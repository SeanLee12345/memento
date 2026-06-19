import Foundation

enum AssistanceIdentityState: Equatable {
  case known(name: String, confidence: Float, userConfirmed: Bool)
  case possibleMatch(name: String, confidence: Float)
  case unknown
  case noFaceDetected
  case multipleFaces(count: Int)
}

struct AssistanceMemorySnapshot: Equatable {
  var lastInteraction: String?
  var lastSeen: String?
  var conversationSummary: String?
  var contextTopics: [String]
  var reminder: String?
  var suggestedAction: String?

  init(
    lastInteraction: String? = nil,
    lastSeen: String? = nil,
    conversationSummary: String? = nil,
    contextTopics: [String] = [],
    reminder: String? = nil,
    suggestedAction: String? = nil
  ) {
    self.lastInteraction = lastInteraction
    self.lastSeen = lastSeen
    self.conversationSummary = conversationSummary
    self.contextTopics = contextTopics
    self.reminder = reminder
    self.suggestedAction = suggestedAction
  }
}

struct PersonConversationSummary: Equatable {
  let personId: UUID
  let displayName: String
  let lastSeenText: String
  let summary: String
  let conversationCount: Int
  let generatedAt: Date
}

struct LiveTranscriptMemoryTrigger: Equatable, Sendable {
  enum Kind: String, Equatable, Sendable {
    case question
    case pastReference
    case similarConversation
  }

  let kind: Kind
  let confidence: Float
  let reason: String
}

struct LiveTranscriptMemoryTriggerResolver {
  static func resolve(text: String) -> LiveTranscriptMemoryTrigger? {
    let normalized = normalize(text)
    guard normalized.count >= 8 else { return nil }

    if containsAny(normalized, phrases: similarReferencePhrases) {
      return LiveTranscriptMemoryTrigger(
        kind: .similarConversation,
        confidence: 0.86,
        reason: "similarConversationPhrase"
      )
    }

    if containsAny(normalized, phrases: pastReferencePhrases) {
      return LiveTranscriptMemoryTrigger(
        kind: .pastReference,
        confidence: 0.82,
        reason: "pastReferencePhrase"
      )
    }

    if isMemoryQuestion(normalized) {
      return LiveTranscriptMemoryTrigger(
        kind: .question,
        confidence: 0.74,
        reason: "memoryQuestion"
      )
    }

    return nil
  }

  private static let similarReferencePhrases: [String] = [
    "similar to last time",
    "like last time",
    "like before",
    "same as last time",
    "same conversation",
    "this again",
    "we had this conversation"
  ]

  private static let pastReferencePhrases: [String] = [
    "remember when",
    "do you remember",
    "can you remind",
    "last time",
    "last week",
    "yesterday",
    "earlier today",
    "previously",
    "before",
    "we talked about",
    "we discussed",
    "what did we",
    "where were we",
    "where did we",
    "when did we",
    "who did we",
    "follow up on"
  ]

  private static let memoryQuestionPrefixes: [String] = [
    "what did we",
    "what was the",
    "what were the",
    "where did we",
    "when did we",
    "who did we",
    "did we",
    "have we",
    "can you remind",
    "do you remember",
    "do you know what"
  ]

  private static let memoryQuestionTerms: [String] = [
    "remember",
    "last",
    "before",
    "previous",
    "earlier",
    "talked",
    "discussed",
    "decided",
    "agreed",
    "follow up",
    "met",
    "conversation"
  ]

  private static func isMemoryQuestion(_ normalized: String) -> Bool {
    let questionLike = normalized.hasSuffix("?")
      || memoryQuestionPrefixes.contains { normalized.hasPrefix($0) }
    guard questionLike else { return false }
    return containsAny(normalized, phrases: memoryQuestionPrefixes)
      || containsAny(normalized, phrases: memoryQuestionTerms)
  }

  private static func containsAny(_ text: String, phrases: [String]) -> Bool {
    phrases.contains { text.contains($0) }
  }

  private static func normalize(_ text: String) -> String {
    text
      .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
      .replacingOccurrences(of: "\n", with: " ")
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

enum LiveTranscriptAnswerMode: String, Codable, Equatable, Sendable {
  case memory
  case general
  case current
  case mixed
  case ignore
}

struct LiveTranscriptResolvedTrigger: Equatable, Sendable {
  let fullText: String
  let answerMode: LiveTranscriptAnswerMode
  let memoryTrigger: LiveTranscriptMemoryTrigger?
  let confidence: Float
  let reason: String
  let mentionedNames: [String]
  let startedAt: Date
  let endedAt: Date

  func replacing(
    fullText: String? = nil,
    answerMode: LiveTranscriptAnswerMode? = nil,
    reason: String? = nil,
    confidence: Float? = nil,
    memoryTrigger: LiveTranscriptMemoryTrigger? = nil
  ) -> LiveTranscriptResolvedTrigger {
    LiveTranscriptResolvedTrigger(
      fullText: fullText ?? self.fullText,
      answerMode: answerMode ?? self.answerMode,
      memoryTrigger: memoryTrigger ?? self.memoryTrigger,
      confidence: confidence ?? self.confidence,
      reason: reason ?? self.reason,
      mentionedNames: mentionedNames,
      startedAt: startedAt,
      endedAt: endedAt
    )
  }
}

enum LiveQuestionThrottleReason: String, Equatable, Sendable {
  case allowed
  case duplicateQuestion
  case nearDuplicateQuestion
}

struct LiveQuestionThrottleEvaluation: Equatable, Sendable {
  let shouldThrottle: Bool
  let reason: LiveQuestionThrottleReason
  let textSimilarity: Double
  let elapsedSeconds: TimeInterval?
}

enum LiveQuestionThrottlePolicy {
  static let previousGeneralThrottleSeconds: TimeInterval = 12
  static let duplicateThrottleSeconds: TimeInterval = 60
  static let nearDuplicateSimilarityThreshold = 0.90

  static func evaluate(
    currentQuestion: String,
    previousQuestion: String,
    currentAt: Date,
    previousAt: Date?
  ) -> LiveQuestionThrottleEvaluation {
    guard let previousAt else {
      return LiveQuestionThrottleEvaluation(
        shouldThrottle: false,
        reason: .allowed,
        textSimilarity: 0,
        elapsedSeconds: nil
      )
    }

    let elapsed = currentAt.timeIntervalSince(previousAt)
    let similarity = textSimilarity(currentQuestion, previousQuestion)
    if similarity >= nearDuplicateSimilarityThreshold,
       elapsed < duplicateThrottleSeconds {
      return LiveQuestionThrottleEvaluation(
        shouldThrottle: true,
        reason: similarity == 1 ? .duplicateQuestion : .nearDuplicateQuestion,
        textSimilarity: similarity,
        elapsedSeconds: elapsed
      )
    }
    return LiveQuestionThrottleEvaluation(
      shouldThrottle: false,
      reason: .allowed,
      textSimilarity: similarity,
      elapsedSeconds: elapsed
    )
  }

  static func textSimilarity(_ lhs: String, _ rhs: String) -> Double {
    let lhsTokens = canonicalContentTokens(lhs)
    let rhsTokens = canonicalContentTokens(rhs)
    guard !lhsTokens.isEmpty, !rhsTokens.isEmpty else {
      return canonicalQuestionText(lhs) == canonicalQuestionText(rhs) ? 1 : 0
    }

    var lhsCounts = Dictionary(lhsTokens.map { ($0, 1) }, uniquingKeysWith: +)
    let rhsCounts = Dictionary(rhsTokens.map { ($0, 1) }, uniquingKeysWith: +)
    var intersectionCount = 0
    for (token, rhsCount) in rhsCounts {
      intersectionCount += min(lhsCounts.removeValue(forKey: token) ?? 0, rhsCount)
    }
    return (2 * Double(intersectionCount)) / Double(lhsTokens.count + rhsTokens.count)
  }

  private static let questionScaffoldingWords: Set<String> = [
    "a", "about", "an", "are", "can", "could", "did", "do", "does", "for", "how",
    "i", "is", "me", "my", "of", "our", "please", "tell", "the", "to", "was", "were",
    "what", "when", "where", "which", "who", "why", "will", "with", "would", "you", "your"
  ]

  private static let numberWords: [String: String] = [
    "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
    "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
    "ten": "10", "eleven": "11", "twelve": "12", "thirteen": "13", "fourteen": "14",
    "fifteen": "15", "sixteen": "16", "seventeen": "17", "eighteen": "18",
    "nineteen": "19", "twenty": "20"
  ]

  private static func canonicalContentTokens(_ text: String) -> [String] {
    let allTokens = canonicalQuestionText(text).split(separator: " ").map(String.init)
    let contentTokens = allTokens.filter { !questionScaffoldingWords.contains($0) }
    return (contentTokens.isEmpty ? allTokens : contentTokens).map { numberWords[$0] ?? $0 }
  }

  private static func canonicalQuestionText(_ text: String) -> String {
    let expanded = text
      .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
      .replacingOccurrences(of: "’", with: "'")
      .replacingOccurrences(of: "what's", with: "what is")
      .replacingOccurrences(of: "who's", with: "who is")
      .replacingOccurrences(of: "where's", with: "where is")
      .replacingOccurrences(of: "when's", with: "when is")
      .replacingOccurrences(of: "how's", with: "how is")
      .replacingOccurrences(of: "+", with: " plus ")
    let scalars = expanded.unicodeScalars.map { scalar -> Character in
      CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : " "
    }
    return String(scalars)
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
  }
}

struct LiveTranscriptTriggerLLMDecision: Codable, Equatable, Sendable {
  let isTrigger: Bool
  let needsMoreTranscript: Bool
  let fullQuestion: String
  let answerMode: LiveTranscriptAnswerMode
  let confidence: Double
  let reason: String

  enum CodingKeys: String, CodingKey {
    case isTrigger
    case needsMoreTranscript
    case fullQuestion
    case answerMode
    case confidence
    case reason
  }

  init(
    isTrigger: Bool,
    needsMoreTranscript: Bool,
    fullQuestion: String,
    answerMode: LiveTranscriptAnswerMode,
    confidence: Double,
    reason: String
  ) {
    self.isTrigger = isTrigger
    self.needsMoreTranscript = needsMoreTranscript
    self.fullQuestion = fullQuestion
    self.answerMode = answerMode
    self.confidence = confidence
    self.reason = reason
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    isTrigger = try container.decode(Bool.self, forKey: .isTrigger)
    needsMoreTranscript = try container.decode(Bool.self, forKey: .needsMoreTranscript)
    fullQuestion = try container.decodeIfPresent(String.self, forKey: .fullQuestion) ?? ""
    let rawMode = try container.decodeIfPresent(String.self, forKey: .answerMode) ?? LiveTranscriptAnswerMode.ignore.rawValue
    answerMode = LiveTranscriptAnswerMode(rawValue: rawMode) ?? .ignore
    confidence = min(max(try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0, 0), 1)
    reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? ""
  }
}

struct LiveTranscriptTriggerLLMRequest: Equatable, Sendable {
  let rollingTranscript: String
  let currentTranscript: String
  let localCandidateQuestion: String
  let localAnswerMode: LiveTranscriptAnswerMode
  let peopleNames: [String]
}

struct LiveTranscriptQuestionObservation: Equatable, Sendable {
  let currentTranscript: String
  let rollingTranscript: String
  let startedAt: Date
  let endedAt: Date
  let localTrigger: LiveTranscriptResolvedTrigger?

  var candidateText: String {
    localTrigger?.fullText ?? LiveTranscriptQuestionRouter.extractQuestionOrTriggerSentence(from: rollingTranscript) ?? rollingTranscript
  }

  var candidateMode: LiveTranscriptAnswerMode {
    localTrigger?.answerMode ?? .ignore
  }
}

struct LiveTranscriptQuestionAssembler {
  private struct Segment: Equatable {
    let text: String
    let startedAt: Date
    let endedAt: Date
  }

  private var segments: [Segment] = []
  private let maxWindowSeconds: TimeInterval

  init(maxWindowSeconds: TimeInterval = 20) {
    self.maxWindowSeconds = maxWindowSeconds
  }

  mutating func reset() {
    segments.removeAll()
  }

  var currentWindowText: String {
    segments.map(\.text).joined(separator: " ")
  }

  mutating func append(
    text: String,
    startedAt: Date?,
    endedAt: Date?,
    people: [PersonNameCandidate] = []
  ) -> LiveTranscriptResolvedTrigger? {
    appendObservation(
      text: text,
      startedAt: startedAt,
      endedAt: endedAt,
      people: people
    )?.localTrigger
  }

  mutating func appendObservation(
    text: String,
    startedAt: Date?,
    endedAt: Date?,
    people: [PersonNameCandidate] = []
  ) -> LiveTranscriptQuestionObservation? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let end = endedAt ?? Date()
    let start = startedAt ?? end
    segments.removeAll { end.timeIntervalSince($0.endedAt) > maxWindowSeconds }
    let previous = segments.map(\.text).joined(separator: " ")
    let merge = AlibabaLiveAudioChunkTranscriber.mergeOverlappingTranscript(
      previousTranscript: previous,
      currentTranscript: trimmed
    )
    guard !merge.deliveredText.isEmpty else { return nil }
    if merge.decision == .replacePartial {
      let windowStart = segments.first?.startedAt ?? start
      segments = [Segment(text: merge.updatedContext, startedAt: windowStart, endedAt: end)]
    } else {
      segments.append(Segment(text: merge.deliveredText, startedAt: start, endedAt: end))
    }
    let windowText = currentWindowText
    let questionText = LiveTranscriptQuestionRouter.extractQuestionOrTriggerSentence(from: windowText)
    let localTrigger = questionText.flatMap {
      LiveTranscriptQuestionRouter.route(
        text: $0,
        startedAt: segments.first?.startedAt ?? start,
        endedAt: end,
        people: people
      )
    }
    return LiveTranscriptQuestionObservation(
      currentTranscript: merge.deliveredText,
      rollingTranscript: windowText,
      startedAt: segments.first?.startedAt ?? start,
      endedAt: end,
      localTrigger: localTrigger
    )
  }
}

struct LiveTranscriptQuestionRouter {
  static func route(
    text: String,
    startedAt: Date = Date(),
    endedAt: Date = Date(),
    people: [PersonNameCandidate] = []
  ) -> LiveTranscriptResolvedTrigger? {
    let originalText = normalizeSpaces(text)
    let fullText = normalizeSpaces(trimmedTriggerClause(from: originalText) ?? originalText)
    guard fullText.count >= 4 else { return nil }
    let normalized = normalizedSearchText(fullText)
    let memoryTrigger = LiveTranscriptMemoryTriggerResolver.resolve(text: fullText)
    let mentioned = mentionedNames(in: originalText, people: people)
    let answerMode: LiveTranscriptAnswerMode
    let reason: String
    let confidence: Float

    if let memoryTrigger {
      let hasGeneralTopic = containsAny(normalized, phrases: generalQuestionPrefixes)
        || containsAny(normalized, phrases: generalKnowledgeTerms)
      answerMode = hasGeneralTopic && containsAny(normalized, phrases: memoryTerms)
        ? .mixed
        : .memory
      reason = memoryTrigger.reason
      confidence = memoryTrigger.confidence
    } else if isCurrentQuestion(normalized) {
      answerMode = .current
      reason = "currentQuestion"
      confidence = 0.78
    } else if isGeneralQuestion(normalized) {
      answerMode = .general
      reason = "generalQuestion"
      confidence = 0.72
    } else {
      return nil
    }

    guard !isIncompleteTrigger(normalized, answerMode: answerMode) else {
      return nil
    }

    return LiveTranscriptResolvedTrigger(
      fullText: fullText,
      answerMode: answerMode,
      memoryTrigger: memoryTrigger,
      confidence: confidence,
      reason: reason,
      mentionedNames: mentioned,
      startedAt: startedAt,
      endedAt: endedAt
    )
  }

  static func extractQuestionOrTriggerSentence(from text: String) -> String? {
    let cleaned = normalizeSpaces(text)
    guard !cleaned.isEmpty else { return nil }
    let sentences = splitSentences(cleaned)
    if let matching = sentences.reversed().first(where: { route(text: $0) != nil }) {
      return trimmedTriggerClause(from: matching) ?? matching
    }
    return trimmedTriggerClause(from: cleaned)
  }

  static func normalizedSearchText(_ text: String) -> String {
    text
      .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
      .replacingOccurrences(of: "\n", with: " ")
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func shouldWaitForMoreTranscript(_ text: String) -> Bool {
    let normalized = normalizedSearchText(text)
    guard !normalized.isEmpty, isQuestionLike(normalized) else { return false }

    if containsAny(normalized, phrases: generalQuestionPrefixes)
      || containsAny(normalized, phrases: generalKnowledgeTerms) {
      return isIncompleteTrigger(normalized, answerMode: .general)
    }

    if containsAny(normalized, phrases: currentQuestionTerms) {
      return isIncompleteTrigger(normalized, answerMode: .current)
    }

    if containsAny(normalized, phrases: memoryQuestionStarts)
      || containsAny(normalized, phrases: memoryTerms) {
      return isIncompleteTrigger(normalized, answerMode: .memory)
    }

    return false
  }

  static func shouldSendToLLMTriggerClassifier(_ text: String) -> Bool {
    let normalized = normalizedSearchText(text)
    guard !normalized.isEmpty else { return false }
    let tokenCount = normalized.split(whereSeparator: \.isWhitespace).count
    if isQuestionLike(normalized) { return tokenCount >= 2 }
    if containsAny(normalized, phrases: memoryQuestionStarts)
      || containsAny(normalized, phrases: memoryTerms) {
      return tokenCount >= 4
    }
    if normalized.hasPrefix("tell me") {
      return tokenCount >= 4
    }
    return false
  }

  private static let memoryTerms = [
    "last time", "previous", "previously", "before", "earlier",
    "remember", "say last", "said last", "talked", "discussed"
  ]

  private static let memoryQuestionStarts = [
    "what did we", "what did you", "what did he", "what did she",
    "what did they", "what were we", "where were we", "do you remember",
    "can you remind", "remember when"
  ]

  private static let generalQuestionPrefixes = [
    "what is", "what are", "who is", "who are", "where is", "where are",
    "when is", "when are", "how many", "how much", "why is", "why are",
    "which", "define", "explain"
  ]

  private static let generalKnowledgeTerms = [
    "capital", "country", "city", "president", "definition", "meaning"
  ]

  private static let currentQuestionTerms = [
    "today", "right now", "current", "currently", "latest", "newest",
    "news", "weather", "stock", "price", "schedule", "tomorrow", "this week",
    "what happened"
  ]

  private static let incompleteTrailingTerms = [
    "a", "an", "the", "of", "for", "with", "about", "in", "on", "at", "to",
    "from", "by", "capital", "president", "weather", "news", "price", "schedule",
    "united"
  ]

  private static func isCurrentQuestion(_ normalized: String) -> Bool {
    isQuestionLike(normalized) && containsAny(normalized, phrases: currentQuestionTerms)
  }

  private static func isGeneralQuestion(_ normalized: String) -> Bool {
    guard isQuestionLike(normalized) else { return false }
    return containsAny(normalized, phrases: generalQuestionPrefixes)
      || containsAny(normalized, phrases: generalKnowledgeTerms)
  }

  private static func isIncompleteTrigger(_ normalized: String, answerMode: LiveTranscriptAnswerMode) -> Bool {
    let tokenCount = normalized.split(whereSeparator: \.isWhitespace).count
    switch answerMode {
    case .memory, .mixed:
      return tokenCount < 5 && !containsAny(normalized, phrases: memoryTerms)
    case .general:
      return tokenCount < 4 || hasIncompleteTrailingTerm(normalized)
    case .current:
      return tokenCount < 3 || hasIncompleteTrailingTerm(normalized)
    case .ignore:
      return true
    }
  }

  private static func hasIncompleteTrailingTerm(_ normalized: String) -> Bool {
    guard let last = normalized
      .split(whereSeparator: \.isWhitespace)
      .last
      .map(String.init)?
      .trimmingCharacters(in: CharacterSet.alphanumerics.inverted) else {
      return true
    }
    return incompleteTrailingTerms.contains(last)
  }

  private static func isQuestionLike(_ normalized: String) -> Bool {
    normalized.hasSuffix("?")
      || containsAny(normalized, phrases: memoryQuestionStarts)
      || containsAny(normalized, phrases: generalQuestionPrefixes)
      || normalized.hasPrefix("tell me")
  }

  private static func trimmedTriggerClause(from text: String) -> String? {
    let normalized = normalizedSearchText(text)
    let starts = (memoryQuestionStarts + generalQuestionPrefixes)
      .compactMap { phrase -> String.Index? in
        guard let range = normalized.range(of: phrase) else { return nil }
        let offset = normalized.distance(from: normalized.startIndex, to: range.lowerBound)
        return text.index(text.startIndex, offsetBy: min(offset, text.count))
      }
    guard let start = starts.min() else { return nil }
    return normalizeSpaces(String(text[start...]))
  }

  private static func mentionedNames(in text: String, people: [PersonNameCandidate]) -> [String] {
    let normalized = normalizedSearchText(text)
    let listed = people
      .map(\.displayName)
      .filter { !normalizedSearchText($0).isEmpty && normalized.contains(normalizedSearchText($0)) }
    if !listed.isEmpty { return Array(NSOrderedSet(array: listed)) as? [String] ?? listed }
    let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
    let guessed = tokens.compactMap { token -> String? in
      let trimmed = token.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
      guard trimmed.count >= 3, trimmed.first?.isUppercase == true else { return nil }
      guard !["What", "Where", "When", "Who", "Why", "How", "Tell"].contains(trimmed) else { return nil }
      return trimmed
    }
    return Array(NSOrderedSet(array: guessed)) as? [String] ?? guessed
  }

  private static func splitSentences(_ text: String) -> [String] {
    var sentences: [String] = []
    var current = ""
    for char in text {
      current.append(char)
      if ".?!".contains(char) {
        let trimmed = normalizeSpaces(current)
        if !trimmed.isEmpty { sentences.append(trimmed) }
        current = ""
      }
    }
    let tail = normalizeSpaces(current)
    if !tail.isEmpty { sentences.append(tail) }
    return sentences
  }

  private static func containsAny(_ text: String, phrases: [String]) -> Bool {
    phrases.contains { text.contains($0) }
  }

  private static func normalizeSpaces(_ text: String) -> String {
    text
      .replacingOccurrences(of: "\n", with: " ")
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

struct LiveMemoryCandidate: Equatable {
  let personId: UUID
  let displayName: String
  let score: Int
  let context: String
  let summaryLine: String
  let contextLine: String
  let lastSeen: Date?
  let conversationStartedAt: Date?
}

struct LiveMemoryCandidateRanker {
  static func rankedCandidates(
    for trigger: LiveTranscriptResolvedTrigger,
    entries: [PersonDictionaryEntry],
    attribution: TranscriptAttribution,
    activePersonIds: Set<UUID> = []
  ) -> [LiveMemoryCandidate] {
    let normalizedQuery = LiveTranscriptQuestionRouter.normalizedSearchText(trigger.fullText)
    let queryTokens = memorySearchTokens(trigger.fullText)
    let namedPeople = Set(trigger.mentionedNames.map(LiveTranscriptQuestionRouter.normalizedSearchText))
    let scopedEntries = namedPeople.isEmpty
      ? entries
      : entries.filter { namedPeople.contains(LiveTranscriptQuestionRouter.normalizedSearchText($0.displayName)) }

    let scored = scopedEntries.compactMap { entry -> LiveMemoryCandidate? in
      guard var candidate = candidate(
        for: entry,
        queryTokens: queryTokens,
        normalizedQuery: normalizedQuery
      ) else { return nil }
      var score = candidate.score
      if activePersonIds.contains(entry.id) { score += 80 }
      if attribution.personId == entry.id { score += 40 }
      if normalizedQuery.contains(LiveTranscriptQuestionRouter.normalizedSearchText(entry.displayName)) { score += 60 }
      if attribution.displayName?.localizedCaseInsensitiveContains(entry.displayName) == true { score += 40 }
      candidate = LiveMemoryCandidate(
        personId: candidate.personId,
        displayName: candidate.displayName,
        score: score,
        context: candidate.context,
        summaryLine: candidate.summaryLine,
        contextLine: candidate.contextLine,
        lastSeen: candidate.lastSeen,
        conversationStartedAt: candidate.conversationStartedAt
      )
      return candidate
    }

    let meaningful = scored.filter { $0.score > 0 }
    let candidates = meaningful.isEmpty ? scored : meaningful
    return candidates
      .sorted {
        if $0.score != $1.score { return $0.score > $1.score }
        if ($0.conversationStartedAt ?? .distantPast) != ($1.conversationStartedAt ?? .distantPast) {
          return ($0.conversationStartedAt ?? .distantPast) > ($1.conversationStartedAt ?? .distantPast)
        }
        return ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast)
      }
      .prefix(3)
      .map { $0 }
  }

  private static func candidate(
    for entry: PersonDictionaryEntry,
    queryTokens: Set<String>,
    normalizedQuery: String
  ) -> LiveMemoryCandidate? {
    let conversations = entry.conversationTranscripts
      .filter { !$0.lines.isEmpty || !$0.sceneContexts.isEmpty }
      .sorted { $0.startedAt > $1.startedAt }
    let sceneContexts = entry.sceneContexts.sorted { $0.startedAt > $1.startedAt }
    guard !conversations.isEmpty || !sceneContexts.isEmpty else { return nil }

    var contextBlocks: [String] = []
    var searchBlob = LiveTranscriptQuestionRouter.normalizedSearchText(entry.displayName)
    var summaryLine = "Previous with \(entry.displayName): saved memory is available."
    var contextLine = "Context: no scene context attached."
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .short

    for conversation in conversations.prefix(3) {
      let transcriptText = conversation.lines
        .suffix(10)
        .map { "\($0.speakerName): \($0.chunk.text.trimmingCharacters(in: .whitespacesAndNewlines))" }
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .joined(separator: " ")
      let sceneText = conversation.sceneContexts
        .prefix(2)
        .map { "\($0.summary) Where: \($0.whereText) What: \($0.what) Why: \($0.why)" }
        .joined(separator: " ")
      let dateText = formatter.string(from: conversation.startedAt)
      let block = [
        "Person: \(entry.displayName)",
        "When: \(dateText)",
        transcriptText.isEmpty ? nil : "Transcript: \(transcriptText)",
        sceneText.isEmpty ? nil : "Context: \(sceneText)"
      ]
      .compactMap { $0 }
      .joined(separator: "\n")
      contextBlocks.append(block)
      searchBlob += " " + LiveTranscriptQuestionRouter.normalizedSearchText(block)
      if summaryLine.hasSuffix("available.") {
        summaryLine = "Previous with \(entry.displayName) \(dateText): \(truncated(transcriptText.isEmpty ? sceneText : transcriptText, maxLength: 130))"
      }
      if !sceneText.isEmpty, contextLine.hasSuffix("attached.") {
        contextLine = "Context: \(truncated(sceneText, maxLength: 150))"
      }
    }

    if conversations.isEmpty {
      for record in sceneContexts.prefix(3) {
        let dateText = formatter.string(from: record.startedAt)
        let block = """
        Person: \(entry.displayName)
        When: \(dateText)
        Context: \(record.summary) Where: \(record.whereText) What: \(record.what) Why: \(record.why)
        """
        contextBlocks.append(block)
        searchBlob += " " + LiveTranscriptQuestionRouter.normalizedSearchText(block)
        if summaryLine.hasSuffix("available.") {
          summaryLine = "Previous with \(entry.displayName) \(dateText): \(truncated(record.summary, maxLength: 130))"
        }
        if contextLine.hasSuffix("attached.") {
          contextLine = "Context: \(truncated(record.whereText + " " + record.what, maxLength: 150))"
        }
      }
    }

    let score = queryTokens.reduce(0) { partial, token in
      searchBlob.contains(token) ? partial + 1 : partial
    }
    let nameMentionScore = normalizedQuery.contains(LiveTranscriptQuestionRouter.normalizedSearchText(entry.displayName)) ? 6 : 0
    let context = contextBlocks.joined(separator: "\n\n")
    guard !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return LiveMemoryCandidate(
      personId: entry.id,
      displayName: entry.displayName,
      score: score + nameMentionScore,
      context: truncated(context, maxLength: 2_400),
      summaryLine: truncated(summaryLine, maxLength: 180),
      contextLine: truncated(contextLine, maxLength: 180),
      lastSeen: entry.lastSeen,
      conversationStartedAt: conversations.first?.startedAt
    )
  }

  private static func memorySearchTokens(_ text: String) -> Set<String> {
    let stop: Set<String> = [
      "what", "when", "where", "who", "why", "how", "did", "does", "the",
      "and", "with", "last", "time", "about", "that", "this", "were", "was",
      "say", "said", "we", "you", "me", "our"
    ]
    return Set(
      LiveTranscriptQuestionRouter.normalizedSearchText(text)
        .split(whereSeparator: \.isWhitespace)
        .map(String.init)
        .map { $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
        .filter { $0.count >= 3 && !stop.contains($0) }
    )
  }

  private static func truncated(_ text: String, maxLength: Int) -> String {
    guard text.count > maxLength else { return text }
    return String(text.prefix(maxLength)) + "..."
  }
}

struct LiveMemoryAnswerPolicy {
  static let noRelevantSavedMemoryLine = "No relevant saved memory."
}

enum LiveTranscriptAnswerDisplayTarget: Equatable {
  case liveHome
}

struct LiveTranscriptAnswerPresentationPolicy {
  static func target(for trigger: LiveTranscriptResolvedTrigger) -> LiveTranscriptAnswerDisplayTarget {
    switch trigger.answerMode {
    case .memory, .general, .current, .mixed:
      return .liveHome
    case .ignore:
      return .liveHome
    }
  }
}

struct AssistanceDisplayStatus: Equatable {
  enum Output: Equatable {
    case glassesDisplay
    case fallback(String)
    case unavailable(String)
  }

  var output: Output

  static let glassesDisplay = AssistanceDisplayStatus(output: .glassesDisplay)

  static func fallback(_ reason: String) -> AssistanceDisplayStatus {
    AssistanceDisplayStatus(output: .fallback(reason))
  }

  static func unavailable(_ reason: String) -> AssistanceDisplayStatus {
    AssistanceDisplayStatus(output: .unavailable(reason))
  }
}

struct AssistanceDisplayCard: Equatable, Sendable {
  let title: String
  let lines: [String]
  let usesFallbackOutput: Bool
  var sections: [AssistanceDisplaySection] = []
  var personId: UUID?
  var displayName: String?
  var thumbnailImageURI: String?
  var thumbnailImageSize: AssistanceDisplayImageSize = .fill
  var primaryAction: GlassesDisplayAction?
  var secondaryAction: GlassesDisplayAction?
  var tertiaryAction: GlassesDisplayAction?

  var text: String {
    let sectionText = sections.flatMap { [$0.title] + $0.lines }
    return ([title] + lines + sectionText).joined(separator: "\n")
  }
}

struct AssistanceDisplaySection: Equatable, Sendable {
  let title: String
  let lines: [String]
  var thumbnailImageURI: String? = nil
  var thumbnailImageSize: AssistanceDisplayImageSize = .fill
}

enum AssistanceDisplayImageSize: String, Equatable, Sendable {
  case icon
  case fill
}

enum GlassesDisplayAction: String, CaseIterable, Codable, Equatable, Sendable {
  case displayed
  case openPeople
  case startStream
  case stopStream
  case openContext
  case openTranscripts
  case snapshotFrame
  case markReviewed
  case hideCard
  case backToHome
  case nextPage
  case previousPage
  case confirmRecognizedPerson
  case rejectRecognizedPerson
  case confirmUnknownPerson
  case rejectUnknownPerson
  case confirmSelectedPerson
  case selectUnknownPerson

  var buttonTitle: String {
    switch self {
    case .displayed:
      return ""
    case .openPeople:
      return "People"
    case .startStream:
      return "Start Stream"
    case .stopStream:
      return "Stop"
    case .openContext:
      return "Context"
    case .openTranscripts:
      return "Transcript"
    case .snapshotFrame:
      return "Photo"
    case .markReviewed:
      return "Reviewed"
    case .hideCard:
      return "Hide"
    case .backToHome:
      return "Back"
    case .nextPage:
      return "More"
    case .previousPage:
      return "Previous"
    case .confirmRecognizedPerson, .confirmUnknownPerson, .confirmSelectedPerson:
      return "Yes"
    case .rejectRecognizedPerson, .rejectUnknownPerson:
      return "No"
    case .selectUnknownPerson:
      return "Unknown"
    }
  }

  var eventTitle: String {
    switch self {
    case .displayed:
      return "Shown"
    case .openPeople:
      return "People opened"
    case .startStream:
      return "Start stream"
    case .stopStream:
      return "Stop stream"
    case .openContext:
      return "Context opened"
    case .openTranscripts:
      return "Transcripts opened"
    case .snapshotFrame:
      return "Photo saved"
    case .markReviewed:
      return "Reviewed"
    case .hideCard:
      return "Hidden"
    case .backToHome:
      return "Back"
    case .nextPage:
      return "Next page"
    case .previousPage:
      return "Previous page"
    case .confirmRecognizedPerson:
      return "Confirmed recognized person"
    case .rejectRecognizedPerson:
      return "Rejected recognized person"
    case .confirmUnknownPerson:
      return "Confirmed unknown person"
    case .rejectUnknownPerson:
      return "Rejected unknown person"
    case .confirmSelectedPerson:
      return "Selected person"
    case .selectUnknownPerson:
      return "Selected unknown person"
    }
  }

  var isPinnedStreamControl: Bool {
    switch self {
    case .stopStream, .openPeople, .previousPage, .nextPage:
      return true
    default:
      return false
    }
  }

  var isIdentityPromptAction: Bool {
    switch self {
    case .confirmRecognizedPerson,
         .rejectRecognizedPerson,
         .confirmUnknownPerson,
         .rejectUnknownPerson,
         .confirmSelectedPerson,
         .selectUnknownPerson:
      return true
    default:
      return false
    }
  }
}

struct MementoGlassesDisplayRenderer {
  static func liveViewSections(
    assistanceCard: AssistanceDisplayCard?,
    recallSection: AssistanceDisplaySection?,
    identityPromptSection: AssistanceDisplaySection?,
    identityPhotoSection: AssistanceDisplaySection? = nil,
    statusLine: String,
    isStreaming: Bool,
    streamTitle: String = "Transport streaming",
    streamModeLine: String = "Mode: General - looking around",
    recognizedPeopleLine: String = "Recognized people: None",
    readinessLine: String = "Context: visual waiting, speech waiting, face on demand"
  ) -> [AssistanceDisplaySection] {
    liveViewSections(
      assistanceCard: assistanceCard,
      recallSections: recallSection.map { [$0] } ?? [],
      identityPromptSection: identityPromptSection,
      identityPhotoSection: identityPhotoSection,
      statusLine: statusLine,
      isStreaming: isStreaming,
      streamTitle: streamTitle,
      streamModeLine: streamModeLine,
      recognizedPeopleLine: recognizedPeopleLine,
      readinessLine: readinessLine
    )
  }

  static func liveViewSections(
    assistanceCard: AssistanceDisplayCard?,
    recallSections: [AssistanceDisplaySection],
    identityPromptSection: AssistanceDisplaySection?,
    identityPhotoSection: AssistanceDisplaySection? = nil,
    statusLine: String,
    isStreaming: Bool,
    streamTitle: String = "Transport streaming",
    streamModeLine: String = "Mode: General - looking around",
    recognizedPeopleLine: String = "Recognized people: None",
    readinessLine: String = "Context: visual waiting, speech waiting, face on demand"
  ) -> [AssistanceDisplaySection] {
    var sections: [AssistanceDisplaySection] = []
    if let identityPromptSection {
      sections.append(identityPromptSection)
    }
    if let identityPhotoSection {
      sections.append(identityPhotoSection)
    }
    if isStreaming {
      sections.append(contentsOf: recallSections)
      sections.append(AssistanceDisplaySection(
        title: streamTitle,
        lines: [streamModeLine, recognizedPeopleLine, readinessLine]
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter { !$0.isEmpty }
      ))
      return sections
    }

    if let assistanceCard {
      sections.append(AssistanceDisplaySection(title: assistanceCard.title, lines: assistanceCard.lines))
      return sections
    }

    return sections
  }

  static func confirmedPersonSummarySection(
    for summary: PersonConversationSummary,
    presentPeople: [String] = []
  ) -> AssistanceDisplaySection {
    let presentLine = presentPeople.isEmpty
      ? nil
      : "Present with you: \(presentPeople.joined(separator: ", "))"
    return AssistanceDisplaySection(
      title: "Last with \(summary.displayName)",
      lines: [presentLine, "Summary: \(conciseInteractionSummary(summary.summary))"].compactMap { $0 }
    )
  }

  static func conciseInteractionSummary(_ summary: String, maxLength: Int = 120) -> String {
    var text = normalizedDisplaySummaryText(summary)
    if let range = text.range(of: "Recent context:", options: .caseInsensitive) {
      text = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if text.localizedCaseInsensitiveContains("Conversation") {
      let timestampMarker = [" AM: ", " PM: "]
        .compactMap { text.range(of: $0, options: .caseInsensitive) }
        .min { $0.lowerBound < $1.lowerBound }
      if let timestampMarker {
        text = String(text[timestampMarker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
      } else if let colon = text.firstIndex(of: ":") {
        let prefix = String(text[..<colon])
        if prefix.localizedCaseInsensitiveContains("Conversation") {
          text = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
      }
    }
    if text.isEmpty {
      return "No saved attributed conversations yet."
    }
    return truncated(text, maxLength: maxLength)
  }

  private static func normalizedDisplaySummaryText(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\n", with: " ")
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func ready(canStartStream: Bool, deviceLine: String, readinessLine: String) -> AssistanceDisplayCard {
    AssistanceDisplayCard(
      title: "Ready",
      lines: [
        deviceLine,
        readinessLine,
        canStartStream ? "Use Start Stream to begin camera input." : "Resolve the readiness item, then start streaming."
      ],
      usesFallbackOutput: false,
      primaryAction: .startStream,
      secondaryAction: .openPeople
    )
  }

  static func streamStatus(title: String, message: String, allowStop: Bool = true) -> AssistanceDisplayCard {
    AssistanceDisplayCard(
      title: title,
      lines: [
        message,
        "Display stays active while the stream prepares."
      ],
      usesFallbackOutput: false,
      primaryAction: allowStop ? .stopStream : nil,
      secondaryAction: .openPeople
    )
  }

  static func streaming(
    currentPersonName: String?,
    frameText: String,
    statusText: String,
    currentLineOverride: String? = nil
  ) -> AssistanceDisplayCard {
    let name = currentPersonName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let override = currentLineOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
    let currentLine: String
    if override?.isEmpty == false {
      currentLine = override!
    } else if name?.isEmpty == false {
      currentLine = "Current: \(name!)"
    } else {
      currentLine = "Current: Looking for people"
    }
    return AssistanceDisplayCard(
      title: "Streaming",
      lines: [
        currentLine,
        "Frames: \(frameText)",
        statusText
      ],
      usesFallbackOutput: false,
      primaryAction: .stopStream,
      secondaryAction: .openPeople
    )
  }

  static func peopleList(
    entries: [PersonDictionaryEntry],
    currentPersonId: UUID?,
    page: Int,
    pageSize: Int = 4
  ) -> AssistanceDisplayCard {
    let ordered = entries.sorted { left, right in
      if left.id == currentPersonId { return true }
      if right.id == currentPersonId { return false }
      return (left.lastSeen ?? .distantPast) > (right.lastSeen ?? .distantPast)
    }
    let safePageSize = max(1, pageSize)
    let maxPage = max(0, (ordered.count - 1) / safePageSize)
    let clampedPage = min(max(page, 0), maxPage)
    let start = clampedPage * safePageSize
    let pageEntries = ordered.isEmpty
      ? []
      : Array(ordered[start..<min(start + safePageSize, ordered.count)])
    let lines: [String]
    if pageEntries.isEmpty {
      lines = ["No saved people yet.", "Recognized people will appear here."]
    } else {
      lines = pageEntries.enumerated().map { index, entry in
        let prefix = entry.id == currentPersonId ? "Current" : "\(start + index + 1)"
        let transcriptText = briefTranscriptText(entry.transcripts)
        return "\(prefix): \(entry.displayName) - \(lastSeenText(entry.lastSeen)), \(transcriptText)"
      }
    }
    return AssistanceDisplayCard(
      title: ordered.isEmpty ? "People" : "People \(clampedPage + 1)/\(maxPage + 1)",
      lines: lines,
      usesFallbackOutput: false,
      personId: currentPersonId,
      displayName: ordered.first(where: { $0.id == currentPersonId })?.displayName,
      primaryAction: .stopStream,
      secondaryAction: .backToHome
    )
  }

  static func photoStatus(success: Bool) -> AssistanceDisplayCard {
    AssistanceDisplayCard(
      title: success ? "Photo saved" : "Waiting for frame",
      lines: [
        success ? "Saved the latest video stream frame." : "No video frame is available yet.",
        "This uses the live stream frame, not DAT photo capture."
      ],
      usesFallbackOutput: false,
      primaryAction: .stopStream,
      secondaryAction: .openPeople
    )
  }

  private static func liveMemoryLine(from card: AssistanceDisplayCard) -> String {
    let lines = card.lines
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }

    let preferredPrefixes = ["Summary:", "Last seen:", "Last:", "Reminder:"]
    for prefix in preferredPrefixes {
      if let line = lines.first(where: { $0.hasPrefix(prefix) }) {
        return line
      }
    }

    if let line = lines.first(where: { !$0.hasPrefix("Confidence:") && !$0.hasPrefix("Needs ") }) {
      return line
    }

    return "Memory: No saved person memory yet."
  }

  private static func briefTranscriptText(_ transcripts: [TranscriptChunk]) -> String {
    let latestText = transcripts
      .sorted { left, right in
        left.transcriptUpdatedAt > right.transcriptUpdatedAt
      }
      .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty }

    guard let latestText else { return "no transcript yet" }
    return "said: \"\(truncated(latestText, maxLength: 64))\""
  }

  private static func truncated(_ value: String, maxLength: Int) -> String {
    guard value.count > maxLength else { return value }
    let endIndex = value.index(value.startIndex, offsetBy: maxLength)
    return String(value[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
  }

  private static func lastSeenText(_ date: Date?) -> String {
    guard let date else { return "never seen" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
  }
}

struct AssistanceCardFormatter {
  var lowConfidenceThreshold: Float = 0.70
  var maximumLineCount = 4
  var maximumLineLength = 2_000

  func makeCard(
    identity: AssistanceIdentityState,
    memory: AssistanceMemorySnapshot,
    displayStatus: AssistanceDisplayStatus
  ) -> AssistanceDisplayCard {
    let title = titleText(for: identity)
    var lines = detailLines(for: identity, memory: memory)
    let fallback = fallbackLine(for: displayStatus)
    let usesFallback = fallback != nil

    if let fallback {
      lines.insert(fallback, at: 0)
    }

    lines = lines
      .map { trimLine($0) }
      .filter { !$0.isEmpty }

    if lines.count > maximumLineCount {
      lines = Array(lines.prefix(maximumLineCount))
    }

    return AssistanceDisplayCard(
      title: trimLine(title),
      lines: lines,
      usesFallbackOutput: usesFallback
    )
  }

  private func titleText(for identity: AssistanceIdentityState) -> String {
    switch identity {
    case .known(let name, _, _):
      return sanitized(name, fallback: "Known person")
    case .possibleMatch(let name, _):
      return "Possible: \(sanitized(name, fallback: "match"))"
    case .unknown:
      return "Unknown person"
    case .noFaceDetected:
      return "No face detected"
    case .multipleFaces(let count):
      return "\(max(count, 2)) faces detected"
    }
  }

  private func detailLines(
    for identity: AssistanceIdentityState,
    memory: AssistanceMemorySnapshot
  ) -> [String] {
    switch identity {
    case .known(_, let confidence, let userConfirmed):
      return knownLines(confidence: confidence, userConfirmed: userConfirmed, memory: memory)
    case .possibleMatch(_, let confidence):
      return possibleMatchLines(confidence: confidence, memory: memory)
    case .unknown:
      return ["Needs confirmation", memoryLine(memory) ?? "No memory found"]
    case .noFaceDetected:
      return ["Camera input active", "Waiting for visible face"]
    case .multipleFaces:
      return ["Select one person", "Hide private details"]
    }
  }

  private func knownLines(
    confidence: Float,
    userConfirmed: Bool,
    memory: AssistanceMemorySnapshot
  ) -> [String] {
    var lines: [String] = []

    if !userConfirmed || confidence < lowConfidenceThreshold {
      lines.append("Confirm before using memory")
    }

    if let lastSeen = memory.lastSeen, !lastSeen.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      lines.append("Last seen: \(lastSeen)")
    } else if let last = memory.lastInteraction, !last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      lines.append("Last: \(last)")
    } else {
      lines.append("No memory found")
    }

    if let summary = memory.conversationSummary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      lines.append("Summary: \(summary)")
    }

    if let context = contextLine(memory.contextTopics) {
      lines.append(context)
    }

    if let reminder = memory.reminder, !reminder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      lines.append("Reminder: \(reminder)")
    } else if let action = memory.suggestedAction, !action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      lines.append("Next: \(action)")
    }

    return lines
  }

  private func possibleMatchLines(
    confidence: Float,
    memory: AssistanceMemorySnapshot
  ) -> [String] {
    var lines = [
      "Confidence: \(Int((confidence * 100).rounded()))%",
      "Needs user confirmation"
    ]

    if confidence < lowConfidenceThreshold {
      lines.append("Privacy: hide sensitive details")
    } else if let summary = memoryLine(memory) {
      lines.append(summary)
    }

    return lines
  }

  private func memoryLine(_ memory: AssistanceMemorySnapshot) -> String? {
    if let reminder = memory.reminder, !reminder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return "Reminder: \(reminder)"
    }

    if let last = memory.lastInteraction, !last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return "Last: \(last)"
    }

    if let context = contextLine(memory.contextTopics) {
      return context
    }

    return nil
  }

  private func contextLine(_ topics: [String]) -> String? {
    let visibleTopics = topics
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .prefix(3)

    guard !visibleTopics.isEmpty else { return nil }
    return "Context: \(visibleTopics.joined(separator: ", "))"
  }

  private func fallbackLine(for status: AssistanceDisplayStatus) -> String? {
    switch status.output {
    case .glassesDisplay:
      return nil
    case .fallback(let reason):
      return "Fallback: \(reason)"
    case .unavailable(let reason):
      return "Display unavailable: \(reason)"
    }
  }

  private func sanitized(_ value: String, fallback: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? fallback : trimmed
  }

  private func trimLine(_ line: String) -> String {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > maximumLineLength else { return trimmed }

    let end = trimmed.index(trimmed.startIndex, offsetBy: max(0, maximumLineLength - 1))
    return String(trimmed[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
  }
}
