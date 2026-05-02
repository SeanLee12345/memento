import AVFoundation
import CoreMedia
import CoreVideo

final class VideoFileFrameProvider: VideoFrameProvider {
  var onFrame: ((CMSampleBuffer) -> Void)?

  private let url: URL
  private let frameInterval: TimeInterval
  private var asset: AVAsset?
  private var reader: AVAssetReader?
  private var output: AVAssetReaderTrackOutput?
  private var timer: Timer?
  private var isRunning = false
  private var frameCount: UInt64 = 0

  init(url: URL, frameRate: Double = 24) {
    self.url = url
    self.frameInterval = 1 / max(frameRate, 1)
  }

  func start() {
    guard !isRunning else { return }
    isRunning = true
    frameCount = 0
    prepareReader()
    timer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { [weak self] _ in
      self?.emitNextFrame()
    }
    timer?.tolerance = frameInterval * 0.20
    AppLogger.log(.stream, "Video file provider started: file=\(url.lastPathComponent), intervalMs=\(String(format: "%.1f", frameInterval * 1_000))")
  }

  func stop() {
    timer?.invalidate()
    timer = nil
    reader?.cancelReading()
    reader = nil
    output = nil
    asset = nil
    isRunning = false
    AppLogger.log(.stream, "Video file provider stopped")
  }

  private func emitNextFrame() {
    guard isRunning else { return }
    guard let sampleBuffer = output?.copyNextSampleBuffer() else {
      AppLogger.log(.stream, "Video file provider reached end; looping")
      prepareReader()
      return
    }

    frameCount += 1
    let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    let timestampText = timestamp.isValid ? String(format: "%.3f", CMTimeGetSeconds(timestamp)) : "invalid"
    AppLogger.log(.frames, "Video file frame #\(frameCount) emitted timestamp=\(timestampText)")
    onFrame?(sampleBuffer)
  }

  private func prepareReader() {
    reader?.cancelReading()

    let asset = AVAsset(url: url)
    self.asset = asset

    guard let videoTrack = asset.tracks(withMediaType: .video).first else {
      AppLogger.log(.stream, "Video file provider failed: no video track in \(url.lastPathComponent)")
      return
    }

    do {
      let reader = try AVAssetReader(asset: asset)
      let output = AVAssetReaderTrackOutput(
        track: videoTrack,
        outputSettings: [
          kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
      )
      output.alwaysCopiesSampleData = false

      guard reader.canAdd(output) else {
        AppLogger.log(.stream, "Video file provider failed: AVAssetReader cannot add video output")
        return
      }

      reader.add(output)
      guard reader.startReading() else {
        AppLogger.log(.stream, "Video file provider failed to start reader: \(reader.error?.localizedDescription ?? "unknown error")")
        return
      }

      self.reader = reader
      self.output = output
    } catch {
      AppLogger.log(.stream, "Video file provider setup failed: \(error.localizedDescription)")
    }
  }
}
