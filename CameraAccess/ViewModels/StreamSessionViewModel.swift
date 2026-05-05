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
  @Published var inputMode: InputMode = .defaultMode

  @Published var framesReceived: UInt64 = 0
  @Published var previewFrames: UInt64 = 0
  @Published var visionSubmittedFrames: UInt64 = 0
  @Published var visionProcessedFrames: UInt64 = 0
  @Published var droppedFrames: UInt64 = 0
  @Published var lastFrameIntervalText: String = "0.0 ms"
  @Published var liveFrameStatsText: String = "received=0 preview=0 vision=0/0 dropped=0 fps=0.0 avgVision=0.0 ms"
  @Published var partialTranscript: String = ""
  @Published var transcriptEntries: [TranscriptEntry] = []
  @Published var people: [Person] = []
  @Published var speechAuthorizationStatusText: String = "Not requested"
  @Published var microphoneStatusText: String = "Stopped"
  @Published var visionLatencyText: String = "0.0 ms"
  @Published var datSDKStatusText: String = "Not configured"
  @Published var datConfigurationModeText: String = DATConfigurationMode.developerMode.rawValue
  @Published var datRegistrationStateText: String = "Unknown"
  @Published var datDeviceCount: Int = 0
  @Published var datSelectedDeviceIDText: String = "None"
  @Published var datDeviceSessionStateText: String = "None"
  @Published var datRuntimeSessionStateText: String = "UNKNOWN"
  @Published var datStreamSessionStateText: String = "STOPPED"
  @Published var datCameraPermissionStatusText: String = "Not requested"
  @Published var datConnectionStageText: String = DATConnectionStage.sdkConfigured.rawValue
  @Published var datWaitingForMetaAIReturn: Bool = false
  @Published var datIsConnecting: Bool = false
  @Published var datIsDeviceSessionReady: Bool = false
  @Published var datIsStreamRunning: Bool = false
  @Published var datIsAppActive: Bool = true
  @Published var datDevicesStreamActive: Bool = false
  @Published var datMetaAIOpenedTimestampText: String = "never"
  @Published var datLastActiveAfterReturnText: String = "never"
  @Published var datFirstDevicesStreamEventTimestampText: String = "never"
  @Published var datLastDevicesEventTimestampText: String = "never"
  @Published var datSelectedDeviceCompatibilityText: String = "unknown"
  @Published var datSelectedDeviceLinkStateText: String = "unknown"
  @Published var datStartReadinessReasonText: String = "SDK not configured"
  @Published var datFirstFrameTimestampText: String = "none"
  @Published var datLastErrorText: String = "None"
  @Published var datRuntimeBundleConfigurationText: String = "Not inspected"
  @Published var datRuntimeURLTypesText: String = "Not inspected"
  @Published var datRuntimeCameraAccessSchemeText: String = "unknown"
  @Published var datRuntimeAssociatedDomainsText: String = "unknown"
  @Published var datRuntimeDeveloperModeFlagText: String = "unknown"
  @Published var datLastOpenURLText: String = "none"
  @Published var datLastHandleURLResultText: String = "none"
  @Published var datLastRegistrationErrorDetailText: String = "None"
  @Published var datStartRegistrationCalledText: String = "no"
  @Published var datRequestCameraPermissionCalledText: String = "no"
  @Published var datRegistrationHandoffDiagnosticText: String = "No handoff attempted"
  @Published var datFramesReceived: UInt64 = 0
  @Published var datFramesConvertedToUIImage: UInt64 = 0
  @Published var datFrameConversionFailures: UInt64 = 0
  @Published var datLastFrameWidthText: String = "none"
  @Published var datLastFrameHeightText: String = "none"
  @Published var datLastFrameTimestampText: String = "none"
  @Published var datLastFrameErrorText: String = "none"
  @Published var mockDeviceKitEnabled: Bool = false
  @Published var mockDevicePaired: Bool = false
  @Published var mockDevicePoweredOn: Bool = false
  @Published var mockDeviceUnfolded: Bool = false
  @Published var mockDeviceDonned: Bool = false
  @Published var mockDeviceHasVideoFeed: Bool = false
  @Published var mockDeviceIDText: String = "None"
  @Published var mockDeviceErrorText: String = "None"
  @Published var lastFrameTimestampText: String = "none"

  var isStreaming: Bool { lifecycleState.isStreamingSurfaceVisible }
  var canConnectRealGlasses: Bool {
    !datIsConnecting
      && !datWaitingForMetaAIReturn
      && datConnectionStageText != DATConnectionStage.registrationStarting.rawValue
      && datRegistrationStateText != "registering"
  }
  var canStartRealStream: Bool {
    inputMode == .realGlasses
      && datSDKStatusText == "Configured"
      && datIsDeviceSessionReady
      && !datWaitingForMetaAIReturn
      && !datIsStreamRunning
      && datStartReadinessReasonText == "Ready to start real stream"
  }
  var canStartMockDeviceKitStream: Bool {
    inputMode == .mockDeviceKit
      && mockDeviceKitEnabled
      && mockDevicePaired
      && mockDevicePoweredOn
      && mockDeviceUnfolded
      && mockDeviceDonned
      && mockDeviceHasVideoFeed
      && !datIsStreamRunning
  }

  // MARK: - Private

  private let frameProcessor = VisionFaceFrameProcessor()
  private let speechManager = SpeechTranscriptionManager()
  private let datManager = DATGlassesManager.shared
  #if DEBUG
  private let mockDeviceKitManager = MockDeviceKitManager.shared
  #endif
  private var videoProvider: VideoFrameProvider?
  private var cancellables = Set<AnyCancellable>()
  private struct PendingVisionImage {
    let image: UIImage
    let sequence: UInt64
  }

  private var isProcessingFrame = false
  private var pendingVisionImage: PendingVisionImage?
  private let simulationFrameThrottle = 3
  private let maxVisionFPS: TimeInterval = 5
  private let maxPreviewFPS: TimeInterval = 15
  private let verboseFrameLogging = ProcessInfo.processInfo.arguments.contains("--verbose-frame-logging")
  private let forceTestFaceOverlay = ProcessInfo.processInfo.arguments.contains("--ui-testing")

  private var lastSpeakingLogAt: Date?
  private var lastFrameArrival: Date?
  private var lastPreviewUpdateAt: Date?
  private var lastVisionSubmissionAt: Date?
  private var statsWindowStartedAt = Date()
  private var statsWindowReceivedFrames: UInt64 = 0
  private var statsWindowPreviewFrames: UInt64 = 0
  private var statsWindowVisionSubmittedFrames: UInt64 = 0
  private var statsWindowVisionProcessedFrames: UInt64 = 0
  private var statsWindowDroppedFrames: UInt64 = 0
  private var statsWindowVisionDurationMS: Double = 0
  private var statsWindowVisionDurationCount: UInt64 = 0

  // MARK: - Init

  init() {
    inputMode = .defaultMode
    streamStateText = inputMode == .realGlasses ? "REAL READY" : "FILE READY"
    sourceStateText = inputMode.rawValue
    datManager.onFrameImage = { [weak self] image in
      Task { @MainActor in
        self?.handleRealGlassesImage(image)
      }
    }
    datManager.onError = { [weak self] message in
      Task { @MainActor in
        self?.showError(message)
      }
    }
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
    datManager.$sdkStatusText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datSDKStatusText)
    datManager.$configurationModeText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datConfigurationModeText)
    datManager.$registrationStateText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datRegistrationStateText)
    datManager.$deviceCount
      .receive(on: DispatchQueue.main)
      .assign(to: &$datDeviceCount)
    datManager.$selectedDeviceIDText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datSelectedDeviceIDText)
    datManager.$deviceSessionStateText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datDeviceSessionStateText)
    datManager.$runtimeSessionStateText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datRuntimeSessionStateText)
    datManager.$cameraPermissionStatusText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datCameraPermissionStatusText)
    datManager.$connectionStageText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datConnectionStageText)
    datManager.$isWaitingForMetaAIReturn
      .receive(on: DispatchQueue.main)
      .assign(to: &$datWaitingForMetaAIReturn)
    datManager.$isConnecting
      .receive(on: DispatchQueue.main)
      .assign(to: &$datIsConnecting)
    datManager.$isDeviceSessionReady
      .receive(on: DispatchQueue.main)
      .assign(to: &$datIsDeviceSessionReady)
    datManager.$isStreamRunning
      .receive(on: DispatchQueue.main)
      .assign(to: &$datIsStreamRunning)
    datManager.$isAppActive
      .receive(on: DispatchQueue.main)
      .assign(to: &$datIsAppActive)
    datManager.$devicesStreamActive
      .receive(on: DispatchQueue.main)
      .assign(to: &$datDevicesStreamActive)
    datManager.$metaAIOpenedTimestampText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datMetaAIOpenedTimestampText)
    datManager.$lastActiveAfterReturnText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datLastActiveAfterReturnText)
    datManager.$firstDevicesStreamEventTimestampText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datFirstDevicesStreamEventTimestampText)
    datManager.$lastDevicesEventTimestampText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datLastDevicesEventTimestampText)
    datManager.$selectedDeviceCompatibilityText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datSelectedDeviceCompatibilityText)
    datManager.$selectedDeviceLinkStateText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datSelectedDeviceLinkStateText)
    datManager.$startReadinessReasonText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datStartReadinessReasonText)
    datManager.$firstFrameTimestampText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datFirstFrameTimestampText)
    datManager.$lastDATErrorText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datLastErrorText)
    datManager.$runtimeBundleConfigurationText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datRuntimeBundleConfigurationText)
    datManager.$runtimeURLTypesText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datRuntimeURLTypesText)
    datManager.$runtimeCameraAccessSchemeText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datRuntimeCameraAccessSchemeText)
    datManager.$runtimeAssociatedDomainsText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datRuntimeAssociatedDomainsText)
    datManager.$runtimeDeveloperModeFlagText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datRuntimeDeveloperModeFlagText)
    datManager.$lastOpenURLText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datLastOpenURLText)
    datManager.$lastHandleURLResultText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datLastHandleURLResultText)
    datManager.$lastRegistrationErrorDetailText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datLastRegistrationErrorDetailText)
    datManager.$startRegistrationCalledText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datStartRegistrationCalledText)
    datManager.$requestCameraPermissionCalledText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datRequestCameraPermissionCalledText)
    datManager.$registrationHandoffDiagnosticText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datRegistrationHandoffDiagnosticText)
    datManager.$framesReceived
      .receive(on: DispatchQueue.main)
      .assign(to: &$datFramesReceived)
    datManager.$framesConvertedToUIImage
      .receive(on: DispatchQueue.main)
      .assign(to: &$datFramesConvertedToUIImage)
    datManager.$frameConversionFailures
      .receive(on: DispatchQueue.main)
      .assign(to: &$datFrameConversionFailures)
    datManager.$lastFrameWidthText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datLastFrameWidthText)
    datManager.$lastFrameHeightText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datLastFrameHeightText)
    datManager.$lastFrameTimestampText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datLastFrameTimestampText)
    datManager.$lastFrameErrorText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datLastFrameErrorText)
    datManager.$streamSessionStateText
      .receive(on: DispatchQueue.main)
      .sink { [weak self] stateText in
        self?.datStreamSessionStateText = stateText
        self?.streamStateText = stateText
        self?.syncLifecycleFromDATState(stateText)
      }
      .store(in: &cancellables)
    #if DEBUG
    mockDeviceKitManager.$isEnabled
      .receive(on: DispatchQueue.main)
      .assign(to: &$mockDeviceKitEnabled)
    mockDeviceKitManager.$isPaired
      .receive(on: DispatchQueue.main)
      .assign(to: &$mockDevicePaired)
    mockDeviceKitManager.$isPoweredOn
      .receive(on: DispatchQueue.main)
      .assign(to: &$mockDevicePoweredOn)
    mockDeviceKitManager.$isUnfolded
      .receive(on: DispatchQueue.main)
      .assign(to: &$mockDeviceUnfolded)
    mockDeviceKitManager.$isDonned
      .receive(on: DispatchQueue.main)
      .assign(to: &$mockDeviceDonned)
    mockDeviceKitManager.$hasVideoFeed
      .receive(on: DispatchQueue.main)
      .assign(to: &$mockDeviceHasVideoFeed)
    mockDeviceKitManager.$mockDeviceIDText
      .receive(on: DispatchQueue.main)
      .assign(to: &$mockDeviceIDText)
    mockDeviceKitManager.$lastMockErrorText
      .receive(on: DispatchQueue.main)
      .assign(to: &$mockDeviceErrorText)
    #endif
  }

  // MARK: - Public API

  func stopSession() async {
    speechManager.stop()
    await datManager.stopStream()
    stopVideoProvider()
    lifecycleState = .stopped
    streamingStatus = .stopped
    streamStateText = StreamLifecycleState.stopped.rawValue
    sourceStateText = inputMode.rawValue
    resetVideoState()
  }

  func connectRealGlasses() async {
    inputMode = .realGlasses
    sourceStateText = inputMode.rawValue
    guard !datManager.isSimulator else {
      showError("Real Meta glasses connection requires a physical iPhone. Use Mock Device Kit mode on simulator.")
      return
    }
    await datManager.connectRealGlasses()
  }

  func startRealGlassesStream() async {
    inputMode = .realGlasses
    sourceStateText = inputMode.rawValue
    guard !datManager.isSimulator else {
      showError("Real Meta glasses connection requires a physical iPhone. Use Mock Device Kit mode on simulator.")
      return
    }
    guard datManager.canStartStream else {
      showError("Start Real Stream blocked: \(datStartReadinessReasonText)")
      AppLogger.log(.stream, "Start Real Stream tapped before ready: \(datStartReadinessReasonText)")
      return
    }

    speechManager.stop()
    stopVideoProvider()
    resetVideoState()
    framesReceived = 0
    previewFrames = 0
    visionSubmittedFrames = 0
    visionProcessedFrames = 0
    droppedFrames = 0
    liveFrameStatsText = "received=0 preview=0 vision=0/0 dropped=0 fps=0.0 avgVision=0.0 ms"
    lastFrameIntervalText = "0.0 ms"
    lastFrameTimestampText = "none"
    lastFrameArrival = nil
    lastPreviewUpdateAt = nil
    lastVisionSubmissionAt = nil
    pendingVisionImage = nil
    resetStatsWindow()

    lifecycleState = .starting
    streamingStatus = .waiting
    streamStateText = "STARTING"
    sourceStateText = "REAL GLASSES"

    let started = await datManager.startStream()
    if started {
      await speechManager.start()
      lifecycleState = .waiting
      streamingStatus = .waiting
      AppLogger.log(.stream, "Real glasses stream start requested")
    } else {
      lifecycleState = .error
      streamingStatus = .stopped
    }
  }

  func unregisterDATApp() async {
    await datManager.unregisterDATApp()
  }

  func resetDATDeviceSession() async {
    await datManager.resetDeviceSession()
  }

  func useSimulationMode() {
    inputMode = .simulation
    sourceStateText = inputMode.rawValue
    streamStateText = "FILE READY"
  }

  func useMockDeviceKitMode() {
    inputMode = .mockDeviceKit
    sourceStateText = inputMode.rawValue
    streamStateText = "MOCK READY"
    #if DEBUG
    mockDeviceKitManager.enable()
    #else
    showError("Mock Device Kit is available only in Debug builds.")
    #endif
  }

  func pairMockRayBanMeta() {
    #if DEBUG
    inputMode = .mockDeviceKit
    sourceStateText = inputMode.rawValue
    mockDeviceKitManager.pairRayBanMeta()
    #endif
  }

  func powerOnMockDevice() {
    #if DEBUG
    mockDeviceKitManager.powerOn()
    #endif
  }

  func unfoldMockDevice() {
    #if DEBUG
    mockDeviceKitManager.unfold()
    #endif
  }

  func donMockDevice() {
    #if DEBUG
    mockDeviceKitManager.don()
    #endif
  }

  func selectMockVideo() {
    #if DEBUG
    mockDeviceKitManager.selectBundledVideo()
    #endif
  }

  func startMockDeviceKitStream() async {
    #if DEBUG
    inputMode = .mockDeviceKit
    sourceStateText = inputMode.rawValue
    guard canStartMockDeviceKitStream else {
      showError("Set up Mock Device Kit first: Pair RayBan Meta, PowerOn, Unfold, Don, Select video.")
      return
    }

    speechManager.stop()
    stopVideoProvider()
    resetVideoState()
    framesReceived = 0
    previewFrames = 0
    visionSubmittedFrames = 0
    visionProcessedFrames = 0
    droppedFrames = 0
    liveFrameStatsText = "received=0 preview=0 vision=0/0 dropped=0 fps=0.0 avgVision=0.0 ms"
    lastFrameIntervalText = "0.0 ms"
    lastFrameTimestampText = "none"
    lastFrameArrival = nil
    lastPreviewUpdateAt = nil
    lastVisionSubmissionAt = nil
    pendingVisionImage = nil
    resetStatsWindow()

    lifecycleState = .starting
    streamingStatus = .waiting
    streamStateText = "MOCK STARTING"
    sourceStateText = "MOCK DEVICE KIT"

    _ = await datManager.requestCameraPermission()
    _ = await datManager.prepareDeviceSession(reason: "mock-device-kit")
    guard datManager.canStartStream else {
      lifecycleState = .error
      streamingStatus = .stopped
      showError("Mock Device Kit DAT DeviceSession is not ready yet. Check runtime session state and device link state.")
      return
    }

    let started = await datManager.startStream()
    if started {
      await speechManager.start()
      lifecycleState = .waiting
      streamingStatus = .waiting
      AppLogger.log(.stream, "Mock Device Kit stream start requested")
    } else {
      lifecycleState = .error
      streamingStatus = .stopped
    }
    #else
    showError("Mock Device Kit is available only in Debug builds.")
    #endif
  }

  func startSimulation() async {
    guard let videoURL = Bundle.main.url(forResource: "Compressed Video", withExtension: "mp4") else {
      showError("Simulation file missing: add Compressed Video.mp4 to the CameraAccess target resources.")
      return
    }

    speechManager.stop()
    await datManager.stopStream()
    stopVideoProvider()
    resetVideoState()

    inputMode = .simulation
    lifecycleState = .running
    streamingStatus = .streaming
    streamStateText = "FILE STREAMING"
    sourceStateText = "LOCAL FILE"
    framesReceived = 0
    previewFrames = 0
    visionSubmittedFrames = 0
    visionProcessedFrames = 0
    droppedFrames = 0
    liveFrameStatsText = "received=0 preview=0 vision=0/0 dropped=0 fps=0.0 avgVision=0.0 ms"
    lastFrameIntervalText = "0.0 ms"
    lastFrameTimestampText = "none"
    lastFrameArrival = nil
    lastPreviewUpdateAt = nil
    lastVisionSubmissionAt = nil
    pendingVisionImage = nil
    resetStatsWindow()

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
    guard sequence % UInt64(simulationFrameThrottle) == 0 || forceTestFaceOverlay else {
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

  private func enqueue(
    image: UIImage,
    sequence: UInt64
  ) -> Bool {
    let now = Date()
    guard forceTestFaceOverlay || shouldSubmitVisionFrame(at: now) else {
      replacePendingVisionImage(image: image, sequence: sequence)
      return false
    }
    guard !isProcessingFrame else {
      replacePendingVisionImage(image: image, sequence: sequence)
      return false
    }
    submitVisionFrame(image: image, sequence: sequence, submittedAt: now)
    return true
  }

  private func submitVisionFrame(image: UIImage, sequence: UInt64, submittedAt: Date) {
    isProcessingFrame = true
    lastVisionSubmissionAt = submittedAt
    visionSubmittedFrames += 1
    statsWindowVisionSubmittedFrames += 1
    Task { [weak self] in
      guard let self else { return }
      let startedAt = Date()
      let result = await frameProcessor.process(
        image: image,
        sequence: sequence,
        forceTestFaceOverlay: forceTestFaceOverlay
      )
      let durationMS = Date().timeIntervalSince(startedAt) * 1_000
      await MainActor.run {
        if let result {
          self.visionProcessedFrames += 1
          self.statsWindowVisionProcessedFrames += 1
          self.statsWindowVisionDurationMS += durationMS
          self.statsWindowVisionDurationCount += 1
          self.currentImageSize = result.imageSize
          self.detectedFaces = result.faces
          self.people = result.people
          self.visionLatencyText = String(format: "%.1f ms", durationMS)
          self.logSpeakingIfNeeded()
          if !self.hasReceivedFirstFrame {
            self.hasReceivedFirstFrame = true
          }
        } else {
          self.noteDroppedFrame(sequence: sequence, reason: "Vision returned no result", shouldLog: self.verboseFrameLogging)
        }
        self.isProcessingFrame = false
        self.flushPendingVisionImageIfReady()
        self.emitAggregateFrameStatsIfNeeded(force: false)
      }
    }
  }

  private func handleRealGlassesImage(_ image: UIImage) {
    framesReceived += 1
    statsWindowReceivedFrames += 1
    let sequence = framesReceived
    let now = Date()
    if let lastFrameArrival {
      lastFrameIntervalText = String(format: "%.1f ms", now.timeIntervalSince(lastFrameArrival) * 1_000)
    }
    lastFrameArrival = now
    lastFrameTimestampText = String(format: "%.3f", now.timeIntervalSince1970)

    let size = image.size
    if verboseFrameLogging {
      AppLogger.log(.frames, "Real DAT frame #\(sequence) arrived imageSize=\(Int(size.width))x\(Int(size.height)), timestamp=\(lastFrameTimestampText)")
    }

    if shouldUpdatePreview(at: now) {
      previewFrames += 1
      statsWindowPreviewFrames += 1
      lastPreviewUpdateAt = now
      currentVideoFrame = image
      currentImageSize = size
      if !hasReceivedFirstFrame {
        hasReceivedFirstFrame = true
      }
    }

    let accepted = enqueue(image: image, sequence: sequence)
    if verboseFrameLogging {
      AppLogger.log(.frames, "Real DAT frame #\(sequence) sentToPreview=true, sentToVision=\(accepted)")
    }
    if !accepted {
      noteDroppedFrame(sequence: sequence, reason: "latest-frame-wins throttle", shouldLog: false)
    }
    emitAggregateFrameStatsIfNeeded(force: false)
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
    lastFrameTimestampText = timestampText

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

  private func shouldUpdatePreview(at now: Date) -> Bool {
    guard !forceTestFaceOverlay else { return true }
    guard let lastPreviewUpdateAt else { return true }
    return now.timeIntervalSince(lastPreviewUpdateAt) >= 1 / maxPreviewFPS
  }

  private func shouldSubmitVisionFrame(at now: Date) -> Bool {
    guard let lastVisionSubmissionAt else { return true }
    return now.timeIntervalSince(lastVisionSubmissionAt) >= 1 / maxVisionFPS
  }

  private func replacePendingVisionImage(image: UIImage, sequence: UInt64) {
    pendingVisionImage = PendingVisionImage(image: image, sequence: sequence)
  }

  private func flushPendingVisionImageIfReady() {
    guard let pendingVisionImage else { return }
    let now = Date()
    guard shouldSubmitVisionFrame(at: now), !isProcessingFrame else { return }
    self.pendingVisionImage = nil
    submitVisionFrame(image: pendingVisionImage.image, sequence: pendingVisionImage.sequence, submittedAt: now)
  }

  private func noteDroppedFrame(sequence: UInt64, reason: String, shouldLog: Bool = true) {
    droppedFrames += 1
    statsWindowDroppedFrames += 1
    if shouldLog || verboseFrameLogging {
      AppLogger.log(.frames, "Dropped \(inputMode.rawValue) frame #\(sequence): \(reason). dropped=\(droppedFrames)")
    }
  }

  private func emitAggregateFrameStatsIfNeeded(force: Bool) {
    let now = Date()
    let elapsed = now.timeIntervalSince(statsWindowStartedAt)
    guard force || elapsed >= 2 else { return }
    let fps = elapsed > 0 ? Double(statsWindowReceivedFrames) / elapsed : 0
    let avgVisionMS = statsWindowVisionDurationCount > 0
      ? statsWindowVisionDurationMS / Double(statsWindowVisionDurationCount)
      : 0
    liveFrameStatsText = String(
      format: "received=%llu preview=%llu vision=%llu/%llu dropped=%llu fps=%.1f avgVision=%.1f ms",
      framesReceived,
      previewFrames,
      visionProcessedFrames,
      visionSubmittedFrames,
      droppedFrames,
      fps,
      avgVisionMS
    )
    AppLogger.log(
      .frames,
      String(
        format: "Live frame stats: windowReceived=%llu windowPreview=%llu windowVision=%llu/%llu windowDropped=%llu totalReceived=%llu totalPreview=%llu totalVision=%llu/%llu totalDropped=%llu currentFPS=%.1f averageVisionMs=%.1f",
        statsWindowReceivedFrames,
        statsWindowPreviewFrames,
        statsWindowVisionProcessedFrames,
        statsWindowVisionSubmittedFrames,
        statsWindowDroppedFrames,
        framesReceived,
        previewFrames,
        visionProcessedFrames,
        visionSubmittedFrames,
        droppedFrames,
        fps,
        avgVisionMS
      )
    )
    resetStatsWindow(startedAt: now)
  }

  private func resetStatsWindow(startedAt: Date = Date()) {
    statsWindowStartedAt = startedAt
    statsWindowReceivedFrames = 0
    statsWindowPreviewFrames = 0
    statsWindowVisionSubmittedFrames = 0
    statsWindowVisionProcessedFrames = 0
    statsWindowDroppedFrames = 0
    statsWindowVisionDurationMS = 0
    statsWindowVisionDurationCount = 0
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
    pendingVisionImage = nil
    lastPreviewUpdateAt = nil
    lastVisionSubmissionAt = nil
    lastFrameTimestampText = "none"
  }

  private func syncLifecycleFromDATState(_ stateText: String) {
    guard inputMode == .realGlasses else { return }
    let lower = stateText.lowercased()
    if lower.contains("streaming") {
      lifecycleState = .running
      streamingStatus = .streaming
    } else if lower.contains("paused") {
      lifecycleState = .paused
      streamingStatus = .paused
    } else if lower.contains("starting") || lower.contains("waiting") {
      lifecycleState = .waiting
      streamingStatus = .waiting
    } else if lower.contains("stopping") {
      lifecycleState = .stopping
      streamingStatus = .waiting
    } else if lower.contains("stopped") {
      lifecycleState = .stopped
      streamingStatus = .stopped
    }
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
