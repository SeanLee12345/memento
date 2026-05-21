import CoreGraphics
import CoreImage
import Foundation

struct FaceQualityFilter {
  var minimumFaceWidthRatio = IdentityConfig.minimumFaceWidthRatio
  var minimumFaceHeightRatio = IdentityConfig.minimumFaceHeightRatio
  var qualityConfig = IdentityConfig.qualityConfig
  var minimumFaceCaptureQuality = IdentityConfig.minimumFaceCaptureQuality
  var minimumFaceAreaRatio = IdentityConfig.minimumFaceAreaRatio
  private let ciContext = CIContext()

  func evaluate(_ crop: FaceCropResult, faceCount: Int = 1, isDominantFace: Bool = true) -> FaceQualityDecision {
    var reasons: [String] = []
    let frameWidth = max(crop.sourceImageSize.width, 1)
    let frameHeight = max(crop.sourceImageSize.height, 1)
    let rawFaceRect = crop.rawFaceBoundingBoxPixels
    let widthRatio = rawFaceRect.width / frameWidth
    let heightRatio = rawFaceRect.height / frameHeight
    let normalizedArea = Float(widthRatio * heightRatio)
    let brightness = averageBrightness(crop.croppedImage)
    let centerOffset = normalizedCenterOffset(rawFaceRect, sourceSize: crop.sourceImageSize)
    let rawMinPixels = min(rawFaceRect.width, rawFaceRect.height)
    let cropMinPixels = CGFloat(min(crop.croppedImage.width, crop.croppedImage.height))

    if widthRatio < minimumFaceWidthRatio {
      reasons.append("faceTooNarrow")
    }
    if heightRatio < minimumFaceHeightRatio {
      reasons.append("faceTooShort")
    }
    if rawMinPixels < qualityConfig.recognitionMinFacePixels {
      reasons.append("tooSmallForRecognition")
    }
    if cropMinPixels < qualityConfig.minCropPixelsForRecognition {
      reasons.append("cropTooSmallForRecognition")
    }
    if normalizedArea < minimumFaceAreaRatio {
      reasons.append("areaTooSmall")
    }
    if let quality = crop.faceCaptureQuality, quality < qualityConfig.recognitionMinFaceCaptureQuality {
      reasons.append("qualityTooLowForRecognition")
    }
    if faceCount > 1 && !isDominantFace {
      reasons.append("notDominantFace")
    }
    if let yaw = crop.yaw, abs(yaw) > IdentityConfig.maxYawAbsRadians {
      reasons.append("yawTooLarge")
    }
    if let pitch = crop.pitch, abs(pitch) > IdentityConfig.maxPitchAbsRadians {
      reasons.append("pitchTooLarge")
    }
    if let roll = crop.roll, abs(roll) > IdentityConfig.maxRollAbsRadians {
      reasons.append("rollTooLarge")
    }
    if CGFloat(centerOffset) > qualityConfig.maxRecognitionCenterOffsetRatio {
      reasons.append("faceTooFarFromCenterForRecognition")
    }
    if crop.isBottomClipped {
      reasons.append("chinClipped")
    }

    let rejectedForQuality = reasons.contains("qualityTooLowForRecognition")
      || reasons.contains("faceTooFarFromCenterForRecognition")
      || reasons.contains("notDominantFace")
    let rejectedForPose = reasons.contains("yawTooLarge")
      || reasons.contains("pitchTooLarge")
      || reasons.contains("rollTooLarge")
    let acceptedForRecognition = rawMinPixels >= qualityConfig.recognitionMinFacePixels
      && cropMinPixels >= qualityConfig.minCropPixelsForRecognition
      && !rejectedForQuality
      && !rejectedForPose
    let acceptedForEnrollment = rawMinPixels >= qualityConfig.enrollmentMinFacePixels
      && cropMinPixels >= qualityConfig.minCropPixelsForEnrollment
      && acceptedForRecognition
      && crop.faceCaptureQuality.map { $0 >= qualityConfig.enrollmentMinFaceCaptureQuality } ?? true
      && CGFloat(centerOffset) <= qualityConfig.maxEnrollmentCenterOffsetRatio
      && !crop.isBottomClipped
    let tier: FaceQualityTier
    if crop.croppedImage.width <= 0 || crop.croppedImage.height <= 0 {
      tier = .rejectedBadCrop
    } else if rawMinPixels < qualityConfig.recognitionMinFacePixels {
      tier = .tooSmallForRecognition
    } else if cropMinPixels < qualityConfig.minCropPixelsForRecognition {
      tier = .tooSmallForRecognition
    } else if rejectedForPose {
      tier = .rejectedBadPose
    } else if rejectedForQuality {
      tier = .rejectedBadQuality
    } else if crop.isBottomClipped {
      tier = .usableForRecognition
    } else if rawMinPixels < qualityConfig.enrollmentMinFacePixels {
      tier = .usableForRecognition
    } else if rawMinPixels < qualityConfig.preferredEnrollmentFacePixels {
      tier = .usableForEnrollment
    } else {
      tier = .preferredEnrollment
    }
    if acceptedForRecognition, !acceptedForEnrollment {
      if rawMinPixels < qualityConfig.enrollmentMinFacePixels {
        reasons.append("tooSmallForEnrollment")
      }
      if cropMinPixels < qualityConfig.minCropPixelsForEnrollment {
        reasons.append("cropTooSmallForEnrollment")
      }
      if let quality = crop.faceCaptureQuality, quality < qualityConfig.enrollmentMinFaceCaptureQuality {
        reasons.append("qualityTooLowForEnrollment")
        reasons.append("lowButAcceptedForRecognition")
      }
      if CGFloat(centerOffset) > qualityConfig.maxEnrollmentCenterOffsetRatio {
        reasons.append("faceTooFarFromCenterForEnrollment")
      }
      if crop.isBottomClipped {
        reasons.append("chinClippedRejectedEnrollment")
      }
    }

    return FaceQualityDecision(
      detected: true,
      cropSucceeded: crop.croppedImage.width > 0 && crop.croppedImage.height > 0,
      rawFaceWidth: Int(rawFaceRect.width),
      rawFaceHeight: Int(rawFaceRect.height),
      accepted: acceptedForRecognition,
      score: crop.faceCaptureQuality,
      reasons: reasons,
      rejectionReasons: acceptedForRecognition ? [] : reasons,
      normalizedFaceArea: normalizedArea,
      cropSize: CGSize(width: crop.croppedImage.width, height: crop.croppedImage.height),
      visionQuality: crop.faceCaptureQuality,
      cropWidth: crop.croppedImage.width,
      cropHeight: crop.croppedImage.height,
      brightness: brightness,
      sharpness: nil,
      faceAreaRatio: normalizedArea,
      centerOffset: centerOffset,
      passes: acceptedForRecognition,
      rejectReason: reasons.isEmpty ? nil : reasons.joined(separator: ", "),
      tier: tier,
      acceptedForRecognition: acceptedForRecognition,
      acceptedForEnrollment: acceptedForEnrollment
    )
  }

  private func normalizedCenterOffset(_ rect: CGRect, sourceSize: CGSize) -> Float {
    let frameCenter = CGPoint(x: sourceSize.width / 2, y: sourceSize.height / 2)
    let faceCenter = CGPoint(x: rect.midX, y: rect.midY)
    let dx = (faceCenter.x - frameCenter.x) / max(sourceSize.width, 1)
    let dy = (faceCenter.y - frameCenter.y) / max(sourceSize.height, 1)
    return Float(sqrt(dx * dx + dy * dy))
  }

  private func averageBrightness(_ image: CGImage) -> Float? {
    let input = CIImage(cgImage: image)
    let extent = input.extent
    guard !extent.isEmpty else { return nil }
    guard let filter = CIFilter(name: "CIAreaAverage") else { return nil }
    filter.setValue(input, forKey: kCIInputImageKey)
    filter.setValue(CIVector(cgRect: extent), forKey: kCIInputExtentKey)
    guard let output = filter.outputImage else { return nil }
    var rgba = [UInt8](repeating: 0, count: 4)
    ciContext.render(
      output,
      toBitmap: &rgba,
      rowBytes: 4,
      bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
      format: .RGBA8,
      colorSpace: CGColorSpaceCreateDeviceRGB()
    )
    return (Float(rgba[0]) + Float(rgba[1]) + Float(rgba[2])) / (3 * 255)
  }
}
