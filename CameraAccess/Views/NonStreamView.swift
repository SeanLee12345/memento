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

      VStack {
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

        VStack(alignment: .leading, spacing: 8) {
          Text("Audio \(viewModel.microphoneStatusText)")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white.opacity(0.82))
          Text(viewModel.speechAuthorizationStatusText)
            .font(.system(size: 12))
            .foregroundColor(.white.opacity(0.72))
          Text("Transcript: \(viewModel.partialTranscript)")
            .font(.system(size: 12))
            .foregroundColor(.white.opacity(0.72))
            .lineLimit(2)
          if !viewModel.transcriptEntries.isEmpty {
            Text("Final: \(viewModel.transcriptEntries.map(\.text).joined(separator: " "))")
              .font(.system(size: 12))
              .foregroundColor(.white.opacity(0.72))
              .lineLimit(2)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.top, 16)

        Spacer()

        VStack(spacing: 12) {
          Image(.cameraAccessIcon)
            .resizable()
            .renderingMode(.template)
            .foregroundColor(.white)
            .aspectRatio(contentMode: .fit)
            .frame(width: 120)

          Text("Simulated Camera Stream")
            .font(.system(size: 20, weight: .semibold))
            .foregroundColor(.white)

          Text("Tap Start Simulation to play the compressed local video as a live camera feed and transcribe its audio.")
            .font(.system(size: 15))
            .multilineTextAlignment(.center)
            .foregroundColor(.white)
        }
        .padding(.horizontal, 12)

        Spacer()

        CustomButton(
          title: "Start Simulation",
          style: .primary,
          isDisabled: false
        ) {
          Task {
            await viewModel.startSimulation()
          }
        }
        .accessibilityIdentifier("Start Simulation")
      }
      .padding(.all, 24)
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
        TipItemView(resource: .videoIcon, text: "Play the bundled compressed video as a live camera feed.")
        TipItemView(
          resource: .tapIcon,
          text: "Vision processes each delivered sample buffer with one frame in flight."
        )
        TipItemView(
          resource: .smartGlassesIcon,
          text: "Speech transcription uses the same compressed file audio through AVAudioEngine."
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
