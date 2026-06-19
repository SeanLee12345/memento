import SwiftUI

struct StreamSummaryHistoryView: View {
  @ObservedObject var viewModel: StreamSessionViewModel

  var body: some View {
    NavigationStack {
      Group {
        if viewModel.streamSummaryHistory.isEmpty {
          ContentUnavailableView(
            "No Stream Summaries",
            systemImage: "sparkles.rectangle.stack",
            description: Text("Stop a stream after transcript or scene context is captured to generate a summary.")
          )
        } else {
          List {
            ForEach(daySections, id: \.day) { section in
              Section(section.day.formatted(date: .complete, time: .omitted)) {
                ForEach(section.entries) { entry in
                  StreamSummaryHistoryRow(entry: entry)
                    .listRowBackground(Color.mementoListCard)
                }
              }
            }
          }
          .listStyle(.insetGrouped)
        }
      }
      .navigationTitle("Stream Summaries")
      .navigationBarTitleDisplayMode(.large)
      .tint(.appPrimary)
      .toolbar {
        ToolbarItem(placement: .navigationBarTrailing) {
          Button("Done") { viewModel.showStreamSummaryHistory = false }
        }
      }
    }
  }

  private var daySections: [(day: Date, entries: [StreamSummaryHistoryEntry])] {
    let calendar = Calendar.current
    let grouped = Dictionary(grouping: viewModel.streamSummaryHistory) {
      calendar.startOfDay(for: $0.endedAt)
    }
    return grouped
      .map { day, entries in
        (day: day, entries: entries.sorted { $0.endedAt > $1.endedAt })
      }
      .sorted { $0.day > $1.day }
  }
}

private struct StreamSummaryHistoryRow: View {
  let entry: StreamSummaryHistoryEntry

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(timeRangeText)
          .font(.headline)
          .foregroundStyle(MementoTheme.listCardPrimaryText)
        Spacer()
        Text("\(Int((entry.confidence * 100).rounded()))%")
          .font(.caption.weight(.semibold))
          .foregroundStyle(MementoTheme.primary)
      }

      Text(entry.summary)
        .font(.subheadline)
        .foregroundStyle(MementoTheme.listCardPrimaryText)
        .fixedSize(horizontal: false, vertical: true)

      VStack(alignment: .leading, spacing: 5) {
        summaryLine("Who", entry.who)
        summaryLine("Where", entry.whereText)
        summaryLine("What", entry.what)
        summaryLine("When", effectiveWhenText)
        summaryLine("Why", entry.why)
        summaryLine("How", entry.how)
      }

      if !entry.outline.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Text("Outline")
            .font(.caption.weight(.bold))
            .foregroundStyle(MementoTheme.listCardSecondaryText)
          ForEach(entry.outline, id: \.self) { item in
            Text("- \(item)")
              .font(.caption)
              .foregroundStyle(MementoTheme.listCardSecondaryText)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }

      if !entry.keyMoments.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Text("Key Moments")
            .font(.caption.weight(.bold))
            .foregroundStyle(MementoTheme.listCardSecondaryText)
          ForEach(entry.keyMoments, id: \.self) { item in
            Text("- \(item)")
              .font(.caption)
              .foregroundStyle(MementoTheme.listCardSecondaryText)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }

      Text("\(entry.statusText) - \(entry.modelName)")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(MementoTheme.listCardTertiaryText)
    }
    .padding(.vertical, 6)
  }

  private func summaryLine(_ label: String, _ value: String) -> some View {
    let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return HStack(alignment: .top, spacing: 6) {
      Text(label)
        .font(.caption.weight(.bold))
        .foregroundStyle(MementoTheme.listCardSecondaryText)
        .frame(width: 46, alignment: .leading)
      Text(text.isEmpty ? "unknown" : text)
        .font(.caption)
        .foregroundStyle(MementoTheme.listCardSecondaryText)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var effectiveWhenText: String {
    let trimmed = entry.whenText.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty || trimmed == "unknown" ? timeRangeText : trimmed
  }

  private var timeRangeText: String {
    "\(entry.startedAt.formatted(date: .omitted, time: .shortened)) - \(entry.endedAt.formatted(date: .omitted, time: .shortened))"
  }
}
