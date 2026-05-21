import Combine
import CoreMedia
import CoreVideo
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
  @Published private(set) var framesConvertedToUIImage: UInt64 = 0
  @Published private(set) var frameConversionFailures: UInt64 = 0
  @Published private(set) var lastFrameWidthText = "none"
  @Published private(set) var lastFrameHeightText = "none"
  @Published private(set) var lastFrameTimestampText = "none"
  @Published private(set) var lastFrameErrorText = "none"

  var onFrameImage: (@MainActor (UIImage) -> Void)?
  var onFrameSampleBuffer: (@MainActor (CMSampleBuffer, UIImage?) -> Void)?
  var onError: ((String) -> Void)?

  private var didAttemptConfigure = false
  private var configureCallCount = 0
  private var currentRegistrationState: RegistrationState?
  private var registrationTask: Task<Void, Never>?
  private var deviceTask: Task<Void, Never>?
  private var devicesStreamListenerId = 0
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
  private var suppressDeviceSessionErrorsUntil: Date?
  private var deviceSessionGenerationId = UUID()
  private var lastDeviceSessionStartupErrorDetail: String?
  private var streamSession: MWDATCamera.Stream?
  private var stateListenerToken: AnyListenerToken?
  private var frameListenerToken: AnyListenerToken?
  private var errorListenerToken: AnyListenerToken?
  private var compatibilityListenerTokens: [DeviceIdentifier: AnyListenerToken] = [:]
  private var linkStateListenerTokens: [DeviceIdentifier: AnyListenerToken] = [:]
  private var deviceSessionStartupErrorListenerToken: AnyListenerToken?
  private var deviceSessionErrorListenerToken: AnyListenerToken?
  private var selectedDeviceIsCompatible = false
  private var firstFrameSeen = false
  private var totalFramesReceived: UInt64 = 0
  private var totalFramesConvertedToUIImage: UInt64 = 0
  private var totalFrameConversionFailures: UInt64 = 0
  private var streamReachedStreaming = false
  private var didStartRegistrationHandoff = false
  private var didObserveRegisteringDuringCurrentHandoff = false
  private struct DATFrameExtraction {
    let frameType: String
    let image: UIImage?
    let errorText: String?
  }

  private init() {}

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
        restartDiscovery(reason: "startup-registered")
        refreshCurrentDevices(reason: "startup-registered")
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

    guard await prepareDeviceSession(reason: "start-stream") else {
      emitError("Start streaming blocked: DeviceSession did not reach started.")
      updateStartReadinessReason()
      return false
    }

    guard let currentSession = deviceSession, currentSession.state == .started else {
      emitError("DeviceSession was lost before stream start. Connect my glasses again.")
      updateStartReadinessReason()
      return false
    }

    return await startStream(session: currentSession, resolution: .low, frameRate: 24)
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
      AppLogger.log(.stream, "Calling addStream(config:) codec=raw resolution=\(resolution) frameRate=\(frameRate) on DeviceSession state=\(session.state) configSource=MetaCameraAccessSample")
      guard let stream = try session.addStream(config: config) else {
        emitError("Failed to create DAT Stream.")
        return false
      }
      streamSession = stream
      resetFrameDiagnostics()
      setupStreamListeners(for: stream)
      streamSessionStateText = "STARTING"
      firstFrameSeen = false
      streamReachedStreaming = false
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
    suppressDeviceSessionErrorsAfterUserStopIfNeeded(reason: reason)
    let stream = streamSession
    clearStreamListeners()
    streamSession = nil
    isStreamRunning = false
    streamReachedStreaming = false
    streamSessionStateText = "STOPPED"
    if let stream {
      AppLogger.log(.stream, "Stopping real DAT Stream reason=\(reason)")
      await stream.stop()
    } else {
      AppLogger.log(.stream, "Stop real DAT Stream requested with no active stream reason=\(reason)")
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
      isPreparingDeviceSession = false
      isStartingDeviceSession = false
      deviceSessionHadStarted = false
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
    deviceSessionStopRequestedByUser = true
    await stopStream(reason: "resetDeviceSession")
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
    runtimeSessionStateText = "StateStream only"
    deviceSessionGenerationId = UUID()
    deviceSessionStateTask?.cancel()
    deviceSessionStateTask = nil
    deviceSessionStartupErrorListenerToken = nil
    deviceSessionErrorListenerToken = nil
    lastDATErrorText = "DeviceSession reset. Keep glasses open/worn and connected in Meta AI, then tap Connect my glasses."
    updateStartReadinessReason()
  }

  private func releaseLocalDeviceSession(reason: String) {
    AppLogger.log(.devices, "Releasing local DeviceSession reference reason=\(reason), deviceId=\(activeDeviceSessionDeviceId ?? "nil"), state=\(deviceSession.map { "\($0.state)" } ?? "nil")")
    deviceSession = nil
    activeDeviceSessionDeviceId = nil
    isPreparingDeviceSession = false
    isStartingDeviceSession = false
    deviceSessionHadStarted = false
    isDeviceSessionReady = false
    deviceSessionStateText = "None"
    runtimeSessionStateText = "StateStream only"
    deviceSessionGenerationId = UUID()
    deviceSessionStateTask?.cancel()
    deviceSessionStateTask = nil
    deviceSessionStartupErrorListenerToken = nil
    deviceSessionErrorListenerToken = nil
  }

  @discardableResult
  func prepareDeviceSession(reason: String) async -> Bool {
    AppLogger.log(.devices, "Preparing DeviceSession reason=\(reason), deviceCount=\(deviceCount), activeDevice=\(deviceSelector?.activeDevice ?? "nil")")
    if let existing = deviceSession {
      switch existing.state {
      case .started:
        isDeviceSessionReady = true
        activeDeviceSessionDeviceId = existing.deviceId
        selectedDeviceIDText = existing.deviceId
        deviceSessionStateText = "\(existing.state)"
        AppLogger.log(.devices, "Reusing started DeviceSession deviceId=\(existing.deviceId), reason=\(reason)")
        updateStartReadinessReason()
        return true
      case .starting, .paused, .stopping:
        isDeviceSessionReady = false
        deviceSessionStateText = "\(existing.state)"
        AppLogger.log(.devices, "DeviceSession is \(existing.state); waiting for SDK state transition. deviceId=\(existing.deviceId), reason=\(reason)")
        updateStartReadinessReason()
        return false
      case .idle, .stopped:
        releaseLocalDeviceSession(reason: "existing-\(existing.state)-before-\(reason)")
      @unknown default:
        releaseLocalDeviceSession(reason: "unknown-existing-state-\(existing.state)-before-\(reason)")
      }
    }
    if isPreparingDeviceSession || isStartingDeviceSession {
      AppLogger.log(.devices, "Skipping DeviceSession prepare; session is already starting. reason=\(reason), activeSessionDevice=\(activeDeviceSessionDeviceId ?? "nil"), localState=\(deviceSession.map { "\($0.state)" } ?? "nil"), preparing=\(isPreparingDeviceSession), starting=\(isStartingDeviceSession)")
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
    if let existing = deviceSession, existing.state == .started {
      return existing
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
      lastDeviceSessionStartupErrorDetail = nil
      selectedDeviceIDText = session.deviceId
      runtimeSessionStateText = "StateStream only"
      AppLogger.log(.devices, "Using DeviceSession.stateStream() and errorPublisher for startup lifecycle before camera streaming. deviceId=\(session.deviceId)")
      let stateStream = session.stateStream()
      deviceSessionStartupErrorListenerToken = session.errorPublisher.listen { [weak self] error in
        Task { @MainActor in
          guard let self else { return }
          let detail = self.detailedErrorDescription(error)
          self.lastDeviceSessionStartupErrorDetail = detail
          self.lastDATErrorText = "DeviceSession startup error: \(detail)"
          AppLogger.log(.devices, "DeviceSession startup error observed before ready. deviceId=\(session.deviceId), detail=\(detail)")
          self.updateStartReadinessReason()
        }
      }
      isStartingDeviceSession = true
      try session.start()
      isPreparingDeviceSession = false
      deviceSessionStateText = "\(session.state)"
      AppLogger.log(.devices, "DeviceSession.start() called for deviceId=\(session.deviceId), initialState=\(session.state)")

      var observedStartupProgress = session.state == .starting
      for await state in stateStream {
        guard generation == deviceSessionGenerationId else {
          AppLogger.log(.devices, "Ignoring stale DeviceSession state \(state), generation=\(generation)")
          return nil
        }
        deviceSessionStateText = "\(state)"
        isDeviceSessionReady = state == .started
        AppLogger.log(.devices, "DeviceSession state changed: \(state)")
        if state == .starting {
          observedStartupProgress = true
        }
        if state == .started {
          isStartingDeviceSession = false
          isPreparingDeviceSession = false
          deviceSessionHadStarted = true
          lastDeviceSessionStartupErrorDetail = nil
          deviceSessionStartupErrorListenerToken = nil
          activeDeviceSessionDeviceId = session.deviceId
          observeDeviceSession(session)
          return session
        }
        if state == .stopped {
          if !observedStartupProgress && !deviceSessionHadStarted {
            AppLogger.log(.devices, "Ignoring initial DeviceSession stopped during startup. deviceId=\(session.deviceId), starting=\(isStartingDeviceSession), hadStarted=\(deviceSessionHadStarted)")
            continue
          }
          let hadStartedBeforeStop = deviceSessionHadStarted
          let message = hadStartedBeforeStop
            ? "DeviceSession stopped after running. deviceId=\(session.deviceId), userRequested=\(deviceSessionStopRequestedByUser)"
            : "DeviceSession startup failed after start attempt. deviceId=\(session.deviceId), lastState=stopped"
          AppLogger.log(.devices, message)
          if let startupError = lastDeviceSessionStartupErrorDetail {
            AppLogger.log(.devices, "DeviceSession startup failed with SDK error detail: \(startupError)")
          }
          isStartingDeviceSession = false
          isPreparingDeviceSession = false
          deviceSession = nil
          deviceSessionStartupErrorListenerToken = nil
          activeDeviceSessionDeviceId = nil
          deviceSessionHadStarted = false
          isDeviceSessionReady = false
          if !hadStartedBeforeStop {
            if let startupError = lastDeviceSessionStartupErrorDetail {
              lastDATErrorText = "DeviceSession startup stopped before becoming ready: \(startupError)"
            } else {
              lastDATErrorText = "DeviceSession startup stopped before becoming ready. Keep glasses open/worn, confirm connected in Meta AI, then tap Connect my glasses again."
            }
          }
          updateStartReadinessReason()
          return nil
        }
      }
    } catch {
      isPreparingDeviceSession = false
      isStartingDeviceSession = false
      isDeviceSessionReady = false
      deviceSessionStartupErrorListenerToken = nil
      if error == .sessionAlreadyExists {
        AppLogger.log(.devices, "Duplicate DeviceSession creation blocked by SDK. Treating as non-fatal while existing SDK session settles.")
        refreshCurrentDevices(reason: "session-already-exists-\(reason)")
        lastDATErrorText = "Previous DeviceSession is still settling inside the SDK. Wait for the active device to return, then tap Start streaming again."
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
        }
        self.updateStartReadinessReason()
        if state == .stopped {
          if self.isStartingDeviceSession || !self.deviceSessionHadStarted {
            AppLogger.log(.devices, "Ignoring initial observed DeviceSession stopped before startup completed. deviceId=\(session.deviceId), starting=\(self.isStartingDeviceSession), hadStarted=\(self.deviceSessionHadStarted)")
            continue
          }
          let wasUserRequested = self.deviceSessionStopRequestedByUser
          AppLogger.log(.devices, "Observed DeviceSession stopped after running. deviceId=\(session.deviceId), userRequested=\(wasUserRequested)")
          self.releaseLocalDeviceSession(reason: "observed-stopped-after-running")
          self.refreshCurrentDevices(reason: "device-session-stopped-after-running")
          self.updateStartReadinessReason()
          if !wasUserRequested {
            AppLogger.log(
              .devices,
              "DeviceSession stopped by SDK/device. Released local session and refreshed discovery; waiting for user to start again after AutoDeviceSelector reports an active device. deviceId=\(session.deviceId)"
            )
          }
          return
        }
      }
    }
    deviceSessionErrorListenerToken = session.errorPublisher.listen { [weak self] error in
      Task { @MainActor in
        guard let self else { return }
        let message = "DeviceSession error: \(error.localizedDescription)"
        guard self.deviceSession != nil,
              self.activeDeviceSessionDeviceId == session.deviceId else {
          AppLogger.log(.devices, "Ignoring stale \(message) from released DeviceSession deviceId=\(session.deviceId)")
          self.updateStartReadinessReason()
          return
        }
        if self.shouldSuppressDeviceSessionErrorForUserStop() {
          AppLogger.log(.devices, "Suppressed user-facing \(message) during user-initiated stop")
          self.updateStartReadinessReason()
          return
        }
        self.emitError(message)
        self.updateStartReadinessReason()
      }
    }
  }

  private func setupStreamListeners(for stream: MWDATCamera.Stream) {
    stateListenerToken = stream.statePublisher.listen { [weak self] state in
      Task { @MainActor in
        self?.handleStreamState(state)
      }
    }
    frameListenerToken = stream.videoFramePublisher.listen { [weak self] frame in
      let extraction = Self.extractVideoFrame(frame)
      Task { @MainActor in
        self?.handleVideoFrame(extraction)
      }
    }
    errorListenerToken = stream.errorPublisher.listen { [weak self] error in
      Task { @MainActor in
        self?.handleStreamError(error)
      }
    }
  }

  private func clearStreamListeners() {
    stateListenerToken = nil
    frameListenerToken = nil
    errorListenerToken = nil
  }

  nonisolated private static func extractVideoFrame(_ frame: VideoFrame) -> DATFrameExtraction {
    let frameType = String(describing: type(of: frame))
    guard let image = frame.makeUIImage() else {
      return DATFrameExtraction(
        frameType: frameType,
        image: nil,
        errorText: "makeUIImage returned nil for \(frameType)"
      )
    }
    return DATFrameExtraction(
      frameType: frameType,
      image: image,
      errorText: nil
    )
  }

  private func handleVideoFrame(_ extraction: DATFrameExtraction) {
    totalFramesReceived += 1
    let frameNumber = totalFramesReceived
    let frameType = extraction.frameType
    let timestamp = Self.timestampText()
    let shouldPublishDiagnostics = frameNumber <= 3 || frameNumber % 30 == 0
    if shouldPublishDiagnostics {
      framesReceived = totalFramesReceived
      lastFrameTimestampText = timestamp
    }

    guard let image = extraction.image else {
      totalFrameConversionFailures += 1
      if shouldPublishDiagnostics {
        frameConversionFailures = totalFrameConversionFailures
      }
      lastFrameErrorText = extraction.errorText ?? "makeUIImage returned nil for \(frameType)"
      lastDATErrorText = "DAT video frame could not be converted for display"
      logFrameDiagnostic(
        frameNumber: frameNumber,
        frameType: frameType,
        timestamp: timestamp,
        image: nil,
        selectedForApp: false,
        error: lastFrameErrorText
      )
      updateStartReadinessReason()
      return
    }

    totalFramesConvertedToUIImage += 1
    let pixelWidth = Int(image.size.width * image.scale)
    let pixelHeight = Int(image.size.height * image.scale)
    if shouldPublishDiagnostics {
      framesConvertedToUIImage = totalFramesConvertedToUIImage
      lastFrameWidthText = "\(pixelWidth)"
      lastFrameHeightText = "\(pixelHeight)"
      lastFrameErrorText = "none"
    }

    if !firstFrameSeen {
      firstFrameSeen = true
      framesReceived = totalFramesReceived
      framesConvertedToUIImage = totalFramesConvertedToUIImage
      firstFrameTimestampText = timestamp
      AppLogger.log(.frames, "First DAT video frame received at \(timestamp)")
    }

    logFrameDiagnostic(
      frameNumber: frameNumber,
      frameType: frameType,
      timestamp: timestamp,
      image: image,
      selectedForApp: true,
      error: nil
    )
    if frameNumber <= 5 || frameNumber % 120 == 0 {
      AppLogger.log(
        .frameSource,
        "frame=\(frameNumber) hasPixelBuffer=false hasUIImage=true preferred=UIImage reason=copiedInsideDATCallback width=\(pixelWidth) height=\(pixelHeight) orientation=up mirrored=false"
      )
    }
    onFrameImage?(image)
  }

  private func logFrameDiagnostic(
    frameNumber: UInt64,
    frameType: String,
    timestamp: String,
    image: UIImage?,
    selectedForApp: Bool,
    error: String?
  ) {
    guard frameNumber <= 20 else { return }
    if let image {
      let pixelWidth = Int(image.size.width * image.scale)
      let pixelHeight = Int(image.size.height * image.scale)
      AppLogger.log(
        .frames,
        "Video frame received count=\(frameNumber), type=\(frameType), makeUIImage=succeeded, width=\(pixelWidth), height=\(pixelHeight), timestamp=\(timestamp), selectedForApp=\(selectedForApp), selectedForVision=deferredToViewModel, visionEnqueued=deferredToViewModel"
      )
    } else {
      AppLogger.log(
        .frames,
        "Video frame received count=\(frameNumber), type=\(frameType), makeUIImage=failed, timestamp=\(timestamp), selectedForApp=\(selectedForApp), selectedForVision=false, visionEnqueued=false, visionSkippedReason=makeUIImageFailed, error=\(error ?? "unknown")"
      )
    }
  }

  private func resetFrameDiagnostics() {
    totalFramesReceived = 0
    totalFramesConvertedToUIImage = 0
    totalFrameConversionFailures = 0
    framesReceived = 0
    framesConvertedToUIImage = 0
    frameConversionFailures = 0
    lastFrameWidthText = "none"
    lastFrameHeightText = "none"
    lastFrameTimestampText = "none"
    lastFrameErrorText = "none"
  }

  private func handleStreamState(_ state: StreamState) {
    streamSessionStateText = "\(state)"
    isStreamRunning = state == .streaming
    if state == .streaming {
      streamReachedStreaming = true
      connectionStageText = DATConnectionStage.streaming.rawValue
    } else if state == .stopped && connectionStageText == DATConnectionStage.streaming.rawValue {
      connectionStageText = DATConnectionStage.streamReady.rawValue
    }
    AppLogger.log(.stream, "Stream state: \(state)")
    if state == .stopped, streamSession != nil, !streamReachedStreaming {
      releaseStreamAfterPreStreamingFailure(reason: "streamStateStoppedBeforeStreaming")
      return
    }
    if state == .stopped, streamReachedStreaming, framesConvertedToUIImage == 0 {
      lastDATErrorText = "DAT stream reached streaming but delivered no video frames before stopping. This matches FrameStallDetectorServiceError; keep the glasses awake/worn and retry Start streaming."
      AppLogger.log(.stream, lastDATErrorText)
    }
    updateStartReadinessReason()
  }

  private func handleStreamError(_ error: StreamError) {
    let message = formatStreamError(error)
    emitError(message)
    if streamSession != nil, !streamReachedStreaming {
      releaseStreamAfterPreStreamingFailure(reason: "streamErrorBeforeStreaming error=\(error)")
    }
  }

  private func releaseStreamAfterPreStreamingFailure(reason: String) {
    let previousError = lastDATErrorText
    let streamState = streamSessionStateText
    let session = deviceSession
    let deviceId = session?.deviceId ?? activeDeviceSessionDeviceId ?? "nil"
    clearStreamListeners()
    streamSession = nil
    isStreamRunning = false
    streamReachedStreaming = false
    streamSessionStateText = "STOPPED"
    if let session {
      deviceSessionStateText = "\(session.state)"
      activeDeviceSessionDeviceId = session.deviceId
      isDeviceSessionReady = session.state == .started
      deviceSessionHadStarted = deviceSessionHadStarted || session.state == .started
      AppLogger.log(.devices, "DAT stream failed before streaming; keeping DeviceSession for SDK-managed retry. deviceId=\(session.deviceId), state=\(session.state), streamState=\(streamState), reason=\(reason)")
    } else {
      isDeviceSessionReady = false
      AppLogger.log(.devices, "DAT stream failed before streaming with no local DeviceSession. deviceId=\(deviceId), streamState=\(streamState), reason=\(reason)")
    }
    isStartingDeviceSession = false
    isPreparingDeviceSession = false
    if previousError == "None" || previousError.isEmpty {
      lastDATErrorText = "DAT stream failed before video reached streaming. Retry Start streaming; the current DeviceSession is being kept if the SDK still reports it started."
    } else {
      lastDATErrorText = "\(previousError) Retry Start streaming; the current DeviceSession is being kept if the SDK still reports it started."
    }
    updateStartReadinessReason()
  }

  private func suppressDeviceSessionErrorsAfterUserStopIfNeeded(reason: String) {
    guard isUserInitiatedStopReason(reason) else { return }
    suppressDeviceSessionErrorsUntil = Date().addingTimeInterval(8)
    AppLogger.log(.devices, "Suppressing user-facing DeviceSession errors after user stop reason=\(reason)")
  }

  private func shouldSuppressDeviceSessionErrorForUserStop() -> Bool {
    let streamIsStopped = streamSession == nil
      && !isStreamRunning
      && streamSessionStateText.lowercased().contains("stopped")
    if deviceSessionStopRequestedByUser {
      return streamIsStopped
    }
    guard let suppressDeviceSessionErrorsUntil else { return false }
    if streamIsStopped, Date() <= suppressDeviceSessionErrorsUntil {
      return true
    }
    self.suppressDeviceSessionErrorsUntil = nil
    return false
  }

  private func isUserInitiatedStopReason(_ reason: String) -> Bool {
    reason == "stopButton"
      || reason == "callerRequested"
      || reason == "streamView.onDisappear"
      || reason == "resetDeviceSession"
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
