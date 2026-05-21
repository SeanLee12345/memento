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
        IdentityStatusPanel(viewModel: viewModel)
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

private struct PhoneAssistancePanel: View {
  @ObservedObject var viewModel: StreamSessionViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: "iphone")
          .font(.system(size: 12, weight: .semibold))
          .foregroundColor(.cyan)
          .padding(.top, 2)
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
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxHeight: 170)

      Text(viewModel.phoneAssistanceStatusText)
        .font(.system(size: 9, weight: .semibold))
        .foregroundColor(.white.opacity(0.58))
        .lineLimit(2)
        .minimumScaleFactor(0.85)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.black.opacity(0.62))
    .clipShape(RoundedRectangle(cornerRadius: 8))
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
        .background(Color.black.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 6))

        ProgressView(value: min(profile.recordingSeconds / SpeakerIdentityConfig.wearerVoiceMinEnrollmentSeconds, 1.0))
          .tint(profile.recordingSeconds >= SpeakerIdentityConfig.wearerVoiceMinEnrollmentSeconds ? .green : .orange)
      }

      Text(viewModel.wearerVoiceStatusText)
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(viewModel.wearerVoiceStatusText.contains("Saved") || viewModel.wearerVoiceStatusText.contains("ready") ? .green : .white.opacity(0.68))
        .lineLimit(2)
    }
    .font(.system(size: 12, weight: .semibold))
    .padding(10)
    .background(Color.black.opacity(0.55))
    .clipShape(RoundedRectangle(cornerRadius: 8))
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

  private var recognitionLine: String {
    let state = viewModel.activeIdentityStateText
    let totalFaces = viewModel.detectedFaceCount
    let isKnown = (state == "confirmed" || state == "possible")
    let knownName = isKnown ? viewModel.activeIdentityName : nil
    let unknownCount = isKnown ? max(0, totalFaces - 1) : totalFaces

    if totalFaces == 0 {
      return "No face detected"
    }
    switch (knownName, unknownCount) {
    case (let name?, 0):
      return "\(name) recognized"
    case (let name?, 1):
      return "\(name) and 1 unknown face"
    case (let name?, let u) where u > 1:
      return "\(name) and \(u) unknown faces"
    case (nil, 1):
      return "1 unknown face"
    case (nil, let u):
      return "\(u) unknown faces"
    default:
      return "No face detected"
    }
  }

  // Color bands: green ≥ 0.75 (strong), yellow ≥ 0.65 (ambiguous), orange below.
  private func similarityColor(_ sim: Float) -> Color {
    if sim >= 0.75 { return .green }
    if sim >= 0.65 { return .yellow }
    return .orange
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .center, spacing: 10) {
        VStack(alignment: .leading, spacing: 3) {
          Text(recognitionLine)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
          Text("\(viewModel.activeIdentityStateText) | \(viewModel.activeIdentityConfidenceText)")
            .font(.system(size: 11))
            .foregroundColor(.white.opacity(0.78))
          if viewModel.faceEmbeddingModelStatusText.contains("missing") {
            Text("Recognition model missing")
              .font(.system(size: 10, weight: .semibold))
              .foregroundColor(.orange)
              .lineLimit(1)
          }
          if !viewModel.faceAlignmentWarning.isEmpty {
            Text(viewModel.faceAlignmentWarning)
              .font(.system(size: 10, weight: .semibold))
              .foregroundColor(.yellow)
              .lineLimit(2)
          }
          voiceStatusRow
        }
        Spacer()
      }

      Text("Faces are captured automatically. Stop streaming to label captured people.")
        .font(.system(size: 11))
        .foregroundColor(.white.opacity(0.72))
    }
    .padding(10)
    .background(Color.black.opacity(0.55))
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  @ViewBuilder
  private var voiceStatusRow: some View {
    let bufSec = viewModel.voiceSpeechBufferSeconds
    let sim = viewModel.lastVoiceSimilarity
    let name = viewModel.activeSpeakerName
    let status = viewModel.voiceMatchStatusText

    if bufSec >= SpeakerIdentityConfig.minSpeechSecondsForEmbedding {
      if viewModel.lastWearerVoiceSimilarity > 0
        || viewModel.lastIPhoneVoiceSimilarity > 0
        || viewModel.lastWorkerVoiceSimilarity > 0 {
        VStack(alignment: .leading, spacing: 2) {
          if viewModel.lastWearerVoiceSimilarity > 0 {
            Text(viewModel.wearerVoiceSimilarityStatusText)
              .font(.system(size: 10, weight: .semibold))
              .foregroundColor(similarityColor(viewModel.lastWearerVoiceSimilarity))
              .lineLimit(1)
          }
          Text(viewModel.iPhoneVoiceSimilarityStatusText)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(similarityColor(viewModel.lastIPhoneVoiceSimilarity))
            .lineLimit(1)
          Text(viewModel.workerVoiceSimilarityStatusText)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(similarityColor(viewModel.lastWorkerVoiceSimilarity))
            .lineLimit(1)
        }
      } else if sim > 0 {
        // Similarity from the last embedding — green/yellow/orange by threshold.
        let suffix = name.isEmpty ? "" : " · \(name)"
        Text("Voice sim: \(String(format: "%.3f", sim))\(suffix)")
          .font(.system(size: 10, weight: .semibold))
          .foregroundColor(similarityColor(sim))
          .lineLimit(1)
      } else if viewModel.iPhoneVoiceSimilarityStatusText != "iPhone: pending"
        || viewModel.workerVoiceSimilarityStatusText != "Worker PC: pending" {
        VStack(alignment: .leading, spacing: 2) {
          Text(viewModel.iPhoneVoiceSimilarityStatusText)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.orange)
            .lineLimit(1)
          Text(viewModel.workerVoiceSimilarityStatusText)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.orange)
            .lineLimit(1)
        }
      } else if !status.isEmpty {
        Text(status)
          .font(.system(size: 10, weight: .semibold))
          .foregroundColor(.orange)
          .lineLimit(1)
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

      Text(viewModel.faceEmbeddingModelStatusText.contains("missing") ? "Detection only" : "Recognition ready")
        .font(.system(size: 12, weight: .semibold))
        .foregroundColor(viewModel.faceEmbeddingModelStatusText.contains("missing") ? .orange : .green)
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
            Text(String(format: "%.0f%% match", viewModel.activeSpeakerSimilarity * 100))
              .font(.system(size: 10))
              .foregroundColor(.white.opacity(0.7))
          }
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 7)
      .background(Color.black.opacity(0.55))
      .clipShape(RoundedRectangle(cornerRadius: 8))
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
    case "confirmed": return .green
    case "possible": return .yellow
    case "speaking": return .cyan
    default: return .orange
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
