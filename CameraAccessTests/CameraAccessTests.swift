/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import XCTest

@testable import CameraAccess

final class VisionInputSafetyTests: XCTestCase {
  func testFaceRectIsClampedToImageBounds() {
    let imageSize = CGSize(width: 640, height: 480)
    let overflowingBox = CGRect(x: 0.85, y: 0.82, width: 0.40, height: 0.35)

    let rect = VisionFaceFrameProcessor.clampedImageRect(
      forNormalizedFaceBox: overflowingBox,
      imageSize: imageSize
    )

    XCTAssertNotNil(rect)
    XCTAssertLessThanOrEqual(rect?.maxX ?? .greatestFiniteMagnitude, imageSize.width)
    XCTAssertLessThanOrEqual(rect?.maxY ?? .greatestFiniteMagnitude, imageSize.height)
    XCTAssertGreaterThan(rect?.width ?? 0, 0)
    XCTAssertGreaterThan(rect?.height ?? 0, 0)
  }

  func testFaceRectOutsideImageIsDiscarded() {
    let imageSize = CGSize(width: 640, height: 480)
    let outsideBox = CGRect(x: 1.2, y: 1.2, width: 0.2, height: 0.2)

    let rect = VisionFaceFrameProcessor.clampedImageRect(
      forNormalizedFaceBox: outsideBox,
      imageSize: imageSize
    )

    XCTAssertNil(rect)
  }

  func testInvalidImageSizeIsDiscardedBeforeImageOperations() {
    let box = CGRect(x: 0.25, y: 0.25, width: 0.25, height: 0.25)

    XCTAssertNil(VisionFaceFrameProcessor.clampedImageRect(forNormalizedFaceBox: box, imageSize: .zero))
    XCTAssertNil(VisionFaceFrameProcessor.safeNormalizedFaceBox(box, imageSize: .zero))
  }

  func testSafeNormalizedFaceBoxStaysInsideUnitBounds() {
    let imageSize = CGSize(width: 320, height: 240)
    let overflowingBox = CGRect(x: -0.2, y: -0.1, width: 0.5, height: 0.5)

    let safeBox = VisionFaceFrameProcessor.safeNormalizedFaceBox(overflowingBox, imageSize: imageSize)

    XCTAssertNotNil(safeBox)
    XCTAssertGreaterThanOrEqual(safeBox?.minX ?? -1, 0)
    XCTAssertGreaterThanOrEqual(safeBox?.minY ?? -1, 0)
    XCTAssertLessThanOrEqual(safeBox?.maxX ?? 2, 1)
    XCTAssertLessThanOrEqual(safeBox?.maxY ?? 2, 1)
  }

  func testUIImageOrientationMapping() {
    XCTAssertEqual(VisionFaceFrameProcessor.cgImagePropertyOrientation(for: .up), .up)
    XCTAssertEqual(VisionFaceFrameProcessor.cgImagePropertyOrientation(for: .right), .right)
    XCTAssertEqual(VisionFaceFrameProcessor.cgImagePropertyOrientation(for: .left), .left)
    XCTAssertEqual(VisionFaceFrameProcessor.cgImagePropertyOrientation(for: .down), .down)
  }

  func testVisionBoundingBoxToPixelRectFlipsYAndPads() {
    let conversion = FaceCropper.visionBoundingBoxToPixelRect(
      CGRect(x: 0.25, y: 0.25, width: 0.50, height: 0.50),
      imageWidth: 200,
      imageHeight: 200,
      paddingRatio: 0.10
    )

    XCTAssertTrue(conversion.valid)
    XCTAssertEqual(conversion.pixelRect.origin.x, 50)
    XCTAssertEqual(conversion.pixelRect.origin.y, 50)
    XCTAssertEqual(conversion.pixelRect.width, 100)
    XCTAssertEqual(conversion.pixelRect.height, 100)
    XCTAssertLessThanOrEqual(conversion.paddedRect.maxX, 200)
    XCTAssertLessThanOrEqual(conversion.paddedRect.maxY, 200)
  }

  func testFaceCropperAccepts47PixelFaceForRecognitionCrop() {
    let conversion = FaceCropper.visionBoundingBoxToPixelRect(
      CGRect(x: 0.45, y: 0.40, width: 47.0 / 360.0, height: 47.0 / 640.0),
      imageWidth: 360,
      imageHeight: 640
    )

    XCTAssertTrue(conversion.valid)
    XCTAssertGreaterThanOrEqual(conversion.pixelRect.width, 47)
    XCTAssertGreaterThanOrEqual(conversion.pixelRect.height, 47)
  }

  func testFaceCropperRejects31PixelFaceBeforeDetection() {
    let conversion = FaceCropper.visionBoundingBoxToPixelRect(
      CGRect(x: 0.45, y: 0.40, width: 31.0 / 360.0, height: 31.0 / 640.0),
      imageWidth: 360,
      imageHeight: 640
    )

    XCTAssertFalse(conversion.valid)
    XCTAssertEqual(conversion.reason, "tooSmall")
  }

  func testFaceQualityRejectsTinyCrop() throws {
    let image = try makeTestImage(width: 33, height: 34)
    let crop = FaceCropResult(
      frameSequence: 1,
      frameTimestamp: Date(),
      faceBoundingBoxNormalized: CGRect(x: 0.1, y: 0.1, width: 0.05, height: 0.05),
      rawFaceBoundingBoxPixels: CGRect(x: 10, y: 10, width: 33, height: 34),
      faceBoundingBoxPixels: CGRect(x: 10, y: 10, width: 33, height: 34),
      croppedImage: image,
      previewImage: UIImage(cgImage: image),
      sourceImageSize: CGSize(width: 640, height: 480),
      visionOrientation: .up,
      alignmentMode: "boundingBoxOnly",
      yaw: nil,
      roll: nil,
      pitch: nil,
      faceCaptureQuality: 0.9,
      alignedCroppedImage: image,
      isBottomClipped: false
    )

    let decision = FaceQualityFilter().evaluate(crop)

    XCTAssertFalse(decision.accepted)
    XCTAssertEqual(decision.tier, .tooSmallForRecognition)
    XCTAssertTrue(decision.reasons.contains("tooSmallForRecognition"))
  }

  func testFaceQualityAccepts48PixelFaceForRecognitionButNotEnrollment() throws {
    let crop = try makeFaceCrop(rawWidth: 48, rawHeight: 48, cropWidth: 97, cropHeight: 109, sourceSize: CGSize(width: 360, height: 640))

    let decision = FaceQualityFilter().evaluate(crop)

    XCTAssertTrue(decision.acceptedForRecognition)
    XCTAssertFalse(decision.acceptedForEnrollment)
    XCTAssertEqual(decision.tier, .usableForRecognition)
  }

  func testFaceQualityAccepts54PixelFaceForRecognitionButNotEnrollment() throws {
    let crop = try makeFaceCrop(rawWidth: 54, rawHeight: 54, cropWidth: 104, cropHeight: 114, sourceSize: CGSize(width: 360, height: 640))

    let decision = FaceQualityFilter().evaluate(crop)

    XCTAssertTrue(decision.acceptedForRecognition)
    XCTAssertFalse(decision.acceptedForEnrollment)
    XCTAssertEqual(decision.tier, .usableForRecognition)
  }

  func testLowResolutionQualityCanPassRecognitionButNotEnrollment() throws {
    let crop = try makeFaceCrop(
      rawWidth: 82,
      rawHeight: 82,
      cropWidth: 150,
      cropHeight: 150,
      sourceSize: CGSize(width: 360, height: 640),
      faceCaptureQuality: 0.09
    )

    let decision = FaceQualityFilter().evaluate(crop)

    XCTAssertTrue(decision.acceptedForRecognition)
    XCTAssertFalse(decision.acceptedForEnrollment)
    XCTAssertTrue(decision.reasons.contains("qualityTooLowForEnrollment"))
  }

  func testLoggedLowResolutionSamplePassesRecognitionButNotEnrollment() throws {
    let crop = try makeFaceCrop(
      rawWidth: 51,
      rawHeight: 51,
      cropWidth: 97,
      cropHeight: 109,
      sourceSize: CGSize(width: 360, height: 640),
      faceCaptureQuality: 0.09
    )

    let decision = FaceQualityFilter().evaluate(crop)

    XCTAssertTrue(decision.acceptedForRecognition)
    XCTAssertFalse(decision.acceptedForEnrollment)
    XCTAssertTrue(decision.reasons.contains("lowButAcceptedForRecognition"))
  }

  func testFaceMatcherThresholds() {
    let personId = UUID()
    let record = FaceEmbeddingRecord(
      id: UUID(),
      personId: personId,
      vector: [1, 0, 0],
      dimension: 3,
      qualityScore: nil,
      sourceFrameTimestamp: Date(),
      createdAt: Date(),
      sampleImageLocalPath: nil,
      metadata: nil
    )

    let known = FaceMatcher().match(vector: [1, 0, 0], against: [record])
    let unknown = FaceMatcher().match(vector: [0, 1, 0], against: [record])

    XCTAssertEqual(known.decision, .known)
    XCTAssertEqual(known.bestPersonId, personId)
    XCTAssertEqual(unknown.decision, .unknown)
  }

  func testIdentityThresholdConfigDefaultsAreCalibrationStartingPoints() {
    XCTAssertEqual(IdentityConfig.weakMatchThreshold, 0.60, accuracy: 0.0001)
    XCTAssertEqual(IdentityConfig.strongMatchThreshold, 0.70, accuracy: 0.0001)
    XCTAssertEqual(IdentityConfig.matchMarginThreshold, 0.05, accuracy: 0.0001)
    XCTAssertEqual(IdentityConfig.rollingWindowSize, 8)
    XCTAssertEqual(IdentityConfig.requiredStrongMatches, 3)
  }

  func testCalibrationSummaryComputesDistributionsAndRecommendations() {
    let samples = [
      calibrationSample(mode: .samePerson, score: 0.68, margin: 0.10),
      calibrationSample(mode: .samePerson, score: 0.72, margin: 0.12),
      calibrationSample(mode: .samePerson, score: 0.78, margin: 0.14),
      calibrationSample(mode: .differentPerson, score: 0.42, margin: 0.04),
      calibrationSample(mode: .differentPerson, score: 0.50, margin: 0.03),
      calibrationSample(mode: .differentPerson, score: 0.56, margin: 0.02)
    ]

    let summary = FaceCalibrationSummary(samples: samples)

    XCTAssertEqual(summary.samePersonCount, 3)
    XCTAssertEqual(summary.differentPersonCount, 3)
    XCTAssertNotNil(summary.sameP10)
    XCTAssertNotNil(summary.differentP90)
    XCTAssertGreaterThan(summary.recommendedStrong, summary.recommendedWeak)
    XCTAssertGreaterThanOrEqual(summary.recommendedMargin, IdentityConfig.matchMarginThreshold)
  }

  func testCalibrationSummaryHandlesNoFaceRejectedSamplesWithoutScores() {
    let samples = [
      calibrationSample(mode: .samePerson, score: nil, margin: nil, reason: "noFaceDetected"),
      calibrationSample(mode: .differentPerson, score: nil, margin: nil, reason: "qualityRejected")
    ]

    let summary = FaceCalibrationSummary(samples: samples)

    XCTAssertEqual(summary.samePersonCount, 0)
    XCTAssertEqual(summary.differentPersonCount, 0)
    XCTAssertEqual(summary.recommendedStrong, IdentityConfig.strongMatchThreshold, accuracy: 0.0001)
    XCTAssertEqual(summary.recommendedWeak, IdentityConfig.weakMatchThreshold, accuracy: 0.0001)
  }

  func testCalibrationLabelRequiresUserTapAndModel() async {
    let pipeline = IdentityPipeline()

    let automatic = await pipeline.recordCalibrationLabel(.differentPerson, source: .automatic)
    XCTAssertTrue(automatic.calibrationSampleCountText.contains("different 0"))
    XCTAssertFalse(automatic.canRecordCalibrationLabel)

    let tapped = await pipeline.recordCalibrationLabel(.samePerson, source: .userTap)
    XCTAssertTrue(tapped.calibrationSampleCountText.contains("same 0"))
    XCTAssertFalse(tapped.canRecordCalibrationLabel)
    XCTAssertFalse(tapped.summary.localizedCaseInsensitiveContains("saved"))
  }

  func testCosineSimilarityRejectsMismatchedDimensions() {
    XCTAssertEqual(FaceMatcher.cosineSimilarity([1, 0, 0], [1, 0]), 0)
    XCTAssertEqual(FaceMatcher.cosineSimilarity([1, 0, 0], [1, 0, 0]), 1)
  }

  func testFaceMatcherRejectsMismatchedModelVersion() {
    let personId = UUID()
    let embedding = FaceEmbedding(
      vector: [1, 0, 0],
      dimension: 3,
      modelName: "MobileFaceNet",
      modelVersion: "v1",
      createdAt: Date()
    )
    let average = PersonAveragedEmbedding(
      id: UUID(),
      personId: personId,
      averagedVector: [1, 0, 0],
      vectorDimension: 3,
      sampleCount: 3,
      modelName: "MobileFaceNet",
      modelVersion: "v2",
      updatedAt: Date()
    )

    let match = FaceMatcher().match(embedding: embedding, against: [average])

    XCTAssertEqual(match.decision, .unknown)
    XCTAssertNil(match.bestPersonId)
  }

  func testFaceMatcherRejectsMismatchedPreprocessingVersion() {
    let personId = UUID()
    let embedding = FaceEmbedding(
      vector: [1, 0, 0],
      dimension: 3,
      modelName: "MobileFaceNet",
      modelVersion: "v1",
      modelSource: "Xiaoccer/MobileFaceNet_Pytorch",
      preprocessingVersion: "xiaoccer-mobilefacenet-rgb-minus-127p5-div-128-v1",
      createdAt: Date()
    )
    let average = PersonAveragedEmbedding(
      id: UUID(),
      personId: personId,
      averagedVector: [1, 0, 0],
      vectorDimension: 3,
      sampleCount: 3,
      modelName: "MobileFaceNet",
      modelVersion: "v1",
      modelSource: "Xiaoccer/MobileFaceNet_Pytorch",
      preprocessingVersion: "other-preprocessing",
      updatedAt: Date()
    )

    let match = FaceMatcher().match(embedding: embedding, against: [average])

    XCTAssertEqual(match.decision, .unknown)
    XCTAssertNil(match.bestPersonId)
  }

  func testAveragedEmbeddingIsL2Normalized() {
    let average = LocalIdentityStore.averagedNormalizedVector([
      [2, 0, 0],
      [0, 2, 0],
      [0, 2, 0]
    ])

    let norm = sqrt(average.reduce(Float(0)) { $0 + $1 * $1 })
    XCTAssertEqual(norm, 1, accuracy: 0.0001)
    XCTAssertEqual(average.count, 3)
  }

  func testL2NormalizeProducesUnitNorm() {
    let vector = LocalIdentityStore.l2Normalized([3, 4])

    let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
    XCTAssertEqual(norm, 1, accuracy: 0.0001)
    XCTAssertEqual(vector[0], 0.6, accuracy: 0.0001)
    XCTAssertEqual(vector[1], 0.8, accuracy: 0.0001)
  }

  func testAverageEmbeddingsProducesUnitNormCentroid() {
    let centroid = LocalIdentityStore.averagedNormalizedVector([
      [1, 0, 0],
      [1, 0, 0],
      [0, 1, 0]
    ])

    let norm = sqrt(centroid.reduce(Float(0)) { $0 + $1 * $1 })
    XCTAssertEqual(norm, 1, accuracy: 0.0001)
    XCTAssertEqual(centroid.count, 3)
    XCTAssertGreaterThan(centroid[0], centroid[1])
  }

  func testAverageEmbeddingsRejectsDimensionMismatch() {
    let centroid = LocalIdentityStore.averagedNormalizedVector([
      [1, 0, 0],
      [0, 1],
      [1, 0, 0]
    ])

    let norm = sqrt(centroid.reduce(Float(0)) { $0 + $1 * $1 })
    XCTAssertEqual(centroid.count, 3)
    XCTAssertEqual(norm, 1, accuracy: 0.0001)
    XCTAssertGreaterThan(centroid[0], 0.99)
  }

  func testCosineSimilarityRanksCorrectCentroidHighest() {
    let seanId = UUID()
    let otherId = UUID()
    let live = FaceEmbedding(
      vector: LocalIdentityStore.l2Normalized([0.95, 0.05, 0]),
      dimension: 3,
      modelName: "MobileFaceNet",
      modelVersion: "v1",
      modelSource: "Xiaoccer/MobileFaceNet_Pytorch",
      preprocessingVersion: "xiaoccer-mobilefacenet-rgb-minus-127p5-div-128-v1",
      createdAt: Date()
    )
    let sean = PersonAveragedEmbedding(
      id: UUID(),
      personId: seanId,
      averagedVector: LocalIdentityStore.l2Normalized([1, 0, 0]),
      vectorDimension: 3,
      sampleCount: 3,
      modelName: "MobileFaceNet",
      modelVersion: "v1",
      modelSource: "Xiaoccer/MobileFaceNet_Pytorch",
      preprocessingVersion: "xiaoccer-mobilefacenet-rgb-minus-127p5-div-128-v1",
      updatedAt: Date()
    )
    let other = PersonAveragedEmbedding(
      id: UUID(),
      personId: otherId,
      averagedVector: LocalIdentityStore.l2Normalized([0, 1, 0]),
      vectorDimension: 3,
      sampleCount: 3,
      modelName: "MobileFaceNet",
      modelVersion: "v1",
      modelSource: "Xiaoccer/MobileFaceNet_Pytorch",
      preprocessingVersion: "xiaoccer-mobilefacenet-rgb-minus-127p5-div-128-v1",
      updatedAt: Date()
    )

    let match = FaceMatcher(knownThreshold: 0.7, unknownThreshold: 0.6, marginThreshold: 0.05)
      .match(embedding: live, against: [other, sean])

    XCTAssertEqual(match.bestPersonId, seanId)
    XCTAssertGreaterThan(match.bestSimilarity, match.secondBestSimilarity ?? 0)
  }

  func testMissingFaceEmbeddingModelThrowsDetectionOnlyError() async throws {
    let model = MissingFaceEmbeddingModel(expectedNames: FaceEmbeddingModelFactory.expectedModelNames)
    let image = try makeTestImage(width: 80, height: 80)

    do {
      _ = try await model.embed(faceImage: image)
      XCTFail("Missing model should not produce embeddings")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("No MobileFaceNet/Core ML face embedding model found"))
    }
  }

  func testMobileFaceNetIsPreferredModelName() {
    XCTAssertEqual(FaceEmbeddingModelFactory.expectedModelNames.first, "MobileFaceNet")
    XCTAssertNotEqual(FaceEmbeddingModelFactory.expectedModelNames.first, "FaceNet")
    XCTAssertTrue(FaceEmbeddingModelFactory.diagnosticsText(bundle: .main).contains("source=Xiaoccer/MobileFaceNet_Pytorch"))
    XCTAssertTrue(FaceEmbeddingModelFactory.expectedModelResourceInstructions().contains("MobileFaceNet.mlpackage"))
    XCTAssertFalse(FaceEmbeddingModelFactory.diagnosticsText(bundle: .main).contains("ZJCV/facenet"))
  }

  func testMobileFaceNetSearchOrder() {
    let paths = CoreMLFaceNetEmbeddingModel.modelSearchCandidatePaths(in: .main)
    XCTAssertTrue(paths[0].hasSuffix("MobileFaceNet.mlpackage"))
    XCTAssertTrue(paths[1].hasSuffix("MobileFaceNet.mlmodel"))
    XCTAssertTrue(paths[2].hasSuffix("MobileFaceNet.mlmodelc"))
  }

  func testRollingIdentityRequiresRepeatedMatches() {
    let personId = UUID()
    let profile = PersonProfile(
      id: personId,
      displayName: "Sean",
      createdAt: Date(),
      updatedAt: Date(),
      notes: nil,
      isUnknownPlaceholder: false,
      lastSeenAt: nil,
      enrollmentStatus: .enrolled
    )
    let match = IdentityMatchResult(
      bestPersonId: personId,
      bestSimilarity: 0.9,
      secondBestSimilarity: nil,
      margin: nil,
      decision: .known,
      matchedEmbeddingId: UUID()
    )
    var tracker = RollingIdentityConfirmor()
    var state = tracker.update(match: match, profile: profile, sawGoodUnknownFace: false)
    XCTAssertNotEqual(state.state, .confirmed)
    state = tracker.update(match: match, profile: profile, sawGoodUnknownFace: false)
    XCTAssertNotEqual(state.state, .confirmed)
    state = tracker.update(match: match, profile: profile, sawGoodUnknownFace: false)
    XCTAssertEqual(state.state, .confirmed)
    XCTAssertEqual(state.personId, personId)
  }

  func testAssistanceCardFormatsKnownPersonForGlassesDisplay() {
    let card = AssistanceCardFormatter().makeCard(
      identity: .known(name: "Sarah", confidence: 0.92, userConfirmed: true),
      memory: AssistanceMemorySnapshot(
        lastInteraction: "3 weeks ago",
        contextTopics: ["Internship", "Japan trip"],
        reminder: "Follow up on resume"
      ),
      displayStatus: .glassesDisplay
    )

    XCTAssertEqual(card.title, "Sarah")
    XCTAssertFalse(card.usesFallbackOutput)
    XCTAssertTrue(card.lines.contains("Last: 3 weeks ago"))
    XCTAssertTrue(card.lines.contains("Context: Internship, Japan trip"))
    XCTAssertTrue(card.lines.contains("Reminder: Follow up on resume"))
    XCTAssertLessThanOrEqual(card.lines.count, 4)
    XCTAssertTrue(([card.title] + card.lines).allSatisfy { $0.count <= 48 })
  }

  func testAssistanceCardUsesPrivacyWarningForLowConfidenceMatch() {
    let card = AssistanceCardFormatter().makeCard(
      identity: .possibleMatch(name: "Sarah", confidence: 0.54),
      memory: AssistanceMemorySnapshot(
        lastInteraction: "Discussed confidential hiring details",
        contextTopics: ["Hiring"],
        reminder: "Ask about the offer"
      ),
      displayStatus: .glassesDisplay
    )

    XCTAssertEqual(card.title, "Possible: Sarah")
    XCTAssertTrue(card.lines.contains("Confidence: 54%"))
    XCTAssertTrue(card.lines.contains("Needs user confirmation"))
    XCTAssertTrue(card.lines.contains("Privacy: hide sensitive details"))
    XCTAssertFalse(card.text.contains("confidential"))
  }

  func testAssistanceCardHandlesNoFaceAndMultipleFaces() {
    let noFace = AssistanceCardFormatter().makeCard(
      identity: .noFaceDetected,
      memory: AssistanceMemorySnapshot(),
      displayStatus: .glassesDisplay
    )
    let multipleFaces = AssistanceCardFormatter().makeCard(
      identity: .multipleFaces(count: 3),
      memory: AssistanceMemorySnapshot(reminder: "Private note"),
      displayStatus: .glassesDisplay
    )

    XCTAssertEqual(noFace.title, "No face detected")
    XCTAssertTrue(noFace.lines.contains("Waiting for visible face"))
    XCTAssertEqual(multipleFaces.title, "3 faces detected")
    XCTAssertTrue(multipleFaces.lines.contains("Select one person"))
    XCTAssertFalse(multipleFaces.text.contains("Private note"))
  }

  func testAssistanceCardLabelsDisplayFallback() {
    let card = AssistanceCardFormatter().makeCard(
      identity: .unknown,
      memory: AssistanceMemorySnapshot(),
      displayStatus: .fallback("phone overlay")
    )

    XCTAssertTrue(card.usesFallbackOutput)
    XCTAssertEqual(card.title, "Unknown person")
    XCTAssertEqual(card.lines.first, "Fallback: phone overlay")
    XCTAssertTrue(card.lines.contains("Needs confirmation"))
  }

  func testSpeechAndMicrophoneUsageDescriptionsArePresent() {
    let speech = Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") as? String
    let microphone = Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String

    XCTAssertFalse(speech?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    XCTAssertFalse(microphone?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
  }

  private func makeTestImage(width: Int, height: Int) throws -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      throw NSError(domain: "CameraAccessTests", code: 1)
    }
    context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else {
      throw NSError(domain: "CameraAccessTests", code: 2)
    }
    return image
  }

  private func calibrationSample(
    mode: FaceCalibrationMode,
    score: Float?,
    margin: Float?,
    reason: String? = nil
  ) -> FaceCalibrationSample {
    FaceCalibrationSample(
      mode: mode,
      source: .userTap,
      profileLabel: mode == .samePerson ? "Sean" : "NonMatch",
      score: score,
      secondBestScore: nil,
      margin: margin,
      threshold: IdentityConfig.strongMatchThreshold,
      decision: score == nil ? "notMatched" : "possibleMatch",
      rawFaceWidth: 96,
      rawFaceHeight: 96,
      cropWidth: 160,
      cropHeight: 160,
      quality: 0.35,
      brightness: 0.42,
      blur: nil,
      acceptedForRecognition: score != nil,
      acceptedForEnrollment: mode == .samePerson && score != nil,
      rejectionReason: reason,
      createdAt: Date()
    )
  }

  private func makeFaceCrop(
    width: Int,
    height: Int,
    sourceSize: CGSize,
    faceCaptureQuality: Float = 0.9
  ) throws -> FaceCropResult {
    try makeFaceCrop(
      rawWidth: width,
      rawHeight: height,
      cropWidth: width,
      cropHeight: height,
      sourceSize: sourceSize,
      faceCaptureQuality: faceCaptureQuality
    )
  }

  private func makeFaceCrop(
    rawWidth: Int,
    rawHeight: Int,
    cropWidth: Int,
    cropHeight: Int,
    sourceSize: CGSize,
    faceCaptureQuality: Float = 0.9
  ) throws -> FaceCropResult {
    let image = try makeTestImage(width: cropWidth, height: cropHeight)
    let origin = CGPoint(
      x: (sourceSize.width - CGFloat(rawWidth)) / 2,
      y: (sourceSize.height - CGFloat(rawHeight)) / 2
    )
    return FaceCropResult(
      frameSequence: 1,
      frameTimestamp: Date(),
      faceBoundingBoxNormalized: CGRect(x: 0.4, y: 0.4, width: CGFloat(rawWidth) / sourceSize.width, height: CGFloat(rawHeight) / sourceSize.height),
      rawFaceBoundingBoxPixels: CGRect(origin: origin, size: CGSize(width: rawWidth, height: rawHeight)),
      faceBoundingBoxPixels: CGRect(origin: origin, size: CGSize(width: cropWidth, height: cropHeight)),
      croppedImage: image,
      previewImage: UIImage(cgImage: image),
      sourceImageSize: sourceSize,
      visionOrientation: .up,
      alignmentMode: "boundingBoxOnly",
      yaw: nil,
      roll: nil,
      pitch: nil,
      faceCaptureQuality: faceCaptureQuality,
      alignedCroppedImage: image,
      isBottomClipped: false
    )
  }
}
