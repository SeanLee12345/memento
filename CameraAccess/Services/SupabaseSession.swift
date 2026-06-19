import Foundation
import Security

// SupabaseSession — owns the per-install Supabase Auth session.
//
// On first launch the app calls `signInAnonymously` against Supabase Auth and
// stores the resulting access + refresh tokens in the iOS Keychain. Every
// subsequent app launch reads them back, refreshes the access token if it's
// near expiry, and hands a fresh bearer token to SupabaseClient.
//
// Why anonymous: it gives every install a unique `auth.uid()` that RLS can
// key on, without forcing the user through a sign-in screen. When you're
// ready to add Sign in with Apple, call `linkAppleIdentity(...)` and the
// existing rows stay attached to the same uid (Supabase merges identities).
//
// Tokens never leave the device except as standard Authorization headers.
//
// Concurrency: SupabaseSession is an actor so token refresh is serialized —
// concurrent callers all await the same refresh task.

actor SupabaseSession {
  static let shared = SupabaseSession()

  // Refresh the access token this many seconds before it actually expires,
  // so in-flight calls don't race the expiry.
  private static let refreshLeeway: TimeInterval = 60

  private let keychainService = "com.cameraaccess.supabase.session"
  private let keychainAccount = "primary"

  private var cached: StoredSession?
  private var refreshTask: Task<StoredSession, Error>?

  struct StoredSession: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var userId: String
    var isAnonymous: Bool
  }

  // MARK: - Public API

  /// Called once at app startup. Reads any persisted session, refreshes it if
  /// needed, or signs in anonymously if there's nothing on disk.
  func signInIfNeeded(url: URL, anonKey: String) async throws -> StoredSession {
    if cached == nil { cached = loadFromKeychain() }

    if let existing = cached, existing.expiresAt.timeIntervalSinceNow > Self.refreshLeeway {
      return existing
    }
    if let existing = cached {
      // Token exists but is near/past expiry — refresh.
      return try await refreshAccessToken(url: url, anonKey: anonKey, refreshToken: existing.refreshToken)
    }
    return try await signInAnonymously(url: url, anonKey: anonKey)
  }

  /// Returns a non-expired access token. SupabaseClient calls this before every
  /// PostgREST request. If the current token is near expiry, this transparently
  /// performs a single concurrent refresh that all callers await.
  func currentAccessToken(url: URL, anonKey: String) async throws -> String {
    let session = try await signInIfNeeded(url: url, anonKey: anonKey)
    return session.accessToken
  }

  /// Wipes the persisted session. The next call to `signInIfNeeded` will
  /// create a brand-new anonymous user. Use when "signing out" or when
  /// debugging RLS issues.
  func resetSession() {
    cached = nil
    deleteKeychain()
  }

  /// Diagnostic snapshot. Safe to log: never includes the access or refresh token.
  func diagnostics() -> (userId: String?, isAnonymous: Bool?, expiresAt: Date?) {
    let s = cached ?? loadFromKeychain()
    return (s?.userId, s?.isAnonymous, s?.expiresAt)
  }

  // MARK: - GoTrue calls

  private func signInAnonymously(url: URL, anonKey: String) async throws -> StoredSession {
    let endpoint = url.appendingPathComponent("auth/v1/signup")
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(anonKey, forHTTPHeaderField: "apikey")
    request.httpBody = Data("{}".utf8) // empty body → anonymous

    let (data, response) = try await URLSession.shared.data(for: request)
    try Self.assertOK(response: response, body: data)
    let token = try JSONDecoder().decode(GoTrueTokenResponse.self, from: data)
    let stored = StoredSession(
      accessToken: token.accessToken,
      refreshToken: token.refreshToken,
      expiresAt: token.expiresAtDate(),
      userId: token.user.id,
      isAnonymous: token.user.isAnonymous ?? true
    )
    cached = stored
    saveToKeychain(stored)
    return stored
  }

  private func refreshAccessToken(
    url: URL,
    anonKey: String,
    refreshToken: String
  ) async throws -> StoredSession {
    // Coalesce concurrent refreshes.
    if let existing = refreshTask {
      return try await existing.value
    }
    let task = Task { [refreshToken] () -> StoredSession in
      let endpoint = url.appendingPathComponent("auth/v1/token")
      var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
      components?.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]
      var request = URLRequest(url: components?.url ?? endpoint)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue(anonKey, forHTTPHeaderField: "apikey")
      let body = try JSONEncoder().encode(["refresh_token": refreshToken])
      request.httpBody = body

      let (data, response) = try await URLSession.shared.data(for: request)
      try Self.assertOK(response: response, body: data)
      let token = try JSONDecoder().decode(GoTrueTokenResponse.self, from: data)
      let stored = StoredSession(
        accessToken: token.accessToken,
        refreshToken: token.refreshToken,
        expiresAt: token.expiresAtDate(),
        userId: token.user.id,
        isAnonymous: token.user.isAnonymous ?? false
      )
      return stored
    }
    refreshTask = task
    defer { refreshTask = nil }
    do {
      let stored = try await task.value
      cached = stored
      saveToKeychain(stored)
      return stored
    } catch {
      // If refresh fails (e.g. refresh token revoked), fall back to a fresh
      // anonymous signup. The caller's request will retry on the new session.
      // NOTE: this loses access to any rows owned by the previous uid.
      resetSession()
      return try await signInAnonymously(url: url, anonKey: anonKey)
    }
  }

  private static func assertOK(response: URLResponse, body: Data) throws {
    guard let http = response as? HTTPURLResponse else { return }
    guard (200..<300).contains(http.statusCode) else {
      let message = String(data: body, encoding: .utf8) ?? ""
      throw SupabaseClientError.badHTTPStatus(http.statusCode, message)
    }
  }

  // MARK: - Keychain

  private func saveToKeychain(_ session: StoredSession) {
    guard let data = try? JSONEncoder().encode(session) else { return }
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: keychainAccount,
    ]
    // Replace if exists.
    SecItemDelete(query as CFDictionary)
    query[kSecValueData as String] = data
    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    SecItemAdd(query as CFDictionary, nil)
  }

  private func loadFromKeychain() -> StoredSession? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: keychainAccount,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else { return nil }
    return try? JSONDecoder().decode(StoredSession.self, from: data)
  }

  private func deleteKeychain() {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: keychainAccount,
    ]
    SecItemDelete(query as CFDictionary)
  }
}

// MARK: - GoTrue wire format

private struct GoTrueTokenResponse: Decodable {
  let accessToken: String
  let refreshToken: String
  let expiresIn: Int
  let expiresAt: Int?           // Unix seconds; present in newer GoTrue versions
  let user: GoTrueUser

  func expiresAtDate() -> Date {
    if let expiresAt {
      return Date(timeIntervalSince1970: TimeInterval(expiresAt))
    }
    return Date().addingTimeInterval(TimeInterval(expiresIn))
  }

  private enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case refreshToken = "refresh_token"
    case expiresIn = "expires_in"
    case expiresAt = "expires_at"
    case user
  }
}

private struct GoTrueUser: Decodable {
  let id: String
  let isAnonymous: Bool?

  private enum CodingKeys: String, CodingKey {
    case id
    case isAnonymous = "is_anonymous"
  }
}
