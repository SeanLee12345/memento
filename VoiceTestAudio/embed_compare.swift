import AVFoundation
import CoreML
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let packageURL = root.appendingPathComponent("CameraAccess/SpeakerEmbedding.mlpackage")
let derivedDataURL = URL(fileURLWithPath: NSHomeDirectory())
  .appendingPathComponent("Library/Developer/Xcode/DerivedData")
let compiledModelURL = FileManager.default.enumerator(
  at: derivedDataURL,
  includingPropertiesForKeys: nil
)?
  .compactMap { $0 as? URL }
  .first {
    $0.lastPathComponent == "SpeakerEmbedding.mlmodelc"
      && $0.path.contains("CameraAccess")
      && $0.path.contains("Debug-iphonesimulator")
  }
let modelURL = compiledModelURL ?? packageURL
let args = CommandLine.arguments.dropFirst()
let wavURLs: [URL]
if args.count == 2 {
  wavURLs = args.map { URL(fileURLWithPath: $0) }
} else {
  wavURLs = [
    root.appendingPathComponent("VoiceTestAudio/IMG_3076_16k_mono.wav"),
    root.appendingPathComponent("VoiceTestAudio/IMG_3075_16k_mono.wav")
  ]
}

func loadSamples(_ url: URL) throws -> [Float] {
  let file = try AVAudioFile(forReading: url)
  let frameCount = AVAudioFrameCount(file.length)
  guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
    throw NSError(domain: "VoiceTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not allocate audio buffer"])
  }
  try file.read(into: buffer)
  guard let channels = buffer.floatChannelData else {
    throw NSError(domain: "VoiceTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "Expected float channel data"])
  }
  let count = Int(buffer.frameLength)
  if buffer.format.channelCount == 1 {
    return Array(UnsafeBufferPointer(start: channels[0], count: count))
  }
  var mono = [Float](repeating: 0, count: count)
  let channelCount = Int(buffer.format.channelCount)
  for channel in 0..<channelCount {
    let data = UnsafeBufferPointer(start: channels[channel], count: count)
    for i in 0..<count {
      mono[i] += data[i] / Float(channelCount)
    }
  }
  return mono
}

func padOrTrim(_ samples: [Float], count: Int) -> [Float] {
  if samples.count >= count {
    return Array(samples.prefix(count))
  }
  return samples + [Float](repeating: 0, count: count - samples.count)
}

func flatten(_ array: MLMultiArray) -> [Float] {
  let count = array.count
  var result = [Float](repeating: 0, count: count)
  switch array.dataType {
  case .float32:
    let ptr = UnsafePointer<Float>(OpaquePointer(array.dataPointer))
    for i in 0..<count { result[i] = ptr[i] }
  case .double:
    let ptr = UnsafePointer<Double>(OpaquePointer(array.dataPointer))
    for i in 0..<count { result[i] = Float(ptr[i]) }
  case .float16:
    for i in 0..<count { result[i] = array[i].floatValue }
  default:
    for i in 0..<count { result[i] = array[i].floatValue }
  }
  return result
}

func l2Normalize(_ vector: [Float]) throws -> ([Float], Float) {
  let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
  guard norm > 1e-6, norm.isFinite else {
    throw NSError(domain: "VoiceTest", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid vector norm \(norm)"])
  }
  return (vector.map { $0 / norm }, norm)
}

func cosine(_ a: [Float], _ b: [Float]) -> Float {
  zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
}

let config = MLModelConfiguration()
config.computeUnits = .cpuAndNeuralEngine
let model = try MLModel(contentsOf: modelURL, configuration: config)
let description = model.modelDescription
let inputName = description.inputDescriptionsByName.keys.first ?? "waveform"
let outputName = description.outputDescriptionsByName.keys.first { key in
  description.outputDescriptionsByName[key]?.type == .multiArray
} ?? "embedding"

let inputDescription = description.inputDescriptionsByName[inputName]
let outputDescription = description.outputDescriptionsByName[outputName]
let inputShape = inputDescription?.multiArrayConstraint?.shape.map { $0.intValue } ?? [1, 48_000]
let windowCount = inputShape.last ?? 48_000

print("model=\(modelURL.lastPathComponent)")
print("input=\(inputName) shape=\(inputShape)")
print("output=\(outputName) shape=\(outputDescription?.multiArrayConstraint?.shape.map { $0.intValue } ?? [])")

var embeddings: [[Float]] = []
for wavURL in wavURLs {
  let samples = try loadSamples(wavURL)
  let window = padOrTrim(samples, count: windowCount)
  let inputArray = try MLMultiArray(shape: [1, NSNumber(value: windowCount)], dataType: .float32)
  let ptr = UnsafeMutablePointer<Float>(OpaquePointer(inputArray.dataPointer))
  window.withUnsafeBufferPointer { buffer in
    ptr.assign(from: buffer.baseAddress!, count: windowCount)
  }
  let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: inputArray])
  let prediction = try model.prediction(from: provider)
  guard let outputArray = prediction.featureValue(for: outputName)?.multiArrayValue else {
    throw NSError(domain: "VoiceTest", code: 4, userInfo: [NSLocalizedDescriptionKey: "Missing output multiArray \(outputName)"])
  }
  let raw = flatten(outputArray)
  let (normalized, normBefore) = try l2Normalize(raw)
  embeddings.append(normalized)
  print("file=\(wavURL.lastPathComponent) samples=\(samples.count) dim=\(normalized.count) normBefore=\(String(format: "%.6f", normBefore)) normAfter=1.000000")
}

guard embeddings.count == 2, embeddings[0].count == embeddings[1].count else {
  throw NSError(domain: "VoiceTest", code: 5, userInfo: [NSLocalizedDescriptionKey: "Embedding dimensions do not match"])
}

let score = cosine(embeddings[0], embeddings[1])
print("cosineSimilarity=\(String(format: "%.6f", score))")
