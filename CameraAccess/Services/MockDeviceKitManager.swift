#if DEBUG

import Foundation
import MWDATMockDevice

@MainActor
final class MockDeviceKitManager: ObservableObject {
  static let shared = MockDeviceKitManager()

  @Published private(set) var isEnabled = false
  @Published private(set) var isPaired = false
  @Published private(set) var isPoweredOn = false
  @Published private(set) var isUnfolded = false
  @Published private(set) var isDonned = false
  @Published private(set) var hasVideoFeed = false
  @Published private(set) var mockDeviceIDText = "None"
  @Published private(set) var lastMockErrorText = "None"

  private let mockDeviceKit = MockDeviceKit.shared
  private var mockDevice: (any MockRaybanMeta)?

  private init() {}

  func enable() {
    mockDeviceKit.enable(config: MockDeviceKitConfig(initiallyRegistered: true, initialPermissionsGranted: true))
    isEnabled = true
    DATGlassesManager.shared.configureForMockDeviceKit()
    AppLogger.log(.devices, "MockDeviceKit enabled with initial registration and camera permission granted")
  }

  func pairRayBanMeta() {
    if !isEnabled {
      enable()
    }
    if let existing = mockDevice {
      isPaired = true
      mockDeviceIDText = existing.deviceIdentifier
      AppLogger.log(.devices, "Mock RayBan Meta already paired id=\(existing.deviceIdentifier)")
      return
    }

    let device = mockDeviceKit.pairRaybanMeta()
    mockDevice = device
    isPaired = true
    mockDeviceIDText = device.deviceIdentifier
    AppLogger.log(.devices, "Mock RayBan Meta paired id=\(device.deviceIdentifier)")
    Task {
      await DATGlassesManager.shared.resumeAfterExternalAppReturn()
    }
  }

  func powerOn() {
    guard let mockDevice else {
      setError("Pair RayBan Meta before PowerOn.")
      return
    }
    mockDevice.powerOn()
    isPoweredOn = true
    AppLogger.log(.devices, "Mock RayBan Meta PowerOn id=\(mockDevice.deviceIdentifier)")
    refreshDATDiscovery()
  }

  func unfold() {
    guard let mockDevice else {
      setError("Pair RayBan Meta before Unfold.")
      return
    }
    mockDevice.unfold()
    isPoweredOn = true
    isUnfolded = true
    AppLogger.log(.devices, "Mock RayBan Meta Unfold id=\(mockDevice.deviceIdentifier)")
    refreshDATDiscovery()
  }

  func don() {
    guard let mockDevice else {
      setError("Pair RayBan Meta before Don.")
      return
    }
    mockDevice.don()
    isPoweredOn = true
    isUnfolded = true
    isDonned = true
    AppLogger.log(.devices, "Mock RayBan Meta Don id=\(mockDevice.deviceIdentifier)")
    refreshDATDiscovery()
  }

  func selectBundledVideo() {
    guard let mockDevice else {
      setError("Pair RayBan Meta before selecting video.")
      return
    }
    guard let url = Bundle.main.url(forResource: "Compressed Video", withExtension: "mp4") else {
      setError("Mock video missing: add Compressed Video.mp4 to the CameraAccess target resources.")
      return
    }

    mockDevice.services.camera.setCameraFeed(fileURL: url)
    hasVideoFeed = true
    AppLogger.log(.devices, "Mock RayBan Meta camera feed set to \(url.lastPathComponent)")
    refreshDATDiscovery()
  }

  private func refreshDATDiscovery() {
    Task {
      await DATGlassesManager.shared.resumeAfterExternalAppReturn()
    }
  }

  private func setError(_ message: String) {
    lastMockErrorText = message
    AppLogger.log(.devices, "MockDeviceKit error: \(message)")
  }
}

#endif
