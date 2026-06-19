import AVFoundation
import Foundation

// Plays back a slice of the captured speech buffer so the user can verify
// the voice sample before enrolling.
final class VoicePreviewPlayer {
  private var engine: AVAudioEngine?
  private var playerNode: AVAudioPlayerNode?
  private var playbackID = UUID()

  // Plays `samples` (16 kHz mono float32) and calls `onFinished` on the main
  // thread when playback ends naturally or is interrupted.
  func play(samples: [Float], sampleRate: Double = SpeakerIdentityConfig.targetSampleRate, onFinished: @escaping () -> Void) {
    guard !samples.isEmpty else {
      DispatchQueue.main.async { onFinished() }
      return
    }

    stop()
    let currentPlaybackID = UUID()
    playbackID = currentPlaybackID
    let sanitizedSamples = sanitize(samples)
    let stats = sampleStats(sanitizedSamples)
    AppLogger.log(.audio, "VoicePreviewPlayer play samples=\(sanitizedSamples.count) seconds=\(String(format: "%.2f", Double(sanitizedSamples.count) / sampleRate)) rms=\(String(format: "%.5f", stats.rms)) peak=\(String(format: "%.5f", stats.peak))")

    guard let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: sampleRate,
      channels: 1,
      interleaved: false
    ) else {
      DispatchQueue.main.async { onFinished() }
      return
    }

    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sanitizedSamples.count)),
          let dest = buffer.floatChannelData?[0] else {
      DispatchQueue.main.async { onFinished() }
      return
    }
    buffer.frameLength = AVAudioFrameCount(sanitizedSamples.count)
    for i in 0..<sanitizedSamples.count { dest[i] = sanitizedSamples[i] }

    let engine = AVAudioEngine()
    let playerNode = AVAudioPlayerNode()
    engine.attach(playerNode)
    engine.connect(playerNode, to: engine.mainMixerNode, format: format)
    self.engine = engine
    self.playerNode = playerNode

    do {
      let session = AVAudioSession.sharedInstance()
      try configureAudioSessionForPreview(session)
      try engine.start()
    } catch {
      AppLogger.log(.audio, "VoicePreviewPlayer engine start failed: \(error.localizedDescription)")
      DispatchQueue.main.async { onFinished() }
      return
    }

    playerNode.scheduleBuffer(buffer, at: nil, options: .interrupts, completionCallbackType: .dataPlayedBack) { [weak self] _ in
      guard let self, self.playbackID == currentPlaybackID else { return }
      AppLogger.log(.audio, "VoicePreviewPlayer finished")
      DispatchQueue.main.async { onFinished() }
    }
    playerNode.play()
  }

  func stop() {
    playbackID = UUID()
    playerNode?.stop()
    if engine?.isRunning == true { engine?.stop() }
    playerNode = nil
    engine = nil
  }

  private func sanitize(_ samples: [Float]) -> [Float] {
    samples.map { sample in
      guard sample.isFinite else { return 0 }
      return min(1, max(-1, sample))
    }
  }

  private func sampleStats(_ samples: [Float]) -> (rms: Float, peak: Float) {
    guard !samples.isEmpty else { return (0, 0) }
    var sum: Float = 0
    var peak: Float = 0
    for sample in samples {
      sum += sample * sample
      peak = max(peak, abs(sample))
    }
    return (sqrt(sum / Float(samples.count)), peak)
  }

  private func configureAudioSessionForPreview(_ session: AVAudioSession) throws {
    AppLogger.log(.audio, "VoicePreviewPlayer configuring audio session category=playAndRecord mode=spokenAudio options=defaultToSpeaker")
    try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
    if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
      try? session.setPreferredInput(builtIn)
    }
    try session.overrideOutputAudioPort(.speaker)
    try session.setActive(true)

    let outputRouteDesc = session.currentRoute.outputs.map { "\($0.portName)/\($0.portType.rawValue)" }.joined(separator: ",")
    if Self.routeDescriptionContainsGlassesOutput(outputRouteDesc) {
      throw NSError(
        domain: "VoicePreviewPlayer",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Voice preview refused glasses output route [\(outputRouteDesc)]"]
      )
    }
  }

  private static func routeDescriptionContainsGlassesOutput(_ route: String) -> Bool {
    let lower = route.lowercased()
    return lower.contains("rb meta")
      || lower.contains("ray-ban")
      || lower.contains("rayban")
      || lower.contains("bluetootha2dpoutput")
      || lower.contains("bluetoothhfp")
  }
}
