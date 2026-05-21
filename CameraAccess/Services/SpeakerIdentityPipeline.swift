import AVFoundation
import Foundation

// Mirrors IdentityPipeline but for voice.
// Receive AVAudioPCMBuffer from SpeechTranscriptionManager.onAudioBuffer,
// gate with VAD, accumulate speech, embed, match, and roll-confirm speaker identity.
actor SpeakerIdentityPipeline {
  private static let wearerPersonId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

  // MARK: - Rolling confirmor (mirrors RollingIdentityConfirmor)

  private struct RollingSpeakerConfirmor {
    private struct Observation {
      let personId: UUID?
      let displayName: String?
      let confidence: Float
      let decision: SpeakerMatchResult.Decision
      let timestamp: Date
    }

    private var observations: [Observation] = []
    private var activeIdentity = SpeakerIdentityState.idle

    mutating func update(match: SpeakerMatchResult, displayName: String?, now: Date = Date()) -> SpeakerIdentityState {
      observations.append(Observation(
        personId: match.bestPersonId,
        displayName: displayName,
        confidence: match.bestSimilarity,
        decision: match.decision,
        timestamp: now
      ))
      observations.removeAll { now.timeIntervalSince($0.timestamp) > SpeakerIdentityConfig.rollingWindowSeconds }
      if observations.count > SpeakerIdentityConfig.rollingWindowSize {
        observations = Array(observations.suffix(SpeakerIdentityConfig.rollingWindowSize))
      }

      let strongByPerson = Dictionary(
        grouping: observations.filter { $0.decision == .known && $0.personId != nil },
        by: { $0.personId! }
      )

      if let winner = strongByPerson.max(by: { $0.value.count < $1.value.count }),
         winner.value.count >= SpeakerIdentityConfig.requiredStrongMatches,
         let latest = winner.value.last {
        activeIdentity = SpeakerIdentityState(
          personId: winner.key,
          displayName: latest.displayName,
          confidence: latest.confidence,
          phase: .confirmed,
          confirmedAt: activeIdentity.personId == winner.key ? activeIdentity.confirmedAt ?? now : now,
          lastMatchAt: now
        )
        return activeIdentity
      }

      if let candidate = strongByPerson.max(by: { $0.value.count < $1.value.count }),
         let latest = candidate.value.last {
        activeIdentity = SpeakerIdentityState(
          personId: candidate.key,
          displayName: latest.displayName,
          confidence: latest.confidence,
          phase: .possible,
          confirmedAt: nil,
          lastMatchAt: now
        )
        return activeIdentity
      }

      if let latestWeak = observations.last(where: { $0.decision == .ambiguous && $0.personId != nil }) {
        activeIdentity = SpeakerIdentityState(
          personId: latestWeak.personId,
          displayName: latestWeak.displayName,
          confidence: latestWeak.confidence,
          phase: .ambiguous,
          confirmedAt: nil,
          lastMatchAt: now
        )
        return activeIdentity
      }

      if let lastSeen = activeIdentity.lastMatchAt,
         activeIdentity.phase == .confirmed,
         now.timeIntervalSince(lastSeen) < SpeakerIdentityConfig.holdIdentitySeconds {
        return activeIdentity
      }

      activeIdentity = .idle
      return activeIdentity
    }

    mutating func reset() {
      observations.removeAll()
      activeIdentity = .idle
    }

    var currentState: SpeakerIdentityState { activeIdentity }
  }

  // MARK: - State

  private let vad = VoiceActivityDetector()
  private let embeddingModel: SpeakerEmbeddingModel
  private let iPhoneEmbeddingModel: SpeakerEmbeddingModel
  private let workerEmbeddingModel: SpeakerEmbeddingModel
  private var confirmor = RollingSpeakerConfirmor()

  // Resampled 16 kHz mono samples accumulated from VAD-confirmed speech frames.
  private var speechBuffer: [Float] = []
  // When the last speech frame was seen (used to detect end of utterance).
  private var lastSpeechAt: Date?
  // When the last embedding was computed (rate-limiting).
  private var lastEmbeddedAt: Date?
  // Actor calls are reentrant while CoreML/network inference awaits. This prevents
  // multiple audio buffers from launching duplicate embedding requests in parallel.
  private var embeddingInFlight = false

  // Enrolled speakers: averaged embedding per person.
  private var enrolledSpeakers: [SpeakerAveragedEmbedding] = []
  // Individual samples (kept for centroid recalculation).
  private var enrolledRecords: [SpeakerEmbeddingRecord] = []
  // Short raw audio snippet saved at enrollment time for playback in the dictionary.
  private var enrolledPreviewSamples: [UUID: [Float]] = [:]
  // The glasses wearer's own voice profile is intentionally separate from
  // dictionary people. It is used as a negative filter for captured voice clips.
  private var wearerProfile: SpeakerAveragedEmbedding?
  private var wearerRecords: [SpeakerEmbeddingRecord] = []
  private var wearerPreviewSamples: [Float] = []
  private var wearerLastConsistencyScore: Float?
  private var wearerAdditionalCentroids: [SpeakerAveragedEmbedding] = []
  private var wearerEnrollmentSamples: [Float] = []
  private var wearerEnrollmentActive = false
  private var wearerEnrollmentStartedAt: Date?
  private var wearerEnrollmentPromptIndex = 0
  private var wearerEnrollmentCompletedPromptCount = 0
  private struct CapturedVoiceClip {
    let id: UUID
    var samples: [Float]
    var embedding: VoiceEmbedding?
    let createdAt: Date
    var updatedAt: Date
    var status: String
    var speakerLabel: String?
    var mergedSegmentCount: Int
    var bestSimilarity: Float?
    var recognizedPersonId: UUID?
    var recognizedPersonName: String?
  }
  private struct DiarizationCluster {
    var id: UUID
    var label: String
    var personId: UUID?
    var displayName: String?
    var centroid: [Float]
    var segmentCount: Int
    var totalSpeechSeconds: Double
    var lastSeenAt: Date
  }
  private var capturedVoiceClips: [CapturedVoiceClip] = []
  private var lastCapturedVoiceClipAt: Date?
  private let maxCapturedVoiceClips = 8
  private var diarizationClusters: [DiarizationCluster] = []
  private var diarizationSegments: [SpeakerDiarizationSegmentSnapshot] = []
  private var currentSpeechStartedAt: Date?
  private var openDiarizationSegmentId: UUID?
  private var nextUnknownSpeakerNumber = 1

  private var diagnosticBufferCount = 0
  private var diagnosticPeakRMS: Float = 0

  // Resampler: created lazily on first buffer to match the mic's native format.
  private var converter: AVAudioConverter?
  private let outputFormat: AVAudioFormat = {
    AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: SpeakerIdentityConfig.targetSampleRate,
      channels: 1,
      interleaved: false
    )!
  }()

  // MARK: - Persistence

  private static let storageURL: URL = {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    return docs.appendingPathComponent("speaker_embeddings.json")
  }()

  private struct SpeakerStorageData: Codable {
    var enrolledSpeakers: [SpeakerAveragedEmbedding]
    var enrolledRecords: [SpeakerEmbeddingRecord]
    // Keyed by personId string; value is 16kHz mono float32 samples (up to 5s).
    var previewSamples: [String: [Float]]
    var wearerProfile: SpeakerAveragedEmbedding?
    var wearerRecords: [SpeakerEmbeddingRecord]?
    var wearerPreviewSamples: [Float]?
    var wearerConsistencyScore: Float?
    var wearerAdditionalCentroids: [SpeakerAveragedEmbedding]?
  }

  func loadFromDisk() {
    guard let data = try? Data(contentsOf: Self.storageURL),
          let stored = try? JSONDecoder().decode(SpeakerStorageData.self, from: data) else { return }
    enrolledSpeakers = stored.enrolledSpeakers
    enrolledRecords = stored.enrolledRecords
    enrolledPreviewSamples = Dictionary(
      uniqueKeysWithValues: stored.previewSamples.compactMap { k, v in
        UUID(uuidString: k).map { ($0, v) }
      }
    )
    wearerProfile = stored.wearerProfile
    wearerRecords = stored.wearerRecords ?? []
    wearerPreviewSamples = stored.wearerPreviewSamples ?? []
    wearerLastConsistencyScore = stored.wearerConsistencyScore
    wearerAdditionalCentroids = stored.wearerAdditionalCentroids ?? []
    let loadedSpeakers = enrolledSpeakers.count
    let hadWearerProfile = wearerProfile != nil
    purgeIncompatibleEnrollments(saveAfterPurge: false)
    if enrolledSpeakers.count != loadedSpeakers || (hadWearerProfile && wearerProfile == nil) {
      saveToDisk()
    }
    AppLogger.log(.speakerIdentity, "Loaded \(enrolledSpeakers.count) compatible speaker enrollments from disk removedIncompatible=\(loadedSpeakers - enrolledSpeakers.count) wearerEnrolled=\(wearerProfile != nil)")
  }

  @discardableResult
  private func saveToDisk() -> Bool {
    let previews = Dictionary(uniqueKeysWithValues: enrolledPreviewSamples.map { ($0.key.uuidString, $0.value) })
    let stored = SpeakerStorageData(
      enrolledSpeakers: enrolledSpeakers,
      enrolledRecords: enrolledRecords,
      previewSamples: previews,
      wearerProfile: wearerProfile,
      wearerRecords: wearerRecords,
      wearerPreviewSamples: wearerPreviewSamples,
      wearerConsistencyScore: wearerLastConsistencyScore,
      wearerAdditionalCentroids: wearerAdditionalCentroids
    )
    let data: Data
    do {
      data = try JSONEncoder().encode(stored)
    } catch {
      AppLogger.log(.speakerIdentity, "Failed to encode speaker enrollments: \(error.localizedDescription)")
      return false
    }
    do {
      try data.write(to: Self.storageURL, options: .atomic)
    } catch {
      AppLogger.log(.speakerIdentity, "Failed to save speaker enrollments to disk: \(error.localizedDescription)")
      return false
    }
    AppLogger.log(.speakerIdentity, "Saved \(enrolledSpeakers.count) speaker enrollments to disk")
    return true
  }

  // MARK: - Init

  init(
    embeddingModel: SpeakerEmbeddingModel? = nil,
    iPhoneEmbeddingModel: SpeakerEmbeddingModel? = nil,
    workerEmbeddingModel: SpeakerEmbeddingModel? = nil
  ) {
    self.embeddingModel = embeddingModel ?? SpeakerEmbeddingModelFactory.makeLocalModelOnly()
    self.iPhoneEmbeddingModel = iPhoneEmbeddingModel ?? SpeakerEmbeddingModelFactory.makeLocalModelOnly()
    self.workerEmbeddingModel = workerEmbeddingModel ?? MissingSpeakerEmbeddingModel()
    AppLogger.log(.speakerEmbeddingModel, SpeakerEmbeddingModelFactory.diagnosticsText())
  }

  // MARK: - Main entry point

  // Called from SpeechTranscriptionManager.onAudioBuffer (background audio thread).
  // Returns a lightweight result; callers can ignore it if they only care about state changes.
  func process(buffer: AVAudioPCMBuffer) async -> SpeakerProcessingResult {
    // Diagnostic: log once every ~200 buffers (~4s at 44.1kHz/1024) to confirm pipeline is live.
    // Remove after verifying.
    let rms = peakRMS(buffer)
    if rms > diagnosticPeakRMS { diagnosticPeakRMS = rms }

    if diagnosticBufferCount % 200 == 0 {
      AppLogger.log(.speakerVAD, "pipeline alive buffers=\(diagnosticBufferCount) speechSec=\(String(format: "%.1f", speechBufferSeconds)) peakRMS=\(String(format: "%.5f", diagnosticPeakRMS)) threshold=\(SpeakerIdentityConfig.vadEnergyThresholdRMS) format=\(buffer.format.sampleRate)Hz ch=\(buffer.format.channelCount)")
      diagnosticPeakRMS = 0
    }
    diagnosticBufferCount += 1

    guard let samples = resample(buffer) else {
      return SpeakerProcessingResult(
        activeIdentity: confirmor.currentState,
        vadDecision: "resampleFailed",
        accumulatedSpeechSeconds: speechBufferSeconds,
        embeddingTriggered: false,
        matchResult: nil
      )
    }

    appendToWearerEnrollmentBuffer(samples)

    let vadDecision = await vad.classify(samples: samples)
    let now = Date()

    if vadDecision == .speech {
      if currentSpeechStartedAt == nil {
        currentSpeechStartedAt = now
      }
      if speechBuffer.isEmpty {
        let rms = samples.isEmpty ? 0 : sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        AppLogger.log(.speakerVAD, "speech started rms=\(String(format: "%.4f", rms))")
      }
      lastSpeechAt = now
      appendToSpeechBuffer(samples)
    } else {
      // Trigger embedding at end of utterance but keep the buffer intact so
      // currentSpeechBufferForPlayback() stays populated for preview/enrollment.
      // Buffer is only cleared in enroll() after a successful enrollment.
	      if let last = lastSpeechAt,
	         now.timeIntervalSince(last) > SpeakerIdentityConfig.silenceFlushSeconds,
	         speechBufferSeconds >= SpeakerIdentityConfig.minSpeechSecondsForDiarization {
	        if embeddingInFlight {
	          return SpeakerProcessingResult(
	            activeIdentity: confirmor.currentState,
	            vadDecision: "embeddingInFlight",
	            accumulatedSpeechSeconds: speechBufferSeconds,
	            embeddingTriggered: false,
	            matchResult: nil
	          )
	        }
	        let segmentStart = currentSpeechStartedAt ?? now.addingTimeInterval(-speechBufferSeconds)
	        let result = await runEmbeddingAndMatch(
	          now: last,
          segmentStartAt: segmentStart,
          segmentEndAt: last,
          finalSegment: true
        )
        lastSpeechAt = nil
        currentSpeechStartedAt = nil
        openDiarizationSegmentId = nil
        speechBuffer.removeAll()
        return result
      }
    }

    // Rate-limited in-progress embedding while speech is ongoing.
    let canEmbed = speechBufferSeconds >= SpeakerIdentityConfig.minSpeechSecondsForEmbedding
      && (lastEmbeddedAt == nil || now.timeIntervalSince(lastEmbeddedAt!) >= SpeakerIdentityConfig.embeddingIntervalSeconds)

    if canEmbed && vadDecision == .speech {
      let segmentStart = currentSpeechStartedAt ?? now.addingTimeInterval(-speechBufferSeconds)
      return await runEmbeddingAndMatch(
        now: now,
        segmentStartAt: segmentStart,
        segmentEndAt: now,
        finalSegment: false
      )
    }

    return SpeakerProcessingResult(
      activeIdentity: confirmor.currentState,
      vadDecision: vadDecision == .speech ? "speech" : "silence",
      accumulatedSpeechSeconds: speechBufferSeconds,
      embeddingTriggered: false,
      matchResult: nil
    )
  }

  // MARK: - Enrollment

  func beginWearerVoiceEnrollment() {
    wearerEnrollmentSamples.removeAll()
    wearerEnrollmentActive = true
    wearerEnrollmentStartedAt = Date()
    wearerEnrollmentPromptIndex = 0
    wearerEnrollmentCompletedPromptCount = 0
    AppLogger.log(.speakerIdentity, "Wearer voice enrollment started prompt=1/\(SpeakerIdentityConfig.wearerVoicePrompts.count)")
  }

  func advanceWearerVoicePrompt() {
    guard wearerEnrollmentActive else { return }
    wearerEnrollmentCompletedPromptCount = min(
      wearerEnrollmentCompletedPromptCount + 1,
      SpeakerIdentityConfig.wearerVoicePrompts.count
    )
    wearerEnrollmentPromptIndex = min(
      wearerEnrollmentPromptIndex + 1,
      max(0, SpeakerIdentityConfig.wearerVoicePrompts.count - 1)
    )
    AppLogger.log(
      .speakerIdentity,
      "Wearer voice enrollment prompt advanced completed=\(wearerEnrollmentCompletedPromptCount) current=\(wearerEnrollmentPromptIndex + 1)/\(SpeakerIdentityConfig.wearerVoicePrompts.count)"
    )
  }

  func cancelWearerVoiceEnrollment() {
    wearerEnrollmentSamples.removeAll()
    wearerEnrollmentActive = false
    wearerEnrollmentStartedAt = nil
    wearerEnrollmentPromptIndex = 0
    wearerEnrollmentCompletedPromptCount = 0
    AppLogger.log(.speakerIdentity, "Wearer voice enrollment canceled")
  }

  func wearerVoiceProfileSnapshot() -> WearerVoiceProfileSnapshot {
    let promptCount = SpeakerIdentityConfig.wearerVoicePrompts.count
    let safePromptIndex = min(max(0, wearerEnrollmentPromptIndex), max(0, promptCount - 1))
    return WearerVoiceProfileSnapshot(
      isEnrolled: wearerProfile != nil,
      isRecording: wearerEnrollmentActive,
      recordingSeconds: wearerEnrollmentSeconds,
      sampleCount: wearerProfile?.sampleCount ?? 0,
      centroidCount: wearerCentroidCandidates.count,
      durationSeconds: Double(wearerPreviewSamples.count) / SpeakerIdentityConfig.targetSampleRate,
      consistencyScore: wearerLastConsistencyScore,
      updatedAt: wearerProfile?.updatedAt,
      embeddingDimension: wearerProfile?.vectorDimension,
      promptText: SpeakerIdentityConfig.wearerVoicePrompts[safePromptIndex],
      promptIndex: safePromptIndex,
      promptCount: promptCount,
      completedPromptCount: wearerEnrollmentCompletedPromptCount
    )
  }

  func wearerVoicePreviewSamplesForPlayback() -> [Float] {
    wearerPreviewSamples
  }

  func resetWearerVoiceProfile() {
    wearerProfile = nil
    wearerRecords.removeAll()
    wearerPreviewSamples.removeAll()
    wearerLastConsistencyScore = nil
    wearerAdditionalCentroids.removeAll()
    wearerEnrollmentSamples.removeAll()
    wearerEnrollmentActive = false
    wearerEnrollmentStartedAt = nil
    wearerEnrollmentPromptIndex = 0
    wearerEnrollmentCompletedPromptCount = 0
    saveToDisk()
    AppLogger.log(.speakerIdentity, "Wearer voice profile reset")
  }

  func saveWearerVoiceEnrollment() async -> WearerVoiceEnrollmentResult {
    let samples = wearerEnrollmentSamples
    let seconds = Double(samples.count) / SpeakerIdentityConfig.targetSampleRate
    guard wearerEnrollmentCompletedPromptCount >= SpeakerIdentityConfig.wearerVoiceMinCompletedPrompts else {
      return .failure("Read at least \(SpeakerIdentityConfig.wearerVoiceMinCompletedPrompts) guided prompts before saving my voice.")
    }
    guard seconds >= SpeakerIdentityConfig.wearerVoiceMinEnrollmentSeconds else {
      return .failure(String(
        format: "Keep recording my voice: %.1f s / %.0f s minimum.",
        seconds,
        SpeakerIdentityConfig.wearerVoiceMinEnrollmentSeconds
      ))
    }

    let windows = fullRegionEmbeddingWindows(from: samples)
    guard windows.count >= SpeakerIdentityConfig.wearerVoiceMinAcceptedWindows else {
      return .failure("Not enough clean speech windows for my voice. Try a longer recording.")
    }

    let embeddings: [VoiceEmbedding]
    do {
      embeddings = try await extractEmbeddings(from: windows, using: iPhoneEmbeddingModel)
    } catch {
      AppLogger.log(.speakerIdentity, "Wearer voice enrollment embedding failed: \(error.localizedDescription)")
      return .failure("Could not create my voice embedding: \(error.localizedDescription)")
    }

    guard let firstCentroid = averageEmbeddings(embeddings) else {
      return .failure("Could not average my voice windows.")
    }
    let scored = embeddings.map { embedding in
      (embedding: embedding, similarity: cosineSimilarity(embedding.vector, firstCentroid.vector))
    }
    let accepted = scored
      .filter { $0.similarity >= SpeakerIdentityConfig.wearerVoiceMinWindowCentroidSimilarity }
      .map(\.embedding)
    let rejectedCount = scored.count - accepted.count
    guard accepted.count >= SpeakerIdentityConfig.wearerVoiceMinAcceptedWindows else {
      let bestConsistency = scored.map(\.similarity).reduce(0, +) / Float(max(scored.count, 1))
      return .failure(
        String(format: "My voice recording is inconsistent (%.2f). Re-record in a quieter room.", bestConsistency),
        acceptedWindowCount: accepted.count,
        rejectedWindowCount: rejectedCount,
        consistencyScore: bestConsistency
      )
    }

    guard let finalCentroid = averageEmbeddings(accepted) else {
      return .failure("Could not build final my voice profile.")
    }
    let consistency = accepted
      .map { cosineSimilarity($0.vector, finalCentroid.vector) }
      .reduce(0, +) / Float(max(accepted.count, 1))
    guard consistency >= SpeakerIdentityConfig.wearerVoiceMinConsistency else {
      return .failure(
        String(format: "My voice recording is not stable enough (%.2f). Re-record with steady speech.", consistency),
        acceptedWindowCount: accepted.count,
        rejectedWindowCount: rejectedCount,
        consistencyScore: consistency
      )
    }

    let previousProfile = wearerProfile
    let previousRecords = wearerRecords
    let previousPreview = wearerPreviewSamples
    let previousConsistency = wearerLastConsistencyScore
    let previousAdditionalCentroids = wearerAdditionalCentroids
    let previousClips = capturedVoiceClips

    let now = Date()
    wearerRecords = accepted.map { SpeakerEmbeddingRecord(embedding: $0, personId: Self.wearerPersonId) }
    wearerProfile = SpeakerAveragedEmbedding(
      id: previousProfile?.id ?? UUID(),
      personId: Self.wearerPersonId,
      name: "Me",
      averagedVector: finalCentroid.vector,
      vectorDimension: finalCentroid.dimension,
      sampleCount: accepted.count,
      modelName: finalCentroid.modelName,
      modelVersion: finalCentroid.modelVersion,
      preprocessingVersion: finalCentroid.preprocessingVersion,
      updatedAt: now
    )
    let maxPreviewSamples = Int(SpeakerIdentityConfig.maxSpeechBufferSeconds * SpeakerIdentityConfig.targetSampleRate)
    wearerPreviewSamples = Array(samples.suffix(maxPreviewSamples))
    wearerLastConsistencyScore = consistency
    wearerEnrollmentSamples.removeAll()
    wearerEnrollmentActive = false
    wearerEnrollmentStartedAt = nil
    wearerEnrollmentPromptIndex = 0
    wearerEnrollmentCompletedPromptCount = 0
    if let previousProfile {
      wearerAdditionalCentroids.insert(previousProfile, at: 0)
      wearerAdditionalCentroids = Array(wearerAdditionalCentroids.prefix(SpeakerIdentityConfig.wearerVoiceCentroidLimit - 1))
    }

    capturedVoiceClips.removeAll { clip in
      guard let embedding = clip.embedding,
            embedding.dimension == finalCentroid.dimension,
            embedding.modelName == finalCentroid.modelName,
            embedding.modelVersion == finalCentroid.modelVersion,
            embedding.preprocessingVersion == finalCentroid.preprocessingVersion else {
        return false
      }
      return cosineSimilarity(embedding.vector, finalCentroid.vector) >= SpeakerIdentityConfig.wearerVoiceMatchThreshold
    }

    guard saveToDisk() else {
      wearerProfile = previousProfile
      wearerRecords = previousRecords
      wearerPreviewSamples = previousPreview
      wearerLastConsistencyScore = previousConsistency
      wearerAdditionalCentroids = previousAdditionalCentroids
      capturedVoiceClips = previousClips
      return .failure("My voice profile could not be saved to disk.")
    }

    AppLogger.log(
      .speakerIdentity,
      "Saved wearer voice profile acceptedWindows=\(accepted.count) rejectedWindows=\(rejectedCount) consistency=\(String(format: "%.3f", consistency)) seconds=\(String(format: "%.1f", seconds))"
    )
    return .success(
      acceptedWindowCount: accepted.count,
      rejectedWindowCount: rejectedCount,
      consistencyScore: consistency
    )
  }

  func enroll(name: String, personId: UUID) async {
    guard speechBufferSeconds >= SpeakerIdentityConfig.minSpeechSecondsForEmbedding else {
      AppLogger.log(.speakerIdentity, "Enrollment skipped: insufficient speech \(String(format: "%.1f", speechBufferSeconds))s < \(SpeakerIdentityConfig.minSpeechSecondsForEmbedding)s")
      return
    }
    guard let embedding = await extractEmbedding() else { return }
    let record = SpeakerEmbeddingRecord(embedding: embedding, personId: personId)
    enrolledRecords.append(record)
    updateCentroid(for: personId, name: name)
    // Save a raw audio snippet (up to 5s) so the dictionary can play it back.
    let maxPreviewSamples = Int(SpeakerIdentityConfig.maxSpeechBufferSeconds * SpeakerIdentityConfig.targetSampleRate)
    enrolledPreviewSamples[personId] = Array(speechBuffer.suffix(maxPreviewSamples))
    speechBuffer.removeAll()
    AppLogger.log(.speakerIdentity, "Enrolled speaker personId=\(personId) name=\(name) dim=\(embedding.dimension)")
    saveToDisk()
  }

  // Enrolls a speaker from raw WAV audio data downloaded from the cloud diarization clip.
  func enrollFromAudioData(_ data: Data, personId: UUID, name: String) async {
    // Decode WAV → float samples and fill speechBuffer so extractEmbedding() can run.
    let samples = Self.floatSamples(fromWAV: data)
    guard samples.count >= SpeakerIdentityConfig.embeddingWindowSamples else {
      AppLogger.log(.speakerIdentity, "enrollFromAudioData: clip too short (\(samples.count) samples)")
      return
    }
    let prev = speechBuffer
    speechBuffer = samples
    guard let embedding = await extractEmbedding() else {
      speechBuffer = prev
      return
    }
    speechBuffer = prev
    let record = SpeakerEmbeddingRecord(embedding: embedding, personId: personId)
    enrolledRecords.append(record)
    updateCentroid(for: personId, name: name)
    saveToDisk()
    AppLogger.log(.speakerIdentity, "enrollFromAudioData: enrolled personId=\(personId) name=\(name) dim=\(embedding.dimension)")
  }

  private static func floatSamples(fromWAV data: Data) -> [Float] {
    // WAV PCM 16-bit LE has a 44-byte header; convert int16 → float in [-1, 1]
    guard data.count > 44 else { return [] }
    let pcmData = data.dropFirst(44)
    var samples = [Float](repeating: 0, count: pcmData.count / 2)
    pcmData.withUnsafeBytes { ptr in
      guard let base = ptr.bindMemory(to: Int16.self).baseAddress else { return }
      for i in 0..<samples.count {
        samples[i] = Float(base[i]) / 32768.0
      }
    }
    return samples
  }

  func saveFirstCapturedVoiceClip(personId: UUID, name: String) async -> SpeakerEnrollmentSaveResult {
    guard let clip = capturedVoiceClips.first else {
      AppLogger.log(.speakerIdentity, "Voice clip save skipped: no captured voice clip")
      return .failure("No captured voice clip to save.", personId: personId)
    }
    return await saveCapturedVoiceClip(id: clip.id, personId: personId, name: name)
  }

  func saveCapturedVoiceClip(id: UUID, personId: UUID, name: String) async -> SpeakerEnrollmentSaveResult {
    guard let index = capturedVoiceClips.firstIndex(where: { $0.id == id }) else {
      AppLogger.log(.speakerIdentity, "Voice clip save skipped: clip not found id=\(id.uuidString)")
      return .failure("Captured voice clip was not found.", personId: personId)
    }
    let clip = capturedVoiceClips[index]
    let clipEmbedding: VoiceEmbedding?
    if let existingEmbedding = clip.embedding {
      clipEmbedding = existingEmbedding
    } else {
      clipEmbedding = await extractEmbedding(fromSamples: clip.samples, using: iPhoneEmbeddingModel, label: "iPhoneClip")
    }
    guard let embedding = clipEmbedding else {
      AppLogger.log(.speakerIdentity, "Voice clip save skipped: embedding unavailable id=\(id.uuidString)")
      return .failure("Could not create a voice embedding for this clip.", personId: personId)
    }
    guard isCompatible(
      modelName: embedding.modelName,
      modelVersion: embedding.modelVersion,
      preprocessingVersion: embedding.preprocessingVersion,
      dimension: embedding.dimension
    ) else {
      AppLogger.log(.speakerIdentity, "Voice clip save skipped: incompatible embedding id=\(id.uuidString) model=\(embedding.modelName) version=\(embedding.modelVersion) preprocessing=\(embedding.preprocessingVersion) dim=\(embedding.dimension)")
      return .failure("Voice embedding is incompatible with the current model. Re-capture this voice.", personId: personId)
    }
    let previousSpeakers = enrolledSpeakers
    let previousRecords = enrolledRecords
    let previousPreviews = enrolledPreviewSamples
    let record = SpeakerEmbeddingRecord(embedding: embedding, personId: personId)
    enrolledRecords.append(record)
    updateCentroid(for: personId, name: name)
    guard enrolledSpeakers.contains(where: { $0.personId == personId }) else {
      enrolledRecords = previousRecords
      AppLogger.log(.speakerIdentity, "Voice clip save skipped: centroid was not created personId=\(personId.uuidString)")
      return .failure("Voice enrollment failed before creating a speaker profile.", personId: personId)
    }
    enrolledPreviewSamples[personId] = clip.samples
    guard saveToDisk() else {
      enrolledSpeakers = previousSpeakers
      enrolledRecords = previousRecords
      enrolledPreviewSamples = previousPreviews
      return .failure("Voice enrollment could not be saved to disk.", personId: personId)
    }
    let previousClipCount = capturedVoiceClips.count
    capturedVoiceClips.removeAll { queuedClip in
      if queuedClip.id == id || queuedClip.recognizedPersonId == personId {
        return true
      }
      guard let queuedEmbedding = queuedClip.embedding,
            queuedEmbedding.dimension == embedding.dimension,
            queuedEmbedding.modelName == embedding.modelName,
            queuedEmbedding.modelVersion == embedding.modelVersion,
            queuedEmbedding.preprocessingVersion == embedding.preprocessingVersion else {
        return false
      }
      return cosineSimilarity(embedding.vector, queuedEmbedding.vector) >= SpeakerIdentityConfig.capturedVoiceSameSpeakerThreshold
    }
    let removedClipCount = previousClipCount - capturedVoiceClips.count
    AppLogger.log(.speakerIdentity, "Saved captured voice clip personId=\(personId.uuidString) name=\(name) seconds=\(String(format: "%.1f", Double(clip.samples.count) / SpeakerIdentityConfig.targetSampleRate)) dim=\(embedding.dimension) removedDuplicateClips=\(max(0, removedClipCount - 1))")
    return .success(
      personId: personId,
      name: name,
      removedDuplicateClipCount: max(0, removedClipCount - 1)
    )
  }

  func ignoreFirstCapturedVoiceClip() {
    guard !capturedVoiceClips.isEmpty else { return }
    let clip = capturedVoiceClips.removeFirst()
    AppLogger.log(.speakerIdentity, "Ignored captured voice clip id=\(clip.id.uuidString) seconds=\(String(format: "%.1f", Double(clip.samples.count) / SpeakerIdentityConfig.targetSampleRate))")
  }

  func capturedVoiceClipSnapshots() -> [CapturedVoiceClipSnapshot] {
    capturedVoiceClips.map { clip in
      CapturedVoiceClipSnapshot(
        id: clip.id,
        durationSeconds: Double(clip.samples.count) / SpeakerIdentityConfig.targetSampleRate,
        embeddingDimension: clip.embedding?.dimension,
        createdAt: clip.createdAt,
        status: clip.status,
        speakerLabel: clip.speakerLabel,
        mergedSegmentCount: clip.mergedSegmentCount,
        bestSimilarity: clip.bestSimilarity,
        recognizedPersonId: clip.recognizedPersonId,
        recognizedPersonName: clip.recognizedPersonName
      )
    }
  }

  func resetEnrollment(for personId: UUID) {
    enrolledRecords.removeAll { $0.personId == personId }
    enrolledSpeakers.removeAll { $0.personId == personId }
    enrolledPreviewSamples.removeValue(forKey: personId)
    capturedVoiceClips.removeAll { $0.recognizedPersonId == personId }
    confirmor.reset()
    AppLogger.log(.speakerIdentity, "Enrollment reset personId=\(personId)")
    saveToDisk()
  }

  func voicePreviewSamples(for personId: UUID) -> [Float] {
    enrolledPreviewSamples[personId] ?? []
  }

  func voicePreviewSamplesForCapturedClip(id: UUID) -> [Float] {
    capturedVoiceClips.first { $0.id == id }?.samples ?? []
  }

  func hasVoicePreview(for personId: UUID) -> Bool {
    !(enrolledPreviewSamples[personId]?.isEmpty ?? true)
  }

  func enrolledPersonIds() -> Set<UUID> {
    Set(enrolledSpeakers.map { $0.personId })
  }

  func hasSpeakerEnrollment(for personId: UUID) -> Bool {
    enrolledSpeakers.contains { $0.personId == personId }
  }

  func sampleCountForPerson(_ personId: UUID) -> Int {
    enrolledSpeakers.first { $0.personId == personId }?.sampleCount ?? 0
  }

  var currentSpeechBufferSeconds: Double { speechBufferSeconds }

  // True when speech was detected recently (within silenceFlushSeconds), used to show
  // live VAD activity in the HUD without flickering on natural pauses.
  var isCurrentlySpeaking: Bool {
    guard let last = lastSpeechAt else { return false }
    return Date().timeIntervalSince(last) < SpeakerIdentityConfig.silenceFlushSeconds
  }

  // Returns a copy of the current speech buffer (16 kHz mono float32) for preview playback.
  func currentSpeechBufferForPlayback() -> [Float] { speechBuffer }

  var activeState: SpeakerIdentityState { confirmor.currentState }

  func resetRuntimeState(reason: String) {
    speechBuffer.removeAll()
    lastCapturedVoiceClipAt = nil
    lastSpeechAt = nil
    lastEmbeddedAt = nil
    embeddingInFlight = false
    currentSpeechStartedAt = nil
    openDiarizationSegmentId = nil
    diarizationClusters.removeAll()
    diarizationSegments.removeAll()
    nextUnknownSpeakerNumber = 1
    confirmor.reset()
    AppLogger.log(.speakerIdentity, "Runtime state reset reason=\(reason)")
  }

  func diarizationSegmentsSnapshot() -> [SpeakerDiarizationSegmentSnapshot] {
    diarizationSegments.sorted { $0.startAt < $1.startAt }
  }

  // MARK: - Private helpers

  private func runEmbeddingAndMatch(
    now: Date,
    segmentStartAt: Date,
    segmentEndAt: Date,
    finalSegment: Bool
  ) async -> SpeakerProcessingResult {
    guard !embeddingInFlight else {
      return SpeakerProcessingResult(
        activeIdentity: confirmor.currentState,
        vadDecision: "embeddingInFlight",
        accumulatedSpeechSeconds: speechBufferSeconds,
        embeddingTriggered: false,
        matchResult: nil
      )
    }
	    embeddingInFlight = true
	    lastEmbeddedAt = now
	    defer { embeddingInFlight = false }
	
	    let speechSamplesSnapshot = speechBuffer
	    let iPhoneDiagnostic = await similarityDiagnostic(
	      using: iPhoneEmbeddingModel,
	      label: "iPhone",
	      samples: speechSamplesSnapshot
	    )
	    let workerDiagnostic: SpeakerSimilarityDiagnostic? = nil
    let wearerMatch = iPhoneDiagnostic.embedding.map(matchWearerEmbedding)
    if let wearerEmbedding = iPhoneDiagnostic.embedding,
       let wearerMatch,
       wearerMatch.decision == .known {
      if finalSegment {
        updateWearerRecentCentroidIfHighConfidence(
          embedding: wearerEmbedding,
          similarity: wearerMatch.bestSimilarity,
          now: now
        )
      }
      let diarizationSegment = upsertWearerDiarizationSegment(
        now: now,
        startAt: segmentStartAt,
        endAt: segmentEndAt,
        similarity: wearerMatch.bestSimilarity,
        finalSegment: finalSegment
      )
      let wearerState = SpeakerIdentityState(
        personId: nil,
        displayName: "Me",
        confidence: wearerMatch.bestSimilarity,
        phase: .confirmed,
        confirmedAt: now,
        lastMatchAt: now
      )
      AppLogger.log(
        .speakerMatch,
        "wearerVoiceMatch similarity=\(String(format: "%.3f", wearerMatch.bestSimilarity)) suppressedCapturedVoice=true"
      )
      AppLogger.log(
        .speakerMatch,
        "diarization segment=\(diarizationSegment.id.uuidString) speaker=\(diarizationSegment.speakerName) confidence=\(String(format: "%.3f", diarizationSegment.confidence)) final=\(finalSegment) start=\(diarizationSegment.startAt.timeIntervalSince1970) end=\(diarizationSegment.endAt.timeIntervalSince1970)"
      )
      return SpeakerProcessingResult(
        activeIdentity: wearerState,
        vadDecision: "wearerSpeech",
        accumulatedSpeechSeconds: speechBufferSeconds,
        embeddingTriggered: true,
        matchResult: wearerMatch,
        iPhoneSimilarity: iPhoneDiagnostic,
        workerSimilarity: workerDiagnostic,
        wearerSimilarity: wearerMatch
      )
    }
    let primaryMatch = iPhoneDiagnostic.matchResult
    let diarizationSegment = iPhoneDiagnostic.embedding.flatMap { embedding in
      upsertDiarizationSegment(
        embedding: embedding,
        match: primaryMatch,
        now: now,
        startAt: segmentStartAt,
        endAt: segmentEndAt,
        finalSegment: finalSegment
      )
    }
    captureVoiceClipIfNeeded(
      now: now,
      embedding: iPhoneDiagnostic.embedding,
      samples: speechSamplesSnapshot,
      speakerLabel: diarizationSegment?.speakerName
    )

    guard let match = primaryMatch else {
      return SpeakerProcessingResult(
        activeIdentity: confirmor.currentState,
        vadDecision: "speech",
        accumulatedSpeechSeconds: speechBufferSeconds,
        embeddingTriggered: true,
        matchResult: nil,
        iPhoneSimilarity: iPhoneDiagnostic,
        workerSimilarity: workerDiagnostic,
        wearerSimilarity: wearerMatch
      )
    }

    let profile = enrolledSpeakers.first { $0.personId == match.bestPersonId }
    let newState = confirmor.update(match: match, displayName: profile?.name, now: now)

    AppLogger.log(
      .speakerMatch,
      "decision=\(match.decision) similarity=\(String(format: "%.3f", match.bestSimilarity)) " +
      "personId=\(match.bestPersonId?.uuidString ?? "nil") state=\(newState.phase.rawValue)"
    )
    AppLogger.log(
      .speakerMatch,
      "dualSimilarity iPhone=\(iPhoneDiagnostic.statusText) worker=disabled"
    )
    if let diarizationSegment {
      AppLogger.log(
        .speakerMatch,
        "diarization segment=\(diarizationSegment.id.uuidString) speaker=\(diarizationSegment.speakerName) confidence=\(String(format: "%.3f", diarizationSegment.confidence)) final=\(finalSegment) start=\(diarizationSegment.startAt.timeIntervalSince1970) end=\(diarizationSegment.endAt.timeIntervalSince1970)"
      )
    }

    return SpeakerProcessingResult(
      activeIdentity: newState,
      vadDecision: "speech",
      accumulatedSpeechSeconds: speechBufferSeconds,
      embeddingTriggered: true,
      matchResult: match,
      iPhoneSimilarity: iPhoneDiagnostic,
      workerSimilarity: workerDiagnostic,
      wearerSimilarity: wearerMatch
    )
  }

  private func upsertDiarizationSegment(
    embedding: VoiceEmbedding,
    match: SpeakerMatchResult?,
    now: Date,
    startAt: Date,
    endAt: Date,
    finalSegment: Bool
  ) -> SpeakerDiarizationSegmentSnapshot? {
    let duration = max(0, endAt.timeIntervalSince(startAt))
    let assignment = assignDiarizationCluster(
      embedding: embedding,
      match: match,
      now: now,
      segmentDuration: duration
    )
    let segmentId = openDiarizationSegmentId ?? UUID()
    openDiarizationSegmentId = finalSegment ? openDiarizationSegmentId : segmentId

    let source = [
      "diarization",
      "speakerLabel=\(safeEvidenceValue(assignment.cluster.label))",
      "cluster=\(assignment.cluster.id.uuidString)",
      "voice=\(String(format: "%.3f", assignment.confidence))",
      "known=\(assignment.cluster.personId != nil)",
      "final=\(finalSegment)"
    ].joined(separator: ";")

    let segment = SpeakerDiarizationSegmentSnapshot(
      id: segmentId,
      startAt: startAt,
      endAt: max(endAt, startAt),
      speakerId: assignment.cluster.id,
      speakerLabel: assignment.cluster.label,
      personId: assignment.cluster.personId,
      displayName: assignment.cluster.displayName,
      confidence: assignment.confidence,
      source: source
    )
    if let index = diarizationSegments.firstIndex(where: { $0.id == segmentId }) {
      diarizationSegments[index] = segment
    } else {
      diarizationSegments.append(segment)
    }
    return segment
  }

  private func upsertWearerDiarizationSegment(
    now: Date,
    startAt: Date,
    endAt: Date,
    similarity: Float,
    finalSegment: Bool
  ) -> SpeakerDiarizationSegmentSnapshot {
    let segmentId = openDiarizationSegmentId ?? UUID()
    openDiarizationSegmentId = finalSegment ? openDiarizationSegmentId : segmentId
    let segment = SpeakerDiarizationSegmentSnapshot(
      id: segmentId,
      startAt: startAt,
      endAt: max(endAt, startAt),
      speakerId: Self.wearerPersonId,
      speakerLabel: "Me",
      personId: nil,
      displayName: "Me",
      confidence: similarity,
      source: "wearerVoice;voice=\(String(format: "%.3f", similarity));final=\(finalSegment)"
    )
    if let index = diarizationSegments.firstIndex(where: { $0.id == segmentId }) {
      diarizationSegments[index] = segment
    } else {
      diarizationSegments.append(segment)
    }
    return segment
  }

  private func assignDiarizationCluster(
    embedding: VoiceEmbedding,
    match: SpeakerMatchResult?,
    now: Date,
    segmentDuration: Double
  ) -> (cluster: DiarizationCluster, confidence: Float) {
    let knownPersonId = usableKnownPersonId(from: match)
    let knownName = knownPersonId.flatMap { personId in
      enrolledSpeakers.first { $0.personId == personId }?.name
    }

    if let knownPersonId {
      if let index = diarizationClusters.firstIndex(where: { $0.personId == knownPersonId }) {
        let confidence = max(match?.bestSimilarity ?? 0, cosineSimilarity(embedding.vector, diarizationClusters[index].centroid))
        return (updateDiarizationCluster(
          at: index,
          embedding: embedding,
          personId: knownPersonId,
          displayName: knownName,
          now: now,
          segmentDuration: segmentDuration,
          confidence: confidence
        ), confidence)
      }

      if let nearest = nearestDiarizationCluster(to: embedding),
         nearest.similarity >= SpeakerIdentityConfig.diarizationSameSpeakerThreshold,
         diarizationClusters[nearest.index].personId == nil {
        let confidence = max(match?.bestSimilarity ?? 0, nearest.similarity)
        return (updateDiarizationCluster(
          at: nearest.index,
          embedding: embedding,
          personId: knownPersonId,
          displayName: knownName,
          now: now,
          segmentDuration: segmentDuration,
          confidence: confidence
        ), confidence)
      }

      let cluster = createDiarizationCluster(
        embedding: embedding,
        personId: knownPersonId,
        displayName: knownName,
        now: now,
        segmentDuration: segmentDuration
      )
      return (cluster, match?.bestSimilarity ?? SpeakerIdentityConfig.strongMatchThreshold)
    }

    if let nearest = nearestDiarizationCluster(to: embedding),
       nearest.similarity >= SpeakerIdentityConfig.diarizationSameSpeakerThreshold {
      return (updateDiarizationCluster(
        at: nearest.index,
        embedding: embedding,
        personId: nil,
        displayName: nil,
        now: now,
        segmentDuration: segmentDuration,
        confidence: nearest.similarity
      ), nearest.similarity)
    }

    let cluster = createDiarizationCluster(
      embedding: embedding,
      personId: nil,
      displayName: nil,
      now: now,
      segmentDuration: segmentDuration
    )
    return (cluster, 0.50)
  }

  private func usableKnownPersonId(from match: SpeakerMatchResult?) -> UUID? {
    guard let match, let personId = match.bestPersonId else { return nil }
    switch match.decision {
    case .known:
      return personId
    case .ambiguous:
      return match.bestSimilarity >= SpeakerIdentityConfig.weakMatchThreshold ? personId : nil
    case .unknown:
      return nil
    }
  }

  private func nearestDiarizationCluster(to embedding: VoiceEmbedding) -> (index: Int, similarity: Float)? {
    var best: (index: Int, similarity: Float)?
    for index in diarizationClusters.indices {
      let similarity = cosineSimilarity(embedding.vector, diarizationClusters[index].centroid)
      if best == nil || similarity > best!.similarity {
        best = (index, similarity)
      }
    }
    return best
  }

  private func createDiarizationCluster(
    embedding: VoiceEmbedding,
    personId: UUID?,
    displayName: String?,
    now: Date,
    segmentDuration: Double
  ) -> DiarizationCluster {
    let label: String
    if let displayName, !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      label = displayName
    } else {
      label = "Speaker \(nextUnknownSpeakerNumber)"
      nextUnknownSpeakerNumber += 1
    }
    let cluster = DiarizationCluster(
      id: UUID(),
      label: label,
      personId: personId,
      displayName: displayName,
      centroid: embedding.vector,
      segmentCount: 1,
      totalSpeechSeconds: segmentDuration,
      lastSeenAt: now
    )
    diarizationClusters.append(cluster)
    return cluster
  }

  private func updateDiarizationCluster(
    at index: Int,
    embedding: VoiceEmbedding,
    personId: UUID?,
    displayName: String?,
    now: Date,
    segmentDuration: Double,
    confidence: Float
  ) -> DiarizationCluster {
    var cluster = diarizationClusters[index]
    if let personId {
      cluster.personId = personId
      cluster.displayName = displayName
      if let displayName, !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        cluster.label = displayName
      }
    }
    let alpha = confidence >= SpeakerIdentityConfig.diarizationUpdateThreshold
      ? SpeakerIdentityConfig.diarizationCentroidAlpha
      : 0.96
    cluster.centroid = blendAndNormalize(cluster.centroid, embedding.vector, alpha: alpha)
    cluster.segmentCount += 1
    cluster.totalSpeechSeconds += segmentDuration
    cluster.lastSeenAt = now
    diarizationClusters[index] = cluster
    return cluster
  }

  private func blendAndNormalize(_ old: [Float], _ new: [Float], alpha: Float) -> [Float] {
    guard old.count == new.count, !old.isEmpty else { return new }
    var blended = [Float](repeating: 0, count: old.count)
    for i in old.indices {
      blended[i] = (alpha * old[i]) + ((1 - alpha) * new[i])
    }
    let norm = sqrt(blended.reduce(0) { $0 + $1 * $1 })
    guard norm > 1e-6, norm.isFinite else { return old }
    return blended.map { $0 / norm }
  }

  private func safeEvidenceValue(_ value: String) -> String {
    value.replacingOccurrences(of: ";", with: ",")
  }

  private func extractEmbedding() async -> VoiceEmbedding? {
    let windows = embeddingWindows(from: speechBuffer)
    guard !windows.isEmpty else {
      AppLogger.log(.speakerEmbedding, "Embedding skipped: insufficient speech samples=\(speechBuffer.count) required=\(SpeakerIdentityConfig.embeddingWindowSamples)")
      return nil
    }

    do {
      return try await extractEmbedding(from: windows, using: embeddingModel, label: "active")
    } catch {
      AppLogger.log(.speakerEmbedding, "Embedding failed: \(error.localizedDescription)")
      return nil
    }
  }

	  private func similarityDiagnostic(
	    using model: SpeakerEmbeddingModel,
	    label: String,
	    samples: [Float]
	  ) async -> SpeakerSimilarityDiagnostic {
	    let windows = embeddingWindows(from: samples)
    guard !windows.isEmpty else {
      return SpeakerSimilarityDiagnostic(label: label, matchResult: nil, error: "insufficient speech", embedding: nil)
    }

    do {
      let embedding = try await extractEmbedding(from: windows, using: model, label: label)
      let match = matchEmbedding(embedding)
      AppLogger.log(
        .speakerMatch,
        "\(label) cosineSimilarity=\(String(format: "%.3f", match.bestSimilarity)) decision=\(match.decision) personId=\(match.bestPersonId?.uuidString ?? "nil") reason=\(match.reason ?? "none")"
      )
      return SpeakerSimilarityDiagnostic(label: label, matchResult: match, error: nil, embedding: embedding)
    } catch {
      let message = error.localizedDescription
      AppLogger.log(.speakerEmbedding, "\(label) embedding failed: \(message)")
      return SpeakerSimilarityDiagnostic(label: label, matchResult: nil, error: message, embedding: nil)
    }
  }

  private func extractEmbedding(
    fromSamples samples: [Float],
    using model: SpeakerEmbeddingModel,
    label: String
  ) async -> VoiceEmbedding? {
    let windows = embeddingWindows(from: samples)
    guard !windows.isEmpty else { return nil }
    do {
      return try await extractEmbedding(from: windows, using: model, label: label)
    } catch {
      AppLogger.log(.speakerEmbedding, "\(label) embedding failed for captured clip: \(error.localizedDescription)")
      return nil
    }
  }

  private func captureVoiceClipIfNeeded(
    now: Date,
    embedding: VoiceEmbedding?,
    samples: [Float],
    speakerLabel: String?
  ) {
    let sampleSeconds = Double(samples.count) / SpeakerIdentityConfig.targetSampleRate
    guard sampleSeconds >= SpeakerIdentityConfig.minSpeechSecondsForEmbedding else { return }
    if let lastCapturedVoiceClipAt,
       now.timeIntervalSince(lastCapturedVoiceClipAt) < SpeakerIdentityConfig.minSpeechSecondsForEmbedding {
      return
    }
    let maxSamples = Int(SpeakerIdentityConfig.maxSpeechBufferSeconds * SpeakerIdentityConfig.targetSampleRate)
    let samples = Array(samples.suffix(maxSamples))
    guard Double(samples.count) / SpeakerIdentityConfig.targetSampleRate >= SpeakerIdentityConfig.minSpeechSecondsForEmbedding else { return }
    if let wearerMatch = embedding.map(matchWearerEmbedding),
       wearerMatch.decision == .known {
      AppLogger.log(
        .speakerIdentity,
        "Captured voice skipped because it matches wearer profile similarity=\(String(format: "%.3f", wearerMatch.bestSimilarity))"
      )
      return
    }

    let knownMatch = embedding.map(matchEmbedding)
    let recognizedPersonId = knownMatch?.decision == .known ? knownMatch?.bestPersonId : nil
    let recognizedPersonName = recognizedPersonId.flatMap { personId in
      enrolledSpeakers.first { $0.personId == personId }?.name
    }

    if let mergeIndex = capturedVoiceClipMergeIndex(
      for: embedding,
      recognizedPersonId: recognizedPersonId
    ) {
      mergeCapturedVoiceClip(
        at: mergeIndex,
        now: now,
        embedding: embedding,
        samples: samples,
        speakerLabel: speakerLabel,
        match: knownMatch,
        recognizedPersonId: recognizedPersonId,
        recognizedPersonName: recognizedPersonName
      )
      lastCapturedVoiceClipAt = now
      return
    }

    let clip = CapturedVoiceClip(
      id: UUID(),
      samples: samples,
      embedding: embedding,
      createdAt: now,
      updatedAt: now,
      status: recognizedPersonId == nil ? (embedding == nil ? "previewOnly" : "embedded") : "recognized",
      speakerLabel: recognizedPersonName ?? speakerLabel,
      mergedSegmentCount: 1,
      bestSimilarity: knownMatch?.bestSimilarity,
      recognizedPersonId: recognizedPersonId,
      recognizedPersonName: recognizedPersonName
    )
    capturedVoiceClips.append(clip)
    if capturedVoiceClips.count > maxCapturedVoiceClips {
      capturedVoiceClips = Array(capturedVoiceClips.suffix(maxCapturedVoiceClips))
    }
    lastCapturedVoiceClipAt = now
    AppLogger.log(.speakerIdentity, "Captured voice clip id=\(clip.id.uuidString) seconds=\(String(format: "%.1f", Double(samples.count) / SpeakerIdentityConfig.targetSampleRate)) status=\(clip.status) recognized=\(clip.recognizedPersonName ?? "none") count=\(capturedVoiceClips.count)")
  }

  private func capturedVoiceClipMergeIndex(
    for embedding: VoiceEmbedding?,
    recognizedPersonId: UUID?
  ) -> Int? {
    if let recognizedPersonId,
       let index = capturedVoiceClips.firstIndex(where: { $0.recognizedPersonId == recognizedPersonId }) {
      return index
    }
    guard let embedding else { return nil }
    return capturedVoiceClips
      .enumerated()
      .compactMap { index, clip -> (Int, Float)? in
        guard let clipEmbedding = clip.embedding,
              clipEmbedding.dimension == embedding.dimension,
              clipEmbedding.modelName == embedding.modelName,
              clipEmbedding.modelVersion == embedding.modelVersion,
              clipEmbedding.preprocessingVersion == embedding.preprocessingVersion else {
          return nil
        }
        return (index, cosineSimilarity(embedding.vector, clipEmbedding.vector))
      }
      .filter { $0.1 >= SpeakerIdentityConfig.capturedVoiceDefiniteSameSpeakerThreshold }
      .max { $0.1 < $1.1 }?
      .0
  }

  private func mergeCapturedVoiceClip(
    at index: Int,
    now: Date,
    embedding: VoiceEmbedding?,
    samples: [Float],
    speakerLabel: String?,
    match: SpeakerMatchResult?,
    recognizedPersonId: UUID?,
    recognizedPersonName: String?
  ) {
    guard capturedVoiceClips.indices.contains(index) else { return }
    let incomingSeconds = Double(samples.count) / SpeakerIdentityConfig.targetSampleRate
    let existingSeconds = Double(capturedVoiceClips[index].samples.count) / SpeakerIdentityConfig.targetSampleRate
    let sameSpeakerSimilarity = embedding.flatMap { incoming in
      capturedVoiceClips[index].embedding.map { existing in
        cosineSimilarity(incoming.vector, existing.vector)
      }
    }
    let shouldReplacePreview = incomingSeconds > existingSeconds
    if shouldReplacePreview {
      capturedVoiceClips[index].samples = samples
      capturedVoiceClips[index].embedding = embedding ?? capturedVoiceClips[index].embedding
      capturedVoiceClips[index].status = embedding == nil ? "previewOnly" : "embedded"
    } else if capturedVoiceClips[index].embedding == nil, let embedding {
      capturedVoiceClips[index].embedding = embedding
      capturedVoiceClips[index].status = "embedded"
    }
    if capturedVoiceClips[index].speakerLabel == nil || recognizedPersonName != nil {
      capturedVoiceClips[index].speakerLabel = recognizedPersonName ?? speakerLabel
    }
    capturedVoiceClips[index].updatedAt = now
    capturedVoiceClips[index].mergedSegmentCount += 1
    capturedVoiceClips[index].bestSimilarity = [
      capturedVoiceClips[index].bestSimilarity,
      match?.bestSimilarity,
      sameSpeakerSimilarity
    ].compactMap { $0 }.max()
    if let recognizedPersonId {
      capturedVoiceClips[index].recognizedPersonId = recognizedPersonId
      capturedVoiceClips[index].recognizedPersonName = recognizedPersonName
      capturedVoiceClips[index].status = "recognized"
    }
    AppLogger.log(
      .speakerIdentity,
      "Merged captured voice clip id=\(capturedVoiceClips[index].id.uuidString) incomingSeconds=\(String(format: "%.1f", incomingSeconds)) keptSeconds=\(String(format: "%.1f", max(incomingSeconds, existingSeconds))) similarity=\(sameSpeakerSimilarity.map { String(format: "%.3f", $0) } ?? "known") recognized=\(capturedVoiceClips[index].recognizedPersonName ?? "none") merged=\(capturedVoiceClips[index].mergedSegmentCount)"
    )
  }

  private func extractEmbedding(
    from windows: [SpeakerEmbeddingWindow],
    using model: SpeakerEmbeddingModel,
    label: String
  ) async throws -> VoiceEmbedding {
    let embeddings = try await extractEmbeddings(from: windows, using: model)
    guard let averaged = averageEmbeddings(embeddings) else {
      throw SpeakerEmbeddingError.invalidEmbeddingValues("could not average \(embeddings.count) \(label) voice windows")
    }
    AppLogger.log(
      .speakerEmbedding,
      "\(label) Embedded averagedWindows=\(embeddings.count) regionSamples=\(min(speechBuffer.count, SpeakerIdentityConfig.embeddingAggregationSamples)) windowSamples=\(SpeakerIdentityConfig.embeddingWindowSamples) hopSamples=\(SpeakerIdentityConfig.embeddingWindowHopSamples) dim=\(averaged.dimension)"
    )
    return averaged
  }

  private func extractEmbeddings(
    from windows: [SpeakerEmbeddingWindow],
    using model: SpeakerEmbeddingModel
  ) async throws -> [VoiceEmbedding] {
    var embeddings: [VoiceEmbedding] = []
    embeddings.reserveCapacity(windows.count)
    for window in windows {
      let embedding = try await model.embed(
        samples: window.samples,
        sampleRate: SpeakerIdentityConfig.targetSampleRate
      )
      embeddings.append(embedding)
    }
    return embeddings
  }

  private struct SpeakerEmbeddingWindow {
    let startOffset: Int
    let samples: [Float]
  }

  private func embeddingWindows(from samples: [Float]) -> [SpeakerEmbeddingWindow] {
    let windowSamples = SpeakerIdentityConfig.embeddingWindowSamples
    let minDiarizationSamples = Int(SpeakerIdentityConfig.minSpeechSecondsForDiarization * SpeakerIdentityConfig.targetSampleRate)
    guard samples.count >= minDiarizationSamples else { return [] }
    if samples.count < windowSamples {
      var padded = samples
      padded.append(contentsOf: [Float](repeating: 0, count: windowSamples - samples.count))
      return [SpeakerEmbeddingWindow(startOffset: 0, samples: padded)]
    }

    let region = Array(samples.suffix(SpeakerIdentityConfig.embeddingAggregationSamples))
    let maxStart = max(0, region.count - windowSamples)
    var starts = stride(
      from: 0,
      through: maxStart,
      by: SpeakerIdentityConfig.embeddingWindowHopSamples
    ).map { $0 }
    if starts.last != maxStart {
      starts.append(maxStart)
    }

    return starts.map { start in
      let end = min(start + windowSamples, region.count)
      var window = Array(region[start..<end])
      if window.count < windowSamples {
        window.append(contentsOf: [Float](repeating: 0, count: windowSamples - window.count))
      }
      return SpeakerEmbeddingWindow(startOffset: start, samples: window)
    }
  }

  private func fullRegionEmbeddingWindows(from samples: [Float]) -> [SpeakerEmbeddingWindow] {
    let windowSamples = SpeakerIdentityConfig.embeddingWindowSamples
    guard samples.count >= windowSamples else { return embeddingWindows(from: samples) }

    let maxStart = max(0, samples.count - windowSamples)
    var starts = stride(
      from: 0,
      through: maxStart,
      by: SpeakerIdentityConfig.embeddingWindowHopSamples
    ).map { $0 }
    if starts.last != maxStart {
      starts.append(maxStart)
    }
    return starts.map { start in
      let end = min(start + windowSamples, samples.count)
      var window = Array(samples[start..<end])
      if window.count < windowSamples {
        window.append(contentsOf: [Float](repeating: 0, count: windowSamples - window.count))
      }
      return SpeakerEmbeddingWindow(startOffset: start, samples: window)
    }
  }

  private func averageEmbeddings(_ embeddings: [VoiceEmbedding]) -> VoiceEmbedding? {
    guard let first = embeddings.first, first.dimension > 0 else { return nil }
    let dim = first.dimension
    let compatible = embeddings.filter {
      $0.dimension == dim
        && $0.modelName == first.modelName
        && $0.modelVersion == first.modelVersion
        && $0.preprocessingVersion == first.preprocessingVersion
        && $0.vector.count == dim
        && $0.vector.allSatisfy(\.isFinite)
    }
    guard !compatible.isEmpty else { return nil }

    var sum = [Float](repeating: 0, count: dim)
    for embedding in compatible {
      for i in 0..<dim {
        sum[i] += embedding.vector[i]
      }
    }
    let norm = sqrt(sum.reduce(0) { $0 + $1 * $1 })
    guard norm > 1e-6, norm.isFinite else { return nil }
    let averaged = sum.map { $0 / norm }
    return VoiceEmbedding(
      vector: averaged,
      modelName: first.modelName,
      modelVersion: first.modelVersion,
      preprocessingVersion: first.preprocessingVersion
    )
  }

  private func matchEmbedding(_ embedding: VoiceEmbedding) -> SpeakerMatchResult {
    let incompatible = enrolledSpeakers.filter {
      !($0.vectorDimension == embedding.dimension
        && $0.modelName == embedding.modelName
        && $0.modelVersion == embedding.modelVersion
        && $0.preprocessingVersion == embedding.preprocessingVersion)
    }
    if !incompatible.isEmpty {
      let sample = incompatible[0]
      AppLogger.log(
        .speakerMatch,
        "incompatibleEnrollmentCount=\(incompatible.count) liveModel=\(embedding.modelName) liveVersion=\(embedding.modelVersion) livePreprocessing=\(embedding.preprocessingVersion) liveDim=\(embedding.dimension) storedModel=\(sample.modelName) storedVersion=\(sample.modelVersion) storedPreprocessing=\(sample.preprocessingVersion) storedDim=\(sample.vectorDimension)"
      )
    }
    let candidates = enrolledSpeakers
      .filter {
        $0.vectorDimension == embedding.dimension
          && $0.modelName == embedding.modelName
          && $0.modelVersion == embedding.modelVersion
          && $0.preprocessingVersion == embedding.preprocessingVersion
      }
      .map { ($0, cosineSimilarity(embedding.vector, $0.averagedVector)) }
      .sorted { $0.1 > $1.1 }

    guard let best = candidates.first else {
      let reason = enrolledSpeakers.isEmpty ? "noEnrollment" : "noCompatibleEnrollment"
      AppLogger.log(
        .speakerMatch,
        "\(reason) liveModel=\(embedding.modelName) liveVersion=\(embedding.modelVersion) livePreprocessing=\(embedding.preprocessingVersion) liveDim=\(embedding.dimension) enrolled=\(enrolledSpeakers.count)"
      )
      return SpeakerMatchResult(
        bestPersonId: nil, bestSimilarity: 0, secondBestSimilarity: nil,
        margin: nil, decision: .unknown, matchedEmbeddingId: nil,
        reason: reason
      )
    }
    let second = candidates.dropFirst().first?.1
    let margin = second.map { best.1 - $0 }
    let decision: SpeakerMatchResult.Decision
    if best.1 >= SpeakerIdentityConfig.strongMatchThreshold
        && (margin == nil || margin! >= SpeakerIdentityConfig.matchMarginThreshold) {
      decision = .known
    } else if best.1 >= SpeakerIdentityConfig.weakMatchThreshold {
      decision = .ambiguous
    } else {
      decision = .unknown
    }
    return SpeakerMatchResult(
      bestPersonId: best.0.personId, bestSimilarity: best.1,
      secondBestSimilarity: second, margin: margin, decision: decision,
      matchedEmbeddingId: best.0.id,
      reason: decision == .unknown ? "belowThreshold" : nil
    )
  }

  private func matchWearerEmbedding(_ embedding: VoiceEmbedding) -> SpeakerMatchResult {
    let candidates = wearerCentroidCandidates.filter {
      $0.vectorDimension == embedding.dimension
        && $0.modelName == embedding.modelName
        && $0.modelVersion == embedding.modelVersion
        && $0.preprocessingVersion == embedding.preprocessingVersion
    }
    guard let best = candidates
      .map({ ($0, cosineSimilarity(embedding.vector, $0.averagedVector)) })
      .max(by: { $0.1 < $1.1 }) else {
      return SpeakerMatchResult(
        bestPersonId: nil,
        bestSimilarity: 0,
        secondBestSimilarity: nil,
        margin: nil,
        decision: .unknown,
        matchedEmbeddingId: wearerProfile?.id,
        reason: wearerProfile == nil ? "noWearerEnrollment" : "incompatibleWearerEnrollment"
      )
    }

    let similarity = best.1
    let decision: SpeakerMatchResult.Decision = similarity >= SpeakerIdentityConfig.wearerVoiceMatchThreshold
      ? .known
      : .unknown
    return SpeakerMatchResult(
      bestPersonId: Self.wearerPersonId,
      bestSimilarity: similarity,
      secondBestSimilarity: nil,
      margin: nil,
      decision: decision,
      matchedEmbeddingId: best.0.id,
      reason: decision == .known ? "wearer" : "belowWearerThreshold"
    )
  }

  private var wearerCentroidCandidates: [SpeakerAveragedEmbedding] {
    ([wearerProfile].compactMap { $0 } + wearerAdditionalCentroids)
      .filter {
        isCompatible(
          modelName: $0.modelName,
          modelVersion: $0.modelVersion,
          preprocessingVersion: $0.preprocessingVersion,
          dimension: $0.vectorDimension
        )
      }
  }

  private func updateWearerRecentCentroidIfHighConfidence(
    embedding: VoiceEmbedding,
    similarity: Float,
    now: Date
  ) {
    guard similarity >= SpeakerIdentityConfig.wearerVoiceAutoUpdateThreshold else { return }
    guard isCompatible(
      modelName: embedding.modelName,
      modelVersion: embedding.modelVersion,
      preprocessingVersion: embedding.preprocessingVersion,
      dimension: embedding.dimension
    ) else { return }

    if wearerAdditionalCentroids.isEmpty {
      wearerAdditionalCentroids.append(SpeakerAveragedEmbedding(
        id: UUID(),
        personId: Self.wearerPersonId,
        name: "Me recent",
        averagedVector: embedding.vector,
        vectorDimension: embedding.dimension,
        sampleCount: 1,
        modelName: embedding.modelName,
        modelVersion: embedding.modelVersion,
        preprocessingVersion: embedding.preprocessingVersion,
        updatedAt: now
      ))
    } else {
      wearerAdditionalCentroids[0].averagedVector = blendAndNormalize(
        wearerAdditionalCentroids[0].averagedVector,
        embedding.vector,
        alpha: 0.95
      )
      wearerAdditionalCentroids[0].sampleCount += 1
      wearerAdditionalCentroids[0].updatedAt = now
    }
    wearerAdditionalCentroids = Array(wearerAdditionalCentroids.prefix(SpeakerIdentityConfig.wearerVoiceCentroidLimit - 1))
    saveToDisk()
    AppLogger.log(.speakerIdentity, "Wearer recent centroid updated similarity=\(String(format: "%.3f", similarity)) centroids=\(wearerCentroidCandidates.count)")
  }

  private func updateCentroid(for personId: UUID, name: String) {
    let samples = enrolledRecords.filter {
      $0.personId == personId
        && !$0.vector.isEmpty
        && isCompatible(modelName: $0.modelName, modelVersion: $0.modelVersion, preprocessingVersion: $0.preprocessingVersion, dimension: $0.dimension)
    }
    guard !samples.isEmpty else { return }
    let dim = samples[0].dimension
    var sum = [Float](repeating: 0, count: dim)
    for s in samples {
      for i in 0..<dim { sum[i] += s.vector[i] }
    }
    let norm = sqrt(sum.reduce(0) { $0 + $1 * $1 })
    let avg = norm > 1e-6 ? sum.map { $0 / norm } : sum
    if let idx = enrolledSpeakers.firstIndex(where: { $0.personId == personId }) {
      enrolledSpeakers[idx].name = name
      enrolledSpeakers[idx].averagedVector = avg
      enrolledSpeakers[idx].sampleCount = samples.count
      enrolledSpeakers[idx].updatedAt = Date()
    } else {
      let first = samples[0]
      enrolledSpeakers.append(SpeakerAveragedEmbedding(
        id: UUID(), personId: personId, name: name, averagedVector: avg, vectorDimension: dim,
        sampleCount: samples.count, modelName: first.modelName, modelVersion: first.modelVersion,
        preprocessingVersion: first.preprocessingVersion, updatedAt: Date()
      ))
    }
  }

  private func purgeIncompatibleEnrollments(saveAfterPurge: Bool = true) {
    let speakerBefore = enrolledSpeakers.count
    let recordBefore = enrolledRecords.count
    let hadWearerProfile = wearerProfile != nil
    let wearerRecordBefore = wearerRecords.count
    let wearerCentroidBefore = wearerAdditionalCentroids.count
    enrolledSpeakers.removeAll {
      !isCompatible(
        modelName: $0.modelName,
        modelVersion: $0.modelVersion,
        preprocessingVersion: $0.preprocessingVersion,
        dimension: $0.vectorDimension
      )
    }
    enrolledRecords.removeAll {
      !isCompatible(
        modelName: $0.modelName,
        modelVersion: $0.modelVersion,
        preprocessingVersion: $0.preprocessingVersion,
        dimension: $0.dimension
      )
    }
    let validPersonIds = Set(enrolledSpeakers.map(\.personId))
    enrolledPreviewSamples = enrolledPreviewSamples.filter { validPersonIds.contains($0.key) }
    if let profile = wearerProfile,
       !isCompatible(
        modelName: profile.modelName,
        modelVersion: profile.modelVersion,
        preprocessingVersion: profile.preprocessingVersion,
        dimension: profile.vectorDimension
       ) {
      wearerProfile = nil
      wearerPreviewSamples.removeAll()
      wearerLastConsistencyScore = nil
    }
    wearerRecords.removeAll {
      !isCompatible(
        modelName: $0.modelName,
        modelVersion: $0.modelVersion,
        preprocessingVersion: $0.preprocessingVersion,
        dimension: $0.dimension
      )
    }
    wearerAdditionalCentroids.removeAll {
      !isCompatible(
        modelName: $0.modelName,
        modelVersion: $0.modelVersion,
        preprocessingVersion: $0.preprocessingVersion,
        dimension: $0.vectorDimension
      )
    }
    let removedSpeakers = speakerBefore - enrolledSpeakers.count
    let removedRecords = recordBefore - enrolledRecords.count
    let removedWearerRecords = wearerRecordBefore - wearerRecords.count
    let removedWearerCentroids = wearerCentroidBefore - wearerAdditionalCentroids.count
    let removedWearerProfile = hadWearerProfile && wearerProfile == nil
    if removedSpeakers > 0 || removedRecords > 0 || removedWearerRecords > 0 || removedWearerCentroids > 0 || removedWearerProfile {
      AppLogger.log(
        .speakerIdentity,
        "Purged incompatible speaker enrollments removedSpeakers=\(removedSpeakers) removedRecords=\(removedRecords) removedWearerProfile=\(removedWearerProfile) removedWearerRecords=\(removedWearerRecords) removedWearerCentroids=\(removedWearerCentroids) expectedModel=\(embeddingModel.modelName) expectedVersion=\(embeddingModel.modelVersion) expectedPreprocessing=\(embeddingModel.preprocessingVersion) expectedDim=\(embeddingModel.embeddingDimension)"
      )
      if saveAfterPurge {
        saveToDisk()
      }
    }
  }

  private func isCompatible(modelName: String, modelVersion: String, preprocessingVersion: String, dimension: Int) -> Bool {
    dimension == embeddingModel.embeddingDimension
      && modelName == embeddingModel.modelName
      && modelVersion == embeddingModel.modelVersion
      && preprocessingVersion == embeddingModel.preprocessingVersion
  }

  private func appendToSpeechBuffer(_ samples: [Float]) {
    speechBuffer.append(contentsOf: samples)
    let maxSamples = Int(SpeakerIdentityConfig.maxSpeechBufferSeconds * SpeakerIdentityConfig.targetSampleRate)
    if speechBuffer.count > maxSamples {
      speechBuffer = Array(speechBuffer.suffix(maxSamples))
    }
  }

  private func appendToWearerEnrollmentBuffer(_ samples: [Float]) {
    guard wearerEnrollmentActive else { return }
    wearerEnrollmentSamples.append(contentsOf: samples)
    let maxSamples = Int(SpeakerIdentityConfig.wearerVoiceMaxEnrollmentSeconds * SpeakerIdentityConfig.targetSampleRate)
    if wearerEnrollmentSamples.count > maxSamples {
      wearerEnrollmentSamples = Array(wearerEnrollmentSamples.suffix(maxSamples))
    }
  }

  private var speechBufferSeconds: Double {
    Double(speechBuffer.count) / SpeakerIdentityConfig.targetSampleRate
  }

  private var wearerEnrollmentSeconds: Double {
    Double(wearerEnrollmentSamples.count) / SpeakerIdentityConfig.targetSampleRate
  }

  // MARK: - Audio resampling

  private func resample(_ buffer: AVAudioPCMBuffer) -> [Float]? {
    let inputFormat = buffer.format
    let frameCount = Int(buffer.frameLength)
    guard frameCount > 0 else { return nil }

    // Fast path: already 16 kHz float32 mono — extract directly without a converter.
    if inputFormat.sampleRate == SpeakerIdentityConfig.targetSampleRate,
       inputFormat.commonFormat == .pcmFormatFloat32,
       inputFormat.channelCount >= 1,
       let channelData = buffer.floatChannelData {
      return Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
    }

    // Slow path: need format conversion (e.g. different sample rate or channel layout).
    if converter == nil || converterInputFormatMismatch(inputFormat) {
      guard let conv = AVAudioConverter(from: inputFormat, to: outputFormat) else {
        AppLogger.log(.speakerVAD, "AVAudioConverter init failed: input=\(inputFormat) output=\(outputFormat)")
        return nil
      }
      converter = conv
    }
    guard let conv = converter else { return nil }

    let ratio = SpeakerIdentityConfig.targetSampleRate / inputFormat.sampleRate
    let outFrameCount = AVAudioFrameCount(max(1, Int(Double(frameCount) * ratio)))
    guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outFrameCount) else {
      return nil
    }

    var inputConsumed = false
    var convError: NSError?
    conv.convert(to: outBuffer, error: &convError) { _, status in
      if inputConsumed {
        status.pointee = .noDataNow
        return nil
      }
      inputConsumed = true
      status.pointee = .haveData
      return buffer
    }
    if let err = convError {
      AppLogger.log(.speakerVAD, "Resample error: \(err.localizedDescription)")
      return nil
    }

    guard let channelData = outBuffer.floatChannelData else { return nil }
    return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outBuffer.frameLength)))
  }

  private func converterInputFormatMismatch(_ format: AVAudioFormat) -> Bool {
    guard let conv = converter else { return true }
    return conv.inputFormat != format
  }

  private func peakRMS(_ buffer: AVAudioPCMBuffer) -> Float {
    guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
    let count = Int(buffer.frameLength)
    var sum: Float = 0
    for i in 0..<count { sum += channelData[0][i] * channelData[0][i] }
    return sqrt(sum / Float(count))
  }

  private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var dot: Float = 0
    for i in a.indices { dot += a[i] * b[i] }
    return dot
  }
}
