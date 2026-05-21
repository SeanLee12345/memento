import CoreMedia
import CoreVideo
import CoreGraphics
import CoreImage
import ImageIO
import UIKit
import Vision

actor VisionFaceFrameProcessor {
  private struct FaceDetectionOutput {
    let observations: [VNFaceObservation]
    let selectedOrientation: CGImagePropertyOrientation
    let preferredOrientation: CGImagePropertyOrientation
    let preferredFaceCount: Int
    let orientationCounts: [CGImagePropertyOrientation: Int]
    let usedSweep: Bool
  }

  private struct Track {
    var id: Int
    var personID: UUID
    var boundingBox: CGRect
    var faceImage: UIImage?
    var lastMouthOpenRatio: Float?
    var mouthMovementScore: Float
    var lastSeenSequence: UInt64
  }

  private var tracks: [Track] = []
  private var nextTrackID = 1
  private let identityResolver: FaceIdentityResolver
  private var loggedFirstFrameDebug = false
  private let ciContext = CIContext()
  private let faceQualityFilter = FaceQualityFilter()
  private let verboseFrameLogging = ProcessInfo.processInfo.arguments.contains("--verbose-frame-logging")
  private var visionStatsStartedAt = Date()
  private var visionStatsProcessedFrames: UInt64 = 0
  private var visionStatsFaces: UInt64 = 0
  private var visionStatsDurationMS: Double = 0
  private var facePipelineStatsStartedAt = Date()
  private var facePipelineFramesSeen: UInt64 = 0
  private var facePipelineVisionProcessed: UInt64 = 0
  private var facePipelineFacesDetected: UInt64 = 0
  private var facePipelineCropsSucceeded: UInt64 = 0
  private var facePipelineCropsRejected: UInt64 = 0
  private var facePipelineQualityAccepted: UInt64 = 0
  private var facePipelineEnrollmentAccepted: UInt64 = 0
  private var facePipelineQualityRejected: UInt64 = 0
  private var facePipelineVisionDurationMS: Double = 0
  private var facePipelineCropDurationMS: Double = 0
  private var facePipelineQualityDurationMS: Double = 0
  private var facePipelineSelectedOrientation = "none"

  init(identityResolver: FaceIdentityResolver = PlaceholderFaceIdentityResolver()) {
    self.identityResolver = identityResolver
  }

  func process(
    sampleBuffer: CMSampleBuffer,
    sequence: UInt64,
    forceTestFaceOverlay: Bool = false,
    context: PipelineContext? = nil
  ) async -> ProcessedVideoFrame? {
    await process(
      sampleBuffer: sampleBuffer,
      sequence: sequence,
      inputType: "CMSampleBuffer -> CVPixelBuffer",
      forceTestFaceOverlay: forceTestFaceOverlay,
      context: context
    )
  }

  private func process(
    sampleBuffer: CMSampleBuffer,
    sequence: UInt64,
    inputType: String,
    forceTestFaceOverlay: Bool,
    context: PipelineContext?
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
    AppLogger.log(.visionInput, "\(context.logPrefix) frame=\(sequence) input=CVPixelBuffer width=\(width) height=\(height) orientation=up mirrored=false")
    let image = UIImage(cgImage: cgImage)

    return await process(
      image: image,
      cgImage: cgImage,
      pixelBuffer: pixelBuffer,
      sequence: sequence,
      timestamp: timestamp,
      inputType: inputType,
      forceTestFaceOverlay: forceTestFaceOverlay,
      context: context
    )
  }

  func process(
    image: UIImage,
    sequence: UInt64,
    forceTestFaceOverlay: Bool = false,
    context: PipelineContext? = nil
  ) async -> ProcessedVideoFrame? {
    guard let cgImage = image.cgImage else {
      AppLogger.log(.frames, "Dropped frame #\(sequence): UIImage.cgImage returned nil")
      return nil
    }
    AppLogger.log(.visionInput, "\(context.logPrefix) frame=\(sequence) input=UIImage fallback=true reason=pixelBufferUnavailable width=\(cgImage.width) height=\(cgImage.height) orientation=\(Self.cgImagePropertyOrientation(for: image.imageOrientation).debugName)")

    return await process(
      image: image,
      cgImage: cgImage,
      pixelBuffer: nil,
      sequence: sequence,
      timestamp: nil,
      inputType: "UIImage",
      forceTestFaceOverlay: forceTestFaceOverlay,
      context: context
    )
  }

  private func process(
    image: UIImage,
    cgImage: CGImage,
    pixelBuffer: CVPixelBuffer?,
    sequence: UInt64,
    timestamp: CMTime?,
    inputType: String,
    forceTestFaceOverlay: Bool,
    context: PipelineContext?
  ) async -> ProcessedVideoFrame {
    logFirstFrameDebugIfNeeded(
      sequence: sequence,
      image: image,
      cgImage: cgImage,
      pixelBuffer: pixelBuffer,
      timestamp: timestamp,
      inputType: inputType,
      context: context
    )

    guard cgImage.width > 0, cgImage.height > 0 else {
      AppLogger.log(.frames, "Dropped frame #\(sequence): invalid CGImage size \(cgImage.width)x\(cgImage.height)")
      return ProcessedVideoFrame(
        sequence: sequence,
        image: image,
        imageSize: .zero,
        faces: [],
        people: [],
        processedAt: Date(),
        pipelineContext: context,
        faceDetectionEvent: nil
      )
    }

    let startedAt = Date()
    let detection: FaceDetectionOutput
    if forceTestFaceOverlay {
      let observation = VNFaceObservation(boundingBox: CGRect(x: 0.34, y: 0.30, width: 0.28, height: 0.34))
      detection = FaceDetectionOutput(
        observations: [observation],
        selectedOrientation: .up,
        preferredOrientation: .up,
        preferredFaceCount: 1,
        orientationCounts: [.up: 1],
        usedSweep: false
      )
    } else {
      detection = detectFaceObservations(
        displayCGImage: cgImage,
        pixelBuffer: pixelBuffer,
        imageOrientation: image.imageOrientation,
        sequence: sequence,
        context: context
      )
    }

    let observations = detection.observations
    let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
    let trackedInputs = observations.compactMap { observation -> FaceTrackInput? in
      guard let box = Self.safeNormalizedFaceBox(observation.boundingBox, imageSize: imageSize) else {
        return nil
      }
      return FaceTrackInput(
        boundingBox: box,
        mouthOpenRatio: Self.mouthOpenRatio(for: observation)
      )
    }
    var faces = updateTracks(with: trackedInputs, cgImage: cgImage, sequence: sequence)
    for index in faces.indices {
      if let name = await identityResolver.displayName(for: faces[index], in: cgImage) {
        faces[index] = DetectedFace(id: faces[index].id, boundingBox: faces[index].boundingBox, displayName: name)
      }
    }

    let people = currentPeople()
    let candidateOutput = buildIdentityCandidates(
      observations: observations,
      cgImage: cgImage,
      sequence: sequence,
      orientation: detection.selectedOrientation,
      context: context
    )
    let faceDetectionEvent = makeFaceDetectionEvent(
      context: context,
      sequence: sequence,
      image: image,
      cgImage: cgImage,
      detection: detection
    )
    let identityCandidates = candidateOutput.candidates

    // Update the overlay bounding boxes to show the padded crop area instead of Vision's tight
    // raw detection box. The raw box intentionally excludes hair/forehead and chin; the padded
    // box is what the crop pipeline actually captures and is more informative for the user.
    let imageW = CGFloat(cgImage.width)
    let imageH = CGFloat(cgImage.height)
    if imageW > 0, imageH > 0 {
      faces = faces.map { face in
        guard let candidate = identityCandidates.first(where: {
          intersectionOverUnion(face.boundingBox, $0.crop.faceBoundingBoxNormalized) > 0.25
        }) else { return face }
        let p = candidate.crop.faceBoundingBoxPixels
        // Convert pixel rect (top-left origin) → Vision-style normalized (bottom-left origin)
        let paddedNorm = CGRect(
          x: p.minX / imageW,
          y: 1.0 - p.maxY / imageH,
          width: p.width / imageW,
          height: p.height / imageH
        )
        return DetectedFace(
          id: face.id,
          boundingBox: paddedNorm,
          displayName: face.displayName,
          mouthOpenRatio: face.mouthOpenRatio,
          mouthMovementScore: face.mouthMovementScore
        )
      }
    }

    let durationMS = Date().timeIntervalSince(startedAt) * 1_000
    recordVisionStats(sequence: sequence, faceCount: faces.count, durationMS: durationMS)
    recordFacePipelineStats(
      context: context,
      facesDetected: observations.count,
      cropsSucceeded: candidateOutput.cropsSucceeded,
      cropsRejected: max(0, observations.count - candidateOutput.cropsSucceeded),
      qualityAccepted: candidateOutput.qualityAccepted,
      enrollmentAccepted: candidateOutput.enrollmentAccepted,
      qualityRejected: max(0, candidateOutput.cropsSucceeded - candidateOutput.qualityAccepted),
      visionDurationMS: durationMS,
      cropDurationMS: candidateOutput.cropDurationMS,
      qualityDurationMS: candidateOutput.qualityDurationMS,
      selectedOrientation: detection.selectedOrientation
    )
    return ProcessedVideoFrame(
      sequence: sequence,
      image: image,
      imageSize: CGSize(width: cgImage.width, height: cgImage.height),
      faces: faces,
      people: people,
      processedAt: Date(),
      identityCandidates: identityCandidates,
      pipelineContext: context,
      faceDetectionEvent: faceDetectionEvent,
      alignmentFailures: candidateOutput.alignmentFailures
    )
  }

  private func detectFaceObservations(
    displayCGImage: CGImage,
    pixelBuffer: CVPixelBuffer?,
    imageOrientation: UIImage.Orientation,
    sequence: UInt64,
    context: PipelineContext?
  ) -> FaceDetectionOutput {
    let preferredOrientation = preferredVisionOrientation(
      imageOrientation: imageOrientation,
      pixelBuffer: pixelBuffer,
      cgImage: displayCGImage
    )
    let shouldSweep = FaceVisionDebugPipeline.shouldRunOrientationSweep(frame: sequence, verbose: verboseFrameLogging)

    let preferredObservations = runFaceDetection(
      cgImage: displayCGImage,
      pixelBuffer: pixelBuffer,
      orientation: preferredOrientation,
      includeQuality: true
    ) ?? []

    var counts: [CGImagePropertyOrientation: Int] = [preferredOrientation: preferredObservations.count]
    var observationsByOrientation: [CGImagePropertyOrientation: [VNFaceObservation]] = [preferredOrientation: preferredObservations]

    if !shouldSweep {
      logOrientationDiagnostic(
        context: context,
        sequence: sequence,
        imageSize: CGSize(width: displayCGImage.width, height: displayCGImage.height),
        imageOrientation: imageOrientation,
        preferredOrientation: preferredOrientation,
        selectedOrientation: preferredOrientation,
        counts: counts,
        usedSweep: false,
        preferredCount: preferredObservations.count
      )
      return FaceDetectionOutput(
        observations: preferredObservations,
        selectedOrientation: preferredOrientation,
        preferredOrientation: preferredOrientation,
        preferredFaceCount: preferredObservations.count,
        orientationCounts: counts,
        usedSweep: false
      )
    }

    let orientations = FaceVisionDebugPipeline.sweepOrientations
    for orientation in orientations where orientation != preferredOrientation {
      let observations = runFaceDetection(
        cgImage: displayCGImage,
        pixelBuffer: pixelBuffer,
        orientation: orientation,
        includeQuality: shouldSweep
      ) ?? []
      counts[orientation] = observations.count
      observationsByOrientation[orientation] = observations
    }

    let selectedOrientation = orientations.max { lhs, rhs in
      (counts[lhs] ?? 0) < (counts[rhs] ?? 0)
    } ?? preferredOrientation
    let selectedCount = counts[selectedOrientation] ?? 0
    let selectedObservations: [VNFaceObservation]
    if selectedOrientation == preferredOrientation {
      selectedObservations = preferredObservations
    } else if shouldSweep {
      selectedObservations = observationsByOrientation[selectedOrientation] ?? []
    } else {
      selectedObservations = runFaceDetection(
        cgImage: displayCGImage,
        pixelBuffer: pixelBuffer,
        orientation: selectedOrientation,
        includeQuality: true
      ) ?? []
    }

    if selectedCount == 0 {
      AppLogger.log(
        .visionOrientation,
        "\(context.logPrefix) frame=\(sequence) noFacesAllOrientations image=\(displayCGImage.width)x\(displayCGImage.height) uiOrientation=\(imageOrientation.debugName) mappedCG=\(preferredOrientation.debugName)"
      )
    }

    logOrientationDiagnostic(
      context: context,
      sequence: sequence,
      imageSize: CGSize(width: displayCGImage.width, height: displayCGImage.height),
      imageOrientation: imageOrientation,
      preferredOrientation: preferredOrientation,
      selectedOrientation: selectedOrientation,
      counts: counts,
      usedSweep: shouldSweep,
      preferredCount: preferredObservations.count
    )
    return FaceDetectionOutput(
      observations: selectedObservations,
      selectedOrientation: selectedOrientation,
      preferredOrientation: preferredOrientation,
      preferredFaceCount: preferredObservations.count,
      orientationCounts: counts,
      usedSweep: shouldSweep
    )
  }

  private func logOrientationDiagnostic(
    context: PipelineContext?,
    sequence: UInt64,
    imageSize: CGSize,
    imageOrientation: UIImage.Orientation,
    preferredOrientation: CGImagePropertyOrientation,
    selectedOrientation: CGImagePropertyOrientation,
    counts: [CGImagePropertyOrientation: Int],
    usedSweep: Bool,
    preferredCount: Int
  ) {
    let reason = FaceVisionDebugPipeline.selectionReason(
      selected: selectedOrientation,
      mapped: preferredOrientation,
      usedSweep: usedSweep
    )
    AppLogger.log(
      .visionOrientation,
      "\(context.logPrefix) frame=\(sequence) image=\(Int(imageSize.width))x\(Int(imageSize.height)) uiOrientation=\(imageOrientation.debugName) mappedCG=\(preferredOrientation.debugName) preferredCount=\(preferredCount) sweep=\(FaceVisionDebugPipeline.orientationCountsText(counts)) selected=\(selectedOrientation.debugName) reason=\(reason)"
    )
  }

  private func orientationSummary(_ counts: [CGImagePropertyOrientation: Int]) -> String {
    return FaceVisionDebugPipeline.sweepOrientations
      .map { "\($0.debugName)=\(counts[$0] ?? -1)" }
      .joined(separator: ", ")
  }

  private struct IdentityCandidateBuildOutput {
    let candidates: [IdentityCandidate]
    let cropsSucceeded: Int
    let qualityAccepted: Int
    let enrollmentAccepted: Int
    let cropDurationMS: Double
    let qualityDurationMS: Double
    let alignmentFailures: Int
  }

  private func buildIdentityCandidates(
    observations: [VNFaceObservation],
    cgImage: CGImage,
    sequence: UInt64,
    orientation: CGImagePropertyOrientation,
    context: PipelineContext?
  ) -> IdentityCandidateBuildOutput {
    let cropStartedAt = Date()
    let cropResult = FaceCropper.cropFaces(
      observations: observations,
      from: cgImage,
      sequence: sequence,
      orientation: orientation,
      context: context
    )
    let crops = cropResult.crops
    let alignmentFailures = cropResult.alignmentFailures
    let cropDurationMS = Date().timeIntervalSince(cropStartedAt) * 1_000
    let qualityStartedAt = Date()
    let largestArea = crops.map { $0.faceBoundingBoxPixels.width * $0.faceBoundingBoxPixels.height }.max() ?? 0
    let candidates = crops.map { crop in
      let isDominant = crop.faceBoundingBoxPixels.width * crop.faceBoundingBoxPixels.height >= largestArea
      let quality = IdentityConfig.enableFaceQualityFilter
        ? faceQualityFilter.evaluate(crop, faceCount: crops.count, isDominantFace: isDominant)
        : FaceQualityDecision(
          detected: true,
          cropSucceeded: true,
          rawFaceWidth: Int(crop.rawFaceBoundingBoxPixels.width),
          rawFaceHeight: Int(crop.rawFaceBoundingBoxPixels.height),
          accepted: true,
          score: crop.faceCaptureQuality,
          reasons: [],
          rejectionReasons: [],
          normalizedFaceArea: Float((crop.faceBoundingBoxPixels.width * crop.faceBoundingBoxPixels.height) / max(crop.sourceImageSize.width * crop.sourceImageSize.height, 1)),
          cropSize: CGSize(width: crop.croppedImage.width, height: crop.croppedImage.height),
          visionQuality: crop.faceCaptureQuality,
          cropWidth: crop.croppedImage.width,
          cropHeight: crop.croppedImage.height,
          brightness: nil,
          sharpness: nil,
          faceAreaRatio: Float((crop.faceBoundingBoxPixels.width * crop.faceBoundingBoxPixels.height) / max(crop.sourceImageSize.width * crop.sourceImageSize.height, 1)),
          centerOffset: 0,
          passes: true,
          rejectReason: nil,
          tier: .preferredEnrollment,
          acceptedForRecognition: true,
          acceptedForEnrollment: true
        )
      return IdentityCandidate(crop: crop, quality: quality)
    }
    let qualityDurationMS = Date().timeIntervalSince(qualityStartedAt) * 1_000
    let accepted = candidates.filter(\.quality.accepted).count
    let enrollmentAccepted = candidates.filter(\.quality.acceptedForEnrollment).count
    if verboseFrameLogging || sequence % 30 == 0 {
      let rejectedReasons = candidates
        .filter { !$0.quality.acceptedForRecognition }
        .flatMap(\.quality.reasons)
        .prefix(3)
        .joined(separator: ", ")
      AppLogger.log(.frames, "\(context.logPrefix) [FACE] detected=\(observations.count) crops=\(crops.count) acceptedForRecognition=\(accepted) acceptedForEnrollment=\(enrollmentAccepted) rejected=\(candidates.count - accepted) reasons=\(rejectedReasons)")
    }
    for (index, candidate) in candidates.enumerated() where verboseFrameLogging || sequence <= 20 || sequence % 30 == 0 {
      AppLogger.log(
        .faceQuality,
        "\(context.logPrefix) frame=\(sequence) face=\(index) quality=\(candidate.quality.visionQuality.map { String(format: "%.2f", $0) } ?? "nil") score=\(candidate.quality.score.map { String(format: "%.2f", $0) } ?? "nil") brightness=\(candidate.quality.brightness.map { String(format: "%.2f", $0) } ?? "nil") areaRatio=\(String(format: "%.3f", candidate.quality.faceAreaRatio)) centerOffset=\(String(format: "%.3f", candidate.quality.centerOffset)) pass=\(candidate.quality.passes) finalAcceptedForRecognition=\(candidate.quality.acceptedForRecognition) finalAcceptedForEnrollment=\(candidate.quality.acceptedForEnrollment) tier=\(candidate.quality.tier.rawValue) width=\(candidate.quality.cropWidth) height=\(candidate.quality.cropHeight) rawWidth=\(candidate.quality.rawFaceWidth) rawHeight=\(candidate.quality.rawFaceHeight) yaw=\(candidate.crop.yaw.map { String(format: "%.2f", $0) } ?? "nil") pitch=\(candidate.crop.pitch.map { String(format: "%.2f", $0) } ?? "nil") roll=\(candidate.crop.roll.map { String(format: "%.2f", $0) } ?? "nil") reason=\(candidate.quality.rejectReason ?? "accepted")"
      )
    }
    return IdentityCandidateBuildOutput(
      candidates: candidates,
      cropsSucceeded: crops.count,
      qualityAccepted: accepted,
      enrollmentAccepted: enrollmentAccepted,
      cropDurationMS: cropDurationMS,
      qualityDurationMS: qualityDurationMS,
      alignmentFailures: alignmentFailures
    )
  }

  private func recordFacePipelineStats(
    context: PipelineContext?,
    facesDetected: Int,
    cropsSucceeded: Int,
    cropsRejected: Int,
    qualityAccepted: Int,
    enrollmentAccepted: Int,
    qualityRejected: Int,
    visionDurationMS: Double,
    cropDurationMS: Double,
    qualityDurationMS: Double,
    selectedOrientation: CGImagePropertyOrientation
  ) {
    facePipelineFramesSeen += 1
    facePipelineVisionProcessed += 1
    facePipelineFacesDetected += UInt64(facesDetected)
    facePipelineCropsSucceeded += UInt64(cropsSucceeded)
    facePipelineCropsRejected += UInt64(cropsRejected)
    facePipelineQualityAccepted += UInt64(qualityAccepted)
    facePipelineEnrollmentAccepted += UInt64(enrollmentAccepted)
    facePipelineQualityRejected += UInt64(qualityRejected)
    facePipelineVisionDurationMS += visionDurationMS
    facePipelineCropDurationMS += cropDurationMS
    facePipelineQualityDurationMS += qualityDurationMS
    facePipelineSelectedOrientation = selectedOrientation.debugName

    let elapsed = Date().timeIntervalSince(facePipelineStatsStartedAt)
    guard elapsed >= 2 else { return }
    let avgVisionMS = facePipelineVisionProcessed > 0 ? facePipelineVisionDurationMS / Double(facePipelineVisionProcessed) : 0
    let avgCropMS = facePipelineVisionProcessed > 0 ? facePipelineCropDurationMS / Double(facePipelineVisionProcessed) : 0
    let avgQualityMS = facePipelineVisionProcessed > 0 ? facePipelineQualityDurationMS / Double(facePipelineVisionProcessed) : 0
    AppLogger.log(
      .facePipelineStats,
      String(
        format: "%@ framesSeen=%llu visionProcessed=%llu visionFacesDetected=%llu cropsAcceptedForRecognition=%llu cropsAcceptedForEnrollment=%llu cropsRejectedTooSmall=%llu cropsRejectedBadQuality=%llu embeddingsRun=0 avgVisionMs=%.1f avgCropMs=%.1f avgQualityMs=%.1f selectedOrientation=%@",
        context.logPrefix,
        facePipelineFramesSeen,
        facePipelineVisionProcessed,
        facePipelineFacesDetected,
        facePipelineQualityAccepted,
        facePipelineEnrollmentAccepted,
        facePipelineCropsRejected,
        facePipelineQualityRejected,
        avgVisionMS,
        avgCropMS,
        avgQualityMS,
        facePipelineSelectedOrientation
      )
    )
    facePipelineStatsStartedAt = Date()
    facePipelineFramesSeen = 0
    facePipelineVisionProcessed = 0
    facePipelineFacesDetected = 0
    facePipelineCropsSucceeded = 0
    facePipelineCropsRejected = 0
    facePipelineQualityAccepted = 0
    facePipelineEnrollmentAccepted = 0
    facePipelineQualityRejected = 0
    facePipelineVisionDurationMS = 0
    facePipelineCropDurationMS = 0
    facePipelineQualityDurationMS = 0
  }

  private func recordVisionStats(sequence: UInt64, faceCount: Int, durationMS: Double) {
    if verboseFrameLogging {
      AppLogger.log(.vision, "Processed frame #\(sequence): faces=\(faceCount), durationMs=\(String(format: "%.1f", durationMS))")
      return
    }

    visionStatsProcessedFrames += 1
    visionStatsFaces += UInt64(faceCount)
    visionStatsDurationMS += durationMS
    let elapsed = Date().timeIntervalSince(visionStatsStartedAt)
    guard elapsed >= 2 else { return }

    let avgDurationMS = visionStatsProcessedFrames > 0
      ? visionStatsDurationMS / Double(visionStatsProcessedFrames)
      : 0
    let fps = elapsed > 0 ? Double(visionStatsProcessedFrames) / elapsed : 0
    AppLogger.log(
      .vision,
      String(
        format: "Vision stats: processed=%llu fps=%.1f avgMs=%.1f faces=%llu",
        visionStatsProcessedFrames,
        fps,
        avgDurationMS,
        visionStatsFaces
      )
    )
    visionStatsStartedAt = Date()
    visionStatsProcessedFrames = 0
    visionStatsFaces = 0
    visionStatsDurationMS = 0
  }

  private func runFaceDetection(
    cgImage: CGImage,
    pixelBuffer: CVPixelBuffer?,
    orientation: CGImagePropertyOrientation,
    includeQuality: Bool
  ) -> [VNFaceObservation]? {
    let request = VNDetectFaceRectanglesRequest()
    // usesCPUOnly removed — Vision uses Neural Engine when available (5-10x faster on A-series chips).
    // VNImageRequestHandler is retained and reused across all three passes so the image buffer
    // is uploaded to hardware only once per frame.

    if let pixelBuffer {
      let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
      do {
        try handler.perform([request])
        return enrichWithQualityAndLandmarks(
          handler: handler,
          rectangleObservations: request.results ?? [],
          includeQuality: includeQuality,
          orientation: orientation
        )
      } catch {
        AppLogger.log(.vision, "VNDetectFaceRectanglesRequest failed on CVPixelBuffer orientation=\(orientation.debugName): \(error.localizedDescription). Retrying sRGB CGImage.")
      }
    }

    let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
    do {
      try handler.perform([request])
      return enrichWithQualityAndLandmarks(
        handler: handler,
        rectangleObservations: request.results ?? [],
        includeQuality: includeQuality,
        orientation: orientation
      )
    } catch {
      AppLogger.log(.vision, "VNDetectFaceRectanglesRequest failed: \(error.localizedDescription)")
      return nil
    }
  }

  // Runs quality scoring and landmark detection on the SAME handler that already holds the
  // image — Apple documents VNImageRequestHandler as safe to call perform() on multiple times
  // for the same image, avoiding repeated buffer uploads.
  private func enrichWithQualityAndLandmarks(
    handler: VNImageRequestHandler,
    rectangleObservations: [VNFaceObservation],
    includeQuality: Bool,
    orientation: CGImagePropertyOrientation
  ) -> [VNFaceObservation] {
    guard includeQuality, !rectangleObservations.isEmpty else { return rectangleObservations }

    // Pass 2: quality scores (reuses existing handler — no image re-upload)
    let qualityRequest = VNDetectFaceCaptureQualityRequest()
    qualityRequest.inputFaceObservations = rectangleObservations
    var withQuality = rectangleObservations
    do {
      try handler.perform([qualityRequest])
      withQuality = qualityRequest.results ?? rectangleObservations
    } catch {
      AppLogger.log(.faceQuality, "VNDetectFaceCaptureQualityRequest failed orientation=\(orientation.debugName): \(error.localizedDescription)")
    }

    // Pass 3: 5-point landmarks for similarity-transform alignment in FaceCropper (reuses handler)
    let landmarksRequest = VNDetectFaceLandmarksRequest()
    landmarksRequest.inputFaceObservations = withQuality
    do {
      try handler.perform([landmarksRequest])
      return landmarksRequest.results ?? withQuality
    } catch {
      AppLogger.log(.faceQuality, "VNDetectFaceLandmarksRequest failed orientation=\(orientation.debugName): \(error.localizedDescription)")
      return withQuality
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
    let uiOrientation = Self.cgImagePropertyOrientation(for: imageOrientation)
    guard uiOrientation == .up, let pixelBuffer else { return uiOrientation }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    if width > height, cgImage.height > cgImage.width {
      return .right
    }
    return .up
  }

  static func cgImagePropertyOrientation(for orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
    FaceVisionDebugPipeline.cgImagePropertyOrientation(from: orientation)
  }

  private func logFirstFrameDebugIfNeeded(
    sequence: UInt64,
    image: UIImage,
    cgImage: CGImage,
    pixelBuffer: CVPixelBuffer?,
    timestamp: CMTime?,
    inputType: String,
    context: PipelineContext?
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
      "\(context.logPrefix) First Vision frame #\(sequence): input=\(inputType), uiImageSize=\(Int(image.size.width))x\(Int(image.size.height)), cgImage=\(cgImage.width)x\(cgImage.height), pixelBuffer=\(pixelSize), uiOrientation=\(image.imageOrientation.debugName), mappedCG=\(Self.cgImagePropertyOrientation(for: image.imageOrientation).debugName), mirrored=\(image.imageOrientation.debugName.contains("Mirrored")), source=glasses-or-file, timestamp=\(timestampText)"
    )
  }

  private func makeFaceDetectionEvent(
    context: PipelineContext?,
    sequence: UInt64,
    image: UIImage,
    cgImage: CGImage,
    detection: FaceDetectionOutput
  ) -> FaceDetectionEvent? {
    guard let context else { return nil }
    guard sequence <= 30 || sequence % 30 == 0 || detection.observations.isEmpty else { return nil }
    let sweepJson = FaceVisionDebugPipeline.orientationCountsJSON(detection.orientationCounts)
    return FaceDetectionEvent(
      id: UUID(),
      appRunId: context.appRunId,
      conversationSessionId: context.conversationSessionId,
      frameIndex: Int(sequence),
      frameWidth: Int(image.size.width),
      frameHeight: Int(image.size.height),
      uiImageOrientation: image.imageOrientation.debugName,
      cgImageWidth: cgImage.width,
      cgImageHeight: cgImage.height,
      visionOrientationUsed: detection.selectedOrientation.debugName,
      preferredFaceCount: detection.preferredFaceCount,
      sweepFaceCountsJson: sweepJson,
      selectedOrientation: detection.selectedOrientation.debugName,
      selectedFaceCount: detection.observations.count,
      createdAt: Date()
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

  private struct FaceTrackInput {
    let boundingBox: CGRect
    let mouthOpenRatio: Float?
  }

  private func updateTracks(with inputs: [FaceTrackInput], cgImage: CGImage, sequence: UInt64) -> [DetectedFace] {
    var updatedTracks: [Track] = []
    var usedTrackIDs = Set<Int>()

    for input in inputs {
      let box = input.boundingBox
      let thumbnail = makeFaceThumbnail(from: cgImage, normalizedBox: box)
      if let matchedTrack = bestMatchingTrack(for: box, excluding: usedTrackIDs) {
        usedTrackIDs.insert(matchedTrack.id)
        let movementScore = Self.updatedMouthMovementScore(
          previousRatio: matchedTrack.lastMouthOpenRatio,
          newRatio: input.mouthOpenRatio,
          previousScore: matchedTrack.mouthMovementScore
        )
        updatedTracks.append(Track(
          id: matchedTrack.id,
          personID: matchedTrack.personID,
          boundingBox: box,
          faceImage: thumbnail ?? matchedTrack.faceImage,
          lastMouthOpenRatio: input.mouthOpenRatio ?? matchedTrack.lastMouthOpenRatio,
          mouthMovementScore: movementScore,
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
          lastMouthOpenRatio: input.mouthOpenRatio,
          mouthMovementScore: 0,
          lastSeenSequence: sequence
        ))
      }
    }

    tracks = updatedTracks + tracks.filter { previous in
      !usedTrackIDs.contains(previous.id) && sequence > previous.lastSeenSequence && sequence - previous.lastSeenSequence < 12
    }

    return updatedTracks.map {
      DetectedFace(
        id: $0.id,
        boundingBox: $0.boundingBox,
        displayName: "Person \($0.id)",
        mouthOpenRatio: $0.lastMouthOpenRatio,
        mouthMovementScore: $0.mouthMovementScore
      )
    }
  }

  private static func mouthOpenRatio(for observation: VNFaceObservation) -> Float? {
    guard let landmarks = observation.landmarks else { return nil }
    let points = landmarks.innerLips?.normalizedPoints ?? landmarks.outerLips?.normalizedPoints ?? []
    guard points.count >= 4 else { return nil }
    let minX = points.map(\.x).min() ?? 0
    let maxX = points.map(\.x).max() ?? 0
    let minY = points.map(\.y).min() ?? 0
    let maxY = points.map(\.y).max() ?? 0
    let width = maxX - minX
    let height = maxY - minY
    guard width > 0 else { return nil }
    return Float(max(0, height / width))
  }

  private static func updatedMouthMovementScore(
    previousRatio: Float?,
    newRatio: Float?,
    previousScore: Float
  ) -> Float {
    guard let newRatio, let previousRatio else {
      return previousScore * 0.80
    }
    let instantaneous = min(1, abs(newRatio - previousRatio) * 8)
    return min(1, max(0, previousScore * 0.65 + instantaneous * 0.35))
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

extension CGImagePropertyOrientation {
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

extension UIImage.Orientation {
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
