/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import CoreVideo
import AVFoundation
import Foundation
import MWDATDisplay
import SwiftUI
import UIKit
import XCTest

@testable import Memento

final class VisionInputSafetyTests: XCTestCase {
  private let resolver = ConversationPartnerResolver()

  func testConversationPartnerConfirmsWhenVoiceAndFaceAgree() {
    let personId = UUID()
    let now = Date()
    let state = resolver.resolve(evidence: [
      partnerEvidence(.voiceLocal, personId: personId, name: "Sean", confidence: 0.82, now: now),
      partnerEvidence(.faceLocal, personId: personId, name: "Sean", confidence: 0.76, now: now),
      partnerEvidence(.mouthMovement, confidence: 0.20, now: now)
    ], now: now)

    XCTAssertEqual(state.phase, .confirmed)
    XCTAssertEqual(state.primary?.personId, personId)
    XCTAssertTrue(state.allowsPrivateMemory)
    XCTAssertTrue(state.sourceSummary.contains("voiceLocal"))
  }

  func testConversationPartnerUserConfirmationImmediatelyConfirmsPerson() {
    let personId = UUID()
    let now = Date()
    let state = resolver.resolve(evidence: [
      partnerEvidence(.userConfirmation, personId: personId, name: "Gary", confidence: 1.0, now: now)
    ], now: now)

    XCTAssertEqual(state.phase, .confirmed)
    XCTAssertEqual(state.primary?.personId, personId)
    XCTAssertEqual(state.primary?.displayName, "Gary")
    XCTAssertTrue(state.allowsPrivateMemory)
    XCTAssertTrue(state.sourceSummary.contains("userConfirmation"))
  }

  func testConversationPartnerUserConfirmationOverridesWearerVoiceSuppression() {
    let personId = UUID()
    let now = Date()
    let state = resolver.resolve(evidence: [
      partnerEvidence(.wearerVoice, confidence: 0.91, now: now),
      partnerEvidence(.userConfirmation, personId: personId, name: "Gary", confidence: 1.0, now: now.addingTimeInterval(1))
    ], now: now.addingTimeInterval(1))

    XCTAssertEqual(state.phase, .confirmed)
    XCTAssertEqual(state.primary?.personId, personId)
    XCTAssertEqual(state.primary?.displayName, "Gary")
  }

  func testConversationPartnerVoiceBeatsSilentVisibleFace() {
    let speakerId = UUID()
    let silentFaceId = UUID()
    let now = Date()
    let state = resolver.resolve(evidence: [
      partnerEvidence(.voiceAWS, personId: speakerId, name: "Speaker", confidence: 0.86, now: now),
      partnerEvidence(.faceLocal, personId: silentFaceId, name: "Visible", confidence: 0.78, now: now),
      partnerEvidence(.mouthMovement, confidence: 0.01, now: now)
    ], now: now)

    XCTAssertEqual(state.phase, .confirmed)
    XCTAssertEqual(state.primary?.personId, speakerId)
  }

  func testConversationPartnerFaceMouthCanIdentifyWhenVoiceAbsent() {
    let personId = UUID()
    let now = Date()
    let state = resolver.resolve(evidence: [
      partnerEvidence(.faceAWS, personId: personId, name: "Mina", confidence: 0.83, now: now),
      partnerEvidence(.mouthMovement, confidence: 0.24, now: now)
    ], now: now)

    XCTAssertEqual(state.phase, .possible)
    XCTAssertEqual(state.primary?.personId, personId)
  }

  func testConversationPartnerMultipleFacesHidePrivateMemory() {
    let now = Date()
    let state = resolver.resolve(evidence: [
      partnerEvidence(.faceLocal, personId: UUID(), name: "A", confidence: 0.74, now: now),
      partnerEvidence(.faceLocal, personId: UUID(), name: "B", confidence: 0.73, now: now),
      partnerEvidence(.mouthMovement, confidence: 0.02, now: now)
    ], now: now)

    XCTAssertEqual(state.phase, .multiplePeople)
    XCTAssertFalse(state.allowsPrivateMemory)
  }

  func testConversationPartnerWearerVoiceSuppressesExternalPartner() {
    let now = Date()
    let state = resolver.resolve(evidence: [
      partnerEvidence(.wearerVoice, confidence: 0.88, now: now),
      partnerEvidence(.faceLocal, personId: UUID(), name: "Visible", confidence: 0.80, now: now)
    ], now: now)

    XCTAssertEqual(state.phase, .unknown)
    XCTAssertNil(state.primary)
    XCTAssertFalse(state.allowsPrivateMemory)
  }

  func testConversationPartnerVoiceFaceConflictHidesMemory() {
    let now = Date()
    let state = resolver.resolve(evidence: [
      partnerEvidence(.voiceLocal, personId: UUID(), name: "Voice", confidence: 0.70, now: now),
      partnerEvidence(.faceLocal, personId: UUID(), name: "Face", confidence: 0.69, now: now),
      partnerEvidence(.mouthMovement, confidence: 0.18, now: now)
    ], now: now)

    XCTAssertEqual(state.phase, .conflicted)
    XCTAssertFalse(state.allowsPrivateMemory)
    XCTAssertEqual(state.primary?.conflictReasons.first, "voice and speaking face disagree")
  }

  func testConversationPartnerVoiceFaceConflictEvenWhenFaceIsStronger() {
    let now = Date()
    let state = resolver.resolve(evidence: [
      partnerEvidence(.voiceLocal, personId: UUID(), name: "Voice", confidence: 0.68, now: now),
      partnerEvidence(.faceAWS, personId: UUID(), name: "SpeakingFace", confidence: 0.91, now: now),
      partnerEvidence(.mouthMovement, confidence: 0.22, now: now)
    ], now: now)

    XCTAssertEqual(state.phase, .conflicted)
    XCTAssertFalse(state.allowsPrivateMemory)
    XCTAssertEqual(state.primary?.conflictReasons.first, "voice and speaking face disagree")
  }

  func testConversationPartnerLocalAndAWSVoiceDisagreementHidesMemory() {
    let now = Date()
    let state = resolver.resolve(evidence: [
      partnerEvidence(.voiceLocal, personId: UUID(), name: "Local", confidence: 0.72, now: now),
      partnerEvidence(.voiceAWS, personId: UUID(), name: "AWS", confidence: 0.88, now: now)
    ], now: now)

    XCTAssertEqual(state.phase, .conflicted)
    XCTAssertFalse(state.allowsPrivateMemory)
    XCTAssertEqual(state.primary?.conflictReasons.first, "local and AWS voice disagree")
  }

  func testConversationPartnerExpiresStaleEvidence() {
    let personId = UUID()
    let now = Date()
    let stale = ConversationPartnerEvidence(
      source: .voiceLocal,
      personId: personId,
      displayName: "Stale",
      confidence: 0.90,
      timestamp: now.addingTimeInterval(-20),
      validUntil: now.addingTimeInterval(-1),
      details: "expired"
    )

    let state = resolver.resolve(evidence: [stale], now: now)

    XCTAssertEqual(state.phase, .none)
    XCTAssertNil(state.primary)
  }

  func testTranscriptNameSignalDetectsDirectAddressAndDeparture() {
    let gary = PersonNameCandidate(personId: UUID(), displayName: "Gary")

    let addressed = TranscriptNameSignalResolver.resolve(
      text: "Gary, can you look at this?",
      people: [gary]
    )
    let departed = TranscriptNameSignalResolver.resolve(
      text: "Bye Gary, see you later.",
      people: [gary]
    )
    let reference = TranscriptNameSignalResolver.resolve(
      text: "Gary told me yesterday that this was broken.",
      people: [gary]
    )

    XCTAssertEqual(addressed?.intent, .directAddress)
    XCTAssertEqual(addressed?.personId, gary.personId)
    XCTAssertEqual(departed?.intent, .departure)
    XCTAssertEqual(reference?.intent, .reference)
  }

  func testPresenceTrackerKeepsActivePersonUntilExplicitDeparture() {
    let tracker = PresenceEpisodeTracker()
    let personId = UUID()
    let start = Date()

    tracker.record(evidence: partnerEvidence(.voiceLocal, personId: personId, name: "Gary", confidence: 0.82, now: start), now: start)
    var snapshot = tracker.snapshot(now: start.addingTimeInterval(30))

    XCTAssertEqual(snapshot.active.count, 1)
    XCTAssertEqual(snapshot.active.first?.displayName, "Gary")

    tracker.record(nameSignal: TranscriptNameSignal(
      intent: .departure,
      personId: personId,
      displayName: "Gary",
      confidence: 0.90,
      evidence: "testFarewell"
    ), now: start.addingTimeInterval(45))
    snapshot = tracker.snapshot(now: start.addingTimeInterval(46))

    XCTAssertTrue(snapshot.active.isEmpty)
    XCTAssertEqual(snapshot.departed.first?.displayName, "Gary")
    XCTAssertEqual(snapshot.departed.first?.status, .departed)
  }

  func testPresenceTrackerDoesNotStartSecondPersonFromWeakFaceOnlyEvidence() {
    let tracker = PresenceEpisodeTracker()
    let garyId = UUID()
    let seanId = UUID()
    let start = Date()

    tracker.record(
      evidence: partnerEvidence(.faceAWS, personId: garyId, name: "Gary", confidence: IdentityConfig.strongMatchThreshold + 0.02, now: start),
      now: start
    )
    tracker.record(
      evidence: partnerEvidence(.faceAWS, personId: seanId, name: "Sean", confidence: IdentityConfig.strongMatchThreshold - 0.001, now: start.addingTimeInterval(30)),
      now: start.addingTimeInterval(30)
    )

    let snapshot = tracker.snapshot(now: start.addingTimeInterval(31))

    XCTAssertEqual(snapshot.active.count, 1)
    XCTAssertEqual(snapshot.active.first?.displayName, "Gary")
  }

  func testPresenceTrackerAllowsWeakFaceEvidenceToRefreshExistingPerson() {
    let tracker = PresenceEpisodeTracker()
    let personId = UUID()
    let start = Date()
    let refresh = start.addingTimeInterval(40)

    tracker.record(
      evidence: partnerEvidence(.faceAWS, personId: personId, name: "Gary", confidence: IdentityConfig.strongMatchThreshold + 0.02, now: start),
      now: start
    )
    tracker.record(
      evidence: partnerEvidence(.faceAWS, personId: personId, name: "Gary", confidence: IdentityConfig.weakMatchThreshold + 0.01, now: refresh),
      now: refresh
    )

    let snapshot = tracker.snapshot(now: refresh.addingTimeInterval(1))

    XCTAssertEqual(snapshot.active.count, 1)
    XCTAssertEqual(snapshot.active.first?.displayName, "Gary")
    XCTAssertEqual(snapshot.active.first?.lastEvidenceAt, refresh)
  }

  func testPresenceEpisodeRecordEncodesSupabaseRow() throws {
    let appRunId = UUID()
    let sessionId = UUID()
    let personId = UUID()
    let now = Date()
    let record = PresenceEpisodeRecord(
      id: UUID(),
      appRunId: appRunId,
      conversationSessionId: sessionId,
      personId: personId,
      displayName: "Gary",
      startedAt: now,
      lastEvidenceAt: now.addingTimeInterval(10),
      endedAt: now.addingTimeInterval(20),
      status: .departed,
      confidence: 0.91,
      evidenceSummary: "faceAWS=0.91;heuristicFarewell",
      updatedAt: now.addingTimeInterval(20)
    )

    let data = try JSONEncoder().encode(SupabaseRowPresenceEpisode(record))
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

    XCTAssertEqual(json["app_run_id"] as? String, appRunId.uuidString)
    XCTAssertEqual(json["conversation_session_id"] as? String, sessionId.uuidString)
    XCTAssertEqual(json["person_id"] as? String, personId.uuidString)
    XCTAssertEqual(json["display_name"] as? String, "Gary")
    XCTAssertEqual(json["status"] as? String, "departed")
    XCTAssertEqual(json["evidence_summary"] as? String, "faceAWS=0.91;heuristicFarewell")
  }

  func testStreamRunningModeUsesSocialFallbackForActiveRecognizedPerson() {
    let mode = StreamSessionViewModel.streamRunningModeText(
      hasActiveRecognizedPeople: true,
      detectedFaceCount: 1,
      activeConversationPartnerStateText: "confirmed",
      activeSpeakerStateText: "none",
      liveTranscriptPreviewText: "No live transcript yet",
      hasReceivedFirstFrame: true
    )

    XCTAssertEqual(mode, "Social - talking with someone")
  }

  func testStreamRunningModeUsesGeneralFallbackWithoutPeopleOrTranscript() {
    let mode = StreamSessionViewModel.streamRunningModeText(
      hasActiveRecognizedPeople: false,
      detectedFaceCount: 0,
      activeConversationPartnerStateText: "none",
      activeSpeakerStateText: "recording",
      liveTranscriptPreviewText: "Listening...",
      hasReceivedFirstFrame: true
    )

    XCTAssertEqual(mode, "General - looking around")
  }

  func testStreamRunningModeUsesActivityModeClassificationWhenAvailable() {
    let mode = StreamSessionViewModel.streamRunningModeText(
      hasActiveRecognizedPeople: false,
      detectedFaceCount: 0,
      activeConversationPartnerStateText: "none",
      activeSpeakerStateText: "recording",
      liveTranscriptPreviewText: "The movie just started.",
      hasReceivedFirstFrame: true,
      activityMode: ActivityModeClassification(
        mode: "entertainment",
        specificActivity: "watching movie",
        confidence: 0.86,
        reason: "Scene context shows a screen and transcript mentions a movie."
      )
    )

    XCTAssertEqual(mode, "Entertainment - watching movie")
  }

  func testStreamRunningRecognizedPeopleFiltersIdentityStatusLabels() {
    let people = StreamSessionViewModel.streamRunningRecognizedPeopleText([
      "Unknown",
      "None",
      "Gary",
      "gary",
      "Confirmed"
    ])

    XCTAssertEqual(people, "Gary")
  }

  func testStreamingGlassesLiveSectionUsesStableMainStreamFormat() {
    let sections = MementoGlassesDisplayRenderer.liveViewSections(
      assistanceCard: AssistanceDisplayCard(
        title: "Unknown person",
        lines: ["Status: Streaming. Identity analysis active."],
        usesFallbackOutput: false
      ),
      recallSections: [],
      identityPromptSection: nil,
      statusLine: "Status: Streaming. Identity analysis active.",
      isStreaming: true,
      streamModeLine: "Mode: Social - talking with Gary",
      recognizedPeopleLine: "Recognized people: Gary"
    )

    let streamSection = sections.last
    XCTAssertEqual(streamSection?.title, "Stream running successfully")
    XCTAssertEqual(streamSection?.lines, ["Mode: Social - talking with Gary", "Recognized people: Gary"])
    let rendered = sections.flatMap { [$0.title] + $0.lines }.joined(separator: "\n")
    XCTAssertFalse(rendered.contains("Unknown person"))
    XCTAssertFalse(rendered.localizedCaseInsensitiveContains("identity analysis"))
  }

  func testSupabaseSyncQueueKeepsParentInsertedWhileChildWriteIsInFlight() async throws {
    let remote = RecordingIdentitySyncRemote()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("IdentitySyncQueueTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let queue = IdentitySyncQueue(remote: remote, persistenceDirectory: directory)
    let now = Date()
    let appRun = AppRun(
      id: UUID(),
      startedAt: now,
      endedAt: nil,
      appBuild: "test",
      appVersion: "test",
      deviceId: "test-device",
      notes: nil,
      createdAt: now
    )
    let chunk = TranscriptChunk(
      id: UUID(),
      appRunId: appRun.id,
      conversationSessionId: UUID(),
      personId: nil,
      activeIdentityState: "unknown",
      text: "hello",
      isFinal: true,
      startedAt: now,
      endedAt: now,
      transcriptUpdatedAt: now,
      source: "test",
      createdAt: now
    )

    await remote.setTranscriptHook {
      await queue.enqueue(.appRun(appRun))
    }

    await queue.enqueue(.transcriptChunk(chunk))

    try await waitUntil {
      await remote.appliedLabels().contains("appRun:\(appRun.id.uuidString)")
    }

    let labels = await remote.appliedLabels()
    XCTAssertTrue(labels.contains("transcriptChunk:\(chunk.id.uuidString)"))
    XCTAssertTrue(labels.contains("appRun:\(appRun.id.uuidString)"))
    let pendingCount = await queue.pendingCount()
    XCTAssertEqual(pendingCount, 0)
  }

  func testSupabaseSyncQueueRestoresRecoverableForeignKeyDeadLetter() async throws {
    let remote = RecordingIdentitySyncRemote()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("IdentitySyncQueueDeadLetterTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let now = Date()
    let chunk = TranscriptChunk(
      id: UUID(),
      appRunId: UUID(),
      conversationSessionId: UUID(),
      personId: nil,
      activeIdentityState: "unknown",
      text: "restored",
      isFinal: true,
      startedAt: now,
      endedAt: now,
      transcriptUpdatedAt: now,
      source: "test",
      createdAt: now
    )
    let deadLetter = IdentitySyncQueue.Entry(
      id: UUID(),
      operation: .transcriptChunk(chunk),
      attempts: 8,
      lastError: "Supabase returned HTTP 409: {\"code\":\"23503\",\"message\":\"foreign key constraint\"}",
      enqueuedAt: now
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let line = try encoder.encode(deadLetter)
    let deadLetterURL = directory.appendingPathComponent("supabase-sync-dead-letter.jsonl")
    var payload = line
    payload.append(0x0A)
    try payload.write(to: deadLetterURL)

    _ = IdentitySyncQueue(remote: remote, persistenceDirectory: directory)

    try await waitUntil {
      await remote.appliedLabels().contains("transcriptChunk:\(chunk.id.uuidString)")
    }

    XCTAssertFalse(FileManager.default.fileExists(atPath: deadLetterURL.path))
  }

  func testSupabaseSyncQueueDeadLettersFaceVectorSchemaMismatch() async throws {
    let remote = RecordingIdentitySyncRemote()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("IdentitySyncQueueVectorMismatchTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    await remote.setPersonAveragedEmbeddingError(
      SupabaseClientError.badHTTPStatus(
        400,
        #"{"code":"22000","details":null,"hint":null,"message":"expected 128 dimensions, not 512"}"#
      )
    )

    let avg = PersonAveragedEmbedding(
      id: UUID(),
      personId: UUID(),
      averagedVector: Array(repeating: Float(0.001), count: 512),
      vectorDimension: 512,
      sampleCount: 3,
      modelName: "AdaFace",
      modelVersion: "cvlface_adaface_ir101_webface12m",
      modelSource: "AWS/AdaFace",
      preprocessingVersion: "aws-adaface-aligned-112-v1",
      updatedAt: Date()
    )
    let queue = IdentitySyncQueue(remote: remote, persistenceDirectory: directory)
    let deadLetterURL = directory.appendingPathComponent("supabase-sync-dead-letter.jsonl")

    await queue.enqueue(.personAveragedEmbedding(avg))

    try await waitUntil {
      await queue.pendingCount() == 0
        && FileManager.default.fileExists(atPath: deadLetterURL.path)
    }

    let attempts = await remote.personAveragedEmbeddingAttempts()
    XCTAssertEqual(attempts, 1)
    let deadLetterText = try String(contentsOf: deadLetterURL, encoding: .utf8)
    XCTAssertTrue(deadLetterText.contains("Schema requires Supabase vector dimension migration"))
    XCTAssertTrue(deadLetterText.contains("0006_relax_face_embedding_vector_dimensions.sql"))
  }

  func testAIProxyEnvelopeCarriesOperationWithoutProviderAuthorization() throws {
    struct Payload: Encodable {
      let model: String
      let systemPrompt: String
      let userPrompt: String
    }

    let envelope = AIProxyEnvelope(
      operation: "qwen.stream_summary",
      requestId: "test1234",
      payload: Payload(
        model: "qwen3.5-flash",
        systemPrompt: "Return JSON.",
        userPrompt: "Summarize this stream."
      )
    )

    let data = try JSONEncoder().encode(envelope)
    let text = try XCTUnwrap(String(data: data, encoding: .utf8))
    XCTAssertTrue(text.contains(#""operation":"qwen.stream_summary""#))
    XCTAssertTrue(text.contains(#""model":"qwen3.5-flash""#))
    XCTAssertFalse(text.localizedCaseInsensitiveContains("authorization"))
    XCTAssertFalse(text.localizedCaseInsensitiveContains("bearer "))
    XCTAssertFalse(text.localizedCaseInsensitiveContains("dashscope_api_key"))
    XCTAssertFalse(text.localizedCaseInsensitiveContains("deepseek_api_key"))
  }

  func testAIProxyFunctionResponseDecodesStructuredError() throws {
    struct Output: Decodable {
      let text: String
    }

    let data = Data("""
    {"ok":false,"source":"supabase_edge","error":{"kind":"malformed_json","message":"model output was not recoverable JSON","retryable":true}}
    """.utf8)

    let decoded = try JSONDecoder().decode(AIProxyFunctionResponse<Output>.self, from: data)
    XCTAssertFalse(decoded.ok)
    XCTAssertNil(decoded.output)
    XCTAssertEqual(decoded.error?.kind, "malformed_json")
    XCTAssertEqual(decoded.error?.retryable, true)
  }

  func testSceneContextClientParsesNameAddressJSON() throws {
    let content = """
{"intent":"departure","displayName":"Gary","personId":null,"confidence":0.88,"evidence":"The wearer said bye Gary."}
"""
    let analysis = try SceneContextClient.parseNameAddressAnalysis(from: content)

    XCTAssertEqual(analysis.intent, .departure)
    XCTAssertEqual(analysis.displayName, "Gary")
    XCTAssertEqual(analysis.confidence, 0.88, accuracy: 0.001)
  }

  func testSceneContextClientParsesActivityModeJSON() throws {
    let content = """
    Here is the classification:
    ```json
    {"mode":"entertainment","specific_activity":"watching movie","confidence":0.91,"reason":"Scene context shows a TV and transcript mentions the movie."}
    ```
    """

    let classification = try SceneContextClient.parseActivityModeClassification(from: content)

    XCTAssertEqual(classification.mode, "entertainment")
    XCTAssertEqual(classification.specificActivity, "watching movie")
    XCTAssertEqual(classification.displayText, "Entertainment - watching movie")
    XCTAssertEqual(classification.confidence, 0.91, accuracy: 0.001)
  }

  func testActivityModeFallbackClassifiesRepresentativeScenarios() {
    let cases: [(text: String, people: [String], faces: Int, mode: String)] = [
      ("You are watching a movie on the screen.", [], 0, "entertainment"),
      ("The wearer is jogging outside during a workout.", [], 0, "sport"),
      ("You are studying a textbook next to a laptop.", [], 0, "study"),
      ("Gary asked you a question about the plan.", ["Gary"], 1, "social"),
      ("You are driving to the train station for a commute.", [], 0, "commute"),
      ("", [], 0, "general")
    ]

    for item in cases {
      let classification = ActivityModeClassifier.fallbackClassification(for: ActivityModeClassificationRequest(
        transcriptText: item.text,
        sceneContexts: [],
        recognizedPeople: item.people,
        detectedFaceCount: item.faces,
        identityEvidence: nil,
        locationLabel: nil,
        streamState: "streaming",
        reason: "test"
      ))
      XCTAssertEqual(classification.mode, item.mode, "text=\(item.text)")
    }
  }

  func testActivityModeSmoothingRejectsLowConfidenceModeSwitch() {
    let current = ActivityModeClassification(
      mode: "study",
      specificActivity: "studying laptop",
      confidence: 0.82,
      reason: "Recent stable mode."
    )
    let weakCandidate = ActivityModeClassification(
      mode: "entertainment",
      specificActivity: "watching a clip",
      confidence: 0.57,
      reason: "One weak visual cue."
    )
    let strongCandidate = ActivityModeClassification(
      mode: "entertainment",
      specificActivity: "watching movie",
      confidence: 0.82,
      reason: "Scene context and transcript both mention a movie."
    )

    XCTAssertFalse(ActivityModeClassifier.shouldApply(current: current, candidate: weakCandidate))
    XCTAssertTrue(ActivityModeClassifier.shouldApply(current: current, candidate: strongCandidate))
  }

  func testActivityModePromptStatesWearerAndRecognizedPeopleBoundary() {
    let prompt = SceneContextClient.activityModePromptForTesting(ActivityModeClassificationRequest(
      transcriptText: "Gary asked whether the movie started.",
      sceneContexts: [],
      recognizedPeople: ["Gary"],
      detectedFaceCount: 1,
      identityEvidence: SceneContextIdentityEvidence(
        wearerName: "you",
        conversationPartnerName: "Gary",
        conversationPartnerPersonId: nil,
        conversationPartnerState: "confirmed",
        confidence: 0.9,
        sourceSummary: "face:Gary"
      ),
      locationLabel: "home",
      streamState: "streaming",
      reason: "test"
    ))

    XCTAssertTrue(prompt.contains("app user/wearer is \"you\""))
    XCTAssertTrue(prompt.contains("recognized people and activePeople are people with you, not you"))
    XCTAssertTrue(prompt.contains("specific_activity"))
  }

  func testSupabaseActivityModeEpisodeEncoder() throws {
    let appRunId = UUID()
    let sessionId = UUID()
    let startedAt = Date(timeIntervalSince1970: 10)
    let record = ActivityModeEpisodeRecord(
      id: UUID(),
      appRunId: appRunId,
      conversationSessionId: sessionId,
      mode: "entertainment",
      specificActivity: "watching movie",
      startedAt: startedAt,
      lastEvidenceAt: startedAt.addingTimeInterval(30),
      endedAt: startedAt.addingTimeInterval(60),
      confidence: 0.87,
      reason: "Scene context and transcript mention a movie.",
      source: "qwen",
      modelName: "qwen3.5-flash",
      promptVersion: ActivityModeClassifier.promptVersion,
      updatedAt: startedAt.addingTimeInterval(60)
    )

    let data = try JSONEncoder().encode(SupabaseRowActivityModeEpisode(record))
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

    XCTAssertEqual(json["app_run_id"] as? String, appRunId.uuidString)
    XCTAssertEqual(json["conversation_session_id"] as? String, sessionId.uuidString)
    XCTAssertEqual(json["mode"] as? String, "entertainment")
    XCTAssertEqual(json["specific_activity"] as? String, "watching movie")
    XCTAssertEqual(json["source"] as? String, "qwen")
    XCTAssertEqual(json["model_name"] as? String, "qwen3.5-flash")
  }

  func testSceneContextSettingsLoadsCheapTextModelForStreamSummary() {
    let settings = SceneContextSettings.load(environment: [
      "DASHSCOPE_API_KEY": "test-key",
      "DASHSCOPE_TEXT_MODEL": "qwen-test-cheap"
    ])

    XCTAssertEqual(settings.textModel, "qwen-test-cheap")
  }

  func testSceneContextClientParsesStreamSummaryJSON() throws {
    let content = """
```json
{"summary":"You checked the smart-glasses display while Gary stood with you.","who":"you and Gary","where":"home workspace","what":"checking the smart-glasses display","when":"after the stream","why":"to verify the recognition prompt","how":"looking at Gary and using the display controls","people":["Gary"],"keyMoments":["Gary was recognized","Display issue was discussed"],"outline":["Gary appeared in front of you","You checked whether the display prompt worked"],"confidence":1.2}
```
"""
    let analysis = try SceneContextClient.parseStreamSummary(from: content)

    XCTAssertEqual(analysis.summary, "You checked the smart-glasses display while Gary stood with you.")
    XCTAssertEqual(analysis.who, "you and Gary")
    XCTAssertEqual(analysis.whereText, "home workspace")
    XCTAssertEqual(analysis.people, ["Gary"])
    XCTAssertEqual(analysis.keyMoments.count, 2)
    XCTAssertEqual(analysis.outline.count, 2)
    XCTAssertEqual(analysis.confidence, 1.0, accuracy: 0.001)
  }

  func testSceneContextClientRepairsRecoverableStreamSummaryJSON() throws {
    let proseWrapped = """
    Here is the summary:
    {"summary":"You checked the display with Gary.","who":"you and Gary","where":"home workspace","what":"display check","when":"after the stream","why":"to verify summary parsing","how":"using the iPhone app","people":["Gary"],"keyMoments":["Display checked"],"outline":["You checked the display"],"confidence":0.9}
    Hope this helps.
    """
    let trailingComma = """
    {"summary":"You checked the display with Gary.","who":"you and Gary","where":"home workspace","what":"display check","when":"after the stream","why":"to verify summary parsing","how":"using the iPhone app","people":["Gary",],"keyMoments":["Display checked",],"outline":["You checked the display",],"confidence":0.9,}
    """

    XCTAssertEqual(try SceneContextClient.parseStreamSummary(from: proseWrapped).people, ["Gary"])
    XCTAssertEqual(try SceneContextClient.parseStreamSummary(from: trailingComma).summary, "You checked the display with Gary.")
  }

  func testSceneContextStreamSummaryPayloadDisablesQwenThinking() throws {
    let request = makeStreamSummaryRequest(transcriptText: "Gary helped you check the display summary.")
    let settings = SceneContextSettings(
      enabled: true,
      locationEnabled: false,
      apiKey: "test-key",
      baseURL: SceneContextSettings.defaultBaseURL,
      model: SceneContextSettings.defaultModel,
      textModel: "qwen3.5-flash"
    )

    let json = try SceneContextClient.streamSummaryPayloadJSONForTesting(request, settings: settings)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])

    XCTAssertEqual(object["model"] as? String, "qwen3.5-flash")
    XCTAssertEqual(object["enable_thinking"] as? Bool, false)
  }

  func testSceneContextStreamSummaryPayloadBoundsLongAndEmptyInputs() throws {
    let settings = SceneContextSettings(
      enabled: true,
      locationEnabled: false,
      apiKey: "test-key",
      baseURL: SceneContextSettings.defaultBaseURL,
      model: SceneContextSettings.defaultModel,
      textModel: "qwen3.5-flash"
    )
    let longTranscript = String(repeating: "Gary discussed the prototype summary behavior. ", count: 80)
    let longPayload = try SceneContextClient.streamSummaryPayloadJSONForTesting(
      makeStreamSummaryRequest(transcriptText: longTranscript),
      settings: settings
    )
    let emptyPayload = try SceneContextClient.streamSummaryPayloadJSONForTesting(
      StreamSummaryRequest(
        transcripts: [],
        sceneContexts: [],
        startedAt: Date(timeIntervalSince1970: 1_800),
        endedAt: Date(timeIntervalSince1970: 1_830),
        identityEvidence: nil
      ),
      settings: settings
    )

    let longUserPrompt = try streamSummaryUserPrompt(fromPayloadJSON: longPayload)
    let emptyUserPrompt = try streamSummaryUserPrompt(fromPayloadJSON: emptyPayload)

    XCTAssertLessThan(longUserPrompt.count, longTranscript.count)
    XCTAssertFalse(longUserPrompt.contains(String(longTranscript.suffix(400))))
    XCTAssertTrue(emptyUserPrompt.contains("Transcript:"))
    XCTAssertTrue(emptyUserPrompt.contains("Multimodal scene-context records:"))
    XCTAssertTrue(emptyUserPrompt.contains("not available"))
  }

  func testSceneContextClientRetriesStreamSummaryTimeoutAndReturnsAlibabaSummary() async throws {
    let request = makeStreamSummaryRequest(transcriptText: "Gary helped you check the post-stream summary.")
    let settings = SceneContextSettings(
      enabled: true,
      locationEnabled: false,
      apiKey: "test-key",
      baseURL: SceneContextSettings.defaultBaseURL,
      model: SceneContextSettings.defaultModel,
      textModel: "qwen3.5-flash"
    )
    let session = makeStreamSummaryMockURLSession()
    StreamSummaryMockURLProtocol.reset()
    StreamSummaryMockURLProtocol.enqueue { _ in
      throw URLError(.timedOut)
    }
    StreamSummaryMockURLProtocol.enqueue { request in
      let response = try XCTUnwrap(HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      ))
      let body = try self.makeStreamSummaryChatCompletionData(content: """
      {"summary":"You checked the latest stream summary with Gary.","who":"you and Gary","where":"home workspace","what":"checking the stream summary","when":"after the stream","why":"to verify Alibaba summarization","how":"using the iPhone app","people":["Gary"],"keyMoments":["Gary was present"],"outline":["You ended the stream","Alibaba generated the summary"],"confidence":0.91}
      """)
      return (response, body)
    }

    let analysis = try await SceneContextClient(settings: settings, session: session)
      .summarizeStream(request, retryPolicy: .immediateRetry)

    XCTAssertEqual(analysis.summary, "You checked the latest stream summary with Gary.")
    XCTAssertEqual(StreamSummaryMockURLProtocol.requestCount(), 2)
  }

  func testSceneContextClientRetriesMalformedStreamSummaryBeforeFallback() async throws {
    let request = makeStreamSummaryRequest(transcriptText: "Gary helped you check the post-stream summary.")
    let settings = SceneContextSettings(
      enabled: true,
      locationEnabled: false,
      apiKey: "test-key",
      baseURL: SceneContextSettings.defaultBaseURL,
      model: SceneContextSettings.defaultModel,
      textModel: "qwen3.5-flash"
    )
    let session = makeStreamSummaryMockURLSession()
    StreamSummaryMockURLProtocol.reset()
    StreamSummaryMockURLProtocol.enqueue { request in
      let prompt = try self.streamSummaryUserPrompt(fromPayloadData: try self.httpBodyData(from: request))
      XCTAssertFalse(prompt.contains("STRICT JSON ONLY"))
      let response = try XCTUnwrap(HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      ))
      return (response, try self.makeStreamSummaryChatCompletionData(content: #"{"summary":"truncated""#))
    }
    StreamSummaryMockURLProtocol.enqueue { request in
      let prompt = try self.streamSummaryUserPrompt(fromPayloadData: try self.httpBodyData(from: request))
      XCTAssertTrue(prompt.contains("STRICT JSON ONLY"))
      let response = try XCTUnwrap(HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      ))
      let body = try self.makeStreamSummaryChatCompletionData(content: """
      {"summary":"You checked the stream summary with Gary after a malformed response retry.","who":"you and Gary","where":"home workspace","what":"checking summary parsing","when":"after the stream","why":"to verify retry behavior","how":"using a strict JSON retry prompt","people":["Gary"],"keyMoments":["Malformed response was retried"],"outline":["First response was malformed","Second response parsed"],"confidence":0.86}
      """)
      return (response, body)
    }

    let analysis = try await SceneContextClient(settings: settings, session: session)
      .summarizeStream(request, retryPolicy: .immediateRetry)

    XCTAssertEqual(analysis.summary, "You checked the stream summary with Gary after a malformed response retry.")
    XCTAssertEqual(StreamSummaryMockURLProtocol.requestCount(), 2)
  }

  func testSceneContextClientChunksLongStreamSummaryAndMergesPartials() async throws {
    let request = makeChunkedStreamSummaryRequest(chunkCount: 18)
    let settings = SceneContextSettings(
      enabled: true,
      locationEnabled: false,
      apiKey: "test-key",
      baseURL: SceneContextSettings.defaultBaseURL,
      model: SceneContextSettings.defaultModel,
      textModel: "qwen3.5-flash"
    )
    let session = makeStreamSummaryMockURLSession()
    StreamSummaryMockURLProtocol.reset()
    for _ in 0..<24 {
      StreamSummaryMockURLProtocol.enqueue { request in
        let prompt = try self.streamSummaryUserPrompt(fromPayloadData: try self.httpBodyData(from: request))
        let response = try XCTUnwrap(HTTPURLResponse(
          url: try XCTUnwrap(request.url),
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        ))
        let content: String
        if prompt.contains("Merge these chronological partial smart-glasses stream summaries") {
          content = """
          {"summary":"You reviewed a long stream with Gary and preserved the important moments.","who":"you and Gary","where":"home workspace","what":"reviewing a long smart-glasses stream","when":"during the full stream","why":"to verify long Alibaba summarization","how":"chunking partial summaries and merging them","people":["Gary"],"keyMoments":["The transcript was chunked","Partial summaries were merged"],"outline":["The long transcript was split","Alibaba summarized each part","Alibaba merged the partials"],"confidence":0.88}
          """
        } else {
          content = """
          {"summary":"You discussed one part of the prototype stream with Gary.","who":"you and Gary","where":"home workspace","what":"prototype stream discussion","when":"one chunk","why":"to test chunked summaries","how":"using the iPhone app","people":["Gary"],"keyMoments":["One transcript section was summarized"],"outline":["A section was processed"],"confidence":0.8}
          """
        }
        return (response, try self.makeStreamSummaryChatCompletionData(content: content))
      }
    }

    let analysis = try await SceneContextClient(settings: settings, session: session)
      .summarizeStreamLongSafe(
        request,
        retryPolicy: .immediateRetry,
        longInputPolicy: .forcedChunkingForTesting
      )

    XCTAssertEqual(analysis.summary, "You reviewed a long stream with Gary and preserved the important moments.")
    XCTAssertGreaterThan(StreamSummaryMockURLProtocol.requestCount(), 2)
  }

  func testSceneContextClientDoesNotRetryUnauthorizedSummaryAndSanitizesReason() async throws {
    let request = makeStreamSummaryRequest(transcriptText: "Gary helped you check the post-stream summary.")
    let settings = SceneContextSettings(
      enabled: true,
      locationEnabled: false,
      apiKey: "test-key",
      baseURL: SceneContextSettings.defaultBaseURL,
      model: SceneContextSettings.defaultModel,
      textModel: "qwen3.5-flash"
    )
    let session = makeStreamSummaryMockURLSession()
    StreamSummaryMockURLProtocol.reset()
    StreamSummaryMockURLProtocol.enqueue { request in
      let response = try XCTUnwrap(HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: 401,
        httpVersion: nil,
        headerFields: nil
      ))
      return (response, Data(#"{"api_key":"should-not-log","message":"unauthorized"}"#.utf8))
    }

    do {
      _ = try await SceneContextClient(settings: settings, session: session)
        .summarizeStream(request, retryPolicy: StreamSummaryRetryPolicy(maxAttempts: 3, timeoutInterval: 1, retryDelays: [0, 0]))
      XCTFail("Expected Alibaba summary failure")
    } catch {
      let fallbackReason = SceneContextClient.streamSummaryFallbackReason(for: error)
      XCTAssertTrue(fallbackReason.contains("badHTTPStatus"))
      XCTAssertTrue(fallbackReason.contains("unauthorized"))
      XCTAssertFalse(fallbackReason.contains("should-not-log"))
    }
    XCTAssertEqual(StreamSummaryMockURLProtocol.requestCount(), 1)
  }

  func testLiveTranscriptMemoryTriggerDetectsPastReferenceQuestion() {
    let trigger = LiveTranscriptMemoryTriggerResolver.resolve(
      text: "What did we talk about last time with Gary?"
    )

    XCTAssertEqual(trigger?.kind, .pastReference)
    XCTAssertEqual(trigger?.reason, "pastReferencePhrase")
  }

  func testLiveTranscriptMemoryTriggerDetectsSimilarConversation() {
    let trigger = LiveTranscriptMemoryTriggerResolver.resolve(
      text: "This is similar to last time we debugged the display issue."
    )

    XCTAssertEqual(trigger?.kind, .similarConversation)
  }

  func testLiveTranscriptMemoryTriggerIgnoresSmallTalk() {
    let trigger = LiveTranscriptMemoryTriggerResolver.resolve(text: "How are you?")

    XCTAssertNil(trigger)
  }

  func testLiveTranscriptAssemblerReconstructsQuestionSplitAcrossASRWindows() {
    var assembler = LiveTranscriptQuestionAssembler()
    let gary = PersonNameCandidate(personId: UUID(), displayName: "Gary")
    let start = Date(timeIntervalSince1970: 1_000)

    XCTAssertNil(assembler.append(
      text: "Gary and I were talking what did we",
      startedAt: start,
      endedAt: start.addingTimeInterval(5),
      people: [gary]
    ))

    let trigger = assembler.append(
      text: "what did we say last time with Gary",
      startedAt: start.addingTimeInterval(3),
      endedAt: start.addingTimeInterval(8),
      people: [gary]
    )

    XCTAssertEqual(trigger?.answerMode, .memory)
    XCTAssertEqual(trigger?.fullText, "what did we say last time with Gary")
    XCTAssertEqual(trigger?.mentionedNames, ["Gary"])
  }

  func testLiveTranscriptAssemblerOverlapRemovalDoesNotDuplicateWords() {
    var assembler = LiveTranscriptQuestionAssembler()
    let start = Date(timeIntervalSince1970: 2_000)

    _ = assembler.append(
      text: "we were debugging the display what did we",
      startedAt: start,
      endedAt: start.addingTimeInterval(5)
    )
    let trigger = assembler.append(
      text: "what did we decide last time with Gary",
      startedAt: start.addingTimeInterval(3),
      endedAt: start.addingTimeInterval(8)
    )

    XCTAssertEqual(trigger?.answerMode, .memory)
    XCTAssertFalse(trigger?.fullText.localizedCaseInsensitiveContains("what did we what did we") ?? true)
    XCTAssertEqual(trigger?.fullText, "what did we decide last time with Gary")
  }

  func testLiveTranscriptAssemblerWaitsForCompleteGeneralQuestionAcrossWindows() {
    var assembler = LiveTranscriptQuestionAssembler()
    let start = Date(timeIntervalSince1970: 2_500)

    XCTAssertNil(assembler.append(
      text: "What is the capital",
      startedAt: start,
      endedAt: start.addingTimeInterval(5)
    ))

    let trigger = assembler.append(
      text: "of Korea",
      startedAt: start.addingTimeInterval(3),
      endedAt: start.addingTimeInterval(8)
    )

    XCTAssertEqual(trigger?.answerMode, .general)
    XCTAssertEqual(trigger?.fullText, "What is the capital of Korea")
  }

  func testLiveTranscriptAssemblerDoesNotFireBeforeUnitedStatesCompletes() {
    var assembler = LiveTranscriptQuestionAssembler()
    let start = Date(timeIntervalSince1970: 2_550)

    let partial = assembler.appendObservation(
      text: "What is the capital",
      startedAt: start,
      endedAt: start.addingTimeInterval(5)
    )

    XCTAssertNil(partial?.localTrigger)
    XCTAssertTrue(LiveTranscriptQuestionRouter.shouldWaitForMoreTranscript(partial?.candidateText ?? ""))

    let complete = assembler.append(
      text: "of the United States",
      startedAt: start.addingTimeInterval(3),
      endedAt: start.addingTimeInterval(8)
    )

    XCTAssertEqual(complete?.answerMode, .general)
    XCTAssertEqual(complete?.fullText, "What is the capital of the United States")
  }

  func testLiveTranscriptAssemblerReturnsObservationForLLMClassificationWithoutLocalTrigger() {
    var assembler = LiveTranscriptQuestionAssembler()
    let start = Date(timeIntervalSince1970: 2_600)

    let observation = assembler.appendObservation(
      text: "I saw Gary near the booth",
      startedAt: start,
      endedAt: start.addingTimeInterval(5)
    )

    XCTAssertEqual(observation?.currentTranscript, "I saw Gary near the booth")
    XCTAssertEqual(observation?.rollingTranscript, "I saw Gary near the booth")
    XCTAssertNil(observation?.localTrigger)
    XCTAssertEqual(observation?.candidateMode, .ignore)
  }

  func testLiveTranscriptRouterRejectsIncompleteGeneralQuestionFragment() {
    XCTAssertNil(LiveTranscriptQuestionRouter.route(text: "What is the capital"))
    XCTAssertNil(LiveTranscriptQuestionRouter.route(text: "What is the capital of"))
    XCTAssertTrue(LiveTranscriptQuestionRouter.shouldWaitForMoreTranscript("What is the capital"))
    XCTAssertTrue(LiveTranscriptQuestionRouter.shouldWaitForMoreTranscript("What is the capital of the United"))
    XCTAssertFalse(LiveTranscriptQuestionRouter.shouldWaitForMoreTranscript("What is the capital of the United States"))
  }

  func testLiveMemoryQuestionWithGarySelectsLatestGaryConversation() {
    let garyId = UUID()
    let oldDate = Date(timeIntervalSince1970: 10_000)
    let latestDate = oldDate.addingTimeInterval(86_400)
    let entry = makePersonEntry(
      id: garyId,
      name: "Gary",
      conversations: [
        makeConversation(personId: garyId, name: "Gary", startedAt: oldDate, text: "Old note about lunch."),
        makeConversation(personId: garyId, name: "Gary", startedAt: latestDate, text: "Latest combo summary about the prototype buttons.")
      ]
    )
    let trigger = LiveTranscriptQuestionRouter.route(
      text: "What did we say last time with Gary?",
      startedAt: latestDate,
      endedAt: latestDate,
      people: [PersonNameCandidate(personId: garyId, displayName: "Gary")]
    )
    let candidates = LiveMemoryCandidateRanker.rankedCandidates(
      for: try! XCTUnwrap(trigger),
      entries: [entry],
      attribution: TranscriptAttribution(personId: nil, displayName: nil, confidence: 0, state: "unknown", sourceEvidence: "test")
    )

    XCTAssertEqual(candidates.first?.personId, garyId)
    XCTAssertEqual(candidates.first?.displayName, "Gary")
    let context = try! XCTUnwrap(candidates.first?.context)
    XCTAssertTrue(context.contains("Latest combo summary"))
    let latestOffset = (try! XCTUnwrap(context.range(of: "Latest combo summary"))).lowerBound
    let oldOffset = (try! XCTUnwrap(context.range(of: "Old note"))).lowerBound
    XCTAssertLessThan(context.distance(from: context.startIndex, to: latestOffset),
                      context.distance(from: context.startIndex, to: oldOffset))
  }

  func testGeneralQuestionRoutesToQwenWithoutMemory() {
    let trigger = LiveTranscriptQuestionRouter.route(text: "What is the capital of Korea?")

    XCTAssertEqual(trigger?.answerMode, .general)
    XCTAssertNil(trigger?.memoryTrigger)
  }

  func testCurrentQuestionRoutesToAlibabaWebSearchMode() {
    let trigger = LiveTranscriptQuestionRouter.route(text: "What happened today?")

    XCTAssertEqual(trigger?.answerMode, .current)
    XCTAssertNil(trigger?.memoryTrigger)
  }

  func testAlibabaQuestionAnswerDefaultsUseVirginiaGlobalEndpoint() {
    XCTAssertEqual(
      AlibabaQuestionAnswerSettings.defaultCompatibleBaseURL,
      "https://dashscope-us.aliyuncs.com/compatible-mode/v1"
    )
    XCTAssertEqual(
      AlibabaQuestionAnswerSettings.defaultGenerationBaseURL,
      "https://dashscope-us.aliyuncs.com/api/v1"
    )
    XCTAssertEqual(AlibabaQuestionAnswerSettings.defaultModel, "qwen3.5-flash")
    XCTAssertEqual(AlibabaQuestionAnswerSettings.defaultSearchStrategy, "turbo")
  }

  func testAlibabaLiveTriggerDecisionParserAcceptsStrictJSON() {
    let decision = try! AlibabaQuestionAnswerClient.parseLiveTranscriptTriggerDecision(from: """
    {"isTrigger":true,"needsMoreTranscript":false,"fullQuestion":"What is the capital of Korea?","answerMode":"general","confidence":0.96,"reason":"complete stable question"}
    """)

    XCTAssertTrue(decision.isTrigger)
    XCTAssertFalse(decision.needsMoreTranscript)
    XCTAssertEqual(decision.fullQuestion, "What is the capital of Korea?")
    XCTAssertEqual(decision.answerMode, .general)
    XCTAssertEqual(decision.reason, "complete stable question")
  }

  func testAlibabaLiveTriggerPromptIncludesRollingAndCurrentTranscript() {
    let prompt = AlibabaQuestionAnswerClient.triggerClassifierPrompt(for: LiveTranscriptTriggerLLMRequest(
      rollingTranscript: "What is the capital of Korea",
      currentTranscript: "of Korea",
      localCandidateQuestion: "What is the capital of Korea",
      localAnswerMode: .general,
      peopleNames: ["Gary"]
    ))

    XCTAssertTrue(prompt.contains("Rolling transcript"))
    XCTAssertTrue(prompt.contains("Current transcript"))
    XCTAssertTrue(prompt.contains("What is the capital of Korea"))
    XCTAssertTrue(prompt.contains("Gary"))
  }

  func testNoSavedGaryMemoryReturnsNoRelevantMemoryPolicy() {
    let garyId = UUID()
    let entry = makePersonEntry(id: garyId, name: "Gary", conversations: [])
    let trigger = LiveTranscriptQuestionRouter.route(
      text: "What did we say last time with Gary?",
      people: [PersonNameCandidate(personId: garyId, displayName: "Gary")]
    )
    let candidates = LiveMemoryCandidateRanker.rankedCandidates(
      for: try! XCTUnwrap(trigger),
      entries: [entry],
      attribution: TranscriptAttribution(personId: nil, displayName: nil, confidence: 0, state: "unknown", sourceEvidence: "test")
    )

    XCTAssertTrue(candidates.isEmpty)
    XCTAssertEqual(LiveMemoryAnswerPolicy.noRelevantSavedMemoryLine, "No relevant saved memory.")
  }

  func testLiveQuestionAnswersTargetLiveHomeDisplayWindow() {
    let trigger = try! XCTUnwrap(LiveTranscriptQuestionRouter.route(text: "What is the capital of Korea?"))

    XCTAssertEqual(LiveTranscriptAnswerPresentationPolicy.target(for: trigger), .liveHome)
  }

  func testQwenLiveMemoryPromptIsShortAndGroundedInProvidedEvidence() {
    let prompt = AlibabaQuestionAnswerClient.memoryAnswerPrompt(AlibabaMemoryAnswerRequest(
      fullQuestion: "What did we say last time with Gary?",
      triggerReason: "memory:pastReferencePhrase",
      memoryEvidence: "Person: Gary\nWhen: yesterday\nTranscript: Gary: We agreed to fix the display buttons."
    ))

    XCTAssertTrue(prompt.contains("Use only the saved memory evidence"))
    XCTAssertTrue(prompt.contains("maximum 22 words"))
    XCTAssertTrue(prompt.contains("What did we say last time with Gary?"))
    XCTAssertTrue(prompt.contains("We agreed to fix the display buttons."))
    XCTAssertTrue(prompt.contains("No relevant saved memory"))
  }

  func testLiveMemoryAnswerLinesIncludeTriggerQuestionAndAnswerLabels() {
    let lines = StreamSessionViewModel.liveMemoryAnswerLines(
      triggerText: "what was I doing last time",
      answerText: "You were testing the glasses display with Gary."
    )

    XCTAssertEqual(lines.first, "Q: what was I doing last time")
    XCTAssertEqual(lines.dropFirst().first, "A: You were testing the glasses display with Gary.")
  }

  func testLiveAnswerLinesApplyQuestionAnswerLabelsForGeneralAndCurrentAnswers() {
    let generalLines = StreamSessionViewModel.liveAnswerLines(
      questionText: "What is the capital of Korea?",
      answerText: "Seoul is the capital of South Korea."
    )
    let currentLines = StreamSessionViewModel.liveAnswerLines(
      questionText: "What happened today?",
      answerText: "Use the latest web-search answer from Qwen."
    )
    let unavailableLines = StreamSessionViewModel.liveAnswerLines(
      questionText: "What did we discuss last time?",
      answerText: LiveMemoryAnswerPolicy.noRelevantSavedMemoryLine
    )

    XCTAssertEqual(generalLines.first, "Q: What is the capital of Korea?")
    XCTAssertEqual(generalLines.dropFirst().first, "A: Seoul is the capital of South Korea.")
    XCTAssertEqual(currentLines.first, "Q: What happened today?")
    XCTAssertEqual(currentLines.dropFirst().first, "A: Use the latest web-search answer from Qwen.")
    XCTAssertEqual(unavailableLines.first, "Q: What did we discuss last time?")
    XCTAssertEqual(unavailableLines.dropFirst().first, "A: No relevant saved memory.")
  }

  func testFaceRectIsClampedToImageBounds() {
    let imageSize = CGSize(width: 640, height: 480)
    let overflowingBox = CGRect(x: 0.85, y: 0.82, width: 0.40, height: 0.35)

    let rect = VisionFaceFrameProcessor.clampedImageRect(
      forNormalizedFaceBox: overflowingBox,
      imageSize: imageSize
    )

    XCTAssertNotNil(rect)
    XCTAssertLessThanOrEqual(rect?.maxX ?? .greatestFiniteMagnitude, imageSize.width)
    XCTAssertLessThanOrEqual(rect?.maxY ?? .greatestFiniteMagnitude, imageSize.height)
    XCTAssertGreaterThan(rect?.width ?? 0, 0)
    XCTAssertGreaterThan(rect?.height ?? 0, 0)
  }

  func testVisionProcessorAcceptsPixelBufferInputWithoutUIImageFallback() async throws {
    let pixelBuffer = try makePixelBuffer(width: 64, height: 48)
    let processor = VisionFaceFrameProcessor()

    let frame = await processor.process(
      pixelBuffer: pixelBuffer,
      sequence: 1,
      forceTestFaceOverlay: true
    )

    XCTAssertEqual(frame?.imageSize, CGSize(width: 64, height: 48))
    XCTAssertEqual(frame?.faces.count, 1)
  }

  func testPhoneVideoFootagePolicyHidesRealGlassesStreamingSurface() {
    XCTAssertTrue(PhoneVideoFootagePolicy.hidesFootage(inputMode: .realGlasses, lifecycleState: .waiting))
    XCTAssertTrue(PhoneVideoFootagePolicy.hidesFootage(inputMode: .realGlasses, lifecycleState: .starting))
    XCTAssertTrue(PhoneVideoFootagePolicy.hidesFootage(inputMode: .realGlasses, lifecycleState: .running))
    XCTAssertTrue(PhoneVideoFootagePolicy.hidesFootage(inputMode: .realGlasses, lifecycleState: .paused))
    XCTAssertTrue(PhoneVideoFootagePolicy.hidesFootage(inputMode: .realGlasses, lifecycleState: .stopping))
    XCTAssertFalse(PhoneVideoFootagePolicy.hidesFootage(inputMode: .realGlasses, lifecycleState: .stopped))
    XCTAssertFalse(PhoneVideoFootagePolicy.hidesFootage(inputMode: .realGlasses, lifecycleState: .error))
  }

  func testLiveDATPhonePreviewIsDisabledBecauseVideoIsHidden() {
    XCTAssertFalse(StreamSessionViewModel.liveDATPhonePreviewEnabled)
    XCTAssertFalse(StreamSessionViewModel.shouldRenderPhonePreviewForLiveDAT(
      phonePreviewEnabled: StreamSessionViewModel.liveDATPhonePreviewEnabled,
      forceTestFaceOverlay: false
    ))
    XCTAssertTrue(StreamSessionViewModel.shouldRenderPhonePreviewForLiveDAT(
      phonePreviewEnabled: StreamSessionViewModel.liveDATPhonePreviewEnabled,
      forceTestFaceOverlay: true
    ))
  }

  func testFaceRectOutsideImageIsDiscarded() {
    let imageSize = CGSize(width: 640, height: 480)
    let outsideBox = CGRect(x: 1.2, y: 1.2, width: 0.2, height: 0.2)

    let rect = VisionFaceFrameProcessor.clampedImageRect(
      forNormalizedFaceBox: outsideBox,
      imageSize: imageSize
    )

    XCTAssertNil(rect)
  }

  func testInvalidImageSizeIsDiscardedBeforeImageOperations() {
    let box = CGRect(x: 0.25, y: 0.25, width: 0.25, height: 0.25)

    XCTAssertNil(VisionFaceFrameProcessor.clampedImageRect(forNormalizedFaceBox: box, imageSize: .zero))
    XCTAssertNil(VisionFaceFrameProcessor.safeNormalizedFaceBox(box, imageSize: .zero))
  }

  func testSafeNormalizedFaceBoxStaysInsideUnitBounds() {
    let imageSize = CGSize(width: 320, height: 240)
    let overflowingBox = CGRect(x: -0.2, y: -0.1, width: 0.5, height: 0.5)

    let safeBox = VisionFaceFrameProcessor.safeNormalizedFaceBox(overflowingBox, imageSize: imageSize)

    XCTAssertNotNil(safeBox)
    XCTAssertGreaterThanOrEqual(safeBox?.minX ?? -1, 0)
    XCTAssertGreaterThanOrEqual(safeBox?.minY ?? -1, 0)
    XCTAssertLessThanOrEqual(safeBox?.maxX ?? 2, 1)
    XCTAssertLessThanOrEqual(safeBox?.maxY ?? 2, 1)
  }

  func testUIImageOrientationMapping() {
    XCTAssertEqual(VisionFaceFrameProcessor.cgImagePropertyOrientation(for: .up), .up)
    XCTAssertEqual(VisionFaceFrameProcessor.cgImagePropertyOrientation(for: .right), .right)
    XCTAssertEqual(VisionFaceFrameProcessor.cgImagePropertyOrientation(for: .left), .left)
    XCTAssertEqual(VisionFaceFrameProcessor.cgImagePropertyOrientation(for: .down), .down)
  }

  func testVisionBoundingBoxToPixelRectFlipsYAndPads() {
    let conversion = FaceCropper.visionBoundingBoxToPixelRect(
      CGRect(x: 0.25, y: 0.25, width: 0.50, height: 0.50),
      imageWidth: 200,
      imageHeight: 200,
      paddingRatio: 0.10
    )

    XCTAssertTrue(conversion.valid)
    XCTAssertEqual(conversion.pixelRect.origin.x, 50)
    XCTAssertEqual(conversion.pixelRect.origin.y, 50)
    XCTAssertEqual(conversion.pixelRect.width, 100)
    XCTAssertEqual(conversion.pixelRect.height, 100)
    XCTAssertLessThanOrEqual(conversion.paddedRect.maxX, 200)
    XCTAssertLessThanOrEqual(conversion.paddedRect.maxY, 200)
  }

  func testFaceCropperAccepts47PixelFaceForRecognitionCrop() {
    let conversion = FaceCropper.visionBoundingBoxToPixelRect(
      CGRect(x: 0.45, y: 0.40, width: 47.0 / 360.0, height: 47.0 / 640.0),
      imageWidth: 360,
      imageHeight: 640
    )

    XCTAssertTrue(conversion.valid)
    XCTAssertGreaterThanOrEqual(conversion.pixelRect.width, 47)
    XCTAssertGreaterThanOrEqual(conversion.pixelRect.height, 47)
  }

  func testFaceCropperRejects31PixelFaceBeforeDetection() {
    let conversion = FaceCropper.visionBoundingBoxToPixelRect(
      CGRect(x: 0.45, y: 0.40, width: 31.0 / 360.0, height: 31.0 / 640.0),
      imageWidth: 360,
      imageHeight: 640
    )

    XCTAssertFalse(conversion.valid)
    XCTAssertEqual(conversion.reason, "tooSmall")
  }

  func testFaceQualityRejectsTinyCrop() throws {
    let image = try makeTestImage(width: 33, height: 34)
    let crop = FaceCropResult(
      frameSequence: 1,
      frameTimestamp: Date(),
      faceBoundingBoxNormalized: CGRect(x: 0.1, y: 0.1, width: 0.05, height: 0.05),
      rawFaceBoundingBoxPixels: CGRect(x: 10, y: 10, width: 33, height: 34),
      faceBoundingBoxPixels: CGRect(x: 10, y: 10, width: 33, height: 34),
      croppedImage: image,
      previewImage: UIImage(cgImage: image),
      sourceImageSize: CGSize(width: 640, height: 480),
      visionOrientation: .up,
      alignmentMode: "boundingBoxOnly",
      yaw: nil,
      roll: nil,
      pitch: nil,
      faceCaptureQuality: 0.9,
      alignedCroppedImage: image,
      isBottomClipped: false
    )

    let decision = FaceQualityFilter().evaluate(crop)

    XCTAssertFalse(decision.accepted)
    XCTAssertEqual(decision.tier, .tooSmallForRecognition)
    XCTAssertTrue(decision.reasons.contains("tooSmallForRecognition"))
  }

  func testFaceQualityAccepts48PixelFaceForRecognitionButNotEnrollment() throws {
    let crop = try makeFaceCrop(rawWidth: 48, rawHeight: 48, cropWidth: 97, cropHeight: 109, sourceSize: CGSize(width: 360, height: 640))

    let decision = FaceQualityFilter().evaluate(crop)

    XCTAssertTrue(decision.acceptedForRecognition)
    XCTAssertFalse(decision.acceptedForEnrollment)
    XCTAssertEqual(decision.tier, .usableForRecognition)
  }

  func testFaceQualityAccepts54PixelFaceForRecognitionButNotEnrollment() throws {
    let crop = try makeFaceCrop(rawWidth: 54, rawHeight: 54, cropWidth: 104, cropHeight: 114, sourceSize: CGSize(width: 360, height: 640))

    let decision = FaceQualityFilter().evaluate(crop)

    XCTAssertTrue(decision.acceptedForRecognition)
    XCTAssertFalse(decision.acceptedForEnrollment)
    XCTAssertEqual(decision.tier, .usableForRecognition)
  }

  func testLowResolutionQualityCanPassRecognitionButNotEnrollment() throws {
    let crop = try makeFaceCrop(
      rawWidth: 82,
      rawHeight: 82,
      cropWidth: 150,
      cropHeight: 150,
      sourceSize: CGSize(width: 360, height: 640),
      faceCaptureQuality: 0.09
    )

    let decision = FaceQualityFilter().evaluate(crop)

    XCTAssertTrue(decision.acceptedForRecognition)
    XCTAssertFalse(decision.acceptedForEnrollment)
    XCTAssertTrue(decision.reasons.contains("qualityTooLowForEnrollment"))
  }

  func testLoggedLowResolutionSamplePassesRecognitionButNotEnrollment() throws {
    let crop = try makeFaceCrop(
      rawWidth: 51,
      rawHeight: 51,
      cropWidth: 97,
      cropHeight: 109,
      sourceSize: CGSize(width: 360, height: 640),
      faceCaptureQuality: 0.09
    )

    let decision = FaceQualityFilter().evaluate(crop)

    XCTAssertTrue(decision.acceptedForRecognition)
    XCTAssertFalse(decision.acceptedForEnrollment)
    XCTAssertTrue(decision.reasons.contains("lowButAcceptedForRecognition"))
  }

  func testFaceMatcherThresholds() {
    let personId = UUID()
    let record = FaceEmbeddingRecord(
      id: UUID(),
      personId: personId,
      vector: [1, 0, 0],
      dimension: 3,
      qualityScore: nil,
      sourceFrameTimestamp: Date(),
      createdAt: Date(),
      sampleImageLocalPath: nil,
      metadata: nil
    )

    let known = FaceMatcher().match(vector: [1, 0, 0], against: [record])
    let unknown = FaceMatcher().match(vector: [0, 1, 0], against: [record])

    XCTAssertEqual(known.decision, .known)
    XCTAssertEqual(known.bestPersonId, personId)
    XCTAssertEqual(unknown.decision, .unknown)
  }

  func testEnrollmentPhysicalSampleCountCountsFramesNotVectors() {
    let records = [
      faceEmbeddingRecord(frame: 101, modelName: "AdaFace", modelVersion: "aws-v1", modelSource: "aws", preprocessingVersion: "adaface-v1"),
      faceEmbeddingRecord(frame: 101, modelName: "MobileFaceNet", modelVersion: "local-v1", modelSource: "local", preprocessingVersion: "mobilefacenet-v1"),
      faceEmbeddingRecord(frame: 102, modelName: "AdaFace", modelVersion: "aws-v1", modelSource: "aws", preprocessingVersion: "adaface-v1")
    ]

    XCTAssertEqual(IdentityPipeline.enrollmentPhysicalSampleCount(in: records), 2)
    XCTAssertEqual(Set(records.map { IdentityPipeline.enrollmentEmbeddingSpaceKey(for: $0) }).count, 2)
  }

  func testTrimPendingEnrollmentRecordsKeepsAllVectorsForLatestPhysicalSamples() {
    let records = [
      faceEmbeddingRecord(frame: 10, modelName: "AdaFace", modelVersion: "aws-v1", modelSource: "aws", preprocessingVersion: "adaface-v1"),
      faceEmbeddingRecord(frame: 10, modelName: "MobileFaceNet", modelVersion: "local-v1", modelSource: "local", preprocessingVersion: "mobilefacenet-v1"),
      faceEmbeddingRecord(frame: 11, modelName: "AdaFace", modelVersion: "aws-v1", modelSource: "aws", preprocessingVersion: "adaface-v1"),
      faceEmbeddingRecord(frame: 11, modelName: "MobileFaceNet", modelVersion: "local-v1", modelSource: "local", preprocessingVersion: "mobilefacenet-v1"),
      faceEmbeddingRecord(frame: 12, modelName: "AdaFace", modelVersion: "aws-v1", modelSource: "aws", preprocessingVersion: "adaface-v1")
    ]

    let trimmed = IdentityPipeline.trimPendingEnrollmentRecords(records, maxPhysicalSamples: 2)

    XCTAssertEqual(IdentityPipeline.enrollmentPhysicalSampleCount(in: trimmed), 2)
    XCTAssertEqual(trimmed.count, 3)
    XCTAssertEqual(Set(trimmed.compactMap(\.frameNumber)), Set<UInt64>([11, 12]))
    XCTAssertEqual(trimmed.filter { $0.frameNumber == 11 }.count, 2)
    XCTAssertEqual(trimmed.filter { $0.frameNumber == 12 }.count, 1)
  }

  func testIdentityThresholdConfigDefaultsAreCalibrationStartingPoints() {
    XCTAssertEqual(IdentityConfig.weakMatchThreshold, 0.60, accuracy: 0.0001)
    XCTAssertEqual(IdentityConfig.strongMatchThreshold, 0.70, accuracy: 0.0001)
    XCTAssertEqual(IdentityConfig.matchMarginThreshold, 0.05, accuracy: 0.0001)
    XCTAssertEqual(IdentityConfig.rollingWindowSize, 8)
    XCTAssertEqual(IdentityConfig.requiredStrongMatches, 3)
  }

  func testCalibrationSummaryComputesDistributionsAndRecommendations() {
    let samples = [
      calibrationSample(mode: .samePerson, score: 0.68, margin: 0.10),
      calibrationSample(mode: .samePerson, score: 0.72, margin: 0.12),
      calibrationSample(mode: .samePerson, score: 0.78, margin: 0.14),
      calibrationSample(mode: .differentPerson, score: 0.42, margin: 0.04),
      calibrationSample(mode: .differentPerson, score: 0.50, margin: 0.03),
      calibrationSample(mode: .differentPerson, score: 0.56, margin: 0.02)
    ]

    let summary = FaceCalibrationSummary(samples: samples)

    XCTAssertEqual(summary.samePersonCount, 3)
    XCTAssertEqual(summary.differentPersonCount, 3)
    XCTAssertNotNil(summary.sameP10)
    XCTAssertNotNil(summary.differentP90)
    XCTAssertGreaterThan(summary.recommendedStrong, summary.recommendedWeak)
    XCTAssertGreaterThanOrEqual(summary.recommendedMargin, IdentityConfig.matchMarginThreshold)
  }

  func testCalibrationSummaryHandlesNoFaceRejectedSamplesWithoutScores() {
    let samples = [
      calibrationSample(mode: .samePerson, score: nil, margin: nil, reason: "noFaceDetected"),
      calibrationSample(mode: .differentPerson, score: nil, margin: nil, reason: "qualityRejected")
    ]

    let summary = FaceCalibrationSummary(samples: samples)

    XCTAssertEqual(summary.samePersonCount, 0)
    XCTAssertEqual(summary.differentPersonCount, 0)
    XCTAssertEqual(summary.recommendedStrong, IdentityConfig.strongMatchThreshold, accuracy: 0.0001)
    XCTAssertEqual(summary.recommendedWeak, IdentityConfig.weakMatchThreshold, accuracy: 0.0001)
  }

  func testCalibrationLabelRequiresUserTapAndModel() async {
    let pipeline = IdentityPipeline()

    let automatic = await pipeline.recordCalibrationLabel(.differentPerson, source: .automatic)
    XCTAssertTrue(automatic.calibrationSampleCountText.contains("different 0"))
    XCTAssertFalse(automatic.canRecordCalibrationLabel)

    let tapped = await pipeline.recordCalibrationLabel(.samePerson, source: .userTap)
    XCTAssertTrue(tapped.calibrationSampleCountText.contains("same 0"))
    XCTAssertFalse(tapped.canRecordCalibrationLabel)
    XCTAssertFalse(tapped.summary.localizedCaseInsensitiveContains("saved"))
  }

  func testCosineSimilarityRejectsMismatchedDimensions() {
    XCTAssertEqual(FaceMatcher.cosineSimilarity([1, 0, 0], [1, 0]), 0)
    XCTAssertEqual(FaceMatcher.cosineSimilarity([1, 0, 0], [1, 0, 0]), 1)
  }

  func testFaceMatcherRejectsMismatchedModelVersion() {
    let personId = UUID()
    let embedding = FaceEmbedding(
      vector: [1, 0, 0],
      dimension: 3,
      modelName: "AdaFace",
      modelVersion: "v1",
      createdAt: Date()
    )
    let average = PersonAveragedEmbedding(
      id: UUID(),
      personId: personId,
      averagedVector: [1, 0, 0],
      vectorDimension: 3,
      sampleCount: 3,
      modelName: "AdaFace",
      modelVersion: "v2",
      updatedAt: Date()
    )

    let match = FaceMatcher().match(embedding: embedding, against: [average])

    XCTAssertEqual(match.decision, .unknown)
    XCTAssertNil(match.bestPersonId)
  }

  func testFaceMatcherRejectsMismatchedPreprocessingVersion() {
    let personId = UUID()
    let embedding = FaceEmbedding(
      vector: [1, 0, 0],
      dimension: 3,
      modelName: "AdaFace",
      modelVersion: "v1",
      modelSource: "AWS/AdaFace",
      preprocessingVersion: "adaface-ir101-webface12m-v1",
      createdAt: Date()
    )
    let average = PersonAveragedEmbedding(
      id: UUID(),
      personId: personId,
      averagedVector: [1, 0, 0],
      vectorDimension: 3,
      sampleCount: 3,
      modelName: "AdaFace",
      modelVersion: "v1",
      modelSource: "AWS/AdaFace",
      preprocessingVersion: "other-preprocessing",
      updatedAt: Date()
    )

    let match = FaceMatcher().match(embedding: embedding, against: [average])

    XCTAssertEqual(match.decision, .unknown)
    XCTAssertNil(match.bestPersonId)
  }

  func testAveragedEmbeddingIsL2Normalized() {
    let average = LocalIdentityStore.averagedNormalizedVector([
      [2, 0, 0],
      [0, 2, 0],
      [0, 2, 0]
    ])

    let norm = sqrt(average.reduce(Float(0)) { $0 + $1 * $1 })
    XCTAssertEqual(norm, 1, accuracy: 0.0001)
    XCTAssertEqual(average.count, 3)
  }

  func testL2NormalizeProducesUnitNorm() {
    let vector = LocalIdentityStore.l2Normalized([3, 4])

    let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
    XCTAssertEqual(norm, 1, accuracy: 0.0001)
    XCTAssertEqual(vector[0], 0.6, accuracy: 0.0001)
    XCTAssertEqual(vector[1], 0.8, accuracy: 0.0001)
  }

  func testAverageEmbeddingsProducesUnitNormCentroid() {
    let centroid = LocalIdentityStore.averagedNormalizedVector([
      [1, 0, 0],
      [1, 0, 0],
      [0, 1, 0]
    ])

    let norm = sqrt(centroid.reduce(Float(0)) { $0 + $1 * $1 })
    XCTAssertEqual(norm, 1, accuracy: 0.0001)
    XCTAssertEqual(centroid.count, 3)
    XCTAssertGreaterThan(centroid[0], centroid[1])
  }

  func testAverageEmbeddingsRejectsDimensionMismatch() {
    let centroid = LocalIdentityStore.averagedNormalizedVector([
      [1, 0, 0],
      [0, 1],
      [1, 0, 0]
    ])

    let norm = sqrt(centroid.reduce(Float(0)) { $0 + $1 * $1 })
    XCTAssertEqual(centroid.count, 3)
    XCTAssertEqual(norm, 1, accuracy: 0.0001)
    XCTAssertGreaterThan(centroid[0], 0.99)
  }

  func testCosineSimilarityRanksCorrectCentroidHighest() {
    let seanId = UUID()
    let otherId = UUID()
    let live = FaceEmbedding(
      vector: LocalIdentityStore.l2Normalized([0.95, 0.05, 0]),
      dimension: 3,
      modelName: "AdaFace",
      modelVersion: "v1",
      modelSource: "AWS/AdaFace",
      preprocessingVersion: "adaface-ir101-webface12m-v1",
      createdAt: Date()
    )
    let sean = PersonAveragedEmbedding(
      id: UUID(),
      personId: seanId,
      averagedVector: LocalIdentityStore.l2Normalized([1, 0, 0]),
      vectorDimension: 3,
      sampleCount: 3,
      modelName: "AdaFace",
      modelVersion: "v1",
      modelSource: "AWS/AdaFace",
      preprocessingVersion: "adaface-ir101-webface12m-v1",
      updatedAt: Date()
    )
    let other = PersonAveragedEmbedding(
      id: UUID(),
      personId: otherId,
      averagedVector: LocalIdentityStore.l2Normalized([0, 1, 0]),
      vectorDimension: 3,
      sampleCount: 3,
      modelName: "AdaFace",
      modelVersion: "v1",
      modelSource: "AWS/AdaFace",
      preprocessingVersion: "adaface-ir101-webface12m-v1",
      updatedAt: Date()
    )

    let match = FaceMatcher(knownThreshold: 0.7, unknownThreshold: 0.6, marginThreshold: 0.05)
      .match(embedding: live, against: [other, sean])

    XCTAssertEqual(match.bestPersonId, seanId)
    XCTAssertGreaterThan(match.bestSimilarity, match.secondBestSimilarity ?? 0)
  }

  func testMissingFaceEmbeddingModelThrowsDetectionOnlyError() async throws {
    let model = MissingFaceEmbeddingModel(expectedNames: FaceEmbeddingModelFactory.expectedModelNames)
    let image = try makeTestImage(width: 80, height: 80)

    do {
      _ = try await model.embed(faceImage: image)
      XCTFail("Missing model should not produce embeddings")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("No MobileFaceNet/Core ML face embedding model found"))
    }
  }

  func testAdaFaceIsPreferredWithMobileFaceNetFallbackResources() {
    XCTAssertEqual(FaceEmbeddingModelFactory.expectedModelNames.first, "AdaFace")
    XCTAssertEqual(FaceEmbeddingModelFactory.preferredModelName, "AdaFace")
    XCTAssertTrue(FaceEmbeddingModelFactory.expectedModelNames.contains("MobileFaceNet"))
    XCTAssertTrue(FaceEmbeddingModelFactory.diagnosticsText(bundle: .main).contains("source=AWS/AdaFace + Xiaoccer/MobileFaceNet_Pytorch"))
    XCTAssertTrue(FaceEmbeddingModelFactory.expectedModelResourceInstructions().contains("MobileFaceNet.mlpackage"))
    XCTAssertFalse(FaceEmbeddingModelFactory.diagnosticsText(bundle: .main).contains("ZJCV/facenet"))
  }

  func testRealDATCloudFaceWarmupContinuesAfterInitialHealthMiss() {
    XCTAssertTrue(StreamSessionViewModel.shouldContinueCloudFaceWarmupAfterInitialHealthMiss(
      useEC2Lifecycle: true,
      inputMode: .realGlasses
    ))
    XCTAssertFalse(StreamSessionViewModel.shouldContinueCloudFaceWarmupAfterInitialHealthMiss(
      useEC2Lifecycle: false,
      inputMode: .realGlasses
    ))
  }

  func testCloudFaceEmbeddingStartingStatusIsNotReportedAsMissing() async {
    let pipeline = IdentityPipeline()

    await pipeline.markCloudFaceEmbeddingStarting()
    let status = await pipeline.embeddingModelStatusText()

    XCTAssertTrue(status.contains("AWS AdaFace is starting"))
    XCTAssertFalse(status.localizedCaseInsensitiveContains("model missing"))
  }

  func testLocalFaceEmbeddingFactoryUsesBundledMobileFaceNet() {
    let model = FaceEmbeddingModelFactory.makeLocalModelOnly()
    XCTAssertFalse(model is MissingFaceEmbeddingModel)
    XCTAssertTrue(FaceEmbeddingModelFactory.expectedModelResourceNames().contains("MobileFaceNet.mlpackage"))
  }

  func testLocalMobileFaceNetEmbeddingUsesLocalMetadata() async throws {
    let model = FaceEmbeddingModelFactory.makeLocalModelOnly()
    let image = try makeTestImage(width: 96, height: 112)
    let embedding = try await model.embed(faceImage: image)

    XCTAssertEqual(embedding.modelName, "MobileFaceNet")
    XCTAssertEqual(embedding.modelSource, FaceEmbeddingModelFactory.localSourceName)
    XCTAssertEqual(embedding.preprocessingVersion, FaceEmbeddingModelFactory.preprocessingVersion)
    XCTAssertEqual(embedding.dimension, 128)
  }

  func testRollingIdentityRequiresRepeatedMatches() {
    let personId = UUID()
    let profile = PersonProfile(
      id: personId,
      displayName: "Sean",
      createdAt: Date(),
      updatedAt: Date(),
      notes: nil,
      isUnknownPlaceholder: false,
      lastSeenAt: nil,
      enrollmentStatus: .enrolled
    )
    let match = IdentityMatchResult(
      bestPersonId: personId,
      bestSimilarity: 0.9,
      secondBestSimilarity: nil,
      margin: nil,
      decision: .known,
      matchedEmbeddingId: UUID()
    )
    var tracker = RollingIdentityConfirmor()
    var state = tracker.update(match: match, profile: profile, sawGoodUnknownFace: false)
    XCTAssertNotEqual(state.state, .confirmed)
    state = tracker.update(match: match, profile: profile, sawGoodUnknownFace: false)
    XCTAssertNotEqual(state.state, .confirmed)
    state = tracker.update(match: match, profile: profile, sawGoodUnknownFace: false)
    XCTAssertEqual(state.state, .confirmed)
    XCTAssertEqual(state.personId, personId)
  }

  func testAssistanceCardFormatsKnownPersonForGlassesDisplay() {
    let card = AssistanceCardFormatter().makeCard(
      identity: .known(name: "Sarah", confidence: 0.92, userConfirmed: true),
      memory: AssistanceMemorySnapshot(
        lastInteraction: "3 weeks ago",
        contextTopics: ["Internship", "Japan trip"],
        reminder: "Follow up on resume"
      ),
      displayStatus: .glassesDisplay
    )

    XCTAssertEqual(card.title, "Sarah")
    XCTAssertFalse(card.usesFallbackOutput)
    XCTAssertTrue(card.lines.contains("Last: 3 weeks ago"))
    XCTAssertTrue(card.lines.contains("Context: Internship, Japan trip"))
    XCTAssertTrue(card.lines.contains("Reminder: Follow up on resume"))
    XCTAssertLessThanOrEqual(card.lines.count, 4)
    XCTAssertTrue(([card.title] + card.lines).allSatisfy { $0.count <= 48 })
  }

  func testAssistanceCardUsesPrivacyWarningForLowConfidenceMatch() {
    let card = AssistanceCardFormatter().makeCard(
      identity: .possibleMatch(name: "Sarah", confidence: 0.54),
      memory: AssistanceMemorySnapshot(
        lastInteraction: "Discussed confidential hiring details",
        contextTopics: ["Hiring"],
        reminder: "Ask about the offer"
      ),
      displayStatus: .glassesDisplay
    )

    XCTAssertEqual(card.title, "Possible: Sarah")
    XCTAssertTrue(card.lines.contains("Confidence: 54%"))
    XCTAssertTrue(card.lines.contains("Needs user confirmation"))
    XCTAssertTrue(card.lines.contains("Privacy: hide sensitive details"))
    XCTAssertFalse(card.text.contains("confidential"))
  }

  func testAssistanceCardHandlesNoFaceAndMultipleFaces() {
    let noFace = AssistanceCardFormatter().makeCard(
      identity: .noFaceDetected,
      memory: AssistanceMemorySnapshot(),
      displayStatus: .glassesDisplay
    )
    let multipleFaces = AssistanceCardFormatter().makeCard(
      identity: .multipleFaces(count: 3),
      memory: AssistanceMemorySnapshot(reminder: "Private note"),
      displayStatus: .glassesDisplay
    )

    XCTAssertEqual(noFace.title, "No face detected")
    XCTAssertTrue(noFace.lines.contains("Waiting for visible face"))
    XCTAssertEqual(multipleFaces.title, "3 faces detected")
    XCTAssertTrue(multipleFaces.lines.contains("Select one person"))
    XCTAssertFalse(multipleFaces.text.contains("Private note"))
  }

  func testAssistanceCardLabelsDisplayFallback() {
    let card = AssistanceCardFormatter().makeCard(
      identity: .unknown,
      memory: AssistanceMemorySnapshot(),
      displayStatus: .fallback("phone overlay")
    )

    XCTAssertTrue(card.usesFallbackOutput)
    XCTAssertEqual(card.title, "Unknown person")
    XCTAssertEqual(card.lines.first, "Fallback: phone overlay")
    XCTAssertTrue(card.lines.contains("Needs confirmation"))
  }

  func testGlassesDisplayInteractionEventSummaryAndLabels() {
    let event = GlassesDisplayInteractionEvent(
      appRunId: UUID(),
      personId: UUID(),
      displayName: "Sarah",
      cardTitle: "Sarah",
      cardText: "Sarah\nLast seen: yesterday\nReminder: Follow up on resume",
      action: .markReviewed,
      source: "glassesButton",
      createdAt: Date()
    )

    XCTAssertEqual(event.actionKind, .markReviewed)
    XCTAssertEqual(event.actionLabel, "Reviewed")
    XCTAssertTrue(event.displaySummary.contains("Reminder: Follow up on resume"))
    XCTAssertEqual(GlassesDisplayAction.startStream.buttonTitle, "Start Stream")
    XCTAssertEqual(GlassesDisplayAction.startStream.eventTitle, "Start stream")
    XCTAssertEqual(GlassesDisplayAction.stopStream.buttonTitle, "Stop")
    XCTAssertEqual(GlassesDisplayAction.stopStream.eventTitle, "Stop stream")
    XCTAssertEqual(GlassesDisplayAction.openContext.buttonTitle, "Context")
    XCTAssertEqual(GlassesDisplayAction.openTranscripts.buttonTitle, "Transcript")
    XCTAssertEqual(GlassesDisplayAction.snapshotFrame.buttonTitle, "Photo")
    XCTAssertEqual(GlassesDisplayAction.snapshotFrame.eventTitle, "Photo saved")
    XCTAssertEqual(GlassesDisplayAction.nextPage.buttonTitle, "More")
    XCTAssertTrue(GlassesDisplayAction.confirmRecognizedPerson.isIdentityPromptAction)
    XCTAssertTrue(GlassesDisplayAction.rejectRecognizedPerson.isIdentityPromptAction)
    XCTAssertFalse(GlassesDisplayAction.openContext.isIdentityPromptAction)
  }

  func testGlassesDisplayRendererKeepsStreamControlsVisible() {
    let starting = MementoGlassesDisplayRenderer.streamStatus(
      title: "Starting stream",
      message: "Preparing iPhone mic and glasses camera."
    )

    XCTAssertEqual(starting.title, "Starting stream")
    XCTAssertEqual(starting.primaryAction, .stopStream)
    XCTAssertEqual(starting.secondaryAction, .openPeople)
    XCTAssertTrue(starting.text.contains("Display stays active"))

    let streaming = MementoGlassesDisplayRenderer.streaming(
      currentPersonName: "Sarah",
      frameText: "12 received",
      statusText: "Display active"
    )

    XCTAssertEqual(streaming.title, "Streaming")
    XCTAssertEqual(streaming.primaryAction, .stopStream)
    XCTAssertEqual(streaming.secondaryAction, .openPeople)
    XCTAssertNil(streaming.tertiaryAction)
    XCTAssertTrue(streaming.text.contains("Current: Sarah"))
  }

  func testStreamingDashboardShowsNoFrameDiagnosticInsteadOfLookingForPeople() {
    let message = DATGlassesManager.noVideoFramesDiagnosticMessage(
      elapsedSeconds: 10,
      streamState: "streaming",
      deviceSessionState: "started"
    )

    XCTAssertTrue(message.contains("delivered no video frames"))
    XCTAssertTrue(message.contains("Face detection and recognition cannot run"))

    let dashboard = StreamSessionViewModel.streamingDashboardText(
      datFramesReceived: 0,
      lastFrameTimestampText: "none",
      datLastErrorText: message,
      hasReceivedFirstFrame: false
    )

    XCTAssertEqual(dashboard.frameText, "0 received; camera frames missing")
    XCTAssertEqual(dashboard.statusText, "Camera stream has no frames")
    XCTAssertEqual(dashboard.currentLineOverride, "Camera: no video frames")

    let streaming = MementoGlassesDisplayRenderer.streaming(
      currentPersonName: nil,
      frameText: dashboard.frameText,
      statusText: dashboard.statusText,
      currentLineOverride: dashboard.currentLineOverride
    )

    XCTAssertTrue(streaming.text.contains("Camera: no video frames"))
    XCTAssertFalse(streaming.text.contains("Current: Looking for people"))
  }

  func testDATStreamPreparingDisplayStatusIsCoalesced() {
    XCTAssertEqual(
      GlassesDisplaySendTiming.streamStatus(reason: "dat-stream-preparing"),
      .coalesced(nanoseconds: GlassesDisplaySendTiming.transientStatusDelayNanoseconds)
    )
    XCTAssertEqual(
      GlassesDisplaySendTiming.streamStatus(reason: "start-stream-from-glasses"),
      .immediate
    )
    XCTAssertEqual(
      GlassesDisplaySendTiming.streamStatus(reason: "dat-stream-paused"),
      .immediate
    )
  }

  func testNoConfirmedPersonDisplayPublishesOnlyDuringRunningStream() {
    XCTAssertTrue(StreamSessionViewModel.shouldPublishLiveDisplayAfterNoConfirmedPerson(
      datIsStreamRunning: true,
      streamStateText: "streaming"
    ))
    XCTAssertFalse(StreamSessionViewModel.shouldPublishLiveDisplayAfterNoConfirmedPerson(
      datIsStreamRunning: false,
      streamStateText: "streaming"
    ))
    XCTAssertFalse(StreamSessionViewModel.shouldPublishLiveDisplayAfterNoConfirmedPerson(
      datIsStreamRunning: true,
      streamStateText: "STOPPED"
    ))
  }

  func testLiveDisplayClearDoesNotRebuildRemainingCardAfterStop() {
    XCTAssertTrue(StreamSessionViewModel.shouldSendRemainingDisplayAfterClear(
      datIsStreamRunning: true,
      streamStateText: "streaming",
      activeWindowIsLive: true
    ))
    XCTAssertFalse(StreamSessionViewModel.shouldSendRemainingDisplayAfterClear(
      datIsStreamRunning: false,
      streamStateText: "STOPPED",
      activeWindowIsLive: true
    ))
    XCTAssertTrue(StreamSessionViewModel.shouldSendRemainingDisplayAfterClear(
      datIsStreamRunning: false,
      streamStateText: "STOPPED",
      activeWindowIsLive: false
    ))
  }

  func testUnknownIdentityPromptRequiresFaceEmbeddingResult() {
    XCTAssertFalse(StreamSessionViewModel.shouldAskToConfirmUnknownIdentity(
      activeIdentityState: .unknown,
      isUnknownPersonVisible: true,
      embeddingGenerated: false,
      matchDecisionText: "modelMissing"
    ))
    XCTAssertFalse(StreamSessionViewModel.shouldAskToConfirmUnknownIdentity(
      activeIdentityState: .unknown,
      isUnknownPersonVisible: true,
      embeddingGenerated: false,
      matchDecisionText: "embeddingFailed"
    ))
    XCTAssertTrue(StreamSessionViewModel.shouldAskToConfirmUnknownIdentity(
      activeIdentityState: .unknown,
      isUnknownPersonVisible: true,
      embeddingGenerated: true,
      matchDecisionText: "unknown"
    ))
  }

  func testRecognizedIdentityPromptAllowsFirstPossibleKnownMatch() {
    let personId = UUID()
    XCTAssertTrue(StreamSessionViewModel.shouldAskToConfirmRecognizedIdentity(
      activeIdentityState: .possible,
      personId: personId,
      embeddingGenerated: true,
      matchDecisionText: "known"
    ))
    XCTAssertTrue(StreamSessionViewModel.shouldAskToConfirmRecognizedIdentity(
      activeIdentityState: .confirmed,
      personId: personId,
      embeddingGenerated: true,
      matchDecisionText: "known"
    ))
    XCTAssertFalse(StreamSessionViewModel.shouldAskToConfirmRecognizedIdentity(
      activeIdentityState: .possible,
      personId: nil,
      embeddingGenerated: true,
      matchDecisionText: "known"
    ))
  }

  func testRecognizedIdentityPromptRejectsUnavailableEmbeddingResult() {
    XCTAssertFalse(StreamSessionViewModel.shouldAskToConfirmRecognizedIdentity(
      activeIdentityState: .possible,
      personId: UUID(),
      embeddingGenerated: false,
      matchDecisionText: "modelMissing"
    ))
  }

  func testRecognizedIdentityPromptPrefersCurrentRecognitionCropOverSavedThumbnail() {
    let currentRecognitionFace = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { context in
      UIColor.white.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
    }
    let savedProfile = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { context in
      UIColor.black.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
    }

    let selection = StreamSessionViewModel.identityConfirmationThumbnailForRecognizedPerson(
      currentRecognitionFaceThumbnail: currentRecognitionFace,
      savedPersonThumbnail: savedProfile
    )

    XCTAssertTrue(selection.image === currentRecognitionFace)
    XCTAssertEqual(selection.source, "currentRecognitionFaceCrop")
  }

  func testRecognizedIdentityPromptUsesSavedThumbnailOnlyWhenCurrentRecognitionCropMissing() {
    let savedProfile = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { context in
      UIColor.black.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
    }

    let selection = StreamSessionViewModel.identityConfirmationThumbnailForRecognizedPerson(
      currentRecognitionFaceThumbnail: nil,
      savedPersonThumbnail: savedProfile
    )

    XCTAssertTrue(selection.image === savedProfile)
    XCTAssertEqual(selection.source, "savedPersonThumbnail")
  }

  func testRecognizedIdentityPromptDoesNotUsePriorPersonRetainedCropWhenCurrentCropMissing() {
    let stalePriorPersonCrop = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { context in
      UIColor.red.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
    }
    let currentPersonSavedThumbnail = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { context in
      UIColor.green.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
    }

    let selection = StreamSessionViewModel.identityConfirmationThumbnailForRecognizedPerson(
      currentRecognitionFaceThumbnail: nil,
      savedPersonThumbnail: currentPersonSavedThumbnail
    )

    XCTAssertFalse(selection.image === stalePriorPersonCrop)
    XCTAssertTrue(selection.image === currentPersonSavedThumbnail)
    XCTAssertEqual(selection.source, "savedPersonThumbnail")
  }

  func testIdentityDisplayThumbnailProducesCompactJPEGForSignedUpload() throws {
    let sourceImage = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 180)).image { context in
      UIColor.systemBlue.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
      UIColor.white.setFill()
      context.fill(CGRect(x: 128, y: 38, width: 64, height: 64))
      context.fill(CGRect(x: 112, y: 112, width: 96, height: 44))
    }

    let data = StreamSessionViewModel.displayImageJPEGData(
      from: sourceImage,
      maxPixelDimension: 96,
      compressionQuality: 0.72
    )

    let jpegData = try XCTUnwrap(data)
    XCTAssertEqual(jpegData.first, 0xFF)
    XCTAssertEqual(jpegData.dropFirst().first, 0xD8)
    XCTAssertLessThan(jpegData.count, 20_000)

    let decoded = try XCTUnwrap(UIImage(data: jpegData))
    let decodedMaxPixelDimension = max(decoded.size.width * decoded.scale, decoded.size.height * decoded.scale)
    XCTAssertLessThanOrEqual(decodedMaxPixelDimension, 96)
    XCTAssertEqual(decoded.size.width * decoded.scale, decoded.size.height * decoded.scale)
  }

  func testIdentityDisplayThumbnailDefaultIsSmallerForRecognitionPrompt() throws {
    let sourceImage = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 240)).image { context in
      UIColor.systemBlue.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
      UIColor.white.setFill()
      context.fill(CGRect(x: 112, y: 48, width: 96, height: 96))
    }

    let data = StreamSessionViewModel.displayImageJPEGData(from: sourceImage)

    let jpegData = try XCTUnwrap(data)
    let decoded = try XCTUnwrap(UIImage(data: jpegData))
    let decodedMaxPixelDimension = max(decoded.size.width * decoded.scale, decoded.size.height * decoded.scale)
    XCTAssertLessThanOrEqual(decodedMaxPixelDimension, 64)
    XCTAssertEqual(decoded.size.width * decoded.scale, decoded.size.height * decoded.scale)
  }

  func testSupabaseSignedStorageURLBuildsAbsoluteHTTPSURL() throws {
    let baseURL = try XCTUnwrap(URL(string: "https://example.supabase.co"))
    let signedURL = "/storage/v1/object/sign/face-crops/service-role/display-thumbnails/gary.jpg?token=abc"

    let absoluteURL = try XCTUnwrap(SupabaseClient.absoluteStorageURL(from: signedURL, baseURL: baseURL))

    XCTAssertEqual(absoluteURL.scheme, "https")
    XCTAssertEqual(absoluteURL.host, "example.supabase.co")
    XCTAssertTrue(absoluteURL.absoluteString.contains("face-crops"))
    XCTAssertTrue(absoluteURL.absoluteString.contains("token=abc"))
  }

  func testSupabaseSignedStorageURLAddsStoragePrefixForObjectRelativeURL() throws {
    let baseURL = try XCTUnwrap(URL(string: "https://example.supabase.co"))
    let signedURL = "/object/sign/face-crops/service-role/display-thumbnails/gary.jpg?token=abc"

    let absoluteURL = try XCTUnwrap(SupabaseClient.absoluteStorageURL(from: signedURL, baseURL: baseURL))

    XCTAssertEqual(
      absoluteURL.absoluteString,
      "https://example.supabase.co/storage/v1/object/sign/face-crops/service-role/display-thumbnails/gary.jpg?token=abc"
    )
  }

  func testSupabaseSignedStorageURLPreservesAbsoluteHTTPSURL() throws {
    let baseURL = try XCTUnwrap(URL(string: "https://example.supabase.co"))
    let signedURL = "https://cdn.example.com/storage/v1/object/sign/face-crops/gary.jpg?token=abc"

    let absoluteURL = try XCTUnwrap(SupabaseClient.absoluteStorageURL(from: signedURL, baseURL: baseURL))

    XCTAssertEqual(absoluteURL.absoluteString, signedURL)
  }

  func testFaceRecognitionUnavailableStatusRequiresAcceptedFaceWithoutEmbedding() {
    XCTAssertTrue(StreamSessionViewModel.shouldShowFaceRecognitionUnavailableStatus(
      faceCandidateCount: 1,
      qualityPassCount: 1,
      embeddingGenerated: false,
      matchDecisionText: "modelMissing"
    ))
    XCTAssertFalse(StreamSessionViewModel.shouldShowFaceRecognitionUnavailableStatus(
      faceCandidateCount: 1,
      qualityPassCount: 1,
      embeddingGenerated: true,
      matchDecisionText: "unknown"
    ))
    XCTAssertFalse(StreamSessionViewModel.shouldShowFaceRecognitionUnavailableStatus(
      faceCandidateCount: 1,
      qualityPassCount: 0,
      embeddingGenerated: false,
      matchDecisionText: "modelMissing"
    ))
  }

  func testFaceRecognitionWarmingStatusUsesTemporaryCloudMessage() {
    XCTAssertTrue(StreamSessionViewModel.isCloudFaceRecognitionWarmingStatus(
      "AWS AdaFace worker is warming; face recognition is paused."
    ))
    XCTAssertTrue(StreamSessionViewModel.isCloudFaceRecognitionWarmingStatus(
      "AWS AdaFace is starting; face recognition will resume when the worker is ready."
    ))
    XCTAssertFalse(StreamSessionViewModel.isCloudFaceRecognitionWarmingStatus(
      "Face recognition model missing. Face labeling can save images, but live recognition is disabled."
    ))
  }

  func testLiveHomeSectionsShowRecallBeforeContextLikeStatus() {
    let sections = MementoGlassesDisplayRenderer.liveViewSections(
      assistanceCard: nil,
      recallSection: AssistanceDisplaySection(
        title: "Relevant memory",
        lines: ["Answer: Gary and Sean already discussed the demo plan."]
      ),
      identityPromptSection: nil,
      statusLine: "Status: Streaming. Identity analysis active.",
      isStreaming: true
    )

    XCTAssertEqual(sections.map(\.title), ["Relevant memory", "Stream running successfully"])
    XCTAssertTrue(sections.first?.lines.first?.contains("Gary and Sean already discussed") == true)
    XCTAssertEqual(sections.last?.lines, ["Mode: General - looking around", "Recognized people: None"])
  }

  func testLiveHomeSectionsStackMostRecentRecallBeforeOlderRecall() {
    let sections = MementoGlassesDisplayRenderer.liveViewSections(
      assistanceCard: nil,
      recallSections: [
        AssistanceDisplaySection(
          title: "Answer",
          lines: ["A: Washington, DC."]
        ),
        AssistanceDisplaySection(
          title: "Relevant memory",
          lines: ["Answer: Gary and Sean discussed the demo plan."]
        )
      ],
      identityPromptSection: nil,
      statusLine: "Status: Streaming. Identity analysis active.",
      isStreaming: true
    )

    XCTAssertEqual(sections.map(\.title), ["Answer", "Relevant memory", "Stream running successfully"])
    XCTAssertEqual(sections.first?.lines.first, "A: Washington, DC.")
    XCTAssertEqual(sections.dropFirst().first?.lines.first, "Answer: Gary and Sean discussed the demo plan.")
    XCTAssertEqual(sections.last?.lines, ["Mode: General - looking around", "Recognized people: None"])
  }

  func testLiveHomeSectionsPutRecognizedPersonPromptOnFirstPage() {
    let sections = MementoGlassesDisplayRenderer.liveViewSections(
      assistanceCard: MementoGlassesDisplayRenderer.streaming(
        currentPersonName: "Gary",
        frameText: "12 received",
        statusText: "Display active"
      ),
      recallSection: nil,
      identityPromptSection: AssistanceDisplaySection(
        title: "Confirm person",
        lines: [
          "Is this Gary?",
          "Use the check button to confirm.",
          "Use X to choose another person or Unknown."
        ]
      ),
      statusLine: "Status: Streaming. Identity analysis active.",
      isStreaming: true
    )

    XCTAssertEqual(sections.first?.title, "Confirm person")
    XCTAssertTrue(sections.first?.lines.contains("Is this Gary?") == true)
    XCTAssertEqual(sections.dropFirst().first?.title, "Stream running successfully")
    XCTAssertEqual(sections.dropFirst().first?.lines, ["Mode: General - looking around", "Recognized people: None"])
  }

  func testLiveHomeSectionsPutIdentityPhotoOnPromptPage() {
    let sections = MementoGlassesDisplayRenderer.liveViewSections(
      assistanceCard: MementoGlassesDisplayRenderer.streaming(
        currentPersonName: "Gary",
        frameText: "12 received",
        statusText: "Display active"
      ),
      recallSection: AssistanceDisplaySection(
        title: "Relevant memory",
        lines: ["Summary: Gary worked on the demo."]
      ),
      identityPromptSection: AssistanceDisplaySection(
        title: "Is this Gary?",
        lines: ["Use the check button to confirm."],
        thumbnailImageURI: "https://example.com/gary.jpg",
        thumbnailImageSize: .fill
      ),
      identityPhotoSection: nil,
      statusLine: "Status: Streaming. Identity analysis active.",
      isStreaming: true
    )

    XCTAssertEqual(sections.map(\.title), [
      "Is this Gary?",
      "Relevant memory",
      "Stream running successfully"
    ])
    XCTAssertEqual(sections[0].thumbnailImageURI, "https://example.com/gary.jpg")
    XCTAssertEqual(sections[0].thumbnailImageSize, .fill)
  }

  func testDisplayPageImagesStayScopedToPromptSection() {
    let card = AssistanceDisplayCard(
      title: "Is this Gary?",
      lines: [],
      usesFallbackOutput: false,
      sections: [
        AssistanceDisplaySection(
          title: "Is this Gary?",
          lines: ["Use the check button to confirm."],
          thumbnailImageURI: "https://example.com/gary.jpg",
          thumbnailImageSize: .fill
        ),
        AssistanceDisplaySection(title: "Streaming", lines: ["Status: Streaming."])
      ],
      thumbnailImageURI: nil
    )

    let pages = DATGlassesManager.displayPageImageDiagnostics(for: card)

    XCTAssertEqual(pages.map { $0.title }, ["Is this Gary?", "Streaming"])
    XCTAssertEqual(pages.map { $0.hasImage }, [true, false])
  }

  func testDisplayPageImageDetailsUseFillForIdentityPromptSection() {
    let card = AssistanceDisplayCard(
      title: "Is this Gary?",
      lines: [],
      usesFallbackOutput: false,
      sections: [
        AssistanceDisplaySection(
          title: "Is this Gary?",
          lines: ["Use the check button to confirm."],
          thumbnailImageURI: "https://example.com/gary.jpg",
          thumbnailImageSize: .fill
        )
      ],
      thumbnailImageURI: nil
    )

    let pages = DATGlassesManager.displayPageImageDetailsForTesting(for: card)

    XCTAssertEqual(pages.map { $0.title }, ["Is this Gary?"])
    XCTAssertEqual(pages.map { $0.hasImage }, [true])
    XCTAssertEqual(pages.map { $0.imageSize }, [.fill])
  }

  func testConfirmedPersonSummaryStacksAsMostRecentLiveRecall() {
    let personId = UUID()
    let confirmedSummary = MementoGlassesDisplayRenderer.confirmedPersonSummarySection(
      for: PersonConversationSummary(
        personId: personId,
        displayName: "Sean",
        lastSeenText: "today",
        summary: "You discussed the glasses display image issue and agreed the recognition photo should be smaller.",
        conversationCount: 1,
        generatedAt: Date(timeIntervalSince1970: 1_800_000_000)
      ),
      presentPeople: ["Gary", "Sean"]
    )

    let sections = MementoGlassesDisplayRenderer.liveViewSections(
      assistanceCard: MementoGlassesDisplayRenderer.streaming(
        currentPersonName: "Sean",
        frameText: "12 received",
        statusText: "Display active"
      ),
      recallSections: [
        confirmedSummary,
        AssistanceDisplaySection(title: "Answer", lines: ["A: Washington, DC."])
      ],
      identityPromptSection: nil,
      statusLine: "Status: Streaming. Identity analysis active.",
      isStreaming: true
    )

    XCTAssertEqual(sections.map(\.title), ["Last with Sean", "Answer", "Stream running successfully"])
    XCTAssertEqual(sections.first?.lines.first, "Present with you: Gary, Sean")
    XCTAssertEqual(sections.first?.lines.dropFirst().first, "Summary: You discussed the glasses display image issue and agreed the recognition photo should be smaller.")
  }

  func testConfirmedPersonSummarySectionTrimsLocalFallbackMetadata() throws {
    let longLocalFallback = """
    Saved history: 3 conversation(s), 42 attributed line(s). Recent context: Conversation Jun 3, 2026 at 7:24 AM: Sean: We tested the Meta glasses display and saw the photo page. You: Let's make the image smaller and keep the previous summary visible after confirmation. Sean: That should appear as the first page in the recall stack.
    """

    let section = MementoGlassesDisplayRenderer.confirmedPersonSummarySection(for: PersonConversationSummary(
      personId: UUID(),
      displayName: "Sean",
      lastSeenText: "today",
      summary: longLocalFallback,
      conversationCount: 3,
      generatedAt: Date(timeIntervalSince1970: 1_800_000_000)
    ))

    let line = try XCTUnwrap(section.lines.first)
    XCTAssertEqual(section.title, "Last with Sean")
    XCTAssertTrue(line.hasPrefix("Summary: Sean: We tested the Meta glasses display"))
    XCTAssertFalse(line.contains("Saved history"))
    XCTAssertFalse(line.contains("conversation(s)"))
    XCTAssertLessThanOrEqual(line.count, 132)
  }

  func testStreamSummaryPromptUsesWearerPerspective() {
    let personId = UUID()
    let request = StreamSummaryRequest(
      transcripts: [],
      sceneContexts: [],
      startedAt: Date(timeIntervalSince1970: 100),
      endedAt: Date(timeIntervalSince1970: 120),
      identityEvidence: SceneContextIdentityEvidence(
        wearerName: "you",
        conversationPartnerName: "Gary",
        conversationPartnerPersonId: personId,
        conversationPartnerState: "confirmed",
        confidence: 0.9,
        sourceSummary: "face:Gary"
      )
    )

    let prompt = SceneContextClient.streamSummaryPromptForTesting(request)

    XCTAssertTrue(prompt.contains("you looked at Gary"))
    XCTAssertTrue(prompt.contains("people present with the wearer"))
    XCTAssertTrue(prompt.contains("scene records describe what the wearer saw"))
    XCTAssertTrue(prompt.contains("The app user is the smart-glasses wearer"))
    XCTAssertTrue(prompt.contains("Recognized faces, conversationPartnerName, activePeople, and transcript displayName values are people present with you, not you"))
    XCTAssertTrue(prompt.contains("semantic place or environment category"))
  }

  func testSceneContextPromptDefinesWearerAndRecognizedPeopleSeparately() {
    let personId = UUID()
    let request = SceneContextRequest(
      appRunId: UUID(),
      conversationSessionId: UUID(),
      frames: [],
      transcripts: [],
      identityEvidence: SceneContextIdentityEvidence(
        wearerName: "you",
        conversationPartnerName: "Gary",
        conversationPartnerPersonId: personId,
        conversationPartnerState: "confirmed",
        confidence: 0.92,
        sourceSummary: "face:Gary"
      ),
      location: nil,
      startedAt: Date(timeIntervalSince1970: 100),
      endedAt: Date(timeIntervalSince1970: 120)
    )

    let prompt = SceneContextClient.sceneContextPromptForTesting(request)

    XCTAssertTrue(prompt.contains("app user/wearer = \"you\""))
    XCTAssertTrue(prompt.contains("recognized faces, activePeople, conversationPartnerName, and transcript displayName values are other people present with you"))
    XCTAssertTrue(prompt.contains("you saw/spoke with [name]"))
    XCTAssertTrue(prompt.contains("Gary"))
  }

  func testSceneContextPromptDoesNotExposeRawCoordinates() {
    let request = SceneContextRequest(
      appRunId: UUID(),
      conversationSessionId: UUID(),
      frames: [],
      transcripts: [],
      identityEvidence: nil,
      location: SceneLocationSnapshot(
        latitude: 37.12345,
        longitude: -122.98765,
        horizontalAccuracy: 42,
        label: "Location 37.1234, -122.9876 (+/- 42m)",
        capturedAt: Date(timeIntervalSince1970: 100)
      ),
      startedAt: Date(timeIntervalSince1970: 100),
      endedAt: Date(timeIntervalSince1970: 120)
    )

    let prompt = SceneContextClient.sceneContextPromptForTesting(request)

    XCTAssertFalse(prompt.localizedCaseInsensitiveContains("lat "))
    XCTAssertFalse(prompt.localizedCaseInsensitiveContains("lon "))
    XCTAssertFalse(prompt.contains("37.12345"))
    XCTAssertFalse(prompt.contains("-122.98765"))
    XCTAssertTrue(prompt.contains("semantic place or environment category"))
    XCTAssertTrue(prompt.contains("iPhone location available within about 42m"))
  }

  func testGlassesDisplayActionIconsDescribeFunctions() {
    XCTAssertEqual(DATGlassesManager.displayIconName(for: .startStream), .videoCamera)
    XCTAssertEqual(DATGlassesManager.displayIconName(for: .stopStream), .videoCameraOff)
    XCTAssertEqual(DATGlassesManager.displayIconName(for: .openPeople), .threePeopleOverlapping)
    XCTAssertEqual(DATGlassesManager.displayIconName(for: .openContext), .iCircle)
    XCTAssertEqual(DATGlassesManager.displayIconName(for: .openTranscripts), .speechBubbleOff)
    XCTAssertEqual(DATGlassesManager.displayIconName(for: .markReviewed), .checkmarkCircle)
    XCTAssertEqual(DATGlassesManager.displayIconName(for: .previousPage), .arrowLeft)
    XCTAssertEqual(DATGlassesManager.displayIconName(for: .nextPage), .arrowRight)
    XCTAssertEqual(DATGlassesManager.displayIconName(for: .confirmRecognizedPerson), .checkmarkCircle)
    XCTAssertEqual(DATGlassesManager.displayIconName(for: .rejectRecognizedPerson), .x)
    XCTAssertEqual(DATGlassesManager.pinnedStreamActions(), [.stopStream, .openPeople, .previousPage, .nextPage])
  }

  func testAlibabaLiveTranscriptionRemovesOverlappedWords() {
    let previous = "I started explaining the project timeline and next steps"
    let current = "timeline and next steps are to test the glasses display"

    let deduped = AlibabaLiveAudioChunkTranscriber.removingOverlappingPrefix(
      previousTranscript: previous,
      currentTranscript: current
    )

    XCTAssertEqual(deduped, "are to test the glasses display")
  }

  func testPeopleDisplayShowsBriefLatestTranscript() {
    let personId = UUID()
    let appRunId = UUID()
    let sessionId = UUID()
    let entry = PersonDictionaryEntry(
      profile: PersonProfile(
        id: personId,
        displayName: "Sarah",
        createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_800_000_100),
        notes: nil,
        isUnknownPlaceholder: false,
        lastSeenAt: Date(timeIntervalSince1970: 1_800_000_100),
        enrollmentStatus: .enrolled
      ),
      thumbnail: nil,
      transcripts: [
        TranscriptChunk(
          id: UUID(),
          appRunId: appRunId,
          conversationSessionId: sessionId,
          personId: personId,
          activeIdentityState: "known",
          text: "Older transcript",
          isFinal: true,
          startedAt: nil,
          endedAt: nil,
          transcriptUpdatedAt: Date(timeIntervalSince1970: 1_800_000_000),
          source: "test",
          createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        ),
        TranscriptChunk(
          id: UUID(),
          appRunId: appRunId,
          conversationSessionId: sessionId,
          personId: personId,
          activeIdentityState: "known",
          text: "Latest quick recap from the conversation",
          isFinal: true,
          startedAt: nil,
          endedAt: nil,
          transcriptUpdatedAt: Date(timeIntervalSince1970: 1_800_000_200),
          source: "test",
          createdAt: Date(timeIntervalSince1970: 1_800_000_200)
        )
      ],
      interactionDays: [],
      embeddingImages: []
    )

    let card = MementoGlassesDisplayRenderer.peopleList(
      entries: [entry],
      currentPersonId: personId,
      page: 0
    )

    XCTAssertTrue(card.text.contains("Latest quick recap"))
    XCTAssertFalse(card.text.contains("2 transcripts"))
  }

  func testInteractionDaysIncludeGlassesDisplayReviews() {
    let appRunId = UUID()
    let personId = UUID()
    let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
    let shown = GlassesDisplayInteractionEvent(
      appRunId: appRunId,
      personId: personId,
      displayName: "Sarah",
      cardTitle: "Sarah",
      cardText: "Sarah\nContext: design review",
      action: .displayed,
      source: "displaySend",
      createdAt: createdAt
    )
    let tapped = GlassesDisplayInteractionEvent(
      appRunId: appRunId,
      personId: personId,
      displayName: "Sarah",
      cardTitle: "Sarah",
      cardText: "Sarah\nContext: design review",
      action: .openPeople,
      source: "glassesButton",
      createdAt: createdAt.addingTimeInterval(60)
    )

    let days = IdentityPipeline.buildInteractionDays(
      transcripts: [],
      embeddings: [],
      glassesInteractions: [shown, tapped]
    )

    XCTAssertEqual(days.count, 1)
    XCTAssertEqual(days.first?.totalGlassesInteractions, 2)
    XCTAssertEqual(days.first?.hours.first?.glassesInteractions.compactMap(\.actionKind) ?? [], [.displayed, .openPeople])
  }

  func testSpeechAndMicrophoneUsageDescriptionsArePresent() {
    let speech = Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") as? String
    let microphone = Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String

    XCTAssertFalse(speech?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    XCTAssertFalse(microphone?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
  }

  func testDiarizedVoiceEnrollmentUsesAWSEmbeddingRuntime() async {
    await withTemporarySpeakerStorage {
      let personId = UUID()
      let pipeline = SpeakerIdentityPipeline(
        iPhoneEmbeddingModel: FixedSpeakerEmbeddingModel(runtime: SpeakerEmbeddingRuntime.localCoreML, vector: [1, 0, 0]),
        workerEmbeddingModel: FixedSpeakerEmbeddingModel(runtime: SpeakerEmbeddingRuntime.awsTitaNet, vector: [0, 1, 0])
      )

      let result = await pipeline.enrollFromAudioData(
        makeMono16BitWAV(seconds: 5),
        personId: personId,
        name: "Gary",
        preferAWS: true,
        allowLocalFallback: false
      )

      XCTAssertTrue(result.saved)
      let runtimes = await pipeline.enrollmentRuntimeSignatures(for: personId)
      let hasAWSEnrollment = await pipeline.hasCompatibleSpeakerEnrollment(for: personId, runtime: SpeakerEmbeddingRuntime.awsTitaNet)
      let hasPreview = await pipeline.hasVoicePreview(for: personId)
      XCTAssertEqual(runtimes, [SpeakerEmbeddingRuntime.awsTitaNet])
      XCTAssertTrue(hasAWSEnrollment)
      XCTAssertTrue(hasPreview)
    }
  }

  func testLocalAndAWSSpeakerEnrollmentsStaySeparate() async {
    await withTemporarySpeakerStorage {
      let personId = UUID()
      let pipeline = SpeakerIdentityPipeline(
        iPhoneEmbeddingModel: FixedSpeakerEmbeddingModel(runtime: SpeakerEmbeddingRuntime.localCoreML, vector: [1, 0, 0]),
        workerEmbeddingModel: FixedSpeakerEmbeddingModel(runtime: SpeakerEmbeddingRuntime.awsTitaNet, vector: [0, 1, 0])
      )

      _ = await pipeline.enrollFromAudioData(
        makeMono16BitWAV(seconds: 5),
        personId: personId,
        name: "Gary",
        preferAWS: true,
        allowLocalFallback: false
      )
      _ = await pipeline.enrollFromAudioData(
        makeMono16BitWAV(seconds: 5),
        personId: personId,
        name: "Gary",
        preferAWS: false
      )

      let runtimes = await pipeline.enrollmentRuntimeSignatures(for: personId)
      let sampleCount = await pipeline.sampleCountForPerson(personId)
      XCTAssertEqual(runtimes, [SpeakerEmbeddingRuntime.awsTitaNet, SpeakerEmbeddingRuntime.localCoreML])
      XCTAssertEqual(sampleCount, 2)
    }
  }

  func testDiarizedVoiceEnrollmentRejectsMissingAWSWithoutLocalFallback() async {
    await withTemporarySpeakerStorage {
      let personId = UUID()
      let pipeline = SpeakerIdentityPipeline(
        iPhoneEmbeddingModel: FixedSpeakerEmbeddingModel(runtime: SpeakerEmbeddingRuntime.localCoreML, vector: [1, 0, 0])
      )

      let result = await pipeline.enrollFromAudioData(
        makeMono16BitWAV(seconds: 5),
        personId: personId,
        name: "Gary",
        preferAWS: true,
        allowLocalFallback: false
      )

      XCTAssertFalse(result.saved)
      let runtimes = await pipeline.enrollmentRuntimeSignatures(for: personId)
      XCTAssertEqual(runtimes, [])
    }
  }

  func testDiarizedVoiceEnrollmentRejectsTooShortOrMissingClip() async {
    await withTemporarySpeakerStorage {
      let personId = UUID()
      let pipeline = SpeakerIdentityPipeline(
        iPhoneEmbeddingModel: FixedSpeakerEmbeddingModel(runtime: SpeakerEmbeddingRuntime.localCoreML, vector: [1, 0, 0]),
        workerEmbeddingModel: FixedSpeakerEmbeddingModel(runtime: SpeakerEmbeddingRuntime.awsTitaNet, vector: [0, 1, 0])
      )

      let tooShort = await pipeline.enrollFromAudioData(
        makeMono16BitWAV(seconds: 1),
        personId: personId,
        name: "Gary",
        preferAWS: true
      )
      let missingClip = await pipeline.enrollFromAudioData(
        Data(),
        personId: personId,
        name: "Gary",
        preferAWS: true
      )

      XCTAssertFalse(tooShort.saved)
      XCTAssertFalse(missingClip.saved)
      let runtimes = await pipeline.enrollmentRuntimeSignatures(for: personId)
      XCTAssertEqual(runtimes, [])
    }
  }

  func testDiarizedVoicePreviewOnlyPersistsShortClipWithoutEnrollment() async {
    await withTemporarySpeakerStorage {
      let personId = UUID()
      let pipeline = SpeakerIdentityPipeline(
        iPhoneEmbeddingModel: FixedSpeakerEmbeddingModel(runtime: SpeakerEmbeddingRuntime.localCoreML, vector: [1, 0, 0]),
        workerEmbeddingModel: FixedSpeakerEmbeddingModel(runtime: SpeakerEmbeddingRuntime.awsTitaNet, vector: [0, 1, 0])
      )

      let clip = makeMono16BitWAV(seconds: 1.4)
      let enrollment = await pipeline.enrollFromAudioData(
        clip,
        personId: personId,
        name: "Gary",
        preferAWS: true
      )
      let previewOnly = await pipeline.saveDiarizedVoicePreviewOnly(
        clip,
        personId: personId,
        name: "Gary"
      )

      XCTAssertFalse(enrollment.saved)
      XCTAssertTrue(previewOnly.saved)
      let runtimes = await pipeline.enrollmentRuntimeSignatures(for: personId)
      let hasEnrollment = await pipeline.hasCompatibleSpeakerEnrollment(for: personId, runtime: SpeakerEmbeddingRuntime.awsTitaNet)
      let previewSamples = await pipeline.voicePreviewSamples(for: personId)
      XCTAssertEqual(runtimes, [])
      XCTAssertFalse(hasEnrollment)
      XCTAssertGreaterThan(previewSamples.count, 0)
    }
  }

  func testUnknownDiarizationSpeakerPromptRequiresPlayablePreview() throws {
    let sessionId = UUID()
    let withPreview = UnknownDiarizationSpeaker(
      id: "Speaker 0",
      speakerIndex: 0,
      clipS3Key: nil,
      segmentCount: 2,
      totalSeconds: 5,
      conversationSessionId: sessionId,
      clipData: try MonoPCM16WAVData.make(samples: [1200, -1200, 900, -900], sampleRate: 16_000)
    )
    let missingPreview = UnknownDiarizationSpeaker(
      id: "Speaker 1",
      speakerIndex: 1,
      clipS3Key: nil,
      segmentCount: 1,
      totalSeconds: 4,
      conversationSessionId: sessionId,
      clipData: nil
    )

    XCTAssertNil(StreamSessionViewModel.speakerEnrollmentSuppressionReason(for: withPreview))
    XCTAssertEqual(
      StreamSessionViewModel.speakerEnrollmentSuppressionReason(for: missingPreview),
      "missingPreviewClip"
    )
    XCTAssertEqual(
      StreamSessionViewModel.promptableUnknownSpeakers([missingPreview, withPreview]).map(\.speakerIndex),
      [0]
    )
  }

  func testUnknownDiarizationPreviewSelectionUsesShortFallback() {
    let tooShort = DiarizenSegment(start: 0.0, end: 0.7, speakerIndex: 0, text: "hi")
    let fallback = DiarizenSegment(start: 1.0, end: 2.4, speakerIndex: 0, text: "hello there")
    let longerFallback = DiarizenSegment(start: 3.0, end: 4.9, speakerIndex: 0, text: "short but usable")

    let selected = StreamSessionViewModel.preferredUnknownSpeakerPreviewSegment([
      tooShort,
      fallback,
      longerFallback
    ])

    XCTAssertEqual(selected?.start, longerFallback.start)
    XCTAssertEqual(selected?.end, longerFallback.end)
  }

  func testUnknownDiarizationPreviewSelectionPrefersEmbeddingLengthSegment() {
    let shortFallback = DiarizenSegment(start: 0.0, end: 2.8, speakerIndex: 0, text: "short")
    let embeddingLength = DiarizenSegment(start: 4.0, end: 7.1, speakerIndex: 0, text: "long enough")

    let selected = StreamSessionViewModel.preferredUnknownSpeakerPreviewSegment([
      shortFallback,
      embeddingLength
    ])

    XCTAssertEqual(selected?.start, embeddingLength.start)
    XCTAssertEqual(selected?.end, embeddingLength.end)
  }

  func testUnknownDiarizationSpeakerPromptDedupesIdenticalPreviewData() throws {
    let clip = try MonoPCM16WAVData.make(samples: [1800, -1800, 600, -600], sampleRate: 16_000)
    let sessionId = UUID()
    let first = UnknownDiarizationSpeaker(
      id: "Speaker 0",
      speakerIndex: 0,
      clipS3Key: nil,
      segmentCount: 1,
      totalSeconds: 5,
      conversationSessionId: sessionId,
      clipData: clip
    )
    let duplicate = UnknownDiarizationSpeaker(
      id: "Speaker 1",
      speakerIndex: 1,
      clipS3Key: nil,
      segmentCount: 1,
      totalSeconds: 5,
      conversationSessionId: sessionId,
      clipData: clip
    )

    XCTAssertEqual(
      StreamSessionViewModel.promptableUnknownSpeakers([duplicate, first]).map(\.speakerIndex),
      [0]
    )
  }

  func testDiarizenJobSpecAndStatusCarryActionableFailureMetadata() throws {
    let spec = DiarizenJobSpec(
      jobId: "JOB123",
      audioKey: "diarizen/audio/JOB123.wav",
      streamStartUnix: 1_780_000_000,
      resultKey: "diarizen/results/JOB123/result.json",
      statusKey: "diarizen/jobs/JOB123/status.json",
      errorKey: "diarizen/jobs/JOB123/error.json",
      conversationSessionId: "SESSION123",
      audioDurationSeconds: 42.5,
      audioByteCount: 1_360_044,
      createdAt: "2026-06-08T08:00:00Z"
    )
    let specData = try JSONEncoder().encode(spec)
    let decodedSpec = try JSONDecoder().decode(DiarizenJobSpec.self, from: specData)

    XCTAssertEqual(decodedSpec.jobId, "JOB123")
    XCTAssertEqual(decodedSpec.resultKey, "diarizen/results/JOB123/result.json")
    XCTAssertEqual(decodedSpec.statusKey, "diarizen/jobs/JOB123/status.json")
    XCTAssertEqual(decodedSpec.conversationSessionId, "SESSION123")
    XCTAssertEqual(decodedSpec.audioDurationSeconds, 42.5)

    let statusJSON = """
    {
      "jobId": "JOB123",
      "state": "failed",
      "audioKey": "diarizen/audio/JOB123.wav",
      "resultKey": "diarizen/results/JOB123/result.json",
      "statusKey": "diarizen/jobs/JOB123/status.json",
      "errorKind": "ec2StoppedBeforeResult",
      "errorMessage": "Result key was still missing.",
      "instanceState": "stopped",
      "updatedAt": "2026-06-08T08:14:00Z"
    }
    """.data(using: .utf8)!
    let status = try JSONDecoder().decode(DiarizenJobStatus.self, from: statusJSON)

    XCTAssertEqual(status.jobId, "JOB123")
    XCTAssertEqual(status.state, "failed")
    XCTAssertEqual(status.errorKind, "ec2StoppedBeforeResult")
    XCTAssertEqual(status.instanceState, "stopped")
  }

  func testMonoPCM16WAVDataBuildsReadablePreviewClipWithoutAVAudioFileWriter() throws {
    let samples: [Int16] = [-1200, 0, 1200, 2400]
    let data = try MonoPCM16WAVData.make(samples: samples, sampleRate: 16_000)

    XCTAssertEqual(ascii(data, offset: 0, length: 4), "RIFF")
    XCTAssertEqual(readUInt32LE(data, offset: 4), UInt32(36 + samples.count * 2))
    XCTAssertEqual(ascii(data, offset: 8, length: 4), "WAVE")
    XCTAssertEqual(ascii(data, offset: 12, length: 4), "fmt ")
    XCTAssertEqual(readUInt32LE(data, offset: 16), 16)
    XCTAssertEqual(readUInt16LE(data, offset: 20), 1)
    XCTAssertEqual(readUInt16LE(data, offset: 22), 1)
    XCTAssertEqual(readUInt32LE(data, offset: 24), 16_000)
    XCTAssertEqual(readUInt32LE(data, offset: 28), 32_000)
    XCTAssertEqual(readUInt16LE(data, offset: 32), 2)
    XCTAssertEqual(readUInt16LE(data, offset: 34), 16)
    XCTAssertEqual(ascii(data, offset: 36, length: 4), "data")
    XCTAssertEqual(readUInt32LE(data, offset: 40), UInt32(samples.count * 2))
    XCTAssertEqual(readUInt16LE(data, offset: 44), UInt16(bitPattern: samples[0]))

    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("mono-pcm16-preview-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    try data.write(to: url)
    let file = try AVAudioFile(forReading: url)
    XCTAssertEqual(file.fileFormat.channelCount, 1)
    XCTAssertEqual(file.fileFormat.sampleRate, 16_000, accuracy: 0.1)
    XCTAssertEqual(file.length, AVAudioFramePosition(samples.count))
  }

  private func withTemporarySpeakerStorage(_ body: () async -> Void) async {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("speaker-embeddings-\(UUID().uuidString).json")
    SpeakerIdentityPipeline.storageURLOverride = url
    defer {
      SpeakerIdentityPipeline.storageURLOverride = nil
      try? FileManager.default.removeItem(at: url)
    }
    await body()
  }

  private func makeMono16BitWAV(seconds: Double, sampleRate: Int = 16_000) -> Data {
    let sampleCount = Int(seconds * Double(sampleRate))
    var samples: [Int16] = []
    samples.reserveCapacity(sampleCount)
    for index in 0..<sampleCount {
      let sample = sin(2 * Double.pi * 220 * Double(index) / Double(sampleRate))
      samples.append(Int16(sample * Double(Int16.max) * 0.2))
    }
    return try! MonoPCM16WAVData.make(samples: samples, sampleRate: Double(sampleRate))
  }

  private func ascii(_ data: Data, offset: Int, length: Int) -> String? {
    String(data: data.subdata(in: offset..<(offset + length)), encoding: .ascii)
  }

  private func readUInt16LE(_ data: Data, offset: Int) -> UInt16 {
    UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
  }

  private func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
    UInt32(data[offset])
      | (UInt32(data[offset + 1]) << 8)
      | (UInt32(data[offset + 2]) << 16)
      | (UInt32(data[offset + 3]) << 24)
  }

  private func makeTestImage(width: Int, height: Int) throws -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      throw NSError(domain: "MementoTests", code: 1)
    }
    context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else {
      throw NSError(domain: "MementoTests", code: 2)
    }
    return image
  }

  private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [
      kCVPixelBufferCGImageCompatibilityKey: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey: true,
      kCVPixelBufferIOSurfacePropertiesKey: [:]
    ]
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      width,
      height,
      kCVPixelFormatType_32BGRA,
      attributes as CFDictionary,
      &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
      throw NSError(domain: "MementoTests", code: Int(status))
    }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
      baseAddress.initializeMemory(as: UInt8.self, repeating: 128, count: CVPixelBufferGetDataSize(pixelBuffer))
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    return pixelBuffer
  }

  private func calibrationSample(
    mode: FaceCalibrationMode,
    score: Float?,
    margin: Float?,
    reason: String? = nil
  ) -> FaceCalibrationSample {
    FaceCalibrationSample(
      mode: mode,
      source: .userTap,
      profileLabel: mode == .samePerson ? "Sean" : "NonMatch",
      score: score,
      secondBestScore: nil,
      margin: margin,
      threshold: IdentityConfig.strongMatchThreshold,
      decision: score == nil ? "notMatched" : "possibleMatch",
      rawFaceWidth: 96,
      rawFaceHeight: 96,
      cropWidth: 160,
      cropHeight: 160,
      quality: 0.35,
      brightness: 0.42,
      blur: nil,
      acceptedForRecognition: score != nil,
      acceptedForEnrollment: mode == .samePerson && score != nil,
      rejectionReason: reason,
      createdAt: Date()
    )
  }

  private func partnerEvidence(
    _ source: ConversationPartnerEvidence.Source,
    personId: UUID? = nil,
    name: String? = nil,
    confidence: Float,
    now: Date
  ) -> ConversationPartnerEvidence {
    ConversationPartnerEvidence(
      source: source,
      personId: personId,
      displayName: name,
      confidence: confidence,
      timestamp: now,
      validUntil: now.addingTimeInterval(5),
      details: source.rawValue
    )
  }

  private func makeFaceCrop(
    width: Int,
    height: Int,
    sourceSize: CGSize,
    faceCaptureQuality: Float = 0.9
  ) throws -> FaceCropResult {
    try makeFaceCrop(
      rawWidth: width,
      rawHeight: height,
      cropWidth: width,
      cropHeight: height,
      sourceSize: sourceSize,
      faceCaptureQuality: faceCaptureQuality
    )
  }

  private func makeFaceCrop(
    rawWidth: Int,
    rawHeight: Int,
    cropWidth: Int,
    cropHeight: Int,
    sourceSize: CGSize,
    faceCaptureQuality: Float = 0.9
  ) throws -> FaceCropResult {
    let image = try makeTestImage(width: cropWidth, height: cropHeight)
    let origin = CGPoint(
      x: (sourceSize.width - CGFloat(rawWidth)) / 2,
      y: (sourceSize.height - CGFloat(rawHeight)) / 2
    )
    return FaceCropResult(
      frameSequence: 1,
      frameTimestamp: Date(),
      faceBoundingBoxNormalized: CGRect(x: 0.4, y: 0.4, width: CGFloat(rawWidth) / sourceSize.width, height: CGFloat(rawHeight) / sourceSize.height),
      rawFaceBoundingBoxPixels: CGRect(origin: origin, size: CGSize(width: rawWidth, height: rawHeight)),
      faceBoundingBoxPixels: CGRect(origin: origin, size: CGSize(width: cropWidth, height: cropHeight)),
      croppedImage: image,
      previewImage: UIImage(cgImage: image),
      sourceImageSize: sourceSize,
      visionOrientation: .up,
      alignmentMode: "boundingBoxOnly",
      yaw: nil,
      roll: nil,
      pitch: nil,
      faceCaptureQuality: faceCaptureQuality,
      alignedCroppedImage: image,
      isBottomClipped: false
    )
  }

  func testSceneContextClientParsesFiveWOneHJSON() throws {
    let content = """
```json
{"who":"Sean","where":"library study area","what":"studying with a laptop","when":"Tuesday morning","why":"preparing for work","how":"sitting at a desk","interactionStyle":"quiet study session","summary":"Sean appears to be studying at a library desk.","confidence":0.82,"evidence":["bookshelves visible","transcript mentions studying"]}
```
"""
    let analysis = try SceneContextClient.parseAnalysis(from: content)

    XCTAssertEqual(analysis.who, "Sean")
    XCTAssertEqual(analysis.whereText, "library study area")
    XCTAssertEqual(analysis.what, "studying with a laptop")
    XCTAssertEqual(analysis.how, "sitting at a desk")
    XCTAssertEqual(analysis.interactionStyle, "quiet study session")
    XCTAssertEqual(analysis.confidence, 0.82, accuracy: 0.001)
    XCTAssertEqual(analysis.evidence.count, 2)
  }

  func testSceneContextClientDefaultsMissingInteractionStyleForOldResponses() throws {
    let content = """
{"who":"Sean and Dad","where":"home bedroom","what":"workspace setup advice","when":"2026-05-19 evening","why":"preparing for smart-glasses testing","how":"casual conversation","summary":"Sean asks Dad for help arranging a bedroom workspace.","confidence":0.95,"evidence":["app identity says Dad","transcript mentions workspace"]}
"""
    let analysis = try SceneContextClient.parseAnalysis(from: content)

    XCTAssertEqual(analysis.who, "Sean and Dad")
    XCTAssertEqual(analysis.interactionStyle, "unknown")
    XCTAssertEqual(analysis.confidence, 0.95, accuracy: 0.001)
  }

  func testDisplayCapabilityAlreadyActiveErrorIsNonRetriable() {
    let error = NSError(
      domain: "MWDATCore",
      code: 1,
      userInfo: [
        NSLocalizedDescriptionKey: "A capability of this type is already active on the session"
      ]
    )

    XCTAssertTrue(DATGlassesManager.isDisplayCapabilityAlreadyActiveError(error))
  }

  func testDisplayCallbackGateRejectsStaleOrTearingDownCallbacks() {
    XCTAssertTrue(DATGlassesManager.shouldAcceptDisplayCallback(
      callbackGeneration: 7,
      currentGeneration: 7,
      isDisplaySDKInteractionAllowed: true,
      isAssistanceDisplayConnected: true,
      isTeardownInProgress: false
    ))

    XCTAssertFalse(DATGlassesManager.shouldAcceptDisplayCallback(
      callbackGeneration: 6,
      currentGeneration: 7,
      isDisplaySDKInteractionAllowed: true,
      isAssistanceDisplayConnected: true,
      isTeardownInProgress: false
    ))

    XCTAssertFalse(DATGlassesManager.shouldAcceptDisplayCallback(
      callbackGeneration: 7,
      currentGeneration: 7,
      isDisplaySDKInteractionAllowed: true,
      isAssistanceDisplayConnected: true,
      isTeardownInProgress: true
    ))

    XCTAssertFalse(DATGlassesManager.shouldAcceptDisplayCallback(
      callbackGeneration: 7,
      currentGeneration: 7,
      isDisplaySDKInteractionAllowed: false,
      isAssistanceDisplayConnected: true,
      isTeardownInProgress: false
    ))
  }

  func testLightListCardTextTokensMeetReadableContrast() {
    let card = Color.mementoListCard
    XCTAssertGreaterThanOrEqual(Self.contrastRatio(MementoTheme.listCardPrimaryText, card), 12.0)
    XCTAssertGreaterThanOrEqual(Self.contrastRatio(MementoTheme.listCardSecondaryText, card), 6.0)
    XCTAssertGreaterThanOrEqual(Self.contrastRatio(MementoTheme.listCardTertiaryText, card), 4.5)
  }

  func testDATStreamingStateAcceptsDelayedFirstFrame() {
    XCTAssertTrue(StreamSessionViewModel.shouldAcceptLiveDATFrameForAnalysis(
      streamStateText: "streaming",
      datIsStreamRunning: true,
      terminalVisionInvalidated: false
    ))
  }

  private static func contrastRatio(_ foreground: Color, _ background: Color) -> Double {
    let fg = relativeLuminance(foreground)
    let bg = relativeLuminance(background)
    let lighter = max(fg, bg)
    let darker = min(fg, bg)
    return (lighter + 0.05) / (darker + 0.05)
  }

  private static func relativeLuminance(_ color: Color) -> Double {
    let uiColor = UIColor(color)
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    let converted = uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    XCTAssertTrue(converted)
    let linearRed = linearizedChannel(Double(red))
    let linearGreen = linearizedChannel(Double(green))
    let linearBlue = linearizedChannel(Double(blue))
    return 0.2126 * linearRed + 0.7152 * linearGreen + 0.0722 * linearBlue
  }

  private static func linearizedChannel(_ value: Double) -> Double {
    if value <= 0.03928 {
      return value / 12.92
    }
    return pow((value + 0.055) / 1.055, 2.4)
  }

  func testSceneContextRequiresAcceptedLiveDATFrame() {
    XCTAssertFalse(StreamSessionViewModel.shouldSubmitSceneContextForLiveDATFrame(
      previewImageAvailable: true,
      isDATAnalysisPaused: false,
      frameAccepted: false
    ))
    XCTAssertFalse(StreamSessionViewModel.shouldSubmitSceneContextForLiveDATFrame(
      previewImageAvailable: true,
      isDATAnalysisPaused: true,
      frameAccepted: true
    ))
    XCTAssertTrue(StreamSessionViewModel.shouldSubmitSceneContextForLiveDATFrame(
      previewImageAvailable: true,
      isDATAnalysisPaused: false,
      frameAccepted: true
    ))
  }

  func testDATTerminalStatesRejectLiveFrameAnalysis() {
    XCTAssertFalse(StreamSessionViewModel.shouldAcceptLiveDATFrameForAnalysis(
      streamStateText: "stopping",
      datIsStreamRunning: false,
      terminalVisionInvalidated: true
    ))
    XCTAssertFalse(StreamSessionViewModel.shouldAcceptLiveDATFrameForAnalysis(
      streamStateText: "stopped",
      datIsStreamRunning: false,
      terminalVisionInvalidated: true
    ))
    XCTAssertTrue(StreamSessionViewModel.shouldAcceptLiveDATFrameForAnalysis(
      streamStateText: "streaming",
      datIsStreamRunning: true,
      terminalVisionInvalidated: false
    ))
  }

  func testLaunchStoppedDATStateDoesNotInvalidateVisionBeforeAnyLiveWork() {
    XCTAssertFalse(StreamSessionViewModel.shouldInvalidateLiveDATVisionWorkOnTerminalState(
      liveStreamSessionActivated: false,
      livePhoneAudioSessionActive: false,
      liveDATStreamingStarted: false,
      hasReceivedFrame: false,
      datFramesReceived: 0,
      datFramesWithPixelBuffer: 0,
      pendingVisionImageAvailable: false,
      liveAudioCaptureReadyForVision: false
    ))
  }

  func testTerminalDATStateInvalidatesVisionAfterLiveWorkStarted() {
    XCTAssertTrue(StreamSessionViewModel.shouldInvalidateLiveDATVisionWorkOnTerminalState(
      liveStreamSessionActivated: true,
      livePhoneAudioSessionActive: false,
      liveDATStreamingStarted: false,
      hasReceivedFrame: false,
      datFramesReceived: 0,
      datFramesWithPixelBuffer: 0,
      pendingVisionImageAvailable: false,
      liveAudioCaptureReadyForVision: false
    ))
    XCTAssertTrue(StreamSessionViewModel.shouldInvalidateLiveDATVisionWorkOnTerminalState(
      liveStreamSessionActivated: false,
      livePhoneAudioSessionActive: false,
      liveDATStreamingStarted: false,
      hasReceivedFrame: true,
      datFramesReceived: 1,
      datFramesWithPixelBuffer: 1,
      pendingVisionImageAvailable: false,
      liveAudioCaptureReadyForVision: false
    ))
  }

  func testSupabaseServiceRoleKeyIsIgnoredUnlessDebugOverrideIsExplicit() {
    XCTAssertNil(SupabaseSettings.serviceRoleKeyForApp(
      rawServiceKey: "service-role-key",
      allowFlag: nil
    ))
    XCTAssertNil(SupabaseSettings.serviceRoleKeyForApp(
      rawServiceKey: "service-role-key",
      allowFlag: "false"
    ))
    XCTAssertEqual(SupabaseSettings.serviceRoleKeyForApp(
      rawServiceKey: " service-role-key ",
      allowFlag: "true"
    ), "service-role-key")
  }

  func testDATStreamCallbackGateRejectsStaleAndTerminalCallbacks() {
    XCTAssertFalse(DATGlassesManager.shouldAcceptStreamCallback(
      callbackGeneration: 1,
      currentGeneration: 2,
      hasStream: true,
      stateText: "streaming"
    ))
    XCTAssertFalse(DATGlassesManager.shouldAcceptStreamCallback(
      callbackGeneration: 2,
      currentGeneration: 2,
      hasStream: false,
      stateText: "streaming"
    ))
    XCTAssertFalse(DATGlassesManager.shouldAcceptStreamCallback(
      callbackGeneration: 2,
      currentGeneration: 2,
      hasStream: true,
      stateText: "stopping"
    ))
    XCTAssertTrue(DATGlassesManager.shouldAcceptStreamCallback(
      callbackGeneration: 2,
      currentGeneration: 2,
      hasStream: true,
      stateText: "STARTING"
    ))
  }

  private func makePersonEntry(
    id: UUID,
    name: String,
    conversations: [PersonConversationTranscript]
  ) -> PersonDictionaryEntry {
    let now = Date()
    return PersonDictionaryEntry(
      profile: PersonProfile(
        id: id,
        displayName: name,
        createdAt: now,
        updatedAt: now,
        notes: nil,
        isUnknownPlaceholder: false,
        lastSeenAt: conversations.map(\.startedAt).max(),
        enrollmentStatus: .enrolled,
        consentStatus: .unknown
      ),
      thumbnail: nil,
      transcripts: conversations.flatMap { $0.lines.map(\.chunk) },
      interactionDays: [],
      embeddingImages: [],
      conversationTranscripts: conversations,
      sceneContexts: [],
      glassesDisplayInteractions: []
    )
  }

  private func makeConversation(
    personId: UUID,
    name: String,
    startedAt: Date,
    text: String
  ) -> PersonConversationTranscript {
    let sessionId = UUID()
    let chunk = TranscriptChunk(
      id: UUID(),
      appRunId: UUID(),
      conversationSessionId: sessionId,
      personId: personId,
      activeIdentityState: "confirmed",
      text: text,
      isFinal: true,
      startedAt: startedAt,
      endedAt: startedAt.addingTimeInterval(4),
      transcriptUpdatedAt: startedAt.addingTimeInterval(4),
      source: "diarizen:\(name)",
      createdAt: startedAt
    )
    return PersonConversationTranscript(
      conversationSessionId: sessionId,
      startedAt: startedAt,
      endedAt: startedAt.addingTimeInterval(4),
      lines: [ConversationTranscriptLine(chunk: chunk, speakerName: name)]
    )
  }

  private func makeStreamSummaryRequest(transcriptText: String) -> StreamSummaryRequest {
    let startedAt = Date(timeIntervalSince1970: 1_800)
    let appRunId = UUID()
    let sessionId = UUID()
    let personId = UUID()
    let chunk = TranscriptChunk(
      id: UUID(),
      appRunId: appRunId,
      conversationSessionId: sessionId,
      personId: personId,
      activeIdentityState: "confirmed",
      text: transcriptText,
      isFinal: true,
      startedAt: startedAt,
      endedAt: startedAt.addingTimeInterval(5),
      transcriptUpdatedAt: startedAt.addingTimeInterval(5),
      source: "alibaba-live",
      createdAt: startedAt
    )
    let evidence = SceneContextIdentityEvidence(
      wearerName: "you",
      conversationPartnerName: "Gary",
      conversationPartnerPersonId: personId,
      conversationPartnerState: "confirmed",
      confidence: 0.92,
      sourceSummary: "face:Gary"
    )
    return StreamSummaryRequest(
      transcripts: [chunk],
      sceneContexts: [],
      startedAt: startedAt,
      endedAt: startedAt.addingTimeInterval(30),
      identityEvidence: evidence
    )
  }

  private func makeChunkedStreamSummaryRequest(chunkCount: Int) -> StreamSummaryRequest {
    let startedAt = Date(timeIntervalSince1970: 1_800)
    let appRunId = UUID()
    let sessionId = UUID()
    let personId = UUID()
    let chunks = (0..<chunkCount).map { index in
      let timestamp = startedAt.addingTimeInterval(Double(index * 15))
      return TranscriptChunk(
        id: UUID(),
        appRunId: appRunId,
        conversationSessionId: sessionId,
        personId: personId,
        activeIdentityState: "confirmed",
        text: "Gary discussed long stream summary behavior, chunk \(index), including timestamps, key moments, people present, and whether the final Alibaba response stayed structured.",
        isFinal: true,
        startedAt: timestamp,
        endedAt: timestamp.addingTimeInterval(5),
        transcriptUpdatedAt: timestamp.addingTimeInterval(5),
        source: "alibaba-live",
        createdAt: timestamp
      )
    }
    let evidence = SceneContextIdentityEvidence(
      wearerName: "you",
      conversationPartnerName: "Gary",
      conversationPartnerPersonId: personId,
      conversationPartnerState: "confirmed",
      confidence: 0.92,
      sourceSummary: "face:Gary"
    )
    return StreamSummaryRequest(
      transcripts: chunks,
      sceneContexts: [],
      startedAt: startedAt,
      endedAt: startedAt.addingTimeInterval(Double(chunkCount * 15)),
      identityEvidence: evidence
    )
  }

  private func makeStreamSummaryMockURLSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StreamSummaryMockURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  private func makeStreamSummaryChatCompletionData(content: String) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "choices": [
        [
          "message": [
            "content": content
          ]
        ]
      ]
    ])
  }

  private func streamSummaryUserPrompt(fromPayloadJSON json: String) throws -> String {
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
    let userMessage = try XCTUnwrap(messages.last)
    let content = try XCTUnwrap(userMessage["content"] as? [[String: Any]])
    let firstText = try XCTUnwrap(content.compactMap { $0["text"] as? String }.first)
    return firstText
  }

  private func streamSummaryUserPrompt(fromPayloadData data: Data) throws -> String {
    let json = try XCTUnwrap(String(data: data, encoding: .utf8))
    return try streamSummaryUserPrompt(fromPayloadJSON: json)
  }

  private func httpBodyData(from request: URLRequest) throws -> Data {
    if let body = request.httpBody {
      return body
    }
    guard let stream = request.httpBodyStream else {
      XCTFail("Expected request body")
      return Data()
    }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufferSize = 4096
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
      let count = stream.read(buffer, maxLength: bufferSize)
      if count < 0 {
        throw stream.streamError ?? URLError(.cannotDecodeContentData)
      }
      if count == 0 {
        break
      }
      data.append(buffer, count: count)
    }
    return data
  }

  private func faceEmbeddingRecord(
    frame: UInt64,
    modelName: String,
    modelVersion: String,
    modelSource: String,
    preprocessingVersion: String
  ) -> FaceEmbeddingRecord {
    FaceEmbeddingRecord(
      id: UUID(),
      personId: nil,
      vector: [1, 0, 0],
      dimension: 3,
      qualityScore: 0.9,
      sourceFrameTimestamp: Date(),
      createdAt: Date(),
      sampleImageLocalPath: nil,
      metadata: nil,
      modelName: modelName,
      modelVersion: modelVersion,
      modelSource: modelSource,
      preprocessingVersion: preprocessingVersion,
      frameNumber: frame
    )
  }

  private func waitUntil(
    timeout: TimeInterval = 2,
    condition: @escaping () async -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if await condition() { return }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTFail("Timed out waiting for async condition")
  }
}

private actor RecordingIdentitySyncRemote: IdentitySyncRemote {
  private var labels: [String] = []
  private var transcriptHook: (() async -> Void)?
  private var personAveragedEmbeddingError: Error?
  private var personAveragedEmbeddingAttemptCount = 0

  func setTranscriptHook(_ hook: @escaping () async -> Void) {
    transcriptHook = hook
  }

  func setPersonAveragedEmbeddingError(_ error: Error?) {
    personAveragedEmbeddingError = error
  }

  func personAveragedEmbeddingAttempts() -> Int {
    personAveragedEmbeddingAttemptCount
  }

  func appliedLabels() -> [String] {
    labels
  }

  func upsertAppRun(_ run: AppRun) async throws {
    labels.append("appRun:\(run.id.uuidString)")
  }

  func upsertPersonProfile(_ profile: PersonProfile) async throws {
    labels.append("personProfile:\(profile.id.uuidString)")
  }

  func deletePersonProfile(id: UUID) async throws {
    labels.append("personDeleted:\(id.uuidString)")
  }

  func deleteFaceEmbeddingsForPerson(personId: UUID) async throws {
    labels.append("faceEnrollmentDeleted:\(personId.uuidString)")
  }

  func upsertConversationSession(_ session: ConversationSession) async throws {
    labels.append("conversationSession:\(session.id.uuidString)")
  }

  func upsertFaceEmbedding(
    _ record: FaceEmbeddingRecord,
    image: SupabaseIdentityStore.FaceCropImageSource?
  ) async throws {
    labels.append("faceEmbedding:\(record.id.uuidString)")
  }

  func upsertPersonAveragedEmbedding(_ avg: PersonAveragedEmbedding) async throws {
    personAveragedEmbeddingAttemptCount += 1
    if let personAveragedEmbeddingError {
      throw personAveragedEmbeddingError
    }
    labels.append("personAveragedEmbedding:\(avg.id.uuidString)")
  }

  func upsertTranscriptChunk(_ chunk: TranscriptChunk) async throws {
    labels.append("transcriptChunk:\(chunk.id.uuidString)")
    if let hook = transcriptHook {
      transcriptHook = nil
      await hook()
    }
  }

  func insertFaceDetectionEvent(_ event: FaceDetectionEvent) async throws {
    labels.append("faceDetectionEvent:\(event.id.uuidString)")
  }

  func insertIdentityMatchEvent(_ event: IdentityMatchEvent) async throws {
    labels.append("identityMatchEvent:\(event.id.uuidString)")
  }

  func upsertSceneContext(_ record: SceneContextRecord) async throws {
    labels.append("sceneContext:\(record.id.uuidString)")
  }

  func upsertPresenceEpisode(_ record: PresenceEpisodeRecord) async throws {
    labels.append("presenceEpisode:\(record.id.uuidString)")
  }

  func upsertActivityModeEpisode(_ record: ActivityModeEpisodeRecord) async throws {
    labels.append("activityModeEpisode:\(record.id.uuidString)")
  }

  func insertGlassesDisplayInteraction(_ event: GlassesDisplayInteractionEvent) async throws {
    labels.append("glassesDisplayInteraction:\(event.id.uuidString)")
  }
}

private actor FixedSpeakerEmbeddingModel: SpeakerEmbeddingModel {
  nonisolated let embeddingDimension: Int
  nonisolated let modelName = "SpeakerEmbedding"
  nonisolated let modelVersion = "nvidia-speakerverification-en-titanet-large-v1"
  nonisolated let preprocessingVersion = "titanet-raw-16khz-v1"
  nonisolated let embeddingRuntime: String

  private let vector: [Float]

  init(runtime: String, vector: [Float]) {
    self.embeddingRuntime = runtime
    self.vector = vector
    self.embeddingDimension = vector.count
  }

  func load() async throws {}

  func embed(samples: [Float], sampleRate: Double) async throws -> VoiceEmbedding {
    VoiceEmbedding(
      vector: vector,
      modelName: modelName,
      modelVersion: modelVersion,
      preprocessingVersion: preprocessingVersion,
      embeddingRuntime: embeddingRuntime
    )
  }
}

private final class StreamSummaryMockURLProtocol: URLProtocol {
  typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

  private static let lock = NSLock()
  private static var handlers: [Handler] = []
  private static var requests: [URLRequest] = []

  static func reset() {
    lock.lock()
    handlers = []
    requests = []
    lock.unlock()
  }

  static func enqueue(_ handler: @escaping Handler) {
    lock.lock()
    handlers.append(handler)
    lock.unlock()
  }

  static func requestCount() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return requests.count
  }

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    let handler: Handler?
    Self.lock.lock()
    Self.requests.append(request)
    handler = Self.handlers.isEmpty ? nil : Self.handlers.removeFirst()
    Self.lock.unlock()

    do {
      guard let handler else {
        throw URLError(.badServerResponse)
      }
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}
