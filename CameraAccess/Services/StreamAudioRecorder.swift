import AVFoundation
import Foundation

// Records all microphone PCM buffers from the stream into a 16 kHz mono WAV file.
// Plug into SpeechTranscriptionManager.onAudioBuffer to receive buffers.
//
// Gain normalization is handled upstream in SpeechTranscriptionManager.TapGainRide
// so the live embedding pipeline and the saved WAV both see the same boosted
// signal. This class serializes resampling and file writes on its own queue.
final class StreamAudioRecorder {
  private let writeQueue = DispatchQueue(label: "com.cameraaccess.stream-audio-recorder")
  private var audioFile: AVAudioFile?
  private var outputURL: URL?
  private var isRecording = false
  private var converter: AVAudioConverter?
  private var converterInputFormat: AVAudioFormat?
  private var recordedFrameCount: AVAudioFramePosition = 0

  private static let targetFormat: AVAudioFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16,
    sampleRate: 16_000,
    channels: 1,
    interleaved: false
  )!

  // Call once per stream to prepare the output file.
  func start() {
    AppLogger.log(.audio, "[StreamAudioRecorder] Start requested")
    writeQueue.async { [weak self] in
      guard let self else { return }
      guard !isRecording else {
        AppLogger.log(.audio, "[StreamAudioRecorder] start() called while already recording -> ignored. Existing file=\(outputURL?.lastPathComponent ?? "none"). This means a previous stream's recorder was not stopped properly.")
        return
      }
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("stream_\(UUID().uuidString).wav")
      let file: AVAudioFile
      do {
        file = try AVAudioFile(forWriting: url, settings: Self.targetFormat.settings)
      } catch {
        AppLogger.log(.audio, "[StreamAudioRecorder] start() failed: \(error.localizedDescription)")
        return
      }
      audioFile = file
      outputURL = url
      converter = nil
      converterInputFormat = nil
      recordedFrameCount = 0
      isRecording = true
      AppLogger.log(.audio, "[StreamAudioRecorder] Started -> \(url.lastPathComponent) fileFormat=\(file.processingFormat)")
    }
  }

  // Called on the audio tap thread for every PCM buffer.
  // Lazily creates the converter on the first buffer that arrives.
  func append(_ buffer: AVAudioPCMBuffer) {
    guard buffer.frameLength > 0 else { return }
    guard let copiedBuffer = Self.copyPCMBuffer(buffer) else { return }
    writeQueue.async { [weak self] in
      self?.appendOnWriteQueue(copiedBuffer)
    }
  }

  private func appendOnWriteQueue(_ buffer: AVAudioPCMBuffer) {
    guard isRecording, let file = audioFile else { return }
    guard buffer.frameLength > 0 else { return }

    let fileFormat = file.processingFormat
    if buffer.format == fileFormat {
      write(buffer, to: file)
      return
    }

    if converter == nil || converterInputFormat != buffer.format {
      converter = AVAudioConverter(from: buffer.format, to: fileFormat)
      converterInputFormat = buffer.format
    }
    guard let conv = converter else {
      AppLogger.log(.audio, "[StreamAudioRecorder] Converter unavailable input=\(buffer.format) output=\(fileFormat)")
      return
    }
    guard let written = resample(buffer, converter: conv, outputFormat: fileFormat) else { return }
    write(written, to: file)
  }

  // Returns the finished WAV file URL, or nil if nothing was recorded.
  func stop() -> URL? {
    writeQueue.sync {
      isRecording = false
      audioFile = nil
      converter = nil
      converterInputFormat = nil
      let url = outputURL
      let frames = recordedFrameCount
      outputURL = nil
      recordedFrameCount = 0
      if frames <= 0 {
        if let url {
          try? FileManager.default.removeItem(at: url)
        }
        AppLogger.log(.audio, "[StreamAudioRecorder] Stopped with no recorded frames; skipping diarization upload")
        return nil
      }
      let seconds = Double(frames) / Self.targetFormat.sampleRate
      AppLogger.log(.audio, "[StreamAudioRecorder] Stopped, file=\(url?.lastPathComponent ?? "none") frames=\(frames) seconds=\(String(format: "%.2f", seconds))")
      return url
    }
  }

  private func resample(
    _ buffer: AVAudioPCMBuffer,
    converter: AVAudioConverter,
    outputFormat: AVAudioFormat
  ) -> AVAudioPCMBuffer? {
    let ratio = outputFormat.sampleRate / max(1, buffer.format.sampleRate)
    let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
    guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
    var didProvide = false
    var conversionError: NSError?
    let status = converter.convert(to: output, error: &conversionError) { _, status in
      if didProvide { status.pointee = .noDataNow; return nil }
      didProvide = true; status.pointee = .haveData; return buffer
    }
    if let conversionError {
      AppLogger.log(.audio, "[StreamAudioRecorder] Resample failed: \(conversionError.localizedDescription)")
      return nil
    }
    if status == .error {
      AppLogger.log(.audio, "[StreamAudioRecorder] Resample failed with converter status=error input=\(buffer.format) output=\(outputFormat)")
      return nil
    }
    return output.frameLength > 0 ? output : nil
  }

  private func write(_ buffer: AVAudioPCMBuffer, to file: AVAudioFile) {
    guard buffer.frameLength > 0 else { return }
    guard buffer.format == file.processingFormat else {
      AppLogger.log(.audio, "[StreamAudioRecorder] Skipping write due to format mismatch buffer=\(buffer.format) file=\(file.processingFormat)")
      return
    }
    do {
      try file.write(from: buffer)
      recordedFrameCount += AVAudioFramePosition(buffer.frameLength)
    } catch {
      AppLogger.log(.audio, "[StreamAudioRecorder] Write failed: \(error.localizedDescription)")
    }
  }

  private static func copyPCMBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else {
      return nil
    }
    copy.frameLength = source.frameLength

    let sourceABL = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
    let copyABL = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    guard sourceABL.count == copyABL.count else { return nil }

    for index in 0..<sourceABL.count {
      let sourceBuffer = sourceABL[index]
      let byteCount = Int(sourceBuffer.mDataByteSize)
      guard byteCount > 0,
            let sourceData = sourceBuffer.mData,
            let copyData = copyABL[index].mData else {
        continue
      }
      memcpy(copyData, sourceData, byteCount)
      copyABL[index].mDataByteSize = sourceBuffer.mDataByteSize
    }

    return copy
  }
}
