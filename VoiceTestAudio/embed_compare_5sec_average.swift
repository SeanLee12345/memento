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
let wavA = args.count == 2 ? URL(fileURLWithPath: args[0]) : root.appendingPathComponent("VoiceTestAudio/IMG_3081_16k_mono.wav")
let wavB = args.count == 2 ? URL(fileURLWithPath: args[1]) : root.appendingPathComponent("VoiceTestAudio/IMG_3080_16k_mono.wav")

let sampleRate = 16_000
let modelWindow = 48_000 // 3 seconds
let oneSecond = 16_000
let fiveSeconds = 80_000

func loadSamples(_ url: URL) throws -> [Float] {
  let file = try AVAudioFile(forReading: url)
  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
  try file.read(into: buffer)
  let data = buffer.floatChannelData![0]
  return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
}

func normalize(_ v: [Float]) -> [Float] {
  let n = sqrt(v.reduce(Float(0)) { $0 + $1 * $1 })
  return v.map { $0 / max(n, 1e-8) }
}

func averageAndNormalize(_ vectors: [[Float]]) -> [Float] {
  guard let first = vectors.first else { return [] }
  var avg = [Float](repeating: 0, count: first.count)
  for v in vectors {
    for i in avg.indices { avg[i] += v[i] / Float(vectors.count) }
  }
  return normalize(avg)
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

func embed(_ samples: [Float], start: Int) throws -> [Float] {
  let safeStart = min(max(start, 0), samples.count)
  var segment = [Float](repeating: 0, count: modelWindow)
  if safeStart < samples.count {
    let available = min(modelWindow, samples.count - safeStart)
    for i in 0..<available {
      segment[i] = samples[safeStart + i]
    }
  }
  let input = try MLMultiArray(shape: [1, NSNumber(value: modelWindow)], dataType: .float32)
  let ptr = UnsafeMutablePointer<Float>(OpaquePointer(input.dataPointer))
  segment.withUnsafeBufferPointer { ptr.update(from: $0.baseAddress!, count: modelWindow) }
  let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [inputName: input]))
  let arr = output.featureValue(for: outputName)!.multiArrayValue!
  var raw = [Float](repeating: 0, count: arr.count)
  let optr = UnsafePointer<Float>(OpaquePointer(arr.dataPointer))
  raw.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: optr, count: arr.count) }
  return normalize(raw)
}

func fiveSecondCentroid(_ samples: [Float], regionStart: Int) throws -> [Float] {
  let starts = [regionStart, regionStart + oneSecond, regionStart + 2 * oneSecond]
  return averageAndNormalize(try starts.map { try embed(samples, start: $0) })
}

func validFiveSecondStarts(_ samples: [Float]) -> [Int] {
  guard samples.count >= fiveSeconds else { return [0] }
  return stride(from: 0, through: samples.count - fiveSeconds, by: oneSecond).map { $0 }
}

let a = try loadSamples(wavA)
let b = try loadSamples(wavB)

let firstA = try fiveSecondCentroid(a, regionStart: 0)
let firstB = try fiveSecondCentroid(b, regionStart: 0)
print("model=\(modelURL.lastPathComponent) input=\(inputName) output=\(outputName)")
print("fileA=\(wavA.lastPathComponent) samples=\(a.count)")
print("fileB=\(wavB.lastPathComponent) samples=\(b.count)")
print("first5sAverageCosine=\(String(format: "%.6f", cosine(firstA, firstB)))")

var best: (Double, Double, Float)? = nil
for sa in validFiveSecondStarts(a) {
  let ca = try fiveSecondCentroid(a, regionStart: sa)
  for sb in validFiveSecondStarts(b) {
    let cb = try fiveSecondCentroid(b, regionStart: sb)
    let score = cosine(ca, cb)
    if best == nil || score > best!.2 {
      best = (Double(sa) / Double(sampleRate), Double(sb) / Double(sampleRate), score)
    }
  }
}

let allA = try validFiveSecondStarts(a).map { try fiveSecondCentroid(a, regionStart: $0) }
let allB = try validFiveSecondStarts(b).map { try fiveSecondCentroid(b, regionStart: $0) }
let allAvgA = averageAndNormalize(allA)
let allAvgB = averageAndNormalize(allB)
print("all5sRegionAverageCosine=\(String(format: "%.6f", cosine(allAvgA, allAvgB)))")
if let best {
  print("best5sAverageCosine=\(String(format: "%.6f", best.2)) Astart=\(String(format: "%.1f", best.0))s Bstart=\(String(format: "%.1f", best.1))s")
}
