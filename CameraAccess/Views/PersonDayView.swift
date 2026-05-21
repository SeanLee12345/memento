import SwiftUI

struct PersonDayView: View {
  let day: PersonInteractionDay
  let personName: String

  private static let dayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .long
    f.timeStyle = .none
    return f
  }()

  private static let hourFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "h:00 a"
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
      summarySection
      ForEach(day.hours) { hour in
        hourSection(hour)
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle(Self.dayFormatter.string(from: day.day))
    .navigationBarTitleDisplayMode(.inline)
  }

  // MARK: - Summary

  private var summarySection: some View {
    Section {
      HStack(spacing: 0) {
        statItem(value: "\(day.hours.count)", label: "Hours active")
        Divider().frame(height: 32)
        statItem(value: "\(day.totalFaceDetections)", label: "Face detections")
        Divider().frame(height: 32)
        statItem(value: "\(day.totalTranscripts)", label: "Transcripts")
      }
      .padding(.vertical, 6)
    }
  }

  // MARK: - Hour section

  private func hourSection(_ hour: PersonInteractionHour) -> some View {
    Section {
      if hour.transcripts.isEmpty {
        HStack {
          Image(systemName: "person.fill.viewfinder")
            .foregroundColor(.secondary)
          Text("\(hour.faceDetectionCount) face detection\(hour.faceDetectionCount == 1 ? "" : "s"), no transcript recorded")
            .font(.subheadline)
            .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
      } else {
        if hour.faceDetectionCount > 0 {
          HStack(spacing: 6) {
            Image(systemName: "person.fill.viewfinder")
              .font(.caption)
              .foregroundColor(.secondary)
            Text("\(hour.faceDetectionCount) face detection\(hour.faceDetectionCount == 1 ? "" : "s")")
              .font(.caption)
              .foregroundColor(.secondary)
          }
          .padding(.vertical, 2)
        }
        ForEach(hour.transcripts) { chunk in
          transcriptRow(chunk)
        }
      }
    } header: {
      hourHeader(hour)
    }
  }

  private func hourHeader(_ hour: PersonInteractionHour) -> some View {
    HStack {
      Image(systemName: "clock")
        .font(.caption2)
      Text(Self.hourFormatter.string(from: hour.hour))
        .font(.system(size: 13, weight: .semibold))
      Spacer()
      if hour.faceDetectionCount > 0 || !hour.transcripts.isEmpty {
        Text("\(hour.faceDetectionCount) detected · \(hour.transcripts.count) transcript\(hour.transcripts.count == 1 ? "" : "s")")
          .font(.caption2)
          .foregroundColor(.secondary)
      }
    }
  }

  private func transcriptRow(_ chunk: TranscriptChunk) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(chunk.text)
        .font(.system(size: 14))
        .foregroundColor(.primary)
        .fixedSize(horizontal: false, vertical: true)
      Text(Self.timeFormatter.string(from: chunk.createdAt))
        .font(.caption2)
        .foregroundColor(.secondary)
    }
    .padding(.vertical, 4)
  }

  // MARK: - Helpers

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
