/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// NonStreamView.swift
//
// Default screen to show getting started tips after app connection
// Initiates streaming
//

import SwiftUI

struct NonStreamView: View {
  @ObservedObject var viewModel: StreamSessionViewModel

  var body: some View {
    ZStack {
      Color.black.edgesIgnoringSafeArea(.all)

      VStack(spacing: 0) {
        ScrollView {
          VStack(spacing: 0) {
            HStack {
              VStack(alignment: .leading, spacing: 4) {
                Text("Session \(viewModel.lifecycleState.rawValue)")
                  .font(.system(size: 13, weight: .bold))
                  .foregroundColor(.white)
                Text("Stream \(viewModel.streamStateText) | Source \(viewModel.sourceStateText)")
                  .font(.system(size: 12))
                  .foregroundColor(.white.opacity(0.72))
              }
              Spacer()
            }
            .padding(.bottom, 8)

            DebugInfoBlock(viewModel: viewModel)
              .padding(.bottom, 16)

            VStack(spacing: 12) {
              Image(.cameraAccessIcon)
                .resizable()
                .renderingMode(.template)
                .foregroundColor(.white)
                .aspectRatio(contentMode: .fit)
                .frame(width: 120)

              Text(viewModel.inputMode == .realGlasses ? "Meta Glasses Stream" : "Mock Device Stream")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)

              Text(
                viewModel.inputMode == .realGlasses
                  ? "Connect your paired Meta glasses, then start the live DAT stream. Use Mock Device Kit only as a fallback."
                  : "Set up the official Mock Device Kit state, select the bundled video, then start the DAT stream."
              )
              .font(.system(size: 15))
              .multilineTextAlignment(.center)
              .foregroundColor(.white)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 24)
          }
          .padding(.all, 24)
        }

        VStack(spacing: 10) {
          CustomButton(
            title: "Connect Real Glasses",
            style: .primary,
            isDisabled: !viewModel.canConnectRealGlasses
          ) {
            Task {
              await viewModel.connectRealGlasses()
            }
          }
          .accessibilityIdentifier("Connect Real Glasses")

          CustomButton(
            title: "Start Real Stream",
            style: .primary,
            isDisabled: !viewModel.canStartRealStream
          ) {
            Task {
              await viewModel.startRealGlassesStream()
            }
          }
          .accessibilityIdentifier("Start Real Stream")

          CustomButton(
            title: "Unregister DAT App",
            style: .primary,
            isDisabled: viewModel.datSDKStatusText != "Configured"
          ) {
            Task {
              await viewModel.unregisterDATApp()
            }
          }
          .accessibilityIdentifier("Unregister DAT App")

          CustomButton(
            title: "Stop/Reset Session",
            style: .primary,
            isDisabled: viewModel.datSDKStatusText != "Configured"
          ) {
            Task {
              await viewModel.resetDATDeviceSession()
            }
          }
          .accessibilityIdentifier("Stop Reset Session")

          CustomButton(
            title: "Use Mock Device Kit Instead",
            style: .primary,
            isDisabled: false
          ) {
            viewModel.useMockDeviceKitMode()
          }
          .accessibilityIdentifier("Use Mock Device Kit")

          if viewModel.inputMode == .mockDeviceKit {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
              CustomButton(title: "Pair RayBan Meta", style: .primary, isDisabled: false) {
                viewModel.pairMockRayBanMeta()
              }
              CustomButton(title: "PowerOn", style: .primary, isDisabled: !viewModel.mockDevicePaired) {
                viewModel.powerOnMockDevice()
              }
              CustomButton(title: "Unfold", style: .primary, isDisabled: !viewModel.mockDevicePoweredOn) {
                viewModel.unfoldMockDevice()
              }
              CustomButton(title: "Don", style: .primary, isDisabled: !viewModel.mockDeviceUnfolded) {
                viewModel.donMockDevice()
              }
              CustomButton(title: "Select video", style: .primary, isDisabled: !viewModel.mockDeviceDonned) {
                viewModel.selectMockVideo()
              }
              CustomButton(
                title: "Start mock stream",
                style: .primary,
                isDisabled: !viewModel.canStartMockDeviceKitStream
              ) {
                Task {
                  await viewModel.startMockDeviceKitStream()
                }
              }
            }
          }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .padding(.top, 8)
        .background(Color.black)
      }
    }
  }
}

private struct DebugInfoBlock: View {
  @ObservedObject var viewModel: StreamSessionViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      debugRow("Input", viewModel.inputMode.rawValue)
      debugRow("DAT", "\(viewModel.datSDKStatusText) | Mode \(viewModel.datConfigurationModeText)")
      debugRow("Connection stage", viewModel.datConnectionStageText, weight: .semibold)
      debugRow("Runtime bundle", viewModel.datRuntimeBundleConfigurationText)
      debugRow("URL types", viewModel.datRuntimeURLTypesText)
      debugRow(
        "URL scheme",
        "cameraaccess \(viewModel.datRuntimeCameraAccessSchemeText) | Associated Domains \(viewModel.datRuntimeAssociatedDomainsText) | Dev flag \(viewModel.datRuntimeDeveloperModeFlagText)"
      )
      debugRow(
        "Developer Mode",
        "\(viewModel.datConfigurationModeText == DATConfigurationMode.developerMode.rawValue ? "yes" : "no") | App active \(viewModel.datIsAppActive ? "yes" : "no")"
      )
      debugRow(
        "Registration",
        "\(viewModel.datRegistrationStateText) | Waiting Meta AI \(viewModel.datWaitingForMetaAIReturn ? "yes" : "no")"
      )
      debugRow("startRegistration", viewModel.datStartRegistrationCalledText)
      debugRow("Meta AI opened", viewModel.datMetaAIOpenedTimestampText)
      debugRow("Handoff", viewModel.datRegistrationHandoffDiagnosticText)
      debugRow(
        "devicesStream",
        "\(viewModel.datDevicesStreamActive ? "active" : "inactive") | First \(viewModel.datFirstDevicesStreamEventTimestampText)"
      )
      debugRow("Last devices event", viewModel.datLastDevicesEventTimestampText)
      debugRow("Devices", "\(viewModel.datDeviceCount) | Selected \(viewModel.datSelectedDeviceIDText)")
      debugRow("Compatibility", "\(viewModel.datSelectedDeviceCompatibilityText) | Link \(viewModel.datSelectedDeviceLinkStateText)")
      debugRow("DeviceSession", "\(viewModel.datDeviceSessionStateText) | Runtime \(viewModel.datRuntimeSessionStateText)")
      debugRow("StreamSession", viewModel.datStreamSessionStateText)

      Divider().background(Color.white.opacity(0.2))

      VStack(alignment: .leading, spacing: 2) {
        Text("Start readiness")
          .font(.system(size: 11, weight: .semibold))
          .foregroundColor(.white.opacity(0.5))
        Text(viewModel.datStartReadinessReasonText)
          .font(.system(size: 12, weight: .semibold))
          .foregroundColor(viewModel.canStartRealStream ? .green : .orange)
          .fixedSize(horizontal: false, vertical: true)
      }

      Divider().background(Color.white.opacity(0.2))

      debugRow("First DAT frame", viewModel.datFirstFrameTimestampText)
      debugRow("Live stats", viewModel.liveFrameStatsText)
      debugRow(
        "DAT frames",
        "received \(viewModel.datFramesReceived) | display \(viewModel.datFramesConvertedToUIImage) | failures \(viewModel.datFrameConversionFailures)"
      )
      debugRow(
        "DAT frame size",
        "\(viewModel.datLastFrameWidthText)x\(viewModel.datLastFrameHeightText) | \(viewModel.datLastFrameTimestampText)"
      )
      debugRow("DAT frame error", viewModel.datLastFrameErrorText)
      debugRow("DAT camera", viewModel.datCameraPermissionStatusText)
      debugRow("requestPermission", viewModel.datRequestCameraPermissionCalledText)
      debugRow("Returned active", viewModel.datLastActiveAfterReturnText)
      debugRow("Last URL", viewModel.datLastOpenURLText)
      debugRow("handleUrl", viewModel.datLastHandleURLResultText)

      Divider().background(Color.white.opacity(0.2))

      VStack(alignment: .leading, spacing: 2) {
        Text("Last DAT error")
          .font(.system(size: 11, weight: .semibold))
          .foregroundColor(.white.opacity(0.5))
        Text(viewModel.datLastErrorText)
          .font(.system(size: 12))
          .foregroundColor(.red.opacity(0.9))
          .fixedSize(horizontal: false, vertical: true)
      }

      VStack(alignment: .leading, spacing: 2) {
        Text("Registration error detail")
          .font(.system(size: 11, weight: .semibold))
          .foregroundColor(.white.opacity(0.5))
        Text(viewModel.datLastRegistrationErrorDetailText)
          .font(.system(size: 11))
          .foregroundColor(.orange.opacity(0.85))
          .fixedSize(horizontal: false, vertical: true)
      }

      Text("Developer Mode note: only one third-party app can remain registered at a time. If registration does not complete, open Meta AI and unregister old test integrations for these glasses.")
        .font(.system(size: 11))
        .foregroundColor(.white.opacity(0.7))
        .fixedSize(horizontal: false, vertical: true)

      if viewModel.inputMode == .mockDeviceKit {
        Divider().background(Color.white.opacity(0.2))
        debugRow("Mock device", "\(viewModel.mockDeviceIDText) | enabled \(viewModel.mockDeviceKitEnabled ? "yes" : "no") | video \(viewModel.mockDeviceHasVideoFeed ? "yes" : "no")")
        debugRow("Mock states", "power \(viewModel.mockDevicePoweredOn ? "on" : "off") | unfold \(viewModel.mockDeviceUnfolded ? "yes" : "no") | don \(viewModel.mockDeviceDonned ? "yes" : "no")")
        debugRow("Last mock error", viewModel.mockDeviceErrorText)
      }

      Divider().background(Color.white.opacity(0.2))

      debugRow("Audio", viewModel.microphoneStatusText, weight: .semibold)
      debugRow("Speech auth", viewModel.speechAuthorizationStatusText)
      if !viewModel.partialTranscript.isEmpty {
        debugRow("Transcript", viewModel.partialTranscript)
      }
      if !viewModel.transcriptEntries.isEmpty {
        debugRow("Final", viewModel.transcriptEntries.map(\.text).joined(separator: " "))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(Color.white.opacity(0.10))
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  @ViewBuilder
  private func debugRow(_ label: String, _ value: String, weight: Font.Weight = .regular) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(.white.opacity(0.5))
      Text(value)
        .font(.system(size: 12, weight: weight))
        .foregroundColor(.white.opacity(0.82))
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct GettingStartedSheetView: View {
  @Environment(\.dismiss) var dismiss
  @Binding var height: CGFloat

  var body: some View {
    VStack(spacing: 24) {
      Text("Getting started")
        .font(.system(size: 18, weight: .semibold))
        .foregroundColor(.primary)

      VStack(spacing: 12) {
        TipItemView(resource: .videoIcon, text: "Connect to paired Meta glasses through the Device Access Toolkit.")
        TipItemView(
          resource: .tapIcon,
          text: "Vision processes each delivered sample buffer with one frame in flight."
        )
        TipItemView(
          resource: .smartGlassesIcon,
          text: "Speech transcription uses the iPhone microphone in real glasses mode."
        )
      }
      .padding(.bottom, 16)

      CustomButton(
        title: "Continue",
        style: .primary,
        isDisabled: false
      ) {
        dismiss()
      }
    }
    .padding(.all, 24)
    .background(
      GeometryReader { geo -> Color in
        DispatchQueue.main.async {
          height = geo.size.height
        }
        return Color.clear
      }
    )
  }
}

struct TipItemView: View {
  let resource: ImageResource
  let text: String

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(resource)
        .resizable()
        .renderingMode(.template)
        .foregroundColor(.primary)
        .aspectRatio(contentMode: .fit)
        .frame(width: 24)
        .padding(.leading, 4)
        .padding(.top, 4)

      Text(text)
        .font(.system(size: 15))
        .foregroundColor(.primary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
