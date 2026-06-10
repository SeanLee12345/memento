import Foundation

struct ConversationPartnerEvidence: Equatable {
  enum Source: String, Equatable {
    case faceLocal
    case faceAWS
    case voiceLocal
    case voiceAWS
    case diarization
    case transcript
    case mouthMovement
    case wearerVoice
    case userConfirmation
  }

  let source: Source
  let personId: UUID?
  let displayName: String?
  let confidence: Float
  let timestamp: Date
  let validUntil: Date
  let details: String

  var isExpired: Bool {
    validUntil <= Date()
  }
}

struct ConversationPartnerCandidate: Equatable {
  let personId: UUID?
  let displayName: String?
  let score: Float
  let evidence: [ConversationPartnerEvidence]
  let conflictReasons: [String]
}

struct ConversationPartnerState: Equatable {
  enum Phase: String, Equatable {
    case none
    case unknown
    case possible
    case confirmed
    case conflicted
    case multiplePeople
  }

  let phase: Phase
  let primary: ConversationPartnerCandidate?
  let alternates: [ConversationPartnerCandidate]
  let sourceSummary: String
  let updatedAt: Date

  static let empty = ConversationPartnerState(
    phase: .none,
    primary: nil,
    alternates: [],
    sourceSummary: "No partner evidence yet",
    updatedAt: Date.distantPast
  )

  var allowsPrivateMemory: Bool {
    phase == .confirmed
  }

  var attributionState: String {
    switch phase {
    case .none:
      return "unknown"
    case .unknown:
      return "partnerUnknown"
    case .possible:
      return "partnerPossible"
    case .confirmed:
      return "partnerConfirmed"
    case .conflicted:
      return "partnerConflicted"
    case .multiplePeople:
      return "partnerMultiplePeople"
    }
  }
}

struct PersonPresenceEpisode: Identifiable, Equatable, Sendable {
  enum Status: String, Codable, Equatable, Sendable {
    case active
    case departed
    case uncertain
  }

  let id: UUID
  var personId: UUID?
  var displayName: String
  var startedAt: Date
  var lastEvidenceAt: Date
  var endedAt: Date?
  var status: Status
  var confidence: Float
  var evidenceSummary: String

  var isActive: Bool { status == .active && endedAt == nil }

  var timeRangeText: String {
    let end = endedAt ?? lastEvidenceAt
    return "\(startedAt.formatted(date: .numeric, time: .shortened))-\(end.formatted(date: .omitted, time: .shortened))"
  }
}

struct PresenceEpisodeRecord: Identifiable, Codable, Equatable, Sendable {
  let id: UUID
  var appRunId: UUID
  var conversationSessionId: UUID?
  var personId: UUID?
  var displayName: String
  var startedAt: Date
  var lastEvidenceAt: Date
  var endedAt: Date?
  var status: PersonPresenceEpisode.Status
  var confidence: Float
  var evidenceSummary: String
  var updatedAt: Date

  init(
    id: UUID,
    appRunId: UUID,
    conversationSessionId: UUID?,
    personId: UUID?,
    displayName: String,
    startedAt: Date,
    lastEvidenceAt: Date,
    endedAt: Date?,
    status: PersonPresenceEpisode.Status,
    confidence: Float,
    evidenceSummary: String,
    updatedAt: Date
  ) {
    self.id = id
    self.appRunId = appRunId
    self.conversationSessionId = conversationSessionId
    self.personId = personId
    self.displayName = displayName
    self.startedAt = startedAt
    self.lastEvidenceAt = lastEvidenceAt
    self.endedAt = endedAt
    self.status = status
    self.confidence = confidence
    self.evidenceSummary = evidenceSummary
    self.updatedAt = updatedAt
  }

  init(episode: PersonPresenceEpisode, context: PipelineContext, updatedAt: Date) {
    self.init(
      id: episode.id,
      appRunId: context.appRunId,
      conversationSessionId: context.conversationSessionId,
      personId: episode.personId,
      displayName: episode.displayName,
      startedAt: episode.startedAt,
      lastEvidenceAt: episode.lastEvidenceAt,
      endedAt: episode.endedAt,
      status: episode.status,
      confidence: episode.confidence,
      evidenceSummary: episode.evidenceSummary,
      updatedAt: updatedAt
    )
  }

  var syncSignature: String {
    [
      personId?.uuidString ?? "nil",
      displayName,
      String(format: "%.3f", startedAt.timeIntervalSince1970),
      String(format: "%.3f", lastEvidenceAt.timeIntervalSince1970),
      endedAt.map { String(format: "%.3f", $0.timeIntervalSince1970) } ?? "nil",
      status.rawValue,
      String(format: "%.3f", Double(confidence)),
      evidenceSummary
    ].joined(separator: "|")
  }
}

struct PersonNameCandidate: Equatable, Sendable {
  let personId: UUID
  let displayName: String
}

struct TranscriptNameSignal: Equatable, Sendable {
  enum Intent: String, Equatable, Sendable {
    case directAddress
    case introduction
    case departure
    case reference
  }

  let intent: Intent
  let personId: UUID?
  let displayName: String
  let confidence: Float
  let evidence: String
}

struct TranscriptNameSignalResolver {
  static func resolve(
    text: String,
    people: [PersonNameCandidate],
    llmAnalysis: NameAddressAnalysis? = nil
  ) -> TranscriptNameSignal? {
    if let llmSignal = signal(from: llmAnalysis, people: people), llmSignal.intent != .reference {
      return llmSignal
    }
    return heuristicSignal(text: text, people: people)
  }

  private static func signal(
    from analysis: NameAddressAnalysis?,
    people: [PersonNameCandidate]
  ) -> TranscriptNameSignal? {
    guard let analysis,
          analysis.intent != .none,
          let name = analysis.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
          !name.isEmpty else { return nil }
    let matched = people.first { $0.displayName.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    let personId = analysis.personId.flatMap(UUID.init(uuidString:)) ?? matched?.personId
    let intent: TranscriptNameSignal.Intent
    switch analysis.intent {
    case .directAddress:
      intent = .directAddress
    case .introduction:
      intent = .introduction
    case .departure:
      intent = .departure
    case .reference:
      intent = .reference
    case .none:
      return nil
    }
    return TranscriptNameSignal(
      intent: intent,
      personId: personId,
      displayName: matched?.displayName ?? name,
      confidence: Float(min(max(analysis.confidence, 0), 1)),
      evidence: "llmNameAddress:\(analysis.evidence)"
    )
  }

  private static func heuristicSignal(text: String, people: [PersonNameCandidate]) -> TranscriptNameSignal? {
    let normalized = normalize(text)
    guard !normalized.isEmpty else { return nil }
    for person in people.sorted(by: { $0.displayName.count > $1.displayName.count }) {
      let name = normalize(person.displayName)
      guard containsName(name, in: normalized) else { continue }
      if isReferenceOnly(name: name, text: normalized) {
        return TranscriptNameSignal(
          intent: .reference,
          personId: person.personId,
          displayName: person.displayName,
          confidence: 0.40,
          evidence: "heuristicNameReference"
        )
      }
      if isDeparture(name: name, text: normalized) {
        return TranscriptNameSignal(
          intent: .departure,
          personId: person.personId,
          displayName: person.displayName,
          confidence: 0.82,
          evidence: "heuristicFarewell"
        )
      }
      if isIntroduction(name: name, text: normalized) {
        return TranscriptNameSignal(
          intent: .introduction,
          personId: person.personId,
          displayName: person.displayName,
          confidence: 0.68,
          evidence: "heuristicIntroduction"
        )
      }
      if isDirectAddress(name: name, text: normalized) {
        return TranscriptNameSignal(
          intent: .directAddress,
          personId: person.personId,
          displayName: person.displayName,
          confidence: 0.66,
          evidence: "heuristicDirectAddress"
        )
      }
    }
    return nil
  }

  private static func normalize(_ text: String) -> String {
    text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
      .lowercased()
      .replacingOccurrences(of: #"[^a-z0-9\s,!.?'-]"#, with: " ", options: .regularExpression)
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func containsName(_ name: String, in text: String) -> Bool {
    guard !name.isEmpty else { return false }
    let pattern = #"(^|[^a-z0-9])"# + NSRegularExpression.escapedPattern(for: name) + #"([^a-z0-9]|$)"#
    return text.range(of: pattern, options: .regularExpression) != nil
  }

  private static func isDeparture(name: String, text: String) -> Bool {
    [
      "bye \(name)", "goodbye \(name)", "see you \(name)", "later \(name)",
      "talk to you later \(name)", "\(name) bye", "\(name) goodbye"
    ].contains { text.contains($0) }
  }

  private static func isIntroduction(name: String, text: String) -> Bool {
    [
      "this is \(name)", "meet \(name)", "called \(name)", "named \(name)"
    ].contains { text.contains($0) }
  }

  private static func isDirectAddress(name: String, text: String) -> Bool {
    text.hasPrefix("\(name) ")
      || text.hasPrefix("\(name),")
      || text.hasPrefix("hey \(name)")
      || text.hasPrefix("hi \(name)")
      || text.hasPrefix("hello \(name)")
      || text.contains(", \(name),")
      || text.contains(" \(name)?")
  }

  private static func isReferenceOnly(name: String, text: String) -> Bool {
    [
      "about \(name)", "talked to \(name)", "talking about \(name)", "met \(name) yesterday",
      "\(name) told me", "\(name) said", "remember \(name)"
    ].contains { text.contains($0) }
  }
}

final class PresenceEpisodeTracker {
  private var activeByKey: [String: PersonPresenceEpisode] = [:]
  private var departed: [PersonPresenceEpisode] = []

  private let staleInterval: TimeInterval = 180
  private let maxDeparted = 12

  func reset() {
    activeByKey.removeAll()
    departed.removeAll()
  }

  @discardableResult
  func record(evidence: ConversationPartnerEvidence, now: Date = Date()) -> PersonPresenceEpisode? {
    guard evidence.source != .mouthMovement,
          evidence.source != .wearerVoice,
          let displayName = evidence.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
          !displayName.isEmpty else { return nil }
    expireStaleEpisodes(now: now)
    let key = episodeKey(personId: evidence.personId, displayName: displayName)
    let hasActiveEpisode = activeByKey[key] != nil
    guard evidence.confidence >= minimumConfidence(for: evidence.source, hasActiveEpisode: hasActiveEpisode) else { return nil }
    return upsert(
      personId: evidence.personId,
      displayName: displayName,
      confidence: evidence.confidence,
      now: now,
      evidence: "\(evidence.source.rawValue)=\(String(format: "%.2f", Double(evidence.confidence)))"
    )
  }

  @discardableResult
  func record(nameSignal: TranscriptNameSignal, now: Date = Date()) -> PersonPresenceEpisode? {
    switch nameSignal.intent {
    case .directAddress, .introduction:
      return upsert(
        personId: nameSignal.personId,
        displayName: nameSignal.displayName,
        confidence: nameSignal.confidence,
        now: now,
        evidence: nameSignal.evidence
      )
    case .departure:
      return close(
        personId: nameSignal.personId,
        displayName: nameSignal.displayName,
        now: now,
        evidence: nameSignal.evidence
      )
    case .reference:
      return nil
    }
  }

  func closeAllActive(now: Date = Date(), evidence: String) -> [PersonPresenceEpisode] {
    let episodes = activeByKey.map { (key, episode) -> PersonPresenceEpisode in
      var closed = episode
      closed.lastEvidenceAt = max(episode.lastEvidenceAt, now)
      closed.endedAt = now
      closed.status = .departed
      closed.evidenceSummary = mergeEvidence(closed.evidenceSummary, evidence)
      removeDeparted(matching: key)
      return closed
    }
    activeByKey.removeAll()
    departed.insert(contentsOf: episodes, at: 0)
    if departed.count > maxDeparted {
      departed = Array(departed.prefix(maxDeparted))
    }
    return episodes
  }

  func snapshot(now: Date = Date()) -> (active: [PersonPresenceEpisode], departed: [PersonPresenceEpisode]) {
    expireStaleEpisodes(now: now)
    let active = activeByKey.values.sorted { lhs, rhs in
      if lhs.lastEvidenceAt == rhs.lastEvidenceAt {
        return lhs.displayName < rhs.displayName
      }
      return lhs.lastEvidenceAt > rhs.lastEvidenceAt
    }
    return (active, departed.sorted { $0.lastEvidenceAt > $1.lastEvidenceAt })
  }

  func summary(now: Date = Date()) -> String {
    let snap = snapshot(now: now)
    let active = snap.active.map { "\($0.displayName) active \(Int(($0.confidence * 100).rounded()))%" }
    let left = snap.departed.prefix(3).map { "\($0.displayName) departed" }
    return (active + left).joined(separator: "; ")
  }

  private func upsert(personId: UUID?, displayName: String, confidence: Float, now: Date, evidence: String) -> PersonPresenceEpisode {
    expireStaleEpisodes(now: now)
    let key = episodeKey(personId: personId, displayName: displayName)
    removeDeparted(matching: key)
    var episode = activeByKey[key] ?? PersonPresenceEpisode(
      id: UUID(),
      personId: personId,
      displayName: displayName,
      startedAt: now,
      lastEvidenceAt: now,
      endedAt: nil,
      status: .active,
      confidence: confidence,
      evidenceSummary: evidence
    )
    episode.personId = episode.personId ?? personId
    episode.displayName = displayName
    episode.lastEvidenceAt = now
    episode.endedAt = nil
    episode.status = .active
    episode.confidence = max(episode.confidence * 0.85, confidence)
    episode.evidenceSummary = mergeEvidence(episode.evidenceSummary, evidence)
    activeByKey[key] = episode
    return episode
  }

  private func close(personId: UUID?, displayName: String, now: Date, evidence: String) -> PersonPresenceEpisode {
    let key = episodeKey(personId: personId, displayName: displayName)
    var episode = activeByKey.removeValue(forKey: key) ?? PersonPresenceEpisode(
      id: UUID(),
      personId: personId,
      displayName: displayName,
      startedAt: now,
      lastEvidenceAt: now,
      endedAt: nil,
      status: .active,
      confidence: 0.55,
      evidenceSummary: evidence
    )
    episode.lastEvidenceAt = now
    episode.endedAt = now
    episode.status = .departed
    episode.evidenceSummary = mergeEvidence(episode.evidenceSummary, evidence)
    removeDeparted(matching: key)
    departed.insert(episode, at: 0)
    if departed.count > maxDeparted {
      departed = Array(departed.prefix(maxDeparted))
    }
    return episode
  }

  private func expireStaleEpisodes(now: Date) {
    for (key, episode) in activeByKey where now.timeIntervalSince(episode.lastEvidenceAt) > staleInterval {
      var expired = episode
      expired.status = .uncertain
      expired.endedAt = episode.lastEvidenceAt.addingTimeInterval(staleInterval)
      expired.evidenceSummary = mergeEvidence(expired.evidenceSummary, "staleTimeout")
      removeDeparted(matching: key)
      departed.insert(expired, at: 0)
      activeByKey.removeValue(forKey: key)
    }
    if departed.count > maxDeparted {
      departed = Array(departed.prefix(maxDeparted))
    }
  }

  private func minimumConfidence(
    for source: ConversationPartnerEvidence.Source,
    hasActiveEpisode: Bool
  ) -> Float {
    switch source {
    case .faceAWS, .faceLocal:
      hasActiveEpisode ? IdentityConfig.weakMatchThreshold : IdentityConfig.strongMatchThreshold
    case .voiceAWS, .voiceLocal:
      SpeakerIdentityConfig.weakMatchThreshold
    case .diarization:
      0.55
    case .transcript:
      0.60
    case .userConfirmation:
      0.50
    case .mouthMovement, .wearerVoice:
      1
    }
  }

  private func episodeKey(personId: UUID?, displayName: String) -> String {
    personId?.uuidString ?? displayName.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
  }

  private func removeDeparted(matching key: String) {
    departed.removeAll { episodeKey(personId: $0.personId, displayName: $0.displayName) == key }
  }

  private func mergeEvidence(_ old: String, _ new: String) -> String {
    guard !old.contains(new) else { return old }
    if old.isEmpty { return new }
    return "\(old);\(new)"
  }
}
