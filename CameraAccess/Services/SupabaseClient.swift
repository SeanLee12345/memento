import Foundation

// SupabaseClient — thin URLSession wrapper around Supabase PostgREST.
//
// The Supabase project is the source-of-truth backend for identity, transcripts,
// scene context, diarization jobs, and glasses interaction events. The schema is
// defined in `supabase/migrations/0001_init.sql` and `0002_owner_rls.sql`.
//
// Authentication: the iOS client uses SUPABASE_ANON_KEY + a per-install
// anonymous Supabase Auth session. SUPABASE_SERVICE_KEY may exist in .env.local
// for laptop-only migrations/admin scripts, but the app ignores it by default.
//
// The session JWT carries auth.uid(); RLS policies (see 0002) restrict every
// row to its owner_uid. Anyone who extracts the IPA only gets the anon key,
// which is incapable of reading data without going through Supabase Auth.
//
// iOS config should come from Xcode build settings / Info.plist placeholders:
//   SUPABASE_URL=https://<ref>.supabase.co
//   SUPABASE_ANON_KEY=<public anon key>
//   SUPABASE_PROJECT_REF=<ref>
//
// Local scripts may keep a service-role key in the repository root .env.local,
// but that file must not be bundled into the app and is ignored unless an
// explicit DEBUG-only override flag is set.
//
// Usage:
//   let client = try SupabaseClient.shared()
//   try await client.healthCheck()
//   try await client.upsert(table: "person_profiles", rows: [profile])

struct SupabaseSettings {
  var url: URL
  var anonKey: String
  var serviceKey: String?
  var projectRef: String?

  var usesServiceRole: Bool {
    guard let key = serviceKey?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
    return !key.isEmpty
  }

  var requestAPIKey: String {
    if let key = serviceKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
      return key
    }
    return anonKey
  }

  static func serviceRoleKeyForApp(rawServiceKey: String?, allowFlag: String?) -> String? {
    guard serviceRoleKeyAllowedInApp(allowFlag: allowFlag),
          let key = rawServiceKey?.trimmingCharacters(in: .whitespacesAndNewlines),
          !key.isEmpty else {
      return nil
    }
    return key
  }

  static func serviceRoleKeyAllowedInApp(allowFlag: String?) -> Bool {
    #if DEBUG
    return isTruthy(allowFlag)
    #else
    return false
    #endif
  }

  private static func isTruthy(_ value: String?) -> Bool {
    switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "1", "true", "yes", "y", "on":
      return true
    default:
      return false
    }
  }

  static func load() -> SupabaseSettings? {
    let env = SupabaseSettings.loadDotEnv()
    let process = ProcessInfo.processInfo.environment

    func value(_ key: String) -> String? {
      if let v = process[key], !v.isEmpty { return v }
      if let v = env[key], !v.isEmpty { return v }
      if let v = plistValue(key), !v.isEmpty { return v }
      return nil
    }

    guard
      let rawURL = value("SUPABASE_URL"),
      let url = URL(string: rawURL),
      let anonKey = value("SUPABASE_ANON_KEY")
    else {
      return nil
    }

    return SupabaseSettings(
      url: url,
      anonKey: anonKey,
      serviceKey: serviceRoleKeyForApp(
        rawServiceKey: value("SUPABASE_SERVICE_KEY"),
        allowFlag: value("MEMENTO_ALLOW_SUPABASE_SERVICE_KEY_IN_IOS_DEBUG")
      ),
      projectRef: value("SUPABASE_PROJECT_REF")
    )
  }

  private static func plistValue(_ key: String) -> String? {
    let plistKey: String
    switch key {
    case "SUPABASE_URL":
      plistKey = "MementoSupabaseURL"
    case "SUPABASE_ANON_KEY":
      plistKey = "MementoSupabaseAnonKey"
    case "SUPABASE_PROJECT_REF":
      plistKey = "MementoSupabaseProjectRef"
    default:
      return nil
    }
    guard let raw = Bundle.main.object(forInfoDictionaryKey: plistKey) as? String else {
      return nil
    }
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, !value.contains("$("), !value.contains("YOUR_") else {
      return nil
    }
    return value
  }

  // Minimal .env(.local) loader. Mirrors the parsing in DotEnvFile in
  // DeepSeekAssistanceClient.swift; intentionally duplicated so this file
  // can be dropped into the project without a target-membership step.
  private static func loadDotEnv() -> [String: String] {
    var values: [String: String] = [:]
    let fm = FileManager.default
    let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
    let candidates = [
      cwd.appendingPathComponent(".env.local"),
      cwd.appendingPathComponent(".env"),
    ]
    for url in candidates {
      guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
      for line in text.split(whereSeparator: \.isNewline) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
              let equals = trimmed.firstIndex(of: "=") else { continue }
        let key = String(trimmed[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines)
        var value = String(trimmed[trimmed.index(after: equals)...])
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if (value.hasPrefix("\"") && value.hasSuffix("\""))
            || (value.hasPrefix("'") && value.hasSuffix("'")) {
          value.removeFirst()
          value.removeLast()
        }
        values[key] = value
      }
      if !values.isEmpty { return values }
    }
    return values
  }
}

enum SupabaseClientError: LocalizedError {
  case missingConfiguration
  case invalidEndpoint(String)
  case badHTTPStatus(Int, String)
  case decodingFailed(String)
  case notAuthenticated

  var errorDescription: String? {
    switch self {
    case .missingConfiguration:
      return "Supabase configuration is missing. Set SUPABASE_URL and SUPABASE_ANON_KEY in .env.local or the process environment."
    case .invalidEndpoint(let path):
      return "Could not construct Supabase URL for path \(path)."
    case .badHTTPStatus(let status, let body):
      return "Supabase returned HTTP \(status): \(body)"
    case .decodingFailed(let message):
      return "Failed to decode Supabase response: \(message)"
    case .notAuthenticated:
      return "No active Supabase session. Call SupabaseSession.shared.signInIfNeeded() at app startup."
    }
  }
}

final class SupabaseClient {
  private let settings: SupabaseSettings
  private let session: URLSession
  private let authSession: SupabaseSession
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  static func shared() throws -> SupabaseClient {
    guard let settings = SupabaseSettings.load() else {
      throw SupabaseClientError.missingConfiguration
    }
    return SupabaseClient(settings: settings, authSession: SupabaseSession.shared)
  }

  init(
    settings: SupabaseSettings,
    authSession: SupabaseSession,
    urlSession: URLSession = .shared
  ) {
    self.settings = settings
    self.authSession = authSession
    self.session = urlSession

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.keyEncodingStrategy = .convertToSnakeCase
    self.encoder = encoder

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    self.decoder = decoder
  }

  // MARK: - Public surface

  /// Pings PostgREST as the current user. 200 confirms anon key + session JWT
  /// are both valid; 401 means the session needs to be re-established.
  func healthCheck() async throws {
    var request = try await makeRequest(path: "/rest/v1/", method: "GET")
    request.setValue("0", forHTTPHeaderField: "Range")
    let (_, response) = try await session.data(for: request)
    try Self.assertSuccess(response: response, body: Data())
  }

  /// Inserts or upserts rows. owner_uid is auto-filled by the column default
  /// (`auth.uid()`); callers should not set it explicitly.
  func upsert<Row: Encodable>(
    table: String,
    rows: [Row],
    onConflict: String? = nil
  ) async throws {
    guard !rows.isEmpty else { return }
    var components = try makeComponents(path: "/rest/v1/\(table)")
    if let onConflict {
      components.queryItems = [URLQueryItem(name: "on_conflict", value: onConflict)]
    }
    guard let url = components.url else {
      throw SupabaseClientError.invalidEndpoint(table)
    }

    var request = try await makeBaseRequest(url: url, method: "POST")
    request.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
    request.httpBody = try encoder.encode(rows)

    let (data, response) = try await session.data(for: request)
    try Self.assertSuccess(response: response, body: data)
  }

  /// Selects rows from `table` and decodes them into `Row`. `filter` is appended
  /// raw to the query string (e.g. "person_id=eq.<uuid>&order=created_at.desc").
  /// RLS narrows the result set to rows owned by the current auth.uid().
  func select<Row: Decodable>(
    table: String,
    columns: String = "*",
    filter: String? = nil,
    limit: Int? = nil
  ) async throws -> [Row] {
    var components = try makeComponents(path: "/rest/v1/\(table)")
    var items = [URLQueryItem(name: "select", value: columns)]
    if let limit { items.append(URLQueryItem(name: "limit", value: String(limit))) }
    components.queryItems = items

    var url = components.url
    if let filter, !filter.isEmpty, let built = url {
      let joiner = built.query == nil ? "?" : "&"
      let raw = built.absoluteString + joiner + filter
      url = URL(string: raw) ?? url
    }
    guard let url else {
      throw SupabaseClientError.invalidEndpoint(table)
    }

    let request = try await makeBaseRequest(url: url, method: "GET")
    let (data, response) = try await session.data(for: request)
    try Self.assertSuccess(response: response, body: data)
    do {
      return try decoder.decode([Row].self, from: data)
    } catch {
      throw SupabaseClientError.decodingFailed(String(describing: error))
    }
  }

  /// Calls a Postgres RPC function via PostgREST. RLS still applies inside
  /// the function unless it was created with `security definer`.
  func rpc<Params: Encodable, Result: Decodable>(
    _ functionName: String,
    params: Params
  ) async throws -> Result {
    var request = try await makeRequest(path: "/rest/v1/rpc/\(functionName)", method: "POST")
    request.httpBody = try encoder.encode(params)
    let (data, response) = try await session.data(for: request)
    try Self.assertSuccess(response: response, body: data)
    do {
      return try decoder.decode(Result.self, from: data)
    } catch {
      throw SupabaseClientError.decodingFailed(String(describing: error))
    }
  }

  func storageOwnerFolder() async throws -> String {
    if settings.usesServiceRole {
      return "service-role"
    }
    return try await authSession.signInIfNeeded(
      url: settings.url,
      anonKey: settings.anonKey
    ).userId
  }

  func uploadStorageObject(
    bucketID: String,
    objectPath: String,
    data: Data,
    contentType: String,
    upsert: Bool = true
  ) async throws {
    var request = try await makeRequest(
      path: "/storage/v1/object/\(bucketID)/\(objectPath)",
      method: "POST"
    )
    request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    request.setValue(upsert ? "true" : "false", forHTTPHeaderField: "x-upsert")
    request.httpBody = data

    let (responseData, response) = try await session.data(for: request)
    try Self.assertSuccess(response: response, body: responseData)
  }

  func createSignedStorageURL(
    bucketID: String,
    objectPath: String,
    expiresIn: Int
  ) async throws -> URL {
    var request = try await makeRequest(
      path: "/storage/v1/object/sign/\(bucketID)/\(objectPath)",
      method: "POST"
    )
    request.httpBody = try JSONSerialization.data(withJSONObject: ["expiresIn": expiresIn])

    let (data, response) = try await session.data(for: request)
    try Self.assertSuccess(response: response, body: data)
    do {
      let decoded = try JSONDecoder().decode(SignedStorageURLResponse.self, from: data)
      guard let url = Self.absoluteStorageURL(from: decoded.signedURL, baseURL: settings.url) else {
        throw SupabaseClientError.invalidEndpoint(decoded.signedURL)
      }
      return url
    } catch let error as SupabaseClientError {
      throw error
    } catch {
      throw SupabaseClientError.decodingFailed(String(describing: error))
    }
  }

  static func absoluteStorageURL(from signedURL: String, baseURL: URL) -> URL? {
    let trimmed = signedURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let absolute = URL(string: trimmed), absolute.scheme != nil {
      return absolute
    }
    let storagePath: String
    if trimmed.hasPrefix("/storage/v1/") {
      storagePath = trimmed
    } else if trimmed.hasPrefix("storage/v1/") {
      storagePath = "/\(trimmed)"
    } else if trimmed.hasPrefix("/object/") {
      storagePath = "/storage/v1\(trimmed)"
    } else if trimmed.hasPrefix("object/") {
      storagePath = "/storage/v1/\(trimmed)"
    } else {
      storagePath = trimmed
    }
    return URL(string: storagePath, relativeTo: baseURL)?.absoluteURL
  }

  // MARK: - Internals

  private struct SignedStorageURLResponse: Decodable {
    let signedURL: String
  }

  private func makeRequest(path: String, method: String) async throws -> URLRequest {
    let components = try makeComponents(path: path)
    guard let url = components.url else {
      throw SupabaseClientError.invalidEndpoint(path)
    }
    return try await makeBaseRequest(url: url, method: method)
  }

  private func makeComponents(path: String) throws -> URLComponents {
    guard var components = URLComponents(url: settings.url, resolvingAgainstBaseURL: false) else {
      throw SupabaseClientError.invalidEndpoint(path)
    }
    components.path = path
    return components
  }

  private func makeBaseRequest(url: URL, method: String) async throws -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(settings.requestAPIKey, forHTTPHeaderField: "apikey")
    if settings.usesServiceRole {
      request.setValue("Bearer \(settings.requestAPIKey)", forHTTPHeaderField: "Authorization")
    } else {
      let accessToken = try await authSession.currentAccessToken(
        url: settings.url,
        anonKey: settings.anonKey
      )
      request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    }
    return request
  }

  private static func assertSuccess(response: URLResponse, body: Data) throws {
    guard let http = response as? HTTPURLResponse else { return }
    guard (200..<300).contains(http.statusCode) else {
      let message = String(data: body, encoding: .utf8) ?? ""
      throw SupabaseClientError.badHTTPStatus(http.statusCode, message)
    }
  }
}

enum SupabaseEdgeFunctionError: LocalizedError {
  case missingConfiguration
  case invalidEndpoint(String)
  case badHTTPStatus(Int, String)
  case functionError(kind: String, message: String, retryable: Bool)
  case missingOutput
  case decodingFailed(String)

  var errorDescription: String? {
    switch self {
    case .missingConfiguration:
      return "Supabase Edge Function configuration is missing."
    case .invalidEndpoint(let name):
      return "Could not construct Supabase Edge Function URL for \(name)."
    case .badHTTPStatus(let status, let body):
      return "Supabase Edge Function returned HTTP \(status): \(body)"
    case .functionError(let kind, let message, let retryable):
      return "Supabase Edge Function failed kind=\(kind) retryable=\(retryable): \(message)"
    case .missingOutput:
      return "Supabase Edge Function response did not include output."
    case .decodingFailed(let message):
      return "Failed to decode Supabase Edge Function response: \(message)"
    }
  }
}

struct AIProxyEnvelope<Payload: Encodable>: Encodable {
  var operation: String
  var requestId: String
  var payload: Payload
}

struct AIProxyFunctionResponse<Output: Decodable>: Decodable {
  struct FunctionError: Decodable {
    var kind: String
    var message: String
    var retryable: Bool?
  }

  var ok: Bool
  var operation: String?
  var source: String?
  var model: String?
  var promptVersion: String?
  var output: Output?
  var error: FunctionError?
}

final class SupabaseEdgeFunctionClient {
  private let settings: SupabaseSettings
  private let authSession: SupabaseSession
  private let session: URLSession
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  static func isConfigured() -> Bool {
    SupabaseSettings.load() != nil
  }

  static func shared(session: URLSession = .shared) throws -> SupabaseEdgeFunctionClient {
    guard let settings = SupabaseSettings.load() else {
      throw SupabaseEdgeFunctionError.missingConfiguration
    }
    return SupabaseEdgeFunctionClient(
      settings: settings,
      authSession: SupabaseSession.shared,
      session: session
    )
  }

  init(
    settings: SupabaseSettings,
    authSession: SupabaseSession,
    session: URLSession = .shared
  ) {
    self.settings = settings
    self.authSession = authSession
    self.session = session

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    self.encoder = encoder

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    self.decoder = decoder
  }

  func invoke<Payload: Encodable, Output: Decodable>(
    functionName: String = "memento-ai",
    operation: String,
    payload: Payload,
    timeoutInterval: TimeInterval = 45
  ) async throws -> AIProxyFunctionResponse<Output> {
    let requestId = UUID().uuidString.prefix(8)
    let envelope = AIProxyEnvelope(
      operation: operation,
      requestId: String(requestId),
      payload: payload
    )
    let requestBody = try encoder.encode(envelope)
    var request = try await makeFunctionRequest(
      functionName: functionName,
      timeoutInterval: timeoutInterval
    )
    request.httpBody = requestBody

    AppLogger.log(
      .sceneContext,
      "[AI_PROXY] operation=\(operation) source=supabase_edge requestId=\(requestId) requestBytes=\(requestBody.count)"
    )

    let startedAt = Date()
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw SupabaseEdgeFunctionError.badHTTPStatus(0, "non-HTTP response")
    }
    guard (200..<300).contains(http.statusCode) else {
      let detail = Self.sanitizedBody(data)
      AppLogger.log(
        .sceneContext,
        "[AI_PROXY] operation=\(operation) source=supabase_edge status=\(http.statusCode) fallback=possible reason=\"\(detail)\""
      )
      throw SupabaseEdgeFunctionError.badHTTPStatus(http.statusCode, detail)
    }
    do {
      let decoded = try decoder.decode(AIProxyFunctionResponse<Output>.self, from: data)
      if decoded.ok {
        AppLogger.log(
          .sceneContext,
          "[AI_PROXY] operation=\(operation) source=supabase_edge model=\(decoded.model ?? "unknown") status=success elapsedMs=\(Self.elapsedMilliseconds(since: startedAt)) responseBytes=\(data.count)"
        )
        return decoded
      }
      if let error = decoded.error {
        throw SupabaseEdgeFunctionError.functionError(
          kind: error.kind,
          message: error.message,
          retryable: error.retryable ?? false
        )
      }
      throw SupabaseEdgeFunctionError.missingOutput
    } catch let error as SupabaseEdgeFunctionError {
      AppLogger.log(
        .sceneContext,
        "[AI_PROXY] operation=\(operation) source=supabase_edge fallback=possible reason=\"\(Self.sanitizedText(error.localizedDescription, maxLength: 240))\""
      )
      throw error
    } catch {
      throw SupabaseEdgeFunctionError.decodingFailed(String(describing: error))
    }
  }

  func workerSession(
    worker: String,
    endpoint: String? = nil,
    conversationSessionId: UUID? = nil,
    ttlSeconds: Int = 900
  ) async throws -> WorkerSessionResponse {
    let payload = WorkerSessionRequest(
      worker: worker,
      endpoint: endpoint,
      ttlSeconds: ttlSeconds,
      conversationSessionId: conversationSessionId?.uuidString
    )
    let requestBody = try encoder.encode(payload)
    var request = try await makeFunctionRequest(
      functionName: "worker-session",
      timeoutInterval: 12
    )
    request.httpBody = requestBody

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw SupabaseEdgeFunctionError.badHTTPStatus(0, "non-HTTP response")
    }
    guard (200..<300).contains(http.statusCode) else {
      throw SupabaseEdgeFunctionError.badHTTPStatus(http.statusCode, Self.sanitizedBody(data))
    }
    do {
      return try decoder.decode(WorkerSessionResponse.self, from: data)
    } catch {
      throw SupabaseEdgeFunctionError.decodingFailed(String(describing: error))
    }
  }

  private func makeFunctionRequest(
    functionName: String,
    timeoutInterval: TimeInterval
  ) async throws -> URLRequest {
    guard var components = URLComponents(url: settings.url, resolvingAgainstBaseURL: false) else {
      throw SupabaseEdgeFunctionError.invalidEndpoint(functionName)
    }
    components.path = "/functions/v1/\(functionName)"
    guard let url = components.url else {
      throw SupabaseEdgeFunctionError.invalidEndpoint(functionName)
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = timeoutInterval
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(settings.anonKey, forHTTPHeaderField: "apikey")
    let accessToken = try await authSession.currentAccessToken(
      url: settings.url,
      anonKey: settings.anonKey
    )
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    return request
  }

  private static func sanitizedBody(_ data: Data) -> String {
    guard let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return "empty response body"
    }
    return sanitizedText(text, maxLength: 360)
  }

  private static func sanitizedText(_ value: String, maxLength: Int) -> String {
    let collapsed = value
      .replacingOccurrences(of: #"(?i)bearer\s+[A-Za-z0-9._~+/=-]+"#, with: "Bearer [redacted]", options: .regularExpression)
      .replacingOccurrences(of: #""api[_-]?key"\s*:\s*"[^"]+""#, with: #""api_key":"[redacted]""#, options: .regularExpression)
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard collapsed.count > maxLength else { return collapsed }
    return String(collapsed.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
  }

  private static func elapsedMilliseconds(since date: Date) -> String {
    String(format: "%.0f", Date().timeIntervalSince(date) * 1_000)
  }
}

struct WorkerSessionRequest: Encodable {
  var worker: String
  var endpoint: String?
  var ttlSeconds: Int
  var conversationSessionId: String?
}

struct WorkerSessionResponse: Decodable {
  var ok: Bool
  var source: String?
  var worker: String
  var token: String
  var tokenType: String
  var authHeader: String
  var expiresAt: Int
  var expiresIn: Int
}
