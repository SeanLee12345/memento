import Foundation
import UIKit

// SyncingIdentityStore — the new default IdentityStore the pipeline talks to.
//
// Reads pass through to the local Core Data store unchanged (zero added
// latency on the streaming hot path). Writes hit local first; only if local
// succeeds do we enqueue a mirror op for IdentitySyncQueue, which drains to
// Supabase in the background with backoff + persistence.
//
// "No fallback without permission" rule: if local write fails, we propagate
// the error and skip the remote enqueue (there's nothing to mirror). If the
// remote write later fails, the queue retries up to maxAttempts and then
// moves the entry to a dead-letter file — never silently dropped.

final class SyncingIdentityStore: IdentityStore, @unchecked Sendable {
  private let local: LocalIdentityStore
  private let queue: IdentitySyncQueue
  private let backfill: IdentityBackfillCoordinator

  init(
    local: LocalIdentityStore = LocalIdentityStore(),
    remote: SupabaseIdentityStore? = SupabaseIdentityStore()
  ) {
    self.local = local
    self.queue = IdentitySyncQueue(remote: remote)
    self.backfill = IdentityBackfillCoordinator(local: local, queue: queue)
    if remote == nil {
      AppLogger.log(.database, "[SUPABASE_SYNC] running local-only — Supabase config missing; remote mirroring disabled")
    }
    Task { await backfill.runIfNeeded() }
  }

  // MARK: - Lifecycle

  func startAppRun(deviceId: String?) async throws -> AppRun {
    let run = try await local.startAppRun(deviceId: deviceId)
    await queue.enqueue(.appRun(run))
    return run
  }

  func endAppRun(_ appRunId: UUID) async throws {
    try await local.endAppRun(appRunId)
    // No need to re-enqueue here: the local store mutates the AppRun row
    // in place, and the cloud copy will catch up if we re-upsert.
    // Pull the updated row out via Core Data — but loadPeople etc. don't
    // expose a "fetch one AppRun" — so we just trust the next AppRun to
    // overwrite. Acceptable: ended_at is set when the local row ends, and
    // the next startAppRun replays the prior one isn't needed for cloud.
    // Tracking gap intentionally: see SUPABASE_SYNC log on endAppRun.
    AppLogger.log(.database, "[SUPABASE_SYNC] note: endAppRun does not mirror ended_at update — see SyncingIdentityStore.endAppRun")
  }

  func startConversationSession(
    appRunId: UUID, deviceId: String?, datDeviceId: String?
  ) async throws -> ConversationSession {
    let session = try await local.startConversationSession(
      appRunId: appRunId, deviceId: deviceId, datDeviceId: datDeviceId
    )
    await enqueueDependencies(appRunId: session.appRunId, conversationSessionId: nil)
    await queue.enqueue(.conversationSession(session))
    return session
  }

  func endConversationSession(_ sessionId: UUID) async throws {
    try await local.endConversationSession(sessionId)
    // Cloud sync gap (known, intentional in v1): we do NOT mirror the
    // end-of-life fields here because LocalIdentityStore doesn't expose a
    // by-id session fetch, and synthesizing a row from Date() would clobber
    // the real startedAt that's already in the cloud (upsert sends the full
    // row). The cloud row will receive the ended state the next time
    // updateConversationSession is called from a ViewModel that has the
    // full session object. Plug this with a PATCH-only path later if
    // session-end accuracy matters in dashboards.
    AppLogger.log(.database, "[SUPABASE_SYNC] note: endConversationSession not mirrored — session=\(sessionId.uuidString.prefix(8)) will reflect ended state on next full updateConversationSession()")
  }

  // MARK: - People

  func loadPeople() async throws -> [PersonProfile] {
    try await local.loadPeople()
  }

  func savePersonProfile(_ profile: PersonProfile, context: PipelineContext?) async throws {
    try await local.savePersonProfile(profile, context: context)
    await queue.enqueue(.personProfile(profile))
  }

  func updatePersonProfile(_ profile: PersonProfile, context: PipelineContext?) async throws {
    try await local.updatePersonProfile(profile, context: context)
    await queue.enqueue(.personProfile(profile))
  }

  func deletePersonProfile(id: UUID, context: PipelineContext?) async throws {
    try await local.deletePersonProfile(id: id, context: context)
    await queue.enqueue(.personDeleted(id))
  }

  func deleteFaceEnrollment(personId: UUID, context: PipelineContext?) async throws {
    try await local.deleteFaceEnrollment(personId: personId, context: context)
    await queue.enqueue(.faceEnrollmentDeleted(personId))
  }

  // MARK: - Embeddings

  func saveEmbedding(_ record: FaceEmbeddingRecord, context: PipelineContext?) async throws {
    try await local.saveEmbedding(record, context: context)
    // Local mutates `vector` to L2-normalized; we don't have access to the
    // normalized version without re-reading. Enqueue the normalized vector
    // by re-normalizing here too (cheap, deterministic).
    var mirrored = record
    mirrored.appRunId = mirrored.appRunId ?? context?.appRunId
    mirrored.conversationSessionId = mirrored.conversationSessionId ?? context?.conversationSessionId
    mirrored.vector = Self.l2Normalized(record.vector)
    mirrored.dimension = mirrored.vector.count
    await enqueueDependencies(
      appRunId: mirrored.appRunId,
      conversationSessionId: mirrored.conversationSessionId
    )
    // face_embeddings.person_id references person_profiles. Enqueue the parent
    // profile ahead of the child so the remote FK is always satisfied; the
    // queue's dependency ordering then drains the profile first.
    await enqueuePersonDependency(personId: mirrored.personId)
    await queue.enqueue(.faceEmbedding(mirrored, localImagePath: mirrored.sampleImageLocalPath))
  }

  func embeddingsForPerson(_ personId: UUID) async throws -> [FaceEmbeddingRecord] {
    try await local.embeddingsForPerson(personId)
  }

  func allEmbeddings() async throws -> [FaceEmbeddingRecord] {
    try await local.allEmbeddings()
  }

  func averagedEmbeddings() async throws -> [PersonAveragedEmbedding] {
    let averages = try await local.averagedEmbeddings()
    for avg in averages {
      // person_averaged_face_embeddings.person_id references person_profiles —
      // enqueue the parent profile first so the FK is satisfied remotely.
      await enqueuePersonDependency(personId: avg.personId)
      await queue.enqueue(.personAveragedEmbedding(avg))
    }
    return averages
  }

  // MARK: - Conversations + events

  func saveConversationSession(_ session: ConversationSession, context: PipelineContext?) async throws {
    try await local.saveConversationSession(session, context: context)
    await enqueueDependencies(appRunId: session.appRunId, conversationSessionId: nil)
    await queue.enqueue(.conversationSession(session))
  }

  func updateConversationSession(_ session: ConversationSession, context: PipelineContext?) async throws {
    try await local.updateConversationSession(session, context: context)
    await enqueueDependencies(appRunId: session.appRunId, conversationSessionId: nil)
    await queue.enqueue(.conversationSession(session))
  }

  func saveConversationEvent(_ event: ConversationEvent, context: PipelineContext?) async throws {
    try await local.saveConversationEvent(event, context: context)
    // Local converts the event into a TranscriptChunk internally. We replicate
    // the same conversion here so the cloud also gets a transcript_chunks row.
    guard let appRunId = context?.appRunId else { return }
    let sessionId = context?.conversationSessionId ?? event.sessionId
    let chunk = TranscriptChunk(
      id: event.id,
      appRunId: appRunId,
      conversationSessionId: sessionId,
      personId: event.visiblePersonId,
      activeIdentityState: event.attributionStatus.rawValue,
      text: event.transcriptText,
      isFinal: event.isFinal,
      startedAt: event.timestamp,
      endedAt: event.timestamp,
      transcriptUpdatedAt: event.timestamp,
      source: "AppleSpeech",
      createdAt: event.timestamp
    )
    await enqueueDependencies(appRunId: appRunId, conversationSessionId: sessionId)
    await queue.enqueue(.transcriptChunk(chunk))
  }

  func saveFaceDetectionEvent(_ event: FaceDetectionEvent, context: PipelineContext?) async throws {
    try await local.saveFaceDetectionEvent(event, context: context)
    await enqueueDependencies(appRunId: event.appRunId, conversationSessionId: event.conversationSessionId)
    await queue.enqueue(.faceDetectionEvent(event))
  }

  func saveTranscriptChunk(_ chunk: TranscriptChunk, context: PipelineContext?) async throws {
    try await local.saveTranscriptChunk(chunk, context: context)
    await enqueueDependencies(appRunId: chunk.appRunId, conversationSessionId: chunk.conversationSessionId)
    await queue.enqueue(.transcriptChunk(chunk))
  }

  func saveSceneContext(_ record: SceneContextRecord, context: PipelineContext?) async throws {
    try await local.saveSceneContext(record, context: context)
    await enqueueDependencies(appRunId: record.appRunId, conversationSessionId: record.conversationSessionId)
    await queue.enqueue(.sceneContext(record))
  }

  func updateSceneContext(_ record: SceneContextRecord, context: PipelineContext?) async throws {
    try await local.updateSceneContext(record, context: context)
    await enqueueDependencies(appRunId: record.appRunId, conversationSessionId: record.conversationSessionId)
    await queue.enqueue(.sceneContext(record))
  }

  func savePresenceEpisode(_ record: PresenceEpisodeRecord, context: PipelineContext?) async throws {
    try await local.savePresenceEpisode(record, context: context)
    await enqueueDependencies(appRunId: record.appRunId, conversationSessionId: record.conversationSessionId)
    await queue.enqueue(.presenceEpisode(record))
  }

  func saveActivityModeEpisode(_ record: ActivityModeEpisodeRecord, context: PipelineContext?) async throws {
    try await local.saveActivityModeEpisode(record, context: context)
    await enqueueDependencies(appRunId: record.appRunId, conversationSessionId: record.conversationSessionId)
    await queue.enqueue(.activityModeEpisode(record))
  }

  func saveGlassesDisplayInteraction(
    _ event: GlassesDisplayInteractionEvent, context: PipelineContext?
  ) async throws {
    try await local.saveGlassesDisplayInteraction(event, context: context)
    await enqueueDependencies(appRunId: event.appRunId, conversationSessionId: event.conversationSessionId)
    await queue.enqueue(.glassesDisplayInteraction(event))
  }

  func saveIdentityMatchEvent(_ event: IdentityMatchEvent, context: PipelineContext?) async throws {
    try await local.saveIdentityMatchEvent(event, context: context)
    await enqueueDependencies(appRunId: event.appRunId, conversationSessionId: event.conversationSessionId)
    await queue.enqueue(.identityMatchEvent(event))
  }

  func runSessionSnapshot(appRunId: UUID?, conversationSessionId: UUID?) async throws -> RunSessionSnapshot {
    try await local.runSessionSnapshot(appRunId: appRunId, conversationSessionId: conversationSessionId)
  }

  // MARK: - Clears (local-only by design)

  func clearIdentities(context: PipelineContext?) async throws {
    try await local.clearIdentities(context: context)
    AppLogger.log(.database, "[SUPABASE_SYNC] clearIdentities did NOT propagate to Supabase by design — use the dashboard or service-role script for cloud wipes")
  }

  func clearConversations(context: PipelineContext?) async throws {
    try await local.clearConversations(context: context)
    AppLogger.log(.database, "[SUPABASE_SYNC] clearConversations did NOT propagate to Supabase by design")
  }

  // MARK: - Read-only pass-throughs

  func transcriptChunksForPerson(_ personId: UUID) async throws -> [TranscriptChunk] {
    try await local.transcriptChunksForPerson(personId)
  }

  func transcriptChunksForConversationSessions(_ sessionIds: [UUID]) async throws -> [TranscriptChunk] {
    try await local.transcriptChunksForConversationSessions(sessionIds)
  }

  func sceneContextsForPerson(_ personId: UUID) async throws -> [SceneContextRecord] {
    try await local.sceneContextsForPerson(personId)
  }

  func sceneContextsForConversationSessions(_ sessionIds: [UUID]) async throws -> [SceneContextRecord] {
    try await local.sceneContextsForConversationSessions(sessionIds)
  }

  func glassesDisplayInteractionsForPerson(_ personId: UUID) async throws -> [GlassesDisplayInteractionEvent] {
    try await local.glassesDisplayInteractionsForPerson(personId)
  }

  func glassesDisplayInteractionsForConversationSessions(_ sessionIds: [UUID]) async throws -> [GlassesDisplayInteractionEvent] {
    try await local.glassesDisplayInteractionsForConversationSessions(sessionIds)
  }

  func thumbnailImage(forDisplayName displayName: String) -> UIImage? {
    local.thumbnailImage(forDisplayName: displayName)
  }

  // MARK: - Diagnostics

  func pendingSyncCount() async -> Int {
    await queue.pendingCount()
  }

  // MARK: - Utility

  private static func l2Normalized(_ vector: [Float]) -> [Float] {
    var sum: Float = 0
    for v in vector { sum += v * v }
    let norm = sum.squareRoot()
    guard norm > 0 else { return vector }
    return vector.map { $0 / norm }
  }

  /// Ensures the parent person_profiles row is enqueued ahead of any child row
  /// that references it (face embeddings, averaged embeddings). The queue's
  /// dependency ordering then drains the profile before the child, so the
  /// remote foreign key is never violated (no Postgres 23503 / HTTP 409).
  private func enqueuePersonDependency(personId: UUID?) async {
    guard let personId else { return }
    if let profile = try? await local.personProfile(id: personId) {
      await queue.enqueue(.personProfile(profile))
    } else {
      AppLogger.log(.database, "[SUPABASE_SYNC] missing local person dependency person=\(personId.uuidString.prefix(8)); child embedding may retry until parent profile exists")
    }
  }

  private func enqueueDependencies(appRunId: UUID?, conversationSessionId: UUID?) async {
    var resolvedAppRunId = appRunId
    if let conversationSessionId,
       let session = try? await local.conversationSession(id: conversationSessionId) {
      resolvedAppRunId = resolvedAppRunId ?? session.appRunId
      if let sessionAppRunId = session.appRunId,
         let run = try? await local.appRun(id: sessionAppRunId) {
        await queue.enqueue(.appRun(run))
      }
      await queue.enqueue(.conversationSession(session))
    } else if let conversationSessionId {
      AppLogger.log(.database, "[SUPABASE_SYNC] missing local conversation dependency session=\(conversationSessionId.uuidString.prefix(8)); child row may retry until parent is restored")
    }

    if let resolvedAppRunId,
       let run = try? await local.appRun(id: resolvedAppRunId) {
      await queue.enqueue(.appRun(run))
    } else if let resolvedAppRunId {
      AppLogger.log(.database, "[SUPABASE_SYNC] missing local appRun dependency appRun=\(resolvedAppRunId.uuidString.prefix(8)); child row may retry until parent is restored")
    }
  }
}

// MARK: - One-time backfill of existing local data into the sync queue

/// Walks the local store on first launch after the Supabase migration ships
/// and enqueues every existing row for upload. Idempotent (gated by
/// UserDefaults flag); safe to re-run by clearing the flag.
actor IdentityBackfillCoordinator {
  private let local: LocalIdentityStore
  private let queue: IdentitySyncQueue
  private let flagKey = "SupabaseSyncBackfillCompleted_v3_parentRepair"

  init(local: LocalIdentityStore, queue: IdentitySyncQueue) {
    self.local = local
    self.queue = queue
  }

  func runIfNeeded() async {
    if UserDefaults.standard.bool(forKey: flagKey) { return }
    AppLogger.log(.database, "[SUPABASE_SYNC] backfill starting — mirroring existing local rows to Supabase")
    do {
      let appRuns = try await local.allAppRuns()
      for run in appRuns {
        await queue.enqueue(.appRun(run))
      }
      let people = try await local.loadPeople()
      for profile in people {
        await queue.enqueue(.personProfile(profile))
      }
      let sessions = try await local.allConversationSessions()
      for session in sessions {
        await queue.enqueue(.conversationSession(session))
      }
      let embeddings = try await local.allEmbeddings()
      for record in embeddings {
        await queue.enqueue(.faceEmbedding(record, localImagePath: record.sampleImageLocalPath))
      }
      let averages = try await local.averagedEmbeddings()
      for avg in averages {
        await queue.enqueue(.personAveragedEmbedding(avg))
      }
      AppLogger.log(.database, "[SUPABASE_SYNC] backfill enqueued appRuns=\(appRuns.count) people=\(people.count) sessions=\(sessions.count) embeddings=\(embeddings.count) averages=\(averages.count)")
      UserDefaults.standard.set(true, forKey: flagKey)
    } catch {
      AppLogger.log(.database, "[SUPABASE_SYNC] backfill aborted: \(error.localizedDescription) — will retry next launch")
    }
  }
}
