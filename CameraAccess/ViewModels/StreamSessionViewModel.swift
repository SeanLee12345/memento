/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AVFoundation
import Combine
import CoreImage
import CoreMedia
import CoreVideo
import SwiftUI
import UIKit

enum StreamingStatus {
  case streaming
  case waiting
  case paused
  case stopped
}

private struct SendablePixelBuffer: @unchecked Sendable {
  let pixelBuffer: CVPixelBuffer
}

private enum GlassesIdentityConfirmation: Equatable {
  case recognized(personId: UUID, displayName: String)
  case unknown
  case selectingPerson
}

private enum GlassesDisplayWindow: Equatable {
  case live
  case people
  case context
  case transcripts
}

private enum StreamSummaryHistoryStore {
  private static let key = "streamSummaryHistory.v1"
  private static let maxEntries = 50

  static func load(defaults: UserDefaults = .standard) -> [StreamSummaryHistoryEntry] {
    guard let data = defaults.data(forKey: key),
          let entries = try? JSONDecoder().decode([StreamSummaryHistoryEntry].self, from: data) else {
      return []
    }
    return entries.sorted { $0.endedAt > $1.endedAt }
  }

  static func save(_ entries: [StreamSummaryHistoryEntry], defaults: UserDefaults = .standard) {
    let trimmed = Array(entries.sorted { $0.endedAt > $1.endedAt }.prefix(maxEntries))
    guard let data = try? JSONEncoder().encode(trimmed) else { return }
    defaults.set(data, forKey: key)
  }
}

struct IdentityPromptThumbnailSelection {
  let image: UIImage?
  let source: String
}

enum GlassesDisplaySendTiming: Equatable {
  case immediate
  case coalesced(nanoseconds: UInt64)

  static let transientStatusDelayNanoseconds: UInt64 = 250_000_000

  static func streamStatus(reason: String) -> GlassesDisplaySendTiming {
    reason == "dat-stream-preparing"
      ? .coalesced(nanoseconds: transientStatusDelayNanoseconds)
      : .immediate
  }
}

private enum CloudDiarizationTuning {
  static let minimumAudioSeconds = 5.0
  static let minSpeakerEnrollmentPreviewSeconds = 1.0
  static let maxNearbySpeakerAlignmentGapSeconds = 0.75
  static let maxSpeakerEvidenceAge: TimeInterval = 10.0
  static let maxTimelineEvidenceAge: TimeInterval = 4.0
  static let maxFaceEvidenceAge: TimeInterval = 6.0
}

private struct CloudFaceWarmupHealthResult {
  let health: String
  let attempts: Int
  let retryCadence: String
}

@MainActor
final class StreamSessionViewModel: ObservableObject {
  nonisolated static let liveDATPhonePreviewEnabled = false
  nonisolated private static let displayImageBucketID = "face-crops"
  nonisolated private static let displayImageSignedURLExpirationSeconds = 10 * 60

  nonisolated static func streamingDashboardText(
    datFramesReceived: UInt64,
    lastFrameTimestampText: String,
    datLastErrorText: String,
    hasReceivedFirstFrame: Bool
  ) -> (frameText: String, statusText: String, currentLineOverride: String?) {
    if datFramesReceived > 0 {
      return (
        frameText: "\(datFramesReceived) received, last \(lastFrameTimestampText)",
        statusText: "Display active",
        currentLineOverride: nil
      )
    }

    if datLastErrorText.localizedCaseInsensitiveContains("no video frames") {
      return (
        frameText: "0 received; camera frames missing",
        statusText: "Camera stream has no frames",
        currentLineOverride: "Camera: no video frames"
      )
    }

    return (
      frameText: "waiting for first frame",
      statusText: hasReceivedFirstFrame ? "Display active" : "Starting stream",
      currentLineOverride: nil
    )
  }

  nonisolated static func streamRunningModeText(
    hasActiveRecognizedPeople: Bool,
    detectedFaceCount: Int,
    activeConversationPartnerStateText: String,
    activeSpeakerStateText: String,
    liveTranscriptPreviewText: String,
    hasReceivedFirstFrame: Bool,
    activityMode: ActivityModeClassification? = nil
  ) -> String {
    guard hasReceivedFirstFrame else { return "Starting stream" }
    if let activityMode {
      return activityMode.displayText
    }

    let partnerState = activeConversationPartnerStateText.lowercased()
    let speakerState = activeSpeakerStateText.lowercased()
    let recognizedPeople = hasActiveRecognizedPeople
      || ["confirmed", "possible", "multiplepeople"].contains(partnerState)
      || ["confirmed", "possible", "speaking"].contains(speakerState)
      ? ["recognized person"]
      : []
    let request = ActivityModeClassificationRequest(
      transcriptText: liveTranscriptPreviewText,
      sceneContexts: [],
      recognizedPeople: recognizedPeople,
      detectedFaceCount: detectedFaceCount,
      identityEvidence: nil,
      locationLabel: nil,
      streamState: "streaming",
      reason: "stream-running-fallback"
    )
    return ActivityModeClassifier.fallbackClassification(for: request).displayText
  }

  nonisolated static func streamRunningRecognizedPeopleText(_ names: [String]) -> String {
    let uniqueNames = uniqueDisplayStrings(names)
    return uniqueNames.isEmpty ? "None" : uniqueNames.joined(separator: ", ")
  }

  nonisolated private static func hasMeaningfulLiveTranscript(_ value: String) -> Bool {
    let normalized = normalizedLiveTranscript(value)
    guard !normalized.isEmpty else { return false }
    let statusLabels: Set<String> = [
      "no live transcript yet",
      "listening...",
      "analysis paused"
    ]
    guard !statusLabels.contains(normalized) else { return false }
    let punctuationStripped = normalizedLiveTranscript(
      normalized.components(separatedBy: .punctuationCharacters).joined(separator: " ")
    )
    let fillerFragments: Set<String> = [
      "ah",
      "eh",
      "er",
      "erm",
      "hm",
      "hmm",
      "mm",
      "mhm",
      "oh",
      "ok",
      "okay",
      "uh",
      "um",
      "yeah",
      "yep",
      "yes",
      "no",
      "嗯",
      "啊",
      "哦",
      "呃"
    ]
    guard !fillerFragments.contains(punctuationStripped) else { return false }
    let words = punctuationStripped.split(whereSeparator: \.isWhitespace)
    if words.count <= 1, !normalized.contains("?") {
      return false
    }
    return true
  }

  nonisolated static func hasMeaningfulLiveTranscriptForTesting(_ value: String) -> Bool {
    hasMeaningfulLiveTranscript(value)
  }

  nonisolated private static func normalizedLiveTranscript(_ value: String) -> String {
    value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  // MARK: - Published State

  @Published var currentVideoFrame: UIImage?
  @Published var lastStreamPhotoSnapshot: UIImage?
  @Published var streamPhotoStatusText: String = "No stream photo yet"
  @Published var currentImageSize: CGSize = .zero
  @Published var detectedFaces: [DetectedFace] = []
  @Published var hasReceivedFirstFrame: Bool = false
  @Published var streamingStatus: StreamingStatus = .stopped
  @Published var lifecycleState: StreamLifecycleState = .stopped
  @Published var streamStateText: String = StreamLifecycleState.stopped.rawValue
  @Published var sourceStateText: String = "LOCAL"
  @Published var showError: Bool = false
  @Published var errorMessage: String = ""
  @Published var inputMode: InputMode = .realGlasses

  // Per-frame diagnostics — mutated 5-12×/sec on the main actor. No SwiftUI view
  // observes them, so they are plain vars (not @Published): publishing them fired
  // objectWillChange at frame rate and re-diffed the whole view tree on Thread 1
  // for data nothing renders. Read directly for logging/control flow.
  var framesReceived: UInt64 = 0
  var previewFrames: UInt64 = 0
  var visionSubmittedFrames: UInt64 = 0
  var visionProcessedFrames: UInt64 = 0
  var droppedFrames: UInt64 = 0
  var lastFrameIntervalText: String = "0.0 ms"
  var liveFrameStatsText: String = "received=0 preview=0 vision=0/0 dropped=0 fps=0.0 avgVision=0.0 ms"
  @Published var people: [Person] = []
  @Published var analysisPaused = false {
    didSet {
      guard oldValue != analysisPaused else { return }
      handleAnalysisPausedChanged()
    }
  }
  @Published var identityRecognitionEnabled = true
  @Published var conversationSavingEnabled = true
  @Published var livePhoneAudioCaptureEnabled = true {
    didSet {
      AppLogger.log(.audio, "User changed livePhoneAudioCaptureEnabled=\(livePhoneAudioCaptureEnabled). Takes effect on next stream.")
    }
  }
  @Published var audioSource: AudioSource = AudioSourcePreference.current {
    didSet {
      guard oldValue != audioSource else { return }
      AudioSourcePreference.current = audioSource
      AppLogger.log(.audio, "User changed audioSource \(oldValue.rawValue) → \(audioSource.rawValue). Takes effect on next stream.")
    }
  }
  @Published var activeIdentityName = "None"
  @Published var activeIdentityConfidenceText = "0.00"
  @Published var activeIdentityStateText = "none"
  @Published var activeConversationPartnerName = "None"
  @Published var activeConversationPartnerStateText = "none"
  @Published var activeConversationPartnerConfidenceText = "0.00"
  @Published var activeConversationPartnerEvidenceText = "No partner evidence yet"
  @Published var detectedFaceCount: Int = 0
  @Published var isUnknownPersonVisible = false
  @Published var pendingEnrollmentFacePreview: UIImage?
  @Published var pendingEnrollmentName = ""
  @Published var lastEnrollmentCandidatePreview: UIImage?
  @Published var hasLastEnrollmentCandidate = false
  @Published var lastEnrollmentCandidateSummary = "No saved face candidate"
  @Published var lastEnrollmentCandidateName = ""
  @Published var identitySummaryText = "Identity idle"
  @Published var recentConversationAttributionText = "No transcript attribution yet"
  @Published var presencePipelineVerificationText = "Presence: waiting for name or identity evidence"
  @Published var sceneContextPipelineVerificationText = "5W/1H: waiting for scene context"
  @Published var activityModeVerificationText = "Activity mode: waiting for stream context"
  @Published var memoryTriggerVerificationText = "Memory trigger: waiting for a past-reference question"
  @Published var phoneAssistanceTitleText = "Memento"
  @Published var phoneAssistanceDetailText = "Live memory will appear when the stream recognizes someone."
  @Published var phoneAssistanceStatusText = "Ready"
  @Published var phoneAssistanceThumbnail: UIImage?
  @Published var phoneAssistanceDismissed = false
  @Published var latestStreamSummaryTimeText = "No stream yet"
  @Published var latestStreamSummaryText = "Stop a stream to generate the latest summary."
  @Published var latestStreamSummaryStatusText = "Stream summary idle"
  @Published var showStreamSummaryHistory = false
  @Published var streamSummaryHistory: [StreamSummaryHistoryEntry] = StreamSummaryHistoryStore.load()
  @Published var currentAppRunIDText = "none"
  @Published var currentConversationSessionIDText = "none"
  @Published var sessionDetectedFacesText = "0"
  @Published var sessionAcceptedFaceCropsText = "0"
  @Published var sessionEmbeddingsSavedText = "0"
  @Published var sessionTranscriptChunksSavedText = "0"
  @Published var pendingEnrollmentSampleText = "0/\(IdentityConfig.minimumEnrollmentSamples)"
  @Published var pendingEnrollmentRejectedText = "0 rejected"
  @Published var enrollmentStatusText = "Enrollment idle"
  @Published var capturedFaceGroups: [CapturedFaceGroupSnapshot] = []
  @Published var streamEndedReviewText = "groups 0, samples 0"
  @Published var showPeopleDictionary = false
  @Published var peopleDictionaryEntries: [PersonDictionaryEntry] = []
  @Published var calibrationModeText = "off"
  @Published var calibrationSampleCountText = "same 0 / different 0"
  @Published var calibrationSummaryText = "same 0, different 0 | strong 0.70, weak 0.60, margin 0.05"
  @Published var canRecordCalibrationLabel = false
  @Published var videoFaceEmbeddingMetricsText = "Video face: waiting for accepted face"
  @Published var videoFaceRecognitionMetricsText = "Recognition source: waiting"
  @Published var faceEmbeddingModelStatusText = "Checking face model"
  @Published var faceEmbeddingModelDiagnosticsText = "Model diagnostics unavailable"
  @Published var faceAlignmentWarning: String = ""

  // Voice enrollment
  @Published var isPlayingVoicePreview = false
  @Published var voiceEnrollmentName = ""
  @Published var voiceEnrollmentStatusText = "Voice enrollment idle"
  @Published var wearerVoiceProfile = WearerVoiceProfileSnapshot.empty
  @Published var wearerVoiceStatusText = "My voice not enrolled"
  @Published var activeSpeakerStateText = "none"
  @Published var activeSpeakerName = ""
  @Published var activeSpeakerPersonId: UUID? = nil
  @Published var activeSpeakerSimilarity: Float = 0
  // Persists the last similarity score produced by an embedding run (not reset to 0 on silence).
  @Published var lastVoiceSimilarity: Float = 0
  @Published var lastIPhoneVoiceSimilarity: Float = 0
  @Published var lastWorkerVoiceSimilarity: Float = 0
  @Published var lastWearerVoiceSimilarity: Float = 0
  @Published var iPhoneVoiceSimilarityStatusText = "iPhone local estimate: pending"
  @Published var workerVoiceSimilarityStatusText = "AWS canonical: disabled"
  @Published var wearerVoiceSimilarityStatusText = "Wearer: not checked"
  @Published var audioSpeakerEmbeddingMetricsText = "Audio speaker: waiting for speech"
  @Published var voiceMatchStatusText = ""
  @Published var voiceSpeechBufferSeconds: Double = 0
  @Published var enrolledVoicePersonIds: Set<UUID> = []
  // People whose diarized voice enrollment is saved as a preview but still
  // awaiting a usable AWS voice embedding. They are NOT in enrolledVoicePersonIds
  // until the pending embedding lands (retried when the worker is reachable).
  @Published var pendingVoiceEnrollmentPersonIds: Set<UUID> = []
  @Published var cloudDiarizationState: CloudDiarizationState = .idle
  @Published var unknownDiarizationSpeakers: [UnknownDiarizationSpeaker] = []
  @Published var capturedVoiceClips: [CapturedVoiceClipSnapshot] = []
  @Published var capturedVoiceClipName = ""
  @Published var localWorkerEnabled = true
  @Published var localWorkerEndpointText = LocalWorkerSettings.defaultEndpoint
  @Published var localWorkerAPIKeyText = ""
  @Published var localWorkerStatusText = "Local worker not tested"
  @Published var deepSeekAPIKeyText = ""
  @Published var deepSeekModelText = DeepSeekSettings.defaultModel
  @Published var deepSeekStatusText = "DeepSeek not configured"
  @Published var liveTranscriptionEnabled = AlibabaTranscriptionSettings.load().enabled {
    didSet {
      guard oldValue != liveTranscriptionEnabled else { return }
      AlibabaTranscriptionSettings.saveEnabled(liveTranscriptionEnabled)
      liveTranscriptionStatusText = liveTranscriptionEnabled
        ? "Live ASR enabled for next stream"
        : "Live ASR disabled"
    }
  }
  @Published var liveTranscriptionStatusText = "Live ASR not configured"
  @Published var liveTranscriptPreviewText = "No live transcript yet"
  @Published var sceneContextEnabled = SceneContextSettings.load().enabled {
    didSet {
      guard !isLoadingSceneContextSettings, oldValue != sceneContextEnabled else { return }
      saveSceneContextSettings()
    }
  }
  @Published var sceneLocationContextEnabled = SceneContextSettings.load().locationEnabled {
    didSet {
      guard !isLoadingSceneContextSettings, oldValue != sceneLocationContextEnabled else { return }
      saveSceneContextSettings()
    }
  }
  @Published var sceneContextStatusText = "Scene context off"
  @Published var cloudFaceEmbeddingEnabled = false {
    didSet {
      guard !isLoadingCloudEmbeddingSettings, oldValue != cloudFaceEmbeddingEnabled else { return }
      saveCloudFaceEmbeddingSettings()
    }
  }
  @Published var cloudFaceEmbeddingEndpointText = CloudFaceEmbeddingSettings.defaultEndpoint
  @Published var cloudFaceEmbeddingAPIKeyText = ""
  @Published var cloudFaceEmbeddingStatusText = "Cloud face embedding off"
  @Published var cloudSpeakerEmbeddingEnabled = false {
    didSet {
      guard !isLoadingCloudEmbeddingSettings, oldValue != cloudSpeakerEmbeddingEnabled else { return }
      saveCloudSpeakerEmbeddingSettings()
    }
  }
  @Published var cloudSpeakerEmbeddingEndpointText = CloudSpeakerEmbeddingSettings.defaultEndpoint
  @Published var cloudSpeakerEmbeddingAPIKeyText = ""
  @Published var cloudSpeakerEmbeddingStatusText = "AWS canonical speaker embeddings off"
  @Published var microphoneStatusText: String = "Stopped"
  @Published var visionLatencyText: String = "0.0 ms"
  @Published var datSDKStatusText: String = "Not configured"
  @Published var datConfigurationModeText: String = DATConfigurationMode.developerMode.rawValue
  @Published var datRegistrationStateText: String = "Unknown"
  @Published var datDeviceCount: Int = 0
  @Published var datSelectedDeviceIDText: String = "None"
  @Published var datDeviceSessionStateText: String = "None"
  @Published var datRuntimeSessionStateText: String = "StateStream only"
  @Published var datStreamSessionStateText: String = "STOPPED"
  @Published var datCameraPermissionStatusText: String = "Not requested"
  @Published var datConnectionStageText: String = DATConnectionStage.sdkConfigured.rawValue
  @Published var datWaitingForMetaAIReturn: Bool = false
  @Published var datIsConnecting: Bool = false
  @Published var datHasActiveDevice: Bool = false
  @Published var datIsDeviceSessionReady: Bool = false
  @Published var datIsStreamRunning: Bool = false
  @Published var datIsAppActive: Bool = true
  @Published var datDevicesStreamActive: Bool = false
  @Published var datMetaAIOpenedTimestampText: String = "never"
  @Published var datLastActiveAfterReturnText: String = "never"
  @Published var datFirstDevicesStreamEventTimestampText: String = "never"
  @Published var datLastDevicesEventTimestampText: String = "never"
  @Published var datSelectedDeviceCompatibilityText: String = "unknown"
  @Published var datSelectedDeviceLinkStateText: String = "unknown"
  @Published var datStartReadinessReasonText: String = "SDK not configured"
  @Published var datFirstFrameTimestampText: String = "none"
  @Published var datLastErrorText: String = "None"
  @Published var datRuntimeBundleConfigurationText: String = "Not inspected"
  @Published var datRuntimeURLTypesText: String = "Not inspected"
  @Published var datRuntimeCameraAccessSchemeText: String = "unknown"
  @Published var datRuntimeAssociatedDomainsText: String = "unknown"
  @Published var datRuntimeDeveloperModeFlagText: String = "unknown"
  @Published var datLastOpenURLText: String = "none"
  @Published var datLastHandleURLResultText: String = "none"
  @Published var datLastRegistrationErrorDetailText: String = "None"
  @Published var datStartRegistrationCalledText: String = "no"
  @Published var datRequestCameraPermissionCalledText: String = "no"
  @Published var datRegistrationHandoffDiagnosticText: String = "No handoff attempted"
  // DAT per-frame diagnostics bridged from DATGlassesManager. Not view-observed —
  // plain vars so the per-frame bridge updates below don't storm objectWillChange.
  var datFramesReceived: UInt64 = 0
  var datFramesWithPixelBuffer: UInt64 = 0
  var datFrameConversionFailures: UInt64 = 0
  var datLastFrameWidthText: String = "none"
  var datLastFrameHeightText: String = "none"
  var datLastFrameTimestampText: String = "none"
  var datLastFrameErrorText: String = "none"
  @Published var glassesDisplayStateText: String = "Not connected"
  @Published var glassesDisplayStatusText: String = "Display idle"
  @Published var glassesDisplayLastCardText: String = "none"
  @Published var glassesDisplayConnected: Bool = false
  @Published var glassesDisplayRequiresDATAppUpdate: Bool = false
  @Published var glassesDisplaySendCount: UInt64 = 0
  // Per-frame diagnostic, not view-observed — plain var (see framesReceived above).
  var lastFrameTimestampText: String = "none"

  var isStreaming: Bool { lifecycleState.isStreamingSurfaceVisible }
  var shouldHidePhoneVideoFootage: Bool {
    PhoneVideoFootagePolicy.hidesFootage(inputMode: inputMode, lifecycleState: lifecycleState)
  }
  var streamRunningHeaderText: String { liveStreamTransportTitle() }
  var streamRunningModeText: String {
    let activityMode = currentActivityModeClassification.confidence > 0
      ? currentActivityModeClassification
      : nil
    return Self.streamRunningModeText(
      hasActiveRecognizedPeople: !activeStreamRecognizedPeopleNames().isEmpty,
      detectedFaceCount: detectedFaceCount,
      activeConversationPartnerStateText: activeConversationPartnerStateText,
      activeSpeakerStateText: activeSpeakerStateText,
      liveTranscriptPreviewText: liveTranscriptPreviewText,
      hasReceivedFirstFrame: hasReceivedFirstFrame,
      activityMode: activityMode
    )
  }
  var streamRunningModeLineText: String {
    "Mode: \(streamRunningModeText)"
  }
  var streamRunningRecognizedPeopleText: String {
    Self.streamRunningRecognizedPeopleText(activeStreamRecognizedPeopleNames())
  }
  var streamRunningRecognizedPeopleLineText: String {
    "Recognized people: \(streamRunningRecognizedPeopleText)"
  }

  var canConnectRealGlasses: Bool {
    !datIsConnecting
      && !datWaitingForMetaAIReturn
      && datRegistrationStateText != "registering"
  }
  var connectGlassesButtonTitle: String {
    canConnectRealGlasses ? "Connect" : "Connecting..."
  }
  var canStartRealStream: Bool {
    inputMode == .realGlasses
      && datSDKStatusText == "Configured"
      && datRegistrationStateText == "registered"
      && !datWaitingForMetaAIReturn
      && datHasActiveDevice
      && !datIsStreamRunning
      && datStartReadinessReasonText == "Ready to start real stream"
  }
  var canSavePendingPersonEnrollment: Bool {
    let accepted = Int(pendingEnrollmentSampleText.split(separator: "/").first ?? "0") ?? 0
    return accepted >= IdentityConfig.minimumEnrollmentSamples
  }

  // MARK: - Private

  private let frameProcessor = VisionFaceFrameProcessor()
  private let speechManager = SpeechTranscriptionManager()
  private let identityPipeline = IdentityPipeline()
  private let speakerPipeline = SpeakerIdentityPipeline()
  private let conversationPartnerResolver = ConversationPartnerResolver()
  private let liveDATPreviewRenderQueue = DispatchQueue(label: "com.metaface.liveDAT.previewRender", qos: .userInitiated)
  private let liveDATStreamHealthIsolationMode = true
  private let aggregateFrameStatsLogIntervalSeconds: TimeInterval = 15
  private let liveVoiceEmbeddingEnabled = true
  private let voicePreviewPlayer = VoicePreviewPlayer()
  private let assistanceCardFormatter = AssistanceCardFormatter()
  private let glassesAssistanceCardFormatter = AssistanceCardFormatter(maximumLineCount: 8, maximumLineLength: 2_000)
  private var conversationSummaryCache: [UUID: PersonConversationSummary] = [:]
  private var knownPersonCandidates: [PersonNameCandidate] = []
  private var conversationSummaryInFlight: Set<UUID> = []
  private var conversationSummaryRefreshPendingPersonIds: Set<UUID> = []
  private var conversationSummaryRefreshedPersonIdsThisStream: Set<UUID> = []
  private var livePhoneAssistancePinnedPersonId: UUID?
  private var livePhoneAssistanceDismissedPersonId: UUID?
  private var assistanceGeneration: UInt64 = 0
  private let datManager = DATGlassesManager.shared
  private var videoProvider: VideoFrameProvider?
  private var cancellables = Set<AnyCancellable>()
  private struct PendingVisionImage {
    let image: UIImage
    let sequence: UInt64
    let capturedAt: Date
  }

  private enum VisionEnqueueResult {
    case accepted
    case dropped(reason: String)

    var accepted: Bool {
      if case .accepted = self { return true }
      return false
    }

    var dropReason: String? {
      if case .dropped(let reason) = self { return reason }
      return nil
    }

    var selectedForVision: Bool {
      switch self {
      case .accepted:
        return true
      case .dropped(let reason):
        return reason.localizedCaseInsensitiveContains("busy")
      }
    }

    var visionEnqueued: Bool {
      accepted
    }

    var visionSkippedReason: String {
      dropReason ?? "none"
    }
  }

  private struct TimedSpeakerEvidence: Sendable {
    let timestamp: Date
    let personId: UUID
    let displayName: String?
    let confidence: Float
    let state: String
  }

  private struct TimedFaceEvidence: Sendable {
    let timestamp: Date
    let personId: UUID
    let displayName: String?
    let confidence: Float
    let state: String
    let mouthMovementScore: Float
  }

  private struct TimedConversationPartnerState {
    let timestamp: Date
    let state: ConversationPartnerState
  }

  private struct CloudDiarizationProcessingOutput: Sendable {
    let savedChunkCount: Int
    let unknownSpeakers: [UnknownDiarizationSpeaker]
    let attributedPersonIds: Set<UUID>
  }

  private struct LocalPostSessionTranscriptSegment: Sendable {
    let id: UUID
    let text: String
    let startedAt: Date
    let endedAt: Date
    let provider: LiveASRProvider
  }

  struct DiarizationSpeakerAlignment: Equatable, Sendable {
    let speakerIndex: Int?
    let reason: String
    let overlapSeconds: Double
    let gapSeconds: Double?
  }

  private struct LiveTranscriptQuestionWork {
    let observation: LiveTranscriptQuestionObservation
    let attribution: TranscriptAttribution
  }

  private struct StreamPerformanceCounters {
    var startedAt = Date()
    var lastLoggedAt = Date()
    var asrTranscriptSegments: UInt64 = 0
    var asrFillerSkipped: UInt64 = 0
    var embeddingsRequested: UInt64 = 0
    var qwenAnswerCalls: UInt64 = 0
    var qwenActivityModeCalls: UInt64 = 0
    var activityModeSkippedNoContext: UInt64 = 0
    var faceEmbeddingFramesSubmitted: UInt64 = 0
    var faceEmbeddingSkippedDisabled: UInt64 = 0
    var faceEmbeddingSkippedNoCandidate: UInt64 = 0
    var faceEmbeddingSkippedPromptActive: UInt64 = 0
    var faceEmbeddingSkippedCooldown: UInt64 = 0
    var faceEmbeddingPipelineNoResult: UInt64 = 0
    var displaySendAttempts: UInt64 = 0
    var databaseWrites: UInt64 = 0
    var locationReads: UInt64 = 0
  }

  private var isProcessingFrame = false
  private var pendingVisionImage: PendingVisionImage?
  private let maxVisionFPS: TimeInterval = 5
  private let liveDATHeavyWorkStartupDelaySeconds: TimeInterval = 5
  private let liveDATVisionStartupDelaySeconds: TimeInterval = 0.5
  private let liveDATRecentFrameGraceSeconds: TimeInterval = 1.5
  private let liveDATVisionWarmupSeconds: TimeInterval = 8
  private let liveDATVisionWarmupFPS: TimeInterval = 1
  private let liveDATVisionSteadyFPS: TimeInterval = 0.5
  private let liveDATDegradedVisionFPS: TimeInterval = 0.25
  private let maxPendingVisionAgeSeconds: TimeInterval = 0.5
  private let identityProcessingMinimumInterval: TimeInterval = 2
  private let degradedIdentityProcessingMinimumInterval: TimeInterval = 5
  // Glasses deliver ~5 FPS; publishing the preview image at 12 FPS just multiplied
  // main-thread re-renders without adding visible smoothness. 6 keeps it above the
  // source rate while halving SwiftUI invalidation churn on Thread 1.
  private let maxPreviewFPS: TimeInterval = 6
  private let speakerUIUpdateIntervalSeconds: TimeInterval = 0.25
  private let verboseFrameLogging = ProcessInfo.processInfo.arguments.contains("--verbose-frame-logging")
  private let forceTestFaceOverlay = ProcessInfo.processInfo.arguments.contains("--ui-testing")

  private var totalReceivedFrames: UInt64 = 0
  private var totalPreviewFrames: UInt64 = 0
  private var totalDroppedFrames: UInt64 = 0
  private var lastFrameArrival: Date?
  private var lastPreviewUpdateAt: Date?
  private var lastVisionSubmissionAt: Date?
  private var liveAudioCaptureReadyForVision = false
  private var statsWindowStartedAt = Date()
  private var statsWindowReceivedFrames: UInt64 = 0
  private var statsWindowPreviewFrames: UInt64 = 0
  private var statsWindowVisionSubmittedFrames: UInt64 = 0
  private var statsWindowVisionProcessedFrames: UInt64 = 0
  private var statsWindowVisionPending: UInt64 = 0
  private var statsWindowDroppedFrames: UInt64 = 0
  private var statsWindowDroppedBusy: UInt64 = 0
  private var statsWindowDroppedStale: UInt64 = 0
  private var statsWindowSkippedThrottle: UInt64 = 0
  private var statsWindowFaceCandidates: UInt64 = 0
  private var statsWindowQualityPass: UInt64 = 0
  private var statsWindowEmbedded: UInt64 = 0
  private var statsWindowMatched: UInt64 = 0
  private var statsWindowEmbeddingDurationMS: Double = 0
  private var statsWindowVisionDurationMS: Double = 0
  private var statsWindowVisionDurationCount: UInt64 = 0
  private var debugMetricSessionStartedAt = Date()
  private var streamPerformanceCounters = StreamPerformanceCounters()
  private let streamPerformanceLogIntervalSeconds: TimeInterval = 60
  private let requestedDATFramesPerSecond: Double = 5
  private var videoAWSFaceMetrics = EmbeddingMetricAggregate()
  private var videoLocalFaceMetrics = EmbeddingMetricAggregate()
  private var audioIPhoneSpeakerMetrics = EmbeddingMetricAggregate()
  private var audioWorkerSpeakerMetrics = EmbeddingMetricAggregate()
  private var visionGeneration: UInt64 = 0
  private var liveDATStreamingStartedAt: Date?
  private var liveDATFirstFrameAt: Date?
  private var liveDATLastFrameAt: Date?
  private var liveDATTerminalVisionInvalidated = false
  private var pipelineContext: PipelineContext?
  private var faceDetectionEventsPersisted = 0
  private var lastFaceDetectionEventPersistedAt: Date?
  private var liveStreamSessionActivated = false
  private var livePhoneAudioSessionActive = false
  private var activeFacePersonId: UUID?
  private var activeFaceName: String?
  private var activeFaceConfidence: Float = 0
  private var activeFaceState = "none"
  private var retainedRecognizedPersonId: UUID?
  private var retainedRecognizedName: String?
  private var retainedRecognizedConfidence: Float = 0
  private var retainedRecognizedAt: Date?
  private var lastIdentityUIUpdateAt: Date?
  private var lastIdentityUIKey: String?
  private var latestMouthMovementScore: Float = 0
  private var speakerEvidenceTimeline: [TimedSpeakerEvidence] = []
  private var faceEvidenceTimeline: [TimedFaceEvidence] = []
  private var conversationPartnerEvidence: [ConversationPartnerEvidence] = []
  private var conversationPartnerTimeline: [TimedConversationPartnerState] = []
  private var activeConversationPartnerState = ConversationPartnerState.empty
  private let presenceTracker = PresenceEpisodeTracker()
  private var lastSavedPresenceEpisodeSignatures: [UUID: String] = [:]
  private var lastPresenceEpisodeSavedAt: [UUID: Date] = [:]
  private var lastNameAddressLLMAt: Date?
  private var lastSpeakerUIUpdateAt: Date?
  // Cloud diarization
  private let audioRecorder = StreamAudioRecorder()
  private let liveTranscriber = AlibabaLiveAudioChunkTranscriber()
  private let sceneContextPipeline = SceneContextPipeline()
  private var sceneContextFrameEncodingToken: UUID?
  private let sceneLocationProvider = SceneLocationProvider()
  private let cloudDiarizationService = CloudDiarizationService()
  private static let liveCaptionDisplayLineLimit = 8
  private static let sceneContextDisplaySectionLimit = 8
  private static let liveRecallDisplaySectionLimit = 6
  private static let activityModeSceneContextLimit = 6
  private static let activityModeMinimumClassificationInterval: TimeInterval = 10
  private let cloudSpeakerLifecycleService = CloudSpeakerEmbeddingLifecycleService()
  private let cloudFaceLifecycleService = CloudFaceEmbeddingLifecycleService()
  private var speakerTimeline: [SpeakerTimelineEntry] = []
  private var streamAudioStart: Date?
  private var postSessionLocalTranscriptSegments: [LocalPostSessionTranscriptSegment] = []
  private var lastConversationSessionIdForSpeakerReview: UUID?
  private var liveStreamActivationTask: Task<Void, Never>?
  private var latestStreamSummaryTask: Task<Void, Never>?
  private var cloudSpeakerLifecycleTask: Task<Void, Never>?
  private var cloudSpeakerHeartbeatTask: Task<Void, Never>?
  private var pendingSpeakerEmbeddingRetryTask: Task<Void, Never>?
  private var cloudFaceLifecycleTask: Task<Void, Never>?
  private var cloudFaceHeartbeatTask: Task<Void, Never>?
  private var deferredCloudWorkerStartTask: Task<Void, Never>?
  private var isLoadingCloudEmbeddingSettings = false
  private var isLoadingSceneContextSettings = false
  private var currentGlassesAssistanceCard: AssistanceDisplayCard?
  private var currentGlassesSceneContextSections: [AssistanceDisplaySection] = []
  private var currentGlassesLiveRecallSections: [AssistanceDisplaySection] = []
  private var currentActivityModeClassification = ActivityModeClassification.unknown
  private var activityModeStabilizer = ActivityModeStabilizer()
  private var currentActivityModeEpisode: ActivityModeEpisodeRecord?
  private var recentActivityModeSceneContexts: [SceneContextRecord] = []
  private var activityModeClassificationTask: Task<Void, Never>?
  private var lastActivityModeClassificationAt: Date?
  private var lastActivityModeClassificationSignature: String?
  private var cloudFaceWorkerStartedAfterFaceCandidate = false
  private var currentGlassesIdentityPromptSection: AssistanceDisplaySection?
  private var currentIdentityConfirmationThumbnail: UIImage?
  private var currentIdentityConfirmationImageURI: String?
  private var identityDisplayImageUploadTask: Task<Void, Never>?
  private var identityDisplayImageUploadToken: UUID?
  private var lastIdentityProcessingAt: Date?
  private var currentGlassesFaceVisibilitySection: AssistanceDisplaySection?
  private var activeGlassesDisplayWindow: GlassesDisplayWindow = .live
  private var currentGlassesDisplayPersonId: UUID?
  private var currentGlassesDisplayName: String?
  private var lastGlassesDisplayCardForActions: AssistanceDisplayCard?
  private var pendingIdentityConfirmation: GlassesIdentityConfirmation?
  private var promptedIdentityPersonIds: Set<UUID> = []
  private var promptedUnknownIdentityThisStream = false
  private var consecutiveUnknownIdentityAttempts = 0
  private var warnedUnavailableFaceEmbeddingPromptThisStream = false
  private var glassesIdentitySelectionEntries: [PersonDictionaryEntry] = []
  private var glassesIdentitySelectionIndex = 0
  private var glassesConfirmedConversationPersonId: UUID?
  private var glassesConfirmedConversationPersonIds: Set<UUID> = []
  private var glassesConfirmedConversationPersonName: String?
  private var glassesPeopleListPage = 0
  private var lastRecordedGlassesDisplayCardKey = ""
  private var lastStreamReadinessDisplaySignature = ""
  private var liveCaptionDisplayLines: [String] = []
  private var lastLiveCaptionDisplayText = ""
  private var liveQuestionAssembler = LiveTranscriptQuestionAssembler()
  private var liveMemoryTriggerInFlight = false
  private var pendingLiveQuestionWorks: [LiveTranscriptQuestionWork] = []
  private var lastLiveMemoryTriggerText = ""
  private var lastLiveMemoryTriggerAt: Date?
  private var glassesDisplaySendTask: Task<Void, Never>?
  private var cloudDiarizationTask: Task<Void, Never>?
  // Set during stopSession() to suppress the DAT-state-publisher-driven deactivate.
  // Without this, a stale "datStreamStopped" deactivate Task can fire AFTER the user
  // starts a new stream and tear down the new stream's mic mid-flight — producing a
  // zero-second WAV.
  private var explicitTeardownInFlight = false
  private var stopSessionInFlight = false
  private var streamStopGeneration: UInt64 = 0
  private static let identityConfirmationStopSuppressionSeconds: TimeInterval = 1.25
  private var suppressGlassesStopUntil: Date?

  // MARK: - Init

  init() {
    inputMode = .realGlasses
    streamStateText = "REAL READY"
    sourceStateText = inputMode.rawValue
    let workerSettings = LocalWorkerSettings.load()
    localWorkerEnabled = workerSettings.enabled
    localWorkerEndpointText = workerSettings.endpoint
    localWorkerAPIKeyText = workerSettings.apiKey
    let deepSeekSettings = DeepSeekSettings.load()
    let aiProxyConfigured = SupabaseEdgeFunctionClient.isConfigured()
    deepSeekAPIKeyText = deepSeekSettings.apiKey
    deepSeekModelText = deepSeekSettings.model
    deepSeekStatusText = aiProxyConfigured
      ? "DeepSeek via Supabase Edge: \(deepSeekSettings.model)"
      : deepSeekSettings.apiKey.isEmpty
        ? "DeepSeek key missing"
        : "DeepSeek configured: \(deepSeekSettings.model)"
    let alibabaSettings = AlibabaTranscriptionSettings.load()
    liveTranscriptionEnabled = alibabaSettings.enabled
    switch alibabaSettings.provider {
    case .localParakeet:
      liveTranscriptionStatusText = "iPhone Parakeet ASR ready: \(alibabaSettings.parakeetModelName)"
    case .dashScope:
      liveTranscriptionStatusText = aiProxyConfigured
        ? "DashScope ASR via Supabase Edge: \(alibabaSettings.model)"
        : alibabaSettings.apiKey.isEmpty
          ? "DashScope ASR key missing"
          : "DashScope ASR ready: \(alibabaSettings.model)"
    }
    isLoadingSceneContextSettings = true
    let sceneSettings = SceneContextSettings.load()
    sceneContextEnabled = sceneSettings.enabled
    sceneLocationContextEnabled = sceneSettings.locationEnabled
    sceneContextStatusText = sceneSettings.enabled
      ? (aiProxyConfigured ? "Scene context via Supabase Edge: \(sceneSettings.model)" : sceneSettings.apiKey.isEmpty ? "Scene context key missing" : "Scene context ready: \(sceneSettings.model)")
      : "Scene context off"
    isLoadingSceneContextSettings = false
    isLoadingCloudEmbeddingSettings = true
    let cloudFaceSettings = CloudFaceEmbeddingSettings.load()
    cloudFaceEmbeddingEnabled = cloudFaceSettings.enabled
    cloudFaceEmbeddingEndpointText = cloudFaceSettings.endpoint
    cloudFaceEmbeddingAPIKeyText = cloudFaceSettings.apiKey
    cloudFaceEmbeddingStatusText = cloudFaceSettings.enabled
      ? "Cloud AdaFace configured; restart stream/app to apply"
      : "Cloud face embedding off"
    let cloudSpeakerSettings = CloudSpeakerEmbeddingSettings.load()
    cloudSpeakerEmbeddingEnabled = cloudSpeakerSettings.enabled
    cloudSpeakerEmbeddingEndpointText = cloudSpeakerSettings.endpoint
    cloudSpeakerEmbeddingAPIKeyText = cloudSpeakerSettings.apiKey
    cloudSpeakerEmbeddingStatusText = cloudSpeakerSettings.enabled
      ? "AWS canonical speaker configured; starts with next stream"
      : "AWS canonical speaker embeddings off"
    isLoadingCloudEmbeddingSettings = false
    Task { [weak self] in
      guard let self else { return }
      let status = await identityPipeline.embeddingModelStatusText()
      let diagnostics = await identityPipeline.embeddingModelDiagnosticsText()
      let profiles = await identityPipeline.currentProfiles()
      await MainActor.run {
        self.faceEmbeddingModelStatusText = status
        self.faceEmbeddingModelDiagnosticsText = diagnostics
        self.knownPersonCandidates = profiles.map {
          PersonNameCandidate(personId: $0.id, displayName: $0.displayName)
        }
      }
    }
    indexRecentStreamSummaries()
    datManager.onFrameImage = { [weak self] image in
      self?.handleRealGlassesImage(image)
    }
    datManager.onFramePixelBuffer = { [weak self] pixelBuffer, previewImage in
      self?.handleRealGlassesPixelBuffer(pixelBuffer, previewImage: previewImage)
    }
    datManager.onError = { [weak self] message in
      Task { @MainActor in
        self?.showError(message)
      }
    }
    datManager.assistanceDisplayActionHandler = { [weak self] action in
      Task { @MainActor in
        await self?.handleGlassesDisplayAction(action)
      }
    }
    speechManager.$microphoneStatusText
      .receive(on: DispatchQueue.main)
      .assign(to: &$microphoneStatusText)
    datManager.$sdkStatusText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datSDKStatusText)
    datManager.$configurationModeText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datConfigurationModeText)
    datManager.$registrationStateText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datRegistrationStateText)
    datManager.$deviceCount
      .receive(on: DispatchQueue.main)
      .assign(to: &$datDeviceCount)
    datManager.$selectedDeviceIDText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datSelectedDeviceIDText)
    datManager.$deviceSessionStateText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datDeviceSessionStateText)
    datManager.$runtimeSessionStateText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datRuntimeSessionStateText)
    datManager.$cameraPermissionStatusText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datCameraPermissionStatusText)
    datManager.$connectionStageText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datConnectionStageText)
    datManager.$isWaitingForMetaAIReturn
      .receive(on: DispatchQueue.main)
      .assign(to: &$datWaitingForMetaAIReturn)
    datManager.$isConnecting
      .receive(on: DispatchQueue.main)
      .assign(to: &$datIsConnecting)
    datManager.$hasActiveDevice
      .receive(on: DispatchQueue.main)
      .assign(to: &$datHasActiveDevice)
    datManager.$isDeviceSessionReady
      .receive(on: DispatchQueue.main)
      .assign(to: &$datIsDeviceSessionReady)
    datManager.$isStreamRunning
      .receive(on: DispatchQueue.main)
      .assign(to: &$datIsStreamRunning)
    datManager.$isAppActive
      .receive(on: DispatchQueue.main)
      .assign(to: &$datIsAppActive)
    datManager.$devicesStreamActive
      .receive(on: DispatchQueue.main)
      .assign(to: &$datDevicesStreamActive)
    datManager.$metaAIOpenedTimestampText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datMetaAIOpenedTimestampText)
    datManager.$lastActiveAfterReturnText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datLastActiveAfterReturnText)
    datManager.$firstDevicesStreamEventTimestampText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datFirstDevicesStreamEventTimestampText)
    datManager.$lastDevicesEventTimestampText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datLastDevicesEventTimestampText)
    datManager.$selectedDeviceCompatibilityText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datSelectedDeviceCompatibilityText)
    datManager.$selectedDeviceLinkStateText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datSelectedDeviceLinkStateText)
    datManager.$startReadinessReasonText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datStartReadinessReasonText)
    datManager.$firstFrameTimestampText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datFirstFrameTimestampText)
    datManager.$lastDATErrorText
      .receive(on: DispatchQueue.main)
      .sink { [weak self] message in
        guard let self else { return }
        self.datLastErrorText = message
        if message.localizedCaseInsensitiveContains("no video frames"),
           self.datIsStreamRunning || self.datStreamSessionStateText.lowercased().contains("streaming") {
          self.showGlassesStreamingDashboard(reason: "dat-stream-no-video-frames")
        }
      }
      .store(in: &cancellables)
    datManager.$runtimeBundleConfigurationText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datRuntimeBundleConfigurationText)
    datManager.$runtimeURLTypesText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datRuntimeURLTypesText)
    datManager.$runtimeCameraAccessSchemeText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datRuntimeCameraAccessSchemeText)
    datManager.$runtimeAssociatedDomainsText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datRuntimeAssociatedDomainsText)
    datManager.$runtimeDeveloperModeFlagText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datRuntimeDeveloperModeFlagText)
    datManager.$lastOpenURLText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datLastOpenURLText)
    datManager.$lastHandleURLResultText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datLastHandleURLResultText)
    datManager.$lastRegistrationErrorDetailText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datLastRegistrationErrorDetailText)
    datManager.$startRegistrationCalledText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datStartRegistrationCalledText)
    datManager.$requestCameraPermissionCalledText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datRequestCameraPermissionCalledText)
    datManager.$registrationHandoffDiagnosticText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datRegistrationHandoffDiagnosticText)
    datManager.$framesReceived
      .receive(on: DispatchQueue.main)
      .sink { [weak self] in self?.datFramesReceived = $0 }
      .store(in: &cancellables)
    datManager.$framesWithPixelBuffer
      .receive(on: DispatchQueue.main)
      .sink { [weak self] count in
        guard let self else { return }
        self.datFramesWithPixelBuffer = count
        var shouldActivateLiveStream = true
        if count > 0 {
          shouldActivateLiveStream = self.markLiveDATFrameArrived(at: Date())
        }
        if shouldActivateLiveStream {
          self.activateLiveStreamSessionAfterFirstFrameIfReady()
        }
      }
      .store(in: &cancellables)
    datManager.$frameConversionFailures
      .receive(on: DispatchQueue.main)
      .sink { [weak self] in self?.datFrameConversionFailures = $0 }
      .store(in: &cancellables)
    datManager.$lastFrameWidthText
      .receive(on: DispatchQueue.main)
      .sink { [weak self] in self?.datLastFrameWidthText = $0 }
      .store(in: &cancellables)
    datManager.$lastFrameHeightText
      .receive(on: DispatchQueue.main)
      .sink { [weak self] in self?.datLastFrameHeightText = $0 }
      .store(in: &cancellables)
    datManager.$lastFrameTimestampText
      .receive(on: DispatchQueue.main)
      .sink { [weak self] in self?.datLastFrameTimestampText = $0 }
      .store(in: &cancellables)
    datManager.$lastFrameErrorText
      .receive(on: DispatchQueue.main)
      .sink { [weak self] in self?.datLastFrameErrorText = $0 }
      .store(in: &cancellables)
    datManager.$assistanceDisplayStateText
      .receive(on: DispatchQueue.main)
      .assign(to: &$glassesDisplayStateText)
    datManager.$assistanceDisplayStatusText
      .receive(on: DispatchQueue.main)
      .assign(to: &$glassesDisplayStatusText)
    datManager.$assistanceDisplayLastCardText
      .receive(on: DispatchQueue.main)
      .assign(to: &$glassesDisplayLastCardText)
    datManager.$isAssistanceDisplayConnected
      .receive(on: DispatchQueue.main)
      .assign(to: &$glassesDisplayConnected)
    datManager.$assistanceDisplayRequiresDATAppUpdate
      .receive(on: DispatchQueue.main)
      .assign(to: &$glassesDisplayRequiresDATAppUpdate)
    datManager.$assistanceDisplaySendCount
      .receive(on: DispatchQueue.main)
      .assign(to: &$glassesDisplaySendCount)
    datManager.$streamSessionStateText
      .receive(on: DispatchQueue.main)
      .sink { [weak self] stateText in
        guard let self else { return }
        self.datStreamSessionStateText = stateText
        self.streamStateText = stateText
        self.syncLifecycleFromDATState(stateText)
        let normalizedState = stateText.lowercased()
        if normalizedState.contains("streaming") {
          self.showGlassesStreamingDashboard(reason: "dat-streaming")
          self.activateLiveStreamSessionAfterFirstFrameIfReady()
        } else if normalizedState.contains("starting") || normalizedState.contains("waiting") {
          self.showGlassesStreamStatus(
            title: "Starting stream",
            message: normalizedState.contains("waiting") ? "Waiting for glasses camera stream." : "Preparing glasses camera stream.",
            reason: "dat-stream-preparing",
            sendTiming: .streamStatus(reason: "dat-stream-preparing")
          )
        } else if normalizedState.contains("paused") {
          self.showGlassesStreamStatus(
            title: "Stream paused",
            message: "Waiting for the DAT stream to resume.",
            reason: "dat-stream-paused"
          )
        } else if normalizedState.contains("stopped") {
          self.liveStreamActivationTask?.cancel()
          self.liveStreamActivationTask = nil
          // If stopSession() is the one driving DAT to "stopped", it already tore
          // everything down synchronously. Scheduling another deactivate Task here
          // would run after the user's next start, killing the new stream's mic.
          guard !self.explicitTeardownInFlight else { return }
          Task { @MainActor [weak self] in
            await self?.deactivateLiveStreamSessionIfNeeded(
              reason: "datStreamStopped",
              cancelDisplayWork: false
            )
          }
        }
      }
      .store(in: &cancellables)
    Task { [weak self] in
      guard let self else { return }
      let snapshot = await identityPipeline.startAppRunIfNeeded()
      let context = await identityPipeline.currentContext()
      await MainActor.run {
        self.pipelineContext = context
        self.applyRunSessionSnapshot(snapshot)
      }
    }
    Task { [weak self] in
      guard let self else { return }
      await speakerPipeline.loadFromDisk()
      await refreshEnrolledVoicePersonIds()
      await refreshWearerVoiceProfile()
    }
  }

  deinit {
    let pipeline = identityPipeline
    Task {
      await pipeline.endAppRun()
    }
  }

  // MARK: - Public API

  func stopSession(reason: String = "callerRequested") async {
    if stopSessionInFlight {
      AppLogger.log(.stream, "stopSession ignored because teardown is already in flight reason=\(reason), lifecycle=\(lifecycleState.rawValue), datStream=\(datStreamSessionStateText)")
      return
    }
    if lifecycleState == .stopping {
      AppLogger.log(.stream, "stopSession ignored because lifecycle is already STOPPING reason=\(reason), datStream=\(datStreamSessionStateText)")
      return
    }
    if lifecycleState == .stopped,
       streamingStatus == .stopped,
       !liveStreamSessionActivated,
       !datIsStreamRunning,
       !datStreamSessionStateText.lowercased().contains("streaming") {
      AppLogger.log(.stream, "stopSession ignored because stream is already stopped reason=\(reason), datStream=\(datStreamSessionStateText)")
      return
    }
    AppLogger.log(.stream, "stopSession requested reason=\(reason), inputMode=\(inputMode.rawValue), lifecycle=\(lifecycleState.rawValue), streamState=\(streamStateText), datStream=\(datStreamSessionStateText)")
    emitStreamPerformanceCountersIfNeeded(force: true)
    stopSessionInFlight = true
    explicitTeardownInFlight = true
    streamStopGeneration &+= 1
    defer {
      explicitTeardownInFlight = false
      stopSessionInFlight = false
    }
    lifecycleState = .stopping
    streamingStatus = .waiting
    streamStateText = StreamLifecycleState.stopping.rawValue
    prepareDisplayForStreamStop(reason: reason)
    let hadLivePhoneAudioSession = livePhoneAudioSessionActive
    liveStreamSessionActivated = false
    livePhoneAudioSessionActive = false
    liveStreamActivationTask?.cancel()
    liveStreamActivationTask = nil
    invalidateLiveDATVisionWork(reason: "stopSession-\(reason)")
    invalidateAssistanceWork(reason: "stopSession-\(reason)", cancelDisplayWork: false)
	    await datManager.stopStream(reason: reason)
	    speechManager.stop()
	    speechManager.onAudioBuffer = nil
	    stopLiveTranscriptionForStream()
	    await stopCloudSpeakerWorkerForStream(reason: reason, stopEC2: !hadLivePhoneAudioSession)
    await stopCloudFaceWorkerForStream(reason: reason, stopEC2: !hadLivePhoneAudioSession)
    if hadLivePhoneAudioSession, !isDATAnalysisPaused {
      await finalizeConversationTranscriptAfterStream(reason: reason)
      await scheduleLatestStreamSummary(reason: reason)
      // Finalize audio recording and submit cloud diarization job.
      let audioFileURL = audioRecorder.stop()
      let capturedStart = streamAudioStart
      let capturedTimeline = speakerTimeline
      let capturedSpeakerEvidence = speakerEvidenceTimeline
      let capturedFaceEvidence = faceEvidenceTimeline
      let capturedContext = pipelineContext
      let capturedLocalTranscripts = postSessionLocalTranscriptSegments
      if let audioURL = audioFileURL, let start = capturedStart {
        scheduleCloudDiarizationJob(
          audioURL: audioURL,
          streamStart: start,
          localTranscriptSegments: capturedLocalTranscripts,
          speakerTimeline: capturedTimeline,
          speakerEvidenceTimeline: capturedSpeakerEvidence,
          faceEvidenceTimeline: capturedFaceEvidence,
          pipelineContext: capturedContext
        )
      } else {
        cloudDiarizationState = .idle
      }
    } else if hadLivePhoneAudioSession {
      let discardedURL = audioRecorder.stop()
      if let discardedURL {
        try? FileManager.default.removeItem(at: discardedURL)
      }
      cloudDiarizationState = .idle
      AppLogger.log(.stream, "Skipped post-stream transcript attribution and cloud diarization because analysis is paused reason=\(reason)")
    } else {
      cloudDiarizationState = .idle
      AppLogger.log(.stream, "Skipping phone audio/conversation teardown because live phone audio was not active reason=\(reason)")
    }
    streamAudioStart = nil
    lastConversationSessionIdForSpeakerReview = pipelineContext?.conversationSessionId
    await speakerPipeline.resetRuntimeState(reason: "stopSession-\(reason)")
    capturedVoiceClips = await speakerPipeline.capturedVoiceClipSnapshots()
    wearerVoiceProfile = await speakerPipeline.wearerVoiceProfileSnapshot()
    persistFinalPresenceEpisodes(reason: "stopSession-\(reason)")
    closeCurrentActivityModeEpisode(reason: "stopSession-\(reason)")
    await identityPipeline.endConversation()
    pipelineContext = await identityPipeline.currentContext()
    applyRunSessionSnapshot(await identityPipeline.currentRunSessionSnapshot())
    stopVideoProvider()
    UIApplication.shared.isIdleTimerDisabled = false
    lifecycleState = .stopped
    streamingStatus = .stopped
    streamStateText = StreamLifecycleState.stopped.rawValue
    sourceStateText = inputMode.rawValue
    lastVoiceSimilarity = 0
    lastIPhoneVoiceSimilarity = 0
    lastWorkerVoiceSimilarity = 0
    lastWearerVoiceSimilarity = 0
    iPhoneVoiceSimilarityStatusText = "iPhone local estimate: pending"
    workerVoiceSimilarityStatusText = "AWS canonical: disabled"
    wearerVoiceSimilarityStatusText = "Wearer: not checked"
    voiceMatchStatusText = ""
    resetVideoState(reason: "streamStopped")
  }

  func connectRealGlasses() async {
    inputMode = .realGlasses
    sourceStateText = inputMode.rawValue
    guard !datManager.isSimulator else {
      showError("Real Meta glasses connection requires a physical iPhone. Use Mock Device Kit mode on simulator.")
      return
    }
    await datManager.connectRealGlasses()
  }

  func startRealGlassesStream() async {
    inputMode = .realGlasses
    sourceStateText = inputMode.rawValue
    guard !datManager.isSimulator else {
      showError("Real Meta glasses connection requires a physical iPhone. Use Mock Device Kit mode on simulator.")
      return
    }
    let datState = datStreamSessionStateText.lowercased()
    if datState.contains("waiting") || datState.contains("starting") || datState.contains("paused") {
      AppLogger.log(.stream, "Start streaming ignored because DAT Stream is \(datStreamSessionStateText). Waiting for SDK state transition.")
      return
    }
    if datState.contains("streaming") || datIsStreamRunning {
      AppLogger.log(.stream, "Start streaming ignored because DAT Stream is already streaming.")
      return
    }
    guard !stopSessionInFlight, lifecycleState != .stopping, !explicitTeardownInFlight else {
      AppLogger.log(.stream, "Start streaming ignored because stream teardown is still settling lifecycle=\(lifecycleState.rawValue) datStream=\(datStreamSessionStateText)")
      return
    }
    guard datManager.canStartStream else {
      showGlassesStreamStatus(
        title: "Stream not ready",
        message: datStartReadinessReasonText,
        reason: "start-real-glasses-stream-not-ready",
        allowStop: false
      )
      showError("Start streaming blocked: \(datStartReadinessReasonText)")
      AppLogger.log(.stream, "Start streaming tapped before ready: \(datStartReadinessReasonText)")
      return
    }

    stopVideoProvider()
    resetVideoState(reason: "startingRealGlassesStream", logStop: false)
    totalReceivedFrames = 0
    totalPreviewFrames = 0
    totalDroppedFrames = 0
    framesReceived = 0
    previewFrames = 0
    visionSubmittedFrames = 0
    visionProcessedFrames = 0
    droppedFrames = 0
    liveFrameStatsText = "received=0 preview=0 vision=0/0 dropped=0 fps=0.0 avgVision=0.0 ms"
    lastFrameIntervalText = "0.0 ms"
    lastFrameTimestampText = "none"
    lastFrameArrival = nil
    lastPreviewUpdateAt = nil
    lastVisionSubmissionAt = nil
    pendingVisionImage = nil
    resetPostSessionAttributionState()
    resetLivePhoneAssistanceState()
    resetStatsWindow()
    resetStreamPerformanceCounters()

    lifecycleState = .starting
    streamingStatus = .waiting
    streamStateText = "STARTING"
    sourceStateText = "REAL GLASSES"
    showGlassesStreamStatus(
      title: "Starting stream",
      message: "Preparing iPhone mic and glasses camera.",
      reason: "start-real-glasses-stream"
    )

    guard livePhoneAudioCaptureEnabled else {
      lifecycleState = .error
      streamingStatus = .stopped
      microphoneStatusText = "iPhone mic required for DAT stream"
      showGlassesStreamStatus(
        title: "Stream blocked",
        message: "Enable iPhone microphone recording before starting.",
        reason: "start-real-glasses-stream-mic-disabled",
        allowStop: false
      )
      showError("Start streaming blocked: iPhone microphone recording is required while DAT streaming is active.")
      AppLogger.log(.stream, "Start streaming blocked because live iPhone audio capture is disabled")
      return
    }
    let datDeviceId = datSelectedDeviceIDText == "None" ? nil : datSelectedDeviceIDText
    let phoneAudioStarted = await startLivePhoneAudioCapture(
      reason: "beforeDATStreamStart",
      datDeviceId: datDeviceId,
      validateDATAfterStart: false
    )
    guard phoneAudioStarted else {
      lifecycleState = .error
      streamingStatus = .stopped
      showGlassesStreamStatus(
        title: "Stream blocked",
        message: "iPhone microphone failed to start.",
        reason: "start-real-glasses-stream-mic-failed",
        allowStop: false
      )
      showError("Start streaming blocked: iPhone microphone failed to start.")
      AppLogger.log(.stream, "Start streaming blocked because live iPhone audio failed to start before DAT stream")
      return
    }

    let started = await datManager.startStream()
    if started {
      lifecycleState = .waiting
      streamingStatus = .waiting
      AppLogger.log(.stream, "Real glasses stream start requested after iPhone microphone startup; waiting for DAT Stream state=streaming")
    } else {
      await deactivateLiveStreamSessionIfNeeded(reason: "datStartFailedAfterPhoneAudioStart")
      lifecycleState = .error
      streamingStatus = .stopped
      let detail = datLastErrorText == "None" ? datStartReadinessReasonText : datLastErrorText
      showGlassesStreamStatus(
        title: "Stream failed",
        message: detail,
        reason: "start-real-glasses-stream-failed",
        allowStop: false
      )
      showError("Start streaming failed: \(detail)")
    }
  }

  private func startLiveTranscriptionForStream(reason: String) {
    let settings = AlibabaTranscriptionSettings.load()
    guard !isDATAnalysisPaused else {
      liveTranscriptPreviewText = "Analysis paused"
      liveTranscriptionStatusText = "Live ASR paused"
      liveTranscriber.stop()
      stopSceneContextForStream()
      sceneContextStatusText = "Scene context paused"
      return
    }
    guard liveTranscriptionEnabled else {
      liveTranscriptPreviewText = "No live transcript yet"
      liveTranscriptionStatusText = "Live ASR disabled"
      liveTranscriber.stop()
      startSceneContextForStream(reason: reason)
      return
    }
    liveTranscriptPreviewText = "Listening..."
    let aiProxyConfigured = SupabaseEdgeFunctionClient.isConfigured()
    let transcriptPath: String
    switch settings.provider {
    case .localParakeet:
      liveTranscriptionStatusText = "iPhone Parakeet ASR starting"
      transcriptPath = "local_iphone_parakeet_coreml"
      AppLogger.log(
        .parakeetASR,
        "status=providerSelected provider=localParakeet model=\(settings.parakeetModelName) cloudASRRequests=false streamReason=\(reason)"
      )
    case .dashScope:
      liveTranscriptionStatusText = aiProxyConfigured
        ? "DashScope ASR proxy starting"
        : settings.apiKey.isEmpty
          ? "DashScope ASR key missing"
          : "DashScope ASR starting"
      transcriptPath = aiProxyConfigured
        ? "supabase_edge_proxy"
        : settings.apiKey.isEmpty ? "unavailable_no_key_no_proxy" : "direct_dashscope_key"
    }
    if transcriptPath == "unavailable_no_key_no_proxy" {
      liveTranscriptPreviewText = "Live transcript unavailable"
      liveTranscriptionStatusText = "Live transcript unavailable: no DashScope key and Supabase ASR proxy not configured"
      AppLogger.log(.transcript, "warning...---- [LIVE_TRANSCRIPT] stage=start reason=\(reason) path=unavailable enabled=true model=\(settings.model) hasKey=false proxy=false detail=Set SUPABASE_URL/SUPABASE_ANON_KEY (edge proxy) or DASHSCOPE_API_KEY (direct) to enable ASR; transcript will stay empty until then")
    } else {
      let modelName = settings.provider == .localParakeet ? settings.parakeetModelName : settings.model
      AppLogger.log(.transcript, "[LIVE_TRANSCRIPT] stage=start reason=\(reason) path=\(transcriptPath) provider=\(settings.provider.rawValue) enabled=\(settings.enabled) model=\(modelName) hasKey=\(!settings.apiKey.isEmpty) proxy=\(aiProxyConfigured)")
    }
    liveTranscriber.start(settings: settings) { [weak self] update in
      Task { @MainActor [weak self] in
        self?.handleLiveTranscriptionUpdate(update)
      }
    }
    startSceneContextForStream(reason: reason)
  }

  private func stopLiveTranscriptionForStream() {
    liveTranscriber.stop()
    stopSceneContextForStream()
  }

  private func startSceneContextForStream(reason: String) {
    let settings = SceneContextSettings.load()
    guard !isDATAnalysisPaused else {
      sceneContextPipeline.stop()
      sceneLocationProvider.stop()
      sceneContextStatusText = "Scene context paused"
      return
    }
    guard sceneContextEnabled else {
      sceneContextPipeline.stop()
      sceneLocationProvider.stop()
      sceneContextStatusText = "Scene context off"
      return
    }
    let aiProxyConfigured = SupabaseEdgeFunctionClient.isConfigured()
    sceneContextFrameEncodingToken = nil
    sceneContextStatusText = aiProxyConfigured
      ? "Scene context proxy listening: \(settings.model)"
      : settings.apiKey.isEmpty
        ? "Scene context key missing"
        : "Scene context listening: \(settings.model)"
    sceneLocationProvider.start(enabled: false)
    sceneContextPipeline.start(
      onStatus: { [weak self] message in
        self?.sceneContextStatusText = message
      },
      onRecord: { [weak self] record in
        guard let self else { return }
        self.streamPerformanceCounters.databaseWrites += 1
        self.emitStreamPerformanceCountersIfNeeded(force: false)
        await self.identityPipeline.saveSceneContext(record)
        self.publishSceneContextDisplay(record, reason: "scene-context")
        if self.showPeopleDictionary {
          self.peopleDictionaryEntries = await self.identityPipeline.loadPeopleForDictionary()
        }
      }
    )
    AppLogger.log(.sceneContext, "Scene context requested reason=\(reason) enabled=\(settings.enabled) model=\(settings.model) hasKey=\(!settings.apiKey.isEmpty) proxy=\(aiProxyConfigured) location=false")
  }

  private func stopSceneContextForStream() {
    sceneContextFrameEncodingToken = nil
    sceneContextPipeline.stop()
    sceneLocationProvider.stop()
  }

  private func handleLiveTranscriptionUpdate(_ update: AlibabaLiveTranscriptionUpdate) {
    switch update {
    case .status(let message):
      liveTranscriptionStatusText = message
      AppLogger.log(.transcript, "[LIVE_TRANSCRIPT] stage=status message=\"\(Self.truncated(message, maxLength: 120))\"")
    case .failure(let message):
      liveTranscriptionStatusText = "Live ASR failed: \(Self.truncated(message, maxLength: 140))"
      AppLogger.log(.transcript, "warning...---- [LIVE_TRANSCRIPT] stage=failure detail=\"\(Self.truncated(message, maxLength: 200))\"; live transcript chunk did not produce text — see preceding [ASR_PROXY]/[AI_PROXY] line for endpoint+status")
    case .transcript(let segment):
      guard !isDATAnalysisPaused else {
        liveTranscriptionStatusText = "Live ASR paused"
        return
      }
      let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return }
      guard Self.hasMeaningfulLiveTranscript(text) else {
        streamPerformanceCounters.asrFillerSkipped += 1
        liveTranscriptionStatusText = "\(segment.provider.displayName) skipped filler"
        emitStreamPerformanceCountersIfNeeded(force: false)
        return
      }
      streamPerformanceCounters.asrTranscriptSegments += 1
      if segment.provider == .localParakeet {
        postSessionLocalTranscriptSegments.append(
          LocalPostSessionTranscriptSegment(
            id: segment.id,
            text: text,
            startedAt: segment.startedAt,
            endedAt: segment.endedAt,
            provider: segment.provider
          )
        )
        postSessionLocalTranscriptSegments = Array(postSessionLocalTranscriptSegments.suffix(400))
      }
      refreshStreamReadinessDisplayIfNeeded(reason: "stream-readiness-speech")
      liveTranscriptPreviewText = text
      liveTranscriptionStatusText = "\(segment.provider.displayName) saved \(String(format: "%.1f", Double(segment.durationSeconds)))s"
      recentConversationAttributionText = "Live transcript: \(Self.truncated(text, maxLength: 180))"
      let attribution = currentTranscriptAttribution()
      let identityEvidence = currentSceneContextIdentityEvidence(attribution: attribution)
      sceneContextPipelineVerificationText = Self.sceneContextIdentityVerificationText(
        evidence: identityEvidence,
        attribution: attribution
      )
      publishLiveCaptionDisplay(text: text, attribution: attribution)
      processTranscriptNamePresence(text: text, timestamp: segment.endedAt)
      scheduleActivityModeClassification(reason: "live-transcript")
      processLiveTranscriptMemoryTrigger(
        text: text,
        attribution: attribution,
        startedAt: segment.startedAt,
        endedAt: segment.endedAt
      )
      let entry = TranscriptEntry(
        id: segment.id,
        text: text,
        timestamp: segment.startedAt.timeIntervalSince1970,
        isFinal: true,
        startedAt: segment.startedAt,
        endedAt: segment.endedAt,
        source: segment.provider.transcriptSource
      )
      Task { @MainActor [weak self] in
        guard let self else { return }
        let pipelineContext = await self.identityPipeline.currentContext()
        self.sceneContextPipeline.captureTranscript(
          id: entry.id,
          text: text,
          startedAt: entry.startedAt,
          endedAt: entry.endedAt,
          personId: attribution.personId,
          displayName: attribution.displayName,
          context: pipelineContext,
          identityEvidence: identityEvidence,
          location: nil
        )
      }
      AppLogger.log(.transcript, "[LIVE_TRANSCRIPT] stage=received provider=\(segment.provider.rawValue) seconds=\(String(format: "%.1f", Double(segment.durationSeconds))) textLen=\(text.count) preview=\"\(Self.truncated(text, maxLength: 120))\"")
    }
  }

  nonisolated private static func truncated(_ text: String, maxLength: Int) -> String {
    guard text.count > maxLength else { return text }
    return String(text.prefix(maxLength)) + "..."
  }

  private static func sceneContextIdentityVerificationText(
    evidence: SceneContextIdentityEvidence?,
    attribution: TranscriptAttribution
  ) -> String {
    guard let evidence else {
      return "5W/1H: no app identity evidence yet; transcript attribution=\(attribution.state)"
    }
    let partner = evidence.conversationPartnerName ?? evidence.conversationPartnerPersonId?.uuidString ?? "unknown"
    let active = evidence.activePeople.map(\.displayName).joined(separator: ", ")
    let departed = evidence.departedPeople.map(\.displayName).joined(separator: ", ")
    var parts = [
      "5W/1H identity: \(partner) \(evidence.conversationPartnerState) \(Int((evidence.confidence * 100).rounded()))%"
    ]
    if !active.isEmpty {
      parts.append("active: \(active)")
    }
    if !departed.isEmpty {
      parts.append("departed: \(departed)")
    }
    return truncated(parts.joined(separator: " | "), maxLength: 220)
  }

  private func processLiveTranscriptMemoryTrigger(
    text: String,
    attribution: TranscriptAttribution,
    startedAt: Date?,
    endedAt: Date?
  ) {
    let people = knownPersonCandidates
    guard let observation = liveQuestionAssembler.appendObservation(
      text: text,
      startedAt: startedAt,
      endedAt: endedAt,
      people: people
    ) else { return }
    if AlibabaTranscriptionSettings.load().provider == .localParakeet {
      AppLogger.log(
        .parakeetASR,
        "status=questionAssembler currentTranscript=\(observation.currentTranscript) rollingTranscript=\(observation.rollingTranscript) classifierCandidate=\(observation.candidateText)"
      )
    }
    if observation.localTrigger == nil,
       LiveTranscriptQuestionRouter.shouldWaitForMoreTranscript(observation.candidateText) {
      memoryTriggerVerificationText = "Live question: waiting for complete question"
      AppLogger.log(.memory, "Live question trigger held locally reason=incompleteQuestion text=\"\(Self.truncated(observation.candidateText, maxLength: 160))\"")
      return
    }
    if observation.localTrigger == nil,
       !LiveTranscriptQuestionRouter.shouldSendToLLMTriggerClassifier(observation.candidateText) {
      streamPerformanceCounters.asrFillerSkipped += 1
      emitStreamPerformanceCountersIfNeeded(force: false)
      memoryTriggerVerificationText = "Live question: filtered locally"
      AppLogger.log(
        .memory,
        "Live question trigger filtered locally reason=noiseOrTestFragment qwenAnswer=false candidate=\"\(Self.truncated(observation.candidateText, maxLength: 160))\" current=\"\(Self.truncated(observation.currentTranscript, maxLength: 120))\""
      )
      return
    }
    let qwenSettings = AlibabaQuestionAnswerSettings.load()
    let hasQwenClassifier = SupabaseEdgeFunctionClient.isConfigured()
      || !qwenSettings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    guard hasQwenClassifier || observation.localTrigger != nil else { return }
    guard !liveMemoryTriggerInFlight else {
      pendingLiveQuestionWorks.append(LiveTranscriptQuestionWork(observation: observation, attribution: attribution))
      pendingLiveQuestionWorks = Array(pendingLiveQuestionWorks.suffix(4))
      AppLogger.log(.memory, "Live question trigger queued reason=inFlight pending=\(pendingLiveQuestionWorks.count) mode=\(observation.candidateMode.rawValue)")
      return
    }

    runLiveTranscriptQuestionWork(
      LiveTranscriptQuestionWork(observation: observation, attribution: attribution),
      qwenSettings: qwenSettings
    )
  }

  private func runLiveTranscriptQuestionWork(
    _ work: LiveTranscriptQuestionWork,
    qwenSettings: AlibabaQuestionAnswerSettings
  ) {
    let observation = work.observation
    liveMemoryTriggerInFlight = true
    let trigger = observation.localTrigger ?? LiveTranscriptResolvedTrigger(
      fullText: observation.candidateText,
      answerMode: .ignore,
      memoryTrigger: nil,
      confidence: 0,
      reason: "pendingLLM",
      mentionedNames: [],
      startedAt: observation.startedAt,
      endedAt: observation.endedAt
    )
    if let localTrigger = observation.localTrigger {
      memoryTriggerVerificationText = "Live question: \(localTrigger.answerMode.rawValue) detected via \(localTrigger.reason)"
      AppLogger.log(.memory, "Live question trigger detected mode=\(localTrigger.answerMode.rawValue) reason=\(localTrigger.reason) confidence=\(String(format: "%.2f", Double(localTrigger.confidence))) text=\"\(Self.truncated(localTrigger.fullText, maxLength: 160))\"")
    } else {
      memoryTriggerVerificationText = "Live question: checking transcript with LLM"
      AppLogger.log(.memory, "Live question classifier queued text=\"\(Self.truncated(observation.rollingTranscript, maxLength: 160))\"")
    }

    Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        self.liveMemoryTriggerInFlight = false
        self.runNextPendingLiveTranscriptQuestionWorkIfNeeded()
      }
      let profiles = await self.identityPipeline.currentProfiles()
      let people = profiles.map { PersonNameCandidate(personId: $0.id, displayName: $0.displayName) }
      self.knownPersonCandidates = people
      guard let resolvedTrigger = await self.resolveLiveTranscriptTrigger(
        trigger,
        rollingTranscript: observation.rollingTranscript,
        currentTranscript: observation.currentTranscript,
        settings: qwenSettings,
        people: people
      ) else { return }
      let triggerTime = resolvedTrigger.endedAt
      let normalizedText = LiveTranscriptQuestionRouter.normalizedSearchText(resolvedTrigger.fullText)
      let throttle = LiveQuestionThrottlePolicy.evaluate(
        currentQuestion: normalizedText,
        previousQuestion: self.lastLiveMemoryTriggerText,
        currentAt: triggerTime,
        previousAt: self.lastLiveMemoryTriggerAt
      )
      if throttle.shouldThrottle {
        AppLogger.log(
          .memory,
          "Live question trigger skipped reason=throttled detail=\(throttle.reason.rawValue) mode=\(resolvedTrigger.answerMode.rawValue) textSimilarity=\(String(format: "%.2f", throttle.textSimilarity)) elapsedSeconds=\(String(format: "%.1f", throttle.elapsedSeconds ?? 0))"
        )
        return
      }
      if let elapsed = throttle.elapsedSeconds,
         elapsed < LiveQuestionThrottlePolicy.previousGeneralThrottleSeconds {
        AppLogger.log(
          .memory,
          "Live question trigger bypassed throttle reason=distinctQuestion mode=\(resolvedTrigger.answerMode.rawValue) textSimilarity=\(String(format: "%.2f", throttle.textSimilarity)) elapsedSeconds=\(String(format: "%.1f", elapsed)) previous=\"\(Self.truncated(self.lastLiveMemoryTriggerText, maxLength: 100))\" current=\"\(Self.truncated(normalizedText, maxLength: 100))\""
        )
      }
      self.lastLiveMemoryTriggerText = normalizedText
      self.lastLiveMemoryTriggerAt = triggerTime

      switch resolvedTrigger.answerMode {
      case .memory, .mixed:
        let retrieval = await self.retrieveMemory(
          for: resolvedTrigger,
          attribution: work.attribution
        )
        let section = await self.liveMemoryTriggerDisplaySection(
          trigger: resolvedTrigger,
          retrieval: retrieval,
          settings: qwenSettings
        )
        self.publishLiveMemoryTriggerSection(section, personId: retrieval?.chunks.first?.personId, trigger: resolvedTrigger)
      case .general, .current:
        let section = await self.liveQuestionAnswerDisplaySection(
          trigger: resolvedTrigger,
          settings: qwenSettings
        )
        self.publishLiveMemoryTriggerSection(section, personId: nil, trigger: resolvedTrigger)
      case .ignore:
        break
      }
    }
  }

  private func runNextPendingLiveTranscriptQuestionWorkIfNeeded() {
    guard !liveMemoryTriggerInFlight, !pendingLiveQuestionWorks.isEmpty else { return }
    let work = pendingLiveQuestionWorks.removeFirst()
    let qwenSettings = AlibabaQuestionAnswerSettings.load()
    let hasQwenClassifier = SupabaseEdgeFunctionClient.isConfigured()
      || !qwenSettings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    guard hasQwenClassifier || work.observation.localTrigger != nil else {
      runNextPendingLiveTranscriptQuestionWorkIfNeeded()
      return
    }
    runLiveTranscriptQuestionWork(
      work,
      qwenSettings: qwenSettings
    )
  }

  private func resolveLiveTranscriptTrigger(
    _ trigger: LiveTranscriptResolvedTrigger,
    rollingTranscript: String,
    currentTranscript: String,
    settings: AlibabaQuestionAnswerSettings,
    people: [PersonNameCandidate]
  ) async -> LiveTranscriptResolvedTrigger? {
    let apiKey = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard SupabaseEdgeFunctionClient.isConfigured() || !apiKey.isEmpty else {
      return trigger.answerMode == .ignore ? nil : trigger
    }
    do {
      let client = try AlibabaQuestionAnswerClient(settings: settings)
      streamPerformanceCounters.qwenAnswerCalls += 1
      emitStreamPerformanceCountersIfNeeded(force: false)
      if AlibabaTranscriptionSettings.load().provider == .localParakeet {
        AppLogger.log(
          .parakeetASR,
          "status=triggerClassifierInput finalUtterance=\(trigger.fullText) rollingTranscript=\(rollingTranscript) currentTranscript=\(currentTranscript)"
        )
      }
      let decision = try await client.classifyLiveTranscriptTrigger(LiveTranscriptTriggerLLMRequest(
        rollingTranscript: rollingTranscript,
        currentTranscript: currentTranscript,
        localCandidateQuestion: trigger.fullText,
        localAnswerMode: trigger.answerMode,
        peopleNames: people.map(\.displayName)
      ))
      guard decision.isTrigger, !decision.needsMoreTranscript else {
        AppLogger.log(
          .memory,
          "Live question trigger held by LLM reason=\(decision.reason) needsMore=\(decision.needsMoreTranscript)"
        )
        memoryTriggerVerificationText = "Live question: waiting for complete question"
        return nil
      }
      let llmQuestion = decision.fullQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
      let question = llmQuestion.isEmpty ? trigger.fullText : llmQuestion
      if LiveTranscriptQuestionRouter.shouldWaitForMoreTranscript(question) {
        AppLogger.log(.memory, "Live question trigger held after LLM reason=incompleteQuestion text=\"\(Self.truncated(question, maxLength: 160))\"")
        memoryTriggerVerificationText = "Live question: waiting for complete question"
        return nil
      }
      let routed = LiveTranscriptQuestionRouter.route(
        text: question,
        startedAt: trigger.startedAt,
        endedAt: trigger.endedAt,
        people: people
      )
      let base = routed ?? trigger.replacing(fullText: question)
      let resolved = base.replacing(
        answerMode: decision.answerMode == .ignore ? base.answerMode : decision.answerMode,
        reason: "llm:\(decision.reason)",
        confidence: Float(decision.confidence)
      )
      AppLogger.log(
        .memory,
        "Live question trigger confirmed by LLM mode=\(resolved.answerMode.rawValue) confidence=\(String(format: "%.2f", decision.confidence)) text=\"\(Self.truncated(resolved.fullText, maxLength: 160))\""
      )
      return resolved
    } catch {
      AppLogger.log(.memory, "Live question LLM trigger classifier failed; using local trigger: \(error.localizedDescription)")
      return trigger
    }
  }

  private func retrieveMemory(
    for trigger: LiveTranscriptResolvedTrigger,
    attribution: TranscriptAttribution
  ) async -> RemoteMemoryRetrievalResult? {
    let activeIds = Set([
      attribution.personId,
      activeConversationPartnerState.primary?.personId,
      glassesConfirmedConversationPersonId,
      livePhoneAssistancePinnedPersonId,
      activeFacePersonId
    ].compactMap { $0 })
      .union(presenceTracker.snapshot().active.compactMap(\.personId))
    let mentionedIds = knownPersonCandidates
      .filter { candidate in
        trigger.mentionedNames.contains {
          LiveTranscriptQuestionRouter.normalizedSearchText($0)
            == LiveTranscriptQuestionRouter.normalizedSearchText(candidate.displayName)
        }
      }
      .map(\.personId)
    let recentSummaries = RecentMemoryContextBuilder.summaries(from: StreamSummaryHistoryStore.load())
    let sceneContext = currentGlassesSceneContextSections.first?
      .lines
      .prefix(2)
      .joined(separator: " ")
    let request = MemoryRetrievalRequest(
      query: trigger.fullText,
      currentMode: currentActivityModeClassification.mode,
      sceneContext: sceneContext,
      presentPeople: activePresenceDisplayNames(),
      personIds: mentionedIds,
      activePersonIds: Array(activeIds),
      recentSummaries: recentSummaries,
      exactWording: Self.requestsExactWording(trigger.fullText),
      limit: 8,
      minSimilarity: 0.2,
      includeSourceTypes: Self.requestsExactWording(trigger.fullText)
        ? [.transcriptChunk, .streamSummary, .sceneContext, .personNote]
        : [.streamSummary, .personNote, .sceneContext, .transcriptChunk],
      maxSensitivity: mentionedIds.isEmpty && activeIds.isEmpty ? 0 : 1
    )
    do {
      return try await RemoteMemoryRetrievalService().retrieve(request)
    } catch {
      AppLogger.log(
        .memory,
        "[MEMORY_RETRIEVAL] source=local_recent_summary_fallback query=\"\(Self.truncated(trigger.fullText, maxLength: 120))\" summaries=\(recentSummaries.count) reason=\(error.localizedDescription)"
      )
      return nil
    }
  }

  private func liveMemoryTriggerDisplaySection(
    trigger: LiveTranscriptResolvedTrigger,
    retrieval: RemoteMemoryRetrievalResult?,
    settings: AlibabaQuestionAnswerSettings
  ) async -> AssistanceDisplaySection {
    let recentSummaries = RecentMemoryContextBuilder.summaries(from: StreamSummaryHistoryStore.load())
    let memoryContext = retrieval?.evidenceText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let fallbackEvidence = recentSummaries.enumerated().map { index, summary in
      "Recent stream \(index + 1): \(summary)"
    }.joined(separator: "\n")
    let selectedEvidence = memoryContext.isEmpty ? fallbackEvidence : memoryContext
    let fallbackAnswer = recentSummaries.first ?? LiveMemoryAnswerPolicy.noRelevantSavedMemoryLine
    let fallbackLines = Self.liveAnswerLines(
      questionText: trigger.fullText,
      answerText: Self.truncated(fallbackAnswer, maxLength: 120)
    )

    let apiKey = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (SupabaseEdgeFunctionClient.isConfigured() || !apiKey.isEmpty), !selectedEvidence.isEmpty else {
      return AssistanceDisplaySection(title: "Relevant memory", lines: fallbackLines)
    }

    do {
      let client = try AlibabaQuestionAnswerClient(settings: settings)
      streamPerformanceCounters.qwenAnswerCalls += 1
      emitStreamPerformanceCountersIfNeeded(force: false)
      let answer = try await client.answerMemoryQuestion(AlibabaMemoryAnswerRequest(
        fullQuestion: trigger.fullText,
        triggerReason: "\(trigger.answerMode.rawValue):\(trigger.reason)",
        memoryEvidence: selectedEvidence
      ))
      let trimmed = answer.text.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.localizedCaseInsensitiveContains("No relevant saved memory") {
        return AssistanceDisplaySection(
          title: "Relevant memory",
          lines: Self.liveAnswerLines(
            questionText: trigger.fullText,
            answerText: LiveMemoryAnswerPolicy.noRelevantSavedMemoryLine
          )
        )
      }
      return AssistanceDisplaySection(
        title: "Relevant memory",
        lines: Self.liveAnswerLines(questionText: trigger.fullText, answerText: trimmed)
      )
    } catch {
      AppLogger.log(.memory, "Qwen live memory trigger failed: \(error.localizedDescription)")
      return AssistanceDisplaySection(title: "Relevant memory", lines: fallbackLines)
    }
  }

  nonisolated private static func requestsExactWording(_ text: String) -> Bool {
    let normalized = LiveTranscriptQuestionRouter.normalizedSearchText(text)
    return ["exact words", "exactly", "word for word", "what did", "quote"].contains {
      normalized.contains($0)
    }
  }

  private func liveQuestionAnswerDisplaySection(
    trigger: LiveTranscriptResolvedTrigger,
    settings: AlibabaQuestionAnswerSettings
  ) async -> AssistanceDisplaySection {
    let title = trigger.answerMode == .current ? "Current answer" : "Answer"
    do {
      let client = try AlibabaQuestionAnswerClient(settings: settings)
      streamPerformanceCounters.qwenAnswerCalls += 1
      emitStreamPerformanceCountersIfNeeded(force: false)
      let answer = trigger.answerMode == .current
        ? try await client.answerCurrentQuestion(trigger.fullText)
        : try await client.answerStableQuestion(trigger.fullText)
      var lines = Self.liveAnswerLines(questionText: trigger.fullText, answerText: answer.text)
      if let source = answer.sources.first {
        lines.append(Self.truncated("Source: \(source.title)", maxLength: 80))
      } else if answer.usedWebSearch {
        lines.append("Source: Alibaba web search")
      }
      return AssistanceDisplaySection(title: title, lines: lines)
    } catch {
      AppLogger.log(.memory, "Alibaba Qwen live question failed: \(error.localizedDescription)")
      return AssistanceDisplaySection(
        title: title,
        lines: Self.liveAnswerLines(
          questionText: trigger.fullText,
          answerText: "Alibaba Qwen answer unavailable: \(Self.truncated(error.localizedDescription, maxLength: 110))"
        )
      )
    }
  }

  private func publishLiveMemoryTriggerSection(
    _ section: AssistanceDisplaySection,
    personId: UUID?,
    trigger: LiveTranscriptResolvedTrigger
  ) {
    let shouldSwitchToLive = LiveTranscriptAnswerPresentationPolicy.target(for: trigger) == .liveHome
      && (datIsStreamRunning || datStreamSessionStateText.lowercased().contains("streaming"))
    publishLiveRecallSection(
      section,
      personId: personId,
      status: "Triggered by live transcript",
      verification: "Live question: displayed \(Self.truncated(section.lines.first ?? section.title, maxLength: 140))",
      reason: "live-memory-trigger",
      shouldSwitchToLive: shouldSwitchToLive
    )
    AppLogger.log(.memory, "Live memory trigger displayed person=\(personId?.uuidString ?? "none") lines=\(section.lines.count) stack=\(currentGlassesLiveRecallSections.count)")
  }

  private func publishLiveRecallSection(
    _ section: AssistanceDisplaySection,
    personId: UUID?,
    status: String,
    verification: String,
    reason: String,
    shouldSwitchToLive: Bool
  ) {
    let sectionKey = liveRecallSectionKey(section)
    currentGlassesLiveRecallSections.removeAll {
      liveRecallSectionKey($0) == sectionKey
    }
    currentGlassesLiveRecallSections.insert(section, at: 0)
    if currentGlassesLiveRecallSections.count > Self.liveRecallDisplaySectionLimit {
      currentGlassesLiveRecallSections.removeLast(currentGlassesLiveRecallSections.count - Self.liveRecallDisplaySectionLimit)
    }
    refreshLiveRecallPresenceLines()
    phoneAssistanceDismissed = false
    phoneAssistanceTitleText = section.title
    phoneAssistanceDetailText = Self.liveRecallPhoneDetailText(from: currentGlassesLiveRecallSections)
    phoneAssistanceStatusText = status
    phoneAssistanceThumbnail = thumbnailForPerson(personId)
    memoryTriggerVerificationText = verification
    if shouldSwitchToLive {
      activeGlassesDisplayWindow = .live
    }
    sendCombinedGlassesDisplayCard(reason: reason)
  }

  private func liveRecallSectionKey(_ section: AssistanceDisplaySection) -> String {
    ([section.title] + section.lines.filter { !Self.isPresentWithYouLine($0) })
      .joined(separator: "\n")
  }

  private func refreshLiveRecallPresenceLines() {
    guard !currentGlassesLiveRecallSections.isEmpty else { return }
    let presentLine = activePresenceDisplayNames().isEmpty
      ? nil
      : "Present with you: \(activePresenceDisplayNames().joined(separator: ", "))"
    currentGlassesLiveRecallSections = currentGlassesLiveRecallSections.enumerated().map { index, section in
      var updated = section
      var lines = section.lines.filter { !Self.isPresentWithYouLine($0) }
      if index == 0, let presentLine {
        lines.insert(presentLine, at: 0)
      }
      updated = AssistanceDisplaySection(
        title: section.title,
        lines: lines,
        thumbnailImageURI: section.thumbnailImageURI,
        thumbnailImageSize: section.thumbnailImageSize
      )
      return updated
    }
  }

  private func activePresenceDisplayNames() -> [String] {
    Self.uniqueDisplayStrings(presenceTracker.snapshot().active.map(\.displayName))
  }

  private func activeStreamRecognizedPeopleNames() -> [String] {
    var names = activePresenceDisplayNames()
    if activeIdentityStateText == ActiveIdentityState.State.confirmed.rawValue {
      names.append(activeIdentityName)
    }
    if let retainedRecognizedName {
      names.append(retainedRecognizedName)
    }
    if activeConversationPartnerStateText == ConversationPartnerState.Phase.confirmed.rawValue {
      names.append(activeConversationPartnerName)
    }
    if activeSpeakerStateText == "confirmed" {
      names.append(activeSpeakerName)
    }
    return Self.uniqueDisplayStrings(names)
  }

  private static func isPresentWithYouLine(_ line: String) -> Bool {
    line.trimmingCharacters(in: .whitespacesAndNewlines)
      .localizedCaseInsensitiveContains("Present with you:")
  }

  private static func liveRecallPhoneDetailText(from sections: [AssistanceDisplaySection]) -> String {
    sections.enumerated().flatMap { index, section -> [String] in
      let lines = section.lines
        .map { truncated($0, maxLength: 140) }
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      guard !lines.isEmpty else { return [] }
      if index == 0 { return lines }
      return ["", "\(section.title):"] + lines
    }
    .joined(separator: "\n")
  }

  private static func localLiveMemoryTriggerLines(
    trigger: LiveTranscriptResolvedTrigger,
    candidates: [LiveMemoryCandidate]
  ) -> [String] {
    guard let best = candidates.first else {
      return liveAnswerLines(
        questionText: trigger.fullText,
        answerText: LiveMemoryAnswerPolicy.noRelevantSavedMemoryLine
      )
    }
    return liveAnswerLines(questionText: trigger.fullText, answerText: best.summaryLine)
  }

  nonisolated static func liveAnswerLines(questionText: String, answerText: String) -> [String] {
    [
      truncated("Q: \(questionText)", maxLength: 90),
      truncated("A: \(answerText)", maxLength: 120)
    ]
    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  }

  nonisolated static func liveMemoryAnswerLines(triggerText: String, answerText: String) -> [String] {
    liveAnswerLines(questionText: triggerText, answerText: answerText)
  }

  private func configureLiveAudioBufferHandling(reason: String) {
    let recorderRef = audioRecorder
    let transcriptionRef = liveTranscriber
    guard !isDATAnalysisPaused else {
      speechManager.onAudioBuffer = { _ in }
      activeSpeakerStateText = "analysis paused"
      activeSpeakerName = ""
      activeSpeakerPersonId = nil
      activeSpeakerSimilarity = 0
      voiceSpeechBufferSeconds = 0
      voiceMatchStatusText = "Analysis paused"
      iPhoneVoiceSimilarityStatusText = "iPhone local estimate: analysis paused"
      workerVoiceSimilarityStatusText = "AWS canonical: analysis paused"
      wearerVoiceSimilarityStatusText = "Wearer: analysis paused"
      AppLogger.log(.speakerIdentity, "Live audio analysis paused reason=\(reason); iPhone audio session remains available for DAT")
      return
    }

    if liveVoiceEmbeddingEnabled {
      let pipeline = speakerPipeline
      speechManager.onAudioBuffer = { [weak self] buffer in
        recorderRef.append(buffer)
        transcriptionRef.append(buffer)
        Task { [weak self] in
          let result = await pipeline.process(buffer: buffer)
          let bufferSec = await pipeline.currentSpeechBufferSeconds
          let isSpeaking = await pipeline.isCurrentlySpeaking
          // Decide the UI throttle and apply the lightweight updates first; only fetch
          // the heavier voice-clip / wearer snapshots when the UI will consume them, so
          // throttled-out buffers do zero snapshot work (and one fewer actor hop).
          let shouldUpdateUI: Bool = await MainActor.run { [weak self] in
            guard let self else { return false }
            let now = Date()
            let shouldUpdate = self.lastSpeakerUIUpdateAt == nil
              || now.timeIntervalSince(self.lastSpeakerUIUpdateAt!) >= self.speakerUIUpdateIntervalSeconds
              || result.embeddingTriggered
              || result.activeIdentity.phase != .none
            guard shouldUpdate else { return false }
            self.lastSpeakerUIUpdateAt = now
            let phase = result.activeIdentity.phase
            if phase != .none {
              self.activeSpeakerStateText = phase.rawValue
              self.activeSpeakerName = result.activeIdentity.displayName ?? ""
              self.activeSpeakerPersonId = result.activeIdentity.personId
              self.activeSpeakerSimilarity = result.matchResult?.bestSimilarity ?? 0
              self.voiceMatchStatusText = ""
              if phase == .confirmed {
                self.recordSpeakerTimelineEntry(personId: result.activeIdentity.personId,
                                                displayName: result.activeIdentity.displayName)
              }
            } else if isSpeaking {
              self.activeSpeakerStateText = "speaking"
              self.activeSpeakerName = ""
              self.activeSpeakerPersonId = nil
              self.activeSpeakerSimilarity = 0
              if result.matchResult?.reason == "noCompatibleEnrollment" {
                self.voiceMatchStatusText = "Voice enrollment incompatible. Re-enroll speaker."
              } else if result.matchResult?.reason == "noEnrollment" {
                self.voiceMatchStatusText = "No saved speaker enrollment."
              }
            } else {
              self.activeSpeakerStateText = "none"
              self.activeSpeakerName = ""
              self.activeSpeakerPersonId = nil
              self.activeSpeakerSimilarity = 0
              if result.matchResult?.reason == "noCompatibleEnrollment" {
                self.voiceMatchStatusText = "Voice enrollment incompatible. Re-enroll speaker."
              }
            }
            if let sim = result.matchResult?.bestSimilarity, sim > 0 {
              self.lastVoiceSimilarity = sim
            }
            if let wearerMatch = result.wearerSimilarity {
              self.lastWearerVoiceSimilarity = wearerMatch.bestSimilarity
              self.wearerVoiceSimilarityStatusText = self.wearerSimilarityStatusText(for: wearerMatch)
            }
            self.recordSpeakerEvidenceIfNeeded(result)
            if let diagnostic = result.iPhoneSimilarity {
              self.iPhoneVoiceSimilarityStatusText = result.vadDecision == "wearerSpeech"
                ? "iPhone local estimate: Me \(String(format: "%.3f", Double(result.matchResult?.bestSimilarity ?? 0))) · same voice"
                : diagnostic.statusText
              if let sim = diagnostic.bestSimilarity {
                self.lastIPhoneVoiceSimilarity = sim
              }
              if result.vadDecision == "wearerSpeech", let sim = result.matchResult?.bestSimilarity {
                self.lastIPhoneVoiceSimilarity = sim
              }
            }
            if let diagnostic = result.workerSimilarity {
              self.workerVoiceSimilarityStatusText = diagnostic.statusText
              if let sim = diagnostic.bestSimilarity {
                self.lastWorkerVoiceSimilarity = sim
              }
            }
            self.updateAudioSpeakerDebugMetrics(with: result)
            self.voiceSpeechBufferSeconds = bufferSec
            return true
          }
          guard shouldUpdateUI else { return }
          let voiceClips = await pipeline.capturedVoiceClipSnapshots()
          let wearerSnapshot = await pipeline.wearerVoiceProfileSnapshot()
          await MainActor.run { [weak self] in
            guard let self else { return }
            self.capturedVoiceClips = voiceClips
            self.wearerVoiceProfile = wearerSnapshot
          }
        }
      }
    } else {
      speechManager.onAudioBuffer = { buffer in
        recorderRef.append(buffer)
        transcriptionRef.append(buffer)
      }
      activeSpeakerStateText = inputMode == .realGlasses ? "recording" : "disabled"
      activeSpeakerName = ""
      activeSpeakerPersonId = nil
      activeSpeakerSimilarity = 0
      voiceSpeechBufferSeconds = 0
      voiceMatchStatusText = "Live voice embedding disabled"
      iPhoneVoiceSimilarityStatusText = "iPhone local estimate: live embedding disabled"
      workerVoiceSimilarityStatusText = "AWS canonical: disabled"
      wearerVoiceSimilarityStatusText = "Wearer: live embedding disabled"
      AppLogger.log(.speakerIdentity, "Live speaker identity disabled for reason=\(reason); iPhone audio buffers are recorded for post-session diarization")
    }
  }

  private func startLivePhoneAudioCapture(reason: String, datDeviceId: String?, validateDATAfterStart: Bool) async -> Bool {
    if livePhoneAudioSessionActive {
      liveAudioCaptureReadyForVision = true
      AppLogger.log(.audio, "Live iPhone audio already active; reusing capture reason=\(reason)")
      return true
    }

    resetPostSessionAttributionState()
    lastWearerVoiceSimilarity = 0
    wearerVoiceSimilarityStatusText = "Wearer: not checked"
    workerVoiceSimilarityStatusText = "AWS canonical: disabled"
    let conversationDeviceId = UIDevice.current.identifierForVendor?.uuidString
    let conversationDATDeviceId = datDeviceId

    configureLiveAudioBufferHandling(reason: reason)

    startLiveTranscriptionForStream(reason: reason)
    liveStreamSessionActivated = true
    livePhoneAudioSessionActive = true
    let audioStart = Date()
    streamAudioStart = isDATAnalysisPaused ? nil : audioStart
    postSessionLocalTranscriptSegments = []
    speakerTimeline = []
    cloudDiarizationState = isDATAnalysisPaused ? .idle : .recording
    AppLogger.log(.stream, "Starting live iPhone audio capture reason=\(reason)")
    if !isDATAnalysisPaused {
      audioRecorder.start()
    }
    let audioStarted = await speechManager.start(audioSource: .iPhone)
    guard audioStarted else {
      let droppedURL = audioRecorder.stop()
      if let droppedURL {
        try? FileManager.default.removeItem(at: droppedURL)
      }
      await stopCloudSpeakerWorkerForStream(reason: "audioStartFailed-\(reason)")
      await stopCloudFaceWorkerForStream(reason: "audioStartFailed-\(reason)")
      cloudDiarizationState = .failed("Could not start iPhone audio capture")
      liveStreamSessionActivated = false
	      livePhoneAudioSessionActive = false
	      liveAudioCaptureReadyForVision = false
	      speechManager.onAudioBuffer = nil
	      stopLiveTranscriptionForStream()
	      streamAudioStart = nil
      return false
    }

    if validateDATAfterStart, let blocker = datActivationReadinessBlocker(at: Date()) {
      AppLogger.log(.stream, "Stopping live audio immediately because DAT is not activation-ready during audio start. reason=\(reason), blocker=\(blocker), stream=\(datStreamSessionStateText), deviceSession=\(datDeviceSessionStateText), device=\(datSelectedDeviceIDText), isStreamRunning=\(datIsStreamRunning)")
      await deactivateLiveStreamSessionIfNeeded(reason: "datStoppedDuringAudioStart-\(reason)")
      return false
    }

    liveAudioCaptureReadyForVision = true
    startCloudWorkersForStream(reason: reason, includeSpeaker: liveVoiceEmbeddingEnabled)
    UIApplication.shared.isIdleTimerDisabled = true
    AppLogger.log(.stream, "Live iPhone audio capture started; creating conversation metadata reason=\(reason)")

    let snapshot = await identityPipeline.startConversationSession(
      deviceId: conversationDeviceId,
      datDeviceId: conversationDATDeviceId
    )
    pipelineContext = await identityPipeline.currentContext()
    applyRunSessionSnapshot(snapshot)
    if validateDATAfterStart, let blocker = datActivationReadinessBlocker(at: Date()) {
      AppLogger.log(.stream, "Canceling live session after conversation setup because DAT is not activation-ready. reason=\(reason), blocker=\(blocker), stream=\(datStreamSessionStateText), deviceSession=\(datDeviceSessionStateText), device=\(datSelectedDeviceIDText), isStreamRunning=\(datIsStreamRunning)")
      await deactivateLiveStreamSessionIfNeeded(reason: "datStoppedAfterConversationSetup-\(reason)")
      return false
    }
    return true
  }

  private func activateLiveStreamSessionIfNeeded() async {
    guard !liveStreamSessionActivated else { return }
    if let activationBlocker = datActivationReadinessBlocker(at: Date()) {
      AppLogger.log(.stream, "Skipping live audio activation because DAT is not activation-ready. blocker=\(activationBlocker), stream=\(datStreamSessionStateText), deviceSession=\(datDeviceSessionStateText), device=\(datSelectedDeviceIDText), isStreamRunning=\(datIsStreamRunning)")
      return
    }
    guard livePhoneAudioCaptureEnabled else {
      liveStreamSessionActivated = true
      livePhoneAudioSessionActive = false
      activeSpeakerStateText = "disabled"
      activeSpeakerName = ""
      activeSpeakerPersonId = nil
      activeSpeakerSimilarity = 0
      voiceSpeechBufferSeconds = 0
      voiceMatchStatusText = "Live phone audio disabled"
      iPhoneVoiceSimilarityStatusText = "iPhone local estimate: live phone audio disabled"
      workerVoiceSimilarityStatusText = "AWS canonical: disabled"
      wearerVoiceSimilarityStatusText = "Wearer: live phone audio disabled"
      cloudDiarizationState = .idle
      microphoneStatusText = "Live phone audio disabled"
      liveAudioCaptureReadyForVision = true
      UIApplication.shared.isIdleTimerDisabled = true
      AppLogger.log(.stream, "Phone audio/conversation activation skipped because live phone audio is disabled")
      return
    }
    resetPostSessionAttributionState()
    lastWearerVoiceSimilarity = 0
    wearerVoiceSimilarityStatusText = "Wearer: not checked"
    workerVoiceSimilarityStatusText = "AWS canonical: disabled"
    let conversationDeviceId = UIDevice.current.identifierForVendor?.uuidString
    let conversationDATDeviceId = datSelectedDeviceIDText == "None" ? nil : datSelectedDeviceIDText

    configureLiveAudioBufferHandling(reason: "afterDATStreamStart")
    startLiveTranscriptionForStream(reason: "afterDATStreamStart")
    liveStreamSessionActivated = true
    livePhoneAudioSessionActive = true
    // Start cloud diarization audio recorder
    let audioStart = Date()
    streamAudioStart = isDATAnalysisPaused ? nil : audioStart
    postSessionLocalTranscriptSegments = []
    speakerTimeline = []
    cloudDiarizationState = isDATAnalysisPaused ? .idle : .recording
    AppLogger.log(.stream, "Starting live iPhone audio before conversation metadata to avoid blocking DAT startup")
    if !isDATAnalysisPaused {
      audioRecorder.start()
    }
    let audioStarted = await speechManager.start(audioSource: audioSource)
    guard audioStarted else {
      let droppedURL = audioRecorder.stop()
      if let droppedURL {
        try? FileManager.default.removeItem(at: droppedURL)
      }
      await stopCloudSpeakerWorkerForStream(reason: "audioStartFailed")
      await stopCloudFaceWorkerForStream(reason: "audioStartFailed")
      cloudDiarizationState = .failed("Could not start \(audioSource.displayName) audio capture")
      liveStreamSessionActivated = false
	      livePhoneAudioSessionActive = false
	      liveAudioCaptureReadyForVision = false
	      speechManager.onAudioBuffer = nil
	      stopLiveTranscriptionForStream()
	      streamAudioStart = nil
      return
    }
    if Task.isCancelled {
      AppLogger.log(.stream, "Stopping live audio immediately because activation task was canceled. stream=\(datStreamSessionStateText), deviceSession=\(datDeviceSessionStateText), device=\(datSelectedDeviceIDText), isStreamRunning=\(datIsStreamRunning)")
      await deactivateLiveStreamSessionIfNeeded(reason: "datStoppedDuringAudioStart")
      return
    }
    if let activationBlocker = datActivationReadinessBlocker(at: Date()) {
      AppLogger.log(.stream, "Stopping live audio immediately because DAT is not activation-ready during audio start. blocker=\(activationBlocker), stream=\(datStreamSessionStateText), deviceSession=\(datDeviceSessionStateText), device=\(datSelectedDeviceIDText), isStreamRunning=\(datIsStreamRunning)")
      await deactivateLiveStreamSessionIfNeeded(reason: "datStoppedDuringAudioStart")
      return
    }
    liveAudioCaptureReadyForVision = true
    startCloudWorkersForStream(reason: "afterDATStreamStart", includeSpeaker: liveVoiceEmbeddingEnabled)
    UIApplication.shared.isIdleTimerDisabled = true
    AppLogger.log(.stream, "Live audio started; creating conversation metadata")

    let snapshot = await identityPipeline.startConversationSession(
      deviceId: conversationDeviceId,
      datDeviceId: conversationDATDeviceId
    )
    pipelineContext = await identityPipeline.currentContext()
    applyRunSessionSnapshot(snapshot)
    if Task.isCancelled {
      AppLogger.log(.stream, "Canceling live session after conversation setup because activation task was canceled. stream=\(datStreamSessionStateText), deviceSession=\(datDeviceSessionStateText), device=\(datSelectedDeviceIDText), isStreamRunning=\(datIsStreamRunning)")
      await identityPipeline.endConversation()
      pipelineContext = await identityPipeline.currentContext()
      applyRunSessionSnapshot(await identityPipeline.currentRunSessionSnapshot())
      await deactivateLiveStreamSessionIfNeeded(reason: "datStoppedAfterConversationSetup")
      return
    }
    if let conversationBlocker = datActivationReadinessBlocker(at: Date()) {
      AppLogger.log(.stream, "Canceling live session after conversation setup because DAT is not activation-ready. blocker=\(conversationBlocker), stream=\(datStreamSessionStateText), deviceSession=\(datDeviceSessionStateText), device=\(datSelectedDeviceIDText), isStreamRunning=\(datIsStreamRunning)")
      await identityPipeline.endConversation()
      pipelineContext = await identityPipeline.currentContext()
      applyRunSessionSnapshot(await identityPipeline.currentRunSessionSnapshot())
      await deactivateLiveStreamSessionIfNeeded(reason: "datStoppedAfterConversationSetup")
      return
    }
    AppLogger.log(.stream, "DAT stream is streaming; live audio and conversation session activated")
  }

  private var canActivateLiveAudioSession: Bool {
    datActivationReadinessBlocker(at: Date()) == nil
  }

  private func datStreamLivenessBlocker() -> String? {
    guard datStreamSessionStateText.lowercased().contains("streaming") else {
      return "DAT StreamSession state=\(datStreamSessionStateText)"
    }
    guard datIsStreamRunning else {
      return "DAT isStreamRunning=false"
    }
    guard datSelectedDeviceIDText != "None" else {
      return "waiting for active DAT device"
    }
    guard datDeviceSessionStateText.lowercased().contains("started") else {
      return "DAT DeviceSession state=\(datDeviceSessionStateText)"
    }
    return nil
  }

  private func datActivationReadinessBlocker(at now: Date) -> String? {
    if let blocker = datStreamLivenessBlocker() {
      return blocker
    }
    guard datFramesWithPixelBuffer > 0, liveDATFirstFrameAt != nil else {
      return "waiting for first DAT video frame"
    }
    let delayRemaining = liveDATHeavyWorkDelayRemaining(at: now)
    if delayRemaining > 0 {
      return String(format: "app-side startup delay %.1fs", Double(delayRemaining))
    }
    return nil
  }

  private func datVisionReadinessBlocker(at now: Date) -> String? {
    if let blocker = datStreamLivenessBlocker() {
      return blocker
    }
    guard datFramesWithPixelBuffer > 0, liveDATLastFrameAt != nil else {
      return "waiting for first DAT video frame"
    }
    let delayRemaining = liveDATVisionDelayRemaining(at: now)
    if delayRemaining > 0 {
      return String(format: "vision startup delay %.1fs", Double(delayRemaining))
    }
    if !liveAudioCaptureReadyForVision {
      return "waiting for live audio startup"
    }
    return nil
  }

  private func liveDATHeavyWorkDelayRemaining(at now: Date) -> TimeInterval {
    guard let liveDATFirstFrameAt else { return .infinity }
    return max(0, liveDATHeavyWorkStartupDelaySeconds - now.timeIntervalSince(liveDATFirstFrameAt))
  }

  private func liveDATVisionDelayRemaining(at now: Date) -> TimeInterval {
    guard let liveDATFirstFrameAt else { return .infinity }
    return max(0, liveDATVisionStartupDelaySeconds - now.timeIntervalSince(liveDATFirstFrameAt))
  }

  nonisolated static func shouldSubmitSceneContextForLiveDATFrame(
    previewImageAvailable: Bool,
    isDATAnalysisPaused: Bool,
    frameAccepted: Bool
  ) -> Bool {
    previewImageAvailable && !isDATAnalysisPaused && frameAccepted
  }

  nonisolated static func shouldEncodeSceneContextFromPixelBuffer(
    sceneContextEnabled: Bool,
    isDATAnalysisPaused: Bool,
    frameAccepted: Bool,
    captureDue: Bool,
    encodingInFlight: Bool
  ) -> Bool {
    sceneContextEnabled
      && !isDATAnalysisPaused
      && frameAccepted
      && captureDue
      && !encodingInFlight
  }

  nonisolated static func shouldAcceptLiveDATFrameForAnalysis(
    streamStateText: String,
    datIsStreamRunning: Bool,
    terminalVisionInvalidated: Bool
  ) -> Bool {
    guard !terminalVisionInvalidated else { return false }
    let normalizedState = streamStateText.lowercased()
    guard normalizedState.contains("streaming"), datIsStreamRunning else { return false }
    return !normalizedState.contains("stopping") && !normalizedState.contains("stopped")
  }

  nonisolated static func shouldInvalidateLiveDATVisionWorkOnTerminalState(
    liveStreamSessionActivated: Bool,
    livePhoneAudioSessionActive: Bool,
    liveDATStreamingStarted: Bool,
    hasReceivedFrame: Bool,
    datFramesReceived: UInt64,
    datFramesWithPixelBuffer: UInt64,
    pendingVisionImageAvailable: Bool,
    liveAudioCaptureReadyForVision: Bool
  ) -> Bool {
    liveStreamSessionActivated
      || livePhoneAudioSessionActive
      || liveDATStreamingStarted
      || hasReceivedFrame
      || datFramesReceived > 0
      || datFramesWithPixelBuffer > 0
      || pendingVisionImageAvailable
      || liveAudioCaptureReadyForVision
  }

  nonisolated static func shouldContinueCloudFaceWarmupAfterInitialHealthMiss(
    useEC2Lifecycle: Bool,
    inputMode: InputMode
  ) -> Bool {
    useEC2Lifecycle || inputMode == .realGlasses
  }

  nonisolated static func shouldContinueCloudFaceWarmupAfterInitialHealthMiss(
    useEC2Lifecycle: Bool,
    inputMode: InputMode,
    error: Error
  ) -> Bool {
    guard shouldContinueCloudFaceWarmupAfterInitialHealthMiss(
      useEC2Lifecycle: useEC2Lifecycle,
      inputMode: inputMode
    ) else {
      return false
    }
    return !isCloudFaceHealthTimeout(error)
  }

  nonisolated static func isCloudFaceHealthTimeout(_ error: Error) -> Bool {
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorTimedOut {
      return true
    }
    let description = error.localizedDescription.lowercased()
    return description.contains("timed out")
      || description.contains("code=-1001")
      || description.contains("nsurlerrordomain")
  }

  nonisolated static func cloudFaceWarmupRetryDelaySeconds(attempt: Int) -> TimeInterval {
    let normalizedAttempt = max(2, attempt)
    return min(15, 5 + TimeInterval(normalizedAttempt - 2) * 2)
  }

  nonisolated static func cloudFaceWarmupRetryLimit(inputMode: InputMode) -> Int {
    inputMode == .realGlasses ? 6 : 24
  }

  nonisolated private static func cloudFaceWarmupRetryCadenceText(maxAttempts: Int) -> String {
    "5-15s capped maxAttempts=\(maxAttempts)"
  }

  nonisolated private static func waitForCloudFaceWorkerReadinessDuringStream(
    lifecycle: CloudFaceEmbeddingLifecycleService,
    endpoint: String,
    apiKey: String,
    initialError: Error,
    initialAttemptCount: Int,
    inputMode: InputMode
  ) async throws -> CloudFaceWarmupHealthResult {
    let maxAttempts = cloudFaceWarmupRetryLimit(inputMode: inputMode)
    let cadence = cloudFaceWarmupRetryCadenceText(maxAttempts: maxAttempts)
    var lastError = initialError.localizedDescription
    AppLogger.log(
      .faceEmbeddingModel,
      "AWS live face worker warmup continuing in background endpoint=\(endpoint) healthAttempts=\(initialAttemptCount) retryCadence=\(cadence) providerState=localMobileFaceNet fallback=localMobileFaceNet error=\(lastError)"
    )
    guard initialAttemptCount < maxAttempts else {
      throw CloudFaceEmbeddingLifecycleError.workerNotReady(lastError)
    }

    for attempt in (initialAttemptCount + 1)...maxAttempts {
      let delay = cloudFaceWarmupRetryDelaySeconds(attempt: attempt)
      try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      do {
        let health = try await lifecycle.checkWorkerHealthOnce(endpoint: endpoint, apiKey: apiKey, timeout: 2)
        AppLogger.log(
          .faceEmbeddingModel,
          "AWS live face worker ready attempt=\(attempt) endpoint=\(endpoint) health=\(health) retryCadence=\(cadence) providerState=localMobileFaceNet"
        )
        return CloudFaceWarmupHealthResult(health: health, attempts: attempt, retryCadence: cadence)
      } catch {
        lastError = error.localizedDescription
        let shouldLog = attempt <= 3 || attempt % 3 == 0 || attempt == maxAttempts
        if shouldLog {
          AppLogger.log(
            .faceEmbeddingModel,
            "AWS live face worker still warming attempt=\(attempt)/\(maxAttempts) endpoint=\(endpoint) retryCadence=\(cadence) providerState=localMobileFaceNet fallback=localMobileFaceNet error=\(lastError)"
          )
        }
      }
    }

    throw CloudFaceEmbeddingLifecycleError.workerNotReady(lastError)
  }

  nonisolated static func shouldPublishLiveDisplayAfterNoConfirmedPerson(
    datIsStreamRunning: Bool,
    streamStateText: String
  ) -> Bool {
    datIsStreamRunning && streamStateText.lowercased().contains("streaming")
  }

  nonisolated static func shouldSendRemainingDisplayAfterClear(
    datIsStreamRunning: Bool,
    streamStateText: String,
    activeWindowIsLive: Bool
  ) -> Bool {
    if !activeWindowIsLive { return true }
    return shouldPublishLiveDisplayAfterNoConfirmedPerson(
      datIsStreamRunning: datIsStreamRunning,
      streamStateText: streamStateText
    )
  }

  nonisolated static func isDATTerminalState(_ stateText: String) -> Bool {
    let normalizedState = stateText.lowercased()
    return normalizedState.contains("stopping") || normalizedState.contains("stopped")
  }

  nonisolated static func shouldRenderPhonePreviewForLiveDAT(
    phonePreviewEnabled: Bool,
    forceTestFaceOverlay: Bool
  ) -> Bool {
    forceTestFaceOverlay || phonePreviewEnabled
  }

  nonisolated static func isUnavailableFaceEmbeddingDecision(_ matchDecisionText: String) -> Bool {
    switch matchDecisionText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "modelmissing", "embeddingmodelmissing", "embeddingfailed", "embeddingdisabled":
      return true
    default:
      return false
    }
  }

  nonisolated static func shouldShowFaceRecognitionUnavailableStatus(
    faceCandidateCount: Int,
    qualityPassCount: Int,
    embeddingGenerated: Bool,
    matchDecisionText: String
  ) -> Bool {
    faceCandidateCount > 0
      && qualityPassCount > 0
      && !embeddingGenerated
      && isUnavailableFaceEmbeddingDecision(matchDecisionText)
  }

  nonisolated static func isCloudFaceRecognitionWarmingStatus(_ modelStatusText: String) -> Bool {
    let normalizedStatus = modelStatusText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalizedStatus.contains("adaface")
      && (
        normalizedStatus.contains("starting")
          || normalizedStatus.contains("warming")
          || normalizedStatus.contains("worker is ready")
      )
  }

  nonisolated static func shouldAskToConfirmUnknownIdentity(
    activeIdentityState: ActiveIdentityState.State,
    isUnknownPersonVisible: Bool,
    embeddingGenerated: Bool,
    matchDecisionText: String
  ) -> Bool {
    guard embeddingGenerated else { return false }
    guard !isUnavailableFaceEmbeddingDecision(matchDecisionText) else { return false }
    return activeIdentityState == .unknown || isUnknownPersonVisible
  }

  nonisolated static func shouldAskToConfirmRecognizedIdentity(
    activeIdentityState: ActiveIdentityState.State,
    personId: UUID?,
    embeddingGenerated: Bool,
    matchDecisionText: String
  ) -> Bool {
    guard personId != nil else { return false }
    guard embeddingGenerated else { return activeIdentityState == .confirmed }
    guard !isUnavailableFaceEmbeddingDecision(matchDecisionText) else { return false }
    return activeIdentityState == .possible || activeIdentityState == .confirmed
  }

  @discardableResult
  private func markLiveDATFrameArrived(at now: Date) -> Bool {
    guard inputMode == .realGlasses else { return true }
    if liveDATFirstFrameAt == nil {
      liveDATFirstFrameAt = now
    }
    liveDATLastFrameAt = now
    return true
  }

  private func shouldAcceptLiveDATFrameForAnalysis() -> Bool {
    Self.shouldAcceptLiveDATFrameForAnalysis(
      streamStateText: datStreamSessionStateText,
      datIsStreamRunning: datIsStreamRunning,
      terminalVisionInvalidated: liveDATTerminalVisionInvalidated
    )
  }

  private func shouldInvalidateLiveDATVisionWorkOnTerminalState() -> Bool {
    Self.shouldInvalidateLiveDATVisionWorkOnTerminalState(
      liveStreamSessionActivated: liveStreamSessionActivated,
      livePhoneAudioSessionActive: livePhoneAudioSessionActive,
      liveDATStreamingStarted: liveDATStreamingStartedAt != nil,
      hasReceivedFrame: hasReceivedFirstFrame || liveDATFirstFrameAt != nil || liveDATLastFrameAt != nil,
      datFramesReceived: datFramesReceived,
      datFramesWithPixelBuffer: datFramesWithPixelBuffer,
      pendingVisionImageAvailable: pendingVisionImage != nil,
      liveAudioCaptureReadyForVision: liveAudioCaptureReadyForVision
    )
  }

  private func invalidateLiveDATVisionWork(reason: String) {
    guard inputMode == .realGlasses else { return }
    guard !liveDATTerminalVisionInvalidated else { return }
    liveDATTerminalVisionInvalidated = true
    visionGeneration &+= 1
    pendingVisionImage = nil
    liveAudioCaptureReadyForVision = false
    AppLogger.log(
      .facePipelineStop,
      "warning...---- reason=\(reason) invalidated live DAT vision work generation=\(visionGeneration) stream=\(datStreamSessionStateText) deviceSession=\(datDeviceSessionStateText)"
    )
  }

  private func markFirstRealGlassesFrameIfNeeded(reason: String) {
    guard !hasReceivedFirstFrame else { return }
    hasReceivedFirstFrame = true
    showGlassesStreamingDashboard(reason: reason)
  }

  private func activateLiveStreamSessionAfterFirstFrameIfReady() {
    guard liveStreamActivationTask == nil else { return }
    guard !liveStreamSessionActivated else { return }
    guard datStreamSessionStateText.lowercased().contains("streaming") else { return }
    guard datFramesWithPixelBuffer > 0 else {
      AppLogger.log(.stream, "Waiting for first DAT video frame before app-side stream activation")
      return
    }
    let delay = liveDATHeavyWorkDelayRemaining(at: Date())
    liveStreamActivationTask = Task { @MainActor [weak self] in
      guard let self else { return }
      if delay.isFinite, delay > 0 {
        AppLogger.log(.stream, "Delaying app-side stream activation for \(String(format: "%.1f", Double(delay)))s after first DAT video frame")
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      }
      guard !Task.isCancelled else {
        self.liveStreamActivationTask = nil
        return
      }
      await self.activateLiveStreamSessionIfNeeded()
      self.liveStreamActivationTask = nil
    }
  }

  private func startCloudWorkersForStream(reason: String, includeSpeaker: Bool) {
    guard !isDATAnalysisPaused else {
      deferredCloudWorkerStartTask?.cancel()
      deferredCloudWorkerStartTask = nil
      cloudFaceEmbeddingStatusText = "AWS AdaFace paused"
      cloudSpeakerEmbeddingStatusText = "AWS canonical speaker paused"
      workerVoiceSimilarityStatusText = "AWS canonical: analysis paused"
      Task {
        await identityPipeline.disableCloudFaceEmbedding(reason: "analysisPaused-\(reason)")
        await speakerPipeline.disableWorkerEmbedding(reason: "analysisPaused-\(reason)")
      }
      AppLogger.log(.stream, "Skipped cloud analysis workers because Pause analysis is enabled reason=\(reason)")
      return
    }
    let shouldDeferForDATWarmup = inputMode == .realGlasses || reason.contains("DAT")
    guard shouldDeferForDATWarmup else {
      if includeSpeaker {
        startCloudSpeakerWorkerForStream()
      }
      prepareCloudFaceWorkerForFaceTriggeredStart(reason: reason)
      return
    }

    let speakerSettings = CloudSpeakerEmbeddingSettings.load()
    let deferSpeaker = includeSpeaker && speakerSettings.enabled
    prepareCloudFaceWorkerForFaceTriggeredStart(reason: reason)

    if includeSpeaker, !speakerSettings.enabled {
      startCloudSpeakerWorkerForStream()
    }
    guard deferSpeaker else { return }

    deferredCloudWorkerStartTask?.cancel()
    if deferSpeaker {
      cloudSpeakerEmbeddingEnabled = true
      cloudSpeakerEmbeddingEndpointText = speakerSettings.endpoint
      cloudSpeakerEmbeddingAPIKeyText = speakerSettings.apiKey
      cloudSpeakerEmbeddingStatusText = "AWS canonical speaker deferred until DAT is stable"
      workerVoiceSimilarityStatusText = "AWS canonical: deferred"
    }
    AppLogger.log(.stream, "Deferred AWS live speaker worker for DAT warmup reason=\(reason) delaySeconds=45; face lease waits for valid face candidate=true")

    deferredCloudWorkerStartTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 45_000_000_000)
      guard !Task.isCancelled, let self else { return }
      guard !self.isDATAnalysisPaused else {
        AppLogger.log(.stream, "Skipped deferred AWS live embedding workers because Pause analysis is enabled")
        return
      }
      guard self.datStreamSessionStateText.lowercased().contains("streaming") else {
        AppLogger.log(.stream, "Skipped deferred AWS live embedding workers because DAT stream is \(self.datStreamSessionStateText)")
        return
      }
      if deferSpeaker {
        self.startCloudSpeakerWorkerForStream()
      }
    }
  }

  private func prepareCloudFaceWorkerForFaceTriggeredStart(reason: String) {
    let settings = CloudFaceEmbeddingLifecycleSettings.load()
    isLoadingCloudEmbeddingSettings = true
    cloudFaceEmbeddingEnabled = settings.enabled
    isLoadingCloudEmbeddingSettings = false
    cloudFaceWorkerStartedAfterFaceCandidate = false

    guard settings.enabled else {
      cloudFaceEmbeddingStatusText = "Cloud face embedding off"
      Task { await identityPipeline.disableCloudFaceEmbedding(reason: "settingsDisabled") }
      AppLogger.log(.faceEmbeddingModel, "AWS AdaFace not started reason=\(reason) gate=settingsDisabled")
      return
    }

    cloudFaceEmbeddingStatusText = "AWS AdaFace idle until face detected"
    Task { await identityPipeline.disableCloudFaceEmbedding(reason: "waitingForValidFace-\(reason)") }
    AppLogger.log(.faceEmbeddingModel, "AWS AdaFace start deferred reason=\(reason) gate=waitingForValidFaceCandidate")
  }

  private func startCloudFaceWorkerForValidFaceCandidateIfNeeded(reason: String) {
    guard !cloudFaceWorkerStartedAfterFaceCandidate else { return }
    guard cloudFaceLifecycleTask == nil else { return }
    let settings = CloudFaceEmbeddingLifecycleSettings.load()
    guard settings.enabled else { return }
    cloudFaceWorkerStartedAfterFaceCandidate = true
    let target = settings.endpointOverride.isEmpty ? "EC2-discovery" : settings.endpointOverride
    AppLogger.log(
      .faceEmbeddingModel,
      "AWS AdaFace starting after valid face candidate reason=\(reason) target=\(target) port=\(settings.workerPort) healthAttempts=1 fallback=localMobileFaceNet"
    )
    startCloudFaceWorkerForStream()
  }

  private func startCloudSpeakerWorkerForStream() {
    let settings = CloudSpeakerEmbeddingSettings.load()
    isLoadingCloudEmbeddingSettings = true
    cloudSpeakerEmbeddingEnabled = settings.enabled
    cloudSpeakerEmbeddingEndpointText = settings.endpoint
    cloudSpeakerEmbeddingAPIKeyText = settings.apiKey
    isLoadingCloudEmbeddingSettings = false

    guard settings.enabled else {
      cloudSpeakerEmbeddingStatusText = "AWS canonical speaker embeddings off"
      workerVoiceSimilarityStatusText = "AWS canonical: disabled"
      Task { await speakerPipeline.disableWorkerEmbedding(reason: "settingsDisabled") }
      return
    }

    cloudSpeakerLifecycleTask?.cancel()
    cloudSpeakerHeartbeatTask?.cancel()
    cloudSpeakerHeartbeatTask = nil
    cloudSpeakerEmbeddingStatusText = settings.useEC2Lifecycle
      ? "AWS canonical speaker starting EC2..."
      : "AWS canonical speaker warming worker..."
    workerVoiceSimilarityStatusText = "AWS canonical: starting"
    let lifecycle = cloudSpeakerLifecycleService
    let pipeline = speakerPipeline
    let localParakeetSelected = AlibabaTranscriptionSettings.load().provider == .localParakeet
    let maxHealthAttempts = inputMode == .realGlasses && localParakeetSelected ? 1 : (inputMode == .realGlasses ? 60 : 24)
    let healthPurpose = "speakerEmbeddingNotASR"
    AppLogger.log(
      .stream,
      "[AWS_SPEAKER_HEALTH] service=\(healthPurpose) endpoint=\(settings.endpoint.isEmpty ? "EC2-discovery:\(settings.workerPort)" : settings.endpoint) maxAttempts=\(maxHealthAttempts) localASRProvider=\(localParakeetSelected ? "parakeet" : "cloud")"
    )
    AppLogger.log(
      .speakerEmbeddingModel,
      "AWS live speaker startup target=\(settings.endpoint) port=\(settings.workerPort) maxHealthAttempts=\(maxHealthAttempts) retryCadence=\(CloudSpeakerEmbeddingLifecycleService.workerHealthRetryCadenceText(maxAttempts: maxHealthAttempts)) fallback=localSpeakerPipeline"
    )
    cloudSpeakerLifecycleTask = Task { [weak self] in
      await pipeline.markWorkerEmbeddingStarting()
      do {
        let result = try await lifecycle.startAndWarm(
          settings: settings,
          maxHealthAttempts: maxHealthAttempts
        )
        guard !Task.isCancelled else { return }
        await pipeline.configureWorkerEmbedding(endpoint: result.endpoint, apiKey: result.apiKey)
        // The worker is now reachable — finish any diarized enrollments that
        // were left pending because the embedding service was unavailable.
        await self?.completePendingSpeakerEmbeddingsIfPossible(reason: "workerReady")
        await MainActor.run { [weak self] in
          guard let self else { return }
          self.cloudSpeakerEmbeddingEndpointText = result.endpoint
          self.cloudSpeakerEmbeddingStatusText = "AWS canonical speaker ready \(result.publicIp ?? result.endpoint)"
          self.workerVoiceSimilarityStatusText = "AWS canonical: ready"
          self.startCloudSpeakerHeartbeatForStream()
          AppLogger.log(
            .speakerEmbeddingModel,
            "AWS canonical speaker ready endpoint=\(result.endpoint) publicIp=\(result.publicIp ?? "none") privateIp=\(result.privateIp ?? "none") health=\(result.healthStatus) session=\(result.liveSessionId ?? "none") expiresAt=\(result.liveExpiresAt ?? "unknown")"
          )
        }
      } catch {
        await pipeline.disableWorkerEmbedding(reason: "startFailed")
        await MainActor.run { [weak self] in
          guard let self else { return }
          self.cloudSpeakerEmbeddingStatusText = "AWS canonical speaker failed: \(error.localizedDescription)"
          self.workerVoiceSimilarityStatusText = "AWS canonical: unavailable"
          AppLogger.log(
            .speakerEmbeddingModel,
            "AWS live speaker start failed target=\(settings.endpoint) attempts=\(maxHealthAttempts) fallback=localSpeakerPipeline error=\(error.localizedDescription)"
          )
        }
      }
    }
  }

  private func stopCloudSpeakerWorkerForStream(reason: String, stopEC2: Bool = true) async {
    cloudSpeakerLifecycleTask?.cancel()
    cloudSpeakerLifecycleTask = nil
    cloudSpeakerHeartbeatTask?.cancel()
    cloudSpeakerHeartbeatTask = nil
    await speakerPipeline.disableWorkerEmbedding(reason: "streamStop-\(reason)")
    let settings = CloudSpeakerEmbeddingSettings.load()
    if stopEC2 {
      await cloudSpeakerLifecycleService.stopIfNeeded(settings: settings)
    } else {
      await cloudSpeakerLifecycleService.releaseLiveSessionWithoutStopping(reason: reason)
    }
    if settings.enabled {
      cloudSpeakerEmbeddingStatusText = "AWS canonical speaker stopped"
    }
    workerVoiceSimilarityStatusText = settings.enabled ? "AWS canonical: stopped" : "AWS canonical: disabled"
  }

  private func startCloudSpeakerHeartbeatForStream() {
    cloudSpeakerHeartbeatTask?.cancel()
    let lifecycle = cloudSpeakerLifecycleService
    cloudSpeakerHeartbeatTask = Task {
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 300_000_000_000)
        guard !Task.isCancelled else { return }
        await lifecycle.refreshLiveLeaseIfNeeded()
      }
    }
  }

  @MainActor
  private func completePendingSpeakerEmbeddingsIfPossible(reason: String) async {
    guard await speakerPipeline.pendingDiarizedEnrollmentCount() > 0 else { return }
    let completed = await speakerPipeline.retryPendingDiarizedEnrollments()
    guard !completed.isEmpty else { return }
    for id in completed {
      pendingVoiceEnrollmentPersonIds.remove(id)
      enrolledVoicePersonIds.insert(id)
    }
    voiceEnrollmentStatusText = "Pending voice enrollment completed."
    AppLogger.log(
      .speakerEnrollment,
      "[CloudDiarization] pending voice enrollments completed reason=\(reason) count=\(completed.count)"
    )
  }

  @MainActor
  private func schedulePendingSpeakerEmbeddingRetry(reason: String) {
    guard pendingSpeakerEmbeddingRetryTask == nil else {
      AppLogger.log(.speakerEnrollment, "[CloudDiarization] pending voice retry already scheduled reason=\(reason)")
      return
    }
    let pipeline = speakerPipeline
    pendingSpeakerEmbeddingRetryTask = Task { @MainActor [weak self] in
      defer { self?.pendingSpeakerEmbeddingRetryTask = nil }
      let maxAttempts = 6
      for attempt in 1...maxAttempts {
        guard !Task.isCancelled, let self else { return }
        guard await pipeline.pendingDiarizedEnrollmentCount() > 0 else { return }
        let delay = Self.pendingSpeakerEmbeddingRetryDelaySeconds(attempt: attempt)
        AppLogger.log(
          .speakerEnrollment,
          "[CloudDiarization] pending voice embedding retry scheduled attempt=\(attempt)/\(maxAttempts) delaySeconds=\(Int(delay)) reason=\(reason) state=speakerEmbeddingPending"
        )
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        guard !Task.isCancelled else { return }

        _ = await self.warmCloudSpeakerWorkerForPostStreamEnrollment(
          reason: "retry-\(attempt)-\(reason)"
        )

        await self.completePendingSpeakerEmbeddingsIfPossible(reason: "retry-\(attempt)-\(reason)")
        await self.cloudSpeakerLifecycleService.releaseLiveSessionWithoutStopping(
          reason: "postStreamEnrollment-\(reason)"
        )
        guard await pipeline.pendingDiarizedEnrollmentCount() > 0 else { return }
      }
      guard let self else { return }
      self.voiceEnrollmentStatusText = "Voice embedding pending; AWS speaker service still unavailable."
      AppLogger.log(
        .speakerEnrollment,
        "[CloudDiarization] pending voice embedding retry capped attempts=\(maxAttempts) state=speakerEmbeddingPending reason=\(reason)"
      )
    }
  }

  @MainActor
  private func warmCloudSpeakerWorkerForPostStreamEnrollment(reason: String) async -> Bool {
    let settings = CloudSpeakerEmbeddingSettings.load()
    guard settings.enabled else {
      voiceEnrollmentStatusText = "Voice embedding unavailable because the AWS speaker service is disabled."
      AppLogger.log(
        .speakerEnrollment,
        "[CloudDiarization] post-stream speaker worker skipped reason=settingsDisabled trigger=\(reason)"
      )
      return false
    }

    cloudSpeakerEmbeddingStatusText = "AWS canonical speaker warming for post-stream enrollment..."
    workerVoiceSimilarityStatusText = "AWS canonical: postStreamWarming"
    await speakerPipeline.markWorkerEmbeddingStarting()
    do {
      let result = try await cloudSpeakerLifecycleService.startAndWarm(
        settings: settings,
        maxHealthAttempts: 6
      )
      await speakerPipeline.configureWorkerEmbedding(endpoint: result.endpoint, apiKey: result.apiKey)
      cloudSpeakerEmbeddingEndpointText = result.endpoint
      cloudSpeakerEmbeddingStatusText = "AWS canonical speaker ready for post-stream enrollment"
      workerVoiceSimilarityStatusText = "AWS canonical: postStreamReady"
      AppLogger.log(
        .speakerEnrollment,
        "[CloudDiarization] post-stream speaker worker ready trigger=\(reason) endpoint=\(result.endpoint) health=\(result.healthStatus)"
      )
      return true
    } catch {
      await speakerPipeline.disableWorkerEmbedding(reason: "postStreamWarmupFailed")
      await cloudSpeakerLifecycleService.releaseLiveSessionWithoutStopping(
        reason: "postStreamWarmupFailed-\(reason)"
      )
      cloudSpeakerEmbeddingStatusText = "AWS canonical speaker unavailable for post-stream enrollment"
      workerVoiceSimilarityStatusText = "AWS canonical: postStreamUnavailable"
      AppLogger.log(
        .speakerEnrollment,
        "[CloudDiarization] post-stream speaker worker unavailable trigger=\(reason) error=\(error.localizedDescription)"
      )
      return false
    }
  }

  nonisolated static func pendingSpeakerEmbeddingRetryDelaySeconds(attempt: Int) -> TimeInterval {
    switch attempt {
    case ...1: return 5
    case 2: return 10
    default: return 20
    }
  }

  private func startCloudFaceWorkerForStream() {
    let settings = CloudFaceEmbeddingLifecycleSettings.load()
    isLoadingCloudEmbeddingSettings = true
    cloudFaceEmbeddingEnabled = settings.enabled
    isLoadingCloudEmbeddingSettings = false

    guard settings.enabled else {
      cloudFaceEmbeddingStatusText = "Cloud face embedding off"
      Task { await identityPipeline.disableCloudFaceEmbedding(reason: "settingsDisabled") }
      return
    }

    if shouldStartCloudFaceLeaseOnly(settings: settings) {
      startCloudFaceWorkerLeaseOnlyForStream(settings: settings)
      return
    }

    cloudFaceLifecycleTask?.cancel()
    cloudFaceHeartbeatTask?.cancel()
    cloudFaceHeartbeatTask = nil
    cloudFaceEmbeddingStatusText = settings.useEC2Lifecycle
      ? "AWS AdaFace starting EC2..."
      : "AWS AdaFace warming worker..."
    let lifecycle = cloudFaceLifecycleService
    let pipeline = identityPipeline
    cloudFaceLifecycleTask = Task { [weak self] in
      await pipeline.markCloudFaceEmbeddingStarting()
      do {
        let result = try await lifecycle.startAndWarm(settings: settings)
        guard !Task.isCancelled else { return }
        await pipeline.configureCloudFaceEmbedding(endpoint: result.endpoint, apiKey: result.apiKey)
        await MainActor.run { [weak self] in
          guard let self else { return }
          self.cloudFaceEmbeddingEndpointText = result.endpoint
          self.cloudFaceEmbeddingStatusText = "AWS AdaFace ready \(result.publicIp ?? result.endpoint)"
          self.startCloudFaceHeartbeatForStream()
          AppLogger.log(
            .faceEmbeddingModel,
            "AWS live face ready endpoint=\(result.endpoint) publicIp=\(result.publicIp ?? "none") privateIp=\(result.privateIp ?? "none") health=\(result.healthStatus) session=\(result.liveSessionId ?? "none") expiresAt=\(result.liveExpiresAt ?? "unknown")"
          )
          Task { @MainActor in
            self.faceEmbeddingModelStatusText = await self.identityPipeline.embeddingModelStatusText()
          }
        }
      } catch {
        await pipeline.disableCloudFaceEmbedding(reason: "startFailed")
        await MainActor.run { [weak self] in
          guard let self else { return }
          self.cloudFaceEmbeddingStatusText = "AWS AdaFace failed: \(error.localizedDescription)"
          AppLogger.log(.faceEmbeddingModel, "AWS live face start failed: \(error.localizedDescription)")
        }
      }
    }
  }

  private func shouldStartCloudFaceLeaseOnly(settings: CloudFaceEmbeddingLifecycleSettings) -> Bool {
    settings.useEC2Lifecycle && inputMode == .realGlasses
  }

  private func startCloudFaceWorkerLeaseOnlyForStream(settings: CloudFaceEmbeddingLifecycleSettings) {
    cloudFaceLifecycleTask?.cancel()
    cloudFaceHeartbeatTask?.cancel()
    cloudFaceHeartbeatTask = nil
    cloudFaceEmbeddingStatusText = "AWS AdaFace starting in background; local face fallback active"
    let lifecycle = cloudFaceLifecycleService
    let pipeline = identityPipeline
    let inputModeAtStart = inputMode
    cloudFaceLifecycleTask = Task { [weak self] in
      await pipeline.markCloudFaceEmbeddingStarting()
      do {
        let result = try await lifecycle.startLeaseOnly(settings: settings)
        guard !Task.isCancelled else { return }
        guard let endpoint = result.endpoint else {
          await MainActor.run { [weak self] in
            guard let self else { return }
            self.cloudFaceEmbeddingStatusText = "AWS AdaFace EC2 starting; local face fallback active"
            AppLogger.log(
              .faceEmbeddingModel,
              "AWS live face lease started without public endpoint yet session=\(result.liveSessionId ?? "none") expiresAt=\(result.liveExpiresAt ?? "unknown")"
            )
          }
          return
        }

        await MainActor.run { [weak self] in
          self?.cloudFaceEmbeddingEndpointText = endpoint
        }

        do {
          let warmupResult: CloudFaceWarmupHealthResult
          do {
            let health = try await lifecycle.checkWorkerHealthOnce(endpoint: endpoint, apiKey: result.apiKey, timeout: 2)
            warmupResult = CloudFaceWarmupHealthResult(
              health: health,
              attempts: 1,
              retryCadence: "initial-only"
            )
          } catch {
            guard Self.shouldContinueCloudFaceWarmupAfterInitialHealthMiss(
              useEC2Lifecycle: settings.useEC2Lifecycle,
              inputMode: inputModeAtStart,
              error: error
            ) else {
              AppLogger.log(
                .faceEmbeddingModel,
                "AWS live face worker missed initial health probe; selecting local fallback without background retry endpoint=\(endpoint) healthAttempts=1 retryCadence=none providerState=localMobileFaceNet fallback=localMobileFaceNet error=\(error.localizedDescription)"
              )
              throw error
            }
            await MainActor.run { [weak self] in
              guard let self else { return }
              self.cloudFaceEmbeddingStatusText = "AWS AdaFace warming; waiting for worker"
              AppLogger.log(
                .faceEmbeddingModel,
                "AWS live face worker missed initial health probe; continuing background warmup endpoint=\(endpoint) error=\(error.localizedDescription)"
              )
            }
            warmupResult = try await Self.waitForCloudFaceWorkerReadinessDuringStream(
              lifecycle: lifecycle,
              endpoint: endpoint,
              apiKey: result.apiKey,
              initialError: error,
              initialAttemptCount: 1,
              inputMode: inputModeAtStart
            )
          }
          guard !Task.isCancelled else { return }
          await pipeline.configureCloudFaceEmbedding(endpoint: endpoint, apiKey: result.apiKey)
          await MainActor.run { [weak self] in
            guard let self else { return }
            self.cloudFaceEmbeddingStatusText = "AWS AdaFace ready \(result.publicIp ?? endpoint)"
            self.startCloudFaceHeartbeatForStream()
            AppLogger.log(
              .faceEmbeddingModel,
              "AWS AdaFace worker ready; switching embedding provider from localMobileFaceNet to awsAdaFace endpoint=\(endpoint) publicIp=\(result.publicIp ?? "none") privateIp=\(result.privateIp ?? "none") health=\(warmupResult.health) healthAttempts=\(warmupResult.attempts) retryCadence=\(warmupResult.retryCadence) session=\(result.liveSessionId ?? "none") expiresAt=\(result.liveExpiresAt ?? "unknown")"
            )
            Task { @MainActor in
              self.faceEmbeddingModelStatusText = await self.identityPipeline.embeddingModelStatusText()
            }
          }
        } catch {
          await MainActor.run { [weak self] in
            guard let self else { return }
            self.cloudFaceEmbeddingStatusText = "AWS AdaFace still warming; local face fallback active"
            Task { @MainActor in
              self.faceEmbeddingModelStatusText = await self.identityPipeline.embeddingModelStatusText()
            }
            AppLogger.log(
              .faceEmbeddingModel,
              "AWS live face worker did not become ready during capped background warmup endpoint=\(endpoint) healthAttempts=\(Self.cloudFaceWarmupRetryLimit(inputMode: inputModeAtStart)) retryCadence=\(Self.cloudFaceWarmupRetryCadenceText(maxAttempts: Self.cloudFaceWarmupRetryLimit(inputMode: inputModeAtStart))) providerState=localMobileFaceNet fallback=localMobileFaceNet error=\(error.localizedDescription)"
            )
          }
        }
      } catch {
        await pipeline.disableCloudFaceEmbedding(reason: "startFailed")
        await MainActor.run { [weak self] in
          guard let self else { return }
          self.cloudFaceEmbeddingStatusText = "AWS AdaFace failed: \(error.localizedDescription)"
          AppLogger.log(.faceEmbeddingModel, "AWS live face lease start failed: \(error.localizedDescription)")
        }
      }
    }
  }

  private func stopCloudFaceWorkerForStream(reason: String, stopEC2: Bool = true) async {
    cloudFaceLifecycleTask?.cancel()
    cloudFaceLifecycleTask = nil
    cloudFaceHeartbeatTask?.cancel()
    cloudFaceHeartbeatTask = nil
    cloudFaceWorkerStartedAfterFaceCandidate = false
    let settings = CloudFaceEmbeddingLifecycleSettings.load()
    if stopEC2 {
      await identityPipeline.disableCloudFaceEmbedding(reason: "streamStop-\(reason)")
      await cloudFaceLifecycleService.stopIfNeeded(settings: settings)
      if settings.enabled {
        cloudFaceEmbeddingStatusText = "AWS AdaFace stopped; restart stream to relaunch"
      }
    } else {
      await cloudFaceLifecycleService.releaseLiveSessionWithoutStopping(reason: reason)
      if settings.enabled {
        cloudFaceEmbeddingStatusText = await identityPipeline.isCloudFaceEmbeddingActive()
          ? "AWS AdaFace ready for post-stream enrollment"
          : "AWS AdaFace released; will warm again before enrollment"
      }
    }
    faceEmbeddingModelStatusText = await identityPipeline.embeddingModelStatusText()
  }

  private func ensureCloudFaceEmbeddingReadyForEnrollmentIfNeeded() async {
    let settings = CloudFaceEmbeddingLifecycleSettings.load()
    guard settings.enabled else { return }

    if let task = cloudFaceLifecycleTask {
      cloudFaceEmbeddingStatusText = "AWS AdaFace finishing startup for enrollment..."
      await task.value
    }

    if await identityPipeline.isCloudFaceEmbeddingActive(),
       cloudFaceEmbeddingStatusText.localizedCaseInsensitiveContains("ready") {
      return
    }

    cloudFaceEmbeddingStatusText = settings.useEC2Lifecycle
      ? "AWS AdaFace warming for enrollment..."
      : "AWS AdaFace checking enrollment worker..."

    do {
      let result = try await cloudFaceLifecycleService.startAndWarm(settings: settings)
      await identityPipeline.configureCloudFaceEmbedding(endpoint: result.endpoint, apiKey: result.apiKey)
      cloudFaceEmbeddingEndpointText = result.endpoint
      cloudFaceEmbeddingStatusText = "AWS AdaFace ready for enrollment \(result.publicIp ?? result.endpoint)"
      faceEmbeddingModelStatusText = await identityPipeline.embeddingModelStatusText()
      AppLogger.log(
        .faceEmbeddingModel,
        "AWS AdaFace enrollment worker ready endpoint=\(result.endpoint) publicIp=\(result.publicIp ?? "none") health=\(result.healthStatus) session=\(result.liveSessionId ?? "none") expiresAt=\(result.liveExpiresAt ?? "unknown")"
      )
    } catch {
      cloudFaceEmbeddingStatusText = "AWS AdaFace enrollment unavailable; saving local vectors"
      faceEmbeddingModelStatusText = await identityPipeline.embeddingModelStatusText()
      AppLogger.log(
        .faceEmbeddingModel,
        "warning...---- AWS AdaFace enrollment warmup failed; enrollment will continue with available local vectors. error=\(error.localizedDescription)"
      )
    }
  }

  private func startCloudFaceHeartbeatForStream() {
    cloudFaceHeartbeatTask?.cancel()
    let lifecycle = cloudFaceLifecycleService
    cloudFaceHeartbeatTask = Task {
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 300_000_000_000)
        guard !Task.isCancelled else { return }
        await lifecycle.refreshLiveLeaseIfNeeded()
      }
    }
  }

  private func deactivateLiveStreamSessionIfNeeded(
    reason: String,
    cancelDisplayWork: Bool = true
  ) async {
    guard liveStreamSessionActivated else { return }
    let hadLivePhoneAudioSession = livePhoneAudioSessionActive
    liveStreamSessionActivated = false
    livePhoneAudioSessionActive = false
    liveAudioCaptureReadyForVision = false
    deferredCloudWorkerStartTask?.cancel()
    deferredCloudWorkerStartTask = nil
    lastSpeakerUIUpdateAt = nil
    prepareDisplayForStreamStop(reason: reason)
    invalidateLiveDATVisionWork(reason: "deactivate-\(reason)")
	    invalidateAssistanceWork(reason: "deactivate-\(reason)", cancelDisplayWork: cancelDisplayWork)
	    speechManager.stop()
	    speechManager.onAudioBuffer = nil
	    stopLiveTranscriptionForStream()
	    await stopCloudSpeakerWorkerForStream(reason: reason, stopEC2: !hadLivePhoneAudioSession)
    await stopCloudFaceWorkerForStream(reason: reason, stopEC2: !hadLivePhoneAudioSession)
    if hadLivePhoneAudioSession, !isDATAnalysisPaused {
      await finalizeConversationTranscriptAfterStream(reason: reason)
      await scheduleLatestStreamSummary(reason: reason)
      // Without this, the open WAV from the disconnected stream stays attached to the
      // recorder; the next stream's audioRecorder.start() hits its !isRecording guard,
      // bails, and the new stream writes into the stale file (or no file at all).
      let audioFileURL = audioRecorder.stop()
      let capturedStart = streamAudioStart
      let capturedTimeline = speakerTimeline
      let capturedSpeakerEvidence = speakerEvidenceTimeline
      let capturedFaceEvidence = faceEvidenceTimeline
      let capturedContext = pipelineContext
      let capturedLocalTranscripts = postSessionLocalTranscriptSegments
      if let audioURL = audioFileURL, let start = capturedStart {
        scheduleCloudDiarizationJob(
          audioURL: audioURL,
          streamStart: start,
          localTranscriptSegments: capturedLocalTranscripts,
          speakerTimeline: capturedTimeline,
          speakerEvidenceTimeline: capturedSpeakerEvidence,
          faceEvidenceTimeline: capturedFaceEvidence,
          pipelineContext: capturedContext
        )
      } else if audioFileURL == nil {
        cloudDiarizationState = .idle
      }
    } else if hadLivePhoneAudioSession {
      let discardedURL = audioRecorder.stop()
      if let discardedURL {
        try? FileManager.default.removeItem(at: discardedURL)
      }
      cloudDiarizationState = .idle
      AppLogger.log(.stream, "Skipped post-stream transcript attribution and cloud diarization because analysis is paused reason=\(reason)")
    } else {
      cloudDiarizationState = .idle
      AppLogger.log(.stream, "DAT stream marker deactivated without phone audio teardown reason=\(reason)")
    }
    streamAudioStart = nil
    lastConversationSessionIdForSpeakerReview = pipelineContext?.conversationSessionId
    await speakerPipeline.resetRuntimeState(reason: reason)
    capturedVoiceClips = await speakerPipeline.capturedVoiceClipSnapshots()
    wearerVoiceProfile = await speakerPipeline.wearerVoiceProfileSnapshot()
    persistFinalPresenceEpisodes(reason: reason)
    closeCurrentActivityModeEpisode(reason: reason)
    await identityPipeline.endConversation()
    pipelineContext = await identityPipeline.currentContext()
    applyRunSessionSnapshot(await identityPipeline.currentRunSessionSnapshot())
    UIApplication.shared.isIdleTimerDisabled = false
    AppLogger.log(.stream, "Live audio and conversation session deactivated reason=\(reason)")
  }

  func unregisterDATApp() async {
    await datManager.unregisterDATApp()
  }

  func resetDATDeviceSession() async {
    await datManager.resetDeviceSession()
  }

  func dismissError() {
    showError = false
    errorMessage = ""
  }

  // MARK: - Private

  private func enqueue(
    sampleBuffer: CMSampleBuffer,
    sequence: UInt64
  ) -> VisionEnqueueResult {
    guard !analysisPaused else {
      return .dropped(reason: "analysis paused")
    }
    let now = Date()
    guard forceTestFaceOverlay || shouldSubmitVisionFrame(at: now) else {
      return .dropped(reason: visionSkipReason(at: now))
    }
    logVisionBusyGate(sequence: sequence, source: "sampleBuffer", stage: "beforeBusyGate")
    guard !isProcessingFrame else {
      logVisionBusyDrop(sequence: sequence, source: "sampleBuffer")
      return .dropped(reason: "processor busy")
    }
    isProcessingFrame = true
    lastVisionSubmissionAt = now
    statsWindowVisionPending += 1
    logVisionBusySetTrue(sequence: sequence, source: "sampleBuffer")
    logVisionEnqueued(sequence: sequence, source: "sampleBuffer")
    let generation = visionGeneration
    let context = pipelineContext
    Task { [weak self] in
      guard let self else { return }
      await MainActor.run {
        self.markVisionStarted(sequence: sequence, source: "sampleBuffer")
      }
      let startedAt = Date()
      let result = await frameProcessor.process(
        sampleBuffer: sampleBuffer,
        sequence: sequence,
        forceTestFaceOverlay: forceTestFaceOverlay,
        context: context
      )
      let durationMS = Date().timeIntervalSince(startedAt) * 1_000
      await MainActor.run {
        defer {
          self.clearVisionBusy(sequence: sequence, source: "sampleBuffer")
          self.emitAggregateFrameStatsIfNeeded(force: false)
        }
        guard self.visionGeneration == generation else {
          AppLogger.log(.facePipelineStop, "reason=staleVisionResultIgnored frame=\(sequence) generation=\(generation) currentGeneration=\(self.visionGeneration)")
          return
        }
        if let result {
          self.visionProcessedFrames += 1
          self.statsWindowVisionProcessedFrames += 1
          self.statsWindowVisionDurationMS += durationMS
          self.statsWindowVisionDurationCount += 1
          self.currentImageSize = result.imageSize
          self.detectedFaces = result.faces
          self.latestMouthMovementScore = result.faces.map(\.mouthMovementScore).max() ?? 0
          if !self.isLiveDATStreamActive {
            self.people = result.people
          }
          self.visionLatencyText = String(format: "%.1f ms", Double(durationMS))
          self.recordFaceDetectionEventIfNeeded(result)
          self.processIdentityIfNeeded(result)
          self.logVisionProcessed(sequence: sequence, source: "sampleBuffer", durationMS: durationMS, faces: result.faces.count)
          if !self.hasReceivedFirstFrame {
            self.hasReceivedFirstFrame = true
          }
        } else {
          AppLogger.log(.pipelineStats, "visionSkippedReason=frame conversion failed frame=\(sequence) source=sampleBuffer")
          self.noteDroppedFrame(sequence: sequence, reason: "frame conversion failed")
        }
      }
    }
    return .accepted
  }

  private func enqueue(
    image: UIImage,
    sequence: UInt64
  ) -> VisionEnqueueResult {
    guard !analysisPaused else {
      return .dropped(reason: "analysis paused")
    }
    let now = Date()
    let shouldDropInsteadOfQueueing = inputMode == .realGlasses && !forceTestFaceOverlay
    guard forceTestFaceOverlay || shouldSubmitVisionFrame(at: now) else {
      if !shouldDropInsteadOfQueueing {
        replacePendingVisionImage(image: image, sequence: sequence)
      }
      return .dropped(reason: visionSkipReason(at: now))
    }
    logVisionBusyGate(sequence: sequence, source: "UIImage", stage: "beforeBusyGate")
    guard !isProcessingFrame else {
      if !shouldDropInsteadOfQueueing {
        replacePendingVisionImage(image: image, sequence: sequence)
      }
      logVisionBusyDrop(sequence: sequence, source: "UIImage")
      return .dropped(reason: "processor busy")
    }
    submitVisionFrame(image: image, sequence: sequence, submittedAt: now)
    return .accepted
  }

  private func enqueue(
    pixelBuffer: CVPixelBuffer,
    sequence: UInt64
  ) -> VisionEnqueueResult {
    guard !analysisPaused else {
      return .dropped(reason: "analysis paused")
    }
    let now = Date()
    guard forceTestFaceOverlay || shouldSubmitVisionFrame(at: now) else {
      return .dropped(reason: visionSkipReason(at: now))
    }
    logVisionBusyGate(sequence: sequence, source: "CVPixelBuffer", stage: "beforeBusyGate")
    guard !isProcessingFrame else {
      logVisionBusyDrop(sequence: sequence, source: "CVPixelBuffer")
      return .dropped(reason: "processor busy")
    }
    isProcessingFrame = true
    lastVisionSubmissionAt = now
    statsWindowVisionPending += 1
    logVisionBusySetTrue(sequence: sequence, source: "CVPixelBuffer")
    logVisionEnqueued(sequence: sequence, source: "CVPixelBuffer")
    let generation = visionGeneration
    let context = pipelineContext
    let sendablePixelBuffer = SendablePixelBuffer(pixelBuffer: pixelBuffer)
    Task { [weak self, sendablePixelBuffer] in
      guard let self else { return }
      await MainActor.run {
        self.markVisionStarted(sequence: sequence, source: "CVPixelBuffer")
      }
      let startedAt = Date()
      let result = await frameProcessor.process(
        pixelBuffer: sendablePixelBuffer.pixelBuffer,
        sequence: sequence,
        forceTestFaceOverlay: forceTestFaceOverlay,
        context: context
      )
      let durationMS = Date().timeIntervalSince(startedAt) * 1_000
      await MainActor.run {
        defer {
          self.clearVisionBusy(sequence: sequence, source: "CVPixelBuffer")
          self.emitAggregateFrameStatsIfNeeded(force: false)
        }
        guard self.visionGeneration == generation else {
          AppLogger.log(.facePipelineStop, "reason=staleVisionResultIgnored frame=\(sequence) generation=\(generation) currentGeneration=\(self.visionGeneration)")
          return
        }
        if let result {
          self.visionProcessedFrames += 1
          self.statsWindowVisionProcessedFrames += 1
          self.statsWindowVisionDurationMS += durationMS
          self.statsWindowVisionDurationCount += 1
          self.currentImageSize = result.imageSize
          self.detectedFaces = result.faces
          self.latestMouthMovementScore = result.faces.map(\.mouthMovementScore).max() ?? 0
          if !self.isLiveDATStreamActive {
            self.people = result.people
          }
          self.visionLatencyText = String(format: "%.1f ms", Double(durationMS))
          self.recordFaceDetectionEventIfNeeded(result)
          self.processIdentityIfNeeded(result)
          self.logVisionProcessed(sequence: sequence, source: "CVPixelBuffer", durationMS: durationMS, faces: result.faces.count)
          if !self.hasReceivedFirstFrame {
            self.hasReceivedFirstFrame = true
          }
        } else {
          AppLogger.log(.pipelineStats, "visionSkippedReason=Vision returned no result frame=\(sequence) source=CVPixelBuffer")
          self.noteDroppedFrame(sequence: sequence, reason: "Vision returned no result", shouldLog: self.verboseFrameLogging)
        }
      }
    }
    return .accepted
  }

  private func submitVisionFrame(image: UIImage, sequence: UInt64, submittedAt: Date) {
    isProcessingFrame = true
    lastVisionSubmissionAt = submittedAt
    statsWindowVisionPending += 1
    logVisionBusySetTrue(sequence: sequence, source: "UIImage")
    logVisionEnqueued(sequence: sequence, source: "UIImage")
    let generation = visionGeneration
    let context = pipelineContext
    Task { [weak self] in
      guard let self else { return }
      await MainActor.run {
        self.markVisionStarted(sequence: sequence, source: "UIImage")
      }
      let startedAt = Date()
      let result = await frameProcessor.process(
        image: image,
        sequence: sequence,
        forceTestFaceOverlay: forceTestFaceOverlay,
        context: context
      )
      let durationMS = Date().timeIntervalSince(startedAt) * 1_000
      await MainActor.run {
        var shouldFlushPending = false
        defer {
          self.clearVisionBusy(sequence: sequence, source: "UIImage")
          if shouldFlushPending {
            self.flushPendingVisionImageIfReady()
          }
          self.emitAggregateFrameStatsIfNeeded(force: false)
        }
        guard self.visionGeneration == generation else {
          AppLogger.log(.facePipelineStop, "reason=staleVisionResultIgnored frame=\(sequence) generation=\(generation) currentGeneration=\(self.visionGeneration)")
          return
        }
        if let result {
          self.visionProcessedFrames += 1
          self.statsWindowVisionProcessedFrames += 1
          self.statsWindowVisionDurationMS += durationMS
          self.statsWindowVisionDurationCount += 1
          self.currentImageSize = result.imageSize
          self.detectedFaces = result.faces
          self.latestMouthMovementScore = result.faces.map(\.mouthMovementScore).max() ?? 0
          if !self.isLiveDATStreamActive {
            self.people = result.people
          }
          self.visionLatencyText = String(format: "%.1f ms", Double(durationMS))
          self.recordFaceDetectionEventIfNeeded(result)
          self.processIdentityIfNeeded(result)
          self.logVisionProcessed(sequence: sequence, source: "UIImage", durationMS: durationMS, faces: result.faces.count)
          if !self.hasReceivedFirstFrame {
            self.hasReceivedFirstFrame = true
          }
        } else {
          AppLogger.log(.pipelineStats, "visionSkippedReason=Vision returned no result frame=\(sequence) source=UIImage")
          self.noteDroppedFrame(sequence: sequence, reason: "Vision returned no result", shouldLog: self.verboseFrameLogging)
        }
        if self.inputMode != .realGlasses || self.forceTestFaceOverlay {
          shouldFlushPending = true
        }
      }
    }
  }

  private func handleRealGlassesImage(_ image: UIImage) {
    totalReceivedFrames += 1
    statsWindowReceivedFrames += 1
    let sequence = totalReceivedFrames
    let now = Date()
    if let lastFrameArrival {
      lastFrameIntervalText = String(format: "%.1f ms", Double(now.timeIntervalSince(lastFrameArrival) * 1_000))
    }
    lastFrameArrival = now
    lastFrameTimestampText = String(format: "%.3f", Double(now.timeIntervalSince1970))
    guard shouldAcceptLiveDATFrameForAnalysis() else {
      AppLogger.log(.frames, "warning...---- Dropped DAT UIImage frame #\(sequence) because stream is terminal or not streaming. stream=\(datStreamSessionStateText), datRunning=\(datIsStreamRunning), terminalInvalidated=\(liveDATTerminalVisionInvalidated)")
      noteDroppedFrame(sequence: sequence, reason: "DAT stream terminal")
      emitAggregateFrameStatsIfNeeded(force: false)
      return
    }
    let frameAccepted = markLiveDATFrameArrived(at: now)
    if Self.shouldSubmitSceneContextForLiveDATFrame(
      previewImageAvailable: true,
      isDATAnalysisPaused: isDATAnalysisPaused,
      frameAccepted: frameAccepted
    ) {
      submitSceneContextFrameIfSampled(image: image, timestamp: now)
    }
    guard frameAccepted else {
      emitAggregateFrameStatsIfNeeded(force: false)
      return
    }
    markFirstRealGlassesFrameIfNeeded(reason: "first-video-stream-frame")

    guard !dropFrameIfAnalysisPaused(sequence: sequence, source: "UIImage") else { return }

    let size = image.size
    if verboseFrameLogging {
      AppLogger.log(.frames, "Real DAT frame #\(sequence) arrived imageSize=\(Int(size.width))x\(Int(size.height)), timestamp=\(lastFrameTimestampText)")
    }

    var previewUpdated = false
    if shouldUpdatePreview(at: now) {
      totalPreviewFrames += 1
      statsWindowPreviewFrames += 1
      lastPreviewUpdateAt = now
      currentVideoFrame = image
      currentImageSize = size
      previewUpdated = true
    }

    let enqueueResult = enqueue(image: image, sequence: sequence)
    logVisionSelection(sequence: sequence, source: "UIImage", result: enqueueResult)
    if verboseFrameLogging {
      AppLogger.log(
        .frames,
        "Real DAT frame #\(sequence) previewUpdated=\(previewUpdated), selectedForVision=\(enqueueResult.selectedForVision), visionEnqueued=\(enqueueResult.visionEnqueued), visionSkippedReason=\(enqueueResult.visionSkippedReason)"
      )
    }
    if let reason = enqueueResult.dropReason {
      noteDroppedFrame(sequence: sequence, reason: reason, shouldLog: false)
    }
    emitAggregateFrameStatsIfNeeded(force: false)
  }

  private func submitSceneContextFrameIfSampled(image: UIImage, timestamp: Date) {
    guard sceneContextPipeline.captureFrame(image: image, timestamp: timestamp) else { return }
    let attribution = currentTranscriptAttribution()
    sceneContextPipeline.submitLatestIfReady(
      context: pipelineContext,
      identityEvidence: currentSceneContextIdentityEvidence(attribution: attribution),
      location: nil
    )
  }

  private func handleRealGlassesPixelBuffer(_ pixelBuffer: CVPixelBuffer, previewImage: UIImage?) {
    totalReceivedFrames += 1
    statsWindowReceivedFrames += 1
    let sequence = totalReceivedFrames
    let now = Date()
    if let lastFrameArrival {
      lastFrameIntervalText = String(format: "%.1f ms", Double(now.timeIntervalSince(lastFrameArrival) * 1_000))
    }
    lastFrameArrival = now
    lastFrameTimestampText = String(format: "%.3f", Double(now.timeIntervalSince1970))
    guard shouldAcceptLiveDATFrameForAnalysis() else {
      AppLogger.log(.frames, "warning...---- Dropped DAT CVPixelBuffer frame #\(sequence) because stream is terminal or not streaming. stream=\(datStreamSessionStateText), datRunning=\(datIsStreamRunning), terminalInvalidated=\(liveDATTerminalVisionInvalidated)")
      noteDroppedFrame(sequence: sequence, reason: "DAT stream terminal")
      emitAggregateFrameStatsIfNeeded(force: false)
      return
    }
    let frameAccepted = markLiveDATFrameArrived(at: now)
    if Self.shouldSubmitSceneContextForLiveDATFrame(
      previewImageAvailable: previewImage != nil,
      isDATAnalysisPaused: isDATAnalysisPaused,
      frameAccepted: frameAccepted
    ), let previewImage {
      submitSceneContextFrameIfSampled(image: previewImage, timestamp: now)
    } else {
      scheduleSceneContextFrameIfSampled(
        pixelBuffer: pixelBuffer,
        timestamp: now,
        sequence: sequence,
        frameAccepted: frameAccepted
      )
    }
    guard frameAccepted else {
      emitAggregateFrameStatsIfNeeded(force: false)
      return
    }
    markFirstRealGlassesFrameIfNeeded(reason: "first-video-stream-frame")

    guard !dropFrameIfAnalysisPaused(sequence: sequence, source: "CVPixelBuffer") else { return }

    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    datFramesWithPixelBuffer = max(datFramesWithPixelBuffer, sequence)

    if verboseFrameLogging {
      AppLogger.log(.frames, "Real DAT frame #\(sequence) arrived pixelBufferSize=\(width)x\(height), previewImage=\(previewImage != nil), timestamp=\(lastFrameTimestampText)")
    }

    var previewUpdated = false
    if shouldUpdatePreview(at: now) {
      lastPreviewUpdateAt = now
      if let previewImage {
        totalPreviewFrames += 1
        statsWindowPreviewFrames += 1
        currentVideoFrame = previewImage
        currentImageSize = previewImage.size
        previewUpdated = true
      } else {
        currentImageSize = CGSize(width: width, height: height)
        renderLiveDATPreview(pixelBuffer: pixelBuffer, sequence: sequence, generation: visionGeneration)
        previewUpdated = true
      }
    }

    let enqueueResult = enqueue(pixelBuffer: pixelBuffer, sequence: sequence)
    logVisionSelection(sequence: sequence, source: "CVPixelBuffer", result: enqueueResult)
    if verboseFrameLogging {
      AppLogger.log(
        .frames,
        "Real DAT frame #\(sequence) previewUpdated=\(previewUpdated), selectedForVision=\(enqueueResult.selectedForVision), visionEnqueued=\(enqueueResult.visionEnqueued), visionSkippedReason=\(enqueueResult.visionSkippedReason)"
      )
    }
    if let reason = enqueueResult.dropReason {
      noteDroppedFrame(sequence: sequence, reason: reason, shouldLog: false)
    }
    emitAggregateFrameStatsIfNeeded(force: false)
  }

  private func handleRealGlassesSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
    totalReceivedFrames += 1
    statsWindowReceivedFrames += 1
    let sequence = totalReceivedFrames
    let now = Date()
    let frameIntervalMS = lastFrameArrival.map { now.timeIntervalSince($0) * 1_000 }
    lastFrameArrival = now
    guard shouldAcceptLiveDATFrameForAnalysis() else {
      AppLogger.log(.frames, "warning...---- Dropped DAT CMSampleBuffer frame #\(sequence) because stream is terminal or not streaming. stream=\(datStreamSessionStateText), datRunning=\(datIsStreamRunning), terminalInvalidated=\(liveDATTerminalVisionInvalidated)")
      noteDroppedFrame(sequence: sequence, reason: "DAT stream terminal")
      emitAggregateFrameStatsIfNeeded(force: false)
      return
    }
    guard markLiveDATFrameArrived(at: now) else {
      emitAggregateFrameStatsIfNeeded(force: false)
      return
    }
    markFirstRealGlassesFrameIfNeeded(reason: "first-video-stream-frame")

    let shouldRenderPreview = shouldUpdatePreview(at: now)
    if shouldRenderPreview {
      lastPreviewUpdateAt = now
      if let frameIntervalMS {
        lastFrameIntervalText = String(format: "%.1f ms", Double(frameIntervalMS))
      }
      lastFrameTimestampText = String(format: "%.3f", Double(now.timeIntervalSince1970))
      if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
        datFramesWithPixelBuffer = max(datFramesWithPixelBuffer, sequence)
        currentImageSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        renderLiveDATPreview(pixelBuffer: pixelBuffer, sequence: sequence, generation: visionGeneration)
      } else if verboseFrameLogging {
        AppLogger.log(
          .visionInput,
          "WARNING frame=\(sequence) input=sampleBuffer pixelBufferUnavailable mode=liveDAT action=previewSkipped"
        )
      }
    }

    if !liveDATStreamHealthIsolationMode {
      scheduleLiveDATAnalysis(sampleBuffer: sampleBuffer, sequence: sequence)
    }
    emitAggregateFrameStatsIfNeeded(force: false)
  }

  private func scheduleLiveDATAnalysis(sampleBuffer: CMSampleBuffer, sequence: UInt64) {
    guard !analysisPaused else { return }
    let now = Date()
    guard forceTestFaceOverlay || shouldSubmitVisionFrame(at: now) else { return }
    let enqueueResult = enqueue(sampleBuffer: sampleBuffer, sequence: sequence)
    logVisionSelection(sequence: sequence, source: "sampleBuffer", result: enqueueResult)
    if let reason = enqueueResult.dropReason {
      noteDroppedFrame(sequence: sequence, reason: reason)
    }
  }

  private func renderLiveDATPreview(pixelBuffer: CVPixelBuffer, sequence: UInt64, generation: UInt64) {
    let sendablePixelBuffer = SendablePixelBuffer(pixelBuffer: pixelBuffer)
    liveDATPreviewRenderQueue.async { [sendablePixelBuffer] in
      guard let image = Self.makePreviewImage(from: sendablePixelBuffer.pixelBuffer) else {
        Task { @MainActor [weak self] in
          guard let self else { return }
          self.noteDroppedFrame(sequence: sequence, reason: "preview render failed", shouldLog: self.verboseFrameLogging)
        }
        return
      }
      Task { @MainActor [weak self] in
        guard let self, self.visionGeneration == generation else { return }
        self.totalPreviewFrames += 1
        self.statsWindowPreviewFrames += 1
        self.currentVideoFrame = image
        self.currentImageSize = image.size
        if !self.isDATAnalysisPaused {
          self.submitSceneContextFrameIfSampled(image: image, timestamp: Date())
        }
        if !self.hasReceivedFirstFrame {
          self.hasReceivedFirstFrame = true
        }
      }
    }
  }

  private func scheduleSceneContextFrameIfSampled(
    pixelBuffer: CVPixelBuffer,
    timestamp: Date,
    sequence: UInt64,
    frameAccepted: Bool
  ) {
    let captureDue = sceneContextPipeline.isFrameCaptureDue(at: timestamp)
    guard Self.shouldEncodeSceneContextFromPixelBuffer(
      sceneContextEnabled: sceneContextEnabled,
      isDATAnalysisPaused: isDATAnalysisPaused,
      frameAccepted: frameAccepted,
      captureDue: captureDue,
      encodingInFlight: sceneContextFrameEncodingToken != nil
    ) else { return }

    let token = UUID()
    let generation = visionGeneration
    sceneContextFrameEncodingToken = token
    let sendablePixelBuffer = SendablePixelBuffer(pixelBuffer: pixelBuffer)
    AppLogger.log(.sceneContext, "[SCENE_CONTEXT_FRAME] frame=\(sequence) stage=selected source=DATPixelBuffer")

    liveDATPreviewRenderQueue.async { [sendablePixelBuffer] in
      let jpegData = Self.makeSceneContextJPEGData(from: sendablePixelBuffer.pixelBuffer)
      Task { @MainActor [weak self] in
        guard let self, self.sceneContextFrameEncodingToken == token else { return }
        self.sceneContextFrameEncodingToken = nil
        guard self.visionGeneration == generation,
              self.shouldAcceptLiveDATFrameForAnalysis(),
              !self.isDATAnalysisPaused else {
          AppLogger.log(.sceneContext, "[SCENE_CONTEXT_FRAME] frame=\(sequence) stage=dropped reason=staleGenerationOrInactiveStream")
          return
        }
        guard let jpegData, !jpegData.isEmpty else {
          AppLogger.log(.sceneContext, "[SCENE_CONTEXT_FRAME] frame=\(sequence) stage=encodeFailed")
          return
        }
        guard self.sceneContextPipeline.captureEncodedFrame(jpegData: jpegData, timestamp: timestamp) else {
          AppLogger.log(.sceneContext, "[SCENE_CONTEXT_FRAME] frame=\(sequence) stage=dropped reason=cadenceChanged bytes=\(jpegData.count)")
          return
        }

        AppLogger.log(.sceneContext, "[SCENE_CONTEXT_FRAME] frame=\(sequence) stage=encoded bytes=\(jpegData.count)")
        let attribution = self.currentTranscriptAttribution()
        self.sceneContextPipeline.submitLatestIfReady(
          context: self.pipelineContext,
          identityEvidence: self.currentSceneContextIdentityEvidence(attribution: attribution),
          location: nil
        )
        self.emitStreamPerformanceCountersIfNeeded(force: false)
      }
    }
  }

  nonisolated private static func makePreviewImage(from pixelBuffer: CVPixelBuffer) -> UIImage? {
    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    let context = CIContext(options: nil)
    guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
    return UIImage(cgImage: cgImage)
  }

  nonisolated private static func makeSceneContextJPEGData(from pixelBuffer: CVPixelBuffer) -> Data? {
    autoreleasepool {
      guard let image = makePreviewImage(from: pixelBuffer) else { return nil }
      return image.jpegData(compressionQuality: 0.55)
    }
  }

  private func handleSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
    totalReceivedFrames += 1
    framesReceived = totalReceivedFrames
    let sequence = totalReceivedFrames
    let now = Date()
    if let lastFrameArrival {
      lastFrameIntervalText = String(format: "%.1f ms", Double(now.timeIntervalSince(lastFrameArrival) * 1_000))
    }
    lastFrameArrival = now

    let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    let timestampText = timestamp.isValid ? String(format: "%.3f", Double(CMTimeGetSeconds(timestamp))) : "invalid"
    lastFrameTimestampText = timestampText

    guard !dropFrameIfAnalysisPaused(sequence: sequence, source: "sampleBuffer") else { return }

    if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
      let width = CVPixelBufferGetWidth(pixelBuffer)
      let height = CVPixelBufferGetHeight(pixelBuffer)
      AppLogger.log(.frames, "File frame #\(sequence) arrived size=\(width)x\(height), timestamp=\(timestampText)")
    } else {
      AppLogger.log(.frames, "File frame #\(sequence) missing CVPixelBuffer, timestamp=\(timestampText)")
    }

    let enqueueResult = enqueue(sampleBuffer: sampleBuffer, sequence: sequence)
    if let reason = enqueueResult.dropReason {
      noteDroppedFrame(sequence: sequence, reason: reason)
    }
  }

  private func shouldUpdatePreview(at now: Date) -> Bool {
    guard !forceTestFaceOverlay else { return true }
    guard Self.shouldRenderPhonePreviewForLiveDAT(
      phonePreviewEnabled: Self.liveDATPhonePreviewEnabled,
      forceTestFaceOverlay: forceTestFaceOverlay
    ) else { return false }
    guard let lastPreviewUpdateAt else { return true }
    return now.timeIntervalSince(lastPreviewUpdateAt) >= 1 / maxPreviewFPS
  }

  private func dropFrameIfAnalysisPaused(sequence: UInt64, source: String) -> Bool {
    guard analysisPaused else { return false }
    let result = VisionEnqueueResult.dropped(reason: "analysis paused")
    logVisionSelection(sequence: sequence, source: source, result: result)
    noteDroppedFrame(sequence: sequence, reason: "analysis paused", shouldLog: verboseFrameLogging)
    emitAggregateFrameStatsIfNeeded(force: false)
    return true
  }

  private func shouldSubmitVisionFrame(at now: Date) -> Bool {
    guard !forceTestFaceOverlay else { return true }
    let interval = visionSubmissionInterval(at: now)
    guard interval.isFinite else { return false }
    guard let lastVisionSubmissionAt else { return true }
    return now.timeIntervalSince(lastVisionSubmissionAt) >= interval
  }

  private func visionSubmissionInterval(at now: Date) -> TimeInterval {
    guard inputMode == .realGlasses else {
      return 1 / maxVisionFPS
    }
    guard datVisionReadinessBlocker(at: now) == nil else {
      return .infinity
    }
    guard let liveDATFirstFrameAt else { return .infinity }
    let analysisSeconds = now.timeIntervalSince(liveDATFirstFrameAt) - liveDATVisionStartupDelaySeconds
    if analysisSeconds < liveDATVisionWarmupSeconds {
      return 1 / liveDATVisionWarmupFPS
    }
    if shouldAdaptVisualWorkForDegradedTransport(at: now) {
      return 1 / liveDATDegradedVisionFPS
    }
    return 1 / liveDATVisionSteadyFPS
  }

  private func replacePendingVisionImage(image: UIImage, sequence: UInt64) {
    pendingVisionImage = PendingVisionImage(image: image, sequence: sequence, capturedAt: Date())
  }

  private func flushPendingVisionImageIfReady() {
    guard let pendingVisionImage else { return }
    let now = Date()
    guard now.timeIntervalSince(pendingVisionImage.capturedAt) <= maxPendingVisionAgeSeconds else {
      self.pendingVisionImage = nil
      noteDroppedFrame(sequence: pendingVisionImage.sequence, reason: "stale pending frame", shouldLog: false)
      return
    }
    guard shouldSubmitVisionFrame(at: now), !isProcessingFrame else { return }
    self.pendingVisionImage = nil
    submitVisionFrame(image: pendingVisionImage.image, sequence: pendingVisionImage.sequence, submittedAt: now)
  }

  private func visionSkipReason(at now: Date) -> String {
    guard inputMode == .realGlasses else {
      return "vision throttle"
    }
    if let blocker = datVisionReadinessBlocker(at: now) {
      return blocker
    }
    return "vision throttle"
  }

  private func logVisionBusyGate(sequence: UInt64, source: String, stage: String) {
    guard verboseFrameLogging else { return }
    AppLogger.log(
      .pipelineStats,
      "visionGate \(stage) frame=\(sequence) source=\(source) busy=\(isProcessingFrame) pending=\(statsWindowVisionPending) attemptedWindow=\(statsWindowVisionSubmittedFrames) processedWindow=\(statsWindowVisionProcessedFrames)"
    )
  }

  private func logVisionBusyDrop(sequence: UInt64, source: String) {
    guard verboseFrameLogging else { return }
    AppLogger.log(
      .pipelineStats,
      "visionGate dropBusy frame=\(sequence) source=\(source) busy=\(isProcessingFrame) pending=\(statsWindowVisionPending)"
    )
  }

  private func logVisionBusySetTrue(sequence: UInt64, source: String) {
    guard verboseFrameLogging else { return }
    AppLogger.log(
      .pipelineStats,
      "visionGate setBusy=true frame=\(sequence) source=\(source) pending=\(statsWindowVisionPending)"
    )
  }

  private func logVisionSelection(sequence: UInt64, source: String, result: VisionEnqueueResult) {
    guard verboseFrameLogging else { return }
    AppLogger.log(
      .pipelineStats,
      "visionSelection frame=\(sequence) source=\(source) selectedForVision=\(result.selectedForVision) visionEnqueued=\(result.visionEnqueued) visionStarted=false visionProcessed=false visionSkippedReason=\(result.visionSkippedReason) pending=\(statsWindowVisionPending)"
    )
  }

  private func logVisionEnqueued(sequence: UInt64, source: String) {
    guard verboseFrameLogging else { return }
    AppLogger.log(
      .pipelineStats,
      "visionEnqueued frame=\(sequence) source=\(source) pending=\(statsWindowVisionPending)"
    )
  }

  private func markVisionStarted(sequence: UInt64, source: String) {
    visionSubmittedFrames += 1
    statsWindowVisionSubmittedFrames += 1
    guard verboseFrameLogging else { return }
    AppLogger.log(
      .pipelineStats,
      "visionStarted frame=\(sequence) source=\(source) pending=\(statsWindowVisionPending) attemptedWindow=\(statsWindowVisionSubmittedFrames)"
    )
  }

  private func logVisionProcessed(sequence: UInt64, source: String, durationMS: Double, faces: Int) {
    guard verboseFrameLogging else { return }
    AppLogger.log(
      .pipelineStats,
      "visionProcessed frame=\(sequence) source=\(source) durationMs=\(String(format: "%.1f", Double(durationMS))) faces=\(faces) pending=\(statsWindowVisionPending)"
    )
  }

  private func clearVisionBusy(sequence: UInt64, source: String) {
    if statsWindowVisionPending > 0 {
      statsWindowVisionPending -= 1
    } else {
      AppLogger.log(
        .pipelineStats,
        "visionGate pendingUnderflow frame=\(sequence) source=\(source) busy=\(isProcessingFrame)"
      )
    }
    isProcessingFrame = false
    guard verboseFrameLogging else { return }
    AppLogger.log(
      .pipelineStats,
      "visionGate setBusy=false frame=\(sequence) source=\(source) pending=\(statsWindowVisionPending)"
    )
  }

  private func noteDroppedFrame(sequence: UInt64, reason: String, shouldLog: Bool = true) {
    totalDroppedFrames += 1
    statsWindowDroppedFrames += 1
    if reason.localizedCaseInsensitiveContains("busy") {
      statsWindowDroppedBusy += 1
    } else if reason.localizedCaseInsensitiveContains("stale") {
      statsWindowDroppedStale += 1
    } else if reason.localizedCaseInsensitiveContains("throttle")
      || reason.localizedCaseInsensitiveContains("delay")
      || reason.localizedCaseInsensitiveContains("not ready") {
      statsWindowSkippedThrottle += 1
    }
    if verboseFrameLogging && shouldLog {
      AppLogger.log(.frames, "Dropped \(inputMode.rawValue) frame #\(sequence): \(reason). dropped=\(totalDroppedFrames)")
    }
  }

  private func emitAggregateFrameStatsIfNeeded(force: Bool) {
    let now = Date()
    let elapsed = now.timeIntervalSince(statsWindowStartedAt)
    guard force || elapsed >= aggregateFrameStatsLogIntervalSeconds else { return }
    let fps = elapsed > 0 ? Double(statsWindowReceivedFrames) / elapsed : 0
    let avgVisionMS = statsWindowVisionDurationCount > 0
      ? statsWindowVisionDurationMS / Double(statsWindowVisionDurationCount)
      : 0
    let avgEmbedMS = statsWindowEmbedded > 0
      ? statsWindowEmbeddingDurationMS / Double(statsWindowEmbedded)
      : 0
    let windowVisionProcessed = statsWindowVisionProcessedFrames
    let totalVisionProcessed = visionProcessedFrames
    framesReceived = totalReceivedFrames
    previewFrames = totalPreviewFrames
    droppedFrames = totalDroppedFrames
    liveFrameStatsText = String(
      format: "received=%llu preview=%llu vision=%llu/%llu pending=%llu dropped=%llu fps=%.1f avgVision=%.1f ms",
      totalReceivedFrames,
      totalPreviewFrames,
      totalVisionProcessed,
      visionSubmittedFrames,
      statsWindowVisionPending,
      totalDroppedFrames,
      fps,
      avgVisionMS
    )
    AppLogger.log(
      .frames,
      String(
        format: "Live frame stats: windowReceived=%llu windowPreview=%llu windowVision=%llu/%llu windowVisionPending=%llu windowDropped=%llu totalReceived=%llu totalPreview=%llu totalVision=%llu/%llu totalDropped=%llu currentFPS=%.1f averageVisionMs=%.1f",
        statsWindowReceivedFrames,
        statsWindowPreviewFrames,
        windowVisionProcessed,
        statsWindowVisionSubmittedFrames,
        statsWindowVisionPending,
        statsWindowDroppedFrames,
        totalReceivedFrames,
        totalPreviewFrames,
        totalVisionProcessed,
        visionSubmittedFrames,
        totalDroppedFrames,
        fps,
        avgVisionMS
      )
    )
    AppLogger.log(
      .pipelineStats,
      String(
        format: "received=%llu preview=%llu visionAttempted=%llu visionProcessed=%llu visionPending=%llu queueBound=1 faces=%llu qualityPass=%llu embedded=%llu matched=%llu droppedBusy=%llu droppedStale=%llu skippedThrottle=%llu avgVisionMs=%.1f avgEmbedMs=%.1f",
        statsWindowReceivedFrames,
        statsWindowPreviewFrames,
        statsWindowVisionSubmittedFrames,
        windowVisionProcessed,
        statsWindowVisionPending,
        statsWindowFaceCandidates,
        statsWindowQualityPass,
        statsWindowEmbedded,
        statsWindowMatched,
        statsWindowDroppedBusy,
        statsWindowDroppedStale,
        statsWindowSkippedThrottle,
        avgVisionMS,
        avgEmbedMS
      )
    )
    emitStreamPerformanceCountersIfNeeded(force: false)
    resetStatsWindow(startedAt: now)
  }

  private func resetStatsWindow(startedAt: Date = Date()) {
    statsWindowStartedAt = startedAt
    statsWindowReceivedFrames = 0
    statsWindowPreviewFrames = 0
    statsWindowVisionSubmittedFrames = 0
    statsWindowVisionProcessedFrames = 0
    statsWindowDroppedFrames = 0
    statsWindowDroppedBusy = 0
    statsWindowDroppedStale = 0
    statsWindowSkippedThrottle = 0
    statsWindowFaceCandidates = 0
    statsWindowQualityPass = 0
    statsWindowEmbedded = 0
    statsWindowMatched = 0
    statsWindowEmbeddingDurationMS = 0
    statsWindowVisionDurationMS = 0
    statsWindowVisionDurationCount = 0
  }

  private func resetStreamPerformanceCounters(startedAt: Date = Date()) {
    streamPerformanceCounters = StreamPerformanceCounters(startedAt: startedAt, lastLoggedAt: startedAt)
    lastStreamReadinessDisplaySignature = ""
  }

  private func emitStreamPerformanceCountersIfNeeded(force: Bool) {
    let now = Date()
    guard force || now.timeIntervalSince(streamPerformanceCounters.lastLoggedAt) >= streamPerformanceLogIntervalSeconds else {
      return
    }
    streamPerformanceCounters.lastLoggedAt = now
    let sceneMetrics = sceneContextPipeline.metricsSnapshot()
    let observedFPS = observedDATFramesPerSecond(at: now)
    let visualAdaptation = visualAdaptationState(at: now)
    AppLogger.log(
      .streamPerf,
      String(
        format: "[STREAM_PERF] windowSec=%.0f videoFramesReceived=%llu observedFPS=%.2f requestedFPS=%.1f visualAdaptation=%@ framesProcessedForFaceDetection=%llu sceneFramesSampled=%llu sceneImagesEncoded=%llu sceneImageBytes=%llu qwenMultimodalRequests=%llu qwenMultimodalSuccesses=%llu qwenMultimodalFailures=%llu multimodalLastLatencyMs=%.0f embeddingsRequested=%llu faceEmbeddingFramesSubmitted=%llu faceEmbeddingSkippedDisabled=%llu faceEmbeddingSkippedNoCandidate=%llu faceEmbeddingSkippedPromptActive=%llu faceEmbeddingSkippedCooldown=%llu faceEmbeddingPipelineNoResult=%llu asrTranscriptSegments=%llu asrFillerSkipped=%llu qwenAnswerCalls=%llu qwenActivityModeCalls=%llu activityModeSkippedNoContext=%llu displaySends=%llu databaseWrites=%llu locationReads=%llu",
        now.timeIntervalSince(streamPerformanceCounters.startedAt),
        totalReceivedFrames,
        observedFPS,
        requestedDATFramesPerSecond,
        visualAdaptation,
        visionProcessedFrames,
        sceneMetrics.framesSampled,
        sceneMetrics.imagesEncoded,
        sceneMetrics.imageBytes,
        sceneMetrics.requestsStarted,
        sceneMetrics.requestsSucceeded,
        sceneMetrics.requestsFailed,
        sceneMetrics.lastRequestLatencyMS,
        streamPerformanceCounters.embeddingsRequested,
        streamPerformanceCounters.faceEmbeddingFramesSubmitted,
        streamPerformanceCounters.faceEmbeddingSkippedDisabled,
        streamPerformanceCounters.faceEmbeddingSkippedNoCandidate,
        streamPerformanceCounters.faceEmbeddingSkippedPromptActive,
        streamPerformanceCounters.faceEmbeddingSkippedCooldown,
        streamPerformanceCounters.faceEmbeddingPipelineNoResult,
        streamPerformanceCounters.asrTranscriptSegments,
        streamPerformanceCounters.asrFillerSkipped,
        streamPerformanceCounters.qwenAnswerCalls,
        streamPerformanceCounters.qwenActivityModeCalls,
        streamPerformanceCounters.activityModeSkippedNoContext,
        streamPerformanceCounters.displaySendAttempts,
        streamPerformanceCounters.databaseWrites,
        streamPerformanceCounters.locationReads
      )
    )
    AppLogger.log(
      .streamPerf,
      "[STREAM_READINESS] transport=\(transportReadiness(observedFPS: observedFPS, now: now)) observedFPS=\(String(format: "%.2f", observedFPS)) requestedFPS=\(String(format: "%.1f", requestedDATFramesPerSecond)) visualAdaptation=\(visualAdaptation) asr=\(speechContextReadiness()) acceptedTranscriptSegments=\(streamPerformanceCounters.asrTranscriptSegments) visual=\(visualContextReadiness(metrics: sceneMetrics)) multimodalRequests=\(sceneMetrics.requestsStarted) multimodalSuccesses=\(sceneMetrics.requestsSucceeded) evidence=\(sceneMetrics.lastEvidenceSource) face=\(faceRecognitionReadiness()) locationReads=\(streamPerformanceCounters.locationReads)"
    )
    refreshStreamReadinessDisplayIfNeeded(reason: "stream-readiness-metrics")
  }

  private func observedDATFramesPerSecond(at now: Date) -> Double {
    guard let startedAt = liveDATStreamingStartedAt else { return 0 }
    let elapsed = max(0.001, now.timeIntervalSince(startedAt))
    return Double(totalReceivedFrames) / elapsed
  }

  private func transportReadiness(observedFPS: Double, now: Date = Date()) -> String {
    guard datIsStreamRunning || datStreamSessionStateText.lowercased().contains("streaming") else {
      return "stopped"
    }
    guard let startedAt = liveDATStreamingStartedAt, now.timeIntervalSince(startedAt) >= 10 else {
      return "starting"
    }
    return observedFPS >= requestedDATFramesPerSecond * 0.6 ? "ready" : "degraded"
  }

  nonisolated static func shouldAdaptVisualWorkForDegradedTransport(
    observedFPS: Double,
    requestedFPS: Double,
    streamAgeSeconds: TimeInterval
  ) -> Bool {
    guard streamAgeSeconds >= 10, requestedFPS > 0 else { return false }
    return observedFPS < requestedFPS * 0.6
  }

  private func shouldAdaptVisualWorkForDegradedTransport(at now: Date = Date()) -> Bool {
    guard let startedAt = liveDATStreamingStartedAt else { return false }
    return Self.shouldAdaptVisualWorkForDegradedTransport(
      observedFPS: observedDATFramesPerSecond(at: now),
      requestedFPS: requestedDATFramesPerSecond,
      streamAgeSeconds: now.timeIntervalSince(startedAt)
    )
  }

  private func visualAdaptationState(at now: Date = Date()) -> String {
    shouldAdaptVisualWorkForDegradedTransport(at: now) ? "degradedBackoff" : "nominal"
  }

  private func speechContextReadiness() -> String {
    streamPerformanceCounters.asrTranscriptSegments > 0 ? "ready" : "waiting"
  }

  private func visualContextReadiness(metrics: SceneContextPipelineMetrics? = nil) -> String {
    let metrics = metrics ?? sceneContextPipeline.metricsSnapshot()
    if metrics.requestsSucceeded > 0 { return "ready" }
    if metrics.requestsStarted > metrics.requestsFailed { return "analyzing" }
    if metrics.requestsFailed > 0 { return "unavailable" }
    if metrics.imagesEncoded > 0 { return "queued" }
    return "waiting"
  }

  private func faceRecognitionReadiness() -> String {
    if activeFacePersonId != nil || streamPerformanceCounters.embeddingsRequested > 0 {
      return "ready"
    }
    let cloudStatus = cloudFaceEmbeddingStatusText.lowercased()
    if cloudStatus.contains("failed") || cloudStatus.contains("unavailable") || cloudStatus.contains("warming") {
      return "localFallback"
    }
    return "onDemand"
  }

  private func refreshStreamReadinessDisplayIfNeeded(reason: String) {
    guard datIsStreamRunning || datStreamSessionStateText.lowercased().contains("streaming") else { return }
    guard pendingIdentityConfirmation == nil, activeGlassesDisplayWindow == .live else { return }
    let signature = "\(liveStreamTransportTitle())|\(liveStreamReadinessLine())"
    guard signature != lastStreamReadinessDisplaySignature else { return }
    lastStreamReadinessDisplaySignature = signature
    sendCombinedGlassesDisplayCard(reason: reason)
  }

  private func processIdentityIfNeeded(_ frame: ProcessedVideoFrame) {
    guard identityRecognitionEnabled else {
      streamPerformanceCounters.faceEmbeddingSkippedDisabled += 1
      emitStreamPerformanceCountersIfNeeded(force: false)
      return
    }
    guard !frame.identityCandidates.isEmpty else {
      streamPerformanceCounters.faceEmbeddingSkippedNoCandidate += 1
      emitStreamPerformanceCountersIfNeeded(force: false)
      identitySummaryText = "No face crop candidates"
      return
    }
    let now = Date()
    guard pendingIdentityConfirmation == nil else {
      streamPerformanceCounters.faceEmbeddingSkippedPromptActive += 1
      emitStreamPerformanceCountersIfNeeded(force: false)
      identitySummaryText = "Identity prompt active; embedding paused"
      return
    }
    let identityInterval = shouldAdaptVisualWorkForDegradedTransport(at: now)
      ? degradedIdentityProcessingMinimumInterval
      : identityProcessingMinimumInterval
    if let lastIdentityProcessingAt,
       now.timeIntervalSince(lastIdentityProcessingAt) < identityInterval {
      streamPerformanceCounters.faceEmbeddingSkippedCooldown += 1
      emitStreamPerformanceCountersIfNeeded(force: false)
      identitySummaryText = shouldAdaptVisualWorkForDegradedTransport(at: now)
        ? "Identity processing throttled for degraded video transport"
        : "Identity processing throttled"
      return
    }
    startCloudFaceWorkerForValidFaceCandidateIfNeeded(reason: "identityCandidate")
    lastIdentityProcessingAt = now
    streamPerformanceCounters.faceEmbeddingFramesSubmitted += 1
    emitStreamPerformanceCountersIfNeeded(force: false)
    Task { [weak self] in
      guard let self else { return }
      let result = await identityPipeline.process(frame: frame)
      guard let result else {
        await MainActor.run {
          self.streamPerformanceCounters.faceEmbeddingPipelineNoResult += 1
          self.emitStreamPerformanceCountersIfNeeded(force: false)
        }
        return
      }
      let snapshot = await identityPipeline.currentRunSessionSnapshot()
      await MainActor.run {
        self.applyIdentityResult(result)
        self.applyRunSessionSnapshot(snapshot)
      }
    }
  }

  private func recordFaceDetectionEventIfNeeded(_ frame: ProcessedVideoFrame) {
    guard let event = frame.faceDetectionEvent else { return }
    guard !(isLiveDATStreamActive && event.selectedFaceCount == 0) else { return }
    let now = Date()
    let shouldPersist: Bool
    if isLiveDATStreamActive {
      shouldPersist = lastFaceDetectionEventPersistedAt.map { now.timeIntervalSince($0) >= 5.0 } ?? true
    } else {
      shouldPersist = faceDetectionEventsPersisted < 30
        || (event.selectedFaceCount > 0 && lastFaceDetectionEventPersistedAt.map { now.timeIntervalSince($0) >= 1.0 } ?? true)
        || lastFaceDetectionEventPersistedAt.map { now.timeIntervalSince($0) >= 3.0 } ?? true
    }
    guard shouldPersist else { return }
    faceDetectionEventsPersisted += 1
    lastFaceDetectionEventPersistedAt = now
    streamPerformanceCounters.databaseWrites += 1
    emitStreamPerformanceCountersIfNeeded(force: false)
    Task { [weak self] in
      guard let self else { return }
      await identityPipeline.recordFaceDetectionEvent(event)
      let snapshot = await identityPipeline.currentRunSessionSnapshot()
      await MainActor.run {
        self.applyRunSessionSnapshot(snapshot)
      }
    }
  }

  private func applyIdentityResult(_ result: IdentityProcessingResult) {
    statsWindowFaceCandidates += UInt64(result.faceCandidateCount)
    statsWindowQualityPass += UInt64(result.qualityPassCount)
    if result.embeddingGenerated {
      statsWindowEmbedded += 1
      streamPerformanceCounters.embeddingsRequested += 1
      statsWindowEmbeddingDurationMS += result.embeddingLatencyMS
    }
    if result.matchDecisionText == IdentityMatchResult.Decision.known.rawValue {
      statsWindowMatched += 1
    }
    updateVideoFaceDebugMetrics(with: result.embeddingMetrics)

    let effectiveIdentity = retainedRecognizedIdentity(for: result)
    let identityUIKey = [
      effectiveIdentity.state.rawValue,
      effectiveIdentity.personId?.uuidString ?? "none",
      effectiveIdentity.displayName ?? "none",
      String(format: "%.1f", Double(effectiveIdentity.confidence * 10)),
      "\(result.faceCandidateCount)",
      "\(result.isUnknownPersonVisible)"
    ].joined(separator: "|")
    let now = Date()
    if lastIdentityUIKey == identityUIKey,
       let lastIdentityUIUpdateAt,
       now.timeIntervalSince(lastIdentityUIUpdateAt) < 1.0 {
      return
    }
    lastIdentityUIKey = identityUIKey
    lastIdentityUIUpdateAt = now

    activeFacePersonId = effectiveIdentity.personId
    activeFaceName = effectiveIdentity.displayName
    activeFaceConfidence = effectiveIdentity.confidence
    activeFaceState = effectiveIdentity.state.rawValue
    if effectiveIdentity.state == .confirmed, let personId = effectiveIdentity.personId {
      recordSpeakerTimelineEntry(personId: personId, displayName: effectiveIdentity.displayName)
      refreshPersonConversationSummaryForCurrentStreamIfNeeded(personId: personId)
    }
    recordFaceEvidenceIfNeeded(
      personId: effectiveIdentity.personId,
      displayName: effectiveIdentity.displayName,
      confidence: effectiveIdentity.confidence,
      state: effectiveIdentity.state.rawValue,
      detectedFaceCount: result.faceCandidateCount
    )
    activeIdentityName = effectiveIdentity.displayName ?? {
      switch effectiveIdentity.state {
      case .unknown:
        return "Unknown"
      case .possible, .ambiguous:
        return "Possible"
      case .confirmed:
        return effectiveIdentity.personId?.uuidString ?? "Confirmed"
      case .none, .noFace:
        return "None"
      }
    }()
    activeIdentityConfidenceText = String(format: "%.2f", Double(effectiveIdentity.confidence))
    activeIdentityStateText = effectiveIdentity.state.rawValue
    detectedFaceCount = result.faceCandidateCount
    isUnknownPersonVisible = result.isUnknownPersonVisible
    if !isLiveDATStreamActive {
      pendingEnrollmentFacePreview = result.pendingEnrollmentFacePreview
      lastEnrollmentCandidatePreview = result.lastEnrollmentCandidatePreview
    }
    hasLastEnrollmentCandidate = result.hasLastEnrollmentCandidate
    lastEnrollmentCandidateSummary = result.lastEnrollmentCandidateSummary
    faceEmbeddingModelStatusText = result.modelStatusText
    faceAlignmentWarning = result.alignmentRejectedCount > 0
      ? "Face detected but landmarks unavailable — move closer or face the camera"
      : ""
    identitySummaryText = result.summary
    pendingEnrollmentSampleText = "\(result.pendingEnrollmentAcceptedSamples)/\(result.pendingEnrollmentRequiredSamples)"
    pendingEnrollmentRejectedText = "\(result.pendingEnrollmentRejectedSamples) rejected"
    enrollmentStatusText = result.enrollmentStatusText
    capturedFaceGroups = result.capturedFaceGroups
    streamEndedReviewText = result.streamEndedReviewText
    calibrationModeText = result.calibrationModeText
    calibrationSampleCountText = result.calibrationSampleCountText
    calibrationSummaryText = result.calibrationSummaryText
    canRecordCalibrationLabel = result.canRecordCalibrationLabel
    if let snapshot = result.runSessionSnapshot {
      applyRunSessionSnapshot(snapshot)
    }
    updateGlassesFaceVisibility(for: result)
    updateGlassesIdentityConfirmation(for: result)
    updateLivePhoneAssistance()
  }

  private func retainedRecognizedIdentity(for result: IdentityProcessingResult) -> ActiveIdentityState {
    if let personId = result.activeIdentity.personId,
       result.activeIdentity.state == .confirmed || result.activeIdentity.state == .possible {
      let displayName = result.activeIdentity.displayName ?? resolvedDisplayName(for: personId)
      retainRecognizedIdentity(
        personId: personId,
        displayName: displayName,
        confidence: result.activeIdentity.confidence,
        source: "faceRecognition-\(result.activeIdentity.state.rawValue)"
      )
      return ActiveIdentityState(
        personId: personId,
        displayName: displayName,
        confidence: max(result.activeIdentity.confidence, IdentityConfig.strongMatchThreshold),
        state: .confirmed,
        confirmedAt: result.activeIdentity.confirmedAt ?? Date(),
        lastSeenAt: result.activeIdentity.lastSeenAt ?? Date()
      )
    }

    if let personId = retainedRecognizedPersonId {
      let displayName = retainedRecognizedName ?? resolvedDisplayName(for: personId)
      return ActiveIdentityState(
        personId: personId,
        displayName: displayName,
        confidence: max(retainedRecognizedConfidence, IdentityConfig.strongMatchThreshold),
        state: .confirmed,
        confirmedAt: retainedRecognizedAt,
        lastSeenAt: retainedRecognizedAt
      )
    }

    return result.activeIdentity
  }

  private func retainRecognizedIdentity(
    personId: UUID,
    displayName: String?,
    confidence: Float,
    source: String
  ) {
    let previousPersonId = retainedRecognizedPersonId
    let previousConfidence = retainedRecognizedConfidence
    let samePerson = previousPersonId == personId
    retainedRecognizedPersonId = personId
    if let trimmedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
       !trimmedName.isEmpty {
      retainedRecognizedName = trimmedName
    }
    retainedRecognizedConfidence = samePerson
      ? max(retainedRecognizedConfidence, confidence)
      : confidence
    retainedRecognizedAt = Date()
    guard previousPersonId != personId || confidence > previousConfidence + 0.01 else { return }
    AppLogger.log(
      .memory,
      "Retained recognized identity person=\(personId.uuidString) name=\"\(retainedRecognizedName ?? "unknown")\" confidence=\(String(format: "%.3f", Double(retainedRecognizedConfidence))) source=\(source)"
    )
  }

  private func clearRetainedRecognizedIdentity(reason: String) {
    guard let retainedPersonId = retainedRecognizedPersonId else { return }
    let retainedName = retainedRecognizedName
    retainedRecognizedPersonId = nil
    retainedRecognizedName = nil
    retainedRecognizedConfidence = 0
    retainedRecognizedAt = nil
    if activeFacePersonId == retainedPersonId {
      activeFacePersonId = nil
      activeFaceName = nil
      activeFaceConfidence = 0
      activeFaceState = ActiveIdentityState.State.none.rawValue
      activeIdentityName = "None"
      activeIdentityConfidenceText = "0.00"
      activeIdentityStateText = ActiveIdentityState.State.none.rawValue
    }
    if livePhoneAssistancePinnedPersonId == retainedPersonId {
      livePhoneAssistancePinnedPersonId = nil
    }
    if currentGlassesDisplayPersonId == retainedPersonId {
      currentGlassesDisplayPersonId = nil
      currentGlassesDisplayName = nil
    }
    AppLogger.log(
      .memory,
      "Retained recognized identity cleared person=\(retainedPersonId.uuidString) name=\"\(retainedName ?? "unknown")\" reason=\(reason)"
    )
  }

  private func updateGlassesFaceVisibility(for result: IdentityProcessingResult) {
    let section: AssistanceDisplaySection?
    let recognitionUnavailable = Self.shouldShowFaceRecognitionUnavailableStatus(
      faceCandidateCount: result.faceCandidateCount,
      qualityPassCount: result.qualityPassCount,
      embeddingGenerated: result.embeddingGenerated,
      matchDecisionText: result.matchDecisionText
    )
    if recognitionUnavailable,
       Self.isCloudFaceRecognitionWarmingStatus(result.modelStatusText) {
      section = AssistanceDisplaySection(
        title: "Face recognition starting",
        lines: [
          "I can see a face. Recognition is still starting.",
          result.modelStatusText
        ]
      )
    } else if recognitionUnavailable {
      section = AssistanceDisplaySection(
        title: "Face recognition off",
        lines: [
          "I can see a face, but recognition is unavailable.",
          result.modelStatusText
        ]
      )
    } else if result.faceCandidateCount > 0, result.qualityPassCount == 0 {
      section = AssistanceDisplaySection(
        title: "Face not clear",
        lines: [
          "I can see a face, but it is not clear enough to recognize.",
          "Move closer, center the face, and improve lighting."
        ]
      )
    } else if result.alignmentRejectedCount > 0 {
      section = AssistanceDisplaySection(
        title: "Face not clear",
        lines: [
          "Face landmarks are not clear enough for recognition.",
          "Ask the person to face the camera or move into better light."
        ]
      )
    } else if result.faceCandidateCount == 0,
              datIsStreamRunning,
              hasReceivedFirstFrame {
      section = AssistanceDisplaySection(
        title: "No clear face",
        lines: [
          "I cannot see a face clearly yet.",
          "Point the glasses toward the person."
        ]
      )
    } else {
      section = nil
    }

    currentGlassesFaceVisibilitySection = section
  }

  private func updateGlassesIdentityConfirmation(for result: IdentityProcessingResult) {
    guard datIsStreamRunning else { return }
    if case .selectingPerson = pendingIdentityConfirmation {
      return
    }

    if Self.shouldShowFaceRecognitionUnavailableStatus(
      faceCandidateCount: result.faceCandidateCount,
      qualityPassCount: result.qualityPassCount,
      embeddingGenerated: result.embeddingGenerated,
      matchDecisionText: result.matchDecisionText
    ) {
      consecutiveUnknownIdentityAttempts = 0
      if case .unknown = pendingIdentityConfirmation {
        pendingIdentityConfirmation = nil
        currentGlassesIdentityPromptSection = nil
        currentIdentityConfirmationThumbnail = nil
        clearIdentityDisplayImageURI()
        sendCombinedGlassesDisplayCard(reason: "identity-confirm-suppressed-recognition-unavailable")
      }
      if !warnedUnavailableFaceEmbeddingPromptThisStream {
        warnedUnavailableFaceEmbeddingPromptThisStream = true
        AppLogger.log(
          .display,
          "warning...---- Suppressed unknown-person confirmation because face embedding did not run. matchDecision=\(result.matchDecisionText) modelStatus=\"\(result.modelStatusText)\""
        )
      }
      return
    }

    if Self.shouldAskToConfirmRecognizedIdentity(
      activeIdentityState: result.activeIdentity.state,
      personId: result.activeIdentity.personId,
      embeddingGenerated: result.embeddingGenerated,
      matchDecisionText: result.matchDecisionText
    ),
       let personId = result.activeIdentity.personId {
      consecutiveUnknownIdentityAttempts = 0
      guard !promptedIdentityPersonIds.contains(personId) else { return }
      let displayName = result.activeIdentity.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
      let name = displayName?.isEmpty == false ? displayName! : resolvedDisplayName(for: personId, fallback: "this person") ?? "this person"
      promptedIdentityPersonIds.insert(personId)
      pendingIdentityConfirmation = .recognized(personId: personId, displayName: name)
      let thumbnailSelection = Self.identityConfirmationThumbnailForRecognizedPerson(
        currentRecognitionFaceThumbnail: result.currentRecognitionFacePreview,
        savedPersonThumbnail: thumbnailForPerson(personId)
      )
      currentIdentityConfirmationThumbnail = thumbnailSelection.image
      clearIdentityDisplayImageURI()
      startIdentityDisplayImageUpload(
        from: currentIdentityConfirmationThumbnail,
        purpose: "recognized-\(name)",
        refreshReason: "identity-confirm-thumbnail-url-ready"
      )
      activeGlassesDisplayWindow = .live
      currentGlassesIdentityPromptSection = AssistanceDisplaySection(
        title: "Is this \(name)?",
        lines: [
          "Use the check button to confirm.",
          "Use X to choose another person or Unknown."
        ]
      )
      AppLogger.log(
        .display,
        "Identity confirmation prompt shown personId=\(personId.uuidString) name=\(name) state=\(result.activeIdentity.state.rawValue) confidence=\(String(format: "%.3f", Double(result.activeIdentity.confidence))) thumbnail=\(currentIdentityConfirmationThumbnail == nil ? "none" : "ready") thumbnailSource=\(thumbnailSelection.source) imageURI=\(currentIdentityConfirmationImageURI == nil ? "none" : "attached")"
      )
      publishPhoneIdentityPromptIfNeeded()
      if currentIdentityConfirmationThumbnail == nil {
        refreshIdentityConfirmationThumbnailIfNeeded(personId: personId)
      }
      sendCombinedGlassesDisplayCard(reason: "identity-confirm-recognized")
      return
    }

    if Self.shouldAskToConfirmUnknownIdentity(
      activeIdentityState: result.activeIdentity.state,
      isUnknownPersonVisible: result.isUnknownPersonVisible,
      embeddingGenerated: result.embeddingGenerated,
      matchDecisionText: result.matchDecisionText
    ) {
      consecutiveUnknownIdentityAttempts += 1
      guard consecutiveUnknownIdentityAttempts >= 3,
            !promptedUnknownIdentityThisStream,
            pendingIdentityConfirmation == nil else { return }
      promptedUnknownIdentityThisStream = true
      pendingIdentityConfirmation = .unknown
      currentIdentityConfirmationThumbnail = result.pendingEnrollmentFacePreview
        ?? result.lastEnrollmentCandidatePreview
      clearIdentityDisplayImageURI()
      startIdentityDisplayImageUpload(
        from: currentIdentityConfirmationThumbnail,
        purpose: "unknown-person",
        refreshReason: "identity-confirm-thumbnail-url-ready"
      )
      activeGlassesDisplayWindow = .live
      currentGlassesIdentityPromptSection = AssistanceDisplaySection(
        title: "Is this person unknown?",
        lines: [
          "Use the check button to keep transcripts unknown.",
          "Use X to choose a saved person."
        ]
      )
      publishPhoneIdentityPromptIfNeeded()
      sendCombinedGlassesDisplayCard(reason: "identity-confirm-unknown")
    } else {
      consecutiveUnknownIdentityAttempts = 0
    }
  }

  private func confirmRecognizedPersonOnGlasses() {
    guard case .recognized(let personId, let displayName) = pendingIdentityConfirmation else { return }
    suppressGlassesStopAfterIdentityConfirmation(reason: "confirmRecognizedPerson")
    let promptThumbnail = currentIdentityConfirmationThumbnail ?? thumbnailForPerson(personId)
    confirmConversationPartnerPresenceOnGlasses(
      personId: personId,
      displayName: displayName,
      evidence: "glassesConfirmed"
    )
    retainRecognizedIdentity(
      personId: personId,
      displayName: displayName,
      confidence: 1.0,
      source: "glassesConfirmed"
    )
    recordSpeakerTimelineEntry(personId: personId, displayName: displayName)
    livePhoneAssistancePinnedPersonId = personId
    currentGlassesDisplayPersonId = personId
    currentGlassesDisplayName = displayName
    pendingIdentityConfirmation = nil
    currentGlassesIdentityPromptSection = nil
    currentIdentityConfirmationThumbnail = nil
    clearIdentityDisplayImageURI()
    phoneAssistanceDismissed = false
    phoneAssistanceTitleText = displayName
    phoneAssistanceDetailText = "Confirmed for live transcript attribution. Loading saved memory."
    phoneAssistanceStatusText = "Identity confirmed"
    phoneAssistanceThumbnail = promptThumbnail
    let publishedCachedSummary = publishConfirmedPersonSummaryOrRefresh(personId: personId)
    if !publishedCachedSummary {
      sendCombinedGlassesDisplayCard(reason: "identity-confirmed-recognized")
    }
  }

  private func confirmUnknownPersonOnGlasses() {
    guard Self.shouldAcceptUnknownIdentityConfirmation(pendingIdentityConfirmation) else {
      AppLogger.log(.display, "Ignored stale unknown-person confirmation because no unknown identity prompt is active")
      return
    }
    suppressGlassesStopAfterIdentityConfirmation(reason: "confirmUnknownPerson")
    let promptThumbnail = currentIdentityConfirmationThumbnail
    clearRetainedRecognizedIdentity(reason: "glassesConfirmedUnknown")
    glassesConfirmedConversationPersonId = nil
    glassesConfirmedConversationPersonName = nil
    pendingIdentityConfirmation = nil
    currentGlassesIdentityPromptSection = nil
    currentIdentityConfirmationThumbnail = nil
    clearIdentityDisplayImageURI()
    phoneAssistanceDismissed = false
    phoneAssistanceTitleText = "Unknown confirmed"
    phoneAssistanceDetailText = "Live transcripts will stay unassigned until you choose a saved person."
    phoneAssistanceStatusText = "Identity confirmed"
    phoneAssistanceThumbnail = promptThumbnail
    sendCombinedGlassesDisplayCard(reason: "identity-confirmed-unknown")
  }

  nonisolated private static func shouldAcceptUnknownIdentityConfirmation(_ pending: GlassesIdentityConfirmation?) -> Bool {
    switch pending {
    case .unknown, .selectingPerson:
      return true
    case .recognized, nil:
      return false
    }
  }

  private func suppressGlassesStopAfterIdentityConfirmation(reason: String) {
    suppressGlassesStopUntil = Date().addingTimeInterval(Self.identityConfirmationStopSuppressionSeconds)
    AppLogger.log(
      .display,
      "Temporarily suppressing glasses stop during identity confirmation handoff reason=\(reason) seconds=\(String(format: "%.2f", Self.identityConfirmationStopSuppressionSeconds))"
    )
  }

  private func shouldSuppressGlassesStopAfterIdentityConfirmation(now: Date = Date()) -> Bool {
    guard let suppressGlassesStopUntil else { return false }
    if now < suppressGlassesStopUntil {
      return true
    }
    self.suppressGlassesStopUntil = nil
    return false
  }

  private func beginGlassesIdentityCorrection() async {
    showGlassesIdentityCorrectionLoading()
    await loadGlassesIdentityCorrectionEntries()
  }

  private func showGlassesIdentityCorrectionLoading() {
    pendingIdentityConfirmation = .selectingPerson
    activeGlassesDisplayWindow = .people
    glassesIdentitySelectionEntries = []
    glassesIdentitySelectionIndex = 0
    currentGlassesIdentityPromptSection = AssistanceDisplaySection(
      title: "Pick person",
      lines: ["Loading saved people."]
    )
    currentIdentityConfirmationThumbnail = nil
    clearIdentityDisplayImageURI()
    publishPhoneIdentityPromptIfNeeded()
    sendCombinedGlassesDisplayCard(reason: "identity-correction-loading")
  }

  private func loadGlassesIdentityCorrectionEntries() async {
    let entries = await identityPipeline.loadPeopleForDictionary()
    peopleDictionaryEntries = entries
    glassesIdentitySelectionEntries = entries.sorted { left, right in
      (left.lastSeen ?? .distantPast) > (right.lastSeen ?? .distantPast)
    }
    glassesIdentitySelectionIndex = 0
    updateGlassesIdentitySelectionSection()
    sendCombinedGlassesDisplayCard(reason: "identity-correction-picker")
  }

  private func moveGlassesIdentitySelection(offset: Int) {
    guard case .selectingPerson = pendingIdentityConfirmation,
          !glassesIdentitySelectionEntries.isEmpty else { return }
    let count = glassesIdentitySelectionEntries.count
    glassesIdentitySelectionIndex = (glassesIdentitySelectionIndex + offset + count) % count
    updateGlassesIdentitySelectionSection()
    sendCombinedGlassesDisplayCard(reason: "identity-correction-move")
  }

  private func confirmSelectedPersonOnGlasses() {
    guard case .selectingPerson = pendingIdentityConfirmation else { return }
    guard !glassesIdentitySelectionEntries.isEmpty else {
      confirmUnknownPersonOnGlasses()
      return
    }
    suppressGlassesStopAfterIdentityConfirmation(reason: "confirmSelectedPerson")
    let selected = glassesIdentitySelectionEntries[min(glassesIdentitySelectionIndex, glassesIdentitySelectionEntries.count - 1)]
    confirmConversationPartnerPresenceOnGlasses(
      personId: selected.id,
      displayName: selected.displayName,
      evidence: "glassesCorrectionSelected"
    )
    retainRecognizedIdentity(
      personId: selected.id,
      displayName: selected.displayName,
      confidence: 1.0,
      source: "glassesCorrectionSelected"
    )
    recordSpeakerTimelineEntry(personId: selected.id, displayName: selected.displayName)
    livePhoneAssistancePinnedPersonId = selected.id
    currentGlassesDisplayPersonId = selected.id
    currentGlassesDisplayName = selected.displayName
    pendingIdentityConfirmation = nil
    currentGlassesIdentityPromptSection = nil
    currentIdentityConfirmationThumbnail = nil
    clearIdentityDisplayImageURI()
    phoneAssistanceDismissed = false
    phoneAssistanceTitleText = selected.displayName
    phoneAssistanceDetailText = "Selected for live transcript attribution. Loading saved memory."
    phoneAssistanceStatusText = "Identity corrected"
    phoneAssistanceThumbnail = selected.thumbnail
    let publishedCachedSummary = publishConfirmedPersonSummaryOrRefresh(personId: selected.id)
    if !publishedCachedSummary {
      sendCombinedGlassesDisplayCard(reason: "identity-correction-selected")
    }
  }

  private func confirmConversationPartnerPresenceOnGlasses(
    personId: UUID,
    displayName: String,
    evidence: String
  ) {
    let now = Date()
    glassesConfirmedConversationPersonId = personId
    glassesConfirmedConversationPersonIds.insert(personId)
    glassesConfirmedConversationPersonName = displayName
    activeFacePersonId = personId
    activeFaceName = displayName
    activeFaceConfidence = 1.0
    activeFaceState = ActiveIdentityState.State.confirmed.rawValue
    activeIdentityName = displayName
    activeIdentityConfidenceText = "1.00"
    activeIdentityStateText = ActiveIdentityState.State.confirmed.rawValue
    appendConversationPartnerEvidence(ConversationPartnerEvidence(
      source: .userConfirmation,
      personId: personId,
      displayName: displayName,
      confidence: 1.0,
      timestamp: now,
      validUntil: now.addingTimeInterval(180),
      details: evidence
    ))
    refreshConversationPartnerState(now: now)
    refreshLiveRecallPresenceLines()
    AppLogger.log(
      .display,
      "Identity confirmation updated active presence personId=\(personId.uuidString) name=\"\(displayName)\" evidence=\(evidence)"
    )
  }

  private func updateGlassesIdentitySelectionSection() {
    if glassesIdentitySelectionEntries.isEmpty {
      currentIdentityConfirmationThumbnail = nil
      clearIdentityDisplayImageURI()
      currentGlassesIdentityPromptSection = AssistanceDisplaySection(
        title: "Pick person",
        lines: [
          "No saved people yet.",
          "Choose Unknown to keep this person unenrolled."
        ]
      )
      publishPhoneIdentityPromptIfNeeded()
      return
    }
    let selected = glassesIdentitySelectionEntries[min(glassesIdentitySelectionIndex, glassesIdentitySelectionEntries.count - 1)]
    currentIdentityConfirmationThumbnail = selected.thumbnail
    clearIdentityDisplayImageURI()
    startIdentityDisplayImageUpload(
      from: selected.thumbnail,
      purpose: "select-\(selected.displayName)",
      refreshReason: "identity-selection-thumbnail-url-ready"
    )
    currentGlassesIdentityPromptSection = AssistanceDisplaySection(
      title: "Pick person \(glassesIdentitySelectionIndex + 1)/\(glassesIdentitySelectionEntries.count)",
      lines: [
        "Selected: \(selected.displayName)",
        "Previous or Next changes the selected person.",
        "Check chooses this person; Unknown keeps unenrolled."
      ]
    )
    publishPhoneIdentityPromptIfNeeded()
  }

  private func applyRunSessionSnapshot(_ snapshot: RunSessionSnapshot) {
    currentAppRunIDText = snapshot.appRunShortText
    currentConversationSessionIDText = snapshot.conversationShortText
    sessionDetectedFacesText = "\(snapshot.detectedFacesThisSession)"
    sessionAcceptedFaceCropsText = "\(snapshot.acceptedFaceCropsThisSession)"
    sessionEmbeddingsSavedText = "\(snapshot.embeddingsSavedThisSession)"
    sessionTranscriptChunksSavedText = "\(snapshot.transcriptChunksSavedThisSession)"
  }

  private func resetPostSessionAttributionState() {
    clearRetainedRecognizedIdentity(reason: "resetPostSessionAttributionState")
    activeFacePersonId = nil
    activeFaceName = nil
    activeFaceConfidence = 0
    activeFaceState = "none"
    lastIdentityUIUpdateAt = nil
    lastIdentityUIKey = nil
    latestMouthMovementScore = 0
    speakerEvidenceTimeline = []
    faceEvidenceTimeline = []
    conversationPartnerEvidence = []
    conversationPartnerTimeline = []
    presenceTracker.reset()
    lastSavedPresenceEpisodeSignatures = [:]
    lastPresenceEpisodeSavedAt = [:]
    lastNameAddressLLMAt = nil
    activeConversationPartnerState = .empty
    activityModeClassificationTask?.cancel()
    activityModeClassificationTask = nil
    currentActivityModeClassification = .unknown
    activityModeStabilizer.reset()
    currentActivityModeEpisode = nil
    recentActivityModeSceneContexts = []
    lastActivityModeClassificationAt = nil
    lastActivityModeClassificationSignature = nil
    cloudFaceWorkerStartedAfterFaceCandidate = false
    activeConversationPartnerName = "None"
    activeConversationPartnerStateText = "none"
    activeConversationPartnerConfidenceText = "0.00"
    activeConversationPartnerEvidenceText = "No partner evidence yet"
    presencePipelineVerificationText = "Presence: waiting for name or identity evidence"
    sceneContextPipelineVerificationText = "5W/1H: waiting for scene context"
    activityModeVerificationText = "Activity mode: waiting for stream context"
  }

  private func resetLivePhoneAssistanceState() {
    invalidateAssistanceWork(reason: "resetLivePhoneAssistanceState", cancelDisplayWork: false)
    livePhoneAssistancePinnedPersonId = nil
    livePhoneAssistanceDismissedPersonId = nil
    conversationSummaryRefreshedPersonIdsThisStream = []
    phoneAssistanceDismissed = false
    phoneAssistanceTitleText = "Memento"
    phoneAssistanceDetailText = "Live memory will appear when the stream recognizes someone."
    phoneAssistanceStatusText = "Ready"
    phoneAssistanceThumbnail = nil
    currentGlassesAssistanceCard = nil
    currentGlassesSceneContextSections = []
    currentGlassesLiveRecallSections = []
    currentGlassesIdentityPromptSection = nil
    currentIdentityConfirmationThumbnail = nil
    clearIdentityDisplayImageURI()
    currentGlassesFaceVisibilitySection = nil
    activeGlassesDisplayWindow = .live
    currentGlassesDisplayPersonId = nil
    currentGlassesDisplayName = nil
    lastGlassesDisplayCardForActions = nil
    pendingIdentityConfirmation = nil
    promptedIdentityPersonIds = []
    promptedUnknownIdentityThisStream = false
    consecutiveUnknownIdentityAttempts = 0
    warnedUnavailableFaceEmbeddingPromptThisStream = false
    glassesIdentitySelectionEntries = []
    glassesIdentitySelectionIndex = 0
    glassesConfirmedConversationPersonId = nil
    glassesConfirmedConversationPersonIds = []
    glassesConfirmedConversationPersonName = nil
    glassesPeopleListPage = 0
    lastRecordedGlassesDisplayCardKey = ""
    liveCaptionDisplayLines = []
    lastLiveCaptionDisplayText = ""
    liveQuestionAssembler.reset()
    liveMemoryTriggerInFlight = false
    pendingLiveQuestionWorks.removeAll()
    lastLiveMemoryTriggerText = ""
    lastLiveMemoryTriggerAt = nil
    memoryTriggerVerificationText = "Memory trigger: waiting for a past-reference question"
    glassesDisplaySendTask?.cancel()
    glassesDisplaySendTask = nil
  }

  private func prepareDisplayForStreamStop(reason: String) {
    glassesDisplaySendTask?.cancel()
    glassesDisplaySendTask = nil
    suppressGlassesStopUntil = nil
    currentGlassesFaceVisibilitySection = nil
    currentGlassesIdentityPromptSection = nil
    currentIdentityConfirmationThumbnail = nil
    clearIdentityDisplayImageURI()
    pendingIdentityConfirmation = nil
    if activeGlassesDisplayWindow == .live {
      currentGlassesAssistanceCard = nil
    }
    AppLogger.log(.display, "Live display state cleared for stream stop reason=\(reason)")
  }

  private func invalidateAssistanceWork(reason: String, cancelDisplayWork: Bool) {
    assistanceGeneration &+= 1
    AppLogger.log(.memory, "Phone assistance work invalidated generation=\(assistanceGeneration) reason=\(reason) cancelDisplayWork=\(cancelDisplayWork)")
    if cancelDisplayWork {
      Task { @MainActor [weak self] in
        await self?.datManager.detachAssistanceDisplay(reason: reason)
      }
    }
  }

  func dismissPhoneAssistance() {
    livePhoneAssistanceDismissedPersonId = livePhoneAssistancePinnedPersonId ?? activeFacePersonId
    livePhoneAssistancePinnedPersonId = nil
    phoneAssistanceDismissed = true
    AppLogger.log(.memory, "Phone assistance dismissed personId=\(livePhoneAssistanceDismissedPersonId?.uuidString ?? "none")")
  }

  func sendTestGlassesDisplayCard() {
    activateGlassesDisplayControl()
  }

  func activateGlassesDisplayControl() {
    inputMode = .realGlasses
    sourceStateText = inputMode.rawValue
    guard !datManager.isSimulator else {
      showError("Real Meta glasses display requires a physical iPhone.")
      return
    }
    guard datRegistrationStateText == "registered" else {
      showError("Connect glasses before activating the Memento display.")
      return
    }

    let readinessLine = canStartRealStream
      ? "Ready to start stream"
      : datStartReadinessReasonText
    let deviceLine = datHasActiveDevice
      ? "Glasses connected"
      : "Waiting for active glasses"
    let card = MementoGlassesDisplayRenderer.ready(
      canStartStream: canStartRealStream,
      deviceLine: deviceLine,
      readinessLine: readinessLine
    )

    currentGlassesDisplayPersonId = nil
    currentGlassesDisplayName = nil
    currentGlassesAssistanceCard = card
    activeGlassesDisplayWindow = .live
    phoneAssistanceTitleText = "Memento"
    phoneAssistanceDetailText = "Glasses controls are being sent."
    phoneAssistanceStatusText = "Sending controls to glasses"
    sendCombinedGlassesDisplayCard(reason: "display-control")
  }

  private func updateLivePhoneAssistance() {
    if publishPhoneIdentityPromptIfNeeded() {
      return
    }

    let identity = currentAssistanceIdentity()
    if case .known = identity, let personId = activeFacePersonId {
      if livePhoneAssistanceDismissedPersonId == personId {
        return
      }
      if livePhoneAssistancePinnedPersonId == personId {
        return
      }
      phoneAssistanceDismissed = false
      livePhoneAssistancePinnedPersonId = personId
      guard conversationSummaryCache[personId] != nil else {
        refreshPersonConversationSummaryIfNeeded(personId: personId, forceSpeak: false, forceRefresh: false)
        let loadingCard = assistanceCardFormatter.makeCard(
          identity: identity,
          memory: currentAssistanceMemorySnapshot(),
          displayStatus: .fallback("phone")
        )
        let status = conversationSummaryInFlight.contains(personId)
          ? "DeepSeek summarizing saved conversations"
          : phoneAssistanceStatusText
        publishPhoneAssistanceCard(loadingCard, status: status, personId: personId)
        publishGlassesAssistanceCard(
          identity: identity,
          memory: currentAssistanceMemorySnapshot(personId: personId),
          reason: "known-person-summary-loading"
        )
        AppLogger.log(.memory, "Phone assistance waiting for person summary personId=\(personId.uuidString) name=\(activeIdentityName) confidence=\(String(format: "%.3f", Double(activeFaceConfidence))) state=\(activeIdentityStateText)")
        return
      }
      let card = assistanceCardFormatter.makeCard(
        identity: identity,
        memory: currentAssistanceMemorySnapshot(personId: personId),
        displayStatus: .fallback("phone")
      )
      publishPhoneAssistanceCard(card, status: "Phone display fallback", personId: personId)
      publishGlassesAssistanceCard(
        identity: identity,
        memory: currentAssistanceMemorySnapshot(personId: personId),
        reason: "known-person-summary"
      )
      return
    }

    if let pinnedPersonId = livePhoneAssistancePinnedPersonId,
       livePhoneAssistanceDismissedPersonId != pinnedPersonId {
      phoneAssistanceDismissed = false
      if let summary = conversationSummaryCache[pinnedPersonId] {
        let pinnedIdentity = AssistanceIdentityState.known(
          name: summary.displayName,
          confidence: max(activeFaceConfidence, 0.70),
          userConfirmed: true
        )
        let card = assistanceCardFormatter.makeCard(
          identity: pinnedIdentity,
          memory: currentAssistanceMemorySnapshot(personId: pinnedPersonId),
          displayStatus: .fallback("phone")
        )
        publishPhoneAssistanceCard(card, status: "Pinned until stream ends", personId: pinnedPersonId)
        publishGlassesAssistanceCard(
          identity: pinnedIdentity,
          memory: currentAssistanceMemorySnapshot(personId: pinnedPersonId),
          reason: "pinned-known-person-summary"
        )
      }
      return
    }

    phoneAssistanceDismissed = false
    let card = assistanceCardFormatter.makeCard(
      identity: identity,
      memory: currentAssistanceMemorySnapshot(),
      displayStatus: .fallback("phone")
    )
    publishPhoneAssistanceCard(card, status: "Phone display fallback")
    if Self.shouldPublishLiveDisplayAfterNoConfirmedPerson(
      datIsStreamRunning: datIsStreamRunning,
      streamStateText: datStreamSessionStateText
    ) {
      publishGlassesAssistanceCard(
        identity: identity,
        memory: currentAssistanceMemorySnapshot(),
        reason: "no-confirmed-person"
      )
    } else {
      currentGlassesAssistanceCard = nil
      currentGlassesFaceVisibilitySection = nil
    }
    AppLogger.log(.memory, "Phone assistance display updated identity=\(identity) state=\(activeIdentityStateText) confidence=\(String(format: "%.3f", Double(activeFaceConfidence))) faces=\(detectedFaceCount)")
  }

  @discardableResult
  private func publishPhoneIdentityPromptIfNeeded() -> Bool {
    switch pendingIdentityConfirmation {
    case .recognized(_, let displayName):
      phoneAssistanceDismissed = false
      phoneAssistanceTitleText = "Is this \(displayName)?"
      phoneAssistanceDetailText = [
        "Confirm the face match before using this identity for live transcripts.",
        "Use the check button for Yes.",
        "Use X to choose another saved person or Unknown."
      ].joined(separator: "\n")
      phoneAssistanceStatusText = "Waiting for identity feedback"
      phoneAssistanceThumbnail = currentIdentityConfirmationThumbnail
      return true
    case .unknown:
      phoneAssistanceDismissed = false
      phoneAssistanceTitleText = "Is this person unknown?"
      phoneAssistanceDetailText = [
        "Confirm before keeping this person unassigned in live transcripts.",
        "Use the check button for Unknown.",
        "Use X to choose a saved person."
      ].joined(separator: "\n")
      phoneAssistanceStatusText = "Waiting for identity feedback"
      phoneAssistanceThumbnail = currentIdentityConfirmationThumbnail
      return true
    case .selectingPerson:
      phoneAssistanceDismissed = false
      if glassesIdentitySelectionEntries.isEmpty {
        phoneAssistanceTitleText = "Choose the correct person"
        phoneAssistanceDetailText = "Loading saved people for identity correction."
        phoneAssistanceThumbnail = nil
      } else {
        let selected = glassesIdentitySelectionEntries[min(glassesIdentitySelectionIndex, glassesIdentitySelectionEntries.count - 1)]
        phoneAssistanceTitleText = "Choose the correct person"
        phoneAssistanceDetailText = [
          "Selected: \(selected.displayName)",
          "Use Previous or Next to change the selection.",
          "Use the check button to choose this person, or Unknown to keep unenrolled."
        ].joined(separator: "\n")
        phoneAssistanceThumbnail = selected.thumbnail
      }
      phoneAssistanceStatusText = "Waiting for identity correction"
      return true
    case nil:
      return false
    }
  }

  private func refreshIdentityConfirmationThumbnailIfNeeded(personId: UUID) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      guard self.currentIdentityConfirmationThumbnail == nil else { return }
      guard let thumbnail = await self.identityPipeline.thumbnailImage(forPersonId: personId) else { return }
      guard case .recognized(let pendingPersonId, _) = self.pendingIdentityConfirmation,
            pendingPersonId == personId else { return }
      self.currentIdentityConfirmationThumbnail = thumbnail
      self.startIdentityDisplayImageUpload(
        from: thumbnail,
        purpose: "recognized-refresh-\(personId.uuidString.prefix(8))",
        refreshReason: "identity-confirm-thumbnail-refresh"
      )
      self.publishPhoneIdentityPromptIfNeeded()
    }
  }

  nonisolated static func identityConfirmationThumbnailForRecognizedPerson(
    currentRecognitionFaceThumbnail: UIImage?,
    savedPersonThumbnail: UIImage?
  ) -> IdentityPromptThumbnailSelection {
    if let currentRecognitionFaceThumbnail {
      return IdentityPromptThumbnailSelection(image: currentRecognitionFaceThumbnail, source: "currentRecognitionFaceCrop")
    }
    if let savedPersonThumbnail {
      return IdentityPromptThumbnailSelection(image: savedPersonThumbnail, source: "savedPersonThumbnail")
    }
    return IdentityPromptThumbnailSelection(image: nil, source: "none")
  }

  private func publishPhoneAssistanceCard(_ card: AssistanceDisplayCard, status: String, personId: UUID? = nil) {
    phoneAssistanceTitleText = card.title
    phoneAssistanceDetailText = card.lines.isEmpty
      ? "No saved conversation summary yet."
      : card.lines.joined(separator: "\n")
    phoneAssistanceStatusText = status
    phoneAssistanceThumbnail = thumbnailForPerson(personId ?? card.personId ?? livePhoneAssistancePinnedPersonId ?? activeFacePersonId)
  }

  private func thumbnailForPerson(_ personId: UUID?) -> UIImage? {
    guard let personId else { return nil }
    return peopleDictionaryEntries.first(where: { $0.id == personId })?.thumbnail
  }

  private func startIdentityDisplayImageUpload(
    from thumbnail: UIImage?,
    purpose: String,
    refreshReason: String
  ) {
    guard let thumbnail else { return }
    guard let jpegData = Self.displayImageJPEGData(from: thumbnail) else {
      AppLogger.log(.display, "Identity prompt thumbnail export failed purpose=\(purpose): image could not be encoded")
      return
    }
    let token = UUID()
    identityDisplayImageUploadTask?.cancel()
    identityDisplayImageUploadTask = nil
    identityDisplayImageUploadToken = token
    AppLogger.log(.display, "Identity prompt thumbnail upload queued purpose=\(purpose) bytes=\(jpegData.count)")
    identityDisplayImageUploadTask = Task.detached(priority: .utility) { [jpegData, purpose, refreshReason, token] in
      do {
        let url = try await Self.uploadDisplayImageForGlasses(jpegData: jpegData)
        let probe = await Self.probeDisplayImageURL(url)
        await MainActor.run { [weak self] in
          guard let self, self.identityDisplayImageUploadToken == token else { return }
          guard probe.isRenderable else {
            AppLogger.log(
              .display,
              "Identity prompt thumbnail signed URL rejected purpose=\(purpose) scheme=\(url.scheme ?? "none") host=\(url.host ?? "none") path=\(url.path) bytes=\(url.absoluteString.utf8.count) probe=\(probe.summary)"
            )
            return
          }
          self.currentIdentityConfirmationImageURI = url.absoluteString
          AppLogger.log(
            .display,
            "Identity prompt thumbnail signed URL ready purpose=\(purpose) scheme=\(url.scheme ?? "none") host=\(url.host ?? "none") path=\(url.path) bytes=\(url.absoluteString.utf8.count) probe=\(probe.summary)"
          )
          self.sendCombinedGlassesDisplayCard(reason: refreshReason, delayNanoseconds: 0)
        }
      } catch is CancellationError {
        return
      } catch {
        await MainActor.run { [weak self] in
          guard let self, self.identityDisplayImageUploadToken == token else { return }
          AppLogger.log(.display, "Identity prompt thumbnail upload failed purpose=\(purpose): \(error.localizedDescription)")
        }
      }
    }
  }

  private func clearIdentityDisplayImageURI() {
    identityDisplayImageUploadTask?.cancel()
    identityDisplayImageUploadTask = nil
    identityDisplayImageUploadToken = nil
    currentIdentityConfirmationImageURI = nil
  }

  nonisolated static func displayImageJPEGData(
    from image: UIImage,
    maxPixelDimension: CGFloat = 64,
    contentScale: CGFloat = 0.76,
    compressionQuality: CGFloat = 0.72
  ) -> Data? {
    let displayImage = resizedDisplayImage(
      image,
      maxPixelDimension: maxPixelDimension,
      contentScale: contentScale
    )
    return displayImage.jpegData(compressionQuality: compressionQuality)
  }

  nonisolated private static func uploadDisplayImageForGlasses(jpegData: Data) async throws -> URL {
    let client = try SupabaseClient.shared()
    let ownerFolder = try await client.storageOwnerFolder()
    let objectPath = "\(ownerFolder)/display-thumbnails/\(UUID().uuidString).jpg"
    try await client.uploadStorageObject(
      bucketID: displayImageBucketID,
      objectPath: objectPath,
      data: jpegData,
      contentType: "image/jpeg"
    )
    return try await client.createSignedStorageURL(
      bucketID: displayImageBucketID,
      objectPath: objectPath,
      expiresIn: displayImageSignedURLExpirationSeconds
    )
  }

  private struct DisplayImageURLProbe: Sendable {
    let status: Int?
    let mime: String
    let byteCount: Int
    let imageSize: String
    let error: String?

    var isRenderable: Bool {
      guard let status, (200..<300).contains(status), error == nil else { return false }
      return imageSize != "decodeFailed"
    }

    var summary: String {
      if let error {
        return "failed=\(error)"
      }
      return "status=\(status ?? -1);mime=\(mime);bytes=\(byteCount);image=\(imageSize)"
    }
  }

  nonisolated private static func probeDisplayImageURL(_ url: URL) async -> DisplayImageURLProbe {
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    request.timeoutInterval = 8
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      let status = (response as? HTTPURLResponse)?.statusCode ?? -1
      let mime = response.mimeType ?? "unknown"
      let decoded = UIImage(data: data)
      let sizeText: String
      if let decoded {
        sizeText = "\(Int(decoded.size.width * decoded.scale))x\(Int(decoded.size.height * decoded.scale))"
      } else {
        sizeText = "decodeFailed"
      }
      return DisplayImageURLProbe(
        status: status,
        mime: mime,
        byteCount: data.count,
        imageSize: sizeText,
        error: nil
      )
    } catch {
      return DisplayImageURLProbe(
        status: nil,
        mime: "unknown",
        byteCount: 0,
        imageSize: "decodeFailed",
        error: error.localizedDescription
      )
    }
  }

  nonisolated private static func resizedDisplayImage(
    _ image: UIImage,
    maxPixelDimension: CGFloat,
    contentScale: CGFloat
  ) -> UIImage {
    let pixelWidth = image.size.width * image.scale
    let pixelHeight = image.size.height * image.scale
    let largestPixelDimension = max(pixelWidth, pixelHeight)
    guard maxPixelDimension > 0, pixelWidth > 0, pixelHeight > 0 else { return image }

    let targetPixelDimension = max(1, min(maxPixelDimension, largestPixelDimension).rounded())
    let safeContentScale = min(max(contentScale, 0.45), 1)
    let contentPixelDimension = max(1, (targetPixelDimension * safeContentScale).rounded())
    let drawScale = min(contentPixelDimension / pixelWidth, contentPixelDimension / pixelHeight, 1)
    let drawSize = CGSize(
      width: max(1, (pixelWidth * drawScale).rounded()),
      height: max(1, (pixelHeight * drawScale).rounded())
    )
    let targetSize = CGSize(width: targetPixelDimension, height: targetPixelDimension)
    let drawRect = CGRect(
      x: (targetSize.width - drawSize.width) / 2,
      y: (targetSize.height - drawSize.height) / 2,
      width: drawSize.width,
      height: drawSize.height
    )
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    return UIGraphicsImageRenderer(size: targetSize, format: format).image { context in
      UIColor.black.setFill()
      context.fill(CGRect(origin: .zero, size: targetSize))
      image.draw(in: drawRect)
    }
  }

  private func publishLiveCaptionDisplay(text: String, attribution: TranscriptAttribution) {
    let caption = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard liveTranscriptionEnabled, !caption.isEmpty else { return }

    let speaker = attribution.personId == nil ? nil : attribution.displayName?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let captionLine: String
    if let speaker, !speaker.isEmpty {
      captionLine = "\(speaker): \(caption)"
    } else {
      captionLine = caption
    }

    if let personId = attribution.personId {
      currentGlassesDisplayPersonId = personId
      currentGlassesDisplayName = resolvedDisplayName(for: personId, fallback: speaker)
    }

    guard captionLine != lastLiveCaptionDisplayText else { return }
    lastLiveCaptionDisplayText = captionLine
    liveCaptionDisplayLines.append(captionLine)
    if liveCaptionDisplayLines.count > Self.liveCaptionDisplayLineLimit {
      liveCaptionDisplayLines.removeFirst(liveCaptionDisplayLines.count - Self.liveCaptionDisplayLineLimit)
    }

    if activeGlassesDisplayWindow == .transcripts {
      sendCombinedGlassesDisplayCard(reason: "live-caption")
    }
  }

  private func publishSceneContextDisplay(_ record: SceneContextRecord, reason: String) {
    if let personId = record.personId {
      currentGlassesDisplayPersonId = personId
      currentGlassesDisplayName = resolvedDisplayName(for: personId)
    }
    recentActivityModeSceneContexts.append(record)
    if recentActivityModeSceneContexts.count > Self.activityModeSceneContextLimit {
      recentActivityModeSceneContexts.removeFirst(
        recentActivityModeSceneContexts.count - Self.activityModeSceneContextLimit
      )
    }
    let timeText = record.createdAt.formatted(date: .omitted, time: .shortened)
    currentGlassesSceneContextSections.append(AssistanceDisplaySection(
      title: "Scene context \(timeText)",
      lines: [
        record.summary,
        "Where: \(record.whereText)",
        "What: \(record.what)",
        "Why: \(record.why)",
        "How: \(record.how)",
        "Style: \(record.interactionStyle)",
        "Confidence: \(Int((record.confidence * 100).rounded()))%"
      ]
      .map { Self.truncated($0, maxLength: 180) }
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    ))
    if currentGlassesSceneContextSections.count > Self.sceneContextDisplaySectionLimit {
      currentGlassesSceneContextSections.removeFirst(
        currentGlassesSceneContextSections.count - Self.sceneContextDisplaySectionLimit
      )
    }
    sceneContextStatusText = "Scene context saved: \(Int((record.confidence * 100).rounded()))%"
    let personText = record.personId.flatMap { resolvedDisplayName(for: $0) } ?? record.who
    sceneContextPipelineVerificationText = "5W/1H saved: \(Self.truncated(record.summary, maxLength: 120)) | who=\(Self.truncated(personText, maxLength: 60)) | confidence=\(Int((record.confidence * 100).rounded()))%"
    let sceneMetrics = sceneContextPipeline.metricsSnapshot()
    AppLogger.log(
      .sceneContext,
      "[CONTEXT_CARD] recordId=\(record.id.uuidString) evidence=\(sceneMetrics.lastEvidenceSource) visualReady=\(sceneMetrics.requestsSucceeded > 0) acceptedTranscriptSegments=\(streamPerformanceCounters.asrTranscriptSegments) summary=\"\(Self.truncated(record.summary, maxLength: 140))\""
    )
    refreshStreamReadinessDisplayIfNeeded(reason: "stream-readiness-visual")
    if activeGlassesDisplayWindow == .context {
      sendCombinedGlassesDisplayCard(reason: reason)
    }
    scheduleActivityModeClassification(reason: reason)
  }

  private func scheduleActivityModeClassification(reason: String) {
    guard datIsStreamRunning || lifecycleState.isStreamingSurfaceVisible else { return }
    let now = Date()
    if let lastActivityModeClassificationAt,
       now.timeIntervalSince(lastActivityModeClassificationAt) < Self.activityModeMinimumClassificationInterval {
      AppLogger.log(
        .activityMode,
        "classification skipped reason=\(reason) gate=interval elapsedSeconds=\(String(format: "%.1f", now.timeIntervalSince(lastActivityModeClassificationAt)))"
      )
      return
    }
    let request = currentActivityModeClassificationRequest(reason: reason)
    guard Self.hasActivityModeClassificationContext(request) else {
      streamPerformanceCounters.activityModeSkippedNoContext += 1
      emitStreamPerformanceCountersIfNeeded(force: false)
      AppLogger.log(.activityMode, "classification skipped reason=\(reason) gate=noContext")
      return
    }
    let signature = Self.activityModeClassificationSignature(request)
    guard signature != lastActivityModeClassificationSignature else {
      streamPerformanceCounters.activityModeSkippedNoContext += 1
      emitStreamPerformanceCountersIfNeeded(force: false)
      AppLogger.log(.activityMode, "classification skipped reason=\(reason) gate=duplicateContext")
      return
    }
    lastActivityModeClassificationAt = now
    lastActivityModeClassificationSignature = signature
    let settings = SceneContextSettings.load()
    let aiProxyConfigured = SupabaseEdgeFunctionClient.isConfigured()
    activityModeClassificationTask?.cancel()
    activityModeClassificationTask = Task { @MainActor [weak self, request, settings, reason, aiProxyConfigured] in
      guard let self else { return }
      if !aiProxyConfigured,
         settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let fallback = ActivityModeClassifier.fallbackClassification(for: request)
        self.applyActivityModeClassification(
          fallback,
          reason: reason,
          source: "localFallback",
          modelName: "localFallback"
        )
        AppLogger.log(
          .activityMode,
          "classification fallback reason=\(reason) source=localFallback cause=missingAPIKey mode=\(fallback.mode) confidence=\(String(format: "%.2f", fallback.confidence))"
        )
        return
      }
      do {
        self.streamPerformanceCounters.qwenActivityModeCalls += 1
        self.emitStreamPerformanceCountersIfNeeded(force: false)
        let classification = try await SceneContextClient(settings: settings).classifyActivityMode(request)
        self.applyActivityModeClassification(
          classification,
          reason: reason,
          source: "qwen",
          modelName: settings.textModel.isEmpty ? SceneContextSettings.defaultTextModel : settings.textModel
        )
      } catch {
        let fallback = ActivityModeClassifier.fallbackClassification(for: request)
        self.applyActivityModeClassification(
          fallback,
          reason: "\(reason)-fallback",
          source: "localFallback",
          modelName: "localFallback"
        )
        AppLogger.log(
          .activityMode,
          "classification fallback reason=\(reason) source=localFallback cause=\"\(Self.truncated(error.localizedDescription, maxLength: 160))\" mode=\(fallback.mode) confidence=\(String(format: "%.2f", fallback.confidence))"
        )
      }
    }
  }

  private func currentActivityModeClassificationRequest(reason: String) -> ActivityModeClassificationRequest {
    let transcriptText: String
    if Self.hasMeaningfulLiveTranscript(liveTranscriptPreviewText) {
      transcriptText = liveTranscriptPreviewText
    } else if recentConversationAttributionText.hasPrefix("Live transcript:") {
      transcriptText = recentConversationAttributionText
    } else {
      transcriptText = ""
    }
    let attribution = currentTranscriptAttribution()
    return ActivityModeClassificationRequest(
      transcriptText: transcriptText,
      sceneContexts: recentActivityModeSceneContexts,
      recognizedPeople: activeStreamRecognizedPeopleNames(),
      detectedFaceCount: detectedFaceCount,
      identityEvidence: currentSceneContextIdentityEvidence(attribution: attribution),
      locationLabel: nil,
      streamState: datStreamSessionStateText,
      reason: reason
    )
  }

  nonisolated private static func hasActivityModeClassificationContext(_ request: ActivityModeClassificationRequest) -> Bool {
    if hasMeaningfulLiveTranscript(request.transcriptText) {
      return true
    }
    if !request.sceneContexts.isEmpty || !request.recognizedPeople.isEmpty || request.detectedFaceCount > 0 {
      return true
    }
    if let evidence = request.identityEvidence {
      return evidence.conversationPartnerPersonId != nil || !evidence.activePeople.isEmpty
    }
    return false
  }

  nonisolated private static func activityModeClassificationSignature(_ request: ActivityModeClassificationRequest) -> String {
    let transcript = request.transcriptText
      .lowercased()
      .split(whereSeparator: \.isWhitespace)
      .suffix(36)
      .joined(separator: " ")
    let sceneSignature = request.sceneContexts
      .suffix(3)
      .map { record in
        [
          record.id.uuidString,
          record.summary,
          record.what,
          record.whereText
        ].joined(separator: ":")
      }
      .joined(separator: "||")
    let people = request.recognizedPeople.sorted().joined(separator: ",")
    let evidence = request.identityEvidence?.activePeople
      .map(\.displayName)
      .sorted()
      .joined(separator: ",") ?? ""
    return [
      transcript,
      sceneSignature,
      people,
      evidence,
      String(request.detectedFaceCount)
    ].joined(separator: "###")
  }

  private func applyActivityModeClassification(
    _ classification: ActivityModeClassification,
    reason: String,
    source: String,
    modelName: String
  ) {
    let stabilization = activityModeStabilizer.evaluate(
      current: currentActivityModeClassification,
      candidate: classification
    )
    guard stabilization.shouldApply else {
      activityModeVerificationText = "Activity mode held: \(currentActivityModeClassification.displayText)"
      AppLogger.log(
        .activityMode,
        "classification held reason=\(reason) source=\(source) gate=\(stabilization.reason) observations=\(stabilization.matchingObservationCount) current=\(currentActivityModeClassification.mode) candidate=\(stabilization.classification.mode) confidence=\(String(format: "%.2f", stabilization.classification.confidence))"
      )
      return
    }

    let acceptedClassification = stabilization.classification
    let previousMode = currentActivityModeClassification.mode
    currentActivityModeClassification = acceptedClassification
    activityModeVerificationText = "Activity mode: \(acceptedClassification.displayText) (\(Int((acceptedClassification.confidence * 100).rounded()))%)"
    persistActivityModeEpisode(
      acceptedClassification,
      reason: reason,
      source: source,
      modelName: modelName,
      previousMode: previousMode
    )
    if stabilization.shouldSendDisplay, activeGlassesDisplayWindow == .live {
      sendCombinedGlassesDisplayCard(reason: "activity-mode-\(reason)")
    } else {
      AppLogger.log(
        .activityMode,
        "display suppressed reason=unchangedBroadMode mode=\(acceptedClassification.mode) specific=\(acceptedClassification.specificActivity.isEmpty ? "none" : "present")"
      )
    }
  }

  private func persistActivityModeEpisode(
    _ classification: ActivityModeClassification,
    reason: String,
    source: String,
    modelName: String,
    previousMode: String
  ) {
    guard let context = pipelineContext else {
      AppLogger.log(.activityMode, "episode skipped reason=\(reason) cause=noPipelineContext mode=\(classification.mode)")
      return
    }
    let now = Date()
    let sameMode = ActivityModeTaxonomy.normalizedMode(previousMode) == ActivityModeTaxonomy.normalizedMode(classification.mode)
    if var episode = currentActivityModeEpisode, sameMode {
      let shouldSaveEpisodeUpdate = now.timeIntervalSince(episode.updatedAt) >= 60
        || episode.specificActivity != classification.specificActivity
      episode.specificActivity = classification.specificActivity
      episode.lastEvidenceAt = now
      episode.confidence = classification.confidence
      episode.reason = classification.reason
      episode.source = source
      episode.modelName = modelName
      episode.promptVersion = ActivityModeClassifier.promptVersion
      episode.updatedAt = now
      currentActivityModeEpisode = episode
      if shouldSaveEpisodeUpdate {
        streamPerformanceCounters.databaseWrites += 1
        emitStreamPerformanceCountersIfNeeded(force: false)
        Task { await identityPipeline.saveActivityModeEpisode(episode) }
      }
      return
    }

    closeCurrentActivityModeEpisode(endedAt: now, reason: "modeSwitch-\(reason)")
    let episode = ActivityModeEpisodeRecord(
      id: UUID(),
      appRunId: context.appRunId,
      conversationSessionId: context.conversationSessionId,
      mode: classification.mode,
      specificActivity: classification.specificActivity,
      startedAt: now,
      lastEvidenceAt: now,
      endedAt: nil,
      confidence: classification.confidence,
      reason: classification.reason,
      source: source,
      modelName: modelName,
      promptVersion: ActivityModeClassifier.promptVersion,
      updatedAt: now
    )
    currentActivityModeEpisode = episode
    streamPerformanceCounters.databaseWrites += 1
    emitStreamPerformanceCountersIfNeeded(force: false)
    Task { await identityPipeline.saveActivityModeEpisode(episode) }
    AppLogger.log(
      .activityMode,
      "episode started reason=\(reason) source=\(source) mode=\(episode.mode) specific=\"\(episode.specificActivity)\" confidence=\(String(format: "%.2f", episode.confidence)) session=\(context.conversationSessionId?.uuidString ?? "none")"
    )
  }

  private func closeCurrentActivityModeEpisode(endedAt: Date = Date(), reason: String) {
    guard var episode = currentActivityModeEpisode else { return }
    episode.lastEvidenceAt = max(episode.lastEvidenceAt, endedAt)
    episode.endedAt = endedAt
    episode.updatedAt = endedAt
    currentActivityModeEpisode = nil
    streamPerformanceCounters.databaseWrites += 1
    emitStreamPerformanceCountersIfNeeded(force: false)
    Task { await identityPipeline.saveActivityModeEpisode(episode) }
    AppLogger.log(
      .activityMode,
      "episode closed reason=\(reason) mode=\(episode.mode) durationSeconds=\(String(format: "%.1f", endedAt.timeIntervalSince(episode.startedAt)))"
    )
  }

  private func publishGlassesAssistanceCard(
    identity: AssistanceIdentityState,
    memory: AssistanceMemorySnapshot,
    reason: String,
    sendImmediately: Bool = true
  ) {
    var card = glassesAssistanceCardFormatter.makeCard(
      identity: identity,
      memory: memory,
      displayStatus: .glassesDisplay
    )
    let metadata = glassesDisplayMetadata(for: identity)
    currentGlassesDisplayPersonId = metadata.personId
    currentGlassesDisplayName = metadata.displayName
    card.personId = metadata.personId
    card.displayName = metadata.displayName
    card.primaryAction = datIsStreamRunning ? .stopStream : (metadata.personId == nil ? .openPeople : .markReviewed)
    card.secondaryAction = .openPeople
    card.tertiaryAction = metadata.personId == nil ? nil : .markReviewed
    currentGlassesAssistanceCard = card
    if sendImmediately {
      sendCombinedGlassesDisplayCard(reason: reason)
    }
  }

  private func glassesDisplayMetadata(for identity: AssistanceIdentityState) -> (personId: UUID?, displayName: String?) {
    switch identity {
    case .known(let name, _, _):
      let personId = livePhoneAssistancePinnedPersonId ?? activeFacePersonId
      return (personId, resolvedDisplayName(for: personId, fallback: name))
    case .possibleMatch(let name, _):
      return (nil, name)
    case .unknown, .noFaceDetected, .multipleFaces:
      return (nil, nil)
    }
  }

  private func resolvedDisplayName(for personId: UUID?, fallback: String? = nil) -> String? {
    guard let personId else { return fallback }
    if activeFacePersonId == personId, let activeFaceName, !activeFaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return activeFaceName
    }
    if let summary = conversationSummaryCache[personId] {
      return summary.displayName
    }
    if let entry = peopleDictionaryEntries.first(where: { $0.id == personId }) {
      return entry.displayName
    }
    return fallback
  }

  private func combinedGlassesDisplayCard() -> AssistanceDisplayCard? {
    let sections = activeGlassesDisplaySections()
    guard !sections.isEmpty else { return nil }
    let baseCard = currentGlassesAssistanceCard
    let actions = activeGlassesDisplayActions(baseCard: baseCard)
    return AssistanceDisplayCard(
      title: activeGlassesDisplayTitle(),
      lines: sections.first?.lines ?? [],
      usesFallbackOutput: baseCard?.usesFallbackOutput ?? false,
      sections: sections,
      personId: baseCard?.personId ?? currentGlassesDisplayPersonId,
      displayName: baseCard?.displayName ?? currentGlassesDisplayName,
      thumbnailImageURI: nil,
      primaryAction: actions.primary,
      secondaryAction: actions.secondary,
      tertiaryAction: actions.tertiary
    )
  }

  private var activeIdentityPromptThumbnailImageURI: String? {
    if shouldShowIdentityPromptOnLive || isGlassesIdentitySelectionActive {
      return currentIdentityConfirmationImageURI
    }
    return nil
  }

  private var liveIdentityPromptSectionWithImage: AssistanceDisplaySection? {
    guard shouldShowIdentityPromptOnLive,
          let currentGlassesIdentityPromptSection else { return nil }
    guard currentIdentityConfirmationThumbnail != nil || currentIdentityConfirmationImageURI != nil else {
      return currentGlassesIdentityPromptSection
    }

    var lines = currentGlassesIdentityPromptSection.lines
    if currentIdentityConfirmationImageURI == nil {
      let loadingLine = "Photo loading for glasses display."
      if !lines.contains(loadingLine) {
        lines.append(loadingLine)
      }
    }
    return AssistanceDisplaySection(
      title: currentGlassesIdentityPromptSection.title,
      lines: lines,
      thumbnailImageURI: currentIdentityConfirmationImageURI,
      thumbnailImageSize: .fill
    )
  }

  private var activeIdentityPromptPhotoSection: AssistanceDisplaySection? {
    guard isGlassesIdentitySelectionActive else { return nil }
    guard currentIdentityConfirmationThumbnail != nil || currentIdentityConfirmationImageURI != nil else { return nil }
    let title: String
    switch pendingIdentityConfirmation {
    case .recognized(_, let displayName):
      title = "\(displayName) photo"
    case .unknown:
      title = "Person photo"
    case .selectingPerson:
      if !glassesIdentitySelectionEntries.isEmpty {
        let selected = glassesIdentitySelectionEntries[min(glassesIdentitySelectionIndex, glassesIdentitySelectionEntries.count - 1)]
        title = "\(selected.displayName) photo"
      } else {
        title = "Person photo"
      }
    case nil:
      return nil
    }
    let imageReady = currentIdentityConfirmationImageURI != nil
    return AssistanceDisplaySection(
      title: title,
      lines: imageReady ? [] : ["Photo loading for glasses display."],
      thumbnailImageURI: currentIdentityConfirmationImageURI,
      thumbnailImageSize: .icon
    )
  }

  private func activeGlassesDisplaySections() -> [AssistanceDisplaySection] {
    if shouldShowIdentityPromptOnLive {
      return liveGlassesDisplaySections()
    }
    if isGlassesIdentitySelectionActive {
      return peopleWindowDisplaySections()
    }

    switch activeGlassesDisplayWindow {
    case .live:
      return liveGlassesDisplaySections()
    case .people:
      return peopleWindowDisplaySections()
    case .context:
      return contextDisplaySections()
    case .transcripts:
      return transcriptDisplaySections()
    }
  }

  private func liveGlassesDisplaySections() -> [AssistanceDisplaySection] {
    let identityPromptSection = liveIdentityPromptSectionWithImage
    if let identityPromptSection,
       identityPromptSection.thumbnailImageURI != nil {
      AppLogger.log(
        .display,
        "Identity confirmation prompt image attached title=\"\(identityPromptSection.title)\" imageURI=attached imageSize=\(identityPromptSection.thumbnailImageSize.rawValue)"
      )
    }
    return MementoGlassesDisplayRenderer.liveViewSections(
      assistanceCard: currentGlassesAssistanceCard,
      recallSections: currentGlassesLiveRecallSections,
      identityPromptSection: identityPromptSection,
      identityPhotoSection: nil,
      statusLine: liveGlassesStatusLine(),
      isStreaming: datIsStreamRunning || datStreamSessionStateText.lowercased().contains("streaming"),
      streamTitle: liveStreamTransportTitle(),
      streamModeLine: streamRunningModeLineText,
      recognizedPeopleLine: streamRunningRecognizedPeopleLineText,
      readinessLine: liveStreamReadinessLine()
    )
  }

  private var shouldShowIdentityPromptOnLive: Bool {
    switch pendingIdentityConfirmation {
    case .recognized, .unknown:
      return true
    case .selectingPerson, nil:
      return false
    }
  }

  private var isGlassesIdentitySelectionActive: Bool {
    if case .selectingPerson = pendingIdentityConfirmation {
      return true
    }
    return false
  }

  private func liveGlassesStatusLine() -> String {
    if let faceStatus = currentGlassesFaceVisibilitySection?.lines.first?.trimmingCharacters(in: .whitespacesAndNewlines),
       !faceStatus.isEmpty {
      return "Status: \(faceStatus)"
    }
    if datIsStreamRunning {
      return hasReceivedFirstFrame
        ? "Status: Stream running successfully."
        : "Status: Starting stream."
    }
    return "Status: Display ready."
  }

  private func liveStreamTransportTitle(now: Date = Date()) -> String {
    let observedFPS = observedDATFramesPerSecond(at: now)
    switch transportReadiness(observedFPS: observedFPS, now: now) {
    case "degraded":
      return "Transport degraded"
    case "starting":
      return "Transport starting"
    default:
      return "Transport streaming"
    }
  }

  private func liveStreamReadinessLine() -> String {
    let visual = visualContextReadiness()
    let speech = speechContextReadiness()
    let face = faceRecognitionReadiness()
    return "Context: visual \(visual), speech \(speech), face \(face)"
  }

  private func peopleWindowDisplaySections() -> [AssistanceDisplaySection] {
    var sections: [AssistanceDisplaySection] = []
    if isGlassesIdentitySelectionActive,
       let currentGlassesIdentityPromptSection {
      sections.append(currentGlassesIdentityPromptSection)
      if let photoSection = activeIdentityPromptPhotoSection {
        AppLogger.log(
          .display,
          "Identity selection photo page included title=\"\(photoSection.title)\" imageURI=\(currentIdentityConfirmationImageURI == nil ? "loading" : "attached")"
        )
        sections.append(photoSection)
      }
    }

    if let current = liveGlassesDisplaySections().first {
      sections.append(AssistanceDisplaySection(
        title: "Current person",
        lines: [current.title] + current.lines
      ))
    }

    let dictionary = MementoGlassesDisplayRenderer.peopleList(
      entries: peopleDictionaryEntries,
      currentPersonId: activeFacePersonId ?? currentGlassesDisplayPersonId,
      page: glassesPeopleListPage
    )
    sections.append(AssistanceDisplaySection(
      title: dictionary.title,
      lines: dictionary.lines
    ))

    if sections.isEmpty {
      sections.append(AssistanceDisplaySection(
        title: "People",
        lines: ["No saved people yet."]
      ))
    }
    return sections
  }

  private func contextDisplaySections() -> [AssistanceDisplaySection] {
    let sections = Array(currentGlassesSceneContextSections.suffix(Self.sceneContextDisplaySectionLimit).reversed())
    guard !sections.isEmpty else {
      return [AssistanceDisplaySection(
        title: "AI context",
        lines: ["Waiting for multimodal scene context.", sceneContextStatusText]
      )]
    }
    return sections
  }

  private func transcriptDisplaySections() -> [AssistanceDisplaySection] {
    let captionLines = Array(liveCaptionDisplayLines.reversed())
    guard !captionLines.isEmpty else {
      return [AssistanceDisplaySection(
        title: "Transcript",
        lines: ["Waiting for live speech.", liveTranscriptionStatusText]
      )]
    }
    return [AssistanceDisplaySection(title: "Transcript", lines: captionLines)]
  }

  private func activeGlassesDisplayTitle() -> String {
    if shouldShowIdentityPromptOnLive {
      return "Live view"
    }
    if isGlassesIdentitySelectionActive {
      return "People"
    }
    switch activeGlassesDisplayWindow {
    case .live:
      return "Live view"
    case .people:
      return "People"
    case .context:
      return "AI context"
    case .transcripts:
      return "Transcript"
    }
  }

  private func activeGlassesDisplayActions(
    baseCard: AssistanceDisplayCard?
  ) -> (primary: GlassesDisplayAction?, secondary: GlassesDisplayAction?, tertiary: GlassesDisplayAction?) {
    if let primary = identityPromptPrimaryAction() {
      return (primary, identityPromptSecondaryAction(), nil)
    }

    guard datIsStreamRunning else {
      return (baseCard?.primaryAction, baseCard?.secondaryAction, baseCard?.tertiaryAction)
    }

    switch activeGlassesDisplayWindow {
    case .live:
      return (.openTranscripts, .openContext, nil)
    case .people:
      return (.backToHome, .openTranscripts, nil)
    case .context:
      return (.openTranscripts, .backToHome, nil)
    case .transcripts:
      return (.openContext, .backToHome, nil)
    }
  }

  private func identityPromptPrimaryAction() -> GlassesDisplayAction? {
    switch pendingIdentityConfirmation {
    case .recognized:
      return .confirmRecognizedPerson
    case .unknown:
      return .confirmUnknownPerson
    case .selectingPerson:
      return glassesIdentitySelectionEntries.isEmpty ? .selectUnknownPerson : .confirmSelectedPerson
    case nil:
      return nil
    }
  }

  private func identityPromptSecondaryAction() -> GlassesDisplayAction? {
    switch pendingIdentityConfirmation {
    case .recognized:
      return .rejectRecognizedPerson
    case .unknown:
      return .rejectUnknownPerson
    case .selectingPerson:
      return .selectUnknownPerson
    case nil:
      return nil
    }
  }

  private func sendCombinedGlassesDisplayCard(reason: String, delayNanoseconds: UInt64 = 250_000_000) {
    guard let card = combinedGlassesDisplayCard() else {
      clearPhysicalGlassesAssistanceDisplay(reason: reason)
      return
    }
    enqueueGlassesDisplayCard(card, reason: reason, delayNanoseconds: delayNanoseconds)
  }

  private func enqueueGlassesDisplayCard(
    _ card: AssistanceDisplayCard,
    reason: String,
    delayNanoseconds: UInt64 = 250_000_000
  ) {
    lastGlassesDisplayCardForActions = card
    glassesDisplaySendTask?.cancel()
    glassesDisplaySendTask = Task { @MainActor [weak self] in
      if delayNanoseconds > 0 {
        do {
          try await Task.sleep(nanoseconds: delayNanoseconds)
        } catch {
          return
        }
      }
      guard let self else { return }
      self.streamPerformanceCounters.displaySendAttempts += 1
      self.emitStreamPerformanceCountersIfNeeded(force: false)
      let sent = await self.datManager.sendAssistanceCard(card, reason: reason, resetPage: false)
      if sent {
        await self.recordGlassesDisplayInteractionIfNeeded(action: .displayed, source: "displaySend", card: card)
      }
      self.glassesDisplaySendTask = nil
    }
  }

  private func clearGlassesAssistanceCard(reason: String) {
    currentGlassesAssistanceCard = nil
    if Self.shouldSendRemainingDisplayAfterClear(
      datIsStreamRunning: datIsStreamRunning,
      streamStateText: datStreamSessionStateText,
      activeWindowIsLive: activeGlassesDisplayWindow == .live
    ), let remainingCard = combinedGlassesDisplayCard() {
      enqueueGlassesDisplayCard(remainingCard, reason: "\(reason)-remaining")
      return
    }
    clearPhysicalGlassesAssistanceDisplay(reason: reason)
  }

  private func clearPhysicalGlassesAssistanceDisplay(reason: String) {
    glassesDisplaySendTask?.cancel()
    glassesDisplaySendTask = nil
    Task { @MainActor [weak self] in
      await self?.datManager.clearAssistanceDisplay(reason: reason)
    }
  }

  private func sendImmediateGlassesDisplayCard(
    _ card: AssistanceDisplayCard,
    reason: String,
    resetPage: Bool = true
  ) {
    currentGlassesAssistanceCard = card
    currentGlassesDisplayPersonId = card.personId
    currentGlassesDisplayName = card.displayName
    lastGlassesDisplayCardForActions = card
    glassesDisplaySendTask?.cancel()
    glassesDisplaySendTask = nil
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.streamPerformanceCounters.displaySendAttempts += 1
      self.emitStreamPerformanceCountersIfNeeded(force: false)
      let sent = await self.datManager.sendAssistanceCard(card, reason: reason, resetPage: resetPage)
      if sent {
        await self.recordGlassesDisplayInteractionIfNeeded(action: .displayed, source: "displaySend", card: card)
      }
    }
  }

  private func sendCoalescedGlassesDisplayCard(
    _ card: AssistanceDisplayCard,
    reason: String,
    resetPage: Bool,
    delayNanoseconds: UInt64
  ) {
    currentGlassesAssistanceCard = card
    currentGlassesDisplayPersonId = card.personId
    currentGlassesDisplayName = card.displayName
    lastGlassesDisplayCardForActions = card
    glassesDisplaySendTask?.cancel()
    glassesDisplaySendTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(nanoseconds: delayNanoseconds)
      } catch {
        return
      }
      guard let self else { return }
      self.streamPerformanceCounters.displaySendAttempts += 1
      self.emitStreamPerformanceCountersIfNeeded(force: false)
      let sent = await self.datManager.sendAssistanceCard(card, reason: reason, resetPage: resetPage)
      if sent {
        await self.recordGlassesDisplayInteractionIfNeeded(action: .displayed, source: "displaySend", card: card)
      }
      self.glassesDisplaySendTask = nil
    }
  }

  private func showGlassesStreamStatus(
    title: String,
    message: String,
    reason: String,
    allowStop: Bool = true,
    sendTiming: GlassesDisplaySendTiming = .immediate
  ) {
    let card = MementoGlassesDisplayRenderer.streamStatus(
      title: title,
      message: message,
      allowStop: allowStop
    )
    switch sendTiming {
    case .immediate:
      sendImmediateGlassesDisplayCard(card, reason: reason)
    case .coalesced(let nanoseconds):
      sendCoalescedGlassesDisplayCard(
        card,
        reason: reason,
        resetPage: true,
        delayNanoseconds: nanoseconds
      )
    }
  }

  private func showGlassesStreamingDashboard(reason: String) {
    guard datIsStreamRunning || datStreamSessionStateText.lowercased().contains("streaming") else { return }
    let dashboardText = Self.streamingDashboardText(
      datFramesReceived: datFramesReceived,
      lastFrameTimestampText: lastFrameTimestampText,
      datLastErrorText: datLastErrorText,
      hasReceivedFirstFrame: hasReceivedFirstFrame
    )
    let card = MementoGlassesDisplayRenderer.streaming(
      currentPersonName: currentGlassesDisplayName ?? activeFaceName,
      frameText: dashboardText.frameText,
      statusText: dashboardText.statusText,
      currentLineOverride: dashboardText.currentLineOverride
    )
    currentGlassesAssistanceCard = card
    currentGlassesDisplayPersonId = card.personId ?? currentGlassesDisplayPersonId
    currentGlassesDisplayName = card.displayName ?? currentGlassesDisplayName ?? activeFaceName
    if activeGlassesDisplayWindow == .live || activeGlassesDisplayWindow == .people {
      sendCombinedGlassesDisplayCard(reason: reason)
    }
  }

  private func showGlassesPeopleDictionary() async {
    let entries = await identityPipeline.loadPeopleForDictionary()
    peopleDictionaryEntries = entries
    activeGlassesDisplayWindow = .people
    sendCombinedGlassesDisplayCard(reason: "glasses-people-list")
  }

  @discardableResult
  func savePhotoFromVideoStream() -> UIImage? {
    guard let image = currentVideoFrame else {
      streamPhotoStatusText = "No stream frame available yet"
      return nil
    }
    lastStreamPhotoSnapshot = image
    streamPhotoStatusText = "Photo saved from latest video stream frame"
    return image
  }

  private func handleGlassesDisplayAction(_ action: GlassesDisplayAction) async {
    guard let card = lastGlassesDisplayCardForActions else { return }
    if action == .displayed {
      await recordGlassesDisplayInteractionIfNeeded(action: .displayed, source: "displaySend", card: card)
      return
    }
    if action.isIdentityPromptAction {
      handleIdentityPromptActionImmediately(action)
      Task { @MainActor [weak self, card] in
        await self?.recordGlassesDisplayInteraction(action: action, source: "glassesButton", card: card)
      }
      return
    }
    await recordGlassesDisplayInteraction(action: action, source: "glassesButton", card: card)

    switch action {
    case .openPeople:
      await showGlassesPeopleDictionary()
    case .openContext:
      activeGlassesDisplayWindow = .context
      sendCombinedGlassesDisplayCard(reason: "glasses-open-context")
    case .openTranscripts:
      activeGlassesDisplayWindow = .transcripts
      sendCombinedGlassesDisplayCard(reason: "glasses-open-transcripts")
    case .startStream:
      phoneAssistanceStatusText = "Starting stream from glasses"
      showGlassesStreamStatus(
        title: "Starting stream",
        message: "Preparing iPhone mic and glasses camera.",
        reason: "start-stream-from-glasses"
      )
      await startRealGlassesStream()
    case .stopStream:
      if shouldSuppressGlassesStopAfterIdentityConfirmation() {
        phoneAssistanceStatusText = "Stream still running"
        AppLogger.log(
          .display,
          "Stop stream action ignored during identity confirmation handoff cardTitle=\"\(card.title)\" primary=\(card.primaryAction?.rawValue ?? "nil") secondary=\(card.secondaryAction?.rawValue ?? "nil") tertiary=\(card.tertiaryAction?.rawValue ?? "nil")"
        )
        return
      }
      phoneAssistanceStatusText = "Stopping stream from glasses"
      AppLogger.log(
        .display,
        "Stop stream requested from glasses; deferring display refresh until DAT teardown settles cardTitle=\"\(card.title)\" primary=\(card.primaryAction?.rawValue ?? "nil") secondary=\(card.secondaryAction?.rawValue ?? "nil") tertiary=\(card.tertiaryAction?.rawValue ?? "nil")"
      )
      let stopGeneration = streamStopGeneration &+ 1
      await stopSession(reason: "glassesDisplay")
      Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard let self else { return }
        guard self.streamStopGeneration == stopGeneration,
              !self.stopSessionInFlight,
              !self.explicitTeardownInFlight,
              !self.datIsStreamRunning,
              !self.datStreamSessionStateText.lowercased().contains("streaming") else {
          AppLogger.log(.display, "Skipped post-stop display control activation because stream lifecycle changed generation=\(stopGeneration) current=\(self.streamStopGeneration) datStream=\(self.datStreamSessionStateText)")
          return
        }
        self.activateGlassesDisplayControl()
      }
    case .snapshotFrame:
      let image = savePhotoFromVideoStream()
      sendImmediateGlassesDisplayCard(
        MementoGlassesDisplayRenderer.photoStatus(success: image != nil),
        reason: "glasses-snapshot-frame"
      )
    case .markReviewed:
      phoneAssistanceStatusText = "Reviewed on glasses"
    case .hideCard:
      clearGlassesAssistanceCard(reason: "glasses-hide")
    case .backToHome:
      if datIsStreamRunning || datStreamSessionStateText.lowercased().contains("streaming") {
        activeGlassesDisplayWindow = .live
        sendCombinedGlassesDisplayCard(reason: "glasses-back-to-streaming")
      } else {
        activateGlassesDisplayControl()
      }
    case .confirmRecognizedPerson:
      confirmRecognizedPersonOnGlasses()
    case .rejectRecognizedPerson:
      clearRetainedRecognizedIdentity(reason: "glassesRejectedRecognized")
      await beginGlassesIdentityCorrection()
    case .confirmUnknownPerson:
      confirmUnknownPersonOnGlasses()
    case .rejectUnknownPerson:
      await beginGlassesIdentityCorrection()
    case .confirmSelectedPerson:
      confirmSelectedPersonOnGlasses()
    case .selectUnknownPerson:
      confirmUnknownPersonOnGlasses()
    case .nextPage:
      moveGlassesIdentitySelection(offset: 1)
    case .previousPage:
      moveGlassesIdentitySelection(offset: -1)
    case .displayed:
      break
    }
  }

  private func handleIdentityPromptActionImmediately(_ action: GlassesDisplayAction) {
    switch action {
    case .confirmRecognizedPerson:
      confirmRecognizedPersonOnGlasses()
    case .rejectRecognizedPerson:
      clearRetainedRecognizedIdentity(reason: "glassesRejectedRecognized")
      showGlassesIdentityCorrectionLoading()
      Task { @MainActor [weak self] in
        await self?.loadGlassesIdentityCorrectionEntries()
      }
    case .confirmUnknownPerson:
      confirmUnknownPersonOnGlasses()
    case .rejectUnknownPerson:
      showGlassesIdentityCorrectionLoading()
      Task { @MainActor [weak self] in
        await self?.loadGlassesIdentityCorrectionEntries()
      }
    case .confirmSelectedPerson:
      confirmSelectedPersonOnGlasses()
    case .selectUnknownPerson:
      confirmUnknownPersonOnGlasses()
    default:
      break
    }
  }

  private func recordGlassesDisplayInteractionIfNeeded(
    action: GlassesDisplayAction,
    source: String,
    card: AssistanceDisplayCard
  ) async {
    let key = "\(action.rawValue)|\(source)|\(card.text)"
    guard key != lastRecordedGlassesDisplayCardKey else { return }
    lastRecordedGlassesDisplayCardKey = key
    await recordGlassesDisplayInteraction(action: action, source: source, card: card)
  }

  private func recordGlassesDisplayInteraction(
    action: GlassesDisplayAction,
    source: String,
    card: AssistanceDisplayCard
  ) async {
    var context = await identityPipeline.currentContext()
    if context == nil {
      let snapshot = await identityPipeline.startAppRunIfNeeded()
      context = await identityPipeline.currentContext()
      pipelineContext = context
      applyRunSessionSnapshot(snapshot)
    }
    guard let context else { return }

    let personId = card.personId ?? currentGlassesDisplayPersonId
    let displayName = card.displayName ?? resolvedDisplayName(for: personId) ?? currentGlassesDisplayName
    let event = GlassesDisplayInteractionEvent(
      appRunId: context.appRunId,
      conversationSessionId: context.conversationSessionId,
      personId: personId,
      displayName: displayName,
      cardTitle: card.title,
      cardText: card.text,
      action: action,
      source: source,
      createdAt: Date()
    )
    await identityPipeline.saveGlassesDisplayInteraction(event)

    if showPeopleDictionary {
      peopleDictionaryEntries = await identityPipeline.loadPeopleForDictionary()
    }
  }

  private func refreshPersonConversationSummaryForCurrentStreamIfNeeded(personId: UUID) {
    guard !conversationSummaryRefreshedPersonIdsThisStream.contains(personId) else { return }
    conversationSummaryRefreshedPersonIdsThisStream.insert(personId)
    AppLogger.log(.memory, "Person summary stream refresh requested personId=\(personId.uuidString)")
    refreshPersonConversationSummaryIfNeeded(personId: personId, forceSpeak: false, forceRefresh: true)
  }

  @discardableResult
  private func publishConfirmedPersonSummaryOrRefresh(personId: UUID) -> Bool {
    if let snapshot = conversationSummaryCache[personId] {
      publishConfirmedPersonSummaryIfNeeded(snapshot, reason: "identity-confirmed-summary-cached")
      return true
    }
    refreshPersonConversationSummaryForCurrentStreamIfNeeded(personId: personId)
    return false
  }

  @discardableResult
  private func publishConfirmedPersonSummaryIfNeeded(
    _ summary: PersonConversationSummary,
    reason: String
  ) -> Bool {
    guard glassesConfirmedConversationPersonId == summary.personId
      || glassesConfirmedConversationPersonIds.contains(summary.personId) else { return false }
    let section = MementoGlassesDisplayRenderer.confirmedPersonSummarySection(
      for: summary,
      presentPeople: activePresenceDisplayNames()
    )
    currentGlassesLiveRecallSections.removeAll { $0.title == section.title }
    publishLiveRecallSection(
      section,
      personId: summary.personId,
      status: "Last interaction loaded",
      verification: "Confirmed person memory: \(Self.truncated(section.lines.first ?? section.title, maxLength: 140))",
      reason: reason,
      shouldSwitchToLive: datIsStreamRunning || datStreamSessionStateText.lowercased().contains("streaming")
    )
    AppLogger.log(.memory, "Confirmed person summary stacked personId=\(summary.personId.uuidString) name=\(summary.displayName) stack=\(currentGlassesLiveRecallSections.count)")
    return true
  }

  private func invalidateAndRefreshConversationSummaries(
    for personIds: Set<UUID>,
    reason: String
  ) {
    guard !personIds.isEmpty else { return }
    for personId in personIds {
      conversationSummaryCache.removeValue(forKey: personId)
      AppLogger.log(.memory, "Person summary invalidated personId=\(personId.uuidString) reason=\(reason)")
      refreshPersonConversationSummaryIfNeeded(
        personId: personId,
        forceSpeak: false,
        forceRefresh: true
      )
    }
  }

  private func refreshPersonConversationSummaryIfNeeded(
    personId: UUID,
    forceSpeak: Bool,
    forceRefresh: Bool
  ) {
    if conversationSummaryInFlight.contains(personId) {
      if forceRefresh {
        conversationSummaryRefreshPendingPersonIds.insert(personId)
        AppLogger.log(.memory, "Person summary refresh queued behind in-flight request personId=\(personId.uuidString)")
      }
      return
    }
    if !forceRefresh, conversationSummaryCache[personId] != nil { return }
    let settings = DeepSeekSettings(apiKey: deepSeekAPIKeyText, model: deepSeekModelText)
    let hasDeepSeekCloud = SupabaseEdgeFunctionClient.isConfigured()
      || !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    conversationSummaryInFlight.insert(personId)
    let generation = assistanceGeneration
    phoneAssistanceStatusText = hasDeepSeekCloud
      ? "DeepSeek summarizing saved conversations"
      : "Loading saved conversation summary"
    AppLogger.log(.memory, "Person summary requested personId=\(personId.uuidString) model=\(settings.model) forceRefresh=\(forceRefresh) hasDeepSeekCloud=\(hasDeepSeekCloud) proxy=\(SupabaseEdgeFunctionClient.isConfigured())")
    Task { [weak self] in
      guard let self else { return }
      let profiles = await self.identityPipeline.currentProfiles()
      guard let profile = profiles.first(where: { $0.id == personId }) else {
        await MainActor.run {
          self.conversationSummaryInFlight.remove(personId)
          let needsRefresh = self.conversationSummaryRefreshPendingPersonIds.remove(personId) != nil
          self.phoneAssistanceStatusText = "Person memory not found"
          AppLogger.log(.memory, "Person summary failed: memory not found personId=\(personId.uuidString)")
          if needsRefresh {
            self.refreshPersonConversationSummaryIfNeeded(personId: personId, forceSpeak: false, forceRefresh: true)
          }
        }
        return
      }

      let recentSummaries = RecentMemoryContextBuilder.summaries(from: StreamSummaryHistoryStore.load())
      let request = MemoryRetrievalRequest(
        query: "What should I remember from my latest conversations with \(profile.displayName)?",
        currentMode: self.currentActivityModeClassification.mode,
        sceneContext: nil,
        presentPeople: self.activePresenceDisplayNames(),
        personIds: [personId],
        activePersonIds: [personId],
        recentSummaries: recentSummaries,
        exactWording: false,
        limit: 6,
        minSimilarity: 0.18,
        includeSourceTypes: [.streamSummary, .personNote, .sceneContext, .transcriptChunk],
        maxSensitivity: 1
      )
      let retrieval: RemoteMemoryRetrievalResult?
      do {
        retrieval = try await RemoteMemoryRetrievalService().retrieve(request)
      } catch {
        retrieval = nil
        AppLogger.log(.memory, "Person summary remote retrieval failed personId=\(personId.uuidString) fallback=last3Summaries reason=\(error.localizedDescription)")
      }
      let selectedContext = retrieval?.evidenceText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let fallbackContext = recentSummaries.joined(separator: "\n")
      let memoryContext = selectedContext.isEmpty ? fallbackContext : selectedContext
      let lastSeenText = Self.formatLastSeen(profile.lastSeenAt)
      let summary: String
        var summaryUsedCloud = hasDeepSeekCloud
        if memoryContext.isEmpty {
          summary = "No relevant saved memory yet."
          summaryUsedCloud = false
          AppLogger.log(.memory, "Person summary has no selective memory results personId=\(personId.uuidString) name=\(profile.displayName)")
        } else if !hasDeepSeekCloud {
          summary = Self.truncated(retrieval?.chunks.first?.evidenceText ?? recentSummaries.first ?? memoryContext, maxLength: 220)
          summaryUsedCloud = false
          AppLogger.log(.memory, "Person summary using selective-memory fallback personId=\(personId.uuidString) name=\(profile.displayName)")
        } else {
          do {
            let client = try DeepSeekAssistanceClient(apiKey: settings.apiKey, model: settings.model)
            summary = try await client.summarizePersonConversations(
              personName: profile.displayName,
              lastSeenText: lastSeenText,
              conversationTranscript: memoryContext
            )
          } catch {
            summary = Self.truncated(retrieval?.chunks.first?.evidenceText ?? recentSummaries.first ?? memoryContext, maxLength: 220)
            summaryUsedCloud = false
            AppLogger.log(.memory, "Person summary fell back to selective memory personId=\(personId.uuidString) name=\(profile.displayName) reason=\(error.localizedDescription)")
          }
        }

        let snapshot = PersonConversationSummary(
          personId: personId,
          displayName: profile.displayName,
          lastSeenText: lastSeenText,
          summary: summary,
          conversationCount: retrieval?.chunks.count ?? recentSummaries.count,
          generatedAt: Date()
        )

        await MainActor.run {
          guard self.assistanceGeneration == generation else {
            self.conversationSummaryInFlight.remove(personId)
            let needsRefresh = self.conversationSummaryRefreshPendingPersonIds.remove(personId) != nil
            AppLogger.log(.memory, "Ignoring stale person summary generation=\(generation) current=\(self.assistanceGeneration) personId=\(personId.uuidString)")
            if needsRefresh {
              self.refreshPersonConversationSummaryIfNeeded(personId: personId, forceSpeak: false, forceRefresh: true)
            }
            return
          }
          self.knownPersonCandidates = profiles.map {
            PersonNameCandidate(personId: $0.id, displayName: $0.displayName)
          }
          self.conversationSummaryCache[personId] = snapshot
          self.conversationSummaryInFlight.remove(personId)
          let needsRefresh = self.conversationSummaryRefreshPendingPersonIds.remove(personId) != nil
          AppLogger.log(.memory, "Person summary ready personId=\(personId.uuidString) name=\(profile.displayName) chunks=\(retrieval?.chunks.count ?? 0) fallbackSummaries=\(recentSummaries.count) evidenceChars=\(memoryContext.count)")
          self.deepSeekStatusText = memoryContext.isEmpty
            ? "No relevant saved memory for \(profile.displayName)"
            : summaryUsedCloud
              ? "DeepSeek summarized selected memory"
              : "Loaded selective memory"
          let identity = AssistanceIdentityState.known(
            name: profile.displayName,
            confidence: self.activeFacePersonId == personId ? self.activeFaceConfidence : 1.0,
            userConfirmed: true
          )
          let card = self.assistanceCardFormatter.makeCard(
            identity: identity,
            memory: self.currentAssistanceMemorySnapshot(personId: personId),
            displayStatus: .fallback("phone")
          )
          if self.livePhoneAssistanceDismissedPersonId != personId {
            self.phoneAssistanceDismissed = false
            self.livePhoneAssistancePinnedPersonId = personId
            self.publishPhoneAssistanceCard(card, status: "Phone display fallback", personId: personId)
            let shouldStackConfirmedSummary = self.glassesConfirmedConversationPersonId == personId
              || self.glassesConfirmedConversationPersonIds.contains(personId)
            self.publishGlassesAssistanceCard(
              identity: identity,
              memory: self.currentAssistanceMemorySnapshot(personId: personId),
              reason: "person-summary-ready",
              sendImmediately: !shouldStackConfirmedSummary
            )
            if shouldStackConfirmedSummary {
              self.publishConfirmedPersonSummaryIfNeeded(snapshot, reason: "person-summary-ready")
            }
          }
          if needsRefresh {
            self.refreshPersonConversationSummaryIfNeeded(personId: personId, forceSpeak: false, forceRefresh: true)
          }
      }
    }
  }

  private static func formatLastSeen(_ date: Date?) -> String {
    guard let date else { return "not recorded" }
    let relative = RelativeDateTimeFormatter()
    relative.unitsStyle = .full
    return relative.localizedString(for: date, relativeTo: Date())
  }

  private static func personConversationTranscriptContext(_ entry: PersonDictionaryEntry) -> String {
    let conversations = entry.conversationTranscripts
      .sorted { $0.startedAt < $1.startedAt }
    guard !conversations.isEmpty else { return "" }

    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short

    var blocks: [String] = []
    for conversation in conversations.suffix(12) {
      let lines = conversation.lines
        .filter { !$0.chunk.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .map { "\($0.speakerName): \($0.chunk.text.trimmingCharacters(in: .whitespacesAndNewlines))" }
      guard !lines.isEmpty else { continue }
      blocks.append("""
      Conversation \(formatter.string(from: conversation.startedAt)):
      \(lines.joined(separator: "\n"))
      """)
    }

    let joined = blocks.joined(separator: "\n\n")
    guard joined.count > 6_000 else { return joined }
    let start = joined.index(joined.endIndex, offsetBy: -6_000)
    return "Earlier transcript omitted for length.\n" + joined[start...]
  }

  private static func localPersonConversationSummary(
    _ entry: PersonDictionaryEntry,
    transcriptContext: String
  ) -> String {
    let lineCount = entry.conversationTranscripts.reduce(0) { $0 + $1.lines.count }
    let cleaned = transcriptContext
      .replacingOccurrences(of: "\n", with: " ")
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else {
      return "No saved attributed conversations yet."
    }
    let maxLength = 420
    let excerpt: String
    if cleaned.count > maxLength {
      let end = cleaned.index(cleaned.startIndex, offsetBy: maxLength)
      excerpt = String(cleaned[..<end]) + "..."
    } else {
      excerpt = cleaned
    }
    return "Saved history: \(entry.conversationTranscripts.count) conversation(s), \(lineCount) attributed line(s). Recent context: \(excerpt)"
  }

  private func currentAssistanceIdentity() -> AssistanceIdentityState {
    let partner = activeConversationPartnerState
    if partner.phase == .confirmed, let primary = partner.primary {
      return .known(
        name: primary.displayName ?? primary.personId?.uuidString ?? "Confirmed",
        confidence: primary.score,
        userConfirmed: true
      )
    }
    if partner.phase == .possible, let primary = partner.primary {
      return .possibleMatch(
        name: primary.displayName ?? primary.personId?.uuidString ?? "Possible",
        confidence: primary.score
      )
    }
    if partner.phase == .conflicted {
      return .unknown
    }
    if partner.phase == .multiplePeople {
      return .multipleFaces(count: max(detectedFaceCount, 2))
    }

    if detectedFaceCount > 1 {
      return .multipleFaces(count: detectedFaceCount)
    }
    if activeIdentityStateText == ActiveIdentityState.State.confirmed.rawValue {
      return .known(
        name: activeIdentityName,
        confidence: activeFaceConfidence,
        userConfirmed: true
      )
    }
    if activeIdentityStateText == ActiveIdentityState.State.possible.rawValue {
      return .possibleMatch(name: activeIdentityName, confidence: activeFaceConfidence)
    }
    if detectedFaceCount == 0 || activeIdentityStateText == ActiveIdentityState.State.noFace.rawValue {
      return .noFaceDetected
    }
    return .unknown
  }

  private func currentAssistanceMemorySnapshot(personId: UUID? = nil) -> AssistanceMemorySnapshot {
    var topics: [String] = []
    let partner = activeConversationPartnerState
    if let partnerTopic = assistancePartnerTopic(from: partner) {
      topics.append(partnerTopic)
    }
    if !recentConversationAttributionText.hasPrefix("No transcript") {
      topics.append(recentConversationAttributionText)
    }
    if !identitySummaryText.isEmpty && identitySummaryText != "Identity idle" {
      topics.append(identitySummaryText)
    }

    let reminder: String?
    switch partner.phase {
    case .conflicted:
      reminder = "Identity conflict: confirm person"
    case .multiplePeople:
      reminder = "Multiple people visible: hide private memory"
    case .confirmed:
      reminder = partner.primary?.displayName.map { "Current partner appears to be \($0)" }
    case .possible:
      reminder = partner.primary?.displayName.map { "Possible partner: \($0)" }
    case .unknown, .none:
      reminder = activeSpeakerStateText == "confirmed" && !activeSpeakerName.isEmpty
        ? "Current speaker appears to be \(activeSpeakerName)"
        : nil
    }

    let canShowPrivateMemory = personId != nil
      || partner.allowsPrivateMemory
      || (partner.phase == .none && activeIdentityStateText == ActiveIdentityState.State.confirmed.rawValue)
    let resolvedPersonId = personId ?? (canShowPrivateMemory ? (partner.primary?.personId ?? activeFacePersonId) : nil)
    let personSummary = resolvedPersonId.flatMap { conversationSummaryCache[$0] }

    return AssistanceMemorySnapshot(
      lastInteraction: topics.first,
      lastSeen: canShowPrivateMemory ? personSummary?.lastSeenText : nil,
      conversationSummary: canShowPrivateMemory ? personSummary?.summary : nil,
      contextTopics: Array(topics.dropFirst()),
      reminder: reminder,
      suggestedAction: "Keep the reply short and confirm uncertain details"
    )
  }

  private func assistancePartnerTopic(from state: ConversationPartnerState) -> String? {
    switch state.phase {
    case .confirmed:
      guard let name = state.primary?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty else {
        return "Partner confirmed"
      }
      return "Partner: \(name)"
    case .possible:
      guard let name = state.primary?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty else {
        return "Possible partner"
      }
      let confidence = Int(((state.primary?.score ?? 0) * 100).rounded())
      return "Possible partner: \(name) (\(confidence)%)"
    case .conflicted:
      return "Identity conflict"
    case .multiplePeople:
      return "Multiple people visible"
    case .unknown:
      return "Partner unknown"
    case .none:
      return nil
    }
  }

  private var isLiveDATStreamActive: Bool {
    inputMode == .realGlasses
      && datIsStreamRunning
      && datStreamSessionStateText.lowercased().contains("streaming")
  }

  private var isDATAnalysisPaused: Bool {
    analysisPaused && inputMode == .realGlasses
  }

  private func handleAnalysisPausedChanged() {
    AppLogger.log(.stream, "Pause analysis changed paused=\(analysisPaused) inputMode=\(inputMode.rawValue) datStream=\(datStreamSessionStateText) datRunning=\(datIsStreamRunning)")
    guard inputMode == .realGlasses else { return }
    if analysisPaused {
      Task { @MainActor [weak self] in
        await self?.pauseDATAnalysisConsumers(reason: "userToggle")
      }
    } else {
      resumeDATAnalysisConsumers(reason: "userToggle")
    }
  }

  private func pauseDATAnalysisConsumers(reason: String) async {
    guard inputMode == .realGlasses else { return }
    deferredCloudWorkerStartTask?.cancel()
    deferredCloudWorkerStartTask = nil
    speechManager.onAudioBuffer = { _ in }
    stopLiveTranscriptionForStream()
    resetPostSessionAttributionState()
    let discardedURL = audioRecorder.stop()
    if let discardedURL {
      try? FileManager.default.removeItem(at: discardedURL)
    }
    streamAudioStart = nil
    speakerTimeline = []
    cloudDiarizationState = .idle
    activeSpeakerStateText = "analysis paused"
    activeSpeakerName = ""
    activeSpeakerPersonId = nil
    activeSpeakerSimilarity = 0
    voiceSpeechBufferSeconds = 0
    voiceMatchStatusText = "Analysis paused"
    iPhoneVoiceSimilarityStatusText = "iPhone local estimate: analysis paused"
    workerVoiceSimilarityStatusText = "AWS canonical: analysis paused"
    wearerVoiceSimilarityStatusText = "Wearer: analysis paused"
    liveTranscriptPreviewText = "Analysis paused"
    liveTranscriptionStatusText = "Live ASR paused"
    sceneContextStatusText = "Scene context paused"
    await speakerPipeline.resetRuntimeState(reason: "analysisPaused-\(reason)")
    await stopCloudSpeakerWorkerForStream(reason: "analysisPaused-\(reason)")
    await stopCloudFaceWorkerForStream(reason: "analysisPaused-\(reason)")
    cloudFaceEmbeddingStatusText = "AWS AdaFace paused"
    cloudSpeakerEmbeddingStatusText = "AWS canonical speaker paused"
    workerVoiceSimilarityStatusText = "AWS canonical: analysis paused"
    AppLogger.log(.stream, "Paused nonessential DAT stream analysis; DAT stream and iPhone audio session are left intact reason=\(reason)")
  }

  private func resumeDATAnalysisConsumers(reason: String) {
    guard inputMode == .realGlasses else { return }
    guard livePhoneAudioSessionActive else {
      AppLogger.log(.stream, "Analysis resumed while live phone audio is inactive reason=\(reason)")
      return
    }
    configureLiveAudioBufferHandling(reason: "analysisResumed-\(reason)")
    startLiveTranscriptionForStream(reason: "analysisResumed-\(reason)")
    streamAudioStart = Date()
    postSessionLocalTranscriptSegments = []
    speakerTimeline = []
    cloudDiarizationState = .recording
    audioRecorder.start()
    startCloudWorkersForStream(reason: "analysisResumed-\(reason)", includeSpeaker: liveVoiceEmbeddingEnabled)
    AppLogger.log(.stream, "Resumed DAT stream analysis consumers reason=\(reason)")
  }

  private func isVoicePreviewBlockedByDATStream() -> Bool {
    guard isLiveDATStreamActive else { return false }
    AppLogger.log(.audio, "Voice preview blocked while DAT stream is active to avoid routing output to Meta/Ray-Ban glasses")
    return true
  }

  func saveDeepSeekSettings() {
    DeepSeekSettings(apiKey: deepSeekAPIKeyText, model: deepSeekModelText).save()
    let aiProxyConfigured = SupabaseEdgeFunctionClient.isConfigured()
    deepSeekStatusText = aiProxyConfigured
      ? "DeepSeek via Supabase Edge: \(deepSeekModelText)"
      : deepSeekAPIKeyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "DeepSeek key missing"
        : "DeepSeek configured: \(deepSeekModelText)"
    AppLogger.log(.audio, "DeepSeek settings saved model=\(deepSeekModelText) hasApiKey=\(!deepSeekAPIKeyText.isEmpty) proxy=\(aiProxyConfigured)")
  }

  func saveSceneContextSettings() {
    SceneContextSettings.save(enabled: sceneContextEnabled, locationEnabled: sceneLocationContextEnabled)
    let settings = SceneContextSettings.load()
    let aiProxyConfigured = SupabaseEdgeFunctionClient.isConfigured()
    sceneContextStatusText = sceneContextEnabled
      ? (aiProxyConfigured ? "Scene context via Supabase Edge: \(settings.model)" : settings.apiKey.isEmpty ? "Scene context key missing" : "Scene context saved: \(settings.model)")
      : "Scene context off"
    AppLogger.log(.sceneContext, "settings saved enabled=\(sceneContextEnabled) location=\(sceneLocationContextEnabled) model=\(settings.model) hasKey=\(!settings.apiKey.isEmpty) proxy=\(aiProxyConfigured)")
    if livePhoneAudioSessionActive {
      startSceneContextForStream(reason: "settingsChanged")
    } else if !sceneContextEnabled {
      stopSceneContextForStream()
    }
  }

  func saveCloudFaceEmbeddingSettings() {
    // Persist the worker-facing settings: when EC2 lifecycle is active the
    // endpoint comes from the Lambda's describeLive response, so the saved
    // endpoint stays empty and is only honored when EC2 lifecycle is off.
    let lifecycle = CloudFaceEmbeddingLifecycleSettings.load()
    let useEC2Lifecycle = lifecycle.useEC2Lifecycle
    CloudFaceEmbeddingSettings(
      enabled: cloudFaceEmbeddingEnabled,
      endpoint: useEC2Lifecycle ? "" : cloudFaceEmbeddingEndpointText,
      apiKey: cloudFaceEmbeddingAPIKeyText.isEmpty ? CloudFaceEmbeddingLifecycleSettings.defaultAPIKey : cloudFaceEmbeddingAPIKeyText
    ).save()
    CloudFaceEmbeddingLifecycleSettings(
      enabled: cloudFaceEmbeddingEnabled,
      endpointOverride: useEC2Lifecycle ? "" : cloudFaceEmbeddingEndpointText,
      apiKey: cloudFaceEmbeddingAPIKeyText.isEmpty ? CloudFaceEmbeddingLifecycleSettings.defaultAPIKey : cloudFaceEmbeddingAPIKeyText,
      lambdaFunctionName: CloudFaceEmbeddingLifecycleSettings.defaultLambdaFunctionName,
      workerPort: CloudFaceEmbeddingLifecycleSettings.defaultWorkerPort,
      useEC2Lifecycle: useEC2Lifecycle,
      stopOnStreamEnd: lifecycle.stopOnStreamEnd
    ).save()
    cloudFaceEmbeddingStatusText = cloudFaceEmbeddingEnabled
      ? "AWS AdaFace saved; starts with active or next stream"
      : "Cloud face embedding off"
    AppLogger.log(
      .faceEmbeddingModel,
      "Cloud face embedding settings saved enabled=\(cloudFaceEmbeddingEnabled) endpointOverride=\(cloudFaceEmbeddingEndpointText) hasApiKey=\(!cloudFaceEmbeddingAPIKeyText.isEmpty) useEC2Lifecycle=\(useEC2Lifecycle)"
    )
    guard livePhoneAudioSessionActive else { return }
    if cloudFaceEmbeddingEnabled {
      prepareCloudFaceWorkerForFaceTriggeredStart(reason: "settingsChanged")
    } else {
      Task { await stopCloudFaceWorkerForStream(reason: "settingsChanged") }
    }
  }

  func saveCloudSpeakerEmbeddingSettings() {
    CloudSpeakerEmbeddingSettings(
      enabled: cloudSpeakerEmbeddingEnabled,
      endpoint: "",
      apiKey: cloudSpeakerEmbeddingAPIKeyText,
      lambdaFunctionName: CloudSpeakerEmbeddingSettings.defaultLambdaFunctionName,
      workerPort: CloudSpeakerEmbeddingSettings.defaultWorkerPort,
      useEC2Lifecycle: true,
      stopOnStreamEnd: true
    ).save()
    cloudSpeakerEmbeddingStatusText = cloudSpeakerEmbeddingEnabled
      ? "AWS canonical speaker saved; starts with active or next stream"
      : "AWS canonical speaker embeddings off"
    AppLogger.log(
      .speakerEmbeddingModel,
      "AWS live speaker settings saved enabled=\(cloudSpeakerEmbeddingEnabled) endpointOverride=\(cloudSpeakerEmbeddingEndpointText) hasApiKey=\(!cloudSpeakerEmbeddingAPIKeyText.isEmpty)"
    )
    guard livePhoneAudioSessionActive else { return }
    if cloudSpeakerEmbeddingEnabled {
      startCloudSpeakerWorkerForStream()
    } else {
      Task { await stopCloudSpeakerWorkerForStream(reason: "settingsChanged") }
    }
  }

  private func recordSpeakerEvidenceIfNeeded(_ result: SpeakerProcessingResult) {
    let now = Date()
    if let wearerMatch = result.wearerSimilarity, wearerMatch.decision == .known {
      appendConversationPartnerEvidence(ConversationPartnerEvidence(
        source: .wearerVoice,
        personId: nil,
        displayName: "Me",
        confidence: wearerMatch.bestSimilarity,
        timestamp: now,
        validUntil: now.addingTimeInterval(SpeakerIdentityConfig.holdIdentitySeconds),
        details: "wearerVoice;\(wearerMatch.reason ?? "match")"
      ))
    }

    if let diagnostic = result.iPhoneSimilarity,
       let match = diagnostic.matchResult,
       match.bestSimilarity >= SpeakerIdentityConfig.weakMatchThreshold {
      appendConversationPartnerEvidence(ConversationPartnerEvidence(
        source: .voiceLocal,
        personId: match.bestPersonId,
        displayName: result.activeIdentity.displayName,
        confidence: match.bestSimilarity,
        timestamp: now,
        validUntil: now.addingTimeInterval(SpeakerIdentityConfig.holdIdentitySeconds),
        details: "iPhone;\(match.reason ?? "\(match.decision)")"
      ))
    }

    if let diagnostic = result.workerSimilarity,
       let match = diagnostic.matchResult,
       match.bestSimilarity >= SpeakerIdentityConfig.weakMatchThreshold {
      appendConversationPartnerEvidence(ConversationPartnerEvidence(
        source: .voiceAWS,
        personId: match.bestPersonId,
        displayName: result.activeIdentity.displayName,
        confidence: match.bestSimilarity,
        timestamp: now,
        validUntil: now.addingTimeInterval(SpeakerIdentityConfig.holdIdentitySeconds),
        details: "AWS;\(match.reason ?? "\(match.decision)")"
      ))
    }

    refreshConversationPartnerState(now: now)

    guard let personId = result.activeIdentity.personId else { return }
    let confidence = max(result.activeIdentity.confidence, result.matchResult?.bestSimilarity ?? 0)
    guard confidence > 0 else { return }
    speakerEvidenceTimeline.append(TimedSpeakerEvidence(
      timestamp: now,
      personId: personId,
      displayName: result.activeIdentity.displayName,
      confidence: confidence,
      state: result.activeIdentity.phase.rawValue
    ))
    speakerEvidenceTimeline = Array(speakerEvidenceTimeline.suffix(240))
    refreshConversationPartnerState(now: now)
  }

  private func recordFaceEvidenceIfNeeded(
    personId: UUID?,
    displayName: String?,
    confidence: Float,
    state: String,
    detectedFaceCount: Int
  ) {
    let now = Date()
    let faceSource: ConversationPartnerEvidence.Source = faceEmbeddingModelStatusText.localizedCaseInsensitiveContains("adaface")
      ? .faceAWS
      : .faceLocal
    if confidence > 0 || detectedFaceCount > 1 {
      appendConversationPartnerEvidence(ConversationPartnerEvidence(
        source: faceSource,
        personId: personId,
        displayName: displayName,
        confidence: confidence,
        timestamp: now,
        validUntil: now.addingTimeInterval(IdentityConfig.holdIdentitySeconds),
        details: "state=\(state);faceCount=\(detectedFaceCount);model=\(safeEvidenceValue(faceEmbeddingModelStatusText))"
      ))
    }
    if latestMouthMovementScore > 0 {
      appendConversationPartnerEvidence(ConversationPartnerEvidence(
        source: .mouthMovement,
        personId: personId,
        displayName: displayName,
        confidence: latestMouthMovementScore,
        timestamp: now,
        validUntil: now.addingTimeInterval(1.5),
        details: "mouthMovement"
      ))
    }

    refreshConversationPartnerState(now: now)

    guard let personId else { return }
    guard confidence > 0 else { return }
    faceEvidenceTimeline.append(TimedFaceEvidence(
      timestamp: now,
      personId: personId,
      displayName: displayName,
      confidence: confidence,
      state: state,
      mouthMovementScore: latestMouthMovementScore
    ))
    faceEvidenceTimeline = Array(faceEvidenceTimeline.suffix(240))
  }

  private func appendConversationPartnerEvidence(_ evidence: ConversationPartnerEvidence) {
    conversationPartnerEvidence.append(evidence)
    conversationPartnerEvidence = conversationPartnerEvidence
      .filter { $0.validUntil >= evidence.timestamp.addingTimeInterval(-2) }
      .suffix(320)
      .map { $0 }
    if let episode = presenceTracker.record(evidence: evidence, now: evidence.timestamp) {
      persistPresenceEpisode(episode, reason: evidence.source.rawValue, now: evidence.timestamp)
    }
  }

  private func persistPresenceEpisode(
    _ episode: PersonPresenceEpisode,
    reason: String,
    now: Date = Date(),
    force: Bool = false
  ) {
    guard let context = pipelineContext else { return }
    let record = PresenceEpisodeRecord(episode: episode, context: context, updatedAt: now)
    let signature = record.syncSignature
    if !force,
       record.status == .active,
       let lastSavedAt = lastPresenceEpisodeSavedAt[record.id],
       now.timeIntervalSince(lastSavedAt) < 5 {
      return
    }
    guard force || lastSavedPresenceEpisodeSignatures[record.id] != signature else { return }
    lastSavedPresenceEpisodeSignatures[record.id] = signature
    lastPresenceEpisodeSavedAt[record.id] = now
    Task { [identityPipeline] in
      await identityPipeline.savePresenceEpisode(record)
    }
    AppLogger.log(
      .database,
      "\(context.logPrefix) presenceEpisode queued id=\(record.id.uuidString) status=\(record.status.rawValue) person=\(record.personId?.uuidString ?? "unknown") reason=\(reason)"
    )
  }

  private func persistFinalPresenceEpisodes(reason: String) {
    let now = Date()
    let episodes = presenceTracker.closeAllActive(now: now, evidence: "streamEnded:\(reason)")
    for episode in episodes {
      persistPresenceEpisode(episode, reason: reason, now: now, force: true)
    }
    clearRetainedRecognizedIdentity(reason: "streamEnded-\(reason)")
  }

  private func refreshConversationPartnerState(now: Date = Date()) {
    let state = conversationPartnerResolver.resolve(evidence: conversationPartnerEvidence, now: now)
    activeConversationPartnerState = state
    activeConversationPartnerStateText = state.phase.rawValue
    activeConversationPartnerName = state.primary?.displayName
      ?? state.primary?.personId?.uuidString
      ?? {
        switch state.phase {
        case .none:
          return "None"
        case .unknown:
          return "Unknown"
        case .multiplePeople:
          return "Multiple people"
        case .conflicted:
          return "Conflict"
        case .possible:
          return "Possible"
        case .confirmed:
          return "Confirmed"
        }
      }()
    activeConversationPartnerConfidenceText = String(format: "%.2f", Double(state.primary?.score ?? 0))
    activeConversationPartnerEvidenceText = state.sourceSummary
    if state.phase == .confirmed, let personId = state.primary?.personId {
      refreshPersonConversationSummaryForCurrentStreamIfNeeded(personId: personId)
    }
    conversationPartnerTimeline.append(TimedConversationPartnerState(timestamp: now, state: state))
    conversationPartnerTimeline = conversationPartnerTimeline
      .filter { now.timeIntervalSince($0.timestamp) <= 120 }
      .suffix(240)
      .map { $0 }
  }

  private func finalizeConversationTranscriptAfterStream(reason: String) async {
    guard conversationSavingEnabled else { return }
    let chunks = await identityPipeline.currentConversationTranscriptChunks()
    let speakerSegments = await speakerPipeline.diarizationSegmentsSnapshot()
    let finalChunks = chunks.filter {
      $0.isFinal && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    guard !finalChunks.isEmpty else {
      AppLogger.log(.transcript, "postSessionAttribution skipped reason=\(reason) chunks=0 voiceEvidence=\(speakerEvidenceTimeline.count) faceEvidence=\(faceEvidenceTimeline.count)")
      return
    }
    let attributions = Dictionary(uniqueKeysWithValues: finalChunks.map { chunk in
      (chunk.id, attributionForEndedChunk(chunk, speakerSegments: speakerSegments))
    })
    let snapshot = await identityPipeline.updateCurrentConversationTranscriptAttributions(attributions)
    applyRunSessionSnapshot(snapshot)
    AppLogger.log(.transcript, "postSessionAttribution reason=\(reason) chunks=\(finalChunks.count) diarizationSegments=\(speakerSegments.count) voiceEvidence=\(speakerEvidenceTimeline.count) faceEvidence=\(faceEvidenceTimeline.count)")
    if showPeopleDictionary {
      peopleDictionaryEntries = await identityPipeline.loadPeopleForDictionary()
    }
  }

  private func scheduleLatestStreamSummary(reason: String) async {
    let endedAt = Date()
    let chunks = await identityPipeline.currentConversationTranscriptChunks()
      .filter { $0.isFinal && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    let sceneContexts = await identityPipeline.currentConversationSceneContexts()
    let conversationSessionId = pipelineContext?.conversationSessionId
    guard !chunks.isEmpty || !sceneContexts.isEmpty else {
      let startedAt = streamAudioStart ?? endedAt
      let analysis = StreamSummaryAnalysis(
        summary: "No transcript or scene context was captured for the latest stream.",
        who: "unknown",
        whereText: "unknown",
        what: "No transcript or scene context captured",
        whenText: endedAt.formatted(date: .numeric, time: .shortened),
        why: "unknown",
        how: "unknown",
        people: [],
        keyMoments: [],
        outline: ["No transcript was captured", "No multimodal scene context was saved"],
        confidence: 0
      )
      latestStreamSummaryTimeText = endedAt.formatted(date: .omitted, time: .shortened)
      latestStreamSummaryText = analysis.summary
      latestStreamSummaryStatusText = "Stream summary skipped"
      recordStreamSummaryHistory(
        analysis,
        conversationSessionId: conversationSessionId,
        startedAt: startedAt,
        endedAt: endedAt,
        modelName: "local",
        statusText: latestStreamSummaryStatusText
      )
      AppLogger.log(.sceneContext, "Stream summary final source=local reason=\(reason) fallbackReason=noContent chunks=0 contexts=0 status=skipped")
      return
    }

    let settings = SceneContextSettings.load()
    let summaryModel = settings.textModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? SceneContextSettings.defaultTextModel
      : settings.textModel.trimmingCharacters(in: .whitespacesAndNewlines)
    let startedAt = streamAudioStart
      ?? chunks.compactMap(\.startedAt).min()
      ?? sceneContexts.map(\.startedAt).min()
      ?? endedAt
    let attribution = currentTranscriptAttribution()
    let identityEvidence = currentSceneContextIdentityEvidence(attribution: attribution)
    let request = StreamSummaryRequest(
      transcripts: chunks,
      sceneContexts: sceneContexts,
      startedAt: startedAt,
      endedAt: endedAt,
      identityEvidence: identityEvidence
    )
    latestStreamSummaryTask?.cancel()
    latestStreamSummaryTimeText = endedAt.formatted(date: .omitted, time: .shortened)
    latestStreamSummaryText = "Summarizing latest stream..."
    let aiProxyConfigured = SupabaseEdgeFunctionClient.isConfigured()
    latestStreamSummaryStatusText = aiProxyConfigured
      ? "Alibaba summary proxy: \(summaryModel)"
      : settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "Alibaba summary key missing"
        : "Alibaba summarizing: \(summaryModel)"
    AppLogger.log(
      .sceneContext,
      "Stream summary requested reason=\(reason) source=alibaba model=\(summaryModel) chunks=\(chunks.count) contexts=\(sceneContexts.count) proxy=\(aiProxyConfigured)"
    )

    latestStreamSummaryTask = Task { @MainActor [weak self, request, settings, reason, conversationSessionId, startedAt, identityEvidence, summaryModel] in
      guard let self else { return }
      do {
        let analysis = try await SceneContextClient(settings: settings).summarizeStreamLongSafe(request)
        guard !Task.isCancelled else { return }
        self.latestStreamSummaryText = analysis.summary
        self.latestStreamSummaryStatusText = "Alibaba summary ready: \(summaryModel)"
        self.recordStreamSummaryHistory(
          analysis,
          conversationSessionId: conversationSessionId,
          startedAt: startedAt,
          endedAt: request.endedAt,
          modelName: summaryModel,
          statusText: self.latestStreamSummaryStatusText
        )
        AppLogger.log(
          .sceneContext,
          "Stream summary final source=alibaba reason=\(reason) model=\(summaryModel) chunks=\(request.transcripts.count) contexts=\(request.sceneContexts.count) summaryChars=\(analysis.summary.count) confidence=\(String(format: "%.2f", analysis.confidence)) people=\(analysis.people.joined(separator: ","))"
        )
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled else { return }
        let fallbackReason = SceneContextClient.streamSummaryFallbackReason(for: error)
        let fallback = Self.localLatestStreamSummaryAnalysis(
          transcripts: request.transcripts,
          sceneContexts: request.sceneContexts,
          startedAt: startedAt,
          endedAt: request.endedAt,
          identityEvidence: identityEvidence
        )
        self.latestStreamSummaryText = fallback.summary
        self.latestStreamSummaryStatusText = "Alibaba summary failed; local summary shown"
        self.recordStreamSummaryHistory(
          fallback,
          conversationSessionId: conversationSessionId,
          startedAt: startedAt,
          endedAt: request.endedAt,
          modelName: "local",
          statusText: self.latestStreamSummaryStatusText
        )
        AppLogger.log(
          .sceneContext,
          "Stream summary final source=local reason=\(reason) alibabaModel=\(summaryModel) fallbackReason=\"\(fallbackReason)\" chunks=\(request.transcripts.count) contexts=\(request.sceneContexts.count) summaryChars=\(fallback.summary.count)"
        )
      }
    }
  }

  private func recordStreamSummaryHistory(
    _ analysis: StreamSummaryAnalysis,
    conversationSessionId: UUID?,
    startedAt: Date,
    endedAt: Date,
    modelName: String,
    statusText: String
  ) {
    let entry = StreamSummaryHistoryEntry(
      conversationSessionId: conversationSessionId,
      startedAt: startedAt,
      endedAt: endedAt,
      analysis: analysis,
      modelName: modelName,
      statusText: statusText
    )
    var entries = StreamSummaryHistoryStore.load()
    if let conversationSessionId {
      entries.removeAll { $0.conversationSessionId == conversationSessionId }
    } else {
      entries.removeAll {
        abs($0.endedAt.timeIntervalSince(endedAt)) < 1
          && $0.summary == analysis.summary
      }
    }
    entries.insert(entry, at: 0)
    StreamSummaryHistoryStore.save(entries)
    streamSummaryHistory = StreamSummaryHistoryStore.load()
    indexStreamSummary(entry)
  }

  private func indexRecentStreamSummaries() {
    for entry in StreamSummaryHistoryStore.load().prefix(3) {
      indexStreamSummary(entry)
    }
  }

  private func indexStreamSummary(_ entry: StreamSummaryHistoryEntry) {
    guard SupabaseEdgeFunctionClient.isConfigured() else { return }
    let normalizedPeople = Set(entry.people.map(LiveTranscriptQuestionRouter.normalizedSearchText))
    let matchedPersonIds = knownPersonCandidates
      .filter { normalizedPeople.contains(LiveTranscriptQuestionRouter.normalizedSearchText($0.displayName)) }
      .map(\.personId)
    let request = MemoryIndexRequest(
      id: entry.id,
      sourceRecordId: entry.id,
      sourceType: .streamSummary,
      conversationId: entry.conversationSessionId,
      streamId: entry.conversationSessionId,
      personId: matchedPersonIds.count == 1 ? matchedPersonIds[0] : nil,
      chunkText: ([entry.summary] + entry.keyMoments + entry.outline)
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .joined(separator: "\n"),
      summaryText: entry.summary,
      keywords: entry.people,
      categories: [],
      startTime: entry.startedAt,
      endTime: entry.endedAt,
      importanceScore: max(0, min(entry.confidence, 1)),
      sensitivityLevel: nil,
      metadata: [
        "model": entry.modelName,
        "status": entry.statusText
      ]
    )
    Task {
      do {
        try await RemoteMemoryRetrievalService().index(request)
      } catch {
        AppLogger.log(.memory, "[MEMORY_INDEX] source=stream_summary id=\(entry.id.uuidString.prefix(8)) status=deferred reason=\(error.localizedDescription)")
      }
    }
  }

  private static func localLatestStreamSummaryAnalysis(
    transcripts: [TranscriptChunk],
    sceneContexts: [SceneContextRecord],
    startedAt: Date,
    endedAt: Date,
    identityEvidence: SceneContextIdentityEvidence?
  ) -> StreamSummaryAnalysis {
    let latestContext = sceneContexts.sorted(by: { $0.createdAt > $1.createdAt }).first
    let text = transcripts
      .sorted { ($0.startedAt ?? $0.createdAt) < ($1.startedAt ?? $1.createdAt) }
      .map(\.text)
      .joined(separator: " ")
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let people = uniqueDisplayStrings(
      (identityEvidence?.activePeople.map(\.displayName) ?? [])
        + (identityEvidence?.conversationPartnerName.map { [$0] } ?? [])
        + sceneContexts.flatMap { context in
          context.who
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    )
    let summary: String
    if let context = latestContext,
       !context.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      summary = truncated(context.summary, maxLength: 220)
    } else if !text.isEmpty {
      summary = truncated(text, maxLength: 220)
    } else {
      summary = "No usable latest-stream content was captured."
    }
    let who = people.isEmpty ? latestContext?.who ?? "unknown" : people.joined(separator: ", ")
    let whereText = semanticWhereText(latestContext?.whereText)
    let what = latestContext?.what ?? (text.isEmpty ? "unknown" : truncated(text, maxLength: 120))
    let whenText = "\(startedAt.formatted(date: .numeric, time: .shortened)) to \(endedAt.formatted(date: .numeric, time: .shortened))"
    let why = latestContext?.why ?? "unknown"
    let how = latestContext?.how ?? "unknown"
    let keyMoments = sceneContexts
      .sorted { $0.createdAt < $1.createdAt }
      .map { truncated($0.summary, maxLength: 96) }
      .filter { !$0.isEmpty }
    let outline = [
      "Who: \(who)",
      "Where: \(whereText)",
      "What: \(what)"
    ].filter { !$0.hasSuffix(": unknown") }
    return StreamSummaryAnalysis(
      summary: summary,
      who: who,
      whereText: whereText,
      what: what,
      whenText: whenText,
      why: why,
      how: how,
      people: people,
      keyMoments: Array(keyMoments.prefix(4)),
      outline: outline,
      confidence: latestContext?.confidence ?? (text.isEmpty ? 0 : 0.35)
    )
  }

  nonisolated private static func uniqueDisplayStrings(_ values: [String]) -> [String] {
    var seen: Set<String> = []
    var output: [String] = []
    let ignoredValues: Set<String> = [
      "none",
      "unknown",
      "unknown person",
      "confirmed",
      "possible",
      "conflict",
      "multiple people"
    ]
    for value in values {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, !ignoredValues.contains(trimmed.lowercased()) else { continue }
      let key = trimmed.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
      guard seen.insert(key).inserted else { continue }
      output.append(trimmed)
    }
    return output
  }

  private static func semanticWhereText(_ value: String?) -> String {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty else { return "unknown" }
    let lower = trimmed.lowercased()
    if lower.contains("lat ") || lower.contains("lon ") || lower.contains("location ") {
      return "unknown"
    }
    return truncated(trimmed, maxLength: 96)
  }

  private func pendingPostSessionAttribution() -> TranscriptAttribution {
    TranscriptAttribution(
      personId: nil,
      displayName: nil,
      confidence: 0,
      state: "pendingPostSession",
      sourceEvidence: "postSessionPending"
    )
  }

  private func attributionForEndedChunk(
    _ chunk: TranscriptChunk,
    speakerSegments: [SpeakerDiarizationSegmentSnapshot]
  ) -> TranscriptAttribution {
    let diarized = diarizationAttributionForEndedChunk(chunk, speakerSegments: speakerSegments)
    if let diarized, diarized.personId != nil {
      return diarized
    }
    if let partner = partnerAttributionForEndedChunk(chunk) {
      return partner
    }
    if let diarized {
      return diarized
    }

    let target = chunk.startedAt ?? chunk.createdAt
    let displayNamesById = Dictionary(uniqueKeysWithValues: peopleDictionaryEntries.map { ($0.id, $0.displayName) })

    let voiceCandidates: [(evidence: TimedSpeakerEvidence, distance: TimeInterval)] = speakerEvidenceTimeline.compactMap { evidence in
      let distance = abs(evidence.timestamp.timeIntervalSince(target))
      guard distance <= 10 else { return nil }
      return (evidence: evidence, distance: distance)
    }
    let voice = voiceCandidates.max { lhs, rhs in
      let lhsScore = lhs.evidence.confidence - Float(lhs.distance * 0.025)
      let rhsScore = rhs.evidence.confidence - Float(rhs.distance * 0.025)
      return lhsScore < rhsScore
    }

    let faceCandidates: [(evidence: TimedFaceEvidence, distance: TimeInterval)] = faceEvidenceTimeline.compactMap { evidence in
      let distance = abs(evidence.timestamp.timeIntervalSince(target))
      guard distance <= 6 else { return nil }
      return (evidence: evidence, distance: distance)
    }
    let face = faceCandidates.max { lhs, rhs in
      let lhsScore = (lhs.evidence.confidence * 0.70)
        + (lhs.evidence.mouthMovementScore * 0.30)
        - Float(lhs.distance * 0.03)
      let rhsScore = (rhs.evidence.confidence * 0.70)
        + (rhs.evidence.mouthMovementScore * 0.30)
        - Float(rhs.distance * 0.03)
      return lhsScore < rhsScore
    }

    if let voice, voice.evidence.confidence >= SpeakerIdentityConfig.weakMatchThreshold {
      var confidence = voice.evidence.confidence
      var evidenceText = "postFusion:voice=\(String(format: "%.2f", Double(voice.evidence.confidence)));voiceDt=\(String(format: "%.1f", Double(voice.distance)))"
      if let face, face.evidence.personId == voice.evidence.personId {
        confidence = min(1, (voice.evidence.confidence * 0.65) + (face.evidence.confidence * 0.25) + (face.evidence.mouthMovementScore * 0.10))
        evidenceText += ";face=\(String(format: "%.2f", Double(face.evidence.confidence)));mouth=\(String(format: "%.2f", Double(face.evidence.mouthMovementScore)));faceDt=\(String(format: "%.1f", Double(face.distance)))"
      } else if let face {
        evidenceText += ";faceDisagrees=\(String(format: "%.2f", Double(face.evidence.confidence)));mouth=\(String(format: "%.2f", Double(face.evidence.mouthMovementScore)));faceDt=\(String(format: "%.1f", Double(face.distance)))"
      }
      return TranscriptAttribution(
        personId: voice.evidence.personId,
        displayName: voice.evidence.displayName ?? displayNamesById[voice.evidence.personId],
        confidence: confidence,
        state: "postFusedVoice",
        sourceEvidence: evidenceText
      )
    }

    if let face, face.evidence.confidence >= IdentityConfig.weakMatchThreshold, face.evidence.mouthMovementScore >= 0.08 {
      let confidence = min(1, (face.evidence.confidence * 0.70) + (face.evidence.mouthMovementScore * 0.30))
      return TranscriptAttribution(
        personId: face.evidence.personId,
        displayName: face.evidence.displayName ?? displayNamesById[face.evidence.personId],
        confidence: confidence,
        state: "postFusedFaceMouth",
        sourceEvidence: "postFusion:face=\(String(format: "%.2f", Double(face.evidence.confidence)));mouth=\(String(format: "%.2f", Double(face.evidence.mouthMovementScore)));faceDt=\(String(format: "%.1f", Double(face.distance)));voice=none"
      )
    }

    return TranscriptAttribution(
      personId: nil,
      displayName: nil,
      confidence: 0,
      state: "unknown",
      sourceEvidence: "postFusion:unknown;voice=\(voice.map { String(format: "%.2f", Double($0.evidence.confidence)) } ?? "none");face=\(face.map { String(format: "%.2f", Double($0.evidence.confidence)) } ?? "none");mouth=\(face.map { String(format: "%.2f", Double($0.evidence.mouthMovementScore)) } ?? "none")"
    )
  }

  private func diarizationAttributionForEndedChunk(
    _ chunk: TranscriptChunk,
    speakerSegments: [SpeakerDiarizationSegmentSnapshot]
  ) -> TranscriptAttribution? {
    guard !speakerSegments.isEmpty else { return nil }
    let chunkStart = chunk.startedAt ?? chunk.createdAt
    let rawEnd = chunk.endedAt ?? chunk.transcriptUpdatedAt
    let chunkEnd = max(rawEnd, chunkStart.addingTimeInterval(0.25))
    let chunkMid = Date(timeIntervalSince1970: (chunkStart.timeIntervalSince1970 + chunkEnd.timeIntervalSince1970) / 2)

    let best = speakerSegments.map { segment in
      let overlap = max(0, min(chunkEnd.timeIntervalSince1970, segment.endAt.timeIntervalSince1970) - max(chunkStart.timeIntervalSince1970, segment.startAt.timeIntervalSince1970))
      let segmentMid = Date(timeIntervalSince1970: (segment.startAt.timeIntervalSince1970 + segment.endAt.timeIntervalSince1970) / 2)
      let distance = abs(segmentMid.timeIntervalSince(chunkMid))
      let score = Float(overlap) + (segment.confidence * 0.25) - Float(distance * 0.04)
      return (segment: segment, overlap: overlap, distance: distance, score: score)
    }
    .max { lhs, rhs in
      lhs.score < rhs.score
    }

    guard let best, best.overlap > 0 || best.distance <= 8 else { return nil }
    let speakerName = best.segment.speakerName
    let state = best.segment.personId == nil ? "diarizedSpeaker" : "diarizedKnown"
    let evidence = "\(best.segment.source);speakerLabel=\(safeEvidenceValue(speakerName));overlap=\(String(format: "%.2f", Double(best.overlap)));distance=\(String(format: "%.2f", Double(best.distance)))"
    return TranscriptAttribution(
      personId: best.segment.personId,
      displayName: speakerName,
      confidence: best.segment.confidence,
      state: state,
      sourceEvidence: evidence
    )
  }

  private func safeEvidenceValue(_ value: String) -> String {
    value.replacingOccurrences(of: ";", with: ",")
  }

  private func partnerAttributionForEndedChunk(_ chunk: TranscriptChunk) -> TranscriptAttribution? {
    guard !conversationPartnerTimeline.isEmpty else { return nil }
    let chunkStart = chunk.startedAt ?? chunk.createdAt
    let rawEnd = chunk.endedAt ?? chunk.transcriptUpdatedAt
    let chunkEnd = max(rawEnd, chunkStart.addingTimeInterval(0.25))
    let chunkMid = Date(timeIntervalSince1970: (chunkStart.timeIntervalSince1970 + chunkEnd.timeIntervalSince1970) / 2)
    guard let best = conversationPartnerTimeline
      .map({ snapshot in
        (snapshot: snapshot, distance: abs(snapshot.timestamp.timeIntervalSince(chunkMid)))
      })
      .filter({ $0.distance <= 8 })
      .min(by: { $0.distance < $1.distance }) else {
      return nil
    }

    let state = best.snapshot.state
    let evidence = "partnerResolver:\(safeEvidenceValue(state.sourceSummary));dt=\(String(format: "%.1f", Double(best.distance)))"
    switch state.phase {
    case .confirmed, .possible:
      guard let primary = state.primary else { return nil }
      let displayName = primary.personId == nil ? nil : primary.displayName
      return TranscriptAttribution(
        personId: primary.personId,
        displayName: displayName,
        confidence: primary.score,
        state: state.attributionState,
        sourceEvidence: evidence
      )
    case .conflicted, .multiplePeople:
      return TranscriptAttribution(
        personId: nil,
        displayName: nil,
        confidence: 0,
        state: state.attributionState,
        sourceEvidence: evidence
      )
    case .none, .unknown:
      return nil
    }
  }

  // MARK: - Cloud diarization

  private func recordSpeakerTimelineEntry(personId: UUID?, displayName: String?) {
    let last = speakerTimeline.last
    guard last?.personId != personId else { return }  // skip duplicates
    speakerTimeline.append(SpeakerTimelineEntry(timestamp: Date(), personId: personId, displayName: displayName))
  }

  nonisolated private static func runCloudDiarizationJob(
    audioURL: URL,
    streamStart: Date,
    localTranscriptSegments: [LocalPostSessionTranscriptSegment],
    speakerTimeline: [SpeakerTimelineEntry],
    speakerEvidenceTimeline: [TimedSpeakerEvidence],
    faceEvidenceTimeline: [TimedFaceEvidence],
    pipelineContext: PipelineContext?,
    cloudDiarizationService: CloudDiarizationService,
    identityPipeline: IdentityPipeline
  ) async throws -> CloudDiarizationProcessingOutput? {
    guard let audioSeconds = Self.audioDurationSeconds(audioURL) else {
      AppLogger.log(.audio, "[CloudDiarization] Skipping AWS job because recorded audio duration could not be read file=\(audioURL.lastPathComponent)")
      return nil
    }
    guard audioSeconds >= CloudDiarizationTuning.minimumAudioSeconds else {
      AppLogger.log(
        .audio,
        "[CloudDiarization] Skipping AWS job because audio is shorter than \(String(format: "%.1f", Double(CloudDiarizationTuning.minimumAudioSeconds)))s seconds=\(String(format: "%.2f", Double(audioSeconds))) file=\(audioURL.lastPathComponent)"
      )
      return nil
    }

    let result = try await cloudDiarizationService.submitJob(
      audioFileURL: audioURL,
      streamStart: streamStart,
      conversationSessionId: pipelineContext?.conversationSessionId
    )
    guard !Task.isCancelled else { throw CancellationError() }
    return try await Self.processDiarizationResult(
      result,
      audioURL: audioURL,
      streamStart: streamStart,
      localTranscriptSegments: localTranscriptSegments,
      speakerTimeline: speakerTimeline,
      speakerEvidenceTimeline: speakerEvidenceTimeline,
      faceEvidenceTimeline: faceEvidenceTimeline,
      pipelineContext: pipelineContext,
      cloudDiarizationService: cloudDiarizationService,
      identityPipeline: identityPipeline
    )
  }

  nonisolated private static func audioDurationSeconds(_ url: URL) -> Double? {
    do {
      let file = try AVAudioFile(forReading: url)
      let sampleRate = file.processingFormat.sampleRate
      guard sampleRate > 0 else { return nil }
      return Double(file.length) / sampleRate
    } catch {
      AppLogger.log(.audio, "[CloudDiarization] Could not inspect audio duration: \(error.localizedDescription)")
      return nil
    }
  }

  nonisolated private static func processDiarizationResult(
    _ result: DiarizenResult,
    audioURL: URL,
    streamStart: Date,
    localTranscriptSegments: [LocalPostSessionTranscriptSegment],
    speakerTimeline: [SpeakerTimelineEntry],
    speakerEvidenceTimeline: [TimedSpeakerEvidence],
    faceEvidenceTimeline: [TimedFaceEvidence],
    pipelineContext: PipelineContext?,
    cloudDiarizationService: CloudDiarizationService,
    identityPipeline: IdentityPipeline
  ) async throws -> CloudDiarizationProcessingOutput? {
    guard let ctx = pipelineContext, let sessionId = ctx.conversationSessionId else { return nil }
    let attributedSegments = speakerAttributedTranscriptSegments(
      diarizationResult: result,
      localTranscriptSegments: localTranscriptSegments,
      streamStart: streamStart
    )
    let hasUsableLocalParakeetTranscript = localTranscriptSegments.contains {
      $0.provider == .localParakeet && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    let usesAuthoritativeCloudTranscript = cloudTranscriptIsAuthoritative(result)
    let transcriptSourcePrefix = usesAuthoritativeCloudTranscript
      ? "awsCanaryQwen+awsSortformer"
      : (hasUsableLocalParakeetTranscript ? "iPhoneParakeetASR+awsDiarization" : "awsDiarization")
    AppLogger.log(
      .speakerEnrollment,
      "[CloudDiarization] transcript source=\(transcriptSourcePrefix) pipeline=\(result.pipelineVersion ?? "legacy") diarizationModel=\(result.diarizationModel ?? "unknown") transcriptionModel=\(result.transcriptionModel ?? "unknown") localSegments=\(localTranscriptSegments.count) cloudSegments=\(result.segments.count) selectedSegments=\(attributedSegments.count)"
    )

    // Build a bounded lookup: given a diarized segment, find a nearby confirmed
    // speaker/person without letting an old identity bleed across later speakers.
    func attribution(for segment: DiarizenSegment) -> (personId: UUID?, displayName: String?, source: String) {
      let midpoint = (segment.start + segment.end) / 2
      let ts = streamStart.addingTimeInterval(midpoint)

      let speakerCandidates: [(evidence: TimedSpeakerEvidence, distance: TimeInterval)] = speakerEvidenceTimeline.compactMap { evidence in
        let distance = abs(evidence.timestamp.timeIntervalSince(ts))
        guard distance <= CloudDiarizationTuning.maxSpeakerEvidenceAge else { return nil }
        return (evidence: evidence, distance: distance)
      }
      if let voice = speakerCandidates.max(by: { lhs, rhs in
        let lhsScore = lhs.evidence.confidence - Float(lhs.distance * 0.025)
        let rhsScore = rhs.evidence.confidence - Float(rhs.distance * 0.025)
        return lhsScore < rhsScore
      }) {
        return (
          voice.evidence.personId,
          voice.evidence.displayName,
          "speakerEvidence distance=\(String(format: "%.1f", Double(voice.distance))) confidence=\(String(format: "%.3f", Double(voice.evidence.confidence)))"
        )
      }

      // The legacy timeline also receives face/user-confirmation entries. Keep it
      // useful for immediate confirmations, but never let it carry indefinitely.
      for entry in speakerTimeline.reversed() {
        let age = ts.timeIntervalSince(entry.timestamp)
        guard age >= 0 else { continue }
        guard age <= CloudDiarizationTuning.maxTimelineEvidenceAge else { break }
        return (
          entry.personId,
          entry.displayName,
          "recentTimeline age=\(String(format: "%.1f", Double(age)))"
        )
      }

      let face = faceEvidenceTimeline
        .filter {
          $0.confidence >= IdentityConfig.weakMatchThreshold
            && abs($0.timestamp.timeIntervalSince(ts)) <= CloudDiarizationTuning.maxFaceEvidenceAge
        }
        .max { lhs, rhs in
          let lhsScore = lhs.confidence - Float(abs(lhs.timestamp.timeIntervalSince(ts)) * 0.02)
          let rhsScore = rhs.confidence - Float(abs(rhs.timestamp.timeIntervalSince(ts)) * 0.02)
          return lhsScore < rhsScore
        }
      if let face {
        let distance = abs(face.timestamp.timeIntervalSince(ts))
        return (
          face.personId,
          face.displayName,
          "faceEvidence distance=\(String(format: "%.1f", Double(distance))) confidence=\(String(format: "%.3f", Double(face.confidence)))"
        )
      }
      return (nil, nil, "unresolved")
    }

    // Group unknown speakers for enrollment prompt
    var unknownSpeakers: [Int: UnknownDiarizationSpeaker] = [:]
    var unknownPreviewCandidates: [Int: [DiarizenSegment]] = [:]
    var savedChunkCount = 0
    var attributedPersonIds: Set<UUID> = []

    for segment in attributedSegments where !segment.text.isEmpty {
      guard !Task.isCancelled else { throw CancellationError() }
      let segStart = streamStart.addingTimeInterval(segment.start)
      let segEnd   = streamStart.addingTimeInterval(segment.end)
      let resolved = attribution(for: segment)
      let resolvedPersonId = resolved.personId
      let resolvedName = resolved.displayName
      if let resolvedPersonId {
        attributedPersonIds.insert(resolvedPersonId)
      }
      let dur = max(0, segment.end - segment.start)
      AppLogger.log(
        .speakerEnrollment,
        "[CloudDiarization] segment speaker=\(segment.speakerIndex) seconds=\(String(format: "%.2f", Double(dur))) textLen=\(segment.text.count) attributed=\(resolvedPersonId?.uuidString ?? "unknown") name=\"\(resolvedName ?? "unknown")\" source=\(resolved.source)"
      )

      let chunk = TranscriptChunk(
        id: UUID(),
        appRunId: ctx.appRunId,
        conversationSessionId: sessionId,
        personId: resolvedPersonId,
        activeIdentityState: resolvedPersonId != nil ? "confirmed" : "unknown",
        text: segment.text,
        isFinal: true,
        startedAt: segStart,
        endedAt: segEnd,
        transcriptUpdatedAt: Date(),
        source: resolvedPersonId != nil
          ? "\(transcriptSourcePrefix):\(resolvedName ?? "confirmed")"
          : "\(transcriptSourcePrefix):unknown:Speaker\(segment.speakerIndex)",
        createdAt: Date()
      )
      await identityPipeline.saveCloudTranscriptChunk(chunk)
      savedChunkCount += 1

      // Track unknown speakers
      if resolvedPersonId == nil, segment.speakerIndex >= 0 {
        let idx = segment.speakerIndex
        if dur >= CloudDiarizationTuning.minSpeakerEnrollmentPreviewSeconds {
          unknownPreviewCandidates[idx, default: []].append(segment)
          AppLogger.log(
            .speakerEnrollment,
            "[CloudDiarization] preview candidate accepted speaker=\(idx) seconds=\(String(format: "%.2f", Double(dur))) fallback=\(dur < SpeakerIdentityConfig.minSpeechSecondsForEmbedding)"
          )
        } else {
          AppLogger.log(
            .speakerEnrollment,
            "[CloudDiarization] preview candidate skipped speaker=\(idx) reason=tooShort seconds=\(String(format: "%.2f", Double(dur))) minSeconds=\(String(format: "%.1f", Double(CloudDiarizationTuning.minSpeakerEnrollmentPreviewSeconds)))"
          )
        }
        if unknownSpeakers[idx] == nil {
          unknownSpeakers[idx] = UnknownDiarizationSpeaker(
            id: "Speaker \(idx)",
            speakerIndex: idx,
            clipS3Key: result.speakerClipKeys["\(idx)"],
            segmentCount: 1,
            totalSeconds: dur,
            conversationSessionId: sessionId
          )
        } else {
          let existing = unknownSpeakers[idx]!
          unknownSpeakers[idx] = UnknownDiarizationSpeaker(
            id: existing.id,
            speakerIndex: idx,
            clipS3Key: existing.clipS3Key,
            segmentCount: existing.segmentCount + 1,
            totalSeconds: existing.totalSeconds + dur,
            conversationSessionId: sessionId
          )
        }
      }
    }

    AppLogger.log(.speakerEnrollment, "[CloudDiarization] Saved \(savedChunkCount) transcript chunks, \(unknownSpeakers.count) unknown speakers")
    AppLogger.log(
      .speakerEnrollment,
      "[CloudDiarization] result clusters=\(result.speakerCount) segments=\(result.segments.count) savedChunks=\(savedChunkCount) unknownSpeakers=\(unknownSpeakers.count) attributedPeople=\(attributedPersonIds.count)"
    )
    await identityPipeline.reconcileSceneContextsForConversation(sessionId: sessionId)
    var unknownList = unknownSpeakers.values.sorted { $0.speakerIndex < $1.speakerIndex }

    // Pre-fetch speaker clip data for enrollment UI
    for speaker in unknownList {
      let workerClipData: Data?
      if let clipS3Key = speaker.clipS3Key {
        do {
          let downloaded = try await cloudDiarizationService.downloadSpeakerClip(s3Key: clipS3Key)
          workerClipData = Self.makeNormalizedSpeakerPreviewClip(
            fromWAVData: downloaded,
            speakerIndex: speaker.speakerIndex,
            source: "s3"
          )
          if workerClipData == nil {
            AppLogger.log(
              .speakerEnrollment,
              "[CloudDiarization] worker preview clip unusable speaker=\(speaker.speakerIndex) key=\(clipS3Key) bytes=\(downloaded.count)"
            )
          }
        } catch {
          workerClipData = nil
          AppLogger.log(
            .speakerEnrollment,
            "[CloudDiarization] worker preview download failed speaker=\(speaker.speakerIndex) key=\(clipS3Key) error=\(error.localizedDescription)"
          )
        }
      } else {
        workerClipData = nil
      }

      let fallbackSegment = Self.preferredUnknownSpeakerPreviewSegment(unknownPreviewCandidates[speaker.speakerIndex] ?? [])
      let clusterSegments = result.segments.filter { $0.speakerIndex == speaker.speakerIndex }
      let mergedClipData = Self.makeMergedSpeakerPreviewClip(
        audioURL: audioURL,
        segments: clusterSegments,
        speakerIndex: speaker.speakerIndex
      )
      let workerClipIsEnrollable = workerClipData.map(Self.isEnrollableSpeakerClip) ?? false
      let selectedClipData = workerClipIsEnrollable ? workerClipData : mergedClipData

      if let data = selectedClipData, Self.isEnrollableSpeakerClip(data) {
        if let idx = unknownList.firstIndex(where: { $0.speakerIndex == speaker.speakerIndex }) {
          unknownList[idx].clipData = data
        }
        AppLogger.log(
          .speakerEnrollment,
          "[CloudDiarization] enrollment clip ready speaker=\(speaker.speakerIndex) source=\(workerClipIsEnrollable ? "workerClip" : "mergedLocalSegments") bytes=\(data.count) seconds=\(String(format: "%.2f", Self.speakerClipDurationSeconds(data) ?? 0)) sourceSegments=\(clusterSegments.count)"
        )
      } else {
        let workerSeconds = workerClipData.flatMap(Self.speakerClipDurationSeconds) ?? 0
        let mergedSeconds = mergedClipData.flatMap(Self.speakerClipDurationSeconds) ?? 0
        AppLogger.log(
          .speakerEnrollment,
          "[CloudDiarization] enrollment prompt suppressed speaker=\(speaker.speakerIndex) reason=clipTooShort workerSeconds=\(String(format: "%.2f", workerSeconds)) mergedSeconds=\(String(format: "%.2f", mergedSeconds)) requiredSeconds=\(String(format: "%.1f", SpeakerIdentityConfig.minSpeechSecondsForEmbedding))"
        )
        AppLogger.log(
          .speakerEnrollment,
          "[CloudDiarization] enrollment clip unavailable speaker=\(speaker.speakerIndex) reason=insufficientMergedSpeech candidates=\(clusterSegments.count) fallbackSegmentSeconds=\(fallbackSegment.map { String(format: "%.2f", Double($0.end - $0.start)) } ?? "n/a")"
        )
      }
    }

    return CloudDiarizationProcessingOutput(
      savedChunkCount: savedChunkCount,
      unknownSpeakers: unknownList,
      attributedPersonIds: attributedPersonIds
    )
  }

  nonisolated private static func speakerAttributedTranscriptSegments(
    diarizationResult result: DiarizenResult,
    localTranscriptSegments: [LocalPostSessionTranscriptSegment],
    streamStart: Date
  ) -> [DiarizenSegment] {
    if cloudTranscriptIsAuthoritative(result) {
      let cloudSegments = result.segments.filter {
        $0.end > $0.start
          && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
      if !cloudSegments.isEmpty {
        return cloudSegments
      }
      AppLogger.log(
        .speakerEnrollment,
        "[CloudDiarization] verified Sortformer+Canary result contained no usable text; falling back to local Parakeet alignment jobId=\(result.jobId)"
      )
    }

    let localParakeetSegments = localTranscriptSegments
      .filter { $0.provider == .localParakeet }
      .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .sorted { $0.startedAt < $1.startedAt }

    guard !localParakeetSegments.isEmpty else {
      return result.segments
    }

    let diarizedSpeakers = result.segments
      .filter { $0.end > $0.start }
      .sorted { $0.start < $1.start }

    guard !diarizedSpeakers.isEmpty else {
      AppLogger.log(
        .speakerEnrollment,
        "[CloudDiarization] local Parakeet transcript available but Sortformer returned no speaker intervals; preserving transcripts as unattributed count=\(localParakeetSegments.count)"
      )
      return localParakeetSegments.map { transcript in
        let start = max(0, transcript.startedAt.timeIntervalSince(streamStart))
        return DiarizenSegment(
          start: start,
          end: max(start + 0.10, transcript.endedAt.timeIntervalSince(streamStart)),
          speakerIndex: -1,
          text: transcript.text
        )
      }
    }

    var output: [DiarizenSegment] = []
    var preservedUnattributed = 0
    for transcript in localParakeetSegments {
      let start = max(0, transcript.startedAt.timeIntervalSince(streamStart))
      let rawEnd = transcript.endedAt.timeIntervalSince(streamStart)
      let end = max(start + 0.10, rawEnd)
      let alignment = diarizationSpeakerAlignment(
        forStart: start,
        end: end,
        diarizationSegments: diarizedSpeakers
      )
      if alignment.speakerIndex == nil {
        preservedUnattributed += 1
        AppLogger.log(
          .speakerEnrollment,
          "[CloudDiarization] preserved local Parakeet transcript without Sortformer assignment id=\(transcript.id.uuidString.prefix(8)) start=\(String(format: "%.2f", start)) end=\(String(format: "%.2f", end)) reason=\(alignment.reason) nearestGap=\(alignment.gapSeconds.map { String(format: "%.2f", $0) } ?? "none")"
        )
      }
      output.append(
        speakerAttributedTranscriptSegment(
          text: transcript.text,
          start: start,
          end: end,
          diarizationSegments: diarizedSpeakers
        )
      )
    }

    if preservedUnattributed > 0 {
      AppLogger.log(
        .speakerEnrollment,
        "[CloudDiarization] local Parakeet alignment completed preservedUnattributed=\(preservedUnattributed) attributed=\(output.count - preservedUnattributed) total=\(output.count)"
      )
    }
    return output
  }

  nonisolated static func cloudTranscriptIsAuthoritative(_ result: DiarizenResult) -> Bool {
    let diarizationModel = result.diarizationModel?.lowercased() ?? ""
    let transcriptionModel = result.transcriptionModel?.lowercased() ?? ""
    return result.transcriptionSource == "awsCanaryQwen"
      && diarizationModel.contains("sortformer")
      && transcriptionModel.contains("canary-qwen")
  }

  nonisolated static func speakerAttributedTranscriptSegment(
    text: String,
    start: Double,
    end: Double,
    diarizationSegments: [DiarizenSegment]
  ) -> DiarizenSegment {
    let alignment = diarizationSpeakerAlignment(
      forStart: start,
      end: end,
      diarizationSegments: diarizationSegments
    )
    return DiarizenSegment(
      start: start,
      end: end,
      speakerIndex: alignment.speakerIndex ?? -1,
      text: text
    )
  }

  nonisolated static func diarizationSpeakerAlignment(
    forStart start: Double,
    end: Double,
    diarizationSegments: [DiarizenSegment]
  ) -> DiarizationSpeakerAlignment {
    let minUsefulOverlap = 0.05
    let candidates = diarizationSegments
      .map { segment -> (speakerIndex: Int, overlap: Double, distance: Double, duration: Double) in
        let overlap = max(0, min(end, segment.end) - max(start, segment.start))
        let transcriptMid = (start + end) / 2
        let segmentMid = (segment.start + segment.end) / 2
        return (
          speakerIndex: segment.speakerIndex,
          overlap: overlap,
          distance: abs(transcriptMid - segmentMid),
          duration: max(0, segment.end - segment.start)
        )
      }
    let best = candidates
      .filter { $0.overlap >= minUsefulOverlap }
      .max { lhs, rhs in
        let lhsScore = lhs.overlap + min(lhs.duration, 3.0) * 0.02 - lhs.distance * 0.01
        let rhsScore = rhs.overlap + min(rhs.duration, 3.0) * 0.02 - rhs.distance * 0.01
        return lhsScore < rhsScore
      }
    if let best {
      return DiarizationSpeakerAlignment(
        speakerIndex: best.speakerIndex,
        reason: "overlap",
        overlapSeconds: best.overlap,
        gapSeconds: 0
      )
    }

    let nearest = diarizationSegments
      .map { segment -> (speakerIndex: Int, gap: Double) in
        let gap = end < segment.start
          ? segment.start - end
          : (start > segment.end ? start - segment.end : 0)
        return (segment.speakerIndex, gap)
      }
      .min { $0.gap < $1.gap }
    if let nearest, nearest.gap <= CloudDiarizationTuning.maxNearbySpeakerAlignmentGapSeconds {
      return DiarizationSpeakerAlignment(
        speakerIndex: nearest.speakerIndex,
        reason: "nearbySpeechWindow",
        overlapSeconds: 0,
        gapSeconds: nearest.gap
      )
    }
    return DiarizationSpeakerAlignment(
      speakerIndex: nil,
      reason: diarizationSegments.isEmpty ? "noSpeechWindows" : "outsideSpeechWindows",
      overlapSeconds: 0,
      gapSeconds: nearest?.gap
    )
  }

  nonisolated static func preferredUnknownSpeakerPreviewSegment(_ segments: [DiarizenSegment]) -> DiarizenSegment? {
    let usable = segments.filter {
      max(0, $0.end - $0.start) >= CloudDiarizationTuning.minSpeakerEnrollmentPreviewSeconds
    }
    guard !usable.isEmpty else { return nil }
    let embeddingLength = usable.filter {
      max(0, $0.end - $0.start) >= SpeakerIdentityConfig.minSpeechSecondsForEmbedding
    }
    let candidates = embeddingLength.isEmpty ? usable : embeddingLength
    return candidates.max { lhs, rhs in
      (lhs.end - lhs.start) < (rhs.end - rhs.start)
    }
  }

  nonisolated private static func makeSingleSpeakerPreviewClip(audioURL: URL, segment: DiarizenSegment) -> Data? {
    do {
      let source = try AVAudioFile(forReading: audioURL)
      let format = source.processingFormat
      let sampleRate = format.sampleRate
      guard sampleRate > 0, format.channelCount == 1 else {
        AppLogger.log(.speakerEnrollment, "[CloudDiarization] preview clip rejected unsupported format=\(format)")
        return nil
      }

      let maxSeconds = SpeakerIdentityConfig.maxSpeechBufferSeconds
      let segmentDuration = max(0, segment.end - segment.start)
      guard segmentDuration >= CloudDiarizationTuning.minSpeakerEnrollmentPreviewSeconds else { return nil }
      let clipDuration = min(maxSeconds, segmentDuration)
      let clipStart = segment.start + max(0, (segmentDuration - clipDuration) / 2)
      let startFrame = max(0, AVAudioFramePosition((clipStart * sampleRate).rounded(.down)))
      let frameCount = min(
        AVAudioFrameCount((clipDuration * sampleRate).rounded(.down)),
        AVAudioFrameCount(max(0, source.length - startFrame))
      )
      guard frameCount > 0 else { return nil }

      source.framePosition = startFrame
      guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
      try source.read(into: buffer, frameCount: frameCount)
      guard buffer.frameLength > 0 else { return nil }

      let boosted = try Self.normalizedMonoInt16Buffer(from: buffer)
      let stats = Self.int16Stats(boosted)
      guard stats.rms >= 300, stats.peak >= 1200 else {
        AppLogger.log(
          .speakerEnrollment,
          "[CloudDiarization] preview clip rejected as too quiet speaker=\(segment.speakerIndex) rms=\(String(format: "%.0f", Double(stats.rms))) peak=\(stats.peak)"
        )
        return nil
      }

      let data = try MonoPCM16WAVData.make(samples: boosted, sampleRate: sampleRate)
      AppLogger.log(
        .speakerEnrollment,
        "[CloudDiarization] prepared single-speaker preview speaker=\(segment.speakerIndex) seconds=\(String(format: "%.2f", Double(boosted.count) / sampleRate)) rms=\(String(format: "%.0f", Double(stats.rms))) peak=\(stats.peak)"
      )
      return data
    } catch {
      AppLogger.log(.speakerEnrollment, "[CloudDiarization] preview clip creation failed speaker=\(segment.speakerIndex): \(error.localizedDescription)")
      return nil
    }
  }

  nonisolated static func mergedSpeakerPreviewSegments(
    _ segments: [DiarizenSegment],
    speakerIndex: Int,
    maximumSeconds: Double = SpeakerIdentityConfig.maxSpeechBufferSeconds
  ) -> [DiarizenSegment] {
    var selected: [DiarizenSegment] = []
    var remaining = maximumSeconds
    for segment in segments
      .filter({ $0.speakerIndex == speakerIndex && $0.end > $0.start })
      .sorted(by: { $0.start < $1.start }) {
      guard remaining > 0 else { break }
      let nonOverlappingStart = max(segment.start, selected.last?.end ?? segment.start)
      let duration = min(segment.end - nonOverlappingStart, remaining)
      guard duration > 0 else { continue }
      selected.append(
        DiarizenSegment(
          start: nonOverlappingStart,
          end: nonOverlappingStart + duration,
          speakerIndex: speakerIndex,
          text: segment.text
        )
      )
      remaining -= duration
    }
    return selected
  }

  nonisolated private static func makeMergedSpeakerPreviewClip(
    audioURL: URL,
    segments: [DiarizenSegment],
    speakerIndex: Int
  ) -> Data? {
    do {
      let source = try AVAudioFile(forReading: audioURL)
      let format = source.processingFormat
      let sampleRate = format.sampleRate
      guard sampleRate > 0, format.channelCount == 1 else { return nil }

      let selected = mergedSpeakerPreviewSegments(segments, speakerIndex: speakerIndex)
      let selectedSeconds = selected.reduce(0) { $0 + max(0, $1.end - $1.start) }
      guard selectedSeconds >= SpeakerIdentityConfig.minSpeechSecondsForEmbedding else {
        return nil
      }

      var samples: [Int16] = []
      for segment in selected {
        let startFrame = max(0, AVAudioFramePosition((segment.start * sampleRate).rounded(.down)))
        let requestedFrames = AVAudioFrameCount(((segment.end - segment.start) * sampleRate).rounded(.down))
        let frameCount = min(requestedFrames, AVAudioFrameCount(max(0, source.length - startFrame)))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
          continue
        }
        source.framePosition = startFrame
        try source.read(into: buffer, frameCount: frameCount)
        samples.append(contentsOf: try rawMonoInt16Buffer(from: buffer))
      }
      guard samples.count >= SpeakerIdentityConfig.embeddingWindowSamples else { return nil }
      let boosted = normalizedInt16Samples(samples)
      let stats = int16Stats(boosted)
      guard stats.rms >= 300, stats.peak >= 1200 else { return nil }
      AppLogger.log(
        .speakerEnrollment,
        "[CloudDiarization] prepared merged speaker enrollment clip speaker=\(speakerIndex) sourceSegments=\(selected.count) seconds=\(String(format: "%.2f", Double(boosted.count) / sampleRate)) rms=\(String(format: "%.0f", Double(stats.rms))) peak=\(stats.peak)"
      )
      return try MonoPCM16WAVData.make(samples: boosted, sampleRate: sampleRate)
    } catch {
      AppLogger.log(
        .speakerEnrollment,
        "[CloudDiarization] merged speaker enrollment clip failed speaker=\(speakerIndex) error=\(error.localizedDescription)"
      )
      return nil
    }
  }

  nonisolated private static func makeNormalizedSpeakerPreviewClip(
    fromWAVData data: Data,
    speakerIndex: Int,
    source: String
  ) -> Data? {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("diarizen-speaker-preview-\(UUID().uuidString).wav")
    do {
      try data.write(to: url, options: .atomic)
      defer { try? FileManager.default.removeItem(at: url) }

      let sourceFile = try AVAudioFile(forReading: url)
      let format = sourceFile.processingFormat
      let sampleRate = format.sampleRate
      guard sampleRate > 0, format.channelCount == 1 else {
        AppLogger.log(.speakerEnrollment, "[CloudDiarization] \(source) preview rejected unsupported format=\(format)")
        return nil
      }
      let frameCount = AVAudioFrameCount(min(
        sourceFile.length,
        AVAudioFramePosition(SpeakerIdentityConfig.maxSpeechBufferSeconds * sampleRate)
      ))
      guard frameCount > 0,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        return nil
      }
      try sourceFile.read(into: buffer, frameCount: frameCount)
      guard buffer.frameLength > 0 else { return nil }

      let boosted = try Self.normalizedMonoInt16Buffer(from: buffer)
      let stats = Self.int16Stats(boosted)
      guard stats.rms >= 300, stats.peak >= 1200 else {
        AppLogger.log(
          .speakerEnrollment,
          "[CloudDiarization] \(source) preview rejected as too quiet speaker=\(speakerIndex) rms=\(String(format: "%.0f", Double(stats.rms))) peak=\(stats.peak)"
        )
        return nil
      }
      let normalized = try MonoPCM16WAVData.make(samples: boosted, sampleRate: sampleRate)
      AppLogger.log(
        .speakerEnrollment,
        "[CloudDiarization] prepared \(source) speaker preview speaker=\(speakerIndex) seconds=\(String(format: "%.2f", Double(boosted.count) / sampleRate)) rms=\(String(format: "%.0f", Double(stats.rms))) peak=\(stats.peak)"
      )
      return normalized
    } catch {
      try? FileManager.default.removeItem(at: url)
      AppLogger.log(.speakerEnrollment, "[CloudDiarization] \(source) preview normalization failed speaker=\(speakerIndex): \(error.localizedDescription)")
      return nil
    }
  }

  nonisolated private static func normalizedMonoInt16Buffer(from buffer: AVAudioPCMBuffer) throws -> [Int16] {
    normalizedInt16Samples(try rawMonoInt16Buffer(from: buffer))
  }

  nonisolated private static func rawMonoInt16Buffer(from buffer: AVAudioPCMBuffer) throws -> [Int16] {
    let count = Int(buffer.frameLength)
    guard count > 0 else { return [] }
    var samples = [Int16](repeating: 0, count: count)
    if let source = buffer.int16ChannelData?[0] {
      for i in 0..<count { samples[i] = source[i] }
    } else if let source = buffer.floatChannelData?[0] {
      for i in 0..<count {
        let value = max(-1, min(1, source[i]))
        samples[i] = Int16(value * Float(Int16.max))
      }
    } else {
      throw NSError(domain: "CloudDiarizationPreview", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported preview buffer format"])
    }
    return samples
  }

  nonisolated private static func normalizedInt16Samples(_ input: [Int16]) -> [Int16] {
    var samples = input
    let peak = samples.reduce(Int32(0)) { current, sample in
      max(current, abs(Int32(sample)))
    }
    guard peak > 0 else { return samples }
    let targetPeak: Float = 24_000
    let gain = min(24, max(1, targetPeak / Float(peak)))
    guard gain > 1 else { return samples }
    for i in samples.indices {
      let scaled = Float(samples[i]) * gain
      samples[i] = Int16(max(Float(Int16.min), min(Float(Int16.max), scaled)))
    }
    return samples
  }

  nonisolated static func speakerClipDurationSeconds(_ data: Data) -> Double? {
    MonoPCM16WAVData.durationSeconds(data)
  }

  nonisolated static func isEnrollableSpeakerClip(_ data: Data) -> Bool {
    (MonoPCM16WAVData.sampleCount(data) ?? 0) >= SpeakerIdentityConfig.embeddingWindowSamples
  }

  nonisolated private static func int16Stats(_ samples: [Int16]) -> (rms: Float, peak: Int32) {
    guard !samples.isEmpty else { return (0, 0) }
    var sum: Double = 0
    var peak: Int32 = 0
    for sample in samples {
      let value = Int32(sample)
      peak = max(peak, abs(value))
      sum += Double(value) * Double(value)
    }
    return (Float(sqrt(sum / Double(samples.count))), peak)
  }

  // Renames all transcript chunks for an unknown speaker and optionally merges into an existing person.
  func renameUnknownSpeaker(speakerIndex: Int, sessionId: UUID, name: String, existingPersonId: UUID?) {
    Task { [weak self] in
      guard let self else { return }
      let sourceTag = "unknown:Speaker\(speakerIndex)"
      let personId: UUID?
      if let existing = existingPersonId {
        personId = existing
      } else {
        personId = await self.identityPipeline.findOrCreatePerson(name: name)
      }
      guard let resolvedPersonId = personId else {
        AppLogger.log(.database, "[CloudDiarization] renameUnknownSpeaker failed to resolve person name=\"\(name)\" speakerIndex=\(speakerIndex)")
        AppLogger.log(.speakerEnrollment, "[CloudDiarization] rename unknown speaker failed speaker=\(speakerIndex) reason=personResolveFailed")
        return
      }
      await self.identityPipeline.reattributeChunks(
        matchingSource: sourceTag,
        sessionId: sessionId,
        toPersonId: resolvedPersonId
      )
      let entries = await self.identityPipeline.loadPeopleForDictionary()
      await MainActor.run {
        self.peopleDictionaryEntries = entries
        self.unknownDiarizationSpeakers.removeAll { $0.speakerIndex == speakerIndex }
        AppLogger.log(
          .speakerEnrollment,
          "[CloudDiarization] renamed unknown speaker speaker=\(speakerIndex) personId=\(resolvedPersonId.uuidString) remainingUnknown=\(self.unknownDiarizationSpeakers.count)"
        )
        self.invalidateAndRefreshConversationSummaries(
          for: [resolvedPersonId],
          reason: "unknownSpeakerRenamed"
        )
      }
    }
  }

  // Enrolls the speaker clip as a voice embedding and renames their transcript chunks.
  func enrollUnknownSpeaker(speakerIndex: Int, sessionId: UUID, name: String, clipData: Data, existingPersonId: UUID?) {
    Task { [weak self] in
      guard let self else { return }
      let personId: UUID?
      if let existing = existingPersonId {
        personId = existing
      } else {
        personId = await self.identityPipeline.findOrCreatePerson(name: name)
      }
      guard let resolvedPersonId = personId else {
        AppLogger.log(.database, "[CloudDiarization] enrollUnknownSpeaker failed to resolve person name=\"\(name)\" speakerIndex=\(speakerIndex)")
        AppLogger.log(.speakerEnrollment, "[CloudDiarization] enrollment failed speaker=\(speakerIndex) reason=personResolveFailed")
        return
      }
      AppLogger.log(
        .speakerEnrollment,
        "[CloudDiarization] enrollment started speaker=\(speakerIndex) personId=\(resolvedPersonId.uuidString) name=\"\(name)\" clipBytes=\(clipData.count)"
      )
      let result = await self.speakerPipeline.enrollFromAudioData(
        clipData,
        personId: resolvedPersonId,
        name: name,
        preferAWS: true,
        allowLocalFallback: false
      )
      if result.pending {
        // Preview saved, but no usable voice embedding yet (AWS worker warming/
        // unavailable). The enrollment is explicitly PENDING and will finish
        // automatically once the worker is reachable. Do NOT mark as enrolled.
        await MainActor.run {
          self.voiceEnrollmentStatusText = "\(result.message)"
          self.pendingVoiceEnrollmentPersonIds.insert(resolvedPersonId)
          self.cloudSpeakerEmbeddingStatusText = "AWS canonical speaker pending; voice preview saved"
          self.workerVoiceSimilarityStatusText = "AWS canonical: speakerEmbeddingPending"
          self.schedulePendingSpeakerEmbeddingRetry(reason: "enrollmentPending")
          AppLogger.log(
            .speakerEnrollment,
            "[CloudDiarization] enrollment pending speaker=\(speakerIndex) personId=\(resolvedPersonId.uuidString) reason=\"\(result.message)\" previewBytes=\(clipData.count) — voice embedding queued for retry"
          )
        }
        // Still relabel transcripts so the name is attached; voice recognition
        // catches up when the pending embedding lands.
        self.renameUnknownSpeaker(speakerIndex: speakerIndex, sessionId: sessionId, name: name, existingPersonId: resolvedPersonId)
        return
      }
      guard result.saved else {
        await MainActor.run {
          self.voiceEnrollmentStatusText = result.message
        }
        AppLogger.log(.speakerIdentity, "[CloudDiarization] enrollUnknownSpeaker failed speakerIndex=\(speakerIndex) personId=\(resolvedPersonId.uuidString) reason=\(result.message)")
        AppLogger.log(.speakerEnrollment, "[CloudDiarization] enrollment failed speaker=\(speakerIndex) personId=\(resolvedPersonId.uuidString) reason=\"\(result.message)\"")
        return
      }
      await MainActor.run {
        self.voiceEnrollmentStatusText = result.message
        self.enrolledVoicePersonIds.insert(resolvedPersonId)
        self.pendingVoiceEnrollmentPersonIds.remove(resolvedPersonId)
        AppLogger.log(
          .speakerEnrollment,
          "[CloudDiarization] enrollment saved speaker=\(speakerIndex) personId=\(resolvedPersonId.uuidString) previewBytes=\(clipData.count)"
        )
      }
      self.renameUnknownSpeaker(speakerIndex: speakerIndex, sessionId: sessionId, name: name, existingPersonId: resolvedPersonId)
    }
  }

  private func wearerSimilarityStatusText(for match: SpeakerMatchResult) -> String {
    switch match.reason {
    case "noWearerEnrollment":
      return "Wearer: not enrolled"
    case "incompatibleWearerEnrollment":
      return "Wearer: incompatible enrollment"
    default:
      let decision = match.decision == .known ? "same voice" : "different voice"
      return "Wearer cosine: \(String(format: "%.3f", Double(match.bestSimilarity))) · \(decision)"
    }
  }

  private func processTranscriptNamePresence(text: String, timestamp: Date) {
    let people = knownPeopleForNameAddress()
    guard !people.isEmpty else {
      presencePipelineVerificationText = "Presence: no saved people available for name matching"
      return
    }

    if let signal = TranscriptNameSignalResolver.resolve(text: text, people: people) {
      presencePipelineVerificationText = "Name signal: \(signal.displayName) \(signal.intent.rawValue) \(Int((signal.confidence * 100).rounded()))% via \(signal.evidence)"
      applyTranscriptNameSignal(signal, timestamp: timestamp)
    }

    let settings = SceneContextSettings.load()
    guard sceneContextEnabled,
          (SupabaseEdgeFunctionClient.isConfigured()
            || !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
          containsKnownPersonName(in: text, people: people) else { return }
    if let lastNameAddressLLMAt,
       timestamp.timeIntervalSince(lastNameAddressLLMAt) < 4 {
      return
    }
    lastNameAddressLLMAt = timestamp

    let activePeople = presenceTracker.snapshot(now: timestamp).active
    presencePipelineVerificationText = "Name signal: asking LLM to classify known-person transcript intent"
    Task { [weak self] in
      do {
        let analysis = try await SceneContextClient(settings: settings).analyzeNameAddress(NameAddressRequest(
          transcriptText: text,
          people: people,
          activePeople: activePeople,
          timestamp: timestamp
        ))
        await MainActor.run { [weak self] in
          guard let self else { return }
          guard let signal = TranscriptNameSignalResolver.resolve(
            text: text,
            people: people,
            llmAnalysis: analysis
          ) else {
            self.presencePipelineVerificationText = "Name signal: LLM returned no actionable direct-address/departure intent"
            return
          }
          self.presencePipelineVerificationText = "Name signal: \(signal.displayName) \(signal.intent.rawValue) \(Int((signal.confidence * 100).rounded()))% via LLM"
          self.applyTranscriptNameSignal(signal, timestamp: timestamp)
        }
      } catch {
        Task { @MainActor [weak self] in
          self?.presencePipelineVerificationText = "Name signal: LLM failed, heuristic path still active"
        }
        AppLogger.log(.sceneContext, "name-address analysis skipped: \(error.localizedDescription)")
      }
    }
  }

  private func knownPeopleForNameAddress() -> [PersonNameCandidate] {
    var byId: [UUID: PersonNameCandidate] = [:]
    for entry in peopleDictionaryEntries {
      byId[entry.id] = PersonNameCandidate(personId: entry.id, displayName: entry.displayName)
    }
    if let id = activeFacePersonId, let name = activeFaceName, !name.isEmpty {
      byId[id] = PersonNameCandidate(personId: id, displayName: name)
    }
    if let id = activeSpeakerPersonId, !activeSpeakerName.isEmpty {
      byId[id] = PersonNameCandidate(personId: id, displayName: activeSpeakerName)
    }
    if let id = glassesConfirmedConversationPersonId,
       let name = glassesConfirmedConversationPersonName ?? resolvedDisplayName(for: id),
       !name.isEmpty {
      byId[id] = PersonNameCandidate(personId: id, displayName: name)
    }
    for id in glassesConfirmedConversationPersonIds {
      guard byId[id] == nil,
            let name = resolvedDisplayName(for: id),
            !name.isEmpty else { continue }
      byId[id] = PersonNameCandidate(personId: id, displayName: name)
    }
    return Array(byId.values).sorted { $0.displayName < $1.displayName }
  }

  private func containsKnownPersonName(in text: String, people: [PersonNameCandidate]) -> Bool {
    let normalized = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
    return people.contains { person in
      let name = person.displayName.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
      return !name.isEmpty && normalized.contains(name)
    }
  }

  private func applyTranscriptNameSignal(_ signal: TranscriptNameSignal, timestamp: Date) {
    if let episode = presenceTracker.record(nameSignal: signal, now: timestamp) {
      persistPresenceEpisode(episode, reason: signal.evidence, now: timestamp)
    }
    switch signal.intent {
    case .directAddress, .introduction:
      appendConversationPartnerEvidence(ConversationPartnerEvidence(
        source: .transcript,
        personId: signal.personId,
        displayName: signal.displayName,
        confidence: signal.confidence,
        timestamp: timestamp,
        validUntil: timestamp.addingTimeInterval(90),
        details: signal.evidence
      ))
      if let personId = signal.personId {
        recordSpeakerTimelineEntry(personId: personId, displayName: signal.displayName)
      }
    case .departure:
      removeConversationEvidenceForDepartedPerson(signal)
      if let personId = signal.personId {
        glassesConfirmedConversationPersonIds.remove(personId)
        if glassesConfirmedConversationPersonId == personId {
          glassesConfirmedConversationPersonId = nil
          glassesConfirmedConversationPersonName = nil
        }
      }
      if transcriptSignalMatchesRetainedRecognizedIdentity(signal) {
        clearRetainedRecognizedIdentity(reason: "transcriptDeparture-\(signal.displayName)")
      }
      recordSpeakerTimelineEntry(personId: nil, displayName: nil)
    case .reference:
      break
    }
    refreshConversationPartnerState(now: timestamp)
    let snapshot = presenceTracker.snapshot(now: timestamp)
    let active = snapshot.active.map(\.displayName).joined(separator: ", ")
    let departed = snapshot.departed.prefix(3).map(\.displayName).joined(separator: ", ")
    let activeText = active.isEmpty ? "none" : active
    let departedText = departed.isEmpty ? "none" : departed
    presencePipelineVerificationText = "Presence: \(signal.displayName) \(signal.intent.rawValue) | active=\(activeText) | departed=\(departedText)"
    refreshLiveRecallPresenceLines()
    if activeGlassesDisplayWindow == .live, !currentGlassesLiveRecallSections.isEmpty {
      phoneAssistanceDetailText = Self.liveRecallPhoneDetailText(from: currentGlassesLiveRecallSections)
      sendCombinedGlassesDisplayCard(reason: "presence-\(signal.intent.rawValue)")
    }
  }

  private func removeConversationEvidenceForDepartedPerson(_ signal: TranscriptNameSignal) {
    let normalizedName = signal.displayName.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
    conversationPartnerEvidence.removeAll { evidence in
      if let personId = signal.personId, evidence.personId == personId {
        return true
      }
      let evidenceName = evidence.displayName?.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
      return evidenceName == normalizedName
    }
  }

  private func transcriptSignalMatchesRetainedRecognizedIdentity(_ signal: TranscriptNameSignal) -> Bool {
    if let personId = signal.personId, personId == retainedRecognizedPersonId {
      return true
    }
    guard let retainedName = retainedRecognizedName else { return false }
    let normalizedRetainedName = retainedName
      .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
      .lowercased()
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedSignalName = signal.displayName
      .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
      .lowercased()
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return !normalizedRetainedName.isEmpty && normalizedRetainedName == normalizedSignalName
  }

  private func currentTranscriptAttribution() -> TranscriptAttribution {
    refreshConversationPartnerState()
    if let confirmedPersonId = glassesConfirmedConversationPersonId {
      return TranscriptAttribution(
        personId: confirmedPersonId,
        displayName: glassesConfirmedConversationPersonName ?? resolvedDisplayName(for: confirmedPersonId),
        confidence: 1.0,
        state: "glassesConfirmed",
        sourceEvidence: "glasses:userConfirmed"
      )
    }
    let partner = activeConversationPartnerState
    if let attribution = transcriptAttribution(from: partner, prefix: "fusion") {
      return attribution
    }

    let voicePersonId = activeSpeakerPersonId
    let voiceConfidence = activeSpeakerSimilarity
    let voiceState = activeSpeakerStateText
    let voiceUsable = voicePersonId != nil && voiceConfidence >= SpeakerIdentityConfig.weakMatchThreshold

    let facePersonId = activeFacePersonId
    let faceConfidence = activeFaceConfidence
    let faceUsable = facePersonId != nil
      && (activeFaceState == ActiveIdentityState.State.confirmed.rawValue || activeFaceState == ActiveIdentityState.State.possible.rawValue)
      && faceConfidence >= IdentityConfig.weakMatchThreshold

    let mouthScore = latestMouthMovementScore
    let displayNamesById = Dictionary(uniqueKeysWithValues: peopleDictionaryEntries.map { ($0.id, $0.displayName) })

    if voiceUsable, let voicePersonId {
      var confidence = voiceConfidence
      var evidence = "fusion:voice=\(String(format: "%.2f", Double(voiceConfidence)))"
      if facePersonId == voicePersonId {
        confidence = min(1, (voiceConfidence * 0.65) + (faceConfidence * 0.25) + (mouthScore * 0.10))
        evidence += ";face=\(String(format: "%.2f", Double(faceConfidence)));mouth=\(String(format: "%.2f", Double(mouthScore)))"
      } else if faceUsable {
        evidence += ";faceDisagrees=\(String(format: "%.2f", Double(faceConfidence)));mouth=\(String(format: "%.2f", Double(mouthScore)))"
      }
      return TranscriptAttribution(
        personId: voicePersonId,
        displayName: activeSpeakerName.isEmpty ? displayNamesById[voicePersonId] : activeSpeakerName,
        confidence: confidence,
        state: voiceState == "confirmed" ? "fusedConfirmed" : "fusedVoice",
        sourceEvidence: evidence
      )
    }

    if faceUsable, let facePersonId, mouthScore >= 0.12 {
      let confidence = min(1, (faceConfidence * 0.70) + (mouthScore * 0.30))
      return TranscriptAttribution(
        personId: facePersonId,
        displayName: activeFaceName ?? displayNamesById[facePersonId],
        confidence: confidence,
        state: "fusedFaceMouth",
        sourceEvidence: "fusion:face=\(String(format: "%.2f", Double(faceConfidence)));mouth=\(String(format: "%.2f", Double(mouthScore)));voice=none"
      )
    }

    if faceUsable, let facePersonId {
      return TranscriptAttribution(
        personId: facePersonId,
        displayName: activeFaceName ?? displayNamesById[facePersonId],
        confidence: faceConfidence,
        state: "fusedFaceOnly",
        sourceEvidence: "fusion:face=\(String(format: "%.2f", Double(faceConfidence)));mouth=\(String(format: "%.2f", Double(mouthScore)));voice=none"
      )
    }

    let activePresence = presenceTracker.snapshot().active
    if activePresence.count == 1, let episode = activePresence.first {
      return TranscriptAttribution(
        personId: episode.personId,
        displayName: episode.displayName,
        confidence: min(episode.confidence, 0.74),
        state: "presenceActive",
        sourceEvidence: "presence:\(safeEvidenceValue(episode.evidenceSummary));last=\(String(format: "%.1f", Date().timeIntervalSince(episode.lastEvidenceAt)))s"
      )
    }

    return TranscriptAttribution(
      personId: nil,
      displayName: nil,
      confidence: 0,
      state: "unknown",
      sourceEvidence: "fusion:unknown;voice=\(String(format: "%.2f", Double(voiceConfidence)));face=\(String(format: "%.2f", Double(faceConfidence)));mouth=\(String(format: "%.2f", Double(mouthScore)))"
    )
  }

  private func currentSceneContextIdentityEvidence(attribution: TranscriptAttribution) -> SceneContextIdentityEvidence? {
    refreshConversationPartnerState()
    let presence = presenceTracker.snapshot()
    let activePresence = presence.active.map(SceneContextPersonPresence.init)
    let departedPresence = presence.departed.prefix(6).map(SceneContextPersonPresence.init)
    let partner = activeConversationPartnerState
    if let primary = partner.primary,
       partner.phase == .confirmed || partner.phase == .possible {
      return SceneContextIdentityEvidence(
        wearerName: "you",
        conversationPartnerName: primary.displayName ?? attribution.displayName,
        conversationPartnerPersonId: primary.personId ?? attribution.personId,
        conversationPartnerState: partner.phase.rawValue,
        confidence: Double(primary.score),
        sourceSummary: [partner.sourceSummary, presenceTracker.summary()].filter { !$0.isEmpty }.joined(separator: ";"),
        activePeople: activePresence,
        departedPeople: Array(departedPresence)
      )
    }
    if attribution.personId != nil || attribution.displayName != nil {
      return SceneContextIdentityEvidence(
        wearerName: "you",
        conversationPartnerName: attribution.displayName,
        conversationPartnerPersonId: attribution.personId,
        conversationPartnerState: attribution.state,
        confidence: Double(attribution.confidence),
        sourceSummary: [attribution.sourceEvidence, presenceTracker.summary()].filter { !$0.isEmpty }.joined(separator: ";"),
        activePeople: activePresence,
        departedPeople: Array(departedPresence)
      )
    }
    if let primaryPresence = presence.active.first {
      return SceneContextIdentityEvidence(
        wearerName: "you",
        conversationPartnerName: primaryPresence.displayName,
        conversationPartnerPersonId: primaryPresence.personId,
        conversationPartnerState: presence.active.count == 1 ? "presenceActive" : "presenceMultiple",
        confidence: Double(primaryPresence.confidence),
        sourceSummary: presenceTracker.summary(),
        activePeople: activePresence,
        departedPeople: Array(departedPresence)
      )
    }
    if !departedPresence.isEmpty {
      return SceneContextIdentityEvidence(
        wearerName: "you",
        conversationPartnerName: nil,
        conversationPartnerPersonId: nil,
        conversationPartnerState: "presenceDeparted",
        confidence: 0.5,
        sourceSummary: presenceTracker.summary(),
        activePeople: [],
        departedPeople: Array(departedPresence)
      )
    }
    return nil
  }

  private func transcriptAttribution(
    from state: ConversationPartnerState,
    prefix: String
  ) -> TranscriptAttribution? {
    let evidence = "\(prefix):\(safeEvidenceValue(state.sourceSummary))"
    switch state.phase {
    case .confirmed, .possible:
      guard let primary = state.primary else { return nil }
      let displayName = primary.personId == nil ? nil : primary.displayName
      return TranscriptAttribution(
        personId: primary.personId,
        displayName: displayName,
        confidence: primary.score,
        state: state.attributionState,
        sourceEvidence: evidence
      )
    case .conflicted, .multiplePeople:
      return TranscriptAttribution(
        personId: nil,
        displayName: nil,
        confidence: 0,
        state: state.attributionState,
        sourceEvidence: evidence
      )
    case .none, .unknown:
      return nil
    }
  }

  func savePendingPersonEnrollment() {
    let name = pendingEnrollmentName
    AppLogger.log(.enrollmentUI, "action=finishEnrollment tapped=true state=\(activeIdentityStateText)")
    enrollmentStatusText = "Creating profile vector..."
    Task { [weak self] in
      guard let self else { return }
      do {
        await self.ensureCloudFaceEmbeddingReadyForEnrollmentIfNeeded()
        let result = try await identityPipeline.savePendingUnknown(name: name)
        await MainActor.run {
          self.pendingEnrollmentName = ""
          self.applyIdentityResult(result)
        }
      } catch {
        await MainActor.run {
          self.showError("Failed to save person: \(error.localizedDescription)")
        }
      }
    }
  }

  func ignorePendingPersonEnrollment() {
    AppLogger.log(.enrollmentUI, "action=cancel tapped=true state=\(activeIdentityStateText)")
    enrollmentStatusText = "Enrollment cancelled."
    Task { [weak self] in
      guard let self else { return }
      let result = await identityPipeline.ignorePendingUnknown()
      await MainActor.run {
        self.pendingEnrollmentName = ""
        self.applyIdentityResult(result)
      }
    }
  }

  func armEnrollmentForNextSample() {
    let name = pendingEnrollmentName
    AppLogger.log(.enrollmentUI, "action=addAnotherSample tapped=true state=\(activeIdentityStateText)")
    enrollmentStatusText = "Waiting for another good sample."
    Task { [weak self] in
      guard let self else { return }
      let result = await identityPipeline.armEnrollmentForNextSample(name: name)
      await MainActor.run {
        self.applyIdentityResult(result)
      }
    }
  }

  func saveCurrentEnrollmentSample() {
    let name = pendingEnrollmentName
    AppLogger.log(.enrollmentUI, "action=saveSample tapped=true state=\(activeIdentityStateText)")
    enrollmentStatusText = "Saving sample..."
    Task { [weak self] in
      guard let self else { return }
      await self.ensureCloudFaceEmbeddingReadyForEnrollmentIfNeeded()
      let result = await identityPipeline.saveCurrentEnrollmentSample(name: name)
      await MainActor.run {
        self.applyIdentityResult(result)
      }
    }
  }

  func saveLastEnrollmentCandidateWithName() {
    let name = lastEnrollmentCandidateName
    Task { [weak self] in
      guard let self else { return }
      await self.ensureCloudFaceEmbeddingReadyForEnrollmentIfNeeded()
      let result = await identityPipeline.saveLastEnrollmentCandidateWithName(name)
      await MainActor.run {
        if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          self.lastEnrollmentCandidateName = ""
        }
        self.applyIdentityResult(result)
      }
    }
  }

  func saveFirstCapturedFaceGroupWithName() {
    let name = lastEnrollmentCandidateName
    Task { [weak self] in
      guard let self else { return }
      await self.ensureCloudFaceEmbeddingReadyForEnrollmentIfNeeded()
      let result = await identityPipeline.saveFirstCapturedFaceGroupAsNewPerson(name: name)
      await MainActor.run {
        if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          self.lastEnrollmentCandidateName = ""
        }
        self.applyIdentityResult(result)
      }
    }
  }

  func ignoreFirstCapturedFaceGroup() {
    Task { [weak self] in
      guard let self else { return }
      let result = await identityPipeline.ignoreFirstCapturedFaceGroup()
      await MainActor.run {
        self.applyIdentityResult(result)
      }
    }
  }

  func saveLastEnrollmentCandidateImageOnly() {
    Task { [weak self] in
      guard let self else { return }
      let result = await identityPipeline.saveLastEnrollmentCandidateImageOnly(name: nil)
      await MainActor.run {
        self.applyIdentityResult(result)
      }
    }
  }

  func discardLastEnrollmentCandidate() {
    Task { [weak self] in
      guard let self else { return }
      let result = await identityPipeline.discardLastEnrollmentCandidate()
      await MainActor.run {
        self.lastEnrollmentCandidateName = ""
        self.applyIdentityResult(result)
      }
    }
  }

  func runEmbeddingOnNextDetectedFace() {
    Task { [weak self] in
      guard let self else { return }
      let result = await identityPipeline.requestDebugEmbeddingOnNextFace()
      await MainActor.run {
        self.applyIdentityResult(result)
      }
    }
  }

  func startSamePersonCalibration() {
    AppLogger.log(.calibrationLabel, "source=userTap label=same action=tapped")
    Task { [weak self] in
      guard let self else { return }
      let result = await identityPipeline.recordCalibrationLabel(.samePerson, source: .userTap)
      await MainActor.run {
        self.applyIdentityResult(result)
      }
    }
  }

  func startDifferentPersonCalibration() {
    AppLogger.log(.calibrationLabel, "source=userTap label=different action=tapped")
    Task { [weak self] in
      guard let self else { return }
      let result = await identityPipeline.recordCalibrationLabel(.differentPerson, source: .userTap)
      await MainActor.run {
        self.applyIdentityResult(result)
      }
    }
  }

  func stopCalibration() {
    Task { [weak self] in
      guard let self else { return }
      let result = await identityPipeline.stopCalibration()
      await MainActor.run {
        self.applyIdentityResult(result)
      }
    }
  }

  func clearCalibrationSamples() {
    Task { [weak self] in
      guard let self else { return }
      let result = await identityPipeline.clearCalibrationSamples()
      await MainActor.run {
        self.applyIdentityResult(result)
      }
    }
  }

  func clearLocalIdentityData() {
    Task { [weak self] in
      guard let self else { return }
      let result = await identityPipeline.clearIdentities()
      await MainActor.run {
        self.applyIdentityResult(result)
      }
    }
  }

  func deleteSavedPersonUsingNameField() {
    let name = lastEnrollmentCandidateName
    Task { [weak self] in
      guard let self else { return }
      let result = await identityPipeline.deleteSavedPerson(named: name)
      await MainActor.run {
        self.applyIdentityResult(result)
        if result.summary.localizedCaseInsensitiveContains("deleted") {
          self.lastEnrollmentCandidateName = ""
        }
      }
    }
  }

  func clearLocalConversationData() {
    Task { [weak self] in
      guard let self else { return }
      await identityPipeline.clearConversations()
      await MainActor.run {
        self.recentConversationAttributionText = "Conversation data cleared"
      }
    }
  }

  func saveLocalWorkerSettings() {
    localWorkerEnabled = true
    LocalWorkerSettings(
      enabled: true,
      endpoint: localWorkerEndpointText,
      apiKey: localWorkerAPIKeyText
    ).save()
    localWorkerStatusText = "Local worker settings saved"
    AppLogger.log(.localWorker, "settingsSaved enabled=true endpoint=\(localWorkerEndpointText) hasApiKey=\(!localWorkerAPIKeyText.isEmpty)")
  }

  func testLocalWorkerConnection() {
    localWorkerStatusText = "Testing local worker..."
    let endpoint = localWorkerEndpointText
    let apiKey = localWorkerAPIKeyText
    Task { [weak self] in
      guard let self else { return }
      do {
        let client = try LocalWorkerClient(endpoint: endpoint, apiKey: apiKey)
        let result = try await client.testConnection()
        await MainActor.run {
          self.localWorkerStatusText = result.modelNames.isEmpty
            ? result.statusText
            : "\(result.statusText): \(result.modelNames.joined(separator: ", "))"
        }
      } catch {
        AppLogger.log(.localWorker, "connectionTest failed error=\(error.localizedDescription)")
        await MainActor.run {
          self.localWorkerStatusText = "Local worker failed: \(error.localizedDescription)"
        }
      }
    }
  }

  func openPeopleDictionary() {
    Task { [weak self] in
      guard let self else { return }
      let entries = await identityPipeline.loadPeopleForDictionary()
      await MainActor.run {
        self.peopleDictionaryEntries = entries
        self.showPeopleDictionary = true
      }
    }
  }

  nonisolated static func speakerEnrollmentSuppressionReason(for speaker: UnknownDiarizationSpeaker) -> String? {
    guard let clipData = speaker.clipData, !clipData.isEmpty else {
      return "missingPreviewClip"
    }
    guard isEnrollableSpeakerClip(clipData) else {
      return "clipTooShort"
    }
    return nil
  }

  nonisolated static func promptableUnknownSpeakers(_ speakers: [UnknownDiarizationSpeaker]) -> [UnknownDiarizationSpeaker] {
    var seenClipData: Set<Data> = []
    return speakers
      .sorted { $0.speakerIndex < $1.speakerIndex }
      .filter { speaker in
        guard speakerEnrollmentSuppressionReason(for: speaker) == nil,
              let clipData = speaker.clipData else {
          return false
        }
        return seenClipData.insert(clipData).inserted
      }
  }

  private func publishUnknownSpeakerEnrollmentPromptsIfNeeded(
    speakers: [UnknownDiarizationSpeaker],
    savedChunkCount: Int
  ) {
    let promptableSpeakers = Self.promptableUnknownSpeakers(speakers)
    AppLogger.log(
      .speakerEnrollment,
      "[CloudDiarization] prompt scan chunks=\(savedChunkCount) unknownSpeakers=\(speakers.count) promptable=\(promptableSpeakers.count) peopleSheetOpen=\(showPeopleDictionary) summarySheetOpen=\(showStreamSummaryHistory)"
    )
    for speaker in speakers.sorted(by: { $0.speakerIndex < $1.speakerIndex }) {
      let clipBytes = speaker.clipData?.count ?? 0
      let reason = Self.speakerEnrollmentSuppressionReason(for: speaker) ?? "eligible"
      AppLogger.log(
        .speakerEnrollment,
        "[CloudDiarization] unknown speaker id=\(speaker.id) cluster=\(speaker.speakerIndex) segments=\(speaker.segmentCount) seconds=\(String(format: "%.1f", Double(speaker.totalSeconds))) clipKey=\(speaker.clipS3Key ?? "local") clipBytes=\(clipBytes) prompt=\(reason == "eligible") reason=\(reason)"
      )
    }
    guard !promptableSpeakers.isEmpty else { return }
    guard !showPeopleDictionary else { return }
    guard !showStreamSummaryHistory else {
      AppLogger.log(
        .speakerEnrollment,
        "[CloudDiarization] enrollment prompt delayed reason=streamSummarySheetOpen promptable=\(promptableSpeakers.count)"
      )
      return
    }
    showPeopleDictionary = true
    AppLogger.log(
      .speakerEnrollment,
      "[CloudDiarization] opened people dictionary for unknown speaker enrollment prompt count=\(promptableSpeakers.count)"
    )
  }

  func openStreamSummaryHistory() {
    streamSummaryHistory = StreamSummaryHistoryStore.load()
    showStreamSummaryHistory = true
  }

  func deletePerson(id: UUID) {
    Task { [weak self] in
      guard let self else { return }
      await identityPipeline.deletePerson(id: id)
      await speakerPipeline.resetEnrollment(for: id)
      let entries = await identityPipeline.loadPeopleForDictionary()
      await MainActor.run {
        self.peopleDictionaryEntries = entries
        self.enrolledVoicePersonIds = self.enrolledVoicePersonIds.filter { $0 != id }
        if self.activeSpeakerPersonId == id {
          self.activeSpeakerPersonId = nil
          self.activeSpeakerName = ""
          self.activeSpeakerStateText = "none"
        }
        if self.activeFacePersonId == id {
          self.activeFacePersonId = nil
          self.activeFaceName = nil
          self.activeFaceState = "none"
          self.activeFaceConfidence = 0
          self.activeIdentityName = "None"
          self.activeIdentityConfidenceText = "0.00"
          self.activeIdentityStateText = "none"
        }
        if self.retainedRecognizedPersonId == id {
          self.clearRetainedRecognizedIdentity(reason: "deletePerson")
        }
      }
    }
  }

  func deleteFaceEnrollmentOnly(for personId: UUID) {
    Task { [weak self] in
      guard let self else { return }
      await identityPipeline.deleteFaceEnrollment(personId: personId)
      let entries = await identityPipeline.loadPeopleForDictionary()
      await MainActor.run {
        self.peopleDictionaryEntries = entries
        if self.activeFacePersonId == personId {
          self.activeFacePersonId = nil
          self.activeFaceName = nil
          self.activeFaceState = "none"
          self.activeFaceConfidence = 0
          self.activeIdentityName = "None"
          self.activeIdentityConfidenceText = "0.00"
          self.activeIdentityStateText = "none"
        }
        if self.retainedRecognizedPersonId == personId {
          self.clearRetainedRecognizedIdentity(reason: "deleteFaceEnrollment")
        }
      }
    }
  }

  func deleteVoiceEnrollmentOnly(for personId: UUID) {
    Task { [weak self] in
      guard let self else { return }
      await speakerPipeline.resetEnrollment(for: personId)
      let clips = await speakerPipeline.capturedVoiceClipSnapshots()
      await MainActor.run {
        self.enrolledVoicePersonIds.remove(personId)
        self.capturedVoiceClips = clips
        if self.activeSpeakerPersonId == personId {
          self.activeSpeakerPersonId = nil
          self.activeSpeakerName = ""
          self.activeSpeakerStateText = "none"
          self.activeSpeakerSimilarity = 0
        }
      }
    }
  }

  func playVoicePreview(for personId: UUID) {
    let pipeline = speakerPipeline
    Task { [weak self] in
      let samples = await pipeline.voicePreviewSamples(for: personId)
      await MainActor.run { [weak self] in
        guard let self else { return }
        let seconds = Double(samples.count) / SpeakerIdentityConfig.targetSampleRate
        AppLogger.log(.audio, "Voice preview requested source=enrollment personId=\(personId.uuidString) samples=\(samples.count) seconds=\(String(format: "%.2f", Double(seconds)))")
        guard !self.isVoicePreviewBlockedByDATStream() else {
          self.voiceEnrollmentStatusText = "Voice preview is disabled while DAT streaming."
          return
        }
        guard !samples.isEmpty else {
          self.voiceEnrollmentStatusText = "No saved voice preview for this person."
          return
        }
        self.isPlayingVoicePreview = true
        self.voicePreviewPlayer.play(samples: samples) { [weak self] in
          self?.isPlayingVoicePreview = false
        }
      }
    }
  }

  func playCapturedVoiceClipPreview(id: UUID) {
    let pipeline = speakerPipeline
    Task { [weak self] in
      let samples = await pipeline.voicePreviewSamplesForCapturedClip(id: id)
      await MainActor.run { [weak self] in
        guard let self else { return }
        let seconds = Double(samples.count) / SpeakerIdentityConfig.targetSampleRate
        AppLogger.log(.audio, "Voice preview requested source=capturedClip id=\(id.uuidString) samples=\(samples.count) seconds=\(String(format: "%.2f", Double(seconds)))")
        guard !self.isVoicePreviewBlockedByDATStream() else {
          self.voiceEnrollmentStatusText = "Voice preview is disabled while DAT streaming."
          return
        }
        guard !samples.isEmpty else {
          self.voiceEnrollmentStatusText = "No captured voice preview available."
          return
        }
        self.isPlayingVoicePreview = true
        self.voicePreviewPlayer.play(samples: samples) { [weak self] in
          self?.isPlayingVoicePreview = false
        }
      }
    }
  }

  func hasVoicePreview(for personId: UUID) async -> Bool {
    await speakerPipeline.hasVoicePreview(for: personId)
  }

  private func stopVideoProvider() {
    videoProvider?.stop()
    videoProvider = nil
    lastFrameArrival = nil
  }

  private func scheduleCloudDiarizationJob(
    audioURL: URL,
    streamStart: Date,
    localTranscriptSegments: [LocalPostSessionTranscriptSegment],
    speakerTimeline: [SpeakerTimelineEntry],
    speakerEvidenceTimeline: [TimedSpeakerEvidence],
    faceEvidenceTimeline: [TimedFaceEvidence],
    pipelineContext: PipelineContext?
  ) {
    cloudDiarizationTask?.cancel()
    cloudDiarizationState = .uploading
    let cloudDiarizationService = cloudDiarizationService
    let identityPipeline = identityPipeline
    cloudDiarizationTask = Task.detached(priority: .utility) { [weak self] in
      defer {
        try? FileManager.default.removeItem(at: audioURL)
      }

      do {
        let output = try await Self.runCloudDiarizationJob(
          audioURL: audioURL,
          streamStart: streamStart,
          localTranscriptSegments: localTranscriptSegments,
          speakerTimeline: speakerTimeline,
          speakerEvidenceTimeline: speakerEvidenceTimeline,
          faceEvidenceTimeline: faceEvidenceTimeline,
          pipelineContext: pipelineContext,
          cloudDiarizationService: cloudDiarizationService,
          identityPipeline: identityPipeline
        )
        guard !Task.isCancelled else { throw CancellationError() }
        guard let output else {
          await MainActor.run {
            self?.cloudDiarizationState = .idle
            self?.cloudDiarizationTask = nil
          }
          return
        }

        let entries = await identityPipeline.loadPeopleForDictionary()
        await MainActor.run {
          guard let self else { return }
          self.peopleDictionaryEntries = entries
          self.unknownDiarizationSpeakers = output.unknownSpeakers
          self.invalidateAndRefreshConversationSummaries(
            for: output.attributedPersonIds,
            reason: "cloudDiarizationSavedChunks"
          )
          self.cloudDiarizationState = .done
          self.cloudDiarizationTask = nil
          AppLogger.log(
            .speakerEnrollment,
            "[CloudDiarization] Published result chunks=\(output.savedChunkCount) unknownSpeakers=\(output.unknownSpeakers.count)"
          )
          self.publishUnknownSpeakerEnrollmentPromptsIfNeeded(
            speakers: output.unknownSpeakers,
            savedChunkCount: output.savedChunkCount
          )
        }
      } catch is CancellationError {
        await MainActor.run {
          self?.cloudDiarizationState = .idle
          self?.cloudDiarizationTask = nil
        }
      } catch {
        AppLogger.log(.audio, "[CloudDiarization] Job failed: \(error.localizedDescription)")
        await MainActor.run {
          self?.cloudDiarizationState = .failed(error.localizedDescription)
          self?.cloudDiarizationTask = nil
        }
      }
    }
  }

  private func resetVideoState(reason: String, logStop: Bool = true) {
    visionGeneration += 1
    let hadPendingVision = pendingVisionImage != nil
    let wasProcessingFrame = isProcessingFrame
    totalReceivedFrames = 0
    totalPreviewFrames = 0
    totalDroppedFrames = 0
    statsWindowVisionPending = 0
    faceDetectionEventsPersisted = 0
    lastFaceDetectionEventPersistedAt = nil
    currentVideoFrame = nil
    currentImageSize = .zero
    detectedFaces = []
    people = []
    hasReceivedFirstFrame = false
    isProcessingFrame = false
    pendingVisionImage = nil
    lastPreviewUpdateAt = nil
    lastVisionSubmissionAt = nil
    liveDATStreamingStartedAt = nil
    liveDATFirstFrameAt = nil
    liveDATLastFrameAt = nil
    liveDATTerminalVisionInvalidated = false
    liveAudioCaptureReadyForVision = false
    resetDebugEmbeddingMetrics()
    lastFrameTimestampText = "none"
    if logStop {
      AppLogger.log(
        .facePipelineStop,
        "reason=\(reason) canceledPendingVision=\(hadPendingVision) canceledPendingEmbedding=false wasProcessingVision=\(wasProcessingFrame)"
      )
      AppLogger.log(
        .streamLifecycle,
        "stop listenersDetached=true frameCachesCleared=true reason=\(reason)"
      )
      AppLogger.log(
        .memory,
        "previewImagePresent=\(currentVideoFrame != nil) retainedFullFrames=0 retainedCrops=\(hasLastEnrollmentCandidate ? 1 : 0) pendingVisionTasks=\(isProcessingFrame ? 1 : 0)"
      )
    }
  }

  private struct EmbeddingMetricAggregate {
    var count: UInt64 = 0
    var totalLatencyMS: Double = 0
    var lastLatencyMS: Double = 0

    var averageLatencyMS: Double {
      count > 0 ? totalLatencyMS / Double(count) : 0
    }

    mutating func record(latencyMS: Double) {
      count += 1
      totalLatencyMS += latencyMS
      lastLatencyMS = latencyMS
    }
  }

  private func resetDebugEmbeddingMetrics() {
    debugMetricSessionStartedAt = Date()
    videoAWSFaceMetrics = EmbeddingMetricAggregate()
    videoLocalFaceMetrics = EmbeddingMetricAggregate()
    audioIPhoneSpeakerMetrics = EmbeddingMetricAggregate()
    audioWorkerSpeakerMetrics = EmbeddingMetricAggregate()
    videoFaceEmbeddingMetricsText = "Video face: waiting for accepted face"
    videoFaceRecognitionMetricsText = "Recognition source: waiting"
    audioSpeakerEmbeddingMetricsText = "Audio speaker: waiting for speech"
  }

  private func updateVideoFaceDebugMetrics(with metrics: [FaceEmbeddingDebugMetric]) {
    guard !metrics.isEmpty else { return }

    for metric in metrics {
      if metric.sourceLabel == "aws-AdaFace" || metric.modelName == "AdaFace" {
        videoAWSFaceMetrics.record(latencyMS: metric.latencyMS)
      } else if metric.sourceLabel == "local-MobileFaceNet" || metric.modelName == "MobileFaceNet" {
        videoLocalFaceMetrics.record(latencyMS: metric.latencyMS)
      }
    }

    let elapsed = max(Date().timeIntervalSince(debugMetricSessionStartedAt), 0.1)
    videoFaceEmbeddingMetricsText = [
      "AWS AdaFace \(formatAggregate(videoAWSFaceMetrics, elapsedSeconds: elapsed))",
      "Local MobileFaceNet \(formatAggregate(videoLocalFaceMetrics, elapsedSeconds: elapsed))"
    ].joined(separator: " | ")

    let selected = metrics.first(where: \.selectedForRecognition) ?? metrics.first
    let selectedText = selected.map { metric in
      let compatText = "\(metric.compatibleAverageCount) avg/\(metric.compatibleSampleCount) samples"
      return "Using \(metric.sourceLabel): \(metric.decisionText) sim \(String(format: "%.3f", Double(metric.bestSimilarity))) compatible \(compatText)"
    } ?? "Recognition source: waiting"
    let otherText = metrics
      .filter { !$0.selectedForRecognition }
      .map { metric in
        "\(metric.sourceLabel) \(metric.decisionText) sim \(String(format: "%.3f", Double(metric.bestSimilarity)))"
      }
      .joined(separator: " · ")
    videoFaceRecognitionMetricsText = otherText.isEmpty ? selectedText : "\(selectedText) · \(otherText)"
  }

  private func updateAudioSpeakerDebugMetrics(with result: SpeakerProcessingResult) {
    guard result.embeddingTriggered else {
      if audioSpeakerEmbeddingMetricsText == "Audio speaker: waiting for speech" {
        audioSpeakerEmbeddingMetricsText = "Audio speaker: buffer \(String(format: "%.1f", Double(result.accumulatedSpeechSeconds)))s; embeds start at \(String(format: "%.1f", Double(SpeakerIdentityConfig.minSpeechSecondsForEmbedding)))s"
      }
      return
    }

    if let latency = result.iPhoneSimilarity?.latencyMS {
      audioIPhoneSpeakerMetrics.record(latencyMS: latency)
    }
    if let latency = result.workerSimilarity?.latencyMS {
      audioWorkerSpeakerMetrics.record(latencyMS: latency)
    }

    let elapsed = max(Date().timeIntervalSince(debugMetricSessionStartedAt), 0.1)
    let decision = result.matchResult.map {
      "\($0.decision) sim \(String(format: "%.3f", Double($0.bestSimilarity)))"
    } ?? result.vadDecision
    audioSpeakerEmbeddingMetricsText = [
      "iPhone TitaNet \(formatAggregate(audioIPhoneSpeakerMetrics, elapsedSeconds: elapsed))",
      "AWS TitaNet \(formatAggregate(audioWorkerSpeakerMetrics, elapsedSeconds: elapsed))",
      decision
    ].joined(separator: " | ")
  }

  private func formatAggregate(_ aggregate: EmbeddingMetricAggregate, elapsedSeconds: TimeInterval) -> String {
    guard aggregate.count > 0 else {
      return "0 runs"
    }
    let runsPerMinute = Double(aggregate.count) * 60 / max(elapsedSeconds, 0.1)
    return String(
      format: "%llu runs %.1f/min last %.0fms avg %.0fms",
      aggregate.count,
      runsPerMinute,
      aggregate.lastLatencyMS,
      aggregate.averageLatencyMS
    )
  }

  private func syncLifecycleFromDATState(_ stateText: String) {
    let lower = stateText.lowercased()
    if lower.contains("streaming") {
      liveDATTerminalVisionInvalidated = false
      if liveDATStreamingStartedAt == nil {
        liveDATStreamingStartedAt = Date()
        lastVisionSubmissionAt = nil
      }
      lifecycleState = .running
      streamingStatus = .streaming
    } else if lower.contains("paused") {
      liveDATStreamingStartedAt = nil
      liveDATFirstFrameAt = nil
      liveDATLastFrameAt = nil
      lifecycleState = .paused
      streamingStatus = .paused
    } else if lower.contains("starting") || lower.contains("waiting") {
      liveDATStreamingStartedAt = nil
      liveDATFirstFrameAt = nil
      liveDATLastFrameAt = nil
      lifecycleState = .waiting
      streamingStatus = .waiting
    } else if lower.contains("stopping") {
      if Self.isDATTerminalState(stateText), shouldInvalidateLiveDATVisionWorkOnTerminalState() {
        invalidateLiveDATVisionWork(reason: "datStream-\(stateText)")
      }
      liveDATStreamingStartedAt = nil
      liveDATFirstFrameAt = nil
      liveDATLastFrameAt = nil
      lifecycleState = .stopping
      streamingStatus = .waiting
    } else if lower.contains("stopped") {
      if Self.isDATTerminalState(stateText), shouldInvalidateLiveDATVisionWorkOnTerminalState() {
        invalidateLiveDATVisionWork(reason: "datStream-\(stateText)")
      }
      liveDATStreamingStartedAt = nil
      liveDATFirstFrameAt = nil
      liveDATLastFrameAt = nil
      lifecycleState = .stopped
      streamingStatus = .stopped
    }
  }

  private func showError(_ message: String) {
    errorMessage = message
    showError = true
  }

  // MARK: - Voice enrollment

  func startWearerVoiceEnrollment() {
    let pipeline = speakerPipeline
    let isAudioActive = microphoneStatusText.lowercased().contains("live")
      || microphoneStatusText.lowercased().contains("listening")
      || datStreamSessionStateText.lowercased().contains("streaming")
    Task { [weak self] in
      await pipeline.beginWearerVoiceEnrollment()
      let snapshot = await pipeline.wearerVoiceProfileSnapshot()
      await MainActor.run {
        self?.wearerVoiceProfile = snapshot
        self?.wearerVoiceStatusText = isAudioActive
          ? "Read the guided prompts aloud. The 20 s target is total recording time."
          : "My voice recording is armed. Start streaming; 20 s is total recording time."
      }
    }
  }

  func cancelWearerVoiceEnrollment() {
    let pipeline = speakerPipeline
    Task { [weak self] in
      await pipeline.cancelWearerVoiceEnrollment()
      let snapshot = await pipeline.wearerVoiceProfileSnapshot()
      await MainActor.run {
        self?.wearerVoiceProfile = snapshot
        self?.wearerVoiceStatusText = "My voice recording canceled."
      }
    }
  }

  func nextWearerVoicePrompt() {
    let pipeline = speakerPipeline
    Task { [weak self] in
      await pipeline.advanceWearerVoicePrompt()
      let snapshot = await pipeline.wearerVoiceProfileSnapshot()
      await MainActor.run {
        self?.wearerVoiceProfile = snapshot
        self?.wearerVoiceStatusText = snapshot.canSaveRecording
          ? "Guided prompts complete. Save when ready."
          : String(
            format: "Read the next prompt. %.1f / %.0f s total recorded.",
            Double(snapshot.recordingSeconds),
            Double(SpeakerIdentityConfig.wearerVoiceMinEnrollmentSeconds)
          )
      }
    }
  }

  func saveWearerVoiceEnrollment() {
    wearerVoiceStatusText = "Saving my voice profile..."
    let pipeline = speakerPipeline
    Task { [weak self] in
      let result = await pipeline.saveWearerVoiceEnrollment()
      let snapshot = await pipeline.wearerVoiceProfileSnapshot()
      let clips = await pipeline.capturedVoiceClipSnapshots()
      await MainActor.run {
        self?.wearerVoiceProfile = snapshot
        self?.capturedVoiceClips = clips
        self?.wearerVoiceStatusText = result.message
      }
    }
  }

  func resetWearerVoiceProfile() {
    let pipeline = speakerPipeline
    Task { [weak self] in
      await pipeline.resetWearerVoiceProfile()
      let snapshot = await pipeline.wearerVoiceProfileSnapshot()
      await MainActor.run {
        self?.wearerVoiceProfile = snapshot
        self?.wearerVoiceStatusText = "My voice profile reset."
      }
    }
  }

  func playWearerVoicePreview() {
    let pipeline = speakerPipeline
    Task { [weak self] in
      let samples = await pipeline.wearerVoicePreviewSamplesForPlayback()
      await MainActor.run { [weak self] in
        guard let self else { return }
        let seconds = Double(samples.count) / SpeakerIdentityConfig.targetSampleRate
        AppLogger.log(.audio, "Voice preview requested source=wearer samples=\(samples.count) seconds=\(String(format: "%.2f", Double(seconds)))")
        guard !self.isVoicePreviewBlockedByDATStream() else {
          self.wearerVoiceStatusText = "My voice preview is disabled while DAT streaming."
          return
        }
        guard !samples.isEmpty else {
          self.wearerVoiceStatusText = "No my voice preview available yet."
          return
        }
        self.isPlayingVoicePreview = true
        self.voicePreviewPlayer.play(samples: samples) { [weak self] in
          self?.isPlayingVoicePreview = false
        }
      }
    }
  }

  func playVoicePreview() {
    let pipeline = speakerPipeline
    Task { [weak self] in
      let samples = await pipeline.currentSpeechBufferForPlayback()
      await MainActor.run { [weak self] in
        guard let self else { return }
        let seconds = Double(samples.count) / SpeakerIdentityConfig.targetSampleRate
        AppLogger.log(.audio, "Voice preview requested source=current samples=\(samples.count) seconds=\(String(format: "%.2f", Double(seconds)))")
        guard !self.isVoicePreviewBlockedByDATStream() else {
          self.voiceEnrollmentStatusText = "Voice preview is disabled while DAT streaming."
          return
        }
        guard !samples.isEmpty else {
          self.voiceEnrollmentStatusText = "No voice preview available yet."
          return
        }
        guard seconds >= SpeakerIdentityConfig.minSpeechSecondsForEmbedding else {
          self.voiceEnrollmentStatusText = String(format: "Keep speaking until %.1f s before previewing.", Double(SpeakerIdentityConfig.minSpeechSecondsForEmbedding))
          return
        }
        self.isPlayingVoicePreview = true
        self.voicePreviewPlayer.play(samples: samples) { [weak self] in
          self?.isPlayingVoicePreview = false
        }
      }
    }
  }

  func stopVoicePreview() {
    voicePreviewPlayer.stop()
    isPlayingVoicePreview = false
  }

  func enrollCurrentVoice() {
    let name = voiceEnrollmentName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      voiceEnrollmentStatusText = "Enter a name before enrolling."
      return
    }
    let personId = UUID()
    voiceEnrollmentStatusText = "Enrolling voice for \(name)..."
    let pipeline = speakerPipeline
    Task { [weak self] in
      await pipeline.enroll(name: name, personId: personId)
      await MainActor.run { [weak self] in
        guard let self else { return }
        self.voiceEnrollmentStatusText = "Enrolled voice: \(name)"
        self.voiceEnrollmentName = ""
      }
      await self?.refreshEnrolledVoicePersonIds()
    }
  }

  func lookupPersonByName(_ name: String) async -> PersonDictionaryEntry? {
    let entries = await identityPipeline.loadPeopleForDictionary()
    let normalized = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    return entries.first { $0.displayName.lowercased() == normalized }
  }

  func enrollVoiceForPerson(_ personId: UUID, name: String) {
    voiceEnrollmentStatusText = "Enrolling voice for \(name)..."
    let pipeline = speakerPipeline
    Task { [weak self] in
      await pipeline.enroll(name: name, personId: personId)
      await MainActor.run { [weak self] in
        guard let self else { return }
        self.voiceEnrollmentStatusText = "Enrolled voice: \(name)"
      }
      await self?.refreshEnrolledVoicePersonIds()
    }
  }

  func saveFirstCapturedVoiceClipWithName() {
    let name = capturedVoiceClipName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      voiceEnrollmentStatusText = "Enter a person name before saving voice."
      return
    }
    voiceEnrollmentStatusText = "Saving voice clip for \(name)..."
    let pipeline = speakerPipeline
    Task { [weak self] in
      guard let self else { return }
      let clipBeingSaved = await MainActor.run { self.capturedVoiceClips.first }
      let entry = await lookupPersonByName(name)
      let personId: UUID
      let displayName: String
      if let entry {
        personId = entry.id
        displayName = entry.displayName
      } else if let profile = await identityPipeline.findOrCreateVoiceOnlyPerson(named: name) {
        personId = profile.id
        displayName = profile.displayName
      } else {
        await MainActor.run {
          self.voiceEnrollmentStatusText = "Could not create \(name) in the dictionary."
        }
        return
      }
      let result = await pipeline.saveFirstCapturedVoiceClip(personId: personId, name: displayName)
      var snapshot = await identityPipeline.currentRunSessionSnapshot()
      if result.saved,
         let speakerLabel = clipBeingSaved?.speakerLabel,
         let sessionId = await MainActor.run(body: { self.lastConversationSessionIdForSpeakerReview }) {
        snapshot = await identityPipeline.labelSpeakerInConversation(
          sessionId: sessionId,
          speakerLabel: speakerLabel,
          personId: personId,
          displayName: displayName
        )
      }
      let clips = await pipeline.capturedVoiceClipSnapshots()
      let people = await identityPipeline.loadPeopleForDictionary()
      await MainActor.run {
        self.capturedVoiceClips = clips
        self.peopleDictionaryEntries = people
        self.applyRunSessionSnapshot(snapshot)
        if result.saved {
          self.capturedVoiceClipName = ""
        }
        self.voiceEnrollmentStatusText = result.message
      }
      await refreshEnrolledVoicePersonIds()
    }
  }

  func ignoreFirstCapturedVoiceClip() {
    let pipeline = speakerPipeline
    Task { [weak self] in
      await pipeline.ignoreFirstCapturedVoiceClip()
      let clips = await pipeline.capturedVoiceClipSnapshots()
      await MainActor.run { [weak self] in
        self?.capturedVoiceClips = clips
        self?.voiceEnrollmentStatusText = "Ignored captured voice clip"
      }
    }
  }

  func resetVoiceEnrollment(for personId: UUID) {
    let pipeline = speakerPipeline
    Task { [weak self] in
      await pipeline.resetEnrollment(for: personId)
      await self?.refreshEnrolledVoicePersonIds()
    }
    voiceEnrollmentStatusText = "Voice enrollment reset."
  }

  @MainActor
  private func refreshEnrolledVoicePersonIds() async {
    let pipeline = speakerPipeline
    let ids = await pipeline.enrolledPersonIds()
    let pending = await pipeline.pendingDiarizedEnrollmentPersonIds()
    enrolledVoicePersonIds = ids
    // Pending enrollments are those still missing a usable embedding.
    pendingVoiceEnrollmentPersonIds = Set(pending).subtracting(ids)
  }

  @MainActor
  private func refreshWearerVoiceProfile() async {
    let pipeline = speakerPipeline
    wearerVoiceProfile = await pipeline.wearerVoiceProfileSnapshot()
    wearerVoiceStatusText = wearerVoiceProfile.isEnrolled ? "My voice profile ready." : "My voice not enrolled"
  }
}

enum MonoPCM16WAVData {
  static func make(samples: [Int16], sampleRate: Double) throws -> Data {
    guard sampleRate.isFinite, sampleRate > 0, sampleRate <= Double(UInt32.max) else {
      throw NSError(domain: "MonoPCM16WAVData", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid WAV sample rate"])
    }
    let dataByteCount = samples.count * MemoryLayout<Int16>.size
    guard dataByteCount <= Int(UInt32.max) - 36 else {
      throw NSError(domain: "MonoPCM16WAVData", code: 2, userInfo: [NSLocalizedDescriptionKey: "WAV clip is too large"])
    }

    let sampleRateValue = UInt32(sampleRate.rounded())
    let channelCount: UInt16 = 1
    let bitsPerSample: UInt16 = 16
    let blockAlign = channelCount * bitsPerSample / 8
    let byteRate = sampleRateValue * UInt32(blockAlign)
    var data = Data()
    data.reserveCapacity(44 + dataByteCount)

    data.appendASCII("RIFF")
    data.appendLittleEndian(UInt32(36 + dataByteCount))
    data.appendASCII("WAVE")
    data.appendASCII("fmt ")
    data.appendLittleEndian(UInt32(16))
    data.appendLittleEndian(UInt16(1))
    data.appendLittleEndian(channelCount)
    data.appendLittleEndian(sampleRateValue)
    data.appendLittleEndian(byteRate)
    data.appendLittleEndian(blockAlign)
    data.appendLittleEndian(bitsPerSample)
    data.appendASCII("data")
    data.appendLittleEndian(UInt32(dataByteCount))
    for sample in samples {
      data.appendLittleEndian(UInt16(bitPattern: sample))
    }
    return data
  }

  static func sampleCount(_ data: Data) -> Int? {
    guard data.count >= 44,
          String(data: data.prefix(4), encoding: .ascii) == "RIFF",
          String(data: data.subdata(in: 8..<12), encoding: .ascii) == "WAVE" else {
      return nil
    }
    guard let channels = data.littleEndianUInt16(at: 22),
          let bitsPerSample = data.littleEndianUInt16(at: 34),
          let dataByteCount = data.littleEndianUInt32(at: 40),
          channels == 1,
          bitsPerSample == 16 else {
      return nil
    }
    return Int(dataByteCount) / MemoryLayout<Int16>.size
  }

  static func durationSeconds(_ data: Data) -> Double? {
    guard let samples = sampleCount(data),
          let sampleRate = data.littleEndianUInt32(at: 24),
          sampleRate > 0 else {
      return nil
    }
    return Double(samples) / Double(sampleRate)
  }
}

private extension Data {
  mutating func appendASCII(_ value: String) {
    append(contentsOf: value.utf8)
  }

  mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
    var littleEndian = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndian) { bytes in
      append(contentsOf: bytes)
    }
  }

  func littleEndianUInt16(at offset: Int) -> UInt16? {
    guard offset >= 0, offset + 2 <= count else { return nil }
    let firstIndex = index(startIndex, offsetBy: offset)
    let secondIndex = index(after: firstIndex)
    let low = UInt16(self[firstIndex])
    let high = UInt16(self[secondIndex]) << 8
    return low | high
  }

  func littleEndianUInt32(at offset: Int) -> UInt32? {
    guard offset >= 0, offset + 4 <= count else { return nil }
    let firstIndex = index(startIndex, offsetBy: offset)
    let secondIndex = index(after: firstIndex)
    let thirdIndex = index(after: secondIndex)
    let fourthIndex = index(after: thirdIndex)
    let byte0 = UInt32(self[firstIndex])
    let byte1 = UInt32(self[secondIndex]) << 8
    let byte2 = UInt32(self[thirdIndex]) << 16
    let byte3 = UInt32(self[fourthIndex]) << 24
    return byte0 | byte1 | byte2 | byte3
  }
}
