import CoreLocation
import Foundation

@MainActor
final class SceneLocationProvider: NSObject, CLLocationManagerDelegate {
  nonisolated private static let collectionDisabledForStreamPerformance = true
  private static var didLogDisabled = false

  private let manager = CLLocationManager()
  private var lastLocation: CLLocation?
  private var isActive = false

  override init() {
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    manager.distanceFilter = 25
  }

  func start(enabled: Bool) {
    guard !Self.collectionDisabledForStreamPerformance else {
      stop()
      lastLocation = nil
      if !Self.didLogDisabled {
        Self.didLogDisabled = true
        AppLogger.log(.streamPerf, "[LOCATION_PERF] disabled=true reads=0 reason=stream-cpu-battery")
      }
      return
    }
    guard enabled else {
      stop()
      return
    }
    isActive = true
    switch manager.authorizationStatus {
    case .notDetermined:
      manager.requestWhenInUseAuthorization()
    case .authorizedAlways, .authorizedWhenInUse:
      manager.startUpdatingLocation()
    case .denied, .restricted:
      AppLogger.log(.sceneContext, "Location context unavailable: permission denied or restricted")
    @unknown default:
      break
    }
  }

  func stop() {
    isActive = false
    manager.stopUpdatingLocation()
  }

  func currentSnapshot() -> SceneLocationSnapshot? {
    guard !Self.collectionDisabledForStreamPerformance else { return nil }
    guard let location = lastLocation else { return nil }
    return SceneLocationSnapshot(
      latitude: location.coordinate.latitude,
      longitude: location.coordinate.longitude,
      horizontalAccuracy: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil,
      label: String(
        format: "Approximate iPhone location (+/- %.0fm)",
        max(location.horizontalAccuracy, 0)
      ),
      capturedAt: location.timestamp
    )
  }

  nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    guard !Self.collectionDisabledForStreamPerformance else { return }
    Task { @MainActor in
      guard self.isActive else { return }
      switch manager.authorizationStatus {
      case .authorizedAlways, .authorizedWhenInUse:
        manager.startUpdatingLocation()
      case .denied, .restricted:
        AppLogger.log(.sceneContext, "Location context permission not granted")
      case .notDetermined:
        break
      @unknown default:
        break
      }
    }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard !Self.collectionDisabledForStreamPerformance else { return }
    guard let location = locations.last else { return }
    Task { @MainActor in
      self.lastLocation = location
    }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    guard !Self.collectionDisabledForStreamPerformance else { return }
    AppLogger.log(.sceneContext, "Location context failed: \(error.localizedDescription)")
  }
}
