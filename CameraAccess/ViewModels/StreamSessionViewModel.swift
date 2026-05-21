/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AVFoundation
import Combine
import CoreMedia
import CoreVideo
import SwiftUI

enum StreamingStatus {
  case streaming
  case waiting
  case paused
  case stopped
}

@MainActor
final class StreamSessionViewModel: ObservableObject {
  // MARK: - Published State

  @Published var currentVideoFrame: UIImage?
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

  @Published var framesReceived: UInt64 = 0
  @Published var previewFrames: UInt64 = 0
  @Published var visionSubmittedFrames: UInt64 = 0
  @Published var visionProcessedFrames: UInt64 = 0
  @Published var droppedFrames: UInt64 = 0
  @Published var lastFrameIntervalText: String = "0.0 ms"
  @Published var liveFrameStatsText: String = "received=0 preview=0 vision=0/0 dropped=0 fps=0.0 avgVision=0.0 ms"
  @Published var people: [Person] = []
  @Published var analysisPaused = false
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
  @Published var phoneAssistanceTitleText = "Phone assistance"
  @Published var phoneAssistanceDetailText = "Identify a person to show conversation memory."
  @Published var phoneAssistanceStatusText = "Phone display fallback"
  @Published var phoneAssistanceDismissed = false
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
  @Published var iPhoneVoiceSimilarityStatusText = "iPhone: pending"
  @Published var workerVoiceSimilarityStatusText = "Worker PC: disabled"
  @Published var wearerVoiceSimilarityStatusText = "Wearer: not checked"
  @Published var voiceMatchStatusText = ""
  @Published var voiceSpeechBufferSeconds: Double = 0
  @Published var enrolledVoicePersonIds: Set<UUID> = []
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
  @Published var cloudFaceEmbeddingEnabled = false
  @Published var cloudFaceEmbeddingEndpointText = CloudFaceEmbeddingSettings.defaultEndpoint
  @Published var cloudFaceEmbeddingAPIKeyText = ""
  @Published var cloudFaceEmbeddingStatusText = "Cloud face embedding off"
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
  @Published var datFramesReceived: UInt64 = 0
  @Published var datFramesConvertedToUIImage: UInt64 = 0
  @Published var datFrameConversionFailures: UInt64 = 0
  @Published var datLastFrameWidthText: String = "none"
  @Published var datLastFrameHeightText: String = "none"
  @Published var datLastFrameTimestampText: String = "none"
  @Published var datLastFrameErrorText: String = "none"
  @Published var lastFrameTimestampText: String = "none"

  var isStreaming: Bool { lifecycleState.isStreamingSurfaceVisible }
  var canConnectRealGlasses: Bool {
    !datIsConnecting
      && !datWaitingForMetaAIReturn
      && datRegistrationStateText != "registering"
  }
  var connectGlassesButtonTitle: String {
    canConnectRealGlasses ? "Connect my glasses" : "Connecting..."
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
  private let liveVoiceEmbeddingEnabled = false
  private let voicePreviewPlayer = VoicePreviewPlayer()
  private let assistanceCardFormatter = AssistanceCardFormatter()
  private var conversationSummaryCache: [UUID: PersonConversationSummary] = [:]
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

  private struct TimedSpeakerEvidence {
    let timestamp: Date
    let personId: UUID
    let displayName: String?
    let confidence: Float
    let state: String
  }

  private struct TimedFaceEvidence {
    let timestamp: Date
    let personId: UUID
    let displayName: String?
    let confidence: Float
    let state: String
    let mouthMovementScore: Float
  }

  private var isProcessingFrame = false
  private var pendingVisionImage: PendingVisionImage?
  private let maxVisionFPS: TimeInterval = 5
  private let liveDATHeavyWorkStartupDelaySeconds: TimeInterval = 5
  private let liveDATVisionStartupDelaySeconds: TimeInterval = 0.5
  private let liveDATRecentFrameGraceSeconds: TimeInterval = 1.5
  private let liveDATVisionWarmupSeconds: TimeInterval = 8
  private let liveDATVisionWarmupFPS: TimeInterval = 1
  private let liveDATVisionSteadyFPS: TimeInterval = 2
  private let maxPreviewFPS: TimeInterval = 12
  private let speakerUIUpdateIntervalSeconds: TimeInterval = 0.25
  private let verboseFrameLogging = ProcessInfo.processInfo.arguments.contains("--verbose-frame-logging")
  private let forceTestFaceOverlay = ProcessInfo.processInfo.arguments.contains("--ui-testing")

  private var totalReceivedFrames: UInt64 = 0
  private var totalPreviewFrames: UInt64 = 0
  private var totalDroppedFrames: UInt64 = 0
  private var lastFrameArrival: Date?
  private var lastPreviewUpdateAt: Date?
  private var lastVisionSubmissionAt: Date?
  private var statsWindowStartedAt = Date()
  private var statsWindowReceivedFrames: UInt64 = 0
  private var statsWindowPreviewFrames: UInt64 = 0
  private var statsWindowVisionSubmittedFrames: UInt64 = 0
  private var statsWindowVisionProcessedFrames: UInt64 = 0
  private var statsWindowVisionPending: UInt64 = 0
  private var statsWindowDroppedFrames: UInt64 = 0
  private var statsWindowDroppedBusy: UInt64 = 0
  private var statsWindowSkippedThrottle: UInt64 = 0
  private var statsWindowFaceCandidates: UInt64 = 0
  private var statsWindowQualityPass: UInt64 = 0
  private var statsWindowEmbedded: UInt64 = 0
  private var statsWindowMatched: UInt64 = 0
  private var statsWindowEmbeddingDurationMS: Double = 0
  private var statsWindowVisionDurationMS: Double = 0
  private var statsWindowVisionDurationCount: UInt64 = 0
  private var visionGeneration: UInt64 = 0
  private var liveDATStreamingStartedAt: Date?
  private var liveDATFirstFrameAt: Date?
  private var liveDATLastFrameAt: Date?
  private var pipelineContext: PipelineContext?
  private var faceDetectionEventsPersisted = 0
  private var lastFaceDetectionEventPersistedAt: Date?
  private var liveStreamSessionActivated = false
  private var livePhoneAudioSessionActive = false
  private var activeFacePersonId: UUID?
  private var activeFaceName: String?
  private var activeFaceConfidence: Float = 0
  private var activeFaceState = "none"
  private var lastIdentityUIUpdateAt: Date?
  private var lastIdentityUIKey: String?
  private var latestMouthMovementScore: Float = 0
  private var speakerEvidenceTimeline: [TimedSpeakerEvidence] = []
  private var faceEvidenceTimeline: [TimedFaceEvidence] = []
  private var lastSpeakerUIUpdateAt: Date?
  // Cloud diarization
  private let audioRecorder = StreamAudioRecorder()
  private let cloudDiarizationService = CloudDiarizationService()
  private var speakerTimeline: [SpeakerTimelineEntry] = []
  private var streamAudioStart: Date?
  private var lastConversationSessionIdForSpeakerReview: UUID?
  private var liveStreamActivationTask: Task<Void, Never>?
  // Set during stopSession() to suppress the DAT-state-publisher-driven deactivate.
  // Without this, a stale "datStreamStopped" deactivate Task can fire AFTER the user
  // starts a new stream and tear down the new stream's mic mid-flight — producing a
  // zero-second WAV.
  private var explicitTeardownInFlight = false
  private var stopSessionInFlight = false

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
    deepSeekAPIKeyText = deepSeekSettings.apiKey
    deepSeekModelText = deepSeekSettings.model
    deepSeekStatusText = deepSeekSettings.apiKey.isEmpty
      ? "DeepSeek key missing"
      : "DeepSeek configured: \(deepSeekSettings.model)"
    let cloudFaceSettings = CloudFaceEmbeddingSettings.load()
    cloudFaceEmbeddingEnabled = cloudFaceSettings.enabled
    cloudFaceEmbeddingEndpointText = cloudFaceSettings.endpoint
    cloudFaceEmbeddingAPIKeyText = cloudFaceSettings.apiKey
    cloudFaceEmbeddingStatusText = cloudFaceSettings.enabled
      ? "Cloud AdaFace configured; restart stream/app to apply"
      : "Cloud face embedding off"
    Task { [weak self] in
      guard let self else { return }
      let status = await identityPipeline.embeddingModelStatusText()
      let diagnostics = await identityPipeline.embeddingModelDiagnosticsText()
      await MainActor.run {
        self.faceEmbeddingModelStatusText = status
        self.faceEmbeddingModelDiagnosticsText = diagnostics
      }
    }
    datManager.onFrameImage = { [weak self] image in
      self?.handleRealGlassesImage(image)
    }
    datManager.onFrameSampleBuffer = { [weak self] sampleBuffer, previewImage in
      self?.handleRealGlassesSampleBuffer(sampleBuffer, previewImage: previewImage)
    }
    datManager.onError = { [weak self] message in
      Task { @MainActor in
        self?.showError(message)
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
      .assign(to: &$datLastErrorText)
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
      .assign(to: &$datFramesReceived)
    datManager.$framesConvertedToUIImage
      .receive(on: DispatchQueue.main)
      .sink { [weak self] count in
        guard let self else { return }
        self.datFramesConvertedToUIImage = count
        if count > 0 {
          let now = Date()
          if self.liveDATFirstFrameAt == nil {
            self.liveDATFirstFrameAt = now
          }
          self.liveDATLastFrameAt = now
        }
        self.activateLiveStreamSessionAfterFirstFrameIfReady()
      }
      .store(in: &cancellables)
    datManager.$frameConversionFailures
      .receive(on: DispatchQueue.main)
      .assign(to: &$datFrameConversionFailures)
    datManager.$lastFrameWidthText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datLastFrameWidthText)
    datManager.$lastFrameHeightText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datLastFrameHeightText)
    datManager.$lastFrameTimestampText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datLastFrameTimestampText)
    datManager.$lastFrameErrorText
      .receive(on: DispatchQueue.main)
      .assign(to: &$datLastFrameErrorText)
    datManager.$streamSessionStateText
      .receive(on: DispatchQueue.main)
      .sink { [weak self] stateText in
        guard let self else { return }
        self.datStreamSessionStateText = stateText
        self.streamStateText = stateText
        self.syncLifecycleFromDATState(stateText)
        if stateText.lowercased().contains("streaming") {
          self.activateLiveStreamSessionAfterFirstFrameIfReady()
        } else if stateText.lowercased().contains("stopped") {
          self.liveStreamActivationTask?.cancel()
          self.liveStreamActivationTask = nil
          // If stopSession() is the one driving DAT to "stopped", it already tore
          // everything down synchronously. Scheduling another deactivate Task here
          // would run after the user's next start, killing the new stream's mic.
          guard !self.explicitTeardownInFlight else { return }
          Task { @MainActor [weak self] in
            await self?.deactivateLiveStreamSessionIfNeeded(reason: "datStreamStopped")
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
    stopSessionInFlight = true
    explicitTeardownInFlight = true
    defer {
      explicitTeardownInFlight = false
      stopSessionInFlight = false
    }
    lifecycleState = .stopping
    streamingStatus = .waiting
    streamStateText = StreamLifecycleState.stopping.rawValue
    let hadLivePhoneAudioSession = livePhoneAudioSessionActive
    liveStreamSessionActivated = false
    livePhoneAudioSessionActive = false
    liveStreamActivationTask?.cancel()
    liveStreamActivationTask = nil
    invalidateAssistanceWork(reason: "stopSession-\(reason)", stopAudio: true)
    await datManager.stopStream(reason: reason)
    speechManager.stop()
    speechManager.onAudioBuffer = nil
    if hadLivePhoneAudioSession {
      await finalizeConversationTranscriptAfterStream(reason: reason)
      // Finalize audio recording and submit cloud diarization job.
      let audioFileURL = audioRecorder.stop()
      let capturedStart = streamAudioStart
      let capturedTimeline = speakerTimeline
      let capturedFaceEvidence = faceEvidenceTimeline
      let capturedContext = pipelineContext
      if let audioURL = audioFileURL, let start = capturedStart {
        Task {
          await self.submitCloudDiarizationJob(audioURL: audioURL, streamStart: start,
                                               speakerTimeline: capturedTimeline,
                                               faceEvidenceTimeline: capturedFaceEvidence,
                                               pipelineContext: capturedContext)
        }
      } else {
        cloudDiarizationState = .idle
      }
    } else {
      cloudDiarizationState = .idle
      AppLogger.log(.stream, "Skipping phone audio/conversation teardown because live phone audio was not active reason=\(reason)")
    }
    streamAudioStart = nil
    lastConversationSessionIdForSpeakerReview = pipelineContext?.conversationSessionId
    await speakerPipeline.resetRuntimeState(reason: "stopSession-\(reason)")
    capturedVoiceClips = await speakerPipeline.capturedVoiceClipSnapshots()
    wearerVoiceProfile = await speakerPipeline.wearerVoiceProfileSnapshot()
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
    iPhoneVoiceSimilarityStatusText = "iPhone: pending"
    workerVoiceSimilarityStatusText = "Worker PC: disabled"
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
    guard datManager.canStartStream else {
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

    lifecycleState = .starting
    streamingStatus = .waiting
    streamStateText = "STARTING"
    sourceStateText = "REAL GLASSES"

    let started = await datManager.startStream()
    if started {
      lifecycleState = .waiting
      streamingStatus = .waiting
      AppLogger.log(.stream, "Real glasses stream start requested; waiting for DAT Stream state=streaming before starting app-side session work")
    } else {
      lifecycleState = .error
      streamingStatus = .stopped
      let detail = datLastErrorText == "None" ? datStartReadinessReasonText : datLastErrorText
      showError("Start streaming failed: \(detail)")
    }
  }

  private func activateLiveStreamSessionIfNeeded() async {
    guard !liveStreamSessionActivated else { return }
    guard canActivateLiveAudioSession else {
      AppLogger.log(.stream, "Skipping live audio activation because DAT stream is no longer usable. stream=\(datStreamSessionStateText), deviceSession=\(datDeviceSessionStateText), device=\(datSelectedDeviceIDText), isStreamRunning=\(datIsStreamRunning)")
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
      iPhoneVoiceSimilarityStatusText = "iPhone: live audio disabled"
      workerVoiceSimilarityStatusText = "Worker PC: disabled"
      wearerVoiceSimilarityStatusText = "Wearer: live audio disabled"
      cloudDiarizationState = .idle
      microphoneStatusText = "Live phone audio disabled"
      UIApplication.shared.isIdleTimerDisabled = true
      AppLogger.log(.stream, "DAT stream is streaming; phone audio/conversation activation skipped to keep DAT camera stream isolated")
      return
    }
    resetPostSessionAttributionState()
    lastWearerVoiceSimilarity = 0
    wearerVoiceSimilarityStatusText = "Wearer: not checked"
    workerVoiceSimilarityStatusText = "Worker PC: disabled"

    let snapshot = await identityPipeline.startConversationSession(
      deviceId: UIDevice.current.identifierForVendor?.uuidString,
      datDeviceId: datSelectedDeviceIDText == "None" ? nil : datSelectedDeviceIDText
    )
    pipelineContext = await identityPipeline.currentContext()
    applyRunSessionSnapshot(snapshot)
    guard !Task.isCancelled, canActivateLiveAudioSession else {
      AppLogger.log(.stream, "Canceling live audio activation after conversation setup because DAT stopped. stream=\(datStreamSessionStateText), deviceSession=\(datDeviceSessionStateText), device=\(datSelectedDeviceIDText), isStreamRunning=\(datIsStreamRunning)")
      await identityPipeline.endConversation()
      pipelineContext = await identityPipeline.currentContext()
      applyRunSessionSnapshot(await identityPipeline.currentRunSessionSnapshot())
      return
    }
    guard datFramesConvertedToUIImage > 0 else {
      AppLogger.log(.stream, "Canceling live audio activation because DAT has not delivered a video frame yet. stream=\(datStreamSessionStateText), datFramesConverted=\(datFramesConvertedToUIImage)")
      await identityPipeline.endConversation()
      pipelineContext = await identityPipeline.currentContext()
      applyRunSessionSnapshot(await identityPipeline.currentRunSessionSnapshot())
      return
    }

    let recorderRef = audioRecorder
    if liveVoiceEmbeddingEnabled {
      let pipeline = speakerPipeline
      speechManager.onAudioBuffer = { [weak self] buffer in
        recorderRef.append(buffer)
        Task { [weak self] in
          let result = await pipeline.process(buffer: buffer)
          let bufferSec = await pipeline.currentSpeechBufferSeconds
          let isSpeaking = await pipeline.isCurrentlySpeaking
          let voiceClips = await pipeline.capturedVoiceClipSnapshots()
          let wearerSnapshot = await pipeline.wearerVoiceProfileSnapshot()
          await MainActor.run { [weak self] in
            guard let self else { return }
            let now = Date()
            let shouldUpdateUI = self.lastSpeakerUIUpdateAt == nil
              || now.timeIntervalSince(self.lastSpeakerUIUpdateAt!) >= self.speakerUIUpdateIntervalSeconds
              || result.embeddingTriggered
              || result.activeIdentity.phase != .none
            guard shouldUpdateUI else { return }
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
                ? "iPhone: Me \(String(format: "%.3f", result.matchResult?.bestSimilarity ?? 0)) · same voice"
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
            self.voiceSpeechBufferSeconds = bufferSec
            self.capturedVoiceClips = voiceClips
            self.wearerVoiceProfile = wearerSnapshot
          }
        }
      }
    } else {
      speechManager.onAudioBuffer = { buffer in
        recorderRef.append(buffer)
      }
      activeSpeakerStateText = "disabled"
      activeSpeakerName = ""
      activeSpeakerPersonId = nil
      activeSpeakerSimilarity = 0
      voiceSpeechBufferSeconds = 0
      voiceMatchStatusText = "Live voice embedding disabled"
      iPhoneVoiceSimilarityStatusText = "iPhone: live embedding disabled"
      workerVoiceSimilarityStatusText = "Worker PC: disabled"
      wearerVoiceSimilarityStatusText = "Wearer: live embedding disabled"
      AppLogger.log(.speakerIdentity, "Live voice embedding disabled; audio buffers are recorded for post-session diarization only")
    }
    liveStreamSessionActivated = true
    livePhoneAudioSessionActive = true
    // Start cloud diarization audio recorder
    let audioStart = Date()
    streamAudioStart = audioStart
    speakerTimeline = []
    cloudDiarizationState = .recording
    do {
      try audioRecorder.start()
    } catch {
      AppLogger.log(.audio, "[StreamAudioRecorder] start() threw: \(error.localizedDescription)")
    }
    let audioStarted = await speechManager.start(audioSource: audioSource)
    guard audioStarted else {
      let droppedURL = audioRecorder.stop()
      if let droppedURL {
        try? FileManager.default.removeItem(at: droppedURL)
      }
      cloudDiarizationState = .failed("Could not start \(audioSource.displayName) audio capture")
      liveStreamSessionActivated = false
      livePhoneAudioSessionActive = false
      await identityPipeline.endConversation()
      pipelineContext = await identityPipeline.currentContext()
      applyRunSessionSnapshot(await identityPipeline.currentRunSessionSnapshot())
      return
    }
    guard !Task.isCancelled, canActivateLiveAudioSession else {
      AppLogger.log(.stream, "Stopping live audio immediately because DAT stopped during audio start. stream=\(datStreamSessionStateText), deviceSession=\(datDeviceSessionStateText), device=\(datSelectedDeviceIDText), isStreamRunning=\(datIsStreamRunning)")
      await deactivateLiveStreamSessionIfNeeded(reason: "datStoppedDuringAudioStart")
      return
    }
    UIApplication.shared.isIdleTimerDisabled = true
    AppLogger.log(.stream, "DAT stream is streaming; live audio and conversation session activated")
  }

  private var canActivateLiveAudioSession: Bool {
    isDATStreamUsableForHeavyWork && liveDATHeavyWorkDelayRemaining(at: Date()) <= 0
  }

  private var isDATStreamUsableForHeavyWork: Bool {
    guard datStreamSessionStateText.lowercased().contains("streaming"),
          datIsStreamRunning,
          datFramesConvertedToUIImage > 0,
          datSelectedDeviceIDText != "None",
          datDeviceSessionStateText.lowercased().contains("started"),
          let liveDATLastFrameAt else {
      return false
    }
    return Date().timeIntervalSince(liveDATLastFrameAt) <= liveDATRecentFrameGraceSeconds
  }

  private func liveDATHeavyWorkDelayRemaining(at now: Date) -> TimeInterval {
    guard let liveDATFirstFrameAt else { return .infinity }
    return max(0, liveDATHeavyWorkStartupDelaySeconds - now.timeIntervalSince(liveDATFirstFrameAt))
  }

  private func liveDATVisionDelayRemaining(at now: Date) -> TimeInterval {
    guard let liveDATFirstFrameAt else { return .infinity }
    return max(0, liveDATVisionStartupDelaySeconds - now.timeIntervalSince(liveDATFirstFrameAt))
  }

  private func activateLiveStreamSessionAfterFirstFrameIfReady() {
    guard liveStreamActivationTask == nil else { return }
    guard !liveStreamSessionActivated else { return }
    guard datStreamSessionStateText.lowercased().contains("streaming") else { return }
    guard datFramesConvertedToUIImage > 0 else {
      AppLogger.log(.stream, "Waiting for first DAT video frame before starting audio/conversation session")
      return
    }
    let delay = liveDATHeavyWorkDelayRemaining(at: Date())
    liveStreamActivationTask = Task { @MainActor [weak self] in
      guard let self else { return }
      if delay.isFinite, delay > 0 {
        AppLogger.log(.stream, "Delaying live audio/conversation activation for \(String(format: "%.1f", delay))s after first DAT video frame")
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

  private func deactivateLiveStreamSessionIfNeeded(reason: String) async {
    guard liveStreamSessionActivated else { return }
    let hadLivePhoneAudioSession = livePhoneAudioSessionActive
    liveStreamSessionActivated = false
    livePhoneAudioSessionActive = false
    lastSpeakerUIUpdateAt = nil
    invalidateAssistanceWork(reason: "deactivate-\(reason)", stopAudio: true)
    speechManager.stop()
    speechManager.onAudioBuffer = nil
    if hadLivePhoneAudioSession {
      await finalizeConversationTranscriptAfterStream(reason: reason)
      // Without this, the open WAV from the disconnected stream stays attached to the
      // recorder; the next stream's audioRecorder.start() hits its !isRecording guard,
      // bails, and the new stream writes into the stale file (or no file at all).
      let audioFileURL = audioRecorder.stop()
      let capturedStart = streamAudioStart
      let capturedTimeline = speakerTimeline
      let capturedFaceEvidence = faceEvidenceTimeline
      let capturedContext = pipelineContext
      if let audioURL = audioFileURL, let start = capturedStart {
        Task {
          await self.submitCloudDiarizationJob(audioURL: audioURL, streamStart: start,
                                                speakerTimeline: capturedTimeline,
                                                faceEvidenceTimeline: capturedFaceEvidence,
                                                pipelineContext: capturedContext)
        }
      } else if audioFileURL == nil {
        cloudDiarizationState = .idle
      }
    } else {
      cloudDiarizationState = .idle
      AppLogger.log(.stream, "DAT stream marker deactivated without phone audio teardown reason=\(reason)")
    }
    streamAudioStart = nil
    lastConversationSessionIdForSpeakerReview = pipelineContext?.conversationSessionId
    await speakerPipeline.resetRuntimeState(reason: reason)
    capturedVoiceClips = await speakerPipeline.capturedVoiceClipSnapshots()
    wearerVoiceProfile = await speakerPipeline.wearerVoiceProfileSnapshot()
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
          self.visionLatencyText = String(format: "%.1f ms", durationMS)
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
          self.visionLatencyText = String(format: "%.1f ms", durationMS)
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
      lastFrameIntervalText = String(format: "%.1f ms", now.timeIntervalSince(lastFrameArrival) * 1_000)
    }
    lastFrameArrival = now
    lastFrameTimestampText = String(format: "%.3f", now.timeIntervalSince1970)

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
      if !hasReceivedFirstFrame {
        hasReceivedFirstFrame = true
      }
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

  private func handleRealGlassesSampleBuffer(_ sampleBuffer: CMSampleBuffer, previewImage: UIImage?) {
    totalReceivedFrames += 1
    statsWindowReceivedFrames += 1
    let sequence = totalReceivedFrames
    let now = Date()
    if let lastFrameArrival {
      lastFrameIntervalText = String(format: "%.1f ms", now.timeIntervalSince(lastFrameArrival) * 1_000)
    }
    lastFrameArrival = now
    lastFrameTimestampText = String(format: "%.3f", now.timeIntervalSince1970)

    if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
      let width = CVPixelBufferGetWidth(pixelBuffer)
      let height = CVPixelBufferGetHeight(pixelBuffer)
      currentImageSize = CGSize(width: width, height: height)
      AppLogger.log(.visionInput, "frame=\(sequence) input=CVPixelBuffer width=\(width) height=\(height) orientation=up mirrored=false")
    } else {
      AppLogger.log(.visionInput, "frame=\(sequence) input=UIImage fallback=true reason=pixelBufferUnavailable")
    }

    var previewUpdated = false
    if let previewImage, shouldUpdatePreview(at: now) {
      totalPreviewFrames += 1
      statsWindowPreviewFrames += 1
      lastPreviewUpdateAt = now
      currentVideoFrame = previewImage
      previewUpdated = true
      if !hasReceivedFirstFrame {
        hasReceivedFirstFrame = true
      }
    }

    let enqueueResult = enqueue(sampleBuffer: sampleBuffer, sequence: sequence)
    logVisionSelection(sequence: sequence, source: "sampleBuffer", result: enqueueResult)
    if verboseFrameLogging {
      AppLogger.log(
        .frames,
        "Real DAT sampleBuffer #\(sequence) previewUpdated=\(previewUpdated), selectedForVision=\(enqueueResult.selectedForVision), visionEnqueued=\(enqueueResult.visionEnqueued), visionSkippedReason=\(enqueueResult.visionSkippedReason)"
      )
    }
    if let reason = enqueueResult.dropReason {
      noteDroppedFrame(sequence: sequence, reason: reason)
    }
    emitAggregateFrameStatsIfNeeded(force: false)
  }

  private func handleSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
    totalReceivedFrames += 1
    framesReceived = totalReceivedFrames
    let sequence = totalReceivedFrames
    let now = Date()
    if let lastFrameArrival {
      lastFrameIntervalText = String(format: "%.1f ms", now.timeIntervalSince(lastFrameArrival) * 1_000)
    }
    lastFrameArrival = now

    let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    let timestampText = timestamp.isValid ? String(format: "%.3f", CMTimeGetSeconds(timestamp)) : "invalid"
    lastFrameTimestampText = timestampText

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
    guard let lastPreviewUpdateAt else { return true }
    return now.timeIntervalSince(lastPreviewUpdateAt) >= 1 / maxPreviewFPS
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
    guard isDATStreamUsableForHeavyWork else {
      return .infinity
    }
    let delayRemaining = liveDATVisionDelayRemaining(at: now)
    guard delayRemaining <= 0 else {
      return .infinity
    }
    guard let liveDATFirstFrameAt else { return .infinity }
    let analysisSeconds = now.timeIntervalSince(liveDATFirstFrameAt) - liveDATVisionStartupDelaySeconds
    if analysisSeconds < liveDATVisionWarmupSeconds {
      return 1 / liveDATVisionWarmupFPS
    }
    return 1 / liveDATVisionSteadyFPS
  }

  private func replacePendingVisionImage(image: UIImage, sequence: UInt64) {
    pendingVisionImage = PendingVisionImage(image: image, sequence: sequence)
  }

  private func flushPendingVisionImageIfReady() {
    guard let pendingVisionImage else { return }
    let now = Date()
    guard shouldSubmitVisionFrame(at: now), !isProcessingFrame else { return }
    self.pendingVisionImage = nil
    submitVisionFrame(image: pendingVisionImage.image, sequence: pendingVisionImage.sequence, submittedAt: now)
  }

  private func visionSkipReason(at now: Date) -> String {
    guard inputMode == .realGlasses else {
      return "vision throttle"
    }
    guard isDATStreamUsableForHeavyWork else {
      return "DAT stream not ready for vision"
    }
    let delayRemaining = liveDATVisionDelayRemaining(at: now)
    if delayRemaining > 0 {
      return String(format: "vision startup delay %.1fs", delayRemaining)
    }
    return "vision throttle"
  }

  private func logVisionBusyGate(sequence: UInt64, source: String, stage: String) {
    guard verboseFrameLogging || sequence <= 5 || sequence % 30 == 0 else { return }
    AppLogger.log(
      .pipelineStats,
      "visionGate \(stage) frame=\(sequence) source=\(source) busy=\(isProcessingFrame) pending=\(statsWindowVisionPending) attemptedWindow=\(statsWindowVisionSubmittedFrames) processedWindow=\(statsWindowVisionProcessedFrames)"
    )
  }

  private func logVisionBusyDrop(sequence: UInt64, source: String) {
    AppLogger.log(
      .pipelineStats,
      "visionGate dropBusy frame=\(sequence) source=\(source) busy=\(isProcessingFrame) pending=\(statsWindowVisionPending)"
    )
  }

  private func logVisionBusySetTrue(sequence: UInt64, source: String) {
    AppLogger.log(
      .pipelineStats,
      "visionGate setBusy=true frame=\(sequence) source=\(source) pending=\(statsWindowVisionPending)"
    )
  }

  private func logVisionSelection(sequence: UInt64, source: String, result: VisionEnqueueResult) {
    guard verboseFrameLogging || result.visionEnqueued || result.selectedForVision || sequence <= 20 || sequence % 30 == 0 else { return }
    AppLogger.log(
      .pipelineStats,
      "visionSelection frame=\(sequence) source=\(source) selectedForVision=\(result.selectedForVision) visionEnqueued=\(result.visionEnqueued) visionStarted=false visionProcessed=false visionSkippedReason=\(result.visionSkippedReason) pending=\(statsWindowVisionPending)"
    )
  }

  private func logVisionEnqueued(sequence: UInt64, source: String) {
    AppLogger.log(
      .pipelineStats,
      "visionEnqueued frame=\(sequence) source=\(source) pending=\(statsWindowVisionPending)"
    )
  }

  private func markVisionStarted(sequence: UInt64, source: String) {
    visionSubmittedFrames += 1
    statsWindowVisionSubmittedFrames += 1
    AppLogger.log(
      .pipelineStats,
      "visionStarted frame=\(sequence) source=\(source) pending=\(statsWindowVisionPending) attemptedWindow=\(statsWindowVisionSubmittedFrames)"
    )
  }

  private func logVisionProcessed(sequence: UInt64, source: String, durationMS: Double, faces: Int) {
    AppLogger.log(
      .pipelineStats,
      "visionProcessed frame=\(sequence) source=\(source) durationMs=\(String(format: "%.1f", durationMS)) faces=\(faces) pending=\(statsWindowVisionPending)"
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
    } else if reason.localizedCaseInsensitiveContains("throttle")
      || reason.localizedCaseInsensitiveContains("delay")
      || reason.localizedCaseInsensitiveContains("not ready") {
      statsWindowSkippedThrottle += 1
    }
    if shouldLog || verboseFrameLogging {
      AppLogger.log(.frames, "Dropped \(inputMode.rawValue) frame #\(sequence): \(reason). dropped=\(totalDroppedFrames)")
    }
  }

  private func emitAggregateFrameStatsIfNeeded(force: Bool) {
    let now = Date()
    let elapsed = now.timeIntervalSince(statsWindowStartedAt)
    guard force || elapsed >= 2 else { return }
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
        format: "received=%llu preview=%llu visionAttempted=%llu visionProcessed=%llu visionPending=%llu faces=%llu qualityPass=%llu embedded=%llu matched=%llu droppedBusy=%llu skippedThrottle=%llu avgVisionMs=%.1f avgEmbedMs=%.1f",
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
        statsWindowSkippedThrottle,
        avgVisionMS,
        avgEmbedMS
      )
    )
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
    statsWindowSkippedThrottle = 0
    statsWindowFaceCandidates = 0
    statsWindowQualityPass = 0
    statsWindowEmbedded = 0
    statsWindowMatched = 0
    statsWindowEmbeddingDurationMS = 0
    statsWindowVisionDurationMS = 0
    statsWindowVisionDurationCount = 0
  }

  private func processIdentityIfNeeded(_ frame: ProcessedVideoFrame) {
    guard identityRecognitionEnabled else { return }
    guard !frame.identityCandidates.isEmpty else {
      identitySummaryText = "No face crop candidates"
      return
    }
    Task { [weak self] in
      guard let self else { return }
      let result = await identityPipeline.process(frame: frame)
      guard let result else { return }
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
    let shouldPersist = faceDetectionEventsPersisted < 30
      || (event.selectedFaceCount > 0 && lastFaceDetectionEventPersistedAt.map { now.timeIntervalSince($0) >= 1.0 } ?? true)
      || lastFaceDetectionEventPersistedAt.map { now.timeIntervalSince($0) >= 3.0 } ?? true
    guard shouldPersist else { return }
    faceDetectionEventsPersisted += 1
    lastFaceDetectionEventPersistedAt = now
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
      statsWindowEmbeddingDurationMS += result.embeddingLatencyMS
    }
    if result.matchDecisionText == IdentityMatchResult.Decision.known.rawValue {
      statsWindowMatched += 1
    }

    let identityUIKey = [
      result.activeIdentity.state.rawValue,
      result.activeIdentity.personId?.uuidString ?? "none",
      result.activeIdentity.displayName ?? "none",
      String(format: "%.1f", result.activeIdentity.confidence * 10),
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

    activeFacePersonId = result.activeIdentity.personId
    activeFaceName = result.activeIdentity.displayName
    activeFaceConfidence = result.activeIdentity.confidence
    activeFaceState = result.activeIdentity.state.rawValue
    if result.activeIdentity.state == .confirmed, let personId = result.activeIdentity.personId {
      recordSpeakerTimelineEntry(personId: personId, displayName: result.activeIdentity.displayName)
      refreshPersonConversationSummaryForCurrentStreamIfNeeded(personId: personId)
    }
    recordFaceEvidenceIfNeeded()
    activeIdentityName = result.activeIdentity.displayName ?? {
      switch result.activeIdentity.state {
      case .unknown:
        return "Unknown"
      case .possible, .ambiguous:
        return "Possible"
      case .confirmed:
        return result.activeIdentity.personId?.uuidString ?? "Confirmed"
      case .none, .noFace:
        return "None"
      }
    }()
    activeIdentityConfidenceText = String(format: "%.2f", result.activeIdentity.confidence)
    activeIdentityStateText = result.activeIdentity.state.rawValue
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
    maybeSpeakLiveAssistance()
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
    activeFacePersonId = nil
    activeFaceName = nil
    activeFaceConfidence = 0
    activeFaceState = "none"
    lastIdentityUIUpdateAt = nil
    lastIdentityUIKey = nil
    latestMouthMovementScore = 0
    speakerEvidenceTimeline = []
    faceEvidenceTimeline = []
  }

  private func resetLivePhoneAssistanceState() {
    invalidateAssistanceWork(reason: "resetLivePhoneAssistanceState", stopAudio: true)
    livePhoneAssistancePinnedPersonId = nil
    livePhoneAssistanceDismissedPersonId = nil
    conversationSummaryRefreshedPersonIdsThisStream = []
    phoneAssistanceDismissed = false
    phoneAssistanceTitleText = "Phone assistance"
    phoneAssistanceDetailText = "Identify a person to show conversation memory."
    phoneAssistanceStatusText = "Phone display fallback"
  }

  private func invalidateAssistanceWork(reason: String, stopAudio: Bool) {
    assistanceGeneration &+= 1
    AppLogger.log(.audio, "Assistance work invalidated generation=\(assistanceGeneration) reason=\(reason) stopAudio=\(stopAudio)")
  }

  func dismissPhoneAssistance() {
    livePhoneAssistanceDismissedPersonId = livePhoneAssistancePinnedPersonId ?? activeFacePersonId
    livePhoneAssistancePinnedPersonId = nil
    phoneAssistanceDismissed = true
    AppLogger.log(.memory, "Phone assistance dismissed personId=\(livePhoneAssistanceDismissedPersonId?.uuidString ?? "none")")
  }

  private func maybeSpeakLiveAssistance() {
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
        publishPhoneAssistanceCard(loadingCard, status: status)
        AppLogger.log(.memory, "Phone assistance waiting for person summary personId=\(personId.uuidString) name=\(activeIdentityName) confidence=\(String(format: "%.3f", activeFaceConfidence)) state=\(activeIdentityStateText)")
        return
      }
      let card = assistanceCardFormatter.makeCard(
        identity: identity,
        memory: currentAssistanceMemorySnapshot(personId: personId),
        displayStatus: .fallback("phone")
      )
      publishPhoneAssistanceCard(card, status: "Phone display fallback")
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
        publishPhoneAssistanceCard(card, status: "Pinned until stream ends")
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
    AppLogger.log(.memory, "Phone assistance updated without spoken trigger identity=\(identity) state=\(activeIdentityStateText) confidence=\(String(format: "%.3f", activeFaceConfidence)) faces=\(detectedFaceCount)")
  }

  private func publishPhoneAssistanceCard(_ card: AssistanceDisplayCard, status: String) {
    phoneAssistanceTitleText = card.title
    phoneAssistanceDetailText = card.lines.isEmpty
      ? "No saved conversation summary yet."
      : card.lines.joined(separator: "\n")
    phoneAssistanceStatusText = status
  }

  private func refreshPersonConversationSummaryForCurrentStreamIfNeeded(personId: UUID) {
    guard !conversationSummaryRefreshedPersonIdsThisStream.contains(personId) else { return }
    conversationSummaryRefreshedPersonIdsThisStream.insert(personId)
    AppLogger.log(.memory, "Person summary stream refresh requested personId=\(personId.uuidString)")
    refreshPersonConversationSummaryIfNeeded(personId: personId, forceSpeak: false, forceRefresh: true)
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
    let hasDeepSeekKey = !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    conversationSummaryInFlight.insert(personId)
    let generation = assistanceGeneration
    phoneAssistanceStatusText = hasDeepSeekKey
      ? "DeepSeek summarizing saved conversations"
      : "Loading saved conversation summary"
    AppLogger.log(.memory, "Person summary requested personId=\(personId.uuidString) model=\(settings.model) forceRefresh=\(forceRefresh) hasDeepSeekKey=\(hasDeepSeekKey)")
    Task { [weak self] in
      guard let self else { return }
      let entries = await self.identityPipeline.loadPeopleForDictionary()
      guard let entry = entries.first(where: { $0.id == personId }) else {
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

      let lastSeenText = Self.formatLastSeen(entry.lastSeen)
      let transcriptContext = Self.personConversationTranscriptContext(entry)
      do {
        let summary: String
        if transcriptContext.isEmpty {
          summary = "No saved attributed conversations yet."
          AppLogger.log(.memory, "Person summary has no saved attributed conversations personId=\(personId.uuidString) name=\(entry.displayName)")
        } else if !hasDeepSeekKey {
          summary = Self.localPersonConversationSummary(entry, transcriptContext: transcriptContext)
          AppLogger.log(.memory, "Person summary using local saved-conversation fallback personId=\(personId.uuidString) name=\(entry.displayName)")
        } else {
          let client = try DeepSeekAssistanceClient(apiKey: settings.apiKey, model: settings.model)
          summary = try await client.summarizePersonConversations(
            personName: entry.displayName,
            lastSeenText: lastSeenText,
            conversationTranscript: transcriptContext
          )
        }

        let snapshot = PersonConversationSummary(
          personId: personId,
          displayName: entry.displayName,
          lastSeenText: lastSeenText,
          summary: summary,
          conversationCount: entry.conversationTranscripts.count,
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
          self.conversationSummaryCache[personId] = snapshot
          self.conversationSummaryInFlight.remove(personId)
          let needsRefresh = self.conversationSummaryRefreshPendingPersonIds.remove(personId) != nil
          AppLogger.log(.memory, "Person summary ready personId=\(personId.uuidString) name=\(entry.displayName) conversations=\(entry.conversationTranscripts.count) transcriptChars=\(transcriptContext.count)")
          self.deepSeekStatusText = transcriptContext.isEmpty
            ? "No saved conversation transcript for \(entry.displayName)"
            : hasDeepSeekKey
              ? "DeepSeek summarized \(entry.conversationTranscripts.count) convo(s)"
              : "Loaded saved conversation summary"
          let identity = AssistanceIdentityState.known(
            name: entry.displayName,
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
            self.publishPhoneAssistanceCard(card, status: "Phone display fallback")
          }
          if needsRefresh {
            self.refreshPersonConversationSummaryIfNeeded(personId: personId, forceSpeak: false, forceRefresh: true)
          }
        }
      } catch {
        AppLogger.log(.memory, "DeepSeek person summary failed personId=\(personId.uuidString): \(error.localizedDescription)")
        await MainActor.run {
          self.conversationSummaryInFlight.remove(personId)
          let needsRefresh = self.conversationSummaryRefreshPendingPersonIds.remove(personId) != nil
          self.deepSeekStatusText = "DeepSeek summary failed"
          self.phoneAssistanceStatusText = "DeepSeek summary failed"
          if needsRefresh {
            self.refreshPersonConversationSummaryIfNeeded(personId: personId, forceSpeak: false, forceRefresh: true)
          }
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
    if detectedFaceCount > 1 {
      return .multipleFaces(count: detectedFaceCount)
    }
    if detectedFaceCount == 0 || activeIdentityStateText == ActiveIdentityState.State.noFace.rawValue {
      return .noFaceDetected
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
    return .unknown
  }

  private func currentAssistanceMemorySnapshot(personId: UUID? = nil) -> AssistanceMemorySnapshot {
    var topics: [String] = []
    if !recentConversationAttributionText.hasPrefix("No transcript") {
      topics.append(recentConversationAttributionText)
    }
    if !identitySummaryText.isEmpty && identitySummaryText != "Identity idle" {
      topics.append(identitySummaryText)
    }

    let reminder: String? = activeSpeakerStateText == "confirmed" && !activeSpeakerName.isEmpty
      ? "Current speaker appears to be \(activeSpeakerName)"
      : nil

    let personSummary = (personId ?? activeFacePersonId).flatMap { conversationSummaryCache[$0] }

    return AssistanceMemorySnapshot(
      lastInteraction: topics.first,
      lastSeen: personSummary?.lastSeenText,
      conversationSummary: personSummary?.summary,
      contextTopics: Array(topics.dropFirst()),
      reminder: reminder,
      suggestedAction: "Keep the reply short and confirm uncertain details"
    )
  }

  private var isLiveDATStreamActive: Bool {
    inputMode == .realGlasses
      && datIsStreamRunning
      && datStreamSessionStateText.lowercased().contains("streaming")
  }

  func saveDeepSeekSettings() {
    DeepSeekSettings(apiKey: deepSeekAPIKeyText, model: deepSeekModelText).save()
    deepSeekStatusText = deepSeekAPIKeyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "DeepSeek key missing"
      : "DeepSeek configured: \(deepSeekModelText)"
    AppLogger.log(.audio, "DeepSeek settings saved model=\(deepSeekModelText) hasApiKey=\(!deepSeekAPIKeyText.isEmpty)")
  }

  func saveCloudFaceEmbeddingSettings() {
    CloudFaceEmbeddingSettings(
      enabled: cloudFaceEmbeddingEnabled,
      endpoint: cloudFaceEmbeddingEndpointText,
      apiKey: cloudFaceEmbeddingAPIKeyText
    ).save()
    cloudFaceEmbeddingStatusText = cloudFaceEmbeddingEnabled
      ? "Cloud AdaFace saved; restart app to apply"
      : "Cloud face embedding off"
    AppLogger.log(.faceEmbeddingModel, "Cloud face embedding settings saved enabled=\(cloudFaceEmbeddingEnabled) endpoint=\(cloudFaceEmbeddingEndpointText) hasApiKey=\(!cloudFaceEmbeddingAPIKeyText.isEmpty)")
  }

  private func recordSpeakerEvidenceIfNeeded(_ result: SpeakerProcessingResult) {
    guard let personId = result.activeIdentity.personId else { return }
    let confidence = max(result.activeIdentity.confidence, result.matchResult?.bestSimilarity ?? 0)
    guard confidence > 0 else { return }
    speakerEvidenceTimeline.append(TimedSpeakerEvidence(
      timestamp: Date(),
      personId: personId,
      displayName: result.activeIdentity.displayName,
      confidence: confidence,
      state: result.activeIdentity.phase.rawValue
    ))
    speakerEvidenceTimeline = Array(speakerEvidenceTimeline.suffix(240))
  }

  private func recordFaceEvidenceIfNeeded() {
    guard let personId = activeFacePersonId else { return }
    guard activeFaceConfidence > 0 else { return }
    faceEvidenceTimeline.append(TimedFaceEvidence(
      timestamp: Date(),
      personId: personId,
      displayName: activeFaceName,
      confidence: activeFaceConfidence,
      state: activeFaceState,
      mouthMovementScore: latestMouthMovementScore
    ))
    faceEvidenceTimeline = Array(faceEvidenceTimeline.suffix(240))
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
    if let diarized = diarizationAttributionForEndedChunk(chunk, speakerSegments: speakerSegments) {
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
      var evidenceText = "postFusion:voice=\(String(format: "%.2f", voice.evidence.confidence));voiceDt=\(String(format: "%.1f", voice.distance))"
      if let face, face.evidence.personId == voice.evidence.personId {
        confidence = min(1, (voice.evidence.confidence * 0.65) + (face.evidence.confidence * 0.25) + (face.evidence.mouthMovementScore * 0.10))
        evidenceText += ";face=\(String(format: "%.2f", face.evidence.confidence));mouth=\(String(format: "%.2f", face.evidence.mouthMovementScore));faceDt=\(String(format: "%.1f", face.distance))"
      } else if let face {
        evidenceText += ";faceDisagrees=\(String(format: "%.2f", face.evidence.confidence));mouth=\(String(format: "%.2f", face.evidence.mouthMovementScore));faceDt=\(String(format: "%.1f", face.distance))"
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
        sourceEvidence: "postFusion:face=\(String(format: "%.2f", face.evidence.confidence));mouth=\(String(format: "%.2f", face.evidence.mouthMovementScore));faceDt=\(String(format: "%.1f", face.distance));voice=none"
      )
    }

    return TranscriptAttribution(
      personId: nil,
      displayName: nil,
      confidence: 0,
      state: "unknown",
      sourceEvidence: "postFusion:unknown;voice=\(voice.map { String(format: "%.2f", $0.evidence.confidence) } ?? "none");face=\(face.map { String(format: "%.2f", $0.evidence.confidence) } ?? "none");mouth=\(face.map { String(format: "%.2f", $0.evidence.mouthMovementScore) } ?? "none")"
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
    let evidence = "\(best.segment.source);speakerLabel=\(safeEvidenceValue(speakerName));overlap=\(String(format: "%.2f", best.overlap));distance=\(String(format: "%.2f", best.distance))"
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

  // MARK: - Cloud diarization

  private func recordSpeakerTimelineEntry(personId: UUID?, displayName: String?) {
    let last = speakerTimeline.last
    guard last?.personId != personId else { return }  // skip duplicates
    speakerTimeline.append(SpeakerTimelineEntry(timestamp: Date(), personId: personId, displayName: displayName))
  }

  private func submitCloudDiarizationJob(audioURL: URL, streamStart: Date,
                                          speakerTimeline: [SpeakerTimelineEntry],
                                          faceEvidenceTimeline: [TimedFaceEvidence],
                                          pipelineContext: PipelineContext?) async {
    cloudDiarizationState = .uploading
    do {
      let result = try await cloudDiarizationService.submitJob(audioFileURL: audioURL, streamStart: streamStart)
      cloudDiarizationState = .processing
      await applyDiarizationResult(result, streamStart: streamStart,
                                   speakerTimeline: speakerTimeline,
                                   faceEvidenceTimeline: faceEvidenceTimeline,
                                   pipelineContext: pipelineContext)
      try? FileManager.default.removeItem(at: audioURL)
      cloudDiarizationState = .done
    } catch {
      AppLogger.log(.audio, "[CloudDiarization] Job failed: \(error.localizedDescription)")
      try? FileManager.default.removeItem(at: audioURL)
      cloudDiarizationState = .failed(error.localizedDescription)
    }
  }

  private func applyDiarizationResult(_ result: DiarizenResult, streamStart: Date,
                                       speakerTimeline: [SpeakerTimelineEntry],
                                       faceEvidenceTimeline: [TimedFaceEvidence],
                                       pipelineContext: PipelineContext?) async {
    guard let ctx = pipelineContext, let sessionId = ctx.conversationSessionId else { return }

    // Build a lookup: given time offset (seconds from streamStart), find the confirmed person
    func personId(forOffset offset: Double) -> (UUID?, String?) {
      let ts = streamStart.addingTimeInterval(offset)
      // Walk the timeline backwards from the segment midpoint
      for entry in speakerTimeline.reversed() {
        if entry.timestamp <= ts { return (entry.personId, entry.displayName) }
      }
      let face = faceEvidenceTimeline
        .filter {
          $0.confidence >= IdentityConfig.weakMatchThreshold
            && abs($0.timestamp.timeIntervalSince(ts)) <= 12
        }
        .max { lhs, rhs in
          let lhsScore = lhs.confidence - Float(abs(lhs.timestamp.timeIntervalSince(ts)) * 0.02)
          let rhsScore = rhs.confidence - Float(abs(rhs.timestamp.timeIntervalSince(ts)) * 0.02)
          return lhsScore < rhsScore
        }
      if let face {
        return (face.personId, face.displayName)
      }
      return (nil, nil)
    }

    // Group unknown speakers for enrollment prompt
    var unknownSpeakers: [Int: UnknownDiarizationSpeaker] = [:]
    var savedChunkCount = 0
    var attributedPersonIds: Set<UUID> = []

    for segment in result.segments where !segment.text.isEmpty {
      let segStart = streamStart.addingTimeInterval(segment.start)
      let segEnd   = streamStart.addingTimeInterval(segment.end)
      let (resolvedPersonId, resolvedName) = personId(forOffset: (segment.start + segment.end) / 2)
      if let resolvedPersonId {
        attributedPersonIds.insert(resolvedPersonId)
      }

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
          ? "diarizen:\(resolvedName ?? "confirmed")"
          : "diarizen:unknown:Speaker\(segment.speakerIndex)",
        createdAt: Date()
      )
      await identityPipeline.saveCloudTranscriptChunk(chunk)
      savedChunkCount += 1

      // Track unknown speakers
      if resolvedPersonId == nil {
        let idx = segment.speakerIndex
        let dur = segment.end - segment.start
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

    AppLogger.log(.audio, "[CloudDiarization] Saved \(savedChunkCount) transcript chunks, \(unknownSpeakers.count) unknown speakers")
    invalidateAndRefreshConversationSummaries(for: attributedPersonIds, reason: "cloudDiarizationSavedChunks")

    // Refresh dictionary and publish unknown speakers
    let entries = await identityPipeline.loadPeopleForDictionary()
    await MainActor.run { self.peopleDictionaryEntries = entries }
    let unknownList = unknownSpeakers.values.sorted { $0.speakerIndex < $1.speakerIndex }
    unknownDiarizationSpeakers = unknownList

    // Pre-fetch speaker clip data for enrollment UI
    for speaker in unknownList {
      guard let key = speaker.clipS3Key else { continue }
      if let data = try? await cloudDiarizationService.downloadSpeakerClip(s3Key: key) {
        if let idx = unknownDiarizationSpeakers.firstIndex(where: { $0.speakerIndex == speaker.speakerIndex }) {
          unknownDiarizationSpeakers[idx].clipData = data
        }
      }
    }
  }

  // Renames all transcript chunks for an unknown speaker and optionally merges into an existing person.
  func renameUnknownSpeaker(speakerIndex: Int, sessionId: UUID, name: String, existingPersonId: UUID?) {
    Task { [weak self] in
      guard let self else { return }
      let sourceTag = "diarizen:unknown:Speaker\(speakerIndex)"
      let personId: UUID?
      if let existing = existingPersonId {
        personId = existing
      } else {
        personId = await self.identityPipeline.findOrCreatePerson(name: name)
      }
      guard let resolvedPersonId = personId else {
        AppLogger.log(.database, "[CloudDiarization] renameUnknownSpeaker failed to resolve person name=\"\(name)\" speakerIndex=\(speakerIndex)")
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
        return
      }
      await self.speakerPipeline.enrollFromAudioData(clipData, personId: resolvedPersonId, name: name)
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
      return "Wearer cosine: \(String(format: "%.3f", match.bestSimilarity)) · \(decision)"
    }
  }

  private func currentTranscriptAttribution() -> TranscriptAttribution {
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
      var evidence = "fusion:voice=\(String(format: "%.2f", voiceConfidence))"
      if facePersonId == voicePersonId {
        confidence = min(1, (voiceConfidence * 0.65) + (faceConfidence * 0.25) + (mouthScore * 0.10))
        evidence += ";face=\(String(format: "%.2f", faceConfidence));mouth=\(String(format: "%.2f", mouthScore))"
      } else if faceUsable {
        evidence += ";faceDisagrees=\(String(format: "%.2f", faceConfidence));mouth=\(String(format: "%.2f", mouthScore))"
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
        sourceEvidence: "fusion:face=\(String(format: "%.2f", faceConfidence));mouth=\(String(format: "%.2f", mouthScore));voice=none"
      )
    }

    if faceUsable, let facePersonId {
      return TranscriptAttribution(
        personId: facePersonId,
        displayName: activeFaceName ?? displayNamesById[facePersonId],
        confidence: faceConfidence,
        state: "fusedFaceOnly",
        sourceEvidence: "fusion:face=\(String(format: "%.2f", faceConfidence));mouth=\(String(format: "%.2f", mouthScore));voice=none"
      )
    }

    return TranscriptAttribution(
      personId: nil,
      displayName: nil,
      confidence: 0,
      state: "unknown",
      sourceEvidence: "fusion:unknown;voice=\(String(format: "%.2f", voiceConfidence));face=\(String(format: "%.2f", faceConfidence));mouth=\(String(format: "%.2f", mouthScore))"
    )
  }

  func savePendingPersonEnrollment() {
    let name = pendingEnrollmentName
    AppLogger.log(.enrollmentUI, "action=finishEnrollment tapped=true state=\(activeIdentityStateText)")
    enrollmentStatusText = "Creating profile vector..."
    Task { [weak self] in
      guard let self else { return }
      do {
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
        AppLogger.log(.audio, "Voice preview requested source=enrollment personId=\(personId.uuidString) samples=\(samples.count) seconds=\(String(format: "%.2f", seconds))")
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
        AppLogger.log(.audio, "Voice preview requested source=capturedClip id=\(id.uuidString) samples=\(samples.count) seconds=\(String(format: "%.2f", seconds))")
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

  private func syncLifecycleFromDATState(_ stateText: String) {
    let lower = stateText.lowercased()
    if lower.contains("streaming") {
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
      liveDATStreamingStartedAt = nil
      liveDATFirstFrameAt = nil
      liveDATLastFrameAt = nil
      lifecycleState = .stopping
      streamingStatus = .waiting
    } else if lower.contains("stopped") {
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
            snapshot.recordingSeconds,
            SpeakerIdentityConfig.wearerVoiceMinEnrollmentSeconds
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
        AppLogger.log(.audio, "Voice preview requested source=wearer samples=\(samples.count) seconds=\(String(format: "%.2f", seconds))")
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
        AppLogger.log(.audio, "Voice preview requested source=current samples=\(samples.count) seconds=\(String(format: "%.2f", seconds))")
        guard !samples.isEmpty else {
          self.voiceEnrollmentStatusText = "No voice preview available yet."
          return
        }
        guard seconds >= SpeakerIdentityConfig.minSpeechSecondsForEmbedding else {
          self.voiceEnrollmentStatusText = String(format: "Keep speaking until %.1f s before previewing.", SpeakerIdentityConfig.minSpeechSecondsForEmbedding)
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
    enrolledVoicePersonIds = ids
  }

  @MainActor
  private func refreshWearerVoiceProfile() async {
    let pipeline = speakerPipeline
    wearerVoiceProfile = await pipeline.wearerVoiceProfileSnapshot()
    wearerVoiceStatusText = wearerVoiceProfile.isEnrolled ? "My voice profile ready." : "My voice not enrolled"
  }
}
