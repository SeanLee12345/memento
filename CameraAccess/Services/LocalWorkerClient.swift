import Foundation

struct LocalWorkerModel: Decodable, Identifiable {
  let id: String
}

struct LocalWorkerHealth: Decodable {
  let status: String
}

struct LocalWorkerTestResult {
  let statusText: String
  let modelNames: [String]
}

enum LocalWorkerClientError: LocalizedError {
  case invalidURL
  case badHTTPStatus(Int, String)
  case invalidResponse

  var errorDescription: String? {
    switch self {
    case .invalidURL:
      return "Local worker URL is invalid."
    case .badHTTPStatus(let code, let body):
      return "Local worker returned HTTP \(code): \(body)"
    case .invalidResponse:
      return "Local worker returned an invalid response."
    }
  }
}

struct LocalWorkerSettings {
  private enum Keys {
    static let enabled = "localWorker.enabled"
    static let endpoint = "localWorker.endpoint"
    static let apiKey = "localWorker.apiKey"
  }

  static let defaultEndpoint = "http://100.125.149.29:8080"
  static let defaultSpeakerEndpoint = "http://100.125.149.29:8090"
  static let defaultAPIKey = ""

  var enabled: Bool
  var endpoint: String
  var apiKey: String

  static func load() -> LocalWorkerSettings {
    let defaults = UserDefaults.standard
    return LocalWorkerSettings(
      enabled: true,
      endpoint: defaults.string(forKey: Keys.endpoint) ?? defaultEndpoint,
      apiKey: defaults.string(forKey: Keys.apiKey) ?? defaultAPIKey
    )
  }

  func save() {
    let defaults = UserDefaults.standard
    defaults.set(true, forKey: Keys.enabled)
    defaults.set(endpoint, forKey: Keys.endpoint)
    defaults.set(apiKey, forKey: Keys.apiKey)
  }
}

struct LocalWorkerClient {
  private let baseURL: URL
  private let apiKey: String
  private let session: URLSession

  init(endpoint: String, apiKey: String, session: URLSession = .shared) throws {
    let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
      throw LocalWorkerClientError.invalidURL
    }
    baseURL = url
    self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    self.session = session
  }

  func testConnection() async throws -> LocalWorkerTestResult {
    let health = try await getJSON(LocalWorkerHealth.self, path: "/health")
    let models = try await getJSON(ModelsResponse.self, path: "/v1/models")
    let names = models.allModelNames
    AppLogger.log(.localWorker, "connectionTest status=\(health.status) models=\(names.joined(separator: ","))")
    return LocalWorkerTestResult(
      statusText: "Connected: \(health.status), models \(names.count)",
      modelNames: names
    )
  }

  private func getJSON<T: Decodable>(_ type: T.Type, path: String) async throws -> T {
    var url = baseURL
    path
      .split(separator: "/")
      .forEach { url.appendPathComponent(String($0)) }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 10
    applyAuth(to: &request)
    let (data, response) = try await session.data(for: request)
    try validate(response: response, data: data)
    return try JSONDecoder().decode(T.self, from: data)
  }

  private func applyAuth(to request: inout URLRequest) {
    guard !apiKey.isEmpty else { return }
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
  }

  private func validate(response: URLResponse, data: Data) throws {
    guard let http = response as? HTTPURLResponse else {
      throw LocalWorkerClientError.invalidResponse
    }
    guard (200..<300).contains(http.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? ""
      throw LocalWorkerClientError.badHTTPStatus(http.statusCode, body)
    }
  }

  private struct ModelsResponse: Decodable {
    struct ModelEntry: Decodable {
      let id: String?
      let name: String?
      let model: String?
    }

    let data: [ModelEntry]?
    let models: [ModelEntry]?

    var allModelNames: [String] {
      let entries = data ?? models ?? []
      return entries.compactMap { $0.id ?? $0.name ?? $0.model }
    }
  }
}
