import Foundation

enum SceneContextClientError: LocalizedError {
  case missingAPIKey
  case invalidBaseURL
  case invalidResponse
  case badHTTPStatus(Int, String)
  case emptyContent
  case malformedJSON(String)

  var errorDescription: String? {
    switch self {
    case .missingAPIKey:
      "DashScope API key is missing"
    case .invalidBaseURL:
      "DashScope base URL is invalid"
    case .invalidResponse:
      "Scene context model returned an invalid response"
    case .badHTTPStatus(let status, let body):
      "Scene context model returned HTTP \(status): \(body)"
    case .emptyContent:
      "Scene context model returned no content"
    case .malformedJSON(let detail):
      "Scene context JSON could not be parsed: \(detail)"
    }
  }
}

private struct StreamSummaryParseResult {
  var analysis: StreamSummaryAnalysis
  var extractedJSON: Bool
  var repairedJSON: Bool
}

struct StreamSummaryRetryPolicy {
  var maxAttempts: Int
  var timeoutInterval: TimeInterval
  var retryDelays: [TimeInterval]

  static let production = StreamSummaryRetryPolicy(
    maxAttempts: 3,
    timeoutInterval: 45,
    retryDelays: [1.0, 3.0]
  )

  static let immediateRetry = StreamSummaryRetryPolicy(
    maxAttempts: 2,
    timeoutInterval: 45,
    retryDelays: [0]
  )

  var normalizedMaxAttempts: Int {
    max(1, maxAttempts)
  }

  func delay(beforeAttempt attempt: Int) -> TimeInterval {
    let index = max(0, attempt - 2)
    guard retryDelays.indices.contains(index) else { return 0 }
    return max(0, retryDelays[index])
  }
}

struct StreamSummaryLongInputPolicy {
  var targetPromptCharacters: Int
  var maxPromptCharacters: Int
  var estimatedCharactersPerToken: Int
  var forceChunkingForTesting: Bool

  static let production = StreamSummaryLongInputPolicy(
    targetPromptCharacters: 18_000,
    maxPromptCharacters: 24_000,
    estimatedCharactersPerToken: 4,
    forceChunkingForTesting: false
  )

  static let forcedChunkingForTesting = StreamSummaryLongInputPolicy(
    targetPromptCharacters: 3_000,
    maxPromptCharacters: 4_500,
    estimatedCharactersPerToken: 4,
    forceChunkingForTesting: true
  )
}

struct SceneContextClient {
  private let settings: SceneContextSettings
  private let session: URLSession

  init(settings: SceneContextSettings, session: URLSession = .shared) {
    self.settings = settings
    self.session = session
  }

  static func streamSummaryPromptForTesting(_ request: StreamSummaryRequest) -> String {
    streamSummaryPrompt(for: request)
  }

  static func streamSummaryPayloadJSONForTesting(
    _ request: StreamSummaryRequest,
    settings: SceneContextSettings
  ) throws -> String {
    let prompt = streamSummaryPrompt(for: request)
    let data = try streamSummaryPayloadData(model: resolvedTextModel(settings.textModel), prompt: prompt)
    guard let json = String(data: data, encoding: .utf8) else {
      throw SceneContextClientError.invalidResponse
    }
    return json
  }

  static func sceneContextPromptForTesting(_ request: SceneContextRequest) -> String {
    userPrompt(for: request)
  }

  func analyze(_ request: SceneContextRequest) async throws -> SceneContextAnalysis {
    if SupabaseEdgeFunctionClient.isConfigured() {
      return try await proxyAnalyze(request)
    }
    guard !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw SceneContextClientError.missingAPIKey
    }
    let url = try completionURL()
    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
    urlRequest.timeoutInterval = 45
    urlRequest.httpBody = try JSONEncoder().encode(ChatRequest(
      model: settings.model,
      messages: [
        ChatMessage(role: "system", content: [.text(Self.systemPrompt)]),
        ChatMessage(role: "user", content: userContent(for: request))
      ],
      temperature: 0.2,
      maxTokens: 800
    ))

    let (data, response) = try await session.data(for: urlRequest)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      let detail = String(data: data, encoding: .utf8) ?? "non-HTTP response"
      throw SceneContextClientError.malformedJSON(detail)
    }
    let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
    guard let content = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines),
          !content.isEmpty else {
      throw SceneContextClientError.emptyContent
    }
    return try Self.parseAnalysis(from: content)
  }

  func analyzeNameAddress(_ request: NameAddressRequest) async throws -> NameAddressAnalysis {
    if SupabaseEdgeFunctionClient.isConfigured() {
      return try await proxyNameAddress(request)
    }
    guard !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw SceneContextClientError.missingAPIKey
    }
    let url = try completionURL()
    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
    urlRequest.timeoutInterval = 20
    urlRequest.httpBody = try JSONEncoder().encode(ChatRequest(
      model: settings.model,
      messages: [
        ChatMessage(role: "system", content: [.text(Self.nameAddressSystemPrompt)]),
        ChatMessage(role: "user", content: [.text(Self.nameAddressPrompt(for: request))])
      ],
      temperature: 0,
      maxTokens: 240
    ))

    let (data, response) = try await session.data(for: urlRequest)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      let detail = String(data: data, encoding: .utf8) ?? "non-HTTP response"
      throw SceneContextClientError.malformedJSON(detail)
    }
    let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
    guard let content = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines),
          !content.isEmpty else {
      throw SceneContextClientError.emptyContent
    }
    return try Self.parseNameAddressAnalysis(from: content)
  }

  func classifyActivityMode(_ request: ActivityModeClassificationRequest) async throws -> ActivityModeClassification {
    if SupabaseEdgeFunctionClient.isConfigured() {
      return try await proxyActivityMode(request)
    }
    guard !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw SceneContextClientError.missingAPIKey
    }
    let url = try completionURL()
    let model = Self.resolvedTextModel(settings.textModel)
    var prompt = Self.activityModePrompt(for: request)
    var payloadData = try Self.activityModePayloadData(model: model, prompt: prompt)
    let maxAttempts = 2
    let requestId = UUID().uuidString.prefix(8)
    AppLogger.log(
      .activityMode,
      "classification start requestId=\(requestId) reason=\(request.reason) model=\(model) promptVersion=\(ActivityModeClassifier.promptVersion) promptChars=\(prompt.count) requestBytes=\(payloadData.count) contexts=\(request.sceneContexts.count) transcriptChars=\(request.transcriptText.count) people=\(request.recognizedPeople.count)"
    )

    for attempt in 1...maxAttempts {
      var urlRequest = URLRequest(url: url)
      urlRequest.httpMethod = "POST"
      urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
      urlRequest.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
      urlRequest.timeoutInterval = 20
      urlRequest.httpBody = payloadData
      let startedAt = Date()
      do {
        let (data, statusCode) = try await send(urlRequest)
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
          throw SceneContextClientError.emptyContent
        }
        let classification = try Self.parseActivityModeClassification(from: content)
        AppLogger.log(
          .activityMode,
          "classification success requestId=\(requestId) attempt=\(attempt)/\(maxAttempts) status=\(statusCode) model=\(model) elapsedMs=\(Self.elapsedMilliseconds(since: startedAt)) mode=\(classification.mode) specific=\"\(Self.sanitizedText(classification.specificActivity, maxLength: 80))\" confidence=\(String(format: "%.2f", classification.confidence)) reason=\"\(Self.sanitizedText(classification.reason, maxLength: 120))\""
        )
        return classification
      } catch {
        AppLogger.log(
          .activityMode,
          "classification failure requestId=\(requestId) attempt=\(attempt)/\(maxAttempts) status=\(Self.statusText(for: error)) model=\(model) retryable=\(Self.isMalformedJSONError(error)) elapsedMs=\(Self.elapsedMilliseconds(since: startedAt)) errorKind=\(Self.errorKind(for: error)) sanitizedError=\"\(Self.sanitizedErrorDescription(error))\""
        )
        guard Self.isMalformedJSONError(error), attempt < maxAttempts else {
          throw error
        }
        prompt = Self.strictActivityModeJSONRetryPrompt(for: prompt)
        payloadData = try Self.activityModePayloadData(model: model, prompt: prompt)
      }
    }
    throw SceneContextClientError.invalidResponse
  }

  func summarizeStream(
    _ request: StreamSummaryRequest,
    retryPolicy: StreamSummaryRetryPolicy = .production
  ) async throws -> StreamSummaryAnalysis {
    guard SupabaseEdgeFunctionClient.isConfigured()
            || !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw SceneContextClientError.missingAPIKey
    }
    let url = try completionURL()
    let model = Self.resolvedTextModel(settings.textModel)
    let prompt = Self.streamSummaryPrompt(for: request)
    let payloadData = try Self.streamSummaryPayloadData(model: model, prompt: prompt)
    let maxAttempts = retryPolicy.normalizedMaxAttempts
    AppLogger.log(
      .sceneContext,
      "Alibaba stream summary start model=\(model) endpointHost=\(url.host ?? "unknown") endpointPath=\(url.path) requestBytes=\(payloadData.count) promptChars=\(prompt.count) estimatedTokens=\(Self.estimatedTokenCount(forCharacters: prompt.count, charactersPerToken: StreamSummaryLongInputPolicy.production.estimatedCharactersPerToken)) transcriptChunks=\(request.transcripts.count) transcriptChars=\(Self.transcriptCharacterCount(request)) sceneContexts=\(request.sceneContexts.count) timeoutSeconds=\(String(format: "%.0f", retryPolicy.timeoutInterval)) maxAttempts=\(maxAttempts)"
    )
    return try await sendStreamSummaryPrompt(
      prompt,
      model: model,
      url: url,
      retryPolicy: retryPolicy,
      payloadData: payloadData,
      operation: "single",
      chunkIndex: nil,
      chunkCount: nil
    )
  }

  func summarizeStreamLongSafe(
    _ request: StreamSummaryRequest,
    retryPolicy: StreamSummaryRetryPolicy = .production,
    longInputPolicy: StreamSummaryLongInputPolicy = .production
  ) async throws -> StreamSummaryAnalysis {
    guard SupabaseEdgeFunctionClient.isConfigured()
            || !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw SceneContextClientError.missingAPIKey
    }
    let url = try completionURL()
    let model = Self.resolvedTextModel(settings.textModel)
    let prompt = Self.streamSummaryPrompt(for: request)
    let payloadData = try Self.streamSummaryPayloadData(model: model, prompt: prompt)
    let estimatedTokens = Self.estimatedTokenCount(
      forCharacters: prompt.count,
      charactersPerToken: longInputPolicy.estimatedCharactersPerToken
    )
    let shouldChunk = longInputPolicy.forceChunkingForTesting
      || prompt.count > longInputPolicy.maxPromptCharacters
      || payloadData.count > longInputPolicy.maxPromptCharacters * 2
    let chunkRequests = shouldChunk
      ? Self.chunkedStreamSummaryRequests(for: request, policy: longInputPolicy)
      : [request]
    AppLogger.log(
      .sceneContext,
      "Alibaba stream summary plan model=\(model) requestBytes=\(payloadData.count) promptChars=\(prompt.count) estimatedTokens=\(estimatedTokens) chunking=\(shouldChunk) chunkCount=\(chunkRequests.count) transcriptChunks=\(request.transcripts.count) transcriptChars=\(Self.transcriptCharacterCount(request)) sceneContexts=\(request.sceneContexts.count) targetPromptChars=\(longInputPolicy.targetPromptCharacters) maxPromptChars=\(longInputPolicy.maxPromptCharacters)"
    )

    guard shouldChunk, chunkRequests.count > 1 else {
      return try await sendStreamSummaryPrompt(
        prompt,
        model: model,
        url: url,
        retryPolicy: retryPolicy,
        payloadData: payloadData,
        operation: "single",
        chunkIndex: nil,
        chunkCount: nil
      )
    }

    var partials: [StreamSummaryAnalysis] = []
    partials.reserveCapacity(chunkRequests.count)
    for (index, chunkRequest) in chunkRequests.enumerated() {
      let chunkPrompt = Self.streamSummaryPrompt(for: chunkRequest)
      let chunkPayload = try Self.streamSummaryPayloadData(model: model, prompt: chunkPrompt)
      AppLogger.log(
        .sceneContext,
        "Alibaba stream summary chunk start index=\(index + 1)/\(chunkRequests.count) model=\(model) requestBytes=\(chunkPayload.count) promptChars=\(chunkPrompt.count) estimatedTokens=\(Self.estimatedTokenCount(forCharacters: chunkPrompt.count, charactersPerToken: longInputPolicy.estimatedCharactersPerToken)) transcriptChunks=\(chunkRequest.transcripts.count) sceneContexts=\(chunkRequest.sceneContexts.count)"
      )
      let partial = try await sendStreamSummaryPrompt(
        chunkPrompt,
        model: model,
        url: url,
        retryPolicy: retryPolicy,
        payloadData: chunkPayload,
        operation: "chunk",
        chunkIndex: index + 1,
        chunkCount: chunkRequests.count
      )
      partials.append(partial)
    }

    let mergePrompt = Self.streamSummaryMergePrompt(for: request, partials: partials)
    let mergePayload = try Self.streamSummaryPayloadData(model: model, prompt: mergePrompt)
    AppLogger.log(
      .sceneContext,
      "Alibaba stream summary merge start model=\(model) requestBytes=\(mergePayload.count) promptChars=\(mergePrompt.count) estimatedTokens=\(Self.estimatedTokenCount(forCharacters: mergePrompt.count, charactersPerToken: longInputPolicy.estimatedCharactersPerToken)) partials=\(partials.count)"
    )
    return try await sendStreamSummaryPrompt(
      mergePrompt,
      model: model,
      url: url,
      retryPolicy: retryPolicy,
      payloadData: mergePayload,
      operation: "merge",
      chunkIndex: nil,
      chunkCount: partials.count
    )
  }

  private func sendStreamSummaryPrompt(
    _ prompt: String,
    model: String,
    url: URL,
    retryPolicy: StreamSummaryRetryPolicy,
    payloadData: Data,
    operation: String,
    chunkIndex: Int?,
    chunkCount: Int?
  ) async throws -> StreamSummaryAnalysis {
    if SupabaseEdgeFunctionClient.isConfigured() {
      return try await proxyStreamSummaryPrompt(
        currentPrompt: prompt,
        model: model,
        retryPolicy: retryPolicy,
        operation: operation,
        chunkIndex: chunkIndex,
        chunkCount: chunkCount
      )
    }

    let maxAttempts = retryPolicy.normalizedMaxAttempts
    let chunkText = chunkIndex.map { " chunk=\($0)/\(chunkCount ?? $0)" } ?? ""
    var currentPrompt = prompt
    var currentPayloadData = payloadData
    var lastError: Error?
    for attempt in 1...maxAttempts {
      var urlRequest = URLRequest(url: url)
      urlRequest.httpMethod = "POST"
      urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
      urlRequest.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
      urlRequest.timeoutInterval = retryPolicy.timeoutInterval
      urlRequest.httpBody = currentPayloadData
      let startedAt = Date()
      let requestId = UUID().uuidString.prefix(8)
      AppLogger.log(
        .sceneContext,
        "Alibaba stream summary attempt requestId=\(requestId) operation=\(operation)\(chunkText) attempt=\(attempt)/\(maxAttempts) retryCount=\(attempt - 1) model=\(model) promptVersion=\(attempt == 1 ? "streamSummary.v2" : "streamSummary.v2.strictJSONRetry") requestBytes=\(currentPayloadData.count) promptChars=\(currentPrompt.count) timeoutSeconds=\(String(format: "%.0f", retryPolicy.timeoutInterval))"
      )
      do {
        let (data, statusCode) = try await send(urlRequest)
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
          throw SceneContextClientError.emptyContent
        }
        let parseResult: StreamSummaryParseResult
        do {
          parseResult = try Self.parseStreamSummaryWithRecovery(from: content)
        } catch {
          AppLogger.log(
            .sceneContext,
            "Alibaba stream summary parse failure requestId=\(requestId) operation=\(operation)\(chunkText) attempt=\(attempt)/\(maxAttempts) model=\(model) promptVersion=\(attempt == 1 ? "streamSummary.v2" : "streamSummary.v2.strictJSONRetry") rawOutput=\"\(Self.sanitizedText(content, maxLength: 700))\" sanitizedOutput=\"\(Self.sanitizedText(content, maxLength: 360))\" extractionAttempted=true repairAttempted=true parseError=\"\(Self.sanitizedErrorDescription(error))\""
          )
          throw error
        }
        AppLogger.log(
          .sceneContext,
          "Alibaba stream summary success requestId=\(requestId) operation=\(operation)\(chunkText) attempt=\(attempt)/\(maxAttempts) retryCount=\(attempt - 1) status=\(statusCode) model=\(model) elapsedMs=\(Self.elapsedMilliseconds(since: startedAt)) responseBytes=\(data.count) summaryChars=\(parseResult.analysis.summary.count) jsonExtracted=\(parseResult.extractedJSON) jsonRepaired=\(parseResult.repairedJSON)"
        )
        return parseResult.analysis
      } catch {
        lastError = error
        let retryable = Self.isRetryableStreamSummaryError(error)
        AppLogger.log(
          .sceneContext,
          "Alibaba stream summary failure operation=\(operation)\(chunkText) attempt=\(attempt)/\(maxAttempts) retryCount=\(attempt - 1) status=\(Self.statusText(for: error)) model=\(model) retryable=\(retryable) elapsedMs=\(Self.elapsedMilliseconds(since: startedAt)) errorKind=\(Self.errorKind(for: error)) sanitizedError=\"\(Self.sanitizedErrorDescription(error))\""
        )
        guard retryable, attempt < maxAttempts else {
          throw error
        }
        if Self.isMalformedJSONError(error) {
          currentPrompt = Self.strictJSONRetryPrompt(for: prompt)
          currentPayloadData = try Self.streamSummaryPayloadData(model: model, prompt: currentPrompt)
        }
        let delay = retryPolicy.delay(beforeAttempt: attempt + 1)
        AppLogger.log(
          .sceneContext,
          "Alibaba stream summary retry scheduled operation=\(operation)\(chunkText) nextAttempt=\(attempt + 1)/\(maxAttempts) delaySeconds=\(String(format: "%.1f", delay)) fallbackDeferred=true"
        )
        if delay > 0 {
          try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
      }
    }
    throw lastError ?? SceneContextClientError.invalidResponse
  }

  static func parseAnalysis(from content: String) throws -> SceneContextAnalysis {
    let jsonText = stripCodeFence(content)
    guard let data = jsonText.data(using: .utf8) else {
      throw SceneContextClientError.malformedJSON("response was not UTF-8")
    }
    do {
      let decoded = try JSONDecoder().decode(SceneContextAnalysis.self, from: data)
      return SceneContextAnalysis(
        who: decoded.who,
        whereText: decoded.whereText,
        what: decoded.what,
        whenText: decoded.whenText,
        why: decoded.why,
        how: decoded.how,
        interactionStyle: decoded.interactionStyle,
        summary: decoded.summary,
        confidence: min(max(decoded.confidence, 0), 1),
        evidence: decoded.evidence
      )
    } catch {
      throw SceneContextClientError.malformedJSON(error.localizedDescription)
    }
  }

  static func parseNameAddressAnalysis(from content: String) throws -> NameAddressAnalysis {
    let jsonText = stripCodeFence(content)
    guard let data = jsonText.data(using: .utf8) else {
      throw SceneContextClientError.malformedJSON("response was not UTF-8")
    }
    do {
      let decoded = try JSONDecoder().decode(NameAddressAnalysis.self, from: data)
      return NameAddressAnalysis(
        intent: decoded.intent,
        displayName: decoded.displayName,
        personId: decoded.personId,
        confidence: min(max(decoded.confidence, 0), 1),
        evidence: decoded.evidence
      )
    } catch {
      throw SceneContextClientError.malformedJSON(error.localizedDescription)
    }
  }

  static func parseActivityModeClassification(from content: String) throws -> ActivityModeClassification {
    let jsonText = stripCodeFence(content)
    if let result = try decodeActivityModeClassification(jsonText) {
      return result
    }
    let repaired = repairCommonJSONIssues(jsonText)
    if repaired != jsonText,
       let result = try decodeActivityModeClassification(repaired) {
      return result
    }
    throw activityModeMalformedJSONError(jsonText)
  }

  static func parseStreamSummary(from content: String) throws -> StreamSummaryAnalysis {
    try parseStreamSummaryWithRecovery(from: content).analysis
  }

  private static func parseStreamSummaryWithRecovery(from content: String) throws -> StreamSummaryParseResult {
    let original = content.trimmingCharacters(in: .whitespacesAndNewlines)
    let jsonText = stripCodeFence(content)
    let extractedJSON = jsonText != original
    if let result = try decodeStreamSummary(jsonText, extractedJSON: extractedJSON, repairedJSON: false) {
      return result
    }
    let repaired = repairCommonJSONIssues(jsonText)
    if repaired != jsonText,
       let result = try decodeStreamSummary(repaired, extractedJSON: extractedJSON, repairedJSON: true) {
      return result
    }
    throw streamSummaryMalformedJSONError(jsonText)
  }

  private static func decodeActivityModeClassification(_ jsonText: String) throws -> ActivityModeClassification? {
    guard let data = jsonText.data(using: .utf8) else {
      throw SceneContextClientError.malformedJSON("response was not UTF-8")
    }
    do {
      let decoded = try JSONDecoder().decode(ActivityModeClassification.self, from: data)
      return ActivityModeClassification(
        mode: decoded.mode,
        specificActivity: truncated(decoded.specificActivity, maxLength: 80),
        confidence: decoded.confidence,
        reason: truncated(decoded.reason, maxLength: 160)
      )
    } catch {
      return nil
    }
  }

  private static func decodeStreamSummary(
    _ jsonText: String,
    extractedJSON: Bool,
    repairedJSON: Bool
  ) throws -> StreamSummaryParseResult? {
    guard let data = jsonText.data(using: .utf8) else {
      throw SceneContextClientError.malformedJSON("response was not UTF-8")
    }
    do {
      let decoded = try JSONDecoder().decode(StreamSummaryAnalysis.self, from: data)
      return StreamSummaryParseResult(
        analysis: normalizedStreamSummary(decoded),
        extractedJSON: extractedJSON,
        repairedJSON: repairedJSON
      )
    } catch {
      return nil
    }
  }

  private static func normalizedStreamSummary(_ decoded: StreamSummaryAnalysis) -> StreamSummaryAnalysis {
    StreamSummaryAnalysis(
      summary: truncated(decoded.summary.trimmingCharacters(in: .whitespacesAndNewlines), maxLength: 260),
      who: truncated(decoded.who.trimmingCharacters(in: .whitespacesAndNewlines), maxLength: 96),
      whereText: truncated(decoded.whereText.trimmingCharacters(in: .whitespacesAndNewlines), maxLength: 96),
      what: truncated(decoded.what.trimmingCharacters(in: .whitespacesAndNewlines), maxLength: 120),
      whenText: truncated(decoded.whenText.trimmingCharacters(in: .whitespacesAndNewlines), maxLength: 96),
      why: truncated(decoded.why.trimmingCharacters(in: .whitespacesAndNewlines), maxLength: 120),
      how: truncated(decoded.how.trimmingCharacters(in: .whitespacesAndNewlines), maxLength: 120),
      people: decoded.people.map { truncated($0.trimmingCharacters(in: .whitespacesAndNewlines), maxLength: 48) }.filter { !$0.isEmpty },
      keyMoments: decoded.keyMoments.map { truncated($0.trimmingCharacters(in: .whitespacesAndNewlines), maxLength: 96) }.filter { !$0.isEmpty },
      outline: decoded.outline.map { truncated($0.trimmingCharacters(in: .whitespacesAndNewlines), maxLength: 110) }.filter { !$0.isEmpty },
      confidence: min(max(decoded.confidence, 0), 1)
    )
  }

  private func proxyAnalyze(_ request: SceneContextRequest) async throws -> SceneContextAnalysis {
    let proxy = try SupabaseEdgeFunctionClient.shared(session: session)
    let payload = AIProxyStructuredPromptPayload(
      model: settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? SceneContextSettings.defaultModel
        : settings.model,
      systemPrompt: Self.systemPrompt,
      userPrompt: Self.userPrompt(for: request),
      imageDataUrls: request.frames.map { "data:image/jpeg;base64,\($0.jpegData.base64EncodedString())" },
      temperature: 0.2,
      maxTokens: 800,
      timeoutSeconds: 45,
      schema: "scene_context"
    )
    let response: AIProxyFunctionResponse<SceneContextAnalysis> = try await proxy.invoke(
      operation: "qwen.scene_context",
      payload: payload,
      timeoutInterval: 50
    )
    guard let analysis = response.output else {
      throw SceneContextClientError.emptyContent
    }
    AppLogger.log(.sceneContext, "[AI_PROXY] operation=qwen.scene_context source=supabase_edge model=\(response.model ?? payload.model) frames=\(request.frames.count)")
    return SceneContextAnalysis(
      who: analysis.who,
      whereText: analysis.whereText,
      what: analysis.what,
      whenText: analysis.whenText,
      why: analysis.why,
      how: analysis.how,
      interactionStyle: analysis.interactionStyle,
      summary: analysis.summary,
      confidence: min(max(analysis.confidence, 0), 1),
      evidence: analysis.evidence
    )
  }

  private func proxyNameAddress(_ request: NameAddressRequest) async throws -> NameAddressAnalysis {
    let proxy = try SupabaseEdgeFunctionClient.shared(session: session)
    let payload = AIProxyStructuredPromptPayload(
      model: Self.resolvedTextModel(settings.textModel),
      systemPrompt: Self.nameAddressSystemPrompt,
      userPrompt: Self.nameAddressPrompt(for: request),
      imageDataUrls: [],
      temperature: 0,
      maxTokens: 240,
      timeoutSeconds: 20,
      schema: "name_address"
    )
    let response: AIProxyFunctionResponse<NameAddressAnalysis> = try await proxy.invoke(
      operation: "qwen.scene_context",
      payload: payload,
      timeoutInterval: 25
    )
    guard let analysis = response.output else {
      throw SceneContextClientError.emptyContent
    }
    AppLogger.log(.sceneContext, "[AI_PROXY] operation=qwen.scene_context kind=name_address source=supabase_edge model=\(response.model ?? payload.model)")
    return analysis
  }

  private func proxyActivityMode(_ request: ActivityModeClassificationRequest) async throws -> ActivityModeClassification {
    let model = Self.resolvedTextModel(settings.textModel)
    let prompt = Self.activityModePrompt(for: request)
    let proxy = try SupabaseEdgeFunctionClient.shared(session: session)
    let payload = AIProxyStructuredPromptPayload(
      model: model,
      systemPrompt: Self.activityModeSystemPrompt,
      userPrompt: prompt,
      imageDataUrls: [],
      temperature: 0,
      maxTokens: 180,
      timeoutSeconds: 20,
      schema: "activity_mode"
    )
    let response: AIProxyFunctionResponse<ActivityModeClassification> = try await proxy.invoke(
      operation: "qwen.activity_mode",
      payload: payload,
      timeoutInterval: 25
    )
    guard let classification = response.output else {
      throw SceneContextClientError.emptyContent
    }
    AppLogger.log(
      .activityMode,
      "[AI_PROXY] operation=qwen.activity_mode source=supabase_edge model=\(response.model ?? model) mode=\(classification.mode) confidence=\(String(format: "%.2f", classification.confidence))"
    )
    return classification
  }

  private func proxyStreamSummaryPrompt(
    currentPrompt: String,
    model: String,
    retryPolicy: StreamSummaryRetryPolicy,
    operation: String,
    chunkIndex: Int?,
    chunkCount: Int?
  ) async throws -> StreamSummaryAnalysis {
    let proxy = try SupabaseEdgeFunctionClient.shared(session: session)
    let chunkText = chunkIndex.map { " chunk=\($0)/\(chunkCount ?? $0)" } ?? ""
    let payload = AIProxyStructuredPromptPayload(
      model: model,
      systemPrompt: Self.streamSummarySystemPrompt,
      userPrompt: currentPrompt,
      imageDataUrls: [],
      temperature: 0.1,
      maxTokens: 320,
      timeoutSeconds: Int(retryPolicy.timeoutInterval.rounded()),
      schema: "stream_summary"
    )
    let response: AIProxyFunctionResponse<StreamSummaryAnalysis> = try await proxy.invoke(
      operation: "qwen.stream_summary",
      payload: payload,
      timeoutInterval: retryPolicy.timeoutInterval + 8
    )
    guard let analysis = response.output else {
      throw SceneContextClientError.emptyContent
    }
    let normalized = Self.normalizedStreamSummary(analysis)
    AppLogger.log(
      .sceneContext,
      "[AI_PROXY] operation=qwen.stream_summary stage=\(operation)\(chunkText) source=supabase_edge model=\(response.model ?? model) summaryChars=\(normalized.summary.count) confidence=\(String(format: "%.2f", normalized.confidence))"
    )
    return normalized
  }

  private struct AIProxyStructuredPromptPayload: Encodable {
    var model: String
    var systemPrompt: String
    var userPrompt: String
    var imageDataUrls: [String]
    var temperature: Double
    var maxTokens: Int
    var timeoutSeconds: Int
    var schema: String? = nil
  }

  private func completionURL() throws -> URL {
    guard var components = URLComponents(string: settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
          components.scheme != nil,
          components.host != nil else {
      throw SceneContextClientError.invalidBaseURL
    }
    let existingPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    components.path = "/" + ([existingPath, "chat/completions"].filter { !$0.isEmpty }.joined(separator: "/"))
    guard let url = components.url else {
      throw SceneContextClientError.invalidBaseURL
    }
    return url
  }

  private static func resolvedTextModel(_ textModel: String) -> String {
    let trimmed = textModel.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? SceneContextSettings.defaultTextModel : trimmed
  }

  private static func streamSummaryPayloadData(model: String, prompt: String) throws -> Data {
    try JSONEncoder().encode(ChatRequest(
      model: model,
      messages: [
        ChatMessage(role: "system", content: [.text(streamSummarySystemPrompt)]),
        ChatMessage(role: "user", content: [.text(prompt)])
      ],
      temperature: 0.1,
      maxTokens: 320,
      enableThinking: false
    ))
  }

  private static func activityModePayloadData(model: String, prompt: String) throws -> Data {
    try JSONEncoder().encode(ChatRequest(
      model: model,
      messages: [
        ChatMessage(role: "system", content: [.text(activityModeSystemPrompt)]),
        ChatMessage(role: "user", content: [.text(prompt)])
      ],
      temperature: 0,
      maxTokens: 180,
      enableThinking: false
    ))
  }

  private func send(_ request: URLRequest) async throws -> (Data, Int) {
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw SceneContextClientError.invalidResponse
    }
    guard (200..<300).contains(http.statusCode) else {
      throw SceneContextClientError.badHTTPStatus(http.statusCode, Self.sanitizedBody(data))
    }
    return (data, http.statusCode)
  }

  private func userContent(for request: SceneContextRequest) -> [ChatContent] {
    var content: [ChatContent] = [
      .text(Self.userPrompt(for: request))
    ]
    content.append(contentsOf: request.frames.map {
      .imageURL("data:image/jpeg;base64,\($0.jpegData.base64EncodedString())")
    })
    return content
  }

  private static let systemPrompt = """
  You produce structured memory context from first-person smart-glasses images and transcript snippets. The app user is the smart-glasses wearer; refer to the wearer as "you". Recognized faces, activePeople, conversationPartnerName, and transcript displayName values are people with or in front of the wearer, not the wearer, unless explicitly marked as the wearer. Infer only what is directly supported by the image, transcript, timestamp, or location metadata. Do not infer sensitive attributes. Return strict JSON only.
  """

  private static let nameAddressSystemPrompt = """
  You classify whether a transcript snippet names someone who is present with the smart-glasses wearer. Return strict JSON only. Do not guess beyond the snippet and supplied people list.
  """

  private static let streamSummarySystemPrompt = """
  You summarize the latest smart-glasses stream for the iPhone UI. The smart glasses are worn by the app user. Refer to the wearer as "you". People recognized by face or presence evidence are people in front of the wearer, not the wearer. Return strict JSON only.
  """

  private static let activityModeSystemPrompt = """
  You classify the current activity mode for a smart-glasses wearer. The app user is the wearer; refer to the wearer as "you". Recognized people, activePeople, conversationPartnerName, and transcript displayName values are people with or in front of the wearer, not the wearer. Return strict JSON only.
  """

  static func activityModePromptForTesting(_ request: ActivityModeClassificationRequest) -> String {
    activityModePrompt(for: request)
  }

  private static func activityModePrompt(for request: ActivityModeClassificationRequest) -> String {
    let contextText = request.sceneContexts
      .sorted { $0.createdAt < $1.createdAt }
      .suffix(6)
      .map { record in
        [
          "- \(record.createdAt.formatted(date: .omitted, time: .shortened)): \(truncated(record.summary, maxLength: 180))",
          "  where=\(truncated(record.whereText, maxLength: 80))",
          "  what=\(truncated(record.what, maxLength: 100))",
          "  how=\(truncated(record.how, maxLength: 100))",
          "  confidence=\(String(format: "%.2f", record.confidence))"
        ].joined(separator: "\n")
      }
      .joined(separator: "\n")
    let peopleText = request.recognizedPeople.isEmpty
      ? "none"
      : request.recognizedPeople.joined(separator: ", ")
    let identityText: String
    if let identityEvidence = request.identityEvidence,
       let data = try? JSONEncoder().encode(identityEvidence),
       let json = String(data: data, encoding: .utf8) {
      identityText = json
    } else {
      identityText = "not available"
    }
    let allowedModes = ActivityModeTaxonomy.allCases
      .filter { $0 != .custom }
      .map(\.rawValue)
      .joined(separator: ", ")
    return """
    Classify the wearer's current stream activity mode.

    Return exactly this JSON object:
    {"mode":"entertainment|sport|study|social|commute|shopping|work|general|unknown","specific_activity":"optional brief action phrase","confidence":0.0,"reason":"short evidence-based reason"}

    Mode taxonomy:
    \(allowedModes)

    Rules:
    - mode must be one taxonomy label. Never invent a custom primary mode.
    - Prefer a broad accurate mode over a specific uncertain claim. For example, laptop use is usually "work" unless study evidence is explicit.
    - specific_activity is optional. Leave it empty unless confidence is at least 0.88 and multiple independent evidence items support the detail.
    - Do not include incidental location, furniture, device, or time-of-day details in specific_activity.
    - Use "general" when the wearer is just looking around and the evidence is sparse.
    - Use "unknown" only when the evidence is too weak to classify.
    - Do not overfit to a single frame or transcript word; use repeated scene context plus transcript together.
    - Role boundary: the app user/wearer is "you"; recognized people and activePeople are people with you, not you.
    - Do not infer sensitive attributes.
    - Confidence is 0 to 1.

    Stream state:
    \(request.streamState)

    Classification trigger:
    \(request.reason)

    Recognized active people:
    \(peopleText)

    Detected face count:
    \(request.detectedFaceCount)

    Location label:
    \(request.locationLabel ?? "unknown")

    Identity evidence:
    \(identityText)

    Recent transcript:
    \(truncated(request.transcriptText, maxLength: 700))

    Recent multimodal scene context:
    \(contextText.isEmpty ? "not available" : contextText)
    """
  }

  private static func userPrompt(for request: SceneContextRequest) -> String {
    let transcriptText = request.transcripts.map { transcript in
      let name = transcript.displayName ?? "unknown"
      return "- \(name): \(transcript.text)"
    }.joined(separator: "\n")
    let locationText = semanticLocationText(for: request.location)
    let identityText: String
    if let identityEvidence = request.identityEvidence,
       let data = try? JSONEncoder().encode(identityEvidence),
       let json = String(data: data, encoding: .utf8) {
      identityText = json
    } else {
      identityText = "not available"
    }
    return """
 Analyze the attached scene images with these live transcript snippets and optional location. Return exactly this JSON shape:
 {"who":"...","where":"...","what":"...","when":"...","why":"...","how":"...","interactionStyle":"...","summary":"...","confidence":0.0,"evidence":["..."]}

Rules:
- Use concise natural language.
- Put "unknown" for any field that is not supported.
- Use App identity evidence as app-observed evidence when confidence is high; do not visually infer names or relationships.
- Role boundary: app user/wearer = "you"; recognized faces, activePeople, conversationPartnerName, and transcript displayName values are other people present with you unless explicitly marked as the wearer.
- If evidence says Gary, Sean, or another recognized person is present, phrase it as "you saw/spoke with [name]"; do not say that recognized person is the app user.
- Treat activePeople as the current presence roster. Treat departedPeople as no longer present after their endedAt time.
- Use the time window for "when".
- Infer "where" as a semantic place or environment category such as home, school, campus hallway, classroom, office, residential area, street, store, restaurant, park, mountain trail, or unknown. Never output latitude, longitude, coordinates, or raw GPS text.
- Infer "why", "how", and "interactionStyle" only from transcript, image, location, and app identity evidence.
- interactionStyle should distinguish cases like casual family check-in, formal dinner, standup conversation, studying, or workspace help.
- Be respectful and natural; do not shame the user or the room.
- Confidence is 0 to 1.
- Evidence must cite only visible image details, transcript snippets, time, location metadata, or app identity evidence.

Time window:
\(request.startedAt.formatted(date: .numeric, time: .standard)) to \(request.endedAt.formatted(date: .numeric, time: .standard))

Location:
\(locationText)

App identity evidence:
\(identityText)

Transcript:
\(transcriptText.isEmpty ? "not available" : transcriptText)
"""
  }

  private static func nameAddressPrompt(for request: NameAddressRequest) -> String {
    let peopleJSON = (try? String(data: JSONEncoder().encode(request.people.map {
      ["personId": $0.personId.uuidString, "displayName": $0.displayName]
    }), encoding: .utf8)) ?? "[]"
    let activeJSON = (try? String(data: JSONEncoder().encode(request.activePeople.map {
      SceneContextPersonPresence($0)
    }), encoding: .utf8)) ?? "[]"
    return """
    Classify whether this transcript names a person who is present with the wearer.

    Return exactly:
    {"intent":"none|directAddress|introduction|departure|reference","displayName":null,"personId":null,"confidence":0.0,"evidence":"short reason"}

    Rules:
    - directAddress means the wearer is speaking to the named person, like "Gary, can you help?"
    - introduction means the snippet identifies a present person, like "this is Gary."
    - departure means the named person is leaving or the wearer says goodbye to them.
    - reference means the name is only mentioned as a topic, like "Gary told me yesterday."
    - none means no listed person is present in the snippet.
    - Use only people from the people list. If a name is not listed, return none.
    - Prefer reference over directAddress when the person is talked about in third person.

    Timestamp:
    \(request.timestamp.formatted(date: .numeric, time: .standard))

    People list:
    \(peopleJSON)

    Active people before this snippet:
    \(activeJSON)

    Transcript:
    \(request.transcriptText)
    """
  }

  private static func streamSummaryPrompt(for request: StreamSummaryRequest) -> String {
    let transcriptText = request.transcripts
      .sorted { ($0.startedAt ?? $0.createdAt) < ($1.startedAt ?? $1.createdAt) }
      .map { chunk in
        let person = chunk.personId?.uuidString ?? chunk.activeIdentityState
        return "- \(chunkTimeText(chunk)): \(person): \(truncated(chunk.text, maxLength: 220))"
      }
      .joined(separator: "\n")
    let contextText = request.sceneContexts
      .sorted { $0.startedAt < $1.startedAt }
      .map { record in
        [
          "- \(record.createdAt.formatted(date: .omitted, time: .shortened)): \(truncated(record.summary, maxLength: 180))",
          "  who=\(truncated(record.who, maxLength: 80))",
          "  where=\(truncated(record.whereText, maxLength: 80))",
          "  what=\(truncated(record.what, maxLength: 80))",
          "  why=\(truncated(record.why, maxLength: 80))",
          "  how=\(truncated(record.how, maxLength: 80))",
          "  confidence=\(String(format: "%.2f", record.confidence))"
        ].joined(separator: "\n")
      }
      .joined(separator: "\n")
    let identityText: String
    if let identityEvidence = request.identityEvidence,
       let data = try? JSONEncoder().encode(identityEvidence),
       let json = String(data: data, encoding: .utf8) {
      identityText = json
    } else {
      identityText = "not available"
    }
    return """
    Return exactly this JSON shape:
    {"summary":"one concise precise sentence","who":"...","where":"semantic place/environment","what":"...","when":"...","why":"...","how":"...","people":["name or role"],"keyMoments":["short event"],"outline":["short bullet"],"confidence":0.0}

    User role facts:
    - The app user is the smart-glasses wearer. Refer to the wearer as "you".
    - Recognized faces, conversationPartnerName, activePeople, and transcript displayName values are people present with you, not you, unless explicitly marked as the wearer.
    - Scene records describe what your glasses saw from your point of view.

    Rules:
    - Summary must be one sentence, maximum 48 words.
    - Write from the wearer's perspective: say "you looked at Gary" or "you spoke with Gary", not "Gary looked at Gary".
    - Treat conversationPartnerName and activePeople as people present with the wearer.
    - Treat transcript labels as speaker/attribution evidence only; scene records describe what the wearer saw.
    - Do not call a recognized face the wearer unless the transcript explicitly says that person wore the glasses.
    - Use the scene-context records as multimodal evidence and the transcript as speech evidence.
    - The "where" field must be a semantic place or environment category, never precise coordinates or raw GPS text.
    - If location is unknown, infer where from visual scene/context when supported; otherwise use "unknown".
    - Outline should be 2 to 4 concise bullets in chronological or importance order.
    - The 5Ws/H fields should be detailed enough for the iPhone summary tab, but concise.
    - Prefer concrete observations over generic phrasing.
    - Do not invent names, relationships, locations, tasks, or intent.
    - If transcript and scene context are both sparse, say what was actually available.
    - Confidence is 0 to 1.

    Time window:
    \((request.startedAt ?? request.endedAt).formatted(date: .numeric, time: .standard)) to \(request.endedAt.formatted(date: .numeric, time: .standard))

    App identity evidence:
    \(identityText)

    Multimodal scene-context records:
    \(contextText.isEmpty ? "not available" : contextText)

    Transcript:
    \(transcriptText.isEmpty ? "not available" : transcriptText)
    """
  }

  private static func streamSummaryMergePrompt(
    for request: StreamSummaryRequest,
    partials: [StreamSummaryAnalysis]
  ) -> String {
    let partialText = partials.enumerated().map { index, partial in
      [
        "Partial \(index + 1):",
        "summary=\(truncated(partial.summary, maxLength: 220))",
        "who=\(truncated(partial.who, maxLength: 96))",
        "where=\(truncated(partial.whereText, maxLength: 96))",
        "what=\(truncated(partial.what, maxLength: 140))",
        "when=\(truncated(partial.whenText, maxLength: 96))",
        "why=\(truncated(partial.why, maxLength: 140))",
        "how=\(truncated(partial.how, maxLength: 140))",
        "people=\(partial.people.map { truncated($0, maxLength: 48) }.joined(separator: ", "))",
        "keyMoments=\(partial.keyMoments.map { truncated($0, maxLength: 96) }.joined(separator: " | "))",
        "outline=\(partial.outline.map { truncated($0, maxLength: 110) }.joined(separator: " | "))",
        "confidence=\(String(format: "%.2f", partial.confidence))"
      ].joined(separator: "\n")
    }.joined(separator: "\n\n")
    let identityText: String
    if let identityEvidence = request.identityEvidence,
       let data = try? JSONEncoder().encode(identityEvidence),
       let json = String(data: data, encoding: .utf8) {
      identityText = json
    } else {
      identityText = "not available"
    }
    return """
    Merge these chronological partial smart-glasses stream summaries into one final iPhone summary.

    Return exactly this JSON shape:
    {"summary":"one concise precise sentence","who":"...","where":"semantic place/environment","what":"...","when":"...","why":"...","how":"...","people":["name or role"],"keyMoments":["short event"],"outline":["short bullet"],"confidence":0.0}

    User role facts:
    - The app user is the smart-glasses wearer. Refer to the wearer as "you".
    - People listed in partial summaries, activePeople, recognized faces, and transcript labels are people with or in front of you, not you, unless explicitly marked as the wearer.

    Rules:
    - Preserve important timestamps, people, places, and key moments from all partials.
    - Do not invent people or places beyond the partials and identity evidence.
    - The "where" field must be a semantic place/environment, never coordinates.
    - Summary must be one sentence, maximum 48 words.
    - Outline should be 2 to 4 concise bullets covering the overall stream.
    - Confidence should reflect the weakest major uncertainty across partials.

    Time window:
    \((request.startedAt ?? request.endedAt).formatted(date: .numeric, time: .standard)) to \(request.endedAt.formatted(date: .numeric, time: .standard))

    App identity evidence:
    \(identityText)

    Partial summaries:
    \(partialText.isEmpty ? "not available" : partialText)
    """
  }

  private static func strictJSONRetryPrompt(for originalPrompt: String) -> String {
    """
    Your previous answer was rejected because it was not valid JSON for the required schema.

    Retry with STRICT JSON ONLY:
    - Return only one JSON object.
    - No markdown fence.
    - No prose before or after JSON.
    - No trailing commas.
    - Use double quotes for all keys and string values.
    - Include every required key exactly: summary, who, where, what, when, why, how, people, keyMoments, outline, confidence.

    Original task:
    \(originalPrompt)
    """
  }

  private static func strictActivityModeJSONRetryPrompt(for originalPrompt: String) -> String {
    """
    Your previous answer was rejected because it was not valid JSON for the required activity mode schema.

    Retry with STRICT JSON ONLY:
    - Return only one JSON object.
    - No markdown fence.
    - No prose before or after JSON.
    - No trailing commas.
    - Use double quotes for all keys and string values.
    - Include every required key exactly: mode, specific_activity, confidence, reason.

    Original task:
    \(originalPrompt)
    """
  }

  private static func chunkedStreamSummaryRequests(
    for request: StreamSummaryRequest,
    policy: StreamSummaryLongInputPolicy
  ) -> [StreamSummaryRequest] {
    var items: [StreamSummaryInputItem] = []
    items.append(contentsOf: request.transcripts.map { .transcript($0) })
    items.append(contentsOf: request.sceneContexts.map { .sceneContext($0) })
    items.sort { $0.timestamp < $1.timestamp }
    guard !items.isEmpty else { return [request] }

    var chunks: [[StreamSummaryInputItem]] = []
    var current: [StreamSummaryInputItem] = []
    for item in items {
      let candidate = current + [item]
      let candidateRequest = streamSummaryRequest(
        from: candidate,
        original: request
      )
      let candidatePromptLength = streamSummaryPrompt(for: candidateRequest).count
      if !current.isEmpty && candidatePromptLength > policy.targetPromptCharacters {
        chunks.append(current)
        current = [item]
      } else {
        current = candidate
      }
    }
    if !current.isEmpty {
      chunks.append(current)
    }

    return chunks.map {
      streamSummaryRequest(from: $0, original: request)
    }
  }

  private static func streamSummaryRequest(
    from items: [StreamSummaryInputItem],
    original: StreamSummaryRequest
  ) -> StreamSummaryRequest {
    let transcripts = items.compactMap { item -> TranscriptChunk? in
      if case .transcript(let chunk) = item { return chunk }
      return nil
    }
    let sceneContexts = items.compactMap { item -> SceneContextRecord? in
      if case .sceneContext(let record) = item { return record }
      return nil
    }
    let startedAt = items.map(\.timestamp).min() ?? original.startedAt ?? original.endedAt
    let endedAt = items.map(\.endTimestamp).max() ?? original.endedAt
    return StreamSummaryRequest(
      transcripts: transcripts,
      sceneContexts: sceneContexts,
      startedAt: startedAt,
      endedAt: endedAt,
      identityEvidence: original.identityEvidence
    )
  }

  private enum StreamSummaryInputItem {
    case transcript(TranscriptChunk)
    case sceneContext(SceneContextRecord)

    var timestamp: Date {
      switch self {
      case .transcript(let chunk):
        return chunk.startedAt ?? chunk.createdAt
      case .sceneContext(let record):
        return record.startedAt
      }
    }

    var endTimestamp: Date {
      switch self {
      case .transcript(let chunk):
        return chunk.endedAt ?? chunk.transcriptUpdatedAt ?? chunk.createdAt
      case .sceneContext(let record):
        return record.endedAt
      }
    }
  }

  private static func chunkTimeText(_ chunk: TranscriptChunk) -> String {
    let start = chunk.startedAt ?? chunk.createdAt
    guard let end = chunk.endedAt else {
      return start.formatted(date: .omitted, time: .shortened)
    }
    return "\(start.formatted(date: .omitted, time: .shortened))-\(end.formatted(date: .omitted, time: .shortened))"
  }

  private static func semanticLocationText(for location: SceneLocationSnapshot?) -> String {
    guard let location else { return "not available" }
    let label = location.label?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let usefulLabel: String?
    if let label, !label.isEmpty, !label.localizedCaseInsensitiveContains("location ") {
      usefulLabel = label
    } else {
      usefulLabel = nil
    }
    var parts: [String] = []
    if let usefulLabel {
      parts.append("place label: \(usefulLabel)")
    }
    if let accuracy = location.horizontalAccuracy {
      parts.append(String(format: "iPhone location available within about %.0fm", accuracy))
    } else {
      parts.append("iPhone location available")
    }
    parts.append("use only as weak context; infer a semantic place category and never output coordinates")
    return parts.joined(separator: "; ")
  }

  private static func truncated(_ value: String, maxLength: Int) -> String {
    let cleaned = value
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard cleaned.count > maxLength else { return cleaned }
    return String(cleaned.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
  }

  private static func transcriptCharacterCount(_ request: StreamSummaryRequest) -> Int {
    request.transcripts.reduce(0) { $0 + $1.text.count }
  }

  private static func estimatedTokenCount(forCharacters characters: Int, charactersPerToken: Int) -> Int {
    let divisor = max(1, charactersPerToken)
    return Int(ceil(Double(max(0, characters)) / Double(divisor)))
  }

  private static func stripCodeFence(_ content: String) -> String {
    var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix("```") {
      text = text.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
      if let range = text.range(of: "```", options: .backwards) {
        text = String(text[..<range.lowerBound])
      }
    }
    if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start <= end {
      return String(text[start...end])
    }
    return text
  }

  private static func repairCommonJSONIssues(_ value: String) -> String {
    value
      .replacingOccurrences(of: #",\s*([}\]])"#, with: "$1", options: .regularExpression)
      .replacingOccurrences(of: "\u{201c}", with: "\"")
      .replacingOccurrences(of: "\u{201d}", with: "\"")
      .replacingOccurrences(of: "\u{2018}", with: "'")
      .replacingOccurrences(of: "\u{2019}", with: "'")
  }

  private static func streamSummaryMalformedJSONError(_ jsonText: String) -> SceneContextClientError {
    guard let data = jsonText.data(using: .utf8) else {
      return .malformedJSON("response was not UTF-8")
    }
    do {
      _ = try JSONSerialization.jsonObject(with: data)
      return .malformedJSON("The JSON shape did not match the stream summary schema")
    } catch {
      let nsError = error as NSError
      var detail = nsError.localizedDescription
      if let line = nsError.userInfo["NSJSONSerializationErrorIndex"] {
        detail += " index=\(line)"
      }
      return .malformedJSON(detail)
    }
  }

  private static func activityModeMalformedJSONError(_ jsonText: String) -> SceneContextClientError {
    guard let data = jsonText.data(using: .utf8) else {
      return .malformedJSON("response was not UTF-8")
    }
    do {
      _ = try JSONSerialization.jsonObject(with: data)
      return .malformedJSON("The JSON shape did not match the activity mode schema")
    } catch {
      let nsError = error as NSError
      var detail = nsError.localizedDescription
      if let index = nsError.userInfo["NSJSONSerializationErrorIndex"] {
        detail += " index=\(index)"
      }
      return .malformedJSON(detail)
    }
  }

  static func streamSummaryFallbackReason(for error: Error) -> String {
    "\(errorKind(for: error)):\(sanitizedErrorDescription(error))"
  }

  private static func isRetryableStreamSummaryError(_ error: Error) -> Bool {
    if let urlError = error as? URLError {
      switch urlError.code {
      case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
           .dnsLookupFailed, .notConnectedToInternet, .internationalRoamingOff,
           .callIsActive, .dataNotAllowed:
        return true
      default:
        return false
      }
    }
    if let sceneError = error as? SceneContextClientError,
       case .badHTTPStatus(let status, _) = sceneError {
      return status == 408 || status == 409 || status == 425 || status == 429 || (500..<600).contains(status)
    }
    if isMalformedJSONError(error) {
      return true
    }
    return false
  }

  private static func isMalformedJSONError(_ error: Error) -> Bool {
    if let sceneError = error as? SceneContextClientError,
       case .malformedJSON = sceneError {
      return true
    }
    return false
  }

  private static func statusText(for error: Error) -> String {
    if let sceneError = error as? SceneContextClientError,
       case .badHTTPStatus(let status, _) = sceneError {
      return "\(status)"
    }
    return "none"
  }

  private static func errorKind(for error: Error) -> String {
    if let urlError = error as? URLError {
      return "url.\(urlError.code.rawValue)"
    }
    if let sceneError = error as? SceneContextClientError {
      switch sceneError {
      case .missingAPIKey: return "missingAPIKey"
      case .invalidBaseURL: return "invalidBaseURL"
      case .invalidResponse: return "invalidResponse"
      case .badHTTPStatus: return "badHTTPStatus"
      case .emptyContent: return "emptyContent"
      case .malformedJSON: return "malformedJSON"
      }
    }
    return String(describing: type(of: error))
  }

  private static func sanitizedErrorDescription(_ error: Error) -> String {
    if let sceneError = error as? SceneContextClientError,
       case .badHTTPStatus(_, let body) = sceneError {
      return sanitizedText(body, maxLength: 360)
    }
    return sanitizedText(error.localizedDescription, maxLength: 240)
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

private struct ChatRequest: Encodable {
  var model: String
  var messages: [ChatMessage]
  var temperature: Double
  var maxTokens: Int
  var enableThinking: Bool? = nil

  enum CodingKeys: String, CodingKey {
    case model
    case messages
    case temperature
    case maxTokens = "max_tokens"
    case enableThinking = "enable_thinking"
  }
}

private struct ChatMessage: Encodable {
  var role: String
  var content: [ChatContent]
}

private struct ChatContent: Encodable {
  var type: String
  var text: String?
  var imageURL: ImageURL?

  static func text(_ value: String) -> ChatContent {
    ChatContent(type: "text", text: value, imageURL: nil)
  }

  static func imageURL(_ value: String) -> ChatContent {
    ChatContent(type: "image_url", text: nil, imageURL: ImageURL(url: value))
  }

  enum CodingKeys: String, CodingKey {
    case type
    case text
    case imageURL = "image_url"
  }
}

private struct ImageURL: Encodable {
  var url: String
}

private struct ChatResponse: Decodable {
  var choices: [Choice]

  struct Choice: Decodable {
    var message: Message
  }

  struct Message: Decodable {
    var content: String
  }
}
