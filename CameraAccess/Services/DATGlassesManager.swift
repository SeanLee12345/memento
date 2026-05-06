import Combine
import MWDATCamera
import MWDATCore
import SwiftUI

@MainActor
final class DATGlassesManager: ObservableObject {
  static let shared = DATGlassesManager()

  @Published private(set) var sdkStatusText = "Not configured"
  @Published private(set) var configurationModeText = DATConfigurationMode.developerMode.rawValue
  @Published private(set) var registrationStateText = "Unknown"
  @Published private(set) var deviceCount = 0
  @Published private(set) var selectedDeviceIDText = "None"
  @Published private(set) var deviceSessionStateText = "None"
  @Published private(set) var runtimeSessionStateText = "UNKNOWN"
  @Published private(set) var streamSessionStateText = "STOPPED"
  @Published private(set) var cameraPermissionStatusText = "Not requested"
  @Published private(set) var connectionStageText = DATConnectionStage.sdkConfigured.rawValue
  @Published private(set) var isConfigured = false
  @Published private(set) var isSimulator = false
  @Published private(set) var isConnecting = false
  @Published private(set) var isWaitingForMetaAIReturn = false
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
  @Published private(set) var framesConvertedToUIImage: UInt64 = 0
  @Published private(set) var frameConversionFailures: UInt64 = 0
  @Published private(set) var lastFrameWidthText = "none"
  @Published private(set) var lastFrameHeightText = "none"
  @Published private(set) var lastFrameTimestampText = "none"
  @Published private(set) var lastFrameErrorText = "none"

  var onFrameImage: ((UIImage) -> Void)?
  var onError: ((String) -> Void)?

  private var didAttemptConfigure = false
  private var configureCallCount = 0
  private var allowsMockDeviceKitConfiguration = false
  private var currentRegistrationState: RegistrationState?
  private var registrationTask: Task<Void, Never>?
  private var deviceTask: Task<Void, Never>?
  private var deviceSessionStateTask: Task<Void, Never>?
  private var activeDeviceTask: Task<Void, Never>?
  private var noDevicesTimeoutTask: Task<Void, Never>?
  private var registrationHandoffTimeoutTask: Task<Void, Never>?
  private var wearables: WearablesInterface?
  private var deviceSelector: AutoDeviceSelector?
  private var deviceSession: DeviceSession?
  private var activeDeviceSessionDeviceId: DeviceIdentifier?
  private var isPreparingDeviceSession = false
  private var isStartingDeviceSession = false
  private var deviceSessionHadStarted = false
  private var deviceSessionStopRequestedByUser = false
  private var deviceSessionGenerationId = UUID()
  private var streamSession: StreamSession?
  private var stateListenerToken: AnyListenerToken?
  private var frameListenerToken: AnyListenerToken?
  private var errorListenerToken: AnyListenerToken?
  private var compatibilityListenerTokens: [DeviceIdentifier: AnyListenerToken] = [:]
  private var linkStateListenerTokens: [DeviceIdentifier: AnyListenerToken] = [:]
  private var runtimeSessionStateListenerToken: AnyListenerToken?
  private var deviceSessionErrorListenerToken: AnyListenerToken?
  private var selectedDeviceIsCompatible = false
  private var firstFrameSeen = false
  private var didStartRegistrationHandoff = false
  private var didObserveRegisteringDuringCurrentHandoff = false

  private init() {}

  var canStartStream: Bool {
    startReadinessBlocker() == nil
  }

  func configureAtStartup() {
    ensureConfigured()
  }

  func configureForMockDeviceKit() {
    allowsMockDeviceKitConfiguration = true
    if !isConfigured {
      didAttemptConfigure = false
    }
    ensureConfigured(allowSimulatorMock: true)
  }

  func ensureConfigured(allowSimulatorMock: Bool = false) {
    guard !didAttemptConfigure else {
      updateStartReadinessReason()
      return
    }
    didAttemptConfigure = true

    #if targetEnvironment(simulator)
    isSimulator = true
    if !allowSimulatorMock && !allowsMockDeviceKitConfiguration {
      sdkStatusText = "Simulator: DAT disabled"
      registrationStateText = "Unavailable on simulator"
      AppLogger.log(.stream, "Real Meta glasses connection requires a physical iPhone. Use Mock Device Kit on simulator.")
      updateStartReadinessReason()
      return
    }
    AppLogger.log(.sdk, "DAT configure allowed on simulator for Mock Device Kit")
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
    AppLogger.log(.registration, "Connect Real Glasses tapped. simulator=\(isSimulator), configured=\(isConfigured), mode=\(configurationModeText), waitingForMetaAIReturn=\(isWaitingForMetaAIReturn)")
    ensureConfigured()
    guard let wearables = wearables, isConfigured, !isSimulator else {
      emitUnavailable()
      return
    }

    if isWaitingForMetaAIReturn || wearables.registrationState == .registering || currentRegistrationState == .registering {
      let message = "Registration in progress. Complete the Meta AI flow or wait."
      AppLogger.log(.registration, "Blocked duplicate Connect Real Glasses tap. state=\(wearables.registrationState), waitingForMetaAIReturn=\(isWaitingForMetaAIReturn)")
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
      if isDeviceSessionReady, let activeDeviceSessionDeviceId {
        let message = "Already connected to Meta glasses device \(activeDeviceSessionDeviceId)."
        lastDATErrorText = message
        AppLogger.log(.devices, message)
        isConnecting = false
        updateStartReadinessReason()
        return
      }
      AppLogger.log(.registration, "Already registered; continuing to camera permission stage")
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
        AppLogger.log(.registration, "Registration already complete; continuing to camera permission stage")
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

    if wearables.registrationState == .registered {
      isWaitingForMetaAIReturn = false
      await continueAfterRegistration(reason: "app-active-registered")
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
      emitError("Camera permission failed: \(error.description)")
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
      emitError("Start Real Stream blocked: \(reason)")
      AppLogger.log(.stream, "Start stream blocked: \(reason)")
      return false
    }
    guard await requestCameraPermission() else { return false }
    guard let session = deviceSession, session.state == .started else {
      isDeviceSessionReady = false
      deviceSessionStateText = deviceSession.map { "\($0.state)" } ?? "None"
      emitError("Start Real Stream blocked: DeviceSession not started.")
      updateStartReadinessReason()
      return false
    }

    await stopStream()
    guard let currentSession = deviceSession, currentSession.state == .started else {
      emitError("DeviceSession was lost before stream start. Connect Real Glasses again.")
      updateStartReadinessReason()
      return false
    }

    if await startStream(session: currentSession, frameRate: 24) {
      return true
    }
    AppLogger.log(.stream, "Primary stream config .raw/.low/24 failed; retrying .raw/.low/15 once")
    return await startStream(session: currentSession, frameRate: 15)
  }

  private func startStream(session: DeviceSession, frameRate: UInt) async -> Bool {
    guard session.state == .started else {
      emitError("Cannot start stream because DeviceSession state is \(session.state)")
      return false
    }

    let config = StreamSessionConfig(
      videoCodec: VideoCodec.raw,
      resolution: StreamingResolution.low,
      frameRate: frameRate
    )

    do {
      AppLogger.log(.stream, "Calling addStream(config:) codec=raw resolution=low frameRate=\(frameRate) on DeviceSession state=\(session.state)")
      guard let stream = try session.addStream(config: config) else {
        emitError("Failed to create DAT StreamSession.")
        return false
      }
      streamSession = stream
      resetFrameDiagnostics()
      setupStreamListeners(for: stream)
      streamSessionStateText = "STARTING"
      firstFrameSeen = false
      AppLogger.log(.stream, "Starting real DAT StreamSession with listeners attached")
      await stream.start()
      return true
    } catch {
      emitError("Failed to create DAT StreamSession: \(error.localizedDescription)")
      return false
    }
  }

  func stopStream() async {
    let stream = streamSession
    clearStreamListeners()
    streamSession = nil
    isStreamRunning = false
    streamSessionStateText = "STOPPED"
    if let stream {
      AppLogger.log(.stream, "Stopping real DAT StreamSession")
      await stream.stop()
    }
    updateStartReadinessReason()
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
      AppLogger.log(.registration, "Calling startUnregistration for Developer Mode one-app-rule recovery")
      try await wearables.startUnregistration()
      applyRegistrationState(wearables.registrationState)
      deviceTask?.cancel()
      deviceTask = nil
      devicesStreamActive = false
      deviceCount = 0
      selectedDeviceIDText = "None"
      selectedDeviceCompatibilityText = "unknown"
      selectedDeviceLinkStateText = "unknown"
      selectedDeviceIsCompatible = false
      deviceSession = nil
      activeDeviceSessionDeviceId = nil
      isPreparingDeviceSession = false
      isStartingDeviceSession = false
      deviceSessionHadStarted = false
      isDeviceSessionReady = false
      connectionStageText = DATConnectionStage.registrationAvailable.rawValue
      lastDATErrorText = "DAT app unregistered. Tap Connect Real Glasses to register again."
      updateStartReadinessReason()
    } catch {
      let detail = detailedErrorDescription(error)
      emitError("Unregistration failed: \(detail)")
    }
  }

  func resetDeviceSession() async {
    AppLogger.log(.devices, "Stop/Reset Session requested by user")
    deviceSessionStopRequestedByUser = true
    await stopStream()
    if let session = deviceSession {
      AppLogger.log(.devices, "Stopping DeviceSession for reset. deviceId=\(session.deviceId), state=\(session.state)")
      session.stop()
    } else {
      AppLogger.log(.devices, "No local DeviceSession exists to stop during reset; clearing local state only")
    }
    deviceSession = nil
    activeDeviceSessionDeviceId = nil
    isPreparingDeviceSession = false
    isStartingDeviceSession = false
    deviceSessionHadStarted = false
    isDeviceSessionReady = false
    deviceSessionStateText = "None"
    runtimeSessionStateText = SessionState.stopped.description.uppercased()
    deviceSessionGenerationId = UUID()
    deviceSessionStateTask?.cancel()
    deviceSessionStateTask = nil
    runtimeSessionStateListenerToken = nil
    deviceSessionErrorListenerToken = nil
    lastDATErrorText = "DeviceSession reset. Keep glasses open/worn and connected in Meta AI, then tap Connect Real Glasses."
    updateStartReadinessReason()
  }

  @discardableResult
  func prepareDeviceSession(reason: String) async -> Bool {
    AppLogger.log(.devices, "Preparing DeviceSession reason=\(reason), deviceCount=\(deviceCount), selectedDevice=\(selectedDeviceIDText)")
    let selectedDeviceId = selectedDeviceIDText == "None" ? deviceSelector?.activeDevice : selectedDeviceIDText
    if let existing = reusableDeviceSession(for: selectedDeviceId, reason: reason) {
      return existing.state == .started && isDeviceSessionReady
    }
    if isPreparingDeviceSession || isStartingDeviceSession {
      AppLogger.log(.devices, "Skipping DeviceSession prepare; existing session for selected device is already starting/ready. reason=\(reason), selected=\(selectedDeviceId ?? "nil"), activeSessionDevice=\(activeDeviceSessionDeviceId ?? "nil"), localState=\(deviceSession.map { "\($0.state)" } ?? "nil"), preparing=\(isPreparingDeviceSession), starting=\(isStartingDeviceSession)")
      updateStartReadinessReason()
      return false
    }
    if devicesStreamActive == false,
       currentRegistrationState == .registered,
       cameraPermissionStatusText.lowercased().contains("granted") {
      restartDiscovery(reason: "prepare-\(reason)")
    }
    refreshCurrentDevices(reason: "prepare-\(reason)")
    guard let session = await getDeviceSession(reason: reason), session.state == .started else {
      isDeviceSessionReady = false
      if deviceCount == 0 {
        emitError("No paired Meta glasses detected. Confirm glasses are paired in the Meta AI app and Developer Mode is enabled if required.")
      }
      updateStartReadinessReason()
      return false
    }
    isDeviceSessionReady = true
    deviceSessionStateText = "\(session.state)"
    connectionStageText = DATConnectionStage.deviceSessionReady.rawValue
    AppLogger.log(.devices, "DeviceSession ready for deviceId=\(session.deviceId), state=\(session.state)")
    updateStartReadinessReason()
    return true
  }

  private func getDeviceSession(reason: String) async -> DeviceSession? {
    let selectedDeviceId = selectedDeviceIDText == "None" ? deviceSelector?.activeDevice : selectedDeviceIDText
    if let existing = reusableDeviceSession(for: selectedDeviceId, reason: reason) {
      return existing
    }
    if deviceSession?.state == .stopped, !isStartingDeviceSession, !isPreparingDeviceSession, deviceSessionHadStarted {
      AppLogger.log(.devices, "Clearing stopped DeviceSession after previously started session. deviceId=\(activeDeviceSessionDeviceId ?? "nil"), reason=\(reason)")
      deviceSession = nil
      activeDeviceSessionDeviceId = nil
      deviceSessionHadStarted = false
      isDeviceSessionReady = false
    }
    guard let wearables, let deviceSelector, deviceSession == nil else {
      AppLogger.log(.devices, "DeviceSession not created: wearables=\(wearables != nil), selector=\(deviceSelector != nil), existingState=\(deviceSession.map { "\($0.state)" } ?? "nil")")
      return nil
    }

    isPreparingDeviceSession = true
    let generation = UUID()
    deviceSessionGenerationId = generation
    do {
      AppLogger.log(.devices, "DeviceSession creation attempted, reason=\(reason), activeDevice=\(deviceSelector.activeDevice ?? "nil")")
      let session = try wearables.createSession(deviceSelector: deviceSelector)
      deviceSession = session
      activeDeviceSessionDeviceId = session.deviceId
      deviceSessionHadStarted = false
      deviceSessionStopRequestedByUser = false
      selectedDeviceIDText = session.deviceId
      await observeRuntimeSessionState(for: session.deviceId)
      let stateStream = session.stateStream()
      isStartingDeviceSession = true
      try session.start()
      isPreparingDeviceSession = false
      deviceSessionStateText = "\(session.state)"
      AppLogger.log(.devices, "DeviceSession.start() called for deviceId=\(session.deviceId), initialState=\(session.state)")

      for await state in stateStream {
        guard generation == deviceSessionGenerationId else {
          AppLogger.log(.devices, "Ignoring stale DeviceSession state \(state), generation=\(generation)")
          return nil
        }
        deviceSessionStateText = "\(state)"
        isDeviceSessionReady = state == .started
        AppLogger.log(.devices, "DeviceSession state changed: \(state)")
        if state == .started {
          isStartingDeviceSession = false
          isPreparingDeviceSession = false
          deviceSessionHadStarted = true
          activeDeviceSessionDeviceId = session.deviceId
          if runtimeSessionStateText.lowercased().contains("stopped") {
            runtimeSessionStateText = "STARTED"
          }
          observeDeviceSession(session)
          return session
        }
        if state == .stopped {
          if isStartingDeviceSession || !deviceSessionHadStarted {
            AppLogger.log(.devices, "Ignoring initial DeviceSession stopped during startup. deviceId=\(session.deviceId), starting=\(isStartingDeviceSession), hadStarted=\(deviceSessionHadStarted)")
            continue
          }
          AppLogger.log(.devices, "DeviceSession stopped after running. deviceId=\(session.deviceId), userRequested=\(deviceSessionStopRequestedByUser)")
          isStartingDeviceSession = false
          isPreparingDeviceSession = false
          deviceSession = nil
          activeDeviceSessionDeviceId = nil
          deviceSessionHadStarted = false
          isDeviceSessionReady = false
          updateStartReadinessReason()
          return nil
        }
      }
    } catch {
      isPreparingDeviceSession = false
      isStartingDeviceSession = false
      isDeviceSessionReady = false
      if error == .sessionAlreadyExists {
        AppLogger.log(.devices, "Duplicate DeviceSession creation blocked by SDK for selected device=\(selectedDeviceId ?? "nil"). Treating as non-fatal while existing SDK session settles.")
        lastDATErrorText = "DeviceSession already exists for this device. Waiting for existing session state; use Stop/Reset if it does not become ready."
      } else {
        deviceSession = nil
        activeDeviceSessionDeviceId = nil
        deviceSessionHadStarted = false
        emitError("DeviceSession failed: \(error.localizedDescription)")
      }
      updateStartReadinessReason()
    }
    return nil
  }

  private func reusableDeviceSession(for selectedDeviceId: DeviceIdentifier?, reason: String) -> DeviceSession? {
    guard let session = deviceSession else { return nil }
    let sameDevice = selectedDeviceId == nil || selectedDeviceId == "None" || session.deviceId == selectedDeviceId
    guard sameDevice else {
      AppLogger.log(.devices, "Existing DeviceSession is for a different device. existing=\(session.deviceId), selected=\(selectedDeviceId ?? "nil"), reason=\(reason)")
      return nil
    }

    switch session.state {
    case .starting:
      isStartingDeviceSession = true
      isDeviceSessionReady = false
      deviceSessionStateText = "\(session.state)"
      AppLogger.log(.devices, "Skipping DeviceSession prepare; existing session for selected device is already starting/ready. reason=\(reason), deviceId=\(session.deviceId), state=\(session.state)")
      return session
    case .started:
      isStartingDeviceSession = false
      isPreparingDeviceSession = false
      isDeviceSessionReady = true
      deviceSessionHadStarted = true
      activeDeviceSessionDeviceId = session.deviceId
      deviceSessionStateText = "\(session.state)"
      AppLogger.log(.devices, "Reusing ready DeviceSession deviceId=\(session.deviceId), reason=\(reason)")
      return session
    case .paused:
      isStartingDeviceSession = false
      isPreparingDeviceSession = false
      isDeviceSessionReady = false
      deviceSessionHadStarted = true
      activeDeviceSessionDeviceId = session.deviceId
      deviceSessionStateText = "\(session.state)"
      AppLogger.log(.devices, "Skipping DeviceSession prepare; existing session for selected device is paused. Waiting for resume or stopped. reason=\(reason), deviceId=\(session.deviceId)")
      return session
    case .idle:
      AppLogger.log(.devices, "Reusing idle DeviceSession shell for selected device if start is requested. reason=\(reason), deviceId=\(session.deviceId)")
      return nil
    case .stopping:
      AppLogger.log(.devices, "Skipping DeviceSession prepare; existing session is stopping. reason=\(reason), deviceId=\(session.deviceId)")
      return session
    case .stopped:
      if isStartingDeviceSession || isPreparingDeviceSession || !deviceSessionHadStarted {
        AppLogger.log(.devices, "Skipping DeviceSession prepare; existing session reported initial stopped during startup. reason=\(reason), deviceId=\(session.deviceId), preparing=\(isPreparingDeviceSession), starting=\(isStartingDeviceSession), hadStarted=\(deviceSessionHadStarted)")
        return session
      }
      return nil
    @unknown default:
      AppLogger.log(.devices, "Existing DeviceSession has unknown state \(session.state). reason=\(reason)")
      return session
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
        if state == .registered {
          self.isWaitingForMetaAIReturn = false
          self.cancelRegistrationHandoffTimeout()
          await self.continueAfterRegistration(reason: "registration-state-registered")
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

    guard await requestCameraPermission() else {
      AppLogger.log(.permissions, "Camera permission not granted; stopping staged flow reason=\(reason), status=\(cameraPermissionStatusText)")
      updateStartReadinessReason()
      return
    }

    restartDiscovery(reason: "post-permission-\(reason)")
    refreshCurrentDevices(reason: "post-permission-\(reason)")
    scheduleNoDevicesTimeout(reason: "post-permission-\(reason)")
    _ = await prepareDeviceSession(reason: "post-permission-\(reason)")
  }

  private func observeDevices(wearables: WearablesInterface) {
    deviceTask?.cancel()
    devicesStreamActive = true
    connectionStageText = DATConnectionStage.discoveringDevices.rawValue
    AppLogger.log(.devices, "devicesStream started")
    updateStartReadinessReason()
    deviceTask = Task { [weak self] in
      for await devices in wearables.devicesStream() {
        guard let self else { return }
        self.applyDevices(devices, reason: "devicesStream")
      }
    }
  }

  private func observeActiveDevice() {
    activeDeviceTask?.cancel()
    guard let deviceSelector else { return }
    activeDeviceTask = Task { [weak self] in
      for await device in deviceSelector.activeDeviceStream() {
        guard let self else { return }
        if let device {
          self.selectedDeviceIDText = "\(device)"
          AppLogger.log(.devices, "Active DAT device selected: \(device)")
          self.refreshSelectedDeviceDiagnostics(deviceId: device)
        } else {
          self.selectedDeviceIDText = "None"
          self.selectedDeviceCompatibilityText = "unknown"
          self.selectedDeviceLinkStateText = "unknown"
          self.selectedDeviceIsCompatible = false
          AppLogger.log(.devices, "No active DAT device selected")
        }
        self.updateStartReadinessReason()
      }
    }
  }

  private func observeDeviceSession(_ session: DeviceSession) {
    deviceSessionStateTask?.cancel()
    deviceSessionStateTask = Task { [weak self] in
      for await state in session.stateStream() {
        guard let self else { return }
        self.deviceSessionStateText = "\(state)"
        self.isDeviceSessionReady = state == .started
        AppLogger.log(.devices, "DeviceSession state observed: \(state)")
        if state == .started {
          self.isStartingDeviceSession = false
          self.isPreparingDeviceSession = false
          self.deviceSessionHadStarted = true
          self.activeDeviceSessionDeviceId = session.deviceId
          if self.runtimeSessionStateText.lowercased().contains("stopped") {
            self.runtimeSessionStateText = "STARTED"
          }
        }
        self.updateStartReadinessReason()
        if state == .stopped {
          if self.isStartingDeviceSession || !self.deviceSessionHadStarted {
            AppLogger.log(.devices, "Ignoring initial observed DeviceSession stopped before startup completed. deviceId=\(session.deviceId), starting=\(self.isStartingDeviceSession), hadStarted=\(self.deviceSessionHadStarted)")
            continue
          }
          AppLogger.log(.devices, "Observed DeviceSession stopped after running. deviceId=\(session.deviceId), userRequested=\(self.deviceSessionStopRequestedByUser)")
          self.deviceSession = nil
          self.activeDeviceSessionDeviceId = nil
          self.isStartingDeviceSession = false
          self.isPreparingDeviceSession = false
          self.deviceSessionHadStarted = false
          self.isDeviceSessionReady = false
          self.updateStartReadinessReason()
          return
        }
      }
    }
    deviceSessionErrorListenerToken = session.errorPublisher.listen { [weak self] error in
      Task { @MainActor in
        self?.emitError("DeviceSession error: \(error.localizedDescription)")
        self?.updateStartReadinessReason()
      }
    }
  }

  private func observeRuntimeSessionState(for deviceId: DeviceIdentifier) async {
    guard let wearables else { return }
    runtimeSessionStateListenerToken = await wearables.addDeviceSessionStateListener(forDeviceId: deviceId) { [weak self] state in
      Task { @MainActor in
        self?.handleRuntimeSessionState(state, deviceId: deviceId)
      }
    }
    AppLogger.log(.devices, "DeviceSession runtime state listener attached for deviceId=\(deviceId)")
  }

  private func handleRuntimeSessionState(_ state: SessionState, deviceId: DeviceIdentifier) {
    runtimeSessionStateText = state.description.uppercased()
    AppLogger.log(.devices, "DAT runtime DeviceSession state for \(deviceId): \(state.description)")
    switch state {
    case .running:
      deviceSessionHadStarted = true
      isStartingDeviceSession = false
      isPreparingDeviceSession = false
      isDeviceSessionReady = deviceSession?.state == .started
      if isDeviceSessionReady {
        AppLogger.log(.devices, "DAT runtime session RUNNING; Start Stream may proceed")
      }
    case .paused:
      isDeviceSessionReady = false
      AppLogger.log(.devices, "DAT runtime session PAUSED; holding session and not restarting")
    case .stopped:
      if isStartingDeviceSession || isPreparingDeviceSession || !deviceSessionHadStarted {
        isDeviceSessionReady = false
        AppLogger.log(.devices, "DAT runtime session STOPPED before startup completed; preserving local DeviceSession. deviceId=\(deviceId), preparing=\(isPreparingDeviceSession), starting=\(isStartingDeviceSession), hadStarted=\(deviceSessionHadStarted)")
        updateStartReadinessReason()
        return
      }
      isDeviceSessionReady = false
      if isStreamRunning {
        Task {
          await self.stopStream()
        }
      }
      deviceSession = nil
      activeDeviceSessionDeviceId = nil
      isStartingDeviceSession = false
      isPreparingDeviceSession = false
      deviceSessionHadStarted = false
      deviceSessionStateText = "stopped"
      runtimeSessionStateListenerToken = nil
      deviceSessionErrorListenerToken = nil
      AppLogger.log(.devices, "DAT runtime session STOPPED after running; released DeviceSession and stream resources. userRequested=\(deviceSessionStopRequestedByUser)")
    case .waitingForDevice:
      isDeviceSessionReady = false
      AppLogger.log(.devices, "DAT runtime session waitingForDevice; check glasses power, hinge state, range, and Developer Mode")
    case .unknown:
      isDeviceSessionReady = false
      AppLogger.log(.devices, "DAT runtime session unknown")
    @unknown default:
      isDeviceSessionReady = false
      AppLogger.log(.devices, "DAT runtime session unknown future state: \(state.description)")
    }
    updateStartReadinessReason()
  }

  private func setupStreamListeners(for stream: StreamSession) {
    stateListenerToken = stream.statePublisher.listen { [weak self] state in
      Task { @MainActor in
        self?.handleStreamState(state)
      }
    }
    frameListenerToken = stream.videoFramePublisher.listen { [weak self] frame in
      Task { @MainActor in
        self?.handleVideoFrame(frame)
      }
    }
    errorListenerToken = stream.errorPublisher.listen { [weak self] error in
      Task { @MainActor in
        self?.emitError(self?.formatStreamError(error) ?? "\(error)")
      }
    }
  }

  private func clearStreamListeners() {
    stateListenerToken = nil
    frameListenerToken = nil
    errorListenerToken = nil
  }

  private func handleVideoFrame(_ frame: VideoFrame) {
    framesReceived += 1
    let frameNumber = framesReceived
    let frameType = String(describing: type(of: frame))
    let timestamp = Self.timestampText()
    lastFrameTimestampText = timestamp

    guard let image = frame.makeUIImage() else {
      frameConversionFailures += 1
      lastFrameErrorText = "makeUIImage returned nil for \(frameType)"
      lastDATErrorText = "DAT video frame could not be converted for display"
      logFrameDiagnostic(
        frameNumber: frameNumber,
        frameType: frameType,
        timestamp: timestamp,
        image: nil,
        sentToPreview: false,
        sentToVision: false,
        error: lastFrameErrorText
      )
      updateStartReadinessReason()
      return
    }

    framesConvertedToUIImage += 1
    let pixelWidth = Int(image.size.width * image.scale)
    let pixelHeight = Int(image.size.height * image.scale)
    lastFrameWidthText = "\(pixelWidth)"
    lastFrameHeightText = "\(pixelHeight)"
    lastFrameErrorText = "none"

    if !firstFrameSeen {
      firstFrameSeen = true
      firstFrameTimestampText = timestamp
      AppLogger.log(.frames, "First DAT video frame received at \(timestamp)")
    }

    logFrameDiagnostic(
      frameNumber: frameNumber,
      frameType: frameType,
      timestamp: timestamp,
      image: image,
      sentToPreview: true,
      sentToVision: true,
      error: nil
    )
    onFrameImage?(image)
  }

  private func logFrameDiagnostic(
    frameNumber: UInt64,
    frameType: String,
    timestamp: String,
    image: UIImage?,
    sentToPreview: Bool,
    sentToVision: Bool,
    error: String?
  ) {
    guard frameNumber <= 20 else { return }
    if let image {
      let pixelWidth = Int(image.size.width * image.scale)
      let pixelHeight = Int(image.size.height * image.scale)
      AppLogger.log(
        .frames,
        "Video frame received count=\(frameNumber), type=\(frameType), makeUIImage=succeeded, width=\(pixelWidth), height=\(pixelHeight), timestamp=\(timestamp), sentToPreview=\(sentToPreview), sentToVision=\(sentToVision)"
      )
    } else {
      AppLogger.log(
        .frames,
        "Video frame received count=\(frameNumber), type=\(frameType), makeUIImage=failed, timestamp=\(timestamp), sentToPreview=\(sentToPreview), sentToVision=\(sentToVision), error=\(error ?? "unknown")"
      )
    }
  }

  private func resetFrameDiagnostics() {
    framesReceived = 0
    framesConvertedToUIImage = 0
    frameConversionFailures = 0
    lastFrameWidthText = "none"
    lastFrameHeightText = "none"
    lastFrameTimestampText = "none"
    lastFrameErrorText = "none"
  }

  private func handleStreamState(_ state: StreamSessionState) {
    streamSessionStateText = "\(state)"
    isStreamRunning = state == .streaming
    if state == .streaming {
      connectionStageText = DATConnectionStage.streaming.rawValue
    } else if state == .stopped && connectionStageText == DATConnectionStage.streaming.rawValue {
      connectionStageText = DATConnectionStage.streamReady.rawValue
    }
    AppLogger.log(.stream, "StreamSession state: \(state)")
    updateStartReadinessReason()
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
    let mwdatKeys = mwdat?.keys.sorted().joined(separator: ",") ?? "none"
    let urlTypeSummaries = bundleURLTypeSummaries()
    let schemes = bundleURLSchemes()
    let hasCameraAccessScheme = schemes.contains("cameraaccess")
    let associatedDomains = associatedDomainsEntitlement()
    let devModeFlag = UserDefaults.standard.bool(forKey: "com.meta.wearable.dat.isDevMode")

    runtimeBundleConfigurationText = "bundleID=\(bundleID) | hasMWDAT=\(mwdat != nil ? "yes" : "no") | keys=\(mwdatKeys) | MetaAppID=\(metaAppID.isEmpty ? "nil" : metaAppID) | AppLinkURLScheme=\(appLinkURLScheme.isEmpty ? "nil" : appLinkURLScheme) | ClientToken=\(hasClientToken ? "present length=\(clientToken.count)" : "absent") | TeamID=\(hasTeamID ? "present" : "absent")"
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
    AppLogger.log(.sdk, "DAT config inputs: bundleID=\(bundleID), mode=\(mode.rawValue), hasMWDAT=\(mwdat != nil), appLinkURLScheme=\(appLinkURLScheme), metaAppID=\(metaAppID.isEmpty ? "missing" : metaAppID), teamID=\(teamID), hasMetaAppID=\(hasMetaAppID), hasClientToken=\(hasClientToken), clientTokenLength=\(clientToken.count)")
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
    AppLogger.log(.devices, "Restarting device discovery stream, reason=\(reason)")
    observeDevices(wearables: wearables)
    observeActiveDevice()
  }

  private func refreshCurrentDevices(reason: String) {
    guard let wearables else { return }
    applyDevices(wearables.devices, reason: reason)
  }

  private func applyDevices(_ devices: [DeviceIdentifier], reason: String) {
    let nowText = Self.timestampText()
    deviceCount = devices.count
    selectedDeviceIDText = devices.first.map { "\($0)" } ?? "None"
    lastDevicesEventTimestampText = nowText
    if reason == "devicesStream", firstDevicesStreamEventTimestampText == "never" {
      firstDevicesStreamEventTimestampText = nowText
      AppLogger.log(.devices, "First devicesStream event at \(nowText)")
    }
    AppLogger.log(.devices, "DAT device discovery update reason=\(reason), count=\(devices.count), ids=\(devices.joined(separator: ","))")
    monitorCompatibility(for: devices)
    if devices.isEmpty {
      isDeviceSessionReady = false
      deviceSessionStateText = deviceSession.map { "\($0.state)" } ?? "None"
      selectedDeviceCompatibilityText = "unknown"
      selectedDeviceLinkStateText = "unknown"
      selectedDeviceIsCompatible = false
      AppLogger.log(.devices, "No device selected because devices list is empty")
    } else {
      noDevicesTimeoutTask?.cancel()
      connectionStageText = DATConnectionStage.deviceSelected.rawValue
      refreshSelectedDeviceDiagnostics(deviceId: devices[0])
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
    if linkState == .disconnected {
      isDeviceSessionReady = false
      emitError("Selected glasses disconnected. Open the glasses, confirm they are connected in Meta AI, then reconnect.")
      if isStreamRunning {
        Task {
          await self.stopStream()
        }
      }
      deviceSession = nil
      activeDeviceSessionDeviceId = nil
      isPreparingDeviceSession = false
      isStartingDeviceSession = false
      deviceSessionHadStarted = false
      deviceSessionStateText = "stopped"
      runtimeSessionStateText = SessionState.stopped.description.uppercased()
    }
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
    if isSimulator && !allowsMockDeviceKitConfiguration {
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
    if !cameraPermissionStatusText.lowercased().contains("granted") {
      return "camera permission missing: \(cameraPermissionStatusText)"
    }
    if !devicesStreamActive {
      return "devicesStream not active"
    }
    if deviceCount == 0 {
      return "no device discovered"
    }
    if selectedDeviceIDText == "None" {
      return "selected device missing"
    }
    if !selectedDeviceIsCompatible {
      return "device discovered but incompatible: \(selectedDeviceCompatibilityText)"
    }
    if selectedDeviceLinkStateText.lowercased() != "connected" {
      return "device unavailable/disconnected: \(selectedDeviceLinkStateText)"
    }
    if deviceSession == nil {
      return "DeviceSession missing"
    }
    if runtimeSessionStateText.lowercased().contains("paused") {
      return "DeviceSession paused"
    }
    if runtimeSessionStateText.lowercased().contains("stopped") {
      if let deviceSession, deviceSession.state == .started, deviceSessionHadStarted {
        AppLogger.log(.devices, "Ignoring stale runtime STOPPED readiness blocker because local DeviceSession is started")
      } else {
        return "DeviceSession stopped"
      }
    }
    if let deviceSession, deviceSession.state != .started {
      return "DeviceSession not started: \(deviceSession.state)"
    }
    if !isDeviceSessionReady {
      return "DeviceSession not running/ready"
    }
    if isStreamRunning {
      return "stream already running"
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

  private func formatStreamError(_ error: StreamSessionError) -> String {
    switch error {
    case .internalError:
      return "An internal DAT streaming error occurred."
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
    @unknown default:
      return "Unknown DAT streaming error: \(error)"
    }
  }
}
