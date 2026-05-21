import CoreGraphics
import CoreImage
import CoreML
import CryptoKit
import Foundation
import UIKit

typealias FaceEmbeddingVector = FaceEmbedding

protocol FaceEmbeddingModel {
  var embeddingDimension: Int { get }
  var inputImageSize: CGSize { get }
  var modelName: String { get }
  var modelVersion: String { get }
  func load() async throws
  func embed(faceImage: CGImage) async throws -> FaceEmbeddingVector
}

extension FaceEmbeddingModel {
  func embed(faceCrop: CGImage) async throws -> FaceEmbeddingVector {
    try await embed(faceImage: faceCrop)
  }
}

enum FaceEmbeddingError: LocalizedError {
  case coreMLModelMissing(expectedNames: [String])
  case modelInputUnsupported
  case modelOutputUnsupported
  case pixelBufferCreationFailed
  case invalidImageData
  case invalidEmbeddingDimension
  case invalidEmbeddingValues(String)

  var errorDescription: String? {
    switch self {
    case .coreMLModelMissing(let names):
      return "No MobileFaceNet/Core ML face embedding model found. Expected \(names.joined(separator: ", ")) in the app bundle."
    case .modelInputUnsupported:
      return "Face embedding model input is unsupported. Expected an image or numeric multi-array input."
    case .modelOutputUnsupported:
      return "Face embedding model output is unsupported. Expected a numeric multi-array embedding."
    case .pixelBufferCreationFailed:
      return "Could not create a Core ML pixel buffer for the face crop."
    case .invalidImageData:
      return "Could not read face crop image data."
    case .invalidEmbeddingDimension:
      return "Face embedding model returned an empty or inconsistent vector."
    case .invalidEmbeddingValues(let reason):
      return "Face embedding model returned an invalid vector: \(reason)."
    }
  }
}

enum FaceEmbeddingModelFactory {
  static let sourceName = "Xiaoccer/MobileFaceNet_Pytorch"
  static let sourceDescription = "MobileFaceNet Core ML face embedding model converted from Xiaoccer/MobileFaceNet_Pytorch"
  static let preferredModelName = "MobileFaceNet"
  static let preprocessingVersion = "xiaoccer-mobilefacenet-rgb-minus-127p5-div-128-v1"
  static let expectedModelNames = ["MobileFaceNet", "FaceNet", "FaceEmbedding"]

  static func makeModel() -> FaceEmbeddingModel {
    if IdentityConfig.useMockEmbeddingModel {
      return MockFaceEmbeddingModel()
    }
    let cloudSettings = CloudFaceEmbeddingSettings.load()
    guard let modelURL = CoreMLFaceNetEmbeddingModel.findBundledModelURL() else {
      let error = FaceEmbeddingError.coreMLModelMissing(expectedNames: expectedModelResourceNames())
      AppLogger.log(.faceEmbedding, "MobileFaceNet/Core ML model unavailable: \(error.localizedDescription)")
      if cloudSettings.enabled {
        AppLogger.log(.faceEmbeddingModel, "Using cloud AdaFace face embedding model without local fallback endpoint=\(cloudSettings.endpoint)")
        return CloudFaceEmbeddingModel(settings: cloudSettings)
      }
      return MissingFaceEmbeddingModel(expectedNames: expectedModelNames)
    }
    let local = LazyCoreMLFaceNetEmbeddingModel(modelURL: modelURL)
    if cloudSettings.enabled {
      AppLogger.log(.faceEmbeddingModel, "Using cloud AdaFace face embedding model with local MobileFaceNet fallback endpoint=\(cloudSettings.endpoint)")
      return CloudFallbackFaceEmbeddingModel(settings: cloudSettings, local: local)
    }
    return local
  }

  static func statusText() -> String {
    if IdentityConfig.useMockEmbeddingModel {
      return "Debug stub embeddings enabled"
    }
    return CoreMLFaceNetEmbeddingModel.findBundledModelURL(logSearch: false) == nil
      ? "Face recognition model missing"
      : "Face recognition model found; loading on demand"
  }

  static func expectedModelResourceInstructions() -> String {
    "Add MobileFaceNet.mlpackage converted from https://github.com/Xiaoccer/MobileFaceNet_Pytorch to the CameraAccess app target and verify Copy Bundle Resources. FaceNet and FaceEmbedding are checked only as explicit fallback resources."
  }

  static func diagnosticsText(bundle: Bundle = .main) -> String {
    let resolved = CoreMLFaceNetEmbeddingModel.findBundledModelURL(in: bundle, logSearch: false)
    let candidates = CoreMLFaceNetEmbeddingModel.modelSearchCandidatePaths(in: bundle)
    let status = resolved == nil ? "modelLoaded=false" : "modelLoaded=pendingLoad"
    return "\(status) source=\(sourceName) preferredModel=MobileFaceNet bundlePath=\(bundle.bundlePath) resolvedPath=\(resolved?.path ?? "none") searchedCandidatePaths=[\(candidates.joined(separator: ", "))] inputNames=unknownUntilLoad outputNames=unknownUntilLoad expectedInputShape=unknownUntilLoad outputEmbeddingDimension=unknownUntilLoad preprocessing=\(preprocessingVersion) lastModelLoadError=\(resolved == nil ? FaceEmbeddingError.coreMLModelMissing(expectedNames: expectedModelResourceNames()).localizedDescription : "none")"
  }

  static func expectedModelResourceNames() -> [String] {
    [
      "MobileFaceNet.mlpackage",
      "MobileFaceNet.mlmodel",
      "MobileFaceNet.mlmodelc",
      "FaceNet.mlpackage",
      "FaceNet.mlmodel",
      "FaceNet.mlmodelc",
      "FaceEmbedding.mlpackage",
      "FaceEmbedding.mlmodel",
      "FaceEmbedding.mlmodelc"
    ]
  }
}

struct CoreMLFaceNetEmbeddingModel: FaceEmbeddingModel {
  enum PreprocessingMode: String {
    case coreMLImageInput
    case xiaoccerRGBMinus127p5Div128
  }

  let embeddingDimension: Int
  let inputImageSize: CGSize
  let modelName: String
  let modelVersion: String
  let preprocessingMode: PreprocessingMode

  private let model: MLModel
  private let inputName: String
  private let inputType: MLFeatureType
  private let inputMultiArrayShape: [Int]?
  private let outputName: String
  private let ciContext = CIContext()

  init(bundle: Bundle = .main) throws {
    guard let modelURL = Self.findBundledModelURL(in: bundle) else {
      throw FaceEmbeddingError.coreMLModelMissing(expectedNames: FaceEmbeddingModelFactory.expectedModelResourceNames())
    }
    try self.init(modelURL: modelURL)
  }

  init(modelURL: URL) throws {
    let loadStartedAt = Date()
    let configuration = MLModelConfiguration()
    // Use Neural Engine + CPU; falls back to CPU if Neural Engine is unavailable.
    // Default (no compute units set) often stays on CPU, which is 3-8x slower for this model.
    configuration.computeUnits = .cpuAndNeuralEngine
    let loadedModel: MLModel
    if modelURL.pathExtension == "mlmodel" {
      let compiledURL = try MLModel.compileModel(at: modelURL)
      loadedModel = try MLModel(contentsOf: compiledURL, configuration: configuration)
    } else {
      loadedModel = try MLModel(contentsOf: modelURL, configuration: configuration)
    }

    guard let input = loadedModel.modelDescription.inputDescriptionsByName.first else {
      throw FaceEmbeddingError.modelInputUnsupported
    }
    guard let output = loadedModel.modelDescription.outputDescriptionsByName.first(where: { $0.value.type == .multiArray }) else {
      throw FaceEmbeddingError.modelOutputUnsupported
    }

    model = loadedModel
    inputName = input.key
    inputType = input.value.type
    outputName = output.key
    modelName = modelURL.deletingPathExtension().lastPathComponent
    let metadataVersion = loadedModel.modelDescription.metadata[.versionString] as? String
    let metadata = loadedModel.modelDescription.metadata[.creatorDefinedKey] as? [String: String]
    modelVersion = metadataVersion
      ?? metadata?["xiaoccer_checkpoint"]
      ?? metadata?["source_checkpoint"]
      ?? metadata?["mobilefacenet_checkpoint"]
      ?? metadata?["checkpoint"]
      ?? "mobilefacenet-unknown-checkpoint"
    inputImageSize = Self.inferInputSize(from: input.value) ?? Self.defaultInputImageSize
    inputMultiArrayShape = input.value.multiArrayConstraint?.shape.map(\.intValue)
    preprocessingMode = input.value.type == .image ? .coreMLImageInput : .xiaoccerRGBMinus127p5Div128
    embeddingDimension = Self.inferEmbeddingDimension(from: output.value) ?? 0

    if Self.inferInputSize(from: input.value) == nil {
      AppLogger.log(.faceEmbedding, "MobileFaceNet/Core ML input size not declared; defaulting to Xiaoccer MobileFaceNet size 96x112")
    }
    if inputImageSize != Self.defaultInputImageSize {
      AppLogger.log(.faceEmbeddingModel, "MobileFaceNet model declares inputSize=\(Int(inputImageSize.width))x\(Int(inputImageSize.height)); using declared model input size")
    }

    // Structured shape log — tasks 1, 2, 3: runtime-verified, not hardcoded.
    let rawShape = inputMultiArrayShape?.map(String.init).joined(separator: "x") ?? "imageInput"
    let layoutStr = Self.isNHWC(inputMultiArrayShape ?? []) ? "NHWC" : "NCHW"
    AppLogger.log(
      .faceEmbeddingModel,
      "inputShape=\(rawShape) inputWidth=\(Int(inputImageSize.width)) inputHeight=\(Int(inputImageSize.height)) layout=\(layoutStr) embeddingDim=\(embeddingDimension) preprocessingMode=\(preprocessingMode.rawValue)"
    )

    // Push the declared size into shared config so FaceCropper uses the same dimensions
    // without hardcoding — satisfies task 2.
    IdentityConfig.activeEmbeddingModelInputSize = inputImageSize

    AppLogger.log(
      .faceEmbeddingModel,
      "loaded name=\(modelName) source=\(FaceEmbeddingModelFactory.sourceName) path=\(modelURL.path) input=\(inputName) output=\(outputName) inputSize=\(Int(inputImageSize.width))x\(Int(inputImageSize.height)) dim=\(embeddingDimension) elapsedMs=\(String(format: "%.1f", Date().timeIntervalSince(loadStartedAt) * 1_000))"
    )
    AppLogger.log(
      .faceEmbeddingModel,
      "modelDescription inputs=[\(Self.featureSummaries(loadedModel.modelDescription.inputDescriptionsByName))] outputs=[\(Self.featureSummaries(loadedModel.modelDescription.outputDescriptionsByName))]"
    )
    AppLogger.log(
      .faceEmbedding,
      "MobileFaceNet/Core ML model loaded modelName=\(modelName) modelVersion=\(modelVersion) source=\(FaceEmbeddingModelFactory.sourceName) embeddingDimension=\(embeddingDimension) inputImageSize=\(Int(inputImageSize.width))x\(Int(inputImageSize.height)) preprocessing=\(preprocessingMode.rawValue)"
    )
  }

  func load() async throws {
    // Loading is completed in init so failures surface before identity processing starts.
  }

  func embed(faceImage: CGImage) async throws -> FaceEmbeddingVector {
    let startedAt = Date()
    let inputValue: MLFeatureValue
    switch inputType {
    case .image:
      let pixelBuffer = try makePixelBuffer(from: faceImage, size: inputImageSize)
      inputValue = MLFeatureValue(pixelBuffer: pixelBuffer)
    case .multiArray:
      inputValue = MLFeatureValue(multiArray: try makeRGBMultiArray(from: faceImage, size: inputImageSize, declaredShape: inputMultiArrayShape))
    default:
      throw FaceEmbeddingError.modelInputUnsupported
    }

    let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: inputValue])
    let output = try await model.prediction(from: provider)
    guard let multiArray = output.featureValue(for: outputName)?.multiArrayValue else {
      throw FaceEmbeddingError.modelOutputUnsupported
    }
    let vector = Self.vector(from: multiArray)
    let normBefore = Self.l2Norm(vector)
    guard vector.allSatisfy({ $0.isFinite }) else {
      throw FaceEmbeddingError.invalidEmbeddingValues("contains NaN or infinite values")
    }
    guard normBefore > 0.000001 else {
      throw FaceEmbeddingError.invalidEmbeddingValues("near-zero norm")
    }
    let normalized = Self.l2Normalized(vector)
    let normAfter = Self.l2Norm(normalized)
    guard !normalized.isEmpty else {
      throw FaceEmbeddingError.invalidEmbeddingDimension
    }
    let elapsedMS = Date().timeIntervalSince(startedAt) * 1_000
    AppLogger.log(
      .faceEmbedding,
      "model=\(modelName) modelVersion=\(modelVersion) source=\(FaceEmbeddingModelFactory.sourceName) embeddingDimension=\(normalized.count) inputImageSize=\(Int(inputImageSize.width))x\(Int(inputImageSize.height)) preprocessing=\(preprocessingMode.rawValue) inferenceMs=\(String(format: "%.1f", elapsedMS))"
    )
    AppLogger.log(
      .faceEmbeddingVector,
      "model=\(modelName) source=\(FaceEmbeddingModelFactory.sourceName) dim=\(normalized.count) normBefore=\(String(format: "%.5f", normBefore)) normAfter=\(String(format: "%.3f", normAfter)) valid=true"
    )
    return FaceEmbedding(
      vector: normalized,
      dimension: normalized.count,
      modelName: modelName,
      modelVersion: modelVersion,
      modelSource: FaceEmbeddingModelFactory.sourceName,
      preprocessingVersion: FaceEmbeddingModelFactory.preprocessingVersion,
      createdAt: Date()
    )
  }

  private func makePixelBuffer(from image: CGImage, size: CGSize) throws -> CVPixelBuffer {
    let width = Int(size.width)
    let height = Int(size.height)
    var pixelBuffer: CVPixelBuffer?
    let attrs: [CFString: Any] = [
      kCVPixelBufferCGImageCompatibilityKey: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey: true,
      kCVPixelBufferIOSurfacePropertiesKey: [:]
    ]
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      width,
      height,
      kCVPixelFormatType_32ARGB,
      attrs as CFDictionary,
      &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
      throw FaceEmbeddingError.pixelBufferCreationFailed
    }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard let context = CGContext(
      data: CVPixelBufferGetBaseAddress(pixelBuffer),
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
    ) else {
      throw FaceEmbeddingError.pixelBufferCreationFailed
    }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return pixelBuffer
  }

  private func makeRGBMultiArray(from image: CGImage, size: CGSize, declaredShape: [Int]?) throws -> MLMultiArray {
    let width = Int(size.width)
    let height = Int(size.height)
    let intShape = Self.usableInputShape(declaredShape, width: width, height: height)
    let shape = intShape.map(NSNumber.init(value:))
    let array = try MLMultiArray(shape: shape, dataType: .float32)
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var buffer = [UInt8](repeating: 0, count: height * bytesPerRow)
    guard let context = CGContext(
      data: &buffer,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: bytesPerRow,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      throw FaceEmbeddingError.invalidImageData
    }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    for y in 0..<height {
      for x in 0..<width {
        let base = y * bytesPerRow + x * bytesPerPixel
        let values: [Float] = [
          Self.xiaoccerMobileFaceNetNormalizedChannel(buffer[base]),
          Self.xiaoccerMobileFaceNetNormalizedChannel(buffer[base + 1]),
          Self.xiaoccerMobileFaceNetNormalizedChannel(buffer[base + 2])
        ]
        if Self.isNHWC(intShape) {
          for channel in 0..<3 {
            array[[0, NSNumber(value: y), NSNumber(value: x), NSNumber(value: channel)]] = NSNumber(value: values[channel])
          }
        } else {
          for channel in 0..<3 {
            array[[0, NSNumber(value: channel), NSNumber(value: y), NSNumber(value: x)]] = NSNumber(value: values[channel])
          }
        }
      }
    }
    return array
  }

  static func findBundledModelURL(in bundle: Bundle = .main, logSearch: Bool = true) -> URL? {
    let bundlePath = bundle.bundlePath
    let candidates = modelSearchCandidatePaths(in: bundle)
    if logSearch {
      AppLogger.log(
        .faceEmbedding,
        "MobileFaceNet/Core ML model search source=\(FaceEmbeddingModelFactory.sourceName) preferred=MobileFaceNet bundle=\(bundlePath) candidates=[\(candidates.joined(separator: ", "))]"
      )
    }
    for candidate in modelResourceCandidates {
      if let url = bundle.url(forResource: candidate.name, withExtension: candidate.ext) {
        if logSearch {
          AppLogger.log(.faceEmbedding, "MobileFaceNet/Core ML model candidate found path=\(url.path) fallback=\(candidate.name != FaceEmbeddingModelFactory.preferredModelName)")
        }
        return url
      }
    }
    return nil
  }

  static func modelSearchCandidatePaths(in bundle: Bundle = .main) -> [String] {
    let resourceBase = bundle.resourceURL ?? URL(fileURLWithPath: bundle.bundlePath, isDirectory: true)
    return modelResourceCandidates.map { candidate in
      resourceBase.appendingPathComponent("\(candidate.name).\(candidate.ext)").path
    }
  }

  private static let modelResourceCandidates: [(name: String, ext: String)] = [
    ("MobileFaceNet", "mlpackage"),
    ("MobileFaceNet", "mlmodel"),
    ("MobileFaceNet", "mlmodelc"),
    ("FaceNet", "mlpackage"),
    ("FaceNet", "mlmodel"),
    ("FaceNet", "mlmodelc"),
    ("FaceEmbedding", "mlpackage"),
    ("FaceEmbedding", "mlmodel"),
    ("FaceEmbedding", "mlmodelc")
  ]

  private static func inferInputSize(from description: MLFeatureDescription) -> CGSize? {
    if let constraint = description.imageConstraint {
      return CGSize(width: constraint.pixelsWide, height: constraint.pixelsHigh)
    }
    guard let shape = description.multiArrayConstraint?.shape.map(\.intValue) else { return nil }
    let dims = shape.filter { $0 > 4 }
    guard dims.count >= 2 else { return nil }
    return CGSize(width: dims.last ?? 112, height: dims.dropLast().last ?? dims.last ?? 112)
  }

  private static var defaultInputImageSize: CGSize {
    CGSize(width: 96, height: 112)
  }

  private static func xiaoccerMobileFaceNetNormalizedChannel(_ byte: UInt8) -> Float {
    (Float(byte) - 127.5) / 128.0
  }

  private static func usableInputShape(_ declaredShape: [Int]?, width: Int, height: Int) -> [Int] {
    guard let declaredShape, declaredShape.count == 4, declaredShape.allSatisfy({ $0 > 0 }) else {
      return [1, 3, height, width]
    }
    return declaredShape
  }

  private static func isNHWC(_ shape: [Int]) -> Bool {
    shape.count == 4 && shape.last == 3
  }

  private static func inferEmbeddingDimension(from description: MLFeatureDescription) -> Int? {
    guard let shape = description.multiArrayConstraint?.shape.map(\.intValue), !shape.isEmpty else { return nil }
    return shape.reduce(1, *)
  }

  private static func featureSummaries(_ descriptions: [String: MLFeatureDescription]) -> String {
    descriptions
      .sorted { $0.key < $1.key }
      .map { name, description in featureSummary(name: name, description: description) }
      .joined(separator: "; ")
  }

  private static func featureSummary(name: String, description: MLFeatureDescription) -> String {
    var parts = ["\(name):type=\(description.type)"]
    if let image = description.imageConstraint {
      parts.append("image=\(image.pixelsWide)x\(image.pixelsHigh)")
      parts.append("pixelFormat=\(image.pixelFormatType)")
    }
    if let array = description.multiArrayConstraint {
      let shape = array.shape.map(\.stringValue).joined(separator: "x")
      parts.append("shape=\(shape)")
      parts.append("dataType=\(array.dataType)")
    }
    return parts.joined(separator: ",")
  }

  private static func vector(from multiArray: MLMultiArray) -> [Float] {
    (0..<multiArray.count).map { Float(truncating: multiArray[$0]) }
  }

  static func l2Normalized(_ vector: [Float]) -> [Float] {
    let norm = l2Norm(vector)
    guard norm > 0 else { return vector }
    return vector.map { $0 / norm }
  }

  static func l2Norm(_ vector: [Float]) -> Float {
    sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
  }
}

actor LazyCoreMLFaceNetEmbeddingModel: FaceEmbeddingModel {
  nonisolated let embeddingDimension = 0
  nonisolated let inputImageSize = CGSize(width: 96, height: 112)
  nonisolated let modelName: String
  nonisolated let modelVersion = "loading"

  private let modelURL: URL
  private var loadedModel: CoreMLFaceNetEmbeddingModel?
  private var loadTask: Task<CoreMLFaceNetEmbeddingModel, Error>?

  init(modelURL: URL) {
    self.modelURL = modelURL
    modelName = modelURL.deletingPathExtension().lastPathComponent
  }

  func load() async throws {
    _ = try await resolvedModel()
  }

  func embed(faceImage: CGImage) async throws -> FaceEmbeddingVector {
    let model = try await resolvedModel()
    return try await model.embed(faceImage: faceImage)
  }

  private func resolvedModel() async throws -> CoreMLFaceNetEmbeddingModel {
    if let loadedModel {
      return loadedModel
    }
    if let loadTask {
      let model = try await loadTask.value
      loadedModel = model
      return model
    }
    let url = modelURL
    let task = Task.detached(priority: .utility) {
      try CoreMLFaceNetEmbeddingModel(modelURL: url)
    }
    loadTask = task
    do {
      let model = try await task.value
      loadedModel = model
      loadTask = nil
      return model
    } catch {
      loadTask = nil
      throw error
    }
  }
}

struct MissingFaceEmbeddingModel: FaceEmbeddingModel {
  let expectedNames: [String]
  let embeddingDimension = 0
  let inputImageSize = CGSize(width: 96, height: 112)
  let modelName = "MissingFaceEmbeddingModel"
  let modelVersion = "missing"

  func load() async throws {
    throw FaceEmbeddingError.coreMLModelMissing(expectedNames: FaceEmbeddingModelFactory.expectedModelResourceNames())
  }

  func embed(faceImage: CGImage) async throws -> FaceEmbeddingVector {
    throw FaceEmbeddingError.coreMLModelMissing(expectedNames: FaceEmbeddingModelFactory.expectedModelResourceNames())
  }
}

struct MockFaceEmbeddingModel: FaceEmbeddingModel {
  let embeddingDimension = 128
  let inputImageSize = CGSize(width: 96, height: 112)
  let modelName = "MockFaceEmbeddingModel"
  let modelVersion = "debug-stub-v1"

  init() {
    AppLogger.log(.faceEmbedding, "DEBUG stub embedding used, not valid for identity recognition")
  }

  func load() async throws {
    AppLogger.log(.faceEmbedding, "DEBUG stub embedding model loaded, not valid for identity recognition")
  }

  func embed(faceImage: CGImage) async throws -> FaceEmbeddingVector {
    let image = UIImage(cgImage: faceImage)
    guard let data = image.jpegData(compressionQuality: 0.25) else {
      throw FaceEmbeddingError.invalidImageData
    }

    var vector: [Float] = []
    var counter: UInt8 = 0
    while vector.count < embeddingDimension {
      var bytes = Data()
      bytes.append(data)
      bytes.append(counter)
      let digest = SHA256.hash(data: bytes)
      for byte in digest {
        let centered = (Float(byte) / 255.0) * 2.0 - 1.0
        vector.append(centered)
        if vector.count == embeddingDimension { break }
      }
      counter &+= 1
    }
    let normalized = Self.l2Normalized(vector)
    return FaceEmbedding(
      vector: normalized,
      dimension: normalized.count,
      modelName: modelName,
      modelVersion: modelVersion,
      modelSource: "debug-stub",
      preprocessingVersion: "debug-stub",
      createdAt: Date()
    )
  }

  static func l2Normalized(_ vector: [Float]) -> [Float] {
    let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
    guard norm > 0 else { return vector }
    return vector.map { $0 / norm }
  }
}
