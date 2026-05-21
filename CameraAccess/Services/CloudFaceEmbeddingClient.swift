import CoreGraphics
import Foundation
import UIKit

struct CloudFaceEmbeddingSettings {
  private enum Keys {
    static let enabled = "cloudFaceEmbedding.enabled"
    static let endpoint = "cloudFaceEmbedding.endpoint"
    static let apiKey = "cloudFaceEmbedding.apiKey"
  }

  static let defaultEndpoint = "https://YOUR_G4DN_WORKER_HOST"

  var enabled: Bool
  var endpoint: String
  var apiKey: String

  static func load() -> CloudFaceEmbeddingSettings {
    let defaults = UserDefaults.standard
    return CloudFaceEmbeddingSettings(
      enabled: defaults.bool(forKey: Keys.enabled),
      endpoint: defaults.string(forKey: Keys.endpoint) ?? defaultEndpoint,
      apiKey: defaults.string(forKey: Keys.apiKey) ?? ""
    )
  }

  func save() {
    let defaults = UserDefaults.standard
    defaults.set(enabled, forKey: Keys.enabled)
    defaults.set(endpoint.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.endpoint)
    defaults.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.apiKey)
  }
}

enum CloudFaceEmbeddingError: LocalizedError {
  case disabled
  case invalidEndpoint
  case imageEncodingFailed
  case badHTTPStatus(Int, String)
  case invalidEmbedding(String)

  var errorDescription: String? {
    switch self {
    case .disabled:
      return "Cloud face embeddings are disabled."
    case .invalidEndpoint:
      return "Cloud face embedding endpoint is invalid."
    case .imageEncodingFailed:
      return "Could not encode face crop for cloud embedding."
    case .badHTTPStatus(let status, let body):
      return "Cloud face embedding returned HTTP \(status): \(body)"
    case .invalidEmbedding(let reason):
      return "Cloud face embedding response is invalid: \(reason)"
    }
  }
}

struct CloudFaceEmbeddingClient {
  private let baseURL: URL
  private let apiKey: String
  private let session: URLSession

  init(endpoint: String, apiKey: String, session: URLSession = .shared) throws {
    let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
      throw CloudFaceEmbeddingError.invalidEndpoint
    }
    baseURL = url
    self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    self.session = session
  }

  func embed(faceImage: CGImage) async throws -> FaceEmbedding {
    var url = baseURL
    url.appendPathComponent("face")
    url.appendPathComponent("embed")

    guard let jpeg = UIImage(cgImage: faceImage).jpegData(compressionQuality: 0.92) else {
      throw CloudFaceEmbeddingError.imageEncodingFailed
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 10
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if !apiKey.isEmpty {
      request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }
    request.httpBody = try JSONEncoder().encode(EmbeddingRequest(
      imageBase64: jpeg.base64EncodedString(),
      imageFormat: "jpeg"
    ))

    let startedAt = Date()
    let (data, response) = try await session.data(for: request)
    try validate(response: response, data: data)
    let decoded = try JSONDecoder().decode(EmbeddingResponse.self, from: data)
    let normalized = try normalize(decoded.embedding)
    let elapsedMS = Date().timeIntervalSince(startedAt) * 1_000
    AppLogger.log(
      .faceEmbedding,
      "Cloud AdaFace embedding succeeded model=\(decoded.modelName) version=\(decoded.modelVersion) dim=\(normalized.count) elapsedMs=\(String(format: "%.1f", elapsedMS))"
    )
    return FaceEmbedding(
      vector: normalized,
      dimension: normalized.count,
      modelName: decoded.modelName,
      modelVersion: decoded.modelVersion,
      modelSource: decoded.modelSource,
      preprocessingVersion: decoded.preprocessingVersion,
      createdAt: Date()
    )
  }

  private func validate(response: URLResponse, data: Data) throws {
    guard let http = response as? HTTPURLResponse else {
      throw CloudFaceEmbeddingError.invalidEmbedding("missing HTTP response")
    }
    guard (200..<300).contains(http.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? ""
      throw CloudFaceEmbeddingError.badHTTPStatus(http.statusCode, body)
    }
  }

  private func normalize(_ vector: [Float]) throws -> [Float] {
    guard !vector.isEmpty else {
      throw CloudFaceEmbeddingError.invalidEmbedding("empty vector")
    }
    var sum: Float = 0
    for value in vector {
      guard value.isFinite else {
        throw CloudFaceEmbeddingError.invalidEmbedding("non-finite value")
      }
      sum += value * value
    }
    let norm = sqrt(sum)
    guard norm > 1e-6 else {
      throw CloudFaceEmbeddingError.invalidEmbedding("near-zero norm")
    }
    return vector.map { $0 / norm }
  }

  private struct EmbeddingRequest: Encodable {
    let imageBase64: String
    let imageFormat: String

    enum CodingKeys: String, CodingKey {
      case imageBase64 = "image_base64"
      case imageFormat = "image_format"
    }
  }

  private struct EmbeddingResponse: Decodable {
    let embedding: [Float]
    let modelName: String
    let modelVersion: String
    let modelSource: String
    let preprocessingVersion: String

    enum CodingKeys: String, CodingKey {
      case embedding
      case modelName = "model_name"
      case modelVersion = "model_version"
      case modelSource = "model_source"
      case preprocessingVersion = "preprocessing_version"
    }
  }
}

actor CloudFaceEmbeddingModel: FaceEmbeddingModel {
  let embeddingDimension = 512
  let inputImageSize = CGSize(width: 112, height: 112)
  let modelName = "AdaFace"
  let modelVersion = "cvlface_adaface_ir101_webface12m"
  private let settings: CloudFaceEmbeddingSettings

  init(settings: CloudFaceEmbeddingSettings) {
    self.settings = settings
  }

  func load() async throws {
    guard settings.enabled else {
      throw CloudFaceEmbeddingError.disabled
    }
    _ = try CloudFaceEmbeddingClient(endpoint: settings.endpoint, apiKey: settings.apiKey)
  }

  func embed(faceImage: CGImage) async throws -> FaceEmbeddingVector {
    guard settings.enabled else {
      throw CloudFaceEmbeddingError.disabled
    }
    let client = try CloudFaceEmbeddingClient(endpoint: settings.endpoint, apiKey: settings.apiKey)
    return try await client.embed(faceImage: faceImage)
  }
}

actor CloudFallbackFaceEmbeddingModel: FaceEmbeddingModel {
  private let cloud: CloudFaceEmbeddingModel
  private let local: FaceEmbeddingModel

  let embeddingDimension: Int
  let inputImageSize: CGSize
  let modelName = "CloudAdaFaceWithLocalFallback"
  let modelVersion = "cloud-adaface-ir101-local-mobilefacenet-v1"

  init(settings: CloudFaceEmbeddingSettings, local: FaceEmbeddingModel) {
    cloud = CloudFaceEmbeddingModel(settings: settings)
    self.local = local
    embeddingDimension = cloud.embeddingDimension
    inputImageSize = cloud.inputImageSize
  }

  func load() async throws {
    try? await cloud.load()
    try? await local.load()
  }

  func embed(faceImage: CGImage) async throws -> FaceEmbeddingVector {
    do {
      return try await cloud.embed(faceImage: faceImage)
    } catch {
      AppLogger.log(.faceEmbedding, "Cloud AdaFace embedding failed; falling back to local model: \(error.localizedDescription)")
      return try await local.embed(faceImage: faceImage)
    }
  }
}
