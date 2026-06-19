# Meta Glasses Living AI App

SwiftUI iOS prototype for a Meta smart glasses based Living AI layer. The app runs on top of Meta Wearables Device Access Toolkit and Apple frameworks; it is not a custom glasses hardware project.

The target pipeline is:

Meta smart glasses input -> voice detection -> face detection -> identity resolution -> memory retrieval -> real-time assistance -> glasses display when supported, otherwise a clearly labeled fallback surface.

## Pipeline

- Glasses video: Meta Wearables DAT camera stream -> `UIImage`/frame processing -> Apple Vision face detection -> face quality checks -> embedding and identity pipeline.
- Mock/file video: `Compressed Video.mp4` -> `AVAssetReader` -> `AVAssetReaderTrackOutput` -> `CMSampleBuffer` -> `CVPixelBuffer` -> Apple Vision -> SwiftUI overlay.
- Audio: iPhone microphone by default -> `AVAudioEngine` -> WAV recording/cloud diarization path -> transcript and speaker records. For real DAT camera streaming, the iPhone microphone is started before the DAT stream starts so recording is already active while camera frames arrive. The app must not use Meta/Ray-Ban glasses speakers for audible result announcements.
- Identity and memory: face matches, speaker evidence, user confirmation, stored profiles, transcript chunks, reminders, and conversation history are combined into person-centered records.
- Assistance output: `AssistanceCardFormatter` produces short display cards for known, possible, unknown, no-face, multi-face, low-confidence, no-memory, and display-fallback states.

All image/audio decoding and buffer ownership is delegated to Apple frameworks. There is no manual buffer construction, slicing, `memcpy`, `copyMemory`, or raw pointer manipulation in the app pipeline.

## Model Inventory

- Face detection and face-quality gating: Apple Vision `VNDetectFaceRectanglesRequest`, `VNDetectFaceCaptureQualityRequest`, and `VNDetectFaceLandmarksRequest` on DAT video frames.
- Face embeddings: AWS FastAPI worker running AdaFace `minchul/cvlface_adaface_ir101_webface12m`, preprocessing `adaface-ir101-112-rgb-normalize-0p5-v1`. There is no local face embedding fallback; if AWS AdaFace is not ready, face recognition and enrollment are paused.
- Local speaker embeddings: Core ML speaker model search order `SpeakerEmbedding`, `ECAPATDNN`, `SpeakerNet`, with TitaNet-compatible raw 16 kHz preprocessing.
- Cloud speaker embeddings: AWS FastAPI worker running NVIDIA NeMo `nvidia/speakerverification_en_titanet_large`, app version `nvidia-speakerverification-en-titanet-large-v1`, preprocessing `titanet-raw-16khz-v1`.
- Live transcription: Alibaba DashScope OpenAI-compatible audio API, default model `qwen3-asr-flash-us`, using overlapping 5 second audio windows with 2 seconds of overlap removed from emitted text.
- Multimodal scene context: Alibaba DashScope/OpenAI-compatible vision-language API, default model `qwen3-vl-flash-us`, prompt version `scene-context-5w1h-v1`.
- Person conversation summaries: DeepSeek chat API, configured by `DEEPSEEK_MODEL` and defaulting to `deepseek-v4-flash`.
- Post-stream diarization: cloud Diarizen flow through S3/Lambda/EC2, then the app reconciles speaker segments with face, voice, and transcript evidence.
- Fusion/decision logic: local Swift rules in `ConversationPartnerResolver`, `FaceMatcher`, and `SpeakerIdentityPipeline`; this is not a separate ML model.

## Key Files

- `CameraAccess/Services/DATGlassesManager.swift`: Meta Wearables DAT registration, device discovery, connection state, and camera stream handling.
- `CameraAccess/Services/SpeechTranscriptionManager.swift`: audio route setup, transcription using `AVAudioEngine` and Apple Speech, and iPhone/glasses route status.
- `CameraAccess/Services/VisionFaceFrameProcessor.swift`: validates `CMSampleBuffer`/`CVPixelBuffer`, runs `VNDetectFaceRectanglesRequest`, tracks face boxes, and creates thumbnails safely.
- `CameraAccess/Services/StreamAudioRecorder.swift`: writes streamed audio to WAV and refuses empty recordings before cloud upload.
- `CameraAccess/Services/CloudDiarizationService.swift`: validates WAV duration before S3 upload and cloud diarization.
- `CameraAccess/Services/IdentityPipeline.swift`: face identity, calibration, user confirmation, transcripts, and people dictionary coordination.
- `CameraAccess/Services/SpeakerIdentityPipeline.swift`: speaker segmentation, speaker identity evidence, and voice preview queueing.
- `CameraAccess/Services/LocalIdentityStore.swift`: local person, embedding, transcript, conversation, reminder, and context storage.
- `CameraAccess/Models/AssistanceModels.swift`: short display-card formatting for glasses/fallback output.
- `CameraAccess/ViewModels/StreamSessionViewModel.swift`: coordinates DAT frames, audio, face identity, speaker identity, diarization, memory, and UI state.
- `CameraAccess/Views/StreamView.swift`: live preview, face boxes, transcript, identity/memory status, and debug stats.

## Environment

Create `.env.local` for laptop-only local secrets. This file is ignored by git and must not be added to the iOS app target or Copy Bundle Resources. The iOS app only needs public Supabase client config: `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and optionally `SUPABASE_PROJECT_REF`. In device builds, provide those as Xcode build settings so `Info.plist` resolves `MementoSupabaseURL`, `MementoSupabaseAnonKey`, and `MementoSupabaseProjectRef`.

```sh
OPEN_SOURCE_TTS_ENABLED=false
OPEN_SOURCE_TTS_ENDPOINT=http://127.0.0.1:5000
OPEN_SOURCE_TTS_VOICE=en_US-lessac-medium
SUPABASE_PROJECT_REF=your_ref
SUPABASE_URL=https://your_ref.supabase.co
SUPABASE_ANON_KEY=your_public_anon_key
```

Use `.env.example` as the committed template. Do not commit real API keys, AWS credentials, or user data. Do not bundle `.env.local` into `Memento.app`; a built app can be inspected, so bundled API keys are client-exposed. Private LLM, worker, AWS, and Supabase management credentials should live behind backend endpoints or local debug-only launch environment, not in app resources.

Alibaba/Qwen, DeepSeek, and worker signing secrets now belong in Supabase Edge Function secrets:

```sh
supabase secrets set DASHSCOPE_API_KEY=...
supabase secrets set DEEPSEEK_API_KEY=...
supabase secrets set NVIDIA_API_KEY=...
supabase secrets set WORKER_TOKEN_SIGNING_SECRET=...
supabase functions deploy memento-ai
supabase functions deploy worker-session
```

Selective memory recall uses `memory_chunks` plus the `hybrid_memory_search`
RPC. Apply migrations, deploy `memento-ai`, then backfill existing remote
transcripts and scene contexts from the laptop:

```sh
supabase db push
supabase functions deploy memento-ai
python tools/backfill_memory_chunks.py --dry-run
python tools/backfill_memory_chunks.py
```

The backfill requires `SUPABASE_SERVICE_KEY`, `NVIDIA_API_KEY`, and optionally
`DASHSCOPE_API_KEY` in the laptop-only `.env.local`. None of these private keys
belong in the iOS target.

For pre-RLS rows whose `owner_uid` is null, pass the intended authenticated
owner explicitly with `--legacy-owner <user-uuid>`. Use `--skip-qwen` for a
faster deterministic metadata pass while retaining NVIDIA embeddings.

The AWS face and speaker workers should receive the same `WORKER_TOKEN_SIGNING_SECRET` in their worker environment. During migration, the workers still accept `FACE_WORKER_API_KEY` and `SPEAKER_WORKER_API_KEY`, but new iOS sessions request short-lived worker tokens from `worker-session`.

DeepSeek spoken assistance and person conversation summaries are proxied through Supabase Edge when Supabase is configured and default to `deepseek-v4-flash`. The app does not expose a production DeepSeek API key field in Settings.

Open-source voice output can use a local Piper HTTP server. Piper returns WAV audio and the app plays it through the iPhone output path only, falling back to Apple `AVSpeechSynthesizer` if the endpoint fails. Do not route spoken results to Meta/Ray-Ban glasses speakers.

Example Piper setup:

```sh
python3 -m pip install 'piper-tts[http]'
python3 -m piper.download_voices en_US-lessac-medium
python3 -m piper.http_server -m en_US-lessac-medium --host 0.0.0.0 --port 5000
```

Set `OPEN_SOURCE_TTS_ENABLED=true` and `OPEN_SOURCE_TTS_ENDPOINT` to the reachable server URL, for example `http://<your-mac-lan-ip>:5000`. The app does not expose open-source voice endpoint fields in Settings.

## Run

1. Open `Memento.xcodeproj`.
2. Select the `Memento` scheme.
3. Run on a physical iPhone for real Meta glasses mode.
4. Use Mock Device Kit on simulator or when physical glasses are unavailable.

Build from the command line:

```sh
xcodebuild -project Memento.xcodeproj -scheme Memento -destination 'generic/platform=iOS' build
```

Run unit tests on an available iOS simulator:

```sh
xcodebuild -project Memento.xcodeproj -scheme Memento -destination 'platform=iOS Simulator,name=iPhone 16' test
```

## DAT Developer Mode Retest

After changing `Info.plist` DAT keys, remove stale installs before retesting registration:

1. Delete the app from the iPhone.
2. In Xcode, use Product -> Clean Build Folder.
3. Reinstall and run from Xcode on the physical iPhone.
4. Confirm the app debug panel shows:
   - `MWDAT.MetaAppID=0`
   - `MWDAT.AppLinkURLScheme=cameraaccess://`
   - `CFBundleURLSchemes=[cameraaccess]`
   - `cameraaccess` URL scheme registered
   - Developer Mode flag `true`
5. Tap `Connect Real Glasses`.
6. If Meta AI opens, return to the app and confirm `handleUrl` or scene-active resume logs appear.

Developer Mode registration still requires Meta AI installed, internet access, Bluetooth enabled, and Developer Mode enabled on the paired glasses in Meta AI.

## Display Output

The current app package is pinned to Meta Wearables DAT `0.7.0` and links `MWDATDisplay`. `MWDAT.DAMEnabled` is enabled in `Info.plist` for display-capable glasses testing. If camera streaming regresses on a target firmware, disable `MWDAT.DAMEnabled` for a camera-only build while isolating the display path.

When a confirmed known face is detected, the app sends a compact person memory card to the glasses display. Live captions, Alibaba scene context, and detected people are separated into distinct display windows so the user is not forced through one endless mixed page list. The app should attach one `MWDATDisplay` capability per active device session and then update that card; if the SDK reports that the display capability is already active, do not keep retrying `addDisplay()` for each caption. The phone UI remains a clearly labeled fallback/debug surface using the same display-card formatter. Unknown, possible, multiple-face, and no-face states do not reveal private conversation memory on the glasses.

Display cards must stay glanceable:

```text
Sarah
Last: 3 weeks ago
Context: Internship, Japan trip
Reminder: Follow up on resume
```

If confidence is low, the card hides sensitive memory and asks for confirmation before showing private context.

## Voice Input

The public DAT camera SDK path used here does not expose a direct raw glasses microphone stream. Audio is captured through iOS audio routes with Apple frameworks. The app supports iPhone audio and Bluetooth/HFP routing where iOS exposes it, validates non-empty WAV duration before S3 upload, and fails visibly instead of uploading zero-second audio.

For live identity detection during real DAT camera streaming, the production path is DAT camera frames plus iPhone microphone recording. The iPhone microphone must be activated before `Stream.start()` so the shared iOS audio session is not renegotiated while DAT video is already streaming. Meta/Ray-Ban glasses audio output is not a product requirement and should be avoided for spoken results because changing the phone's Bluetooth audio output route can destabilize DAT camera streaming. If audible feedback is added or tested, keep it on the iPhone speaker/receiver path outside the active DAT stream unless the user explicitly approves a separate glasses-audio experiment.

## Face Detection

Real face detection uses Apple Vision on frames received from DAT camera streaming or the file/mock path. Each detection path records frame timing, bounding boxes, confidence/quality evidence where available, and no-face/multiple-face states. Mock media is for development and does not replace the real DAT camera path when hardware is available.

If the glasses display or phone UI stays on "Looking for people", first confirm that DAT is delivering camera frames before debugging embeddings or thresholds. A healthy live stream should log `First DAT video frame received`, `first-video-stream-frame`, `visionInput`, crop, embedding, and match diagnostics. If DAT reaches `streaming` but the SDK delivers no video frames for 10 seconds, the app logs:

```text
[STREAM] warning...---- DAT stream is streaming but delivered no video frames after 10s...
[FRAMES] warning...---- DAT zero-frame stream; videoFramePublisher has not delivered any frames...
```

In that state face detection, crop generation, profile loading, embedding, and threshold decisions have not run yet. Treat it as a DAT camera frame delivery issue: keep the glasses awake/open/worn, confirm the camera permission and active device state, then stop and start the stream. Do not tune recognition thresholds until frame logs are present.

Live cloud face embeddings run the AdaFace IR-101 WebFace12M model on a shared EC2 instance (`i-0c400af918e775f20`, `m7i-flex.large`, us-west-1). Toggle `AWS AdaFace embeddings` in Settings: with the toggle on, the `DiarizenStartEC2` Lambda boots the instance at stream start via `startLiveFace`, the iOS app polls the returned public IP at `:8080/health`, and the identity pipeline uses the AdaFace worker only. While the worker is starting or warming, face recognition and enrollment are paused instead of falling back to local Core ML.

The face worker shares EC2 with the speaker worker (port 8090, TitaNet). The Lambda tracks each service's live session independently and only stops the instance once both leases are idle, so toggling one service does not interrupt the other. The starter FastAPI service and AWS setup notes live in:

```text
tools/aws_face_worker
```

## Identity And Memory

Identity resolution combines face matches, speaker evidence, prior stored profiles, rolling confirmation, and explicit user confirmation. Unknown people remain unknown until the user confirms a profile. Stored records include person profiles, embeddings, transcript chunks, conversation sessions, reminders, and context.

Privacy controls live in the people dictionary and stream UI: users can review, label, edit, and delete stored people and conversations. Sensitive memory should not be logged unnecessarily, and future storage hardening should encrypt local memory at rest where practical.

## Known Limitations

- Display output now targets one `MWDATDisplay` capability on display-capable glasses; real-device validation still requires Meta Ray-Ban Display hardware and a physical iPhone.
- Direct raw glasses microphone access is not exposed through the current DAT path; iOS audio routing is used.
- Local memory storage is structured, but encryption-at-rest hardening remains a required next step.
- Real-device validation requires physical Meta smart glasses, a physical iPhone, Meta AI, compatible firmware, Bluetooth, internet, and Developer Mode.

## Next Engineering Steps

- Add encryption-at-rest for sensitive memory records and verify delete flows remove derived artifacts.
- Expand simulator/device tests for DAT fallback states, audio WAV validation, identity confirmation, memory retrieval, and display-card behavior.

## Safety

Before Vision processing, every frame is validated:

```swift
guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

let width = CVPixelBufferGetWidth(pixelBuffer)
let height = CVPixelBufferGetHeight(pixelBuffer)

guard width > 0 && height > 0 else { return }
```

The view model allows only one Vision request in flight and drops late frames instead of queueing them. Debug logs include frame timestamp, frame size, dropped frame count, and Vision latency.
