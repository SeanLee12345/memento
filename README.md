# Meta Smart Glass Project

SwiftUI iOS prototype for Meta Wearables DAT camera streaming, local face detection, speech transcription, and Mock Device Kit fallback testing.

## Pipeline

- Video: `Compressed Video.mp4` -> `AVAssetReader` -> `AVAssetReaderTrackOutput` -> `CMSampleBuffer` -> `CVPixelBuffer` -> Apple Vision -> SwiftUI overlay
- Audio: `Compressed Video.mp4` -> `AVAudioFile` -> `AVAudioEngine` + `AVAudioPlayerNode` -> `SFSpeechAudioBufferRecognitionRequest` -> transcript UI

All image/audio decoding and buffer ownership is delegated to Apple frameworks. There is no manual buffer construction, slicing, `memcpy`, `copyMemory`, or raw pointer manipulation in the app pipeline.

## Key Files

- `CameraAccess/Services/VideoFileFrameProvider.swift`: real-time 24 FPS file-backed video provider using `AVAssetReader`.
- `CameraAccess/Services/SpeechTranscriptionManager.swift`: audio playback/transcription using `AVAudioEngine` and Apple Speech.
- `CameraAccess/Services/VisionFaceFrameProcessor.swift`: validates `CMSampleBuffer`/`CVPixelBuffer`, runs `VNDetectFaceRectanglesRequest`, tracks face boxes, and creates thumbnails safely.
- `CameraAccess/ViewModels/StreamSessionViewModel.swift`: coordinates video frames, speech updates, dropped-frame accounting, and UI state.
- `CameraAccess/Views/StreamView.swift`: live preview, face boxes, transcript, and debug stats.

## Run

1. Open `CameraAccess.xcodeproj`.
2. Select the `CameraAccess` scheme.
3. Run on a physical iPhone for real Meta glasses mode.
4. Use Mock Device Kit on simulator or when physical glasses are unavailable.

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

## Safety

Before Vision processing, every frame is validated:

```swift
guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

let width = CVPixelBufferGetWidth(pixelBuffer)
let height = CVPixelBufferGetHeight(pixelBuffer)

guard width > 0 && height > 0 else { return }
```

The view model allows only one Vision request in flight and drops late frames instead of queueing them. Debug logs include frame timestamp, frame size, dropped frame count, and Vision latency.
