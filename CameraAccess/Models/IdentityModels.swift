import CoreGraphics
import Foundation
import UIKit
import Vision

struct FaceCropResult {
  let frameSequence: UInt64
  let frameTimestamp: Date
  let faceBoundingBoxNormalized: CGRect
  let rawFaceBoundingBoxPixels: CGRect
  let faceBoundingBoxPixels: CGRect
  let croppedImage: CGImage
  let previewImage: UIImage
  let sourceImageSize: CGSize
  let visionOrientation: CGImagePropertyOrientation
  let alignmentMode: String
  let yaw: Float?
  let roll: Float?
  let pitch: Float?
  let faceCaptureQuality: Float?
  // Similarity-transform-aligned face crop matching the active embedding model.
  let alignedCroppedImage: CGImage
  // True when the padded bounding box was clipped at the image bottom edge (chin likely cut off).
  let isBottomClipped: Bool
}

enum FaceQualityTier: String, Codable, Equatable {
  case noFace
  case tooSmallForRecognition
  case usableForRecognition
  case tooSmallForEnrollment
  case usableForEnrollment
  case preferredEnrollment
  case rejectedBadQuality
  case rejectedBadPose
  case rejectedBadCrop
}

struct FaceQualityConfig: Equatable {
  var minRawFacePixelsForDetection: CGFloat = 32
  var minRawFacePixelsForRecognition: CGFloat = 48
  var minRawFacePixelsForEnrollment: CGFloat = 80
  var minCropPixelsForRecognition: CGFloat = 90
  var minCropPixelsForEnrollment: CGFloat = 140
  var minRecognitionQuality: Float = 0.04
  var minEnrollmentQuality: Float = 0.18
  var recognitionMinFacePixels: CGFloat { minRawFacePixelsForRecognition }
  var enrollmentMinFacePixels: CGFloat { minRawFacePixelsForEnrollment }
  var preferredEnrollmentFacePixels: CGFloat = 90
  var recognitionMinFaceCaptureQuality: Float { minRecognitionQuality }
  var enrollmentMinFaceCaptureQuality: Float { minEnrollmentQuality }
  var minFaceCaptureQuality: Float { enrollmentMinFaceCaptureQuality }
  var maxAbsYawRadians: Float = 0.7
  var maxAbsPitchRadians: Float = 0.7
  var maxAbsRollRadians: Float = 0.7
  var maxRecognitionCenterOffsetRatio: CGFloat = 0.55
  var maxEnrollmentCenterOffsetRatio: CGFloat = 0.45
  var maxCenterOffsetRatio: CGFloat { maxEnrollmentCenterOffsetRatio }
}

struct FaceQualityDecision {
  let detected: Bool
  let cropSucceeded: Bool
  let rawFaceWidth: Int
  let rawFaceHeight: Int
  let accepted: Bool
  let score: Float?
  let reasons: [String]
  let rejectionReasons: [String]
  let normalizedFaceArea: Float
  let cropSize: CGSize
  let visionQuality: Float?
  let cropWidth: Int
  let cropHeight: Int
  let brightness: Float?
  let sharpness: Float?
  let faceAreaRatio: Float
  let centerOffset: Float
  let passes: Bool
  let rejectReason: String?
  let tier: FaceQualityTier
  let acceptedForRecognition: Bool
  let acceptedForEnrollment: Bool
}

struct IdentityCandidate {
  let crop: FaceCropResult
  let quality: FaceQualityDecision
}

struct FaceEmbedding {
  let vector: [Float]
  let dimension: Int
  let modelName: String
  let modelVersion: String
  let modelSource: String
  let preprocessingVersion: String
  let createdAt: Date

  init(
    vector: [Float],
    dimension: Int,
    modelName: String,
    modelVersion: String = "unknown",
    modelSource: String = "unknown",
    preprocessingVersion: String = "unknown",
    createdAt: Date
  ) {
    self.vector = vector
    self.dimension = dimension
    self.modelName = modelName
    self.modelVersion = modelVersion
    self.modelSource = modelSource
    self.preprocessingVersion = preprocessingVersion
    self.createdAt = createdAt
  }
}

struct PersonProfile: Identifiable, Codable, Equatable {
  enum EnrollmentStatus: String, Codable {
    case unknown
    case pending
    case pendingName
    case enrolled
    case deleted
  }

  enum ConsentStatus: String, Codable {
    case unknown
    case consented
    case revoked
  }

  let id: UUID
  var displayName: String
  var createdAt: Date
  var updatedAt: Date
  var notes: String?
  var isUnknownPlaceholder: Bool
  var lastSeenAt: Date?
  var enrollmentStatus: EnrollmentStatus
  var consentStatus: ConsentStatus
  var embeddingIds: [UUID]
  var primaryEmbeddingId: UUID?

  init(
    id: UUID,
    displayName: String,
    createdAt: Date,
    updatedAt: Date,
    notes: String?,
    isUnknownPlaceholder: Bool,
    lastSeenAt: Date?,
    enrollmentStatus: EnrollmentStatus,
    consentStatus: ConsentStatus = .unknown,
    embeddingIds: [UUID] = [],
    primaryEmbeddingId: UUID? = nil
  ) {
    self.id = id
    self.displayName = displayName
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.notes = notes
    self.isUnknownPlaceholder = isUnknownPlaceholder
    self.lastSeenAt = lastSeenAt
    self.enrollmentStatus = enrollmentStatus
    self.consentStatus = consentStatus
    self.embeddingIds = embeddingIds
    self.primaryEmbeddingId = primaryEmbeddingId
  }
}

struct FaceEmbeddingMetadata: Codable, Equatable {
  var boundingBoxNormalized: CodableCGRect
  var cropSize: CodableCGSize
  var sourceImageSize: CodableCGSize
}

struct FaceEmbeddingRecord: Identifiable, Codable, Equatable {
  let id: UUID
  var personId: UUID?
  var appRunId: UUID?
  var conversationSessionId: UUID?
  var vector: [Float]
  var dimension: Int
  var modelName: String
  var modelVersion: String
  var modelSource: String
  var preprocessingVersion: String
  var qualityScore: Float?
  var frameNumber: UInt64?
  var sourceFrameTimestamp: Date
  var createdAt: Date
  var sampleImageLocalPath: String?
  var metadata: FaceEmbeddingMetadata?
  var rawFaceBoxPixels: CodableCGRect?
  var faceBoxPixels: CodableCGRect?
  var qualityTier: FaceQualityTier?
  var faceCaptureQuality: Float?
  var yaw: Float?
  var pitch: Float?
  var roll: Float?
  var cropWidth: Int?
  var cropHeight: Int?
  var sourceFrameWidth: Int?
  var sourceFrameHeight: Int?
  var orientationUsed: String?

  init(
    id: UUID,
    personId: UUID?,
    vector: [Float],
    dimension: Int,
    qualityScore: Float?,
    sourceFrameTimestamp: Date,
    createdAt: Date,
    sampleImageLocalPath: String?,
    metadata: FaceEmbeddingMetadata?,
    appRunId: UUID? = nil,
    conversationSessionId: UUID? = nil,
    modelName: String = "unknown",
    modelVersion: String = "unknown",
    modelSource: String = "unknown",
    preprocessingVersion: String = "unknown",
    frameNumber: UInt64? = nil,
    rawFaceBoxPixels: CodableCGRect? = nil,
    faceBoxPixels: CodableCGRect? = nil,
    qualityTier: FaceQualityTier? = nil,
    faceCaptureQuality: Float? = nil,
    yaw: Float? = nil,
    pitch: Float? = nil,
    roll: Float? = nil,
    cropWidth: Int? = nil,
    cropHeight: Int? = nil,
    sourceFrameWidth: Int? = nil,
    sourceFrameHeight: Int? = nil,
    orientationUsed: String? = nil
  ) {
    self.id = id
    self.personId = personId
    self.appRunId = appRunId
    self.conversationSessionId = conversationSessionId
    self.vector = vector
    self.dimension = dimension
    self.modelName = modelName
    self.modelVersion = modelVersion
    self.modelSource = modelSource
    self.preprocessingVersion = preprocessingVersion
    self.qualityScore = qualityScore
    self.frameNumber = frameNumber
    self.sourceFrameTimestamp = sourceFrameTimestamp
    self.createdAt = createdAt
    self.sampleImageLocalPath = sampleImageLocalPath
    self.metadata = metadata
    self.rawFaceBoxPixels = rawFaceBoxPixels
    self.faceBoxPixels = faceBoxPixels
    self.qualityTier = qualityTier
    self.faceCaptureQuality = faceCaptureQuality
    self.yaw = yaw
    self.pitch = pitch
    self.roll = roll
    self.cropWidth = cropWidth
    self.cropHeight = cropHeight
    self.sourceFrameWidth = sourceFrameWidth
    self.sourceFrameHeight = sourceFrameHeight
    self.orientationUsed = orientationUsed
  }
}

struct ConversationSession: Identifiable, Codable, Equatable {
  enum Status: String, Codable {
    case active
    case ended
    case unknown
  }

  let id: UUID
  var appRunId: UUID?
  var deviceId: String?
  var datDeviceId: String?
  var personId: UUID?
  var startedAt: Date
  var endedAt: Date?
  var streamStartedAt: Date?
  var streamEndedAt: Date?
  var state: String
  var createdAt: Date
  var updatedAt: Date
  var confidence: Float
  var status: Status

  init(
    id: UUID,
    personId: UUID? = nil,
    startedAt: Date,
    endedAt: Date? = nil,
    confidence: Float,
    status: Status,
    appRunId: UUID? = nil,
    deviceId: String? = nil,
    datDeviceId: String? = nil,
    streamStartedAt: Date? = nil,
    streamEndedAt: Date? = nil,
    state: String? = nil,
    createdAt: Date? = nil,
    updatedAt: Date? = nil
  ) {
    self.id = id
    self.appRunId = appRunId
    self.deviceId = deviceId
    self.datDeviceId = datDeviceId
    self.personId = personId
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.streamStartedAt = streamStartedAt
    self.streamEndedAt = streamEndedAt
    self.state = state ?? status.rawValue
    self.createdAt = createdAt ?? startedAt
    self.updatedAt = updatedAt ?? startedAt
    self.confidence = confidence
    self.status = status
  }
}

struct ConversationEvent: Identifiable, Codable, Equatable {
  enum AttributionStatus: String, Codable {
    case known
    case possible
    case unknown
    case noFace
  }

  let id: UUID
  var sessionId: UUID
  var timestamp: Date
  var transcriptText: String
  var isFinal: Bool
  var visiblePersonId: UUID?
  var faceConfidence: Float?
  var attributionStatus: AttributionStatus
}

struct IdentityMatchResult {
  enum Decision: String {
    case known
    case ambiguous
    case unknown
  }

  let bestPersonId: UUID?
  let bestSimilarity: Float
  let secondBestSimilarity: Float?
  let margin: Float?
  let decision: Decision
  let matchedEmbeddingId: UUID?
  let l2Distance: Float?

  init(
    bestPersonId: UUID?,
    bestSimilarity: Float,
    secondBestSimilarity: Float?,
    margin: Float?,
    decision: Decision,
    matchedEmbeddingId: UUID?,
    l2Distance: Float? = nil
  ) {
    self.bestPersonId = bestPersonId
    self.bestSimilarity = bestSimilarity
    self.secondBestSimilarity = secondBestSimilarity
    self.margin = margin
    self.decision = decision
    self.matchedEmbeddingId = matchedEmbeddingId
    self.l2Distance = l2Distance
  }
}

struct AppRun: Identifiable, Codable, Equatable {
  let id: UUID
  var startedAt: Date
  var endedAt: Date?
  var appBuild: String?
  var appVersion: String?
  var deviceId: String?
  var notes: String?
  var createdAt: Date
}

struct PersonAveragedEmbedding: Identifiable, Codable, Equatable {
  let id: UUID
  var personId: UUID
  var averagedVector: [Float]
  var vectorDimension: Int
  var sampleCount: Int
  var modelName: String
  var modelVersion: String
  var modelSource: String = "unknown"
  var preprocessingVersion: String = "unknown"
  var updatedAt: Date
}

struct FaceDetectionEvent: Identifiable, Codable, Equatable {
  let id: UUID
  var appRunId: UUID
  var conversationSessionId: UUID?
  var frameIndex: Int
  var frameWidth: Int
  var frameHeight: Int
  var uiImageOrientation: String
  var cgImageWidth: Int
  var cgImageHeight: Int
  var visionOrientationUsed: String
  var preferredFaceCount: Int
  var sweepFaceCountsJson: String
  var selectedOrientation: String?
  var selectedFaceCount: Int
  var createdAt: Date
}

struct TranscriptChunk: Identifiable, Codable, Equatable {
  let id: UUID
  var appRunId: UUID
  var conversationSessionId: UUID
  var personId: UUID?
  var activeIdentityState: String
  var text: String
  var isFinal: Bool
  var startedAt: Date?
  var endedAt: Date?
  var transcriptUpdatedAt: Date
  var source: String
  var createdAt: Date
}

struct TranscriptAttribution: Codable, Equatable {
  var personId: UUID?
  var displayName: String?
  var confidence: Float
  var state: String
  var sourceEvidence: String
}

struct IdentityMatchEvent: Identifiable, Codable, Equatable {
  let id: UUID
  var appRunId: UUID
  var conversationSessionId: UUID?
  var frameNumber: UInt64?
  var detectedFaceCount: Int
  var cropQualityTier: String?
  var embeddingModelName: String?
  var embeddingModelVersion: String?
  var candidatePersonId: UUID?
  var cosineSimilarity: Double
  var l2Distance: Double?
  var threshold: Double
  var rollingWindowSize: Int
  var rollingConfirmCount: Int
  var decision: String
  var rollingConfirmationState: String?
  var createdAt: Date
}

struct PipelineContext: Codable, Equatable, Sendable {
  var appRunId: UUID
  var conversationSessionId: UUID?
  var datDeviceId: String?

  var logPrefix: String {
    "appRun=\(appRunId.uuidString) session=\(conversationSessionId?.uuidString ?? "none")"
  }
}

struct RunSessionSnapshot: Equatable {
  var appRunId: UUID?
  var conversationSessionId: UUID?
  var detectedFacesThisSession: Int
  var acceptedFaceCropsThisSession: Int
  var embeddingsSavedThisSession: Int
  var transcriptChunksSavedThisSession: Int

  var appRunShortText: String { appRunId?.shortLogID ?? "none" }
  var conversationShortText: String { conversationSessionId?.shortLogID ?? "none" }
}

struct ActiveIdentityState {
  enum State: String {
    case none
    case noFace
    case unknown
    case possible
    case confirmed
    case ambiguous
  }

  var personId: UUID?
  var displayName: String?
  var confidence: Float
  var state: State
  var confirmedAt: Date?
  var lastSeenAt: Date?

  static let none = ActiveIdentityState(
    personId: nil,
    displayName: nil,
    confidence: 0,
    state: .none,
    confirmedAt: nil,
    lastSeenAt: nil
  )
}

struct EnrollmentCandidateSnapshot {
  let id: UUID
  let kind: String
  let frameSequence: UInt64
  let timestamp: Date
  let cropImage: UIImage
  let alignedCropImage: UIImage
  let thumbnailImage: UIImage
  let cropSize: CGSize
  let sourceImageSize: CGSize
  let qualityScore: Float?
  let qualityTier: FaceQualityTier
  let acceptedForEnrollment: Bool
  let embeddingStatus: String
  var savedImagePath: String?

  var summaryText: String {
    let quality = qualityScore.map { String(format: "%.2f", $0) } ?? "nil"
    let status = acceptedForEnrollment ? "enrollment-ready" : "image-only"
    return "\(kind) | frame \(frameSequence) | crop \(Int(cropSize.width))x\(Int(cropSize.height)) | q \(quality) | \(qualityTier.rawValue) | \(status) | \(embeddingStatus)"
  }
}

struct CapturedFaceSampleSnapshot: Identifiable {
  let id: UUID
  let groupId: UUID
  let frameSequence: UInt64
  let timestamp: Date
  let thumbnailImage: UIImage
  let cropImage: UIImage
  let cropSize: CGSize
  let sourceImageSize: CGSize
  let qualityScore: Float?
  let qualityTier: FaceQualityTier
  let rawFaceWidth: Int
  let rawFaceHeight: Int
  let faceBoxPixels: CGRect
  let embeddingRecords: [FaceEmbeddingRecord]
  let embeddingStatus: String

  var embeddingRecord: FaceEmbeddingRecord? {
    embeddingRecords.first
  }
}

struct CapturedFaceGroupSnapshot: Identifiable {
  let id: UUID
  let bestThumbnailImage: UIImage?
  let sampleCount: Int
  let embeddingCount: Int
  let qualitySummary: String
  let status: String
  let recognizedPersonId: UUID?
  let recognizedPersonName: String?

  var isAlreadyRecognized: Bool { recognizedPersonId != nil }
}

struct FaceEmbeddingDebugMetric: Equatable {
  let sourceLabel: String
  let modelName: String
  let modelSource: String
  let dimension: Int
  let latencyMS: Double
  let bestSimilarity: Float
  let decisionText: String
  let compatibleSampleCount: Int
  let compatibleAverageCount: Int
  let selectedForRecognition: Bool
}

struct IdentityProcessingResult {
  var activeIdentity: ActiveIdentityState
  var pendingEnrollmentFacePreview: UIImage?
  var lastEnrollmentCandidatePreview: UIImage?
  var currentRecognitionFacePreview: UIImage?
  var hasLastEnrollmentCandidate: Bool
  var lastEnrollmentCandidateSummary: String
  var modelStatusText: String
  var isUnknownPersonVisible: Bool
  var summary: String
  var profiles: [PersonProfile]
  var faceCandidateCount: Int
  var qualityPassCount: Int
  var embeddingGenerated: Bool
  var matchDecisionText: String
  var embeddingLatencyMS: Double
  var embeddingMetrics: [FaceEmbeddingDebugMetric]
  var alignmentRejectedCount: Int
  var pendingEnrollmentAcceptedSamples: Int
  var pendingEnrollmentRequiredSamples: Int
  var pendingEnrollmentRejectedSamples: Int
  var enrollmentStatusText: String
  var capturedFaceGroups: [CapturedFaceGroupSnapshot]
  var streamEndedReviewText: String
  var calibrationModeText: String
  var calibrationSampleCountText: String
  var calibrationSummaryText: String
  var canRecordCalibrationLabel: Bool
  var runSessionSnapshot: RunSessionSnapshot?
}

struct CodableCGRect: Codable, Equatable {
  var x: CGFloat
  var y: CGFloat
  var width: CGFloat
  var height: CGFloat

  init(_ rect: CGRect) {
    x = rect.origin.x
    y = rect.origin.y
    width = rect.size.width
    height = rect.size.height
  }

  var cgRect: CGRect {
    CGRect(x: x, y: y, width: width, height: height)
  }
}

struct CodableCGSize: Codable, Equatable {
  var width: CGFloat
  var height: CGFloat

  init(_ size: CGSize) {
    width = size.width
    height = size.height
  }

  var cgSize: CGSize {
    CGSize(width: width, height: height)
  }
}

enum IdentityConfig {
  #if DEBUG
  static let enableVisionOrientationSweep = false
  static let enableFaceCropDebugSave = false
  static let enableFaceEmbeddings = true
  static let enableIdentityMatching = true
  static let useMockEmbeddingModel = ProcessInfo.processInfo.environment["BBOL_USE_DEBUG_FACE_EMBEDDING"] == "1"
    || ProcessInfo.processInfo.arguments.contains("--use-debug-face-embedding")
  #else
  static let enableVisionOrientationSweep = false
  static let enableFaceCropDebugSave = false
  static let enableFaceEmbeddings = true
  static let enableIdentityMatching = true
  static let useMockEmbeddingModel = false
  #endif
  static let enableFaceQualityFilter = true
  static let enableTranscriptAttachment = true
  static let allowLowQualityEmbeddingDebug = false

  static let identityProcessingFPS: TimeInterval = 3
  static let qualityConfig = FaceQualityConfig()
  static let minimumFaceWidthRatio: CGFloat = 0.04
  static let minimumFaceHeightRatio: CGFloat = 0.04
  static let minimumFaceBoxWidthPixels: CGFloat = qualityConfig.recognitionMinFacePixels
  static let minimumFaceBoxHeightPixels: CGFloat = qualityConfig.recognitionMinFacePixels
  static let minimumCropPixelSize: CGFloat = qualityConfig.recognitionMinFacePixels
  static let minimumFaceCaptureQuality: Float = qualityConfig.recognitionMinFaceCaptureQuality
  static let minimumEnrollmentFaceCaptureQuality: Float = qualityConfig.enrollmentMinFaceCaptureQuality
  static let minimumFaceAreaRatio: Float = 0.003
  static let thresholdConfig = IdentityThresholdConfig()
  static let strongMatchThreshold: Float = thresholdConfig.strongMatchThreshold
  static let weakMatchThreshold: Float = thresholdConfig.weakMatchThreshold
  static let matchMarginThreshold: Float = thresholdConfig.matchMarginThreshold
  static let maxYawAbsRadians: Float = 0.7
  static let maxPitchAbsRadians: Float = 0.7
  static let maxRollAbsRadians: Float = 0.7
  static let rollingWindowSeconds: TimeInterval = 4
  static let rollingWindowSize = thresholdConfig.rollingWindowSize
  static let requiredStrongMatches = thresholdConfig.requiredStrongMatches
  static let holdIdentitySeconds: TimeInterval = thresholdConfig.identityHoldSeconds
  static let unknownPromptStrongFrames = 3
  static let conversationIdleTimeout: TimeInterval = 60
  static let debugFaceCropLimit = 20
  static let saveDebugFaceCrops = enableFaceCropDebugSave
  static let minimumEnrollmentSamples = 3
  static let preferredEnrollmentSamples = 5
  static let faceCropHorizontalPaddingRatio: CGFloat = 0.50
  // Extra padding above the face (for hair/forehead) vs below (chin).
  // Vision's detection box often stops around the lower lip, so bottom needs extra room
  // to include the chin. Top still needs more for hair/forehead.
  static let faceCropTopPaddingRatio: CGFloat = 0.75
  static let faceCropBottomPaddingRatio: CGFloat = 0.60
  // Left/right padding stays symmetric.
  static let faceCropVerticalPaddingRatio: CGFloat = 1.55
  // Populated by FaceEmbeddingModels once the active model is configured.
  // FaceCropper reads this to size the aligned warp output without hardcoding dimensions.
  // Default matches AWS AdaFace/ArcFace-style 112x112 crops.
  static var activeEmbeddingModelInputSize: CGSize = CGSize(width: 112, height: 112)

  static var startupLogText: String {
    "minRawFacePixelsForDetection=\(Int(qualityConfig.minRawFacePixelsForDetection)) minRawFacePixelsForRecognition=\(Int(qualityConfig.minRawFacePixelsForRecognition)) minRawFacePixelsForEnrollment=\(Int(qualityConfig.minRawFacePixelsForEnrollment)) minCropPixelsForRecognition=\(Int(qualityConfig.minCropPixelsForRecognition)) minCropPixelsForEnrollment=\(Int(qualityConfig.minCropPixelsForEnrollment)) minRecognitionQuality=\(String(format: "%.2f", qualityConfig.minRecognitionQuality)) minEnrollmentQuality=\(String(format: "%.2f", qualityConfig.minEnrollmentQuality)) faceCropHorizontalPaddingRatio=\(String(format: "%.2f", faceCropHorizontalPaddingRatio)) faceCropVerticalPaddingRatio=\(String(format: "%.2f", faceCropVerticalPaddingRatio)) weakMatchThreshold=\(String(format: "%.2f", weakMatchThreshold)) strongMatchThreshold=\(String(format: "%.2f", strongMatchThreshold)) matchMarginThreshold=\(String(format: "%.2f", matchMarginThreshold)) rollingWindowSize=\(rollingWindowSize) requiredStrongMatches=\(requiredStrongMatches) identityHoldSeconds=\(String(format: "%.1f", holdIdentitySeconds)) allowLowQualityEmbeddingDebug=\(allowLowQualityEmbeddingDebug)"
  }
}

struct IdentityThresholdConfig: Equatable {
  var weakMatchThreshold: Float = 0.60
  var strongMatchThreshold: Float = 0.70
  var matchMarginThreshold: Float = 0.05
  var rollingWindowSize: Int = 8
  var requiredStrongMatches: Int = 3
  var identityHoldSeconds: TimeInterval = 2
}

enum FaceCalibrationMode: String, Codable, Equatable {
  case samePerson
  case differentPerson

  var displayText: String {
    switch self {
    case .samePerson:
      return "same person"
    case .differentPerson:
      return "different person"
    }
  }
}

enum CalibrationLabelSource: String, Codable, Equatable {
  case userTap
  case automatic
  case unknown
}

struct FaceCalibrationSample: Codable, Equatable {
  let mode: FaceCalibrationMode
  let source: CalibrationLabelSource
  let profileLabel: String
  let score: Float?
  let secondBestScore: Float?
  let margin: Float?
  let threshold: Float
  let decision: String
  let rawFaceWidth: Int?
  let rawFaceHeight: Int?
  let cropWidth: Int?
  let cropHeight: Int?
  let quality: Float?
  let brightness: Float?
  let blur: Float?
  let acceptedForRecognition: Bool
  let acceptedForEnrollment: Bool
  let rejectionReason: String?
  let createdAt: Date
}

struct FaceCalibrationSummary: Equatable {
  let samePersonCount: Int
  let differentPersonCount: Int
  let sameMean: Float?
  let sameP10: Float?
  let sameP50: Float?
  let sameP90: Float?
  let differentMean: Float?
  let differentP90: Float?
  let recommendedWeak: Float
  let recommendedStrong: Float
  let recommendedMargin: Float

  init(
    samePersonCount: Int,
    differentPersonCount: Int,
    sameMean: Float?,
    sameP10: Float?,
    sameP50: Float?,
    sameP90: Float?,
    differentMean: Float?,
    differentP90: Float?,
    recommendedWeak: Float,
    recommendedStrong: Float,
    recommendedMargin: Float
  ) {
    self.samePersonCount = samePersonCount
    self.differentPersonCount = differentPersonCount
    self.sameMean = sameMean
    self.sameP10 = sameP10
    self.sameP50 = sameP50
    self.sameP90 = sameP90
    self.differentMean = differentMean
    self.differentP90 = differentP90
    self.recommendedWeak = recommendedWeak
    self.recommendedStrong = recommendedStrong
    self.recommendedMargin = recommendedMargin
  }

  static let empty = FaceCalibrationSummary(
    samePersonCount: 0,
    differentPersonCount: 0,
    sameMean: nil,
    sameP10: nil,
    sameP50: nil,
    sameP90: nil,
    differentMean: nil,
    differentP90: nil,
    recommendedWeak: IdentityConfig.weakMatchThreshold,
    recommendedStrong: IdentityConfig.strongMatchThreshold,
    recommendedMargin: IdentityConfig.matchMarginThreshold
  )

  init(samples: [FaceCalibrationSample]) {
    let sameScores = samples.filter { $0.mode == .samePerson }.compactMap(\.score).sorted()
    let differentScores = samples.filter { $0.mode == .differentPerson }.compactMap(\.score).sorted()
    samePersonCount = sameScores.count
    differentPersonCount = differentScores.count
    sameMean = Self.mean(sameScores)
    sameP10 = Self.percentile(sameScores, percentile: 0.10)
    sameP50 = Self.percentile(sameScores, percentile: 0.50)
    sameP90 = Self.percentile(sameScores, percentile: 0.90)
    differentMean = Self.mean(differentScores)
    differentP90 = Self.percentile(differentScores, percentile: 0.90)

    let defaultWeak = IdentityConfig.weakMatchThreshold
    let defaultStrong = IdentityConfig.strongMatchThreshold
    let defaultMargin = IdentityConfig.matchMarginThreshold
    if let sameP10 = sameP10, let differentP90 = differentP90 {
      let midpoint = (sameP10 + differentP90) / 2
      recommendedStrong = Self.clamp(midpoint, min: 0.55, max: 0.85)
      recommendedWeak = Self.clamp(min(recommendedStrong - 0.05, differentP90 + 0.02), min: 0.45, max: recommendedStrong)
      let separation = sameP10 - differentP90
      recommendedMargin = Self.clamp(max(defaultMargin, separation / 2), min: defaultMargin, max: 0.15)
    } else if let sameP10 = sameP10 {
      recommendedStrong = Self.clamp(sameP10 - 0.03, min: 0.55, max: 0.85)
      recommendedWeak = Self.clamp(recommendedStrong - 0.07, min: 0.45, max: recommendedStrong)
      recommendedMargin = defaultMargin
    } else if let differentP90 = differentP90 {
      recommendedStrong = Self.clamp(differentP90 + 0.08, min: defaultStrong, max: 0.85)
      recommendedWeak = Self.clamp(recommendedStrong - 0.07, min: defaultWeak, max: recommendedStrong)
      recommendedMargin = defaultMargin
    } else {
      recommendedWeak = defaultWeak
      recommendedStrong = defaultStrong
      recommendedMargin = defaultMargin
    }
  }

  private static func mean(_ values: [Float]) -> Float? {
    guard !values.isEmpty else { return nil }
    return values.reduce(0, +) / Float(values.count)
  }

  private static func percentile(_ sortedValues: [Float], percentile: Float) -> Float? {
    guard !sortedValues.isEmpty else { return nil }
    guard sortedValues.count > 1 else { return sortedValues[0] }
    let clamped = clamp(percentile, min: 0, max: 1)
    let position = clamped * Float(sortedValues.count - 1)
    let lower = Int(floor(position))
    let upper = Int(ceil(position))
    if lower == upper {
      return sortedValues[lower]
    }
    let fraction = position - Float(lower)
    return sortedValues[lower] + (sortedValues[upper] - sortedValues[lower]) * fraction
  }

  private static func clamp(_ value: Float, min: Float, max: Float) -> Float {
    Swift.max(min, Swift.min(max, value))
  }

  var logText: String {
    "samePersonCount=\(samePersonCount) differentPersonCount=\(differentPersonCount) sameMean=\(Self.format(sameMean)) sameP10=\(Self.format(sameP10)) sameP50=\(Self.format(sameP50)) sameP90=\(Self.format(sameP90)) differentMean=\(Self.format(differentMean)) differentP90=\(Self.format(differentP90)) recommendedWeak=\(String(format: "%.3f", recommendedWeak)) recommendedStrong=\(String(format: "%.3f", recommendedStrong)) recommendedMargin=\(String(format: "%.3f", recommendedMargin))"
  }

  var displayText: String {
    "same \(samePersonCount), different \(differentPersonCount) | strong \(String(format: "%.2f", recommendedStrong)), weak \(String(format: "%.2f", recommendedWeak)), margin \(String(format: "%.2f", recommendedMargin))"
  }

  private static func format(_ value: Float?) -> String {
    value.map { String(format: "%.3f", $0) } ?? "nil"
  }
}

struct PersonInteractionHour: Identifiable {
  var hour: Date
  var faceDetectionCount: Int
  var transcripts: [TranscriptChunk]
  var glassesInteractions: [GlassesDisplayInteractionEvent] = []
  var id: Date { hour }
}

struct PersonInteractionDay: Identifiable {
  var day: Date
  var hours: [PersonInteractionHour]
  var id: Date { day }
  var totalFaceDetections: Int { hours.reduce(0) { $0 + $1.faceDetectionCount } }
  var totalTranscripts: Int { hours.reduce(0) { $0 + $1.transcripts.count } }
  var totalGlassesInteractions: Int { hours.reduce(0) { $0 + $1.glassesInteractions.count } }
}

struct GlassesDisplayInteractionEvent: Identifiable, Hashable, Codable {
  let id: UUID
  var appRunId: UUID
  var conversationSessionId: UUID?
  var personId: UUID?
  var displayName: String?
  var cardTitle: String
  var cardText: String
  var action: String
  var source: String
  var createdAt: Date

  init(
    id: UUID = UUID(),
    appRunId: UUID,
    conversationSessionId: UUID? = nil,
    personId: UUID? = nil,
    displayName: String? = nil,
    cardTitle: String,
    cardText: String,
    action: GlassesDisplayAction,
    source: String,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.appRunId = appRunId
    self.conversationSessionId = conversationSessionId
    self.personId = personId
    self.displayName = displayName
    self.cardTitle = cardTitle
    self.cardText = cardText
    self.action = action.rawValue
    self.source = source
    self.createdAt = createdAt
  }

  var actionKind: GlassesDisplayAction? {
    GlassesDisplayAction(rawValue: action)
  }

  var actionLabel: String {
    actionKind?.eventTitle ?? action
  }

  var displaySummary: String {
    let trimmed = cardText
      .replacingOccurrences(of: "\n", with: " ")
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return cardTitle
    }
    return String(trimmed.prefix(140))
  }
}

struct ConversationTranscriptLine: Identifiable {
  var chunk: TranscriptChunk
  var speakerName: String

  var id: UUID { chunk.id }
}

struct PersonConversationTranscript: Identifiable {
  var conversationSessionId: UUID
  var startedAt: Date
  var endedAt: Date?
  var lines: [ConversationTranscriptLine]
  var sceneContexts: [SceneContextRecord] = []

  var id: UUID { conversationSessionId }
}

struct PersonDictionaryEntry: Identifiable, Hashable {
  let profile: PersonProfile
  var thumbnail: UIImage?
  var transcripts: [TranscriptChunk]
  var interactionDays: [PersonInteractionDay]
  var embeddingImages: [UIImage]
  var conversationTranscripts: [PersonConversationTranscript] = []
  var sceneContexts: [SceneContextRecord] = []
  var glassesDisplayInteractions: [GlassesDisplayInteractionEvent] = []

  var id: UUID { profile.id }
  var displayName: String { profile.displayName }
  var lastSeen: Date? { profile.lastSeenAt }

  static func == (lhs: PersonDictionaryEntry, rhs: PersonDictionaryEntry) -> Bool {
    lhs.profile.id == rhs.profile.id
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(profile.id)
  }
}

extension Optional where Wrapped == PipelineContext {
  var logPrefix: String {
    self?.logPrefix ?? "appRun=none session=none"
  }
}

extension UUID {
  var shortLogID: String {
    String(uuidString.prefix(8))
  }
}
