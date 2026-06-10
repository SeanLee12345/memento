/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import XCTest

final class MementoUITests: XCTestCase {

  private let app = XCUIApplication()

  override func setUpWithError() throws {
    continueAfterFailure = false
    app.launchArguments = ["--ui-testing"]
  }

  // MARK: - Helpers

  /// Waits for the Start Stream button to exist and be enabled (mock device active).
  private func waitForStartStreamingEnabled(timeout: TimeInterval = 15) -> XCUIElement {
    let startButton = app.buttons["Start streaming"]
    XCTAssertTrue(startButton.waitForExistence(timeout: timeout), "Start streaming button should appear")

    let enabledPredicate = NSPredicate(format: "isEnabled == true")
    expectation(for: enabledPredicate, evaluatedWith: startButton)
    waitForExpectations(timeout: timeout)

    return startButton
  }

  /// Starts streaming and waits for the StreamView to appear.
  private func startStreaming(timeout: TimeInterval = 15) {
    let startButton = waitForStartStreamingEnabled(timeout: timeout)
    startButton.tap()

    let stopButton = app.buttons["Stop streaming"]
    XCTAssertTrue(stopButton.waitForExistence(timeout: timeout), "Stop streaming button should appear after starting")
  }

  // MARK: - Tests

  /// Verifies the app launches directly to the streaming screen (NonStreamView)
  /// when MockDeviceKit is auto-configured via --ui-testing launch argument.
  @MainActor
  func testAppLaunchShowsStreamingScreen() {
    app.launch()

    // Mock device auto-paired -> should skip HomeScreenView and show NonStreamView.
    let title = app.staticTexts["Memento"]
    XCTAssertTrue(title.waitForExistence(timeout: 10), "NonStreamView title should be visible")

    let startButton = app.buttons["Start streaming"]
    XCTAssertTrue(startButton.exists, "Start streaming button should be present")
    XCTAssertTrue(app.buttons["People"].exists, "People button should be present")
  }

  /// Verifies the complete start → stop streaming flow.
  @MainActor
  func testStartAndStopStreaming() {
    app.launch()

    // Wait for device to become active and start streaming
    startStreaming()

    // Stop streaming
    let stopButton = app.buttons["Stop streaming"]
    stopButton.tap()

    // Should return to NonStreamView
    let startButton = app.buttons["Start streaming"]
    XCTAssertTrue(startButton.waitForExistence(timeout: 10), "Should return to NonStreamView after stopping")
    XCTAssertTrue(app.staticTexts["Memento"].exists, "NonStreamView title should reappear")
  }

  /// Verifies the prototype simulation flow: mock device, stream frames, face overlay, and stop.
  @MainActor
  func testCompleteSimulationFaceFlow() {
    app.launch()

    startStreaming(timeout: 20)

    let faceLabel = app.staticTexts["Person 1"]
    XCTAssertTrue(faceLabel.waitForExistence(timeout: 20), "Face label should render over the mock stream")

    app.buttons["Stop streaming"].tap()
    XCTAssertTrue(app.buttons["Start streaming"].waitForExistence(timeout: 10), "Start button should return after stop")
  }

  /// Verifies the phone streaming surface no longer exposes a photo capture button.
  @MainActor
  func testPhotoCaptureButtonIsNotShownDuringStreaming() {
    app.launch()

    startStreaming()

    let captureButton = app.buttons["capture_photo_button"]
    XCTAssertFalse(captureButton.waitForExistence(timeout: 2), "Photo capture button should not be visible during streaming")

    let stopButton = app.buttons["Stop streaming"]
    XCTAssertTrue(stopButton.waitForExistence(timeout: 10), "Should still be streaming")

    stopButton.tap()

    let startButton = app.buttons["Start streaming"]
    XCTAssertTrue(startButton.waitForExistence(timeout: 10), "Should return to NonStreamView after stopping")
  }
}
