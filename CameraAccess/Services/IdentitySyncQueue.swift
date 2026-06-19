import Foundation
import UIKit

protocol IdentitySyncRemote: Sendable {
  func upsertAppRun(_ run: AppRun) async throws
  func upsertPersonProfile(_ profile: PersonProfile) async throws
  func deletePersonProfile(id: UUID) async throws
  func deleteFaceEmbeddingsForPerson(personId: UUID) async throws
  func upsertConversationSession(_ session: ConversationSession) async throws
  func upsertFaceEmbedding(
    _ record: FaceEmbeddingRecord,
    image: SupabaseIdentityStore.FaceCropImageSource?
  ) async throws
  func upsertPersonAveragedEmbedding(_ avg: PersonAveragedEmbedding) async throws
  func upsertTranscriptChunk(_ chunk: TranscriptChunk) async throws
  func insertFaceDetectionEvent(_ event: FaceDetectionEvent) async throws
  func insertIdentityMatchEvent(_ event: IdentityMatchEvent) async throws
  func upsertSceneContext(_ record: SceneContextRecord) async throws
  func upsertPresenceEpisode(_ record: PresenceEpisodeRecord) async throws
  func upsertActivityModeEpisode(_ record: ActivityModeEpisodeRecord) async throws
  func insertGlassesDisplayInteraction(_ event: GlassesDisplayInteractionEvent) async throws
}

extension SupabaseIdentityStore: IdentitySyncRemote {}

// IdentitySyncQueue — durable retry queue for Supabase mirror writes.
//
// SyncingIdentityStore performs the local write synchronously (which must
// succeed) and then enqueues a mirror operation here. A background task
// drains the queue with exponential backoff. The queue is persisted to a
// JSON file in Application Support so pending ops survive app restarts.
//
// Per the user's "no fallback without permission" rule, the queue does NOT
// silently degrade. Every state change is logged to AppLogger.SUPABASE_SYNC
// so divergence between local and cloud is observable.

actor IdentitySyncQueue {
  enum Operation: Codable, Equatable {
    case appRun(AppRun)
    case personProfile(PersonProfile)
    case personDeleted(UUID)
    case faceEnrollmentDeleted(UUID)
    case conversationSession(ConversationSession)
    case faceEmbedding(FaceEmbeddingRecord, localImagePath: String?)
    case personAveragedEmbedding(PersonAveragedEmbedding)
    case transcriptChunk(TranscriptChunk)
    case faceDetectionEvent(FaceDetectionEvent)
    case identityMatchEvent(IdentityMatchEvent)
    case sceneContext(SceneContextRecord)
    case presenceEpisode(PresenceEpisodeRecord)
    case activityModeEpisode(ActivityModeEpisodeRecord)
    case glassesDisplayInteraction(GlassesDisplayInteractionEvent)

    var label: String {
      switch self {
      case .appRun: "appRun"
      case .personProfile: "personProfile"
      case .personDeleted: "personDeleted"
      case .faceEnrollmentDeleted: "faceEnrollmentDeleted"
      case .conversationSession: "conversationSession"
      case .faceEmbedding: "faceEmbedding"
      case .personAveragedEmbedding: "personAveragedEmbedding"
      case .transcriptChunk: "transcriptChunk"
      case .faceDetectionEvent: "faceDetectionEvent"
      case .identityMatchEvent: "identityMatchEvent"
      case .sceneContext: "sceneContext"
      case .presenceEpisode: "presenceEpisode"
      case .activityModeEpisode: "activityModeEpisode"
      case .glassesDisplayInteraction: "glassesDisplayInteraction"
      }
    }

    var dependencyPriority: Int {
      switch self {
      case .appRun:
        return 0
      case .personProfile:
        return 1
      case .conversationSession:
        return 2
      case .faceEmbedding, .personAveragedEmbedding:
        return 4
      case .transcriptChunk, .faceDetectionEvent, .identityMatchEvent, .sceneContext, .presenceEpisode, .activityModeEpisode, .glassesDisplayInteraction:
        return 5
      case .personDeleted, .faceEnrollmentDeleted:
        return 6
      }
    }

    var deduplicationKey: String {
      switch self {
      case .appRun(let run):
        return "appRun:\(run.id.uuidString)"
      case .personProfile(let profile):
        return "personProfile:\(profile.id.uuidString)"
      case .personDeleted(let id):
        return "personDeleted:\(id.uuidString)"
      case .faceEnrollmentDeleted(let id):
        return "faceEnrollmentDeleted:\(id.uuidString)"
      case .conversationSession(let session):
        return "conversationSession:\(session.id.uuidString)"
      case .faceEmbedding(let record, _):
        return "faceEmbedding:\(record.id.uuidString)"
      case .personAveragedEmbedding(let avg):
        return [
          "personAveragedEmbedding",
          avg.personId.uuidString,
          avg.modelName,
          avg.modelVersion,
          avg.preprocessingVersion
        ].joined(separator: ":")
      case .transcriptChunk(let chunk):
        return "transcriptChunk:\(chunk.id.uuidString)"
      case .faceDetectionEvent(let event):
        return "faceDetectionEvent:\(event.id.uuidString)"
      case .identityMatchEvent(let event):
        return "identityMatchEvent:\(event.id.uuidString)"
      case .sceneContext(let record):
        return "sceneContext:\(record.id.uuidString)"
      case .presenceEpisode(let record):
        return "presenceEpisode:\(record.id.uuidString)"
      case .activityModeEpisode(let record):
        return "activityModeEpisode:\(record.id.uuidString)"
      case .glassesDisplayInteraction(let event):
        return "glassesDisplayInteraction:\(event.id.uuidString)"
      }
    }
  }

  struct Entry: Codable {
    let id: UUID
    var operation: Operation
    var attempts: Int
    var lastError: String?
    let enqueuedAt: Date
  }

  // MARK: - Configuration

  private let maxAttempts: Int
  private let baseBackoff: TimeInterval
  private let maxBackoff: TimeInterval
  private let persistURL: URL
  private let remote: (any IdentitySyncRemote)?

  private var entries: [Entry] = []
  private var loggedLocalOnlySkip = false
  private var drainTask: Task<Void, Never>?
  private var notificationObservers: [NSObjectProtocol] = []

  // MARK: - Init

  init(
    remote: (any IdentitySyncRemote)?,
    fileManager: FileManager = .default,
    persistenceDirectory: URL? = nil,
    maxAttempts: Int = 8,
    baseBackoff: TimeInterval = 2,
    maxBackoff: TimeInterval = 60
  ) {
    self.remote = remote
    self.maxAttempts = max(1, maxAttempts)
    self.baseBackoff = max(0, baseBackoff)
    self.maxBackoff = max(0, maxBackoff)
    let directory: URL
    if let persistenceDirectory {
      directory = persistenceDirectory
    } else {
      let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? fileManager.temporaryDirectory
      directory = base.appendingPathComponent("MetaFaceIdentity", isDirectory: true)
    }
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    persistURL = directory.appendingPathComponent("supabase-sync-queue.json")
    Task { await self.bootstrap() }
  }

  // MARK: - Public API

  /// Adds a new operation to the tail of the queue and kicks the drain task.
  func enqueue(_ operation: Operation) {
    // No Supabase remote configured: stay fully local. Don't accumulate queue
    // entries on disk that can never drain (scheduleDrain also gates on remote),
    // and don't attempt any storage/upsert work that requires Supabase.
    guard remote != nil else {
      if !loggedLocalOnlySkip {
        loggedLocalOnlySkip = true
        AppLogger.log(.database, "[SUPABASE_SYNC] local-only mode — skipping enqueue (Supabase not configured); no remote uploads or retries will be attempted")
      }
      return
    }
    let key = operation.deduplicationKey
    if let index = entries.firstIndex(where: { $0.operation.deduplicationKey == key }) {
      entries[index].operation = operation
      entries[index].lastError = nil
      sortByDependencies()
      persist()
      scheduleDrain()
      return
    }
    let entry = Entry(id: UUID(), operation: operation, attempts: 0, lastError: nil, enqueuedAt: Date())
    entries.append(entry)
    sortByDependencies()
    persist()
    AppLogger.log(.database, "[SUPABASE_SYNC] enqueued kind=\(operation.label) depth=\(entries.count) entry=\(entry.id.uuidString.prefix(8))")
    scheduleDrain()
  }

  /// Force the queue to attempt to drain immediately. Called on app foreground
  /// and from network reachability hooks.
  func kick() {
    restoreRecoverableDeadLetters()
    scheduleDrain()
  }

  func pendingCount() -> Int { entries.count }
  func snapshot() -> [Entry] { entries }

  // MARK: - Drain loop

  private func bootstrap() {
    loadFromDisk()
    restoreRecoverableDeadLetters()
    if !entries.isEmpty {
      sortByDependencies()
      persist()
      AppLogger.log(.database, "[SUPABASE_SYNC] restored pending=\(entries.count) from disk")
      scheduleDrain()
    }
    Task { await registerForegroundObserver() }
  }

  @MainActor
  private func registerForegroundObserver() async {
    let center = NotificationCenter.default
    let token = center.addObserver(
      forName: UIApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { await self?.kick() }
    }
    await self.storeObserverToken(token)
  }

  private func storeObserverToken(_ token: NSObjectProtocol) {
    notificationObservers.append(token)
  }

  private func scheduleDrain() {
    guard remote != nil, !entries.isEmpty else { return }
    sortByDependencies()
    if drainTask != nil { return }
    drainTask = Task { await self.drain() }
  }

  private func drain() async {
    defer { drainTask = nil }
    while !entries.isEmpty {
      sortByDependencies()
      guard let next = entries.first else { return }
      do {
        try await apply(next.operation)
        guard let index = entries.firstIndex(where: { $0.id == next.id }) else {
          continue
        }
        guard entries[index].operation == next.operation else {
          continue
        }
        entries.remove(at: index)
        persist()
        AppLogger.log(.database, "[SUPABASE_SYNC] applied kind=\(next.operation.label) entry=\(next.id.uuidString.prefix(8)) remaining=\(entries.count)")
      } catch {
        guard let index = entries.firstIndex(where: { $0.id == next.id }) else {
          continue
        }
        guard entries[index].operation == next.operation else {
          continue
        }
        var updated = entries[index]
        updated.attempts += 1
        updated.lastError = Self.terminalSchemaMismatchMessage(
          for: updated.operation,
          error: error
        ) ?? error.localizedDescription
        // Foreign-key ordering races are retried with backoff, but remain
        // bounded. A missing parent must not spin forever if it can never be
        // reconstructed locally or is rejected remotely.
        if Self.isRecoverableDependencyFailure(updated.lastError) {
          if updated.attempts >= maxAttempts {
            updated.lastError = [
              "Terminal parent dependency unresolved after \(updated.attempts) attempts.",
              "The child row was not dropped; it is archived in the Supabase sync dead-letter file.",
              "Re-enqueue the parent and child explicitly after repairing the missing or inaccessible parent row."
            ].joined(separator: " ")
            archiveDeadLetter(updated)
            entries.remove(at: index)
            persist()
            AppLogger.log(
              .database,
              "[SUPABASE_SYNC] dependency-terminal kind=\(updated.operation.label) entry=\(updated.id.uuidString.prefix(8)) attempts=\(updated.attempts) reason=parent-not-yet-synced action=dead-letter"
            )
            continue
          }
          entries[index] = updated
          sortByDependencies()
          persist()
          let delay = min(maxBackoff, baseBackoff * pow(2, Double(max(0, updated.attempts - 1))))
          if Self.shouldLogRecoverableDependencyDeferral(attempts: updated.attempts, maxAttempts: maxAttempts) {
            AppLogger.log(.database, "[SUPABASE_SYNC] deferred kind=\(updated.operation.label) entry=\(updated.id.uuidString.prefix(8)) reason=parent-not-yet-synced attempts=\(updated.attempts) sleep=\(String(format: "%.1f", delay))s — requeue until parent row exists")
          }
          try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
          continue
        }
        if Self.isTerminalSchemaMismatch(updated.lastError, operation: updated.operation) {
          archiveDeadLetter(updated)
          entries.remove(at: index)
          persist()
          AppLogger.log(
            .database,
            "[SUPABASE_SYNC] schema-mismatch kind=\(updated.operation.label) entry=\(updated.id.uuidString.prefix(8)) action=schema-pending retry=foreground-or-relaunch reason=\(updated.lastError ?? "unknown")"
          )
          continue
        }
        if updated.attempts >= maxAttempts {
          // Move to dead-letter at the tail by removing — but keep it logged
          // loudly. We do NOT silently drop: persist a sibling file so the
          // user/admin can inspect it later.
          archiveDeadLetter(updated)
          entries.remove(at: index)
          persist()
          AppLogger.log(.database, "[SUPABASE_SYNC] dead-letter kind=\(updated.operation.label) entry=\(updated.id.uuidString.prefix(8)) attempts=\(updated.attempts) reason=\(updated.lastError ?? "unknown")")
        } else {
          entries[index] = updated
          sortByDependencies()
          persist()
          let delay = min(maxBackoff, baseBackoff * pow(2, Double(updated.attempts - 1)))
          AppLogger.log(.database, "[SUPABASE_SYNC] retry kind=\(updated.operation.label) entry=\(updated.id.uuidString.prefix(8)) attempt=\(updated.attempts) sleep=\(String(format: "%.1f", delay))s reason=\(updated.lastError ?? "unknown")")
          try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
      }
    }
  }

  private func apply(_ op: Operation) async throws {
    guard let remote else {
      throw SupabaseClientError.missingConfiguration
    }
    switch op {
    case .appRun(let run):
      try await remote.upsertAppRun(run)
    case .personProfile(let profile):
      try await remote.upsertPersonProfile(profile)
    case .personDeleted(let id):
      try await remote.deletePersonProfile(id: id)
    case .faceEnrollmentDeleted(let id):
      try await remote.deleteFaceEmbeddingsForPerson(personId: id)
    case .conversationSession(let session):
      try await remote.upsertConversationSession(session)
    case let .faceEmbedding(record, localImagePath):
      let image: SupabaseIdentityStore.FaceCropImageSource? = localImagePath
        .map { .localPath($0) }
      try await remote.upsertFaceEmbedding(record, image: image)
    case .personAveragedEmbedding(let avg):
      try await remote.upsertPersonAveragedEmbedding(avg)
    case .transcriptChunk(let chunk):
      try await remote.upsertTranscriptChunk(chunk)
    case .faceDetectionEvent(let event):
      try await remote.insertFaceDetectionEvent(event)
    case .identityMatchEvent(let event):
      try await remote.insertIdentityMatchEvent(event)
    case .sceneContext(let record):
      try await remote.upsertSceneContext(record)
    case .presenceEpisode(let record):
      try await remote.upsertPresenceEpisode(record)
    case .activityModeEpisode(let record):
      try await remote.upsertActivityModeEpisode(record)
    case .glassesDisplayInteraction(let event):
      try await remote.insertGlassesDisplayInteraction(event)
    }
  }

  // MARK: - Persistence

  private func loadFromDisk() {
    guard let data = try? Data(contentsOf: persistURL) else { return }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    if let restored = try? decoder.decode([Entry].self, from: data) {
      entries = restored
    } else {
      AppLogger.log(.database, "[SUPABASE_SYNC] failed to decode queue file at \(persistURL.path) — starting fresh (file preserved as .corrupt)")
      let corrupt = persistURL.deletingPathExtension().appendingPathExtension("corrupt")
      try? FileManager.default.moveItem(at: persistURL, to: corrupt)
    }
  }

  private func persist() {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(entries) else { return }
    try? data.write(to: persistURL, options: .atomic)
  }

  private func sortByDependencies() {
    entries.sort { lhs, rhs in
      let lhsPriority = lhs.operation.dependencyPriority
      let rhsPriority = rhs.operation.dependencyPriority
      if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
      if lhs.enqueuedAt != rhs.enqueuedAt { return lhs.enqueuedAt < rhs.enqueuedAt }
      return lhs.id.uuidString < rhs.id.uuidString
    }
  }

  private func archiveDeadLetter(_ entry: Entry) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(entry) else { return }
    var payload = data
    payload.append(0x0A) // newline
    if FileManager.default.fileExists(atPath: deadLetterURL.path),
       let handle = try? FileHandle(forWritingTo: deadLetterURL) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: payload)
    } else {
      try? payload.write(to: deadLetterURL, options: .atomic)
    }
  }

  private var deadLetterURL: URL {
    persistURL.deletingLastPathComponent().appendingPathComponent("supabase-sync-dead-letter.jsonl")
  }

  private func restoreRecoverableDeadLetters() {
    guard let data = try? Data(contentsOf: deadLetterURL),
          let text = String(data: data, encoding: .utf8) else { return }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var retainedLines: [String] = []
    var restored = 0

    for rawLine in text.split(whereSeparator: \.isNewline) {
      let line = String(rawLine)
      guard let lineData = line.data(using: .utf8),
            var entry = try? decoder.decode(Entry.self, from: lineData) else {
        retainedLines.append(line)
        continue
      }
      guard Self.isRecoverableDeadLetter(entry.lastError) else {
        retainedLines.append(line)
        continue
      }
      entry.attempts = 0
      entry.lastError = nil
      if !entries.contains(where: { $0.operation.deduplicationKey == entry.operation.deduplicationKey }) {
        entries.append(entry)
        restored += 1
      }
    }

    if retainedLines.isEmpty {
      try? FileManager.default.removeItem(at: deadLetterURL)
    } else {
      let retained = retainedLines.joined(separator: "\n") + "\n"
      try? Data(retained.utf8).write(to: deadLetterURL, options: .atomic)
    }

    if restored > 0 {
      AppLogger.log(.database, "[SUPABASE_SYNC] restored recoverable dead-letter entries=\(restored)")
    }
  }

  private static func isRecoverableDependencyFailure(_ message: String?) -> Bool {
    guard let message = message?.lowercased() else { return false }
    return message.contains("\"23503\"")
      || message.contains("foreign key constraint")
      || message.contains("is not present in table")
  }

  static func shouldLogRecoverableDependencyDeferral(attempts: Int, maxAttempts: Int) -> Bool {
    attempts <= 1 || attempts >= maxAttempts - 1
  }

  private static func isRecoverableDeadLetter(_ message: String?) -> Bool {
    isRecoverableDependencyFailure(message) || isRecoverableSchemaMismatch(message)
  }

  private static func isRecoverableSchemaMismatch(_ message: String?) -> Bool {
    guard let message = message?.lowercased() else { return false }
    return message.contains("schema requires supabase vector dimension migration")
      || (
        message.contains("expected")
          && message.contains("dimensions")
          && message.contains("not")
      )
      || message.contains("no unique or exclusion constraint matching the on conflict specification")
  }

  private static func isTerminalSchemaMismatch(_ message: String?, operation: Operation) -> Bool {
    guard let message = message?.lowercased(),
          operation.carriesFaceEmbeddingVector else { return false }
    return message.contains("schema requires supabase vector dimension migration")
      || message.contains("schema requires supabase averaged face embedding model-space unique key")
      || message.contains("no unique or exclusion constraint matching the on conflict specification")
      || (message.contains("expected") && message.contains("dimensions") && message.contains("not"))
  }

  private static func terminalSchemaMismatchMessage(
    for operation: Operation,
    error: Error
  ) -> String? {
    guard operation.carriesFaceEmbeddingVector else { return nil }
    let message = error.localizedDescription
    let lower = message.lowercased()
    if lower.contains("no unique or exclusion constraint matching the on conflict specification") {
      return [
        "Schema requires Supabase averaged face embedding model-space unique key.",
        "Remote person_averaged_face_embeddings cannot upsert by person, model, source, preprocessing, and vector dimension yet.",
        "Apply supabase/migrations/0007_person_average_embedding_space_key.sql; the app will restore this entry from schema-pending storage on foreground or relaunch.",
        "Original error: \(message)"
      ].joined(separator: " ")
    }
    guard lower.contains("expected"),
          lower.contains("dimensions"),
          lower.contains("not") else { return nil }

    let actualDimension: Int?
    switch operation {
    case .faceEmbedding(let record, _):
      actualDimension = record.dimension
    case .personAveragedEmbedding(let avg):
      actualDimension = avg.vectorDimension
    default:
      actualDimension = nil
    }

    let actualText = actualDimension.map(String.init) ?? "unknown"
    return [
      "Schema requires Supabase vector dimension migration.",
      "Remote face embedding columns still reject \(actualText)-dimension vectors.",
      "Apply supabase/migrations/0006_relax_face_embedding_vector_dimensions.sql and supabase/migrations/0007_person_average_embedding_space_key.sql; the app will restore this entry from schema-pending storage on foreground or relaunch.",
      "Original error: \(message)"
    ].joined(separator: " ")
  }
}

private extension IdentitySyncQueue.Operation {
  var carriesFaceEmbeddingVector: Bool {
    switch self {
    case .faceEmbedding, .personAveragedEmbedding:
      return true
    default:
      return false
    }
  }
}
