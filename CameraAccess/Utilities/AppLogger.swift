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
  case audio = "AUDIO"
  case speakerVAD = "SPEAKER_VAD"
  case speakerEmbedding = "SPEAKER_EMBEDDING"
  case speakerEmbeddingModel = "SPEAKER_EMBEDDING_MODEL"
  case speakerMatch = "SPEAKER_MATCH"
  case speakerIdentity = "SPEAKER_IDENTITY"
  case localWorker = "LOCAL_WORKER"
  case mock = "MOCK"
  case tests = "TESTS"
}

enum AppLogger {
  private static let timestampLock = NSLock()
  private static let timestampFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  static func log(_ category: AppLogCategory, _ message: String) {
    timestampLock.lock()
    let timestamp = timestampFormatter.string(from: Date())
    timestampLock.unlock()
    print("[MetaFace][\(timestamp)][\(category.rawValue)] \(message)")
  }
}
