# Meta Wearables DAT SDK

> Full API reference: https://wearables.developer.meta.com/llms.txt?full=true
> Developer docs: https://wearables.developer.meta.com/docs/develop/

This project is the Meta Smart Glass Project. Keep work scoped to Swift, Apple frameworks, and the Meta Wearables Device Access Toolkit. Do not mix in unrelated project assumptions.

## Architecture

The SDK is organized into three modules:

- `MWDATCore`: Device discovery, registration, permissions, device selectors
- `MWDATCamera`: `StreamSession`, `VideoFrame`, photo capture
- `MWDATMockDevice`: MockDeviceKit for testing without hardware

## Swift Patterns

- Use `async/await` for SDK operations.
- Use `AsyncSequence` and publisher `.listen {}` callbacks for observing streams.
- Annotate UI-updating code with `@MainActor`.
- Never block the main thread with frame processing.
- Handle SDK errors with `do/catch`; SDK calls throw typed errors.

## Naming Conventions

| Type | Convention | Example |
| --- | --- | --- |
| Entry point | `Wearables.shared` | `Wearables.shared.startRegistration()` |
| Sessions | `*Session` | `StreamSession`, `DeviceStateSession` |
| Selectors | `*DeviceSelector` | `AutoDeviceSelector`, `SpecificDeviceSelector` |
| Config | `*Config` | `StreamSessionConfig` |
| Publishers | `*Publisher` | `statePublisher`, `videoFramePublisher` |

## Imports

```swift
import MWDATCore
import MWDATCamera
```

For testing:

```swift
import MWDATMockDevice
```

## Key Types

- `Wearables`: SDK entry point. Call `Wearables.configure()` once at launch, then use `Wearables.shared`.
- `StreamSession`: Camera streaming session.
- `VideoFrame`: Individual video frame with `.makeUIImage()`.
- `AutoDeviceSelector`: Automatically selects the best available device.
- `SpecificDeviceSelector`: Selects a specific device by identifier.
- `StreamSessionConfig`: Configures video codec, resolution, and frame rate.
- `MockDeviceKit`: Factory for creating simulated devices in tests.

## Info.plist Configuration

Developer Mode for SDK 0.6.0 uses an `MWDAT` dictionary with `MetaAppID` set to `0`.

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleTypeRole</key>
    <string>Editor</string>
    <key>CFBundleURLName</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>cameraaccess</string>
    </array>
  </dict>
</array>

<key>LSApplicationQueriesSchemes</key>
<array>
  <string>fb-viewapp</string>
</array>

<key>UISupportedExternalAccessoryProtocols</key>
<array>
  <string>com.meta.ar.wearable</string>
</array>

<key>UIBackgroundModes</key>
<array>
  <string>bluetooth-peripheral</string>
  <string>external-accessory</string>
</array>

<key>NSBluetoothAlwaysUsageDescription</key>
<string>Needed to connect to Meta Wearables</string>

<key>MWDAT</key>
<dict>
  <key>AppLinkURLScheme</key>
  <string>cameraaccess://</string>
  <key>MetaAppID</key>
  <string>0</string>
</dict>
```

For production, use a real `MetaAppID`, `ClientToken`, and `TeamID` from the Wearables Developer Center. Do not require production credentials for local Developer Mode testing.

## SDK Initialization

Call `Wearables.configure()` once at app launch before accessing `Wearables.shared`.

```swift
import MWDATCore

@main
struct MyApp: App {
  init() {
    do {
      try Wearables.configure()
    } catch {
      assertionFailure("Failed to configure Wearables SDK: \(error)")
    }
  }
}
```

## URL Callback Handling

The app must handle Meta AI callback URLs and pass them directly to the SDK.

```swift
.onOpenURL { url in
  Task {
    _ = try? await Wearables.shared.handleUrl(url)
  }
}
```

Do not require a specific query parameter before passing the URL to `handleUrl`.

## Registration

```swift
try await Wearables.shared.startRegistration()
```

Observe registration state:

```swift
Task {
  for await state in Wearables.shared.registrationStateStream() {
    // Update UI based on state.
  }
}
```

## Camera Permission

```swift
let status = try await Wearables.shared.checkPermissionStatus(.camera)
let newStatus = try await Wearables.shared.requestPermission(.camera)
```

Registration and permission grants happen through the Meta AI companion app.

## Streaming

```swift
let deviceSelector = AutoDeviceSelector(wearables: Wearables.shared)
let config = StreamSessionConfig(
  videoCodec: .raw,
  resolution: .low,
  frameRate: 24
)
let session = StreamSession(streamSessionConfig: config, deviceSelector: deviceSelector)

let stateToken = session.statePublisher.listen { state in
  Task { @MainActor in
    // Update stream state.
  }
}

let frameToken = session.videoFramePublisher.listen { frame in
  guard let image = frame.makeUIImage() else { return }
  Task { @MainActor in
    // Update preview image.
  }
}

Task {
  await session.start()
}
```

## Stream Session States

`StreamSessionState` transitions:

```text
stopped -> waitingForDevice -> starting -> streaming -> paused -> stopped
```

Handle `paused` by holding work and waiting. Do not restart a session while paused.

## Device Session Lifecycle

DAT work runs inside device sessions. On iOS, observe lifecycle with `addDeviceSessionStateListener()`.

| State | Meaning | App action |
| --- | --- | --- |
| `STOPPED` | Session inactive | Free resources and wait for user action |
| `RUNNING` | Session active | Perform live work |
| `PAUSED` | Temporarily suspended | Hold work and wait |

Closing the glasses hinges disconnects Bluetooth, stops active streams, and forces `STOPPED`. Opening the hinges restores Bluetooth when nearby, but does not restart the session automatically.

## Mock Device Kit

Mock Device Kit is the official no-hardware test path.

```swift
import MWDATMockDevice

let mockDeviceKit = MockDeviceKit.shared
mockDeviceKit.enable()
let mockDevice = mockDeviceKit.pairRaybanMeta()

await mockDevice.powerOn()
await mockDevice.unfold()
await mockDevice.don()

let camera = mockDevice.services.camera
camera.setCameraFeed(fileURL: videoURL)
```

CameraAccess sample debug flow:

1. Pair RayBan Meta.
2. PowerOn.
3. Unfold.
4. Don.
5. Select video.
6. Start streaming.

Supported mock media:

| Type | Formats |
| --- | --- |
| Video | h.265 / HEVC |
| Image | JPEG, PNG |

## Debugging Checklist

- Developer Mode enabled in Meta AI app.
- Meta AI app installed and compatible.
- Glasses firmware compatible.
- Internet available for registration.
- Bluetooth enabled.
- Correct URL scheme in `CFBundleURLSchemes`.
- `MWDAT.AppLinkURLScheme` matches the URL scheme and includes `://`.
- `UISupportedExternalAccessoryProtocols` includes `com.meta.ar.wearable`.
- Background modes include `bluetooth-peripheral` and `external-accessory`.
- `registrationStateStream()` reaches `registered`.
- `devicesStream()` emits a compatible device.
- `StreamSession` does not remain stuck in `waitingForDevice`.

## Known Issues

- No internet can cause registration failure.
- Developer Mode can toggle off after firmware updates.
- Developer Mode is per-device.
- Streams started while glasses are doffed may pause when donned; wait for state changes.
- Avoid relying on `DeviceStateSession` while using camera streaming.

## Allowed Dependencies

The DAT app should only depend on:

- `MWDATCore`
- `MWDATCamera`
- `MWDATMockDevice`

## Links

- iOS API Reference: https://wearables.developer.meta.com/docs/reference/ios_swift/dat/0.6
- Developer Documentation: https://wearables.developer.meta.com/docs/develop/
- GitHub Repository: https://github.com/facebook/meta-wearables-dat-ios
- Mock Device Kit: https://wearables.developer.meta.com/docs/mock-device-kit/
- Session Lifecycle: https://wearables.developer.meta.com/docs/lifecycle-events
