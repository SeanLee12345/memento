import AVFoundation
import SwiftUI

struct PeopleDictionaryView: View {
  @ObservedObject var viewModel: StreamSessionViewModel
  @State private var selectedEntry: PersonDictionaryEntry?
  @State private var enrollingSpeaker: UnknownDiarizationSpeaker?
  @State private var pendingSpeakerPrompts: [UnknownDiarizationSpeaker] = []
  @State private var promptedSpeakerKeys: Set<String> = []

  var body: some View {
    NavigationStack {
      Group {
        if viewModel.peopleDictionaryEntries.isEmpty && viewModel.unknownDiarizationSpeakers.isEmpty {
          emptyState
        } else {
          List {
            // Cloud diarization status banner
            if viewModel.cloudDiarizationState != .idle && viewModel.cloudDiarizationState != .done {
              Section {
                HStack(spacing: 10) {
                  ProgressView()
                  Text(viewModel.cloudDiarizationState.statusText)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
              }
              .listRowBackground(Color(.secondarySystemGroupedBackground))
            }

            // Unidentified speakers from last session
            if !viewModel.unknownDiarizationSpeakers.isEmpty {
              Section("Unidentified Speakers") {
                ForEach(viewModel.unknownDiarizationSpeakers) { speaker in
                  UnknownSpeakerRowView(speaker: speaker, onEnroll: {
                    enrollingSpeaker = speaker
                  })
                  .listRowBackground(Color(.secondarySystemGroupedBackground))
                }
              }
            }

            // Enrolled people
            ForEach(viewModel.peopleDictionaryEntries) { entry in
              PersonRowView(entry: entry, viewModel: viewModel)
                .contentShape(Rectangle())
                .onTapGesture { selectedEntry = entry }
                .listRowBackground(Color(.secondarySystemGroupedBackground))
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                  Button(role: .destructive) {
                    viewModel.deletePerson(id: entry.id)
                  } label: {
                    Label("Delete", systemImage: "trash")
                  }
                }
            }
          }
          .listStyle(.insetGrouped)
        }
      }
      .navigationTitle("People")
      .navigationBarTitleDisplayMode(.large)
      .toolbar {
        ToolbarItem(placement: .navigationBarTrailing) {
          Button("Done") { viewModel.showPeopleDictionary = false }
        }
      }
      .navigationDestination(item: $selectedEntry) { entry in
        PersonDetailView(entry: entry, viewModel: viewModel)
      }
      .sheet(item: $enrollingSpeaker) { speaker in
        UnknownSpeakerEnrollSheet(speaker: speaker, viewModel: viewModel) {
          finishCurrentSpeakerPrompt()
        }
      }
      .onAppear {
        enqueueSpeakerPrompts(from: viewModel.unknownDiarizationSpeakers)
      }
      .onChange(of: viewModel.unknownDiarizationSpeakers) { speakers in
        enqueueSpeakerPrompts(from: speakers)
      }
    }
  }

  private func speakerPromptKey(_ speaker: UnknownDiarizationSpeaker) -> String {
    "\(speaker.conversationSessionId.uuidString)-\(speaker.speakerIndex)"
  }

  private func enqueueSpeakerPrompts(from speakers: [UnknownDiarizationSpeaker]) {
    var seenClipData: Set<Data> = []
    let promptableSpeakers = speakers
      .sorted { $0.speakerIndex < $1.speakerIndex }
      .filter { speaker in
        guard let clipData = speaker.clipData, !clipData.isEmpty else { return false }
        return seenClipData.insert(clipData).inserted
      }

    for speaker in promptableSpeakers {
      let key = speakerPromptKey(speaker)
      guard !promptedSpeakerKeys.contains(key),
            !pendingSpeakerPrompts.contains(where: { speakerPromptKey($0) == key }),
            enrollingSpeaker.map(speakerPromptKey) != key else {
        continue
      }
      pendingSpeakerPrompts.append(speaker)
    }
    presentNextSpeakerPromptIfNeeded()
  }

  private func presentNextSpeakerPromptIfNeeded() {
    guard enrollingSpeaker == nil, !pendingSpeakerPrompts.isEmpty else { return }
    let next = pendingSpeakerPrompts.removeFirst()
    promptedSpeakerKeys.insert(speakerPromptKey(next))
    enrollingSpeaker = next
  }

  private func finishCurrentSpeakerPrompt() {
    enrollingSpeaker = nil
    DispatchQueue.main.async {
      presentNextSpeakerPromptIfNeeded()
    }
  }

  private var emptyState: some View {
    VStack(spacing: 16) {
      Image(systemName: "person.2.slash")
        .font(.system(size: 48))
        .foregroundColor(.secondary)
      Text("No people enrolled yet")
        .font(.headline)
        .foregroundColor(.primary)
      Text("Stream video with your glasses to capture and label faces.")
        .font(.subheadline)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct PersonRowView: View {
  let entry: PersonDictionaryEntry
  @ObservedObject var viewModel: StreamSessionViewModel

  private var isActiveSpeaker: Bool {
    viewModel.activeSpeakerPersonId == entry.id
      && viewModel.activeSpeakerStateText != "none"
  }

  private var hasVoiceEnrollment: Bool {
    viewModel.enrolledVoicePersonIds.contains(entry.id)
  }

  var body: some View {
    HStack(spacing: 14) {
      thumbnailView
        .frame(width: 56, height: 56)
        .clipShape(Circle())
        .overlay(alignment: .bottomTrailing) {
          if hasVoiceEnrollment {
            Image(systemName: "waveform.circle.fill")
              .font(.system(size: 16))
              .foregroundColor(.blue)
              .background(Color(.secondarySystemGroupedBackground).clipShape(Circle()))
          }
        }

      VStack(alignment: .leading, spacing: 4) {
        Text(entry.displayName)
          .font(.system(size: 16, weight: .semibold))
          .foregroundColor(.primary)
        if !entry.embeddingImages.isEmpty {
          embeddingImageStrip
        }
        Text(statusLine)
          .font(.system(size: 13))
          .foregroundColor(.secondary)
        if !entry.transcripts.isEmpty {
          Text("\(entry.transcripts.count) transcript \(entry.transcripts.count == 1 ? "entry" : "entries")")
            .font(.system(size: 12))
            .foregroundColor(.secondary)
        }
      }

      Spacer()

      if isActiveSpeaker {
        speakerBadge
      }

      Image(systemName: "chevron.right")
        .font(.system(size: 13, weight: .semibold))
        .foregroundColor(Color(.tertiaryLabel))
    }
    .padding(.vertical, 6)
  }

  private var speakerBadge: some View {
    VStack(spacing: 2) {
      Image(systemName: "waveform")
        .font(.system(size: 14, weight: .semibold))
        .foregroundColor(.blue)
      Text(String(format: "%.0f%%", viewModel.activeSpeakerSimilarity * 100))
        .font(.system(size: 10, weight: .medium))
        .foregroundColor(.blue)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(Color.blue.opacity(0.12))
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  private var thumbnailView: some View {
    Group {
      if let image = entry.thumbnail {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
      } else {
        Circle()
          .fill(Color(.systemGray5))
          .overlay(
            Text(entry.displayName.prefix(1).uppercased())
              .font(.system(size: 22, weight: .semibold))
              .foregroundColor(.secondary)
          )
      }
    }
  }

  private var embeddingImageStrip: some View {
    HStack(spacing: 4) {
      ForEach(0..<min(entry.embeddingImages.count, 5), id: \.self) { index in
        Image(uiImage: entry.embeddingImages[index])
          .resizable()
          .scaledToFill()
          .frame(width: 26, height: 26)
          .clipShape(RoundedRectangle(cornerRadius: 5))
      }
      if entry.embeddingImages.count > 5 {
        Text("+\(entry.embeddingImages.count - 5)")
          .font(.system(size: 10, weight: .semibold))
          .foregroundColor(.secondary)
          .frame(width: 26, height: 26)
          .background(Color(.tertiarySystemGroupedBackground))
          .clipShape(RoundedRectangle(cornerRadius: 5))
      }
    }
  }

  private var statusLine: String {
    var parts: [String] = []
    parts.append(entry.profile.enrollmentStatus.rawValue.capitalized)
    if let lastSeen = entry.lastSeen {
      parts.append("Last seen \(RelativeDateTimeFormatter().localizedString(for: lastSeen, relativeTo: Date()))")
    }
    return parts.joined(separator: " · ")
  }
}

// MARK: - Unknown speaker row

private struct UnknownSpeakerRowView: View {
  let speaker: UnknownDiarizationSpeaker
  let onEnroll: () -> Void

  var body: some View {
    HStack(spacing: 14) {
      Circle()
        .fill(Color(.systemGray4))
        .frame(width: 56, height: 56)
        .overlay(
          Image(systemName: "person.fill.questionmark")
            .font(.system(size: 22))
            .foregroundColor(.secondary)
        )
      VStack(alignment: .leading, spacing: 4) {
        Text(speaker.id)
          .font(.system(size: 16, weight: .semibold))
        Text(String(format: "%.0f s spoken · %d segment%@",
                    speaker.totalSeconds, speaker.segmentCount,
                    speaker.segmentCount == 1 ? "" : "s"))
          .font(.system(size: 13))
          .foregroundColor(.secondary)
        Text("Tap to identify & enroll")
          .font(.system(size: 12))
          .foregroundColor(.blue)
      }
      Spacer()
      Button(action: onEnroll) {
        Label("Identify", systemImage: "person.badge.plus")
          .font(.system(size: 13, weight: .medium))
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.small)
    }
    .padding(.vertical, 6)
  }
}

// MARK: - Unknown speaker enrollment sheet

private struct UnknownSpeakerEnrollSheet: View {
  let speaker: UnknownDiarizationSpeaker
  @ObservedObject var viewModel: StreamSessionViewModel
  let onDismiss: () -> Void

  @State private var name = ""
  @State private var isPlayingClip = false
  @State private var audioPlayer: AVAudioPlayer?
  @State private var existingPerson: PersonDictionaryEntry?

  var body: some View {
    NavigationStack {
      Form {
        // Clip playback
        if speaker.clipData != nil {
          Section("Voice Preview") {
            Button(action: toggleClipPlayback) {
              Label(isPlayingClip ? "Stop" : "Play \(speaker.id) Voice Clip",
                    systemImage: isPlayingClip ? "stop.circle" : "play.circle")
            }
          }
        }

        // Assign to existing person or create new
        Section("Assign to") {
          if !viewModel.peopleDictionaryEntries.isEmpty {
            ForEach(viewModel.peopleDictionaryEntries) { entry in
              Button {
                name = entry.displayName
                existingPerson = entry
              } label: {
                HStack {
                  Text(entry.displayName)
                    .foregroundColor(.primary)
                  Spacer()
                  if existingPerson?.id == entry.id {
                    Image(systemName: "checkmark").foregroundColor(.blue)
                  }
                }
              }
            }
          }
          TextField("Or enter a new name…", text: $name)
            .onChange(of: name) { _ in existingPerson = nil }
        }

        Section {
          Button("Save & Enroll") {
            enrollSpeaker()
          }
          .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
          .frame(maxWidth: .infinity)
        }
      }
      .navigationTitle("Who is \(speaker.id)?")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Skip") { onDismiss() }
        }
      }
    }
    .onDisappear { audioPlayer?.stop() }
  }

  private func toggleClipPlayback() {
    if isPlayingClip {
      audioPlayer?.stop()
      isPlayingClip = false
    } else if let data = speaker.clipData,
              let player = try? AVAudioPlayer(data: data) {
      audioPlayer = player
      player.play()
      isPlayingClip = true
      player.delegate = nil  // reset when done
      // Auto-reset when clip ends
      DispatchQueue.main.asyncAfter(deadline: .now() + player.duration + 0.1) {
        isPlayingClip = false
      }
    }
  }

  private func enrollSpeaker() {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return }
    // Enroll the speaker clip as a voice sample for this person
    if let clipData = speaker.clipData {
      viewModel.enrollUnknownSpeaker(speakerIndex: speaker.speakerIndex,
                                      sessionId: speaker.conversationSessionId,
                                      name: trimmed,
                                      clipData: clipData,
                                      existingPersonId: existingPerson?.id)
    } else {
      viewModel.renameUnknownSpeaker(speakerIndex: speaker.speakerIndex,
                                      sessionId: speaker.conversationSessionId,
                                      name: trimmed,
                                      existingPersonId: existingPerson?.id)
    }
    onDismiss()
  }
}
