import CoreData
import Foundation
import UIKit

enum LocalIdentityStoreError: LocalizedError {
  case persistentStoreUnavailable(String)

  var errorDescription: String? {
    switch self {
    case .persistentStoreUnavailable(let detail):
      "MetaFace identity store is unavailable: \(detail)"
    }
  }
}

protocol IdentityStore {
  func startAppRun(deviceId: String?) async throws -> AppRun
  func endAppRun(_ appRunId: UUID) async throws
  func startConversationSession(appRunId: UUID, deviceId: String?, datDeviceId: String?) async throws -> ConversationSession
  func endConversationSession(_ sessionId: UUID) async throws
  func loadPeople() async throws -> [PersonProfile]
  func savePersonProfile(_ profile: PersonProfile, context: PipelineContext?) async throws
  func updatePersonProfile(_ profile: PersonProfile, context: PipelineContext?) async throws
  func deletePersonProfile(id: UUID, context: PipelineContext?) async throws
  func deleteFaceEnrollment(personId: UUID, context: PipelineContext?) async throws
  func saveEmbedding(_ record: FaceEmbeddingRecord, context: PipelineContext?) async throws
  func embeddingsForPerson(_ personId: UUID) async throws -> [FaceEmbeddingRecord]
  func allEmbeddings() async throws -> [FaceEmbeddingRecord]
  func averagedEmbeddings() async throws -> [PersonAveragedEmbedding]
  func saveConversationSession(_ session: ConversationSession, context: PipelineContext?) async throws
  func updateConversationSession(_ session: ConversationSession, context: PipelineContext?) async throws
  func saveConversationEvent(_ event: ConversationEvent, context: PipelineContext?) async throws
  func saveFaceDetectionEvent(_ event: FaceDetectionEvent, context: PipelineContext?) async throws
  func saveTranscriptChunk(_ chunk: TranscriptChunk, context: PipelineContext?) async throws
  func saveSceneContext(_ record: SceneContextRecord, context: PipelineContext?) async throws
  func updateSceneContext(_ record: SceneContextRecord, context: PipelineContext?) async throws
  func savePresenceEpisode(_ record: PresenceEpisodeRecord, context: PipelineContext?) async throws
  func saveActivityModeEpisode(_ record: ActivityModeEpisodeRecord, context: PipelineContext?) async throws
  func saveGlassesDisplayInteraction(_ event: GlassesDisplayInteractionEvent, context: PipelineContext?) async throws
  func saveIdentityMatchEvent(_ event: IdentityMatchEvent, context: PipelineContext?) async throws
  func runSessionSnapshot(appRunId: UUID?, conversationSessionId: UUID?) async throws -> RunSessionSnapshot
  func clearIdentities(context: PipelineContext?) async throws
  func clearConversations(context: PipelineContext?) async throws
  func transcriptChunksForPerson(_ personId: UUID) async throws -> [TranscriptChunk]
  func transcriptChunksForConversationSessions(_ sessionIds: [UUID]) async throws -> [TranscriptChunk]
  func sceneContextsForPerson(_ personId: UUID) async throws -> [SceneContextRecord]
  func sceneContextsForConversationSessions(_ sessionIds: [UUID]) async throws -> [SceneContextRecord]
  func glassesDisplayInteractionsForPerson(_ personId: UUID) async throws -> [GlassesDisplayInteractionEvent]
  func glassesDisplayInteractionsForConversationSessions(_ sessionIds: [UUID]) async throws -> [GlassesDisplayInteractionEvent]
  func thumbnailImage(forDisplayName displayName: String) -> UIImage?
}

final class LocalIdentityStore: IdentityStore, @unchecked Sendable {
  private let container: NSPersistentContainer
  private let context: NSManagedObjectContext
  private let storeLoaded: Bool
  private let storeLoadError: Error?
  private let fileManager: FileManager
  private let identityDirectory: URL

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
    let model = Self.makeModel()
    let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    let directory = base.appendingPathComponent("MetaFaceIdentity", isDirectory: true)
    identityDirectory = directory
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let storeURL = directory.appendingPathComponent("MetaFaceIdentity.sqlite")

    let initialContainer = Self.makeContainer(model: model, storeURL: storeURL)
    var loadResult = Self.loadPersistentStores(container: initialContainer)
    var selectedContainer = initialContainer
    if let error = loadResult.error {
      AppLogger.log(.database, "Core Data store load failed: \(error.localizedDescription)")
      if Self.backupIncompatibleStore(at: storeURL, fileManager: fileManager, reason: error) {
        let retryContainer = Self.makeContainer(model: model, storeURL: storeURL)
        loadResult = Self.loadPersistentStores(container: retryContainer)
        selectedContainer = retryContainer
        if let retryError = loadResult.error {
          AppLogger.log(.database, "Core Data store retry failed after backup: \(retryError.localizedDescription)")
        } else {
          AppLogger.log(.database, "Core Data store recreated after incompatible migration backup")
        }
      }
    }

    container = selectedContainer
    storeLoaded = loadResult.loaded
    storeLoadError = loadResult.error
    context = container.newBackgroundContext()
    context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    context.undoManager = nil
  }

  private func requireStoreLoaded() throws {
    guard storeLoaded, !container.persistentStoreCoordinator.persistentStores.isEmpty else {
      let detail = storeLoadError?.localizedDescription ?? "persistent store was not loaded"
      AppLogger.log(.database, "Skipping identity persistence because Core Data store is unavailable: \(detail)")
      throw LocalIdentityStoreError.persistentStoreUnavailable(detail)
    }
  }

  func startAppRun(deviceId: String?) async throws -> AppRun {
    try requireStoreLoaded()
    let now = Date()
    let run = AppRun(
      id: UUID(),
      startedAt: now,
      endedAt: nil,
      appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
      appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
      deviceId: deviceId,
      notes: nil,
      createdAt: now
    )
    try await context.perform {
      let object = NSEntityDescription.insertNewObject(forEntityName: "AppRun", into: self.context)
      self.write(run, to: object)
      try self.context.save()
    }
    AppLogger.log(.runSession, "AppRun created appRun=\(run.id.uuidString) deviceId=\(deviceId ?? "none")")
    return run
  }

  func endAppRun(_ appRunId: UUID) async throws {
    try requireStoreLoaded()
    try await context.perform {
      guard let object = try self.fetchOne(entity: "AppRun", id: appRunId) else { return }
      object.setValue(Date(), forKey: "endedAt")
      try self.context.save()
    }
    AppLogger.log(.runSession, "AppRun closed appRun=\(appRunId.uuidString)")
  }

  func startConversationSession(appRunId: UUID, deviceId: String?, datDeviceId: String?) async throws -> ConversationSession {
    let now = Date()
    let session = ConversationSession(
      id: UUID(),
      personId: nil,
      startedAt: now,
      endedAt: nil,
      confidence: 0,
      status: .active,
      appRunId: appRunId,
      deviceId: deviceId,
      datDeviceId: datDeviceId,
      streamStartedAt: now,
      streamEndedAt: nil,
      state: "streaming",
      createdAt: now,
      updatedAt: now
    )
    try await saveConversationSession(session, context: PipelineContext(appRunId: appRunId, conversationSessionId: session.id, datDeviceId: datDeviceId))
    AppLogger.log(.runSession, "ConversationSession created appRun=\(appRunId.uuidString) session=\(session.id.uuidString) datDeviceId=\(datDeviceId ?? "none")")
    return session
  }

  func endConversationSession(_ sessionId: UUID) async throws {
    let now = Date()
    try await context.perform {
      guard let object = try self.fetchOne(entity: "ConversationSession", id: sessionId) else { return }
      object.setValue(now, forKey: "endedAt")
      object.setValue(now, forKey: "streamEndedAt")
      object.setValue("ended", forKey: "state")
      object.setValue(now, forKey: "updatedAt")
      try self.context.save()
    }
    AppLogger.log(.runSession, "ConversationSession closed session=\(sessionId.uuidString)")
  }

  func loadPeople() async throws -> [PersonProfile] {
    try requireStoreLoaded()
    let people = try await context.perform {
      try self.fetch(entity: "PersonProfile").compactMap(self.readPersonProfile)
    }
    let embeddings = try await allEmbeddings()
    AppLogger.log(.vectorStore, "loadedProfiles=\(people.count) loadedEmbeddings=\(embeddings.count)")
    return people.filter { $0.enrollmentStatus != .deleted }
  }

  func savePersonProfile(_ profile: PersonProfile, context pipelineContext: PipelineContext?) async throws {
    try requireStoreLoaded()
    try await self.context.perform {
      let object = try self.fetchOne(entity: "PersonProfile", id: profile.id)
        ?? NSEntityDescription.insertNewObject(forEntityName: "PersonProfile", into: self.context)
      self.write(profile, to: object)
      try self.context.save()
    }
    AppLogger.log(.database, "\(pipelineContext.logPrefix) entity=PersonProfile saved id=\(profile.id.uuidString)")
  }

  func updatePersonProfile(_ profile: PersonProfile, context pipelineContext: PipelineContext?) async throws {
    try await savePersonProfile(profile, context: pipelineContext)
  }

  func deletePersonProfile(id: UUID, context pipelineContext: PipelineContext?) async throws {
    try requireStoreLoaded()
    var deletedDisplayName: String?
    try await self.context.perform {
      if let person = try self.fetchOne(entity: "PersonProfile", id: id) {
        deletedDisplayName = person.value(forKey: "displayName") as? String
        person.setValue("deleted", forKey: "enrollmentStatus")
        person.setValue(Date(), forKey: "updatedAt")
      }
      try self.delete(entity: "FaceEmbeddingSample", predicate: NSPredicate(format: "personId == %@", id as CVarArg))
      try self.delete(entity: "PersonAveragedEmbedding", predicate: NSPredicate(format: "personId == %@", id as CVarArg))
      try self.delete(entity: "SceneContextRecord", predicate: NSPredicate(format: "personId == %@", id as CVarArg))
      try self.delete(entity: "GlassesDisplayInteractionEvent", predicate: NSPredicate(format: "personId == %@", id as CVarArg))
      try self.delete(entity: "PresenceEpisodeRecord", predicate: NSPredicate(format: "personId == %@", id as CVarArg))
      let chunks = try self.fetch(entity: "TranscriptChunk", predicate: NSPredicate(format: "personId == %@", id as CVarArg))
      for chunk in chunks {
        chunk.setValue(nil, forKey: "personId")
        chunk.setValue("unknown", forKey: "activeIdentityState")
      }
      try self.context.save()
    }
    let removedFiles = clearIdentityImageFiles(nameHint: deletedDisplayName)
    AppLogger.log(.database, "\(pipelineContext.logPrefix) entity=PersonProfile deleted id=\(id.uuidString) name=\(deletedDisplayName ?? "unknown") removedImageFiles=\(removedFiles)")
  }

  func deleteFaceEnrollment(personId: UUID, context pipelineContext: PipelineContext?) async throws {
    try requireStoreLoaded()
    var removedImagePaths: [String] = []
    try await self.context.perform {
      if let person = try self.fetchOne(entity: "PersonProfile", id: personId) {
        person.setValue(Date(), forKey: "updatedAt")
      }
      let samples = try self.fetch(entity: "FaceEmbeddingSample", predicate: NSPredicate(format: "personId == %@", personId as CVarArg))
      removedImagePaths = samples.compactMap { $0.value(forKey: "sampleImageLocalPath") as? String }
      try self.delete(entity: "FaceEmbeddingSample", predicate: NSPredicate(format: "personId == %@", personId as CVarArg))
      try self.delete(entity: "PersonAveragedEmbedding", predicate: NSPredicate(format: "personId == %@", personId as CVarArg))
      try self.context.save()
    }
    var removedFiles = 0
    for path in Set(removedImagePaths) {
      if fileManager.fileExists(atPath: path) {
        try? fileManager.removeItem(atPath: path)
        removedFiles += 1
      }
    }
    AppLogger.log(.database, "\(pipelineContext.logPrefix) faceEnrollment deleted personId=\(personId.uuidString) removedEmbeddings=\(removedImagePaths.count) removedImageFiles=\(removedFiles)")
  }

  func saveEmbedding(_ record: FaceEmbeddingRecord, context pipelineContext: PipelineContext?) async throws {
    try requireStoreLoaded()
    let normalized = Self.l2Normalized(record.vector)
    var savedRecord = record
    savedRecord.vector = normalized
    savedRecord.dimension = normalized.count
    try await self.context.perform {
      let object = NSEntityDescription.insertNewObject(forEntityName: "FaceEmbeddingSample", into: self.context)
      self.write(savedRecord, to: object, context: pipelineContext)
      try self.context.save()
    }
    let personLogValue = savedRecord.personId?.uuidString ?? "unknown"
    AppLogger.log(
      .faceVectorStore,
      "\(pipelineContext.logPrefix) saved sample personId=\(personLogValue) sampleId=\(savedRecord.id.uuidString) quality=\(String(format: "%.3f", savedRecord.qualityScore ?? 0)) dim=\(savedRecord.dimension)"
    )
    if let personId = savedRecord.personId {
      try await recomputeAverageEmbedding(
        personId: personId,
        modelName: savedRecord.modelName,
        modelVersion: savedRecord.modelVersion,
        modelSource: savedRecord.modelSource,
        preprocessingVersion: savedRecord.preprocessingVersion,
        dimension: savedRecord.dimension,
        context: pipelineContext
      )
    }
  }

  func embeddingsForPerson(_ personId: UUID) async throws -> [FaceEmbeddingRecord] {
    try requireStoreLoaded()
    return try await context.perform {
      try self.fetch(entity: "FaceEmbeddingSample", predicate: NSPredicate(format: "personId == %@", personId as CVarArg))
        .compactMap(self.readEmbedding)
    }
  }

  func allEmbeddings() async throws -> [FaceEmbeddingRecord] {
    try requireStoreLoaded()
    return try await context.perform {
      try self.fetch(entity: "FaceEmbeddingSample").compactMap(self.readEmbedding)
    }
  }

  func averagedEmbeddings() async throws -> [PersonAveragedEmbedding] {
    try requireStoreLoaded()
    return try await context.perform {
      try self.fetch(entity: "PersonAveragedEmbedding").compactMap(self.readAverageEmbedding)
    }
  }

  func allAppRuns() async throws -> [AppRun] {
    try requireStoreLoaded()
    return try await context.perform {
      try self.fetch(entity: "AppRun")
        .compactMap(self.readAppRun)
        .sorted { $0.startedAt < $1.startedAt }
    }
  }

  func appRun(id: UUID) async throws -> AppRun? {
    try requireStoreLoaded()
    return try await context.perform {
      guard let object = try self.fetchOne(entity: "AppRun", id: id) else { return nil }
      return self.readAppRun(object)
    }
  }

  func personProfile(id: UUID) async throws -> PersonProfile? {
    try requireStoreLoaded()
    return try await context.perform {
      guard let object = try self.fetchOne(entity: "PersonProfile", id: id) else { return nil }
      return self.readPersonProfile(object)
    }
  }

  func allConversationSessions() async throws -> [ConversationSession] {
    try requireStoreLoaded()
    return try await context.perform {
      try self.fetch(entity: "ConversationSession")
        .compactMap(self.readConversationSession)
        .sorted { $0.startedAt < $1.startedAt }
    }
  }

  func conversationSession(id: UUID) async throws -> ConversationSession? {
    try requireStoreLoaded()
    return try await context.perform {
      guard let object = try self.fetchOne(entity: "ConversationSession", id: id) else { return nil }
      return self.readConversationSession(object)
    }
  }

  func saveConversationSession(_ session: ConversationSession, context pipelineContext: PipelineContext?) async throws {
    try requireStoreLoaded()
    try await self.context.perform {
      let object = try self.fetchOne(entity: "ConversationSession", id: session.id)
        ?? NSEntityDescription.insertNewObject(forEntityName: "ConversationSession", into: self.context)
      self.write(session, to: object)
      try self.context.save()
    }
    AppLogger.log(.database, "\(pipelineContext.logPrefix) entity=ConversationSession saved id=\(session.id.uuidString) state=\(session.state)")
  }

  func updateConversationSession(_ session: ConversationSession, context pipelineContext: PipelineContext?) async throws {
    try await saveConversationSession(session, context: pipelineContext)
  }

  func saveConversationEvent(_ event: ConversationEvent, context pipelineContext: PipelineContext?) async throws {
    guard let appRunId = pipelineContext?.appRunId else { return }
    let sessionId = pipelineContext?.conversationSessionId ?? event.sessionId
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
    try await saveTranscriptChunk(chunk, context: pipelineContext)
  }

  func saveFaceDetectionEvent(_ event: FaceDetectionEvent, context pipelineContext: PipelineContext?) async throws {
    try requireStoreLoaded()
    try await self.context.perform {
      let object = NSEntityDescription.insertNewObject(forEntityName: "FaceDetectionEvent", into: self.context)
      self.write(event, to: object)
      try self.context.save()
    }
    AppLogger.log(.database, "\(pipelineContext.logPrefix) entity=FaceDetectionEvent saved id=\(event.id.uuidString) frame=\(event.frameIndex) faces=\(event.selectedFaceCount)")
  }

  func saveTranscriptChunk(_ chunk: TranscriptChunk, context pipelineContext: PipelineContext?) async throws {
    try requireStoreLoaded()
    try await self.context.perform {
      let object = try self.fetchOne(entity: "TranscriptChunk", id: chunk.id)
        ?? NSEntityDescription.insertNewObject(forEntityName: "TranscriptChunk", into: self.context)
      self.write(chunk, to: object)
      try self.context.save()
    }
    AppLogger.log(
      .transcript,
      "\(pipelineContext.logPrefix) saved chunk=\(chunk.id.uuidString) person=\(chunk.personId?.uuidString ?? "unknown") isFinal=\(chunk.isFinal) textLen=\(chunk.text.count)"
    )
  }

  func saveSceneContext(_ record: SceneContextRecord, context pipelineContext: PipelineContext?) async throws {
    try requireStoreLoaded()
    try await self.context.perform {
      let object = try self.fetchOne(entity: "SceneContextRecord", id: record.id)
        ?? NSEntityDescription.insertNewObject(forEntityName: "SceneContextRecord", into: self.context)
      self.write(record, to: object)
      try self.context.save()
    }
    AppLogger.log(
      .sceneContext,
      "\(pipelineContext.logPrefix) saved context=\(record.id.uuidString) person=\(record.personId?.uuidString ?? "unknown") confidence=\(String(format: "%.2f", record.confidence))"
    )
  }

  func updateSceneContext(_ record: SceneContextRecord, context pipelineContext: PipelineContext?) async throws {
    try await saveSceneContext(record, context: pipelineContext)
  }

  func savePresenceEpisode(_ record: PresenceEpisodeRecord, context pipelineContext: PipelineContext?) async throws {
    try requireStoreLoaded()
    try await self.context.perform {
      let object = try self.fetchOne(entity: "PresenceEpisodeRecord", id: record.id)
        ?? NSEntityDescription.insertNewObject(forEntityName: "PresenceEpisodeRecord", into: self.context)
      self.write(record, to: object)
      try self.context.save()
    }
    AppLogger.log(
      .database,
      "\(pipelineContext.logPrefix) saved presenceEpisode=\(record.id.uuidString) person=\(record.personId?.uuidString ?? "unknown") status=\(record.status.rawValue)"
    )
  }

  func saveActivityModeEpisode(_ record: ActivityModeEpisodeRecord, context pipelineContext: PipelineContext?) async throws {
    try requireStoreLoaded()
    try await self.context.perform {
      let object = try self.fetchOne(entity: "ActivityModeEpisodeRecord", id: record.id)
        ?? NSEntityDescription.insertNewObject(forEntityName: "ActivityModeEpisodeRecord", into: self.context)
      self.write(record, to: object)
      try self.context.save()
    }
    AppLogger.log(
      .activityMode,
      "\(pipelineContext.logPrefix) saved activityModeEpisode=\(record.id.uuidString) mode=\(record.mode) specific=\"\(record.specificActivity)\" confidence=\(String(format: "%.2f", record.confidence)) ended=\(record.endedAt != nil)"
    )
  }

  func saveGlassesDisplayInteraction(_ event: GlassesDisplayInteractionEvent, context pipelineContext: PipelineContext?) async throws {
    try requireStoreLoaded()
    try await self.context.perform {
      let object = try self.fetchOne(entity: "GlassesDisplayInteractionEvent", id: event.id)
        ?? NSEntityDescription.insertNewObject(forEntityName: "GlassesDisplayInteractionEvent", into: self.context)
      self.write(event, to: object)
      try self.context.save()
    }
    AppLogger.log(
      .display,
      "\(pipelineContext.logPrefix) saved glassesDisplayInteraction=\(event.id.uuidString) action=\(event.action) person=\(event.personId?.uuidString ?? "unknown") source=\(event.source)"
    )
  }

  func saveIdentityMatchEvent(_ event: IdentityMatchEvent, context pipelineContext: PipelineContext?) async throws {
    try requireStoreLoaded()
    try await self.context.perform {
      let object = NSEntityDescription.insertNewObject(forEntityName: "IdentityMatchEvent", into: self.context)
      self.write(event, to: object)
      try self.context.save()
    }
    AppLogger.log(.database, "\(pipelineContext.logPrefix) entity=IdentityMatchEvent saved id=\(event.id.uuidString) decision=\(event.decision)")
  }

  func runSessionSnapshot(appRunId: UUID?, conversationSessionId: UUID?) async throws -> RunSessionSnapshot {
    try requireStoreLoaded()
    guard let appRunId else {
      return RunSessionSnapshot(appRunId: nil, conversationSessionId: conversationSessionId, detectedFacesThisSession: 0, acceptedFaceCropsThisSession: 0, embeddingsSavedThisSession: 0, transcriptChunksSavedThisSession: 0)
    }
    return try await context.perform {
      let sessionPredicate = conversationSessionId.map { NSPredicate(format: "conversationSessionId == %@", $0 as CVarArg) }
      let appRunPredicate = NSPredicate(format: "appRunId == %@", appRunId as CVarArg)
      let scopedPredicate: NSPredicate
      if let sessionPredicate {
        scopedPredicate = NSCompoundPredicate(andPredicateWithSubpredicates: [appRunPredicate, sessionPredicate])
      } else {
        scopedPredicate = appRunPredicate
      }
      let detections = try self.fetch(entity: "FaceDetectionEvent", predicate: scopedPredicate)
      let detectedFaces = detections.reduce(0) { $0 + (($1.value(forKey: "selectedFaceCount") as? Int) ?? 0) }
      let embeddings = try self.count(entity: "FaceEmbeddingSample", predicate: scopedPredicate)
      let chunks = try self.count(entity: "TranscriptChunk", predicate: scopedPredicate)
      return RunSessionSnapshot(
        appRunId: appRunId,
        conversationSessionId: conversationSessionId,
        detectedFacesThisSession: detectedFaces,
        acceptedFaceCropsThisSession: embeddings,
        embeddingsSavedThisSession: embeddings,
        transcriptChunksSavedThisSession: chunks
      )
    }
  }

  func clearIdentities(context pipelineContext: PipelineContext?) async throws {
    try requireStoreLoaded()
    try await self.context.perform {
      try self.delete(entity: "FaceEmbeddingSample")
      try self.delete(entity: "PersonAveragedEmbedding")
      try self.delete(entity: "IdentityMatchEvent")
      try self.delete(entity: "SceneContextRecord")
      try self.delete(entity: "GlassesDisplayInteractionEvent")
      try self.delete(entity: "PresenceEpisodeRecord")
      try self.delete(entity: "ActivityModeEpisodeRecord")
      try self.delete(entity: "PersonProfile")
      try self.context.save()
    }
    let removedFiles = clearIdentityImageFiles()
    AppLogger.log(.database, "\(pipelineContext.logPrefix) cleared identity data removedImageFiles=\(removedFiles)")
  }

  func clearConversations(context pipelineContext: PipelineContext?) async throws {
    try requireStoreLoaded()
    try await self.context.perform {
      try self.delete(entity: "ConversationSession")
      try self.delete(entity: "TranscriptChunk")
      try self.delete(entity: "FaceDetectionEvent")
      try self.delete(entity: "SceneContextRecord")
      try self.delete(entity: "GlassesDisplayInteractionEvent")
      try self.delete(entity: "PresenceEpisodeRecord")
      try self.delete(entity: "ActivityModeEpisodeRecord")
      try self.context.save()
    }
    AppLogger.log(.database, "\(pipelineContext.logPrefix) cleared conversation data")
  }

  func transcriptChunksForPerson(_ personId: UUID) async throws -> [TranscriptChunk] {
    try requireStoreLoaded()
    return try await context.perform {
      try self.fetch(
        entity: "TranscriptChunk",
        predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
          NSPredicate(format: "personId == %@", personId as CVarArg),
          NSPredicate(format: "isFinal == YES")
        ])
      ).compactMap(self.readTranscriptChunk)
    }
  }

  func transcriptChunksForConversationSessions(_ sessionIds: [UUID]) async throws -> [TranscriptChunk] {
    try requireStoreLoaded()
    guard !sessionIds.isEmpty else { return [] }
    return try await context.perform {
      try self.fetch(
        entity: "TranscriptChunk",
        predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
          NSPredicate(format: "conversationSessionId IN %@", sessionIds),
          NSPredicate(format: "isFinal == YES")
        ])
      )
      .compactMap(self.readTranscriptChunk)
      .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .sorted { ($0.startedAt ?? $0.createdAt) < ($1.startedAt ?? $1.createdAt) }
    }
  }

  func sceneContextsForPerson(_ personId: UUID) async throws -> [SceneContextRecord] {
    try requireStoreLoaded()
    return try await context.perform {
      try self.fetch(entity: "SceneContextRecord", predicate: NSPredicate(format: "personId == %@", personId as CVarArg))
        .compactMap(self.readSceneContext)
        .sorted { $0.startedAt > $1.startedAt }
    }
  }

  func sceneContextsForConversationSessions(_ sessionIds: [UUID]) async throws -> [SceneContextRecord] {
    try requireStoreLoaded()
    guard !sessionIds.isEmpty else { return [] }
    return try await context.perform {
      try self.fetch(
        entity: "SceneContextRecord",
        predicate: NSPredicate(format: "conversationSessionId IN %@", sessionIds)
      )
      .compactMap(self.readSceneContext)
      .sorted { $0.startedAt > $1.startedAt }
    }
  }

  func glassesDisplayInteractionsForPerson(_ personId: UUID) async throws -> [GlassesDisplayInteractionEvent] {
    try requireStoreLoaded()
    return try await context.perform {
      try self.fetch(entity: "GlassesDisplayInteractionEvent", predicate: NSPredicate(format: "personId == %@", personId as CVarArg))
        .compactMap(self.readGlassesDisplayInteraction)
        .sorted { $0.createdAt > $1.createdAt }
    }
  }

  func glassesDisplayInteractionsForConversationSessions(_ sessionIds: [UUID]) async throws -> [GlassesDisplayInteractionEvent] {
    try requireStoreLoaded()
    guard !sessionIds.isEmpty else { return [] }
    return try await context.perform {
      try self.fetch(
        entity: "GlassesDisplayInteractionEvent",
        predicate: NSPredicate(format: "conversationSessionId IN %@", sessionIds)
      )
      .compactMap(self.readGlassesDisplayInteraction)
      .sorted { $0.createdAt > $1.createdAt }
    }
  }

  func thumbnailImage(forDisplayName displayName: String) -> UIImage? {
    let safeName = Self.safeFileComponent(displayName)
    let directory = identityDirectory.appendingPathComponent("EnrollmentImages", isDirectory: true)
    guard let enumerator = fileManager.enumerator(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) else { return nil }
    for case let url as URL in enumerator {
      let name = url.lastPathComponent
      if name.hasPrefix("\(safeName)_"), url.pathExtension.lowercased() == "png" {
        return UIImage(contentsOfFile: url.path)
      }
    }
    return nil
  }

  private func recomputeAverageEmbedding(
    personId: UUID,
    modelName: String,
    modelVersion: String,
    modelSource: String,
    preprocessingVersion: String,
    dimension: Int,
    context pipelineContext: PipelineContext?
  ) async throws {
    try requireStoreLoaded()
    let samples = try await embeddingsForPerson(personId)
      .filter {
        $0.modelName == modelName
          && $0.modelVersion == modelVersion
          && $0.modelSource == modelSource
          && $0.preprocessingVersion == preprocessingVersion
          && $0.dimension == dimension
          && $0.vector.count == dimension
      }
    guard !samples.isEmpty else { return }
    let average = Self.averagedNormalizedVector(samples.map(\.vector))
    let now = Date()
    let averaged = PersonAveragedEmbedding(
      id: UUID(),
      personId: personId,
      averagedVector: average,
      vectorDimension: dimension,
      sampleCount: samples.count,
      modelName: modelName,
      modelVersion: modelVersion,
      modelSource: modelSource,
      preprocessingVersion: preprocessingVersion,
      updatedAt: now
    )
    try await self.context.perform {
      if let existing = try self.fetchOne(entity: "PersonAveragedEmbedding", predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
        NSPredicate(format: "personId == %@", personId as CVarArg),
        NSPredicate(format: "modelName == %@", modelName),
        NSPredicate(format: "modelVersion == %@", modelVersion),
        NSPredicate(format: "modelSource == %@", modelSource),
        NSPredicate(format: "preprocessingVersion == %@", preprocessingVersion),
        NSPredicate(format: "vectorDimension == %d", dimension)
      ])) {
        self.write(averaged, to: existing, keepExistingID: true)
      } else {
        let object = NSEntityDescription.insertNewObject(forEntityName: "PersonAveragedEmbedding", into: self.context)
        self.write(averaged, to: object, keepExistingID: false)
      }
      try self.context.save()
    }
    AppLogger.log(.faceVectorStore, "\(pipelineContext.logPrefix) recomputed average personId=\(personId.uuidString) sampleCount=\(samples.count) dim=\(dimension)")
  }

  private func fetch(entity: String, predicate: NSPredicate? = nil) throws -> [NSManagedObject] {
    let request = NSFetchRequest<NSManagedObject>(entityName: entity)
    request.predicate = predicate
    return try context.fetch(request)
  }

  private func fetchOne(entity: String, id: UUID) throws -> NSManagedObject? {
    try fetchOne(entity: entity, predicate: NSPredicate(format: "id == %@", id as CVarArg))
  }

  private func fetchOne(entity: String, predicate: NSPredicate) throws -> NSManagedObject? {
    let request = NSFetchRequest<NSManagedObject>(entityName: entity)
    request.predicate = predicate
    request.fetchLimit = 1
    return try context.fetch(request).first
  }

  private func count(entity: String, predicate: NSPredicate? = nil) throws -> Int {
    let request = NSFetchRequest<NSFetchRequestResult>(entityName: entity)
    request.predicate = predicate
    return try context.count(for: request)
  }

  private func delete(entity: String, predicate: NSPredicate? = nil) throws {
    for object in try fetch(entity: entity, predicate: predicate) {
      context.delete(object)
    }
  }

  private func clearIdentityImageFiles() -> Int {
    clearIdentityImageFiles(nameHint: nil)
  }

  private func clearIdentityImageFiles(nameHint: String?) -> Int {
    var removed = 0
    let safePrefix = nameHint.map(Self.safeFileComponent)
    let directories = [
      identityDirectory.appendingPathComponent("EnrollmentImages", isDirectory: true),
      fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
    ].compactMap { $0 }

    for directory in directories {
      guard let enumerator = fileManager.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      ) else { continue }
      for case let url as URL in enumerator {
        let fileName = url.lastPathComponent
        let isIdentityImage = directory.lastPathComponent == "EnrollmentImages"
          || fileName.hasPrefix("face_crop_run_")
        if let safePrefix, !fileName.hasPrefix("\(safePrefix)_") {
          continue
        }
        guard isIdentityImage else { continue }
        do {
          try fileManager.removeItem(at: url)
          removed += 1
        } catch {
          AppLogger.log(.database, "Failed to remove identity image file path=\(url.path): \(error.localizedDescription)")
        }
      }
    }
    return removed
  }

  private static func safeFileComponent(_ text: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    let mapped = text.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
    let value = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    return value.isEmpty ? "unknown" : value
  }

  private func write(_ run: AppRun, to object: NSManagedObject) {
    object.setValue(run.id, forKey: "id")
    object.setValue(run.startedAt, forKey: "startedAt")
    object.setValue(run.endedAt, forKey: "endedAt")
    object.setValue(run.appBuild, forKey: "appBuild")
    object.setValue(run.appVersion, forKey: "appVersion")
    object.setValue(run.deviceId, forKey: "deviceId")
    object.setValue(run.notes, forKey: "notes")
    object.setValue(run.createdAt, forKey: "createdAt")
  }

  private func write(_ session: ConversationSession, to object: NSManagedObject) {
    object.setValue(session.id, forKey: "id")
    object.setValue(session.appRunId, forKey: "appRunId")
    object.setValue(session.deviceId, forKey: "deviceId")
    object.setValue(session.datDeviceId, forKey: "datDeviceId")
    object.setValue(session.startedAt, forKey: "startedAt")
    object.setValue(session.endedAt, forKey: "endedAt")
    object.setValue(session.streamStartedAt, forKey: "streamStartedAt")
    object.setValue(session.streamEndedAt, forKey: "streamEndedAt")
    object.setValue(session.state, forKey: "state")
    object.setValue(session.createdAt, forKey: "createdAt")
    object.setValue(session.updatedAt, forKey: "updatedAt")
  }

  private func write(_ profile: PersonProfile, to object: NSManagedObject) {
    object.setValue(profile.id, forKey: "id")
    object.setValue(profile.displayName, forKey: "displayName")
    object.setValue(profile.enrollmentStatus.rawValue, forKey: "enrollmentStatus")
    object.setValue(profile.consentStatus.rawValue, forKey: "consentStatus")
    object.setValue(profile.createdAt, forKey: "createdAt")
    object.setValue(profile.updatedAt, forKey: "updatedAt")
    object.setValue(profile.lastSeenAt, forKey: "lastSeenAt")
    object.setValue(profile.notes, forKey: "notes")
    object.setValue(profile.isUnknownPlaceholder, forKey: "isUnknownPlaceholder")
  }

  private func write(_ record: FaceEmbeddingRecord, to object: NSManagedObject, context pipelineContext: PipelineContext?) {
    object.setValue(record.id, forKey: "id")
    object.setValue(record.personId, forKey: "personId")
    object.setValue(record.appRunId ?? pipelineContext?.appRunId, forKey: "appRunId")
    object.setValue(record.conversationSessionId ?? pipelineContext?.conversationSessionId, forKey: "conversationSessionId")
    object.setValue(Self.data(from: record.vector), forKey: "vector")
    object.setValue(record.dimension, forKey: "vectorDimension")
    object.setValue(record.modelName, forKey: "modelName")
    object.setValue(record.modelVersion, forKey: "modelVersion")
    object.setValue(record.modelSource, forKey: "modelSource")
    object.setValue(record.preprocessingVersion, forKey: "preprocessingVersion")
    object.setValue(Double(record.qualityScore ?? 0), forKey: "qualityScore")
    object.setValue(record.frameNumber.map(Int64.init), forKey: "frameNumber")
    object.setValue(record.metadata?.boundingBoxNormalized.jsonString, forKey: "faceBoxNormalized")
    object.setValue(record.rawFaceBoxPixels?.jsonString, forKey: "rawFaceBoxPixels")
    object.setValue(record.faceBoxPixels?.jsonString, forKey: "faceBoxPixels")
    object.setValue(record.qualityTier?.rawValue, forKey: "qualityTier")
    object.setValue(record.faceCaptureQuality.map { Double($0) }, forKey: "faceCaptureQuality")
    object.setValue(record.yaw.map { Double($0) }, forKey: "yaw")
    object.setValue(record.pitch.map { Double($0) }, forKey: "pitch")
    object.setValue(record.roll.map { Double($0) }, forKey: "roll")
    object.setValue(record.cropWidth ?? Int(record.metadata?.cropSize.width ?? 0), forKey: "cropWidth")
    object.setValue(record.cropHeight ?? Int(record.metadata?.cropSize.height ?? 0), forKey: "cropHeight")
    object.setValue(record.sourceFrameWidth ?? Int(record.metadata?.sourceImageSize.width ?? 0), forKey: "sourceFrameWidth")
    object.setValue(record.sourceFrameHeight ?? Int(record.metadata?.sourceImageSize.height ?? 0), forKey: "sourceFrameHeight")
    object.setValue(record.sourceFrameTimestamp, forKey: "sourceFrameTimestamp")
    object.setValue(record.orientationUsed, forKey: "orientationUsed")
    object.setValue(record.sampleImageLocalPath, forKey: "sampleImageLocalPath")
    object.setValue(record.createdAt, forKey: "createdAt")
  }

  private func write(_ averaged: PersonAveragedEmbedding, to object: NSManagedObject, keepExistingID: Bool) {
    if !keepExistingID || object.value(forKey: "id") == nil {
      object.setValue(averaged.id, forKey: "id")
    }
    object.setValue(averaged.personId, forKey: "personId")
    object.setValue(Self.data(from: averaged.averagedVector), forKey: "averagedVector")
    object.setValue(averaged.vectorDimension, forKey: "vectorDimension")
    object.setValue(averaged.sampleCount, forKey: "sampleCount")
    object.setValue(averaged.modelName, forKey: "modelName")
    object.setValue(averaged.modelVersion, forKey: "modelVersion")
    object.setValue(averaged.modelSource, forKey: "modelSource")
    object.setValue(averaged.preprocessingVersion, forKey: "preprocessingVersion")
    object.setValue(averaged.updatedAt, forKey: "updatedAt")
  }

  private func write(_ event: FaceDetectionEvent, to object: NSManagedObject) {
    object.setValue(event.id, forKey: "id")
    object.setValue(event.appRunId, forKey: "appRunId")
    object.setValue(event.conversationSessionId, forKey: "conversationSessionId")
    object.setValue(event.frameIndex, forKey: "frameIndex")
    object.setValue(event.frameWidth, forKey: "frameWidth")
    object.setValue(event.frameHeight, forKey: "frameHeight")
    object.setValue(event.uiImageOrientation, forKey: "uiImageOrientation")
    object.setValue(event.cgImageWidth, forKey: "cgImageWidth")
    object.setValue(event.cgImageHeight, forKey: "cgImageHeight")
    object.setValue(event.visionOrientationUsed, forKey: "visionOrientationUsed")
    object.setValue(event.preferredFaceCount, forKey: "preferredFaceCount")
    object.setValue(event.sweepFaceCountsJson, forKey: "sweepFaceCountsJson")
    object.setValue(event.selectedOrientation, forKey: "selectedOrientation")
    object.setValue(event.selectedFaceCount, forKey: "selectedFaceCount")
    object.setValue(event.createdAt, forKey: "createdAt")
  }

  private func write(_ chunk: TranscriptChunk, to object: NSManagedObject) {
    object.setValue(chunk.id, forKey: "id")
    object.setValue(chunk.appRunId, forKey: "appRunId")
    object.setValue(chunk.conversationSessionId, forKey: "conversationSessionId")
    object.setValue(chunk.personId, forKey: "personId")
    object.setValue(chunk.activeIdentityState, forKey: "activeIdentityState")
    object.setValue(chunk.text, forKey: "text")
    object.setValue(chunk.isFinal, forKey: "isFinal")
    object.setValue(chunk.startedAt, forKey: "startedAt")
    object.setValue(chunk.endedAt, forKey: "endedAt")
    object.setValue(chunk.transcriptUpdatedAt, forKey: "transcriptUpdatedAt")
    object.setValue(chunk.source, forKey: "source")
    object.setValue(chunk.createdAt, forKey: "createdAt")
  }

  private func write(_ record: SceneContextRecord, to object: NSManagedObject) {
    object.setValue(record.id, forKey: "id")
    object.setValue(record.appRunId, forKey: "appRunId")
    object.setValue(record.conversationSessionId, forKey: "conversationSessionId")
    object.setValue(record.personId, forKey: "personId")
    object.setValue(record.startedAt, forKey: "startedAt")
    object.setValue(record.endedAt, forKey: "endedAt")
    object.setValue(record.createdAt, forKey: "createdAt")
    object.setValue(record.modelName, forKey: "modelName")
    object.setValue(record.promptVersion, forKey: "promptVersion")
    object.setValue(record.transcriptChunkIdsJson, forKey: "transcriptChunkIdsJson")
    object.setValue(record.frameTimestampsJson, forKey: "frameTimestampsJson")
    object.setValue(record.locationLabel, forKey: "locationLabel")
    object.setValue(record.latitude, forKey: "latitude")
    object.setValue(record.longitude, forKey: "longitude")
    object.setValue(record.locationAccuracyMeters, forKey: "locationAccuracyMeters")
    object.setValue(record.who, forKey: "who")
    object.setValue(record.whereText, forKey: "whereText")
    object.setValue(record.what, forKey: "what")
    object.setValue(record.whenText, forKey: "whenText")
    object.setValue(record.why, forKey: "why")
    object.setValue(record.how, forKey: "how")
    object.setValue(record.interactionStyle, forKey: "interactionStyle")
    object.setValue(record.summary, forKey: "summary")
    object.setValue(record.confidence, forKey: "confidence")
    object.setValue(record.evidenceJson, forKey: "evidenceJson")
  }

  private func write(_ record: PresenceEpisodeRecord, to object: NSManagedObject) {
    object.setValue(record.id, forKey: "id")
    object.setValue(record.appRunId, forKey: "appRunId")
    object.setValue(record.conversationSessionId, forKey: "conversationSessionId")
    object.setValue(record.personId, forKey: "personId")
    object.setValue(record.displayName, forKey: "displayName")
    object.setValue(record.startedAt, forKey: "startedAt")
    object.setValue(record.lastEvidenceAt, forKey: "lastEvidenceAt")
    object.setValue(record.endedAt, forKey: "endedAt")
    object.setValue(record.status.rawValue, forKey: "status")
    object.setValue(Double(record.confidence), forKey: "confidence")
    object.setValue(record.evidenceSummary, forKey: "evidenceSummary")
    object.setValue(record.updatedAt, forKey: "updatedAt")
  }

  private func write(_ record: ActivityModeEpisodeRecord, to object: NSManagedObject) {
    object.setValue(record.id, forKey: "id")
    object.setValue(record.appRunId, forKey: "appRunId")
    object.setValue(record.conversationSessionId, forKey: "conversationSessionId")
    object.setValue(record.mode, forKey: "mode")
    object.setValue(record.specificActivity, forKey: "specificActivity")
    object.setValue(record.startedAt, forKey: "startedAt")
    object.setValue(record.lastEvidenceAt, forKey: "lastEvidenceAt")
    object.setValue(record.endedAt, forKey: "endedAt")
    object.setValue(record.confidence, forKey: "confidence")
    object.setValue(record.reason, forKey: "reason")
    object.setValue(record.source, forKey: "source")
    object.setValue(record.modelName, forKey: "modelName")
    object.setValue(record.promptVersion, forKey: "promptVersion")
    object.setValue(record.updatedAt, forKey: "updatedAt")
  }

  private func write(_ event: GlassesDisplayInteractionEvent, to object: NSManagedObject) {
    object.setValue(event.id, forKey: "id")
    object.setValue(event.appRunId, forKey: "appRunId")
    object.setValue(event.conversationSessionId, forKey: "conversationSessionId")
    object.setValue(event.personId, forKey: "personId")
    object.setValue(event.displayName, forKey: "displayName")
    object.setValue(event.cardTitle, forKey: "cardTitle")
    object.setValue(event.cardText, forKey: "cardText")
    object.setValue(event.action, forKey: "action")
    object.setValue(event.source, forKey: "source")
    object.setValue(event.createdAt, forKey: "createdAt")
  }

  private func write(_ event: IdentityMatchEvent, to object: NSManagedObject) {
    object.setValue(event.id, forKey: "id")
    object.setValue(event.appRunId, forKey: "appRunId")
    object.setValue(event.conversationSessionId, forKey: "conversationSessionId")
    object.setValue(event.frameNumber.map(Int64.init), forKey: "frameNumber")
    object.setValue(event.detectedFaceCount, forKey: "detectedFaceCount")
    object.setValue(event.cropQualityTier, forKey: "cropQualityTier")
    object.setValue(event.embeddingModelName, forKey: "embeddingModelName")
    object.setValue(event.embeddingModelVersion, forKey: "embeddingModelVersion")
    object.setValue(event.candidatePersonId, forKey: "candidatePersonId")
    object.setValue(event.cosineSimilarity, forKey: "cosineSimilarity")
    object.setValue(event.l2Distance, forKey: "l2Distance")
    object.setValue(event.threshold, forKey: "threshold")
    object.setValue(event.rollingWindowSize, forKey: "rollingWindowSize")
    object.setValue(event.rollingConfirmCount, forKey: "rollingConfirmCount")
    object.setValue(event.decision, forKey: "decision")
    object.setValue(event.rollingConfirmationState, forKey: "rollingConfirmationState")
    object.setValue(event.createdAt, forKey: "createdAt")
  }

  private func readAppRun(_ object: NSManagedObject) -> AppRun? {
    guard let id = object.value(forKey: "id") as? UUID,
          let startedAt = object.value(forKey: "startedAt") as? Date,
          let createdAt = object.value(forKey: "createdAt") as? Date else { return nil }
    return AppRun(
      id: id,
      startedAt: startedAt,
      endedAt: object.value(forKey: "endedAt") as? Date,
      appBuild: object.value(forKey: "appBuild") as? String,
      appVersion: object.value(forKey: "appVersion") as? String,
      deviceId: object.value(forKey: "deviceId") as? String,
      notes: object.value(forKey: "notes") as? String,
      createdAt: createdAt
    )
  }

  private func readConversationSession(_ object: NSManagedObject) -> ConversationSession? {
    guard let id = object.value(forKey: "id") as? UUID,
          let startedAt = object.value(forKey: "startedAt") as? Date,
          let state = object.value(forKey: "state") as? String,
          let createdAt = object.value(forKey: "createdAt") as? Date,
          let updatedAt = object.value(forKey: "updatedAt") as? Date else { return nil }
    let status = ConversationSession.Status(rawValue: state) ?? (state == "ended" ? .ended : .active)
    return ConversationSession(
      id: id,
      personId: nil,
      startedAt: startedAt,
      endedAt: object.value(forKey: "endedAt") as? Date,
      confidence: 0,
      status: status,
      appRunId: object.value(forKey: "appRunId") as? UUID,
      deviceId: object.value(forKey: "deviceId") as? String,
      datDeviceId: object.value(forKey: "datDeviceId") as? String,
      streamStartedAt: object.value(forKey: "streamStartedAt") as? Date,
      streamEndedAt: object.value(forKey: "streamEndedAt") as? Date,
      state: state,
      createdAt: createdAt,
      updatedAt: updatedAt
    )
  }

  private func readPersonProfile(_ object: NSManagedObject) -> PersonProfile? {
    guard let id = object.value(forKey: "id") as? UUID,
          let displayName = object.value(forKey: "displayName") as? String,
          let createdAt = object.value(forKey: "createdAt") as? Date,
          let updatedAt = object.value(forKey: "updatedAt") as? Date else { return nil }
    return PersonProfile(
      id: id,
      displayName: displayName,
      createdAt: createdAt,
      updatedAt: updatedAt,
      notes: object.value(forKey: "notes") as? String,
      isUnknownPlaceholder: (object.value(forKey: "isUnknownPlaceholder") as? Bool) ?? false,
      lastSeenAt: object.value(forKey: "lastSeenAt") as? Date,
      enrollmentStatus: PersonProfile.EnrollmentStatus(rawValue: object.value(forKey: "enrollmentStatus") as? String ?? "unknown") ?? .unknown,
      consentStatus: PersonProfile.ConsentStatus(rawValue: object.value(forKey: "consentStatus") as? String ?? "unknown") ?? .unknown
    )
  }

  private func readEmbedding(_ object: NSManagedObject) -> FaceEmbeddingRecord? {
    guard let id = object.value(forKey: "id") as? UUID,
          let data = object.value(forKey: "vector") as? Data,
          let createdAt = object.value(forKey: "createdAt") as? Date else { return nil }
    let personId = object.value(forKey: "personId") as? UUID
    let vector = Self.vector(from: data)
    return FaceEmbeddingRecord(
      id: id,
      personId: personId,
      vector: vector,
      dimension: (object.value(forKey: "vectorDimension") as? Int) ?? vector.count,
      qualityScore: Float((object.value(forKey: "qualityScore") as? Double) ?? 0),
      sourceFrameTimestamp: object.value(forKey: "sourceFrameTimestamp") as? Date ?? createdAt,
      createdAt: createdAt,
      sampleImageLocalPath: object.value(forKey: "sampleImageLocalPath") as? String,
      metadata: nil,
      appRunId: object.value(forKey: "appRunId") as? UUID,
      conversationSessionId: object.value(forKey: "conversationSessionId") as? UUID,
      modelName: object.value(forKey: "modelName") as? String ?? "unknown",
      modelVersion: object.value(forKey: "modelVersion") as? String ?? "unknown",
      modelSource: object.value(forKey: "modelSource") as? String ?? "unknown",
      preprocessingVersion: object.value(forKey: "preprocessingVersion") as? String ?? "unknown",
      frameNumber: (object.value(forKey: "frameNumber") as? Int64).map(UInt64.init),
      cropWidth: object.value(forKey: "cropWidth") as? Int,
      cropHeight: object.value(forKey: "cropHeight") as? Int,
      sourceFrameWidth: object.value(forKey: "sourceFrameWidth") as? Int,
      sourceFrameHeight: object.value(forKey: "sourceFrameHeight") as? Int,
      orientationUsed: object.value(forKey: "orientationUsed") as? String
    )
  }

  private func readTranscriptChunk(_ object: NSManagedObject) -> TranscriptChunk? {
    guard let id = object.value(forKey: "id") as? UUID,
          let appRunId = object.value(forKey: "appRunId") as? UUID,
          let conversationSessionId = object.value(forKey: "conversationSessionId") as? UUID,
          let text = object.value(forKey: "text") as? String,
          let activeIdentityState = object.value(forKey: "activeIdentityState") as? String,
          let source = object.value(forKey: "source") as? String,
          let transcriptUpdatedAt = object.value(forKey: "transcriptUpdatedAt") as? Date,
          let createdAt = object.value(forKey: "createdAt") as? Date else { return nil }
    return TranscriptChunk(
      id: id,
      appRunId: appRunId,
      conversationSessionId: conversationSessionId,
      personId: object.value(forKey: "personId") as? UUID,
      activeIdentityState: activeIdentityState,
      text: text,
      isFinal: (object.value(forKey: "isFinal") as? Bool) ?? false,
      startedAt: object.value(forKey: "startedAt") as? Date,
      endedAt: object.value(forKey: "endedAt") as? Date,
      transcriptUpdatedAt: transcriptUpdatedAt,
      source: source,
      createdAt: createdAt
    )
  }

  private func readSceneContext(_ object: NSManagedObject) -> SceneContextRecord? {
    guard let id = object.value(forKey: "id") as? UUID,
          let appRunId = object.value(forKey: "appRunId") as? UUID,
          let startedAt = object.value(forKey: "startedAt") as? Date,
          let endedAt = object.value(forKey: "endedAt") as? Date,
          let createdAt = object.value(forKey: "createdAt") as? Date,
          let modelName = object.value(forKey: "modelName") as? String,
          let promptVersion = object.value(forKey: "promptVersion") as? String,
          let transcriptChunkIdsJson = object.value(forKey: "transcriptChunkIdsJson") as? String,
          let frameTimestampsJson = object.value(forKey: "frameTimestampsJson") as? String,
          let who = object.value(forKey: "who") as? String,
          let whereText = object.value(forKey: "whereText") as? String,
          let what = object.value(forKey: "what") as? String,
          let whenText = object.value(forKey: "whenText") as? String,
          let why = object.value(forKey: "why") as? String,
          let how = object.value(forKey: "how") as? String,
          let summary = object.value(forKey: "summary") as? String,
          let evidenceJson = object.value(forKey: "evidenceJson") as? String else { return nil }
    return SceneContextRecord(
      id: id,
      appRunId: appRunId,
      conversationSessionId: object.value(forKey: "conversationSessionId") as? UUID,
      personId: object.value(forKey: "personId") as? UUID,
      startedAt: startedAt,
      endedAt: endedAt,
      createdAt: createdAt,
      modelName: modelName,
      promptVersion: promptVersion,
      transcriptChunkIdsJson: transcriptChunkIdsJson,
      frameTimestampsJson: frameTimestampsJson,
      locationLabel: object.value(forKey: "locationLabel") as? String,
      latitude: object.value(forKey: "latitude") as? Double,
      longitude: object.value(forKey: "longitude") as? Double,
      locationAccuracyMeters: object.value(forKey: "locationAccuracyMeters") as? Double,
      who: who,
      whereText: whereText,
      what: what,
      whenText: whenText,
      why: why,
      how: how,
      interactionStyle: object.value(forKey: "interactionStyle") as? String ?? "unknown",
      summary: summary,
      confidence: (object.value(forKey: "confidence") as? Double) ?? 0,
      evidenceJson: evidenceJson
    )
  }

  private func readGlassesDisplayInteraction(_ object: NSManagedObject) -> GlassesDisplayInteractionEvent? {
    guard let id = object.value(forKey: "id") as? UUID,
          let appRunId = object.value(forKey: "appRunId") as? UUID,
          let cardTitle = object.value(forKey: "cardTitle") as? String,
          let cardText = object.value(forKey: "cardText") as? String,
          let action = object.value(forKey: "action") as? String,
          let source = object.value(forKey: "source") as? String,
          let createdAt = object.value(forKey: "createdAt") as? Date,
          let actionKind = GlassesDisplayAction(rawValue: action) else { return nil }
    return GlassesDisplayInteractionEvent(
      id: id,
      appRunId: appRunId,
      conversationSessionId: object.value(forKey: "conversationSessionId") as? UUID,
      personId: object.value(forKey: "personId") as? UUID,
      displayName: object.value(forKey: "displayName") as? String,
      cardTitle: cardTitle,
      cardText: cardText,
      action: actionKind,
      source: source,
      createdAt: createdAt
    )
  }

  private func readAverageEmbedding(_ object: NSManagedObject) -> PersonAveragedEmbedding? {
    guard let id = object.value(forKey: "id") as? UUID,
          let personId = object.value(forKey: "personId") as? UUID,
          let data = object.value(forKey: "averagedVector") as? Data,
          let modelName = object.value(forKey: "modelName") as? String,
          let updatedAt = object.value(forKey: "updatedAt") as? Date else { return nil }
    let vector = Self.vector(from: data)
    return PersonAveragedEmbedding(
      id: id,
      personId: personId,
      averagedVector: vector,
      vectorDimension: (object.value(forKey: "vectorDimension") as? Int) ?? vector.count,
      sampleCount: (object.value(forKey: "sampleCount") as? Int) ?? 0,
      modelName: modelName,
      modelVersion: object.value(forKey: "modelVersion") as? String ?? "unknown",
      modelSource: object.value(forKey: "modelSource") as? String ?? "unknown",
      preprocessingVersion: object.value(forKey: "preprocessingVersion") as? String ?? "unknown",
      updatedAt: updatedAt
    )
  }

  static func l2Normalized(_ vector: [Float]) -> [Float] {
    let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
    guard norm > 0 else { return vector }
    return vector.map { $0 / norm }
  }

  static func averagedNormalizedVector(_ vectors: [[Float]]) -> [Float] {
    guard let dimension = vectors.first?.count, dimension > 0 else { return [] }
    let compatible = vectors.filter { $0.count == dimension }.map(Self.l2Normalized)
    guard !compatible.isEmpty else { return [] }
    var average = [Float](repeating: 0, count: dimension)
    for vector in compatible {
      for index in 0..<dimension {
        average[index] += vector[index]
      }
    }
    average = average.map { $0 / Float(compatible.count) }
    return Self.l2Normalized(average)
  }

  static func data(from vector: [Float]) -> Data {
    let copy = vector
    return copy.withUnsafeBufferPointer { Data(buffer: $0) }
  }

  static func vector(from data: Data) -> [Float] {
    guard data.count % MemoryLayout<Float>.size == 0 else { return [] }
    return data.withUnsafeBytes { rawBuffer in
      Array(rawBuffer.bindMemory(to: Float.self))
    }
  }
}

private extension LocalIdentityStore {
  static func makeContainer(model: NSManagedObjectModel, storeURL: URL) -> NSPersistentContainer {
    let container = NSPersistentContainer(name: "MetaFaceIdentity", managedObjectModel: model)
    let description = NSPersistentStoreDescription(url: storeURL)
    description.type = NSSQLiteStoreType
    description.shouldMigrateStoreAutomatically = true
    description.shouldInferMappingModelAutomatically = true
    description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
    container.persistentStoreDescriptions = [description]
    return container
  }

  static func loadPersistentStores(container: NSPersistentContainer) -> (loaded: Bool, error: Error?) {
    var loadError: Error?
    let semaphore = DispatchSemaphore(value: 0)
    container.loadPersistentStores { _, error in
      loadError = error
      semaphore.signal()
    }
    semaphore.wait()
    return (loadError == nil && !container.persistentStoreCoordinator.persistentStores.isEmpty, loadError)
  }

  static func backupIncompatibleStore(at storeURL: URL, fileManager: FileManager, reason: Error) -> Bool {
    guard fileManager.fileExists(atPath: storeURL.path) else { return false }
    let timestamp = ISO8601DateFormatter().string(from: Date())
      .replacingOccurrences(of: ":", with: "-")
      .replacingOccurrences(of: ".", with: "-")
    let backupDirectory = storeURL
      .deletingLastPathComponent()
      .appendingPathComponent("MigrationBackups", isDirectory: true)
      .appendingPathComponent(timestamp, isDirectory: true)

    do {
      try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
      let sidecars = [
        storeURL,
        URL(fileURLWithPath: storeURL.path + "-wal"),
        URL(fileURLWithPath: storeURL.path + "-shm")
      ]
      var movedFiles = 0
      for source in sidecars where fileManager.fileExists(atPath: source.path) {
        let destination = backupDirectory.appendingPathComponent(source.lastPathComponent)
        try fileManager.moveItem(at: source, to: destination)
        movedFiles += 1
      }
      AppLogger.log(
        .database,
        "Backed up incompatible MetaFace identity store files=\(movedFiles) path=\(backupDirectory.path) reason=\(reason.localizedDescription)"
      )
      return movedFiles > 0
    } catch {
      AppLogger.log(.database, "Failed to back up incompatible MetaFace identity store: \(error.localizedDescription)")
      return false
    }
  }

  static func makeModel() -> NSManagedObjectModel {
    let model = NSManagedObjectModel()
    model.entities = [
      entity("AppRun", [
        attr("id", .UUIDAttributeType), attr("startedAt", .dateAttributeType), attr("endedAt", .dateAttributeType, optional: true),
        attr("appBuild", .stringAttributeType, optional: true), attr("appVersion", .stringAttributeType, optional: true),
        attr("deviceId", .stringAttributeType, optional: true), attr("notes", .stringAttributeType, optional: true), attr("createdAt", .dateAttributeType)
      ]),
      entity("ConversationSession", [
        attr("id", .UUIDAttributeType), attr("appRunId", .UUIDAttributeType), attr("deviceId", .stringAttributeType, optional: true),
        attr("datDeviceId", .stringAttributeType, optional: true), attr("startedAt", .dateAttributeType), attr("endedAt", .dateAttributeType, optional: true),
        attr("streamStartedAt", .dateAttributeType, optional: true), attr("streamEndedAt", .dateAttributeType, optional: true),
        attr("state", .stringAttributeType), attr("createdAt", .dateAttributeType), attr("updatedAt", .dateAttributeType)
      ]),
      entity("PersonProfile", [
        attr("id", .UUIDAttributeType), attr("displayName", .stringAttributeType), attr("enrollmentStatus", .stringAttributeType),
        attr("consentStatus", .stringAttributeType), attr("createdAt", .dateAttributeType), attr("updatedAt", .dateAttributeType),
        attr("lastSeenAt", .dateAttributeType, optional: true), attr("notes", .stringAttributeType, optional: true), attr("isUnknownPlaceholder", .booleanAttributeType)
      ]),
      entity("FaceEmbeddingSample", [
        attr("id", .UUIDAttributeType), attr("personId", .UUIDAttributeType, optional: true), attr("appRunId", .UUIDAttributeType),
        attr("conversationSessionId", .UUIDAttributeType, optional: true), attr("vector", .binaryDataAttributeType), attr("vectorDimension", .integer64AttributeType),
        attr("modelName", .stringAttributeType), attr("modelVersion", .stringAttributeType, optional: true),
        attr("modelSource", .stringAttributeType, optional: true), attr("preprocessingVersion", .stringAttributeType, optional: true),
        attr("qualityScore", .doubleAttributeType),
        attr("frameNumber", .integer64AttributeType, optional: true), attr("faceBoxNormalized", .stringAttributeType, optional: true),
        attr("rawFaceBoxPixels", .stringAttributeType, optional: true), attr("faceBoxPixels", .stringAttributeType, optional: true),
        attr("qualityTier", .stringAttributeType, optional: true), attr("faceCaptureQuality", .doubleAttributeType, optional: true),
        attr("yaw", .doubleAttributeType, optional: true), attr("pitch", .doubleAttributeType, optional: true), attr("roll", .doubleAttributeType, optional: true),
        attr("cropWidth", .integer64AttributeType), attr("cropHeight", .integer64AttributeType), attr("sourceFrameWidth", .integer64AttributeType),
        attr("sourceFrameHeight", .integer64AttributeType), attr("sourceFrameTimestamp", .dateAttributeType, optional: true),
        attr("orientationUsed", .stringAttributeType, optional: true), attr("sampleImageLocalPath", .stringAttributeType, optional: true),
        attr("createdAt", .dateAttributeType)
      ]),
      entity("PersonAveragedEmbedding", [
        attr("id", .UUIDAttributeType), attr("personId", .UUIDAttributeType), attr("averagedVector", .binaryDataAttributeType),
        attr("vectorDimension", .integer64AttributeType), attr("sampleCount", .integer64AttributeType), attr("modelName", .stringAttributeType),
        attr("modelVersion", .stringAttributeType, optional: true), attr("modelSource", .stringAttributeType, optional: true),
        attr("preprocessingVersion", .stringAttributeType, optional: true), attr("updatedAt", .dateAttributeType)
      ]),
      entity("FaceDetectionEvent", [
        attr("id", .UUIDAttributeType), attr("appRunId", .UUIDAttributeType), attr("conversationSessionId", .UUIDAttributeType, optional: true),
        attr("frameIndex", .integer64AttributeType), attr("frameWidth", .integer64AttributeType), attr("frameHeight", .integer64AttributeType),
        attr("uiImageOrientation", .stringAttributeType), attr("cgImageWidth", .integer64AttributeType), attr("cgImageHeight", .integer64AttributeType),
        attr("visionOrientationUsed", .stringAttributeType), attr("preferredFaceCount", .integer64AttributeType), attr("sweepFaceCountsJson", .stringAttributeType),
        attr("selectedOrientation", .stringAttributeType, optional: true), attr("selectedFaceCount", .integer64AttributeType), attr("createdAt", .dateAttributeType)
      ]),
      entity("TranscriptChunk", [
        attr("id", .UUIDAttributeType), attr("appRunId", .UUIDAttributeType), attr("conversationSessionId", .UUIDAttributeType),
        attr("personId", .UUIDAttributeType, optional: true), attr("activeIdentityState", .stringAttributeType), attr("text", .stringAttributeType),
        attr("isFinal", .booleanAttributeType), attr("startedAt", .dateAttributeType, optional: true), attr("endedAt", .dateAttributeType, optional: true),
        attr("transcriptUpdatedAt", .dateAttributeType), attr("source", .stringAttributeType), attr("createdAt", .dateAttributeType)
      ]),
      entity("SceneContextRecord", [
        attr("id", .UUIDAttributeType), attr("appRunId", .UUIDAttributeType), attr("conversationSessionId", .UUIDAttributeType, optional: true),
        attr("personId", .UUIDAttributeType, optional: true), attr("startedAt", .dateAttributeType), attr("endedAt", .dateAttributeType),
        attr("createdAt", .dateAttributeType), attr("modelName", .stringAttributeType), attr("promptVersion", .stringAttributeType),
        attr("transcriptChunkIdsJson", .stringAttributeType), attr("frameTimestampsJson", .stringAttributeType),
        attr("locationLabel", .stringAttributeType, optional: true), attr("latitude", .doubleAttributeType, optional: true),
        attr("longitude", .doubleAttributeType, optional: true), attr("locationAccuracyMeters", .doubleAttributeType, optional: true),
        attr("who", .stringAttributeType), attr("whereText", .stringAttributeType), attr("what", .stringAttributeType),
        attr("whenText", .stringAttributeType), attr("why", .stringAttributeType), attr("how", .stringAttributeType),
        attr("interactionStyle", .stringAttributeType, optional: true), attr("summary", .stringAttributeType),
        attr("confidence", .doubleAttributeType), attr("evidenceJson", .stringAttributeType)
      ]),
      entity("PresenceEpisodeRecord", [
        attr("id", .UUIDAttributeType), attr("appRunId", .UUIDAttributeType),
        attr("conversationSessionId", .UUIDAttributeType, optional: true), attr("personId", .UUIDAttributeType, optional: true),
        attr("displayName", .stringAttributeType), attr("startedAt", .dateAttributeType),
        attr("lastEvidenceAt", .dateAttributeType), attr("endedAt", .dateAttributeType, optional: true),
        attr("status", .stringAttributeType), attr("confidence", .doubleAttributeType),
        attr("evidenceSummary", .stringAttributeType), attr("updatedAt", .dateAttributeType)
      ]),
      entity("ActivityModeEpisodeRecord", [
        attr("id", .UUIDAttributeType), attr("appRunId", .UUIDAttributeType),
        attr("conversationSessionId", .UUIDAttributeType, optional: true),
        attr("mode", .stringAttributeType), attr("specificActivity", .stringAttributeType),
        attr("startedAt", .dateAttributeType), attr("lastEvidenceAt", .dateAttributeType),
        attr("endedAt", .dateAttributeType, optional: true), attr("confidence", .doubleAttributeType),
        attr("reason", .stringAttributeType), attr("source", .stringAttributeType),
        attr("modelName", .stringAttributeType), attr("promptVersion", .stringAttributeType),
        attr("updatedAt", .dateAttributeType)
      ]),
      entity("GlassesDisplayInteractionEvent", [
        attr("id", .UUIDAttributeType), attr("appRunId", .UUIDAttributeType),
        attr("conversationSessionId", .UUIDAttributeType, optional: true), attr("personId", .UUIDAttributeType, optional: true),
        attr("displayName", .stringAttributeType, optional: true), attr("cardTitle", .stringAttributeType),
        attr("cardText", .stringAttributeType), attr("action", .stringAttributeType), attr("source", .stringAttributeType),
        attr("createdAt", .dateAttributeType)
      ]),
      entity("IdentityMatchEvent", [
        attr("id", .UUIDAttributeType), attr("appRunId", .UUIDAttributeType), attr("conversationSessionId", .UUIDAttributeType, optional: true),
        attr("frameNumber", .integer64AttributeType, optional: true), attr("detectedFaceCount", .integer64AttributeType),
        attr("cropQualityTier", .stringAttributeType, optional: true), attr("embeddingModelName", .stringAttributeType, optional: true),
        attr("embeddingModelVersion", .stringAttributeType, optional: true), attr("candidatePersonId", .UUIDAttributeType, optional: true),
        attr("cosineSimilarity", .doubleAttributeType), attr("l2Distance", .doubleAttributeType, optional: true), attr("threshold", .doubleAttributeType),
        attr("rollingWindowSize", .integer64AttributeType), attr("rollingConfirmCount", .integer64AttributeType), attr("decision", .stringAttributeType),
        attr("rollingConfirmationState", .stringAttributeType, optional: true), attr("createdAt", .dateAttributeType)
      ])
    ]
    return model
  }

  static func entity(_ name: String, _ attributes: [NSAttributeDescription]) -> NSEntityDescription {
    let entity = NSEntityDescription()
    entity.name = name
    entity.managedObjectClassName = "NSManagedObject"
    entity.properties = attributes
    return entity
  }

  static func attr(_ name: String, _ type: NSAttributeType, optional: Bool = false) -> NSAttributeDescription {
    let attr = NSAttributeDescription()
    attr.name = name
    attr.attributeType = type
    attr.isOptional = optional
    if !optional {
      switch type {
      case .UUIDAttributeType:
        attr.defaultValue = UUID()
      case .stringAttributeType:
        attr.defaultValue = ""
      case .dateAttributeType:
        attr.defaultValue = Date(timeIntervalSince1970: 0)
      case .booleanAttributeType:
        attr.defaultValue = false
      case .doubleAttributeType, .floatAttributeType, .decimalAttributeType:
        attr.defaultValue = 0
      case .integer16AttributeType, .integer32AttributeType, .integer64AttributeType:
        attr.defaultValue = 0
      case .binaryDataAttributeType:
        attr.defaultValue = Data()
      default:
        break
      }
    }
    return attr
  }
}

private extension CodableCGRect {
  var jsonString: String {
    String(format: "{\"x\":%.5f,\"y\":%.5f,\"width\":%.5f,\"height\":%.5f}", x, y, width, height)
  }
}
