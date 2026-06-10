import Foundation
import UIKit

// SupabaseIdentityStore — write-only mirror of LocalIdentityStore against
// Postgres + Storage. Every method is idempotent (upsert on primary key) so
// the retry queue can safely re-run it after a failure.
//
// This struct is NOT what IdentityPipeline talks to directly. The pipeline
// uses SyncingIdentityStore, which delegates reads to Local and fans writes
// out to Local + this store via IdentitySyncQueue.
//
// Face crops are uploaded to the `face-crops` Storage bucket at the path
// `<auth.uid()>/<personId-or-unknown>/<embeddingId>.jpg`. The storage RLS
// policies in 0003_storage_rls.sql enforce that prefix.

actor SupabaseIdentityStore {
  enum FaceCropImageSource {
    /// Read the JPEG bytes from `sampleImageLocalPath` on the local filesystem.
    case localPath(String)
    /// Use the JPEG bytes directly.
    case data(Data)
  }

  private let client: SupabaseClient
  private let auth: SupabaseSession
  private let settings: SupabaseSettings
  private let bucketID = "face-crops"
  private let urlSession: URLSession

  init?(client: SupabaseClient? = nil) {
    guard let settings = SupabaseSettings.load() else { return nil }
    do {
      let client = try (client ?? SupabaseClient.shared())
      self.client = client
      self.settings = settings
      self.auth = SupabaseSession.shared
      self.urlSession = .shared
      if settings.usesServiceRole {
        AppLogger.log(.database, "[SUPABASE_STORE] using explicit DEBUG service-role override")
      }
    } catch {
      AppLogger.log(.database, "[SUPABASE_STORE] init failed: \(error.localizedDescription)")
      return nil
    }
  }

  // MARK: - Writes (mirrors of LocalIdentityStore methods)

  func upsertAppRun(_ run: AppRun) async throws {
    try await client.upsert(
      table: SupabaseTable.appRuns,
      rows: [SupabaseRowAppRun(run)],
      onConflict: "id"
    )
  }

  func upsertPersonProfile(_ profile: PersonProfile) async throws {
    try await client.upsert(
      table: SupabaseTable.personProfiles,
      rows: [SupabaseRowPersonProfile(profile)],
      onConflict: "id"
    )
  }

  func upsertConversationSession(_ session: ConversationSession) async throws {
    try await client.upsert(
      table: SupabaseTable.conversationSessions,
      rows: [SupabaseRowConversationSession(session)],
      onConflict: "id"
    )
  }

  /// Uploads the face crop image (if provided) and inserts the embedding row
  /// with the resulting storage path.
  func upsertFaceEmbedding(
    _ record: FaceEmbeddingRecord,
    image: FaceCropImageSource?
  ) async throws {
    var storagePath: String?
    if let image, let jpeg = try Self.jpegBytes(image) {
      storagePath = try await uploadFaceCrop(record: record, jpeg: jpeg)
    }
    try await client.upsert(
      table: SupabaseTable.faceEmbeddings,
      rows: [SupabaseRowFaceEmbedding(record, sampleImageStoragePath: storagePath)],
      onConflict: "id"
    )
  }

  func upsertPersonAveragedEmbedding(_ avg: PersonAveragedEmbedding) async throws {
    try await client.upsert(
      table: SupabaseTable.personAveragedFaceEmbeddings,
      rows: [SupabaseRowPersonAveragedEmbedding(avg)],
      onConflict: "person_id,model_name,model_version,model_source,preprocessing_version,vector_dimension"
    )
  }

  func upsertTranscriptChunk(_ chunk: TranscriptChunk) async throws {
    try await client.upsert(
      table: SupabaseTable.transcriptChunks,
      rows: [SupabaseRowTranscriptChunk(chunk)],
      onConflict: "id"
    )
  }

  func insertFaceDetectionEvent(_ event: FaceDetectionEvent) async throws {
    // Append-only events use insert semantics; upsert on id keeps it idempotent
    // if a retry fires after the original succeeded but ack was lost.
    try await client.upsert(
      table: SupabaseTable.faceDetectionEvents,
      rows: [SupabaseRowFaceDetectionEvent(event)],
      onConflict: "id"
    )
  }

  func insertIdentityMatchEvent(_ event: IdentityMatchEvent) async throws {
    try await client.upsert(
      table: SupabaseTable.identityMatchEvents,
      rows: [SupabaseRowIdentityMatchEvent(event)],
      onConflict: "id"
    )
  }

  func upsertSceneContext(_ record: SceneContextRecord) async throws {
    try await client.upsert(
      table: SupabaseTable.sceneContextRecords,
      rows: [SupabaseRowSceneContext(record)],
      onConflict: "id"
    )
  }

  func upsertPresenceEpisode(_ record: PresenceEpisodeRecord) async throws {
    try await client.upsert(
      table: SupabaseTable.presenceEpisodes,
      rows: [SupabaseRowPresenceEpisode(record)],
      onConflict: "id"
    )
  }

  func upsertActivityModeEpisode(_ record: ActivityModeEpisodeRecord) async throws {
    try await client.upsert(
      table: SupabaseTable.activityModeEpisodes,
      rows: [SupabaseRowActivityModeEpisode(record)],
      onConflict: "id"
    )
  }

  func insertGlassesDisplayInteraction(
    _ event: GlassesDisplayInteractionEvent
  ) async throws {
    try await client.upsert(
      table: SupabaseTable.glassesDisplayInteractionEvents,
      rows: [SupabaseRowGlassesDisplayInteractionEvent(event)],
      onConflict: "id"
    )
  }

  // MARK: - Deletes

  func deletePersonProfile(id: UUID) async throws {
    try await deleteByID(table: SupabaseTable.personProfiles, id: id)
  }

  func deleteFaceEmbeddingsForPerson(personId: UUID) async throws {
    try await deleteByColumn(
      table: SupabaseTable.faceEmbeddings,
      column: "person_id",
      value: personId.uuidString
    )
    try await deleteByColumn(
      table: SupabaseTable.personAveragedFaceEmbeddings,
      column: "person_id",
      value: personId.uuidString
    )
  }

  // MARK: - Storage

  private func uploadFaceCrop(
    record: FaceEmbeddingRecord,
    jpeg: Data
  ) async throws -> String {
    let ownerFolder: String
    if settings.usesServiceRole {
      ownerFolder = "service-role"
    } else {
      ownerFolder = try await auth.signInIfNeeded(
        url: settings.url, anonKey: settings.anonKey
      ).userId
    }

    let personFolder = record.personId?.uuidString ?? "unknown"
    let objectPath = "\(ownerFolder)/\(personFolder)/\(record.id.uuidString).jpg"
    let endpoint = settings.url.appendingPathComponent(
      "storage/v1/object/\(bucketID)/\(objectPath)"
    )

    let bearerToken: String
    if settings.usesServiceRole {
      bearerToken = settings.requestAPIKey
    } else {
      bearerToken = try await auth.currentAccessToken(
        url: settings.url, anonKey: settings.anonKey
      )
    }

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
    request.setValue("true", forHTTPHeaderField: "x-upsert")
    request.setValue(settings.requestAPIKey, forHTTPHeaderField: "apikey")
    request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
    request.httpBody = jpeg

    let (data, response) = try await urlSession.data(for: request)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      let body = String(data: data, encoding: .utf8) ?? ""
      throw SupabaseClientError.badHTTPStatus(http.statusCode, body)
    }
    return objectPath
  }

  // MARK: - Helpers

  private func deleteByID(table: String, id: UUID) async throws {
    try await rawDelete(
      table: table,
      filter: "id=eq.\(id.uuidString.lowercased())"
    )
  }

  private func deleteByColumn(
    table: String, column: String, value: String
  ) async throws {
    try await rawDelete(
      table: table,
      filter: "\(column)=eq.\(value.lowercased())"
    )
  }

  private func rawDelete(table: String, filter: String) async throws {
    let bearerToken: String
    if settings.usesServiceRole {
      bearerToken = settings.requestAPIKey
    } else {
      bearerToken = try await auth.currentAccessToken(
        url: settings.url, anonKey: settings.anonKey
      )
    }
    let components = URLComponents(
      url: settings.url.appendingPathComponent("rest/v1/\(table)"),
      resolvingAgainstBaseURL: false
    )
    let path = components?.url?.absoluteString ?? ""
    let joiner = path.contains("?") ? "&" : "?"
    guard let url = URL(string: path + joiner + filter) else {
      throw SupabaseClientError.invalidEndpoint(table)
    }
    var request = URLRequest(url: url)
    request.httpMethod = "DELETE"
    request.setValue(settings.requestAPIKey, forHTTPHeaderField: "apikey")
    request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
    request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
    let (data, response) = try await urlSession.data(for: request)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      let body = String(data: data, encoding: .utf8) ?? ""
      throw SupabaseClientError.badHTTPStatus(http.statusCode, body)
    }
  }

  private static func jpegBytes(_ source: FaceCropImageSource) throws -> Data? {
    switch source {
    case .data(let data):
      return data
    case .localPath(let path):
      let url = URL(fileURLWithPath: path)
      guard FileManager.default.fileExists(atPath: path) else { return nil }
      let data = try Data(contentsOf: url)
      // If the on-disk file isn't JPEG, transcode via UIImage.
      if data.starts(with: [0xFF, 0xD8]) { return data }
      guard let image = UIImage(data: data),
            let jpeg = image.jpegData(compressionQuality: 0.85) else { return nil }
      return jpeg
    }
  }
}
