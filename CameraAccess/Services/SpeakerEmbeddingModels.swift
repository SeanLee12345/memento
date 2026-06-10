import AVFoundation
import CoreML
import Foundation

protocol SpeakerEmbeddingModel {
  var embeddingDimension: Int { get }
  var modelName: String { get }
  var modelVersion: String { get }
  var preprocessingVersion: String { get }
  var embeddingRuntime: String { get }

  func load() async throws
  func embed(samples: [Float], sampleRate: Double) async throws -> VoiceEmbedding
}

enum SpeakerEmbeddingError: LocalizedError {
  case coreMLModelMissing(expectedNames: [String])
  case modelInputUnsupported
  case modelOutputUnsupported
  case inferenceBufferCreationFailed
  case invalidEmbeddingValues(String)
  case remoteEmbeddingFailed(String)

  var errorDescription: String? {
    switch self {
    case .coreMLModelMissing(let names):
      return "No speaker embedding CoreML model found. Expected: \(names.joined(separator: ", "))"
    case .modelInputUnsupported:
      return "Speaker model input type unsupported."
    case .modelOutputUnsupported:
      return "Speaker model output type unsupported."
    case .inferenceBufferCreationFailed:
      return "Could not create CoreML MLMultiArray for audio input."
    case .invalidEmbeddingValues(let reason):
      return "Speaker model returned invalid vector: \(reason)"
    case .remoteEmbeddingFailed(let reason):
      return "Remote speaker embedding failed: \(reason)"
    }
  }
}

actor RemoteTitaNetSpeakerEmbeddingModel: SpeakerEmbeddingModel {
  nonisolated let embeddingDimension = 192
  nonisolated let modelName = "SpeakerEmbedding"
  nonisolated let modelVersion = "nvidia-speakerverification-en-titanet-large-v1"
  nonisolated let preprocessingVersion = "titanet-raw-16khz-v1"
  nonisolated let embeddingRuntime = SpeakerEmbeddingRuntime.awsTitaNet

  private let endpoint: String
  private let apiKey: String
  private let session: URLSession
  private let fallback: SpeakerEmbeddingModel?
  private var remoteDisabledUntil: Date?
  private var lastRemoteFailureLogAt: Date?

  private let embedTimeoutSeconds: TimeInterval = 12
  private let remoteFailureBackoffSeconds: TimeInterval = 60

  init(
    endpoint: String = LocalWorkerSettings.defaultSpeakerEndpoint,
    apiKey: String = LocalWorkerSettings.defaultAPIKey,
    session: URLSession = .shared,
    fallback: SpeakerEmbeddingModel? = nil
  ) {
    self.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    self.session = session
    self.fallback = fallback
  }

  func load() async throws {
    guard let url = URL(string: endpoint)?.appendingPathComponent("health") else {
      throw SpeakerEmbeddingError.remoteEmbeddingFailed("invalid endpoint \(endpoint)")
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = 5
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    do {
      let (_, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        throw SpeakerEmbeddingError.remoteEmbeddingFailed("health check failed")
      }
      AppLogger.log(.speakerEmbeddingModel, "Remote TitaNet worker reachable endpoint=\(endpoint)")
    } catch {
      remoteDisabledUntil = Date().addingTimeInterval(remoteFailureBackoffSeconds)
      if let fallback {
        AppLogger.log(.speakerEmbeddingModel, "Remote TitaNet load failed; falling back to local CoreML: \(error.localizedDescription)")
        try await fallback.load()
      } else {
        throw error
      }
    }
  }

  func embed(samples: [Float], sampleRate: Double) async throws -> VoiceEmbedding {
    if fallback != nil, let remoteDisabledUntil, Date() < remoteDisabledUntil {
      if let fallback {
        return try await fallback.embed(samples: samples, sampleRate: sampleRate)
      }
      throw SpeakerEmbeddingError.remoteEmbeddingFailed("remote temporarily disabled after recent failure")
    }

    do {
      return try await embedRemotely(samples: samples, sampleRate: sampleRate)
    } catch {
      if let fallback {
        remoteDisabledUntil = Date().addingTimeInterval(remoteFailureBackoffSeconds)
        let now = Date()
        if lastRemoteFailureLogAt == nil || now.timeIntervalSince(lastRemoteFailureLogAt!) > 10 {
          AppLogger.log(.speakerEmbedding, "Remote TitaNet embedding failed; falling back to local CoreML for \(Int(remoteFailureBackoffSeconds))s: \(error.localizedDescription)")
          lastRemoteFailureLogAt = now
        }
        return try await fallback.embed(samples: samples, sampleRate: sampleRate)
      }
      remoteDisabledUntil = nil
      throw error
    }
  }

  private func embedRemotely(samples: [Float], sampleRate: Double) async throws -> VoiceEmbedding {
    guard let url = URL(string: endpoint)?.appendingPathComponent("speaker").appendingPathComponent("embed") else {
      throw SpeakerEmbeddingError.remoteEmbeddingFailed("invalid endpoint \(endpoint)")
    }
    let window = padOrTrim(samples, to: SpeakerIdentityConfig.embeddingWindowSamples)
    let wavData = makeWAVData(samples: window, sampleRate: Int(sampleRate))
    let boundary = "MetaFaceBoundary-\(UUID().uuidString)"

    var body = Data()
    appendString("--\(boundary)\r\n", to: &body)
    appendString("Content-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\n", to: &body)
    appendString("Content-Type: audio/wav\r\n\r\n", to: &body)
    body.append(wavData)
    appendString("\r\n--\(boundary)--\r\n", to: &body)

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = embedTimeoutSeconds
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.httpBody = body

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw SpeakerEmbeddingError.remoteEmbeddingFailed("invalid HTTP response")
    }
    guard (200..<300).contains(http.statusCode) else {
      let bodyText = String(data: data, encoding: .utf8) ?? ""
      throw SpeakerEmbeddingError.remoteEmbeddingFailed("HTTP \(http.statusCode) \(bodyText)")
    }

    let decoded = try JSONDecoder().decode(RemoteEmbeddingResponse.self, from: data)
    let vector = decoded.embedding
    guard vector.count == decoded.dimension, !vector.isEmpty else {
      throw SpeakerEmbeddingError.invalidEmbeddingValues("remote dimension mismatch")
    }
    guard vector.allSatisfy(\.isFinite) else {
      throw SpeakerEmbeddingError.invalidEmbeddingValues("remote NaN or Inf")
    }
    let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
    guard norm > 1e-6 else {
      throw SpeakerEmbeddingError.invalidEmbeddingValues("remote near-zero norm")
    }
    let normalized = vector.map { $0 / norm }
    AppLogger.log(.speakerEmbedding, "Remote TitaNet embedding succeeded endpoint=\(endpoint) dim=\(normalized.count)")
    return VoiceEmbedding(
      vector: normalized,
      modelName: modelName,
      modelVersion: modelVersion,
      preprocessingVersion: preprocessingVersion,
      embeddingRuntime: embeddingRuntime
    )
  }

  private func padOrTrim(_ samples: [Float], to count: Int) -> [Float] {
    if samples.count >= count { return Array(samples.prefix(count)) }
    return samples + [Float](repeating: 0, count: count - samples.count)
  }

  private func appendString(_ string: String, to data: inout Data) {
    data.append(Data(string.utf8))
  }

  private func makeWAVData(samples: [Float], sampleRate: Int) -> Data {
    var data = Data()
    let channels: UInt16 = 1
    let bitsPerSample: UInt16 = 16
    let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
    let blockAlign = channels * (bitsPerSample / 8)
    let pcmSamples = samples.map { sample -> Int16 in
      let clamped = max(-1, min(1, sample))
      return Int16(clamped * Float(Int16.max))
    }
    let dataSize = UInt32(pcmSamples.count * MemoryLayout<Int16>.size)

    appendString("RIFF", to: &data)
    appendLittleEndian(UInt32(36) + dataSize, to: &data)
    appendString("WAVE", to: &data)
    appendString("fmt ", to: &data)
    appendLittleEndian(UInt32(16), to: &data)
    appendLittleEndian(UInt16(1), to: &data)
    appendLittleEndian(channels, to: &data)
    appendLittleEndian(UInt32(sampleRate), to: &data)
    appendLittleEndian(byteRate, to: &data)
    appendLittleEndian(blockAlign, to: &data)
    appendLittleEndian(bitsPerSample, to: &data)
    appendString("data", to: &data)
    appendLittleEndian(dataSize, to: &data)
    for sample in pcmSamples {
      appendLittleEndian(sample, to: &data)
    }
    return data
  }

  private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var little = value.littleEndian
    withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
  }

  private struct RemoteEmbeddingResponse: Decodable {
    let model: String
    let dimension: Int
    let normalized: Bool?
    let embedding: [Float]
  }
}

struct FallbackSpeakerEmbeddingModel: SpeakerEmbeddingModel {
  let primary: SpeakerEmbeddingModel
  let fallback: SpeakerEmbeddingModel

  var embeddingDimension: Int { primary.embeddingDimension }
  var modelName: String { primary.modelName }
  var modelVersion: String { primary.modelVersion }
  var preprocessingVersion: String { primary.preprocessingVersion }
  var embeddingRuntime: String { primary.embeddingRuntime }

  func load() async throws {
    do {
      try await primary.load()
    } catch {
      AppLogger.log(.speakerEmbeddingModel, "Primary speaker model load failed; fallback available: \(error.localizedDescription)")
      try await fallback.load()
    }
  }

  func embed(samples: [Float], sampleRate: Double) async throws -> VoiceEmbedding {
    do {
      return try await primary.embed(samples: samples, sampleRate: sampleRate)
    } catch {
      AppLogger.log(.speakerEmbedding, "Primary speaker model embed failed; using fallback: \(error.localizedDescription)")
      return try await fallback.embed(samples: samples, sampleRate: sampleRate)
    }
  }
}

// Fallback used when no .mlpackage is found; logs a clear message and skips inference.
struct MissingSpeakerEmbeddingModel: SpeakerEmbeddingModel {
  let embeddingDimension = 0
  let modelName = "missing"
  let modelVersion = "0"
  let preprocessingVersion = "none"
  let embeddingRuntime = SpeakerEmbeddingRuntime.missing

  func load() async throws {}
  func embed(samples: [Float], sampleRate: Double) async throws -> VoiceEmbedding {
    throw SpeakerEmbeddingError.coreMLModelMissing(
      expectedNames: SpeakerEmbeddingModelFactory.expectedModelNames
    )
  }
}

// Loads on first embed() call so app startup is not blocked by model compilation.
// Expects a CoreML model whose input is a raw 16 kHz mono waveform [1, N] float32
// and whose output is an L2-normalized embedding float32 vector.
// The TitaNet conversion script includes feature extraction inside the exported
// graph so iOS passes raw samples only.
actor LazyCoreMLSpeakerEmbeddingModel: SpeakerEmbeddingModel {
  nonisolated let modelName: String
  nonisolated let modelVersion = "nvidia-speakerverification-en-titanet-large-v1"
  nonisolated let embeddingDimension = 192
  nonisolated let preprocessingVersion: String
  nonisolated let embeddingRuntime = SpeakerEmbeddingRuntime.localCoreML

  private let modelURL: URL
  private var loadedModel: MLModel?
  private var inputName: String = "waveform"
  private var outputName: String = "embedding"
  private var loadTask: Task<(MLModel, String, String), Error>?

  init(modelURL: URL, preprocessingVersion: String) {
    self.modelURL = modelURL
    self.modelName = modelURL.deletingPathExtension().lastPathComponent
    self.preprocessingVersion = preprocessingVersion
  }

  func load() async throws {
    _ = try await resolvedModel()
  }

  func embed(samples: [Float], sampleRate: Double) async throws -> VoiceEmbedding {
    let (model, inName, outName) = try await resolvedModel()
    let window = padOrTrim(samples, to: SpeakerIdentityConfig.embeddingWindowSamples)

    guard let multiArray = try? MLMultiArray(
      shape: [1, NSNumber(value: window.count)], dataType: .float32
    ) else {
      throw SpeakerEmbeddingError.inferenceBufferCreationFailed
    }
    let ptr = UnsafeMutablePointer<Float>(OpaquePointer(multiArray.dataPointer))
    window.withUnsafeBufferPointer { buf in
      ptr.assign(from: buf.baseAddress!, count: window.count)
    }

    let input = try MLDictionaryFeatureProvider(dictionary: [inName: multiArray])
    let output = try await model.prediction(from: input)

    guard let embArray = output.featureValue(for: outName)?.multiArrayValue else {
      throw SpeakerEmbeddingError.modelOutputUnsupported
    }

    let dim = embArray.count
    var vector = [Float](repeating: 0, count: dim)
    let embPtr = UnsafePointer<Float>(OpaquePointer(embArray.dataPointer))
    vector.withUnsafeMutableBufferPointer { buf in
      buf.baseAddress!.assign(from: embPtr, count: dim)
    }

    guard vector.allSatisfy(\.isFinite) else {
      throw SpeakerEmbeddingError.invalidEmbeddingValues("NaN or Inf")
    }
    let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
    guard norm > 1e-6 else {
      throw SpeakerEmbeddingError.invalidEmbeddingValues("near-zero norm")
    }
    let normalized = vector.map { $0 / norm }

    return VoiceEmbedding(
      vector: normalized,
      modelName: modelName,
      modelVersion: modelVersion,
      preprocessingVersion: preprocessingVersion,
      embeddingRuntime: embeddingRuntime
    )
  }

  private func resolvedModel() async throws -> (MLModel, String, String) {
    if let model = loadedModel {
      return (model, inputName, outputName)
    }
    if let task = loadTask {
      let (m, i, o) = try await task.value
      loadedModel = m
      inputName = i
      outputName = o
      return (m, i, o)
    }
    let url = modelURL
    let task = Task.detached(priority: .utility) { () -> (MLModel, String, String) in
      let config = MLModelConfiguration()
      config.computeUnits = .cpuAndNeuralEngine
      let model = try MLModel(contentsOf: url, configuration: config)
      let inName = model.modelDescription.inputDescriptionsByName.keys.first ?? "waveform"
      let outName = model.modelDescription.outputDescriptionsByName.keys.first(where: {
        model.modelDescription.outputDescriptionsByName[$0]?.type == .multiArray
      }) ?? "embedding"
      AppLogger.log(
        .speakerEmbeddingModel,
        "Loaded speaker model \(url.lastPathComponent) input=\(inName) output=\(outName)"
      )
      return (model, inName, outName)
    }
    loadTask = task
    do {
      let (m, i, o) = try await task.value
      loadedModel = m
      inputName = i
      outputName = o
      loadTask = nil
      return (m, i, o)
    } catch {
      loadTask = nil
      throw error
    }
  }

  private func padOrTrim(_ samples: [Float], to count: Int) -> [Float] {
    if samples.count >= count { return Array(samples.prefix(count)) }
    return samples + [Float](repeating: 0, count: count - samples.count)
  }
}

enum SpeakerEmbeddingModelFactory {
  static let expectedModelNames = ["SpeakerEmbedding", "ECAPATDNN", "SpeakerNet"]
  // Xcode may compile .mlpackage → .mlmodelc; search all three extensions.
  private static let searchExtensions = ["mlpackage", "mlmodelc", "mlmodel"]
  // Versioned preprocessing tag — must match what convert_titanet_to_coreml.py exports.
  static let preprocessingVersion = "titanet-raw-16khz-v1"

  static func makeModel() -> SpeakerEmbeddingModel {
    return makeLocalModelOnly()
  }

  static func makeLocalModelOnly() -> SpeakerEmbeddingModel {
    for name in expectedModelNames {
      for ext in searchExtensions {
        if let url = Bundle.main.url(forResource: name, withExtension: ext) {
          return LazyCoreMLSpeakerEmbeddingModel(modelURL: url, preprocessingVersion: preprocessingVersion)
        }
      }
    }
    AppLogger.log(
      .speakerEmbeddingModel,
      "modelLoaded=false — no SpeakerEmbedding/ECAPATDNN/SpeakerNet.mlpackage in bundle. " +
      "Run tools/convert_titanet_to_coreml.py to generate one. Speaker recognition disabled."
    )
    return MissingSpeakerEmbeddingModel()
  }

  static func makeRemoteModelOnly() -> SpeakerEmbeddingModel {
    RemoteTitaNetSpeakerEmbeddingModel(fallback: nil)
  }

  static func makeRemoteModelOnly(endpoint: String, apiKey: String) -> SpeakerEmbeddingModel {
    RemoteTitaNetSpeakerEmbeddingModel(endpoint: endpoint, apiKey: apiKey, fallback: nil)
  }

  static func diagnosticsText() -> String {
    for name in expectedModelNames {
      for ext in searchExtensions {
        if Bundle.main.url(forResource: name, withExtension: ext) != nil {
          return "modelLoaded=pendingLoad name=\(name).\(ext)"
        }
      }
    }
    return "modelLoaded=false"
  }
}
