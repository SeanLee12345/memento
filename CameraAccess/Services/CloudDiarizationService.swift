import AVFoundation
import CryptoKit
import Foundation

enum CloudDiarizationError: LocalizedError {
  case credentialsFailed(String)
  case uploadFailed(String)
  case timeout(jobId: String, audioSeconds: Double?, lastState: String?, timeoutMinutes: Int)
  case resultDecodeFailed(String)
  case backendFailed(jobId: String, state: String, kind: String?, message: String?)
  case emptyAudioFile

  var errorDescription: String? {
    switch self {
    case .credentialsFailed(let m): return "AWS credentials failed: \(m)"
    case .uploadFailed(let m): return "S3 upload failed: \(m)"
    case .timeout(let jobId, let audioSeconds, let lastState, let timeoutMinutes):
      let secondsText = audioSeconds.map { String(format: "%.1f", Double($0)) } ?? "unknown"
      return "Diarization job \(jobId) timed out after \(timeoutMinutes) min; audioSeconds=\(secondsText), lastState=\(lastState ?? "unknown")"
    case .resultDecodeFailed(let jobId): return "Could not decode diarization result for job \(jobId)"
    case .backendFailed(let jobId, let state, let kind, let message):
      let detail = [kind, message].compactMap { $0 }.joined(separator: ": ")
      return detail.isEmpty
        ? "Diarization job \(jobId) failed with state \(state)"
        : "Diarization job \(jobId) failed with state \(state): \(detail)"
    case .emptyAudioFile: return "Recorded audio was empty; skipping diarization upload"
    }
  }
}

// Orchestrates the cloud diarization job:
//   upload WAV → upload job spec (S3 event triggers Lambda → EC2) → poll S3 for result.
actor CloudDiarizationService {
  private static let lifecycleLambdaFunctionName = "DiarizenStartEC2"
  private let bucket         = "meta-glasses-transcribe-620969609288"
  private let s3Region       = "us-west-1"
  private let cognitoRegion  = "us-west-1"
  private let identityPoolId = "us-west-1:1166ae70-5652-4a7b-b045-66fdaf6e1efb"
  private let accountId      = "620969609288"
  private let pollIntervalSeconds: UInt64 = 10
  private let pollAttemptCount = 360

  private var cachedCredentials: CloudAWSCredentials?
  private var cognitoIdentityId: String?
  private let lifecycleClient = AWSCognitoLambdaClient()

  // MARK: - Public API

  func submitJob(audioFileURL: URL, streamStart: Date, conversationSessionId: UUID? = nil) async throws -> DiarizenResult {
    let jobId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    AppLogger.log(.cloudDiarization, "submit jobId=\(jobId) conversationSessionId=\(conversationSessionId?.uuidString ?? "none")")
    let creds = try await getCredentials()
    let audioStats = try validateAudioFileForUpload(audioFileURL)

    // 1. Upload session audio
    let audioKey = "diarizen/audio/\(jobId).wav"
    let specKey = "diarizen/jobs/\(jobId)/spec.json"
    let statusKey = "diarizen/jobs/\(jobId)/status.json"
    let errorKey = "diarizen/jobs/\(jobId)/error.json"
    let pendingKey = "diarizen/jobs/pending.json"
    let resultKey = "diarizen/results/\(jobId)/result.json"
    let audioData = try Data(contentsOf: audioFileURL)
    try await s3Put(data: audioData, key: audioKey, contentType: "audio/wav", creds: creds)
    AppLogger.log(
      .cloudDiarization,
      "audio uploaded jobId=\(jobId) key=\(audioKey) bytes=\(audioData.count) seconds=\(String(format: "%.2f", Double(audioStats.seconds))) frames=\(audioStats.frames)"
    )

    // 2. Upload durable job metadata plus the legacy trigger key consumed by the
    // current EC2 worker. The per-job spec/status keys make overwritten
    // pending.json failures diagnosable and recoverable by a newer worker.
    let createdAt = Self.iso8601(Date())
    let spec = DiarizenJobSpec(
      jobId: jobId,
      audioKey: audioKey,
      streamStartUnix: streamStart.timeIntervalSince1970,
      resultKey: resultKey,
      statusKey: statusKey,
      errorKey: errorKey,
      conversationSessionId: conversationSessionId?.uuidString,
      audioDurationSeconds: audioStats.seconds,
      audioByteCount: audioData.count,
      createdAt: createdAt
    )
    let specData = try JSONEncoder().encode(spec)
    try await s3Put(data: specData, key: specKey, contentType: "application/json", creds: creds)
    let queued = DiarizenJobStatus(
      jobId: jobId,
      state: "queued",
      audioKey: audioKey,
      resultKey: resultKey,
      statusKey: statusKey,
      conversationSessionId: conversationSessionId?.uuidString,
      audioDurationSeconds: audioStats.seconds,
      audioByteCount: audioData.count,
      createdAt: createdAt,
      startedAt: nil,
      finishedAt: nil,
      failedAt: nil,
      updatedAt: createdAt,
      lambdaRequestId: nil,
      workerHostname: nil,
      workerProcessId: nil,
      errorKind: nil,
      errorMessage: nil,
      instanceState: nil,
      publicIp: nil,
      privateIp: nil
    )
    try await s3Put(data: try JSONEncoder().encode(queued), key: statusKey, contentType: "application/json", creds: creds)
    try await s3Put(data: specData, key: pendingKey, contentType: "application/json", creds: creds)
    AppLogger.log(
      .cloudDiarization,
      "job trigger uploaded jobId=\(jobId) specKey=\(specKey) statusKey=\(statusKey) pendingKey=\(pendingKey) resultKey=\(resultKey)"
    )

    // 3. Poll S3 for result (10 s interval, up to 60 min).
    // S3 PUT on diarizen/jobs/pending.json triggers DiarizenStartEC2 Lambda,
    // which starts the EC2 worker if stopped. The worker polls S3 and processes
    // any pending job.
    let result = try await pollForResult(
      resultKey: resultKey,
      statusKey: statusKey,
      jobId: jobId,
      audioSeconds: audioStats.seconds,
      creds: creds
    )
    await stopComputeAfterCompletion(jobId: jobId)
    return result
  }

  func downloadSpeakerClip(s3Key: String) async throws -> Data {
    let creds = try await getCredentials()
    return try await s3Get(key: s3Key, creds: creds)
  }

  private func stopComputeAfterCompletion(jobId: String) async {
    do {
      let response = try await lifecycleClient.invokeLambda(
        functionName: Self.lifecycleLambdaFunctionName,
        payload: [
          "action": "stopAfterDiarizationComplete",
          "jobId": jobId,
        ]
      )
      AppLogger.log(
        .cloudDiarization,
        "shutdown requested jobId=\(jobId) action=\(response.action ?? "unknown") instanceState=\(response.state ?? "unknown") speakerLease=\(response.liveSessionId ?? "none") faceLease=\(response.liveFaceSessionId ?? "none")"
      )
    } catch {
      AppLogger.log(
        .cloudDiarization,
        "shutdown request failed jobId=\(jobId) error=\(error.localizedDescription); delayed Lambda watchdog remains active"
      )
    }
  }

  private func validateAudioFileForUpload(_ url: URL) throws -> (frames: AVAudioFramePosition, seconds: Double) {
    let file = try AVAudioFile(forReading: url)
    let frames = file.length
    let sampleRate = file.processingFormat.sampleRate
    let seconds = sampleRate > 0 ? Double(frames) / sampleRate : 0
    guard frames > 0, seconds > 0 else {
      AppLogger.log(.audio, "[CloudDiarization] Refusing to upload empty audio file=\(url.lastPathComponent) frames=\(frames) sampleRate=\(sampleRate)")
      throw CloudDiarizationError.emptyAudioFile
    }
    return (frames, seconds)
  }

  // MARK: - S3

  private func s3Put(data: Data, key: String, contentType: String, creds: CloudAWSCredentials) async throws {
    let url = URL(string: "https://\(bucket).s3.\(s3Region).amazonaws.com/\(key)")!
    var req = URLRequest(url: url)
    req.httpMethod = "PUT"
    req.setValue(contentType, forHTTPHeaderField: "Content-Type")
    req.httpBody = data
    try signRequest(&req, service: "s3", region: s3Region, creds: creds, body: data)
    let (_, resp) = try await URLSession.shared.data(for: req)
    guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      throw CloudDiarizationError.uploadFailed("PUT \(key) HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
    }
  }

  private func s3Get(key: String, creds: CloudAWSCredentials) async throws -> Data {
    let url = URL(string: "https://\(bucket).s3.\(s3Region).amazonaws.com/\(key)")!
    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    try signRequest(&req, service: "s3", region: s3Region, creds: creds, body: Data())
    let (data, resp) = try await URLSession.shared.data(for: req)
    guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      throw CloudDiarizationError.uploadFailed("GET \(key) HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
    }
    return data
  }

  private func s3Exists(key: String, creds: CloudAWSCredentials) async -> Bool {
    let url = URL(string: "https://\(bucket).s3.\(s3Region).amazonaws.com/\(key)")!
    var req = URLRequest(url: url)
    req.httpMethod = "HEAD"
    try? signRequest(&req, service: "s3", region: s3Region, creds: creds, body: Data())
    guard let (_, resp) = try? await URLSession.shared.data(for: req),
          let http = resp as? HTTPURLResponse else { return false }
    return http.statusCode == 200
  }

  private func pollForResult(
    resultKey: String,
    statusKey: String,
    jobId: String,
    audioSeconds: Double?,
    creds: CloudAWSCredentials
  ) async throws -> DiarizenResult {
    var lastState: String?
    for attempt in 0..<pollAttemptCount {
      if attempt > 0 { try await Task.sleep(nanoseconds: pollIntervalSeconds * 1_000_000_000) }
      let resultExists = await s3Exists(key: resultKey, creds: creds)
      if let status = await s3StatusIfPresent(key: statusKey, creds: creds) {
        lastState = status.state
        AppLogger.log(
          .cloudDiarization,
          "poll jobId=\(jobId) attempt=\(attempt + 1)/\(pollAttemptCount) state=\(status.state) instanceState=\(status.instanceState ?? "unknown") resultKey=\(resultKey)"
        )
        if Self.shouldTreatDiarizationStatusAsTerminalFailure(statusState: status.state, resultExists: resultExists) {
          throw CloudDiarizationError.backendFailed(
            jobId: jobId,
            state: status.state,
            kind: status.errorKind,
            message: status.errorMessage
          )
        }
      } else {
        AppLogger.log(.cloudDiarization, "poll jobId=\(jobId) attempt=\(attempt + 1)/\(pollAttemptCount) state=missingStatus resultKey=\(resultKey)")
      }
      guard resultExists else {
        continue
      }
      let data = try await s3Get(key: resultKey, creds: creds)
      guard let result = try? JSONDecoder().decode(DiarizenResult.self, from: data) else {
        throw CloudDiarizationError.resultDecodeFailed(jobId)
      }
      AppLogger.log(
        .cloudDiarization,
        "result received jobId=\(jobId) speakers=\(result.speakerCount) segments=\(result.segments.count) resultBytes=\(data.count)"
      )
      return result
    }
    let timeoutMinutes = Int((pollIntervalSeconds * UInt64(pollAttemptCount)) / 60)
    throw CloudDiarizationError.timeout(
      jobId: jobId,
      audioSeconds: audioSeconds,
      lastState: lastState,
      timeoutMinutes: timeoutMinutes
    )
  }

  nonisolated static func shouldTreatDiarizationStatusAsTerminalFailure(statusState: String, resultExists: Bool) -> Bool {
    statusState == "failed" && !resultExists
  }

  private func s3StatusIfPresent(key: String, creds: CloudAWSCredentials) async -> DiarizenJobStatus? {
    guard let data = try? await s3Get(key: key, creds: creds) else { return nil }
    return try? JSONDecoder().decode(DiarizenJobStatus.self, from: data)
  }

  // MARK: - Cognito credentials

  private func getCredentials() async throws -> CloudAWSCredentials {
    if let c = cachedCredentials, !c.isExpired { return c }
    let identityId = try await fetchIdentityId()
    var req = URLRequest(url: URL(string: "https://cognito-identity.\(cognitoRegion).amazonaws.com/")!)
    req.httpMethod = "POST"
    req.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
    req.setValue("AWSCognitoIdentityService.GetCredentialsForIdentity", forHTTPHeaderField: "X-Amz-Target")
    req.httpBody = try JSONSerialization.data(withJSONObject: ["IdentityId": identityId])
    let (data, _) = try await URLSession.shared.data(for: req)
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let credDict = json["Credentials"] as? [String: Any],
          let accessKey = credDict["AccessKeyId"] as? String,
          let secretKey = credDict["SecretKey"] as? String,
          let token = credDict["SessionToken"] as? String else {
      throw CloudDiarizationError.credentialsFailed(String(data: data, encoding: .utf8) ?? "")
    }
    let expiration: Date
    if let exp = credDict["Expiration"] as? Double { expiration = Date(timeIntervalSince1970: exp) }
    else { expiration = Date().addingTimeInterval(3600) }
    let creds = CloudAWSCredentials(accessKeyId: accessKey, secretKey: secretKey, sessionToken: token, expiration: expiration)
    cachedCredentials = creds
    return creds
  }

  private func fetchIdentityId() async throws -> String {
    if let id = cognitoIdentityId { return id }
    var req = URLRequest(url: URL(string: "https://cognito-identity.\(cognitoRegion).amazonaws.com/")!)
    req.httpMethod = "POST"
    req.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
    req.setValue("AWSCognitoIdentityService.GetId", forHTTPHeaderField: "X-Amz-Target")
    req.httpBody = try JSONSerialization.data(withJSONObject: ["AccountId": accountId, "IdentityPoolId": identityPoolId])
    let (data, _) = try await URLSession.shared.data(for: req)
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let id = json["IdentityId"] as? String else {
      throw CloudDiarizationError.credentialsFailed("GetId failed")
    }
    cognitoIdentityId = id
    return id
  }

  // MARK: - AWS SigV4

  private func signRequest(_ request: inout URLRequest, service: String, region: String,
                           creds: CloudAWSCredentials, body: Data) throws {
    let now = Date()
    let amzDate  = Self.awsDate(from: now)
    let dateStamp = String(amzDate.prefix(8))
    let url  = request.url!
    let host = url.host!

    request.setValue(host, forHTTPHeaderField: "Host")
    request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
    request.setValue(creds.sessionToken, forHTTPHeaderField: "X-Amz-Security-Token")
    let bodyHash = Self.sha256Hex(body)
    request.setValue(bodyHash, forHTTPHeaderField: "X-Amz-Content-Sha256")

    let headers = request.allHTTPHeaderFields ?? [:]
    let signedSet = Set(headers.keys.map { $0.lowercased() })
    let canonicalHeaders = headers
      .sorted { $0.key.lowercased() < $1.key.lowercased() }
      .filter { signedSet.contains($0.key.lowercased()) }
      .map { "\($0.key.lowercased()):\($0.value.trimmingCharacters(in: .whitespaces))\n" }
      .joined()
    let signedHeadersStr = signedSet.sorted().joined(separator: ";")

    let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let canonicalQuery = queryItems
      .map { ($0.name.awsEncoded, $0.value?.awsEncoded ?? "") }
      .sorted { $0.0 < $1.0 }
      .map { "\($0.0)=\($0.1)" }
      .joined(separator: "&")

    let path = url.path.isEmpty ? "/" : url.path
    let canonicalReq = [request.httpMethod ?? "GET", path, canonicalQuery,
                        canonicalHeaders, signedHeadersStr, bodyHash].joined(separator: "\n")
    let credScope = "\(dateStamp)/\(region)/\(service)/aws4_request"
    let stringToSign = "AWS4-HMAC-SHA256\n\(amzDate)\n\(credScope)\n\(Self.sha256Hex(Data(canonicalReq.utf8)))"

    let sigKey = Self.signingKey(secret: creds.secretKey, dateStamp: dateStamp, region: region, service: service)
    let signature = Data(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: sigKey))
      .map { String(format: "%02x", $0) }.joined()

    request.setValue(
      "AWS4-HMAC-SHA256 Credential=\(creds.accessKeyId)/\(credScope), SignedHeaders=\(signedHeadersStr), Signature=\(signature)",
      forHTTPHeaderField: "Authorization"
    )
  }

  private static func signingKey(secret: String, dateStamp: String, region: String, service: String) -> SymmetricKey {
    let kDate    = Data(HMAC<SHA256>.authenticationCode(for: Data(dateStamp.utf8), using: SymmetricKey(data: Data(("AWS4" + secret).utf8))))
    let kRegion  = Data(HMAC<SHA256>.authenticationCode(for: Data(region.utf8),    using: SymmetricKey(data: kDate)))
    let kService = Data(HMAC<SHA256>.authenticationCode(for: Data(service.utf8),   using: SymmetricKey(data: kRegion)))
    let kSigning = Data(HMAC<SHA256>.authenticationCode(for: Data("aws4_request".utf8), using: SymmetricKey(data: kService)))
    return SymmetricKey(data: kSigning)
  }

  private static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func awsDate(from date: Date) -> String {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    return String(format: "%04d%02d%02dT%02d%02d%02dZ",
                  c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
  }

  private static func iso8601(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }
}

// MARK: - Credential type (private to this file)

private struct CloudAWSCredentials {
  let accessKeyId: String
  let secretKey: String
  let sessionToken: String
  let expiration: Date
  var isExpired: Bool { Date() >= expiration.addingTimeInterval(-60) }
}

private extension String {
  var awsEncoded: String {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
  }
}
