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

## Configuration

### `BandwidthRTCClient` init

| Parameter | Type | Default | Description |
|---|---|---|---|
| `logLevel` | `LogLevel` | `.warn` | SDK log verbosity (`.off`, `.error`, `.warn`, `.info`, `.debug`, `.trace`) |

### `RtcAuthParams`

Passed to `connect(authParams:options:)`.

| Field | Type | Required | Description |
|---|---|---|---|
| `endpointToken` | `String` | Yes | JWT endpoint token obtained from the Bandwidth Endpoints API |

### `RtcOptions`

Passed as `options` to `connect(authParams:options:)`. All fields are optional.

| Field | Type | Default | Description |
|---|---|---|---|
| `websocketUrl` | `String?` | `nil` | Override the default BRTC gateway WebSocket URL |
| `iceServers` | `[RTCIceServer]?` | `nil` | Custom STUN/TURN servers. Uses WebRTC defaults when `nil` |
| `iceTransportPolicy` | `RTCIceTransportPolicy?` | `.all` | Restrict ICE candidate types (e.g. `.relay` to force TURN) |
| `audioProcessing` | `AudioProcessingOptions` | See below | Audio session, sample rate, and buffer configuration |

### `AudioProcessingOptions`

Nested inside `RtcOptions.audioProcessing`.

| Field | Type | Default | Description |
|---|---|---|---|
| `audioSessionMode` | `AVAudioSession.Mode` | `.voiceChat` | AVAudioSession mode. `.voiceChat` enables Apple hardware AEC and noise suppression; use `.default` or `.measurement` to disable |
| `audioSessionCategoryOptions` | `AVAudioSession.CategoryOptions` | `[.allowBluetoothHFP]` | AVAudioSession category options (e.g. add `.defaultToSpeaker` to route audio to the loudspeaker) |
| `inputSampleRate` | `Double` | `48000` | Recording sample rate in Hz. 48 kHz matches WebRTC's Opus rate and avoids a resampling step |
| `outputSampleRate` | `Double` | `48000` | Playout sample rate in Hz |
| `inputChannels` | `Int` | `1` | Number of input (microphone) channels |
| `outputChannels` | `Int` | `1` | Number of output (speaker) channels |
| `useLowLatency` | `Bool` | `false` | Request a 5 ms I/O buffer from AVAudioSession. Reduces latency at the cost of higher CPU usage |
| `preferredIOBufferDuration` | `TimeInterval?` | `nil` | Explicit I/O buffer duration in seconds. Overrides `useLowLatency` when set; the OS rounds to the nearest supported value |

---

## Samples

Sample apps can be found in [Bandwidth-Samples](https://github.com/Bandwidth-Samples).

---

## Compatibility

This SDK follows [SemVer 2.0.0](https://semver.org/#semantic-versioning-200). Each release publishes three Git tags — `v{MAJOR}`, `v{MAJOR}.{MINOR}`, and `v{MAJOR}.{MINOR}.{PATCH}` — so you can pin at any granularity in your `Package.swift`:

```swift
// Exact version
.package(url: "https://github.com/Bandwidth/swift-brtc-sdk", exact: "1.0.0"),

// Latest patch in a minor series
.package(url: "https://github.com/Bandwidth/swift-brtc-sdk", from: "1.0.0"),
```

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
