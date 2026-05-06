/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamView.swift
//
// Main UI for local video-file simulation with real-time Vision and Speech output.
//

import SwiftUI

struct StreamView: View {
  @ObservedObject var viewModel: StreamSessionViewModel

  var body: some View {
    ZStack {
      // Black background for letterboxing/pillarboxing
      Color.black
        .edgesIgnoringSafeArea(.all)

      // Video backdrop
      if let videoFrame = viewModel.currentVideoFrame, viewModel.hasReceivedFirstFrame {
        GeometryReader { geometry in
          ZStack {
            Image(uiImage: videoFrame)
              .resizable()
              .aspectRatio(contentMode: .fill)
              .frame(width: geometry.size.width, height: geometry.size.height)
              .clipped()

            FaceOverlayView(faces: viewModel.detectedFaces, imageSize: viewModel.currentImageSize)
          }
        }
        .edgesIgnoringSafeArea(.all)
      } else {
        ProgressView()
          .scaleEffect(1.5)
          .foregroundColor(.white)
      }

      VStack {
        StreamHUDView(viewModel: viewModel)
        PeopleStripView(people: viewModel.people)
        Spacer()
        ControlsView(viewModel: viewModel)
      }
      .padding(.all, 24)
    }
    .onDisappear {
      Task {
        if viewModel.streamingStatus != .stopped {
          await viewModel.stopSession()
        }
      }
    }
  }
}

// Extracted controls for clarity
struct ControlsView: View {
  @ObservedObject var viewModel: StreamSessionViewModel
  var body: some View {
    VStack(spacing: 10) {
      CustomButton(
        title: "Stop streaming",
        style: .destructive,
        isDisabled: false
      ) {
        Task {
          await viewModel.stopSession()
        }
      }
      .accessibilityIdentifier("Stop streaming")

      HStack(spacing: 12) {
        CircleButton(icon: "arrow.clockwise", text: "Restart") {
          Task {
            if viewModel.inputMode == .realGlasses {
              await viewModel.startRealGlassesStream()
            } else if viewModel.inputMode == .mockDeviceKit {
              await viewModel.startMockDeviceKitStream()
            } else {
              await viewModel.startSimulation()
            }
          }
        }
        .accessibilityIdentifier("restart_simulation_button")
      }
    }
  }
}

private struct StreamHUDView: View {
  @ObservedObject var viewModel: StreamSessionViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(viewModel.lifecycleState.rawValue)
          .font(.system(size: 13, weight: .bold))
          .foregroundColor(.white)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(statusColor)
          .clipShape(RoundedRectangle(cornerRadius: 4))

        Text("Faces: \(viewModel.detectedFaces.count)")
          .font(.system(size: 13, weight: .semibold))
          .foregroundColor(.white)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(Color.black.opacity(0.65))
          .clipShape(RoundedRectangle(cornerRadius: 4))
      }

      Text("Stream \(viewModel.streamStateText) | Source \(viewModel.sourceStateText)")
        .font(.system(size: 12))
        .foregroundColor(.white)
      Text("Input \(viewModel.inputMode.rawValue)")
        .font(.system(size: 12))
        .foregroundColor(.white.opacity(0.85))
      if viewModel.inputMode == .realGlasses || viewModel.inputMode == .mockDeviceKit {
        Text("DAT \(viewModel.datSDKStatusText) | Mode \(viewModel.datConfigurationModeText)")
          .font(.system(size: 12))
          .foregroundColor(.white.opacity(0.85))
        Text("Connection stage \(viewModel.datConnectionStageText)")
          .font(.system(size: 12, weight: .semibold))
          .foregroundColor(.white.opacity(0.85))
        Text("Runtime bundle: \(viewModel.datRuntimeBundleConfigurationText)")
          .font(.system(size: 11))
          .foregroundColor(.white.opacity(0.85))
          .lineLimit(4)
        Text("URL types: \(viewModel.datRuntimeURLTypesText)")
          .font(.system(size: 11))
          .foregroundColor(.white.opacity(0.85))
          .lineLimit(3)
        Text("URL scheme cameraaccess \(viewModel.datRuntimeCameraAccessSchemeText) | Associated Domains \(viewModel.datRuntimeAssociatedDomainsText) | Dev flag \(viewModel.datRuntimeDeveloperModeFlagText)")
          .font(.system(size: 11))
          .foregroundColor(.white.opacity(0.85))
          .lineLimit(3)
        Text("Developer Mode assumed \(viewModel.datConfigurationModeText == DATConfigurationMode.developerMode.rawValue ? "yes" : "no") | App active \(viewModel.datIsAppActive ? "yes" : "no")")
          .font(.system(size: 12))
          .foregroundColor(.white.opacity(0.85))
        Text("Registration \(viewModel.datRegistrationStateText) | Waiting Meta AI \(viewModel.datWaitingForMetaAIReturn ? "yes" : "no")")
          .font(.system(size: 12))
          .foregroundColor(.white.opacity(0.85))
        Text("startRegistration \(viewModel.datStartRegistrationCalledText)")
          .font(.system(size: 12))
          .foregroundColor(.white.opacity(0.85))
        Text("Meta AI opened \(viewModel.datMetaAIOpenedTimestampText)")
          .font(.system(size: 12))
          .foregroundColor(.white.opacity(0.85))
        Text("Handoff \(viewModel.datRegistrationHandoffDiagnosticText)")
          .font(.system(size: 11))
          .foregroundColor(.white.opacity(0.85))
          .lineLimit(5)
        Text("devicesStream \(viewModel.datDevicesStreamActive ? "active" : "inactive") | Last devices \(viewModel.datLastDevicesEventTimestampText)")
          .font(.system(size: 12))
          .foregroundColor(.white.opacity(0.85))
        Text("Devices \(viewModel.datDeviceCount) | Selected \(viewModel.datSelectedDeviceIDText)")
          .font(.system(size: 12))
          .foregroundColor(.white.opacity(0.85))
        Text("Compatibility \(viewModel.datSelectedDeviceCompatibilityText) | Link \(viewModel.datSelectedDeviceLinkStateText)")
          .font(.system(size: 12))
          .foregroundColor(.white.opacity(0.85))
        Text("DeviceSession \(viewModel.datDeviceSessionStateText) | Runtime \(viewModel.datRuntimeSessionStateText)")
          .font(.system(size: 12))
          .foregroundColor(.white.opacity(0.85))
        Text("StreamSession \(viewModel.datStreamSessionStateText)")
          .font(.system(size: 12))
          .foregroundColor(.white.opacity(0.85))
        Text("DAT camera \(viewModel.datCameraPermissionStatusText) | requestPermission \(viewModel.datRequestCameraPermissionCalledText)")
          .font(.system(size: 12))
          .foregroundColor(.white.opacity(0.85))
        Text("Start readiness: \(viewModel.datStartReadinessReasonText)")
          .font(.system(size: 12, weight: .semibold))
          .foregroundColor(.white.opacity(0.85))
        Text("Returned active \(viewModel.datLastActiveAfterReturnText)")
          .font(.system(size: 12))
          .foregroundColor(.white.opacity(0.85))
        Text("Last URL \(viewModel.datLastOpenURLText)")
          .font(.system(size: 12))
          .foregroundColor(.white.opacity(0.85))
          .lineLimit(2)
        Text("handleUrl \(viewModel.datLastHandleURLResultText)")
          .font(.system(size: 12))
          .foregroundColor(.white.opacity(0.85))
          .lineLimit(2)
        Text("Last DAT error: \(viewModel.datLastErrorText)")
          .font(.system(size: 12))
          .foregroundColor(.white.opacity(0.85))
          .lineLimit(2)
        Text("Registration error detail: \(viewModel.datLastRegistrationErrorDetailText)")
          .font(.system(size: 11))
          .foregroundColor(.white.opacity(0.85))
          .lineLimit(4)
      }
      Text("Frames \(viewModel.framesReceived) | Dropped \(viewModel.droppedFrames) | \(viewModel.lastFrameIntervalText)")
        .font(.system(size: 12))
        .foregroundColor(.white.opacity(0.85))
      Text("Preview \(viewModel.previewFrames) | Vision \(viewModel.visionProcessedFrames)/\(viewModel.visionSubmittedFrames)")
        .font(.system(size: 12))
        .foregroundColor(.white.opacity(0.85))
      Text(viewModel.liveFrameStatsText)
        .font(.system(size: 12))
        .foregroundColor(.white.opacity(0.85))
        .lineLimit(2)
      Text("Last frame \(viewModel.lastFrameTimestampText)")
        .font(.system(size: 12))
        .foregroundColor(.white.opacity(0.85))
      Text("First DAT frame \(viewModel.datFirstFrameTimestampText)")
        .font(.system(size: 12))
        .foregroundColor(.white.opacity(0.85))
      Text("DAT frames received \(viewModel.datFramesReceived) | display \(viewModel.datFramesConvertedToUIImage) | failures \(viewModel.datFrameConversionFailures)")
        .font(.system(size: 12))
        .foregroundColor(.white.opacity(0.85))
      Text("DAT frame size \(viewModel.datLastFrameWidthText)x\(viewModel.datLastFrameHeightText) | \(viewModel.datLastFrameTimestampText)")
        .font(.system(size: 12))
        .foregroundColor(.white.opacity(0.85))
      Text("DAT frame error \(viewModel.datLastFrameErrorText)")
        .font(.system(size: 12))
        .foregroundColor(.white.opacity(0.85))
        .lineLimit(2)
      Text("Vision \(viewModel.visionLatencyText) | Audio \(viewModel.microphoneStatusText)")
        .font(.system(size: 12))
        .foregroundColor(.white.opacity(0.85))
      Text(viewModel.speechAuthorizationStatusText)
        .font(.system(size: 12))
        .foregroundColor(.white.opacity(0.85))
      Text("Transcript: \(viewModel.partialTranscript)")
        .font(.system(size: 12, weight: .semibold))
        .foregroundColor(.white.opacity(0.85))
        .lineLimit(3)
      if !viewModel.transcriptEntries.isEmpty {
        Text("Final: \(viewModel.transcriptEntries.map(\.text).joined(separator: " "))")
          .font(.system(size: 12))
          .foregroundColor(.white.opacity(0.85))
          .lineLimit(3)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
    .background(Color.black.opacity(0.50))
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  private var statusColor: Color {
    switch viewModel.lifecycleState {
    case .running:
      return .green
    case .paused, .waiting, .starting:
      return .orange
    case .error:
      return .red
    case .stopping, .stopped:
      return .gray
    }
  }
}

private struct PeopleStripView: View {
  let people: [Person]

  var body: some View {
    if !people.isEmpty {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 10) {
          ForEach(people) { person in
            VStack(spacing: 6) {
              Image(uiImage: person.faceImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 6))
              Text(person.displayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
            }
            .frame(width: 72)
            .padding(8)
            .background(Color.black.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 8))
          }
        }
        .padding(.vertical, 8)
      }
    }
  }
}
