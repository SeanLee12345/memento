import Foundation

// MARK: - Job spec (uploaded to S3 to trigger EC2 job)

struct DiarizenJobSpec: Codable, Sendable {
  let jobId: String
  let audioKey: String          // S3 key of the session WAV
  let streamStartUnix: Double   // Unix timestamp when stream audio recording started
  let resultKey: String?
  let statusKey: String?
  let errorKey: String?
  let conversationSessionId: String?
  let audioDurationSeconds: Double?
  let audioByteCount: Int?
  let createdAt: String?

  init(
    jobId: String,
    audioKey: String,
    streamStartUnix: Double,
    resultKey: String? = nil,
    statusKey: String? = nil,
    errorKey: String? = nil,
    conversationSessionId: String? = nil,
    audioDurationSeconds: Double? = nil,
    audioByteCount: Int? = nil,
    createdAt: String? = nil
  ) {
    self.jobId = jobId
    self.audioKey = audioKey
    self.streamStartUnix = streamStartUnix
    self.resultKey = resultKey
    self.statusKey = statusKey
    self.errorKey = errorKey
    self.conversationSessionId = conversationSessionId
    self.audioDurationSeconds = audioDurationSeconds
    self.audioByteCount = audioByteCount
    self.createdAt = createdAt
  }
}

struct DiarizenJobStatus: Codable, Sendable {
  let jobId: String
  let state: String
  let audioKey: String?
  let resultKey: String?
  let statusKey: String?
  let conversationSessionId: String?
  let audioDurationSeconds: Double?
  let audioByteCount: Int?
  let createdAt: String?
  let startedAt: String?
  let finishedAt: String?
  let failedAt: String?
  let updatedAt: String?
  let lambdaRequestId: String?
  let workerHostname: String?
  let workerProcessId: Int?
  let errorKind: String?
  let errorMessage: String?
  let instanceState: String?
  let publicIp: String?
  let privateIp: String?
}

// MARK: - Result (returned by EC2 worker)

struct DiarizenSegment: Codable, Sendable {
  let start: Double             // seconds from audio start
  let end: Double
  let speakerIndex: Int         // 0-based, stable within a job
  let text: String
}

struct DiarizenResult: Codable, Sendable {
  let jobId: String
  let speakerCount: Int
  let segments: [DiarizenSegment]
  let speakerClipKeys: [String: String]  // "0" → S3 key of speaker audio clip
  let processedAt: String
}

// MARK: - Speaker timeline (recorded during the live stream)

struct SpeakerTimelineEntry: Sendable {
  let timestamp: Date
  let personId: UUID?
  let displayName: String?
}

// MARK: - Cloud diarization job state (published by ViewModel)

enum CloudDiarizationState: Equatable, Sendable {
  case idle
  case recording                          // stream is live, audio is being captured
  case uploading                          // stream ended, uploading to S3
  case processing                         // EC2 job running
  case done                              // result received and saved
  case failed(String)

  static func == (lhs: CloudDiarizationState, rhs: CloudDiarizationState) -> Bool {
    switch (lhs, rhs) {
    case (.idle, .idle), (.recording, .recording), (.uploading, .uploading),
         (.processing, .processing), (.done, .done): return true
    case (.failed(let a), .failed(let b)): return a == b
    default: return false
    }
  }

  var statusText: String {
    switch self {
    case .idle: return ""
    case .recording: return "Recording session audio…"
    case .uploading: return "Uploading for diarization…"
    case .processing: return "Cloud diarization in progress…"
    case .done: return "Transcript ready"
    case .failed(let msg): return "Diarization failed: \(msg)"
    }
  }
}

// MARK: - Unknown speaker (needs voice enrollment after diarization)

struct UnknownDiarizationSpeaker: Identifiable, Equatable, Sendable {
  let id: String                  // "Speaker 0", "Speaker 1" etc.
  let speakerIndex: Int
  let clipS3Key: String?          // S3 key for a short audio clip
  let segmentCount: Int
  let totalSeconds: Double
  let conversationSessionId: UUID // session the chunks were saved under
  var clipData: Data?             // downloaded locally after job completes
}
