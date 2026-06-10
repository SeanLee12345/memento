import Foundation
import UIKit

actor IdentityPipeline {
  private struct CapturedFaceGroup {
    var id: UUID
    var samples: [CapturedFaceSampleSnapshot]
    var firstSeenAt: Date
    var lastSeenAt: Date
    var bestQuality: Float
    var status: String
    var recognizedPersonId: UUID?
    var recognizedPersonName: String?
  }

  private struct CaptureGroupMatch {
    let index: Int
    let method: String
    let score: Float?
    let reason: String
  }

  private struct CalibrationObservation {
    let profile: PersonProfile?
    let frameSequence: UInt64
    let candidate: IdentityCandidate
    let match: IdentityMatchResult
    let state: ActiveIdentityState
  }

  private struct FaceEnrollmentEmbeddingSource {
    let label: String
    let model: FaceEmbeddingModel
  }

  private let store: IdentityStore
  private var embeddingModel: FaceEmbeddingModel
  private var cloudFaceEmbeddingEnabled = false
  private var cloudFaceEmbeddingDisabledReason: String?
  private var cloudEnrollmentEmbeddingModel: FaceEmbeddingModel?
  private var localEnrollmentEmbeddingModel: FaceEmbeddingModel?
  private let matcher = FaceMatcher()
  private var confirmor = RollingIdentityConfirmor()
  private var isProcessing = false
  private var lastProcessedAt: Date?
  private var lastPromptAt: Date?
  private var pendingUnknownEmbeddings: [FaceEmbeddingRecord] = []
  private var pendingUnknownRejectedSamples = 0
  private var pendingUnknownPreview: UIImage?
  private var enrollmentWaitingForNextSample = false
  private var enrollmentStatusText = "Enrollment idle"
  private var forceDebugEmbeddingOnNextFace = false
  private var lastDetectedFaceCandidate: EnrollmentCandidateSnapshot?
  private var lastRecognitionCandidate: EnrollmentCandidateSnapshot?
  private var lastEnrollmentCandidate: EnrollmentCandidateSnapshot?
  private var lastEnrollmentCandidateUpdateAt: Date?
  private var activeState = ActiveIdentityState.none
  private var activeAppRun: AppRun?
  private var activeConversation: ConversationSession?
  private var activePartialTranscriptChunk: TranscriptChunk?
  private var lastSavedFinalTranscript = ""
  private var lastMeaningfulPartialTranscript = ""
  private var cachedProfiles: [PersonProfile] = []
  private var statsStartedAt = Date()
  private var statsFaces = 0
  private var statsQualityPass = 0
  private var statsEmbedded = 0
  private var statsMatched = 0
  private var statsEmbedLatencyMS: Double = 0
  private var calibrationStatusText = "ready"
  private var calibrationSamples: [FaceCalibrationSample] = []
  private var lastCalibrationObservation: CalibrationObservation?
  private var captureGroups: [CapturedFaceGroup] = []
  private var totalSessionCaptures = 0
  private let faceCaptureIntervalSeconds: TimeInterval = 1.0
  private let maxSamplesPerCaptureGroup = 60
  private let maxSessionCaptures = 300

  // Default store is the Supabase-syncing wrapper around LocalIdentityStore.
  // Reads stay on the fast local path; writes also enqueue a cloud mirror via
  // IdentitySyncQueue. Passing a bare LocalIdentityStore is still valid for
  // tests that want to bypass network mirroring.
  init(store: IdentityStore = SyncingIdentityStore()) {
    self.store = store
    AppLogger.log(.identityConfig, IdentityConfig.startupLogText)
    AppLogger.log(.faceEmbeddingModel, FaceEmbeddingModelFactory.diagnosticsText())
    AppLogger.log(.faceEmbeddingModel, FaceEmbeddingModelFactory.expectedModelResourceInstructions())
    let localModel = Self.localEmbeddingModelIfAvailable()
    localEnrollmentEmbeddingModel = localModel
    let baseModel = localModel ?? FaceEmbeddingModelFactory.makeModel()
    embeddingModel = baseModel
    let cloudSettings = CloudFaceEmbeddingSettings.load()
    if cloudSettings.enabled, cloudSettings.hasUsableEndpoint {
      let cloudModel = CloudFaceEmbeddingModel(settings: cloudSettings)
      cloudEnrollmentEmbeddingModel = cloudModel
      embeddingModel = cloudModel
      cloudFaceEmbeddingEnabled = true
    }
  }

  private static func localEmbeddingModelIfAvailable() -> FaceEmbeddingModel? {
    let model = FaceEmbeddingModelFactory.makeLocalModelOnly()
    return model is MissingFaceEmbeddingModel ? nil : model
  }

  // Swap the live embedding model to the AWS AdaFace worker while keeping
  // MobileFaceNet as the local fallback if the bundled model is available.
  func configureCloudFaceEmbedding(endpoint: String, apiKey: String) async {
    let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let settings = CloudFaceEmbeddingSettings(
      enabled: true,
      endpoint: trimmedEndpoint,
      apiKey: trimmedKey
    )
    let localFallback = Self.localEmbeddingModelIfAvailable()
    localEnrollmentEmbeddingModel = localFallback
    let cloudModel: FaceEmbeddingModel = CloudFaceEmbeddingModel(settings: settings)
    do {
      try await cloudModel.load()
    } catch {
      cloudFaceEmbeddingEnabled = false
      cloudFaceEmbeddingDisabledReason = "loadFailed"
      AppLogger.log(.faceEmbeddingModel, "warning...---- AWS AdaFace face embedding load failed: \(error.localizedDescription)")
      return
    }
    cloudEnrollmentEmbeddingModel = cloudModel
    embeddingModel = cloudModel
    cloudFaceEmbeddingEnabled = true
    cloudFaceEmbeddingDisabledReason = nil
    AppLogger.log(.faceEmbeddingModel, "AWS AdaFace face embedding active endpoint=\(trimmedEndpoint)")
  }

  func disableCloudFaceEmbedding(reason: String) async {
    guard cloudFaceEmbeddingEnabled || cloudFaceEmbeddingDisabledReason == "starting" else { return }
    cloudFaceEmbeddingEnabled = false
    cloudFaceEmbeddingDisabledReason = reason
    cloudEnrollmentEmbeddingModel = nil
    let localFallback = Self.localEmbeddingModelIfAvailable()
    localEnrollmentEmbeddingModel = localFallback
    embeddingModel = localFallback ?? MissingFaceEmbeddingModel(expectedNames: FaceEmbeddingModelFactory.expectedModelNames)
    let fallbackStatus = localFallback == nil ? "local MobileFaceNet missing" : "using local \(embeddingModel.modelName)"
    AppLogger.log(.faceEmbeddingModel, "AWS AdaFace face embedding disabled reason=\(reason); \(fallbackStatus)")
  }

  func markCloudFaceEmbeddingStarting() {
    cloudFaceEmbeddingEnabled = false
    cloudFaceEmbeddingDisabledReason = "starting"
    localEnrollmentEmbeddingModel = Self.localEmbeddingModelIfAvailable()
    if let localEnrollmentEmbeddingModel {
      embeddingModel = localEnrollmentEmbeddingModel
    }
    AppLogger.log(.faceEmbeddingModel, "AWS AdaFace face embedding starting")
  }

  func embeddingModelStatusText() -> String {
    if let reason = cloudFaceEmbeddingDisabledReason {
      let hasLocalFallback = !(embeddingModel is MissingFaceEmbeddingModel)
      switch reason {
      case "starting":
        return hasLocalFallback
          ? "AWS AdaFace is starting; using local \(embeddingModel.modelName) until the worker is ready."
          : "AWS AdaFace is starting; face recognition will resume when the worker is ready."
      case "workerWarming":
        return hasLocalFallback
          ? "AWS AdaFace worker is warming; using local \(embeddingModel.modelName) fallback."
          : "AWS AdaFace worker is warming; face recognition is paused."
      case "settingsDisabled":
        return hasLocalFallback
          ? "AWS AdaFace disabled; using local \(embeddingModel.modelName)."
          : "AWS AdaFace disabled; face recognition is disabled."
      case "startFailed":
        return hasLocalFallback
          ? "AWS AdaFace failed to start; using local \(embeddingModel.modelName)."
          : "AWS AdaFace failed to start; face recognition is disabled."
      default:
        if reason.hasPrefix("streamStop-") {
          return hasLocalFallback
            ? "AWS AdaFace stopped with the stream; using local \(embeddingModel.modelName)."
            : "AWS AdaFace stopped with the stream; face recognition is disabled."
        }
      }
    }
    if embeddingModel is MissingFaceEmbeddingModel {
      return "Face recognition model missing. Face labeling can save images, but live recognition is disabled."
    }
    if embeddingModel is MockFaceEmbeddingModel {
      return "Debug stub embeddings enabled"
    }
    return "Loaded \(embeddingModel.modelName) \(embeddingModel.modelVersion) dim \(embeddingModel.embeddingDimension)"
  }

  func embeddingModelDiagnosticsText() -> String {
    FaceEmbeddingModelFactory.diagnosticsText()
  }

  func isCloudFaceEmbeddingActive() -> Bool {
    cloudFaceEmbeddingEnabled
      && cloudEnrollmentEmbeddingModel != nil
      && embeddingModel.modelName == "AdaFace"
  }

  static func enrollmentPhysicalSampleCount(in records: [FaceEmbeddingRecord]) -> Int {
    Set(records.map { enrollmentPhysicalSampleKey(for: $0) }).count
  }

  static func trimPendingEnrollmentRecords(_ records: [FaceEmbeddingRecord], maxPhysicalSamples: Int) -> [FaceEmbeddingRecord] {
    guard maxPhysicalSamples > 0 else { return [] }
    var orderedKeys: [String] = []
    for record in records {
      let key = enrollmentPhysicalSampleKey(for: record)
      if !orderedKeys.contains(key) {
        orderedKeys.append(key)
      }
    }
    let keysToKeep = Set(orderedKeys.suffix(maxPhysicalSamples))
    return records.filter { keysToKeep.contains(enrollmentPhysicalSampleKey(for: $0)) }
  }

  static func enrollmentEmbeddingSpaceKey(for record: FaceEmbeddingRecord) -> String {
    [
      record.modelName,
      record.modelVersion,
      record.modelSource,
      record.preprocessingVersion,
      String(record.dimension)
    ].joined(separator: "|")
  }

  private static func enrollmentEmbeddingSpaceKey(for embedding: FaceEmbedding) -> String {
    [
      embedding.modelName,
      embedding.modelVersion,
      embedding.modelSource,
      embedding.preprocessingVersion,
      String(embedding.dimension)
    ].joined(separator: "|")
  }

  private static func enrollmentPhysicalSampleKey(for record: FaceEmbeddingRecord) -> String {
    if let frameNumber = record.frameNumber {
      return "frame:\(frameNumber)"
    }
    if let path = record.sampleImageLocalPath {
      return "path:\(path)"
    }
    return "record:\(record.id.uuidString)"
  }

  private func enrollmentEmbeddingSources() -> [FaceEnrollmentEmbeddingSource] {
    var sources: [FaceEnrollmentEmbeddingSource] = []
    if cloudFaceEmbeddingEnabled,
       let cloudEnrollmentEmbeddingModel,
       !(cloudEnrollmentEmbeddingModel is MissingFaceEmbeddingModel) {
      sources.append(FaceEnrollmentEmbeddingSource(label: "aws-AdaFace", model: cloudEnrollmentEmbeddingModel))
    }
    if let localEnrollmentEmbeddingModel,
       !(localEnrollmentEmbeddingModel is MissingFaceEmbeddingModel) {
      sources.append(FaceEnrollmentEmbeddingSource(label: "local-MobileFaceNet", model: localEnrollmentEmbeddingModel))
    }
    if sources.isEmpty, !(embeddingModel is MissingFaceEmbeddingModel) {
      sources.append(FaceEnrollmentEmbeddingSource(label: "active-\(embeddingModel.modelName)", model: embeddingModel))
    }
    return sources
  }

  private func logEnrollmentWarning(_ message: String, context: PipelineContext?) {
    AppLogger.log(.enrollment, "\(context.logPrefix) warning...---- \(message)")
  }

  private func makeEnrollmentEmbeddingRecords(
    faceImage: CGImage,
    cropImage: UIImage,
    personId: UUID?,
    context: PipelineContext?,
    frameSequence: UInt64,
    timestamp: Date,
    qualityScore: Float?,
    qualityTier: FaceQualityTier?,
    cropSize: CGSize,
    sourceImageSize: CGSize,
    existingImagePath: String? = nil
  ) async throws -> [FaceEmbeddingRecord] {
    let sources = enrollmentEmbeddingSources()
    guard !sources.isEmpty else {
      logEnrollmentWarning("faceEnrollment failed reason=noEmbeddingModels", context: context)
      throw FaceEmbeddingError.coreMLModelMissing(expectedNames: FaceEmbeddingModelFactory.expectedModelResourceNames())
    }

    var records: [FaceEmbeddingRecord] = []
    var seenEmbeddingSpaces = Set<String>()
    var sharedImagePath = existingImagePath
    var failures: [String] = []

    for source in sources {
      do {
        let embedding = try await source.model.embed(faceImage: faceImage)
        let embeddingKey = Self.enrollmentEmbeddingSpaceKey(for: embedding)
        guard !seenEmbeddingSpaces.contains(embeddingKey) else {
          AppLogger.log(.enrollment, "\(context.logPrefix) faceEnrollment skippedDuplicateEmbeddingSpace source=\(source.label) key=\(embeddingKey)")
          continue
        }
        seenEmbeddingSpaces.insert(embeddingKey)
        let recordId = UUID()
        if sharedImagePath == nil {
          do {
            sharedImagePath = try saveCropImage(cropImage, frameSequence: frameSequence, recordId: recordId)
          } catch {
            logEnrollmentWarning("faceEnrollment cropSaveFailed frame=\(frameSequence) error=\(error.localizedDescription)", context: context)
          }
        }
        let record = FaceEmbeddingRecord(
          id: recordId,
          personId: personId,
          vector: embedding.vector,
          dimension: embedding.dimension,
          qualityScore: qualityScore,
          sourceFrameTimestamp: timestamp,
          createdAt: Date(),
          sampleImageLocalPath: sharedImagePath,
          metadata: FaceEmbeddingMetadata(
            boundingBoxNormalized: CodableCGRect(.zero),
            cropSize: CodableCGSize(cropSize),
            sourceImageSize: CodableCGSize(sourceImageSize)
          ),
          appRunId: context?.appRunId,
          conversationSessionId: context?.conversationSessionId,
          modelName: embedding.modelName,
          modelVersion: embedding.modelVersion,
          modelSource: embedding.modelSource,
          preprocessingVersion: embedding.preprocessingVersion,
          frameNumber: frameSequence,
          qualityTier: qualityTier,
          cropWidth: Int(cropSize.width),
          cropHeight: Int(cropSize.height),
          sourceFrameWidth: Int(sourceImageSize.width),
          sourceFrameHeight: Int(sourceImageSize.height)
        )
        records.append(record)
      } catch {
        failures.append("\(source.label):\(error.localizedDescription)")
        logEnrollmentWarning("faceEnrollment embeddingFailed source=\(source.label) frame=\(frameSequence) error=\(error.localizedDescription)", context: context)
      }
    }

    guard !records.isEmpty else {
      logEnrollmentWarning("faceEnrollment failed reason=allEmbeddingModelsFailed failures=\(failures.joined(separator: ";"))", context: context)
      throw FaceEmbeddingError.invalidEmbeddingValues("all enrollment embedding models failed")
    }
    return records
  }

  private func backfillPendingEnrollmentVectors(context: PipelineContext?) async {
    let sources = enrollmentEmbeddingSources()
    guard sources.count > 1, !pendingUnknownEmbeddings.isEmpty else { return }

    let grouped = Dictionary(grouping: pendingUnknownEmbeddings, by: { Self.enrollmentPhysicalSampleKey(for: $0) })
    var additionalRecords: [FaceEmbeddingRecord] = []
    for records in grouped.values {
      guard let representative = records.first else { continue }
      let existingSpaces = Set(records.map { Self.enrollmentEmbeddingSpaceKey(for: $0) })
      guard existingSpaces.count < sources.count else { continue }
      guard let path = representative.sampleImageLocalPath, !path.isEmpty else {
        logEnrollmentWarning("pendingEnrollmentBackfill skipped reason=missingCropImage frame=\(representative.frameNumber.map(String.init) ?? "nil")", context: context)
        continue
      }
      guard let image = UIImage(contentsOfFile: path), let cgImage = image.cgImage else {
        logEnrollmentWarning("pendingEnrollmentBackfill skipped reason=cropImageUnreadable path=\(path)", context: context)
        continue
      }

      let cropSize = representative.metadata?.cropSize.cgSize
        ?? CGSize(width: CGFloat(representative.cropWidth ?? cgImage.width), height: CGFloat(representative.cropHeight ?? cgImage.height))
      let sourceImageSize = representative.metadata?.sourceImageSize.cgSize
        ?? CGSize(width: CGFloat(representative.sourceFrameWidth ?? Int(cropSize.width)), height: CGFloat(representative.sourceFrameHeight ?? Int(cropSize.height)))
      do {
        let backfilled = try await makeEnrollmentEmbeddingRecords(
          faceImage: cgImage,
          cropImage: image,
          personId: nil,
          context: context,
          frameSequence: representative.frameNumber ?? 0,
          timestamp: representative.sourceFrameTimestamp,
          qualityScore: representative.qualityScore,
          qualityTier: representative.qualityTier,
          cropSize: cropSize,
          sourceImageSize: sourceImageSize,
          existingImagePath: path
        )
        let missingRecords = backfilled.filter { !existingSpaces.contains(Self.enrollmentEmbeddingSpaceKey(for: $0)) }
        additionalRecords.append(contentsOf: missingRecords)
      } catch {
        logEnrollmentWarning("pendingEnrollmentBackfill failed frame=\(representative.frameNumber.map(String.init) ?? "nil") error=\(error.localizedDescription)", context: context)
      }
    }

    if !additionalRecords.isEmpty {
      pendingUnknownEmbeddings.append(contentsOf: additionalRecords)
      pendingUnknownEmbeddings = Self.trimPendingEnrollmentRecords(pendingUnknownEmbeddings, maxPhysicalSamples: 12)
      AppLogger.log(.enrollment, "\(context.logPrefix) pendingEnrollmentBackfill addedVectors=\(additionalRecords.count) totalSamples=\(Self.enrollmentPhysicalSampleCount(in: pendingUnknownEmbeddings)) totalVectors=\(pendingUnknownEmbeddings.count)")
    }
  }

  @discardableResult
  func startAppRunIfNeeded(deviceId: String? = nil) async -> RunSessionSnapshot {
    if let activeAppRun {
      return snapshot(appRunId: activeAppRun.id, conversationSessionId: activeConversation?.id)
    }
    do {
      let run = try await store.startAppRun(deviceId: deviceId)
      activeAppRun = run
      return try await store.runSessionSnapshot(appRunId: run.id, conversationSessionId: activeConversation?.id)
    } catch {
      AppLogger.log(.database, "AppRun creation failed: \(error.localizedDescription)")
      return RunSessionSnapshot(appRunId: nil, conversationSessionId: nil, detectedFacesThisSession: 0, acceptedFaceCropsThisSession: 0, embeddingsSavedThisSession: 0, transcriptChunksSavedThisSession: 0)
    }
  }

  @discardableResult
  func startConversationSession(deviceId: String? = nil, datDeviceId: String? = nil) async -> RunSessionSnapshot {
    _ = await startAppRunIfNeeded(deviceId: deviceId)
    guard let activeAppRun else {
      return snapshot(appRunId: nil, conversationSessionId: nil)
    }
    do {
      if let activeConversation, activeConversation.endedAt == nil {
        try await store.endConversationSession(activeConversation.id)
      }
      let session = try await store.startConversationSession(appRunId: activeAppRun.id, deviceId: deviceId, datDeviceId: datDeviceId)
      activeConversation = session
      activePartialTranscriptChunk = nil
      lastSavedFinalTranscript = ""
      lastMeaningfulPartialTranscript = ""
      // Session start is on the DAT stream startup path. Avoid a synchronous
      // aggregate fetch here; live processing will refresh counts as events arrive.
      return snapshot(appRunId: activeAppRun.id, conversationSessionId: session.id)
    } catch {
      AppLogger.log(.database, "ConversationSession creation failed appRun=\(activeAppRun.id.uuidString): \(error.localizedDescription)")
      return snapshot(appRunId: activeAppRun.id, conversationSessionId: activeConversation?.id)
    }
  }

  func endAppRun() async {
    if let activeConversation {
      try? await store.endConversationSession(activeConversation.id)
      self.activeConversation = nil
    }
    if let activeAppRun {
      try? await store.endAppRun(activeAppRun.id)
      self.activeAppRun = nil
    }
  }

  func currentContext() -> PipelineContext? {
    guard let activeAppRun else { return nil }
    return PipelineContext(
      appRunId: activeAppRun.id,
      conversationSessionId: activeConversation?.id,
      datDeviceId: activeConversation?.datDeviceId
    )
  }

  func currentRunSessionSnapshot() async -> RunSessionSnapshot {
    let context = currentContext()
    guard let appRunId = context?.appRunId else {
      return RunSessionSnapshot(appRunId: nil, conversationSessionId: nil, detectedFacesThisSession: 0, acceptedFaceCropsThisSession: 0, embeddingsSavedThisSession: 0, transcriptChunksSavedThisSession: 0)
    }
    return (try? await store.runSessionSnapshot(appRunId: appRunId, conversationSessionId: context?.conversationSessionId))
      ?? snapshot(appRunId: appRunId, conversationSessionId: context?.conversationSessionId)
  }

  func currentProfiles() async -> [PersonProfile] {
    (try? await store.loadPeople()) ?? []
  }

  func loadPeopleForDictionary() async -> [PersonDictionaryEntry] {
    let profiles = (try? await store.loadPeople()) ?? []
    let displayNamesById = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0.displayName) })
    var entries: [PersonDictionaryEntry] = []
    for profile in profiles {
      let transcripts = (try? await store.transcriptChunksForPerson(profile.id)) ?? []
      let embeddings = (try? await store.embeddingsForPerson(profile.id)) ?? []
      let thumbnail = Self.thumbnailImage(from: embeddings)
        ?? Self.thumbnailImage(fromProfileNotes: profile.notes)
        ?? store.thumbnailImage(forDisplayName: profile.displayName)
      let glassesInteractions = (try? await store.glassesDisplayInteractionsForPerson(profile.id)) ?? []
      let interactionDays = Self.buildInteractionDays(
        transcripts: transcripts,
        embeddings: embeddings,
        glassesInteractions: glassesInteractions
      )
      let sceneContexts = (try? await store.sceneContextsForPerson(profile.id)) ?? []
      let conversationTranscripts = await conversationTranscripts(
        involving: profile.id,
        ownTranscripts: transcripts,
        displayNamesById: displayNamesById
      )
      let embeddingImages = embeddings.compactMap { record -> UIImage? in
        guard let path = record.sampleImageLocalPath else { return nil }
        return UIImage(contentsOfFile: path)
      }
      entries.append(PersonDictionaryEntry(
        profile: profile,
        thumbnail: thumbnail,
        transcripts: transcripts,
        interactionDays: interactionDays,
        embeddingImages: embeddingImages,
        conversationTranscripts: conversationTranscripts,
        sceneContexts: sceneContexts,
        glassesDisplayInteractions: glassesInteractions
      ))
    }
    return entries.sorted { $0.profile.displayName.localizedCaseInsensitiveCompare($1.profile.displayName) == .orderedAscending }
  }

  func thumbnailImage(forPersonId personId: UUID) async -> UIImage? {
    let embeddings = (try? await store.embeddingsForPerson(personId)) ?? []
    if let thumbnail = Self.thumbnailImage(from: embeddings) {
      return thumbnail
    }
    let profile = (try? await store.loadPeople())?
      .first(where: { $0.id == personId })
    if let thumbnail = Self.thumbnailImage(fromProfileNotes: profile?.notes) {
      return thumbnail
    }
    return profile.flatMap { store.thumbnailImage(forDisplayName: $0.displayName) }
  }

  func saveSceneContext(_ record: SceneContextRecord) async {
    try? await store.saveSceneContext(record, context: currentContext())
  }

  func savePresenceEpisode(_ record: PresenceEpisodeRecord) async {
    try? await store.savePresenceEpisode(record, context: currentContext())
  }

  func saveActivityModeEpisode(_ record: ActivityModeEpisodeRecord) async {
    try? await store.saveActivityModeEpisode(record, context: currentContext())
  }

  func saveGlassesDisplayInteraction(_ event: GlassesDisplayInteractionEvent) async {
    try? await store.saveGlassesDisplayInteraction(event, context: currentContext())
  }

  func reconcileSceneContextsForConversation(sessionId: UUID) async {
    let context = currentContext()
    let chunks = ((try? await store.transcriptChunksForConversationSessions([sessionId])) ?? [])
      .filter { $0.isFinal }
    guard !chunks.isEmpty else { return }
    let contexts = (try? await store.sceneContextsForConversationSessions([sessionId])) ?? []
    var updatedCount = 0
    for var record in contexts {
      let candidateChunks = transcriptChunks(for: record, in: chunks)
      let personIds = Set(candidateChunks.compactMap(\.personId))
      guard personIds.count == 1, let personId = personIds.first, record.personId != personId else { continue }
      record.personId = personId
      try? await store.updateSceneContext(record, context: context)
      updatedCount += 1
    }
    if updatedCount > 0 {
      AppLogger.log(.sceneContext, "\(context.logPrefix) reconciled scene contexts session=\(sessionId.uuidString) updated=\(updatedCount)")
    }
  }

  func findOrCreateVoiceOnlyPerson(named name: String) async -> PersonProfile? {
    _ = await startAppRunIfNeeded()
    let context = currentContext()
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let profiles = (try? await store.loadPeople()) ?? cachedProfiles
    if let existing = profiles.first(where: {
      !$0.isUnknownPlaceholder && $0.displayName.lowercased() == trimmed.lowercased()
    }) {
      cachedProfiles = profiles
      return existing
    }

    let now = Date()
    let profile = PersonProfile(
      id: UUID(),
      displayName: trimmed,
      createdAt: now,
      updatedAt: now,
      notes: "source=voiceOnly",
      isUnknownPlaceholder: false,
      lastSeenAt: now,
      enrollmentStatus: .enrolled,
      consentStatus: .consented,
      embeddingIds: [],
      primaryEmbeddingId: nil
    )
    do {
      try await store.savePersonProfile(profile, context: context)
      cachedProfiles = (try? await store.loadPeople()) ?? (profiles + [profile])
      AppLogger.log(.database, "\(context.logPrefix) createdVoiceOnlyPerson id=\(profile.id.uuidString) displayName=\"\(profile.displayName)\"")
      return profile
    } catch {
      AppLogger.log(.database, "\(context.logPrefix) createVoiceOnlyPerson failed name=\"\(trimmed)\" error=\(error.localizedDescription)")
      return nil
    }
  }

  private func conversationTranscripts(
    involving personId: UUID,
    ownTranscripts: [TranscriptChunk],
    displayNamesById: [UUID: String]
  ) async -> [PersonConversationTranscript] {
    let sessionIds = Array(Set(ownTranscripts.map(\.conversationSessionId)))
    let allChunks = ((try? await store.transcriptChunksForConversationSessions(sessionIds)) ?? [])
      .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    let sceneContexts = ((try? await store.sceneContextsForConversationSessions(sessionIds)) ?? [])
      .filter { $0.personId == personId }
    let sceneContextsBySession = Dictionary(grouping: sceneContexts) { $0.conversationSessionId }
    let grouped = Dictionary(grouping: allChunks, by: \.conversationSessionId)
    return grouped.map { sessionId, chunks in
      let sorted = chunks.sorted { ($0.startedAt ?? $0.createdAt) < ($1.startedAt ?? $1.createdAt) }
      let lines = sorted.map { chunk in
        ConversationTranscriptLine(
          chunk: chunk,
          speakerName: chunk.personId.flatMap { displayNamesById[$0] }
            ?? Self.speakerLabel(from: chunk.source)
            ?? "Unknown Speaker"
        )
      }
      return PersonConversationTranscript(
        conversationSessionId: sessionId,
        startedAt: sorted.first?.startedAt ?? sorted.first?.createdAt ?? Date(),
        endedAt: sorted.last?.endedAt ?? sorted.last?.createdAt,
        lines: lines,
        sceneContexts: sceneContextsBySession[sessionId]?.sorted { $0.startedAt > $1.startedAt } ?? []
      )
    }
    .sorted { $0.startedAt > $1.startedAt }
  }

  private func transcriptChunks(for record: SceneContextRecord, in chunks: [TranscriptChunk]) -> [TranscriptChunk] {
    let ids = Self.decodeUUIDArray(record.transcriptChunkIdsJson)
    if !ids.isEmpty {
      let idSet = Set(ids)
      let matches = chunks.filter { idSet.contains($0.id) }
      if !matches.isEmpty { return matches }
    }
    return chunks.filter { chunk in
      let start = chunk.startedAt ?? chunk.createdAt
      let end = chunk.endedAt ?? start
      return start <= record.endedAt && end >= record.startedAt
    }
  }

  private static func decodeUUIDArray(_ json: String) -> [UUID] {
    guard let data = json.data(using: .utf8),
          let strings = try? JSONDecoder().decode([String].self, from: data) else {
      return []
    }
    return strings.compactMap(UUID.init(uuidString:))
  }

  private static func speakerLabel(from source: String) -> String? {
    for marker in ["speakerLabel=", "speaker="] {
      guard let range = source.range(of: marker) else { continue }
      let tail = source[range.upperBound...]
      let value = tail.split(separator: ";", maxSplits: 1).first.map(String.init) ?? String(tail)
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { return trimmed }
    }
    return nil
  }

  static func buildInteractionDays(
    transcripts: [TranscriptChunk],
    embeddings: [FaceEmbeddingRecord],
    glassesInteractions: [GlassesDisplayInteractionEvent] = []
  ) -> [PersonInteractionDay] {
    let calendar = Calendar.current
    var data: [Date: [Date: (count: Int, chunks: [TranscriptChunk], glasses: [GlassesDisplayInteractionEvent])]] = [:]

    for emb in embeddings {
      let ts = emb.sourceFrameTimestamp
      let day = calendar.startOfDay(for: ts)
      let comps = calendar.dateComponents([.year, .month, .day, .hour], from: ts)
      let hour = calendar.date(from: comps) ?? day
      if data[day] == nil { data[day] = [:] }
      if data[day]![hour] == nil { data[day]![hour] = (0, [], []) }
      data[day]![hour]!.count += 1
    }

    for chunk in transcripts where chunk.isFinal && !chunk.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let ts = chunk.createdAt
      let day = calendar.startOfDay(for: ts)
      let comps = calendar.dateComponents([.year, .month, .day, .hour], from: ts)
      let hour = calendar.date(from: comps) ?? day
      if data[day] == nil { data[day] = [:] }
      if data[day]![hour] == nil { data[day]![hour] = (0, [], []) }
      data[day]![hour]!.chunks.append(chunk)
    }

    for event in glassesInteractions {
      let ts = event.createdAt
      let day = calendar.startOfDay(for: ts)
      let comps = calendar.dateComponents([.year, .month, .day, .hour], from: ts)
      let hour = calendar.date(from: comps) ?? day
      if data[day] == nil { data[day] = [:] }
      if data[day]![hour] == nil { data[day]![hour] = (0, [], []) }
      data[day]![hour]!.glasses.append(event)
    }

    return data.map { day, hourMap in
      let hours = hourMap.map { hour, d in
        PersonInteractionHour(
          hour: hour,
          faceDetectionCount: d.count,
          transcripts: d.chunks.sorted { $0.createdAt < $1.createdAt },
          glassesInteractions: d.glasses.sorted { $0.createdAt < $1.createdAt }
        )
      }.sorted { $0.hour < $1.hour }
      return PersonInteractionDay(day: day, hours: hours)
    }.sorted { $0.day > $1.day }
  }

  func currentActiveState() -> ActiveIdentityState {
    activeState
  }

  // Saves a transcript chunk produced by the cloud diarization pipeline.
  func saveCloudTranscriptChunk(_ chunk: TranscriptChunk) async {
    try? await store.saveTranscriptChunk(chunk, context: currentContext())
  }

  // Returns the personId for an existing person with this name, or creates a voice-only profile.
  // Returns nil only when the name is empty/blank or the store write fails.
  func findOrCreatePerson(name: String) async -> UUID? {
    await findOrCreateVoiceOnlyPerson(named: name)?.id
  }

  // Re-assigns all transcript chunks whose source tag matches to a resolved personId.
  // `sessionId` is required because the diarization result may arrive after the live
  // conversation has ended (activeConversation == nil), and we need to scope the rewrite
  // to the originating session.
  func reattributeChunks(matchingSource sourceTag: String, sessionId: UUID, toPersonId personId: UUID) async {
    let ctx = currentContext()
    var chunks = (try? await store.transcriptChunksForConversationSessions([sessionId])) ?? []
    var updatedCount = 0
    for i in chunks.indices where chunks[i].source.contains(sourceTag) {
      chunks[i].personId = personId
      chunks[i].activeIdentityState = "confirmed"
      chunks[i].source = chunks[i].source.replacingOccurrences(of: "unknown:", with: "enrolled:")
      try? await store.saveTranscriptChunk(chunks[i], context: ctx)
      updatedCount += 1
    }
    await reconcileSceneContextsForConversation(sessionId: sessionId)
    AppLogger.log(.transcript, "[CloudDiarization] reattributeChunks tag=\(sourceTag) personId=\(personId.uuidString) updatedChunks=\(updatedCount)")
  }

  func currentConversationTranscriptChunks() async -> [TranscriptChunk] {
    guard let sessionId = activeConversation?.id else { return [] }
    return (try? await store.transcriptChunksForConversationSessions([sessionId])) ?? []
  }

  func currentConversationSceneContexts() async -> [SceneContextRecord] {
    guard let sessionId = activeConversation?.id else { return [] }
    return (try? await store.sceneContextsForConversationSessions([sessionId])) ?? []
  }

  @discardableResult
  func updateCurrentConversationTranscriptAttributions(_ attributionsByChunkId: [UUID: TranscriptAttribution]) async -> RunSessionSnapshot {
    guard let context = currentContext(), let sessionId = activeConversation?.id else {
      return await currentRunSessionSnapshot()
    }
    let chunks = (try? await store.transcriptChunksForConversationSessions([sessionId])) ?? []
    var updatedCount = 0
    for var chunk in chunks {
      guard let attribution = attributionsByChunkId[chunk.id] else { continue }
      chunk.personId = attribution.personId
      chunk.activeIdentityState = attribution.state
      let speechSource = chunk.source.hasPrefix("AWSTranscribe") ? "AWSTranscribe" : "AppleSpeech"
      chunk.source = "\(speechSource)+\(attribution.sourceEvidence)"
      try? await store.saveTranscriptChunk(chunk, context: context)
      updatedCount += 1
    }
    await reconcileSceneContextsForConversation(sessionId: sessionId)
    AppLogger.log(.transcript, "\(context.logPrefix) postSessionAttribution updatedChunks=\(updatedCount)")
    return await currentRunSessionSnapshot()
  }

  @discardableResult
  func labelSpeakerInConversation(
    sessionId: UUID,
    speakerLabel: String,
    personId: UUID,
    displayName: String
  ) async -> RunSessionSnapshot {
    let context = currentContext()
    let chunks = (try? await store.transcriptChunksForConversationSessions([sessionId])) ?? []
    let marker = "speakerLabel=\(speakerLabel)"
    var updatedCount = 0
    for var chunk in chunks {
      guard chunk.source.contains(marker) || chunk.source.contains("speaker=\(speakerLabel)") else { continue }
      chunk.personId = personId
      chunk.activeIdentityState = "manualSpeakerLabel"
      if !chunk.source.contains("manualSpeakerName=") {
        chunk.source += ";manualSpeakerName=\(displayName.replacingOccurrences(of: ";", with: ","))"
      }
      try? await store.saveTranscriptChunk(chunk, context: context)
      updatedCount += 1
    }
    await reconcileSceneContextsForConversation(sessionId: sessionId)
    AppLogger.log(.transcript, "\(context.logPrefix) manualSpeakerLabel speakerLabel=\(speakerLabel) displayName=\"\(displayName)\" personId=\(personId.uuidString) updatedChunks=\(updatedCount)")
    if let snapshot = try? await store.runSessionSnapshot(appRunId: context?.appRunId, conversationSessionId: sessionId) {
      return snapshot
    }
    return await currentRunSessionSnapshot()
  }

  func recordCalibrationLabel(_ label: FaceCalibrationMode, source: CalibrationLabelSource) -> IdentityProcessingResult {
    let context = currentContext()
    guard source == .userTap else {
      logCalibrationLabelSkip(label: label, reason: "sourceNotUserTap", context: context)
      calibrationStatusText = "Calibration label skipped: source was not a user tap."
      return result(summary: calibrationStatusText)
    }
    guard !(embeddingModel is MissingFaceEmbeddingModel) else {
      logCalibrationLabelSkip(label: label, reason: "modelMissing", context: context)
      calibrationStatusText = "Calibration skipped: AWS AdaFace is not configured."
      return result(summary: calibrationStatusText)
    }
    guard let observation = lastCalibrationObservation else {
      logCalibrationLabelSkip(label: label, reason: "noCurrentLiveEmbedding", context: context)
      calibrationStatusText = "Calibration skipped: no current live embedding."
      return result(summary: calibrationStatusText)
    }
    guard let profile = observation.profile else {
      logCalibrationLabelSkip(label: label, reason: "noSelectedProfile", context: context)
      calibrationStatusText = "Calibration skipped: no selected or matched saved profile."
      return result(summary: calibrationStatusText)
    }
    guard observation.candidate.quality.acceptedForRecognition else {
      logCalibrationLabelSkip(label: label, reason: "recognitionQualityRejected", context: context)
      calibrationStatusText = "Calibration skipped: current face is not recognition quality."
      return result(summary: calibrationStatusText)
    }
    guard observation.match.bestSimilarity.isFinite else {
      logCalibrationLabelSkip(label: label, reason: "noMatchScore", context: context)
      calibrationStatusText = "Calibration skipped: no match score."
      return result(summary: calibrationStatusText)
    }

    let sample = FaceCalibrationSample(
      mode: label,
      source: source,
      profileLabel: profile.displayName,
      score: observation.match.bestSimilarity,
      secondBestScore: observation.match.secondBestSimilarity,
      margin: observation.match.margin,
      threshold: IdentityConfig.strongMatchThreshold,
      decision: observation.state.state == .confirmed ? "confirmed" : observation.match.decision.rawValue,
      rawFaceWidth: observation.candidate.quality.rawFaceWidth,
      rawFaceHeight: observation.candidate.quality.rawFaceHeight,
      cropWidth: observation.candidate.quality.cropWidth,
      cropHeight: observation.candidate.quality.cropHeight,
      quality: observation.candidate.quality.score,
      brightness: observation.candidate.quality.brightness,
      blur: observation.candidate.quality.sharpness,
      acceptedForRecognition: observation.candidate.quality.acceptedForRecognition,
      acceptedForEnrollment: observation.candidate.quality.acceptedForEnrollment,
      rejectionReason: observation.candidate.quality.rejectionReasons.joined(separator: ","),
      createdAt: Date()
    )
    calibrationSamples.append(sample)
    calibrationSamples = Array(calibrationSamples.suffix(500))
    calibrationStatusText = "Saved \(label.displayText) calibration label."
    logCalibrationSample(sample, context: context, frame: observation.frameSequence)
    AppLogger.log(
      .calibrationLabel,
      "\(context.logPrefix) source=\(source.rawValue) label=\(label == .samePerson ? "same" : "different") profile=\(profile.displayName) score=\(String(format: "%.3f", observation.match.bestSimilarity)) margin=\(observation.match.margin.map { String(format: "%.3f", $0) } ?? "nil") frame=\(observation.frameSequence)"
    )
    let summary = calibrationSummary()
    AppLogger.log(.faceCalibrationSummary, "\(context.logPrefix) \(summary.logText)")
    return result(summary: calibrationStatusText)
  }

  func stopCalibration() -> IdentityProcessingResult {
    lastCalibrationObservation = nil
    calibrationStatusText = "Calibration context cleared."
    let summary = calibrationSummary()
    AppLogger.log(.faceCalibrationSummary, "\(currentContext().logPrefix) mode=off action=stop \(summary.logText)")
    return result(summary: "Calibration stopped")
  }

  func clearCalibrationSamples() -> IdentityProcessingResult {
    calibrationSamples = []
    lastCalibrationObservation = nil
    calibrationStatusText = "Calibration samples cleared."
    AppLogger.log(.faceCalibrationSummary, "\(currentContext().logPrefix) action=clear \(calibrationSummary().logText)")
    return result(summary: "Calibration samples cleared")
  }

  func requestDebugEmbeddingOnNextFace() -> IdentityProcessingResult {
    forceDebugEmbeddingOnNextFace = IdentityConfig.allowLowQualityEmbeddingDebug
    AppLogger.log(.faceEmbeddingDebug, "requested=\(forceDebugEmbeddingOnNextFace) allowLowQualityEmbeddingDebug=\(IdentityConfig.allowLowQualityEmbeddingDebug)")
    return result(summary: forceDebugEmbeddingOnNextFace ? "Debug embedding will run on next detected crop" : "Debug embedding is disabled in this build")
  }

  func process(frame: ProcessedVideoFrame) async -> IdentityProcessingResult? {
    _ = await startAppRunIfNeeded()
    let context = frame.pipelineContext ?? currentContext()
    let now = Date()

    // Fast path: identity is confirmed and a face is still in frame.
    // Skip embedding for holdIdentitySeconds after the last full pipeline run. Once
    // that window elapses we fall through and re-embed so a new (unrecognized) face
    // causes the confirmed state to lapse rather than being held indefinitely.
    let lastRunAge = lastProcessedAt.map { now.timeIntervalSince($0) } ?? .infinity
    if activeState.state == .confirmed,
       !frame.identityCandidates.isEmpty,
       lastRunAge < IdentityConfig.holdIdentitySeconds {
      confirmor.noteConfirmedFaceVisible(at: now)
      activeState = confirmor.currentState
      let sortedForPreview = frame.identityCandidates.sorted {
        $0.crop.faceBoundingBoxPixels.width * $0.crop.faceBoundingBoxPixels.height >
        $1.crop.faceBoundingBoxPixels.width * $1.crop.faceBoundingBoxPixels.height
      }
      if let best = sortedForPreview.first {
        updateRetainedFaceCandidatesIfNeeded(best, context: context, embeddingStatus: embeddingModelStatusText())
      }
      AppLogger.log(.identityMatch, "\(context.logPrefix) frame=\(frame.sequence) confirmedHold=true person=\(activeState.displayName ?? "nil") faceVisible=true skipEmbedding=true")
      return result(
        summary: "Confirmed: \(activeState.displayName ?? "unknown") (held)",
        faceCandidateCount: frame.identityCandidates.count,
        qualityPassCount: frame.identityCandidates.filter(\.quality.accepted).count
      )
    }

    guard shouldProcessIdentityFrame(at: now) else { return nil }
    guard !isProcessing else { return nil }
    isProcessing = true
    defer {
      isProcessing = false
      lastProcessedAt = Date()
    }

    cachedProfiles = (try? await store.loadPeople()) ?? []
    let sortedCandidates = frame.identityCandidates
      .sorted { lhs, rhs in
        let lhsArea = lhs.crop.faceBoundingBoxPixels.width * lhs.crop.faceBoundingBoxPixels.height
        let rhsArea = rhs.crop.faceBoundingBoxPixels.width * rhs.crop.faceBoundingBoxPixels.height
        return lhsArea > rhsArea
      }
    if let bestDetected = sortedCandidates.first {
      updateRetainedFaceCandidatesIfNeeded(bestDetected, context: context, embeddingStatus: embeddingModelStatusText())
    }
    let accepted = sortedCandidates.filter(\.quality.accepted)
    let debugEmbeddingRequested = forceDebugEmbeddingOnNextFace
    let debugCandidate = debugEmbeddingRequested ? sortedCandidates.first(where: isEligibleForDebugEmbedding) : nil

    statsFaces += frame.identityCandidates.count
    statsQualityPass += accepted.count
    AppLogger.log(.pipelineStats, "\(context.logPrefix) frame=\(frame.sequence) faces=\(frame.identityCandidates.count) qualityPass=\(accepted.count)")

    guard let primary = accepted.first ?? debugCandidate else {
      if !enrollmentWaitingForNextSample {
        pendingUnknownRejectedSamples += max(frame.identityCandidates.count, 1)
      }
      AppLogger.log(.faceEmbeddingSkip, "\(context.logPrefix) frame=\(frame.sequence) face=none reason=\(frame.identityCandidates.isEmpty ? "noFaceDetected" : "qualityRejected")")
      if enrollmentWaitingForNextSample {
        logEnrollmentSampleRejected(frame: frame.sequence, candidate: sortedCandidates.first, reason: frame.identityCandidates.isEmpty ? "noFaceDetected" : "qualityRejected", context: context)
      }
      lastCalibrationObservation = nil
      let state = confirmor.update(
        match: IdentityMatchResult(bestPersonId: nil, bestSimilarity: 0, secondBestSimilarity: nil, margin: nil, decision: .unknown, matchedEmbeddingId: nil),
        profile: nil,
        sawGoodUnknownFace: false,
        now: now
      )
      activeState = state
      logRolling(
        frame: frame.sequence,
        match: nil,
        state: state,
        inputDecisionOverride: frame.identityCandidates.isEmpty ? "noFaceDetected" : "faceDetectedButQualityRejected",
        reasonOverride: frame.identityCandidates.isEmpty ? "noFace" : "qualityRejected"
      )
      emitStatsIfNeeded(context: context)
      return result(summary: "No accepted face crop", faceCandidateCount: frame.identityCandidates.count, qualityPassCount: accepted.count, alignmentRejectedCount: frame.alignmentFailures)
    }
    if debugEmbeddingRequested {
      AppLogger.log(.faceEmbeddingDebug, "\(context.logPrefix) requested=true frame=\(frame.sequence) qualityAccepted=\(primary.quality.acceptedForRecognition)")
      forceDebugEmbeddingOnNextFace = false
    }

    guard IdentityConfig.enableFaceEmbeddings else {
      lastCalibrationObservation = nil
      pendingUnknownPreview = primary.crop.previewImage
      let state = confirmor.update(
        match: IdentityMatchResult(bestPersonId: nil, bestSimilarity: 0, secondBestSimilarity: nil, margin: nil, decision: .unknown, matchedEmbeddingId: nil),
        profile: nil,
        sawGoodUnknownFace: true,
        now: now
      )
      activeState = state
      AppLogger.log(.faceEmbeddingSkip, "\(context.logPrefix) frame=\(frame.sequence) face=0 reason=embeddingDisabled debugRequested=\(debugEmbeddingRequested)")
      AppLogger.log(
        .enrollment,
        "\(context.logPrefix) unknownFaceAvailable=true quality=\(primary.quality.score.map { String(format: "%.2f", $0) } ?? "nil") cropPath=none"
      )
      logRolling(
        frame: frame.sequence,
        match: nil,
        state: state,
        inputDecisionOverride: "faceDetectedButEmbeddingDisabled",
        reasonOverride: "embeddingDisabled"
      )
      autoCaptureFaceSample(candidate: primary, embedding: nil, context: context, embeddingStatus: "embeddingDisabled")
      emitStatsIfNeeded(context: context)
      return result(
        summary: "High-quality unknown face; embeddings disabled",
        faceCandidateCount: frame.identityCandidates.count,
        qualityPassCount: accepted.count
      )
    }

    let embeddingSources = enrollmentEmbeddingSources()
    let embeddingStartedAt = Date()
    var embeddingOutputs: [(source: FaceEnrollmentEmbeddingSource, embedding: FaceEmbedding, latencyMS: Double)] = []
    var embeddingFailures: [String] = []
    for source in embeddingSources {
      let sourceStartedAt = Date()
      do {
        let sourceEmbedding = try await source.model.embed(faceImage: primary.crop.alignedCroppedImage)
        let sourceLatencyMS = Date().timeIntervalSince(sourceStartedAt) * 1_000
        embeddingOutputs.append((source: source, embedding: sourceEmbedding, latencyMS: sourceLatencyMS))
        statsEmbedded += 1
        statsEmbedLatencyMS += sourceLatencyMS
        AppLogger.log(
          .faceEmbedding,
          "\(context.logPrefix) frame=\(frame.sequence) face=0 source=\(source.label) model=\(sourceEmbedding.modelName) dim=\(sourceEmbedding.dimension) status=success elapsedMs=\(String(format: "%.1f", sourceLatencyMS)) normalized=true"
        )
      } catch {
        embeddingFailures.append("\(source.label):\(error.localizedDescription)")
        AppLogger.log(.faceEmbedding, "\(context.logPrefix) frame=\(frame.sequence) face=0 source=\(source.label) model=\(source.model.modelName) modelVersion=\(source.model.modelVersion) dim=0 status=failure elapsedMs=0.0 error=\(error.localizedDescription)")
      }
    }
    guard let firstEmbeddingOutput = embeddingOutputs.first else {
      let isMissingModel = embeddingSources.isEmpty || embeddingModel is MissingFaceEmbeddingModel
      pendingUnknownPreview = primary.crop.previewImage
      if primary.quality.acceptedForEnrollment {
        AppLogger.log(.enrollment, "\(context.logPrefix) unknownFaceAvailable=true quality=\(primary.quality.score.map { String(format: "%.2f", $0) } ?? "nil") cropPath=none action=blocked reason=modelMissing")
      }
      let state = confirmor.update(
        match: IdentityMatchResult(bestPersonId: nil, bestSimilarity: 0, secondBestSimilarity: nil, margin: nil, decision: .unknown, matchedEmbeddingId: nil),
        profile: nil,
        sawGoodUnknownFace: primary.quality.acceptedForEnrollment,
        now: now
      )
      activeState = state
      AppLogger.log(.faceEmbeddingSkip, "\(context.logPrefix) frame=\(frame.sequence) face=0 reason=\(isMissingModel ? "modelMissing" : "embeddingFailed") debugRequested=\(debugEmbeddingRequested)")
      autoCaptureFaceSample(candidate: primary, embedding: nil, context: context, embeddingStatus: isMissingModel ? "modelMissing" : "embeddingFailed")
      if debugEmbeddingRequested {
        AppLogger.log(.faceEmbeddingDebug, "\(context.logPrefix) requested=true frame=\(frame.sequence) status=failure reason=\(isMissingModel ? "modelMissing" : "embeddingFailed")")
      }
      lastCalibrationObservation = nil
      await saveMatchEvent(
        frame: frame,
        candidate: primary,
        match: nil,
        decision: isMissingModel ? "embeddingModelMissing" : "embeddingFailed",
        rollingState: state,
        context: context,
        modelName: embeddingModel.modelName,
        modelVersion: embeddingModel.modelVersion
      )
      logRolling(
        frame: frame.sequence,
        match: nil,
        state: state,
        inputDecisionOverride: isMissingModel ? "faceDetectedButModelMissing" : "faceDetectedButEmbeddingFailed",
        reasonOverride: isMissingModel ? "modelMissing" : "embeddingFailed"
      )
      return result(
        summary: isMissingModel ? "Face recognition model missing. Detection-only mode." : "Embedding failed: \(embeddingFailures.joined(separator: "; "))",
        faceCandidateCount: frame.identityCandidates.count,
        qualityPassCount: accepted.count,
        matchDecisionText: isMissingModel ? "modelMissing" : "embeddingFailed"
      )
    }
    let embedLatencyMS = Date().timeIntervalSince(embeddingStartedAt) * 1_000
    var embedding = firstEmbeddingOutput.embedding
    if debugEmbeddingRequested {
      AppLogger.log(.faceEmbeddingDebug, "\(context.logPrefix) requested=true frame=\(frame.sequence) status=success embeddings=\(embeddingOutputs.map { "\($0.source.label):\($0.embedding.dimension)" }.joined(separator: ","))")
    }
    if !IdentityConfig.enableIdentityMatching {
      let embeddingMetrics = embeddingOutputs.map { output in
        FaceEmbeddingDebugMetric(
          sourceLabel: output.source.label,
          modelName: output.embedding.modelName,
          modelSource: output.embedding.modelSource,
          dimension: output.embedding.dimension,
          latencyMS: output.latencyMS,
          bestSimilarity: 0,
          decisionText: "disabled",
          compatibleSampleCount: 0,
          compatibleAverageCount: 0,
          selectedForRecognition: output.source.label == firstEmbeddingOutput.source.label
        )
      }
      pendingUnknownPreview = primary.crop.previewImage
      let liveEmbeddingRecords = makeEmbeddingRecords(
        personId: nil,
        embeddings: embeddingOutputs.map(\.embedding),
        crop: primary.crop,
        quality: primary.quality,
        context: context
      )
      var placeholders = liveEmbeddingRecords
      let sharedPath = placeholders.first.flatMap {
        try? saveCropImage(UIImage(cgImage: primary.crop.alignedCroppedImage), frameSequence: primary.crop.frameSequence, recordId: $0.id)
      }
      if let sharedPath {
        for index in placeholders.indices {
          placeholders[index].sampleImageLocalPath = sharedPath
        }
      }
      if primary.quality.acceptedForEnrollment {
        pendingUnknownEmbeddings.append(contentsOf: placeholders)
        pendingUnknownEmbeddings = Self.trimPendingEnrollmentRecords(pendingUnknownEmbeddings, maxPhysicalSamples: 8)
        if enrollmentWaitingForNextSample {
          enrollmentWaitingForNextSample = false
          let sampleCount = Self.enrollmentPhysicalSampleCount(in: pendingUnknownEmbeddings)
          enrollmentStatusText = "Sample \(sampleCount) captured."
          AppLogger.log(.enrollmentSampleCaptured, "\(context.logPrefix) personDraft=pending sampleIndex=\(sampleCount) vectorCount=\(pendingUnknownEmbeddings.count) frame=\(frame.sequence) cropSize=\(primary.quality.cropWidth)x\(primary.quality.cropHeight) quality=\(primary.quality.score.map { String(format: "%.3f", $0) } ?? "nil")")
        }
      } else {
        if enrollmentWaitingForNextSample {
          logEnrollmentSampleRejected(frame: frame.sequence, candidate: primary, reason: primary.quality.rejectReason ?? "notAcceptedForEnrollment", context: context)
        } else {
          pendingUnknownRejectedSamples += 1
        }
      }
      let state = confirmor.update(
        match: IdentityMatchResult(bestPersonId: nil, bestSimilarity: 0, secondBestSimilarity: nil, margin: nil, decision: .unknown, matchedEmbeddingId: nil),
        profile: nil,
        sawGoodUnknownFace: true,
        now: now
      )
      activeState = state
      AppLogger.log(.identityMatch, "\(context.logPrefix) frame=\(frame.sequence) face=0 bestPerson=nil similarity=0.000 threshold=\(String(format: "%.2f", IdentityConfig.weakMatchThreshold)) accepted=false reason=matchingDisabled")
      logRolling(frame: frame.sequence, match: nil, state: state)
      emitStatsIfNeeded(context: context)
      return result(
        summary: "Embedding ready; matching disabled",
        faceCandidateCount: frame.identityCandidates.count,
        qualityPassCount: accepted.count,
        embeddingGenerated: true,
        matchDecisionText: "disabled",
        embeddingLatencyMS: embedLatencyMS,
        embeddingMetrics: embeddingMetrics
      )
    }
    let allStoredSamples = (try? await store.allEmbeddings()) ?? []
    let averages = (try? await store.averagedEmbeddings()) ?? []
    func decisionRank(_ decision: IdentityMatchResult.Decision) -> Int {
      switch decision {
      case .known: return 3
      case .ambiguous: return 2
      case .unknown: return 1
      }
    }
    let matchEvaluations = embeddingOutputs.map { output in
      let outputEmbedding = output.embedding
      let outputCompatibleSamples = allStoredSamples.filter {
        $0.personId != nil
          && $0.dimension == outputEmbedding.dimension
          && $0.vector.count == outputEmbedding.dimension
          && $0.modelName == outputEmbedding.modelName
          && $0.modelVersion == outputEmbedding.modelVersion
          && $0.modelSource == outputEmbedding.modelSource
          && $0.preprocessingVersion == outputEmbedding.preprocessingVersion
      }
      let outputCompatibleAverages = averages.filter {
        $0.vectorDimension == outputEmbedding.dimension
          && $0.averagedVector.count == outputEmbedding.dimension
          && $0.modelName == outputEmbedding.modelName
          && $0.modelVersion == outputEmbedding.modelVersion
          && $0.modelSource == outputEmbedding.modelSource
          && $0.preprocessingVersion == outputEmbedding.preprocessingVersion
      }
      let outputSampleMatch = matcher.match(vector: outputEmbedding.vector, against: outputCompatibleSamples)
      let outputCentroidMatch = matcher.match(embedding: outputEmbedding, against: outputCompatibleAverages)
      let outputMatch = outputSampleMatch.bestSimilarity >= outputCentroidMatch.bestSimilarity ? outputSampleMatch : outputCentroidMatch
      return (
        output: output,
        compatibleSamples: outputCompatibleSamples,
        compatibleAverages: outputCompatibleAverages,
        sampleMatch: outputSampleMatch,
        centroidMatch: outputCentroidMatch,
        match: outputMatch
      )
    }
    let selectedMatch = matchEvaluations.max {
      let lhsRank = decisionRank($0.match.decision)
      let rhsRank = decisionRank($1.match.decision)
      if lhsRank != rhsRank { return lhsRank < rhsRank }
      return $0.match.bestSimilarity < $1.match.bestSimilarity
    }!
    let selectedSourceLabel = selectedMatch.output.source.label
    for evaluation in matchEvaluations {
      let outputEmbedding = evaluation.output.embedding
      let compatibleProfileIds = Set(evaluation.compatibleSamples.compactMap(\.personId))
        .union(Set(evaluation.compatibleAverages.map(\.personId)))
      let profile = cachedProfiles.first { $0.id == evaluation.match.bestPersonId }
      AppLogger.log(
        .faceMatch,
        "\(context.logPrefix) frame=\(frame.sequence) face=0 [SOURCE_COMPARISON] selected=\(evaluation.output.source.label == selectedSourceLabel) sourceLabel=\(evaluation.output.source.label) embeddingDim=\(outputEmbedding.dimension) model=\(outputEmbedding.modelName) modelVersion=\(outputEmbedding.modelVersion) source=\(outputEmbedding.modelSource) preprocessing=\(outputEmbedding.preprocessingVersion) compatibleProfiles=\(compatibleProfileIds.count) compatibleSamples=\(evaluation.compatibleSamples.count) compatibleAverages=\(evaluation.compatibleAverages.count) top1=\(profile?.displayName ?? evaluation.match.bestPersonId?.uuidString ?? "nil") score=\(String(format: "%.3f", evaluation.match.bestSimilarity)) top2=\(evaluation.match.secondBestSimilarity.map { String(format: "%.3f", $0) } ?? "nil") margin=\(evaluation.match.margin.map { String(format: "%.3f", $0) } ?? "nil") threshold=\(String(format: "%.2f", IdentityConfig.strongMatchThreshold)) decision=\(evaluation.match.decision.rawValue) reason=\(matchRejectionReason(evaluation.match)) latencyMs=\(String(format: "%.1f", evaluation.output.latencyMS))"
      )
    }
    let embeddingMetrics = matchEvaluations.map { evaluation in
      FaceEmbeddingDebugMetric(
        sourceLabel: evaluation.output.source.label,
        modelName: evaluation.output.embedding.modelName,
        modelSource: evaluation.output.embedding.modelSource,
        dimension: evaluation.output.embedding.dimension,
        latencyMS: evaluation.output.latencyMS,
        bestSimilarity: evaluation.match.bestSimilarity,
        decisionText: evaluation.match.decision.rawValue,
        compatibleSampleCount: evaluation.compatibleSamples.count,
        compatibleAverageCount: evaluation.compatibleAverages.count,
        selectedForRecognition: evaluation.output.source.label == selectedSourceLabel
      )
    }
    embedding = selectedMatch.output.embedding
    let compatibleSamples = selectedMatch.compatibleSamples
    let compatibleAverages = selectedMatch.compatibleAverages
    let sampleMatch = selectedMatch.sampleMatch
    let centroidMatch = selectedMatch.centroidMatch
    let match = selectedMatch.match
    let liveEmbeddingRecords = makeEmbeddingRecords(
      personId: nil,
      embeddings: embeddingOutputs.map(\.embedding),
      crop: primary.crop,
      quality: primary.quality,
      context: context
    )
    autoCaptureFaceSample(
      candidate: primary,
      embedding: embedding,
      embeddingRecords: liveEmbeddingRecords,
      context: context,
      embeddingStatus: "embedded"
    )
    for incompatible in allStoredSamples.filter({ $0.personId != nil && !compatibleSamples.contains($0) }).prefix(3) {
      AppLogger.log(
        .faceMatchSkip,
        "\(context.logPrefix) reason=incompatibleVector storedModel=\(incompatible.modelName) liveModel=\(embedding.modelName) storedModelVersion=\(incompatible.modelVersion) liveModelVersion=\(embedding.modelVersion) storedSource=\(incompatible.modelSource) liveSource=\(embedding.modelSource) storedPreprocessing=\(incompatible.preprocessingVersion) livePreprocessing=\(embedding.preprocessingVersion) storedDim=\(incompatible.dimension) liveDim=\(embedding.dimension)"
      )
    }
    if !averages.isEmpty, compatibleAverages.isEmpty {
      for stored in averages.prefix(3) {
        AppLogger.log(
          .faceMatchSkip,
          "\(context.logPrefix) reason=incompatibleVector storedModel=\(stored.modelName) liveModel=\(embedding.modelName) storedModelVersion=\(stored.modelVersion) liveModelVersion=\(embedding.modelVersion) storedSource=\(stored.modelSource) liveSource=\(embedding.modelSource) storedPreprocessing=\(stored.preprocessingVersion) livePreprocessing=\(embedding.preprocessingVersion) storedDim=\(stored.vectorDimension) liveDim=\(embedding.dimension)"
        )
      }
    }
    if match.decision == .known {
      statsMatched += 1
    }
    let profile = cachedProfiles.first { $0.id == match.bestPersonId }
    let state = confirmor.update(
      match: match,
      profile: profile,
      sawGoodUnknownFace: match.decision == .unknown,
      now: now
    )
    activeState = state
    await saveMatchEvent(
      frame: frame,
      candidate: primary,
      match: match,
      decision: state.state == .confirmed ? "confirmedMatch" : match.decision.eventDecision,
      rollingState: state,
      context: context,
      modelName: embedding.modelName,
      modelVersion: embedding.modelVersion
    )

    AppLogger.log(
      .identityMatch,
      "\(context.logPrefix) frame=\(frame.sequence) face=0 bestPerson=\(profile?.displayName ?? match.bestPersonId?.uuidString ?? "nil") similarity=\(String(format: "%.3f", match.bestSimilarity)) threshold=\(String(format: "%.2f", IdentityConfig.strongMatchThreshold)) accepted=\(match.decision == .known) secondBest=\(match.secondBestSimilarity.map { String(format: "%.3f", $0) } ?? "nil") margin=\(match.margin.map { String(format: "%.3f", $0) } ?? "nil")"
    )
    let compatibleProfileCount = Set(compatibleSamples.compactMap(\.personId)).count
    AppLogger.log(
      .faceMatch,
      "\(context.logPrefix) frame=\(frame.sequence) face=0 embeddingDim=\(embedding.dimension) model=\(embedding.modelName) source=\(embedding.modelSource) profiles=\(compatibleProfileCount) top1=\(profile?.displayName ?? match.bestPersonId?.uuidString ?? "nil") score=\(String(format: "%.3f", match.bestSimilarity)) top2=\(match.secondBestSimilarity.map { String(format: "%.3f", $0) } ?? "nil") margin=\(match.margin.map { String(format: "%.3f", $0) } ?? "nil") threshold=\(String(format: "%.2f", IdentityConfig.strongMatchThreshold)) decision=\(state.state == .confirmed ? "confirmed" : match.decision.rawValue) reason=\(matchRejectionReason(match))"
    )
    if let personId = match.bestPersonId {
      let sampleCount = compatibleSamples.filter { $0.personId == personId }.count
      AppLogger.log(
        .identityMatch,
        "\(context.logPrefix) [IDENTITY_PROFILE_MATCH] person=\(profile?.displayName ?? personId.uuidString) bestSample=\(match.matchedEmbeddingId?.uuidString ?? "nil") bestScore=\(String(format: "%.3f", sampleMatch.bestSimilarity)) centroidScore=\(String(format: "%.3f", centroidMatch.bestSimilarity)) sampleCount=\(sampleCount)"
      )
    }
    // Log per-person scores when multiple people are enrolled so it's clear every person was evaluated.
    if compatibleProfileCount > 1 {
      let perPersonScores = Dictionary(grouping: compatibleSamples, by: { $0.personId! })
        .mapValues { samples in samples.map { FaceMatcher.cosineSimilarity(embedding.vector, $0.vector) }.max() ?? 0 }
        .sorted { $0.value > $1.value }
        .map { personId, score -> String in
          let name = cachedProfiles.first { $0.id == personId }?.displayName ?? personId.uuidString.prefix(8).description
          return "\(name):\(String(format: "%.3f", score))"
        }
        .joined(separator: " ")
      AppLogger.log(
        .faceMatch,
        "\(context.logPrefix) frame=\(frame.sequence) [ALL_CANDIDATES] \(perPersonScores)"
      )
    }
    updateCalibrationObservation(
      frame: frame,
      candidate: primary,
      match: match,
      profile: profile,
      state: state,
      context: context
    )
    logRolling(frame: frame.sequence, match: match, state: state)
    let currentRecognitionFacePreview: UIImage? = {
      guard match.decision == .known,
            let matchedPersonId = match.bestPersonId,
            state.personId == matchedPersonId else { return nil }
      return Self.makeThumbnail(from: UIImage(cgImage: primary.crop.alignedCroppedImage), maxPixelSize: 160)
    }()

    if match.decision == .known, let personId = match.bestPersonId, primary.quality.acceptedForEnrollment {
      markCaptureGroupRecognized(frame: frame.sequence, personId: personId, personName: profile?.displayName)
      try? await saveEnrollmentSamples(
        personId: personId,
        embeddings: embeddingOutputs.map(\.embedding),
        crop: primary.crop,
        quality: primary.quality,
        context: context
      )
      if var profile {
        profile.lastSeenAt = now
        profile.updatedAt = now
        try? await store.updatePersonProfile(profile, context: context)
      }
    } else if match.decision == .unknown {
      pendingUnknownPreview = primary.crop.previewImage
      if primary.quality.acceptedForEnrollment {
        var placeholders = liveEmbeddingRecords
        let sharedPath = placeholders.first.flatMap {
          try? saveCropImage(UIImage(cgImage: primary.crop.alignedCroppedImage), frameSequence: primary.crop.frameSequence, recordId: $0.id)
        }
        if let sharedPath {
          for index in placeholders.indices {
            placeholders[index].sampleImageLocalPath = sharedPath
          }
        }
        pendingUnknownEmbeddings.append(contentsOf: placeholders)
        pendingUnknownEmbeddings = Self.trimPendingEnrollmentRecords(pendingUnknownEmbeddings, maxPhysicalSamples: 8)
        if enrollmentWaitingForNextSample {
          enrollmentWaitingForNextSample = false
          let sampleCount = Self.enrollmentPhysicalSampleCount(in: pendingUnknownEmbeddings)
          enrollmentStatusText = "Sample \(sampleCount) captured."
          AppLogger.log(.enrollmentSampleCaptured, "\(context.logPrefix) personDraft=pending sampleIndex=\(sampleCount) vectorCount=\(pendingUnknownEmbeddings.count) frame=\(frame.sequence) cropSize=\(primary.quality.cropWidth)x\(primary.quality.cropHeight) quality=\(primary.quality.score.map { String(format: "%.3f", $0) } ?? "nil")")
        }
      } else {
        if enrollmentWaitingForNextSample {
          logEnrollmentSampleRejected(frame: frame.sequence, candidate: primary, reason: primary.quality.rejectReason ?? "notAcceptedForEnrollment", context: context)
        } else {
          pendingUnknownRejectedSamples += 1
        }
      }
      if state.state == .unknown {
        AppLogger.log(.enrollment, "\(context.logPrefix) unknownCandidate=\(frame.sequence) quality=\(primary.quality.score.map { String(format: "%.3f", $0) } ?? "nil") tier=\(primary.quality.tier.rawValue) action=shown personId=none acceptedSamples=\(Self.enrollmentPhysicalSampleCount(in: pendingUnknownEmbeddings)) acceptedVectors=\(pendingUnknownEmbeddings.count) rejectedSamples=\(pendingUnknownRejectedSamples)")
      }
    }

    emitStatsIfNeeded(context: context)
    return result(
      summary: "Identity \(state.state.rawValue): \(state.displayName ?? "unknown")",
      faceCandidateCount: frame.identityCandidates.count,
      qualityPassCount: accepted.count,
      embeddingGenerated: true,
      matchDecisionText: match.decision.rawValue,
      currentRecognitionFacePreview: currentRecognitionFacePreview,
      embeddingLatencyMS: embedLatencyMS,
      embeddingMetrics: embeddingMetrics
    )
  }

  func savePendingUnknown(name: String) async throws -> IdentityProcessingResult {
    _ = await startAppRunIfNeeded()
    let context = currentContext()
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    var pendingSampleCount = Self.enrollmentPhysicalSampleCount(in: pendingUnknownEmbeddings)
    AppLogger.log(.enrollmentFinishRequest, "\(context.logPrefix) name=\(trimmed.isEmpty ? "none" : trimmed) sampleCount=\(pendingSampleCount) vectorCount=\(pendingUnknownEmbeddings.count)")
    enrollmentStatusText = "Creating profile vector..."
    guard !trimmed.isEmpty else {
      enrollmentStatusText = "Name is empty."
      return result(summary: "Name is empty")
    }
    let nameExists = cachedProfiles.contains {
      $0.displayName.lowercased() == trimmed.lowercased() && !$0.isUnknownPlaceholder
    }
    guard !nameExists else {
      enrollmentStatusText = "\"\(trimmed)\" is already in the dictionary."
      return result(summary: "Duplicate name: \(trimmed)")
    }
    guard pendingSampleCount >= IdentityConfig.minimumEnrollmentSamples else {
      AppLogger.log(.enrollment, "\(context.logPrefix) failed reason=notEnoughQualitySamples accepted=\(pendingSampleCount) vectors=\(pendingUnknownEmbeddings.count) required=\(IdentityConfig.minimumEnrollmentSamples)")
      enrollmentStatusText = "Need at least \(IdentityConfig.minimumEnrollmentSamples) good samples before finishing."
      return result(summary: "Need \(IdentityConfig.minimumEnrollmentSamples) quality samples before enrollment")
    }
    await backfillPendingEnrollmentVectors(context: context)
    pendingSampleCount = Self.enrollmentPhysicalSampleCount(in: pendingUnknownEmbeddings)
    let now = Date()
    let profile = PersonProfile(
      id: UUID(),
      displayName: trimmed,
      createdAt: now,
      updatedAt: now,
      notes: nil,
      isUnknownPlaceholder: false,
      lastSeenAt: now,
      enrollmentStatus: .enrolled,
      consentStatus: .consented,
      embeddingIds: pendingUnknownEmbeddings.map(\.id),
      primaryEmbeddingId: pendingUnknownEmbeddings.first?.id
    )
    do {
      try await store.savePersonProfile(profile, context: context)
    } catch {
      logEnrollmentWarning("savePendingUnknown savePersonProfileFailed personId=\(profile.id.uuidString) error=\(error.localizedDescription)", context: context)
      throw error
    }
    let savedImagePath = try? await saveLastEnrollmentCandidateImageToDisk(nameHint: trimmed)
    if let savedImagePath {
      AppLogger.log(.enrollmentImageSave, "\(context.logPrefix) status=success path=\(savedImagePath)")
    }
    let embeddingCount = pendingUnknownEmbeddings.count
    for record in pendingUnknownEmbeddings {
      var saved = record
      saved.personId = profile.id
      saved.appRunId = saved.appRunId ?? context?.appRunId
      saved.conversationSessionId = saved.conversationSessionId ?? context?.conversationSessionId
      saved.sampleImageLocalPath = saved.sampleImageLocalPath ?? savedImagePath
      do {
        try await store.saveEmbedding(saved, context: context)
      } catch {
        logEnrollmentWarning("savePendingUnknown saveEmbeddingFailed personId=\(profile.id.uuidString) sampleId=\(saved.id.uuidString) error=\(error.localizedDescription)", context: context)
        throw error
      }
    }
    pendingUnknownEmbeddings = []
    pendingUnknownRejectedSamples = 0
    pendingUnknownPreview = nil
    enrollmentWaitingForNextSample = false
    cachedProfiles = try await store.loadPeople()
    let averages = (try? await store.averagedEmbeddings()) ?? []
    if let centroid = averages.first(where: { $0.personId == profile.id }) {
      let norm = sqrt(centroid.averagedVector.reduce(Float(0)) { $0 + $1 * $1 })
      AppLogger.log(
        .enrollmentCentroid,
        "\(context.logPrefix) personId=\(profile.id.uuidString) sampleCount=\(centroid.sampleCount) dim=\(centroid.vectorDimension) normAfter=\(String(format: "%.3f", norm)) modelName=\(centroid.modelName) preprocessing=\(centroid.preprocessingVersion)"
      )
    }
    let embeddingsAfter = ((try? await store.allEmbeddings()) ?? []).count
    activeState = confirmor.setConfirmed(profile: profile)
    AppLogger.log(.enrollment, "\(context.logPrefix) unknownCandidate=pending quality=nil action=save personId=\(profile.id.uuidString)")
    AppLogger.log(.enrollment, "\(context.logPrefix) createdPerson id=\(profile.id.uuidString) displayName=\"\(profile.displayName)\" samples=\(pendingSampleCount) embeddings=\(embeddingCount) cropSaved=\(savedImagePath != nil)")
    AppLogger.log(.faceVectorStore, "\(context.logPrefix) savedProfile personId=\(profile.id.uuidString) sampleCount=\(pendingSampleCount) embeddingCount=\(embeddingCount)")
    AppLogger.log(.enrollmentFinished, "\(context.logPrefix) personId=\(profile.id.uuidString) name=\(profile.displayName) saved=true loadedProfilesAfter=\(cachedProfiles.count) loadedEmbeddingsAfter=\(embeddingsAfter)")
    enrollmentStatusText = "Enrollment finished for \(trimmed) with \(pendingSampleCount) samples and \(embeddingCount) vectors."
    return result(summary: "Saved \(trimmed)")
  }

  func armEnrollmentForNextSample(name: String) -> IdentityProcessingResult {
    let context = currentContext()
    enrollmentWaitingForNextSample = true
    let draft = name.trimmingCharacters(in: .whitespacesAndNewlines)
    enrollmentStatusText = "Waiting for another good face sample. Turn slightly or change expression."
    AppLogger.log(.enrollmentAddSampleArmed, "\(context.logPrefix) personDraft=\(draft.isEmpty ? "pending" : draft) currentSampleCount=\(Self.enrollmentPhysicalSampleCount(in: pendingUnknownEmbeddings)) currentVectorCount=\(pendingUnknownEmbeddings.count)")
    return result(summary: enrollmentStatusText)
  }

  func saveCurrentEnrollmentSample(name: String) async -> IdentityProcessingResult {
    _ = await startAppRunIfNeeded()
    let context = currentContext()
    let draft = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let candidate = lastEnrollmentCandidate
    let hasEmbeddingModel = !enrollmentEmbeddingSources().isEmpty
    AppLogger.log(.enrollmentSampleSaveRequest, "\(context.logPrefix) name=\(draft.isEmpty ? "pending" : draft) hasCrop=\(candidate != nil) modelLoaded=\(hasEmbeddingModel)")
    enrollmentStatusText = "Saving sample..."
    guard hasEmbeddingModel else {
      enrollmentStatusText = "AWS AdaFace is not configured. Start the AdaFace worker before enrolling a face."
      logEnrollmentWarning("saveCurrentEnrollmentSample failed reason=modelMissing", context: context)
      return result(summary: enrollmentStatusText)
    }
    guard let candidate else {
      enrollmentStatusText = "No enrollment-quality face crop available yet."
      AppLogger.log(.enrollmentSampleSaveFailed, "\(context.logPrefix) reason=noEnrollmentCandidate")
      return result(summary: enrollmentStatusText)
    }
    guard candidate.acceptedForEnrollment else {
      enrollmentStatusText = "Current face is not enrollment quality. Move closer and center the face."
      AppLogger.log(.enrollmentSampleSaveFailed, "\(context.logPrefix) reason=notEnrollmentQuality frame=\(candidate.frameSequence) cropSize=\(Int(candidate.cropSize.width))x\(Int(candidate.cropSize.height))")
      AppLogger.log(.enrollmentGuidance, "\(context.logPrefix) Move closer. Need raw face width at least \(Int(IdentityConfig.qualityConfig.minRawFacePixelsForEnrollment)) px, ideally 100 px.")
      return result(summary: enrollmentStatusText)
    }
    guard let cgImage = candidate.alignedCropImage.cgImage else {
      enrollmentStatusText = "Face image cannot be embedded."
      AppLogger.log(.enrollmentSampleSaveFailed, "\(context.logPrefix) reason=candidateMissingCGImage")
      return result(summary: enrollmentStatusText)
    }
    do {
      let records = try await makeEnrollmentEmbeddingRecords(
        faceImage: cgImage,
        cropImage: candidate.alignedCropImage,
        personId: nil,
        context: context,
        frameSequence: candidate.frameSequence,
        timestamp: candidate.timestamp,
        qualityScore: candidate.qualityScore,
        qualityTier: candidate.qualityTier,
        cropSize: candidate.cropSize,
        sourceImageSize: candidate.sourceImageSize
      )
      let existingKeys = Set(pendingUnknownEmbeddings
        .filter { Self.enrollmentPhysicalSampleKey(for: $0) == Self.enrollmentPhysicalSampleKey(for: records[0]) }
        .map { Self.enrollmentEmbeddingSpaceKey(for: $0) })
      let newRecords = records.filter { !existingKeys.contains(Self.enrollmentEmbeddingSpaceKey(for: $0)) }
      guard !newRecords.isEmpty else {
        enrollmentStatusText = "That frame is already saved. Use Add Another Sample for a new frame."
        AppLogger.log(.enrollmentSampleSaveFailed, "\(context.logPrefix) reason=duplicateFrame frame=\(candidate.frameSequence)")
        return result(summary: enrollmentStatusText)
      }
      pendingUnknownEmbeddings.append(contentsOf: newRecords)
      pendingUnknownEmbeddings = Self.trimPendingEnrollmentRecords(pendingUnknownEmbeddings, maxPhysicalSamples: 12)
      let sampleCount = Self.enrollmentPhysicalSampleCount(in: pendingUnknownEmbeddings)
      enrollmentStatusText = "Saved sample \(sampleCount) with \(newRecords.count) face vectors."
      AppLogger.log(.enrollmentCropSaved, "\(context.logPrefix) sampleIndex=\(sampleCount) path=\(newRecords.first?.sampleImageLocalPath ?? "failed")")
      AppLogger.log(.enrollmentSampleSaved, "\(context.logPrefix) personId=pending sampleIndex=\(sampleCount) vectorsAdded=\(newRecords.count) totalVectors=\(pendingUnknownEmbeddings.count) modelSpaces=\(newRecords.map { $0.modelName }.joined(separator: ","))")
      return result(summary: enrollmentStatusText)
    } catch {
      enrollmentStatusText = "Embedding failed: \(error.localizedDescription)"
      logEnrollmentWarning("saveCurrentEnrollmentSample failed reason=embeddingFailed error=\(error.localizedDescription)", context: context)
      return result(summary: enrollmentStatusText)
    }
  }

  func saveLastEnrollmentCandidateImageOnly(name: String?) async -> IdentityProcessingResult {
    _ = await startAppRunIfNeeded()
    let context = currentContext()
    guard let candidate = bestRetainedCandidate() else {
      AppLogger.log(.enrollmentImageSave, "\(context.logPrefix) status=failed reason=noLastCandidate")
      return result(summary: "No detected face image to save")
    }
    do {
      let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let path = try await saveLastEnrollmentCandidateImageToDisk(nameHint: trimmedName.isEmpty ? nil : trimmedName)
      if !trimmedName.isEmpty {
        let now = Date()
        let profile = PersonProfile(
          id: UUID(),
          displayName: trimmedName,
          createdAt: now,
          updatedAt: now,
          notes: "imageOnlyEnrollmentPath=\(path); recognitionReady=false; reason=embeddingModelMissingOrNotRun",
          isUnknownPlaceholder: false,
          lastSeenAt: now,
          enrollmentStatus: .pending,
          consentStatus: .consented
        )
        try await store.savePersonProfile(profile, context: context)
        cachedProfiles = (try? await store.loadPeople()) ?? cachedProfiles
        AppLogger.log(
          .enrollment,
          "\(context.logPrefix) name=\(trimmedName) status=imageOnly profileId=\(profile.id.uuidString) embeddingDim=0 totalEmbeddings=0 recognitionReady=false cropSaved=true"
        )
      }
      var updated = candidate
      updated.savedImagePath = path
      updateRetainedCandidate(updated)
      AppLogger.log(.enrollmentImageSave, "\(context.logPrefix) status=success kind=\(candidate.kind) path=\(path)")
      return result(summary: trimmedName.isEmpty ? "Saved face image only" : "Saved image-only profile for \(trimmedName)")
    } catch {
      AppLogger.log(.enrollmentImageSave, "\(context.logPrefix) warning...---- status=failed reason=\(error.localizedDescription)")
      return result(summary: "Face image save failed: \(error.localizedDescription)")
    }
  }

  func saveLastEnrollmentCandidateWithName(_ name: String) async -> IdentityProcessingResult {
    _ = await startAppRunIfNeeded()
    let context = currentContext()
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      return result(summary: "Name is empty")
    }
    guard let candidate = bestRetainedCandidate() else {
      AppLogger.log(.enrollment, "\(context.logPrefix) failed reason=noLastCandidate")
      return result(summary: "No detected face image to save")
    }
    guard !enrollmentEmbeddingSources().isEmpty else {
      return await saveLastEnrollmentCandidateImageOnly(name: trimmedName)
    }
    guard let cgImage = candidate.alignedCropImage.cgImage else {
      AppLogger.log(.enrollment, "\(context.logPrefix) failed reason=candidateMissingCGImage")
      return result(summary: "Face image cannot be embedded")
    }
    do {
      let embeddingStartedAt = Date()
      let now = Date()
      let profileId = UUID()
      let records = try await makeEnrollmentEmbeddingRecords(
        faceImage: cgImage,
        cropImage: candidate.alignedCropImage,
        personId: profileId,
        context: context,
        frameSequence: candidate.frameSequence,
        timestamp: candidate.timestamp,
        qualityScore: candidate.qualityScore,
        qualityTier: candidate.qualityTier,
        cropSize: candidate.cropSize,
        sourceImageSize: candidate.sourceImageSize
      )
      let profile = PersonProfile(
        id: profileId,
        displayName: trimmedName,
        createdAt: now,
        updatedAt: now,
        notes: records.first?.sampleImageLocalPath.map { "enrollmentImagePath=\($0)" },
        isUnknownPlaceholder: false,
        lastSeenAt: now,
        enrollmentStatus: .enrolled,
        consentStatus: .consented,
        embeddingIds: records.map(\.id),
        primaryEmbeddingId: records.first?.id
      )
      do {
        try await store.savePersonProfile(profile, context: context)
      } catch {
        logEnrollmentWarning("saveLastEnrollmentCandidate savePersonProfileFailed personId=\(profile.id.uuidString) error=\(error.localizedDescription)", context: context)
        throw error
      }
      for record in records {
        do {
          try await store.saveEmbedding(record, context: context)
        } catch {
          logEnrollmentWarning("saveLastEnrollmentCandidate saveEmbeddingFailed personId=\(profile.id.uuidString) sampleId=\(record.id.uuidString) error=\(error.localizedDescription)", context: context)
          throw error
        }
      }
      cachedProfiles = (try? await store.loadPeople()) ?? cachedProfiles
      activeState = confirmor.setConfirmed(profile: profile)
      let elapsedMS = Date().timeIntervalSince(embeddingStartedAt) * 1_000
      AppLogger.log(
        .enrollment,
        "\(context.logPrefix) name=\(trimmedName) status=success totalEmbeddings=\(records.count) recognitionReady=true elapsedMs=\(String(format: "%.1f", elapsedMS)) modelSpaces=\(records.map { $0.modelName }.joined(separator: ","))"
      )
      AppLogger.log(
        .faceVectorStore,
        "\(context.logPrefix) person=\(trimmedName) embeddingsAdded=\(records.count) totalValid=\(records.count) centroidUpdated=true"
      )
      return result(summary: "Saved \(trimmedName) with \(records.count) face embeddings")
    } catch {
      logEnrollmentWarning("saveLastEnrollmentCandidate failed reason=embeddingFailed error=\(error.localizedDescription)", context: context)
      return result(summary: "Embedding failed; use Save Image Only. \(error.localizedDescription)")
    }
  }

  func saveFirstCapturedFaceGroupAsNewPerson(name: String) async -> IdentityProcessingResult {
    _ = await startAppRunIfNeeded()
    let context = currentContext()
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else { return result(summary: "Name is empty") }
    guard let groupIndex = bestCapturedFaceGroupIndex() else {
      return result(summary: "No captured face group to save")
    }
    let group = captureGroups[groupIndex]
    let rankedSamples = group.samples
      .sorted { lhs, rhs in
        let lhsEnrollmentBoost = lhs.qualityTier == .usableForEnrollment || lhs.qualityTier == .preferredEnrollment ? Float(1) : Float(0)
        let rhsEnrollmentBoost = rhs.qualityTier == .usableForEnrollment || rhs.qualityTier == .preferredEnrollment ? Float(1) : Float(0)
        let lhsScore = (lhs.qualityScore ?? 0) + lhsEnrollmentBoost
        let rhsScore = (rhs.qualityScore ?? 0) + rhsEnrollmentBoost
        if lhsScore == rhsScore {
          return lhs.cropSize.width * lhs.cropSize.height > rhs.cropSize.width * rhs.cropSize.height
        }
        return lhsScore > rhsScore
      }
    let selectedSamples = Array(rankedSamples.prefix(3))
    guard selectedSamples.count >= 3 else {
      AppLogger.log(.enrollment, "\(context.logPrefix) capturedGroupSaveBlocked reason=needThreeSamples availableSamples=\(rankedSamples.count)")
      return result(summary: "Need 3 captured face pictures before saving \(trimmedName)")
    }
    let now = Date()
    let profileId = UUID()
    var recordsToSave: [FaceEmbeddingRecord] = []
    var embeddedPhysicalFrames = Set<UInt64>()
    for selected in selectedSamples {
      var retainedRecords = selected.embeddingRecords
      var retainedKeys = Set(retainedRecords.map { Self.enrollmentEmbeddingSpaceKey(for: $0) })
      var sharedImagePath = retainedRecords.compactMap(\.sampleImageLocalPath).first
      if !retainedRecords.isEmpty {
        if sharedImagePath == nil {
          sharedImagePath = try? saveCropImage(
            selected.cropImage,
            frameSequence: selected.frameSequence,
            recordId: retainedRecords.first?.id ?? UUID()
          )
        }
        for index in retainedRecords.indices {
          retainedRecords[index].personId = profileId
          retainedRecords[index].appRunId = retainedRecords[index].appRunId ?? context?.appRunId
          retainedRecords[index].conversationSessionId = retainedRecords[index].conversationSessionId ?? context?.conversationSessionId
          retainedRecords[index].sampleImageLocalPath = retainedRecords[index].sampleImageLocalPath ?? sharedImagePath
        }
        recordsToSave.append(contentsOf: retainedRecords)
        embeddedPhysicalFrames.insert(selected.frameSequence)
      }
      guard let cgImage = selected.cropImage.cgImage else {
        logEnrollmentWarning("capturedGroup sampleMissingCGImage frame=\(selected.frameSequence)", context: context)
        continue
      }
      do {
        let records = try await makeEnrollmentEmbeddingRecords(
          faceImage: cgImage,
          cropImage: selected.cropImage,
          personId: profileId,
          context: context,
          frameSequence: selected.frameSequence,
          timestamp: selected.timestamp,
          qualityScore: selected.qualityScore,
          qualityTier: selected.qualityTier,
          cropSize: selected.cropSize,
          sourceImageSize: selected.sourceImageSize,
          existingImagePath: sharedImagePath
        )
        let missingRecords = records.filter { !retainedKeys.contains(Self.enrollmentEmbeddingSpaceKey(for: $0)) }
        retainedKeys.formUnion(missingRecords.map { Self.enrollmentEmbeddingSpaceKey(for: $0) })
        recordsToSave.append(contentsOf: missingRecords)
        if !missingRecords.isEmpty {
          embeddedPhysicalFrames.insert(selected.frameSequence)
        }
      } catch {
        if retainedRecords.isEmpty {
          logEnrollmentWarning("capturedGroup embeddingFailed frame=\(selected.frameSequence) error=\(error.localizedDescription)", context: context)
        } else {
          logEnrollmentWarning("capturedGroup backfillEmbeddingFailed frame=\(selected.frameSequence) retainedVectors=\(retainedRecords.count) error=\(error.localizedDescription)", context: context)
        }
      }
    }
    guard embeddedPhysicalFrames.count >= IdentityConfig.minimumEnrollmentSamples else {
      logEnrollmentWarning("capturedGroupSaveBlocked reason=notEnoughEmbeddedPhysicalSamples embedded=\(embeddedPhysicalFrames.count) required=\(IdentityConfig.minimumEnrollmentSamples)", context: context)
      return result(summary: "Need \(IdentityConfig.minimumEnrollmentSamples) embedded face pictures before saving \(trimmedName)")
    }
    let profile = PersonProfile(
      id: profileId,
      displayName: trimmedName,
      createdAt: now,
      updatedAt: now,
      notes: "source=capturedFaceGroup;\(group.id.uuidString)",
      isUnknownPlaceholder: false,
      lastSeenAt: now,
      enrollmentStatus: .enrolled,
      consentStatus: .consented,
      embeddingIds: recordsToSave.map(\.id),
      primaryEmbeddingId: recordsToSave.first?.id
    )
    do {
      do {
        try await store.savePersonProfile(profile, context: context)
      } catch {
        logEnrollmentWarning("capturedGroup savePersonProfileFailed personId=\(profile.id.uuidString) error=\(error.localizedDescription)", context: context)
        throw error
      }
      var savedCount = 0
      for saved in recordsToSave {
        do {
          try await store.saveEmbedding(saved, context: context)
        } catch {
          logEnrollmentWarning("capturedGroup saveEmbeddingFailed personId=\(profile.id.uuidString) sampleId=\(saved.id.uuidString) error=\(error.localizedDescription)", context: context)
          throw error
        }
        savedCount += 1
      }
      captureGroups.remove(at: groupIndex)
      cachedProfiles = (try? await store.loadPeople()) ?? cachedProfiles
      let centroids = (try? await store.averagedEmbeddings()) ?? []
      if let centroid = centroids
        .filter({ $0.personId == profile.id })
        .max(by: { $0.sampleCount < $1.sampleCount }) {
        let norm = sqrt(centroid.averagedVector.reduce(Float(0)) { $0 + $1 * $1 })
        AppLogger.log(
          .enrollmentCentroid,
          "\(context.logPrefix) personId=\(profile.id.uuidString) sampleCount=\(centroid.sampleCount) dim=\(centroid.vectorDimension) normAfter=\(String(format: "%.3f", norm)) modelName=\(centroid.modelName) preprocessing=\(centroid.preprocessingVersion) source=capturedPictures"
        )
      }
      let selectedFrames = selectedSamples.map { String($0.frameSequence) }.joined(separator: ",")
      AppLogger.log(.profileSave, "\(context.logPrefix) name=\(trimmedName) personId=\(profile.id.uuidString) samplesAvailable=\(group.samples.count) embeddedPhysicalSamples=\(embeddedPhysicalFrames.count) bestThreeFrames=[\(selectedFrames)] embeddingsAdded=\(savedCount)")
      return result(summary: "Saved \(trimmedName) from the best \(embeddedPhysicalFrames.count) captured face samples with \(savedCount) embeddings")
    } catch {
      logEnrollmentWarning("capturedGroup saveFailed error=\(error.localizedDescription)", context: context)
      return result(summary: "Captured group save failed: \(error.localizedDescription)")
    }
  }

  func ignoreFirstCapturedFaceGroup() -> IdentityProcessingResult {
    let context = currentContext()
    guard let groupIndex = bestCapturedFaceGroupIndex() else { return result(summary: "No captured face group to ignore") }
    let group = captureGroups.remove(at: groupIndex)
    AppLogger.log(.streamEndedReview, "\(context.logPrefix) action=ignore group=\(group.id.uuidString) samples=\(group.samples.count)")
    return result(summary: "Ignored captured face group")
  }

  func ignorePendingUnknown() -> IdentityProcessingResult {
    let context = currentContext()
    let pendingSamples = Self.enrollmentPhysicalSampleCount(in: pendingUnknownEmbeddings)
    let pendingVectors = pendingUnknownEmbeddings.count
    pendingUnknownEmbeddings = []
    pendingUnknownRejectedSamples = 0
    pendingUnknownPreview = nil
    enrollmentWaitingForNextSample = false
    enrollmentStatusText = "Enrollment cancelled."
    lastPromptAt = Date()
    AppLogger.log(.enrollmentUI, "\(context.logPrefix) action=cancel tapped=true state=\(activeState.state.rawValue)")
    AppLogger.log(.enrollmentCancel, "\(context.logPrefix) personDraft=pending pendingSamples=\(pendingSamples) pendingVectors=\(pendingVectors) cleared=true")
    AppLogger.log(.enrollment, "\(context.logPrefix) unknownCandidate=pending quality=nil action=ignore personId=none")
    return result(summary: "Unknown enrollment ignored")
  }

  func discardLastEnrollmentCandidate() -> IdentityProcessingResult {
    let context = currentContext()
    let hadCandidate = bestRetainedCandidate() != nil
    lastDetectedFaceCandidate = nil
    lastRecognitionCandidate = nil
    lastEnrollmentCandidate = nil
    lastEnrollmentCandidateUpdateAt = nil
    pendingUnknownPreview = nil
    AppLogger.log(.enrollment, "\(context.logPrefix) unknownCandidate=last action=discard hadCandidate=\(hadCandidate)")
    return result(summary: hadCandidate ? "Last detected face discarded" : "No detected face to discard")
  }

  func recordTranscript(_ entry: TranscriptEntry, attribution: TranscriptAttribution? = nil) async {
    _ = await startAppRunIfNeeded()
    let context = currentContext()
    guard IdentityConfig.enableTranscriptAttachment else {
      AppLogger.log(.transcriptAttachSkip, "\(context.logPrefix) reason=transcriptAttachmentDisabled")
      return
    }
    guard let appRunId = context?.appRunId, let conversationSessionId = context?.conversationSessionId else {
      AppLogger.log(.transcript, "\(context.logPrefix) skipped reason=noActiveConversationSession isFinal=\(entry.isFinal) textLen=\(entry.text.count)")
      return
    }
    let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      if entry.isFinal {
        AppLogger.log(.transcript, "\(context.logPrefix) ignored empty final transcript appRun=\(appRunId.uuidString) session=\(conversationSessionId.uuidString)")
        AppLogger.log(.transcriptAttachSkip, "\(context.logPrefix) reason=emptyFinalAfterCancellation")
      }
      return
    }
    let personId = attribution?.personId ?? (activeState.state == .confirmed ? activeState.personId : nil)
    let stateText = attribution?.state ?? activeState.state.rawValue
    let sourceText = attribution.map { "\(entry.source)+\($0.sourceEvidence)" } ?? entry.source
    let now = Date()
    let startedAt = entry.startedAt ?? now
    let endedAt = entry.endedAt ?? now
    if !entry.isFinal {
      lastMeaningfulPartialTranscript = text
      var chunk = activePartialTranscriptChunk ?? TranscriptChunk(
        id: UUID(),
        appRunId: appRunId,
        conversationSessionId: conversationSessionId,
        personId: personId,
        activeIdentityState: stateText,
        text: text,
        isFinal: false,
        startedAt: startedAt,
        endedAt: nil,
        transcriptUpdatedAt: now,
        source: sourceText,
        createdAt: startedAt
      )
      chunk.personId = personId
      chunk.activeIdentityState = stateText
      chunk.source = sourceText
      chunk.text = text
      chunk.isFinal = false
      chunk.endedAt = nil
      chunk.transcriptUpdatedAt = now
      activePartialTranscriptChunk = chunk
      try? await store.saveTranscriptChunk(chunk, context: context)
      AppLogger.log(.transcript, "\(context.logPrefix) partial updated chunk=\(chunk.id.uuidString) person=\(personId?.uuidString ?? "unknown") state=\(stateText) source=\(sourceText) textLen=\(text.count) preview=\"\(Self.preview(text))\"")
      return
    }
    guard text != lastSavedFinalTranscript else { return }
    lastSavedFinalTranscript = text
    let chunk = TranscriptChunk(
      id: activePartialTranscriptChunk?.id ?? UUID(),
      appRunId: appRunId,
      conversationSessionId: conversationSessionId,
      personId: personId,
      activeIdentityState: stateText,
      text: text,
      isFinal: true,
      startedAt: activePartialTranscriptChunk?.startedAt ?? startedAt,
      endedAt: endedAt,
      transcriptUpdatedAt: now,
      source: sourceText,
      createdAt: activePartialTranscriptChunk?.createdAt ?? startedAt
    )
    activePartialTranscriptChunk = nil
    try? await store.saveTranscriptChunk(chunk, context: context)
    AppLogger.log(.transcript, "\(context.logPrefix) final committed chunk=\(chunk.id.uuidString) person=\(personId?.uuidString ?? "unknown") state=\(stateText) source=\(sourceText) textLen=\(text.count) preview=\"\(Self.preview(text))\"")
    AppLogger.log(.transcriptAttach, "\(context.logPrefix) chunk=\(chunk.id.uuidString) person=\(attribution?.displayName ?? activeState.displayName ?? "unknown") personId=\(personId?.uuidString ?? "nil") isFinal=true textLength=\(text.count) reason=\(attribution?.sourceEvidence ?? (personId == nil ? "noConfirmedIdentity" : "activeIdentityConfirmed"))")
  }

  func flushPartialTranscriptOnStop(_ text: String, attribution: TranscriptAttribution? = nil) async {
    let fallback = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? lastMeaningfulPartialTranscript
      : text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !fallback.isEmpty, fallback != lastSavedFinalTranscript else {
      AppLogger.log(.transcriptAttach, "\(currentContext().logPrefix) textLength=0 isFinal=false activePerson=\(activeState.personId?.uuidString ?? "unknown") saved=false reason=no-meaningful-partial")
      return
    }
    let entry = TranscriptEntry(id: UUID(), text: fallback, timestamp: 0, isFinal: true)
    await recordTranscript(entry, attribution: attribution)
  }

  func endConversation() async {
    AppLogger.log(.streamEndedReview, "\(currentContext().logPrefix) groups=\(captureGroups.count) samples=\(captureGroups.reduce(0) { $0 + $1.samples.count })")
    if let candidate = lastEnrollmentCandidate {
      AppLogger.log(
        .enrollmentCandidate,
        "\(currentContext().logPrefix) preservedAfterStop lastDetected=\(lastDetectedFaceCandidate != nil) recognitionCandidate=\(lastRecognitionCandidate != nil) enrollmentCandidate=true frame=\(candidate.frameSequence) hasEmbedding=\(!pendingUnknownEmbeddings.isEmpty)"
      )
    } else {
      AppLogger.log(
        .enrollmentCandidate,
        "\(currentContext().logPrefix) preservedAfterStop lastDetected=\(lastDetectedFaceCandidate != nil) recognitionCandidate=\(lastRecognitionCandidate != nil) enrollmentCandidate=false"
      )
    }
    if let chunk = activePartialTranscriptChunk, !chunk.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      await recordTranscript(TranscriptEntry(id: chunk.id, text: chunk.text, timestamp: 0, isFinal: true))
    }
    guard let session = activeConversation else { return }
    try? await store.endConversationSession(session.id)
    activeConversation = nil
    activePartialTranscriptChunk = nil
  }

  func clearIdentities() async -> IdentityProcessingResult {
    let context = currentContext()
    try? await store.clearIdentities(context: context)
    pendingUnknownEmbeddings = []
    pendingUnknownRejectedSamples = 0
    pendingUnknownPreview = nil
    lastDetectedFaceCandidate = nil
    lastRecognitionCandidate = nil
    lastEnrollmentCandidate = nil
    confirmor.reset()
    activeState = .none
    cachedProfiles = []
    captureGroups = []
    totalSessionCaptures = 0
    return result(summary: "Local identity data cleared")
  }

  func deletePerson(id: UUID) async {
    let context = currentContext()
    try? await store.deletePersonProfile(id: id, context: context)
    cachedProfiles = (try? await store.loadPeople()) ?? []
    if activeState.personId == id {
      confirmor.reset()
      activeState = .none
    }
    AppLogger.log(.database, "\(context.logPrefix) deletePerson id=\(id)")
  }

  func deleteFaceEnrollment(personId: UUID) async {
    let context = currentContext()
    try? await store.deleteFaceEnrollment(personId: personId, context: context)
    cachedProfiles = (try? await store.loadPeople()) ?? []
    if activeState.personId == personId {
      confirmor.reset()
      activeState = .none
    }
    AppLogger.log(.database, "\(context.logPrefix) deleteFaceEnrollment personId=\(personId)")
  }

  func deleteSavedPerson(named name: String) async -> IdentityProcessingResult {
    _ = await startAppRunIfNeeded()
    let context = currentContext()
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return result(summary: "Enter a saved person name to delete")
    }
    let profiles = (try? await store.loadPeople()) ?? cachedProfiles
    let matches = profiles.filter {
      $0.enrollmentStatus != .deleted
        && $0.displayName.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
    guard !matches.isEmpty else {
      AppLogger.log(.database, "\(context.logPrefix) deleteSavedPerson name=\(trimmed) status=notFound")
      return result(summary: "No saved person named \(trimmed)")
    }
    for profile in matches {
      try? await store.deletePersonProfile(id: profile.id, context: context)
    }
    cachedProfiles = (try? await store.loadPeople()) ?? []
    if matches.contains(where: { $0.id == activeState.personId }) {
      confirmor.reset()
      activeState = .none
    }
    AppLogger.log(.database, "\(context.logPrefix) deleteSavedPerson name=\(trimmed) deletedProfiles=\(matches.count)")
    return result(summary: "Deleted \(matches.count) saved profile(s) named \(trimmed)")
  }

  func clearConversations() async {
    let context = currentContext()
    try? await store.clearConversations(context: context)
    activeConversation = nil
  }

  private func saveEnrollmentSamples(
    personId: UUID,
    embeddings: [FaceEmbedding],
    crop: FaceCropResult,
    quality: FaceQualityDecision,
    context: PipelineContext?
  ) async throws {
    let uniqueRecords = makeEmbeddingRecords(
      personId: personId,
      embeddings: embeddings,
      crop: crop,
      quality: quality,
      context: context
    )
    guard !uniqueRecords.isEmpty else { return }
    let existing = (try? await store.embeddingsForPerson(personId)) ?? []
    var sharedImagePath: String?
    for var record in uniqueRecords {
      let key = Self.enrollmentEmbeddingSpaceKey(for: record)
      let existingForSpace = existing.filter { Self.enrollmentEmbeddingSpaceKey(for: $0) == key }
      guard existingForSpace.count < 12 else { continue }
      if IdentityConfig.saveDebugFaceCrops {
        if sharedImagePath == nil {
          sharedImagePath = try? saveCropImage(UIImage(cgImage: crop.alignedCroppedImage), frameSequence: crop.frameSequence, recordId: record.id)
        }
        record.sampleImageLocalPath = sharedImagePath
      }
      try await store.saveEmbedding(record, context: context)
    }
  }

  private func saveCropImage(_ image: UIImage, frameSequence: UInt64, recordId: UUID) throws -> String {
    guard let data = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
    let fileManager = FileManager.default
    let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    let directory = base
      .appendingPathComponent("MetaFaceIdentity", isDirectory: true)
      .appendingPathComponent("EnrollmentImages", isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileName = "frame_\(frameSequence)_\(recordId.uuidString.prefix(8)).png"
    let fileURL = directory.appendingPathComponent(fileName)
    try data.write(to: fileURL, options: .atomic)
    return fileURL.path
  }

  private func autoCaptureFaceSample(
    candidate: IdentityCandidate,
    embedding: FaceEmbedding?,
    embeddingRecords: [FaceEmbeddingRecord] = [],
    context: PipelineContext?,
    embeddingStatus: String
  ) {
    let frame = candidate.crop.frameSequence
    AppLogger.log(
      .faceCaptureCandidate,
      "\(context.logPrefix) frame=\(frame) track=pending rawWidth=\(candidate.quality.rawFaceWidth) rawHeight=\(candidate.quality.rawFaceHeight) cropWidth=\(candidate.quality.cropWidth) cropHeight=\(candidate.quality.cropHeight) quality=\(candidate.quality.score.map { String(format: "%.3f", $0) } ?? "nil") accepted=\(candidate.quality.acceptedForRecognition) reason=\(candidate.quality.acceptedForRecognition ? "acceptedForCapture" : candidate.quality.rejectReason ?? "qualityRejected")"
    )
    guard candidate.quality.acceptedForRecognition else {
      AppLogger.log(.faceCaptureSkip, "\(context.logPrefix) frame=\(frame) track=none reason=qualityRejected")
      return
    }
    guard totalSessionCaptures < maxSessionCaptures else {
      AppLogger.log(.faceCaptureSkip, "\(context.logPrefix) frame=\(frame) track=none reason=storageLimit")
      return
    }

    let resolvedIndex: Int
    let groupMatch: CaptureGroupMatch?
    if let match = captureGroupMatch(for: candidate, embedding: embedding) {
      resolvedIndex = match.index
      groupMatch = match
    } else {
      captureGroups.append(CapturedFaceGroup(id: UUID(), samples: [], firstSeenAt: Date(), lastSeenAt: Date(), bestQuality: 0, status: "unknown"))
      resolvedIndex = captureGroups.count - 1
      groupMatch = nil
    }

    guard captureGroups[resolvedIndex].samples.count < maxSamplesPerCaptureGroup else {
      AppLogger.log(.faceCaptureSkip, "\(context.logPrefix) frame=\(frame) track=\(captureGroups[resolvedIndex].id.uuidString) reason=storageLimit")
      return
    }
    guard shouldSaveDiverseSample(candidate: candidate, embedding: embedding, group: captureGroups[resolvedIndex], context: context) else {
      AppLogger.log(.faceCaptureSkip, "\(context.logPrefix) frame=\(frame) track=\(captureGroups[resolvedIndex].id.uuidString) reason=duplicateRecent")
      return
    }

    let groupId = captureGroups[resolvedIndex].id
    let records: [FaceEmbeddingRecord]
    if !embeddingRecords.isEmpty {
      records = embeddingRecords
    } else if let embedding {
      records = [
        makeEmbeddingRecord(personId: nil, vector: embedding.vector, embedding: embedding, crop: candidate.crop, quality: candidate.quality, context: context)
      ]
    } else {
      records = []
    }
    let sample = CapturedFaceSampleSnapshot(
      id: UUID(),
      groupId: groupId,
      frameSequence: frame,
      timestamp: candidate.crop.frameTimestamp,
      thumbnailImage: Self.makeThumbnail(from: UIImage(cgImage: candidate.crop.alignedCroppedImage), maxPixelSize: 96),
      cropImage: UIImage(cgImage: candidate.crop.alignedCroppedImage),
      cropSize: CGSize(width: candidate.crop.croppedImage.width, height: candidate.crop.croppedImage.height),
      sourceImageSize: candidate.crop.sourceImageSize,
      qualityScore: candidate.quality.score,
      qualityTier: candidate.quality.tier,
      rawFaceWidth: candidate.quality.rawFaceWidth,
      rawFaceHeight: candidate.quality.rawFaceHeight,
      faceBoxPixels: candidate.crop.rawFaceBoundingBoxPixels,
      embeddingRecords: records,
      embeddingStatus: embeddingStatus
    )
    captureGroups[resolvedIndex].samples.append(sample)
    captureGroups[resolvedIndex].lastSeenAt = Date()
    captureGroups[resolvedIndex].bestQuality = max(captureGroups[resolvedIndex].bestQuality, candidate.quality.score ?? 0)
    totalSessionCaptures += 1
    AppLogger.log(.faceCaptureSave, "\(context.logPrefix) session=\(context?.conversationSessionId?.uuidString ?? "none") captureId=\(sample.id.uuidString) track=\(groupId.uuidString) frame=\(frame) cropSize=\(Int(sample.cropSize.width))x\(Int(sample.cropSize.height)) quality=\(sample.qualityScore.map { String(format: "%.3f", $0) } ?? "nil") embeddingStatus=\(embeddingStatus) vectorCount=\(records.count) modelSpaces=\(records.map { $0.modelName }.joined(separator: ","))")
    AppLogger.log(.faceTrack, "\(context.logPrefix) frame=\(frame) captureId=\(sample.id.uuidString) assignedGroup=\(groupId.uuidString) method=\(groupMatch?.method ?? "newGroup") score=\(groupMatch?.score.map { String(format: "%.3f", $0) } ?? "nil") reason=\(groupMatch?.reason ?? "firstSample")")
    AppLogger.log(.faceGroupUpdate, "\(context.logPrefix) group=\(groupId.uuidString) sampleCount=\(captureGroups[resolvedIndex].samples.count) bestQuality=\(String(format: "%.3f", captureGroups[resolvedIndex].bestQuality)) suggestedLabel=none status=\(captureGroups[resolvedIndex].status)")
  }

  private func captureGroupMatch(for candidate: IdentityCandidate, embedding: FaceEmbedding?) -> CaptureGroupMatch? {
    var bestMatch: CaptureGroupMatch?
    var bestRank: Float = -.greatestFiniteMagnitude
    let candidateBox = candidate.crop.rawFaceBoundingBoxPixels
    let candidateTimestamp = candidate.crop.frameTimestamp

    for index in captureGroups.indices.reversed() {
      let group = captureGroups[index]
      guard let last = group.samples.last else { continue }
      let timeGap = abs(candidateTimestamp.timeIntervalSince(last.timestamp))
      let centerDistance = Self.normalizedFaceCenterDistance(candidateBox, last.faceBoxPixels, sourceSize: candidate.crop.sourceImageSize)
      let sizeSimilarity = Self.faceBoxSizeSimilarity(candidateBox, last.faceBoxPixels)
      let temporalScore = max(Float(0), Float(1 - centerDistance)) * 0.70
        + max(Float(0), Float(sizeSimilarity)) * 0.30

      if let embedding, let embeddingScore = bestEmbeddingSimilarity(for: embedding, in: group) {
        if embeddingScore >= 0.50 {
          let match = CaptureGroupMatch(
            index: index,
            method: "embedding",
            score: embeddingScore,
            reason: "sameEmbeddingSpace"
          )
          if embeddingScore + 2.0 > bestRank {
            bestRank = embeddingScore + 2.0
            bestMatch = match
          }
          continue
        }

        if timeGap <= 15.0, centerDistance <= 0.45, embeddingScore >= 0.35 {
          let combined = (embeddingScore * 0.55) + (temporalScore * 0.45)
          let match = CaptureGroupMatch(
            index: index,
            method: "embeddingTemporal",
            score: combined,
            reason: "sameRecentFace"
          )
          if combined + 1.0 > bestRank {
            bestRank = combined + 1.0
            bestMatch = match
          }
          continue
        }
      }

      guard timeGap <= 8.0, centerDistance <= 0.30, sizeSimilarity >= 0.35 else { continue }
      let match = CaptureGroupMatch(
        index: index,
        method: "boxTemporal",
        score: temporalScore,
        reason: "sameRecentBox"
      )
      if temporalScore > bestRank {
        bestRank = temporalScore
        bestMatch = match
      }
    }
    return bestMatch
  }

  private func bestEmbeddingSimilarity(for embedding: FaceEmbedding, in group: CapturedFaceGroup) -> Float? {
    let embeddingKey = Self.enrollmentEmbeddingSpaceKey(for: embedding)
    return group.samples
      .flatMap(\.embeddingRecords)
      .filter { Self.enrollmentEmbeddingSpaceKey(for: $0) == embeddingKey && $0.vector.count == embedding.vector.count }
      .map { FaceMatcher.cosineSimilarity(embedding.vector, $0.vector) }
      .max()
  }

  private static func normalizedFaceCenterDistance(_ lhs: CGRect, _ rhs: CGRect, sourceSize: CGSize) -> CGFloat {
    let frameDiagonal = max(hypot(sourceSize.width, sourceSize.height), 1)
    return hypot(lhs.midX - rhs.midX, lhs.midY - rhs.midY) / frameDiagonal
  }

  private static func faceBoxSizeSimilarity(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
    let lhsArea = max(lhs.width * lhs.height, 1)
    let rhsArea = max(rhs.width * rhs.height, 1)
    return min(lhsArea, rhsArea) / max(lhsArea, rhsArea)
  }

  private func shouldSaveDiverseSample(candidate: IdentityCandidate, embedding: FaceEmbedding?, group: CapturedFaceGroup, context: PipelineContext?) -> Bool {
    guard let last = group.samples.last else {
      AppLogger.log(.faceSampleDiversity, "\(context.logPrefix) group=\(group.id.uuidString) candidateFrame=\(candidate.crop.frameSequence) saved=true reason=firstSample score=1.000")
      return true
    }
    let timeGap = Date().timeIntervalSince(last.timestamp)
    let rawDelta = abs(candidate.quality.rawFaceWidth - last.rawFaceWidth)
    if timeGap >= faceCaptureIntervalSeconds {
      AppLogger.log(.faceSampleDiversity, "\(context.logPrefix) group=\(group.id.uuidString) candidateFrame=\(candidate.crop.frameSequence) saved=true reason=timeGap score=\(String(format: "%.2f", timeGap))")
      return true
    }
    if rawDelta >= 16 {
      AppLogger.log(.faceSampleDiversity, "\(context.logPrefix) group=\(group.id.uuidString) candidateFrame=\(candidate.crop.frameSequence) saved=true reason=sizeChange score=\(rawDelta)")
      return true
    }
    if let embedding, let lastVector = last.embeddingRecord?.vector, lastVector.count == embedding.vector.count {
      let distance = 1 - FaceMatcher.cosineSimilarity(embedding.vector, lastVector)
      if distance >= 0.08 {
        AppLogger.log(.faceSampleDiversity, "\(context.logPrefix) group=\(group.id.uuidString) candidateFrame=\(candidate.crop.frameSequence) saved=true reason=embeddingDiversity score=\(String(format: "%.3f", distance))")
        return true
      }
    }
    AppLogger.log(.faceSampleDiversity, "\(context.logPrefix) group=\(group.id.uuidString) candidateFrame=\(candidate.crop.frameSequence) saved=false reason=duplicateRecent score=0.000")
    return false
  }

  private func makeEmbeddingRecords(
    personId: UUID?,
    embeddings: [FaceEmbedding],
    crop: FaceCropResult,
    quality: FaceQualityDecision,
    context: PipelineContext?
  ) -> [FaceEmbeddingRecord] {
    var seenSpaces = Set<String>()
    var records: [FaceEmbeddingRecord] = []
    for embedding in embeddings {
      let key = Self.enrollmentEmbeddingSpaceKey(for: embedding)
      guard !seenSpaces.contains(key) else { continue }
      seenSpaces.insert(key)
      records.append(makeEmbeddingRecord(
        personId: personId,
        vector: embedding.vector,
        embedding: embedding,
        crop: crop,
        quality: quality,
        context: context
      ))
    }
    return records
  }

  private func makeEmbeddingRecord(
    personId: UUID?,
    vector: [Float],
    embedding: FaceEmbedding,
    crop: FaceCropResult,
    quality: FaceQualityDecision,
    context: PipelineContext?
  ) -> FaceEmbeddingRecord {
    FaceEmbeddingRecord(
      id: UUID(),
      personId: personId,
      vector: vector,
      dimension: vector.count,
      qualityScore: quality.score,
      sourceFrameTimestamp: crop.frameTimestamp,
      createdAt: Date(),
      sampleImageLocalPath: nil,
      metadata: FaceEmbeddingMetadata(
        boundingBoxNormalized: CodableCGRect(crop.faceBoundingBoxNormalized),
        cropSize: CodableCGSize(quality.cropSize),
        sourceImageSize: CodableCGSize(crop.sourceImageSize)
      ),
      appRunId: context?.appRunId,
      conversationSessionId: context?.conversationSessionId,
      modelName: embedding.modelName,
      modelVersion: embedding.modelVersion,
      modelSource: embedding.modelSource,
      preprocessingVersion: embedding.preprocessingVersion,
      frameNumber: crop.frameSequence,
      rawFaceBoxPixels: CodableCGRect(crop.rawFaceBoundingBoxPixels),
      faceBoxPixels: CodableCGRect(crop.faceBoundingBoxPixels),
      qualityTier: quality.tier,
      faceCaptureQuality: crop.faceCaptureQuality,
      yaw: crop.yaw,
      pitch: crop.pitch,
      roll: crop.roll,
      cropWidth: quality.cropWidth,
      cropHeight: quality.cropHeight,
      sourceFrameWidth: Int(crop.sourceImageSize.width),
      sourceFrameHeight: Int(crop.sourceImageSize.height),
      orientationUsed: crop.visionOrientation.debugName
    )
  }

  private func updateRetainedFaceCandidatesIfNeeded(
    _ candidate: IdentityCandidate,
    context: PipelineContext?,
    embeddingStatus: String
  ) {
    updateCandidate(&lastDetectedFaceCandidate, candidate: candidate, kind: "lastDetected", context: context, embeddingStatus: embeddingStatus)
    if candidate.quality.acceptedForRecognition {
      updateCandidate(&lastRecognitionCandidate, candidate: candidate, kind: "recognitionCandidate", context: context, embeddingStatus: embeddingStatus)
    }
    if candidate.quality.acceptedForEnrollment {
      updateCandidate(&lastEnrollmentCandidate, candidate: candidate, kind: "enrollmentCandidate", context: context, embeddingStatus: embeddingStatus)
    }
  }

  private func updateCandidate(
    _ storage: inout EnrollmentCandidateSnapshot?,
    candidate: IdentityCandidate,
    kind: String,
    context: PipelineContext?,
    embeddingStatus: String
  ) {
    let now = Date()
    let crop = candidate.crop
    let cropArea = CGFloat(crop.croppedImage.width * crop.croppedImage.height)
    let previousArea = (storage?.cropSize.width ?? 0) * (storage?.cropSize.height ?? 0)
    let quality = candidate.quality.score ?? 0
    let previousQuality = storage?.qualityScore ?? 0
    let enoughTimeElapsed = lastEnrollmentCandidateUpdateAt.map { now.timeIntervalSince($0) >= faceCaptureIntervalSeconds } ?? true
    let shouldReplace = storage == nil
      || quality > previousQuality + 0.05
      || cropArea > previousArea * 1.20
      || enoughTimeElapsed
    guard shouldReplace else { return }

    let snapshot = EnrollmentCandidateSnapshot(
      id: UUID(),
      kind: kind,
      frameSequence: crop.frameSequence,
      timestamp: crop.frameTimestamp,
      cropImage: UIImage(cgImage: crop.alignedCroppedImage),
      alignedCropImage: UIImage(cgImage: crop.alignedCroppedImage),
      thumbnailImage: Self.makeThumbnail(from: UIImage(cgImage: crop.alignedCroppedImage), maxPixelSize: 160),
      cropSize: CGSize(width: crop.croppedImage.width, height: crop.croppedImage.height),
      sourceImageSize: crop.sourceImageSize,
      qualityScore: candidate.quality.score,
      qualityTier: candidate.quality.tier,
      acceptedForEnrollment: candidate.quality.acceptedForEnrollment,
      embeddingStatus: embeddingStatus,
      savedImagePath: nil
    )
    storage = snapshot
    lastEnrollmentCandidateUpdateAt = now
    AppLogger.log(
      .enrollmentCandidate,
      "\(context.logPrefix) updated kind=\(kind) frame=\(snapshot.frameSequence) cropSize=\(Int(snapshot.cropSize.width))x\(Int(snapshot.cropSize.height)) quality=\(snapshot.qualityScore.map { String(format: "%.3f", $0) } ?? "nil") source=live"
    )
  }

  private func isEligibleForDebugEmbedding(_ candidate: IdentityCandidate) -> Bool {
    guard IdentityConfig.allowLowQualityEmbeddingDebug else { return false }
    let rawMin = min(candidate.quality.rawFaceWidth, candidate.quality.rawFaceHeight)
    let cropMin = min(candidate.quality.cropWidth, candidate.quality.cropHeight)
    return CGFloat(rawMin) >= IdentityConfig.qualityConfig.minRawFacePixelsForDetection
      && CGFloat(cropMin) >= IdentityConfig.qualityConfig.minCropPixelsForRecognition
  }

  private func saveLastEnrollmentCandidateImageToDisk(nameHint: String?) async throws -> String {
    guard let candidate = bestRetainedCandidate() else {
      throw CocoaError(.fileNoSuchFile)
    }
    guard let data = candidate.alignedCropImage.pngData() else {
      throw CocoaError(.fileWriteUnknown)
    }
    let fileManager = FileManager.default
    let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    let directory = base
      .appendingPathComponent("MetaFaceIdentity", isDirectory: true)
      .appendingPathComponent("EnrollmentImages", isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let safeName = Self.safeFileComponent(nameHint?.isEmpty == false ? nameHint! : "unknown")
    let fileName = "\(safeName)_frame_\(candidate.frameSequence)_\(candidate.id.uuidString.prefix(8)).png"
    let fileURL = directory.appendingPathComponent(fileName)
    try data.write(to: fileURL, options: .atomic)
    return fileURL.path
  }

  private func bestRetainedCandidate() -> EnrollmentCandidateSnapshot? {
    lastEnrollmentCandidate ?? lastRecognitionCandidate ?? lastDetectedFaceCandidate
  }

  private func calibrationSummary() -> FaceCalibrationSummary {
    FaceCalibrationSummary(samples: calibrationSamples)
  }

  private func calibrationSampleCountText() -> String {
    let summary = calibrationSummary()
    return "same \(summary.samePersonCount) / different \(summary.differentPersonCount)"
  }

  private func markCaptureGroupRecognized(frame: UInt64, personId: UUID, personName: String?) {
    guard let index = captureGroups.indices.last(where: { captureGroups[$0].samples.contains(where: { $0.frameSequence == frame }) }) else { return }
    captureGroups[index].recognizedPersonId = personId
    captureGroups[index].recognizedPersonName = personName
  }

  private func bestCapturedFaceGroupIndex() -> Int? {
    captureGroups.indices
      .filter { !captureGroups[$0].samples.isEmpty }
      .max { lhs, rhs in
        isCaptureGroupRankedBefore(captureGroups[lhs], captureGroups[rhs])
      }
  }

  private func captureGroupDisplayIndices() -> [Int] {
    captureGroups.indices.sorted {
      isCaptureGroupRankedBefore(captureGroups[$1], captureGroups[$0])
    }
  }

  private func isCaptureGroupRankedBefore(_ lhs: CapturedFaceGroup, _ rhs: CapturedFaceGroup) -> Bool {
    let lhsNeedsReview = lhs.recognizedPersonId == nil
    let rhsNeedsReview = rhs.recognizedPersonId == nil
    if lhsNeedsReview != rhsNeedsReview { return !lhsNeedsReview && rhsNeedsReview }

    let lhsEmbedded = lhs.samples.filter { !$0.embeddingRecords.isEmpty }.count
    let rhsEmbedded = rhs.samples.filter { !$0.embeddingRecords.isEmpty }.count
    if lhsEmbedded != rhsEmbedded { return lhsEmbedded < rhsEmbedded }

    if lhs.samples.count != rhs.samples.count { return lhs.samples.count < rhs.samples.count }
    if lhs.bestQuality != rhs.bestQuality { return lhs.bestQuality < rhs.bestQuality }
    return lhs.lastSeenAt < rhs.lastSeenAt
  }

  private func captureGroupSnapshots() -> [CapturedFaceGroupSnapshot] {
    captureGroupDisplayIndices().map { index in
      let group = captureGroups[index]
      let qualities = group.samples.compactMap(\.qualityScore)
      let minQ = qualities.min().map { String(format: "%.2f", $0) } ?? "nil"
      let maxQ = qualities.max().map { String(format: "%.2f", $0) } ?? "nil"
      return CapturedFaceGroupSnapshot(
        id: group.id,
        bestThumbnailImage: group.samples.max { ($0.qualityScore ?? 0) < ($1.qualityScore ?? 0) }?.thumbnailImage,
        sampleCount: group.samples.count,
        embeddingCount: group.samples.filter { $0.embeddingRecord != nil }.count,
        qualitySummary: "q \(minQ)-\(maxQ)",
        status: group.status,
        recognizedPersonId: group.recognizedPersonId,
        recognizedPersonName: group.recognizedPersonName
      )
    }
  }

  private func canRecordCalibrationLabel() -> Bool {
    guard !(embeddingModel is MissingFaceEmbeddingModel), let observation = lastCalibrationObservation else {
      return false
    }
    return observation.profile != nil
      && observation.candidate.quality.acceptedForRecognition
      && observation.match.bestSimilarity.isFinite
  }

  private func updateCalibrationObservation(
    frame: ProcessedVideoFrame,
    candidate: IdentityCandidate,
    match: IdentityMatchResult,
    profile: PersonProfile?,
    state: ActiveIdentityState,
    context: PipelineContext?
  ) {
    lastCalibrationObservation = CalibrationObservation(
      profile: profile,
      frameSequence: frame.sequence,
      candidate: candidate,
      match: match,
      state: state
    )
  }

  private func logCalibrationLabelSkip(
    label: FaceCalibrationMode,
    reason: String,
    context: PipelineContext?
  ) {
    let observation = lastCalibrationObservation
    AppLogger.log(
      .calibrationLabelSkip,
      "\(context.logPrefix) label=\(label == .samePerson ? "same" : "different") reason=\(reason) modelLoaded=\(!(embeddingModel is MissingFaceEmbeddingModel)) selectedProfile=\(observation?.profile?.displayName ?? "nil") hasEmbedding=\(observation != nil) hasScore=\(observation?.match.bestSimilarity.isFinite == true)"
    )
  }

  private func logCalibrationSample(_ sample: FaceCalibrationSample, context: PipelineContext?, frame: UInt64) {
    AppLogger.log(
      .faceCalibrationSample,
      "\(context.logPrefix) frame=\(frame) source=\(sample.source.rawValue) mode=\(sample.mode.rawValue) profile=\(sample.profileLabel) score=\(Self.formatScore(sample.score)) margin=\(Self.formatScore(sample.margin)) rawFaceWidth=\(sample.rawFaceWidth.map(String.init) ?? "nil") cropWidth=\(sample.cropWidth.map(String.init) ?? "nil") cropHeight=\(sample.cropHeight.map(String.init) ?? "nil") quality=\(Self.formatScore(sample.quality)) brightness=\(Self.formatScore(sample.brightness)) blur=\(Self.formatScore(sample.blur)) acceptedForRecognition=\(sample.acceptedForRecognition) acceptedForEnrollment=\(sample.acceptedForEnrollment) reason=\(sample.rejectionReason?.isEmpty == false ? sample.rejectionReason! : sample.decision)"
    )
  }

  private static func formatScore(_ value: Float?) -> String {
    value.map { String(format: "%.3f", $0) } ?? "nil"
  }

  private func updateRetainedCandidate(_ candidate: EnrollmentCandidateSnapshot) {
    switch candidate.kind {
    case "enrollmentCandidate":
      lastEnrollmentCandidate = candidate
    case "recognitionCandidate":
      lastRecognitionCandidate = candidate
    default:
      lastDetectedFaceCandidate = candidate
    }
  }

  private func logEnrollmentSampleRejected(
    frame: UInt64,
    candidate: IdentityCandidate?,
    reason: String,
    context: PipelineContext?
  ) {
    pendingUnknownRejectedSamples += 1
    enrollmentStatusText = "Sample rejected: \(reason). Move closer, center face, improve lighting."
    let rawFaceWidth = candidate.map { "\($0.quality.rawFaceWidth)" } ?? "nil"
    let cropSize = candidate.map { "\($0.quality.cropWidth)x\($0.quality.cropHeight)" } ?? "nil"
    let quality = candidate?.quality.score.map { String(format: "%.3f", $0) } ?? "nil"
    AppLogger.log(
      .enrollmentSampleRejected,
      "\(context.logPrefix) reason=\(reason) frame=\(frame) rawFaceWidth=\(rawFaceWidth) cropSize=\(cropSize) quality=\(quality)"
    )
    AppLogger.log(
      .enrollmentGuidance,
      "\(context.logPrefix) Move closer. Need raw face width at least \(Int(IdentityConfig.qualityConfig.minRawFacePixelsForEnrollment)) px, ideally 100 px."
    )
  }

  private static func makeThumbnail(from image: UIImage, maxPixelSize: CGFloat) -> UIImage {
    let scale = min(maxPixelSize / max(image.size.width, 1), maxPixelSize / max(image.size.height, 1), 1)
    let size = CGSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.image { _ in
      image.draw(in: CGRect(origin: .zero, size: size))
    }
  }

  private static func thumbnailImage(from embeddings: [FaceEmbeddingRecord]) -> UIImage? {
    let ordered = embeddings.sorted { left, right in
      let leftQuality = left.qualityScore ?? -1
      let rightQuality = right.qualityScore ?? -1
      if leftQuality != rightQuality {
        return leftQuality > rightQuality
      }
      return left.createdAt > right.createdAt
    }
    for record in ordered {
      guard let path = record.sampleImageLocalPath,
            let thumbnail = thumbnailImage(atLocalPath: path) else { continue }
      return thumbnail
    }
    return nil
  }

  private static func thumbnailImage(fromProfileNotes notes: String?) -> UIImage? {
    for path in thumbnailPaths(fromProfileNotes: notes) {
      if let thumbnail = thumbnailImage(atLocalPath: path) {
        return thumbnail
      }
    }
    return nil
  }

  private static func thumbnailPaths(fromProfileNotes notes: String?) -> [String] {
    guard let notes else { return [] }
    return notes.components(separatedBy: CharacterSet(charactersIn: ";\n"))
      .compactMap { component -> String? in
        let parts = component.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard key == "enrollmentImagePath" || key == "imageOnlyEnrollmentPath" else { return nil }
        let path = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
      }
  }

  private static func thumbnailImage(atLocalPath path: String) -> UIImage? {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          let image = UIImage(contentsOfFile: trimmed) else {
      return nil
    }
    return makeThumbnail(from: image, maxPixelSize: 160)
  }

  private static func safeFileComponent(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
    let text = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    return text.isEmpty ? "unknown" : String(text.prefix(40))
  }

  private func saveMatchEvent(
    frame: ProcessedVideoFrame,
    candidate: IdentityCandidate?,
    match: IdentityMatchResult?,
    decision: String,
    rollingState: ActiveIdentityState,
    context: PipelineContext?,
    modelName: String?,
    modelVersion: String?
  ) async {
    guard let appRunId = context?.appRunId else { return }
    let event = IdentityMatchEvent(
      id: UUID(),
      appRunId: appRunId,
      conversationSessionId: context?.conversationSessionId,
      frameNumber: frame.sequence,
      detectedFaceCount: frame.identityCandidates.count,
      cropQualityTier: candidate?.quality.tier.rawValue,
      embeddingModelName: modelName,
      embeddingModelVersion: modelVersion,
      candidatePersonId: match?.bestPersonId,
      cosineSimilarity: Double(match?.bestSimilarity ?? 0),
      l2Distance: match?.l2Distance.map(Double.init),
      threshold: Double(IdentityConfig.strongMatchThreshold),
      rollingWindowSize: IdentityConfig.rollingWindowSize,
      rollingConfirmCount: rollingState.state == .confirmed ? IdentityConfig.requiredStrongMatches : 0,
      decision: decision,
      rollingConfirmationState: rollingState.state.rawValue,
      createdAt: Date()
    )
    try? await store.saveIdentityMatchEvent(event, context: context)
  }

  private func shouldProcessIdentityFrame(at now: Date) -> Bool {
    guard let lastProcessedAt else { return true }
    return now.timeIntervalSince(lastProcessedAt) >= 1 / IdentityConfig.identityProcessingFPS
  }

  private func result(
    summary: String,
    faceCandidateCount: Int = 0,
    qualityPassCount: Int = 0,
    embeddingGenerated: Bool = false,
    matchDecisionText: String = "none",
    currentRecognitionFacePreview: UIImage? = nil,
    embeddingLatencyMS: Double = 0,
    embeddingMetrics: [FaceEmbeddingDebugMetric] = [],
    alignmentRejectedCount: Int = 0
  ) -> IdentityProcessingResult {
    let suppressPrompt: Bool
    if let lastPromptAt {
      suppressPrompt = Date().timeIntervalSince(lastPromptAt) < 15
    } else {
      suppressPrompt = false
    }
    let retainedCandidate = bestRetainedCandidate()
    let groupSnapshots = captureGroupSnapshots()
    return IdentityProcessingResult(
      activeIdentity: activeState,
      pendingEnrollmentFacePreview: suppressPrompt ? nil : pendingUnknownPreview,
      lastEnrollmentCandidatePreview: retainedCandidate?.thumbnailImage,
      currentRecognitionFacePreview: currentRecognitionFacePreview,
      hasLastEnrollmentCandidate: retainedCandidate != nil,
      lastEnrollmentCandidateSummary: retainedCandidate?.summaryText ?? "No saved face candidate",
      modelStatusText: embeddingModelStatusText(),
      isUnknownPersonVisible: !suppressPrompt && pendingUnknownPreview != nil && activeState.state == .unknown,
      summary: summary,
      profiles: cachedProfiles,
      faceCandidateCount: faceCandidateCount,
      qualityPassCount: qualityPassCount,
      embeddingGenerated: embeddingGenerated,
      matchDecisionText: matchDecisionText,
      embeddingLatencyMS: embeddingLatencyMS,
      embeddingMetrics: embeddingMetrics,
      alignmentRejectedCount: alignmentRejectedCount,
      pendingEnrollmentAcceptedSamples: Self.enrollmentPhysicalSampleCount(in: pendingUnknownEmbeddings),
      pendingEnrollmentRequiredSamples: IdentityConfig.minimumEnrollmentSamples,
      pendingEnrollmentRejectedSamples: pendingUnknownRejectedSamples,
      enrollmentStatusText: enrollmentStatusText,
      capturedFaceGroups: groupSnapshots,
      streamEndedReviewText: "groups \(groupSnapshots.count), samples \(groupSnapshots.reduce(0) { $0 + $1.sampleCount })",
      calibrationModeText: calibrationStatusText,
      calibrationSampleCountText: calibrationSampleCountText(),
      calibrationSummaryText: calibrationSummary().displayText,
      canRecordCalibrationLabel: canRecordCalibrationLabel(),
      runSessionSnapshot: nil
    )
  }

  private func logRolling(
    frame: UInt64,
    match: IdentityMatchResult?,
    state: ActiveIdentityState,
    inputDecisionOverride: String? = nil,
    reasonOverride: String? = nil
  ) {
    let context = currentContext()
    let inputDecision = inputDecisionOverride ?? match?.decision.rawValue ?? "noFace"
    let reason = reasonOverride ?? state.state.rawValue
    AppLogger.log(
      .rollingIdentity,
      "\(context.logPrefix) frame=\(frame) inputDecision=\(inputDecision) candidate=\(match?.bestPersonId?.uuidString ?? "none") confirmed=\(state.state == .confirmed ? state.personId?.uuidString ?? "none" : "none") streak=window activePerson=\(state.displayName ?? state.personId?.uuidString ?? "unknown")"
    )
    AppLogger.log(
      .identityRolling,
      "\(context.logPrefix) frame=\(frame) inputDecision=\(inputDecision) candidate=\(match?.bestPersonId?.uuidString ?? "unknown") activeAfter=\(state.displayName ?? state.personId?.uuidString ?? "unknown") reason=\(reason)"
    )
  }

  private func emitStatsIfNeeded(context: PipelineContext?) {
    let elapsed = Date().timeIntervalSince(statsStartedAt)
    guard elapsed >= 2 else { return }
    let avgEmbed = statsEmbedded > 0 ? statsEmbedLatencyMS / Double(statsEmbedded) : 0
    AppLogger.log(
      .pipelineStats,
      "\(context.logPrefix) received=na preview=na visionAttempted=na visionProcessed=na faces=\(statsFaces) qualityPass=\(statsQualityPass) embedded=\(statsEmbedded) matched=\(statsMatched) droppedBusy=na skippedThrottle=na avgVisionMs=na avgEmbedMs=\(String(format: "%.1f", avgEmbed))"
    )
    statsStartedAt = Date()
    statsFaces = 0
    statsQualityPass = 0
    statsEmbedded = 0
    statsMatched = 0
    statsEmbedLatencyMS = 0
  }

  private func matchRejectionReason(_ match: IdentityMatchResult) -> String {
    if match.decision == .known {
      return "acceptedByThresholdAndMargin"
    }
    if match.bestPersonId == nil {
      return "noCompatibleProfileCentroid"
    }
    if match.bestSimilarity < IdentityConfig.weakMatchThreshold {
      return "belowWeakThreshold"
    }
    if match.bestSimilarity < IdentityConfig.strongMatchThreshold {
      return "belowConfirmedThreshold"
    }
    if let margin = match.margin, margin < IdentityConfig.matchMarginThreshold {
      return "belowMargin"
    }
    return "ambiguous"
  }

  func recordFaceDetectionEvent(_ event: FaceDetectionEvent) async {
    let context = PipelineContext(appRunId: event.appRunId, conversationSessionId: event.conversationSessionId, datDeviceId: activeConversation?.datDeviceId)
    try? await store.saveFaceDetectionEvent(event, context: context)
  }

  private func snapshot(appRunId: UUID?, conversationSessionId: UUID?) -> RunSessionSnapshot {
    RunSessionSnapshot(
      appRunId: appRunId,
      conversationSessionId: conversationSessionId,
      detectedFacesThisSession: 0,
      acceptedFaceCropsThisSession: Self.enrollmentPhysicalSampleCount(in: pendingUnknownEmbeddings),
      embeddingsSavedThisSession: pendingUnknownEmbeddings.count,
      transcriptChunksSavedThisSession: 0
    )
  }

  private static func preview(_ text: String) -> String {
    let trimmed = text.replacingOccurrences(of: "\n", with: " ")
    return trimmed.count > 80 ? "\(trimmed.prefix(80))..." : trimmed
  }
}
