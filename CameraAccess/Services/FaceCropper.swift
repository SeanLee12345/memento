import CoreGraphics
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers
import Vision

enum FaceCropper {
  struct BoxConversion {
    let normalizedRect: CGRect
    let vnPixelRect: CGRect
    let manualFlipPixelRect: CGRect
    let finalPixelRect: CGRect
    let paddedRect: CGRect
    let valid: Bool
    let reason: String
    let isBottomClipped: Bool

    var pixelRect: CGRect { finalPixelRect }
  }

  private static var savedDebugCropCount = 0
  private static let debugCropLimit = IdentityConfig.debugFaceCropLimit
  private static var shouldSaveDebugCrops: Bool {
    IdentityConfig.saveDebugFaceCrops
      || ProcessInfo.processInfo.environment["BBOL_SAVE_FACE_DEBUG_CROPS"] == "1"
      || ProcessInfo.processInfo.arguments.contains("--save-debug-face-crops")
  }

  static func cropFaces(
    observations: [VNFaceObservation],
    from cgImage: CGImage,
    sequence: UInt64,
    orientation: CGImagePropertyOrientation,
    paddingRatio: CGFloat = IdentityConfig.faceCropHorizontalPaddingRatio,
    context: PipelineContext? = nil
  ) -> (crops: [FaceCropResult], alignmentFailures: Int) {
    let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
    var alignmentFailures = 0

    let crops: [FaceCropResult] = observations.enumerated().compactMap { faceIndex, observation in
      let conversion = visionBoundingBoxToPixelRect(
        observation.boundingBox,
        imageWidth: cgImage.width,
        imageHeight: cgImage.height,
        paddingRatio: paddingRatio
      )
      logBox(context: context, frame: sequence, faceIndex: faceIndex, imageSize: imageSize, conversion: conversion)
      guard conversion.valid else {
        return nil
      }

      guard let cropped = cgImage.cropping(to: conversion.paddedRect) else {
        AppLogger.log(
          .faceCrop,
          "\(context.logPrefix) frame=\(sequence) face=\(faceIndex) crop=failed reason=cgImageCroppingReturnedNil rect=\(rectText(conversion.paddedRect)) source=\(cgImage.width)x\(cgImage.height)"
        )
        return nil
      }

      let modelSize = IdentityConfig.activeEmbeddingModelInputSize
      guard let aligned = alignFace(
        observation: observation, from: cgImage, imageSize: imageSize,
        sequence: sequence, faceIndex: faceIndex, context: context
      ) else {
        alignmentFailures += 1
        AppLogger.log(
          .faceCrop,
          "\(context.logPrefix) frame=\(sequence) face=\(faceIndex) crop=rejected reason=landmarkAlignmentRequired rawFacePixels=\(rectText(conversion.finalPixelRect)) source=\(cgImage.width)x\(cgImage.height)"
        )
        return nil
      }

      let debugPath = saveDebugCropIfNeeded(cropped, sequence: sequence, faceIndex: faceIndex, context: context)
      saveAlignedDebugCropIfNeeded(aligned, sequence: sequence, faceIndex: faceIndex, context: context)
      AppLogger.log(
        .faceCrop,
        "\(context.logPrefix) frame=\(sequence) face=\(faceIndex) crop=succeeded rawFacePixels=\(rectText(conversion.finalPixelRect)) paddedCropPixels=\(rectText(conversion.paddedRect)) cropSize=\(cropped.width)x\(cropped.height) alignmentMode=similarityTransformAligned alignedSize=\(aligned.width)x\(aligned.height) modelDeclaredInput=\(Int(modelSize.width))x\(Int(modelSize.height)) source=\(cgImage.width)x\(cgImage.height) orientation=\(orientation.debugName) geometryAcceptedForRecognition=true geometryAcceptedForEnrollment=\(conversion.finalPixelRect.width >= IdentityConfig.qualityConfig.enrollmentMinFacePixels && conversion.finalPixelRect.height >= IdentityConfig.qualityConfig.enrollmentMinFacePixels) isBottomClipped=\(conversion.isBottomClipped) cropSavedPath=\(debugPath ?? "none")"
      )

      return FaceCropResult(
        frameSequence: sequence,
        frameTimestamp: Date(),
        faceBoundingBoxNormalized: observation.boundingBox,
        rawFaceBoundingBoxPixels: conversion.finalPixelRect,
        faceBoundingBoxPixels: conversion.paddedRect,
        croppedImage: cropped,
        previewImage: UIImage(cgImage: cropped, scale: 1.0, orientation: Self.uiImageOrientation(for: orientation)),
        sourceImageSize: imageSize,
        visionOrientation: orientation,
        alignmentMode: "similarityTransformAligned",
        yaw: observation.yaw?.floatValue,
        roll: observation.roll?.floatValue,
        pitch: observation.pitch?.floatValue,
        faceCaptureQuality: observation.faceCaptureQuality,
        alignedCroppedImage: aligned,
        isBottomClipped: conversion.isBottomClipped
      )
    }
    return (crops, alignmentFailures)
  }

  static func pixelRectFromVisionBoundingBox(
    _ boundingBox: CGRect,
    imageWidth: Int,
    imageHeight: Int
  ) -> CGRect {
    VNImageRectForNormalizedRect(boundingBox, imageWidth, imageHeight).integral
  }

  static func visionBoundingBoxToPixelRect(
    _ normalizedRect: CGRect,
    imageWidth: Int,
    imageHeight: Int,
    paddingRatio: CGFloat = IdentityConfig.faceCropHorizontalPaddingRatio
  ) -> BoxConversion {
    let imageSize = CGSize(width: imageWidth, height: imageHeight)
    let imageBounds = CGRect(origin: .zero, size: imageSize)
    guard imageWidth > 0, imageHeight > 0 else {
      return BoxConversion(
        normalizedRect: normalizedRect,
        vnPixelRect: .null,
        manualFlipPixelRect: .null,
        finalPixelRect: .null,
        paddedRect: .null,
        valid: false,
        reason: "invalidImageSize",
        isBottomClipped: false
      )
    }
    guard normalizedRect.origin.x.isFinite,
          normalizedRect.origin.y.isFinite,
          normalizedRect.size.width.isFinite,
          normalizedRect.size.height.isFinite,
          normalizedRect.width > 0,
          normalizedRect.height > 0 else {
      return BoxConversion(
        normalizedRect: normalizedRect,
        vnPixelRect: .null,
        manualFlipPixelRect: .null,
        finalPixelRect: .null,
        paddedRect: .null,
        valid: false,
        reason: "invalidNormalizedRect",
        isBottomClipped: false
      )
    }

    let vnPixelRect = pixelRectFromVisionBoundingBox(
      normalizedRect,
      imageWidth: imageWidth,
      imageHeight: imageHeight
    )
    let manualFlipPixelRect = CGRect(
      x: normalizedRect.minX * imageSize.width,
      y: (1 - normalizedRect.maxY) * imageSize.height,
      width: normalizedRect.width * imageSize.width,
      height: normalizedRect.height * imageSize.height
    ).integral

    guard vnPixelRect.origin.x.isFinite,
          vnPixelRect.origin.y.isFinite,
          vnPixelRect.size.width.isFinite,
          vnPixelRect.size.height.isFinite else {
      return BoxConversion(
        normalizedRect: normalizedRect,
        vnPixelRect: vnPixelRect,
        manualFlipPixelRect: manualFlipPixelRect,
        finalPixelRect: .null,
        paddedRect: .null,
        valid: false,
        reason: "nonFinitePixelRect",
        isBottomClipped: false
      )
    }

    let safePixelRect = vnPixelRect.intersection(imageBounds).integral
    guard !safePixelRect.isNull, safePixelRect.width > 0, safePixelRect.height > 0 else {
      return BoxConversion(
        normalizedRect: normalizedRect,
        vnPixelRect: vnPixelRect,
        manualFlipPixelRect: manualFlipPixelRect,
        finalPixelRect: vnPixelRect,
        paddedRect: .null,
        valid: false,
        reason: "outOfBounds",
        isBottomClipped: false
      )
    }
    guard safePixelRect.width >= IdentityConfig.qualityConfig.minRawFacePixelsForDetection,
          safePixelRect.height >= IdentityConfig.qualityConfig.minRawFacePixelsForDetection else {
      return BoxConversion(
        normalizedRect: normalizedRect,
        vnPixelRect: vnPixelRect,
        manualFlipPixelRect: manualFlipPixelRect,
        finalPixelRect: safePixelRect,
        paddedRect: .null,
        valid: false,
        reason: "tooSmall",
        isBottomClipped: false
      )
    }

    // Asymmetric vertical padding: hair requires more room above than chin requires below.
    // Vision's detection box already covers forehead→chin, so top needs the larger margin.
    let paddingLeft = safePixelRect.width * paddingRatio
    let paddingRight = paddingLeft
    let paddingTop = safePixelRect.height * IdentityConfig.faceCropTopPaddingRatio
    let paddingBottom = safePixelRect.height * IdentityConfig.faceCropBottomPaddingRatio
    let padded = CGRect(
      x: safePixelRect.minX - paddingLeft,
      y: safePixelRect.minY - paddingTop,
      width: safePixelRect.width + paddingLeft + paddingRight,
      height: safePixelRect.height + paddingTop + paddingBottom
    )
    // Detect if the face bounding box itself is clipped at the bottom image edge.
    // Use a 2px tolerance: if Vision's box reaches within 2px of the bottom, chin is likely cut off.
    let rawBottomClipped = safePixelRect.maxY >= CGFloat(imageHeight) - 2
    let safePadded = padded.intersection(imageBounds).integral
    guard !safePadded.isNull, safePadded.width > 0, safePadded.height > 0 else {
      return BoxConversion(
        normalizedRect: normalizedRect,
        vnPixelRect: vnPixelRect,
        manualFlipPixelRect: manualFlipPixelRect,
        finalPixelRect: safePixelRect,
        paddedRect: .null,
        valid: false,
        reason: "paddedRectOutsideImage",
        isBottomClipped: rawBottomClipped
      )
    }
    return BoxConversion(
      normalizedRect: normalizedRect,
      vnPixelRect: vnPixelRect,
      manualFlipPixelRect: manualFlipPixelRect,
      finalPixelRect: safePixelRect,
      paddedRect: safePadded,
      valid: true,
      reason: rawBottomClipped ? "bottomClipped" : "ok",
      isBottomClipped: rawBottomClipped
    )
  }

  private static func logBox(context: PipelineContext?, frame: UInt64, faceIndex: Int, imageSize: CGSize, conversion: BoxConversion) {
    let message = "\(context.logPrefix) frame=\(frame) face=\(faceIndex) normalized=\(rectText(conversion.normalizedRect)) vnPixel=\(rectText(conversion.vnPixelRect)) manualFlipPixel=\(rectText(conversion.manualFlipPixelRect)) rawFacePixels=\(rectText(conversion.finalPixelRect)) paddedCropPixels=\(rectText(conversion.paddedRect)) finalPixel=\(rectText(conversion.finalPixelRect)) image=\(Int(imageSize.width))x\(Int(imageSize.height))"
    if conversion.valid {
      AppLogger.log(.visionBox, message)
    } else {
      AppLogger.log(
        .visionBoxReject,
        "\(message) reason=\(conversion.reason) minFacePixels=\(Int(IdentityConfig.qualityConfig.minRawFacePixelsForDetection))"
      )
    }
  }

  // MARK: - Similarity-transform face alignment

  // AdaFace/ArcFace reference landmarks for 112 wide x 112 tall crops.
  // modelInputSize is NOT hardcoded here; it reads IdentityConfig.activeEmbeddingModelInputSize,
  // which is set by the active face embedding model.
  private static let referenceLandmarks: [CGPoint] = [
    CGPoint(x: 38.2946, y: 51.6963),  // left eye
    CGPoint(x: 73.5318, y: 51.5014),  // right eye
    CGPoint(x: 56.0252, y: 71.7366),  // nose tip
    CGPoint(x: 41.5493, y: 92.3655),  // left mouth corner
    CGPoint(x: 70.7299, y: 92.2041),  // right mouth corner
  ]

  // Task 7/6: full landmark logging; returns nil with reason if any required part is absent.
  private static func alignFace(
    observation: VNFaceObservation,
    from cgImage: CGImage,
    imageSize: CGSize,
    sequence: UInt64,
    faceIndex: Int,
    context: PipelineContext?
  ) -> CGImage? {
    guard let landmarks = observation.landmarks else {
      AppLogger.log(.faceCrop, "\(context.logPrefix) frame=\(sequence) face=\(faceIndex) alignment=skipped reason=noLandmarks")
      return nil
    }

    // Log each absent landmark region — helps diagnose Vision pipeline issues.
    let missing = [
      landmarks.leftEye == nil ? "leftEye" : nil,
      landmarks.rightEye == nil ? "rightEye" : nil,
      landmarks.noseCrest == nil ? "noseCrest" : nil,
      landmarks.outerLips == nil ? "outerLips" : nil,
    ].compactMap { $0 }
    if !missing.isEmpty {
      AppLogger.log(.faceCrop, "\(context.logPrefix) frame=\(sequence) face=\(faceIndex) alignment=partial missingLandmarks=\(missing.joined(separator: ","))")
    }

    guard let srcPoints = extractFiveLandmarks(
      landmarks,
      boundingBox: observation.boundingBox,
      imageSize: imageSize
    ) else {
      AppLogger.log(.faceCrop, "\(context.logPrefix) frame=\(sequence) face=\(faceIndex) alignment=failed reason=landmarkExtractionFailed")
      return nil
    }

    // Task 3/7: log all five extracted points so coordinate conversion can be verified.
    let modelSize = IdentityConfig.activeEmbeddingModelInputSize
    AppLogger.log(
      .faceCrop,
      "\(context.logPrefix) frame=\(sequence) face=\(faceIndex) alignment=computing"
        + " leftEye=\(ptText(srcPoints[0])) rightEye=\(ptText(srcPoints[1]))"
        + " nose=\(ptText(srcPoints[2])) leftMouth=\(ptText(srcPoints[3])) rightMouth=\(ptText(srcPoints[4]))"
        + " modelDeclaredInput=\(Int(modelSize.width))x\(Int(modelSize.height))"
    )

    guard let transform = similarityTransform(from: srcPoints, to: referenceLandmarks) else {
      AppLogger.log(.faceCrop, "\(context.logPrefix) frame=\(sequence) face=\(faceIndex) alignment=failed reason=degenerateSimilarityTransform")
      return nil
    }
    let warped = warpFace(cgImage: cgImage, transform: transform, outputSize: modelSize)
    if warped == nil {
      AppLogger.log(.faceCrop, "\(context.logPrefix) frame=\(sequence) face=\(faceIndex) alignment=failed reason=warpContextCreationFailed")
    }
    return warped
  }

  // Extracts the 5 canonical face landmark points from VNFaceLandmarks2D.
  //
  // Coordinate conversion (task 6):
  //   Vision normalizedPoints are in [0,1] relative to the face bounding box, bottom-left origin.
  //   VNImageRectForNormalizedRect converts the bounding box to pixel coords, top-left origin.
  //   Within that pixel rect: x = bbPixel.minX + lmk.x * bbWidth (same axis)
  //                           y = bbPixel.minY + (1 - lmk.y) * bbHeight  (y-flip: Vision y=1 = top of box)
  //
  // Nose tip (task 7): uses noseCrest.last — noseCrest traces bridge → tip, so the last point
  //   is geometrically closest to the tip. Falls back to midpoint of eye line if absent.
  static func extractFiveLandmarks(
    _ landmarks: VNFaceLandmarks2D,
    boundingBox: CGRect,
    imageSize: CGSize
  ) -> [CGPoint]? {
    // VNImageRectForNormalizedRect flips y, returning a top-left-origin pixel rect.
    let bbPixel = VNImageRectForNormalizedRect(
      boundingBox,
      Int(imageSize.width),
      Int(imageSize.height)
    )

    func toImagePixel(_ norm: CGPoint) -> CGPoint {
      CGPoint(
        x: bbPixel.minX + norm.x * bbPixel.width,
        y: bbPixel.minY + (1.0 - norm.y) * bbPixel.height
      )
    }

    func centroid(_ pts: [CGPoint]) -> CGPoint? {
      guard !pts.isEmpty else { return nil }
      return CGPoint(
        x: pts.map(\.x).reduce(0, +) / CGFloat(pts.count),
        y: pts.map(\.y).reduce(0, +) / CGFloat(pts.count)
      )
    }

    guard
      let leftEyeCenter = centroid(landmarks.leftEye?.normalizedPoints.map(toImagePixel) ?? []),
      let rightEyeCenter = centroid(landmarks.rightEye?.normalizedPoints.map(toImagePixel) ?? []),
      let outerLipsPoints = landmarks.outerLips?.normalizedPoints.map(toImagePixel),
      !outerLipsPoints.isEmpty
    else { return nil }

    // Nose tip: last point of noseCrest (bridge→tip ordering) or midpoint of eye line as fallback.
    let noseTip: CGPoint
    if let crestPoints = landmarks.noseCrest?.normalizedPoints.map(toImagePixel), !crestPoints.isEmpty {
      noseTip = crestPoints.last!
    } else {
      noseTip = CGPoint(
        x: (leftEyeCenter.x + rightEyeCenter.x) / 2,
        y: (leftEyeCenter.y + rightEyeCenter.y) / 2 + (bbPixel.height * 0.15)
      )
    }

    // Mouth corners: geometric min-x / max-x — robust regardless of Vision point ordering.
    let leftMouth = outerLipsPoints.min(by: { $0.x < $1.x })!
    let rightMouth = outerLipsPoints.max(by: { $0.x < $1.x })!

    return [leftEyeCenter, rightEyeCenter, noseTip, leftMouth, rightMouth]
  }

  private static func ptText(_ p: CGPoint) -> String {
    String(format: "(%.1f,%.1f)", p.x, p.y)
  }

  // Computes the least-squares optimal similarity transform (4-DOF: scale, rotation, translation)
  // mapping src points to dst points. Returns a CGAffineTransform in top-left-origin image coords.
  static func similarityTransform(from src: [CGPoint], to dst: [CGPoint]) -> CGAffineTransform? {
    guard src.count == dst.count, src.count >= 2 else { return nil }
    let n = CGFloat(src.count)

    let srcMeanX = src.map(\.x).reduce(0, +) / n
    let srcMeanY = src.map(\.y).reduce(0, +) / n
    let dstMeanX = dst.map(\.x).reduce(0, +) / n
    let dstMeanY = dst.map(\.y).reduce(0, +) / n

    var a: CGFloat = 0  // will become s·cos θ
    var b: CGFloat = 0  // will become s·sin θ
    var sigma2: CGFloat = 0

    for i in 0..<src.count {
      let sx = src[i].x - srcMeanX, sy = src[i].y - srcMeanY
      let dx = dst[i].x - dstMeanX, dy = dst[i].y - dstMeanY
      a += dx * sx + dy * sy
      b += dx * sy - dy * sx
      sigma2 += sx * sx + sy * sy
    }

    guard sigma2 > 1e-6 else { return nil }
    a /= sigma2; b /= sigma2
    let tx = dstMeanX - a * srcMeanX + b * srcMeanY
    let ty = dstMeanY - b * srcMeanX - a * srcMeanY

    // CGAffineTransform convention: x' = a·x + c·y + tx,  y' = b·x + d·y + ty
    // Similarity: x' = a·x − b·y + tx,  y' = b·x + a·y + ty  → c = −b, d = a
    return CGAffineTransform(a: a, b: b, c: -b, d: a, tx: tx, ty: ty)
  }

  // Applies a CGAffineTransform to a source CGImage and renders a new image of outputSize.
  // The transform is in top-left-origin pixel coordinates (standard image space).
  private static func warpFace(
    cgImage: CGImage,
    transform: CGAffineTransform,
    outputSize: CGSize
  ) -> CGImage? {
    let outputW = Int(outputSize.width)
    let outputH = Int(outputSize.height)
    guard let context = CGContext(
      data: nil,
      width: outputW,
      height: outputH,
      bitsPerComponent: 8,
      bytesPerRow: outputW * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.interpolationQuality = .high
    // Bitmap CGContext pixel coordinates are top-left-origin, matching the similarity transform T.
    // No y-flip is needed — applying one inverts the output.
    context.concatenate(transform)
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
    return context.makeImage()
  }

  private static func saveDebugCropIfNeeded(_ image: CGImage, sequence: UInt64, faceIndex: Int, context: PipelineContext?) -> String? {
    guard shouldSaveDebugCrops, savedDebugCropCount < debugCropLimit else { return nil }
    guard let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
      return nil
    }
    let appRun = context?.appRunId.shortLogID ?? "noRun"
    let session = context?.conversationSessionId?.shortLogID ?? "noSession"
    let fileName = "face_crop_preview_run_\(appRun)_session_\(session)_frame_\(sequence)_face_\(faceIndex).png"
    let url = cacheDirectory.appendingPathComponent(fileName)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    savedDebugCropCount += 1
    return url.path
  }

  // Task 5: saves the aligned embedding crop separately so both crops can be compared on disk.
  private static func saveAlignedDebugCropIfNeeded(_ image: CGImage?, sequence: UInt64, faceIndex: Int, context: PipelineContext?) {
    guard shouldSaveDebugCrops, savedDebugCropCount < debugCropLimit, let image else { return }
    guard let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
    let appRun = context?.appRunId.shortLogID ?? "noRun"
    let session = context?.conversationSessionId?.shortLogID ?? "noSession"
    let fileName = "face_crop_aligned_run_\(appRun)_session_\(session)_frame_\(sequence)_face_\(faceIndex)_\(image.width)x\(image.height).png"
    let url = cacheDirectory.appendingPathComponent(fileName)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    AppLogger.log(.faceCrop, "\(context.logPrefix) aligned crop saved path=\(url.path)")
  }

  static func uiImageOrientation(for cgOrientation: CGImagePropertyOrientation) -> UIImage.Orientation {
    switch cgOrientation {
    case .up: return .up
    case .upMirrored: return .upMirrored
    case .down: return .down
    case .downMirrored: return .downMirrored
    case .left: return .left
    case .leftMirrored: return .leftMirrored
    case .right: return .right
    case .rightMirrored: return .rightMirrored
    }
  }

  private static func rectText(_ rect: CGRect) -> String {
    guard !rect.isNull else { return "(null)" }
    return String(
      format: "(x:%.3f, y:%.3f, w:%.3f, h:%.3f)",
      rect.origin.x,
      rect.origin.y,
      rect.size.width,
      rect.size.height
    )
  }
}
