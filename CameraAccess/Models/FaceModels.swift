import CoreGraphics
import UIKit

struct DetectedFace: Identifiable, Equatable {
  let id: Int
  let boundingBox: CGRect
  let displayName: String
}

struct Person: Identifiable, Equatable {
  let id: UUID
  var displayName: String
  var faceImage: UIImage
  var lastSeen: Date
}

struct TranscriptEntry: Identifiable, Equatable {
  let id: UUID
  let text: String
  let timestamp: TimeInterval
  let isFinal: Bool
}

struct ProcessedVideoFrame {
  let sequence: UInt64
  let image: UIImage
  let imageSize: CGSize
  let faces: [DetectedFace]
  let people: [Person]
  let processedAt: Date
}

enum StreamLifecycleState: String, Equatable {
  case stopped = "STOPPED"
  case waiting = "WAITING"
  case starting = "STARTING"
  case running = "RUNNING"
  case paused = "PAUSED"
  case stopping = "STOPPING"
  case error = "ERROR"

  var isStreamingSurfaceVisible: Bool {
    switch self {
    case .waiting, .starting, .running, .paused, .stopping:
      return true
    case .stopped, .error:
      return false
    }
  }
}

enum InputMode: String, CaseIterable, Equatable {
  case realGlasses = "REAL GLASSES"
  case mockDeviceKit = "MOCK DEVICE KIT"
  case simulation = "SIMULATION"

  static var defaultMode: InputMode {
    #if targetEnvironment(simulator)
    return .simulation
    #else
    return .realGlasses
    #endif
  }
}

enum DATConfigurationMode: String, Equatable {
  case developerMode = "developerMode"
  case production = "production"
}

enum DATConnectionStage: String, Equatable {
  case sdkConfigured
  case registrationAvailable
  case registrationStarting
  case waitingForMetaAIRegistration
  case registered
  case requestingCameraPermission
  case cameraPermissionGranted
  case discoveringDevices
  case deviceSelected
  case deviceSessionReady
  case streamReady
  case streaming
}

protocol FaceIdentityResolver {
  func displayName(for face: DetectedFace, in image: CGImage) async -> String?
}

struct PlaceholderFaceIdentityResolver: FaceIdentityResolver {
  func displayName(for face: DetectedFace, in image: CGImage) async -> String? {
    nil
  }
}
