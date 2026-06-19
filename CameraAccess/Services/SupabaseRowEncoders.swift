import Foundation

// Wire-format encoders mapping Swift model structs (camelCase) to the
// Postgres row shape (snake_case) defined in supabase/migrations/0001_init.sql.
//
// Each encoder:
//   * intentionally OMITS owner_uid — the column has `default auth.uid()` and
//     the user's JWT determines the value. Sending it would fail the WITH CHECK
//     clause on the RLS policy if the iOS clock ever drifted.
//   * encodes UUIDs as lowercase strings (PostgREST canonical form).
//   * encodes dates as ISO8601 (Postgres timestamptz accepts it).
//   * encodes vectors as JSON arrays of floats (pgvector parses these natively).
//   * passes nested Codable structs straight through into jsonb columns.
//
// Convention: each wire-shape struct is named `SupabaseRow<Entity>` and lives
// next to the Swift model it mirrors. Add a new entry here every time the
// pipeline starts persisting a new entity.

enum SupabaseTable {
  static let appRuns = "app_runs"
  static let personProfiles = "person_profiles"
  static let conversationSessions = "conversation_sessions"
  static let faceEmbeddings = "face_embeddings"
  static let personAveragedFaceEmbeddings = "person_averaged_face_embeddings"
  static let transcriptChunks = "transcript_chunks"
  static let conversationEvents = "conversation_events"
  static let faceDetectionEvents = "face_detection_events"
  static let identityMatchEvents = "identity_match_events"
  static let sceneContextRecords = "scene_context_records"
  static let presenceEpisodes = "presence_episodes"
  static let activityModeEpisodes = "activity_mode_episodes"
  static let glassesDisplayInteractionEvents = "glasses_display_interaction_events"
}

// MARK: - app_runs

struct SupabaseRowAppRun: Encodable {
  let id: UUID
  let started_at: Date
  let ended_at: Date?
  let app_build: String?
  let app_version: String?
  let device_id: String?
  let notes: String?

  init(_ run: AppRun) {
    id = run.id
    started_at = run.startedAt
    ended_at = run.endedAt
    app_build = run.appBuild
    app_version = run.appVersion
    device_id = run.deviceId
    notes = run.notes
  }
}

// MARK: - person_profiles

struct SupabaseRowPersonProfile: Encodable {
  let id: UUID
  let display_name: String
  let created_at: Date
  let updated_at: Date
  let notes: String?
  let is_unknown_placeholder: Bool
  let last_seen_at: Date?
  let enrollment_status: String
  let consent_status: String
  let primary_embedding_id: UUID?
  let embedding_count: Int

  init(_ profile: PersonProfile) {
    id = profile.id
    display_name = profile.displayName
    created_at = profile.createdAt
    updated_at = profile.updatedAt
    notes = profile.notes
    is_unknown_placeholder = profile.isUnknownPlaceholder
    last_seen_at = profile.lastSeenAt
    enrollment_status = profile.enrollmentStatus.rawValue
    consent_status = profile.consentStatus.rawValue
    primary_embedding_id = profile.primaryEmbeddingId
    embedding_count = profile.embeddingIds.count
  }
}

// MARK: - conversation_sessions

struct SupabaseRowConversationSession: Encodable {
  let id: UUID
  let app_run_id: UUID?
  let device_id: String?
  let dat_device_id: String?
  let person_id: UUID?
  let started_at: Date
  let ended_at: Date?
  let stream_started_at: Date?
  let stream_ended_at: Date?
  let state: String
  let created_at: Date
  let updated_at: Date
  let confidence: Float
  let status: String

  init(_ session: ConversationSession) {
    id = session.id
    app_run_id = session.appRunId
    device_id = session.deviceId
    dat_device_id = session.datDeviceId
    person_id = session.personId
    started_at = session.startedAt
    ended_at = session.endedAt
    stream_started_at = session.streamStartedAt
    stream_ended_at = session.streamEndedAt
    state = session.state
    created_at = session.createdAt
    updated_at = session.updatedAt
    confidence = session.confidence
    status = session.status.rawValue
  }
}

// MARK: - face_embeddings

struct SupabaseRowFaceEmbedding: Encodable {
  let id: UUID
  let person_id: UUID?
  let app_run_id: UUID?
  let conversation_session_id: UUID?
  let vector: [Float]
  let dimension: Int
  let model_name: String
  let model_version: String
  let model_source: String
  let preprocessing_version: String
  let quality_score: Float?
  let frame_number: UInt64?
  let source_frame_timestamp: Date
  let created_at: Date
  let sample_image_local_path: String?
  let sample_image_storage_path: String?
  let metadata: FaceEmbeddingMetadata?
  let raw_face_box_pixels: CodableCGRect?
  let face_box_pixels: CodableCGRect?
  let quality_tier: String?
  let face_capture_quality: Float?
  let yaw: Float?
  let pitch: Float?
  let roll: Float?
  let crop_width: Int?
  let crop_height: Int?
  let source_frame_width: Int?
  let source_frame_height: Int?
  let orientation_used: String?

  init(_ record: FaceEmbeddingRecord, sampleImageStoragePath: String? = nil) {
    id = record.id
    person_id = record.personId
    app_run_id = record.appRunId
    conversation_session_id = record.conversationSessionId
    vector = record.vector
    dimension = record.dimension
    model_name = record.modelName
    model_version = record.modelVersion
    model_source = record.modelSource
    preprocessing_version = record.preprocessingVersion
    quality_score = record.qualityScore
    frame_number = record.frameNumber
    source_frame_timestamp = record.sourceFrameTimestamp
    created_at = record.createdAt
    sample_image_local_path = record.sampleImageLocalPath
    sample_image_storage_path = sampleImageStoragePath
    metadata = record.metadata
    raw_face_box_pixels = record.rawFaceBoxPixels
    face_box_pixels = record.faceBoxPixels
    quality_tier = record.qualityTier?.rawValue
    face_capture_quality = record.faceCaptureQuality
    yaw = record.yaw
    pitch = record.pitch
    roll = record.roll
    crop_width = record.cropWidth
    crop_height = record.cropHeight
    source_frame_width = record.sourceFrameWidth
    source_frame_height = record.sourceFrameHeight
    orientation_used = record.orientationUsed
  }
}

// MARK: - person_averaged_face_embeddings

struct SupabaseRowPersonAveragedEmbedding: Encodable {
  let id: UUID
  let person_id: UUID
  let averaged_vector: [Float]
  let vector_dimension: Int
  let sample_count: Int
  let model_name: String
  let model_version: String
  let model_source: String
  let preprocessing_version: String
  let updated_at: Date

  init(_ avg: PersonAveragedEmbedding) {
    id = avg.id
    person_id = avg.personId
    averaged_vector = avg.averagedVector
    vector_dimension = avg.vectorDimension
    sample_count = avg.sampleCount
    model_name = avg.modelName
    model_version = avg.modelVersion
    model_source = avg.modelSource
    preprocessing_version = avg.preprocessingVersion
    updated_at = avg.updatedAt
  }
}

// MARK: - transcript_chunks

struct SupabaseRowTranscriptChunk: Encodable {
  let id: UUID
  let app_run_id: UUID
  let conversation_session_id: UUID
  let person_id: UUID?
  let active_identity_state: String
  let text: String
  let is_final: Bool
  let started_at: Date?
  let ended_at: Date?
  let transcript_updated_at: Date
  let source: String
  let created_at: Date

  init(_ chunk: TranscriptChunk) {
    id = chunk.id
    app_run_id = chunk.appRunId
    conversation_session_id = chunk.conversationSessionId
    person_id = chunk.personId
    active_identity_state = chunk.activeIdentityState
    text = chunk.text
    is_final = chunk.isFinal
    started_at = chunk.startedAt
    ended_at = chunk.endedAt
    transcript_updated_at = chunk.transcriptUpdatedAt
    source = chunk.source
    created_at = chunk.createdAt
  }
}

// MARK: - face_detection_events

struct SupabaseRowFaceDetectionEvent: Encodable {
  // RawJSONString carries the existing JSON blob through as a Postgres jsonb value.
  struct RawJSONString: Encodable {
    let json: String
    func encode(to encoder: Encoder) throws {
      var container = encoder.singleValueContainer()
      // PostgREST accepts a JSON value directly for jsonb. If the source string
      // isn't valid JSON, fall back to wrapping it as a string element.
      if let data = json.data(using: .utf8),
         let any = try? JSONSerialization.jsonObject(with: data, options: [.allowFragments]) {
        if let dict = any as? [String: Any] {
          let nested = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
          guard let text = String(data: nested, encoding: .utf8) else {
            try container.encode(json)
            return
          }
          // Re-encode through JSONDecoder to produce a proper JSON value.
          let decoded = try JSONDecoder().decode(AnyCodable.self, from: Data(text.utf8))
          try container.encode(decoded)
        } else if let arr = any as? [Any] {
          let nested = try JSONSerialization.data(withJSONObject: arr, options: [])
          let decoded = try JSONDecoder().decode(AnyCodable.self, from: nested)
          try container.encode(decoded)
        } else {
          try container.encode(json)
        }
      } else {
        try container.encode(json)
      }
    }
  }

  let id: UUID
  let app_run_id: UUID
  let conversation_session_id: UUID?
  let frame_index: Int
  let frame_width: Int
  let frame_height: Int
  let ui_image_orientation: String
  let cg_image_width: Int
  let cg_image_height: Int
  let vision_orientation_used: String
  let preferred_face_count: Int
  let sweep_face_counts: RawJSONString
  let selected_orientation: String?
  let selected_face_count: Int
  let created_at: Date

  init(_ event: FaceDetectionEvent) {
    id = event.id
    app_run_id = event.appRunId
    conversation_session_id = event.conversationSessionId
    frame_index = event.frameIndex
    frame_width = event.frameWidth
    frame_height = event.frameHeight
    ui_image_orientation = event.uiImageOrientation
    cg_image_width = event.cgImageWidth
    cg_image_height = event.cgImageHeight
    vision_orientation_used = event.visionOrientationUsed
    preferred_face_count = event.preferredFaceCount
    sweep_face_counts = RawJSONString(json: event.sweepFaceCountsJson)
    selected_orientation = event.selectedOrientation
    selected_face_count = event.selectedFaceCount
    created_at = event.createdAt
  }
}

// MARK: - identity_match_events

struct SupabaseRowIdentityMatchEvent: Encodable {
  let id: UUID
  let app_run_id: UUID
  let conversation_session_id: UUID?
  let frame_number: UInt64?
  let detected_face_count: Int
  let crop_quality_tier: String?
  let embedding_model_name: String?
  let embedding_model_version: String?
  let candidate_person_id: UUID?
  let cosine_similarity: Double
  let l2_distance: Double?
  let threshold: Double
  let rolling_window_size: Int
  let rolling_confirm_count: Int
  let decision: String
  let rolling_confirmation_state: String?
  let created_at: Date

  init(_ event: IdentityMatchEvent) {
    id = event.id
    app_run_id = event.appRunId
    conversation_session_id = event.conversationSessionId
    frame_number = event.frameNumber
    detected_face_count = event.detectedFaceCount
    crop_quality_tier = event.cropQualityTier
    embedding_model_name = event.embeddingModelName
    embedding_model_version = event.embeddingModelVersion
    candidate_person_id = event.candidatePersonId
    cosine_similarity = event.cosineSimilarity
    l2_distance = event.l2Distance
    threshold = event.threshold
    rolling_window_size = event.rollingWindowSize
    rolling_confirm_count = event.rollingConfirmCount
    decision = event.decision
    rolling_confirmation_state = event.rollingConfirmationState
    created_at = event.createdAt
  }
}

// MARK: - scene_context_records

struct SupabaseRowSceneContext: Encodable {
  let id: UUID
  let app_run_id: UUID
  let conversation_session_id: UUID?
  let person_id: UUID?
  let started_at: Date
  let ended_at: Date
  let created_at: Date
  let model_name: String
  let prompt_version: String
  let transcript_chunk_ids: SupabaseRowFaceDetectionEvent.RawJSONString
  let frame_timestamps: SupabaseRowFaceDetectionEvent.RawJSONString
  let location_label: String?
  let latitude: Double?
  let longitude: Double?
  let location_accuracy_meters: Double?
  let who: String
  let where_text: String
  let what: String
  let when_text: String
  let why: String
  let how: String
  let interaction_style: String
  let summary: String
  let confidence: Double
  let evidence: SupabaseRowFaceDetectionEvent.RawJSONString

  init(_ record: SceneContextRecord) {
    id = record.id
    app_run_id = record.appRunId
    conversation_session_id = record.conversationSessionId
    person_id = record.personId
    started_at = record.startedAt
    ended_at = record.endedAt
    created_at = record.createdAt
    model_name = record.modelName
    prompt_version = record.promptVersion
    transcript_chunk_ids = .init(json: record.transcriptChunkIdsJson)
    frame_timestamps = .init(json: record.frameTimestampsJson)
    location_label = record.locationLabel
    latitude = record.latitude
    longitude = record.longitude
    location_accuracy_meters = record.locationAccuracyMeters
    who = record.who
    where_text = record.whereText
    what = record.what
    when_text = record.whenText
    why = record.why
    how = record.how
    interaction_style = record.interactionStyle
    summary = record.summary
    confidence = record.confidence
    evidence = .init(json: record.evidenceJson)
  }
}

// MARK: - presence_episodes

struct SupabaseRowPresenceEpisode: Encodable {
  let id: UUID
  let app_run_id: UUID
  let conversation_session_id: UUID?
  let person_id: UUID?
  let display_name: String
  let started_at: Date
  let last_evidence_at: Date
  let ended_at: Date?
  let status: String
  let confidence: Float
  let evidence_summary: String
  let updated_at: Date

  init(_ record: PresenceEpisodeRecord) {
    id = record.id
    app_run_id = record.appRunId
    conversation_session_id = record.conversationSessionId
    person_id = record.personId
    display_name = record.displayName
    started_at = record.startedAt
    last_evidence_at = record.lastEvidenceAt
    ended_at = record.endedAt
    status = record.status.rawValue
    confidence = record.confidence
    evidence_summary = record.evidenceSummary
    updated_at = record.updatedAt
  }
}

// MARK: - activity_mode_episodes

struct SupabaseRowActivityModeEpisode: Encodable {
  let id: UUID
  let app_run_id: UUID
  let conversation_session_id: UUID?
  let mode: String
  let specific_activity: String
  let started_at: Date
  let last_evidence_at: Date
  let ended_at: Date?
  let confidence: Double
  let reason: String
  let source: String
  let model_name: String
  let prompt_version: String
  let updated_at: Date

  init(_ record: ActivityModeEpisodeRecord) {
    id = record.id
    app_run_id = record.appRunId
    conversation_session_id = record.conversationSessionId
    mode = record.mode
    specific_activity = record.specificActivity
    started_at = record.startedAt
    last_evidence_at = record.lastEvidenceAt
    ended_at = record.endedAt
    confidence = record.confidence
    reason = record.reason
    source = record.source
    model_name = record.modelName
    prompt_version = record.promptVersion
    updated_at = record.updatedAt
  }
}

// MARK: - glasses_display_interaction_events

struct SupabaseRowGlassesDisplayInteractionEvent: Encodable {
  let id: UUID
  let app_run_id: UUID
  let conversation_session_id: UUID?
  let person_id: UUID?
  let display_name: String?
  let card_title: String
  let card_text: String
  let action: String
  let source: String
  let created_at: Date

  init(_ event: GlassesDisplayInteractionEvent) {
    id = event.id
    app_run_id = event.appRunId
    conversation_session_id = event.conversationSessionId
    person_id = event.personId
    display_name = event.displayName
    card_title = event.cardTitle
    card_text = event.cardText
    action = event.action
    source = event.source
    created_at = event.createdAt
  }
}

// MARK: - AnyCodable helper for nested JSON

/// Minimal Codable wrapper that round-trips arbitrary JSON values so we can
/// hand existing JSON strings (e.g. transcriptChunkIdsJson) to PostgREST as
/// real jsonb values instead of stringified blobs.
struct AnyCodable: Codable {
  let value: Any

  init(_ value: Any) { self.value = value }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() { self.value = NSNull() ; return }
    if let v = try? container.decode(Bool.self) { self.value = v; return }
    if let v = try? container.decode(Int.self) { self.value = v; return }
    if let v = try? container.decode(Double.self) { self.value = v; return }
    if let v = try? container.decode(String.self) { self.value = v; return }
    if let v = try? container.decode([AnyCodable].self) { self.value = v.map(\.value); return }
    if let v = try? container.decode([String: AnyCodable].self) {
      self.value = v.mapValues(\.value); return
    }
    throw DecodingError.dataCorruptedError(
      in: container, debugDescription: "Unsupported JSON value"
    )
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch value {
    case is NSNull: try container.encodeNil()
    case let v as Bool: try container.encode(v)
    case let v as Int: try container.encode(v)
    case let v as Double: try container.encode(v)
    case let v as String: try container.encode(v)
    case let v as [Any]: try container.encode(v.map { AnyCodable($0) })
    case let v as [String: Any]: try container.encode(v.mapValues { AnyCodable($0) })
    default:
      throw EncodingError.invalidValue(value, .init(
        codingPath: container.codingPath,
        debugDescription: "Unsupported JSON value"
      ))
    }
  }
}
