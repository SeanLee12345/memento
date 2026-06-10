import AVFoundation
import Foundation

struct AlibabaTranscriptionSettings {
  private enum Keys {
    static let enabled = "alibaba.liveTranscription.enabled"
  }

  static let defaultBaseURL = "https://dashscope-us.aliyuncs.com/compatible-mode/v1"
  static let defaultModel = "qwen3-asr-flash-us"

  var enabled: Bool
  var apiKey: String
  var baseURL: String
  var model: String

  static func load() -> AlibabaTranscriptionSettings {
    let defaults = UserDefaults.standard
    let env = DotEnvFile.load()
    let envEnabled = boolValue(ProcessInfo.processInfo.environment["DASHSCOPE_LIVE_TRANSCRIPTION_ENABLED"]
                               ?? env["DASHSCOPE_LIVE_TRANSCRIPTION_ENABLED"])
    let savedEnabled = defaults.object(forKey: Keys.enabled) as? Bool
    let apiKey = ProcessInfo.processInfo.environment["DASHSCOPE_API_KEY"]
      ?? ProcessInfo.processInfo.environment["ALIBABA_DASHSCOPE_API_KEY"]
      ?? env["DASHSCOPE_API_KEY"]
      ?? env["ALIBABA_DASHSCOPE_API_KEY"]
      ?? ""
    let baseURL = ProcessInfo.processInfo.environment["DASHSCOPE_BASE_URL"]
      ?? env["DASHSCOPE_BASE_URL"]
      ?? defaultBaseURL
    let model = ProcessInfo.processInfo.environment["DASHSCOPE_ASR_MODEL"]
      ?? env["DASHSCOPE_ASR_MODEL"]
      ?? defaultModel
    return AlibabaTranscriptionSettings(
      enabled: savedEnabled ?? envEnabled ?? true,
      apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
      baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultBaseURL : baseURL,
      model: model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultModel : model
    )
  }

  static func saveEnabled(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: Keys.enabled)
  }

  private static func boolValue(_ raw: String?) -> Bool? {
    guard let raw else { return nil }
    switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "1", "true", "yes", "on": return true
    case "0", "false", "no", "off": return false
    default: return nil
    }
  }
}

struct AlibabaLiveTranscriptSegment: Sendable {
  let id: UUID
  let text: String
  let startedAt: Date
  let endedAt: Date
  let durationSeconds: Double
  let model: String
}

enum AlibabaLiveTranscriptionUpdate: Sendable {
  case status(String)
  case transcript(AlibabaLiveTranscriptSegment)
  case failure(String)
}

enum AlibabaTranscriptionError: LocalizedError {
  case missingAPIKey
  case invalidBaseURL
  case badHTTPStatus(Int, String)
  case emptyResponse

  var errorDescription: String? {
    switch self {
    case .missingAPIKey:
      return "Alibaba DashScope API key is missing."
    case .invalidBaseURL:
      return "Alibaba DashScope base URL is invalid."
    case .badHTTPStatus(let status, let body):
      return "Alibaba DashScope returned HTTP \(status): \(body)"
    case .emptyResponse:
      return "Alibaba DashScope returned an empty transcript."
    }
  }
}

struct AlibabaTranscriptionClient {
  private let apiKey: String
  private let endpoint: URL
  private let model: String
  private let session: URLSession
  private let useProxy: Bool

  init(settings: AlibabaTranscriptionSettings, session: URLSession = .shared) throws {
    let canUseProxy = SupabaseEdgeFunctionClient.isConfigured()
    guard canUseProxy || !settings.apiKey.isEmpty else {
      throw AlibabaTranscriptionError.missingAPIKey
    }
    let endpoint: URL
    if var components = URLComponents(string: settings.baseURL),
       components.scheme != nil,
       components.host != nil {
      let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      components.path = "/" + ([path, "chat/completions"].filter { !$0.isEmpty }.joined(separator: "/"))
      guard let resolved = components.url else {
        throw AlibabaTranscriptionError.invalidBaseURL
      }
      endpoint = resolved
    } else if canUseProxy {
      endpoint = URL(string: "https://supabase.local/functions/v1/memento-ai")!
    } else {
      throw AlibabaTranscriptionError.invalidBaseURL
    }
    self.apiKey = settings.apiKey
    self.endpoint = endpoint
    self.model = settings.model
    self.session = session
    self.useProxy = canUseProxy
  }

  func transcribe(wavData: Data) async throws -> String {
    if useProxy {
      let proxy = try SupabaseEdgeFunctionClient.shared(session: session)
      let payload = AIProxyLiveASRPayload(
        model: model,
        wavBase64: wavData.base64EncodedString(),
        timeoutSeconds: 35
      )
      let response: AIProxyFunctionResponse<AIProxyLiveASROutput> = try await proxy.invoke(
        operation: "qwen.live_asr",
        payload: payload,
        timeoutInterval: 40
      )
      guard let output = response.output,
            !output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw AlibabaTranscriptionError.emptyResponse
      }
      AppLogger.log(.transcript, "[ASR_PROXY] windowBytes=\(wavData.count) model=\(response.model ?? model) status=success")
      return output.text
    }

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = 35
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(ChatCompletionRequest(
      model: model,
      messages: [
        ChatMessage(
          role: "user",
          content: [
            ChatMessageContent(
              type: "input_audio",
              inputAudio: InputAudio(
                data: "data:audio/wav;base64,\(wavData.base64EncodedString())",
                format: "wav"
              )
            )
          ]
        )
      ]
    ))

    let (data, response) = try await session.data(for: request)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      let body = String(data: data, encoding: .utf8) ?? ""
      throw AlibabaTranscriptionError.badHTTPStatus(http.statusCode, body)
    }
    let text = try Self.extractTranscript(from: data)
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AlibabaTranscriptionError.emptyResponse
    }
    return text
  }

  private struct AIProxyLiveASRPayload: Encodable {
    var model: String
    var wavBase64: String
    var timeoutSeconds: Int
  }

  private struct AIProxyLiveASROutput: Decodable {
    var text: String
  }

  private static func extractTranscript(from data: Data) throws -> String {
    let root = try JSONSerialization.jsonObject(with: data)
    if let dict = root as? [String: Any] {
      if let choices = dict["choices"] as? [[String: Any]],
         let text = textFromChoice(choices.first) {
        return text
      }
      if let output = dict["output"] as? [String: Any] {
        if let choices = output["choices"] as? [[String: Any]],
           let text = textFromChoice(choices.first) {
          return text
        }
        if let text = output["text"] as? String {
          return text
        }
        if let transcripts = output["transcripts"] as? [[String: Any]],
           let text = transcripts.compactMap({ $0["text"] as? String }).joined(separator: " ").nilIfEmpty {
          return text
        }
      }
    }
    throw AlibabaTranscriptionError.emptyResponse
  }

  private static func textFromChoice(_ choice: [String: Any]?) -> String? {
    guard let choice else { return nil }
    if let message = choice["message"] as? [String: Any] {
      if let text = message["content"] as? String {
        return text
      }
      if let content = message["content"] as? [[String: Any]] {
        let text = content.compactMap { item in
          item["text"] as? String ?? item["transcript"] as? String
        }.joined(separator: " ")
        return text.nilIfEmpty
      }
    }
    return choice["text"] as? String
  }

  private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
  }

  private struct ChatMessage: Encodable {
    let role: String
    let content: [ChatMessageContent]
  }

  private struct ChatMessageContent: Encodable {
    let type: String
    let inputAudio: InputAudio

    enum CodingKeys: String, CodingKey {
      case type
      case inputAudio = "input_audio"
    }
  }

  private struct InputAudio: Encodable {
    let data: String
    let format: String
  }
}

final class AlibabaLiveAudioChunkTranscriber: @unchecked Sendable {
  static let chunkSeconds = 5.0
  static let overlapSeconds = 2.0
  // ASR speech gating: a chunk is only sent to the cloud when at least one short
  // analysis window inside it rises above the speech floor. Reuses the speaker
  // VAD floor so live ASR and speaker VAD agree on what counts as "speech".
  static let speechRMSThreshold: Float = SpeakerIdentityConfig.vadEnergyThresholdRMS
  // Width of the sub-window scanned for a speech burst inside a chunk. A 5s chunk
  // with a brief utterance surrounded by silence still passes because the peak
  // window — not the diluted whole-chunk average — drives the decision.
  static let vadWindowSeconds = 0.20

  private let queue = DispatchQueue(label: "com.cameraaccess.alibaba-live-transcription")
  private let targetFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16,
    sampleRate: 16_000,
    channels: 1,
    interleaved: false
  )!

  private var isRunning = false
  private var generation = UUID()
  private var client: AlibabaTranscriptionClient?
  private var model = AlibabaTranscriptionSettings.defaultModel
  private var onUpdate: (@Sendable (AlibabaLiveTranscriptionUpdate) -> Void)?
  private var converter: AVAudioConverter?
  private var converterInputFormat: AVAudioFormat?
  private var pcmData = Data()
  private var pcmFrameCount: AVAudioFramePosition = 0
  private var chunkStartedAt: Date?
  private var pendingRequestCount = 0
  private let maxPendingRequests = 2
  private var deliveredTranscriptContext = ""

  func start(
    settings: AlibabaTranscriptionSettings,
    onUpdate: @escaping @Sendable (AlibabaLiveTranscriptionUpdate) -> Void
  ) {
    queue.async { [weak self] in
      guard let self else { return }
      self.resetBuffer()
      self.converter = nil
      self.converterInputFormat = nil
      self.client = nil
      self.pendingRequestCount = 0
      self.deliveredTranscriptContext = ""
      self.onUpdate = onUpdate
      self.generation = UUID()
      guard settings.enabled else {
        self.isRunning = false
        onUpdate(.status("Alibaba ASR disabled"))
        return
      }
      do {
        self.client = try AlibabaTranscriptionClient(settings: settings)
        self.model = settings.model
        self.isRunning = true
        onUpdate(.status("Alibaba ASR listening: \(settings.model)"))
        AppLogger.log(.transcript, "Alibaba live transcription started model=\(settings.model) chunkSeconds=\(String(format: "%.1f", Self.chunkSeconds)) overlapSeconds=\(String(format: "%.1f", Self.overlapSeconds))")
      } catch {
        self.isRunning = false
        onUpdate(.failure(error.localizedDescription))
        AppLogger.log(.transcript, "Alibaba live transcription disabled: \(error.localizedDescription)")
      }
    }
  }

  func append(_ buffer: AVAudioPCMBuffer) {
    guard buffer.frameLength > 0, let copiedBuffer = Self.copyPCMBuffer(buffer) else { return }
    queue.async { [weak self] in
      self?.appendOnQueue(copiedBuffer)
    }
  }

  func stop() {
    queue.async { [weak self] in
      guard let self else { return }
      let wasRunning = self.isRunning
      self.isRunning = false
      self.resetBuffer()
      self.converter = nil
      self.converterInputFormat = nil
      self.client = nil
      self.generation = UUID()
      self.deliveredTranscriptContext = ""
      if wasRunning {
        self.onUpdate?(.status("Alibaba ASR stopped"))
        AppLogger.log(.transcript, "Alibaba live transcription stopped")
      }
    }
  }

  private func appendOnQueue(_ buffer: AVAudioPCMBuffer) {
    guard isRunning, buffer.frameLength > 0 else { return }
    guard let converted = convertToTargetFormat(buffer) else { return }
    appendPCMData(converted)
    let chunkFrameTarget = AVAudioFramePosition(Self.chunkSeconds * targetFormat.sampleRate)
    if pcmFrameCount >= chunkFrameTarget {
      submitCurrentChunkOnQueue()
    }
  }

  private func appendPCMData(_ buffer: AVAudioPCMBuffer) {
    guard buffer.format.commonFormat == .pcmFormatInt16,
          let channelData = buffer.int16ChannelData,
          buffer.frameLength > 0 else { return }
    if chunkStartedAt == nil {
      chunkStartedAt = Date()
    }
    let byteCount = Int(buffer.frameLength) * MemoryLayout<Int16>.size
    pcmData.append(Data(bytes: channelData[0], count: byteCount))
    pcmFrameCount += AVAudioFramePosition(buffer.frameLength)
  }

  private func submitCurrentChunkOnQueue() {
    guard isRunning, let client, !pcmData.isEmpty else {
      resetBuffer()
      return
    }
    guard pendingRequestCount < maxPendingRequests else {
      AppLogger.log(.transcript, "Alibaba live transcription chunk delayed reason=requestInFlight frames=\(pcmFrameCount)")
      return
    }
    let chunkFrameTarget = AVAudioFramePosition(Self.chunkSeconds * targetFormat.sampleRate)
    let overlapFrameCount = AVAudioFramePosition(Self.overlapSeconds * targetFormat.sampleRate)
    let submittedFrameCount = min(pcmFrameCount, chunkFrameTarget)
    let submittedByteCount = Int(submittedFrameCount) * MemoryLayout<Int16>.size
    guard submittedByteCount > 0, submittedByteCount <= pcmData.count else {
      resetBuffer()
      return
    }
    let generation = generation
    let startedAt = chunkStartedAt ?? Date()
    let duration = Double(submittedFrameCount) / targetFormat.sampleRate
    let endedAt = startedAt.addingTimeInterval(duration)
    let model = self.model
    let submittedPCM = Data(pcmData.prefix(submittedByteCount))

    // Speech gating: only spend an ASR request when the chunk actually contains
    // speech. Silent/background chunks are dropped here so the cloud never sees
    // them (and never returns an empty transcript that looks like a failure).
    let vad = Self.detectSpeech(int16PCM: submittedPCM, sampleRate: targetFormat.sampleRate)
    guard vad.isSpeech else {
      AppLogger.log(.transcript, "[ASR_VAD] chunk skipped reason=noSpeech durationSec=\(String(format: "%.2f", duration)) overallRMS=\(String(format: "%.6f", vad.overallRMS)) peakRMS=\(String(format: "%.6f", vad.peakRMS)) threshold=\(String(format: "%.6f", Self.speechRMSThreshold)) format=int16/\(Int(targetFormat.sampleRate))Hz/ch\(targetFormat.channelCount) sent=false")
      retainOverlapAfterSubmitting(
        submittedFrameCount: submittedFrameCount,
        overlapFrameCount: overlapFrameCount,
        originalStartedAt: startedAt
      )
      return
    }
    AppLogger.log(.transcript, "[ASR_VAD] chunk speech detected durationSec=\(String(format: "%.2f", duration)) overallRMS=\(String(format: "%.6f", vad.overallRMS)) peakRMS=\(String(format: "%.6f", vad.peakRMS)) threshold=\(String(format: "%.6f", Self.speechRMSThreshold)) format=int16/\(Int(targetFormat.sampleRate))Hz/ch\(targetFormat.channelCount) sent=true")

    let wavData = Self.wavData(
      pcmData: submittedPCM,
      sampleRate: UInt32(targetFormat.sampleRate),
      channels: UInt16(targetFormat.channelCount)
    )
    retainOverlapAfterSubmitting(
      submittedFrameCount: submittedFrameCount,
      overlapFrameCount: overlapFrameCount,
      originalStartedAt: startedAt
    )
    pendingRequestCount += 1
    onUpdate?(.status("Alibaba ASR transcribing \(String(format: "%.1f", duration))s"))
    Task { [weak self] in
      defer {
        self?.queue.async { [weak self] in
          self?.pendingRequestCount = max(0, (self?.pendingRequestCount ?? 1) - 1)
        }
      }
      do {
        let transcript = try await client.transcribe(wavData: wavData)
        self?.queue.async { [weak self] in
          guard let self, self.generation == generation else { return }
          let deduped = Self.removingOverlappingPrefix(
            previousTranscript: self.deliveredTranscriptContext,
            currentTranscript: transcript
          )
          guard !deduped.isEmpty else {
            AppLogger.log(.transcript, "Alibaba live transcription overlap removed entire chunk")
            return
          }
          self.deliveredTranscriptContext = Self.updatedTranscriptContext(
            previous: self.deliveredTranscriptContext,
            appended: deduped
          )
          let segment = AlibabaLiveTranscriptSegment(
            id: UUID(),
            text: deduped,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: duration,
            model: model
          )
          self.onUpdate?(.transcript(segment))
        }
      } catch {
        self?.queue.async { [weak self] in
          guard let self, self.generation == generation else { return }
          if Self.isNoSpeechError(error) {
            // An empty transcript is a normal "this window had no recognizable
            // speech" outcome, not an app failure. Don't surface it as an error.
            AppLogger.log(.transcript, "[ASR_VAD] empty transcript treated as noSpeech durationSec=\(String(format: "%.2f", duration)) sent=true reason=emptyTranscript")
            return
          }
          self.onUpdate?(.failure(error.localizedDescription))
          AppLogger.log(.transcript, "Alibaba live transcription failed: \(error.localizedDescription)")
        }
      }
    }
  }

  private func resetBuffer() {
    pcmData.removeAll(keepingCapacity: true)
    pcmFrameCount = 0
    chunkStartedAt = nil
  }

  private func retainOverlapAfterSubmitting(
    submittedFrameCount: AVAudioFramePosition,
    overlapFrameCount: AVAudioFramePosition,
    originalStartedAt: Date
  ) {
    let retainStartFrame = max(0, submittedFrameCount - overlapFrameCount)
    let retainStartByte = Int(retainStartFrame) * MemoryLayout<Int16>.size
    if retainStartByte < pcmData.count {
      pcmData = Data(pcmData.dropFirst(retainStartByte))
      pcmFrameCount = AVAudioFramePosition(pcmData.count / MemoryLayout<Int16>.size)
      chunkStartedAt = originalStartedAt.addingTimeInterval(Double(retainStartFrame) / targetFormat.sampleRate)
    } else {
      resetBuffer()
    }
  }

  static func removingOverlappingPrefix(
    previousTranscript: String,
    currentTranscript: String
  ) -> String {
    let currentWords = currentTranscript
      .split(whereSeparator: \.isWhitespace)
      .map(String.init)
    guard !currentWords.isEmpty else { return "" }

    let previousNormalized = normalizedWords(previousTranscript)
    let currentNormalized = currentWords.map(normalizedWord).filter { !$0.isEmpty }
    guard !previousNormalized.isEmpty, !currentNormalized.isEmpty else {
      return currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    let maxOverlap = min(24, previousNormalized.count, currentNormalized.count)
    for overlap in stride(from: maxOverlap, through: 2, by: -1) {
      let previousSuffix = Array(previousNormalized.suffix(overlap))
      let currentPrefix = Array(currentNormalized.prefix(overlap))
      if previousSuffix == currentPrefix {
        return currentWords.dropFirst(overlap)
          .joined(separator: " ")
          .trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }

    return currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func updatedTranscriptContext(previous: String, appended: String) -> String {
    let words = (previous + " " + appended)
      .split(whereSeparator: \.isWhitespace)
      .map(String.init)
    return words.suffix(80).joined(separator: " ")
  }

  private static func normalizedWords(_ text: String) -> [String] {
    text
      .split(whereSeparator: \.isWhitespace)
      .map(String.init)
      .map(normalizedWord)
      .filter { !$0.isEmpty }
  }

  private static func normalizedWord(_ word: String) -> String {
    word
      .lowercased()
      .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
  }

  private func convertToTargetFormat(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    if buffer.format == targetFormat {
      return buffer
    }
    if converter == nil || converterInputFormat != buffer.format {
      converter = AVAudioConverter(from: buffer.format, to: targetFormat)
      converterInputFormat = buffer.format
    }
    guard let converter else { return nil }
    let ratio = targetFormat.sampleRate / max(1, buffer.format.sampleRate)
    let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
    guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
    var didProvide = false
    var conversionError: NSError?
    let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
      if didProvide {
        inputStatus.pointee = .noDataNow
        return nil
      }
      didProvide = true
      inputStatus.pointee = .haveData
      return buffer
    }
    if let conversionError {
      AppLogger.log(.transcript, "Alibaba live transcription resample failed: \(conversionError.localizedDescription)")
      return nil
    }
    return status == .error || output.frameLength == 0 ? nil : output
  }

  private static func copyPCMBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
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

  struct VADResult {
    let isSpeech: Bool
    let overallRMS: Float
    let peakRMS: Float
  }

  // Energy-based speech detection over an int16 mono PCM chunk. Scans short
  // sub-windows and reports the peak window RMS so a brief utterance surrounded
  // by silence still classifies as speech. Mirrors the speaker VAD floor.
  static func detectSpeech(int16PCM data: Data, sampleRate: Double) -> VADResult {
    let sampleCount = data.count / MemoryLayout<Int16>.size
    guard sampleCount > 0 else { return VADResult(isSpeech: false, overallRMS: 0, peakRMS: 0) }

    return data.withUnsafeBytes { raw -> VADResult in
      let samples = raw.bindMemory(to: Int16.self)
      let windowSize = max(1, Int(vadWindowSeconds * sampleRate))
      var overallSumSquares: Double = 0
      var peakRMS: Float = 0
      var index = 0
      while index < sampleCount {
        let end = min(index + windowSize, sampleCount)
        var windowSumSquares: Double = 0
        for i in index..<end {
          let normalized = Double(samples[i]) / 32768.0
          let sq = normalized * normalized
          windowSumSquares += sq
          overallSumSquares += sq
        }
        let windowRMS = Float((windowSumSquares / Double(end - index)).squareRoot())
        peakRMS = max(peakRMS, windowRMS)
        index = end
      }
      let overallRMS = Float((overallSumSquares / Double(sampleCount)).squareRoot())
      return VADResult(isSpeech: peakRMS > speechRMSThreshold, overallRMS: overallRMS, peakRMS: peakRMS)
    }
  }

  // Empty-transcript outcomes are no-speech, not failures — whether they arrive as
  // a local empty parse or as the edge proxy's `empty_response` error envelope.
  static func isNoSpeechError(_ error: Error) -> Bool {
    if case AlibabaTranscriptionError.emptyResponse = error { return true }
    if let edge = error as? SupabaseEdgeFunctionError {
      switch edge {
      case .functionError(let kind, let message, _):
        let haystack = (kind + " " + message).lowercased()
        return haystack.contains("empty_response") || haystack.contains("empty transcript")
      case .badHTTPStatus(_, let body):
        return body.lowercased().contains("empty_response") || body.lowercased().contains("empty transcript")
      case .missingOutput:
        return true
      default:
        return false
      }
    }
    return error.localizedDescription.lowercased().contains("empty transcript")
  }

  private static func wavData(pcmData: Data, sampleRate: UInt32, channels: UInt16) -> Data {
    let bitsPerSample: UInt16 = 16
    let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
    let blockAlign = channels * (bitsPerSample / 8)
    var data = Data()
    data.append(contentsOf: "RIFF".utf8)
    appendUInt32(UInt32(36 + pcmData.count), to: &data)
    data.append(contentsOf: "WAVE".utf8)
    data.append(contentsOf: "fmt ".utf8)
    appendUInt32(16, to: &data)
    appendUInt16(1, to: &data)
    appendUInt16(channels, to: &data)
    appendUInt32(sampleRate, to: &data)
    appendUInt32(byteRate, to: &data)
    appendUInt16(blockAlign, to: &data)
    appendUInt16(bitsPerSample, to: &data)
    data.append(contentsOf: "data".utf8)
    appendUInt32(UInt32(pcmData.count), to: &data)
    data.append(pcmData)
    return data
  }

  private static func appendUInt16(_ value: UInt16, to data: inout Data) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
  }

  private static func appendUInt32(_ value: UInt32, to data: inout Data) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
  }
}

private extension String {
  var nilIfEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
