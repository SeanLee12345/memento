import AVFoundation
import Speech

@MainActor
final class SpeechTranscriptionManager: ObservableObject {
  @Published private(set) var partialTranscript: String = ""
  @Published private(set) var transcriptEntries: [TranscriptEntry] = []
  @Published private(set) var authorizationStatusText: String = "Not requested"
  @Published private(set) var microphoneStatusText: String = "Stopped"
  @Published private(set) var isRunning: Bool = false

  private let audioEngine = AVAudioEngine()
  private let simulatedPlayerNode = AVAudioPlayerNode()
  private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en_US"))
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private var startedAt: Date?
  private var activeTapNode: AVAudioNode?
  private var simulatedPlayerAttached = false
  private var simulatedAudioFile: AVAudioFile?

  func start() async {
    guard !isRunning else { return }

    let speechAuthorized = await requestSpeechAuthorization()
    guard speechAuthorized else {
      AppLogger.log(.audio, "Speech recognition authorization denied: \(authorizationStatusText)")
      return
    }

    let micAuthorized = await requestMicrophoneAuthorization()
    guard micAuthorized else {
      microphoneStatusText = "Microphone denied"
      AppLogger.log(.audio, "Microphone authorization denied")
      return
    }

    do {
      try startAudioEngine()
    } catch {
      microphoneStatusText = "Start failed"
      AppLogger.log(.audio, "Live audio transcription failed to start: \(error.localizedDescription)")
    }
  }

  func startSimulation(audioURL: URL) async {
    guard !isRunning else { return }

    let speechAuthorized = await requestSpeechAuthorization()
    guard speechAuthorized else {
      AppLogger.log(.audio, "Simulated speech authorization denied: \(authorizationStatusText)")
      return
    }

    do {
      try startSimulatedAudioEngine(audioURL: audioURL)
    } catch {
      microphoneStatusText = "Simulation failed"
      AppLogger.log(.audio, "Simulated audio transcription failed to start: \(error.localizedDescription)")
    }
  }

  func stop() {
    guard isRunning || recognitionTask != nil || recognitionRequest != nil else { return }

    activeTapNode?.removeTap(onBus: 0)
    activeTapNode = nil
    simulatedPlayerNode.stop()
    audioEngine.stop()
    recognitionRequest?.endAudio()
    recognitionTask?.cancel()
    recognitionTask = nil
    recognitionRequest = nil
    simulatedAudioFile = nil
    isRunning = false
    microphoneStatusText = "Stopped"
    AppLogger.log(.audio, "Live audio transcription stopped")
  }

  func resetTranscript() {
    partialTranscript = ""
    transcriptEntries = []
  }

  private func requestSpeechAuthorization() async -> Bool {
    await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { status in
        Task { @MainActor in
          switch status {
          case .authorized:
            self.authorizationStatusText = "Speech authorized"
            continuation.resume(returning: true)
          case .denied:
            self.authorizationStatusText = "Speech denied"
            continuation.resume(returning: false)
          case .restricted:
            self.authorizationStatusText = "Speech restricted"
            continuation.resume(returning: false)
          case .notDetermined:
            self.authorizationStatusText = "Speech not determined"
            continuation.resume(returning: false)
          @unknown default:
            self.authorizationStatusText = "Speech unknown"
            continuation.resume(returning: false)
          }
        }
      }
    }
  }

  private func requestMicrophoneAuthorization() async -> Bool {
    await withCheckedContinuation { continuation in
      AVAudioSession.sharedInstance().requestRecordPermission { granted in
        continuation.resume(returning: granted)
      }
    }
  }

  private func startAudioEngine() throws {
    guard let recognizer, recognizer.isAvailable else {
      microphoneStatusText = "Speech unavailable"
      throw SpeechTranscriptionError.recognizerUnavailable
    }

    stop()

    let audioSession = AVAudioSession.sharedInstance()
    try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetooth, .defaultToSpeaker])
    try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    if #available(iOS 13.0, *) {
      request.requiresOnDeviceRecognition = false
    }
    recognitionRequest = request

    startedAt = Date()
    recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
      Task { @MainActor in
        self?.handleRecognition(result: result, error: error)
      }
    }

    let inputNode = audioEngine.inputNode
    let format = inputNode.outputFormat(forBus: 0)
    inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak request] buffer, _ in
      request?.append(buffer)
    }
    activeTapNode = inputNode

    audioEngine.prepare()
    try audioEngine.start()
    isRunning = true
    microphoneStatusText = "Microphone live"
    AppLogger.log(.audio, "Live audio transcription started: sampleRate=\(format.sampleRate), channels=\(format.channelCount), format=\(format.commonFormat.rawValue)")
  }

  private func startSimulatedAudioEngine(audioURL: URL) throws {
    guard let recognizer, recognizer.isAvailable else {
      microphoneStatusText = "Speech unavailable"
      throw SpeechTranscriptionError.recognizerUnavailable
    }

    stop()

    let audioFile = try AVAudioFile(forReading: audioURL)
    simulatedAudioFile = audioFile

    let audioSession = AVAudioSession.sharedInstance()
    try audioSession.setCategory(.playback, mode: .spokenAudio, options: [.defaultToSpeaker])
    try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

    if !simulatedPlayerAttached {
      audioEngine.attach(simulatedPlayerNode)
      simulatedPlayerAttached = true
    }
    audioEngine.connect(simulatedPlayerNode, to: audioEngine.mainMixerNode, format: audioFile.processingFormat)

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    if #available(iOS 13.0, *) {
      request.requiresOnDeviceRecognition = false
    }
    recognitionRequest = request

    startedAt = Date()
    recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
      Task { @MainActor in
        self?.handleRecognition(result: result, error: error)
      }
    }

    simulatedPlayerNode.installTap(onBus: 0, bufferSize: 1_024, format: audioFile.processingFormat) { [weak request] buffer, _ in
      request?.append(buffer)
    }
    activeTapNode = simulatedPlayerNode

    audioEngine.prepare()
    try audioEngine.start()
    scheduleSimulatedAudioFileLoop()
    simulatedPlayerNode.play()
    isRunning = true
    microphoneStatusText = "Simulation audio"
    AppLogger.log(.audio, "Simulated audio transcription started: file=\(audioURL.lastPathComponent), sampleRate=\(audioFile.processingFormat.sampleRate), channels=\(audioFile.processingFormat.channelCount), format=\(audioFile.processingFormat.commonFormat.rawValue)")
  }

  private func scheduleSimulatedAudioFileLoop() {
    guard let simulatedAudioFile else { return }
    simulatedPlayerNode.scheduleFile(simulatedAudioFile, at: nil) { [weak self] in
      Task { @MainActor in
        guard let self, self.isRunning, self.simulatedAudioFile != nil else { return }
        self.scheduleSimulatedAudioFileLoop()
      }
    }
  }

  private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?) {
    if let result {
      let text = result.bestTranscription.formattedString
      partialTranscript = text
      if result.isFinal {
        transcriptEntries.append(
          TranscriptEntry(
            id: UUID(),
            text: text,
            timestamp: Date().timeIntervalSince(startedAt ?? Date()),
            isFinal: true
          )
        )
        partialTranscript = ""
      }
      AppLogger.log(.audio, "Speech transcript updated final=\(result.isFinal): \"\(text)\"")
    }

    if let error {
      microphoneStatusText = "Speech error"
      AppLogger.log(.audio, "Speech recognition error: \(error.localizedDescription)")
      stop()
    }
  }
}

private enum SpeechTranscriptionError: LocalizedError {
  case recognizerUnavailable

  var errorDescription: String? {
    switch self {
    case .recognizerUnavailable:
      return "SFSpeechRecognizer is unavailable for the current locale."
    }
  }
}
