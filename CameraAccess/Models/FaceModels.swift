import CoreGraphics
import CoreMedia
import CoreVideo
import UIKit

struct LiveFrameImageSource {
  let pixelBuffer: CVPixelBuffer?
  let sampleBuffer: CMSampleBuffer?
  let uiImage: UIImage?
  let width: Int
  let height: Int
  let orientation: CGImagePropertyOrientation
  let mirrored: Bool
  let timestamp: Date?
  let frameIndex: UInt64
  let sourceDescription: String
}

struct DetectedFace: Identifiable, Equatable {
  let id: Int
  let boundingBox: CGRect
  let displayName: String
  let mouthOpenRatio: Float?
  let mouthMovementScore: Float

  init(
    id: Int,
    boundingBox: CGRect,
    displayName: String,
    mouthOpenRatio: Float? = nil,
    mouthMovementScore: Float = 0
  ) {
    self.id = id
    self.boundingBox = boundingBox
    self.displayName = displayName
    self.mouthOpenRatio = mouthOpenRatio
    self.mouthMovementScore = mouthMovementScore
  }
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
  var startedAt: Date? = nil
  var endedAt: Date? = nil
  var source: String = "AppleSpeech"
}

struct ProcessedVideoFrame {
  let sequence: UInt64
  let image: UIImage
  let imageSize: CGSize
  let faces: [DetectedFace]
  let people: [Person]
  let processedAt: Date
  let identityCandidates: [IdentityCandidate]
  let pipelineContext: PipelineContext?
  let faceDetectionEvent: FaceDetectionEvent?
  let alignmentFailures: Int

  init(
    sequence: UInt64,
    image: UIImage,
    imageSize: CGSize,
    faces: [DetectedFace],
    people: [Person],
    processedAt: Date,
    identityCandidates: [IdentityCandidate] = [],
    pipelineContext: PipelineContext? = nil,
    faceDetectionEvent: FaceDetectionEvent? = nil,
    alignmentFailures: Int = 0
  ) {
    self.sequence = sequence
    self.image = image
    self.imageSize = imageSize
    self.faces = faces
    self.people = people
    self.processedAt = processedAt
    self.identityCandidates = identityCandidates
    self.pipelineContext = pipelineContext
    self.faceDetectionEvent = faceDetectionEvent
    self.alignmentFailures = alignmentFailures
  }
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
}

enum PhoneVideoFootagePolicy {
  static func hidesFootage(inputMode: InputMode, lifecycleState: StreamLifecycleState) -> Bool {
    inputMode == .realGlasses && lifecycleState.isStreamingSurfaceVisible
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
