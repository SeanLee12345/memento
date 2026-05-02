# Meta Face Simulation

SwiftUI iOS prototype for local face detection and speech transcription using a bundled compressed video file. The app does not use Meta DAT, physical glasses, or Meta streaming APIs at runtime.

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
3. Run on an iPhone or simulator.
4. Tap `Start Simulation`.

The bundled `CameraAccess/Compressed Video.mp4` is copied into the app bundle and used as the only video/audio source.

## Safety

Before Vision processing, every frame is validated:

```swift
guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

let width = CVPixelBufferGetWidth(pixelBuffer)
let height = CVPixelBufferGetHeight(pixelBuffer)

guard width > 0 && height > 0 else { return }
```

The view model allows only one Vision request in flight and drops late frames instead of queueing them. Debug logs include frame timestamp, frame size, dropped frame count, and Vision latency.
