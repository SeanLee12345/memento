# Meta Glasses Living AI App

SwiftUI iOS prototype for a Meta smart glasses based Living AI layer. The app runs on top of Meta Wearables Device Access Toolkit and Apple frameworks; it is not a custom glasses hardware project.

The target pipeline is:

Meta smart glasses input -> voice detection -> face detection -> identity resolution -> memory retrieval -> real-time assistance -> glasses display when supported, otherwise a clearly labeled fallback surface.

## Pipeline

- Glasses video: Meta Wearables DAT camera stream -> `UIImage`/frame processing -> Apple Vision face detection -> face quality checks -> embedding and identity pipeline.
- Mock/file video: `Compressed Video.mp4` -> `AVAssetReader` -> `AVAssetReaderTrackOutput` -> `CMSampleBuffer` -> `CVPixelBuffer` -> Apple Vision -> SwiftUI overlay.
- Audio: iPhone or selected Bluetooth audio route -> `AVAudioEngine` -> voice activity detection -> Apple Speech/cloud diarization path -> transcript and speaker records.
- Identity and memory: face matches, speaker evidence, user confirmation, stored profiles, transcript chunks, reminders, and conversation history are combined into person-centered records.
- Assistance output: `AssistanceCardFormatter` produces short display cards for known, possible, unknown, no-face, multi-face, low-confidence, no-memory, and display-fallback states.

All image/audio decoding and buffer ownership is delegated to Apple frameworks. There is no manual buffer construction, slicing, `memcpy`, `copyMemory`, or raw pointer manipulation in the app pipeline.

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

Create `.env.local` for local secrets. This file is ignored by git.

```sh
DEEPSEEK_API_KEY=your_key_here
DEEPSEEK_MODEL=deepseek-v4-flash
OPEN_SOURCE_TTS_ENABLED=false
OPEN_SOURCE_TTS_ENDPOINT=http://127.0.0.1:5000
OPEN_SOURCE_TTS_VOICE=en_US-lessac-medium
```

Use `.env.example` as the committed template. Do not commit real API keys, AWS credentials, or user data. The iOS app must receive secrets through secure local configuration or a backend; do not hardcode them in Swift source.

DeepSeek spoken assistance and person conversation summaries are configured from `.env.local`/process environment and default to `deepseek-v4-flash`. The app does not expose a DeepSeek API key field in Settings.

Open-source voice output can use a local Piper HTTP server. Piper returns WAV audio and the app plays it through the iPhone speaker or Bluetooth/HFP route, falling back to Apple `AVSpeechSynthesizer` if the endpoint fails.

Example Piper setup:

```sh
python3 -m pip install 'piper-tts[http]'
python3 -m piper.download_voices en_US-lessac-medium
python3 -m piper.http_server -m en_US-lessac-medium --host 0.0.0.0 --port 5000
```

Set `OPEN_SOURCE_TTS_ENABLED=true` and `OPEN_SOURCE_TTS_ENDPOINT` to the reachable server URL, for example `http://<your-mac-lan-ip>:5000`. The app does not expose open-source voice endpoint fields in Settings.

## Run

1. Open `CameraAccess.xcodeproj`.
2. Select the `CameraAccess` scheme.
3. Run on a physical iPhone for real Meta glasses mode.
4. Use Mock Device Kit on simulator or when physical glasses are unavailable.

Build from the command line:

```sh
xcodebuild -project CameraAccess.xcodeproj -scheme CameraAccess -destination 'generic/platform=iOS' build
```

Run unit tests on an available iOS simulator:

```sh
xcodebuild -project CameraAccess.xcodeproj -scheme CameraAccess -destination 'platform=iOS Simulator,name=iPhone 16' test
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

The current app package is pinned to Meta Wearables DAT `0.7.0` and links `MWDATDisplay`. `MWDAT.DAMEnabled` is intentionally not enabled in the default `Info.plist` because the current live camera path targets Ray-Ban Meta camera streaming; forcing the DAT App Model display path can stop `DeviceSession` startup on displayless Ray-Ban Meta devices. Enable `MWDAT.DAMEnabled` only for a display-specific build path that opens a real `MWDATDisplay` session on supported display glasses.

The app is ready for a Display session implementation, but real glasses display output is not yet wired into the live identity/memory pipeline. The current supported output is still a clearly labeled fallback in the phone UI/debug surface using the same short display-card formatter intended for `MWDATDisplay`.

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

## Face Detection

Real face detection uses Apple Vision on frames received from DAT camera streaming or the file/mock path. Each detection path records frame timing, bounding boxes, confidence/quality evidence where available, and no-face/multiple-face states. Mock media is for development and does not replace the real DAT camera path when hardware is available.

Cloud face embeddings can be enabled for an AWS `g4dn.xlarge` GPU worker. The app posts aligned face crops to `/face/embed`, expects a normalized embedding response, and falls back to the local MobileFaceNet model if the cloud call fails. Configure the endpoint in Settings under `AWS AdaFace embeddings`.

The worker contract and starter FastAPI service live in:

```text
tools/aws_face_worker
```

## Identity And Memory

Identity resolution combines face matches, speaker evidence, prior stored profiles, rolling confirmation, and explicit user confirmation. Unknown people remain unknown until the user confirms a profile. Stored records include person profiles, embeddings, transcript chunks, conversation sessions, reminders, and context.

Privacy controls live in the people dictionary and stream UI: users can review, label, edit, and delete stored people and conversations. Sensitive memory should not be logged unnecessarily, and future storage hardening should encrypt local memory at rest where practical.

## Known Limitations

- DAT `0.7.0` and `MWDATDisplay` are linked, but the live `Display` session/send flow still needs to be connected to the assistance card pipeline.
- Direct raw glasses microphone access is not exposed through the current DAT path; iOS audio routing is used.
- Local memory storage is structured, but encryption-at-rest hardening remains a required next step.
- Real-device validation requires physical Meta smart glasses, a physical iPhone, Meta AI, compatible firmware, Bluetooth, internet, and Developer Mode.

## Next Engineering Steps

- Wire `AssistanceCardFormatter` into the live identity/memory pipeline and send the resulting cards to `MWDATDisplay` or fallback UI.
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
