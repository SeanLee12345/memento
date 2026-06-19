import Foundation

enum AppLogCategory: String {
  case sdk = "SDK"
  case registration = "REGISTRATION"
  case permissions = "PERMISSIONS"
  case devices = "DEVICES"
  case stream = "STREAM"
  case frames = "FRAMES"
  case frameSource = "FRAME_SOURCE"
  case vision = "VISION"
  case visionInput = "VISION_INPUT"
  case visionOrientation = "VISION_ORIENTATION"
  case faceBox = "FACE_BOX"
  case visionBox = "VISION_BOX"
  case visionBoxReject = "VISION_BOX_REJECT"
  case faceCrop = "FACE_CROP"
  case faceQuality = "FACE_QUALITY"
  case embedding = "EMBEDDING"
  case faceEmbedding = "FACE_EMBEDDING"
  case faceEmbeddingModel = "FACE_EMBEDDING_MODEL"
  case faceEmbeddingVector = "FACE_EMBEDDING_VECTOR"
  case faceEmbeddingDebug = "FACE_EMBEDDING_DEBUG"
  case identityConfig = "IDENTITY_CONFIG"
  case faceEmbeddingSkip = "FACE_EMBEDDING_SKIP"
  case vectorStore = "VECTOR_STORE"
  case faceVectorStore = "FACE_VECTOR_STORE"
  case identityMatch = "IDENTITY_MATCH"
  case faceMatch = "FACE_MATCH"
  case faceMatchSkip = "FACE_MATCH_SKIP"
  case faceCalibrationSample = "FACE_CALIBRATION_SAMPLE"
  case faceCalibrationSummary = "FACE_CALIBRATION_SUMMARY"
  case calibrationLabel = "CALIBRATION_LABEL"
  case calibrationLabelSkip = "CALIBRATION_LABEL_SKIP"
  case rollingIdentity = "ROLLING_IDENTITY"
  case identityRolling = "IDENTITY_ROLLING"
  case transcript = "TRANSCRIPT"
  case parakeetASR = "PARAKEET_ASR"
  case transcriptAttach = "TRANSCRIPT_ATTACH"
  case transcriptAttachSkip = "TRANSCRIPT_ATTACH_SKIP"
  case enrollment = "ENROLLMENT"
  case enrollmentUI = "ENROLLMENT_UI"
  case enrollmentCancel = "ENROLLMENT_CANCEL"
  case enrollmentAddSampleArmed = "ENROLLMENT_ADD_SAMPLE_ARMED"
  case enrollmentSampleCaptured = "ENROLLMENT_SAMPLE_CAPTURED"
  case enrollmentSampleRejected = "ENROLLMENT_SAMPLE_REJECTED"
  case enrollmentSampleSaveRequest = "ENROLLMENT_SAMPLE_SAVE_REQUEST"
  case enrollmentSampleSaved = "ENROLLMENT_SAMPLE_SAVED"
  case enrollmentSampleSaveFailed = "ENROLLMENT_SAMPLE_SAVE_FAILED"
  case enrollmentFinishRequest = "ENROLLMENT_FINISH_REQUEST"
  case enrollmentCentroid = "ENROLLMENT_CENTROID"
  case enrollmentFinished = "ENROLLMENT_FINISHED"
  case enrollmentCropSaved = "ENROLLMENT_CROP_SAVED"
  case enrollmentCropSaveSkipped = "ENROLLMENT_CROP_SAVE_SKIPPED"
  case enrollmentGuidance = "ENROLLMENT_GUIDANCE"
  case enrollmentCandidate = "ENROLLMENT_CANDIDATE"
  case enrollmentImageSave = "ENROLLMENT_IMAGE_SAVE"
  case database = "DATABASE"
  case runSession = "RUN_SESSION"
  case pipelineStats = "PIPELINE_STATS"
  case streamPerf = "STREAM_PERF"
  case display = "DISPLAY"
  case facePipelineStats = "FACE_PIPELINE_STATS"
  case facePipelineStop = "FACE_PIPELINE_STOP"
  case faceCaptureCandidate = "FACE_CAPTURE_CANDIDATE"
  case faceCaptureSave = "FACE_CAPTURE_SAVE"
  case faceCaptureSkip = "FACE_CAPTURE_SKIP"
  case faceTrack = "FACE_TRACK"
  case faceGroupUpdate = "FACE_GROUP_UPDATE"
  case faceSampleDiversity = "FACE_SAMPLE_DIVERSITY"
  case streamEndedReview = "STREAM_ENDED_REVIEW"
  case profileSave = "PROFILE_SAVE"
  case streamLifecycle = "STREAM_LIFECYCLE"
  case memory = "MEMORY"
  case sceneContext = "SCENE_CONTEXT"
  case activityMode = "ACTIVITY_MODE"
  case cloudDiarization = "CLOUD_DIARIZATION"
  case audio = "AUDIO"
  case speakerVAD = "SPEAKER_VAD"
  case speakerEmbedding = "SPEAKER_EMBEDDING"
  case speakerEmbeddingModel = "SPEAKER_EMBEDDING_MODEL"
  case speakerMatch = "SPEAKER_MATCH"
  case speakerIdentity = "SPEAKER_IDENTITY"
  case speakerEnrollment = "SPEAKER_ENROLLMENT"
  case localWorker = "LOCAL_WORKER"
  case mock = "MOCK"
  case tests = "TESTS"
}

enum AppLogger {
  private static let suppressedCategories: Set<AppLogCategory> = [
    .frames,
    .frameSource,
    .vision,
    .visionInput,
    .visionOrientation,
    .faceBox,
    .visionBox,
    .visionBoxReject,
    .faceCrop,
    .faceQuality,
    .embedding,
    .faceEmbedding,
    .faceEmbeddingVector,
    .faceEmbeddingDebug,
    .faceEmbeddingSkip,
    .faceVectorStore,
    .identityMatch,
    .faceMatch,
    .faceMatchSkip,
    .rollingIdentity,
    .identityRolling,
    .pipelineStats,
    .facePipelineStats,
    .faceCaptureCandidate,
    .faceCaptureSave,
    .faceCaptureSkip,
    .faceTrack,
    .faceGroupUpdate,
    .faceSampleDiversity,
    .enrollmentCandidate,
    .audio,
    .speakerVAD,
    .speakerEmbedding,
    .speakerEmbeddingModel,
    .speakerMatch,
    .speakerIdentity,
    .transcript,
    .transcriptAttach,
    .transcriptAttachSkip,
    .vectorStore,
    .sceneContext
  ]
  private static let timestampLock = NSLock()
  private static let printedOnceLock = NSLock()
  private static var printedOnceKeys: Set<String> = []
  private static let timestampFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  static func log(_ category: AppLogCategory, _ message: @autoclosure () -> String) {
    // Cheap, message-independent rejection first so suppressed hot-path
    // categories never pay to build their interpolated string.
    guard shouldPrintCategory(category) else { return }
    let resolved = message()
    guard shouldPrint(category, resolved) else { return }
    timestampLock.lock()
    let timestamp = timestampFormatter.string(from: Date())
    timestampLock.unlock()
    print("[MetaFace][\(timestamp)][\(category.rawValue)] \(resolved)")
  }

  /// Message-independent gate. Returns false for categories that can never
  /// print regardless of content, so the caller can skip resolving the
  /// `@autoclosure` message entirely on hot paths.
  private static func shouldPrintCategory(_ category: AppLogCategory) -> Bool {
    if category == .activityMode {
      return ActivityModeDebugSettings.isLoggingEnabled()
    }
    // .sceneContext is listed in suppressedCategories but is special-cased by message
    // content in shouldPrint(_:_:) (only summary lines print). It must reach that
    // check, so don't reject it on the cheap category-only gate.
    if category == .sceneContext {
      return true
    }
    if suppressedCategories.contains(category) {
      return false
    }
    return true
  }

  private static func shouldPrint(_ category: AppLogCategory, _ message: String) -> Bool {
    if category == .sceneContext {
      return shouldPrintSceneContext(message)
    }
    if category == .activityMode {
      return ActivityModeDebugSettings.isLoggingEnabled()
    }
    guard !suppressedCategories.contains(category) else { return false }
    if category == .database {
      if message.contains("[SUPABASE_SYNC] enqueued")
        || message.contains("[SUPABASE_SYNC] applied")
        || message.contains("[SUPABASE_SYNC] restored pending") {
        return false
      }
      if message.contains("presenceEpisode queued")
        || message.contains("saved presenceEpisode=")
        || message.contains("entity=IdentityMatchEvent saved")
        || message.contains("entity=PersonProfile saved") {
        return false
      }
      if message.contains("[SUPABASE_SYNC] schema-mismatch") {
        return shouldPrintOnce("supabase-schema-mismatch:\(syncKind(in: message) ?? "unknown")")
      }
    }
    if category == .memory {
      if message.hasPrefix("Phone assistance display updated")
        || message.hasPrefix("Phone assistance work invalidated")
        || message.hasPrefix("Person summary requested")
        || message.hasPrefix("Person summary stream refresh requested")
        || message.hasPrefix("Person summary ready")
        || message.hasPrefix("Live question classifier queued") {
        return false
      }
    }
    return true
  }

  private static func shouldPrintSceneContext(_ message: String) -> Bool {
    message.hasPrefix("Stream summary")
      || message.hasPrefix("Alibaba stream summary")
      || message.hasPrefix("[AI_PROXY]")
  }

  private static func shouldPrintOnce(_ key: String) -> Bool {
    printedOnceLock.lock()
    defer { printedOnceLock.unlock() }
    guard !printedOnceKeys.contains(key) else { return false }
    printedOnceKeys.insert(key)
    return true
  }

  private static func syncKind(in message: String) -> String? {
    guard let range = message.range(of: "kind=") else { return nil }
    return message[range.upperBound...]
      .split(whereSeparator: { $0 == " " || $0 == "\t" })
      .first
      .map(String.init)
  }
}
