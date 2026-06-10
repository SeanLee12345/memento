import Combine
import CoreMedia
import CoreVideo
import MWDATCamera
import MWDATCore
import MWDATDisplay
import SwiftUI

@MainActor
final class DATGlassesManager: ObservableObject {
  static let shared = DATGlassesManager()
  private static let realStreamFrameRate: UInt = 5
  private static let appFrameDeliveryMaxFPS: Double = 5
  private static let noVideoFramesWarningDelaySeconds: TimeInterval = 10
  private static let displayActionDispatchDelayNanoseconds: UInt64 = 150_000_000

  @Published private(set) var sdkStatusText = "Not configured"
  @Published private(set) var configurationModeText = DATConfigurationMode.developerMode.rawValue
  @Published private(set) var registrationStateText = "Unknown"
  @Published private(set) var deviceCount = 0
  @Published private(set) var selectedDeviceIDText = "None"
  @Published private(set) var deviceSessionStateText = "None"
  @Published private(set) var runtimeSessionStateText = "StateStream only"
  @Published private(set) var streamSessionStateText = "STOPPED"
  @Published private(set) var cameraPermissionStatusText = "Not requested"
  @Published private(set) var connectionStageText = DATConnectionStage.sdkConfigured.rawValue
  @Published private(set) var isConfigured = false
  @Published private(set) var isSimulator = false
  @Published private(set) var isConnecting = false
  @Published private(set) var isWaitingForMetaAIReturn = false
  @Published private(set) var hasActiveDevice = false
  @Published private(set) var isDeviceSessionReady = false
  @Published private(set) var isStreamRunning = false
  @Published private(set) var isAppActive = true
  @Published private(set) var devicesStreamActive = false
  @Published private(set) var metaAIOpenedTimestampText = "never"
  @Published private(set) var lastActiveAfterReturnText = "never"
  @Published private(set) var firstDevicesStreamEventTimestampText = "never"
  @Published private(set) var lastDevicesEventTimestampText = "never"
  @Published private(set) var selectedDeviceCompatibilityText = "unknown"
  @Published private(set) var selectedDeviceLinkStateText = "unknown"
  @Published private(set) var startReadinessReasonText = "SDK not configured"
  @Published private(set) var firstFrameTimestampText = "none"
  @Published private(set) var lastDATErrorText = "None"
  @Published private(set) var runtimeBundleConfigurationText = "Not inspected"
  @Published private(set) var runtimeURLTypesText = "Not inspected"
  @Published private(set) var runtimeCameraAccessSchemeText = "unknown"
  @Published private(set) var runtimeAssociatedDomainsText = "unknown"
  @Published private(set) var runtimeDeveloperModeFlagText = "unknown"
  @Published private(set) var lastOpenURLText = "none"
  @Published private(set) var lastHandleURLResultText = "none"
  @Published private(set) var lastRegistrationErrorDetailText = "None"
  @Published private(set) var startRegistrationCalledText = "no"
  @Published private(set) var requestCameraPermissionCalledText = "no"
  @Published private(set) var registrationHandoffDiagnosticText = "No handoff attempted"
  @Published private(set) var framesReceived: UInt64 = 0
  @Published private(set) var framesWithPixelBuffer: UInt64 = 0
  @Published private(set) var frameConversionFailures: UInt64 = 0
  @Published private(set) var lastFrameWidthText = "none"
  @Published private(set) var lastFrameHeightText = "none"
  @Published private(set) var lastFrameTimestampText = "none"
  @Published private(set) var lastFrameErrorText = "none"
  @Published private(set) var assistanceDisplayStateText = "Not connected"
  @Published private(set) var assistanceDisplayStatusText = "Display idle"
  @Published private(set) var assistanceDisplayLastCardText = "none"
  @Published private(set) var isAssistanceDisplayConnected = false
  @Published private(set) var assistanceDisplayRequiresDATAppUpdate = false
  @Published private(set) var assistanceDisplaySendCount: UInt64 = 0

  var onFrameImage: (@MainActor (UIImage) -> Void)?
  var onFramePixelBuffer: (@MainActor (CVPixelBuffer, UIImage?) -> Void)?
  var onError: ((String) -> Void)?
  var assistanceDisplayActionHandler: ((GlassesDisplayAction) -> Void)?

  private var didAttemptConfigure = false
  private var configureCallCount = 0
  private var currentRegistrationState: RegistrationState?
  private var registrationTask: Task<Void, Never>?
  private var deviceTask: Task<Void, Never>?
  private var devicesStreamListenerId = 0
  private var deviceSessionStateTask: Task<Void, Never>?
  private var activeDeviceTask: Task<Void, Never>?
  private var noDevicesTimeoutTask: Task<Void, Never>?
  private var noVideoFramesWatchdogTask: Task<Void, Never>?
  private var noVideoFramesWatchdogGeneration: UInt64 = 0
  private var registrationHandoffTimeoutTask: Task<Void, Never>?
  private var wearables: WearablesInterface?
  private var deviceSelector: AutoDeviceSelector?
  private var deviceSession: DeviceSession?
  private var activeDeviceSessionDeviceId: DeviceIdentifier?
  private var streamSession: MWDATCamera.Stream?
  private var stateListenerToken: AnyListenerToken?
  private var frameListenerToken: AnyListenerToken?
  private var errorListenerToken: AnyListenerToken?
  private var display: Display?
  private var displayStateListenerToken: AnyListenerToken?
  private var displayStateTask: Task<Void, Never>?
  private var displayStateContinuation: AsyncStream<DisplayState>.Continuation?
  private var pendingDisplayAction: (() async -> Void)?
  private var displayAttachInFlight = false
  private var displayAttachBlockedDeviceSessionId: String?
  private var displaySendInFlight = false
  private var queuedDisplaySend: QueuedDisplaySend?
  private var displayDetachAfterSendReason: String?
  private var displayGeneration: UInt64 = 0
  private var displaySDKTeardownInProgress = false
  private var teardownRetainedListenerTokens: [AnyListenerToken] = []
  private var teardownRetainedStreams: [MWDATCamera.Stream] = []
  private var teardownRetainedDisplays: [Display] = []
  private var lastSentDisplayCardKey = ""
  private var currentDisplayCardKey = ""
  private var currentDisplayPageIndex = 0
  private var lastLoggedStreamStateText = ""
  private var compatibilityListenerTokens: [DeviceIdentifier: AnyListenerToken] = [:]
  private var linkStateListenerTokens: [DeviceIdentifier: AnyListenerToken] = [:]
  private var selectedDeviceIsCompatible = false
  private var firstFrameSeen = false
  private var totalFramesReceived: UInt64 = 0
  private var totalFramesWithPixelBuffer: UInt64 = 0
  private var totalFrameConversionFailures: UInt64 = 0
  // App-delivered FPS window: distinguishes how many frames the app actually
  // processes per second (post delivery-gate) from the DAT SDK's own internal
  // recv/dec fps stats. Logged ~every 2s while frames flow so a slow stream can
  // be attributed to SDK delivery vs app processing vs network.
  private var fpsWindowStartedAt: Date?
  private var fpsWindowFrameCount: Int = 0
  private var fpsWindowConversionFailures: Int = 0
  // Per-window app processing latency (SDK callback → app handoff), in ms.
  private var fpsWindowLatencySumMs: Double = 0
  private var fpsWindowLatencyMaxMs: Double = 0
  private var fpsWindowLatencySamples: Int = 0
  private let appFrameDeliveryGate = DATFrameDeliveryGate(maxFPS: appFrameDeliveryMaxFPS)
  nonisolated private let streamCallbackGate = DATStreamCallbackGate()
  private var streamReachedStreaming = false
  private var didStartRegistrationHandoff = false
  private var didObserveRegisteringDuringCurrentHandoff = false
  private struct DATFrameExtraction: @unchecked Sendable {
    let frameType: String
    let pixelBuffer: CVPixelBuffer?
    let image: UIImage?
    let errorText: String?
    // Uptime (ns) captured the moment the SDK handed us the frame, before any
    // app processing — used to measure end-to-end app handoff latency.
    var receivedAtNanos: UInt64 = 0
  }

  private init() {}

  nonisolated static func noVideoFramesDiagnosticMessage(
    elapsedSeconds: TimeInterval,
    streamState: String,
    deviceSessionState: String
  ) -> String {
    "DAT stream is streaming but delivered no video frames after \(String(format: "%.0f", elapsedSeconds))s. Face detection and recognition cannot run until frames arrive. stream=\(streamState) deviceSession=\(deviceSessionState) framesReceived=0 firstFrame=none action=checkGlassesWornAwakeCameraAvailableThenStopAndStartStream"
  }

  var canStartStream: Bool {
    startReadinessBlocker() == nil
  }

  func configureAtStartup() {
    ensureConfigured()
  }

  func ensureConfigured() {
    guard !didAttemptConfigure else {
      updateStartReadinessReason()
      return
    }
    didAttemptConfigure = true

    #if targetEnvironment(simulator)
    isSimulator = true
    sdkStatusText = "Simulator: DAT disabled"
    registrationStateText = "Unavailable on simulator"
    AppLogger.log(.stream, "Real Meta glasses connection requires a physical iPhone.")
    updateStartReadinessReason()
    return
    #endif

    let mode = detectConfigurationMode()
    configurationModeText = mode.rawValue
    AppLogger.log(.sdk, "DAT configure requested. simulator=\(isSimulator), physicalDevice=\(!isSimulator), configurationMode=\(mode.rawValue)")
    refreshRuntimeConfigurationSnapshot(reason: "ensureConfigured")
    logConfigurationInputs(mode: mode)
    if mode == .developerMode {
      AppLogger.log(.sdk, "Running in Meta Developer Mode (MetaAppID=0, no ClientToken required)")
      UserDefaults.standard.set(true, forKey: "com.meta.wearable.dat.isDevMode")
    } else if let validationError = validateProductionConfiguration() {
      UserDefaults.standard.removeObject(forKey: "com.meta.wearable.dat.isDevMode")
      let message = "Production DAT configuration invalid: \(validationError)"
      sdkStatusText = "Configure blocked"
      lastDATErrorText = message
      AppLogger.log(.sdk, message)
      onError?(message)
      return
    }

    do {
      logSDKConfigurationPreflight()
      configureCallCount += 1
      AppLogger.log(.sdk, "Calling Wearables.configure() count=\(configureCallCount)")
      try Wearables.configure()
      let wearables = Wearables.shared
      self.wearables = wearables
      self.deviceSelector = AutoDeviceSelector(wearables: wearables)
      self.isConfigured = true
      self.sdkStatusText = "Configured"
      self.applyRegistrationState(wearables.registrationState)
      self.deviceCount = wearables.devices.count
      AppLogger.log(.sdk, "Wearables SDK configured. registrationState=\(wearables.registrationState), initialDeviceCount=\(wearables.devices.count)")
      observeRegistration(wearables: wearables)
      if wearables.registrationState == .registered {
        // Device discovery drives the DAT SDK's CoreBluetooth scanning. This
        // path runs synchronously inside MementoApp.init(), before the BLE
        // central has reached .poweredOn — kicking off discovery here produces
        // the "CBCentralManager can only accept this command while in the
        // powered on state" warning. Defer onto the next main-actor turn so the
        // central has a chance to power on first. The registration-state
        // observer also restarts discovery on .registered, and restartDiscovery
        // is idempotent (guards on devicesStreamActive), so this is race-safe.
        Task { @MainActor [weak self] in
          guard let self else { return }
          self.restartDiscovery(reason: "startup-registered")
          self.refreshCurrentDevices(reason: "startup-registered")
        }
      }
      updateStartReadinessReason()
    } catch {
      isConfigured = false
      sdkStatusText = "Configure failed"
      let message = "Wearables SDK configuration failed: \(error.localizedDescription)"
      lastDATErrorText = message
      AppLogger.log(.sdk, message)
      onError?(message)
      updateStartReadinessReason()
    }
  }

  func connectRealGlasses() async {
    AppLogger.log(.registration, "Connect my glasses tapped. simulator=\(isSimulator), configured=\(isConfigured), mode=\(configurationModeText), waitingForMetaAIReturn=\(isWaitingForMetaAIReturn)")
    ensureConfigured()
    guard let wearables = wearables, isConfigured, !isSimulator else {
      emitUnavailable()
      return
    }

    if isWaitingForMetaAIReturn || wearables.registrationState == .registering || currentRegistrationState == .registering {
      let message = "Registration in progress. Complete the Meta AI flow or wait."
      AppLogger.log(.registration, "Blocked duplicate Connect my glasses tap. state=\(wearables.registrationState), waitingForMetaAIReturn=\(isWaitingForMetaAIReturn)")
      lastDATErrorText = message
      onError?(message)
      updateStartReadinessReason()
      return
    }

    isConnecting = true
    applyRegistrationState(wearables.registrationState)
    AppLogger.log(.registration, "Connect state before registration call: \(wearables.registrationState)")

    if wearables.registrationState == .registered {
      applyRegistrationState(wearables.registrationState)
      AppLogger.log(.registration, "Already registered; continuing to device discovery stage")
      await continueAfterRegistration(reason: "already-registered-connect")
      isConnecting = false
      updateStartReadinessReason()
      return
    }

    do {
      isWaitingForMetaAIReturn = true
      metaAIOpenedTimestampText = Self.timestampText()
      connectionStageText = DATConnectionStage.registrationStarting.rawValue
      startRegistrationCalledText = "yes at \(metaAIOpenedTimestampText)"
      didStartRegistrationHandoff = true
      didObserveRegisteringDuringCurrentHandoff = false
      registrationHandoffDiagnosticText = "startRegistration called at \(metaAIOpenedTimestampText); waiting for Meta AI handoff, callback URL, or registered state."
      AppLogger.log(.registration, "Calling startRegistration from state=\(wearables.registrationState). Opening Meta AI is expected when user approval is required.")
      refreshRuntimeConfigurationSnapshot(reason: "before-startRegistration")
      scheduleRegistrationHandoffTimeout()
      try await wearables.startRegistration()
      applyRegistrationState(wearables.registrationState)
      AppLogger.log(.registration, "startRegistration returned. registrationState=\(wearables.registrationState)")
      if wearables.registrationState == .registered {
        isWaitingForMetaAIReturn = false
        cancelRegistrationHandoffTimeout()
        await continueAfterRegistration(reason: "registration-returned-registered")
      } else {
        connectionStageText = DATConnectionStage.waitingForMetaAIRegistration.rawValue
        AppLogger.log(.registration, "startRegistration returned without registered state. Waiting for Meta AI callback or registrationStateStream update.")
      }
    } catch {
      if error == .alreadyRegistered {
        isWaitingForMetaAIReturn = false
        cancelRegistrationHandoffTimeout()
        applyRegistrationState(wearables.registrationState)
        AppLogger.log(.registration, "Registration already complete; continuing to device discovery stage")
        await continueAfterRegistration(reason: "already-registered-error")
      } else {
        isWaitingForMetaAIReturn = false
        cancelRegistrationHandoffTimeout()
        logRegistrationFailure(error, wearables: wearables)
        emitError("Registration failed: \(error.description)")
      }
    }
    isConnecting = false
    updateStartReadinessReason()
  }

  func resumeAfterExternalAppReturn() async {
    let nowText = Self.timestampText()
    lastActiveAfterReturnText = nowText
    AppLogger.log(.registration, "App became active at \(nowText). waitingForMetaAIReturn=\(isWaitingForMetaAIReturn), configured=\(isConfigured)")
    ensureConfigured()
    guard let wearables = wearables, isConfigured, !isSimulator else { return }

    applyRegistrationState(wearables.registrationState)
    AppLogger.log(.registration, "Resume registration state=\(wearables.registrationState)")

    if wearables.registrationState == .registered && (isWaitingForMetaAIReturn || didStartRegistrationHandoff) {
      isWaitingForMetaAIReturn = false
      await continueAfterRegistration(reason: "app-active-registered")
    } else if wearables.registrationState == .registered {
      restartDiscovery(reason: "app-active-registered")
      refreshCurrentDevices(reason: "app-active-registered")
      AppLogger.log(.registration, "App active with registered DAT state; observing active device and waiting for Start streaming before preparing DeviceSession.")
    } else if isWaitingForMetaAIReturn {
      AppLogger.log(.registration, "Returned active but DAT is not registered yet. Waiting for registrationStateStream or callback URL.")
    }
    updateStartReadinessReason()
  }

  func noteScenePhase(_ phase: ScenePhase) {
    switch phase {
    case .active:
      isAppActive = true
      AppLogger.log(.registration, "Scene phase active")
    case .inactive:
      isAppActive = false
      AppLogger.log(.registration, "Scene phase inactive; external Meta AI handoff may be starting")
    case .background:
      isAppActive = false
      AppLogger.log(.registration, "Scene phase background; preserving DAT session state")
    @unknown default:
      AppLogger.log(.registration, "Scene phase unknown")
    }
    updateStartReadinessReason()
  }

  func requestCameraPermission() async -> Bool {
    guard let wearables = wearables, isConfigured else {
      emitUnavailable()
      return false
    }
    guard currentRegistrationState == .registered || wearables.registrationState == .registered else {
      cameraPermissionStatusText = "Not requested: registration not ready"
      AppLogger.log(.permissions, "Camera permission blocked because registrationState=\(wearables.registrationState)")
      updateStartReadinessReason()
      return false
    }
    do {
      connectionStageText = DATConnectionStage.requestingCameraPermission.rawValue
      var status = try await wearables.checkPermissionStatus(.camera)
      cameraPermissionStatusText = "\(status)"
      AppLogger.log(.permissions, "DAT camera permission status: \(status)")
      if status != .granted {
        requestCameraPermissionCalledText = "yes at \(Self.timestampText())"
        AppLogger.log(.permissions, "Calling requestPermission(.camera). Meta AI approval may be required.")
        status = try await wearables.requestPermission(.camera)
        cameraPermissionStatusText = "\(status)"
        AppLogger.log(.permissions, "DAT camera permission request result: \(status)")
      }
      if status == .granted {
        connectionStageText = DATConnectionStage.cameraPermissionGranted.rawValue
      }
      updateStartReadinessReason()
      return status == .granted
    } catch {
      cameraPermissionStatusText = "Permission error"
      let detail = error.description
      if detail.localizedCaseInsensitiveContains("No wearable devices")
        || detail.localizedCaseInsensitiveContains("discovered or registered")
        || detail.localizedCaseInsensitiveContains("powered off or disconnected")
        || detail.localizedCaseInsensitiveContains("connection error occurred while communicating with the device") {
        cameraPermissionStatusText = "Waiting for device discovery"
        connectionStageText = DATConnectionStage.discoveringDevices.rawValue
        lastDATErrorText = "Waiting for connected glasses before camera permission can be confirmed. Keep the glasses awake/open and retry Connect."
        restartDiscovery(reason: "camera-permission-transient-error")
        refreshCurrentDevices(reason: "camera-permission-transient-error")
        scheduleNoDevicesTimeout(reason: "camera-permission-transient-error")
        AppLogger.log(.permissions, "Camera permission temporarily unavailable while waiting for DAT device discovery/connectivity: \(detail)")
      } else {
        emitError("Camera permission failed: \(detail)")
      }
      updateStartReadinessReason()
      return false
    }
  }

  func startStream() async -> Bool {
    guard isConfigured else {
      emitUnavailable()
      return false
    }
    guard canStartStream else {
      let reason = startReadinessBlocker() ?? "unknown readiness failure"
      emitError("Start streaming blocked: \(reason)")
      AppLogger.log(.stream, "Start stream blocked: \(reason)")
      return false
    }
    guard await requestCameraPermission() else { return false }

    if let existingStream = streamSession {
      let stateText = streamSessionStateText.lowercased()
      if stateText.contains("waiting") || stateText.contains("starting") || stateText.contains("paused") {
        AppLogger.log(.stream, "Start stream ignored because existing DAT Stream is still \(streamSessionStateText). Waiting for SDK state transition.")
        return true
      }
      if isStreamRunning || stateText.contains("streaming") {
        AppLogger.log(.stream, "Start stream ignored because existing DAT Stream is already streaming.")
        return true
      }
      AppLogger.log(.stream, "Clearing stopped DAT Stream before creating a new stream. state=\(streamSessionStateText)")
      clearStreamListeners()
      streamSession = nil
      _ = existingStream
    }

    guard let currentSession = await prepareDeviceSession(reason: "start-stream") else {
      emitError("Start streaming blocked: DeviceSession did not reach started.")
      updateStartReadinessReason()
      return false
    }

    return await startStream(session: currentSession, resolution: .low, frameRate: Self.realStreamFrameRate)
  }

  private func startStream(session: DeviceSession, resolution: StreamingResolution, frameRate: UInt) async -> Bool {
    guard session.state == .started else {
      emitError("Cannot start stream because DeviceSession state is \(session.state)")
      return false
    }

    let config = StreamConfiguration(
      videoCodec: VideoCodec.raw,
      resolution: resolution,
      frameRate: frameRate
    )

    do {
      AppLogger.log(.stream, "Calling addStream(config:) codec=raw resolution=\(resolution) frameRate=\(frameRate) on DeviceSession state=\(session.state) configSource=MetaCameraAccessSample appFrameDeliveryFPS=\(Self.appFrameDeliveryMaxFPS)")
      guard let stream = try session.addStream(config: config) else {
        emitError("Failed to create DAT Stream.")
        return false
      }
      streamSession = stream
      resetFrameDiagnostics()
      cancelNoVideoFramesWatchdog()
      streamSessionStateText = "STARTING"
      firstFrameSeen = false
      streamReachedStreaming = false
      setupStreamListeners(for: stream)
      AppLogger.log(.stream, "Starting real DAT Stream with listeners attached")
      await stream.start()
      AppLogger.log(.stream, "Real DAT Stream start requested; waiting for SDK statePublisher to report streaming or stopped")
      return true
    } catch {
      emitError("Failed to create DAT Stream: \(error.localizedDescription)")
      return false
    }
  }

  func stopStream(reason: String = "callerRequested") async {
    let stream = streamSession
    releaseLocalStreamReference(reason: "stopStream-\(reason)", stateText: "STOPPED")
    if let stream {
      AppLogger.log(.stream, "Stopping real DAT Stream reason=\(reason)")
      await stream.stop()
    } else {
      AppLogger.log(.stream, "Stop real DAT Stream requested with no active stream reason=\(reason)")
    }
    updateStartReadinessReason()
  }

  @discardableResult
  func sendAssistanceCard(
    _ card: AssistanceDisplayCard,
    reason: String,
    resetPage: Bool = false
  ) async -> Bool {
    guard isConfigured, !isSimulator else {
      assistanceDisplayStatusText = isSimulator
        ? "Display unavailable on simulator"
        : "Display unavailable before DAT configuration"
      AppLogger.log(.display, "Assistance display send skipped reason=\(reason) status=\(assistanceDisplayStatusText)")
      return false
    }

    guard isDATAppModelEnabled else {
      assistanceDisplayStatusText = "Display disabled for camera-stream build"
      AppLogger.log(.display, "Assistance display send skipped reason=\(reason) status=DAMDisabled")
      return false
    }

    let cardKey = Self.displayCardKey(card)
    let pages = Self.displayPages(for: card)
    if resetPage {
      currentDisplayPageIndex = 0
    } else if cardKey != currentDisplayCardKey {
      currentDisplayCardKey = cardKey
      currentDisplayPageIndex = min(currentDisplayPageIndex, max(0, pages.count - 1))
    }
    let pageIndex = min(currentDisplayPageIndex, max(0, pages.count - 1))
    let payloadKey = Self.displayPayloadKey(cardKey: cardKey, pageIndex: pageIndex)
    if payloadKey == lastSentDisplayCardKey, isAssistanceDisplayConnected {
      AppLogger.log(.display, "Assistance display send skipped duplicate reason=\(reason)")
      return true
    }

    if let display, isAssistanceDisplayConnected {
      return await sendAssistancePage(
        cardKey: cardKey,
        pages: pages,
        pageIndex: pageIndex,
        on: display,
        reason: reason
      )
    }

    pendingDisplayAction = { [weak self] in
      guard let self, let display = self.display else { return }
      _ = await self.sendAssistancePage(
        cardKey: cardKey,
        pages: pages,
        pageIndex: pageIndex,
        on: display,
        reason: "pending-\(reason)"
      )
    }

    if display == nil {
      await attachAssistanceDisplayIfNeeded(reason: reason)
    } else {
      assistanceDisplayStatusText = "Waiting for glasses display"
    }

    return false
  }

  func clearAssistanceDisplay(reason: String) async {
    guard isDATAppModelEnabled else { return }
    guard isDisplaySDKInteractionAllowed else {
      releaseLocalDisplayReference(reason: "clear-\(reason)-sessionNotStarted")
      return
    }
    guard let display else { return }
    let card = AssistanceCardFormatter(maximumLineCount: 2, maximumLineLength: 96).makeCard(
      identity: .noFaceDetected,
      memory: AssistanceMemorySnapshot(),
      displayStatus: .glassesDisplay
    )
    let cardKey = Self.displayCardKey(card)
    let pages = Self.displayPages(for: card)
    _ = await sendAssistancePage(
      cardKey: cardKey,
      pages: pages,
      pageIndex: 0,
      on: display,
      reason: "clear-\(reason)"
    )
  }

  func detachAssistanceDisplay(reason: String) async {
    guard isDisplaySDKInteractionAllowed else {
      releaseLocalDisplayReference(reason: "detach-\(reason)-sessionNotStarted")
      return
    }
    pendingDisplayAction = nil
    queuedDisplaySend = nil
    lastSentDisplayCardKey = ""
    currentDisplayCardKey = ""
    currentDisplayPageIndex = 0
    if displaySendInFlight {
      displayDetachAfterSendReason = reason
      assistanceDisplayStatusText = "Stopping display after current update"
      AppLogger.log(.display, "Assistance display detach deferred because send is in flight reason=\(reason)")
      return
    }
    displayDetachAfterSendReason = nil
    displayStateListenerToken = nil
    displayStateContinuation?.finish()
    displayStateContinuation = nil
    displayStateTask?.cancel()
    displayStateTask = nil
    displayAttachInFlight = false
    displayAttachBlockedDeviceSessionId = nil
    if let display {
      AppLogger.log(.display, "Stopping assistance display reason=\(reason)")
      await display.stop()
    }
    display = nil
    isAssistanceDisplayConnected = false
    assistanceDisplayStateText = "Not connected"
    assistanceDisplayStatusText = "Display stopped"
  }

  private var isDisplaySDKInteractionAllowed: Bool {
    guard isDATAppModelEnabled else { return false }
    guard let session = deviceSession else { return false }
    return session.state == .started
      && deviceSessionStateText.lowercased().contains("started")
  }

  private func releaseLocalDisplayReference(
    reason: String,
    preserveSDKReferencesForTeardown: Bool = false
  ) {
    if preserveSDKReferencesForTeardown {
      beginDisplaySDKTeardown(reason: reason)
      return
    }
    let hadDisplayState = display != nil
      || displayStateListenerToken != nil
      || displayStateContinuation != nil
      || displayStateTask != nil
      || pendingDisplayAction != nil
      || queuedDisplaySend != nil
      || displaySendInFlight
      || isAssistanceDisplayConnected
    displayGeneration &+= 1
    displaySDKTeardownInProgress = false
    pendingDisplayAction = nil
    queuedDisplaySend = nil
    displayDetachAfterSendReason = nil
    lastSentDisplayCardKey = ""
    currentDisplayCardKey = ""
    currentDisplayPageIndex = 0
    displayStateListenerToken = nil
    displayStateContinuation?.finish()
    displayStateContinuation = nil
    displayStateTask?.cancel()
    displayStateTask = nil
    displayAttachInFlight = false
    displayAttachBlockedDeviceSessionId = nil
    display = nil
    displaySendInFlight = false
    isAssistanceDisplayConnected = false
    assistanceDisplayStateText = "Not connected"
    assistanceDisplayStatusText = "Display stopped"
    if hadDisplayState {
      AppLogger.log(.display, "Released local assistance display reference reason=\(reason), deviceSession=\(deviceSessionStateText)")
    }
  }

  private func beginDisplaySDKTeardown(reason: String) {
    let hadDisplayState = display != nil
      || displayStateListenerToken != nil
      || displayStateContinuation != nil
      || displayStateTask != nil
      || pendingDisplayAction != nil
      || queuedDisplaySend != nil
      || displaySendInFlight
      || isAssistanceDisplayConnected
    guard hadDisplayState else { return }
    displayGeneration &+= 1
    pendingDisplayAction = nil
    queuedDisplaySend = nil
    displayDetachAfterSendReason = nil
    lastSentDisplayCardKey = ""
    currentDisplayCardKey = ""
    currentDisplayPageIndex = 0
    displayAttachInFlight = false
    displayAttachBlockedDeviceSessionId = nil
    isAssistanceDisplayConnected = false
    assistanceDisplayStateText = "Not connected"
    assistanceDisplayStatusText = "Display teardown pending"

    if !displaySDKTeardownInProgress {
      var retainedCount = 0
      if let displayStateListenerToken {
        teardownRetainedListenerTokens.append(displayStateListenerToken)
        retainedCount += 1
      }
      if let display {
        teardownRetainedDisplays.append(display)
      }
      displaySDKTeardownInProgress = true
      AppLogger.log(.display, "Retained DAT display references through SDK teardown reason=\(reason), listenerTokens=\(retainedCount), displayRetained=\(display != nil)")
    } else {
      AppLogger.log(.display, "DAT display teardown already pending reason=\(reason)")
    }
  }

  private func finalizeDisplaySDKTeardown(reason: String) {
    if displaySDKTeardownInProgress {
      AppLogger.log(.display, "Finalizing DAT display teardown reason=\(reason)")
    }
    releaseLocalDisplayReference(reason: reason)
  }

  private func attachAssistanceDisplayIfNeeded(reason: String) async {
    guard display == nil else { return }
    if let activeDeviceSessionDeviceId,
       displayAttachBlockedDeviceSessionId == "\(activeDeviceSessionDeviceId)" {
      assistanceDisplayStatusText = "Glasses display already active"
      AppLogger.log(.display, "Assistance display attach skipped reason=\(reason) status=capabilityAlreadyActive deviceId=\(activeDeviceSessionDeviceId)")
      return
    }
    guard !displayAttachInFlight else {
      assistanceDisplayStatusText = "Starting glasses display..."
      AppLogger.log(.display, "Assistance display attach already in flight reason=\(reason)")
      return
    }
    guard isDATAppModelEnabled else {
      assistanceDisplayStatusText = "Display disabled for camera-stream build"
      AppLogger.log(.display, "Assistance display attach skipped reason=\(reason) status=DAMDisabled")
      return
    }
    guard currentRegistrationState == .registered || wearables?.registrationState == .registered else {
      assistanceDisplayStatusText = "Display waiting for DAT registration"
      AppLogger.log(.display, "Assistance display attach skipped before registration reason=\(reason)")
      return
    }

    assistanceDisplayStatusText = "Starting glasses display..."
    AppLogger.log(.display, "Preparing assistance display reason=\(reason)")
    displayAttachInFlight = true
    defer { displayAttachInFlight = false }

    guard let session = await prepareDeviceSession(reason: "assistance-display-\(reason)") else {
      assistanceDisplayStatusText = "Display session unavailable"
      return
    }
    let sessionDeviceIdText = "\(session.deviceId)"

    guard displayAttachBlockedDeviceSessionId != sessionDeviceIdText else {
      assistanceDisplayStatusText = "Glasses display already active"
      AppLogger.log(.display, "Assistance display attach skipped reason=\(reason) status=capabilityAlreadyActive deviceId=\(session.deviceId)")
      return
    }

    guard selectedDeviceSupportsDisplay(session.deviceId) else {
      assistanceDisplayStatusText = "Selected glasses do not report display support"
      AppLogger.log(.display, "Assistance display unavailable deviceId=\(session.deviceId) reason=noDisplaySupport")
      return
    }

    do {
      let capability = try session.addDisplay()
      displayGeneration &+= 1
      display = capability
      let (stateStream, continuation) = AsyncStream.makeStream(of: DisplayState.self)
      displayStateContinuation = continuation
      displayStateListenerToken = capability.statePublisher.listen { state in
        continuation.yield(state)
      }
      displayStateTask = Task { [weak self] in
        for await state in stateStream {
          guard let self, !Task.isCancelled else { return }
          self.handleAssistanceDisplayState(state)
        }
      }
      assistanceDisplayStateText = "starting"
      await capability.start()
      AppLogger.log(.display, "Assistance display start requested deviceId=\(session.deviceId)")
    } catch DeviceSessionError.datAppOnTheGlassesUpdateRequired {
      assistanceDisplayRequiresDATAppUpdate = true
      assistanceDisplayStatusText = "DAT glasses app update required"
      display = nil
      AppLogger.log(.display, "Assistance display failed: DAT app on glasses update required")
    } catch {
      assistanceDisplayRequiresDATAppUpdate = false
      display = nil
      if Self.isDisplayCapabilityAlreadyActiveError(error) {
        displayAttachBlockedDeviceSessionId = sessionDeviceIdText
        assistanceDisplayStatusText = "Glasses display already active"
        AppLogger.log(.display, "Assistance display attach blocked for active capability deviceId=\(session.deviceId) reason=\(reason): \(error.localizedDescription)")
        return
      }
      assistanceDisplayStatusText = "Display failed: \(error.localizedDescription)"
      AppLogger.log(.display, "Assistance display failed reason=\(reason): \(error.localizedDescription)")
    }
  }

  nonisolated static func isDisplayCapabilityAlreadyActiveError(_ error: Error) -> Bool {
    let text = "\(error.localizedDescription) \(String(describing: error))".lowercased()
    return text.contains("capability")
      && text.contains("already active")
      && text.contains("session")
  }

  private func handleAssistanceDisplayState(_ state: DisplayState) {
    assistanceDisplayStateText = "\(state)"
    switch state {
    case .started:
      isAssistanceDisplayConnected = true
      assistanceDisplayRequiresDATAppUpdate = false
      assistanceDisplayStatusText = "Glasses display connected"
      if let action = pendingDisplayAction {
        pendingDisplayAction = nil
        Task { await action() }
      }
    case .starting:
      isAssistanceDisplayConnected = false
      assistanceDisplayStatusText = "Starting glasses display..."
    case .stopping:
      isAssistanceDisplayConnected = false
      assistanceDisplayStatusText = "Stopping glasses display..."
    case .stopped:
      if displaySDKTeardownInProgress,
         deviceSessionStateText.lowercased().contains("stopping") {
        AppLogger.log(.display, "Assistance display stopped during DeviceSession teardown; waiting for DeviceSession stopped before releasing references")
        return
      }
      releaseLocalDisplayReference(reason: "displayStateStopped")
    }
    AppLogger.log(.display, "Assistance display state=\(state)")
  }

  @discardableResult
  private func sendAssistancePage(
    cardKey: String,
    pages: [AssistanceDisplayPage],
    pageIndex: Int,
    on display: Display,
    reason: String
  ) async -> Bool {
    guard !pages.isEmpty else { return false }
    guard isDisplaySDKInteractionAllowed else {
      releaseLocalDisplayReference(reason: "send-\(reason)-sessionNotStarted")
      return false
    }
    let clampedPageIndex = min(max(pageIndex, 0), pages.count - 1)
    let page = pages[clampedPageIndex]

    if displaySendInFlight {
      let replacedQueuedSend = queuedDisplaySend != nil
      queuedDisplaySend = QueuedDisplaySend(
        cardKey: cardKey,
        pages: pages,
        pageIndex: clampedPageIndex,
        reason: reason
      )
      assistanceDisplayStatusText = "Display update queued"
      AppLogger.log(.display, "Assistance display send queued reason=\(reason) replaced=\(replacedQueuedSend)")
      return false
    }

    displayGeneration &+= 1
    let sendGeneration = displayGeneration
    let shouldPinStreamControls = Self.shouldPinStreamControls(for: page, isStreamRunning: isStreamRunning)

    let previousAction: (@Sendable () -> Void)?
    if shouldPinStreamControls || clampedPageIndex > 0 {
      previousAction = { [weak self] in
        Task<Void, Never> { @MainActor in
          try? await Task.sleep(nanoseconds: Self.displayActionDispatchDelayNanoseconds)
          guard let self,
                let display = self.display,
                self.shouldAcceptDisplayCallback(generation: sendGeneration) else { return }
          self.dispatchAssistanceDisplayButtonAction(.previousPage, source: "previousPage", generation: sendGeneration)
          guard clampedPageIndex > 0 else { return }
          _ = await self.sendAssistancePage(
            cardKey: cardKey,
            pages: pages,
            pageIndex: clampedPageIndex - 1,
            on: display,
            reason: "previous-\(reason)"
          )
        }
      }
    } else {
      previousAction = nil
    }

    let nextAction: (@Sendable () -> Void)?
    if shouldPinStreamControls || clampedPageIndex < pages.count - 1 {
      nextAction = { [weak self] in
        Task<Void, Never> { @MainActor in
          try? await Task.sleep(nanoseconds: Self.displayActionDispatchDelayNanoseconds)
          guard let self,
                let display = self.display,
                self.shouldAcceptDisplayCallback(generation: sendGeneration) else { return }
          self.dispatchAssistanceDisplayButtonAction(.nextPage, source: "nextPage", generation: sendGeneration)
          guard clampedPageIndex < pages.count - 1 else { return }
          _ = await self.sendAssistancePage(
            cardKey: cardKey,
            pages: pages,
            pageIndex: clampedPageIndex + 1,
            on: display,
            reason: "next-\(reason)"
          )
        }
      }
    } else {
      nextAction = nil
    }

    let primaryAction: (@Sendable () -> Void)?
    if let action = page.primaryAction {
      primaryAction = { [weak self] in
        Task<Void, Never> { @MainActor in
          try? await Task.sleep(nanoseconds: Self.displayActionDispatchDelayNanoseconds)
          guard let self, self.shouldAcceptDisplayCallback(generation: sendGeneration) else { return }
          self.dispatchAssistanceDisplayButtonAction(action, source: "primary", generation: sendGeneration)
        }
      }
    } else {
      primaryAction = nil
    }

    let secondaryAction: (@Sendable () -> Void)?
    if let action = page.secondaryAction {
      secondaryAction = { [weak self] in
        Task<Void, Never> { @MainActor in
          try? await Task.sleep(nanoseconds: Self.displayActionDispatchDelayNanoseconds)
          guard let self, self.shouldAcceptDisplayCallback(generation: sendGeneration) else { return }
          self.dispatchAssistanceDisplayButtonAction(action, source: "secondary", generation: sendGeneration)
        }
      }
    } else {
      secondaryAction = nil
    }

    let tertiaryAction: (@Sendable () -> Void)?
    if let action = page.tertiaryAction {
      tertiaryAction = { [weak self] in
        Task<Void, Never> { @MainActor in
          try? await Task.sleep(nanoseconds: Self.displayActionDispatchDelayNanoseconds)
          guard let self, self.shouldAcceptDisplayCallback(generation: sendGeneration) else { return }
          self.dispatchAssistanceDisplayButtonAction(action, source: "tertiary", generation: sendGeneration)
        }
      }
    } else {
      tertiaryAction = nil
    }

    let stopAction: @Sendable () -> Void = { [weak self] in
      Task<Void, Never> { @MainActor in
        try? await Task.sleep(nanoseconds: Self.displayActionDispatchDelayNanoseconds)
        guard let self, self.shouldAcceptDisplayCallback(generation: sendGeneration) else { return }
        self.dispatchAssistanceDisplayButtonAction(.stopStream, source: "pinnedStop", generation: sendGeneration)
      }
    }
    let peopleAction: @Sendable () -> Void = { [weak self] in
      Task<Void, Never> { @MainActor in
        try? await Task.sleep(nanoseconds: Self.displayActionDispatchDelayNanoseconds)
        guard let self, self.shouldAcceptDisplayCallback(generation: sendGeneration) else { return }
        self.dispatchAssistanceDisplayButtonAction(.openPeople, source: "pinnedPeople", generation: sendGeneration)
      }
    }

    let view: FlexBox = Self.displayView(
      for: page,
      pinsStreamControls: shouldPinStreamControls,
      onPrevious: previousAction,
      onNext: nextAction,
      onStop: shouldPinStreamControls ? stopAction : nil,
      onPeople: shouldPinStreamControls ? peopleAction : nil,
      onPrimary: primaryAction,
      onSecondary: secondaryAction,
      onTertiary: tertiaryAction
    )

    let imageDiagnostic = Self.displayImageDiagnostic(for: page.thumbnailImageURI)
    if page.thumbnailImageURI != nil || reason.contains("identity-confirm") || reason.contains("identity-selection") {
      AppLogger.log(
        .display,
        "Assistance display image payload reason=\(reason) title=\"\(page.title)\" page=\(page.number)/\(page.count) \(imageDiagnostic)"
      )
    }

    displaySendInFlight = true
    defer { displaySendInFlight = false }
    let sendSucceeded: Bool
    do {
      try await display.send(view)
      guard sendGeneration == displayGeneration else {
        AppLogger.log(.display, "Assistance display send result ignored because display generation changed reason=\(reason)")
        return false
      }
      assistanceDisplaySendCount += 1
      currentDisplayCardKey = cardKey
      currentDisplayPageIndex = clampedPageIndex
      lastSentDisplayCardKey = Self.displayPayloadKey(cardKey: cardKey, pageIndex: clampedPageIndex)
      assistanceDisplayLastCardText = page.text
      assistanceDisplayStatusText = "Sent to glasses display"
      assistanceDisplayActionHandler?(.displayed)
      AppLogger.log(.display, "Assistance display card sent reason=\(reason) title=\"\(page.title)\" page=\(page.number)/\(page.count) lines=\(page.lines.count) \(imageDiagnostic)")
      sendSucceeded = true
    } catch {
      guard sendGeneration == displayGeneration else {
        AppLogger.log(.display, "Assistance display send error ignored because display generation changed reason=\(reason)")
        return false
      }
      let message = (error as? DisplayError)?.description ?? error.localizedDescription
      assistanceDisplayStatusText = "Display send failed: \(message)"
      AppLogger.log(.display, "Assistance display send failed reason=\(reason): \(message)")
      sendSucceeded = false
    }
    displaySendInFlight = false
    if let detachReason = displayDetachAfterSendReason {
      displayDetachAfterSendReason = nil
      await detachAssistanceDisplay(reason: "deferred-\(detachReason)")
    } else {
      await flushQueuedDisplaySendIfNeeded()
    }

    return sendSucceeded
  }

  private func dispatchAssistanceDisplayButtonAction(
    _ action: GlassesDisplayAction,
    source: String,
    generation: UInt64? = nil
  ) {
    if let generation,
       !shouldAcceptDisplayCallback(generation: generation) {
      AppLogger.log(.display, "Assistance display button ignored because display generation changed action=\(action.rawValue) source=\(source)")
      return
    }
    guard isDisplaySDKInteractionAllowed else { return }
    AppLogger.log(
      .display,
      "Assistance display button dispatched action=\(action.rawValue) source=\(source) delayMs=150"
    )
    assistanceDisplayActionHandler?(action)
  }

  private func shouldAcceptDisplayCallback(generation: UInt64) -> Bool {
    Self.shouldAcceptDisplayCallback(
      callbackGeneration: generation,
      currentGeneration: displayGeneration,
      isDisplaySDKInteractionAllowed: isDisplaySDKInteractionAllowed,
      isAssistanceDisplayConnected: isAssistanceDisplayConnected,
      isTeardownInProgress: displaySDKTeardownInProgress
    )
  }

  nonisolated static func shouldAcceptDisplayCallback(
    callbackGeneration: UInt64,
    currentGeneration: UInt64,
    isDisplaySDKInteractionAllowed: Bool,
    isAssistanceDisplayConnected: Bool,
    isTeardownInProgress: Bool
  ) -> Bool {
    callbackGeneration == currentGeneration
      && isDisplaySDKInteractionAllowed
      && isAssistanceDisplayConnected
      && !isTeardownInProgress
  }

  private func flushQueuedDisplaySendIfNeeded() async {
    guard !displaySendInFlight,
          let queuedSend = queuedDisplaySend,
          let display,
          isAssistanceDisplayConnected else {
      return
    }
    queuedDisplaySend = nil
    _ = await sendAssistancePage(
      cardKey: queuedSend.cardKey,
      pages: queuedSend.pages,
      pageIndex: queuedSend.pageIndex,
      on: display,
      reason: "queued-\(queuedSend.reason)"
    )
  }

  private func selectedDeviceSupportsDisplay(_ deviceId: DeviceIdentifier) -> Bool {
    guard let device = wearables?.deviceForIdentifier(deviceId) else { return false }
    return device.supportsDisplay()
  }

  nonisolated static func displayIconName(for action: GlassesDisplayAction) -> IconName {
    switch action {
    case .displayed:
      return .iCircle
    case .openPeople:
      return .threePeopleOverlapping
    case .startStream:
      return .videoCamera
    case .stopStream:
      return .videoCameraOff
    case .openContext:
      return .iCircle
    case .openTranscripts:
      return .speechBubbleOff
    case .snapshotFrame:
      return .fourCornerFrame
    case .markReviewed:
      return .checkmarkCircle
    case .hideCard:
      return .speechBubbleOff
    case .backToHome:
      return .house
    case .nextPage:
      return .arrowRight
    case .previousPage:
      return .arrowLeft
    case .confirmRecognizedPerson, .confirmUnknownPerson, .confirmSelectedPerson:
      return .checkmarkCircle
    case .rejectRecognizedPerson, .rejectUnknownPerson:
      return .x
    case .selectUnknownPerson:
      return .avatarOff
    }
  }

  nonisolated static func pinnedStreamActions() -> [GlassesDisplayAction] {
    [.stopStream, .openPeople, .previousPage, .nextPage]
  }

  private nonisolated static func shouldPinStreamControls(
    for page: AssistanceDisplayPage,
    isStreamRunning: Bool
  ) -> Bool {
    isStreamRunning
      || page.primaryAction == .stopStream
      || page.secondaryAction == .stopStream
      || page.tertiaryAction == .stopStream
  }

  private static func displayView(
    for page: AssistanceDisplayPage,
    pinsStreamControls: Bool,
    onPrevious: (@Sendable () -> Void)? = nil,
    onNext: (@Sendable () -> Void)? = nil,
    onStop: (@Sendable () -> Void)? = nil,
    onPeople: (@Sendable () -> Void)? = nil,
    onPrimary: (@Sendable () -> Void)? = nil,
    onSecondary: (@Sendable () -> Void)? = nil,
    onTertiary: (@Sendable () -> Void)? = nil
  ) -> FlexBox {
    let visibleCardActions: [(GlassesDisplayAction, (@Sendable () -> Void), MWDATDisplay.ButtonStyle)] = [
      (page.secondaryAction, onSecondary, .secondary),
      (page.tertiaryAction, onTertiary, .secondary),
      (page.primaryAction, onPrimary, .primary)
    ].compactMap { action, handler, style in
      guard let action, let handler else { return nil }
      guard !pinsStreamControls || !action.isPinnedStreamControl else { return nil }
      return (action, handler, style)
    }
    let shouldShowCardActions = !visibleCardActions.isEmpty
      && (
        page.count == 1
          || onNext == nil
          || visibleCardActions.contains { $0.0.isIdentityPromptAction }
          || visibleCardActions.contains { $0.0 == .openContext || $0.0 == .openTranscripts }
      )
    let hasCardActions = !visibleCardActions.isEmpty
    return FlexBox(direction: .column, spacing: 10) {
      FlexBox(direction: .column, spacing: 8) {
        FlexBox(direction: .row, spacing: 8, crossAlignment: .center) {
          MWDATDisplay.Icon(name: Self.displayHeaderIconName(for: page), style: .filled)
          MWDATDisplay.Text("Memento", style: .meta, color: .secondary)
        }
        if let thumbnailImageURI = page.thumbnailImageURI {
          MWDATDisplay.Image(
            uri: thumbnailImageURI,
            sizePreset: page.thumbnailImageSize.datImageSize,
            cornerRadius: .medium
          )
        }
        MWDATDisplay.Text(page.title, style: .heading)
        if page.count > 1 {
          MWDATDisplay.Text("Page \(page.number) of \(page.count)", style: .meta, color: .secondary)
        }
        for index in page.lines.indices {
          let line = page.lines[index]
          if index == 0 {
            MWDATDisplay.Text(line, style: .body)
          } else {
            MWDATDisplay.Text(line, style: .body, color: .secondary)
          }
        }
      }
      .padding(24)
      .background(.card)

      if page.hasControls || pinsStreamControls {
        FlexBox(direction: .row, spacing: 8, alignment: .center, crossAlignment: .center) {
          if shouldShowCardActions && hasCardActions {
            for (action, handler, style) in visibleCardActions {
              MWDATDisplay.Button(
                label: action.buttonTitle,
                style: style,
                iconName: Self.displayIconName(for: action),
                onClick: handler
              )
            }
          } else if !pinsStreamControls {
            if let onPrevious {
              MWDATDisplay.Button(
                label: GlassesDisplayAction.previousPage.buttonTitle,
                style: .secondary,
                iconName: Self.displayIconName(for: .previousPage),
                onClick: onPrevious
              )
            }
            if let onNext {
              MWDATDisplay.Button(
                label: GlassesDisplayAction.nextPage.buttonTitle,
                style: .primary,
                iconName: Self.displayIconName(for: .nextPage),
                onClick: onNext
              )
            }
          }
        }
      }

      if pinsStreamControls {
        FlexBox(direction: .row, spacing: 8, alignment: .center, crossAlignment: .center) {
          if let onStop {
            MWDATDisplay.Button(
              label: GlassesDisplayAction.stopStream.buttonTitle,
              style: .primary,
              iconName: Self.displayIconName(for: .stopStream),
              onClick: onStop
            )
          }
          if let onPeople {
            MWDATDisplay.Button(
              label: GlassesDisplayAction.openPeople.buttonTitle,
              style: .secondary,
              iconName: Self.displayIconName(for: .openPeople),
              onClick: onPeople
            )
          }
          if let onPrevious {
              MWDATDisplay.Button(
                label: GlassesDisplayAction.previousPage.buttonTitle,
                style: .secondary,
                iconName: Self.displayIconName(for: .previousPage),
                onClick: onPrevious
              )
          }
          if let onNext {
              MWDATDisplay.Button(
                label: GlassesDisplayAction.nextPage.buttonTitle,
                style: .secondary,
                iconName: Self.displayIconName(for: .nextPage),
                onClick: onNext
              )
          }
        }
      }
    }
  }

  nonisolated private static func displayHeaderIconName(for page: AssistanceDisplayPage) -> IconName {
    if let action = page.primaryAction ?? page.secondaryAction ?? page.tertiaryAction {
      return displayIconName(for: action)
    }
    return .iCircle
  }

  nonisolated private static func displayCardKey(_ card: AssistanceDisplayCard) -> String {
    let rootImageKeys = [card.thumbnailImageURI]
      .compactMap { uri -> String? in
        let trimmed = uri?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : "\(trimmed):\(card.thumbnailImageSize.rawValue)"
      }
    let sectionImageKeys = card.sections.compactMap { section -> String? in
      let trimmed = section.thumbnailImageURI?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return trimmed.isEmpty ? nil : "\(trimmed):\(section.thumbnailImageSize.rawValue)"
    }
    let imageKeys = (rootImageKeys + sectionImageKeys)
      .filter { !$0.isEmpty }
    return [
      card.text.trimmingCharacters(in: .whitespacesAndNewlines),
      imageKeys.joined(separator: "|")
    ].joined(separator: "\nimage=")
  }

  nonisolated private static func displayPayloadKey(cardKey: String, pageIndex: Int) -> String {
    "\(cardKey)#page=\(pageIndex)"
  }

  nonisolated static func displayPageImageDiagnostics(for card: AssistanceDisplayCard) -> [(title: String, hasImage: Bool)] {
    displayPages(for: card).map { (title: $0.title, hasImage: $0.thumbnailImageURI != nil) }
  }

  nonisolated static func displayPageImageDetailsForTesting(
    for card: AssistanceDisplayCard
  ) -> [(title: String, hasImage: Bool, imageSize: AssistanceDisplayImageSize)] {
    displayPages(for: card).map {
      (title: $0.title, hasImage: $0.thumbnailImageURI != nil, imageSize: $0.thumbnailImageSize)
    }
  }

  nonisolated private static func displayImageDiagnostic(for imageURI: String?) -> String {
    guard let imageURI,
          !imageURI.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return "image=none"
    }
    let trimmed = imageURI.trimmingCharacters(in: .whitespacesAndNewlines)
    let url = URL(string: trimmed)
    let queryBytes = url?.query?.utf8.count ?? 0
    return [
      "image=attached",
      "scheme=\(url?.scheme ?? "none")",
      "host=\(url?.host ?? "none")",
      "pathExt=\(url?.pathExtension.isEmpty == false ? url?.pathExtension ?? "none" : "none")",
      "queryBytes=\(queryBytes)",
      "bytes=\(trimmed.utf8.count)"
    ].joined(separator: " ")
  }

  nonisolated private static func displayPages(for card: AssistanceDisplayCard) -> [AssistanceDisplayPage] {
    let sections: [AssistanceDisplaySection]
    if card.sections.isEmpty {
      sections = [AssistanceDisplaySection(title: card.title, lines: card.lines)]
    } else {
      sections = card.sections
    }

    var pages: [AssistanceDisplayPage] = []
    for section in sections {
      let title = normalizedDisplayText(section.title)
      let lines = section.lines
        .map { normalizedDisplayText($0) }
        .filter { !$0.isEmpty }
        .flatMap { displayChunks(for: $0, maxLength: 220) }
      let chunks = lines.chunked(into: 4)
      let imageURI = section.thumbnailImageURI ?? card.thumbnailImageURI
      let imageSize = section.thumbnailImageURI == nil ? card.thumbnailImageSize : section.thumbnailImageSize
      if chunks.isEmpty {
        pages.append(AssistanceDisplayPage(
          title: title,
          lines: [],
          number: 1,
          count: 1,
          thumbnailImageURI: imageURI,
          thumbnailImageSize: imageSize
        ))
      } else {
        pages.append(contentsOf: chunks.map {
          AssistanceDisplayPage(
            title: title,
            lines: $0,
            number: 1,
            count: 1,
            thumbnailImageURI: imageURI,
            thumbnailImageSize: imageSize
          )
        })
      }
    }

    let count = max(pages.count, 1)
    return pages.enumerated().map { index, page in
      AssistanceDisplayPage(
        title: page.title,
        lines: page.lines,
        number: index + 1,
        count: count,
        thumbnailImageURI: page.thumbnailImageURI,
        thumbnailImageSize: page.thumbnailImageSize,
        primaryAction: card.primaryAction,
        secondaryAction: card.secondaryAction,
        tertiaryAction: card.tertiaryAction
      )
    }
  }

  nonisolated private static func normalizedDisplayText(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\n", with: " ")
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  nonisolated private static func displayChunks(for value: String, maxLength: Int) -> [String] {
    let normalized = normalizedDisplayText(value)
    guard normalized.count > maxLength else { return normalized.isEmpty ? [] : [normalized] }

    var chunks: [String] = []
    var current = ""

    for word in normalized.split(separator: " ") {
      let wordText = String(word)
      if wordText.count > maxLength {
        if !current.isEmpty {
          chunks.append(current)
          current = ""
        }
        chunks.append(contentsOf: splitLongDisplayWord(wordText, maxLength: maxLength))
        continue
      }

      let candidate = current.isEmpty ? wordText : "\(current) \(wordText)"
      if candidate.count > maxLength {
        if !current.isEmpty {
          chunks.append(current)
        }
        current = wordText
      } else {
        current = candidate
      }
    }

    if !current.isEmpty {
      chunks.append(current)
    }

    return chunks
  }

  nonisolated private static func splitLongDisplayWord(_ value: String, maxLength: Int) -> [String] {
    var chunks: [String] = []
    var start = value.startIndex
    while start < value.endIndex {
      let end = value.index(start, offsetBy: maxLength, limitedBy: value.endIndex) ?? value.endIndex
      chunks.append(String(value[start..<end]))
      start = end
    }
    return chunks
  }

  private var isDATAppModelEnabled: Bool {
    let mwdat = Bundle.main.object(forInfoDictionaryKey: "MWDAT") as? [String: Any]
    return (mwdat?["DAMEnabled"] as? Bool) == true
  }

  func handleOpenURL(_ url: URL) async {
    lastOpenURLText = url.absoluteString
    AppLogger.log(.registration, "onOpenURL received: \(url.absoluteString)")
    ensureConfigured()
    guard isConfigured else { return }
    do {
      let handled = try await Wearables.shared.handleUrl(url)
      lastHandleURLResultText = "success handled=\(handled)"
      AppLogger.log(.registration, "DAT callback URL handled=\(handled)")
      isWaitingForMetaAIReturn = false
      cancelRegistrationHandoffTimeout()
      applyRegistrationState(Wearables.shared.registrationState)
      await resumeAfterExternalAppReturn()
    } catch {
      let detail = detailedErrorDescription(error)
      lastHandleURLResultText = "failed \(detail)"
      cancelRegistrationHandoffTimeout()
      AppLogger.log(.registration, "DAT handleUrl failed for \(url.absoluteString): \(detail)")
      emitError("Registration callback failed: \(detail)")
    }
    updateStartReadinessReason()
  }

  func unregisterDATApp() async {
    ensureConfigured()
    guard let wearables = wearables, isConfigured, !isSimulator else {
      emitUnavailable()
      return
    }

    do {
      await detachAssistanceDisplay(reason: "unregisterDATApp")
      AppLogger.log(.registration, "Calling startUnregistration for Developer Mode one-app-rule recovery")
      try await wearables.startUnregistration()
      applyRegistrationState(wearables.registrationState)
      deviceTask?.cancel()
      deviceTask = nil
      activeDeviceTask?.cancel()
      activeDeviceTask = nil
      devicesStreamActive = false
      deviceCount = 0
      hasActiveDevice = false
      selectedDeviceIDText = "None"
      selectedDeviceCompatibilityText = "unknown"
      selectedDeviceLinkStateText = "unknown"
      selectedDeviceIsCompatible = false
      deviceSession = nil
      activeDeviceSessionDeviceId = nil
      isDeviceSessionReady = false
      connectionStageText = DATConnectionStage.registrationAvailable.rawValue
      lastDATErrorText = "DAT app unregistered. Tap Connect my glasses to register again."
      updateStartReadinessReason()
    } catch {
      let detail = detailedErrorDescription(error)
      emitError("Unregistration failed: \(detail)")
    }
  }

  func resetDeviceSession() async {
    AppLogger.log(.devices, "Stop/Reset Session requested by user")
    await stopStream(reason: "resetDeviceSession")
    await detachAssistanceDisplay(reason: "resetDeviceSession")
    if let session = deviceSession {
      AppLogger.log(.devices, "Stopping DeviceSession for reset. deviceId=\(session.deviceId), state=\(session.state)")
      session.stop()
    } else {
      AppLogger.log(.devices, "No local DeviceSession exists to stop during reset; clearing local state only")
    }
    deviceSession = nil
    activeDeviceSessionDeviceId = nil
    isDeviceSessionReady = false
    deviceSessionStateText = "None"
    runtimeSessionStateText = "StateStream only"
    deviceSessionStateTask?.cancel()
    deviceSessionStateTask = nil
    lastDATErrorText = "DeviceSession reset. Keep glasses open/worn and connected in Meta AI, then tap Connect my glasses."
    updateStartReadinessReason()
  }

  private func releaseLocalDeviceSession(reason: String) {
    AppLogger.log(.devices, "Releasing local DeviceSession reference reason=\(reason), deviceId=\(activeDeviceSessionDeviceId ?? "nil"), state=\(deviceSession.map { "\($0.state)" } ?? "nil")")
    if display != nil {
      if isDisplaySDKInteractionAllowed {
        releaseLocalDisplayReference(reason: "releaseLocalDeviceSession-\(reason)")
      } else {
        finalizeDisplaySDKTeardown(reason: "releaseLocalDeviceSession-\(reason)")
      }
    }
    deviceSession = nil
    activeDeviceSessionDeviceId = nil
    isDeviceSessionReady = false
    deviceSessionStateText = "None"
    runtimeSessionStateText = "StateStream only"
    deviceSessionStateTask?.cancel()
    deviceSessionStateTask = nil
  }

  @discardableResult
  func prepareDeviceSession(reason: String) async -> DeviceSession? {
    AppLogger.log(.devices, "Preparing DeviceSession reason=\(reason), deviceCount=\(deviceCount), activeDevice=\(deviceSelector?.activeDevice ?? "nil")")
    do {
      let session = try await getDeviceSession(reason: reason)
      isDeviceSessionReady = true
      deviceSessionStateText = "\(session.state)"
      connectionStageText = DATConnectionStage.deviceSessionReady.rawValue
      AppLogger.log(.devices, "DeviceSession ready for deviceId=\(session.deviceId), state=\(session.state)")
      updateStartReadinessReason()
      return session
    } catch {
      isDeviceSessionReady = false
      let detail = detailedErrorDescription(error)
      AppLogger.log(.devices, "DeviceSession failed detail: \(detail)")
      emitError("DeviceSession failed: \(error.localizedDescription)")
      updateStartReadinessReason()
      return nil
    }
  }

  private func getDeviceSession(reason: String) async throws(DeviceSessionError) -> DeviceSession {
    if let existing = deviceSession, existing.state == .started {
      isDeviceSessionReady = true
      activeDeviceSessionDeviceId = existing.deviceId
      selectedDeviceIDText = existing.deviceId
      deviceSessionStateText = "\(existing.state)"
      AppLogger.log(.devices, "Reusing started DeviceSession deviceId=\(existing.deviceId), reason=\(reason)")
      return existing
    }

    if deviceSession?.state == .stopped {
      releaseLocalDeviceSession(reason: "existing-stopped-before-\(reason)")
    }

    if let existing = deviceSession {
      if existing.state == .started {
        isDeviceSessionReady = true
        startDeviceSessionStateObserver(for: existing)
        return existing
      }
      AppLogger.log(.devices, "Waiting for existing DeviceSession to reach started. deviceId=\(existing.deviceId), state=\(existing.state), reason=\(reason)")
      try await waitForDeviceSessionStart(
        stateStream: existing.stateStream(),
        errorStream: existing.errorStream()
      )
      isDeviceSessionReady = true
      activeDeviceSessionDeviceId = existing.deviceId
      selectedDeviceIDText = existing.deviceId
      deviceSessionStateText = "\(existing.state)"
      startDeviceSessionStateObserver(for: existing)
      return existing
    }

    guard let wearables, let deviceSelector else {
      throw .unexpectedError(description: "Wearables SDK or AutoDeviceSelector is unavailable")
    }

    do {
      AppLogger.log(.devices, "DeviceSession creation attempted, reason=\(reason), activeDevice=\(deviceSelector.activeDevice ?? "nil")")
      let session = try wearables.createSession(deviceSelector: deviceSelector)
      deviceSession = session
      activeDeviceSessionDeviceId = session.deviceId
      selectedDeviceIDText = session.deviceId
      runtimeSessionStateText = "StateStream only"
      AppLogger.log(.devices, "Using DeviceSession.stateStream() and errorStream() for sample-aligned startup lifecycle. deviceId=\(session.deviceId)")

      let stateStream = session.stateStream()
      let errorStream = session.errorStream()
      try session.start()
      deviceSessionStateText = "\(session.state)"
      AppLogger.log(.devices, "DeviceSession.start() called for deviceId=\(session.deviceId), initialState=\(session.state)")

      if session.state == .started {
        isDeviceSessionReady = true
        startDeviceSessionStateObserver(for: session)
        return session
      }

      try await waitForDeviceSessionStart(stateStream: stateStream, errorStream: errorStream)
      isDeviceSessionReady = true
      activeDeviceSessionDeviceId = session.deviceId
      selectedDeviceIDText = session.deviceId
      deviceSessionStateText = "\(session.state)"
      startDeviceSessionStateObserver(for: session)
      return session
    } catch {
      isDeviceSessionReady = false
      deviceSession = nil
      activeDeviceSessionDeviceId = nil
      throw error
    }
  }

  private func waitForDeviceSessionStart(
    stateStream: AsyncStream<DeviceSessionState>,
    errorStream: AsyncStream<DeviceSessionError>
  ) async throws(DeviceSessionError) {
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          for await state in stateStream {
            AppLogger.log(.devices, "DeviceSession startup state observed: \(state)")
            if state == .started {
              return
            }
            if state == .stopped {
              throw DeviceSessionError.unexpectedError(description: "DeviceSession stopped before reaching started")
            }
          }
          guard !Task.isCancelled else {
            return
          }
          throw DeviceSessionError.unexpectedError(description: "The session failed to start")
        }

        group.addTask {
          for await error in errorStream {
            AppLogger.log(.devices, "DeviceSession startup error observed: \(String(reflecting: error))")
            throw error
          }
          guard !Task.isCancelled else {
            return
          }
          throw DeviceSessionError.unexpectedError(description: "The session failed to start")
        }

        guard try await group.next() != nil else {
          throw DeviceSessionError.unexpectedError(description: "The session failed to start")
        }
        group.cancelAll()
      }
    } catch let error as DeviceSessionError {
      throw error
    } catch {
      throw .unexpectedError(description: error.localizedDescription)
    }
  }

  private func observeRegistration(wearables: WearablesInterface) {
    registrationTask?.cancel()
    registrationTask = Task { [weak self] in
      for await state in wearables.registrationStateStream() {
        guard let self else { return }
        self.applyRegistrationState(state)
        AppLogger.log(.registration, "Registration state changed: \(state)")
        self.updateStartReadinessReason()
        if state == .registered && (self.isWaitingForMetaAIReturn || self.didStartRegistrationHandoff) {
          self.isWaitingForMetaAIReturn = false
          self.cancelRegistrationHandoffTimeout()
          await self.continueAfterRegistration(reason: "registration-state-registered")
        } else if state == .registered {
          self.restartDiscovery(reason: "registration-state-registered-observed")
          self.refreshCurrentDevices(reason: "registration-state-registered-observed")
          AppLogger.log(.registration, "Registration stream is registered; observing active device and waiting for Start streaming before preparing DeviceSession.")
        } else if state == .available,
                  self.isWaitingForMetaAIReturn,
                  self.didStartRegistrationHandoff,
                  self.didObserveRegisteringDuringCurrentHandoff {
          self.cancelRegistrationHandoffTimeout()
          let message = self.metaAIHandoffFailureMessage(prefix: "Meta AI registration handoff returned to available without registering.")
          self.isWaitingForMetaAIReturn = false
          self.registrationHandoffDiagnosticText = message
          self.lastDATErrorText = message
          AppLogger.log(.registration, message)
          self.onError?(message)
        }
      }
    }
  }

  private func continueAfterRegistration(reason: String) async {
    guard let wearables else { return }
    applyRegistrationState(wearables.registrationState)
    guard wearables.registrationState == .registered else {
      AppLogger.log(.registration, "Cannot continue after registration because state=\(wearables.registrationState), reason=\(reason)")
      updateStartReadinessReason()
      return
    }

    restartDiscovery(reason: "registered-\(reason)")
    refreshCurrentDevices(reason: "registered-\(reason)")
    scheduleNoDevicesTimeout(reason: "registered-\(reason)")
    connectionStageText = DATConnectionStage.streamReady.rawValue
    updateStartReadinessReason()
  }

  private func observeDevices(wearables: WearablesInterface, reason: String) {
    let canceledPrevious = deviceTask != nil && deviceTask?.isCancelled == false
    deviceTask?.cancel()
    devicesStreamListenerId += 1
    let listenerId = devicesStreamListenerId
    devicesStreamActive = true
    connectionStageText = DATConnectionStage.discoveringDevices.rawValue
    AppLogger.log(.devices, "devicesStream start listenerId=\(listenerId) reason=\(reason) canceledPrevious=\(canceledPrevious)")
    updateStartReadinessReason()
    deviceTask = Task { [weak self] in
      for await devices in wearables.devicesStream() {
        guard let self else { return }
        guard !Task.isCancelled else { return }
        self.applyDevices(devices, reason: "devicesStream")
      }
      guard let self else { return }
      if self.devicesStreamListenerId == listenerId {
        self.devicesStreamActive = false
        AppLogger.log(.devices, "devicesStream ended listenerId=\(listenerId)")
      }
    }
  }

  private func observeActiveDevice() {
    activeDeviceTask?.cancel()
    guard let deviceSelector else { return }
    activeDeviceTask = Task { [weak self] in
      for await device in deviceSelector.activeDeviceStream() {
        guard let self else { return }
        self.hasActiveDevice = device != nil
        if let device {
          self.selectedDeviceIDText = "\(device)"
          AppLogger.log(.devices, "Active DAT device selected: \(device)")
          self.refreshSelectedDeviceDiagnostics(deviceId: device)
        } else {
          self.selectedDeviceIDText = "None"
          if self.deviceCount > 0 {
            self.selectedDeviceCompatibilityText = "AutoDeviceSelector pending"
            self.selectedDeviceLinkStateText = "AutoDeviceSelector pending"
          } else {
            self.selectedDeviceCompatibilityText = "unknown"
            self.selectedDeviceLinkStateText = "unknown"
          }
          self.selectedDeviceIsCompatible = false
          AppLogger.log(.devices, "No active DAT device selected")
        }
        self.updateStartReadinessReason()
      }
    }
  }

  private func startDeviceSessionStateObserver(for session: DeviceSession) {
    deviceSessionStateTask?.cancel()
    deviceSessionStateTask = Task { [weak self] in
      for await state in session.stateStream() {
        guard let self else { return }
        self.deviceSessionStateText = "\(state)"
        self.isDeviceSessionReady = state == .started
        AppLogger.log(.devices, "DeviceSession state observed: \(state)")
        if state == .started {
          self.clearTeardownRetainedDATReferences(reason: "deviceSessionStarted")
          self.activeDeviceSessionDeviceId = session.deviceId
        } else if state == .stopping {
          self.disableStreamFrameCallbacks(
            reason: "deviceSessionStopping",
            preserveListenerTokenForSDKTeardown: true
          )
          self.releaseLocalDisplayReference(
            reason: "deviceSessionStopping",
            preserveSDKReferencesForTeardown: true
          )
        } else if state == .stopped {
          self.releaseLocalStreamReference(
            reason: "deviceSessionStopped",
            stateText: "STOPPED",
            isUnexpected: true,
            preserveSDKReferencesForTeardown: true
          )
          self.finalizeDisplaySDKTeardown(reason: "deviceSessionStopped")
          self.isDeviceSessionReady = false
          self.deviceSession = nil
          self.activeDeviceSessionDeviceId = nil
          self.deviceSessionStateTask = nil
          self.updateStartReadinessReason()
          return
        }
        self.updateStartReadinessReason()
      }
    }
  }

  private func setupStreamListeners(for stream: MWDATCamera.Stream) {
    let callbackGeneration = streamCallbackGate.beginStream(stateText: streamSessionStateText)
    stateListenerToken = stream.statePublisher.listen { [weak self] state in
      Task { @MainActor in
        self?.handleStreamState(state)
      }
    }
    let appFrameDeliveryGate = appFrameDeliveryGate
    frameListenerToken = stream.videoFramePublisher.listen { [weak self, appFrameDeliveryGate, callbackGeneration] frame in
      let receivedAtNanos = DispatchTime.now().uptimeNanoseconds
      guard appFrameDeliveryGate.shouldDeliver() else { return }
      guard let self else { return }
      guard self.shouldAcceptStreamCallback(generation: callbackGeneration) else { return }
      var extraction = Self.extractVideoFrame(frame)
      extraction.receivedAtNanos = receivedAtNanos
      Task { @MainActor in
        guard self.shouldAcceptStreamCallback(generation: callbackGeneration) else { return }
        self.handleVideoFrame(extraction)
      }
    }
    errorListenerToken = stream.errorPublisher.listen { [weak self] error in
      Task { @MainActor in
        self?.handleStreamError(error)
      }
    }
  }

  private func clearStreamListeners(preserveForSDKTeardown reason: String? = nil) {
    if let reason {
      var retainedCount = 0
      if let stateListenerToken {
        teardownRetainedListenerTokens.append(stateListenerToken)
        retainedCount += 1
      }
      if let frameListenerToken {
        teardownRetainedListenerTokens.append(frameListenerToken)
        retainedCount += 1
      }
      if let errorListenerToken {
        teardownRetainedListenerTokens.append(errorListenerToken)
        retainedCount += 1
      }
      if retainedCount > 0 {
        AppLogger.log(.stream, "Retained DAT stream listener tokens through SDK teardown reason=\(reason), count=\(retainedCount)")
      }
    }
    stateListenerToken = nil
    frameListenerToken = nil
    errorListenerToken = nil
  }

  private func disableStreamFrameCallbacks(
    reason: String,
    preserveListenerTokenForSDKTeardown: Bool = false
  ) {
    guard frameListenerToken != nil else { return }
    streamCallbackGate.disableFrames(stateText: streamSessionStateText)
    if preserveListenerTokenForSDKTeardown, let frameListenerToken {
      teardownRetainedListenerTokens.append(frameListenerToken)
      AppLogger.log(.stream, "Retained DAT frame listener token through SDK teardown reason=\(reason)")
    }
    frameListenerToken = nil
    appFrameDeliveryGate.reset()
    AppLogger.log(.stream, "warning...---- Disabled DAT video frame callbacks reason=\(reason), streamState=\(streamSessionStateText), deviceSession=\(deviceSessionStateText)")
  }

  private func releaseLocalStreamReference(
    reason: String,
    stateText: String? = nil,
    isUnexpected: Bool = false,
    preserveSDKReferencesForTeardown: Bool = false
  ) {
    let hadLocalStreamState = streamSession != nil
      || stateListenerToken != nil
      || frameListenerToken != nil
      || errorListenerToken != nil
      || isStreamRunning
    streamCallbackGate.release(stateText: stateText ?? streamSessionStateText)
    if preserveSDKReferencesForTeardown, let streamSession {
      teardownRetainedStreams.append(streamSession)
      AppLogger.log(.stream, "Retained DAT Stream reference through SDK teardown reason=\(reason)")
    }
    clearStreamListeners(preserveForSDKTeardown: preserveSDKReferencesForTeardown ? reason : nil)
    streamSession = nil
    isStreamRunning = false
    streamReachedStreaming = false
    cancelNoVideoFramesWatchdog()
    appFrameDeliveryGate.reset()
    if let stateText {
      streamSessionStateText = stateText
    }
    guard hadLocalStreamState else { return }
    let prefix = isUnexpected ? "warning...---- " : ""
    AppLogger.log(.stream, "\(prefix)Released local DAT Stream reference reason=\(reason), streamState=\(streamSessionStateText), deviceSession=\(deviceSessionStateText)")
  }

  private func clearTeardownRetainedDATReferences(reason: String) {
    let listenerCount = teardownRetainedListenerTokens.count
    let streamCount = teardownRetainedStreams.count
    let displayCount = teardownRetainedDisplays.count
    guard listenerCount > 0 || streamCount > 0 || displayCount > 0 else { return }
    teardownRetainedListenerTokens.removeAll()
    teardownRetainedStreams.removeAll()
    teardownRetainedDisplays.removeAll()
    AppLogger.log(.devices, "Cleared retained DAT teardown references reason=\(reason), listenerTokens=\(listenerCount), streams=\(streamCount), displays=\(displayCount)")
  }

  nonisolated private func shouldAcceptStreamCallback(generation: UInt64) -> Bool {
    streamCallbackGate.shouldAccept(generation: generation)
  }

  nonisolated static func shouldAcceptStreamCallback(
    callbackGeneration: UInt64,
    currentGeneration: UInt64,
    hasStream: Bool,
    stateText: String
  ) -> Bool {
    guard callbackGeneration == currentGeneration, hasStream else { return false }
    let normalizedState = stateText.lowercased()
    return !normalizedState.contains("stopping") && !normalizedState.contains("stopped")
  }

  nonisolated private static func extractVideoFrame(_ frame: VideoFrame) -> DATFrameExtraction {
    let frameType = String(describing: type(of: frame))
    let pixelBuffer = copyPixelBuffer(from: frame.sampleBuffer)
    let image = autoreleasepool {
      frame.makeUIImage()
    }
    if pixelBuffer != nil {
      return DATFrameExtraction(
        frameType: frameType,
        pixelBuffer: pixelBuffer,
        image: image,
        errorText: image == nil ? "makeUIImage returned nil for \(frameType)" : nil
      )
    }
    guard let image else {
      return DATFrameExtraction(
        frameType: frameType,
        pixelBuffer: nil,
        image: nil,
        errorText: "sampleBuffer image buffer unavailable and makeUIImage returned nil for \(frameType)"
      )
    }
    return DATFrameExtraction(
      frameType: frameType,
      pixelBuffer: nil,
      image: image,
      errorText: "sampleBuffer image buffer unavailable for \(frameType)"
    )
  }

  nonisolated private static func copyPixelBuffer(from sampleBuffer: CMSampleBuffer) -> CVPixelBuffer? {
    guard let source = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
    let width = CVPixelBufferGetWidth(source)
    let height = CVPixelBufferGetHeight(source)
    guard width > 0, height > 0 else { return nil }

    var copied: CVPixelBuffer?
    let attributes: [CFString: Any] = [
      kCVPixelBufferCGImageCompatibilityKey: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey: true,
      kCVPixelBufferIOSurfacePropertiesKey: [:]
    ]
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      width,
      height,
      CVPixelBufferGetPixelFormatType(source),
      attributes as CFDictionary,
      &copied
    )
    guard status == kCVReturnSuccess, let copied else { return nil }

    CVPixelBufferLockBaseAddress(source, .readOnly)
    CVPixelBufferLockBaseAddress(copied, [])
    defer {
      CVPixelBufferUnlockBaseAddress(copied, [])
      CVPixelBufferUnlockBaseAddress(source, .readOnly)
    }

    if CVPixelBufferIsPlanar(source) {
      guard CVPixelBufferGetPlaneCount(source) == CVPixelBufferGetPlaneCount(copied) else { return nil }
      for plane in 0..<CVPixelBufferGetPlaneCount(source) {
        guard
          let sourceBase = CVPixelBufferGetBaseAddressOfPlane(source, plane),
          let copiedBase = CVPixelBufferGetBaseAddressOfPlane(copied, plane)
        else { return nil }
        let rowBytes = min(
          CVPixelBufferGetBytesPerRowOfPlane(source, plane),
          CVPixelBufferGetBytesPerRowOfPlane(copied, plane)
        )
        let rows = min(
          CVPixelBufferGetHeightOfPlane(source, plane),
          CVPixelBufferGetHeightOfPlane(copied, plane)
        )
        let sourceBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
        let copiedBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(copied, plane)
        for row in 0..<rows {
          copiedBase
            .advanced(by: row * copiedBytesPerRow)
            .copyMemory(from: sourceBase.advanced(by: row * sourceBytesPerRow), byteCount: rowBytes)
        }
      }
    } else {
      guard
        let sourceBase = CVPixelBufferGetBaseAddress(source),
        let copiedBase = CVPixelBufferGetBaseAddress(copied)
      else { return nil }
      let rowBytes = min(CVPixelBufferGetBytesPerRow(source), CVPixelBufferGetBytesPerRow(copied))
      let rows = min(CVPixelBufferGetHeight(source), CVPixelBufferGetHeight(copied))
      let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(source)
      let copiedBytesPerRow = CVPixelBufferGetBytesPerRow(copied)
      for row in 0..<rows {
        copiedBase
          .advanced(by: row * copiedBytesPerRow)
          .copyMemory(from: sourceBase.advanced(by: row * sourceBytesPerRow), byteCount: rowBytes)
      }
    }

    return copied
  }

  private func handleVideoFrame(_ extraction: DATFrameExtraction) {
    totalFramesReceived += 1
    cancelNoVideoFramesWatchdog()
    let latencyMs = extraction.receivedAtNanos == 0
      ? nil
      : Double(DispatchTime.now().uptimeNanoseconds &- extraction.receivedAtNanos) / 1_000_000.0
    recordAppDeliveredFrameForFPS(
      converted: extraction.pixelBuffer != nil || extraction.image != nil,
      processingLatencyMs: latencyMs
    )
    let frameNumber = totalFramesReceived
    let timestamp = Self.timestampText()
    let shouldPublishDiagnostics = frameNumber <= 3 || frameNumber % 30 == 0
    if shouldPublishDiagnostics {
      framesReceived = totalFramesReceived
      lastFrameTimestampText = timestamp
    }

    guard extraction.pixelBuffer != nil || extraction.image != nil else {
      totalFrameConversionFailures += 1
      if shouldPublishDiagnostics {
        frameConversionFailures = totalFrameConversionFailures
      }
      lastFrameErrorText = extraction.errorText ?? "makeUIImage returned nil for \(extraction.frameType)"
      lastDATErrorText = "DAT video frame could not be converted for display"
      AppLogger.log(
        .frames,
        "Video frame received count=\(frameNumber), type=\(extraction.frameType), makeUIImage=failed, timestamp=\(timestamp), selectedForApp=false, selectedForVision=false, error=\(lastFrameErrorText)"
      )
      updateStartReadinessReason()
      return
    }

    if extraction.pixelBuffer != nil {
      totalFramesWithPixelBuffer += 1
    }
    let pixelWidth: Int
    let pixelHeight: Int
    if let pixelBuffer = extraction.pixelBuffer {
      pixelWidth = CVPixelBufferGetWidth(pixelBuffer)
      pixelHeight = CVPixelBufferGetHeight(pixelBuffer)
    } else if let image = extraction.image {
      pixelWidth = Int(image.size.width * image.scale)
      pixelHeight = Int(image.size.height * image.scale)
    } else {
      pixelWidth = 0
      pixelHeight = 0
    }
    if shouldPublishDiagnostics {
      framesWithPixelBuffer = totalFramesWithPixelBuffer
      lastFrameWidthText = "\(pixelWidth)"
      lastFrameHeightText = "\(pixelHeight)"
      lastFrameErrorText = extraction.pixelBuffer == nil
        ? (extraction.errorText ?? "sampleBuffer image buffer unavailable")
        : "none"
    }
    if !firstFrameSeen {
      firstFrameSeen = true
      framesReceived = totalFramesReceived
      framesWithPixelBuffer = totalFramesWithPixelBuffer
      firstFrameTimestampText = timestamp
      AppLogger.log(.frames, "First DAT video frame received at \(timestamp)")
    }

    if frameNumber <= 5 || frameNumber % 120 == 0 {
      AppLogger.log(
        .frameSource,
        "frame=\(frameNumber) hasPixelBuffer=\(extraction.pixelBuffer != nil) hasUIImage=\(extraction.image != nil) preferred=\(extraction.pixelBuffer == nil ? "UIImage" : "CVPixelBuffer") reason=sampledAndCopiedInsideDATCallback width=\(pixelWidth) height=\(pixelHeight) orientation=up mirrored=false"
      )
    }
    if let pixelBuffer = extraction.pixelBuffer {
      onFramePixelBuffer?(pixelBuffer, extraction.image)
    } else if let image = extraction.image {
      onFrameImage?(image)
    }
  }

  // Rolling app-delivered FPS. Frames arrive here only after the delivery gate,
  // so this is the throughput the recognition pipeline actually sees. Compare
  // against the DAT SDK's recv/dec fps lines: if SDK recv fps is healthy but
  // this is near zero, frames are being dropped in app processing; if both are
  // low, the bottleneck is SDK delivery or the glasses link, not the app.
  private func recordAppDeliveredFrameForFPS(converted: Bool, processingLatencyMs: Double?) {
    let now = Date()
    if fpsWindowStartedAt == nil {
      fpsWindowStartedAt = now
      fpsWindowFrameCount = 0
      fpsWindowConversionFailures = 0
      fpsWindowLatencySumMs = 0
      fpsWindowLatencyMaxMs = 0
      fpsWindowLatencySamples = 0
    }
    fpsWindowFrameCount += 1
    if !converted { fpsWindowConversionFailures += 1 }
    if let processingLatencyMs {
      fpsWindowLatencySumMs += processingLatencyMs
      fpsWindowLatencyMaxMs = max(fpsWindowLatencyMaxMs, processingLatencyMs)
      fpsWindowLatencySamples += 1
    }
    guard let start = fpsWindowStartedAt else { return }
    let elapsed = now.timeIntervalSince(start)
    guard elapsed >= 2.0 else { return }
    let deliveredFPS = Double(fpsWindowFrameCount) / elapsed
    let conversionFailures = fpsWindowConversionFailures
    // Pull SDK-arrival vs gate-dropped counts so a slow stream can be attributed:
    //   arrivedFPS ≈ SDK delivery rate, deliveredFPS = app throughput,
    //   droppedFrames = frames intentionally rate-limited by the app gate.
    let gate = appFrameDeliveryGate.pullWindowCounts()
    let arrivedFPS = Double(gate.arrived) / elapsed
    let avgLatencyMs = fpsWindowLatencySamples > 0 ? fpsWindowLatencySumMs / Double(fpsWindowLatencySamples) : 0
    AppLogger.log(
      .frames,
      "DAT app frame health appDeliveredFPS=\(String(format: "%.1f", deliveredFPS)) sdkArrivedFPS=\(String(format: "%.1f", arrivedFPS)) deliveredFrames=\(fpsWindowFrameCount) sdkArrivedFrames=\(gate.arrived) droppedByAppGate=\(gate.dropped) conversionFailures=\(conversionFailures) procLatencyAvgMs=\(String(format: "%.1f", avgLatencyMs)) procLatencyMaxMs=\(String(format: "%.1f", fpsWindowLatencyMaxMs)) windowSeconds=\(String(format: "%.1f", elapsed)) totalReceived=\(totalFramesReceived) note=sdkArrivedFPS is raw SDK delivery; appDeliveredFPS is post-gate app throughput; droppedByAppGate are intentional rate-limit drops not link loss. If sdkArrivedFPS is also low the bottleneck is SDK delivery/glasses link/network, not the app. procLatency is SDK-callback→app-handoff time. dec fps=0 in SDK stats is expected for raw/undecoded frame delivery and is not a fault."
    )
    fpsWindowStartedAt = now
    fpsWindowFrameCount = 0
    fpsWindowConversionFailures = 0
    fpsWindowLatencySumMs = 0
    fpsWindowLatencyMaxMs = 0
    fpsWindowLatencySamples = 0
  }

  private func resetFrameDiagnostics() {
    appFrameDeliveryGate.reset()
    fpsWindowStartedAt = nil
    fpsWindowFrameCount = 0
    fpsWindowConversionFailures = 0
    fpsWindowLatencySumMs = 0
    fpsWindowLatencyMaxMs = 0
    fpsWindowLatencySamples = 0
    totalFramesReceived = 0
    totalFramesWithPixelBuffer = 0
    totalFrameConversionFailures = 0
    framesReceived = 0
    framesWithPixelBuffer = 0
    frameConversionFailures = 0
    firstFrameTimestampText = "none"
    lastFrameWidthText = "none"
    lastFrameHeightText = "none"
    lastFrameTimestampText = "none"
    lastFrameErrorText = "none"
    lastDATErrorText = "None"
  }

  private func scheduleNoVideoFramesWatchdog() {
    noVideoFramesWatchdogGeneration &+= 1
    let generation = noVideoFramesWatchdogGeneration
    noVideoFramesWatchdogTask?.cancel()
    noVideoFramesWatchdogTask = Task { @MainActor [weak self] in
      let delay = Self.noVideoFramesWarningDelaySeconds
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      guard let self, !Task.isCancelled else { return }
      guard self.noVideoFramesWatchdogGeneration == generation else { return }
      guard self.isStreamRunning || self.streamSessionStateText.lowercased().contains("streaming") else { return }
      guard self.totalFramesReceived == 0 else { return }

      let message = Self.noVideoFramesDiagnosticMessage(
        elapsedSeconds: delay,
        streamState: self.streamSessionStateText,
        deviceSessionState: self.deviceSessionStateText
      )
      self.lastDATErrorText = message
      AppLogger.log(.stream, "warning...---- \(message)")
      AppLogger.log(
        .frames,
        "warning...---- DAT zero-frame stream; videoFramePublisher has not delivered any frames after streaming. recognitionBlocked=true profilesLoaded=notChecked faceDetectionCount=0 cropDimensions=none embeddingDimension=none top1=none top2=none thresholdDecision=notEvaluated"
      )
      self.updateStartReadinessReason()
    }
  }

  private func cancelNoVideoFramesWatchdog() {
    noVideoFramesWatchdogGeneration &+= 1
    noVideoFramesWatchdogTask?.cancel()
    noVideoFramesWatchdogTask = nil
  }

  private func handleStreamState(_ state: StreamState) {
    let stateText = "\(state)"
    streamSessionStateText = stateText
    streamCallbackGate.updateStateText(stateText)
    isStreamRunning = state == .streaming
    if state == .streaming {
      streamReachedStreaming = true
      connectionStageText = DATConnectionStage.streaming.rawValue
      scheduleNoVideoFramesWatchdog()
    } else if state == .stopped && connectionStageText == DATConnectionStage.streaming.rawValue {
      connectionStageText = DATConnectionStage.streamReady.rawValue
      cancelNoVideoFramesWatchdog()
    } else if state != .streaming {
      cancelNoVideoFramesWatchdog()
    }
    if stateText != lastLoggedStreamStateText {
      lastLoggedStreamStateText = stateText
      AppLogger.log(.stream, "Stream state: \(state)")
    }
    if stateText.lowercased().contains("stopping") {
      disableStreamFrameCallbacks(
        reason: "streamStateStopping",
        preserveListenerTokenForSDKTeardown: true
      )
    }
    if state == .stopped, streamReachedStreaming, totalFramesReceived == 0 {
      lastDATErrorText = "DAT stream reached streaming but delivered no video frames before stopping. This matches FrameStallDetectorServiceError; keep the glasses awake/worn and retry Start streaming."
      AppLogger.log(.stream, lastDATErrorText)
    }
    if state == .stopped {
      let wasUnexpectedTerminalState = streamReachedStreaming
      releaseLocalStreamReference(
        reason: "streamStateStopped",
        stateText: stateText,
        isUnexpected: wasUnexpectedTerminalState,
        preserveSDKReferencesForTeardown: wasUnexpectedTerminalState
      )
    }
    updateStartReadinessReason()
  }

  private func handleStreamError(_ error: StreamError) {
    let message = formatStreamError(error)
    emitError(message)
  }

  private func emitUnavailable() {
    #if targetEnvironment(simulator)
    emitError("Real Meta glasses connection requires a physical iPhone. Use Mock Device Kit mode on simulator.")
    #else
    emitError("DAT SDK is unavailable. \(sdkStatusText)")
    #endif
  }

  private func emitError(_ message: String) {
    lastDATErrorText = message
    AppLogger.log(.stream, message)
    onError?(message)
    updateStartReadinessReason()
  }

  func refreshRuntimeConfigurationSnapshot(reason: String) {
    let bundle = Bundle.main
    let bundleID = bundle.bundleIdentifier ?? "nil"
    let mwdat = bundle.object(forInfoDictionaryKey: "MWDAT") as? [String: Any]
    let metaAppID = stringValue(mwdat?["MetaAppID"])
    let appLinkURLScheme = stringValue(mwdat?["AppLinkURLScheme"])
    let clientToken = stringValue(mwdat?["ClientToken"])
    let hasClientToken = !clientToken.isEmpty
    let hasTeamID = !stringValue(mwdat?["TeamID"]).isEmpty
    let damEnabled = (mwdat?["DAMEnabled"] as? Bool) == true
    let mwdatKeys = mwdat?.keys.sorted().joined(separator: ",") ?? "none"
    let urlTypeSummaries = bundleURLTypeSummaries()
    let schemes = bundleURLSchemes()
    let hasCameraAccessScheme = schemes.contains("cameraaccess")
    let associatedDomains = associatedDomainsEntitlement()
    let devModeFlag = UserDefaults.standard.bool(forKey: "com.meta.wearable.dat.isDevMode")

    runtimeBundleConfigurationText = "bundleID=\(bundleID) | hasMWDAT=\(mwdat != nil ? "yes" : "no") | keys=\(mwdatKeys) | MetaAppID=\(metaAppID.isEmpty ? "nil" : metaAppID) | AppLinkURLScheme=\(appLinkURLScheme.isEmpty ? "nil" : appLinkURLScheme) | ClientToken=\(hasClientToken ? "present length=\(clientToken.count)" : "absent") | TeamID=\(hasTeamID ? "present" : "absent") | DAMEnabled=\(damEnabled)"
    runtimeURLTypesText = urlTypeSummaries.isEmpty ? "none" : urlTypeSummaries.joined(separator: " ; ")
    runtimeCameraAccessSchemeText = hasCameraAccessScheme ? "registered" : "missing"
    runtimeAssociatedDomainsText = associatedDomains
    runtimeDeveloperModeFlagText = "\(devModeFlag)"

    AppLogger.log(.sdk, "Runtime DAT config snapshot reason=\(reason): \(runtimeBundleConfigurationText)")
    AppLogger.log(.sdk, "Runtime URL types reason=\(reason): \(runtimeURLTypesText)")
    AppLogger.log(.sdk, "Runtime URL scheme cameraaccess=\(runtimeCameraAccessSchemeText), associatedDomains=\(runtimeAssociatedDomainsText), devModeFlag=\(runtimeDeveloperModeFlagText)")
  }

  private func detectConfigurationMode() -> DATConfigurationMode {
    guard let mwdat = Bundle.main.object(forInfoDictionaryKey: "MWDAT") as? [String: Any] else {
      return .developerMode
    }
    let metaAppID = (mwdat["MetaAppID"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if metaAppID.isEmpty || metaAppID == "0" {
      return .developerMode
    }
    return .production
  }

  private func logRegistrationFailure(_ error: RegistrationError, wearables: WearablesInterface) {
    refreshRuntimeConfigurationSnapshot(reason: "registration-failure")
    let detail = detailedErrorDescription(error)
    lastRegistrationErrorDetailText = detail
    applyRegistrationState(wearables.registrationState)
    AppLogger.log(.registration, "Registration failed detail: \(detail)")
    AppLogger.log(.registration, "Registration failed current state=\(wearables.registrationState), runtimeConfig=\(runtimeBundleConfigurationText), urlTypes=\(runtimeURLTypesText)")
  }

  private func detailedErrorDescription(_ error: some Error) -> String {
    let mirror = Mirror(reflecting: error)
    let children = mirror.children.map { child in
      "\(child.label ?? "_")=\(child.value)"
    }.joined(separator: ",")
    return "type=\(type(of: error)) | localized=\(error.localizedDescription) | describing=\(String(describing: error)) | reflecting=\(String(reflecting: error)) | mirror=\(children.isEmpty ? "none" : children)"
  }

  private func validateProductionConfiguration() -> String? {
    guard let mwdat = Bundle.main.object(forInfoDictionaryKey: "MWDAT") as? [String: Any] else {
      return "Missing MWDAT dictionary"
    }
    let metaAppID = (mwdat["MetaAppID"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let clientToken = (mwdat["ClientToken"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let teamID = (mwdat["TeamID"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if metaAppID == "0" { return nil }
    if metaAppID.isEmpty { return "Missing MetaAppID" }
    if clientToken.isEmpty { return "Missing ClientToken" }
    if teamID.isEmpty { return "Missing TeamID" }
    return nil
  }

  private func logConfigurationInputs(mode: DATConfigurationMode) {
    let bundleID = Bundle.main.bundleIdentifier ?? "Missing bundle identifier"
    let mwdat = Bundle.main.object(forInfoDictionaryKey: "MWDAT") as? [String: Any]
    let metaAppID = mwdat?["MetaAppID"] as? String ?? ""
    let appLinkURLScheme = mwdat?["AppLinkURLScheme"] as? String ?? "Missing AppLinkURLScheme"
    let hasMetaAppID = !metaAppID.isEmpty
    let clientToken = mwdat?["ClientToken"] as? String ?? ""
    let hasClientToken = !clientToken.isEmpty
    let teamID = mwdat?["TeamID"] as? String ?? "Missing TeamID"
    let damEnabled = (mwdat?["DAMEnabled"] as? Bool) == true
    AppLogger.log(.sdk, "DAT config inputs: bundleID=\(bundleID), mode=\(mode.rawValue), hasMWDAT=\(mwdat != nil), appLinkURLScheme=\(appLinkURLScheme), metaAppID=\(metaAppID.isEmpty ? "missing" : metaAppID), teamID=\(teamID), hasMetaAppID=\(hasMetaAppID), hasClientToken=\(hasClientToken), clientTokenLength=\(clientToken.count), damEnabled=\(damEnabled)")
  }

  private func bundleURLSchemes() -> [String] {
    guard let urlTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] else {
      return []
    }
    return urlTypes.flatMap { urlType in
      urlType["CFBundleURLSchemes"] as? [String] ?? []
    }
  }

  private func bundleURLTypeSummaries() -> [String] {
    guard let urlTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] else {
      return []
    }
    return urlTypes.enumerated().map { index, urlType in
      let name = stringValue(urlType["CFBundleURLName"])
      let role = stringValue(urlType["CFBundleTypeRole"])
      let schemes = (urlType["CFBundleURLSchemes"] as? [String] ?? []).joined(separator: ",")
      return "#\(index) name=\(name.isEmpty ? "nil" : name) role=\(role.isEmpty ? "nil" : role) schemes=[\(schemes)]"
    }
  }

  private func associatedDomainsEntitlement() -> String {
    let infoPlistValue = Bundle.main.object(forInfoDictionaryKey: "com.apple.developer.associated-domains")
    if let domains = infoPlistValue as? [String] {
      return domains.isEmpty ? "absent" : "declared in Info.plist \(domains.joined(separator: ","))"
    }
    if let value = infoPlistValue {
      return "declared in Info.plist \(value)"
    }
    return "not declared in app Info.plist"
  }

  private func stringValue(_ value: Any?) -> String {
    switch value {
    case let string as String:
      return string
    case let number as NSNumber:
      return number.stringValue
    case let value?:
      return "\(value)"
    case nil:
      return ""
    }
  }

  private func logSDKConfigurationPreflight() {
    do {
      let configuration = try Configuration(bundle: .main)
      AppLogger.log(
        .sdk,
        "MWDAT preflight passed: bundleID=\(configuration.appConfiguration.bundleIdentifier), appLinkURLScheme=\(configuration.appConfiguration.appLinkURLScheme ?? "nil"), metaAppID=\(configuration.appConfiguration.metaAppId ?? "nil"), hasClientToken=\(configuration.appConfiguration.clientToken != nil), teamID=\(configuration.appConfiguration.teamID ?? "nil"), devModeFlag=\(UserDefaults.standard.bool(forKey: "com.meta.wearable.dat.isDevMode"))"
      )
    } catch {
      AppLogger.log(.sdk, "MWDAT preflight failed before Wearables.configure(): \(error)")
    }
  }

  private func restartDiscovery(reason: String) {
    guard let wearables else { return }
    if devicesStreamActive, let deviceTask, !deviceTask.isCancelled {
      AppLogger.log(.devices, "devicesStream already active; skipping restart reason=\(reason) listenerId=\(devicesStreamListenerId)")
      if activeDeviceTask == nil || activeDeviceTask?.isCancelled == true {
        observeActiveDevice()
      }
      return
    }
    AppLogger.log(.devices, "Restarting device discovery stream, reason=\(reason)")
    observeDevices(wearables: wearables, reason: reason)
    observeActiveDevice()
  }

  private func refreshCurrentDevices(reason: String) {
    guard let wearables else { return }
    applyDevices(wearables.devices, reason: reason)
  }

  private func applyDevices(_ devices: [DeviceIdentifier], reason: String) {
    let nowText = Self.timestampText()
    deviceCount = devices.count
    lastDevicesEventTimestampText = nowText
    if reason == "devicesStream", firstDevicesStreamEventTimestampText == "never" {
      firstDevicesStreamEventTimestampText = nowText
      AppLogger.log(.devices, "First devicesStream event at \(nowText)")
    }
    AppLogger.log(.devices, "DAT device discovery update reason=\(reason), count=\(devices.count), ids=\(devices.joined(separator: ","))")
    monitorCompatibility(for: devices)
    if devices.isEmpty {
      isDeviceSessionReady = false
      hasActiveDevice = false
      deviceSessionStateText = deviceSession.map { "\($0.state)" } ?? "None"
      selectedDeviceIDText = "None"
      selectedDeviceCompatibilityText = "unknown"
      selectedDeviceLinkStateText = "unknown"
      selectedDeviceIsCompatible = false
      AppLogger.log(.devices, "No device selected because devices list is empty")
    } else {
      noDevicesTimeoutTask?.cancel()
      if let activeDevice = deviceSelector?.activeDevice, devices.contains(activeDevice) {
        hasActiveDevice = true
        connectionStageText = DATConnectionStage.deviceSelected.rawValue
        selectedDeviceIDText = "\(activeDevice)"
        refreshSelectedDeviceDiagnostics(deviceId: activeDevice)
      } else {
        hasActiveDevice = false
        connectionStageText = DATConnectionStage.discoveringDevices.rawValue
        selectedDeviceIDText = "None"
        selectedDeviceCompatibilityText = "AutoDeviceSelector pending"
        selectedDeviceLinkStateText = "AutoDeviceSelector pending"
        selectedDeviceIsCompatible = false
        AppLogger.log(.devices, "DAT devices are available, waiting for AutoDeviceSelector activeDevice. count=\(devices.count)")
      }
    }
    updateStartReadinessReason()
  }

  private func monitorCompatibility(for devices: [DeviceIdentifier]) {
    guard let wearables else { return }
    let current = Set(devices)
    compatibilityListenerTokens = compatibilityListenerTokens.filter { current.contains($0.key) }
    linkStateListenerTokens = linkStateListenerTokens.filter { current.contains($0.key) }
    for id in devices where compatibilityListenerTokens[id] == nil {
      guard let device = wearables.deviceForIdentifier(id) else {
        AppLogger.log(.devices, "No Device object available for id=\(id)")
        continue
      }
      let deviceType = "\(device.deviceType())"
      let compatibility = device.compatibility()
      AppLogger.log(.devices, "Device id=\(id), name=\(device.nameOrId()), type=\(deviceType), compatibility=\(compatibility.displayString), linkState=\(device.linkState)")
      let token = device.addCompatibilityListener { [weak self] compatibility in
        Task { @MainActor in
          AppLogger.log(.devices, "Compatibility changed for id=\(id): \(compatibility.displayString)")
          if self?.selectedDeviceIDText == id {
            self?.selectedDeviceCompatibilityText = compatibility.displayString
            self?.selectedDeviceIsCompatible = compatibility == .compatible
            self?.updateStartReadinessReason()
          }
        }
      }
      compatibilityListenerTokens[id] = token
      let linkToken = device.addLinkStateListener { [weak self] linkState in
        Task { @MainActor in
          self?.handleDeviceLinkState(linkState, deviceId: id)
        }
      }
      linkStateListenerTokens[id] = linkToken
    }
  }

  private func handleDeviceLinkState(_ linkState: LinkState, deviceId: DeviceIdentifier) {
    AppLogger.log(.devices, "Device link state changed id=\(deviceId): \(linkState)")
    guard selectedDeviceIDText == deviceId else { return }
    selectedDeviceLinkStateText = "\(linkState)"
    updateStartReadinessReason()
  }

  private func refreshSelectedDeviceDiagnostics(deviceId: DeviceIdentifier) {
    guard let device = wearables?.deviceForIdentifier(deviceId) else {
      selectedDeviceCompatibilityText = "unknown"
      selectedDeviceLinkStateText = "unknown"
      selectedDeviceIsCompatible = false
      AppLogger.log(.devices, "Selected device diagnostics unavailable for id=\(deviceId)")
      updateStartReadinessReason()
      return
    }

    let compatibility = device.compatibility()
    selectedDeviceCompatibilityText = compatibility.displayString
    selectedDeviceIsCompatible = compatibility == .compatible
    selectedDeviceLinkStateText = "\(device.linkState)"
    AppLogger.log(
      .devices,
      "Selected device diagnostics id=\(deviceId), type=\(device.deviceType()), compatibility=\(compatibility.displayString), linkState=\(device.linkState)"
    )
    updateStartReadinessReason()
  }

  private func scheduleNoDevicesTimeout(reason: String) {
    noDevicesTimeoutTask?.cancel()
    noDevicesTimeoutTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 10_000_000_000)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard let self, self.deviceCount == 0, self.isConfigured else { return }
        let message = "No DAT device discovered. Confirm glasses are awake, unfolded, nearby, paired in Meta AI, and Developer Mode is enabled."
        self.lastDATErrorText = message
        AppLogger.log(.devices, "\(message) timeoutReason=\(reason)")
        self.onError?(message)
        self.updateStartReadinessReason()
      }
    }
  }

  private func scheduleRegistrationHandoffTimeout() {
    registrationHandoffTimeoutTask?.cancel()
    registrationHandoffTimeoutTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 60_000_000_000)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard let self,
              self.isWaitingForMetaAIReturn,
              self.currentRegistrationState != .registered else { return }
        let message = self.metaAIHandoffFailureMessage(prefix: "Meta AI registration handoff did not complete within 60 seconds.")
        self.isWaitingForMetaAIReturn = false
        self.registrationHandoffDiagnosticText = message
        self.lastDATErrorText = message
        AppLogger.log(.registration, message)
        self.onError?(message)
        self.updateStartReadinessReason()
      }
    }
  }

  private func cancelRegistrationHandoffTimeout() {
    registrationHandoffTimeoutTask?.cancel()
    registrationHandoffTimeoutTask = nil
  }

  private func metaAIHandoffFailureMessage(prefix: String) -> String {
    """
    \(prefix) Update Meta AI, confirm it opens normally, confirm glasses are connected in Meta AI, confirm Developer Mode is enabled for this glasses pair, update glasses firmware, check internet, try cellular instead of Wi-Fi, disable VPN/custom DNS/content blockers/iCloud Private Relay, force quit and reopen Meta AI, then delete and reinstall this app after plist changes.
    """
  }

  private func updateStartReadinessReason() {
    startReadinessReasonText = startReadinessBlocker() ?? "Ready to start real stream"
  }

  private func startReadinessBlocker() -> String? {
    if !isConfigured {
      return "SDK not configured"
    }
    if isSimulator {
      return "real glasses require a physical iPhone"
    }
    if !isAppActive {
      return "app is not active"
    }
    if isWaitingForMetaAIReturn {
      return "waiting for Meta AI return"
    }
    if currentRegistrationState == .registering {
      return "registration in progress"
    }
    if currentRegistrationState != .registered {
      return "registration not ready: \(registrationStateText)"
    }
    if !hasActiveDevice {
      return "waiting for an active device"
    }
    if let deviceSession, deviceSession.state == .starting || deviceSession.state == .stopping || deviceSession.state == .paused {
      return "DeviceSession not started: \(deviceSession.state)"
    }
    if isStreamRunning {
      return "stream already running"
    }
    if streamSession != nil {
      let state = streamSessionStateText.lowercased()
      if state.contains("waiting") || state.contains("starting") || state.contains("paused") {
        return "stream session is \(streamSessionStateText); wait for it to finish"
      }
    }
    return nil
  }

  private func applyRegistrationState(_ state: RegistrationState) {
    currentRegistrationState = state
    registrationStateText = describeRegistrationState(state)
    switch state {
    case .available:
      if connectionStageText != DATConnectionStage.registrationStarting.rawValue
        && connectionStageText != DATConnectionStage.waitingForMetaAIRegistration.rawValue {
        connectionStageText = DATConnectionStage.registrationAvailable.rawValue
      }
    case .registering:
      if isWaitingForMetaAIReturn || didStartRegistrationHandoff {
        didObserveRegisteringDuringCurrentHandoff = true
      }
      connectionStageText = DATConnectionStage.registrationStarting.rawValue
    case .registered:
      if connectionStageText == DATConnectionStage.sdkConfigured.rawValue
        || connectionStageText == DATConnectionStage.registrationAvailable.rawValue
        || connectionStageText == DATConnectionStage.registrationStarting.rawValue
        || connectionStageText == DATConnectionStage.waitingForMetaAIRegistration.rawValue {
        connectionStageText = DATConnectionStage.registered.rawValue
      }
    case .unavailable:
      break
    @unknown default:
      break
    }
  }

  private func describeRegistrationState(_ state: RegistrationState) -> String {
    switch state {
    case .unavailable:
      return "unavailable"
    case .available:
      return "available"
    case .registering:
      return "registering"
    case .registered:
      return "registered"
    @unknown default:
      return "\(state)"
    }
  }

  private static func timestampText() -> String {
    ISO8601DateFormatter().string(from: Date())
  }

  private func formatStreamError(_ error: StreamError) -> String {
    switch error {
    case .internalError:
      return "Glasses camera failed to start (ActivityManager error). Close and reopen the glasses hinges to reset the camera, then tap Start streaming again. If it repeats, force-quit Meta AI and reopen it, or power-cycle the glasses."
    case .deviceNotFound:
      return "Device not found. Confirm glasses are paired in Meta AI."
    case .deviceNotConnected:
      return "Device not connected. Check glasses connection and retry."
    case .timeout:
      return "DAT stream timed out."
    case .videoStreamingError:
      return "DAT video streaming failed."
    case .permissionDenied:
      return "DAT camera permission denied."
    case .hingesClosed:
      return "Glasses hinges are closed."
    case .thermalCritical:
      return "Glasses are too warm; streaming paused."
    case .thermalEmergency:
      return "Glasses thermal emergency; stop streaming and let the device cool down."
    case .peakPowerShutdown:
      return "Glasses stopped streaming because peak power protection was triggered."
    case .batteryCritical:
      return "Glasses battery is critically low; charge the device before streaming."
    @unknown default:
      return "Unknown DAT streaming error: \(error)"
    }
  }
}

private struct AssistanceDisplayPage {
  let title: String
  let lines: [String]
  let number: Int
  let count: Int
  var thumbnailImageURI: String? = nil
  var thumbnailImageSize: AssistanceDisplayImageSize = .fill
  var primaryAction: GlassesDisplayAction? = nil
  var secondaryAction: GlassesDisplayAction? = nil
  var tertiaryAction: GlassesDisplayAction? = nil

  var hasControls: Bool {
    count > 1 || primaryAction != nil || secondaryAction != nil || tertiaryAction != nil
  }

  var text: String {
    let pageText = count > 1 ? "Page \(number) of \(count)" : nil
    return ([title, pageText].compactMap { $0 } + lines).joined(separator: "\n")
  }
}

private extension AssistanceDisplayImageSize {
  var datImageSize: MWDATDisplay.ImageSize {
    switch self {
    case .icon:
      return .icon
    case .fill:
      return .fill
    }
  }
}

private struct QueuedDisplaySend {
  let cardKey: String
  let pages: [AssistanceDisplayPage]
  let pageIndex: Int
  let reason: String
}

private extension Array {
  func chunked(into size: Int) -> [[Element]] {
    guard size > 0 else { return [self] }
    var chunks: [[Element]] = []
    var index = startIndex
    while index < endIndex {
      let next = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
      chunks.append(Array(self[index..<next]))
      index = next
    }
    return chunks
  }
}

private final class DATFrameDeliveryGate: @unchecked Sendable {
  private let lock = NSLock()
  private let minimumIntervalNanoseconds: UInt64
  private var lastDeliveryNanoseconds: UInt64 = 0
  // Window counters for diagnostics: every frame the SDK hands us is counted as
  // "arrived"; frames rate-limited out by the gate are counted as "dropped".
  // Comparing arrived-FPS (SDK delivery) to delivered-FPS (app throughput)
  // localizes a slow stream to the link/SDK vs intentional app rate limiting.
  private var windowArrived: Int = 0
  private var windowDropped: Int = 0

  struct WindowCounts {
    let arrived: Int
    let dropped: Int
  }

  init(maxFPS: Double) {
    let fps = max(1, maxFPS)
    minimumIntervalNanoseconds = UInt64((1_000_000_000 / fps).rounded())
  }

  func reset() {
    lock.lock()
    lastDeliveryNanoseconds = 0
    windowArrived = 0
    windowDropped = 0
    lock.unlock()
  }

  func shouldDeliver() -> Bool {
    let now = DispatchTime.now().uptimeNanoseconds
    lock.lock()
    defer { lock.unlock() }
    windowArrived += 1
    if lastDeliveryNanoseconds == 0 || now - lastDeliveryNanoseconds >= minimumIntervalNanoseconds {
      lastDeliveryNanoseconds = now
      return true
    }
    windowDropped += 1
    return false
  }

  /// Reads and zeroes the window counters. Called by the FPS logger each window.
  func pullWindowCounts() -> WindowCounts {
    lock.lock()
    defer {
      windowArrived = 0
      windowDropped = 0
      lock.unlock()
    }
    return WindowCounts(arrived: windowArrived, dropped: windowDropped)
  }
}

private final class DATStreamCallbackGate: @unchecked Sendable {
  private let lock = NSLock()
  private var generation: UInt64 = 0
  private var hasStream = false
  private var stateText = "STOPPED"

  func beginStream(stateText: String) -> UInt64 {
    lock.lock()
    generation &+= 1
    hasStream = true
    self.stateText = stateText
    let nextGeneration = generation
    lock.unlock()
    return nextGeneration
  }

  func updateStateText(_ stateText: String) {
    lock.lock()
    self.stateText = stateText
    lock.unlock()
  }

  func disableFrames(stateText: String) {
    lock.lock()
    generation &+= 1
    self.stateText = stateText
    lock.unlock()
  }

  func release(stateText: String) {
    lock.lock()
    generation &+= 1
    hasStream = false
    self.stateText = stateText
    lock.unlock()
  }

  func shouldAccept(generation callbackGeneration: UInt64) -> Bool {
    lock.lock()
    let currentGeneration = generation
    let streamIsPresent = hasStream
    let currentStateText = stateText
    lock.unlock()
    return DATGlassesManager.shouldAcceptStreamCallback(
      callbackGeneration: callbackGeneration,
      currentGeneration: currentGeneration,
      hasStream: streamIsPresent,
      stateText: currentStateText
    )
  }
}
