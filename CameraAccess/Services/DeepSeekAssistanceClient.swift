import Foundation

struct DeepSeekSettings {
  private enum Keys {
    static let apiKey = "deepSeek.apiKey"
    static let model = "deepSeek.model"
  }

  static let defaultModel = "deepseek-v4-flash"
  static let defaultBaseURL = "https://api.deepseek.com/v1"

  var apiKey: String
  var model: String

  static func load() -> DeepSeekSettings {
    let defaults = UserDefaults.standard
    let env = DotEnvFile.load()
    let environmentKey = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"]
      ?? env["DEEPSEEK_API_KEY"]
      ?? ""
    let savedKey = defaults.string(forKey: Keys.apiKey) ?? ""
    let environmentModel = ProcessInfo.processInfo.environment["DEEPSEEK_MODEL"]
      ?? env["DEEPSEEK_MODEL"]
      ?? defaultModel
    return DeepSeekSettings(
      apiKey: environmentKey.isEmpty ? savedKey : environmentKey,
      model: environmentModel.isEmpty ? defaultModel : environmentModel
    )
  }

  func save() {
    let defaults = UserDefaults.standard
    defaults.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.apiKey)
    defaults.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.model)
  }
}

struct AlibabaQuestionAnswerSettings {
  static let defaultCompatibleBaseURL = "https://dashscope-us.aliyuncs.com/compatible-mode/v1"
  static let defaultGenerationBaseURL = "https://dashscope-us.aliyuncs.com/api/v1"
  static let defaultModel = "qwen3.5-flash"
  static let defaultSearchStrategy = "turbo"

  var apiKey: String
  var compatibleBaseURL: String
  var generationBaseURL: String
  var model: String
  var searchStrategy: String

  static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> AlibabaQuestionAnswerSettings {
    let env = DotEnvFile.load()
      .merging(ProcessInfo.processInfo.environment) { _, new in new }
      .merging(environment) { _, new in new }
    return AlibabaQuestionAnswerSettings(
      apiKey: env["DASHSCOPE_API_KEY"] ?? env["ALIBABA_DASHSCOPE_API_KEY"] ?? "",
      compatibleBaseURL: env["DASHSCOPE_QA_BASE_URL"] ?? env["DASHSCOPE_BASE_URL"] ?? defaultCompatibleBaseURL,
      generationBaseURL: env["DASHSCOPE_GENERATION_BASE_URL"] ?? defaultGenerationBaseURL,
      model: env["DASHSCOPE_QA_MODEL"] ?? env["QWEN_QA_MODEL"] ?? defaultModel,
      searchStrategy: env["DASHSCOPE_SEARCH_STRATEGY"] ?? defaultSearchStrategy
    )
  }
}

struct AlibabaQuestionAnswer: Equatable {
  struct Source: Equatable {
    let title: String
    let url: String
  }

  let text: String
  let usedWebSearch: Bool
  let sources: [Source]
}

struct AlibabaMemoryAnswerRequest: Equatable {
  let fullQuestion: String
  let triggerReason: String
  let memoryEvidence: String
}

enum DotEnvFile {
  static func load() -> [String: String] {
    var values: [String: String] = [:]
    for url in candidateURLs() {
      guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
      for line in text.split(whereSeparator: \.isNewline) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { continue }
        let key = String(trimmed[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines)
        var value = String(trimmed[trimmed.index(after: equals)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
          value.removeFirst()
          value.removeLast()
        }
        values[key] = value
      }
      if !values.isEmpty { return values }
    }
    return values
  }

  private static func candidateURLs() -> [URL] {
    let fm = FileManager.default
    let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
    return [
      cwd.appendingPathComponent(".env.local"),
      cwd.appendingPathComponent(".env")
    ]
  }
}

enum AlibabaQuestionAnswerClientError: LocalizedError {
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
      return "Alibaba DashScope returned an empty answer."
    }
  }
}

struct AlibabaQuestionAnswerClient {
  private let settings: AlibabaQuestionAnswerSettings
  private let session: URLSession
  private let useProxy: Bool

  init(settings: AlibabaQuestionAnswerSettings, session: URLSession = .shared) throws {
    let canUseProxy = SupabaseEdgeFunctionClient.isConfigured()
    guard canUseProxy || !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AlibabaQuestionAnswerClientError.missingAPIKey
    }
    guard canUseProxy || (
      URL(string: settings.compatibleBaseURL)?.host != nil
        && URL(string: settings.generationBaseURL)?.host != nil
    ) else {
      throw AlibabaQuestionAnswerClientError.invalidBaseURL
    }
    self.settings = settings
    self.session = session
    self.useProxy = canUseProxy
  }

  func answerStableQuestion(_ question: String) async throws -> AlibabaQuestionAnswer {
    if useProxy {
      return try await proxyAnswer(
        kind: "stable",
        systemPrompt: Self.stableSystemPrompt,
        userPrompt: question,
        maxTokens: 60,
        enableSearch: false,
        timeoutSeconds: 12
      )
    }

    var url = try compatibleURL()
    url.appendPathComponent("chat")
    url.appendPathComponent("completions")
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 12
    request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(ChatCompletionRequest(
      model: settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? AlibabaQuestionAnswerSettings.defaultModel
        : settings.model,
      messages: [
        Message(role: "system", content: Self.stableSystemPrompt),
        Message(role: "user", content: question)
      ],
      temperature: 0.1,
      maxTokens: 60,
      enableThinking: false
    ))
    let (data, response) = try await session.data(for: request)
    try validate(response: response, data: data)
    let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
    let text = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !text.isEmpty else { throw AlibabaQuestionAnswerClientError.emptyResponse }
    return AlibabaQuestionAnswer(text: text, usedWebSearch: false, sources: [])
  }

  func answerCurrentQuestion(_ question: String) async throws -> AlibabaQuestionAnswer {
    if useProxy {
      return try await proxyAnswer(
        kind: "current",
        systemPrompt: Self.currentSystemPrompt,
        userPrompt: question,
        maxTokens: 80,
        enableSearch: true,
        timeoutSeconds: 25
      )
    }

    var url = try compatibleURL()
    url.appendPathComponent("chat")
    url.appendPathComponent("completions")
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 25
    request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(ChatCompletionRequest(
      model: settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? AlibabaQuestionAnswerSettings.defaultModel
        : settings.model,
      messages: [
        Message(role: "system", content: Self.currentSystemPrompt),
        Message(role: "user", content: question)
      ],
      temperature: 0.1,
      maxTokens: 80,
      enableSearch: true,
      enableThinking: false,
      searchOptions: DashScopeSearchOptions(
        searchStrategy: settings.searchStrategy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? AlibabaQuestionAnswerSettings.defaultSearchStrategy
          : settings.searchStrategy,
        forcedSearch: true,
        enableSource: nil
      )
    ))
    let (data, response) = try await session.data(for: request)
    try validate(response: response, data: data)
    let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
    let text = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !text.isEmpty else { throw AlibabaQuestionAnswerClientError.emptyResponse }
    return AlibabaQuestionAnswer(text: text, usedWebSearch: true, sources: [])
  }

  func answerMemoryQuestion(_ request: AlibabaMemoryAnswerRequest) async throws -> AlibabaQuestionAnswer {
    if useProxy {
      return try await proxyAnswer(
        kind: "memory",
        systemPrompt: Self.memorySystemPrompt,
        userPrompt: Self.memoryAnswerPrompt(request),
        maxTokens: 70,
        enableSearch: false,
        timeoutSeconds: 10
      )
    }

    var url = try compatibleURL()
    url.appendPathComponent("chat")
    url.appendPathComponent("completions")
    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = "POST"
    urlRequest.timeoutInterval = 10
    urlRequest.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.httpBody = try JSONEncoder().encode(ChatCompletionRequest(
      model: settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? AlibabaQuestionAnswerSettings.defaultModel
        : settings.model,
      messages: [
        Message(role: "system", content: Self.memorySystemPrompt),
        Message(role: "user", content: Self.memoryAnswerPrompt(request))
      ],
      temperature: 0,
      maxTokens: 70,
      enableThinking: false
    ))
    let (data, response) = try await session.data(for: urlRequest)
    try validate(response: response, data: data)
    let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
    let text = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !text.isEmpty else { throw AlibabaQuestionAnswerClientError.emptyResponse }
    AppLogger.log(.memory, "Qwen live memory answer generated model=\(settings.model) characters=\(text.count)")
    return AlibabaQuestionAnswer(text: text, usedWebSearch: false, sources: [])
  }

  func classifyLiveTranscriptTrigger(_ request: LiveTranscriptTriggerLLMRequest) async throws -> LiveTranscriptTriggerLLMDecision {
    if useProxy {
      let proxy = try SupabaseEdgeFunctionClient.shared(session: session)
      let payload = AIProxyQwenAnswerPayload(
        kind: "live_trigger",
        model: resolvedModel,
        systemPrompt: Self.triggerClassifierSystemPrompt,
        userPrompt: Self.triggerClassifierPrompt(for: request),
        temperature: 0,
        maxTokens: 220,
        enableSearch: false,
        searchStrategy: nil,
        schema: "live_trigger",
        timeoutSeconds: 12
      )
      let response: AIProxyFunctionResponse<LiveTranscriptTriggerLLMDecision> = try await proxy.invoke(
        operation: "qwen.answer",
        payload: payload,
        timeoutInterval: 16
      )
      guard let output = response.output else {
        throw AlibabaQuestionAnswerClientError.emptyResponse
      }
      AppLogger.log(.memory, "[AI_PROXY] operation=qwen.answer kind=live_trigger source=supabase_edge model=\(response.model ?? resolvedModel)")
      return output
    }

    var url = try compatibleURL()
    url.appendPathComponent("chat")
    url.appendPathComponent("completions")
    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = "POST"
    urlRequest.timeoutInterval = 12
    urlRequest.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.httpBody = try JSONEncoder().encode(ChatCompletionRequest(
      model: settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? AlibabaQuestionAnswerSettings.defaultModel
        : settings.model,
      messages: [
        Message(role: "system", content: Self.triggerClassifierSystemPrompt),
        Message(role: "user", content: Self.triggerClassifierPrompt(for: request))
      ],
      temperature: 0,
      maxTokens: 220,
      enableThinking: false
    ))
    let (data, response) = try await session.data(for: urlRequest)
    try validate(response: response, data: data)
    let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
    let text = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !text.isEmpty else { throw AlibabaQuestionAnswerClientError.emptyResponse }
    return try Self.parseLiveTranscriptTriggerDecision(from: text)
  }

  private var resolvedModel: String {
    settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? AlibabaQuestionAnswerSettings.defaultModel
      : settings.model
  }

  private func proxyAnswer(
    kind: String,
    systemPrompt: String,
    userPrompt: String,
    maxTokens: Int,
    enableSearch: Bool,
    timeoutSeconds: Int
  ) async throws -> AlibabaQuestionAnswer {
    let proxy = try SupabaseEdgeFunctionClient.shared(session: session)
    let payload = AIProxyQwenAnswerPayload(
      kind: kind,
      model: resolvedModel,
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
      temperature: enableSearch ? 0.1 : 0.1,
      maxTokens: maxTokens,
      enableSearch: enableSearch,
      searchStrategy: settings.searchStrategy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? AlibabaQuestionAnswerSettings.defaultSearchStrategy
        : settings.searchStrategy,
      schema: nil,
      timeoutSeconds: timeoutSeconds
    )
    let response: AIProxyFunctionResponse<AIProxyQwenAnswerOutput> = try await proxy.invoke(
      operation: "qwen.answer",
      payload: payload,
      timeoutInterval: TimeInterval(timeoutSeconds + 5)
    )
    guard let output = response.output,
          !output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AlibabaQuestionAnswerClientError.emptyResponse
    }
    AppLogger.log(.memory, "[AI_PROXY] operation=qwen.answer kind=\(kind) source=supabase_edge model=\(response.model ?? resolvedModel)")
    return AlibabaQuestionAnswer(
      text: output.text,
      usedWebSearch: output.usedWebSearch,
      sources: output.sources.map {
        AlibabaQuestionAnswer.Source(title: $0.title, url: $0.url)
      }
    )
  }

  private struct AIProxyQwenAnswerPayload: Encodable {
    var kind: String
    var model: String
    var systemPrompt: String
    var userPrompt: String
    var temperature: Double
    var maxTokens: Int
    var enableSearch: Bool
    var searchStrategy: String?
    var schema: String?
    var timeoutSeconds: Int
  }

  private struct AIProxyQwenAnswerOutput: Decodable {
    struct Source: Decodable {
      var title: String
      var url: String
    }

    var text: String
    var usedWebSearch: Bool
    var sources: [Source]
  }

  private static let stableSystemPrompt = """
  Answer stable general-knowledge questions for a smart-glasses user. Return one direct sentence, maximum 18 words. No preamble, markdown, or extra context. If current information is needed, say: Need current search.
  """

  private static let currentSystemPrompt = """
  Answer current, time-sensitive questions for a smart-glasses user using web search. Return one direct sentence, maximum 22 words. Include a date only when it changes the answer. No markdown.
  """

  private static let memorySystemPrompt = """
  Answer saved-memory questions for a smart-glasses user. Use only supplied evidence. Return one direct sentence, maximum 22 words. No markdown.
  """

  private static let triggerClassifierSystemPrompt = """
  You classify live ASR text for a smart-glasses assistant. Decide if the latest text is a complete question or memory trigger that should be answered now. Return strict JSON only.
  """

  static func parseLiveTranscriptTriggerDecision(from content: String) throws -> LiveTranscriptTriggerLLMDecision {
    let jsonText = stripCodeFence(content)
    guard let data = jsonText.data(using: .utf8) else {
      throw AlibabaQuestionAnswerClientError.emptyResponse
    }
    return try JSONDecoder().decode(LiveTranscriptTriggerLLMDecision.self, from: data)
  }

  static func triggerClassifierPrompt(for request: LiveTranscriptTriggerLLMRequest) -> String {
    let peopleText = request.peopleNames.isEmpty ? "none" : request.peopleNames.joined(separator: ", ")
    return """
    Return exactly this JSON shape:
    {"isTrigger":true,"needsMoreTranscript":false,"fullQuestion":"...","answerMode":"general","confidence":0.0,"reason":"..."}

    answerMode must be one of: memory, general, current, mixed, ignore.

    Rules:
    - The rolling transcript is ASR text from overlapping 5 second audio chunks.
    - Decide whether the current transcript connects to prior words.
    - If the local candidate is a fragment like "what is the capital", set needsMoreTranscript=true and isTrigger=false.
    - If prior words plus the current transcript complete the question, put the complete question in fullQuestion.
    - Memory means questions about saved/past conversation, e.g. "what did we say last time with Gary".
    - General means stable facts, e.g. "what is the capital of Korea".
    - Current means time-sensitive facts, e.g. "what happened today".
    - Ignore small talk, incomplete fragments, commands that do not ask for an answer, and unrelated sentence fragments.
    - Do not invent missing words. Use only the rolling transcript and current transcript.

    Known people:
    \(peopleText)

    Local candidate:
    \(request.localCandidateQuestion)

    Local answer mode:
    \(request.localAnswerMode.rawValue)

    Current transcript:
    \(request.currentTranscript)

    Rolling transcript:
    \(request.rollingTranscript)
    """
  }

  static func memoryAnswerPrompt(_ request: AlibabaMemoryAnswerRequest) -> String {
    """
    Use only the saved memory evidence below.
    Rules:
    - Answer the user's full question directly in one sentence, maximum 22 words.
    - Prefer the latest conversation when the question asks "last time" or "last".
    - If the evidence does not directly answer the question, return exactly: No relevant saved memory.
    - Do not add background, bullets, markdown, sources, or guesses.

    Trigger: \(request.triggerReason)
    Full question:
    \(request.fullQuestion)

    Saved memory evidence:
    \(request.memoryEvidence)
    """
  }

  private func compatibleURL() throws -> URL {
    let trimmed = settings.compatibleBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard let url = URL(string: trimmed) else { throw AlibabaQuestionAnswerClientError.invalidBaseURL }
    return url
  }

  private func generationURL() throws -> URL {
    let trimmed = settings.generationBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard let url = URL(string: trimmed) else { throw AlibabaQuestionAnswerClientError.invalidBaseURL }
    return url
  }

  private func validate(response: URLResponse, data: Data) throws {
    guard let http = response as? HTTPURLResponse else {
      throw AlibabaQuestionAnswerClientError.emptyResponse
    }
    guard (200..<300).contains(http.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? ""
      throw AlibabaQuestionAnswerClientError.badHTTPStatus(http.statusCode, body)
    }
  }

  private static func stripCodeFence(_ text: String) -> String {
    var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("```") {
      let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
      if lines.count >= 2 {
        trimmed = lines.dropFirst().joined(separator: "\n")
        if let lastFence = trimmed.range(of: "```", options: .backwards) {
          trimmed = String(trimmed[..<lastFence.lowerBound])
        }
      }
    }
    return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [Message]
    let temperature: Double
    let maxTokens: Int
    var enableSearch: Bool? = nil
    var enableThinking: Bool? = nil
    var searchOptions: DashScopeSearchOptions? = nil

    enum CodingKeys: String, CodingKey {
      case model, messages, temperature
      case maxTokens = "max_tokens"
      case enableSearch = "enable_search"
      case enableThinking = "enable_thinking"
      case searchOptions = "search_options"
    }
  }

  private struct Message: Codable {
    let role: String
    let content: String
  }

  private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
      let message: Message
    }

    let choices: [Choice]
  }

  private struct DashScopeGenerationRequest: Encodable {
    let model: String
    let input: DashScopeInput
    let parameters: DashScopeParameters
  }

  private struct DashScopeInput: Encodable {
    let messages: [Message]
  }

  private struct DashScopeParameters: Encodable {
    let enableSearch: Bool
    let searchOptions: DashScopeSearchOptions
    let resultFormat: String

    enum CodingKeys: String, CodingKey {
      case enableSearch = "enable_search"
      case searchOptions = "search_options"
      case resultFormat = "result_format"
    }
  }

  private struct DashScopeSearchOptions: Encodable {
    let searchStrategy: String
    let forcedSearch: Bool?
    let enableSource: Bool?

    enum CodingKeys: String, CodingKey {
      case searchStrategy = "search_strategy"
      case forcedSearch = "forced_search"
      case enableSource = "enable_source"
    }
  }

  private struct DashScopeGenerationResponse: Decodable {
    struct Output: Decodable {
      struct Choice: Decodable {
        let message: Message
      }

      struct SearchInfo: Decodable {
        struct SearchResult: Decodable {
          let title: String?
          let url: String?
        }

        let searchResults: [SearchResult]

        enum CodingKeys: String, CodingKey {
          case searchResults = "search_results"
        }
      }

      let choices: [Choice]
      let searchInfo: SearchInfo?

      enum CodingKeys: String, CodingKey {
        case choices
        case searchInfo = "search_info"
      }
    }

    let output: Output
  }
}

struct DeepSeekLiveMemoryAnswerRequest: Equatable {
  let fullQuestion: String
  let triggerReason: String
  let memoryEvidence: String
}

enum DeepSeekClientError: LocalizedError {
  case missingAPIKey
  case invalidBaseURL
  case badHTTPStatus(Int, String)
  case emptyResponse

  var errorDescription: String? {
    switch self {
    case .missingAPIKey:
      return "DeepSeek API key is missing."
    case .invalidBaseURL:
      return "DeepSeek base URL is invalid."
    case .badHTTPStatus(let status, let body):
      return "DeepSeek returned HTTP \(status): \(body)"
    case .emptyResponse:
      return "DeepSeek returned an empty response."
    }
  }
}

struct DeepSeekAssistanceClient {
  private let apiKey: String
  private let model: String
  private let baseURL: URL
  private let session: URLSession
  private let useProxy: Bool

  init(
    apiKey: String,
    model: String = DeepSeekSettings.defaultModel,
    baseURL: String = DeepSeekSettings.defaultBaseURL,
    session: URLSession = .shared
  ) throws {
    let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let canUseProxy = SupabaseEdgeFunctionClient.isConfigured()
    guard canUseProxy || !trimmedKey.isEmpty else {
      throw DeepSeekClientError.missingAPIKey
    }
    guard canUseProxy || (URL(string: baseURL)?.scheme != nil && URL(string: baseURL)?.host != nil) else {
      throw DeepSeekClientError.invalidBaseURL
    }
    self.apiKey = trimmedKey
    self.model = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? DeepSeekSettings.defaultModel
      : model.trimmingCharacters(in: .whitespacesAndNewlines)
    self.baseURL = URL(string: baseURL) ?? URL(string: DeepSeekSettings.defaultBaseURL)!
    self.session = session
    self.useProxy = canUseProxy
  }

  func summarizePersonConversations(
    personName: String,
    lastSeenText: String,
    conversationTranscript: String
  ) async throws -> String {
    var url = baseURL
    url.appendPathComponent("chat")
    url.appendPathComponent("completions")

    let prompt = """
    Summarize saved conversations with this identified person for a wearable memory assistant.
    Rules:
    - Return one sentence, maximum 35 words.
    - Include only the most useful topic, promise, follow-up, or relationship cue.
    - Do not invent facts.
    - If the transcript is sparse, say only what is known.
    - Make it safe to show on the user's phone during a conversation.

    Person: \(personName)
    Last seen: \(lastSeenText)
    Saved conversation transcript:
    \(conversationTranscript)
    """

    if useProxy {
      return try await proxyAnswer(
        systemPrompt: "You summarize personal conversation history for a privacy-conscious wearable assistant.",
        userPrompt: prompt,
        maxTokens: 90,
        temperature: 0.2,
        timeoutSeconds: 18,
        logContext: "person conversation summary"
      )
    }

    let payload = ChatCompletionRequest(
      model: model,
      messages: [
        Message(role: "system", content: "You summarize personal conversation history for a privacy-conscious wearable assistant."),
        Message(role: "user", content: prompt)
      ],
      temperature: 0.2,
      maxTokens: 90
    )

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 18
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(payload)

    let (data, response) = try await session.data(for: request)
    try validate(response: response, data: data)
    let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
    let content = decoded.choices.first?.message.content
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !content.isEmpty else {
      throw DeepSeekClientError.emptyResponse
    }
    AppLogger.log(.audio, "DeepSeek person conversation summary generated model=\(model) characters=\(content.count)")
    return content
  }

  func answerLiveMemoryTrigger(
    liveTranscript: String,
    triggerReason: String,
    memoryContext: String
  ) async throws -> String {
    try await answerLiveMemoryTrigger(DeepSeekLiveMemoryAnswerRequest(
      fullQuestion: liveTranscript,
      triggerReason: triggerReason,
      memoryEvidence: memoryContext
    ))
  }

  func answerLiveMemoryTrigger(_ request: DeepSeekLiveMemoryAnswerRequest) async throws -> String {
    let prompt = Self.liveMemoryAnswerPrompt(request)

    if useProxy {
      return try await proxyAnswer(
        systemPrompt: "You answer from saved personal memory for a privacy-conscious wearable assistant.",
        userPrompt: prompt,
        maxTokens: 70,
        temperature: 0.1,
        timeoutSeconds: 12,
        logContext: "live memory trigger"
      )
    }

    var url = baseURL
    url.appendPathComponent("chat")
    url.appendPathComponent("completions")

    let payload = ChatCompletionRequest(
      model: model,
      messages: [
        Message(role: "system", content: "You answer from saved personal memory for a privacy-conscious wearable assistant."),
        Message(role: "user", content: prompt)
      ],
      temperature: 0.1,
      maxTokens: 70
    )

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 12
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(payload)

    let (data, response) = try await session.data(for: request)
    try validate(response: response, data: data)
    let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
    let content = decoded.choices.first?.message.content
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !content.isEmpty else {
      throw DeepSeekClientError.emptyResponse
    }
    AppLogger.log(.memory, "DeepSeek live memory trigger answered model=\(model) characters=\(content.count)")
    return content
  }

  private func proxyAnswer(
    systemPrompt: String,
    userPrompt: String,
    maxTokens: Int,
    temperature: Double,
    timeoutSeconds: Int,
    logContext: String
  ) async throws -> String {
    let proxy = try SupabaseEdgeFunctionClient.shared(session: session)
    let payload = AIProxyDeepSeekAnswerPayload(
      model: model,
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
      temperature: temperature,
      maxTokens: maxTokens,
      timeoutSeconds: timeoutSeconds
    )
    let response: AIProxyFunctionResponse<AIProxyDeepSeekAnswerOutput> = try await proxy.invoke(
      operation: "deepseek.answer",
      payload: payload,
      timeoutInterval: TimeInterval(timeoutSeconds + 5)
    )
    guard let output = response.output,
          !output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw DeepSeekClientError.emptyResponse
    }
    AppLogger.log(.memory, "[AI_PROXY] operation=deepseek.answer source=supabase_edge model=\(response.model ?? model) context=\"\(logContext)\" characters=\(output.text.count)")
    return output.text
  }

  static func liveMemoryAnswerPrompt(_ request: DeepSeekLiveMemoryAnswerRequest) -> String {
    """
    A wearable user is in a live conversation. The captured text below is the full trigger sentence/question, not a random fragment.
    Use only the saved memory evidence below.
    Rules:
    - Return one sentence, maximum 25 words.
    - Answer the full trigger question only when the saved memory evidence directly supports it.
    - Prefer the latest conversation for a named person when the question says "last time".
    - If it is a past/similar reference, give the most relevant prior point only.
    - Do not invent names, times, decisions, or facts.
    - If no saved memory is relevant, return exactly: No relevant saved memory.

    Trigger: \(request.triggerReason)
    Full trigger:
    \(request.fullQuestion)

    Saved memory evidence:
    \(request.memoryEvidence)
    """
  }

  private func validate(response: URLResponse, data: Data) throws {
    guard let http = response as? HTTPURLResponse else {
      throw DeepSeekClientError.emptyResponse
    }
    guard (200..<300).contains(http.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? ""
      throw DeepSeekClientError.badHTTPStatus(http.statusCode, body)
    }
  }

  private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [Message]
    let temperature: Double
    let maxTokens: Int

    enum CodingKeys: String, CodingKey {
      case model, messages, temperature
      case maxTokens = "max_tokens"
    }
  }

  private struct Message: Codable {
    let role: String
    let content: String
  }

  private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
      let message: Message
    }

    let choices: [Choice]
  }

  private struct AIProxyDeepSeekAnswerPayload: Encodable {
    var model: String
    var systemPrompt: String
    var userPrompt: String
    var temperature: Double
    var maxTokens: Int
    var timeoutSeconds: Int
  }

  private struct AIProxyDeepSeekAnswerOutput: Decodable {
    var text: String
  }
}
