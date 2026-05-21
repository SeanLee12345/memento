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
    var urls = [
      cwd.appendingPathComponent(".env.local"),
      cwd.appendingPathComponent(".env")
    ]
    if let bundleLocal = Bundle.main.url(forResource: ".env", withExtension: "local") {
      urls.append(bundleLocal)
    }
    if let bundleEnv = Bundle.main.url(forResource: ".env", withExtension: nil) {
      urls.append(bundleEnv)
    }
    return urls
  }
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

  init(
    apiKey: String,
    model: String = DeepSeekSettings.defaultModel,
    baseURL: String = DeepSeekSettings.defaultBaseURL,
    session: URLSession = .shared
  ) throws {
    let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedKey.isEmpty else {
      throw DeepSeekClientError.missingAPIKey
    }
    guard let url = URL(string: baseURL), url.scheme != nil, url.host != nil else {
      throw DeepSeekClientError.invalidBaseURL
    }
    self.apiKey = trimmedKey
    self.model = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? DeepSeekSettings.defaultModel
      : model.trimmingCharacters(in: .whitespacesAndNewlines)
    self.baseURL = url
    self.session = session
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
    Summarize all saved conversations with this identified person for a wearable memory assistant.
    Rules:
    - Return 1 compact paragraph, maximum 70 words.
    - Include useful topics, promises, follow-ups, and relationship context.
    - Do not invent facts.
    - If the transcript is sparse, say what is known.
    - Make it safe to show on the user's phone during a conversation.

    Person: \(personName)
    Last seen: \(lastSeenText)
    Saved conversation transcript:
    \(conversationTranscript)
    """

    let payload = ChatCompletionRequest(
      model: model,
      messages: [
        Message(role: "system", content: "You summarize personal conversation history for a privacy-conscious wearable assistant."),
        Message(role: "user", content: prompt)
      ],
      temperature: 0.2,
      maxTokens: 180
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
}
