import AVFoundation
import CoreML
import FluidAudio
import Foundation

enum LiveASRProvider: String, Sendable {
  case dashScope
  case localParakeet

  init(rawSetting: String?) {
    let normalized = rawSetting?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    switch normalized {
    case "localparakeet", "iphoneparakeet", "parakeet", "local":
      self = .localParakeet
    default:
      self = .dashScope
    }
  }

  var displayName: String {
    switch self {
    case .dashScope: return "DashScope ASR"
    case .localParakeet: return "iPhone Parakeet ASR"
    }
  }

  var transcriptSource: String {
    switch self {
    case .dashScope: return "AlibabaLiveASR"
    case .localParakeet: return "iPhoneParakeetASR"
    }
  }
}

struct AlibabaTranscriptionSettings {
  private enum Keys {
    static let enabled = "alibaba.liveTranscription.enabled"
  }

  static let defaultBaseURL = "https://dashscope-us.aliyuncs.com/compatible-mode/v1"
  static let defaultModel = "qwen3-asr-flash-us"
  static let defaultParakeetModelName = "parakeet-tdt-ctc-110m"
  static let defaultProvider = LiveASRProvider.localParakeet
  static let defaultMaximumChunkAgeSeconds: TimeInterval = 1.5

  var enabled: Bool
  var provider: LiveASRProvider
  var apiKey: String
  var baseURL: String
  var model: String
  var parakeetModelName: String
  var maximumChunkAgeSeconds: TimeInterval

  static func load() -> AlibabaTranscriptionSettings {
    let defaults = UserDefaults.standard
    let env = DotEnvFile.load()
    let envEnabled = boolValue(ProcessInfo.processInfo.environment["DASHSCOPE_LIVE_TRANSCRIPTION_ENABLED"]
                               ?? env["DASHSCOPE_LIVE_TRANSCRIPTION_ENABLED"])
    let savedEnabled = defaults.object(forKey: Keys.enabled) as? Bool
    let providerRaw = ProcessInfo.processInfo.environment["LIVE_ASR_PROVIDER"]
      ?? ProcessInfo.processInfo.environment["MEMENTO_LIVE_ASR_PROVIDER"]
      ?? env["LIVE_ASR_PROVIDER"]
      ?? env["MEMENTO_LIVE_ASR_PROVIDER"]
    let provider = providerRaw == nil ? defaultProvider : LiveASRProvider(rawSetting: providerRaw)
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
    let parakeetModelName = ProcessInfo.processInfo.environment["PARAKEET_ASR_MODEL_NAME"]
      ?? env["PARAKEET_ASR_MODEL_NAME"]
      ?? defaultParakeetModelName
    let maximumChunkAgeMS = Double(
      ProcessInfo.processInfo.environment["PARAKEET_ASR_MAX_CHUNK_AGE_MS"]
        ?? env["PARAKEET_ASR_MAX_CHUNK_AGE_MS"]
        ?? ""
    )
    let maximumChunkAgeSeconds = min(
      max((maximumChunkAgeMS ?? defaultMaximumChunkAgeSeconds * 1_000) / 1_000, 0.75),
      5.0
    )
    return AlibabaTranscriptionSettings(
      enabled: savedEnabled ?? envEnabled ?? true,
      provider: provider,
      apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
      baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultBaseURL : baseURL,
      model: model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultModel : model,
      parakeetModelName: parakeetModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultParakeetModelName : parakeetModelName,
      maximumChunkAgeSeconds: maximumChunkAgeSeconds
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
  let provider: LiveASRProvider
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

enum LocalParakeetTranscriptionError: LocalizedError {
  case wavDecodeFailed
  case staleChunk(Double)

  var errorDescription: String? {
    switch self {
    case .wavDecodeFailed:
      return "Could not decode ASR WAV chunk for iPhone Parakeet ASR."
    case .staleChunk(let ageMS):
      return "Parakeet ASR chunk became stale before inference (\(Int(ageMS.rounded())) ms)."
    }
  }
}

private enum LocalParakeetModelSelection: Sendable {
  case tdtCtc110m
  case v2
  case v3

  init(rawValue: String) {
    switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "v2", "parakeet-v2", "parakeet-tdt-0.6b-v2":
      self = .v2
    case "v3", "parakeet-v3", "parakeet-tdt-0.6b-v3":
      self = .v3
    default:
      self = .tdtCtc110m
    }
  }

  var fluidAudioVersion: AsrModelVersion {
    switch self {
    case .tdtCtc110m: return .tdtCtc110m
    case .v2: return .v2
    case .v3: return .v3
    }
  }

  var displayName: String {
    switch self {
    case .tdtCtc110m: return "parakeet-tdt-ctc-110m"
    case .v2: return "parakeet-tdt-0.6b-v2"
    case .v3: return "parakeet-tdt-0.6b-v3"
    }
  }
}

actor LocalParakeetTranscriptionClient {
  private let selection: LocalParakeetModelSelection
  private var manager: AsrManager?
  private var managerLoadTask: Task<AsrManager, Error>?

  init(modelName: String) {
    let resolvedName = modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? AlibabaTranscriptionSettings.defaultParakeetModelName
      : modelName
    selection = LocalParakeetModelSelection(rawValue: resolvedName)
  }

  func prepare() async throws {
    _ = try await resolvedManager()
  }

  func transcribe(
    wavData: Data,
    capturedThroughAt: Date,
    maximumAgeSeconds: TimeInterval
  ) async throws -> String {
    let ageMS = max(0, Date().timeIntervalSince(capturedThroughAt) * 1_000)
    guard ageMS <= maximumAgeSeconds * 1_000 else {
      throw LocalParakeetTranscriptionError.staleChunk(ageMS)
    }
    let manager = try await resolvedManager()
    let samples = try Self.floatSamples(fromWAVData: wavData)
    var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
    let result = try await manager.transcribe(samples, decoderState: &decoderState)
    return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func resolvedManager() async throws -> AsrManager {
    if let manager { return manager }
    if let managerLoadTask { return try await managerLoadTask.value }

    let selection = selection
    let task = Task<AsrManager, Error> {
      let configuration = MLModelConfiguration()
      configuration.computeUnits = .cpuAndNeuralEngine
      let models = try await AsrModels.downloadAndLoad(
        configuration: configuration,
        version: selection.fluidAudioVersion
      )
      let manager = AsrManager(config: .default)
      try await manager.loadModels(models)
      return manager
    }
    managerLoadTask = task
    do {
      let loadedManager = try await task.value
      manager = loadedManager
      managerLoadTask = nil
      AppLogger.log(
        .parakeetASR,
        "status=ready success=true model=\(selection.displayName) runtime=FluidAudio computeUnits=cpuAndNeuralEngine"
      )
      return loadedManager
    } catch {
      managerLoadTask = nil
      throw error
    }
  }

  private static func floatSamples(fromWAVData data: Data) throws -> [Float] {
    guard let dataRange = data.range(of: Data("data".utf8)),
          dataRange.upperBound + 4 <= data.count else {
      throw LocalParakeetTranscriptionError.wavDecodeFailed
    }
    let sizeStart = dataRange.upperBound
    let dataSize = data[sizeStart..<(sizeStart + 4)].withUnsafeBytes {
      UInt32(littleEndian: $0.load(as: UInt32.self))
    }
    let pcmStart = sizeStart + 4
    let pcmEnd = min(data.count, pcmStart + Int(dataSize))
    guard pcmEnd > pcmStart else {
      throw LocalParakeetTranscriptionError.wavDecodeFailed
    }
    return data[pcmStart..<pcmEnd].withUnsafeBytes { raw in
      let samples = raw.bindMemory(to: Int16.self)
      return samples.map { Float($0) / 32768.0 }
    }
  }
}

struct LiveASRTranscriptionClient {
  let provider: LiveASRProvider
  let modelName: String
  private let cloud: AlibabaTranscriptionClient?
  private let localParakeet: LocalParakeetTranscriptionClient?

  init(settings: AlibabaTranscriptionSettings) throws {
    provider = settings.provider
    switch settings.provider {
    case .dashScope:
      cloud = try AlibabaTranscriptionClient(settings: settings)
      localParakeet = nil
      modelName = settings.model
    case .localParakeet:
      cloud = nil
      localParakeet = LocalParakeetTranscriptionClient(modelName: settings.parakeetModelName)
      modelName = settings.parakeetModelName
    }
  }

  func prepare() async throws {
    try await localParakeet?.prepare()
  }

  func transcribe(
    wavData: Data,
    capturedThroughAt: Date,
    maximumAgeSeconds: TimeInterval
  ) async throws -> String {
    switch provider {
    case .dashScope:
      guard let cloud else { throw AlibabaTranscriptionError.emptyResponse }
      return try await cloud.transcribe(wavData: wavData)
    case .localParakeet:
      guard let localParakeet else { throw AlibabaTranscriptionError.emptyResponse }
      return try await localParakeet.transcribe(
        wavData: wavData,
        capturedThroughAt: capturedThroughAt,
        maximumAgeSeconds: maximumAgeSeconds
      )
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
      guard let output = response.output else {
        throw AlibabaTranscriptionError.emptyResponse
      }
      let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard output.noSpeech != true, !text.isEmpty else {
        throw AlibabaTranscriptionError.emptyResponse
      }
      AppLogger.log(.transcript, "[ASR_PROXY] windowBytes=\(wavData.count) model=\(response.model ?? model) status=success")
      return text
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
    var noSpeech: Bool?
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
  struct ChunkingProfile: Equatable, Sendable {
    let chunkSeconds: Double
    let overlapSeconds: Double
  }

  static let cloudChunkingProfile = ChunkingProfile(chunkSeconds: 5.0, overlapSeconds: 2.0)
  static let localParakeetChunkingProfile = ChunkingProfile(chunkSeconds: 3.0, overlapSeconds: 1.0)
  // This is the absolute floor. The effective threshold rises above the measured
  // ambient noise floor so steady room noise does not become a cloud ASR call.
  static let minimumSpeechRMSThreshold: Float = 0.006
  static let defaultNoiseFloorRMS: Float = 0.0015
  static let noiseFloorMultiplier: Float = 2.2
  static let maximumAdaptiveSpeechRMSThreshold: Float = 0.025
  static let minimumOverallRMSThreshold: Float = 0.0008
  static let minimumSpeechWindowCount = 2
  static let minimumSpeechWindowFraction: Float = 0.08
  static let highConfidenceSpeechWindowFraction: Float = 0.12
  // Width of the sub-window scanned for a speech burst inside a chunk. A 5s chunk
  // with a brief utterance surrounded by silence still passes because the peak
  // window — not the diluted whole-chunk average — drives the decision.
  static let vadWindowSeconds = 0.20

  private struct Metrics {
    var startedAt = Date()
    var lastLoggedAt = Date()
    var chunksCaptured: UInt64 = 0
    var chunksSkippedNoSpeech: UInt64 = 0
    var inferenceCallsSent: UInt64 = 0
    var emptyTranscriptResponses: UInt64 = 0
    var chunksDroppedBackpressure: UInt64 = 0
    var chunksSkippedBackoff: UInt64 = 0
    var chunksDroppedStale: UInt64 = 0
    var maxQueueDepth: Int = 0
    var maxChunkAgeAtInferenceMS: Double = 0
  }

  private let queue = DispatchQueue(label: "com.cameraaccess.alibaba-live-transcription")
  private let targetFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16,
    sampleRate: 16_000,
    channels: 1,
    interleaved: false
  )!

  private var isRunning = false
  private var generation = UUID()
  private var client: LiveASRTranscriptionClient?
  private var provider = LiveASRProvider.dashScope
  private var model = AlibabaTranscriptionSettings.defaultModel
  private var onUpdate: (@Sendable (AlibabaLiveTranscriptionUpdate) -> Void)?
  private var converter: AVAudioConverter?
  private var converterInputFormat: AVAudioFormat?
  private var pcmData = Data()
  private var pcmFrameCount: AVAudioFramePosition = 0
  private var chunkStartedAt: Date?
  private var chunkCapturedThroughAt: Date?
  private var pendingRequestCount = 0
  private let maxPendingRequests = 1
  private var pendingInferenceTask: Task<Void, Never>?
  private var pendingInferenceRequestID: UUID?
  private var pendingInferenceCapturedThroughAt: Date?
  private var maximumChunkAgeSeconds = AlibabaTranscriptionSettings.defaultMaximumChunkAgeSeconds
  private var deliveredTranscriptContext = ""
  private var metrics = Metrics()
  private let metricsLogInterval: TimeInterval = 60
  private var adaptiveNoiseFloorRMS = defaultNoiseFloorRMS
  private var lastVADThresholdRMS = minimumSpeechRMSThreshold
  private var consecutiveEmptyTranscriptResponses = 0
  private var asrBackoffUntil: Date?

  static func chunkingProfile(for provider: LiveASRProvider) -> ChunkingProfile {
    switch provider {
    case .localParakeet:
      return localParakeetChunkingProfile
    case .dashScope:
      return cloudChunkingProfile
    }
  }

  private var chunkingProfile: ChunkingProfile {
    Self.chunkingProfile(for: provider)
  }

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
      self.pendingInferenceTask?.cancel()
      self.pendingInferenceTask = nil
      self.pendingInferenceRequestID = nil
      self.pendingInferenceCapturedThroughAt = nil
      self.pendingRequestCount = 0
      self.deliveredTranscriptContext = ""
      self.metrics = Metrics()
      self.adaptiveNoiseFloorRMS = Self.defaultNoiseFloorRMS
      self.lastVADThresholdRMS = Self.minimumSpeechRMSThreshold
      self.consecutiveEmptyTranscriptResponses = 0
      self.asrBackoffUntil = nil
      self.onUpdate = onUpdate
      self.generation = UUID()
      self.maximumChunkAgeSeconds = settings.maximumChunkAgeSeconds
      guard settings.enabled else {
        self.isRunning = false
        onUpdate(.status("Live ASR disabled"))
        return
      }
      do {
        let client = try LiveASRTranscriptionClient(settings: settings)
        self.client = client
        self.provider = settings.provider
        self.model = client.modelName
        self.isRunning = true
        onUpdate(.status("\(settings.provider.displayName) listening: \(client.modelName)"))
        let chunkingProfile = Self.chunkingProfile(for: settings.provider)
        AppLogger.log(.transcript, "[LIVE_ASR] started provider=\(settings.provider.rawValue) model=\(client.modelName) chunkSeconds=\(String(format: "%.1f", chunkingProfile.chunkSeconds)) overlapSeconds=\(String(format: "%.1f", chunkingProfile.overlapSeconds)) maximumChunkAgeMs=\(String(format: "%.0f", settings.maximumChunkAgeSeconds * 1_000))")
        if settings.provider == .localParakeet {
          AppLogger.log(
            .parakeetASR,
            "status=loading model=\(client.modelName) firstRunDownloadApproxMB=227"
          )
          onUpdate(.status("Downloading/loading iPhone Parakeet (~227 MB first run): \(client.modelName)"))
          let startGeneration = self.generation
          Task { [weak self] in
            do {
              try await client.prepare()
              self?.queue.async { [weak self] in
                guard let self, self.generation == startGeneration else { return }
                self.onUpdate?(.status("iPhone Parakeet loaded on Core ML: \(client.modelName)"))
              }
            } catch {
              self?.queue.async { [weak self] in
                guard let self, self.generation == startGeneration else { return }
                self.isRunning = false
                self.onUpdate?(.failure(error.localizedDescription))
                AppLogger.log(
                  .parakeetASR,
                  "status=loadFailed success=false model=\(client.modelName) error=\(error.localizedDescription)"
                )
              }
            }
          }
        }
      } catch {
        self.isRunning = false
        onUpdate(.failure(error.localizedDescription))
        AppLogger.log(.transcript, "[LIVE_ASR] disabled provider=\(settings.provider.rawValue) error=\(error.localizedDescription)")
      }
    }
  }

  func append(_ buffer: AVAudioPCMBuffer) {
    let capturedThroughAt = Date()
    guard buffer.frameLength > 0, let copiedBuffer = Self.copyPCMBuffer(buffer) else { return }
    queue.async { [weak self] in
      self?.appendOnQueue(copiedBuffer, capturedThroughAt: capturedThroughAt)
    }
  }

  func stop() {
    queue.async { [weak self] in
      guard let self else { return }
      let wasRunning = self.isRunning
      self.isRunning = false
      self.emitMetricsIfNeeded(force: true)
      self.resetBuffer()
      self.converter = nil
      self.converterInputFormat = nil
      self.client = nil
      self.pendingInferenceTask?.cancel()
      self.pendingInferenceTask = nil
      self.pendingInferenceRequestID = nil
      self.pendingInferenceCapturedThroughAt = nil
      self.pendingRequestCount = 0
      self.generation = UUID()
      self.deliveredTranscriptContext = ""
      if wasRunning {
        self.onUpdate?(.status("\(self.provider.displayName) stopped"))
        AppLogger.log(.transcript, "[LIVE_ASR] stopped provider=\(self.provider.rawValue)")
      }
    }
  }

  private func appendOnQueue(_ buffer: AVAudioPCMBuffer, capturedThroughAt: Date) {
    guard isRunning, buffer.frameLength > 0 else { return }
    guard let converted = convertToTargetFormat(buffer) else { return }
    appendPCMData(converted, capturedThroughAt: capturedThroughAt)
    let chunkFrameTarget = AVAudioFramePosition(chunkingProfile.chunkSeconds * targetFormat.sampleRate)
    if pcmFrameCount >= chunkFrameTarget {
      submitCurrentChunkOnQueue()
    }
  }

  private func appendPCMData(_ buffer: AVAudioPCMBuffer, capturedThroughAt: Date) {
    guard buffer.format.commonFormat == .pcmFormatInt16,
          let channelData = buffer.int16ChannelData,
          buffer.frameLength > 0 else { return }
    if chunkStartedAt == nil {
      let bufferDuration = Double(buffer.frameLength) / targetFormat.sampleRate
      chunkStartedAt = capturedThroughAt.addingTimeInterval(-bufferDuration)
    }
    chunkCapturedThroughAt = capturedThroughAt
    let byteCount = Int(buffer.frameLength) * MemoryLayout<Int16>.size
    pcmData.append(Data(bytes: channelData[0], count: byteCount))
    pcmFrameCount += AVAudioFramePosition(buffer.frameLength)
  }

  private func submitCurrentChunkOnQueue() {
    guard isRunning, let client, !pcmData.isEmpty else {
      resetBuffer()
      return
    }
    let chunkFrameTarget = AVAudioFramePosition(chunkingProfile.chunkSeconds * targetFormat.sampleRate)
    let overlapFrameCount = AVAudioFramePosition(chunkingProfile.overlapSeconds * targetFormat.sampleRate)
    let submittedFrameCount = min(pcmFrameCount, chunkFrameTarget)
    let submittedByteCount = Int(submittedFrameCount) * MemoryLayout<Int16>.size
    guard submittedByteCount > 0, submittedByteCount <= pcmData.count else {
      resetBuffer()
      return
    }
    metrics.chunksCaptured += 1
    let generation = generation
    let duration = Double(submittedFrameCount) / targetFormat.sampleRate
    let endedAt = chunkCapturedThroughAt ?? Date()
    let startedAt = endedAt.addingTimeInterval(-duration)
    let model = self.model
    let provider = self.provider
    let submittedPCM = Data(pcmData.prefix(submittedByteCount))

    guard provider != .localParakeet || !Self.shouldDropStaleChunk(
      capturedThrough: endedAt,
      now: Date(),
      maximumAgeSeconds: maximumChunkAgeSeconds
    ) else {
      recordStaleChunkDrop(stage: "queueAdmission", capturedThroughAt: endedAt)
      retainOverlapAfterSubmitting(
        submittedFrameCount: submittedFrameCount,
        overlapFrameCount: overlapFrameCount,
        originalStartedAt: startedAt
      )
      return
    }

    if pendingRequestCount >= maxPendingRequests {
      let pendingIsStale: Bool
      if provider == .localParakeet, let pendingInferenceCapturedThroughAt {
        pendingIsStale = Self.shouldDropStaleChunk(
          capturedThrough: pendingInferenceCapturedThroughAt,
          now: Date(),
          maximumAgeSeconds: maximumChunkAgeSeconds
        )
      } else {
        pendingIsStale = false
      }
      if pendingIsStale {
        let staleCapturedThroughAt = pendingInferenceCapturedThroughAt ?? endedAt
        pendingInferenceTask?.cancel()
        pendingInferenceTask = nil
        pendingInferenceRequestID = nil
        pendingInferenceCapturedThroughAt = nil
        pendingRequestCount = 0
        recordStaleChunkDrop(stage: "backpressureReplacement", capturedThroughAt: staleCapturedThroughAt)
      } else {
        metrics.chunksDroppedBackpressure += 1
        metrics.maxQueueDepth = max(metrics.maxQueueDepth, pendingRequestCount + 1)
        emitMetricsIfNeeded(force: false)
        retainOverlapAfterSubmitting(
          submittedFrameCount: submittedFrameCount,
          overlapFrameCount: overlapFrameCount,
          originalStartedAt: startedAt
        )
        return
      }
    }

    // Speech gating: only spend an ASR request when the chunk actually contains
    // speech. Silent/background chunks are dropped here so the cloud never sees
    // them (and never returns an empty transcript that looks like a failure).
    let vad = Self.detectSpeech(
      int16PCM: submittedPCM,
      sampleRate: targetFormat.sampleRate,
      noiseFloorRMS: adaptiveNoiseFloorRMS
    )
    lastVADThresholdRMS = vad.thresholdRMS
    guard vad.isSpeech else {
      metrics.chunksSkippedNoSpeech += 1
      updateAdaptiveNoiseFloor(estimatedRMS: vad.estimatedNoiseFloorRMS, weight: 0.20)
      if provider == .localParakeet {
        AppLogger.log(
          .parakeetASR,
          "status=inferenceSkipped reason=vadNoSpeech peakRMS=\(String(format: "%.5f", vad.peakRMS)) noiseRMS=\(String(format: "%.5f", vad.estimatedNoiseFloorRMS)) thresholdRMS=\(String(format: "%.5f", vad.thresholdRMS)) speechWindows=\(vad.speechWindowCount)/\(vad.windowCount)"
        )
      }
      emitMetricsIfNeeded(force: false)
      retainOverlapAfterSubmitting(
        submittedFrameCount: submittedFrameCount,
        overlapFrameCount: overlapFrameCount,
        originalStartedAt: startedAt
      )
      return
    }

    if let asrBackoffUntil,
       asrBackoffUntil > Date(),
       !vad.isHighConfidenceSpeech {
      metrics.chunksSkippedBackoff += 1
      if provider == .localParakeet {
        AppLogger.log(
          .parakeetASR,
          "status=inferenceSkipped reason=emptyBackoff remainingSeconds=\(String(format: "%.1f", asrBackoffUntil.timeIntervalSinceNow)) peakRMS=\(String(format: "%.5f", vad.peakRMS)) thresholdRMS=\(String(format: "%.5f", vad.thresholdRMS))"
        )
      }
      emitMetricsIfNeeded(force: false)
      retainOverlapAfterSubmitting(
        submittedFrameCount: submittedFrameCount,
        overlapFrameCount: overlapFrameCount,
        originalStartedAt: startedAt
      )
      return
    }

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
    let requestID = UUID()
    pendingRequestCount += 1
    pendingInferenceRequestID = requestID
    pendingInferenceCapturedThroughAt = endedAt
    metrics.maxQueueDepth = max(metrics.maxQueueDepth, pendingRequestCount)
    metrics.inferenceCallsSent += 1
    emitMetricsIfNeeded(force: false)
    onUpdate?(.status("\(provider.displayName) transcribing \(String(format: "%.1f", duration))s"))
    let task = Task(priority: .userInitiated) { [weak self] in
      let inferenceStartedAt = Date()
      let chunkAgeAtInferenceMS = Self.chunkAgeMilliseconds(
        capturedThrough: endedAt,
        now: inferenceStartedAt
      )
      guard !Task.isCancelled,
            provider != .localParakeet || !Self.shouldDropStaleChunk(
              capturedThrough: endedAt,
              now: inferenceStartedAt,
              maximumAgeSeconds: self?.maximumChunkAgeSeconds
                ?? AlibabaTranscriptionSettings.defaultMaximumChunkAgeSeconds
            ) else {
        self?.queue.async { [weak self] in
          guard let self, self.pendingInferenceRequestID == requestID else { return }
          self.recordStaleChunkDrop(stage: "inferenceStart", capturedThroughAt: endedAt)
          self.finishPendingInference(requestID: requestID)
        }
        return
      }
      self?.queue.async { [weak self] in
        guard let self, self.pendingInferenceRequestID == requestID else { return }
        self.metrics.maxChunkAgeAtInferenceMS = max(
          self.metrics.maxChunkAgeAtInferenceMS,
          chunkAgeAtInferenceMS
        )
      }
      if provider == .localParakeet {
        AppLogger.log(
          .parakeetASR,
          "status=inferenceStarted model=\(model) audioSeconds=\(String(format: "%.2f", duration)) wavBytes=\(wavData.count) asrChunkAgeAtInferenceMs=\(String(format: "%.1f", chunkAgeAtInferenceMS))"
        )
      }
      defer {
        self?.queue.async { [weak self] in
          self?.finishPendingInference(requestID: requestID)
        }
      }
      do {
        let transcript = try await client.transcribe(
          wavData: wavData,
          capturedThroughAt: endedAt,
          maximumAgeSeconds: self?.maximumChunkAgeSeconds
            ?? AlibabaTranscriptionSettings.defaultMaximumChunkAgeSeconds
        )
        let inferenceLatencyMS = Date().timeIntervalSince(inferenceStartedAt) * 1_000
        if provider == .localParakeet {
          AppLogger.log(
            .parakeetASR,
            "status=inferenceSucceeded success=true model=\(model) latencyMs=\(String(format: "%.1f", inferenceLatencyMS)) rawTranscript=\(transcript)"
          )
        }
        self?.queue.async { [weak self] in
          guard let self,
                self.generation == generation,
                self.pendingInferenceRequestID == requestID else { return }
          let completedAt = Date()
          guard provider != .localParakeet || !Self.shouldDropStaleChunk(
            capturedThrough: endedAt,
            now: completedAt,
            maximumAgeSeconds: self.maximumChunkAgeSeconds
          ) else {
            self.recordStaleChunkDrop(stage: "delivery", capturedThroughAt: endedAt)
            return
          }
          let rawTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !rawTranscript.isEmpty else {
            self.recordEmptyTranscriptOutcome(
              reason: "rawEmpty",
              vad: vad,
              provider: provider,
              model: model,
              latencyMS: inferenceLatencyMS
            )
            return
          }
          let previousContext = self.deliveredTranscriptContext
          let merge = Self.mergeOverlappingTranscript(
            previousTranscript: self.deliveredTranscriptContext,
            currentTranscript: rawTranscript
          )
          if provider == .localParakeet {
            AppLogger.log(
              .parakeetASR,
              "status=dedupDecision model=\(model) decision=\(merge.decision.logValue) overlapWords=\(merge.overlapWordCount) previousTranscript=\(previousContext) rawTranscript=\(rawTranscript) deliveredTranscript=\(merge.deliveredText.isEmpty ? "<empty>" : merge.deliveredText)"
            )
          }
          guard !merge.deliveredText.isEmpty else {
            if provider == .localParakeet {
              AppLogger.log(
                .parakeetASR,
                "status=deduplicated success=true model=\(model) deliveredTranscript=<empty> reason=overlapRemovedEntireChunk"
              )
            }
            self.recordEmptyTranscriptOutcome(
              reason: "fullyDeduplicated",
              vad: vad,
              provider: provider,
              model: model,
              latencyMS: inferenceLatencyMS
            )
            AppLogger.log(.transcript, "[LIVE_ASR] overlap removed entire chunk provider=\(provider.rawValue)")
            return
          }
          self.consecutiveEmptyTranscriptResponses = 0
          self.asrBackoffUntil = nil
          self.deliveredTranscriptContext = merge.updatedContext
          let segment = AlibabaLiveTranscriptSegment(
            id: UUID(),
            text: merge.deliveredText,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: duration,
            model: model,
            provider: provider
          )
          if provider == .localParakeet {
            let captureToDeliveryMS = max(0, completedAt.timeIntervalSince(endedAt) * 1_000)
            AppLogger.log(
              .parakeetASR,
              "status=transcriptDelivered success=true model=\(model) inferenceLatencyMs=\(String(format: "%.1f", inferenceLatencyMS)) captureToDeliveryMs=\(String(format: "%.1f", captureToDeliveryMS)) asrChunkAgeAtDeliveryMs=\(String(format: "%.1f", captureToDeliveryMS)) deliveredTranscript=\(merge.deliveredText)"
            )
          }
          self.onUpdate?(.transcript(segment))
        }
      } catch {
        let inferenceLatencyMS = Date().timeIntervalSince(inferenceStartedAt) * 1_000
        self?.queue.async { [weak self] in
          guard let self,
                self.generation == generation,
                self.pendingInferenceRequestID == requestID else { return }
          if Self.isStaleChunkError(error) {
            self.recordStaleChunkDrop(stage: "providerAdmission", capturedThroughAt: endedAt)
            return
          }
          if Self.isNoSpeechError(error) {
            self.recordEmptyTranscriptOutcome(
              reason: "providerEmpty",
              vad: vad,
              provider: provider,
              model: model,
              latencyMS: inferenceLatencyMS
            )
            return
          }
          if provider == .localParakeet {
            AppLogger.log(
              .parakeetASR,
              "status=inferenceFailed success=false model=\(model) latencyMs=\(String(format: "%.1f", inferenceLatencyMS)) error=\(error.localizedDescription)"
            )
          }
          self.onUpdate?(.failure(error.localizedDescription))
          AppLogger.log(.transcript, "[LIVE_ASR] failed provider=\(provider.rawValue) error=\(error.localizedDescription)")
        }
      }
    }
    pendingInferenceTask = task
  }

  private func resetBuffer() {
    pcmData.removeAll(keepingCapacity: true)
    pcmFrameCount = 0
    chunkStartedAt = nil
    chunkCapturedThroughAt = nil
  }

  private func finishPendingInference(requestID: UUID) {
    guard pendingInferenceRequestID == requestID else { return }
    pendingRequestCount = max(0, pendingRequestCount - 1)
    pendingInferenceTask = nil
    pendingInferenceRequestID = nil
    pendingInferenceCapturedThroughAt = nil
  }

  private func recordStaleChunkDrop(stage: String, capturedThroughAt: Date) {
    let ageMS = Self.chunkAgeMilliseconds(capturedThrough: capturedThroughAt, now: Date())
    metrics.chunksDroppedStale += 1
    AppLogger.log(
      provider == .localParakeet ? .parakeetASR : .streamPerf,
      "status=chunkDropped reason=stale stage=\(stage) asrChunkAgeMs=\(String(format: "%.1f", ageMS)) maximumChunkAgeMs=\(String(format: "%.1f", maximumChunkAgeSeconds * 1_000)) asrDroppedStaleChunks=\(metrics.chunksDroppedStale) asrMaxQueueDepth=\(metrics.maxQueueDepth)"
    )
    emitMetricsIfNeeded(force: false)
  }

  static func chunkAgeMilliseconds(capturedThrough: Date, now: Date) -> Double {
    max(0, now.timeIntervalSince(capturedThrough) * 1_000)
  }

  static func shouldDropStaleChunk(
    capturedThrough: Date,
    now: Date,
    maximumAgeSeconds: TimeInterval
  ) -> Bool {
    now.timeIntervalSince(capturedThrough) > maximumAgeSeconds
  }

  private func recordEmptyTranscriptOutcome(
    reason: String,
    vad: VADResult,
    provider: LiveASRProvider,
    model: String,
    latencyMS: Double
  ) {
    metrics.emptyTranscriptResponses += 1
    consecutiveEmptyTranscriptResponses += 1
    updateAdaptiveNoiseFloor(estimatedRMS: vad.estimatedNoiseFloorRMS, weight: 0.45)
    let backoffSeconds = Self.emptyTranscriptBackoffSeconds(
      consecutiveEmptyResponses: consecutiveEmptyTranscriptResponses
    )
    if backoffSeconds > 0 {
      asrBackoffUntil = Date().addingTimeInterval(backoffSeconds)
    }
    if provider == .localParakeet {
      AppLogger.log(
        .parakeetASR,
        "status=inferenceEmpty success=true model=\(model) reason=\(reason) latencyMs=\(String(format: "%.1f", latencyMS)) rawTranscript=<empty> consecutiveEmpty=\(consecutiveEmptyTranscriptResponses) backoffSeconds=\(String(format: "%.0f", backoffSeconds))"
      )
    }
    emitMetricsIfNeeded(force: false)
  }

  private func emitMetricsIfNeeded(force: Bool) {
    let now = Date()
    guard force || now.timeIntervalSince(metrics.lastLoggedAt) >= metricsLogInterval else { return }
    metrics.lastLoggedAt = now
    AppLogger.log(
      .streamPerf,
      String(
        format: "[ASR_PERF] windowSec=%.0f chunksCaptured=%llu skippedNoSpeech=%llu skippedBackoff=%llu inferenceCallsSent=%llu emptyTranscriptResponses=%llu droppedBackpressure=%llu asrDroppedStaleChunks=%llu pending=%d asrMaxQueueDepth=%d asrMaxChunkAgeAtInferenceMs=%.1f adaptiveNoiseRMS=%.5f vadThresholdRMS=%.5f consecutiveEmpty=%d backoffRemainingSec=%.0f",
        now.timeIntervalSince(metrics.startedAt),
        metrics.chunksCaptured,
        metrics.chunksSkippedNoSpeech,
        metrics.chunksSkippedBackoff,
        metrics.inferenceCallsSent,
        metrics.emptyTranscriptResponses,
        metrics.chunksDroppedBackpressure,
        metrics.chunksDroppedStale,
        pendingRequestCount,
        metrics.maxQueueDepth,
        metrics.maxChunkAgeAtInferenceMS,
        adaptiveNoiseFloorRMS,
        lastVADThresholdRMS,
        consecutiveEmptyTranscriptResponses,
        max(0, asrBackoffUntil?.timeIntervalSince(now) ?? 0)
      )
    )
  }

  private func updateAdaptiveNoiseFloor(estimatedRMS: Float, weight: Float) {
    guard estimatedRMS.isFinite, estimatedRMS > 0 else { return }
    let clampedEstimate = min(max(estimatedRMS, 0.0005), 0.02)
    let clampedWeight = min(max(weight, 0), 1)
    adaptiveNoiseFloorRMS = min(
      max(
        adaptiveNoiseFloorRMS * (1 - clampedWeight) + clampedEstimate * clampedWeight,
        0.0005
      ),
      0.02
    )
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
    mergeOverlappingTranscript(
      previousTranscript: previousTranscript,
      currentTranscript: currentTranscript
    ).deliveredText
  }

  enum TranscriptMergeDecision: Equatable, Sendable {
    case empty
    case append
    case appendAfterOverlap
    case replacePartial
    case duplicate

    var logValue: String {
      switch self {
      case .empty: return "empty"
      case .append: return "append"
      case .appendAfterOverlap: return "appendAfterOverlap"
      case .replacePartial: return "replacePartial"
      case .duplicate: return "duplicate"
      }
    }
  }

  struct TranscriptMergeResult: Equatable, Sendable {
    let deliveredText: String
    let updatedContext: String
    let decision: TranscriptMergeDecision
    let overlapWordCount: Int
  }

  static func mergeOverlappingTranscript(
    previousTranscript: String,
    currentTranscript: String
  ) -> TranscriptMergeResult {
    let currentWords = currentTranscript
      .split(whereSeparator: \.isWhitespace)
      .map(String.init)
    guard !currentWords.isEmpty else {
      return TranscriptMergeResult(
        deliveredText: "",
        updatedContext: cappedTranscriptContext(previousTranscript),
        decision: .empty,
        overlapWordCount: 0
      )
    }

    let previousWords = previousTranscript.split(whereSeparator: \.isWhitespace).map(String.init)
    let previousNormalized = normalizedWords(previousTranscript)
    let currentNormalized = currentWords.map(normalizedWord).filter { !$0.isEmpty }
    guard !previousNormalized.isEmpty, !currentNormalized.isEmpty else {
      let delivered = currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
      return TranscriptMergeResult(
        deliveredText: delivered,
        updatedContext: cappedTranscriptContext(previousTranscript + " " + delivered),
        decision: .append,
        overlapWordCount: 0
      )
    }

    let maxOverlap = min(24, previousNormalized.count, currentNormalized.count)
    for overlap in stride(from: maxOverlap, through: 2, by: -1) {
      let previousSuffix = Array(previousNormalized.suffix(overlap))
      let currentPrefix = Array(currentNormalized.prefix(overlap))
      if previousSuffix == currentPrefix {
        if overlap == currentNormalized.count {
          return TranscriptMergeResult(
            deliveredText: "",
            updatedContext: cappedTranscriptContext(previousTranscript),
            decision: .duplicate,
            overlapWordCount: overlap
          )
        }
        let trailingUtteranceCount = trailingUtteranceWordCount(previousTranscript)
        if trailingUtteranceCount >= 2, overlap >= trailingUtteranceCount {
          let replacementContext = (Array(previousWords.dropLast(min(overlap, previousWords.count))) + currentWords)
            .joined(separator: " ")
          return TranscriptMergeResult(
            deliveredText: currentWords.joined(separator: " "),
            updatedContext: cappedTranscriptContext(replacementContext),
            decision: .replacePartial,
            overlapWordCount: overlap
          )
        }
        let delivered = currentWords.dropFirst(overlap)
          .joined(separator: " ")
          .trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptMergeResult(
          deliveredText: delivered,
          updatedContext: cappedTranscriptContext(previousTranscript + " " + delivered),
          decision: .appendAfterOverlap,
          overlapWordCount: overlap
        )
      }
    }

    let delivered = currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    return TranscriptMergeResult(
      deliveredText: delivered,
      updatedContext: cappedTranscriptContext(previousTranscript + " " + delivered),
      decision: .append,
      overlapWordCount: 0
    )
  }

  private static func cappedTranscriptContext(_ text: String) -> String {
    let words = text
      .split(whereSeparator: \.isWhitespace)
      .map(String.init)
    return words.suffix(80).joined(separator: " ")
  }

  private static func trailingUtteranceWordCount(_ text: String) -> Int {
    text.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
      .reversed()
      .map { normalizedWords($0).count }
      .first(where: { $0 > 0 }) ?? normalizedWords(text).count
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
      AppLogger.log(.transcript, "[LIVE_ASR] resample failed: \(conversionError.localizedDescription)")
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

  struct VADResult: Sendable {
    let isSpeech: Bool
    let isHighConfidenceSpeech: Bool
    let overallRMS: Float
    let peakRMS: Float
    let estimatedNoiseFloorRMS: Float
    let thresholdRMS: Float
    let speechWindowCount: Int
    let windowCount: Int
  }

  // Energy-based speech detection over an int16 mono PCM chunk. Scans short
  // sub-windows and reports the peak window RMS so a brief utterance surrounded
  // by silence still classifies as speech. Requires more than a single noisy
  // spike so mostly-silent DAT windows do not produce empty ASR responses.
  static func detectSpeech(
    int16PCM data: Data,
    sampleRate: Double,
    noiseFloorRMS: Float = defaultNoiseFloorRMS
  ) -> VADResult {
    let sampleCount = data.count / MemoryLayout<Int16>.size
    guard sampleCount > 0 else {
      return VADResult(
        isSpeech: false,
        isHighConfidenceSpeech: false,
        overallRMS: 0,
        peakRMS: 0,
        estimatedNoiseFloorRMS: 0,
        thresholdRMS: minimumSpeechRMSThreshold,
        speechWindowCount: 0,
        windowCount: 0
      )
    }

    return data.withUnsafeBytes { raw -> VADResult in
      let samples = raw.bindMemory(to: Int16.self)
      let windowSize = max(1, Int(vadWindowSeconds * sampleRate))
      var overallSumSquares: Double = 0
      var peakRMS: Float = 0
      var windowCount = 0
      var windowRMSValues: [Float] = []
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
        windowCount += 1
        windowRMSValues.append(windowRMS)
        index = end
      }
      let sortedRMS = windowRMSValues.sorted()
      let noiseIndex = min(sortedRMS.count - 1, Int(Double(max(0, sortedRMS.count - 1)) * 0.20))
      let estimatedNoiseFloorRMS = sortedRMS.isEmpty ? 0 : sortedRMS[noiseIndex]
      let effectiveNoiseFloor = max(
        0.0005,
        min(max(noiseFloorRMS, estimatedNoiseFloorRMS), 0.02)
      )
      let thresholdRMS = min(
        maximumAdaptiveSpeechRMSThreshold,
        max(minimumSpeechRMSThreshold, effectiveNoiseFloor * noiseFloorMultiplier)
      )
      let speechWindowCount = windowRMSValues.reduce(into: 0) { count, value in
        if value >= thresholdRMS { count += 1 }
      }
      let overallRMS = Float((overallSumSquares / Double(sampleCount)).squareRoot())
      let speechWindowFraction = windowCount > 0
        ? Float(speechWindowCount) / Float(windowCount)
        : 0
      let hasSustainedSpeech = speechWindowCount >= minimumSpeechWindowCount
        || speechWindowFraction >= minimumSpeechWindowFraction
      let isSpeech = peakRMS >= thresholdRMS
        && overallRMS >= minimumOverallRMSThreshold
        && hasSustainedSpeech
      let isHighConfidenceSpeech = isSpeech
        && peakRMS >= max(0.012, thresholdRMS * 1.8)
        && speechWindowFraction >= highConfidenceSpeechWindowFraction
      return VADResult(
        isSpeech: isSpeech,
        isHighConfidenceSpeech: isHighConfidenceSpeech,
        overallRMS: overallRMS,
        peakRMS: peakRMS,
        estimatedNoiseFloorRMS: estimatedNoiseFloorRMS,
        thresholdRMS: thresholdRMS,
        speechWindowCount: speechWindowCount,
        windowCount: windowCount
      )
    }
  }

  static func emptyTranscriptBackoffSeconds(consecutiveEmptyResponses: Int) -> TimeInterval {
    guard consecutiveEmptyResponses >= 2 else { return 0 }
    let exponent = min(3, consecutiveEmptyResponses - 2)
    return min(30, 6 * pow(2, Double(exponent)))
  }

  static func isStaleChunkError(_ error: Error) -> Bool {
    if case LocalParakeetTranscriptionError.staleChunk = error { return true }
    return false
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
