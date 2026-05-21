import Foundation

struct RollingIdentityConfirmor {
  private struct Observation {
    let personId: UUID?
    let displayName: String?
    let confidence: Float
    let decision: IdentityMatchResult.Decision
    let timestamp: Date
  }

  private var observations: [Observation] = []
  private var activeIdentity = ActiveIdentityState.none
  private var unknownGoodFaceCount = 0

  mutating func update(
    match: IdentityMatchResult,
    profile: PersonProfile?,
    sawGoodUnknownFace: Bool,
    now: Date = Date()
  ) -> ActiveIdentityState {
    observations.append(Observation(
      personId: match.bestPersonId,
      displayName: profile?.displayName,
      confidence: match.bestSimilarity,
      decision: match.decision,
      timestamp: now
    ))
    observations.removeAll { now.timeIntervalSince($0.timestamp) > IdentityConfig.rollingWindowSeconds }
    if observations.count > IdentityConfig.rollingWindowSize {
      observations = Array(observations.suffix(IdentityConfig.rollingWindowSize))
    }

    if sawGoodUnknownFace && match.decision == .unknown {
      unknownGoodFaceCount += 1
    } else if match.decision == .known {
      unknownGoodFaceCount = 0
    }

    let strongByPerson = Dictionary(grouping: observations.filter { $0.decision == .known && $0.personId != nil }) {
      $0.personId!
    }
    if let winner = strongByPerson.max(by: { $0.value.count < $1.value.count }),
       winner.value.count >= IdentityConfig.requiredStrongMatches,
       let latest = winner.value.last {
      activeIdentity = ActiveIdentityState(
        personId: winner.key,
        displayName: latest.displayName,
        confidence: latest.confidence,
        state: .confirmed,
        confirmedAt: activeIdentity.personId == winner.key ? activeIdentity.confirmedAt ?? now : now,
        lastSeenAt: now
      )
      return activeIdentity
    }

    if let candidate = strongByPerson.max(by: { $0.value.count < $1.value.count }),
       let latest = candidate.value.last {
      activeIdentity = ActiveIdentityState(
        personId: candidate.key,
        displayName: latest.displayName,
        confidence: latest.confidence,
        state: .possible,
        confirmedAt: nil,
        lastSeenAt: now
      )
      return activeIdentity
    }

    if let latestWeak = observations.last(where: { $0.decision == .ambiguous && $0.personId != nil }) {
      activeIdentity = ActiveIdentityState(
        personId: latestWeak.personId,
        displayName: latestWeak.displayName,
        confidence: latestWeak.confidence,
        state: .ambiguous,
        confirmedAt: nil,
        lastSeenAt: now
      )
      return activeIdentity
    }

    if let lastSeen = activeIdentity.lastSeenAt,
       activeIdentity.state == .confirmed,
       now.timeIntervalSince(lastSeen) < IdentityConfig.holdIdentitySeconds {
      return activeIdentity
    }

    if unknownGoodFaceCount >= IdentityConfig.unknownPromptStrongFrames {
      activeIdentity = ActiveIdentityState(
        personId: nil,
        displayName: nil,
        confidence: 0,
        state: .unknown,
        confirmedAt: nil,
        lastSeenAt: now
      )
      return activeIdentity
    }

    activeIdentity = .none
    return activeIdentity
  }

  // Called when the confirmed face is still visible but we're skipping embedding/matching.
  // Keeps lastSeenAt current so holdIdentitySeconds counts from the last real sighting.
  mutating func noteConfirmedFaceVisible(at now: Date) {
    guard activeIdentity.state == .confirmed else { return }
    activeIdentity = ActiveIdentityState(
      personId: activeIdentity.personId,
      displayName: activeIdentity.displayName,
      confidence: activeIdentity.confidence,
      state: .confirmed,
      confirmedAt: activeIdentity.confirmedAt,
      lastSeenAt: now
    )
  }

  var currentState: ActiveIdentityState { activeIdentity }

  mutating func setConfirmed(profile: PersonProfile, confidence: Float = 1) -> ActiveIdentityState {
    activeIdentity = ActiveIdentityState(
      personId: profile.id,
      displayName: profile.displayName,
      confidence: confidence,
      state: .confirmed,
      confirmedAt: Date(),
      lastSeenAt: Date()
    )
    observations.removeAll()
    unknownGoodFaceCount = 0
    return activeIdentity
  }

  mutating func reset() {
    observations.removeAll()
    activeIdentity = .none
    unknownGoodFaceCount = 0
  }
}
