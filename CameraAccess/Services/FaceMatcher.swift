import Foundation

struct FaceMatcher {
  // These thresholds are placeholders. They must be calibrated with real
  // samples from the exact model, preprocessing pipeline, crop alignment,
  // glasses camera resolution, and lighting conditions.
  var knownThreshold = IdentityConfig.strongMatchThreshold
  var unknownThreshold = IdentityConfig.weakMatchThreshold
  var marginThreshold = IdentityConfig.matchMarginThreshold

  func match(embedding: FaceEmbedding, against records: [PersonAveragedEmbedding]) -> IdentityMatchResult {
    match(
      vector: embedding.vector,
      modelName: embedding.modelName,
      modelVersion: embedding.modelVersion,
      modelSource: embedding.modelSource,
      preprocessingVersion: embedding.preprocessingVersion,
      against: records
    )
  }

  func match(vector: [Float], against records: [PersonAveragedEmbedding]) -> IdentityMatchResult {
    match(vector: vector, modelName: nil, modelVersion: nil, modelSource: nil, preprocessingVersion: nil, against: records)
  }

  func match(
    vector: [Float],
    modelName: String?,
    modelVersion: String?,
    modelSource: String? = nil,
    preprocessingVersion: String? = nil,
    against records: [PersonAveragedEmbedding]
  ) -> IdentityMatchResult {
    let candidates = records
      .filter {
        $0.vectorDimension == vector.count
          && $0.averagedVector.count == vector.count
          && (modelName == nil || $0.modelName == modelName)
          && (modelVersion == nil || $0.modelVersion == modelVersion)
          && (modelSource == nil || $0.modelSource == modelSource)
          && (preprocessingVersion == nil || $0.preprocessingVersion == preprocessingVersion)
      }
      .map { record in
        (
          record: record,
          similarity: Self.cosineSimilarity(vector, record.averagedVector),
          distance: Self.l2Distance(vector, record.averagedVector)
        )
      }
      .sorted { $0.similarity > $1.similarity }

    guard let best = candidates.first else {
      return IdentityMatchResult(
        bestPersonId: nil,
        bestSimilarity: 0,
        secondBestSimilarity: nil,
        margin: nil,
        decision: .unknown,
        matchedEmbeddingId: nil,
        l2Distance: nil
      )
    }

    let second = candidates.dropFirst().first?.similarity
    let margin = second.map { best.similarity - $0 }
    let decision: IdentityMatchResult.Decision
    if best.similarity >= knownThreshold && (margin == nil || margin! >= marginThreshold) {
      decision = .known
    } else if best.similarity >= unknownThreshold {
      decision = .ambiguous
    } else {
      decision = .unknown
    }

    return IdentityMatchResult(
      bestPersonId: best.record.personId,
      bestSimilarity: best.similarity,
      secondBestSimilarity: second,
      margin: margin,
      decision: decision,
      matchedEmbeddingId: best.record.id,
      l2Distance: best.distance
    )
  }

  func match(vector: [Float], against records: [FaceEmbeddingRecord]) -> IdentityMatchResult {
    // Reduce to per-person best: for each enrolled person, keep only their highest-scoring sample.
    // This prevents same-person samples from competing with each other in the margin calculation,
    // which would artificially shrink the inter-person margin and produce false ambiguous decisions.
    let perPersonBest: [(record: FaceEmbeddingRecord, similarity: Float)] = {
      var best: [UUID: (record: FaceEmbeddingRecord, similarity: Float)] = [:]
      for record in records where record.personId != nil && record.dimension == vector.count && record.vector.count == vector.count {
        let sim = Self.cosineSimilarity(vector, record.vector)
        if let existing = best[record.personId!] {
          if sim > existing.similarity { best[record.personId!] = (record, sim) }
        } else {
          best[record.personId!] = (record, sim)
        }
      }
      return best.values.sorted { $0.similarity > $1.similarity }
    }()

    guard let best = perPersonBest.first else {
      return IdentityMatchResult(
        bestPersonId: nil,
        bestSimilarity: 0,
        secondBestSimilarity: nil,
        margin: nil,
        decision: .unknown,
        matchedEmbeddingId: nil,
        l2Distance: nil
      )
    }

    // second is the best score from a different person — the true inter-person margin.
    let second = perPersonBest.dropFirst().first?.similarity
    let margin = second.map { best.similarity - $0 }
    let decision: IdentityMatchResult.Decision
    if best.similarity >= knownThreshold && (margin == nil || margin! >= marginThreshold) {
      decision = .known
    } else if best.similarity >= unknownThreshold {
      decision = .ambiguous
    } else {
      decision = .unknown
    }

    return IdentityMatchResult(
      bestPersonId: best.record.personId,
      bestSimilarity: best.similarity,
      secondBestSimilarity: second,
      margin: margin,
      decision: decision,
      matchedEmbeddingId: best.record.id,
      l2Distance: Self.l2Distance(vector, best.record.vector)
    )
  }

  static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float {
    guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
    var dot: Float = 0
    for index in lhs.indices {
      dot += lhs[index] * rhs[index]
    }
    return dot
  }

  static func l2Distance(_ lhs: [Float], _ rhs: [Float]) -> Float {
    guard lhs.count == rhs.count, !lhs.isEmpty else { return .greatestFiniteMagnitude }
    var sum: Float = 0
    for index in lhs.indices {
      let delta = lhs[index] - rhs[index]
      sum += delta * delta
    }
    return sqrt(sum)
  }
}

extension IdentityMatchResult.Decision {
  var eventDecision: String {
    switch self {
    case .known:
      return "possibleMatch"
    case .ambiguous:
      return "possibleMatch"
    case .unknown:
      return "unknown"
    }
  }
}
