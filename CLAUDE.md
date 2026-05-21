# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

SwiftUI iOS app that streams video from Meta Ray-Ban smart glasses via the Meta Wearables DAT SDK, runs on-device face detection and recognition, and transcribes speech. The app targets physical iPhones connected to Meta glasses; a Mock Device Kit path supports simulator testing.

## Build & Run

Open `CameraAccess.xcodeproj` in Xcode, select the `CameraAccess` scheme, and run on a physical iPhone. There is no CLI build script — use Xcode's Product menu or `xcodebuild`:

```sh
# Build only
xcodebuild -project CameraAccess.xcodeproj -scheme CameraAccess -destination 'generic/platform=iOS' build

# Run all unit tests (simulator)
xcodebuild -project CameraAccess.xcodeproj -scheme CameraAccess -destination 'platform=iOS Simulator,name=iPhone 16' test

# Run a single test class
xcodebuild -project CameraAccess.xcodeproj -scheme CameraAccess \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:CameraAccessTests/VisionInputSafetyTests test

# Run a single test method
xcodebuild -project CameraAccess.xcodeproj -scheme CameraAccess \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:CameraAccessTests/VisionInputSafetyTests/testFaceMatcherThresholds test
```

All tests live in `CameraAccessTests/CameraAccessTests.swift` under `VisionInputSafetyTests`.

## Architecture

### Frame pipeline (end-to-end)

```
DAT SDK (Meta glasses Bluetooth)
  └─ DATGlassesManager          — SDK lifecycle, registration, device session, StreamSession
       └─ StreamSessionViewModel — @MainActor coordinator; receives VideoFrame, drives all UI state
            ├─ VisionFaceFrameProcessor (actor) — Vision face detection, FaceCropper alignment, FaceQualityFilter
            │    └─ ProcessedVideoFrame          — carries detected faces + IdentityCandidate list per frame
            ├─ IdentityPipeline (actor)          — embedding, matching, rolling confirmation, enrollment
            │    ├─ FaceEmbeddingModels          — CoreML MobileFaceNet (96×112 input, 128-dim output)
            │    ├─ FaceMatcher                  — cosine similarity, strong/weak/ambiguous decision
            │    ├─ RollingIdentityConfirmor      — requires N repeated strong matches to confirm identity
            │    └─ LocalIdentityStore (actor)    — JSON persistence for profiles, embeddings, sessions
            └─ SpeechTranscriptionManager        — AVAudioEngine + Apple Speech, attaches transcript to confirmed identity
```

### Key types in `Models/`

- **`ProcessedVideoFrame`** — the frame envelope passed from `VisionFaceFrameProcessor` to `StreamSessionViewModel`. Contains `identityCandidates: [IdentityCandidate]`, each holding the aligned `96×112` crop ready for embedding.
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

`FaceCropper.alignFace` uses Vision's 5-point landmarks (left eye, right eye, nose tip, left/right mouth corners) and a least-squares similarity transform to warp the source image into a `96×112` crop aligned to the Xiaoccer MobileFaceNet reference landmark positions. The aligned image is what gets embedded.

### Persistence

`LocalIdentityStore` persists to the app's Documents directory as JSON. Each person has a `PersonProfile` plus `FaceEmbeddingRecord` entries (individual samples) and a `PersonAveragedEmbedding` (L2-normalized centroid). When a new sample is added to an enrolled person, the centroid is recomputed.

### Logging

`AppLogger.log(.category, message)` — every log has a `[CATEGORY]` prefix. Useful categories for debugging identity: `IDENTITY_MATCH`, `FACE_MATCH`, `ROLLING_IDENTITY`, `FACE_EMBEDDING`, `FACE_CROP`, `FACE_QUALITY`. Enable `--verbose-frame-logging` launch argument for per-frame crop detail.

## DAT SDK Integration

See `AGENTS.md` for the full SDK API reference. Critical points:

- `DATGlassesManager.shared` is the singleton; `configureAtStartup()` must be called before `Wearables.shared` is used.
- URL callbacks from Meta AI must be forwarded via `DATGlassesManager.handleOpenURL(_:)` in the app's `onOpenURL` handler.
- After any `Info.plist` DAT key change: delete app from device → Clean Build Folder → reinstall.
- Developer Mode requires `MWDAT.MetaAppID = "0"` and `MWDAT.AppLinkURLScheme = "cameraaccess://"` in `Info.plist`.

## MobileFaceNet Model

The `.mlpackage` ships in the repo at `CameraAccess/MobileFaceNet.mlpackage`. The model must be in the `CameraAccess` target's Copy Bundle Resources phase. If the model is missing, the pipeline runs in detection-only mode and logs `[FACE_EMBEDDING_MODEL] modelLoaded=false`.

To regenerate the model from the Xiaoccer PyTorch checkpoint:

```sh
python -m venv /tmp/metaface-venv
/tmp/metaface-venv/bin/pip install torch coremltools numpy
git clone https://github.com/Xiaoccer/MobileFaceNet_Pytorch.git /tmp/MobileFaceNet_Pytorch
/tmp/metaface-venv/bin/python tools/convert_mobilefacenet_to_coreml.py \
  --repo /tmp/MobileFaceNet_Pytorch \
  --checkpoint /tmp/MobileFaceNet_Pytorch/model/best/068.ckpt \
  --output CameraAccess/MobileFaceNet.mlpackage
```

Embeddings from different model versions or preprocessing versions are intentionally rejected during matching (keyed by `modelName`, `modelVersion`, `modelSource`, `preprocessingVersion`). Changing the model requires re-enrolling all people.

## Offline Model Testing

To verify MobileFaceNet can distinguish two people without running the full app, use the Swift script pattern from `/tmp/TestEmbeddings2.swift` (created during development): detect face with `VNDetectFaceRectanglesRequest`, crop + resize to 96×112, preprocess with `(pixel - 127.5) / 128.0` in NCHW float32, run via `MLModel.prediction(from:)`. Compile the `.mlpackage` first with `MLModel.compileModel(at:)`.
