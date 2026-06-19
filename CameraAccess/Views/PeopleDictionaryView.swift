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
            Section {
              PeopleOverviewRow(
                peopleCount: viewModel.peopleDictionaryEntries.count,
                glassesInteractionCount: viewModel.peopleDictionaryEntries.reduce(0) { $0 + $1.glassesDisplayInteractions.count },
                activeDisplayConnected: viewModel.glassesDisplayConnected
              )
              .listRowBackground(Color.mementoListCard)
            }

            // Cloud diarization status banner
            if viewModel.cloudDiarizationState != .idle && viewModel.cloudDiarizationState != .done {
              Section {
                HStack(spacing: 10) {
                  ProgressView()
                  Text(viewModel.cloudDiarizationState.statusText)
                    .font(.subheadline)
                    .foregroundColor(MementoTheme.listCardSecondaryText)
                }
                .padding(.vertical, 4)
              }
              .listRowBackground(Color.mementoListCard)
            }

            // Unidentified speakers from last session
            if !viewModel.unknownDiarizationSpeakers.isEmpty {
              Section("Unidentified Speakers") {
                ForEach(viewModel.unknownDiarizationSpeakers) { speaker in
                  UnknownSpeakerRowView(speaker: speaker, onEnroll: {
                    enrollingSpeaker = speaker
                  })
                  .listRowBackground(Color.mementoListCard)
                }
              }
            }

            // Enrolled people
            ForEach(viewModel.peopleDictionaryEntries) { entry in
              PersonRowView(entry: entry, viewModel: viewModel)
                .contentShape(Rectangle())
                .onTapGesture { selectedEntry = entry }
                .listRowBackground(Color.mementoListCard)
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
      .tint(.appPrimary)
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
    let promptableSpeakers = StreamSessionViewModel.promptableUnknownSpeakers(speakers)
    AppLogger.log(
      .speakerEnrollment,
      "[PeopleDictionary] enqueue speaker prompts unknown=\(speakers.count) promptable=\(promptableSpeakers.count)"
    )
    for speaker in speakers.sorted(by: { $0.speakerIndex < $1.speakerIndex }) {
      if let reason = StreamSessionViewModel.speakerEnrollmentSuppressionReason(for: speaker) {
        AppLogger.log(
          .speakerEnrollment,
          "[PeopleDictionary] prompt suppressed speaker=\(speaker.speakerIndex) reason=\(reason) clipBytes=\(speaker.clipData?.count ?? 0)"
        )
      }
    }

    for speaker in promptableSpeakers {
      let key = speakerPromptKey(speaker)
      guard !promptedSpeakerKeys.contains(key),
            !pendingSpeakerPrompts.contains(where: { speakerPromptKey($0) == key }),
            enrollingSpeaker.map(speakerPromptKey) != key else {
        AppLogger.log(
          .speakerEnrollment,
          "[PeopleDictionary] prompt skipped duplicate speaker=\(speaker.speakerIndex) key=\(key)"
        )
        continue
      }
      pendingSpeakerPrompts.append(speaker)
      AppLogger.log(
        .speakerEnrollment,
        "[PeopleDictionary] prompt queued speaker=\(speaker.speakerIndex) key=\(key) clipBytes=\(speaker.clipData?.count ?? 0)"
      )
    }
    presentNextSpeakerPromptIfNeeded()
  }

  private func presentNextSpeakerPromptIfNeeded() {
    guard enrollingSpeaker == nil, !pendingSpeakerPrompts.isEmpty else { return }
    let next = pendingSpeakerPrompts.removeFirst()
    promptedSpeakerKeys.insert(speakerPromptKey(next))
    enrollingSpeaker = next
    AppLogger.log(
      .speakerEnrollment,
      "[PeopleDictionary] prompt presented speaker=\(next.speakerIndex) clipBytes=\(next.clipData?.count ?? 0)"
    )
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
      Text("Memento saves people, conversations, and glasses display reviews here.")
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
              .foregroundColor(MementoTheme.primary)
              .background(Color.mementoListCard.clipShape(Circle()))
          }
        }

      VStack(alignment: .leading, spacing: 4) {
        Text(entry.displayName)
          .font(.system(size: 16, weight: .semibold))
          .foregroundColor(MementoTheme.listCardPrimaryText)
        if !entry.embeddingImages.isEmpty {
          embeddingImageStrip
        }
        Text(statusLine)
          .font(.system(size: 13))
          .foregroundColor(MementoTheme.listCardSecondaryText)
        if !entry.transcripts.isEmpty {
          Text("\(entry.transcripts.count) transcript \(entry.transcripts.count == 1 ? "entry" : "entries")")
            .font(.system(size: 12))
            .foregroundColor(MementoTheme.listCardSecondaryText)
        }
      }

      Spacer()

      if isActiveSpeaker {
        speakerBadge
      }

      Image(systemName: "chevron.right")
        .font(.system(size: 13, weight: .semibold))
        .foregroundColor(MementoTheme.listCardTertiaryText)
    }
    .padding(.vertical, 6)
  }

  private var speakerBadge: some View {
    VStack(spacing: 2) {
      Image(systemName: "waveform")
        .font(.system(size: 14, weight: .semibold))
        .foregroundColor(MementoTheme.primary)
      Text(String(format: "%.0f%%", Double(viewModel.activeSpeakerSimilarity * 100)))
        .font(.system(size: 10, weight: .medium))
        .foregroundColor(MementoTheme.primary)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(MementoTheme.primary.opacity(0.12))
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
          .fill(MementoTheme.listCardMutedFill)
          .overlay(
            Text(entry.displayName.prefix(1).uppercased())
              .font(.system(size: 22, weight: .semibold))
              .foregroundColor(MementoTheme.listCardSecondaryText)
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
          .foregroundColor(MementoTheme.listCardSecondaryText)
          .frame(width: 26, height: 26)
          .background(MementoTheme.listCardMutedFill)
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
    if !entry.glassesDisplayInteractions.isEmpty {
      parts.append("\(entry.glassesDisplayInteractions.count) glasses review\(entry.glassesDisplayInteractions.count == 1 ? "" : "s")")
    }
    return parts.joined(separator: " · ")
  }
}

private struct PeopleOverviewRow: View {
  let peopleCount: Int
  let glassesInteractionCount: Int
  let activeDisplayConnected: Bool

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: "person.2.fill")
        .font(.system(size: 22, weight: .semibold))
        .foregroundColor(MementoTheme.primary)
        .frame(width: 44, height: 44)
        .background(MementoTheme.primary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))

      VStack(alignment: .leading, spacing: 4) {
        Text("Memento People")
          .font(.system(size: 16, weight: .semibold))
          .foregroundColor(MementoTheme.listCardPrimaryText)
        HStack(spacing: 10) {
          Label("\(peopleCount)", systemImage: "person")
          Label("\(glassesInteractionCount)", systemImage: "eyeglasses")
          Label(activeDisplayConnected ? "Display on" : "Display idle", systemImage: "rectangle.on.rectangle")
        }
        .font(.caption)
        .foregroundColor(MementoTheme.listCardSecondaryText)
      }

      Spacer()
    }
    .padding(.vertical, 6)
  }
}

// MARK: - Unknown speaker row

private struct UnknownSpeakerRowView: View {
  let speaker: UnknownDiarizationSpeaker
  let onEnroll: () -> Void

  var body: some View {
    HStack(spacing: 14) {
      Circle()
        .fill(MementoTheme.listCardMutedFill)
        .frame(width: 56, height: 56)
        .overlay(
          Image(systemName: "person.fill.questionmark")
            .font(.system(size: 22))
            .foregroundColor(MementoTheme.listCardSecondaryText)
        )
      VStack(alignment: .leading, spacing: 4) {
        Text(speaker.id)
          .font(.system(size: 16, weight: .semibold))
          .foregroundColor(MementoTheme.listCardPrimaryText)
        Text(String(format: "%.0f s spoken · %d segment%@",
                    Double(speaker.totalSeconds), speaker.segmentCount,
                    speaker.segmentCount == 1 ? "" : "s"))
          .font(.system(size: 13))
          .foregroundColor(MementoTheme.listCardSecondaryText)
        Text("Tap to identify & enroll")
          .font(.system(size: 12))
          .foregroundColor(MementoTheme.primary)
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
        } else {
          Section("Voice Preview") {
            Text("No clean single-speaker clip is available for voice enrollment.")
              .font(.system(size: 13))
              .foregroundColor(.secondary)
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
                    Image(systemName: "checkmark").foregroundColor(MementoTheme.primary)
                  }
                }
              }
            }
          }
          TextField("Or enter a new name…", text: $name)
            .onChange(of: name) { _ in existingPerson = nil }
        }

        Section {
          Button(speaker.clipData == nil ? "Save Name" : "Save & Enroll") {
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
    } else if let data = speaker.clipData {
      do {
        try configurePhoneSpeakerPlayback()
        let player = try AVAudioPlayer(data: data)
        player.volume = 1.0
        player.prepareToPlay()
        audioPlayer = player
        player.play()
        isPlayingClip = true
        player.delegate = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + player.duration + 0.1) {
          isPlayingClip = false
        }
      } catch {
        AppLogger.log(.audio, "Unknown speaker preview playback failed speaker=\(speaker.speakerIndex): \(error.localizedDescription)")
        isPlayingClip = false
      }
    }
  }

  private func configurePhoneSpeakerPlayback() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
    if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
      try? session.setPreferredInput(builtIn)
    }
    try session.overrideOutputAudioPort(.speaker)
    try session.setActive(true)
    let outputRouteDesc = session.currentRoute.outputs
      .map { "\($0.portName)/\($0.portType.rawValue)" }
      .joined(separator: ",")
    let lower = outputRouteDesc.lowercased()
    if lower.contains("rb meta")
      || lower.contains("ray-ban")
      || lower.contains("rayban")
      || lower.contains("bluetootha2dpoutput")
      || lower.contains("bluetoothhfp") {
      throw NSError(
        domain: "UnknownSpeakerPreview",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Refused glasses output route [\(outputRouteDesc)]"]
      )
    }
    AppLogger.log(.audio, "Unknown speaker preview route=[\(outputRouteDesc)]")
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
