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
// Main UI for streaming with real-time Vision and Speech output.
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
      if viewModel.shouldHidePhoneVideoFootage {
        PhoneVideoHiddenBackdrop(viewModel: viewModel)
      } else if let videoFrame = viewModel.currentVideoFrame, viewModel.hasReceivedFirstFrame {
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
        IdentityStatusPanel(viewModel: viewModel)
        EmbeddingDebugMetricsPanel(viewModel: viewModel)
        LiveTranscriptPanel(viewModel: viewModel)
        PipelineVerificationPanel(viewModel: viewModel)
        LatestStreamSummaryPanel(viewModel: viewModel)
        if !viewModel.phoneAssistanceDismissed {
          PhoneAssistancePanel(viewModel: viewModel)
        }
        WearerVoiceStreamPanel(viewModel: viewModel)
        VoiceSpeakerBadge(viewModel: viewModel)
        Spacer()
        ControlsView(viewModel: viewModel)
      }
      .padding(.all, 24)
    }
    .onDisappear {
      Task {
        if viewModel.streamingStatus != .stopped {
          await viewModel.stopSession(reason: "streamView.onDisappear")
        }
      }
    }
  }
}

private struct EmbeddingDebugMetricsPanel: View {
  @ObservedObject var viewModel: StreamSessionViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      metricSection(
        title: "Video face",
        icon: "video",
        tint: .cyan,
        lines: [
          viewModel.videoFaceEmbeddingMetricsText,
          viewModel.videoFaceRecognitionMetricsText
        ]
      )
      Divider()
        .overlay(Color.white.opacity(0.14))
      metricSection(
        title: "Audio speaker",
        icon: "waveform",
        tint: .green,
        lines: [
          viewModel.audioSpeakerEmbeddingMetricsText,
          viewModel.iPhoneVoiceSimilarityStatusText,
          viewModel.workerVoiceSimilarityStatusText
        ]
      )
    }
    .padding(9)
    .frame(maxWidth: .infinity, alignment: .leading)
    .mementoPanel(cornerRadius: 8)
    .accessibilityIdentifier("embedding_debug_metrics_panel")
  }

  private func metricSection(title: String, icon: String, tint: Color, lines: [String]) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 6) {
        Image(systemName: icon)
          .font(.system(size: 10, weight: .semibold))
          .foregroundColor(tint)
          .frame(width: 14)
        Text(title)
          .font(.system(size: 10, weight: .bold))
          .foregroundColor(.white)
        Spacer()
      }
      ForEach(lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }, id: \.self) { line in
        Text(line)
          .font(.system(size: 9, weight: .semibold))
          .foregroundColor(.white.opacity(0.76))
          .lineLimit(2)
          .minimumScaleFactor(0.78)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

private struct PipelineVerificationPanel: View {
  @ObservedObject var viewModel: StreamSessionViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 8) {
        Image(systemName: "checklist")
          .font(.system(size: 11, weight: .semibold))
          .foregroundColor(MementoTheme.primary)
        Text("Pipeline checks")
          .font(.system(size: 11, weight: .bold))
          .foregroundColor(.white)
        Spacer()
      }

      verificationRow(
        icon: "person.crop.circle.badge.checkmark",
        text: viewModel.presencePipelineVerificationText,
        accessibilityIdentifier: "presence_verification_text"
      )
      verificationRow(
        icon: "location.viewfinder",
        text: viewModel.sceneContextPipelineVerificationText,
        accessibilityIdentifier: "scene_context_verification_text"
      )
      verificationRow(
        icon: "brain.head.profile",
        text: viewModel.memoryTriggerVerificationText,
        accessibilityIdentifier: "memory_trigger_verification_text"
      )
    }
    .padding(9)
    .frame(maxWidth: .infinity, alignment: .leading)
    .mementoPanel(cornerRadius: 8)
    .accessibilityIdentifier("pipeline_verification_panel")
  }

  private func verificationRow(
    icon: String,
    text: String,
    accessibilityIdentifier: String
  ) -> some View {
    HStack(alignment: .top, spacing: 6) {
      Image(systemName: icon)
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(rowColor(for: text))
        .frame(width: 14)
      Text(text)
        .font(.system(size: 9, weight: .semibold))
        .foregroundColor(.white.opacity(0.76))
        .lineLimit(2)
        .minimumScaleFactor(0.82)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
  }

  private func rowColor(for text: String) -> Color {
    let lowered = text.lowercased()
    if lowered.contains("failed") || lowered.contains("no saved memory matched") {
      return MementoTheme.warning
    }
    if lowered.contains("saved") || lowered.contains("displayed") || lowered.contains("active=") {
      return MementoTheme.success
    }
    if lowered.contains("detected") || lowered.contains("asking") {
      return MementoTheme.warning
    }
    return MementoTheme.primary
  }
}

private struct PhoneVideoHiddenBackdrop: View {
  @ObservedObject var viewModel: StreamSessionViewModel

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: "eyeglasses")
        .font(.system(size: 32, weight: .semibold))
        .foregroundColor(.white.opacity(0.82))
      Text(viewModel.streamRunningHeaderText)
        .font(.system(size: 18, weight: .bold))
        .foregroundColor(.white)
      Text(viewModel.streamRunningModeLineText)
        .font(.system(size: 12, weight: .semibold))
        .foregroundColor(.white.opacity(0.72))
      Text(viewModel.streamRunningRecognizedPeopleLineText)
        .font(.system(size: 12, weight: .semibold))
        .foregroundColor(.white.opacity(0.72))
    }
    .padding(18)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.black)
    .accessibilityIdentifier("phone_video_hidden_backdrop")
  }

}

private struct LiveTranscriptPanel: View {
  @ObservedObject var viewModel: StreamSessionViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 8) {
        Image(systemName: "text.bubble")
          .font(.system(size: 12, weight: .semibold))
          .foregroundColor(statusColor)
        Text("Live transcript")
          .font(.system(size: 12, weight: .bold))
          .foregroundColor(.white)
        Spacer()
        Text(viewModel.liveTranscriptionStatusText)
          .font(.system(size: 9, weight: .semibold))
          .foregroundColor(statusColor)
          .lineLimit(1)
          .minimumScaleFactor(0.75)
      }

      Text(viewModel.liveTranscriptPreviewText)
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(.white.opacity(0.82))
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .mementoPanel(cornerRadius: 8)
  }

  private var statusColor: Color {
    let status = viewModel.liveTranscriptionStatusText.lowercased()
    if !viewModel.liveTranscriptionEnabled || status.contains("disabled") { return .white.opacity(0.55) }
    if status.contains("failed") || status.contains("missing") { return MementoTheme.warning }
    if status.contains("saved") || status.contains("listening") || status.contains("transcribing") { return MementoTheme.success }
    return MementoTheme.primary
  }
}

struct LatestStreamSummaryPanel: View {
  @ObservedObject var viewModel: StreamSessionViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Image(systemName: "sparkles.rectangle.stack")
          .font(.system(size: 11, weight: .semibold))
          .foregroundColor(statusColor)
        Text("Latest stream")
          .font(.system(size: 11, weight: .bold))
          .foregroundColor(.white)
        Spacer()
        Text(viewModel.latestStreamSummaryTimeText)
          .font(.system(size: 9, weight: .semibold))
          .foregroundColor(.white.opacity(0.58))
          .lineLimit(1)
          .minimumScaleFactor(0.8)
      }

      Text(viewModel.latestStreamSummaryText)
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(.white.opacity(0.80))
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)

      Text(viewModel.latestStreamSummaryStatusText)
        .font(.system(size: 9, weight: .semibold))
        .foregroundColor(.white.opacity(0.58))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
    .padding(9)
    .frame(maxWidth: .infinity, alignment: .leading)
    .mementoPanel(cornerRadius: 8)
    .accessibilityIdentifier("latest_stream_summary_panel")
  }

  private var statusColor: Color {
    let status = viewModel.latestStreamSummaryStatusText.lowercased()
    if status.contains("ready") { return MementoTheme.success }
    if status.contains("failed") || status.contains("missing") { return MementoTheme.warning }
    if status.contains("summarizing") { return MementoTheme.warning }
    return MementoTheme.primary
  }
}

private struct PhoneAssistancePanel: View {
  @ObservedObject var viewModel: StreamSessionViewModel
  @State private var isExpanded = false

  private var hasMoreDetail: Bool {
    viewModel.phoneAssistanceDetailText.count > 140
      || viewModel.phoneAssistanceDetailText.contains("\n")
  }

  private var isIdentityFeedbackPrompt: Bool {
    let title = viewModel.phoneAssistanceTitleText.trimmingCharacters(in: .whitespacesAndNewlines)
    let status = viewModel.phoneAssistanceStatusText.lowercased()
    return title.hasPrefix("Is this ")
      || title == "Choose the correct person"
      || status.contains("identity")
  }

  private var thumbnailSize: CGFloat {
    guard viewModel.phoneAssistanceThumbnail != nil else { return 34 }
    return isIdentityFeedbackPrompt ? 96 : 34
  }

  private var thumbnailCornerRadius: CGFloat {
    isIdentityFeedbackPrompt ? 8 : 6
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .top, spacing: 8) {
        if let thumbnail = viewModel.phoneAssistanceThumbnail {
          Image(uiImage: thumbnail)
            .resizable()
            .scaledToFill()
            .frame(width: thumbnailSize, height: thumbnailSize)
            .clipShape(RoundedRectangle(cornerRadius: thumbnailCornerRadius))
            .overlay(
              RoundedRectangle(cornerRadius: thumbnailCornerRadius)
                .stroke(Color.white.opacity(0.22), lineWidth: 1)
            )
        } else {
          Image(systemName: viewModel.glassesDisplayConnected ? "eyeglasses" : "iphone")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(viewModel.glassesDisplayConnected ? MementoTheme.success : MementoTheme.primary)
            .frame(width: 34, height: 34)
            .background(Color.white.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        Text(viewModel.phoneAssistanceTitleText)
          .font(.system(size: 14, weight: .bold))
          .foregroundColor(.white)
          .lineLimit(2)
          .minimumScaleFactor(0.78)
          .fixedSize(horizontal: false, vertical: true)
          .layoutPriority(1)
        Spacer()
        Button {
          viewModel.dismissPhoneAssistance()
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.white.opacity(0.82))
            .frame(width: 24, height: 24)
            .background(Color.white.opacity(0.14))
            .clipShape(Circle())
        }
        .accessibilityIdentifier("dismiss_phone_assistance_button")
      }

      ScrollView {
        Text(viewModel.phoneAssistanceDetailText)
          .font(.system(size: 11, weight: .semibold))
          .foregroundColor(.white.opacity(0.82))
          .lineLimit(isExpanded ? nil : 3)
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxHeight: isExpanded ? 170 : 56)

      if hasMoreDetail {
        Button {
          isExpanded.toggle()
        } label: {
          Text(isExpanded ? "Show less" : "See more")
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(MementoTheme.primary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("phone_assistance_see_more_button")
      }

      Text(viewModel.glassesDisplayStatusText == "Display idle" ? viewModel.phoneAssistanceStatusText : viewModel.glassesDisplayStatusText)
        .font(.system(size: 9, weight: .semibold))
        .foregroundColor(.white.opacity(0.58))
        .lineLimit(2)
        .minimumScaleFactor(0.85)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .mementoPanel(cornerRadius: 8)
  }
}

private struct WearerVoiceStreamPanel: View {
  @ObservedObject var viewModel: StreamSessionViewModel

  var body: some View {
    let profile = viewModel.wearerVoiceProfile
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text("My voice")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
          Text(profile.summaryText)
            .font(.system(size: 10))
            .foregroundColor(.white.opacity(0.72))
            .lineLimit(2)
        }
        Spacer()
        if profile.isRecording {
          Button("Next") {
            viewModel.nextWearerVoicePrompt()
          }
          .buttonStyle(.bordered)
          .disabled(profile.completedPromptCount >= profile.promptCount)

          Button("Save") {
            viewModel.saveWearerVoiceEnrollment()
          }
          .buttonStyle(.borderedProminent)
          .disabled(!profile.canSaveRecording)

          Button("Cancel") {
            viewModel.cancelWearerVoiceEnrollment()
          }
          .buttonStyle(.bordered)
        } else {
          Button(profile.isEnrolled ? "Re-record" : "Record") {
            viewModel.startWearerVoiceEnrollment()
          }
          .buttonStyle(.borderedProminent)
        }
      }

      if profile.isRecording {
        VStack(alignment: .leading, spacing: 3) {
          Text("Prompt \(min(profile.promptIndex + 1, profile.promptCount)) of \(profile.promptCount)")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.white.opacity(0.55))
          Text(profile.promptText)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
            .lineLimit(3)
          Text("20 seconds total across prompts. No per-phrase timer.")
            .font(.system(size: 9))
            .foregroundColor(.white.opacity(0.60))
            .lineLimit(2)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MementoTheme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 6))

        ProgressView(value: min(profile.recordingSeconds / SpeakerIdentityConfig.wearerVoiceMinEnrollmentSeconds, 1.0))
          .tint(profile.recordingSeconds >= SpeakerIdentityConfig.wearerVoiceMinEnrollmentSeconds ? MementoTheme.success : MementoTheme.warning)
      }

      Text(viewModel.wearerVoiceStatusText)
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(viewModel.wearerVoiceStatusText.contains("Saved") || viewModel.wearerVoiceStatusText.contains("ready") ? MementoTheme.success : .white.opacity(0.68))
        .lineLimit(2)
    }
    .font(.system(size: 12, weight: .semibold))
    .padding(10)
    .mementoPanel(cornerRadius: 8)
  }
}

// Extracted controls for clarity
struct ControlsView: View {
  @ObservedObject var viewModel: StreamSessionViewModel
  @State private var isScreenDimmed = false

  var body: some View {
    VStack(spacing: 10) {
      CustomButton(
        title: "Stop streaming",
        style: .destructive,
        isDisabled: viewModel.lifecycleState == .stopping || viewModel.streamingStatus == .stopped
      ) {
        Task {
          if isScreenDimmed { toggleDim() }
          await viewModel.stopSession(reason: "stopButton")
        }
      }
      .accessibilityIdentifier("Stop streaming")

      HStack(spacing: 12) {
        CircleButton(icon: "person.2", text: "People") {
          viewModel.openPeopleDictionary()
        }
        CircleButton(icon: "sparkles.rectangle.stack", text: "Summary") {
          viewModel.openStreamSummaryHistory()
        }
        CircleButton(icon: "rectangle.on.rectangle", text: "Display") {
          viewModel.activateGlassesDisplayControl()
        }
        CircleButton(icon: isScreenDimmed ? "sun.max.fill" : "moon.fill", text: isScreenDimmed ? "Brighten" : "Dim") {
          toggleDim()
        }
      }
    }
  }

  private func toggleDim() {
    isScreenDimmed.toggle()
    UIScreen.main.brightness = isScreenDimmed ? 0.01 : 0.5
  }
}

private struct IdentityStatusPanel: View {
  @ObservedObject var viewModel: StreamSessionViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .center, spacing: 10) {
        VStack(alignment: .leading, spacing: 3) {
          Text(viewModel.streamRunningHeaderText)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .accessibilityIdentifier("stream_running_header")
          Text(viewModel.streamRunningModeLineText)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white.opacity(0.82))
            .lineLimit(1)
            .accessibilityIdentifier("stream_running_mode")
          Text(viewModel.streamRunningRecognizedPeopleLineText)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white.opacity(0.82))
            .lineLimit(2)
            .accessibilityIdentifier("stream_running_recognized_people")
        }
        Spacer()
      }
    }
    .padding(10)
    .mementoPanel(cornerRadius: 8)
    .accessibilityIdentifier("stream_running_status_panel")
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
          .background(MementoTheme.panelRaised)
          .clipShape(RoundedRectangle(cornerRadius: 4))
      }

      Text(viewModel.faceEmbeddingModelStatusText.contains("missing") ? "Detection only" : "Recognition ready")
        .font(.system(size: 12, weight: .semibold))
        .foregroundColor(viewModel.faceEmbeddingModelStatusText.contains("missing") ? .orange : .green)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
    .mementoPanel(cornerRadius: 8)
  }

  private var statusColor: Color {
    switch viewModel.lifecycleState {
    case .running:
      return MementoTheme.success
    case .paused, .waiting, .starting:
      return MementoTheme.warning
    case .error:
      return .red
    case .stopping, .stopped:
      return .gray
    }
  }
}

private struct VoiceSpeakerBadge: View {
  @ObservedObject var viewModel: StreamSessionViewModel

  private var state: String { viewModel.activeSpeakerStateText }
  private var isActive: Bool { state != "none" && state != "idle" }

  var body: some View {
    if isActive {
      HStack(spacing: 8) {
        Image(systemName: "waveform")
          .font(.system(size: 13, weight: .semibold))
          .foregroundColor(badgeColor)
          .symbolEffect(.variableColor.iterative, isActive: state == "confirmed" || state == "speaking")
        VStack(alignment: .leading, spacing: 1) {
          Text(speakerLabel)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(badgeColor)
          if state == "confirmed" || state == "possible" {
            Text(String(format: "%.0f%% match", Double(viewModel.activeSpeakerSimilarity * 100)))
              .font(.system(size: 10))
              .foregroundColor(.white.opacity(0.7))
          }
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 7)
      .mementoPanel(cornerRadius: 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .transition(.opacity.combined(with: .move(edge: .top)))
    }
  }

  private var speakerLabel: String {
    switch state {
    case "confirmed":
      return "Speaking: \(viewModel.activeSpeakerName.isEmpty ? "Unknown" : viewModel.activeSpeakerName)"
    case "possible":
      return "Possibly: \(viewModel.activeSpeakerName.isEmpty ? "Unknown" : viewModel.activeSpeakerName)"
    case "ambiguous":
      return "Voice: ambiguous"
    case "speaking":
      return "Voice: speaking..."
    default:
      return "Voice: \(state)"
    }
  }

  private var badgeColor: Color {
    switch state {
    case "confirmed": return MementoTheme.success
    case "possible": return MementoTheme.warning
    case "speaking": return MementoTheme.primary
    default: return .mementoCoral
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
            .mementoPanel(cornerRadius: 8)
          }
        }
        .padding(.vertical, 8)
      }
    }
  }
}
