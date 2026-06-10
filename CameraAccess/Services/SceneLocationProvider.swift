import CoreLocation
import Foundation

@MainActor
final class SceneLocationProvider: NSObject, CLLocationManagerDelegate {
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
    guard let location = locations.last else { return }
    Task { @MainActor in
      self.lastLocation = location
    }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    AppLogger.log(.sceneContext, "Location context failed: \(error.localizedDescription)")
  }
}
