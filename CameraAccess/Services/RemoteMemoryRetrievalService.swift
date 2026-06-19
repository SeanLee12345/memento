import Foundation

enum MemorySourceType: String, Codable {
  case transcriptChunk = "transcript_chunk"
  case streamSummary = "stream_summary"
  case sceneContext = "scene_context"
  case personNote = "person_note"
}

struct RemoteMemoryChunk: Decodable, Identifiable {
  let id: UUID
  let conversationId: UUID?
  let streamId: UUID?
  let personId: UUID?
  let chunkText: String
  let summaryText: String?
  let keywords: [String]
  let categories: [String]
  let similarity: Double
  let finalScore: Double
  let sourceType: MemorySourceType
  let startTime: Date?
  let endTime: Date?
  let createdAt: Date
  let importanceScore: Double?
  let sensitivityLevel: Int
  let metadata: [String: AnyCodable]?

  var evidenceText: String {
    let preferred = summaryText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return preferred.isEmpty ? chunkText : preferred
  }

  private enum CodingKeys: String, CodingKey {
    case id = "memory_chunk_id"
    case conversationId = "conversation_id"
    case streamId = "stream_id"
    case personId = "person_id"
    case chunkText = "chunk_text"
    case summaryText = "summary_text"
    case keywords
    case categories
    case similarity
    case finalScore = "final_score"
    case sourceType = "source_type"
    case startTime = "start_time"
    case endTime = "end_time"
    case createdAt = "created_at"
    case importanceScore = "importance_score"
    case sensitivityLevel = "sensitivity_level"
    case metadata
  }
}

struct RemoteMemoryRetrievalResult {
  let query: String
  let keywords: [String]
  let categories: [String]
  let chunks: [RemoteMemoryChunk]
  let latencyMS: Int

  var evidenceText: String {
    chunks.map { chunk in
      let date = chunk.startTime ?? chunk.createdAt
      return [
        "Memory ID: \(chunk.id.uuidString)",
        "Source: \(chunk.sourceType.rawValue)",
        "When: \(date.formatted(date: .abbreviated, time: .shortened))",
        "Evidence: \(chunk.evidenceText)"
      ].joined(separator: "\n")
    }.joined(separator: "\n\n")
  }
}

struct MemoryRetrievalRequest: Encodable {
  let query: String
  let currentMode: String?
  let sceneContext: String?
  let presentPeople: [String]
  let personIds: [UUID]
  let activePersonIds: [UUID]
  let recentSummaries: [String]
  let exactWording: Bool
  let limit: Int
  let minSimilarity: Double
  let includeSourceTypes: [MemorySourceType]
  let maxSensitivity: Int
}

struct MemoryIndexRequest: Encodable {
  let id: UUID
  let sourceRecordId: UUID
  let sourceType: MemorySourceType
  let conversationId: UUID?
  let streamId: UUID?
  let personId: UUID?
  let chunkText: String
  let summaryText: String?
  let keywords: [String]
  let categories: [String]
  let startTime: Date?
  let endTime: Date?
  let importanceScore: Double?
  let sensitivityLevel: Int?
  let metadata: [String: String]
}

struct RecentMemoryContextBuilder {
  static let defaultLimit = 3

  static func summaries(
    from entries: [StreamSummaryHistoryEntry],
    limit: Int = defaultLimit
  ) -> [String] {
    entries
      .sorted { $0.endedAt > $1.endedAt }
      .prefix(max(0, limit))
      .map { entry in
        let people = entry.people.isEmpty ? entry.who : entry.people.joined(separator: ", ")
        return [
          entry.endedAt.formatted(date: .abbreviated, time: .shortened),
          people.isEmpty ? nil : "People: \(people)",
          entry.summary
        ]
        .compactMap { $0 }
        .joined(separator: " | ")
      }
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  }
}

enum RemoteMemoryIndexError: LocalizedError {
  case conversationParentNotSynced(UUID, attempts: Int, lastError: String?)

  var errorDescription: String? {
    switch self {
    case .conversationParentNotSynced(let id, let attempts, let lastError):
      let detail = lastError.map { " lastError=\($0)" } ?? ""
      return "Supabase conversation_sessions parent \(id.uuidString) was not available after \(attempts) checks.\(detail)"
    }
  }
}

final class RemoteMemoryRetrievalService {
  private struct RetrievalOutput: Decodable {
    let query: String
    let keywords: [String]
    let categories: [String]
    let chunks: [RemoteMemoryChunk]
    let latencyMs: Int
  }

  private struct IndexOutput: Decodable {
    let id: UUID
    let skipped: Bool
    let reason: String?
    let keywords: [String]?
    let categories: [String]?
    let sensitivityLevel: Int?
  }

  private struct ConversationParentRow: Decodable {
    let id: UUID
  }

  private let client: SupabaseEdgeFunctionClient
  private let databaseClient: SupabaseClient

  init(
    client: SupabaseEdgeFunctionClient? = nil,
    databaseClient: SupabaseClient? = nil
  ) throws {
    self.client = try client ?? SupabaseEdgeFunctionClient.shared()
    self.databaseClient = try databaseClient ?? SupabaseClient.shared()
  }

  func retrieve(_ request: MemoryRetrievalRequest) async throws -> RemoteMemoryRetrievalResult {
    let startedAt = Date()
    let response: AIProxyFunctionResponse<RetrievalOutput> = try await client.invoke(
      operation: "memory.retrieve",
      payload: request,
      timeoutInterval: 40
    )
    guard let output = response.output else {
      throw SupabaseEdgeFunctionError.missingOutput
    }
    let result = RemoteMemoryRetrievalResult(
      query: output.query,
      keywords: output.keywords,
      categories: output.categories,
      chunks: output.chunks,
      latencyMS: output.latencyMs
    )
    let ids = result.chunks.map { String($0.id.uuidString.prefix(8)) }.joined(separator: ",")
    AppLogger.log(
      .memory,
      "[MEMORY_RETRIEVAL] source=remote query=\"\(Self.logText(request.query))\" keywords=\(result.keywords.joined(separator: ",")) categories=\(result.categories.joined(separator: ",")) chunks=\(result.chunks.count) ids=\(ids.isEmpty ? "none" : ids) providerLatencyMs=\(result.latencyMS) totalLatencyMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
    )
    return result
  }

  func index(_ request: MemoryIndexRequest) async throws {
    if let conversationId = request.conversationId {
      try await waitForConversationParent(conversationId)
    }
    let response: AIProxyFunctionResponse<IndexOutput> = try await client.invoke(
      operation: "memory.index",
      payload: request,
      timeoutInterval: 45
    )
    guard let output = response.output else {
      throw SupabaseEdgeFunctionError.missingOutput
    }
    AppLogger.log(
      .memory,
      "[MEMORY_INDEX] id=\(output.id.uuidString.prefix(8)) source=\(request.sourceType.rawValue) skipped=\(output.skipped) reason=\(output.reason ?? "none") keywords=\(output.keywords?.count ?? 0) categories=\(output.categories?.count ?? 0)"
    )
  }

  static func parentRetryDelaySeconds(attempt: Int) -> TimeInterval {
    switch attempt {
    case ...1: return 0
    case 2: return 2
    case 3: return 4
    case 4: return 8
    case 5: return 16
    default: return 30
    }
  }

  static func shouldLogParentDeferredAttempt(attempt: Int, maxAttempts: Int) -> Bool {
    attempt == 1 || attempt == maxAttempts
  }

  private func waitForConversationParent(_ conversationId: UUID) async throws {
    let maxAttempts = 6
    var lastError: String?
    for attempt in 1...maxAttempts {
      let delay = Self.parentRetryDelaySeconds(attempt: attempt)
      if delay > 0 {
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      }
      do {
        let rows: [ConversationParentRow] = try await databaseClient.select(
          table: SupabaseTable.conversationSessions,
          columns: "id",
          filter: "id=eq.\(conversationId.uuidString)",
          limit: 1
        )
        if !rows.isEmpty {
          AppLogger.log(
            .memory,
            "[MEMORY_INDEX] parentReady conversation=\(conversationId.uuidString.prefix(8)) attempt=\(attempt)"
          )
          return
        }
        lastError = "parent row not visible"
      } catch {
        lastError = error.localizedDescription
      }
      if Self.shouldLogParentDeferredAttempt(attempt: attempt, maxAttempts: maxAttempts) {
        AppLogger.log(
          .memory,
          "[MEMORY_INDEX] parentDeferred conversation=\(conversationId.uuidString.prefix(8)) attempt=\(attempt)/\(maxAttempts) nextDelaySeconds=\(attempt < maxAttempts ? Int(Self.parentRetryDelaySeconds(attempt: attempt + 1)) : 0) reason=\(lastError ?? "unknown")"
        )
      }
    }
    throw RemoteMemoryIndexError.conversationParentNotSynced(
      conversationId,
      attempts: maxAttempts,
      lastError: lastError
    )
  }

  private static func logText(_ value: String) -> String {
    let collapsed = value
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return collapsed.count <= 120 ? collapsed : String(collapsed.prefix(120)) + "..."
  }
}
