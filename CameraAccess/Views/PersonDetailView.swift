import SwiftUI

struct PersonDetailView: View {
  let entry: PersonDictionaryEntry
  @ObservedObject var viewModel: StreamSessionViewModel
  @Environment(\.dismiss) private var dismiss

  @State private var selectedTab: DetailTab = .face
  @State private var pendingDeleteTarget: DeleteTarget?

  enum DetailTab: String, CaseIterable {
    case face = "Face"
    case voice = "Voice"
    case conversations = "Convos"
  }

  private enum DeleteTarget: Identifiable {
    case person
    case face
    case voice

    var id: String {
      switch self {
      case .person: "person"
      case .face: "face"
      case .voice: "voice"
      }
    }

    var title: String {
      switch self {
      case .person: "Delete person?"
      case .face: "Delete facial scan?"
      case .voice: "Delete voice enrollment?"
      }
    }

    var message: String {
      switch self {
      case .person:
        "This will permanently remove their face embeddings, voice enrollment, and all interaction history."
      case .face:
        "This removes only the stored face embeddings and enrollment photos. Voice enrollment and conversation history stay in the dictionary."
      case .voice:
        "This removes only the stored voice embedding and voice preview. Face enrollment and conversation history stay in the dictionary."
      }
    }

    var buttonTitle: String {
      switch self {
      case .person: "Delete Person"
      case .face: "Delete Facial Scan"
      case .voice: "Delete Voice"
      }
    }
  }

  private static let dayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .full
    f.timeStyle = .none
    return f
  }()

  private static let enrolledFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    return f
  }()

  private static let conversationTimeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    return f
  }()

  private static let lineTimeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .none
    f.timeStyle = .medium
    return f
  }()

  var body: some View {
    List {
      tabPickerSection
      if selectedTab == .face {
        headerSection
        if !displayedEntry.embeddingImages.isEmpty {
          embeddingImagesSection
        }
        faceDeleteSection
        if !displayedEntry.interactionDays.isEmpty {
          daysSection
        } else {
          emptySection
        }
        deleteSection
      } else if selectedTab == .voice {
        voiceSection
        voiceDeleteSection
        deleteSection
      } else {
        conversationsSection
        deleteSection
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle(displayedEntry.displayName)
    .navigationBarTitleDisplayMode(.inline)
    .alert(item: $pendingDeleteTarget) { target in
      Alert(
        title: Text(target.title),
        message: Text(target.message),
        primaryButton: .destructive(Text(target.buttonTitle)) {
          switch target {
          case .person:
            viewModel.deletePerson(id: entry.id)
            dismiss()
          case .face:
            viewModel.deleteFaceEnrollmentOnly(for: entry.id)
          case .voice:
            viewModel.deleteVoiceEnrollmentOnly(for: entry.id)
          }
        },
        secondaryButton: .cancel()
      )
    }
  }

  private var displayedEntry: PersonDictionaryEntry {
    viewModel.peopleDictionaryEntries.first { $0.id == entry.id } ?? entry
  }

  private var hasFaceEnrollment: Bool {
    !displayedEntry.embeddingImages.isEmpty || !displayedEntry.profile.embeddingIds.isEmpty
  }

  private var currentDisplayName: String {
    displayedEntry.displayName
  }

  private func destructiveButton(title: String, systemImage: String, target: DeleteTarget) -> some View {
    Button(role: .destructive) {
      pendingDeleteTarget = target
    } label: {
      Label(title, systemImage: systemImage)
        .frame(maxWidth: .infinity)
    }
  }

  // MARK: - Tab picker

  private var tabPickerSection: some View {
    Section {
      Picker("", selection: $selectedTab) {
        ForEach(DetailTab.allCases, id: \.self) { tab in
          Text(tab.rawValue).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .listRowBackground(Color.clear)
      .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
    }
  }

  // MARK: - Header

  private var headerSection: some View {
    Section {
      HStack(spacing: 16) {
        thumbnailView
          .frame(width: 76, height: 76)
          .clipShape(Circle())

        VStack(alignment: .leading, spacing: 6) {
          Text(displayedEntry.displayName)
            .font(.title2.bold())
          statusBadge
          if let lastSeen = displayedEntry.lastSeen {
            Text("Last seen " + RelativeDateTimeFormatter().localizedString(for: lastSeen, relativeTo: Date()))
              .font(.caption)
              .foregroundColor(.secondary)
          }
        }
        Spacer()
      }
      .padding(.vertical, 6)

      HStack(spacing: 0) {
        statItem(value: "\(displayedEntry.interactionDays.count)", label: "Days")
        Divider().frame(height: 32)
        statItem(value: "\(displayedEntry.interactionDays.reduce(0) { $0 + $1.totalFaceDetections })", label: "Detections")
        Divider().frame(height: 32)
        statItem(value: "\(displayedEntry.transcripts.count)", label: "Transcripts")
      }
      .padding(.vertical, 4)
    }
  }

  // MARK: - Voice section

  private var voiceEnrolled: Bool {
    viewModel.enrolledVoicePersonIds.contains(entry.id)
  }

  private var isActiveSpeaker: Bool {
    viewModel.activeSpeakerPersonId == entry.id
  }

  private var voiceSection: some View {
    Group {
      Section {
        HStack {
          Image(systemName: voiceEnrolled ? "waveform.badge.checkmark" : "waveform.badge.exclamationmark")
            .foregroundColor(voiceEnrolled ? .green : .orange)
            .font(.title2)
          VStack(alignment: .leading, spacing: 4) {
            Text(voiceEnrolled ? "Voice enrolled" : "No voice enrolled")
              .font(.system(size: 15, weight: .semibold))
            Text(voiceEnrolled
              ? "Voice pattern saved. \(displayedEntry.displayName)'s speech will be identified."
              : "To enroll a voice, stream audio then use the Voice Enrollment card on the main screen.")
              .font(.caption)
              .foregroundColor(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .padding(.vertical, 4)

        if isActiveSpeaker {
          HStack {
            Image(systemName: "waveform")
              .foregroundColor(.blue)
            VStack(alignment: .leading, spacing: 2) {
              Text("Currently listening to \(displayedEntry.displayName)")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.blue)
              Text("Similarity: \(String(format: "%.2f", viewModel.activeSpeakerSimilarity))")
                .font(.caption)
                .foregroundColor(.secondary)
            }
          }
          .padding(.vertical, 2)
        }
      } header: {
        Text("Voice Identity")
      }

      Section {
        voicePreviewButton
      }
    }
  }

  private var voicePreviewButton: some View {
    let isPlaying = viewModel.isPlayingVoicePreview
    return Button {
      if isPlaying {
        viewModel.stopVoicePreview()
      } else {
        viewModel.playVoicePreview(for: entry.id)
      }
    } label: {
      Label(
        isPlaying ? "Stop Preview" : "Preview Enrolled Voice",
        systemImage: isPlaying ? "stop.circle.fill" : "speaker.wave.2"
      )
      .frame(maxWidth: .infinity)
    }
    .disabled(!voiceEnrolled && !isPlaying)
    .buttonStyle(.bordered)
    .listRowBackground(Color.clear)
    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
  }

  // MARK: - Conversations

  private var conversationsSection: some View {
    Group {
      if displayedEntry.conversationTranscripts.isEmpty {
        Section {
          VStack(spacing: 8) {
            Image(systemName: "text.bubble")
              .font(.system(size: 32))
              .foregroundColor(.secondary)
            Text("No attributed conversations yet")
              .font(.subheadline)
              .foregroundColor(.secondary)
            Text("After a stream ends, transcript lines attributed to \(displayedEntry.displayName) will make the whole conversation available here.")
              .font(.caption)
              .foregroundColor(.secondary)
              .multilineTextAlignment(.center)
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 16)
        }
      } else {
        Section {
          HStack(spacing: 0) {
            statItem(value: "\(displayedEntry.conversationTranscripts.count)", label: "Convos")
            Divider().frame(height: 32)
            statItem(value: "\(displayedEntry.conversationTranscripts.reduce(0) { $0 + $1.lines.count })", label: "Lines")
          }
          .padding(.vertical, 6)
        }

        ForEach(displayedEntry.conversationTranscripts) { conversation in
          Section {
            ForEach(conversation.lines) { line in
              transcriptLineRow(line)
            }
          } header: {
            Text(Self.conversationTimeFormatter.string(from: conversation.startedAt))
          }
        }
      }
    }
  }

  private func transcriptLineRow(_ line: ConversationTranscriptLine) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text(line.speakerName)
          .font(.system(size: 13, weight: .semibold))
          .foregroundColor(line.chunk.personId == displayedEntry.id ? .blue : .secondary)
        Spacer()
        Text(Self.lineTimeFormatter.string(from: line.chunk.startedAt ?? line.chunk.createdAt))
          .font(.caption2)
          .foregroundColor(.secondary)
      }
      Text(line.chunk.text)
        .font(.system(size: 14))
        .foregroundColor(.primary)
        .fixedSize(horizontal: false, vertical: true)
      if line.chunk.source.contains("fusion:") || line.chunk.source.contains("diarization") {
        Text(line.chunk.source.replacingOccurrences(of: "AppleSpeech+", with: ""))
          .font(.caption2)
          .foregroundColor(.secondary)
          .lineLimit(2)
      }
    }
    .padding(.vertical, 4)
  }

  private var deleteSection: some View {
    Section {
      destructiveButton(title: "Delete \(currentDisplayName)", systemImage: "trash", target: .person)
    }
  }

  private var faceDeleteSection: some View {
    Section {
      destructiveButton(title: "Delete Facial Scan Only", systemImage: "person.crop.rectangle.badge.xmark", target: .face)
        .disabled(!hasFaceEnrollment)
    } footer: {
      Text("Removes face embeddings and enrollment photos only. Voice and conversations are kept.")
    }
  }

  private var voiceDeleteSection: some View {
    Section {
      destructiveButton(title: "Delete Voice Only", systemImage: "waveform.badge.minus", target: .voice)
        .disabled(!voiceEnrolled)
    } footer: {
      Text("Removes voice identification only. Face scans and conversations are kept.")
    }
  }

  // MARK: - Embedding images

  private var embeddingImagesSection: some View {
    Section("Enrollment Photos (\(displayedEntry.embeddingImages.count))") {
      let columns = [GridItem(.adaptive(minimum: 80, maximum: 120), spacing: 8)]
      LazyVGrid(columns: columns, spacing: 8) {
        ForEach(0..<displayedEntry.embeddingImages.count, id: \.self) { i in
          Image(uiImage: displayedEntry.embeddingImages[i])
            .resizable()
            .scaledToFill()
            .frame(width: 80, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
      }
      .padding(.vertical, 6)
    }
  }

  // MARK: - Days list

  private var daysSection: some View {
    Section("Interactions by Date") {
      ForEach(displayedEntry.interactionDays) { day in
        NavigationLink(destination: PersonDayView(day: day, personName: displayedEntry.displayName)) {
          dayRow(day)
        }
      }
    }
  }

  private var emptySection: some View {
    Section {
      VStack(spacing: 8) {
        Image(systemName: "calendar.badge.exclamationmark")
          .font(.system(size: 32))
          .foregroundColor(.secondary)
        Text("No recorded interactions yet")
          .font(.subheadline)
          .foregroundColor(.secondary)
        Text("Interaction history appears here after streaming sessions where this person's face is detected.")
          .font(.caption)
          .foregroundColor(.secondary)
          .multilineTextAlignment(.center)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 16)
    }
  }

  // MARK: - Row

  private func dayRow(_ day: PersonInteractionDay) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(Self.dayFormatter.string(from: day.day))
        .font(.system(size: 15, weight: .semibold))
        .foregroundColor(.primary)
      HStack(spacing: 12) {
        Label("\(day.totalFaceDetections) detected", systemImage: "person.fill.viewfinder")
        if day.totalTranscripts > 0 {
          Label("\(day.totalTranscripts) transcript\(day.totalTranscripts == 1 ? "" : "s")", systemImage: "text.bubble")
        }
      }
      .font(.caption)
      .foregroundColor(.secondary)
    }
    .padding(.vertical, 4)
  }

  // MARK: - Helpers

  private var thumbnailView: some View {
    Group {
      if let image = displayedEntry.thumbnail {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
      } else {
        Circle()
          .fill(Color(.systemGray5))
          .overlay(
            Text(displayedEntry.displayName.prefix(1).uppercased())
              .font(.system(size: 28, weight: .semibold))
              .foregroundColor(.secondary)
          )
      }
    }
  }

  private var statusBadge: some View {
    let enrolled = displayedEntry.profile.enrollmentStatus == .enrolled
    return Text(displayedEntry.profile.enrollmentStatus.rawValue.capitalized)
      .font(.caption.bold())
      .foregroundColor(enrolled ? .green : .orange)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background((enrolled ? Color.green : Color.orange).opacity(0.15))
      .clipShape(Capsule())
  }

  private func statItem(value: String, label: String) -> some View {
    VStack(spacing: 2) {
      Text(value)
        .font(.system(size: 20, weight: .bold))
      Text(label)
        .font(.caption)
        .foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity)
  }
}
