import AVFoundation
import CoreML
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let derivedDataURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Developer/Xcode/DerivedData")
let modelURL = FileManager.default.enumerator(at: derivedDataURL, includingPropertiesForKeys: nil)?
  .compactMap { $0 as? URL }
  .first { $0.lastPathComponent == "SpeakerEmbedding.mlmodelc" && $0.path.contains("CameraAccess") && $0.path.contains("Debug-iphonesimulator") }
  ?? root.appendingPathComponent("CameraAccess/SpeakerEmbedding.mlpackage")

let args = CommandLine.arguments.dropFirst().filter { $0 != "--" }
let probeURL = args.count >= 2 ? URL(fileURLWithPath: args[0]) : root.appendingPathComponent("VoiceTestAudio/IMG_3083_16k_mono.wav")
let enrollURL = args.count >= 2 ? URL(fileURLWithPath: args[1]) : root.appendingPathComponent("VoiceTestAudio/IMG_3081_16k_mono.wav")

let sampleRate = 16_000
let windowSamples = 48_000
let hopSamples = 16_000
let weakThreshold: Float = 0.60
let strongThreshold: Float = 0.70

func loadSamples(_ url: URL) throws -> [Float] {
  let file = try AVAudioFile(forReading: url)
  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
  try file.read(into: buffer)
  let data = buffer.floatChannelData![0]
  return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
}

func normalize(_ vector: [Float]) -> [Float] {
  let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
  return vector.map { $0 / max(norm, 1e-8) }
}

func average(_ vectors: [[Float]]) -> [Float] {
  guard let first = vectors.first else { return [] }
  var sum = [Float](repeating: 0, count: first.count)
  for vector in vectors where vector.count == first.count {
    for i in sum.indices {
      sum[i] += vector[i]
    }
  }
  return normalize(sum)
}

func cosine(_ a: [Float], _ b: [Float]) -> Float {
  zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
}

let config = MLModelConfiguration()
config.computeUnits = .cpuAndNeuralEngine
let model = try MLModel(contentsOf: modelURL, configuration: config)
let desc = model.modelDescription
let inputName = desc.inputDescriptionsByName.keys.first ?? "waveform"
let outputName = desc.outputDescriptionsByName.keys.first { desc.outputDescriptionsByName[$0]?.type == .multiArray } ?? "embedding"

func starts(for samples: [Float]) -> [Int] {
  guard samples.count > windowSamples else { return [0] }
  return stride(from: 0, through: samples.count - windowSamples, by: hopSamples).map { $0 }
}

func embed(_ samples: [Float], start: Int) throws -> [Float] {
  let safeStart = min(max(start, 0), samples.count)
  var segment = [Float](repeating: 0, count: windowSamples)
  if safeStart < samples.count {
    let available = min(windowSamples, samples.count - safeStart)
    for i in 0..<available {
      segment[i] = samples[safeStart + i]
    }
  }

  let input = try MLMultiArray(shape: [1, NSNumber(value: windowSamples)], dataType: .float32)
  let ptr = UnsafeMutablePointer<Float>(OpaquePointer(input.dataPointer))
  segment.withUnsafeBufferPointer { ptr.update(from: $0.baseAddress!, count: windowSamples) }
  let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [inputName: input]))
  let arr = out.featureValue(for: outputName)!.multiArrayValue!
  var raw = [Float](repeating: 0, count: arr.count)
  let optr = UnsafePointer<Float>(OpaquePointer(arr.dataPointer))
  raw.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: optr, count: arr.count) }
  return normalize(raw)
}

func evaluate(probeURL: URL, enrollURL: URL) throws {
  let probe = try loadSamples(probeURL)
  let enroll = try loadSamples(enrollURL)
  let enrollEmbeddings = try starts(for: enroll).map { try embed(enroll, start: $0) }
  let centroid = average(enrollEmbeddings)

  let probeStarts = starts(for: probe)
  let scores = try probeStarts.map { start -> (Double, Float) in
    let score = cosine(try embed(probe, start: start), centroid)
    return (Double(start) / Double(sampleRate), score)
  }

  var rollingWeak = [Bool]()
  var confirmedAt: [Double] = []
  for (time, score) in scores {
    let isWeak = score >= weakThreshold
    let isStrong = score >= strongThreshold
    rollingWeak.append(isWeak)
    if rollingWeak.count > 3 { rollingWeak.removeFirst() }
    let weakCount = rollingWeak.filter { $0 }.count
    if isStrong || weakCount >= 2 {
      confirmedAt.append(time)
    }
  }

  let best = scores.max { $0.1 < $1.1 }
  let mean = scores.map(\.1).reduce(Float(0), +) / Float(max(scores.count, 1))
  let weakCount = scores.filter { $0.1 >= weakThreshold }.count
  let strongCount = scores.filter { $0.1 >= strongThreshold }.count

  print("probe=\(probeURL.lastPathComponent) enrolledCentroid=\(enrollURL.lastPathComponent)")
  print("enrollWindows=\(enrollEmbeddings.count) probeWindows=\(scores.count)")
  print("meanScore=\(String(format: "%.6f", mean)) bestScore=\(String(format: "%.6f", best?.1 ?? 0)) bestStart=\(String(format: "%.1f", best?.0 ?? 0))s weakCount=\(weakCount) strongCount=\(strongCount) confirmed=\(!confirmedAt.isEmpty) confirmedAt=\(confirmedAt.map { String(format: "%.1f", $0) }.joined(separator: ","))")
  for (time, score) in scores {
    let label = score >= strongThreshold ? "strong" : (score >= weakThreshold ? "weak" : "reject")
    print("  t=\(String(format: "%.1f", time))s score=\(String(format: "%.6f", score)) \(label)")
  }
}

print("model=\(modelURL.lastPathComponent) input=\(inputName) output=\(outputName)")
print("thresholds weak=\(weakThreshold) strong=\(strongThreshold) rolling=2of3WeakOr1Strong")
try evaluate(probeURL: probeURL, enrollURL: enrollURL)
