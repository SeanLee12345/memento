import Foundation
import UIKit

@MainActor
final class SceneContextPipeline {
  private var frames: [SceneFrameSnapshot] = []
  private var transcripts: [SceneTranscriptSnapshot] = []
  private var lastFrameSampleAt: Date?
  private var lastAnalysisAt: Date?
  private var isSubmitting = false
  private var generation = UUID()
  private var onStatus: ((String) -> Void)?
  private var onRecord: ((SceneContextRecord) async -> Void)?

  private let maxFrames = 5
  private let maxTranscripts = 8
  private let frameSampleInterval: TimeInterval = 5
  private let analysisInterval: TimeInterval = 5

  func start(
    onStatus: @escaping (String) -> Void,
    onRecord: @escaping (SceneContextRecord) async -> Void
  ) {
    self.onStatus = onStatus
    self.onRecord = onRecord
    generation = UUID()
    let settings = SceneContextSettings.load()
    if SupabaseEdgeFunctionClient.isConfigured() {
      onStatus("Scene context proxy listening: \(settings.model)")
    } else if settings.apiKey.isEmpty {
      onStatus("Scene context key missing")
    } else {
      onStatus("Scene context listening: \(settings.model)")
    }
  }

  func stop() {
    generation = UUID()
    frames.removeAll()
    transcripts.removeAll()
    isSubmitting = false
    onStatus?("Scene context stopped")
  }

  @discardableResult
  func captureFrame(image: UIImage, timestamp: Date) -> Bool {
    guard SceneContextSettings.load().enabled else { return false }
    if let lastFrameSampleAt, timestamp.timeIntervalSince(lastFrameSampleAt) < frameSampleInterval {
      return false
    }
    guard let data = Self.resizedJPEGData(from: image, maxDimension: 512) else { return false }
    lastFrameSampleAt = timestamp
    frames.append(SceneFrameSnapshot(timestamp: timestamp, jpegData: data))
    if frames.count > maxFrames {
      frames.removeFirst(frames.count - maxFrames)
    }
    return true
  }

  func captureTranscript(
    id: UUID,
    text: String,
    startedAt: Date?,
    endedAt: Date?,
    personId: UUID?,
    displayName: String?,
    context: PipelineContext?,
    identityEvidence: SceneContextIdentityEvidence?,
    location: SceneLocationSnapshot?
  ) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard SceneContextSettings.load().enabled, !trimmed.isEmpty else { return }
    let start = startedAt ?? Date()
    transcripts.append(SceneTranscriptSnapshot(
      id: id,
      text: trimmed,
      startedAt: start,
      endedAt: endedAt,
      personId: personId,
      displayName: displayName
    ))
    if transcripts.count > maxTranscripts {
      transcripts.removeFirst(transcripts.count - maxTranscripts)
    }
    submitIfReady(context: context, identityEvidence: identityEvidence, location: location)
  }

  func submitLatestIfReady(
    context: PipelineContext?,
    identityEvidence: SceneContextIdentityEvidence?,
    location: SceneLocationSnapshot?
  ) {
    submitIfReady(context: context, identityEvidence: identityEvidence, location: location)
  }

  private func submitIfReady(
    context: PipelineContext?,
    identityEvidence: SceneContextIdentityEvidence?,
    location: SceneLocationSnapshot?
  ) {
    guard let appRunId = context?.appRunId else {
      onStatus?("Scene context waiting for session")
      return
    }
    guard !isSubmitting else { return }
    let settings = SceneContextSettings.load()
    guard settings.enabled else { return }
    guard SupabaseEdgeFunctionClient.isConfigured() || !settings.apiKey.isEmpty else {
      onStatus?("Scene context key missing")
      return
    }
    guard !frames.isEmpty else {
      onStatus?("Scene context waiting for images")
      return
    }
    let now = Date()
    if let lastAnalysisAt, now.timeIntervalSince(lastAnalysisAt) < analysisInterval {
      return
    }

    let requestFrames = frames
    let requestTranscripts = transcripts
    let startedAt = ([requestFrames.map(\.timestamp).min(), requestTranscripts.map(\.startedAt).min()].compactMap { $0 }).min() ?? now
    let endedAt = ([requestFrames.map(\.timestamp).max(), requestTranscripts.compactMap(\.endedAt).max(), requestTranscripts.map(\.startedAt).max()].compactMap { $0 }).max() ?? now
    let request = SceneContextRequest(
      appRunId: appRunId,
      conversationSessionId: context?.conversationSessionId,
      frames: requestFrames,
      transcripts: requestTranscripts,
      identityEvidence: identityEvidence ?? Self.transcriptIdentityEvidence(from: requestTranscripts),
      location: location,
      startedAt: startedAt,
      endedAt: endedAt
    )
    let currentGeneration = generation
    isSubmitting = true
    lastAnalysisAt = now
    onStatus?("Scene context analyzing...")

    Task {
      do {
        let analysis = try await SceneContextClient(settings: settings).analyze(request)
        guard currentGeneration == self.generation else { return }
        let record = Self.record(
          from: analysis,
          request: request,
          settings: settings,
          createdAt: Date()
        )
        await onRecord?(record)
        onStatus?("Scene context saved")
      } catch {
        guard currentGeneration == self.generation else { return }
        onStatus?("Scene context failed: \(error.localizedDescription)")
        AppLogger.log(.sceneContext, "analysis failed: \(error.localizedDescription)")
      }
      if currentGeneration == self.generation {
        isSubmitting = false
      }
    }
  }

  private static func record(
    from analysis: SceneContextAnalysis,
    request: SceneContextRequest,
    settings: SceneContextSettings,
    createdAt: Date
  ) -> SceneContextRecord {
    let personIds = Set(request.transcripts.compactMap(\.personId))
    let personId = personIds.count == 1
      ? personIds.first
      : request.identityEvidence?.conversationPartnerPersonId
    let storedEvidence = uniqueStrings(analysis.evidence + identityEvidenceStrings(from: request.identityEvidence))
    return SceneContextRecord(
      id: UUID(),
      appRunId: request.appRunId,
      conversationSessionId: request.conversationSessionId,
      personId: personId,
      startedAt: request.startedAt,
      endedAt: request.endedAt,
      createdAt: createdAt,
      modelName: settings.model,
      promptVersion: SceneContextSettings.promptVersion,
      transcriptChunkIdsJson: jsonString(request.transcripts.map { $0.id.uuidString }),
      frameTimestampsJson: jsonString(request.frames.map { ISO8601DateFormatter().string(from: $0.timestamp) }),
      locationLabel: request.location?.label,
      latitude: request.location?.latitude,
      longitude: request.location?.longitude,
      locationAccuracyMeters: request.location?.horizontalAccuracy,
      who: analysis.who,
      whereText: analysis.whereText,
      what: analysis.what,
      whenText: analysis.whenText,
      why: analysis.why,
      how: analysis.how,
      interactionStyle: analysis.interactionStyle,
      summary: analysis.summary,
      confidence: analysis.confidence,
      evidenceJson: jsonString(storedEvidence)
    )
  }

  private static func identityEvidenceStrings(from evidence: SceneContextIdentityEvidence?) -> [String] {
    guard let evidence else { return [] }
    var lines: [String] = []
    let confidence = Int((evidence.confidence * 100).rounded())
    if let name = evidence.conversationPartnerName {
      lines.append("App identity: \(name) \(evidence.conversationPartnerState) \(confidence)% via \(evidence.sourceSummary)")
    } else if !evidence.sourceSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      lines.append("App identity: \(evidence.conversationPartnerState) \(confidence)% via \(evidence.sourceSummary)")
    }
    for person in evidence.activePeople {
      let personConfidence = Int((person.confidence * 100).rounded())
      lines.append("Presence active: \(person.displayName) \(personConfidence)% since \(ISO8601DateFormatter().string(from: person.startedAt)) via \(person.evidenceSummary)")
    }
    for person in evidence.departedPeople {
      let personConfidence = Int((person.confidence * 100).rounded())
      let endedAt = person.endedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown"
      lines.append("Presence departed: \(person.displayName) \(personConfidence)% at \(endedAt) via \(person.evidenceSummary)")
    }
    return lines
  }

  private static func uniqueStrings(_ values: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for value in values {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
      result.append(trimmed)
    }
    return result
  }

  private static func transcriptIdentityEvidence(from transcripts: [SceneTranscriptSnapshot]) -> SceneContextIdentityEvidence? {
    let attributed = transcripts.filter { $0.personId != nil || $0.displayName != nil }
    guard !attributed.isEmpty else { return nil }
    let personIds = Set(attributed.compactMap(\.personId))
    let names = attributed.compactMap(\.displayName)
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    let partnerName = names.last
    return SceneContextIdentityEvidence(
      wearerName: nil,
      conversationPartnerName: partnerName,
      conversationPartnerPersonId: personIds.count == 1 ? personIds.first : nil,
      conversationPartnerState: personIds.isEmpty ? "unknown" : "attributedTranscript",
      confidence: personIds.isEmpty ? 0.5 : 0.75,
      sourceSummary: "Transcript attribution"
    )
  }

  private static func jsonString(_ value: [String]) -> String {
    guard let data = try? JSONEncoder().encode(value),
          let text = String(data: data, encoding: .utf8) else {
      return "[]"
    }
    return text
  }

  private static func resizedJPEGData(from image: UIImage, maxDimension: CGFloat) -> Data? {
    let size = image.size
    guard size.width > 0, size.height > 0 else { return image.jpegData(compressionQuality: 0.55) }
    let scale = min(1, maxDimension / max(size.width, size.height))
    let target = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    let renderer = UIGraphicsImageRenderer(size: target, format: format)
    let resized = renderer.image { _ in
      image.draw(in: CGRect(origin: .zero, size: target))
    }
    return resized.jpegData(compressionQuality: 0.55)
  }
}
