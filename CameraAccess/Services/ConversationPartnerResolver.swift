import Foundation

struct ConversationPartnerResolver {
  private struct CandidateAccumulator {
    var personId: UUID?
    var displayName: String?
    var evidence: [ConversationPartnerEvidence] = []
    var score: Float = 0
    var conflictReasons: [String] = []
  }

  var voiceWeakThreshold: Float = SpeakerIdentityConfig.weakMatchThreshold
  var voiceStrongThreshold: Float = SpeakerIdentityConfig.strongMatchThreshold
  var faceWeakThreshold: Float = IdentityConfig.weakMatchThreshold
  var faceStrongThreshold: Float = IdentityConfig.strongMatchThreshold
  var mouthSpeakingThreshold: Float = 0.12

  func resolve(
    evidence allEvidence: [ConversationPartnerEvidence],
    now: Date = Date()
  ) -> ConversationPartnerState {
    let evidence = allEvidence
      .filter { $0.validUntil >= now }
      .sorted { $0.timestamp < $1.timestamp }

    guard !evidence.isEmpty else {
      return ConversationPartnerState(
        phase: .none,
        primary: nil,
        alternates: [],
        sourceSummary: "No partner evidence yet",
        updatedAt: now
      )
    }

    let hasUserConfirmation = evidence.contains {
      $0.source == .userConfirmation && $0.personId != nil && $0.confidence >= 0.50
    }

    if !hasUserConfirmation,
       let wearer = strongest(evidence, matching: { $0.source == .wearerVoice }),
       wearer.confidence >= voiceStrongThreshold {
      return ConversationPartnerState(
        phase: .unknown,
        primary: nil,
        alternates: [],
        sourceSummary: "wearer voice \(format(wearer.confidence)); external partner suppressed",
        updatedAt: now
      )
    }

    let faceEvidence = evidence.filter { $0.source == .faceLocal || $0.source == .faceAWS }
    let voiceEvidence = evidence.filter { $0.source == .voiceLocal || $0.source == .voiceAWS }
    let diarizationEvidence = evidence.filter { $0.source == .diarization }
    let mouthEvidence = evidence.filter { $0.source == .mouthMovement }
    let latestMouth = mouthEvidence.last?.confidence ?? 0
    let visiblePeople = Set(faceEvidence.compactMap(\.personId))
    let hasMultipleFaceMarker = faceEvidence.contains { item in
      item.details.contains("faceCount=") && !item.details.contains("faceCount=0") && !item.details.contains("faceCount=1")
    }

    var candidates: [String: CandidateAccumulator] = [:]
    for item in evidence where item.source != .mouthMovement && item.source != .wearerVoice {
      let key = candidateKey(for: item)
      var candidate = candidates[key] ?? CandidateAccumulator(
        personId: item.personId,
        displayName: item.displayName
      )
      candidate.personId = candidate.personId ?? item.personId
      candidate.displayName = candidate.displayName ?? item.displayName
      candidate.evidence.append(item)
      candidate.score += weightedScore(for: item, latestMouthScore: latestMouth)
      candidates[key] = candidate
    }

    guard !candidates.isEmpty else {
      return ConversationPartnerState(
        phase: .unknown,
        primary: nil,
        alternates: [],
        sourceSummary: "No external partner evidence",
        updatedAt: now
      )
    }

    let resolved = candidates.map { _, value -> ConversationPartnerCandidate in
      var adjusted = value
      let candidateVoice = adjusted.evidence.filter { $0.source == .voiceLocal || $0.source == .voiceAWS || $0.source == .diarization }
      let candidateFace = adjusted.evidence.filter { $0.source == .faceLocal || $0.source == .faceAWS }
      if !candidateVoice.isEmpty && !candidateFace.isEmpty {
        adjusted.score += 0.18
      }
      if candidateFace.count >= 2, Set(candidateFace.map(\.source)).count >= 2 {
        adjusted.score += 0.08
      }
      if candidateVoice.count >= 2, Set(candidateVoice.map(\.source)).count >= 2 {
        adjusted.score += 0.10
      }
      if candidateFace.contains(where: { $0.confidence >= faceWeakThreshold }) && latestMouth >= mouthSpeakingThreshold {
        adjusted.score += latestMouth * 0.45
      }
      return ConversationPartnerCandidate(
        personId: adjusted.personId,
        displayName: adjusted.displayName,
        score: min(1, adjusted.score),
        evidence: adjusted.evidence,
        conflictReasons: adjusted.conflictReasons
      )
    }
    .sorted { lhs, rhs in
      if lhs.score == rhs.score {
        return latestEvidenceTimestamp(in: lhs) > latestEvidenceTimestamp(in: rhs)
      }
      return lhs.score > rhs.score
    }

    guard let primary = resolved.first else {
      return ConversationPartnerState(
        phase: .unknown,
        primary: nil,
        alternates: [],
        sourceSummary: "No external partner evidence",
        updatedAt: now
      )
    }

    let alternates = Array(resolved.dropFirst())
    if primary.evidence.contains(where: { $0.source == .userConfirmation && $0.confidence >= 0.50 }) {
      return ConversationPartnerState(
        phase: .confirmed,
        primary: primary,
        alternates: alternates,
        sourceSummary: sourceSummary(phase: .confirmed, primary: primary, mouthScore: latestMouth),
        updatedAt: now
      )
    }

    let voiceWinner = strongestKnownPerson(in: voiceEvidence + diarizationEvidence, threshold: voiceWeakThreshold)
    let faceWinner = strongestKnownPerson(in: faceEvidence, threshold: faceWeakThreshold)

    let localVoiceWinner = strongestKnownPerson(in: voiceEvidence.filter { $0.source == .voiceLocal }, threshold: voiceWeakThreshold)
    let awsVoiceWinner = strongestKnownPerson(in: voiceEvidence.filter { $0.source == .voiceAWS }, threshold: voiceWeakThreshold)

    if let localVoiceWinner, let awsVoiceWinner,
       localVoiceWinner.personId != awsVoiceWinner.personId {
      let conflictPrimary = ConversationPartnerCandidate(
        personId: primary.personId,
        displayName: primary.displayName,
        score: primary.score,
        evidence: primary.evidence,
        conflictReasons: ["local and AWS voice disagree"]
      )
      return ConversationPartnerState(
        phase: .conflicted,
        primary: conflictPrimary,
        alternates: alternates,
        sourceSummary: sourceSummary(phase: .conflicted, primary: conflictPrimary, mouthScore: latestMouth),
        updatedAt: now
      )
    }

    if let voiceWinner, let faceWinner,
       voiceWinner.personId != faceWinner.personId,
       faceWinner.confidence >= faceWeakThreshold,
       latestMouth >= mouthSpeakingThreshold {
      let conflictPrimary = ConversationPartnerCandidate(
        personId: primary.personId,
        displayName: primary.displayName,
        score: primary.score,
        evidence: primary.evidence,
        conflictReasons: ["voice and speaking face disagree"]
      )
      return ConversationPartnerState(
        phase: .conflicted,
        primary: conflictPrimary,
        alternates: alternates,
        sourceSummary: sourceSummary(phase: .conflicted, primary: conflictPrimary, mouthScore: latestMouth),
        updatedAt: now
      )
    }

    if (visiblePeople.count > 1 || hasMultipleFaceMarker),
       case nil = voiceWinner,
       latestMouth < mouthSpeakingThreshold {
      return ConversationPartnerState(
        phase: .multiplePeople,
        primary: primary,
        alternates: alternates,
        sourceSummary: sourceSummary(phase: .multiplePeople, primary: primary, mouthScore: latestMouth),
        updatedAt: now
      )
    }

    let phase = phase(for: primary)
    return ConversationPartnerState(
      phase: phase,
      primary: primary,
      alternates: alternates,
      sourceSummary: sourceSummary(phase: phase, primary: primary, mouthScore: latestMouth),
      updatedAt: now
    )
  }

  private func weightedScore(
    for evidence: ConversationPartnerEvidence,
    latestMouthScore: Float
  ) -> Float {
    switch evidence.source {
    case .voiceAWS:
      return evidence.confidence >= voiceStrongThreshold ? evidence.confidence * 0.82 : evidence.confidence * 0.58
    case .voiceLocal:
      return evidence.confidence >= voiceStrongThreshold ? evidence.confidence * 0.74 : evidence.confidence * 0.52
    case .diarization:
      return evidence.personId == nil ? evidence.confidence * 0.30 : evidence.confidence * 0.68
    case .faceAWS:
      let multiplier: Float = latestMouthScore >= mouthSpeakingThreshold ? 0.62 : 0.34
      return evidence.confidence * multiplier
    case .faceLocal:
      let multiplier: Float = latestMouthScore >= mouthSpeakingThreshold ? 0.56 : 0.30
      return evidence.confidence * multiplier
    case .transcript:
      return evidence.confidence * 0.20
    case .userConfirmation:
      return evidence.confidence
    case .mouthMovement, .wearerVoice:
      return 0
    }
  }

  private func phase(for candidate: ConversationPartnerCandidate) -> ConversationPartnerState.Phase {
    if candidate.evidence.contains(where: { $0.source == .userConfirmation && $0.confidence >= 0.50 }) {
      return .confirmed
    }
    if candidate.personId == nil {
      return .unknown
    }
    if candidate.evidence.contains(where: {
      ($0.source == .voiceLocal || $0.source == .voiceAWS || $0.source == .diarization)
        && $0.confidence >= voiceStrongThreshold
    }) {
      return .confirmed
    }
    if candidate.score >= 0.72 {
      return .confirmed
    }
    if candidate.score >= 0.48 {
      return .possible
    }
    return .unknown
  }

  private func latestEvidenceTimestamp(in candidate: ConversationPartnerCandidate) -> Date {
    candidate.evidence.map(\.timestamp).max() ?? Date.distantPast
  }

  private func sourceSummary(
    phase: ConversationPartnerState.Phase,
    primary: ConversationPartnerCandidate,
    mouthScore: Float
  ) -> String {
    let identity = primary.displayName ?? primary.personId?.uuidString ?? "unknown"
    let sourceText = primary.evidence
      .sorted { $0.source.rawValue < $1.source.rawValue }
      .map { "\($0.source.rawValue)=\(format($0.confidence))" }
      .joined(separator: " ")
    var parts = [
      "state=\(phase.rawValue)",
      "person=\(identity)",
      "score=\(format(primary.score))"
    ]
    if mouthScore > 0 {
      parts.append("mouth=\(format(mouthScore))")
    }
    if !sourceText.isEmpty {
      parts.append(sourceText)
    }
    if !primary.conflictReasons.isEmpty {
      parts.append("conflict=\(primary.conflictReasons.joined(separator: ","))")
    }
    return parts.joined(separator: ";")
  }

  private func strongest(
    _ evidence: [ConversationPartnerEvidence],
    matching predicate: (ConversationPartnerEvidence) -> Bool
  ) -> ConversationPartnerEvidence? {
    evidence.filter(predicate).max { $0.confidence < $1.confidence }
  }

  private func strongestKnownPerson(
    in evidence: [ConversationPartnerEvidence],
    threshold: Float
  ) -> (personId: UUID, confidence: Float)? {
    evidence
      .compactMap { item -> (personId: UUID, confidence: Float)? in
        guard let personId = item.personId, item.confidence >= threshold else { return nil }
        return (personId, item.confidence)
      }
      .max { $0.confidence < $1.confidence }
  }

  private func candidateKey(for evidence: ConversationPartnerEvidence) -> String {
    if let personId = evidence.personId {
      return personId.uuidString
    }
    if let displayName = evidence.displayName, !displayName.isEmpty {
      return "name:\(displayName.lowercased())"
    }
    return "unknown:\(evidence.source.rawValue):\(evidence.details)"
  }

  private func format(_ value: Float) -> String {
    String(format: "%.2f", value)
  }
}
