import Foundation

struct SceneContextSettings {
  private enum Keys {
    static let enabled = "sceneContext.enabled"
    static let locationEnabled = "sceneContext.locationEnabled"
  }

  static let defaultBaseURL = "https://dashscope-us.aliyuncs.com/compatible-mode/v1"
  static let defaultModel = "qwen3-vl-flash-us"
  static let defaultTextModel = "qwen3.5-flash"
  static let promptVersion = "scene-context-5w1h-v1"

  var enabled: Bool
  var locationEnabled: Bool
  var apiKey: String
  var baseURL: String
  var model: String
  var textModel: String

  static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> SceneContextSettings {
    let defaults = UserDefaults.standard
    let env = DotEnvFile.load()
      .merging(ProcessInfo.processInfo.environment) { _, new in new }
      .merging(environment) { _, new in new }
    let enabled = defaults.object(forKey: Keys.enabled) as? Bool
      ?? boolValue(env["DASHSCOPE_SCENE_CONTEXT_ENABLED"])
      ?? false
    let locationEnabled = defaults.object(forKey: Keys.locationEnabled) as? Bool
      ?? boolValue(env["DASHSCOPE_SCENE_CONTEXT_LOCATION_ENABLED"])
      ?? false
    return SceneContextSettings(
      enabled: enabled,
      locationEnabled: locationEnabled,
      apiKey: env["DASHSCOPE_API_KEY"] ?? env["ALIBABA_DASHSCOPE_API_KEY"] ?? "",
      baseURL: env["DASHSCOPE_BASE_URL"] ?? defaultBaseURL,
      model: env["DASHSCOPE_VL_MODEL"] ?? env["QWEN_VL_MODEL"] ?? defaultModel,
      textModel: env["DASHSCOPE_TEXT_MODEL"]
        ?? env["QWEN_TEXT_MODEL"]
        ?? env["DASHSCOPE_QA_MODEL"]
        ?? env["QWEN_QA_MODEL"]
        ?? defaultTextModel
    )
  }

  static func save(enabled: Bool, locationEnabled: Bool) {
    let defaults = UserDefaults.standard
    defaults.set(enabled, forKey: Keys.enabled)
    defaults.set(locationEnabled, forKey: Keys.locationEnabled)
  }

  private static func boolValue(_ value: String?) -> Bool? {
    guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
          !normalized.isEmpty else { return nil }
    if ["1", "true", "yes", "on"].contains(normalized) { return true }
    if ["0", "false", "no", "off"].contains(normalized) { return false }
    return nil
  }
}

enum ActivityModeTaxonomy: String, Codable, CaseIterable, Sendable {
  case entertainment
  case sport
  case study
  case social
  case commute
  case shopping
  case work
  case general
  case unknown
  case custom

  static func normalizedMode(_ value: String) -> String {
    let normalized = value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "-", with: " ")
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
    switch normalized {
    case "movie", "movies", "tv", "television", "watching movie", "watching a movie", "entertainment":
      return ActivityModeTaxonomy.entertainment.rawValue
    case "exercise", "exercising", "jogging", "running", "fitness", "sports", "sport":
      return ActivityModeTaxonomy.sport.rawValue
    case "reading", "studying", "school", "homework", "study":
      return ActivityModeTaxonomy.study.rawValue
    case "conversation", "conversational", "talking", "people", "person", "social":
      return ActivityModeTaxonomy.social.rawValue
    case "transit", "travel", "traveling", "travelling", "driving", "walking transit", "commuting", "commute":
      return ActivityModeTaxonomy.commute.rawValue
    case "shop", "shopping", "store", "retail":
      return ActivityModeTaxonomy.shopping.rawValue
    case "working", "office", "coding", "meeting", "work":
      return ActivityModeTaxonomy.work.rawValue
    case "unclear", "none", "general":
      return ActivityModeTaxonomy.general.rawValue
    case "unknown", "":
      return ActivityModeTaxonomy.unknown.rawValue
    default:
      if ActivityModeTaxonomy.allCases.contains(where: { $0 != .custom && $0.rawValue == normalized }) {
        return normalized
      }
      if containsAny(normalized, ["movie", "baseball", "game", "television", "video", "watching"]) {
        return ActivityModeTaxonomy.entertainment.rawValue
      }
      if containsAny(normalized, ["run", "jog", "exercise", "workout", "gym", "cycling", "sport"]) {
        return ActivityModeTaxonomy.sport.rawValue
      }
      if containsAny(normalized, ["study", "reading", "homework", "school", "class", "textbook"]) {
        return ActivityModeTaxonomy.study.rawValue
      }
      if containsAny(normalized, ["talk", "conversation", "meeting with", "social"]) {
        return ActivityModeTaxonomy.social.rawValue
      }
      if containsAny(normalized, ["driv", "train", "bus", "subway", "commut", "travel"]) {
        return ActivityModeTaxonomy.commute.rawValue
      }
      if containsAny(normalized, ["shop", "store", "checkout", "mall"]) {
        return ActivityModeTaxonomy.shopping.rawValue
      }
      if containsAny(normalized, ["work", "coding", "laptop", "computer", "office", "desk"]) {
        return ActivityModeTaxonomy.work.rawValue
      }
      return ActivityModeTaxonomy.unknown.rawValue
    }
  }

  private static func containsAny(_ value: String, _ fragments: [String]) -> Bool {
    fragments.contains { value.contains($0) }
  }

  static func displayName(for mode: String) -> String {
    let normalized = normalizedMode(mode)
    guard !normalized.isEmpty else { return "Unknown" }
    if let taxonomy = ActivityModeTaxonomy(rawValue: normalized) {
      switch taxonomy {
      case .entertainment: return "Entertainment"
      case .sport: return "Sport"
      case .study: return "Study"
      case .social: return "Social"
      case .commute: return "Commute"
      case .shopping: return "Shopping"
      case .work: return "Work"
      case .general: return "General"
      case .unknown: return "Unknown"
      case .custom: return "Custom"
      }
    }
    return normalized
      .split(separator: " ")
      .map { $0.prefix(1).uppercased() + $0.dropFirst() }
      .joined(separator: " ")
  }
}

struct ActivityModeClassification: Codable, Equatable, Sendable {
  var mode: String
  var specificActivity: String
  var confidence: Double
  var reason: String

  init(
    mode: String,
    specificActivity: String,
    confidence: Double,
    reason: String
  ) {
    self.mode = ActivityModeTaxonomy.normalizedMode(mode)
    self.specificActivity = specificActivity
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
    self.confidence = min(max(confidence, 0), 1)
    self.reason = reason
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
  }

  private enum CodingKeys: String, CodingKey {
    case mode
    case specificActivity = "specific_activity"
    case specificActivityCamel = "specificActivity"
    case confidence
    case reason
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let mode = try container.decode(String.self, forKey: .mode)
    let specificActivity = try container.decodeIfPresent(String.self, forKey: .specificActivity)
      ?? container.decodeIfPresent(String.self, forKey: .specificActivityCamel)
      ?? ""
    let confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
    let reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? ""
    self.init(
      mode: mode,
      specificActivity: specificActivity,
      confidence: confidence,
      reason: reason
    )
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(mode, forKey: .mode)
    try container.encode(specificActivity, forKey: .specificActivity)
    try container.encode(confidence, forKey: .confidence)
    try container.encode(reason, forKey: .reason)
  }

  var modeDisplayName: String {
    ActivityModeTaxonomy.displayName(for: mode)
  }

  var displayText: String {
    let specific = specificActivity.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !specific.isEmpty,
          ActivityModeTaxonomy.normalizedMode(specific) != ActivityModeTaxonomy.normalizedMode(mode),
          specific.lowercased() != modeDisplayName.lowercased() else {
      return modeDisplayName
    }
    return "\(modeDisplayName) - \(specific)"
  }

  static let unknown = ActivityModeClassification(
    mode: ActivityModeTaxonomy.unknown.rawValue,
    specificActivity: "",
    confidence: 0,
    reason: "No activity context has been classified yet."
  )
}

struct ActivityModeClassificationRequest: Equatable, Sendable {
  var transcriptText: String
  var sceneContexts: [SceneContextRecord]
  var recognizedPeople: [String]
  var detectedFaceCount: Int
  var identityEvidence: SceneContextIdentityEvidence?
  var locationLabel: String?
  var streamState: String
  var reason: String
}

struct ActivityModeEpisodeRecord: Identifiable, Codable, Equatable, Sendable {
  let id: UUID
  var appRunId: UUID
  var conversationSessionId: UUID?
  var mode: String
  var specificActivity: String
  var startedAt: Date
  var lastEvidenceAt: Date
  var endedAt: Date?
  var confidence: Double
  var reason: String
  var source: String
  var modelName: String
  var promptVersion: String
  var updatedAt: Date

  var isActive: Bool { endedAt == nil }
}

enum ActivityModeClassifier {
  static let promptVersion = "activity-mode-v1"
  static let minimumSwitchConfidence = 0.58
  static let minimumDifferentModeSwitchConfidence = 0.68
  static let minimumSpecificActivityConfidence = 0.88

  static func conservativeClassification(
    _ classification: ActivityModeClassification
  ) -> ActivityModeClassification {
    let broadMode = ActivityModeTaxonomy.normalizedMode(classification.mode)
    let permitsSpecificDetail = classification.confidence >= minimumSpecificActivityConfidence
      && broadMode != ActivityModeTaxonomy.general.rawValue
      && broadMode != ActivityModeTaxonomy.unknown.rawValue
    return ActivityModeClassification(
      mode: broadMode,
      specificActivity: permitsSpecificDetail ? classification.specificActivity : "",
      confidence: classification.confidence,
      reason: classification.reason
    )
  }

  static func shouldApply(
    current: ActivityModeClassification,
    candidate: ActivityModeClassification
  ) -> Bool {
    let currentMode = ActivityModeTaxonomy.normalizedMode(current.mode)
    let candidateMode = ActivityModeTaxonomy.normalizedMode(candidate.mode)
    if currentMode == ActivityModeTaxonomy.unknown.rawValue,
       candidateMode == ActivityModeTaxonomy.general.rawValue,
       candidate.confidence >= 0.45 {
      return true
    }
    guard candidate.confidence >= minimumSwitchConfidence else { return false }
    if currentMode == ActivityModeTaxonomy.unknown.rawValue || currentMode == ActivityModeTaxonomy.general.rawValue {
      return true
    }
    if currentMode == candidateMode {
      return true
    }
    return candidate.confidence >= minimumDifferentModeSwitchConfidence
  }

  static func fallbackClassification(
    for request: ActivityModeClassificationRequest
  ) -> ActivityModeClassification {
    let text = [
      request.transcriptText,
      request.sceneContexts.map { "\($0.summary) \($0.what) \($0.whereText) \($0.how)" }.joined(separator: " "),
      request.identityEvidence?.sourceSummary ?? ""
    ]
    .joined(separator: " ")
    .lowercased()

    let recognizedPeople = request.recognizedPeople.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    if containsAny(text, ["movie", "tv", "show", "screen", "video", "watching"]) {
      return ActivityModeClassification(mode: "entertainment", specificActivity: "watching movie", confidence: 0.64, reason: "Fallback matched entertainment scene or transcript cues.")
    }
    if containsAny(text, ["jogging", "running", "run", "workout", "exercise", "gym", "bike", "cycling"]) {
      return ActivityModeClassification(mode: "sport", specificActivity: "exercising", confidence: 0.64, reason: "Fallback matched exercise cues.")
    }
    if containsAny(text, ["studying", "reading", "book", "textbook", "laptop", "homework", "class", "school"]) {
      return ActivityModeClassification(mode: "study", specificActivity: "studying", confidence: 0.62, reason: "Fallback matched study or work surface cues.")
    }
    if containsAny(text, ["driving", "bus", "train", "subway", "commute", "commuting", "station", "traveling", "travelling"]) {
      return ActivityModeClassification(mode: "commute", specificActivity: "traveling", confidence: 0.62, reason: "Fallback matched travel cues.")
    }
    if containsAny(text, ["store", "shopping", "checkout", "shelf", "mall", "cart"]) {
      return ActivityModeClassification(mode: "shopping", specificActivity: "shopping", confidence: 0.62, reason: "Fallback matched shopping cues.")
    }
    if !recognizedPeople.isEmpty
      || request.detectedFaceCount > 0
      || containsAny(text, ["talking", "conversation", "said", "asked", "speaker"]) {
      return ActivityModeClassification(mode: "social", specificActivity: "talking with someone", confidence: 0.6, reason: "Fallback matched people, face, or transcript cues.")
    }
    return ActivityModeClassification(mode: "general", specificActivity: "looking around", confidence: 0.5, reason: "Fallback found no specific high-confidence activity cue.")
  }

  private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
    needles.contains { text.contains($0) }
  }
}

struct ActivityModeStabilizationResult: Equatable, Sendable {
  let classification: ActivityModeClassification
  let shouldApply: Bool
  let shouldSendDisplay: Bool
  let reason: String
  let matchingObservationCount: Int
}

struct ActivityModeStabilizer: Sendable {
  private static let requiredMatchingObservations = 2
  private static let minimumStableSwitchConfidence = 0.75

  private var pendingMode: String?
  private var pendingSpecificActivity: String?
  private var matchingObservationCount = 0

  mutating func reset() {
    pendingMode = nil
    pendingSpecificActivity = nil
    matchingObservationCount = 0
  }

  mutating func evaluate(
    current: ActivityModeClassification,
    candidate rawCandidate: ActivityModeClassification
  ) -> ActivityModeStabilizationResult {
    let candidate = ActivityModeClassifier.conservativeClassification(rawCandidate)
    let currentMode = ActivityModeTaxonomy.normalizedMode(current.mode)
    let candidateMode = ActivityModeTaxonomy.normalizedMode(candidate.mode)

    guard ActivityModeClassifier.shouldApply(current: current, candidate: candidate) else {
      reset()
      return result(candidate, apply: false, display: false, reason: "confidenceGate", count: 0)
    }

    if currentMode == candidateMode {
      guard !candidate.specificActivity.isEmpty,
            candidate.specificActivity != current.specificActivity else {
        reset()
        return result(candidate, apply: false, display: false, reason: "broadModeUnchanged", count: 0)
      }
      let count = recordObservation(mode: candidateMode, specificActivity: candidate.specificActivity)
      let stable = count >= Self.requiredMatchingObservations
      return result(
        candidate,
        apply: stable,
        display: false,
        reason: stable ? "specificDetailStable" : "specificDetailPending",
        count: count
      )
    }

    let currentIsUnclassified = currentMode == ActivityModeTaxonomy.unknown.rawValue
      || currentMode == ActivityModeTaxonomy.general.rawValue
    if currentIsUnclassified, candidate.confidence >= 0.85 {
      reset()
      return result(candidate, apply: true, display: true, reason: "initialHighConfidenceMode", count: 1)
    }

    let requiredConfidence = currentIsUnclassified
      ? ActivityModeClassifier.minimumSwitchConfidence
      : Self.minimumStableSwitchConfidence
    guard candidate.confidence >= requiredConfidence else {
      reset()
      return result(candidate, apply: false, display: false, reason: "switchConfidenceGate", count: 0)
    }
    let count = recordObservation(mode: candidateMode, specificActivity: candidate.specificActivity)
    let stable = count >= Self.requiredMatchingObservations
    return result(
      candidate,
      apply: stable,
      display: stable,
      reason: stable ? "broadModeStable" : "broadModePending",
      count: count
    )
  }

  private mutating func recordObservation(mode: String, specificActivity: String) -> Int {
    if pendingMode == mode, pendingSpecificActivity == specificActivity {
      matchingObservationCount += 1
    } else {
      pendingMode = mode
      pendingSpecificActivity = specificActivity
      matchingObservationCount = 1
    }
    return matchingObservationCount
  }

  private func result(
    _ classification: ActivityModeClassification,
    apply: Bool,
    display: Bool,
    reason: String,
    count: Int
  ) -> ActivityModeStabilizationResult {
    ActivityModeStabilizationResult(
      classification: classification,
      shouldApply: apply,
      shouldSendDisplay: display,
      reason: reason,
      matchingObservationCount: count
    )
  }
}

enum ActivityModeDebugSettings {
  private enum Keys {
    static let loggingEnabled = "activityMode.debugLoggingEnabled"
  }

  static func isLoggingEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
    if let stored = UserDefaults.standard.object(forKey: Keys.loggingEnabled) as? Bool {
      return stored
    }
    let env = DotEnvFile.load()
      .merging(ProcessInfo.processInfo.environment) { _, new in new }
      .merging(environment) { _, new in new }
    if let value = boolValue(env["MEMENTO_ACTIVITY_MODE_DEBUG"] ?? env["ACTIVITY_MODE_DEBUG"]) {
      return value
    }
    #if DEBUG
    return true
    #else
    return false
    #endif
  }

  static func save(loggingEnabled: Bool) {
    UserDefaults.standard.set(loggingEnabled, forKey: Keys.loggingEnabled)
  }

  private static func boolValue(_ value: String?) -> Bool? {
    guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
          !normalized.isEmpty else { return nil }
    if ["1", "true", "yes", "on"].contains(normalized) { return true }
    if ["0", "false", "no", "off"].contains(normalized) { return false }
    return nil
  }
}

struct SceneFrameSnapshot: Equatable {
  var timestamp: Date
  var jpegData: Data
}

struct SceneTranscriptSnapshot: Equatable {
  var id: UUID
  var text: String
  var startedAt: Date
  var endedAt: Date?
  var personId: UUID?
  var displayName: String?
}

struct SceneLocationSnapshot: Codable, Equatable {
  var latitude: Double?
  var longitude: Double?
  var horizontalAccuracy: Double?
  var label: String?
  var capturedAt: Date
}

struct SceneContextRequest {
  var appRunId: UUID
  var conversationSessionId: UUID?
  var frames: [SceneFrameSnapshot]
  var transcripts: [SceneTranscriptSnapshot]
  var identityEvidence: SceneContextIdentityEvidence?
  var location: SceneLocationSnapshot?
  var startedAt: Date
  var endedAt: Date
}

struct SceneContextPersonPresence: Codable, Equatable, Sendable {
  var personId: UUID?
  var displayName: String
  var status: String
  var confidence: Double
  var startedAt: Date
  var lastEvidenceAt: Date
  var endedAt: Date?
  var evidenceSummary: String

  init(_ episode: PersonPresenceEpisode) {
    personId = episode.personId
    displayName = episode.displayName
    status = episode.status.rawValue
    confidence = Double(episode.confidence)
    startedAt = episode.startedAt
    lastEvidenceAt = episode.lastEvidenceAt
    endedAt = episode.endedAt
    evidenceSummary = episode.evidenceSummary
  }
}

struct SceneContextIdentityEvidence: Codable, Equatable, Sendable {
  var wearerName: String?
  var conversationPartnerName: String?
  var conversationPartnerPersonId: UUID?
  var conversationPartnerState: String
  var confidence: Double
  var sourceSummary: String
  var activePeople: [SceneContextPersonPresence]
  var departedPeople: [SceneContextPersonPresence]

  init(
    wearerName: String?,
    conversationPartnerName: String?,
    conversationPartnerPersonId: UUID?,
    conversationPartnerState: String,
    confidence: Double,
    sourceSummary: String,
    activePeople: [SceneContextPersonPresence] = [],
    departedPeople: [SceneContextPersonPresence] = []
  ) {
    self.wearerName = wearerName
    self.conversationPartnerName = conversationPartnerName
    self.conversationPartnerPersonId = conversationPartnerPersonId
    self.conversationPartnerState = conversationPartnerState
    self.confidence = confidence
    self.sourceSummary = sourceSummary
    self.activePeople = activePeople
    self.departedPeople = departedPeople
  }
}

struct NameAddressRequest: Sendable {
  var transcriptText: String
  var people: [PersonNameCandidate]
  var activePeople: [PersonPresenceEpisode]
  var timestamp: Date
}

struct NameAddressAnalysis: Codable, Equatable, Sendable {
  enum Intent: String, Codable, Sendable {
    case none
    case directAddress
    case introduction
    case departure
    case reference
  }

  var intent: Intent
  var displayName: String?
  var personId: String?
  var confidence: Double
  var evidence: String
}

struct StreamSummaryRequest {
  var transcripts: [TranscriptChunk]
  var sceneContexts: [SceneContextRecord]
  var startedAt: Date?
  var endedAt: Date
  var identityEvidence: SceneContextIdentityEvidence?
}

struct StreamSummaryAnalysis: Codable, Equatable {
  var summary: String
  var who: String
  var whereText: String
  var what: String
  var whenText: String
  var why: String
  var how: String
  var people: [String]
  var keyMoments: [String]
  var outline: [String]
  var confidence: Double

  enum CodingKeys: String, CodingKey {
    case summary
    case who
    case whereText = "where"
    case what
    case whenText = "when"
    case why
    case how
    case people
    case keyMoments
    case outline
    case confidence
  }

  init(
    summary: String,
    who: String = "unknown",
    whereText: String = "unknown",
    what: String = "unknown",
    whenText: String = "unknown",
    why: String = "unknown",
    how: String = "unknown",
    people: [String],
    keyMoments: [String],
    outline: [String] = [],
    confidence: Double
  ) {
    self.summary = summary
    self.who = who
    self.whereText = whereText
    self.what = what
    self.whenText = whenText
    self.why = why
    self.how = how
    self.people = people
    self.keyMoments = keyMoments
    self.outline = outline
    self.confidence = confidence
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    summary = try container.decode(String.self, forKey: .summary)
    people = try container.decodeIfPresent([String].self, forKey: .people) ?? []
    keyMoments = try container.decodeIfPresent([String].self, forKey: .keyMoments) ?? []
    outline = try container.decodeIfPresent([String].self, forKey: .outline) ?? []
    confidence = try container.decode(Double.self, forKey: .confidence)
    who = try container.decodeIfPresent(String.self, forKey: .who) ?? "unknown"
    whereText = try container.decodeIfPresent(String.self, forKey: .whereText) ?? "unknown"
    what = try container.decodeIfPresent(String.self, forKey: .what) ?? "unknown"
    whenText = try container.decodeIfPresent(String.self, forKey: .whenText) ?? "unknown"
    why = try container.decodeIfPresent(String.self, forKey: .why) ?? "unknown"
    how = try container.decodeIfPresent(String.self, forKey: .how) ?? "unknown"
  }
}

struct StreamSummaryHistoryEntry: Identifiable, Codable, Equatable {
  var id: UUID
  var conversationSessionId: UUID?
  var startedAt: Date
  var endedAt: Date
  var summary: String
  var who: String
  var whereText: String
  var what: String
  var whenText: String
  var why: String
  var how: String
  var people: [String]
  var keyMoments: [String]
  var outline: [String]
  var modelName: String
  var statusText: String
  var confidence: Double

  init(
    id: UUID = UUID(),
    conversationSessionId: UUID?,
    startedAt: Date,
    endedAt: Date,
    analysis: StreamSummaryAnalysis,
    modelName: String,
    statusText: String
  ) {
    self.id = id
    self.conversationSessionId = conversationSessionId
    self.startedAt = startedAt
    self.endedAt = endedAt
    summary = analysis.summary
    who = analysis.who
    whereText = analysis.whereText
    what = analysis.what
    whenText = analysis.whenText
    why = analysis.why
    how = analysis.how
    people = analysis.people
    keyMoments = analysis.keyMoments
    outline = analysis.outline
    self.modelName = modelName
    self.statusText = statusText
    confidence = analysis.confidence
  }
}

struct SceneContextAnalysis: Codable, Equatable {
  var who: String
  var whereText: String
  var what: String
  var whenText: String
  var why: String
  var how: String
  var interactionStyle: String
  var summary: String
  var confidence: Double
  var evidence: [String]

  enum CodingKeys: String, CodingKey {
    case who
    case whereText = "where"
    case what
    case whenText = "when"
    case why
    case how
    case interactionStyle
    case summary
    case confidence
    case evidence
  }

  init(
    who: String,
    whereText: String,
    what: String,
    whenText: String,
    why: String,
    how: String,
    interactionStyle: String,
    summary: String,
    confidence: Double,
    evidence: [String]
  ) {
    self.who = who
    self.whereText = whereText
    self.what = what
    self.whenText = whenText
    self.why = why
    self.how = how
    self.interactionStyle = interactionStyle
    self.summary = summary
    self.confidence = confidence
    self.evidence = evidence
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    who = try container.decode(String.self, forKey: .who)
    whereText = try container.decode(String.self, forKey: .whereText)
    what = try container.decode(String.self, forKey: .what)
    whenText = try container.decode(String.self, forKey: .whenText)
    why = try container.decode(String.self, forKey: .why)
    how = try container.decode(String.self, forKey: .how)
    interactionStyle = try container.decodeIfPresent(String.self, forKey: .interactionStyle) ?? "unknown"
    summary = try container.decode(String.self, forKey: .summary)
    confidence = try container.decode(Double.self, forKey: .confidence)
    evidence = try container.decode([String].self, forKey: .evidence)
  }
}

struct SceneContextRecord: Identifiable, Codable, Equatable, Sendable {
  var id: UUID
  var appRunId: UUID
  var conversationSessionId: UUID?
  var personId: UUID?
  var startedAt: Date
  var endedAt: Date
  var createdAt: Date
  var modelName: String
  var promptVersion: String
  var transcriptChunkIdsJson: String
  var frameTimestampsJson: String
  var locationLabel: String?
  var latitude: Double?
  var longitude: Double?
  var locationAccuracyMeters: Double?
  var who: String
  var whereText: String
  var what: String
  var whenText: String
  var why: String
  var how: String
  var interactionStyle: String
  var summary: String
  var confidence: Double
  var evidenceJson: String
}
