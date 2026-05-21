import AVFoundation
import Combine

enum AudioSource: String, CaseIterable, Identifiable, Sendable {
  case glasses
  case iPhone

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .glasses: return "Glasses mic (Bluetooth)"
    case .iPhone: return "iPhone mic"
    }
  }

  var detailText: String {
    switch self {
    case .glasses: return "Wearer-focused, far speakers suppressed"
    case .iPhone: return "Omnidirectional, captures conversations, defaults output to iPhone speaker"
    }
  }
}

enum AudioSourcePreference {
  private static let key = "audioSourcePreference"
  static var current: AudioSource {
    get {
      if let raw = UserDefaults.standard.string(forKey: key), let s = AudioSource(rawValue: raw) {
        return s
      }
      return .iPhone
    }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
  }
}

@MainActor
final class SpeechTranscriptionManager: ObservableObject {
  @Published private(set) var microphoneStatusText: String = "Stopped"
  @Published private(set) var isRunning: Bool = false

  // Called on the audio tap's background thread for every PCM buffer captured.
  // Assign before calling start(). Used by SpeakerIdentityPipeline and StreamAudioRecorder.
  nonisolated(unsafe) var onAudioBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?

  private let audioEngine = AVAudioEngine()
  private var activeTapNode: AVAudioNode?
  // Observers for AVAudioSession route changes and interruptions. Subscribed in
  // start(), released in stop(). Used to surface BT SCO drops that cause audible
  // gaps in the captured audio.
  private var routeObserver: AnyCancellable?
  private var interruptionObserver: AnyCancellable?
  // Boosts the audio level before it's handed to either the recorder or the
  // live embedding pipeline. HFP from the Ray-Bans is consistently quiet; without
  // this, log-mel features sit near the embedding model's noise floor and matching
  // collapses. Reset on start().
  private let gainRide = TapGainRide()

  @discardableResult
  func start(audioSource: AudioSource = AudioSourcePreference.current) async -> Bool {
    guard !isRunning else { return true }

    let micAuthorized = await requestMicrophoneAuthorization()
    guard micAuthorized else {
      microphoneStatusText = "Microphone denied"
      AppLogger.log(.audio, "Microphone authorization denied")
      return false
    }

    do {
      try startAudioEngine(audioSource: audioSource)
      return true
    } catch {
      stop()
      microphoneStatusText = "Start failed"
      AppLogger.log(.audio, "Live audio capture failed to start: \(error.localizedDescription)")
      return false
    }
  }

  func stop() {
    guard isRunning || activeTapNode != nil else { return }
    activeTapNode?.removeTap(onBus: 0)
    activeTapNode = nil
    audioEngine.stop()
    isRunning = false
    microphoneStatusText = "Stopped"
    routeObserver = nil
    interruptionObserver = nil
    AppLogger.log(.audio, "Live audio capture stopped")
  }

  private func requestMicrophoneAuthorization() async -> Bool {
    await withCheckedContinuation { continuation in
      AVAudioSession.sharedInstance().requestRecordPermission { granted in
        continuation.resume(returning: granted)
      }
    }
  }

  private func startAudioEngine(audioSource: AudioSource) throws {
    let audioSession = AVAudioSession.sharedInstance()
    try Self.applyPreferredAudioSession(audioSession, includeDefaultToSpeaker: audioSource == .iPhone, audioSource: audioSource)
    try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
    if audioSource == .iPhone {
      try? audioSession.overrideOutputAudioPort(.speaker)
      // Explicitly pick the iPhone's built-in mic. Without this, iOS may still
      // route to the glasses if they were the last-used input even though we
      // omitted .allowBluetoothHFP.
      if let builtIn = audioSession.availableInputs?.first(where: { $0.portType == .builtInMic }) {
        try audioSession.setPreferredInput(builtIn)
      } else {
        AppLogger.log(.audio, "[AudioRoute] Built-in mic was not present in availableInputs for iPhone audio source")
      }
    }
    subscribeToAudioSessionEvents(audioSession)

    let inputNode = audioEngine.inputNode
    gainRide.reset()
    // 4096-frame tap (~256 ms at 16 kHz) is more tolerant of brief BT SCO stalls
    // than the original 1024-frame (~64 ms) tap. Larger taps trade a tiny bit of
    // latency for fewer underruns during HFP packet loss.
    let rideRef = gainRide
    inputNode.installTap(onBus: 0, bufferSize: 4_096, format: nil) { [weak self] buffer, _ in
      if let copiedBuffer = SpeechTranscriptionManager.copyPCMBuffer(buffer) {
        rideRef.processInPlace(copiedBuffer)
        self?.onAudioBuffer?(copiedBuffer)
      }
    }
    activeTapNode = inputNode

    audioEngine.prepare()
    try audioEngine.start()
    if audioSource == .iPhone {
      let usingBuiltInMic = audioSession.currentRoute.inputs.contains { $0.portType == .builtInMic }
      if !usingBuiltInMic {
        let routeDesc = audioSession.currentRoute.inputs.map { "\($0.portName)/\($0.portType.rawValue)" }.joined(separator: ",")
        throw NSError(
          domain: "SpeechTranscriptionManager",
          code: 1,
          userInfo: [NSLocalizedDescriptionKey: "iPhone audio requested but active input route is [\(routeDesc)]"]
        )
      }
    }
    isRunning = true
    let liveFormat = inputNode.outputFormat(forBus: 0)
    microphoneStatusText = "Microphone live"
    let inputRouteDesc = audioSession.currentRoute.inputs.map { "\($0.portName)/\($0.portType.rawValue)" }.joined(separator: ",")
    let outputRouteDesc = audioSession.currentRoute.outputs.map { "\($0.portName)/\($0.portType.rawValue)" }.joined(separator: ",")
    AppLogger.log(.audio, "Live audio capture started sampleRate=\(liveFormat.sampleRate), channels=\(liveFormat.channelCount), inputRoute=[\(inputRouteDesc)], outputRoute=[\(outputRouteDesc)], preferredSR=\(audioSession.preferredSampleRate), ioBuffer=\(String(format: "%.3f", audioSession.ioBufferDuration))s, tapBufferFrames=4096")
  }

  private func subscribeToAudioSessionEvents(_ session: AVAudioSession) {
    routeObserver = NotificationCenter.default
      .publisher(for: AVAudioSession.routeChangeNotification)
      .sink { [weak self] note in
        guard let self else { return }
        let reasonRaw = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
        let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw)
        let previousRoute = note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
        let prevDesc = previousRoute?.inputs.map { "\($0.portName)/\($0.portType.rawValue)" }.joined(separator: ",") ?? "none"
        let nowDesc = session.currentRoute.inputs.map { "\($0.portName)/\($0.portType.rawValue)" }.joined(separator: ",")
        let reasonText: String
        switch reason {
        case .newDeviceAvailable: reasonText = "newDeviceAvailable"
        case .oldDeviceUnavailable: reasonText = "oldDeviceUnavailable"
        case .categoryChange: reasonText = "categoryChange"
        case .override: reasonText = "override"
        case .wakeFromSleep: reasonText = "wakeFromSleep"
        case .noSuitableRouteForCategory: reasonText = "noSuitableRouteForCategory"
        case .routeConfigurationChange: reasonText = "routeConfigurationChange"
        default: reasonText = "unknown(\(reasonRaw))"
        }
        let droppedBT = prevDesc.lowercased().contains("bluetoothhfp") && !nowDesc.lowercased().contains("bluetoothhfp")
        let warning = droppedBT ? " ⚠ DROPPED BT MIC — falling back to a different input" : ""
        AppLogger.log(.audio, "[AudioRoute] change reason=\(reasonText) prev=[\(prevDesc)] now=[\(nowDesc)]\(warning)")
        _ = self  // silence unused warning; observer keeps the manager alive
      }
    interruptionObserver = NotificationCenter.default
      .publisher(for: AVAudioSession.interruptionNotification)
      .sink { note in
        let typeRaw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 0
        let type = AVAudioSession.InterruptionType(rawValue: typeRaw)
        let typeText: String
        switch type {
        case .began: typeText = "began"
        case .ended: typeText = "ended"
        default: typeText = "unknown(\(typeRaw))"
        }
        AppLogger.log(.audio, "[AudioInterruption] \(typeText)")
      }
  }

  // Configures the shared audio session for live capture only after DAT video
  // streaming has delivered its first frame.
  //
  // .allowBluetoothHFP (modern option) enables mSBC wideband (16 kHz) negotiation
  // on supporting accessories. Ray-Ban Gen 2 supports mSBC. .allowBluetooth (the
  // legacy flag we previously used) would settle for CVSD narrowband (8 kHz).
  //
  // `includeDefaultToSpeaker` is omitted during live capture: with HFP duplex,
  // forcing output to the phone speaker can destabilize the SCO link on some iOS
  // versions and cause mid-stream drops.
  private static func applyPreferredAudioSession(_ session: AVAudioSession, includeDefaultToSpeaker: Bool, audioSource: AudioSource) throws {
    var options: AVAudioSession.CategoryOptions = []
    // Only allow HFP routing when the user has picked the glasses as source.
    // For .iPhone, omitting this flag prevents iOS from picking the BT mic even
    // when the glasses are paired (they remain paired for DAT video over BLE).
    if audioSource == .glasses { options.insert(.allowBluetoothHFP) }
    if includeDefaultToSpeaker { options.insert(.defaultToSpeaker) }
    // .videoRecording gives the least-processed input mode iOS exposes for the
    // built-in mic, which matters when the user picks .iPhone for conversations.
    // For .glasses, the glasses' firmware DSP dominates anyway so mode mostly
    // affects iOS-side processing — .default keeps AGC on for HFP.
    let mode: AVAudioSession.Mode = audioSource == .iPhone ? .videoRecording : .default
    try session.setCategory(.playAndRecord, mode: mode, options: options)
    let preferredSR: Double = audioSource == .iPhone ? 48_000 : 16_000
    try? session.setPreferredSampleRate(preferredSR)
    try? session.setPreferredInputNumberOfChannels(1)
    try? session.setPreferredIOBufferDuration(0.020)
  }

  // Single-threaded gain ride run from the audio tap. The tap fires from a
  // dedicated audio thread (always the same one), so the mutable state here is
  // race-free in practice. Marked @unchecked Sendable because Swift can't see
  // that contract.
  //
  // Also emits a per-second diagnostic line with pre-gain and post-gain
  // RMS/peak. Use the stream-relative `t=` timestamp to correlate playback
  // moments in the uploaded WAV with the level the BT mic actually delivered.
  // If the far-field speaker's segments show preRMS < 0.001 (~-60 dBFS), the
  // glasses' DSP gated them at source and no amount of post-gain will recover
  // intelligible speech.
  final class TapGainRide: @unchecked Sendable {
    private var smoothedRMS: Float = 0
    private var streamStartedAt: Date?
    private var lastDiagWindowStart: Date?
    private var windowPreRMSSumSq: Double = 0
    private var windowPrePeak: Float = 0
    private var windowPostRMSSumSq: Double = 0
    private var windowPostPeak: Float = 0
    private var windowFrameCount: Int = 0
    // -20 dBFS target. +30 dB max boost. Noise-floor gate at -50 dBFS: below
    // that, the buffer is treated as silence and does not pull smoothedRMS
    // down (otherwise long pauses would push gain through the roof and amplify
    // pure noise in the next speech burst).
    private static let targetRMS: Float = 0.1
    private static let maxGain: Float = 32.0
    private static let alpha: Float = 0.1
    private static let noiseFloorRMS: Float = 0.0031   // ~-50 dBFS
    private static let minGain: Float = 1.0
    private static let diagWindowSeconds: TimeInterval = 1.0

    func reset() {
      smoothedRMS = 0
      streamStartedAt = nil
      lastDiagWindowStart = nil
      windowPreRMSSumSq = 0
      windowPrePeak = 0
      windowPostRMSSumSq = 0
      windowPostPeak = 0
      windowFrameCount = 0
    }

    func processInPlace(_ buffer: AVAudioPCMBuffer) {
      guard let channels = buffer.floatChannelData else { return }
      let frameCount = Int(buffer.frameLength)
      guard frameCount > 0 else { return }
      let samples = channels[0]
      let now = Date()
      if streamStartedAt == nil { streamStartedAt = now }
      if lastDiagWindowStart == nil { lastDiagWindowStart = now }

      var preSumSquares: Float = 0
      var prePeak: Float = 0
      for i in 0..<frameCount {
        let s = samples[i]
        preSumSquares += s * s
        let a = abs(s)
        if a > prePeak { prePeak = a }
      }
      let preRMS = sqrt(preSumSquares / Float(frameCount))

      // Only let speech drive the smoothed level. Silence holds the last
      // speech-calibrated gain; it does not raise gain further.
      if preRMS > Self.noiseFloorRMS {
        smoothedRMS = Self.alpha * preRMS + (1 - Self.alpha) * smoothedRMS
      }
      let reference = max(smoothedRMS, Self.noiseFloorRMS)
      let gain = min(Self.maxGain, max(Self.minGain, Self.targetRMS / reference))

      var postPeak: Float = prePeak * gain
      if postPeak > 1.0 { postPeak = 1.0 }
      if gain > 1.0 {
        for i in 0..<frameCount {
          samples[i] = max(-1.0, min(1.0, samples[i] * gain))
        }
      }
      let postRMS = min(1.0, preRMS * gain)

      // Accumulate into the 1 s diagnostic window.
      windowPreRMSSumSq += Double(preSumSquares)
      windowPrePeak = max(windowPrePeak, prePeak)
      windowPostRMSSumSq += Double(preSumSquares) * Double(gain * gain)
      windowPostPeak = max(windowPostPeak, postPeak)
      windowFrameCount += frameCount

      if let start = lastDiagWindowStart,
         now.timeIntervalSince(start) >= Self.diagWindowSeconds,
         windowFrameCount > 0,
         let streamStart = streamStartedAt {
        let elapsed = now.timeIntervalSince(streamStart)
        let aggPreRMS = sqrt(windowPreRMSSumSq / Double(windowFrameCount))
        let aggPostRMS = min(1.0, sqrt(windowPostRMSSumSq / Double(windowFrameCount)))
        let preDBFS = aggPreRMS > 0 ? 20.0 * log10(aggPreRMS) : -120.0
        let postDBFS = aggPostRMS > 0 ? 20.0 * log10(aggPostRMS) : -120.0
        AppLogger.log(.audio, "[AudioLevel] t=\(String(format: "%.1f", elapsed))s preRMS=\(String(format: "%.5f", aggPreRMS)) (\(String(format: "%.1f", preDBFS))dBFS) prePeak=\(String(format: "%.5f", windowPrePeak)) gain=\(String(format: "%.2f", gain))x postRMS=\(String(format: "%.5f", aggPostRMS)) (\(String(format: "%.1f", postDBFS))dBFS) postPeak=\(String(format: "%.5f", windowPostPeak)) smoothedRMS=\(String(format: "%.5f", smoothedRMS))")
        lastDiagWindowStart = now
        windowPreRMSSumSq = 0
        windowPrePeak = 0
        windowPostRMSSumSq = 0
        windowPostPeak = 0
        windowFrameCount = 0
      }
    }
  }

  nonisolated static func copyPCMBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else {
      return nil
    }
    copy.frameLength = source.frameLength

    let sourceABL = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
    let copyABL = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    guard sourceABL.count == copyABL.count else { return nil }

    for index in 0..<sourceABL.count {
      let sourceBuffer = sourceABL[index]
      let byteCount = Int(sourceBuffer.mDataByteSize)
      guard byteCount > 0,
            let sourceData = sourceBuffer.mData,
            let copyData = copyABL[index].mData else {
        continue
      }
      memcpy(copyData, sourceData, byteCount)
      copyABL[index].mDataByteSize = sourceBuffer.mDataByteSize
    }

    return copy
  }
}
