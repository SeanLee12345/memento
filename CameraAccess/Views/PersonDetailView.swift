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
    case glasses = "Glasses"
    case context = "Context"
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
      historyButtonSection
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
      } else if selectedTab == .conversations {
        conversationsSection
        deleteSection
      } else if selectedTab == .glasses {
        glassesSection
        deleteSection
      } else {
        contextSection
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

  private var historyButtonSection: some View {
    Section {
      NavigationLink(destination: PersonHistoryView(entry: displayedEntry)) {
        Label("History", systemImage: "clock.arrow.circlepath")
      }
      .disabled(
        displayedEntry.conversationTranscripts.isEmpty
          && displayedEntry.sceneContexts.isEmpty
          && displayedEntry.glassesDisplayInteractions.isEmpty
      )
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
              Text("Similarity: \(String(format: "%.2f", Double(viewModel.activeSpeakerSimilarity)))")
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

  // MARK: - Context

  private var contextSection: some View {
    Group {
      if displayedEntry.sceneContexts.isEmpty {
        Section {
          VStack(spacing: 8) {
            Image(systemName: "map")
              .font(.system(size: 32))
              .foregroundColor(.secondary)
            Text("No scene context yet")
              .font(.subheadline)
              .foregroundColor(.secondary)
            Text("Enable Alibaba scene context during a live stream to save 5W1H memories from images, transcript, and optional iPhone location.")
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
            statItem(value: "\(displayedEntry.sceneContexts.count)", label: "Contexts")
            Divider().frame(height: 32)
            statItem(value: "\(averageContextConfidence)%", label: "Avg confidence")
          }
          .padding(.vertical, 6)
        }

        ForEach(displayedEntry.sceneContexts) { context in
          Section {
            sceneContextRow(context)
          } header: {
            Text(Self.conversationTimeFormatter.string(from: context.startedAt))
          }
        }
      }
    }
  }

  private var averageContextConfidence: Int {
    guard !displayedEntry.sceneContexts.isEmpty else { return 0 }
    let average = displayedEntry.sceneContexts.reduce(0) { $0 + $1.confidence } / Double(displayedEntry.sceneContexts.count)
    return Int((average * 100).rounded())
  }

  // MARK: - Glasses

  private var glassesSection: some View {
    Group {
      if displayedEntry.glassesDisplayInteractions.isEmpty {
        Section {
          ContentUnavailableView(
            "No glasses reviews yet",
            systemImage: "eyeglasses",
            description: Text("Memento will save shown cards and button taps from the glasses display here.")
          )
        }
      } else {
        Section {
          HStack(spacing: 0) {
            statItem(value: "\(displayedEntry.glassesDisplayInteractions.filter { $0.actionKind == .displayed }.count)", label: "Shown")
            Divider().frame(height: 32)
            statItem(value: "\(displayedEntry.glassesDisplayInteractions.filter { $0.actionKind != .displayed }.count)", label: "Taps")
            Divider().frame(height: 32)
            statItem(value: "\(displayedEntry.glassesDisplayInteractions.count)", label: "Total")
          }
          .padding(.vertical, 6)
        }

        Section("Glasses Reviews") {
          ForEach(displayedEntry.glassesDisplayInteractions.sorted { $0.createdAt > $1.createdAt }) { event in
            glassesInteractionRow(event)
          }
        }
      }
    }
  }

  private func glassesInteractionRow(_ event: GlassesDisplayInteractionEvent) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Label(event.actionLabel, systemImage: event.actionKind == .displayed ? "rectangle.on.rectangle" : "hand.tap")
          .font(.system(size: 13, weight: .semibold))
          .foregroundColor(event.actionKind == .displayed ? .secondary : .blue)
        Spacer()
        Text(Self.lineTimeFormatter.string(from: event.createdAt))
          .font(.caption2)
          .foregroundColor(.secondary)
      }
      Text(event.cardTitle)
        .font(.system(size: 14, weight: .semibold))
      Text(event.displaySummary)
        .font(.caption)
        .foregroundColor(.secondary)
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.vertical, 4)
  }

  private func sceneContextRow(_ context: SceneContextRecord) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(context.summary)
        .font(.system(size: 15, weight: .semibold))
        .fixedSize(horizontal: false, vertical: true)

      Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
        contextGridRow("Who", context.who)
        contextGridRow("Where", context.whereText)
        contextGridRow("What", context.what)
        contextGridRow("When", context.whenText)
        contextGridRow("Why", context.why)
        contextGridRow("How", context.how)
        contextGridRow("Style", context.interactionStyle)
      }
      .font(.system(size: 13))

      HStack(spacing: 10) {
        Label("\(Int((context.confidence * 100).rounded()))%", systemImage: "gauge.medium")
        if let locationLabel = context.locationLabel, !locationLabel.isEmpty {
          Label(locationLabel, systemImage: "location")
            .lineLimit(1)
        }
      }
      .font(.caption)
      .foregroundColor(.secondary)
    }
    .padding(.vertical, 4)
  }

  private func contextGridRow(_ label: String, _ value: String) -> some View {
    GridRow {
      Text(label)
        .fontWeight(.semibold)
        .foregroundColor(.secondary)
      Text(value.isEmpty ? "unknown" : value)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var deleteSection: some View {
    Section {
      destructiveButton(title: "Delete \(currentDisplayName)", systemImage: "trash", target: .person)
    }
  }

  private var faceDeleteSection: some View {
    Section {
      destructiveButton(title: "Delete Facial Scan Only", systemImage: "person.crop.circle.badge.xmark", target: .face)
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
        if day.totalGlassesInteractions > 0 {
          Label("\(day.totalGlassesInteractions) glasses", systemImage: "eyeglasses")
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

private struct PersonHistoryView: View {
  let entry: PersonDictionaryEntry

  private static let dayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .full
    f.timeStyle = .none
    return f
  }()

  var body: some View {
    List {
      if dayGroups.isEmpty {
        Section {
          ContentUnavailableView(
            "No history yet",
            systemImage: "clock",
            description: Text("Conversation history and scene context will appear here after a session.")
          )
        }
      } else {
        Section("Days") {
          ForEach(dayGroups) { group in
            NavigationLink(destination: PersonHistoryDayView(personName: entry.displayName, group: group)) {
              VStack(alignment: .leading, spacing: 4) {
                Text(Self.dayFormatter.string(from: group.day))
                  .font(.system(size: 15, weight: .semibold))
                HStack(spacing: 12) {
                  Label("\(group.conversations.count) convo\(group.conversations.count == 1 ? "" : "s")", systemImage: "text.bubble")
                  Label("\(group.totalContextCount) context\(group.totalContextCount == 1 ? "" : "s")", systemImage: "map")
                  Label("\(group.glassesInteractions.count) glasses", systemImage: "eyeglasses")
                }
                .font(.caption)
                .foregroundColor(.secondary)
              }
              .padding(.vertical, 4)
            }
          }
        }
      }
    }
    .navigationTitle("History")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var dayGroups: [PersonHistoryDayGroup] {
    let calendar = Calendar.current
    let conversationSessionIds = Set(entry.conversationTranscripts.map(\.conversationSessionId))
    let contextOnly = entry.sceneContexts
      .filter { context in
        guard let sessionId = context.conversationSessionId else { return true }
        return !conversationSessionIds.contains(sessionId)
      }
    let days = Set(
      entry.conversationTranscripts.map { calendar.startOfDay(for: $0.startedAt) }
        + contextOnly.map { calendar.startOfDay(for: $0.startedAt) }
        + entry.glassesDisplayInteractions.map { calendar.startOfDay(for: $0.createdAt) }
    )

    return days.map { day in
      PersonHistoryDayGroup(
        day: day,
        conversations: entry.conversationTranscripts
          .filter { calendar.isDate($0.startedAt, inSameDayAs: day) }
          .sorted { $0.startedAt > $1.startedAt },
        contextOnly: contextOnly
          .filter { calendar.isDate($0.startedAt, inSameDayAs: day) }
          .sorted { $0.startedAt > $1.startedAt },
        glassesInteractions: entry.glassesDisplayInteractions
          .filter { calendar.isDate($0.createdAt, inSameDayAs: day) }
          .sorted { $0.createdAt > $1.createdAt }
      )
    }
    .sorted { $0.day > $1.day }
  }
}

private struct PersonHistoryDayGroup: Identifiable {
  let day: Date
  let conversations: [PersonConversationTranscript]
  let contextOnly: [SceneContextRecord]
  let glassesInteractions: [GlassesDisplayInteractionEvent]

  var id: Date { day }
  var totalContextCount: Int {
    conversations.reduce(contextOnly.count) { $0 + $1.sceneContexts.count }
  }
}

private struct PersonHistoryDayView: View {
  let personName: String
  let group: PersonHistoryDayGroup

  private static let dayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .full
    f.timeStyle = .none
    return f
  }()

  private static let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .none
    f.timeStyle = .short
    return f
  }()

  var body: some View {
    List {
      if !group.conversations.isEmpty {
        Section("Conversations") {
          ForEach(group.conversations) { conversation in
            NavigationLink(destination: PersonHistoryConversationView(personName: personName, conversation: conversation)) {
              conversationRow(conversation)
            }
          }
        }
      }

      if !group.contextOnly.isEmpty {
        Section("Scene Context") {
          ForEach(group.contextOnly) { context in
            SceneContextHistoryRow(context: context)
          }
        }
      }

      if !group.glassesInteractions.isEmpty {
        Section("Glasses Reviews") {
          ForEach(group.glassesInteractions) { event in
            VStack(alignment: .leading, spacing: 6) {
              Label(event.actionLabel, systemImage: event.actionKind == .displayed ? "rectangle.on.rectangle" : "hand.tap")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(event.actionKind == .displayed ? .secondary : .blue)
              Text(event.displaySummary)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(3)
            }
            .padding(.vertical, 4)
          }
        }
      }
    }
    .navigationTitle(Self.dayFormatter.string(from: group.day))
    .navigationBarTitleDisplayMode(.inline)
  }

  private func conversationRow(_ conversation: PersonConversationTranscript) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(Self.timeFormatter.string(from: conversation.startedAt))
        .font(.system(size: 15, weight: .semibold))
      HStack(spacing: 12) {
        Label("\(conversation.lines.count) line\(conversation.lines.count == 1 ? "" : "s")", systemImage: "text.quote")
        Label("\(conversation.sceneContexts.count) context\(conversation.sceneContexts.count == 1 ? "" : "s")", systemImage: "map")
      }
      .font(.caption)
      .foregroundColor(.secondary)
      if let context = conversation.sceneContexts.first {
        Text(context.summary)
          .font(.caption)
          .foregroundColor(.secondary)
          .lineLimit(2)
      }
    }
    .padding(.vertical, 4)
  }
}

private struct PersonHistoryConversationView: View {
  let personName: String
  let conversation: PersonConversationTranscript

  private static let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .none
    f.timeStyle = .medium
    return f
  }()

  var body: some View {
    List {
      if !conversation.sceneContexts.isEmpty {
        Section("Scene Context") {
          ForEach(conversation.sceneContexts) { context in
            SceneContextHistoryRow(context: context)
          }
        }
      }

      Section("Transcript") {
        ForEach(conversation.lines) { line in
          VStack(alignment: .leading, spacing: 5) {
            HStack {
              Text(line.speakerName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(line.speakerName == personName ? .blue : .secondary)
              Spacer()
              Text(Self.timeFormatter.string(from: line.chunk.startedAt ?? line.chunk.createdAt))
                .font(.caption2)
                .foregroundColor(.secondary)
            }
            Text(line.chunk.text)
              .font(.system(size: 14))
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(.vertical, 4)
        }
      }
    }
    .navigationTitle("Conversation")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct SceneContextHistoryRow: View {
  let context: SceneContextRecord

  private static let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .none
    f.timeStyle = .short
    return f
  }()

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(Self.timeFormatter.string(from: context.startedAt))
          .font(.system(size: 13, weight: .semibold))
        Spacer()
        Text("\(Int((context.confidence * 100).rounded()))%")
          .font(.caption)
          .foregroundColor(.secondary)
      }
      Text(context.summary)
        .font(.system(size: 15, weight: .semibold))
        .fixedSize(horizontal: false, vertical: true)
      Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
        gridRow("Who", context.who)
        gridRow("Where", context.whereText)
        gridRow("What", context.what)
        gridRow("When", context.whenText)
        gridRow("Why", context.why)
        gridRow("How", context.how)
        gridRow("Style", context.interactionStyle)
      }
      .font(.system(size: 13))
      if let locationLabel = context.locationLabel, !locationLabel.isEmpty {
        Label(locationLabel, systemImage: "location")
          .font(.caption)
          .foregroundColor(.secondary)
      }
    }
    .padding(.vertical, 4)
  }

  private func gridRow(_ label: String, _ value: String) -> some View {
    GridRow {
      Text(label)
        .fontWeight(.semibold)
        .foregroundColor(.secondary)
      Text(value.isEmpty ? "unknown" : value)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
