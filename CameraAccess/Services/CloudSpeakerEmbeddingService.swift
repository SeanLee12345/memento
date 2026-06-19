import Foundation

struct CloudSpeakerEmbeddingSettings {
  private enum Keys {
    static let enabled = "cloudSpeakerEmbedding.enabled"
    static let endpoint = "cloudSpeakerEmbedding.endpoint"
    static let apiKey = "cloudSpeakerEmbedding.apiKey"
    static let lambdaFunctionName = "cloudSpeakerEmbedding.lambdaFunctionName"
    static let workerPort = "cloudSpeakerEmbedding.workerPort"
    static let useEC2Lifecycle = "cloudSpeakerEmbedding.useEC2Lifecycle"
    static let stopOnStreamEnd = "cloudSpeakerEmbedding.stopOnStreamEnd"
  }

  static let defaultEndpoint = ""
  static let defaultAPIKey = ""
  static let defaultLambdaFunctionName = "DiarizenStartEC2"
  static let defaultRegion = "us-west-1"
  static let defaultWorkerPort = 8090

  var enabled: Bool
  var endpoint: String
  var apiKey: String
  var lambdaFunctionName: String
  var workerPort: Int
  var useEC2Lifecycle: Bool
  var stopOnStreamEnd: Bool

  static func load() -> CloudSpeakerEmbeddingSettings {
    let defaults = UserDefaults.standard
    let savedPort = defaults.integer(forKey: Keys.workerPort)
    let savedAPIKey = defaults.string(forKey: Keys.apiKey)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let useEC2Lifecycle = defaults.object(forKey: Keys.useEC2Lifecycle) as? Bool ?? true
    let savedEndpoint = defaults.string(forKey: Keys.endpoint) ?? defaultEndpoint
    return CloudSpeakerEmbeddingSettings(
      enabled: defaults.bool(forKey: Keys.enabled),
      endpoint: useEC2Lifecycle ? defaultEndpoint : savedEndpoint,
      apiKey: savedAPIKey.isEmpty ? defaultAPIKey : savedAPIKey,
      lambdaFunctionName: defaults.string(forKey: Keys.lambdaFunctionName) ?? defaultLambdaFunctionName,
      workerPort: savedPort > 0 ? savedPort : defaultWorkerPort,
      useEC2Lifecycle: useEC2Lifecycle,
      stopOnStreamEnd: defaults.object(forKey: Keys.stopOnStreamEnd) as? Bool ?? true
    )
  }

  func save() {
    let defaults = UserDefaults.standard
    defaults.set(enabled, forKey: Keys.enabled)
    defaults.set(endpoint.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.endpoint)
    defaults.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.apiKey)
    defaults.set(lambdaFunctionName.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.lambdaFunctionName)
    defaults.set(workerPort, forKey: Keys.workerPort)
    defaults.set(useEC2Lifecycle, forKey: Keys.useEC2Lifecycle)
    defaults.set(stopOnStreamEnd, forKey: Keys.stopOnStreamEnd)
  }
}

enum CloudSpeakerEmbeddingLifecycleError: LocalizedError {
  case disabled
  case invalidEndpoint
  case lambdaInvokeFailed(String)
  case lambdaResponseInvalid(String)
  case workerNotReady(String)
  case credentialsFailed(String)

  var errorDescription: String? {
    switch self {
    case .disabled:
      return "AWS live speaker embeddings are disabled."
    case .invalidEndpoint:
      return "AWS live speaker embedding endpoint is invalid."
    case .lambdaInvokeFailed(let message):
      return "AWS live speaker lifecycle Lambda failed: \(message)"
    case .lambdaResponseInvalid(let message):
      return "AWS live speaker lifecycle response is invalid: \(message)"
    case .workerNotReady(let message):
      return "AWS live speaker worker did not become ready: \(message)"
    case .credentialsFailed(let message):
      return "AWS credentials failed: \(message)"
    }
  }
}

struct CloudSpeakerWorkerStartResult {
  let endpoint: String
  let apiKey: String
  let publicIp: String?
  let privateIp: String?
  let healthStatus: String
  let liveSessionId: String?
  let liveExpiresAt: String?
}

actor CloudSpeakerEmbeddingLifecycleService {
  nonisolated static func workerHealthRetryDelaySeconds(attempt: Int) -> TimeInterval {
    switch attempt {
    case ...1: return 0
    case 2: return 5
    case 3: return 10
    default: return 20
    }
  }

  nonisolated static func workerHealthRetryCadenceText(maxAttempts: Int) -> String {
    "5/10/20s capped maxAttempts=\(maxAttempts)"
  }

  private let lambda: AWSCognitoLambdaClient
  private var liveStartRequested = false
  private var startedLiveWorker = false
  private var activeLambdaFunctionName: String?
  private var activeUseEC2Lifecycle = false
  private var activeStopOnStreamEnd = false
  private var activeLiveSessionId: String?
  private var lastEndpoint: String?

  init(lambda: AWSCognitoLambdaClient = AWSCognitoLambdaClient(region: CloudSpeakerEmbeddingSettings.defaultRegion)) {
    self.lambda = lambda
  }

  func startAndWarm(
    settings: CloudSpeakerEmbeddingSettings,
    maxHealthAttempts: Int = 24
  ) async throws -> CloudSpeakerWorkerStartResult {
    guard settings.enabled else { throw CloudSpeakerEmbeddingLifecycleError.disabled }

    var publicIp: String?
    var privateIp: String?
    var liveExpiresAt: String?
    var endpoint = settings.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)

    if settings.useEC2Lifecycle {
      let liveSessionId = UUID().uuidString
      liveStartRequested = true
      activeLambdaFunctionName = settings.lambdaFunctionName
      activeUseEC2Lifecycle = true
      activeStopOnStreamEnd = settings.stopOnStreamEnd
      activeLiveSessionId = liveSessionId
      let response = try await invokeLifecycle(
        functionName: settings.lambdaFunctionName,
        payload: ["action": "startLive", "sessionId": liveSessionId]
      )
      publicIp = response.publicIp
      privateIp = response.privateIp
      liveExpiresAt = response.liveExpiresAt
      startedLiveWorker = true
      if endpoint.isEmpty {
        let resolved = try await waitForLivePublicIP(
          functionName: settings.lambdaFunctionName,
          initialPublicIp: publicIp
        )
        publicIp = resolved.publicIp
        privateIp = resolved.privateIp ?? privateIp
        guard let publicIp, !publicIp.isEmpty else {
          throw CloudSpeakerEmbeddingLifecycleError.lambdaResponseInvalid("missing publicIp and no endpoint override configured")
        }
        endpoint = "http://\(publicIp):\(settings.workerPort)"
      }
    }

    guard let endpointURL = URL(string: endpoint), endpointURL.scheme != nil, endpointURL.host != nil else {
      throw CloudSpeakerEmbeddingLifecycleError.invalidEndpoint
    }
    lastEndpoint = endpoint
    let workerAPIKey = await workerAuthorizationToken(
      worker: "speaker",
      endpoint: endpoint,
      fallbackAPIKey: settings.apiKey
    )
    let health = try await waitForWorkerHealth(
      endpoint: endpoint,
      apiKey: workerAPIKey,
      maxAttempts: maxHealthAttempts
    )
    return CloudSpeakerWorkerStartResult(
      endpoint: endpoint,
      apiKey: workerAPIKey,
      publicIp: publicIp,
      privateIp: privateIp,
      healthStatus: health,
      liveSessionId: activeLiveSessionId,
      liveExpiresAt: liveExpiresAt
    )
  }

  func stopIfNeeded(settings: CloudSpeakerEmbeddingSettings) async {
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
        payload: ["action": "releaseLiveAndMaybeStop", "service": "speaker"]
      )
      let stoppedNow = response.action == "stoppedLive" || response.state?.lowercased() == "stopping" || response.state?.lowercased() == "stopped"
      AppLogger.log(
        .speakerEmbeddingModel,
        "AWS live speaker lease released; EC2 stopped=\(stoppedNow) state=\(response.state ?? "unknown") endpoint=\(lastEndpoint ?? "none")"
      )
    } catch {
      AppLogger.log(.speakerEmbeddingModel, "AWS live speaker lease release failed: \(error.localizedDescription)")
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
          payload: ["action": "releaseLive"]
        )
        AppLogger.log(.speakerEmbeddingModel, "AWS live speaker EC2 released for post-session diarization reason=\(reason) endpoint=\(endpoint)")
      } catch {
        AppLogger.log(.speakerEmbeddingModel, "AWS live speaker EC2 release failed; leaving instance for diarization reason=\(reason) endpoint=\(endpoint) error=\(error.localizedDescription)")
      }
    } else {
      AppLogger.log(.speakerEmbeddingModel, "AWS live speaker EC2 left running for post-session diarization reason=\(reason) endpoint=\(endpoint)")
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
        payload: ["action": "refreshLive", "sessionId": liveSessionId]
      )
      AppLogger.log(
        .speakerEmbeddingModel,
        "AWS live speaker lease refreshed session=\(liveSessionId) expiresAt=\(response.liveExpiresAt ?? "unknown")"
      )
    } catch {
      AppLogger.log(.speakerEmbeddingModel, "AWS live speaker lease refresh failed: \(error.localizedDescription)")
    }
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
        AppLogger.log(.speakerEmbeddingModel, "AWS live speaker public IP ready attempt=\(attempt) publicIp=\(publicIp) state=\(response.state ?? "unknown")")
        return (publicIp, response.privateIp)
      }
      lastState = response.state ?? "unknown"
      try await Task.sleep(nanoseconds: 5_000_000_000)
    }
    throw CloudSpeakerEmbeddingLifecycleError.lambdaResponseInvalid("missing publicIp after polling instance state=\(lastState)")
  }

  private func waitForWorkerHealth(
    endpoint: String,
    apiKey: String,
    maxAttempts: Int
  ) async throws -> String {
    var lastError = "not attempted"
    let boundedAttempts = max(1, maxAttempts)
    let retryCadence = Self.workerHealthRetryCadenceText(maxAttempts: boundedAttempts)
    for attempt in 1...boundedAttempts {
      if attempt > 1 {
        try await Task.sleep(nanoseconds: UInt64(Self.workerHealthRetryDelaySeconds(attempt: attempt) * 1_000_000_000))
      }
      do {
        let text = try await requestWorkerHealth(endpoint: endpoint, apiKey: apiKey, timeout: 2)
        AppLogger.log(.speakerEmbeddingModel, "AWS live speaker worker ready attempt=\(attempt) endpoint=\(endpoint) health=\(text) retryCadence=\(retryCadence)")
        return text
      } catch {
        lastError = error.localizedDescription
      }
      let shouldLog = attempt <= 3 || attempt % 3 == 0 || attempt == boundedAttempts
      if shouldLog {
        AppLogger.log(
          .speakerEmbeddingModel,
          "AWS live speaker worker not ready attempt=\(attempt)/\(boundedAttempts) endpoint=\(endpoint) retryCadence=\(retryCadence) serviceStatus=speakerServiceWarming error=\(lastError)"
        )
      }
    }
    throw CloudSpeakerEmbeddingLifecycleError.workerNotReady(lastError)
  }

  private func requestWorkerHealth(endpoint: String, apiKey: String, timeout: TimeInterval) async throws -> String {
    guard var url = URL(string: endpoint) else {
      throw CloudSpeakerEmbeddingLifecycleError.invalidEndpoint
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
      throw CloudSpeakerEmbeddingLifecycleError.workerNotReady("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
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
      AppLogger.log(.speakerEmbeddingModel, "AWS \(worker) worker session token minted via Supabase Edge expiresIn=\(response.expiresIn)s")
      return response.token
    } catch {
      AppLogger.log(.speakerEmbeddingModel, "AWS \(worker) worker session token failed; using configured fallback key: \(error.localizedDescription)")
      return fallbackAPIKey
    }
  }

  private func invokeLifecycle(functionName: String, payload: [String: String]) async throws -> AWSCognitoLambdaClient.LifecycleResponse {
    do {
      return try await lambda.invokeLambda(functionName: functionName, payload: payload)
    } catch let error as AWSCognitoLambdaClient.LambdaError {
      switch error {
      case .invalidFunctionName, .invalidLambdaURL:
        throw CloudSpeakerEmbeddingLifecycleError.lambdaResponseInvalid(error.localizedDescription)
      case .missingHTTPResponse, .invokeFailed:
        throw CloudSpeakerEmbeddingLifecycleError.lambdaInvokeFailed(error.localizedDescription)
      case .credentialsFailed(let message):
        throw CloudSpeakerEmbeddingLifecycleError.credentialsFailed(message)
      }
    }
  }
}
