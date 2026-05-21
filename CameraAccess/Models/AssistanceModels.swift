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

struct AssistanceDisplayCard: Equatable {
  let title: String
  let lines: [String]
  let usesFallbackOutput: Bool

  var text: String {
    ([title] + lines).joined(separator: "\n")
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
