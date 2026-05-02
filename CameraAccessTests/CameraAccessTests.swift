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

  func testSpeechAndMicrophoneUsageDescriptionsArePresent() {
    let speech = Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") as? String
    let microphone = Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String

    XCTAssertEqual(
      speech,
      "This app uses Apple Speech recognition to transcribe live local audio while processing the glasses stream."
    )
    XCTAssertEqual(
      microphone,
      "This app uses the iPhone microphone to transcribe live audio while streaming from your glasses."
    )
  }
}
