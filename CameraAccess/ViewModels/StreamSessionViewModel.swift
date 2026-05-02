/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Combine
import CoreMedia
import CoreVideo
import SwiftUI

enum StreamingStatus {
  case streaming
  case waiting
  case paused
  case stopped
}

/// ViewModel for the local file simulation. Decoding is delegated to VideoFileFrameProvider
/// and frame analysis is delegated to VisionFaceFrameProcessor.
@MainActor
final class StreamSessionViewModel: ObservableObject {
  // MARK: - Published State

  @Published var currentVideoFrame: UIImage?
  @Published var currentImageSize: CGSize = .zero
  @Published var detectedFaces: [DetectedFace] = []
  @Published var hasReceivedFirstFrame: Bool = false
  @Published var streamingStatus: StreamingStatus = .stopped
  @Published var lifecycleState: StreamLifecycleState = .stopped
  @Published var streamStateText: String = StreamLifecycleState.stopped.rawValue
  @Published var sourceStateText: String = "LOCAL"
  @Published var showError: Bool = false
  @Published var errorMessage: String = ""

  @Published var framesReceived: UInt64 = 0
  @Published var droppedFrames: UInt64 = 0
  @Published var lastFrameIntervalText: String = "0.0 ms"
  @Published var partialTranscript: String = ""
  @Published var transcriptEntries: [TranscriptEntry] = []
  @Published var people: [Person] = []
  @Published var speechAuthorizationStatusText: String = "Not requested"
  @Published var microphoneStatusText: String = "Stopped"
  @Published var visionLatencyText: String = "0.0 ms"

  var isStreaming: Bool { lifecycleState.isStreamingSurfaceVisible }

  // MARK: - Private

  private let frameProcessor = VisionFaceFrameProcessor()
  private let speechManager = SpeechTranscriptionManager()
  private var videoProvider: VideoFrameProvider?
  private var cancellables = Set<AnyCancellable>()
  private var isProcessingFrame = false
  private let frameThrottle = 3
  private let forceTestFaceOverlay = ProcessInfo.processInfo.arguments.contains("--ui-testing")

  private var lastSpeakingLogAt: Date?
  private var lastFrameArrival: Date?

  // MARK: - Init

  init() {
    streamStateText = "FILE READY"
    sourceStateText = "LOCAL"
    speechManager.$partialTranscript
      .receive(on: DispatchQueue.main)
      .sink { [weak self] transcript in
        self?.partialTranscript = transcript
        self?.logSpeakingIfNeeded()
      }
      .store(in: &cancellables)
    speechManager.$transcriptEntries
      .receive(on: DispatchQueue.main)
      .sink { [weak self] entries in
        self?.transcriptEntries = entries
        self?.logSpeakingIfNeeded()
      }
      .store(in: &cancellables)
    speechManager.$authorizationStatusText
      .receive(on: DispatchQueue.main)
      .assign(to: &$speechAuthorizationStatusText)
    speechManager.$microphoneStatusText
      .receive(on: DispatchQueue.main)
      .assign(to: &$microphoneStatusText)
  }

  // MARK: - Public API

  func stopSession() async {
    speechManager.stop()
    stopVideoProvider()
    lifecycleState = .stopped
    streamingStatus = .stopped
    streamStateText = StreamLifecycleState.stopped.rawValue
    sourceStateText = "LOCAL"
    resetVideoState()
  }

  func startSimulation() async {
    guard let videoURL = Bundle.main.url(forResource: "Compressed Video", withExtension: "mp4") else {
      showError("Simulation file missing: add Compressed Video.mp4 to the CameraAccess target resources.")
      return
    }

    speechManager.stop()
    stopVideoProvider()
    resetVideoState()

    lifecycleState = .running
    streamingStatus = .streaming
    streamStateText = "FILE STREAMING"
    sourceStateText = "LOCAL FILE"
    framesReceived = 0
    droppedFrames = 0
    lastFrameIntervalText = "0.0 ms"
    lastFrameArrival = nil

    let provider = VideoFileFrameProvider(url: videoURL)
    provider.onFrame = { [weak self] sampleBuffer in
      Task { @MainActor in
        self?.handleSampleBuffer(sampleBuffer)
      }
    }
    videoProvider = provider
    provider.start()
    await speechManager.startSimulation(audioURL: videoURL)
    AppLogger.log(.stream, "Simulation started from Compressed Video.mp4")
  }

  func dismissError() {
    showError = false
    errorMessage = ""
  }

  // MARK: - Private

  private func enqueue(
    sampleBuffer: CMSampleBuffer,
    sequence: UInt64
  ) -> Bool {
    guard sequence % UInt64(frameThrottle) == 0 || forceTestFaceOverlay else {
      return false
    }
    guard !isProcessingFrame else { return false }
    isProcessingFrame = true
    Task { [weak self] in
      guard let self else { return }
      let result = await frameProcessor.process(
        sampleBuffer: sampleBuffer,
        sequence: sequence,
        forceTestFaceOverlay: forceTestFaceOverlay
      )
      await MainActor.run {
        if let result {
          let latencyMS = Date().timeIntervalSince(result.processedAt) * 1_000
          self.currentVideoFrame = result.image
          self.currentImageSize = result.imageSize
          self.detectedFaces = result.faces
          self.people = result.people
          self.visionLatencyText = String(format: "%.1f ms", latencyMS)
          self.logSpeakingIfNeeded()
          if !self.hasReceivedFirstFrame {
            self.hasReceivedFirstFrame = true
          }
        } else {
          self.noteDroppedFrame(sequence: sequence, reason: "frame conversion failed")
        }
        self.isProcessingFrame = false
      }
    }
    return true
  }

  private func handleSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
    framesReceived += 1
    let sequence = framesReceived
    let now = Date()
    if let lastFrameArrival {
      lastFrameIntervalText = String(format: "%.1f ms", now.timeIntervalSince(lastFrameArrival) * 1_000)
    }
    lastFrameArrival = now

    let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    let timestampText = timestamp.isValid ? String(format: "%.3f", CMTimeGetSeconds(timestamp)) : "invalid"

    if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
      let width = CVPixelBufferGetWidth(pixelBuffer)
      let height = CVPixelBufferGetHeight(pixelBuffer)
      AppLogger.log(.frames, "File frame #\(sequence) arrived size=\(width)x\(height), timestamp=\(timestampText)")
    } else {
      AppLogger.log(.frames, "File frame #\(sequence) missing CVPixelBuffer, timestamp=\(timestampText)")
    }

    let accepted = enqueue(sampleBuffer: sampleBuffer, sequence: sequence)
    if !accepted {
      noteDroppedFrame(sequence: sequence, reason: "processor busy or throttled")
    }
  }

  private func noteDroppedFrame(sequence: UInt64, reason: String) {
    droppedFrames += 1
    AppLogger.log(.frames, "Dropped file frame #\(sequence): \(reason). dropped=\(droppedFrames)")
  }

  private func stopVideoProvider() {
    videoProvider?.stop()
    videoProvider = nil
    lastFrameArrival = nil
  }

  private func resetVideoState() {
    currentVideoFrame = nil
    currentImageSize = .zero
    detectedFaces = []
    people = []
    hasReceivedFirstFrame = false
    isProcessingFrame = false
  }

  private func showError(_ message: String) {
    errorMessage = message
    showError = true
  }

  private func logSpeakingIfNeeded() {
    let transcript = currentTranscriptText()
    guard !detectedFaces.isEmpty, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    let now = Date()
    if let lastSpeakingLogAt, now.timeIntervalSince(lastSpeakingLogAt) < 1 {
      return
    }
    lastSpeakingLogAt = now
    AppLogger.log(.audio, "Person speaking: faces=\(detectedFaces.count), transcript=\"\(transcript)\"")
  }

  private func currentTranscriptText() -> String {
    if !partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return partialTranscript
    }
    return transcriptEntries.last?.text ?? ""
  }
}
