import AVFoundation
import CoreML
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let derivedDataURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Developer/Xcode/DerivedData")
let modelURL = FileManager.default.enumerator(at: derivedDataURL, includingPropertiesForKeys: nil)?
  .compactMap { $0 as? URL }
  .first { $0.lastPathComponent == "SpeakerEmbedding.mlmodelc" && $0.path.contains("CameraAccess") && $0.path.contains("Debug-iphonesimulator") }
  ?? root.appendingPathComponent("CameraAccess/SpeakerEmbedding.mlpackage")
let args = CommandLine.arguments.dropFirst()
let wavA: URL
let wavB: URL
if args.count == 2 {
  let paths = args.map { URL(fileURLWithPath: $0) }
  wavA = paths[0]
  wavB = paths[1]
} else {
  wavA = root.appendingPathComponent("VoiceTestAudio/IMG_3076_16k_mono.wav")
  wavB = root.appendingPathComponent("VoiceTestAudio/IMG_3075_16k_mono.wav")
}

func loadSamples(_ url: URL) throws -> [Float] {
  let file = try AVAudioFile(forReading: url)
  let frameCount = AVAudioFrameCount(file.length)
  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount)!
  try file.read(into: buffer)
  let data = buffer.floatChannelData![0]
  return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
}

func l2(_ v: [Float]) -> [Float] {
  let n = sqrt(v.reduce(Float(0)) { $0 + $1 * $1 })
  return v.map { $0 / max(n, 1e-8) }
}

func rms(_ v: [Float]) -> Float {
  sqrt(v.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(v.count, 1)))
}

let config = MLModelConfiguration()
config.computeUnits = .cpuAndNeuralEngine
let model = try MLModel(contentsOf: modelURL, configuration: config)
let desc = model.modelDescription
let inputName = desc.inputDescriptionsByName.keys.first ?? "waveform"
let outputName = desc.outputDescriptionsByName.keys.first { desc.outputDescriptionsByName[$0]?.type == .multiArray } ?? "embedding"
let window = 48_000
let hop = 16_000
let a = try loadSamples(wavA)
let b = try loadSamples(wavB)

func embed(_ samples: [Float], start: Int) throws -> [Float] {
  var segment = Array(samples[start..<min(start + window, samples.count)])
  if segment.count < window { segment += [Float](repeating: 0, count: window - segment.count) }
  let input = try MLMultiArray(shape: [1, NSNumber(value: window)], dataType: .float32)
  let ptr = UnsafeMutablePointer<Float>(OpaquePointer(input.dataPointer))
  segment.withUnsafeBufferPointer { ptr.update(from: $0.baseAddress!, count: window) }
  let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [inputName: input]))
  let arr = out.featureValue(for: outputName)!.multiArrayValue!
  var raw = [Float](repeating: 0, count: arr.count)
  let optr = UnsafePointer<Float>(OpaquePointer(arr.dataPointer))
  raw.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: optr, count: arr.count) }
  return l2(raw)
}

func starts(for samples: [Float]) -> [Int] {
  stride(from: 0, through: max(0, samples.count - window), by: hop).map { $0 }
}

let startsA = starts(for: a)
let startsB = starts(for: b)
var embA: [(Double, Float, [Float])] = []
var embB: [(Double, Float, [Float])] = []
for s in startsA { embA.append((Double(s) / 16_000, rms(Array(a[s..<min(s + window, a.count)])), try embed(a, start: s))) }
for s in startsB { embB.append((Double(s) / 16_000, rms(Array(b[s..<min(s + window, b.count)])), try embed(b, start: s))) }

var best: (Double, Double, Float, Float, Float)? = nil
for ea in embA {
  for eb in embB {
    let score = zip(ea.2, eb.2).reduce(Float(0)) { $0 + $1.0 * $1.1 }
    if best == nil || score > best!.4 {
      best = (ea.0, eb.0, ea.1, eb.1, score)
    }
  }
}
print("windowsA=\(embA.count) windowsB=\(embB.count)")
for ea in embA { print("A start=\(String(format: "%.1f", ea.0))s rms=\(String(format: "%.5f", ea.1))") }
for eb in embB { print("B start=\(String(format: "%.1f", eb.0))s rms=\(String(format: "%.5f", eb.1))") }
if let best {
  print("bestCosine=\(String(format: "%.6f", best.4)) Astart=\(String(format: "%.1f", best.0))s Bstart=\(String(format: "%.1f", best.1))s Arms=\(String(format: "%.5f", best.2)) Brms=\(String(format: "%.5f", best.3))")
}
