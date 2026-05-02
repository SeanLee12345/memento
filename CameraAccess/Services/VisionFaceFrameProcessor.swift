import CoreMedia
import CoreVideo
import CoreGraphics
import CoreImage
import ImageIO
import UIKit
import Vision

actor VisionFaceFrameProcessor {
  private struct Track {
    var id: Int
    var personID: UUID
    var boundingBox: CGRect
    var faceImage: UIImage?
    var lastSeenSequence: UInt64
  }

  private var tracks: [Track] = []
  private var nextTrackID = 1
  private let identityResolver: FaceIdentityResolver
  private var loggedFirstFrameDebug = false
  private var loggedOrientationSweep = false
  private let ciContext = CIContext()

  init(identityResolver: FaceIdentityResolver = PlaceholderFaceIdentityResolver()) {
    self.identityResolver = identityResolver
  }

  func process(sampleBuffer: CMSampleBuffer, sequence: UInt64, forceTestFaceOverlay: Bool = false) async -> ProcessedVideoFrame? {
    await process(
      sampleBuffer: sampleBuffer,
      sequence: sequence,
      inputType: "CMSampleBuffer -> CVPixelBuffer",
      forceTestFaceOverlay: forceTestFaceOverlay
    )
  }

  private func process(
    sampleBuffer: CMSampleBuffer,
    sequence: UInt64,
    inputType: String,
    forceTestFaceOverlay: Bool
  ) async -> ProcessedVideoFrame? {
    let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
      AppLogger.log(.frames, "Dropped frame #\(sequence): CMSampleBufferGetImageBuffer returned nil")
      return nil
    }

    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    guard width > 0, height > 0 else {
      AppLogger.log(.frames, "Dropped frame #\(sequence): invalid CVPixelBuffer size \(width)x\(height)")
      return nil
    }

    guard let cgImage = makeDisplayCGImage(from: pixelBuffer) else {
      AppLogger.log(.frames, "Dropped frame #\(sequence): CoreImage could not create a display CGImage")
      return nil
    }
    let image = UIImage(cgImage: cgImage)

    return await process(
      image: image,
      cgImage: cgImage,
      pixelBuffer: pixelBuffer,
      sequence: sequence,
      timestamp: timestamp,
      inputType: inputType,
      forceTestFaceOverlay: forceTestFaceOverlay
    )
  }

  func process(image: UIImage, sequence: UInt64, forceTestFaceOverlay: Bool = false) async -> ProcessedVideoFrame? {
    guard let cgImage = image.cgImage else {
      AppLogger.log(.frames, "Dropped frame #\(sequence): UIImage.cgImage returned nil")
      return nil
    }

    return await process(
      image: image,
      cgImage: cgImage,
      pixelBuffer: nil,
      sequence: sequence,
      timestamp: nil,
      inputType: "UIImage",
      forceTestFaceOverlay: forceTestFaceOverlay
    )
  }

  private func process(
    image: UIImage,
    cgImage: CGImage,
    pixelBuffer: CVPixelBuffer?,
    sequence: UInt64,
    timestamp: CMTime?,
    inputType: String,
    forceTestFaceOverlay: Bool
  ) async -> ProcessedVideoFrame {
    logFirstFrameDebugIfNeeded(
      sequence: sequence,
      image: image,
      cgImage: cgImage,
      pixelBuffer: pixelBuffer,
      timestamp: timestamp,
      inputType: inputType
    )

    guard cgImage.width > 0, cgImage.height > 0 else {
      AppLogger.log(.frames, "Dropped frame #\(sequence): invalid CGImage size \(cgImage.width)x\(cgImage.height)")
      return ProcessedVideoFrame(
        sequence: sequence,
        image: image,
        imageSize: .zero,
        faces: [],
        people: [],
        processedAt: Date()
      )
    }

    let startedAt = Date()
    let boxes: [CGRect]
    if forceTestFaceOverlay {
      boxes = [CGRect(x: 0.34, y: 0.30, width: 0.28, height: 0.34)]
    } else {
      boxes = detectFaceBoxes(
        displayCGImage: cgImage,
        pixelBuffer: pixelBuffer,
        imageOrientation: image.imageOrientation,
        sequence: sequence
      )
    }

    let safeBoxes = boxes.compactMap {
      Self.safeNormalizedFaceBox($0, imageSize: CGSize(width: cgImage.width, height: cgImage.height))
    }
    var faces = updateTracks(with: safeBoxes, cgImage: cgImage, sequence: sequence)
    for index in faces.indices {
      if let name = await identityResolver.displayName(for: faces[index], in: cgImage) {
        faces[index] = DetectedFace(id: faces[index].id, boundingBox: faces[index].boundingBox, displayName: name)
      }
    }

    let people = currentPeople()
    let durationMS = Date().timeIntervalSince(startedAt) * 1_000
    AppLogger.log(.vision, "Processed frame #\(sequence): faces=\(faces.count), durationMs=\(String(format: "%.1f", durationMS))")
    return ProcessedVideoFrame(
      sequence: sequence,
      image: image,
      imageSize: CGSize(width: cgImage.width, height: cgImage.height),
      faces: faces,
      people: people,
      processedAt: Date()
    )
  }

  private func detectFaceBoxes(
    displayCGImage: CGImage,
    pixelBuffer: CVPixelBuffer?,
    imageOrientation: UIImage.Orientation,
    sequence: UInt64
  ) -> [CGRect] {
    let preferredOrientation = preferredVisionOrientation(
      imageOrientation: imageOrientation,
      pixelBuffer: pixelBuffer,
      cgImage: displayCGImage
    )

    if let boxes = runFaceDetection(
      cgImage: displayCGImage,
      pixelBuffer: pixelBuffer,
      orientation: preferredOrientation
    ), !boxes.isEmpty {
      AppLogger.log(.vision, "VNDetectFaceRectanglesRequest frame #\(sequence): orientation=\(preferredOrientation.debugName), faces=\(boxes.count)")
      return boxes
    }

    let orientations: [CGImagePropertyOrientation] = [.up, .right, .left, .down]
    var sweepResults: [(CGImagePropertyOrientation, Int)] = []
    for orientation in orientations where orientation != preferredOrientation {
      guard let boxes = runFaceDetection(
        cgImage: displayCGImage,
        pixelBuffer: pixelBuffer,
        orientation: orientation
      ) else {
        sweepResults.append((orientation, -1))
        continue
      }
      sweepResults.append((orientation, boxes.count))
      if !boxes.isEmpty {
        AppLogger.log(.vision, "VNDetectFaceRectanglesRequest frame #\(sequence): preferred=\(preferredOrientation.debugName) returned 0; orientation=\(orientation.debugName) faces=\(boxes.count)")
        return boxes
      }
    }

    if !loggedOrientationSweep {
      loggedOrientationSweep = true
      let summary = sweepResults
        .map { "\($0.0.debugName)=\($0.1)" }
        .joined(separator: ", ")
      AppLogger.log(.vision, "VNDetectFaceRectanglesRequest frame #\(sequence): no faces. preferred=\(preferredOrientation.debugName)=0; sweep[\(summary)]")
    }
    return []
  }

  private func runFaceDetection(
    cgImage: CGImage,
    pixelBuffer: CVPixelBuffer?,
    orientation: CGImagePropertyOrientation
  ) -> [CGRect]? {
    let request = VNDetectFaceRectanglesRequest()
    request.usesCPUOnly = true
    if let pixelBuffer {
      let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
      do {
        try handler.perform([request])
        return (request.results ?? []).map(\.boundingBox)
      } catch {
        AppLogger.log(.vision, "VNDetectFaceRectanglesRequest failed on CVPixelBuffer orientation=\(orientation.debugName): \(error.localizedDescription). Retrying sRGB CGImage.")
      }
    }

    let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
    do {
      try handler.perform([request])
      return (request.results ?? []).map(\.boundingBox)
    } catch {
      AppLogger.log(.vision, "VNDetectFaceRectanglesRequest failed: \(error.localizedDescription)")
      return nil
    }
  }

  private func makeDisplayCGImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    guard width > 0, height > 0 else { return nil }
    let image = CIImage(cvPixelBuffer: pixelBuffer)
    return ciContext.createCGImage(image, from: CGRect(x: 0, y: 0, width: width, height: height))
  }

  private func preferredVisionOrientation(
    imageOrientation: UIImage.Orientation,
    pixelBuffer: CVPixelBuffer?,
    cgImage: CGImage
  ) -> CGImagePropertyOrientation {
    // File-decoded sample buffers can carry landscape pixel buffers while the
    // display image is portrait. Try UIImage orientation first when meaningful;
    // otherwise choose by buffer shape and let the orientation sweep correct it.
    let uiOrientation = CGImagePropertyOrientation(imageOrientation)
    guard uiOrientation == .up, let pixelBuffer else { return uiOrientation }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    if width > height, cgImage.height > cgImage.width {
      return .right
    }
    return .up
  }

  private func logFirstFrameDebugIfNeeded(
    sequence: UInt64,
    image: UIImage,
    cgImage: CGImage,
    pixelBuffer: CVPixelBuffer?,
    timestamp: CMTime?,
    inputType: String
  ) {
    guard !loggedFirstFrameDebug else { return }
    loggedFirstFrameDebug = true

    let pixelSize: String
    if let pixelBuffer {
      pixelSize = "\(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer))"
    } else {
      pixelSize = "nil"
    }

    let timestampText: String
    if let timestamp, timestamp.isValid {
      timestampText = String(format: "%.3f", CMTimeGetSeconds(timestamp))
    } else {
      timestampText = "nil"
    }

    AppLogger.log(
      .vision,
      "First Vision frame #\(sequence): input=\(inputType), cgImage=\(cgImage.width)x\(cgImage.height), pixelBuffer=\(pixelSize), uiOrientation=\(image.imageOrientation.debugName), timestamp=\(timestampText)"
    )
  }

  static func clampedImageRect(forNormalizedFaceBox box: CGRect, imageSize: CGSize) -> CGRect? {
    guard imageSize.width > 0, imageSize.height > 0 else { return nil }
    let imageBounds = CGRect(origin: .zero, size: imageSize)
    let pixelRect = CGRect(
      x: box.minX * imageSize.width,
      y: (1 - box.maxY) * imageSize.height,
      width: box.width * imageSize.width,
      height: box.height * imageSize.height
    )
    let safeRect = pixelRect.intersection(imageBounds)
    guard !safeRect.isNull, safeRect.width > 0, safeRect.height > 0 else { return nil }
    assert(safeRect.maxX <= imageBounds.maxX)
    assert(safeRect.maxY <= imageBounds.maxY)
    return safeRect.integral.intersection(imageBounds)
  }

  static func safeNormalizedFaceBox(_ box: CGRect, imageSize: CGSize) -> CGRect? {
    guard let safeRect = clampedImageRect(forNormalizedFaceBox: box, imageSize: imageSize) else { return nil }
    let normalized = CGRect(
      x: safeRect.minX / imageSize.width,
      y: 1 - (safeRect.maxY / imageSize.height),
      width: safeRect.width / imageSize.width,
      height: safeRect.height / imageSize.height
    )
    let unitBounds = CGRect(x: 0, y: 0, width: 1, height: 1)
    let safeNormalized = normalized.intersection(unitBounds)
    guard !safeNormalized.isNull, safeNormalized.width > 0, safeNormalized.height > 0 else { return nil }
    return safeNormalized
  }

  private func updateTracks(with boxes: [CGRect], cgImage: CGImage, sequence: UInt64) -> [DetectedFace] {
    var updatedTracks: [Track] = []
    var usedTrackIDs = Set<Int>()

    for box in boxes {
      let thumbnail = makeFaceThumbnail(from: cgImage, normalizedBox: box)
      if let matchedTrack = bestMatchingTrack(for: box, excluding: usedTrackIDs) {
        usedTrackIDs.insert(matchedTrack.id)
        updatedTracks.append(Track(
          id: matchedTrack.id,
          personID: matchedTrack.personID,
          boundingBox: box,
          faceImage: thumbnail ?? matchedTrack.faceImage,
          lastSeenSequence: sequence
        ))
      } else {
        let id = nextTrackID
        nextTrackID += 1
        updatedTracks.append(Track(
          id: id,
          personID: UUID(),
          boundingBox: box,
          faceImage: thumbnail,
          lastSeenSequence: sequence
        ))
      }
    }

    tracks = updatedTracks + tracks.filter { previous in
      !usedTrackIDs.contains(previous.id) && sequence > previous.lastSeenSequence && sequence - previous.lastSeenSequence < 12
    }

    return updatedTracks.map {
      DetectedFace(id: $0.id, boundingBox: $0.boundingBox, displayName: "Person \($0.id)")
    }
  }

  private func bestMatchingTrack(for box: CGRect, excluding usedTrackIDs: Set<Int>) -> Track? {
    tracks
      .filter { !usedTrackIDs.contains($0.id) }
      .map { track in (track: track, score: intersectionOverUnion(box, track.boundingBox)) }
      .filter { $0.score > 0.20 }
      .max { $0.score < $1.score }?
      .track
  }

  private func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
    let intersection = lhs.intersection(rhs)
    guard !intersection.isNull else { return 0 }
    let intersectionArea = intersection.width * intersection.height
    let unionArea = lhs.width * lhs.height + rhs.width * rhs.height - intersectionArea
    guard unionArea > 0 else { return 0 }
    return intersectionArea / unionArea
  }

  private func makeFaceThumbnail(from cgImage: CGImage, normalizedBox: CGRect) -> UIImage? {
    guard let safeRect = Self.clampedImageRect(
      forNormalizedFaceBox: normalizedBox,
      imageSize: CGSize(width: cgImage.width, height: cgImage.height)
    ) else {
      return nil
    }
    guard let cropped = cgImage.cropping(to: safeRect) else {
      AppLogger.log(.vision, "Face thumbnail crop failed for safeRect=\(safeRect)")
      return nil
    }
    return UIImage(cgImage: cropped)
  }

  private func currentPeople() -> [Person] {
    tracks
      .compactMap { track -> Person? in
        guard let faceImage = track.faceImage else { return nil }
        return Person(
          id: track.personID,
          displayName: "Person \(track.id)",
          faceImage: faceImage,
          lastSeen: Date()
        )
      }
      .sorted { $0.displayName < $1.displayName }
  }
}

private extension CGImagePropertyOrientation {
  init(_ orientation: UIImage.Orientation) {
    switch orientation {
    case .up:
      self = .up
    case .upMirrored:
      self = .upMirrored
    case .down:
      self = .down
    case .downMirrored:
      self = .downMirrored
    case .left:
      self = .left
    case .leftMirrored:
      self = .leftMirrored
    case .right:
      self = .right
    case .rightMirrored:
      self = .rightMirrored
    @unknown default:
      self = .up
    }
  }

  var debugName: String {
    switch self {
    case .up:
      return "up"
    case .upMirrored:
      return "upMirrored"
    case .down:
      return "down"
    case .downMirrored:
      return "downMirrored"
    case .left:
      return "left"
    case .leftMirrored:
      return "leftMirrored"
    case .right:
      return "right"
    case .rightMirrored:
      return "rightMirrored"
    }
  }
}

private extension UIImage.Orientation {
  var debugName: String {
    switch self {
    case .up:
      return "up"
    case .upMirrored:
      return "upMirrored"
    case .down:
      return "down"
    case .downMirrored:
      return "downMirrored"
    case .left:
      return "left"
    case .leftMirrored:
      return "leftMirrored"
    case .right:
      return "right"
    case .rightMirrored:
      return "rightMirrored"
    @unknown default:
      return "unknown"
    }
  }
}
