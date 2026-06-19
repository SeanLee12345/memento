# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

SwiftUI iOS app that streams video from Meta Ray-Ban smart glasses via the Meta Wearables DAT SDK, runs on-device face detection and recognition, and transcribes speech. The app targets physical iPhones connected to Meta glasses; a Mock Device Kit path supports simulator testing.
The project is pinned to Meta Wearables DAT `0.7.0` and links `MWDATCore`, `MWDATCamera`, and `MWDATDisplay`.

## Build & Run

Open `Memento.xcodeproj` in Xcode, select the `Memento` scheme, and run on a physical iPhone. There is no CLI build script — use Xcode's Product menu or `xcodebuild`:

```sh
# Build only
xcodebuild -project Memento.xcodeproj -scheme Memento -destination 'generic/platform=iOS' build

# Run all unit tests (simulator)
xcodebuild -project Memento.xcodeproj -scheme Memento -destination 'platform=iOS Simulator,name=iPhone 16' test

# Run a single test class
xcodebuild -project Memento.xcodeproj -scheme Memento \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:MementoTests/VisionInputSafetyTests test

# Run a single test method
xcodebuild -project Memento.xcodeproj -scheme Memento \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:MementoTests/VisionInputSafetyTests/testFaceMatcherThresholds test
```

All tests live in `MementoTests/MementoTests.swift` under `VisionInputSafetyTests`.

## Architecture

### Frame pipeline (end-to-end)

```
DAT SDK (Meta glasses Bluetooth)
  └─ DATGlassesManager          — SDK lifecycle, registration, device session, StreamSession
       └─ StreamSessionViewModel — @MainActor coordinator; receives VideoFrame, drives all UI state
            ├─ VisionFaceFrameProcessor (actor) — Vision face detection, FaceCropper alignment, FaceQualityFilter
            │    └─ ProcessedVideoFrame          — carries detected faces + IdentityCandidate list per frame
            ├─ IdentityPipeline (actor)          — embedding, matching, rolling confirmation, enrollment
            │    ├─ FaceEmbeddingModels          — AWS AdaFace only (112x112 input, 512-dim output)
            │    ├─ FaceMatcher                  — cosine similarity, strong/weak/ambiguous decision
            │    ├─ RollingIdentityConfirmor      — requires N repeated strong matches to confirm identity
            │    └─ LocalIdentityStore (actor)    — JSON persistence for profiles, embeddings, sessions
            └─ SpeechTranscriptionManager        — AVAudioEngine + Apple Speech, attaches transcript to confirmed identity
```

### Key types in `Models/`

- **`ProcessedVideoFrame`** — the frame envelope passed from `VisionFaceFrameProcessor` to `StreamSessionViewModel`. Contains `identityCandidates: [IdentityCandidate]`, each holding the aligned `112x112` crop ready for embedding.
- **`IdentityConfig`** — single source of truth for all thresholds (quality, recognition, enrollment). Tweak here to change pipeline behavior without touching logic.
- **`ActiveIdentityState`** — enum-like struct (`none`, `unknown`, `possible`, `ambiguous`, `confirmed`) representing the rolling confirmor's current conclusion.
- **`IdentityProcessingResult`** — returned by `IdentityPipeline.process(frame:)` to the ViewModel; contains `activeIdentity`, `faceCandidateCount`, `summary`, embedding stats, and enrollment state.

### Identity pipeline detail

`IdentityPipeline.process(frame:)` runs at most `identityProcessingFPS = 3` times per second. It has a fast path: while a face is confirmed *and* the last full pipeline run was within `holdIdentitySeconds` (default 2 s), embedding is skipped and the hold refreshed. After that window the full embed+match runs. This prevents holding a stale identity when a new (unrecognized) face appears.

Matching uses both per-sample cosine similarity and averaged-centroid similarity; whichever scores higher wins. A match becomes `.confirmed` only after `requiredStrongMatches` (default 3) consecutive `.known` decisions within a `rollingWindowSeconds` (default 4 s) window.

Thresholds (all in `IdentityConfig` / `IdentityThresholdConfig`):
- `strongMatchThreshold = 0.70` — `.known`
- `weakMatchThreshold = 0.60` — `.ambiguous`
- `matchMarginThreshold = 0.05` — margin between top-1 and top-2 scores required for `.known`

### Face alignment

`FaceCropper.alignFace` uses Vision's 5-point landmarks (left eye, right eye, nose tip, left/right mouth corners) and a least-squares similarity transform to warp the source image into a `112x112` crop aligned to AdaFace/ArcFace reference landmark positions. The aligned image is what gets embedded.

### Persistence

`LocalIdentityStore` persists to the app's Documents directory as JSON. Each person has a `PersonProfile` plus `FaceEmbeddingRecord` entries (individual samples) and a `PersonAveragedEmbedding` (L2-normalized centroid). When a new sample is added to an enrolled person, the centroid is recomputed.

### Logging

`AppLogger.log(.category, message)` — every log has a `[CATEGORY]` prefix. Useful categories for debugging identity: `IDENTITY_MATCH`, `FACE_MATCH`, `ROLLING_IDENTITY`, `FACE_EMBEDDING`, `FACE_CROP`, `FACE_QUALITY`. Enable `--verbose-frame-logging` launch argument for per-frame crop detail.

Before investigating face embeddings, profile loading, thresholds, or rolling identity, verify that DAT camera frames are actually arriving. A working stream logs `First DAT video frame received` and `first-video-stream-frame`, followed by `visionInput`, crop, embedding, and match diagnostics. If the stream reaches `streaming` but no frames arrive for 10 seconds, `DATGlassesManager` logs:

```text
[STREAM] warning...---- DAT stream is streaming but delivered no video frames after 10s...
[FRAMES] warning...---- DAT zero-frame stream; videoFramePublisher has not delivered any frames...
```

That means face detection and recognition have not run. Diagnose glasses/camera frame delivery before changing recognition thresholds or embedding code.

## DAT SDK Integration

See `AGENTS.md` for the full SDK API reference. Critical points:

- `DATGlassesManager.shared` is the singleton; `configureAtStartup()` must be called before `Wearables.shared` is used.
- URL callbacks from Meta AI must be forwarded via `DATGlassesManager.handleOpenURL(_:)` in the app's `onOpenURL` handler.
- After any `Info.plist` DAT key change: delete app from device → Clean Build Folder → reinstall.
- Developer Mode requires `MWDAT.MetaAppID = "0"` and `MWDAT.AppLinkURLScheme = "cameraaccess://"` in `Info.plist`; display builds also require `MWDAT.DAMEnabled = true`.
- Display output must use one active `MWDATDisplay` capability per device session. Combine identity memory, scene context, and live captions into the current display card instead of repeatedly calling `addDisplay()`.

## Face Embedding Model

Face embeddings use the AWS AdaFace worker only. There is no local Core ML face embedding fallback. If the worker is disabled, warming, or unreachable, the identity pipeline runs detection/quality only and logs a `warning...----` line explaining that face recognition is paused.

Embeddings from different model versions or preprocessing versions are intentionally rejected during matching (keyed by `modelName`, `modelVersion`, `modelSource`, `preprocessingVersion`). People enrolled with older local face embeddings must be re-enrolled with AdaFace.

## Supabase Backend

The cloud source-of-truth lives in Supabase project **`meta-smart-glasses`** (ref `puenkwjljhmhanlnuugy`, region `us-west-1`, Postgres 17 + pgvector 0.8 + pg_trgm). Migrations are in `supabase/migrations/`:

- `0001_init.sql` — 18 tables mirroring `CameraAccess/Models/*.swift`, vector(512) face + vector(192) speaker columns with ivfflat cosine indexes, fuzzy name search index, updated_at triggers.
- `0002_owner_rls.sql` — adds `owner_uid uuid default auth.uid() references auth.users(id) on delete cascade` to every table, with per-table select/insert/update/delete policies keyed on `auth.uid()`.

To apply or update:

```sh
# .env.local provides SUPABASE_ACCESS_TOKEN (Management API PAT)
set -a && source .env.local && set +a
for f in supabase/migrations/*.sql; do
  python3 -c "import json; print(json.dumps({'query': open('$f').read()}))" > /tmp/m.json
  curl -sS -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" -H "Content-Type: application/json" \
    -X POST "https://api.supabase.com/v1/projects/$SUPABASE_PROJECT_REF/database/query" \
    --data-binary @/tmp/m.json
done
```

Both migrations are idempotent — re-running is a no-op.

**Auth model:** Supabase Auth (anonymous mode) + RLS keyed on `auth.uid()`. On first launch, `SupabaseSession` calls `POST /auth/v1/signup` with an empty body, persists the resulting access + refresh tokens in the iOS Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), and refreshes the access token on a 60-second leeway. The app embeds only the **anon key** (public, role=anon); per-row access is gated by the user's JWT. Anyone who extracts the IPA can mint themselves a brand-new anonymous user but sees zero existing rows.

The service role key is **not** used by the app. Anonymous sign-ins are enabled via the Management API (`PATCH /v1/projects/$ref/config/auth` with `{"external_anonymous_users_enabled": true}`).

To upgrade to Sign in with Apple later: call `supabase.auth.linkIdentity({provider: "apple"})` from the existing anonymous session — Supabase merges identities and all existing rows stay attached to the same `auth.uid()`.

**Client:** `CameraAccess/Services/SupabaseClient.swift` is a thin URLSession wrapper around PostgREST — `upsert(table:rows:onConflict:)`, `select(table:filter:limit:)`, `rpc(_:params:)`, `healthCheck()`. Every request sends `apikey: <anon>` + `Authorization: Bearer <session JWT>`. The session is owned by `CameraAccess/Services/SupabaseSession.swift` (an actor that serializes token refresh). Both files must be added to the `CameraAccess` target's Compile Sources phase.

**LocalIdentityStore mirror:** `IdentityPipeline` now defaults to `SyncingIdentityStore` instead of `LocalIdentityStore`. The wrapper keeps Core Data as the fast read path and mirrors every write to Supabase via `IdentitySyncQueue` (durable JSON-backed retry queue at `Application Support/MetaFaceIdentity/supabase-sync-queue.json`, exponential backoff, max 8 attempts before moving the entry to `supabase-sync-dead-letter.jsonl`). Wire shapes per table live in `CameraAccess/Services/SupabaseRowEncoders.swift`. Face crops upload to the private `face-crops` bucket at `<auth.uid()>/<personId|unknown>/<embeddingId>.jpg` (storage RLS in `0003_storage_rls.sql`). Bucket cap is 512 KB per file, jpeg/png only. `owner_uid` is auto-filled by the DB default; never set it client-side.

**Backfill:** on first launch after this lands, `IdentityBackfillCoordinator` walks the local store and enqueues every existing `PersonProfile` / `FaceEmbeddingRecord` / `PersonAveragedEmbedding` for cloud upload (gated by `UserDefaults` key `SupabaseSyncBackfillCompleted_v1` — clear it to re-run).

**Known sync gaps (v1):** `endAppRun` and `endConversationSession` do NOT push the end-of-life fields to Supabase, because the local store doesn't expose by-id fetches and synthesizing a partial row would clobber the rest of the cloud row (PostgREST upserts full rows). The cloud row gets the updated state the next time `updateConversationSession` is called with a complete object. `clearIdentities` / `clearConversations` are local-only by design — wipe cloud data via the dashboard or a service-role script. Both gaps are logged loudly under `[SUPABASE_SYNC]` so divergence is observable.
