/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import SwiftUI

private let waitingForActiveDeviceText = "Waiting for an active device"

struct NonStreamView: View {
  @ObservedObject var viewModel: StreamSessionViewModel
  @State private var showSettingsMenu = false
  @State private var showAdvancedControls = false

  var body: some View {
    ZStack {
      Color.black.edgesIgnoringSafeArea(.all)

      if showSettingsMenu {
        Color.clear
          .contentShape(Rectangle())
          .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
              showSettingsMenu = false
            }
          }
          .edgesIgnoringSafeArea(.all)
      }

      VStack {
        topBar

        Spacer()

        heroContent

        Spacer()

        startControls
      }
      .padding(.all, 24)
    }
    .sheet(isPresented: $showAdvancedControls) {
      AdvancedControlsSheet(viewModel: viewModel)
    }
  }

  private var topBar: some View {
    HStack {
      Spacer()

      Button {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
          showSettingsMenu.toggle()
        }
      } label: {
        Image(systemName: "gearshape")
          .resizable()
          .aspectRatio(contentMode: .fit)
          .foregroundColor(.white)
          .frame(width: 24, height: 24)
      }
      .overlay(alignment: .topTrailing) {
        if showSettingsMenu {
          settingsMenu
            .frame(width: 190)
            .padding(.top, 36)
            .transition(.scale(scale: 0.01, anchor: .topTrailing).combined(with: .opacity))
        }
      }
    }
    .zIndex(2)
  }

  private var settingsMenu: some View {
    VStack(spacing: 8) {
      CustomButton(
        title: "App controls",
        style: .primary,
        isDisabled: false
      ) {
        showAdvancedControls = true
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
          showSettingsMenu = false
        }
      }

      CustomButton(
        title: "People",
        style: .primary,
        isDisabled: false
      ) {
        viewModel.openPeopleDictionary()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
          showSettingsMenu = false
        }
      }

      CustomButton(
        title: "Disconnect",
        style: .destructive,
        isDisabled: viewModel.datRegistrationStateText != "registered"
      ) {
        Task { await viewModel.unregisterDATApp() }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
          showSettingsMenu = false
        }
      }
    }
  }

  private var heroContent: some View {
    VStack(spacing: 12) {
      Image(.cameraAccessIcon)
        .resizable()
        .renderingMode(.template)
        .foregroundColor(.white)
        .aspectRatio(contentMode: .fit)
        .frame(width: 120)

      Text("Stream Your Glasses Camera")
        .font(.system(size: 20, weight: .semibold))
        .foregroundColor(.white)

      Text("Tap the Start streaming button to stream video from your glasses.")
        .font(.system(size: 15))
        .multilineTextAlignment(.center)
        .foregroundColor(.white)
    }
    .padding(.horizontal, 12)
  }

  private var startControls: some View {
    VStack(spacing: 12) {
      activeDeviceStatus

      if viewModel.datRegistrationStateText != "registered" {
        CustomButton(
          title: viewModel.connectGlassesButtonTitle,
          style: .primary,
          isDisabled: !viewModel.canConnectRealGlasses
        ) {
          Task { await viewModel.connectRealGlasses() }
        }
        .accessibilityIdentifier("Connect my glasses")
      }

      CustomButton(
        title: "Start streaming",
        style: .primary,
        isDisabled: !viewModel.canStartRealStream
      ) {
        Task { await viewModel.startRealGlassesStream() }
      }
      .accessibilityIdentifier("Start streaming")

      if viewModel.datLastErrorText != "None" {
        Text(viewModel.datLastErrorText)
          .font(.system(size: 12))
          .foregroundColor(Color.orange.opacity(0.9))
          .multilineTextAlignment(.center)
          .lineLimit(3)
      }
    }
  }

  private var activeDeviceStatus: some View {
    HStack(spacing: 8) {
      Image(systemName: "hourglass")
        .resizable()
        .aspectRatio(contentMode: .fit)
        .foregroundColor(Color.white.opacity(0.7))
        .frame(width: 16, height: 16)

      Text(waitingStatusText)
        .font(.system(size: 14))
        .foregroundColor(Color.white.opacity(0.7))
    }
    .opacity(viewModel.canStartRealStream ? 0 : 1)
  }

  private var waitingStatusText: String {
    if viewModel.datRegistrationStateText != "registered" {
      return "Connect your glasses"
    }
    if !viewModel.datHasActiveDevice {
      return waitingForActiveDeviceText
    }
    return viewModel.datStartReadinessReasonText
  }
}

private struct AdvancedControlsSheet: View {
  @ObservedObject var viewModel: StreamSessionViewModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    ZStack {
      Color.black.edgesIgnoringSafeArea(.all)

      ScrollView {
        VStack(spacing: 14) {
          HStack {
            Text("App controls")
              .font(.system(size: 18, weight: .semibold))
              .foregroundColor(.white)
            Spacer()
            Button("Done") {
              dismiss()
            }
            .font(.system(size: 15, weight: .semibold))
          }

          ConnectionStatusCard(viewModel: viewModel)
          LastDetectedFacePanel(viewModel: viewModel)
          WearerVoiceProfilePanel(viewModel: viewModel)
          SettingsCard(viewModel: viewModel)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
      }
    }
  }
}

// MARK: - Connection Status

private struct ConnectionStatusCard: View {
  @ObservedObject var viewModel: StreamSessionViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        Image(.cameraAccessIcon)
          .resizable()
          .renderingMode(.template)
          .foregroundColor(.white)
          .aspectRatio(contentMode: .fit)
          .frame(width: 24)
        Text("Meta Glasses")
          .font(.system(size: 17, weight: .bold))
          .foregroundColor(.white)
        Spacer()
        modeBadge
      }

      Divider().background(Color.white.opacity(0.15))

      HStack(alignment: .top, spacing: 0) {
        VStack(alignment: .leading, spacing: 3) {
          label("Stage")
          Text(viewModel.datConnectionStageText)
            .font(.system(size: 13))
            .foregroundColor(.white.opacity(0.85))
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 3) {
          label("Readiness")
          Text(viewModel.datStartReadinessReasonText)
            .font(.system(size: 12))
            .foregroundColor(viewModel.canStartRealStream ? .green : Color.orange.opacity(0.9))
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      VStack(alignment: .leading, spacing: 6) {
        statusLine("Camera", viewModel.datCameraPermissionStatusText)
        statusLine("Device", deviceStatusText)
        if viewModel.datLastErrorText != "None" {
          statusLine("DAT", viewModel.datLastErrorText, color: Color.orange.opacity(0.9))
        }
      }
      .padding(.top, 2)
    }
    .padding(14)
    .background(Color.white.opacity(0.08))
    .clipShape(RoundedRectangle(cornerRadius: 12))
  }

  private var modeBadge: some View {
    return Text("Real")
      .font(.system(size: 11, weight: .bold))
      .foregroundColor(.white)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(Color.white.opacity(0.15))
      .clipShape(Capsule())
  }

  private func label(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 11, weight: .semibold))
      .foregroundColor(.white.opacity(0.45))
  }

  private var deviceStatusText: String {
    let deviceID = viewModel.datSelectedDeviceIDText == "None" ? "none" : viewModel.datSelectedDeviceIDText
    return "\(viewModel.datSelectedDeviceLinkStateText) / \(viewModel.datSelectedDeviceCompatibilityText) / \(deviceID)"
  }

  private func statusLine(_ title: String, _ value: String, color: Color = .white.opacity(0.72)) -> some View {
    HStack(alignment: .top, spacing: 8) {
      label(title)
        .frame(width: 48, alignment: .leading)
      Text(value)
        .font(.system(size: 12))
        .foregroundColor(color)
        .lineLimit(3)
        .minimumScaleFactor(0.82)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

// MARK: - Enrollment Panel (reused from previous design)

private struct LastDetectedFacePanel: View {
  @ObservedObject var viewModel: StreamSessionViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .center, spacing: 12) {
        if let image = viewModel.lastEnrollmentCandidatePreview {
          Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
          RoundedRectangle(cornerRadius: 6)
            .fill(Color.white.opacity(0.08))
            .frame(width: 72, height: 72)
            .overlay(
              Text("No face")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.45))
            )
        }

        VStack(alignment: .leading, spacing: 4) {
          Text("Last detected face")
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
          Text(viewModel.lastEnrollmentCandidateSummary)
            .font(.system(size: 11))
            .foregroundColor(.white.opacity(0.70))
            .fixedSize(horizontal: false, vertical: true)
          Text(viewModel.faceEmbeddingModelStatusText)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(viewModel.faceEmbeddingModelStatusText.contains("missing") ? .orange : .green)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer()
      }

      Text("Faces are captured automatically while streaming. Stop the stream, then label a captured face group below.")
        .font(.system(size: 11))
        .foregroundColor(.white.opacity(0.62))
        .fixedSize(horizontal: false, vertical: true)

      if let group = viewModel.capturedFaceGroups.first {
        Divider().background(Color.white.opacity(0.2))
        HStack(spacing: 10) {
          if let thumbnail = group.bestThumbnailImage {
            Image(uiImage: thumbnail)
              .resizable()
              .scaledToFill()
              .frame(width: 54, height: 54)
              .clipShape(RoundedRectangle(cornerRadius: 6))
          }
          VStack(alignment: .leading, spacing: 3) {
            Text(group.isAlreadyRecognized ? "Recognized person" : "Review captured faces")
              .font(.system(size: 12, weight: .semibold))
              .foregroundColor(.white)
            if group.isAlreadyRecognized, let name = group.recognizedPersonName {
              Text("Identified as \(name) — no labeling needed.")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.70))
            } else {
              Text("\(viewModel.streamEndedReviewText) | first group samples \(group.sampleCount), embeddings \(group.embeddingCount), \(group.qualitySummary)")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.70))
            }
          }
          Spacer()
        }
        if !group.isAlreadyRecognized {
          TextField("Name for captured person", text: $viewModel.lastEnrollmentCandidateName)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 13))
          HStack(spacing: 8) {
            Button("Save Person") {
              viewModel.saveFirstCapturedFaceGroupWithName()
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.lastEnrollmentCandidateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || group.embeddingCount < 3)

            Button("Ignore") {
              viewModel.ignoreFirstCapturedFaceGroup()
            }
            .buttonStyle(.bordered)

            Button("Delete Name") {
              viewModel.deleteSavedPersonUsingNameField()
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.lastEnrollmentCandidateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
          .font(.system(size: 12, weight: .semibold))
          if group.embeddingCount < 3 {
            Text("Need 3+ embedded face pictures before saving.")
              .font(.system(size: 11, weight: .semibold))
              .foregroundColor(.orange.opacity(0.9))
          }
        } else {
          Button("Dismiss") {
            viewModel.ignoreFirstCapturedFaceGroup()
          }
          .buttonStyle(.bordered)
          .font(.system(size: 12, weight: .semibold))
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(Color.white.opacity(0.10))
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }
}

// MARK: - Voice Review

private struct WearerVoiceProfilePanel: View {
  @ObservedObject var viewModel: StreamSessionViewModel

  var body: some View {
    let profile = viewModel.wearerVoiceProfile
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("My voice")
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
          Text(profile.summaryText)
            .font(.system(size: 11))
            .foregroundColor(.white.opacity(0.70))
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer()
        Image(systemName: profile.isEnrolled ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.plus")
          .font(.system(size: 24))
          .foregroundColor(profile.isEnrolled ? .green : .white.opacity(0.55))
      }

      if profile.isRecording {
        VStack(alignment: .leading, spacing: 4) {
          Text("Prompt \(min(profile.promptIndex + 1, profile.promptCount)) of \(profile.promptCount)")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.white.opacity(0.55))
          Text(profile.promptText)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .fixedSize(horizontal: false, vertical: true)
          Text("Record 20 seconds total across the prompts. There is no per-phrase timer.")
            .font(.system(size: 10))
            .foregroundColor(.white.opacity(0.60))
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.28))
        .clipShape(RoundedRectangle(cornerRadius: 8))

        ProgressView(value: min(profile.recordingSeconds / SpeakerIdentityConfig.wearerVoiceMinEnrollmentSeconds, 1.0))
          .tint(profile.recordingSeconds >= SpeakerIdentityConfig.wearerVoiceMinEnrollmentSeconds ? .green : .orange)
        HStack(spacing: 8) {
          Button("Next Phrase") {
            viewModel.nextWearerVoicePrompt()
          }
          .buttonStyle(.bordered)
          .disabled(profile.completedPromptCount >= profile.promptCount)

          Button("Save My Voice") {
            viewModel.saveWearerVoiceEnrollment()
          }
          .buttonStyle(.borderedProminent)
          .disabled(!profile.canSaveRecording)

          Button("Cancel") {
            viewModel.cancelWearerVoiceEnrollment()
          }
          .buttonStyle(.bordered)
        }
        .font(.system(size: 12, weight: .semibold))
      } else {
        HStack(spacing: 8) {
          Button(profile.isEnrolled ? "Re-record" : "Record My Voice") {
            viewModel.startWearerVoiceEnrollment()
          }
          .buttonStyle(.borderedProminent)

          Button(viewModel.isPlayingVoicePreview ? "Stop Preview" : "Preview") {
            if viewModel.isPlayingVoicePreview {
              viewModel.stopVoicePreview()
            } else {
              viewModel.playWearerVoicePreview()
            }
          }
          .buttonStyle(.bordered)
          .disabled(!profile.isEnrolled)

          Button("Reset") {
            viewModel.resetWearerVoiceProfile()
          }
          .buttonStyle(.bordered)
          .disabled(!profile.isEnrolled)
        }
        .font(.system(size: 12, weight: .semibold))
      }

      Text(viewModel.wearerVoiceStatusText)
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(viewModel.wearerVoiceStatusText.contains("Saved") || viewModel.wearerVoiceStatusText.contains("ready") ? .green : .white.opacity(0.55))
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(Color.white.opacity(0.08))
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }
}

// MARK: - Settings Card

private struct SettingsCard: View {
  @ObservedObject var viewModel: StreamSessionViewModel

  var body: some View {
    VStack(spacing: 0) {
      toggleRow("Pause analysis", isOn: $viewModel.analysisPaused)
      Divider().background(Color.white.opacity(0.1))
      toggleRow("Identity recognition", isOn: $viewModel.identityRecognitionEnabled)
      Divider().background(Color.white.opacity(0.1))
      toggleRow("Conversation saving", isOn: $viewModel.conversationSavingEnabled)
      Divider().background(Color.white.opacity(0.1))
      cloudFaceEmbeddingRow
      Divider().background(Color.white.opacity(0.1))
      toggleRow("Live phone audio capture", isOn: $viewModel.livePhoneAudioCaptureEnabled)
      Divider().background(Color.white.opacity(0.1))
      audioSourceRow
      Divider().background(Color.white.opacity(0.1))
      HStack(spacing: 10) {
        clearButton("Clear Identity") { viewModel.clearLocalIdentityData() }
        clearButton("Clear Conversations") { viewModel.clearLocalConversationData() }
      }
      .padding(.vertical, 10)
      .padding(.horizontal, 14)
    }
    .background(Color.white.opacity(0.06))
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }

  private var cloudFaceEmbeddingRow: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Toggle("AWS AdaFace embeddings", isOn: $viewModel.cloudFaceEmbeddingEnabled)
          .font(.system(size: 13, weight: .medium))
          .foregroundColor(.white.opacity(0.82))
        Spacer()
        Button("Save") {
          viewModel.saveCloudFaceEmbeddingSettings()
        }
        .font(.system(size: 12, weight: .semibold))
      }

      TextField("GPU worker endpoint", text: $viewModel.cloudFaceEmbeddingEndpointText)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .font(.system(size: 12))
        .padding(8)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .foregroundColor(.white)

      SecureField("Worker API key", text: $viewModel.cloudFaceEmbeddingAPIKeyText)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .font(.system(size: 12))
        .padding(8)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .foregroundColor(.white)

      Text(viewModel.cloudFaceEmbeddingStatusText)
        .font(.system(size: 11))
        .foregroundColor(.white.opacity(0.55))
        .lineLimit(2)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  private var audioSourceRow: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("Audio source")
          .font(.system(size: 13, weight: .semibold))
          .foregroundColor(.white.opacity(0.82))
        Spacer()
        Picker("Audio source", selection: $viewModel.audioSource) {
          ForEach(AudioSource.allCases) { source in
            Text(source.displayName).tag(source)
          }
        }
        .pickerStyle(.menu)
        .tint(.white.opacity(0.9))
      }
      Text(viewModel.audioSource.detailText)
        .font(.system(size: 11))
        .foregroundColor(.white.opacity(0.55))
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
    Toggle(title, isOn: isOn)
      .font(.system(size: 13, weight: .medium))
      .foregroundColor(.white.opacity(0.82))
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
  }

  private func clearButton(_ title: String, action: @escaping () -> Void) -> some View {
    Button(title, action: action)
      .font(.system(size: 12, weight: .semibold))
      .foregroundColor(.white.opacity(0.6))
      .frame(maxWidth: .infinity)
      .padding(.vertical, 6)
      .background(Color.white.opacity(0.07))
      .clipShape(RoundedRectangle(cornerRadius: 6))
  }
}

// MARK: - Action Panel

private struct ActionPanel: View {
  @ObservedObject var viewModel: StreamSessionViewModel

  var body: some View {
    VStack(spacing: 10) {
      realGlassesButtons
    }
    .padding(.horizontal, 20)
    .padding(.bottom, 28)
    .padding(.top, 10)
    .background(Color.black)
  }

  private var realGlassesButtons: some View {
    VStack(spacing: 8) {
      CustomButton(
        title: viewModel.connectGlassesButtonTitle,
        style: .primary,
        isDisabled: !viewModel.canConnectRealGlasses
      ) {
        Task { await viewModel.connectRealGlasses() }
      }
      .accessibilityIdentifier("Connect my glasses")

      CustomButton(
        title: "Start streaming",
        style: .primary,
        isDisabled: !viewModel.canStartRealStream
      ) {
        Task { await viewModel.startRealGlassesStream() }
      }
      .accessibilityIdentifier("Start streaming")
    }
  }
}

// MARK: - Getting Started Sheet (unchanged)

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
          text: "Audio is recorded for post-session cloud transcription and speaker identification."
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
