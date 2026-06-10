import Foundation

// Settings for the AWS AdaFace face embedding worker. The face worker shares
// the same EC2 instance and Lambda lifecycle controller as the speaker worker,
// but runs on its own port and uses a separate live-session tag namespace so
// the Lambda can decide when it is safe to stop EC2.
struct CloudFaceEmbeddingLifecycleSettings {
  private enum Keys {
    static let workerPort = "cloudFaceEmbedding.workerPort"
    static let lambdaFunctionName = "cloudFaceEmbedding.lambdaFunctionName"
    static let useEC2Lifecycle = "cloudFaceEmbedding.useEC2Lifecycle"
    static let stopOnStreamEnd = "cloudFaceEmbedding.stopOnStreamEnd"
  }

  static let defaultLambdaFunctionName = "DiarizenStartEC2"
  static let defaultRegion = "us-west-1"
  static let defaultWorkerPort = 8080
  static let defaultAPIKey = ""

  var enabled: Bool
  var endpointOverride: String
  var apiKey: String
  var lambdaFunctionName: String
  var workerPort: Int
  var useEC2Lifecycle: Bool
  var stopOnStreamEnd: Bool

  static func load() -> CloudFaceEmbeddingLifecycleSettings {
    let defaults = UserDefaults.standard
    let base = CloudFaceEmbeddingSettings.load()
    let useEC2 = defaults.object(forKey: Keys.useEC2Lifecycle) as? Bool ?? true
    let stop = defaults.object(forKey: Keys.stopOnStreamEnd) as? Bool ?? true
    let port = defaults.integer(forKey: Keys.workerPort)
    let lambdaName = defaults.string(forKey: Keys.lambdaFunctionName)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return CloudFaceEmbeddingLifecycleSettings(
      enabled: base.enabled,
      endpointOverride: useEC2 ? "" : base.endpoint,
      apiKey: base.apiKey.isEmpty ? defaultAPIKey : base.apiKey,
      lambdaFunctionName: lambdaName.isEmpty ? defaultLambdaFunctionName : lambdaName,
      workerPort: port > 0 ? port : defaultWorkerPort,
      useEC2Lifecycle: useEC2,
      stopOnStreamEnd: stop
    )
  }

  func save() {
    let defaults = UserDefaults.standard
    defaults.set(workerPort, forKey: Keys.workerPort)
    defaults.set(lambdaFunctionName.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.lambdaFunctionName)
    defaults.set(useEC2Lifecycle, forKey: Keys.useEC2Lifecycle)
    defaults.set(stopOnStreamEnd, forKey: Keys.stopOnStreamEnd)
  }
}

enum CloudFaceEmbeddingLifecycleError: LocalizedError {
  case disabled
  case invalidEndpoint
  case lambdaInvokeFailed(String)
  case lambdaResponseInvalid(String)
  case workerNotReady(String)
  case credentialsFailed(String)

  var errorDescription: String? {
    switch self {
    case .disabled: return "AWS face embeddings are disabled."
    case .invalidEndpoint: return "AWS face embedding endpoint is invalid."
    case .lambdaInvokeFailed(let message): return "AWS face lifecycle Lambda failed: \(message)"
    case .lambdaResponseInvalid(let message): return "AWS face lifecycle response is invalid: \(message)"
    case .workerNotReady(let message): return "AWS face worker did not become ready: \(message)"
    case .credentialsFailed(let message): return "AWS credentials failed: \(message)"
    }
  }
}

struct CloudFaceWorkerStartResult {
  let endpoint: String
  let apiKey: String
  let publicIp: String?
  let privateIp: String?
  let healthStatus: String
  let liveSessionId: String?
  let liveExpiresAt: String?
}

struct CloudFaceWorkerLeaseStartResult {
  let endpoint: String?
  let apiKey: String
  let publicIp: String?
  let privateIp: String?
  let liveSessionId: String?
  let liveExpiresAt: String?
}

actor CloudFaceEmbeddingLifecycleService {
  private let lambda: AWSCognitoLambdaClient
  private var liveStartRequested = false
  private var startedLiveWorker = false
  private var activeLambdaFunctionName: String?
  private var activeUseEC2Lifecycle = false
  private var activeStopOnStreamEnd = false
  private var activeLiveSessionId: String?
  private var lastEndpoint: String?

  init(lambda: AWSCognitoLambdaClient = AWSCognitoLambdaClient(region: CloudFaceEmbeddingLifecycleSettings.defaultRegion)) {
    self.lambda = lambda
  }

  func startAndWarm(settings: CloudFaceEmbeddingLifecycleSettings) async throws -> CloudFaceWorkerStartResult {
    guard settings.enabled else { throw CloudFaceEmbeddingLifecycleError.disabled }

    var publicIp: String?
    var privateIp: String?
    var liveExpiresAt: String?
    var endpoint = settings.endpointOverride.trimmingCharacters(in: .whitespacesAndNewlines)

    if settings.useEC2Lifecycle {
      let liveSessionId = UUID().uuidString
      liveStartRequested = true
      activeLambdaFunctionName = settings.lambdaFunctionName
      activeUseEC2Lifecycle = true
      activeStopOnStreamEnd = settings.stopOnStreamEnd
      activeLiveSessionId = liveSessionId
      let response = try await invokeLifecycle(
        functionName: settings.lambdaFunctionName,
        payload: ["action": "startLiveFace", "sessionId": liveSessionId]
      )
      publicIp = response.publicIp
      privateIp = response.privateIp
      liveExpiresAt = response.liveFaceExpiresAt ?? response.liveExpiresAt
      startedLiveWorker = true
      if endpoint.isEmpty {
        let resolved = try await waitForLivePublicIP(
          functionName: settings.lambdaFunctionName,
          initialPublicIp: publicIp
        )
        publicIp = resolved.publicIp
        privateIp = resolved.privateIp ?? privateIp
        guard let publicIp, !publicIp.isEmpty else {
          throw CloudFaceEmbeddingLifecycleError.lambdaResponseInvalid("missing publicIp and no endpoint override configured")
        }
        endpoint = "http://\(publicIp):\(settings.workerPort)"
      }
    }

    guard let endpointURL = URL(string: endpoint), endpointURL.scheme != nil, endpointURL.host != nil else {
      throw CloudFaceEmbeddingLifecycleError.invalidEndpoint
    }
    lastEndpoint = endpoint
    let workerAPIKey = await workerAuthorizationToken(
      worker: "face",
      endpoint: endpoint,
      fallbackAPIKey: settings.apiKey
    )
    let health = try await waitForWorkerHealth(endpoint: endpoint, apiKey: workerAPIKey)
    return CloudFaceWorkerStartResult(
      endpoint: endpoint,
      apiKey: workerAPIKey,
      publicIp: publicIp,
      privateIp: privateIp,
      healthStatus: health,
      liveSessionId: activeLiveSessionId,
      liveExpiresAt: liveExpiresAt
    )
  }

  func startLeaseOnly(settings: CloudFaceEmbeddingLifecycleSettings) async throws -> CloudFaceWorkerLeaseStartResult {
    guard settings.enabled else { throw CloudFaceEmbeddingLifecycleError.disabled }

    var publicIp: String?
    var privateIp: String?
    var liveExpiresAt: String?
    var endpoint = settings.endpointOverride.trimmingCharacters(in: .whitespacesAndNewlines)

    if settings.useEC2Lifecycle {
      let liveSessionId = UUID().uuidString
      liveStartRequested = true
      activeLambdaFunctionName = settings.lambdaFunctionName
      activeUseEC2Lifecycle = true
      activeStopOnStreamEnd = settings.stopOnStreamEnd
      activeLiveSessionId = liveSessionId
      let response = try await invokeLifecycle(
        functionName: settings.lambdaFunctionName,
        payload: ["action": "startLiveFace", "sessionId": liveSessionId]
      )
      publicIp = response.publicIp
      privateIp = response.privateIp
      liveExpiresAt = response.liveFaceExpiresAt ?? response.liveExpiresAt
      startedLiveWorker = true
      if endpoint.isEmpty, let publicIp, !publicIp.isEmpty {
        endpoint = "http://\(publicIp):\(settings.workerPort)"
      }
    }

    if !endpoint.isEmpty {
      guard let endpointURL = URL(string: endpoint), endpointURL.scheme != nil, endpointURL.host != nil else {
        throw CloudFaceEmbeddingLifecycleError.invalidEndpoint
      }
      lastEndpoint = endpoint
    }

    return CloudFaceWorkerLeaseStartResult(
      endpoint: endpoint.isEmpty ? nil : endpoint,
      apiKey: await workerAuthorizationToken(
        worker: "face",
        endpoint: endpoint,
        fallbackAPIKey: settings.apiKey
      ),
      publicIp: publicIp,
      privateIp: privateIp,
      liveSessionId: activeLiveSessionId,
      liveExpiresAt: liveExpiresAt
    )
  }

  func stopIfNeeded(settings: CloudFaceEmbeddingLifecycleSettings) async {
    guard activeUseEC2Lifecycle, activeStopOnStreamEnd else { return }
    guard liveStartRequested || startedLiveWorker else { return }
    liveStartRequested = false
    startedLiveWorker = false
    activeUseEC2Lifecycle = false
    activeStopOnStreamEnd = false
    let functionName = activeLambdaFunctionName ?? settings.lambdaFunctionName
    activeLambdaFunctionName = nil
    activeLiveSessionId = nil
    do {
      let response = try await invokeLifecycle(
        functionName: functionName,
        payload: ["action": "releaseLiveAndMaybeStop", "service": "face"]
      )
      let stoppedNow = response.action == "stoppedLive" || response.state?.lowercased() == "stopping" || response.state?.lowercased() == "stopped"
      AppLogger.log(
        .faceEmbeddingModel,
        "AWS live face lease released; EC2 stopped=\(stoppedNow) state=\(response.state ?? "unknown") endpoint=\(lastEndpoint ?? "none")"
      )
    } catch {
      AppLogger.log(.faceEmbeddingModel, "AWS live face lease release failed: \(error.localizedDescription)")
    }
  }

  func releaseLiveSessionWithoutStopping(reason: String) async {
    guard activeUseEC2Lifecycle else { return }
    let endpoint = lastEndpoint ?? "none"
    let functionName = activeLambdaFunctionName
    liveStartRequested = false
    startedLiveWorker = false
    activeUseEC2Lifecycle = false
    activeStopOnStreamEnd = false
    activeLambdaFunctionName = nil
    activeLiveSessionId = nil
    if let functionName {
      do {
        _ = try await invokeLifecycle(
          functionName: functionName,
          payload: ["action": "releaseLiveFace"]
        )
        AppLogger.log(.faceEmbeddingModel, "AWS live face EC2 released reason=\(reason) endpoint=\(endpoint)")
      } catch {
        AppLogger.log(.faceEmbeddingModel, "AWS live face EC2 release failed reason=\(reason) endpoint=\(endpoint) error=\(error.localizedDescription)")
      }
    } else {
      AppLogger.log(.faceEmbeddingModel, "AWS live face EC2 left running reason=\(reason) endpoint=\(endpoint)")
    }
  }

  func refreshLiveLeaseIfNeeded() async {
    guard activeUseEC2Lifecycle,
          liveStartRequested || startedLiveWorker,
          let functionName = activeLambdaFunctionName,
          let liveSessionId = activeLiveSessionId else {
      return
    }
    do {
      let response = try await invokeLifecycle(
        functionName: functionName,
        payload: ["action": "refreshLiveFace", "sessionId": liveSessionId]
      )
      AppLogger.log(
        .faceEmbeddingModel,
        "AWS live face lease refreshed session=\(liveSessionId) expiresAt=\(response.liveFaceExpiresAt ?? "unknown")"
      )
    } catch {
      AppLogger.log(.faceEmbeddingModel, "AWS live face lease refresh failed: \(error.localizedDescription)")
    }
  }

  func checkWorkerHealthOnce(endpoint: String, apiKey: String, timeout: TimeInterval = 2) async throws -> String {
    try await requestWorkerHealth(endpoint: endpoint, apiKey: apiKey, timeout: timeout)
  }

  func waitForWorkerHealth(endpoint: String, apiKey: String) async throws -> String {
    var lastError = "not attempted"
    for attempt in 1...24 {
      do {
        let text = try await requestWorkerHealth(endpoint: endpoint, apiKey: apiKey, timeout: 5)
        AppLogger.log(.faceEmbeddingModel, "AWS live face worker ready attempt=\(attempt) endpoint=\(endpoint) health=\(text)")
        return text
      } catch {
        lastError = error.localizedDescription
      }
      AppLogger.log(
        .faceEmbeddingModel,
        "AWS live face worker not ready attempt=\(attempt)/24 endpoint=\(endpoint) error=\(lastError)"
      )
      try await Task.sleep(nanoseconds: 3_000_000_000)
    }
    throw CloudFaceEmbeddingLifecycleError.workerNotReady(lastError)
  }

  private func waitForLivePublicIP(functionName: String, initialPublicIp: String?) async throws -> (publicIp: String?, privateIp: String?) {
    if let initialPublicIp, !initialPublicIp.isEmpty {
      return (initialPublicIp, nil)
    }
    var lastState = "not attempted"
    for attempt in 1...36 {
      let response = try await invokeLifecycle(
        functionName: functionName,
        payload: ["action": "describeLive"]
      )
      if let publicIp = response.publicIp, !publicIp.isEmpty {
        AppLogger.log(.faceEmbeddingModel, "AWS live face public IP ready attempt=\(attempt) publicIp=\(publicIp) state=\(response.state ?? "unknown")")
        return (publicIp, response.privateIp)
      }
      lastState = response.state ?? "unknown"
      try await Task.sleep(nanoseconds: 5_000_000_000)
    }
    throw CloudFaceEmbeddingLifecycleError.lambdaResponseInvalid("missing publicIp after polling instance state=\(lastState)")
  }

  private func requestWorkerHealth(endpoint: String, apiKey: String, timeout: TimeInterval) async throws -> String {
    guard var url = URL(string: endpoint) else {
      throw CloudFaceEmbeddingLifecycleError.invalidEndpoint
    }
    url.appendPathComponent("health")
    var request = URLRequest(url: url)
    request.timeoutInterval = timeout
    let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedKey.isEmpty {
      request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw CloudFaceEmbeddingLifecycleError.workerNotReady("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
    }
    return String(data: data, encoding: .utf8) ?? "ok"
  }

  private func workerAuthorizationToken(
    worker: String,
    endpoint: String,
    fallbackAPIKey: String
  ) async -> String {
    guard SupabaseEdgeFunctionClient.isConfigured() else {
      return fallbackAPIKey
    }
    do {
      let response = try await SupabaseEdgeFunctionClient.shared().workerSession(
        worker: worker,
        endpoint: endpoint,
        ttlSeconds: 1800
      )
      AppLogger.log(.faceEmbeddingModel, "AWS \(worker) worker session token minted via Supabase Edge expiresIn=\(response.expiresIn)s")
      return response.token
    } catch {
      AppLogger.log(.faceEmbeddingModel, "AWS \(worker) worker session token failed; using configured fallback key: \(error.localizedDescription)")
      return fallbackAPIKey
    }
  }

  private func invokeLifecycle(functionName: String, payload: [String: String]) async throws -> AWSCognitoLambdaClient.LifecycleResponse {
    do {
      return try await lambda.invokeLambda(functionName: functionName, payload: payload)
    } catch let error as AWSCognitoLambdaClient.LambdaError {
      switch error {
      case .invalidFunctionName, .invalidLambdaURL:
        throw CloudFaceEmbeddingLifecycleError.lambdaResponseInvalid(error.localizedDescription)
      case .missingHTTPResponse, .invokeFailed:
        throw CloudFaceEmbeddingLifecycleError.lambdaInvokeFailed(error.localizedDescription)
      case .credentialsFailed(let message):
        throw CloudFaceEmbeddingLifecycleError.credentialsFailed(message)
      }
    }
  }
}
