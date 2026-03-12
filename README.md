# Bandwidth RTC Swift SDK

An iOS SDK for building real-time audio communication apps on the [Bandwidth](https://www.bandwidth.com) platform. Wraps WebRTC and connects to the Bandwidth BRTC gateway over a JSON-RPC 2.0 WebSocket signaling channel. Distributed as a signed XCFramework via Swift Package Manager.

For product documentation, see the [Bandwidth RTC developer docs](https://dev.bandwidth.com/docs/brtc/).

---

## Requirements

- iOS 17+
- Swift 5.9+
- Xcode 16+
- Swift Package Manager

---

## Installation

### Swift Package Manager

In Xcode, go to **File → Add Package Dependencies** and enter the repository URL. Or add it directly to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Bandwidth/swift-brtc-sdk", from: "1.0.0"),
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "BandwidthRTC", package: "swift-brtc-sdk")
        ]
    ),
]
```

---

## Quick Start

```swift
import BandwidthRTC

class CallService {
    let client = BandwidthRTCClient()

    func startCall(token: String) async throws {
        // Called when a remote participant starts streaming
        client.onStreamAvailable = { stream in
            print("Remote stream available: \(stream.streamId)")
        }

        // Called when a remote participant stops streaming
        client.onStreamUnavailable = { streamId in
            print("Remote stream removed: \(streamId)")
        }

        // Called once the gateway signals readiness
        client.onReady = { metadata in
            print("Connected — endpointId: \(metadata.endpointId ?? "unknown")")
        }

        // Called if the WebSocket drops unexpectedly
        client.onDisconnected = {
            print("Disconnected from gateway")
        }

        // Connect and publish local microphone audio
        try await client.connect(authParams: RtcAuthParams(endpointToken: token))
        let localStream = try await client.publish(audio: true)
        print("Publishing local audio: \(localStream.streamId)")
    }

    func endCall() {
        client.disconnect()
    }
}
```

---

## Callbacks

| Property | When it fires |
|---|---|
| `onReady` | Gateway signals the endpoint is ready to receive calls |
| `onStreamAvailable` | A remote participant begins streaming audio |
| `onStreamUnavailable` | A remote participant stops streaming |
| `onDisconnected` | WebSocket connection dropped unexpectedly |
| `onLocalAudioLevel` | Per-chunk Float32 mic samples (for visualization) |
| `onRemoteAudioLevel` | Per-chunk Float32 remote playout samples (for visualization) |

---

## Samples

Sample apps can be found in [Bandwidth-Samples](https://github.com/Bandwidth-Samples).

---

## Compatibility

This SDK follows [SemVer 2.0.0](https://semver.org/#semantic-versioning-200).

---

## Contributing

> **Every PR must bump the `VERSION` file.** CI will fail if you don't.

1. Make your changes.
2. Open `VERSION` at the repo root and increment the version (e.g. `1.0.1` → `1.0.2`). Use patch for bug fixes, minor for new features, major for breaking changes.
3. Open your PR — `build.yml` enforces that the new version is strictly greater than `main`.

### Running Unit Tests

#### In Xcode

1. Open the package:
   ```
   open Package.swift
   ```
2. Select the **BandwidthRTC** scheme.
3. Choose an iOS Simulator destination (e.g. **iPhone 17 Pro**).
4. Press **⌘U**.

#### From the command line

```bash
xcodebuild test \
  -scheme BandwidthRTC \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```
