import Foundation

// L2-normalized embedding vector produced by the speaker embedding model.
struct VoiceEmbedding: Codable, Equatable {
  let vector: [Float]
  let dimension: Int
  let modelName: String
  let modelVersion: String
  let preprocessingVersion: String
  let embeddingRuntime: String

  init(
    vector: [Float],
    modelName: String,
    modelVersion: String,
    preprocessingVersion: String,
    embeddingRuntime: String = SpeakerEmbeddingRuntime.localCoreML
  ) {
    self.vector = vector
    self.dimension = vector.count
    self.modelName = modelName
    self.modelVersion = modelVersion
    self.preprocessingVersion = preprocessingVersion
    self.embeddingRuntime = embeddingRuntime
  }

  private enum CodingKeys: String, CodingKey {
    case vector
    case dimension
    case modelName
    case modelVersion
    case preprocessingVersion
    case embeddingRuntime
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    vector = try container.decode([Float].self, forKey: .vector)
    dimension = try container.decodeIfPresent(Int.self, forKey: .dimension) ?? vector.count
    modelName = try container.decode(String.self, forKey: .modelName)
    modelVersion = try container.decode(String.self, forKey: .modelVersion)
    preprocessingVersion = try container.decode(String.self, forKey: .preprocessingVersion)
    embeddingRuntime = try container.decodeIfPresent(String.self, forKey: .embeddingRuntime)
      ?? SpeakerEmbeddingRuntime.localCoreML
  }
}

enum SpeakerEmbeddingRuntime {
  static let localCoreML = "coreml-titanet"
  static let awsTitaNet = "aws-titanet"
  static let missing = "none"
}

struct SpeakerEmbeddingRecord: Codable {
  var id: UUID
  var personId: UUID?
  var vector: [Float]
  var dimension: Int
  var modelName: String
  var modelVersion: String
  var preprocessingVersion: String
  var embeddingRuntime: String?
  var recordedAt: Date

  init(embedding: VoiceEmbedding, personId: UUID? = nil) {
    id = UUID()
    self.personId = personId
    vector = embedding.vector
    dimension = embedding.dimension
    modelName = embedding.modelName
    modelVersion = embedding.modelVersion
    preprocessingVersion = embedding.preprocessingVersion
    embeddingRuntime = embedding.embeddingRuntime
    recordedAt = Date()
  }
}

struct SpeakerAveragedEmbedding: Codable {
  var id: UUID
  var personId: UUID
  var name: String?
  var averagedVector: [Float]
  var vectorDimension: Int
  var sampleCount: Int
  var modelName: String
  var modelVersion: String
  var preprocessingVersion: String
  var embeddingRuntime: String?
  var updatedAt: Date
}

struct SpeakerMatchResult {
  enum Decision { case known, ambiguous, unknown }

  let bestPersonId: UUID?
  let bestSimilarity: Float
  let secondBestSimilarity: Float?
  let margin: Float?
  let decision: Decision
  let matchedEmbeddingId: UUID?
  let reason: String?
}

struct SpeakerSimilarityDiagnostic {
  let label: String
  let matchResult: SpeakerMatchResult?
  let error: String?
  let embedding: VoiceEmbedding?
  let latencyMS: Double?

  init(
    label: String,
    matchResult: SpeakerMatchResult?,
    error: String?,
    embedding: VoiceEmbedding?,
    latencyMS: Double? = nil
  ) {
    self.label = label
    self.matchResult = matchResult
    self.error = error
    self.embedding = embedding
    self.latencyMS = latencyMS
  }

  var bestSimilarity: Float? {
    guard let matchResult, matchResult.reason != "noEnrollment", matchResult.reason != "noCompatibleEnrollment" else {
      return nil
    }
    return matchResult.bestSimilarity
  }

  var statusText: String {
    if let bestSimilarity {
      return "\(label): \(String(format: "%.3f", Double(bestSimilarity)))"
    }
    if let reason = matchResult?.reason {
      switch reason {
      case "noEnrollment":
        return "\(label): no enrollment"
      case "noCompatibleEnrollment":
        return "\(label): incompatible enrollment"
      default:
        return "\(label): \(reason)"
      }
    }
    if let error, !error.isEmpty {
      return "\(label): \(error)"
    }
    return "\(label): pending"
  }
}

struct SpeakerDiarizationSegmentSnapshot: Identifiable, Equatable {
  let id: UUID
  let startAt: Date
  let endAt: Date
  let speakerId: UUID
  let speakerLabel: String
  let personId: UUID?
  let displayName: String?
  let confidence: Float
  let source: String

  var speakerName: String {
    displayName ?? speakerLabel
  }
}

struct CapturedVoiceClipSnapshot: Identifiable, Equatable {
  let id: UUID
  let durationSeconds: Double
  let embeddingDimension: Int?
  let createdAt: Date
  let status: String
  let speakerLabel: String?
  let mergedSegmentCount: Int
  let bestSimilarity: Float?
  let recognizedPersonId: UUID?
  let recognizedPersonName: String?

  var isAlreadyRecognized: Bool {
    recognizedPersonId != nil
  }

  var summaryText: String {
    let dimText = embeddingDimension.map { "dim \($0)" } ?? "no embedding"
    let mergeText = mergedSegmentCount > 1 ? ", \(mergedSegmentCount) merged clips" : ""
    let similarityText = bestSimilarity.map { String(format: ", best %.2f", Double($0)) } ?? ""
    let labelText = speakerLabel.map { "\($0), " } ?? ""
    return String(format: "%@%.1f s, %@%@%@", labelText, Double(durationSeconds), dimText, mergeText, similarityText)
  }
}

struct SpeakerEnrollmentSaveResult: Equatable {
  let saved: Bool
  let message: String
  let personId: UUID?
  let removedDuplicateClipCount: Int
  // True when a usable voice embedding could not be created yet (e.g. the AWS
  // speaker worker was unavailable) but the clip was persisted and the
  // enrollment is queued to finish automatically once the service is reachable.
  // `pending` is mutually exclusive with `saved`: a pending enrollment is NOT
  // complete and must not be treated as a usable speaker profile.
  let pending: Bool

  static func success(personId: UUID, name: String, removedDuplicateClipCount: Int) -> SpeakerEnrollmentSaveResult {
    SpeakerEnrollmentSaveResult(
      saved: true,
      message: "Saved voice: \(name)",
      personId: personId,
      removedDuplicateClipCount: removedDuplicateClipCount,
      pending: false
    )
  }

  static func failure(_ message: String, personId: UUID? = nil) -> SpeakerEnrollmentSaveResult {
    SpeakerEnrollmentSaveResult(
      saved: false,
      message: message,
      personId: personId,
      removedDuplicateClipCount: 0,
      pending: false
    )
  }

  static func pendingEmbedding(_ message: String, personId: UUID) -> SpeakerEnrollmentSaveResult {
    SpeakerEnrollmentSaveResult(
      saved: false,
      message: message,
      personId: personId,
      removedDuplicateClipCount: 0,
      pending: true
    )
  }
}

struct WearerVoiceProfileSnapshot: Equatable {
  let isEnrolled: Bool
  let isRecording: Bool
  let recordingSeconds: Double
  let sampleCount: Int
  let centroidCount: Int
  let durationSeconds: Double
  let consistencyScore: Float?
  let updatedAt: Date?
  let embeddingDimension: Int?
  let promptText: String
  let promptIndex: Int
  let promptCount: Int
  let completedPromptCount: Int

  static let empty = WearerVoiceProfileSnapshot(
    isEnrolled: false,
    isRecording: false,
    recordingSeconds: 0,
    sampleCount: 0,
    centroidCount: 0,
    durationSeconds: 0,
    consistencyScore: nil,
    updatedAt: nil,
    embeddingDimension: nil,
    promptText: SpeakerIdentityConfig.wearerVoicePrompts.first ?? "",
    promptIndex: 0,
    promptCount: SpeakerIdentityConfig.wearerVoicePrompts.count,
    completedPromptCount: 0
  )

  var hasRequiredPromptCoverage: Bool {
    completedPromptCount >= SpeakerIdentityConfig.wearerVoiceMinCompletedPrompts
  }

  var hasRequiredDuration: Bool {
    recordingSeconds >= SpeakerIdentityConfig.wearerVoiceMinEnrollmentSeconds
  }

  var canSaveRecording: Bool {
    isRecording && hasRequiredPromptCoverage && hasRequiredDuration
  }

  var summaryText: String {
    if isRecording {
      return String(
        format: "Recording %.1f s / %.0f s total, prompts %d/%d",
        Double(recordingSeconds),
        Double(SpeakerIdentityConfig.wearerVoiceMinEnrollmentSeconds),
        completedPromptCount,
        SpeakerIdentityConfig.wearerVoiceMinCompletedPrompts
      )
    }
    guard isEnrolled else {
      return String(format: "Not enrolled. Record %.0f-%.0f s total while streaming.",
                    Double(SpeakerIdentityConfig.wearerVoiceMinEnrollmentSeconds),
                    Double(SpeakerIdentityConfig.wearerVoiceMaxEnrollmentSeconds))
    }
    let consistency = consistencyScore.map { String(format: ", consistency %.2f", Double($0)) } ?? ""
    let dimText = embeddingDimension.map { ", dim \($0)" } ?? ""
    return "Enrolled with \(sampleCount) voice windows, \(centroidCount) centroids\(consistency)\(dimText)"
  }
}

struct WearerVoiceEnrollmentResult: Equatable {
  let saved: Bool
  let message: String
  let acceptedWindowCount: Int
  let rejectedWindowCount: Int
  let consistencyScore: Float?

  static func success(acceptedWindowCount: Int, rejectedWindowCount: Int, consistencyScore: Float) -> WearerVoiceEnrollmentResult {
    WearerVoiceEnrollmentResult(
      saved: true,
      message: String(format: "Saved my voice: %d windows, consistency %.2f", acceptedWindowCount, Double(consistencyScore)),
      acceptedWindowCount: acceptedWindowCount,
      rejectedWindowCount: rejectedWindowCount,
      consistencyScore: consistencyScore
    )
  }

  static func failure(_ message: String, acceptedWindowCount: Int = 0, rejectedWindowCount: Int = 0, consistencyScore: Float? = nil) -> WearerVoiceEnrollmentResult {
    WearerVoiceEnrollmentResult(
      saved: false,
      message: message,
      acceptedWindowCount: acceptedWindowCount,
      rejectedWindowCount: rejectedWindowCount,
      consistencyScore: consistencyScore
    )
  }
}

struct SpeakerIdentityState {
  enum Phase: String { case none, possible, ambiguous, confirmed, unknown }

  let personId: UUID?
  let displayName: String?
  let confidence: Float
  let phase: Phase
  let confirmedAt: Date?
  let lastMatchAt: Date?

  static let idle = SpeakerIdentityState(
    personId: nil, displayName: nil, confidence: 0,
    phase: .none, confirmedAt: nil, lastMatchAt: nil
  )
}

struct SpeakerProcessingResult {
  let activeIdentity: SpeakerIdentityState
  let vadDecision: String
  let accumulatedSpeechSeconds: Double
  let embeddingTriggered: Bool
  let matchResult: SpeakerMatchResult?
  let iPhoneSimilarity: SpeakerSimilarityDiagnostic?
  let workerSimilarity: SpeakerSimilarityDiagnostic?
  let wearerSimilarity: SpeakerMatchResult?

  init(
    activeIdentity: SpeakerIdentityState,
    vadDecision: String,
    accumulatedSpeechSeconds: Double,
    embeddingTriggered: Bool,
    matchResult: SpeakerMatchResult?,
    iPhoneSimilarity: SpeakerSimilarityDiagnostic? = nil,
    workerSimilarity: SpeakerSimilarityDiagnostic? = nil,
    wearerSimilarity: SpeakerMatchResult? = nil
  ) {
    self.activeIdentity = activeIdentity
    self.vadDecision = vadDecision
    self.accumulatedSpeechSeconds = accumulatedSpeechSeconds
    self.embeddingTriggered = embeddingTriggered
    self.matchResult = matchResult
    self.iPhoneSimilarity = iPhoneSimilarity
    self.workerSimilarity = workerSimilarity
    self.wearerSimilarity = wearerSimilarity
  }
}

// Single source of truth for all speaker identity thresholds.
enum SpeakerIdentityConfig {
  static let strongMatchThreshold: Float = 0.75
  static let weakMatchThreshold: Float = 0.65
  static let matchMarginThreshold: Float = 0.05
  static let diarizationSameSpeakerThreshold: Float = 0.62
  static let diarizationUpdateThreshold: Float = 0.70
  static let diarizationCentroidAlpha: Float = 0.88
  static let capturedVoiceSameSpeakerThreshold: Float = 0.70
  static let capturedVoiceDefiniteSameSpeakerThreshold: Float = 0.82
  // TitaNet calibration showed clear separation in local clips; confirm a speaker
  // as soon as one margin-valid match reaches the strong threshold.
  static let requiredStrongMatches = 1
  static let rollingWindowSeconds: TimeInterval = 6.0
  static let rollingWindowSize = 20
  static let holdIdentitySeconds: TimeInterval = 3.0

  // VAD: root-mean-square energy threshold below which audio is classified as silence.
  // Meta glasses mic can sit around ~0.00003 RMS with background/static noise.
  // 0.00005 rejects that floor while keeping quiet speech observed around ~0.0001+.
  static let vadEnergyThresholdRMS: Float = 0.00005

  // Accumulate this many seconds of VAD-gated speech before triggering an embedding.
  // The Core ML model consumes 3-second windows; preview clips are capped at 5s.
  static let minSpeechSecondsForEmbedding: Double = 3.0
  // Shorter utterances are padded for diarization only. Enrollment still requires
  // minSpeechSecondsForEmbedding so saved identity profiles stay cleaner.
  static let minSpeechSecondsForDiarization: Double = 1.5
  // Discard oldest speech once the buffer exceeds this limit.
  static let maxSpeechBufferSeconds: Double = 5.0
  // Silence window that flushes an in-progress utterance.
  static let silenceFlushSeconds: Double = 0.8
  // Rate-limit: minimum gap between successive live embedding runs. Keep this
  // conservative during DAT camera streaming; the iPhone already records the full
  // session for post-session diarization/enrollment.
  static let embeddingIntervalSeconds: TimeInterval = 2.0
  // Cloud/AWS speaker embeddings are higher-latency than local TitaNet, but the
  // live worker should still participate frequently while the toggle is on.
  static let cloudEmbeddingMinIntervalSeconds: TimeInterval = 2.0
  // All models and feature extraction operate at this sample rate.
  static let targetSampleRate: Double = 16_000
  // Samples in the 3-second embedding window fed to the model.
  static let embeddingWindowSamples: Int = 48_000
  // Samples in the 5-second speech region used to average multiple embeddings.
  static let embeddingAggregationSamples: Int = 80_000
  // Hop between overlapping 3-second windows inside the aggregation region.
  static let embeddingWindowHopSamples: Int = 16_000

  // Wearer voice profile: this profile is stored separately from people in the
  // dictionary and is used to filter the glasses wearer's own voice from review.
  static let wearerVoicePrompts = [
    "The quick brown fox jumps over the lazy dog.",
    "Today I am testing my smart glasses voice profile.",
    "Please identify my voice during conversations.",
    "My voice should be separated from people around me.",
    "This recording helps the glasses recognize the wearer."
  ]
  static let wearerVoiceMinCompletedPrompts = 3
  static let wearerVoiceMinEnrollmentSeconds: Double = 20.0
  static let wearerVoiceMaxEnrollmentSeconds: Double = 30.0
  static let wearerVoiceMinAcceptedWindows = 5
  static let wearerVoiceMinConsistency: Float = 0.72
  static let wearerVoiceMinWindowCentroidSimilarity: Float = 0.65
  static let wearerVoiceMatchThreshold: Float = 0.75
  static let wearerVoiceAutoUpdateThreshold: Float = 0.88
  static let wearerVoiceCentroidLimit = 6
}
