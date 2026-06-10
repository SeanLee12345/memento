import CryptoKit
import Foundation

// Shared Cognito-backed AWS Lambda client used by the live face and speaker
// embedding lifecycles. Both lifecycles invoke the same DiarizenStartEC2 Lambda
// in us-west-1, signed with SigV4 using credentials vended by the
// MetaGlassesTranscribe Cognito identity pool.
//
// The decoded response shape covers fields returned by all current actions
// (startLive/describeLive/refreshLive/releaseLive plus their face variants).
actor AWSCognitoLambdaClient {
  struct LifecycleResponse: Decodable {
    let statusCode: Int?
    let action: String?
    let publicIp: String?
    let privateIp: String?
    let state: String?
    let errorMessage: String?
    let liveSessionId: String?
    let liveExpiresAt: String?
    let liveFaceSessionId: String?
    let liveFaceExpiresAt: String?
  }

  enum LambdaError: LocalizedError {
    case invalidFunctionName
    case invalidLambdaURL
    case missingHTTPResponse
    case invokeFailed(String)
    case credentialsFailed(String)

    var errorDescription: String? {
      switch self {
      case .invalidFunctionName: return "Lambda function name is empty"
      case .invalidLambdaURL: return "Lambda invocation URL is invalid"
      case .missingHTTPResponse: return "Lambda response missing HTTP metadata"
      case .invokeFailed(let message): return "Lambda invoke failed: \(message)"
      case .credentialsFailed(let message): return "Cognito credentials failed: \(message)"
      }
    }
  }

  private struct Credentials {
    let accessKeyId: String
    let secretKey: String
    let sessionToken: String
    let expiration: Date
    var isExpired: Bool { Date() >= expiration.addingTimeInterval(-60) }
  }

  private let region: String
  private let identityPoolRegion: String
  private let identityPoolId: String
  private let accountId: String
  private let session: URLSession
  private var cachedCredentials: Credentials?
  private var cognitoIdentityId: String?

  init(
    region: String = "us-west-1",
    identityPoolRegion: String = "us-west-1",
    identityPoolId: String = "us-west-1:1166ae70-5652-4a7b-b045-66fdaf6e1efb",
    accountId: String = "620969609288",
    session: URLSession = .shared
  ) {
    self.region = region
    self.identityPoolRegion = identityPoolRegion
    self.identityPoolId = identityPoolId
    self.accountId = accountId
    self.session = session
  }

  func invokeLambda(
    functionName: String,
    payload: [String: String],
    timeout: TimeInterval = 15
  ) async throws -> LifecycleResponse {
    let trimmedName = functionName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else { throw LambdaError.invalidFunctionName }
    let encodedFunctionName = trimmedName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmedName
    guard let url = URL(string: "https://lambda.\(region).amazonaws.com/2015-03-31/functions/\(encodedFunctionName)/invocations") else {
      throw LambdaError.invalidLambdaURL
    }
    let body = try JSONEncoder().encode(payload)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = timeout
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let credentials = try await getCredentials()
    try signRequest(&request, service: "lambda", region: region, credentials: credentials, body: body)
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw LambdaError.missingHTTPResponse
    }
    guard (200..<300).contains(http.statusCode) else {
      let text = String(data: data, encoding: .utf8) ?? ""
      throw LambdaError.invokeFailed("HTTP \(http.statusCode) \(text)")
    }
    let decoded = try JSONDecoder().decode(LifecycleResponse.self, from: data)
    if let statusCode = decoded.statusCode, !(200..<300).contains(statusCode) {
      throw LambdaError.invokeFailed(decoded.errorMessage ?? "function statusCode=\(statusCode)")
    }
    return decoded
  }

  private func getCredentials() async throws -> Credentials {
    if let credentials = cachedCredentials, !credentials.isExpired {
      return credentials
    }
    let identityId = try await fetchIdentityId()
    var request = URLRequest(url: URL(string: "https://cognito-identity.\(identityPoolRegion).amazonaws.com/")!)
    request.httpMethod = "POST"
    request.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
    request.setValue("AWSCognitoIdentityService.GetCredentialsForIdentity", forHTTPHeaderField: "X-Amz-Target")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["IdentityId": identityId])
    let (data, _) = try await session.data(for: request)
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let credDict = json["Credentials"] as? [String: Any],
          let accessKey = credDict["AccessKeyId"] as? String,
          let secretKey = credDict["SecretKey"] as? String,
          let token = credDict["SessionToken"] as? String else {
      throw LambdaError.credentialsFailed(String(data: data, encoding: .utf8) ?? "")
    }
    let expiration: Date
    if let exp = credDict["Expiration"] as? Double {
      expiration = Date(timeIntervalSince1970: exp)
    } else {
      expiration = Date().addingTimeInterval(3600)
    }
    let credentials = Credentials(
      accessKeyId: accessKey,
      secretKey: secretKey,
      sessionToken: token,
      expiration: expiration
    )
    cachedCredentials = credentials
    return credentials
  }

  private func fetchIdentityId() async throws -> String {
    if let cognitoIdentityId { return cognitoIdentityId }
    var request = URLRequest(url: URL(string: "https://cognito-identity.\(identityPoolRegion).amazonaws.com/")!)
    request.httpMethod = "POST"
    request.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
    request.setValue("AWSCognitoIdentityService.GetId", forHTTPHeaderField: "X-Amz-Target")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["AccountId": accountId, "IdentityPoolId": identityPoolId])
    let (data, _) = try await session.data(for: request)
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let id = json["IdentityId"] as? String else {
      throw LambdaError.credentialsFailed("GetId failed")
    }
    cognitoIdentityId = id
    return id
  }

  private func signRequest(
    _ request: inout URLRequest,
    service: String,
    region: String,
    credentials: Credentials,
    body: Data
  ) throws {
    let now = Date()
    let amzDate = Self.awsDate(from: now)
    let dateStamp = String(amzDate.prefix(8))
    let url = request.url!
    let host = url.host!

    request.setValue(host, forHTTPHeaderField: "Host")
    request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
    request.setValue(credentials.sessionToken, forHTTPHeaderField: "X-Amz-Security-Token")
    let bodyHash = Self.sha256Hex(body)
    request.setValue(bodyHash, forHTTPHeaderField: "X-Amz-Content-Sha256")

    let headers = request.allHTTPHeaderFields ?? [:]
    let signedHeaders = headers.keys.map { $0.lowercased() }.sorted()
    let canonicalHeaders = headers
      .sorted { $0.key.lowercased() < $1.key.lowercased() }
      .map { "\($0.key.lowercased()):\($0.value.trimmingCharacters(in: .whitespaces))\n" }
      .joined()
    let signedHeadersText = signedHeaders.joined(separator: ";")
    let canonicalRequest = [
      request.httpMethod ?? "POST",
      url.path,
      "",
      canonicalHeaders,
      signedHeadersText,
      bodyHash
    ].joined(separator: "\n")
    let credentialScope = "\(dateStamp)/\(region)/\(service)/aws4_request"
    let stringToSign = [
      "AWS4-HMAC-SHA256",
      amzDate,
      credentialScope,
      Self.sha256Hex(Data(canonicalRequest.utf8))
    ].joined(separator: "\n")
    let signatureKey = Self.signingKey(
      secret: credentials.secretKey,
      dateStamp: dateStamp,
      region: region,
      service: service
    )
    let signature = Data(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: signatureKey))
      .map { String(format: "%02x", $0) }
      .joined()
    request.setValue(
      "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyId)/\(credentialScope), SignedHeaders=\(signedHeadersText), Signature=\(signature)",
      forHTTPHeaderField: "Authorization"
    )
  }

  private static func signingKey(secret: String, dateStamp: String, region: String, service: String) -> SymmetricKey {
    let kDate = Data(HMAC<SHA256>.authenticationCode(for: Data(dateStamp.utf8), using: SymmetricKey(data: Data(("AWS4" + secret).utf8))))
    let kRegion = Data(HMAC<SHA256>.authenticationCode(for: Data(region.utf8), using: SymmetricKey(data: kDate)))
    let kService = Data(HMAC<SHA256>.authenticationCode(for: Data(service.utf8), using: SymmetricKey(data: kRegion)))
    let kSigning = Data(HMAC<SHA256>.authenticationCode(for: Data("aws4_request".utf8), using: SymmetricKey(data: kService)))
    return SymmetricKey(data: kSigning)
  }

  private static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func awsDate(from date: Date) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    return String(
      format: "%04d%02d%02dT%02d%02d%02dZ",
      components.year!,
      components.month!,
      components.day!,
      components.hour!,
      components.minute!,
      components.second!
    )
  }
}
