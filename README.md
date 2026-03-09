# Bandwidth RTC Swift

Bandwidth RTC Swift is an iOS SDK for building real-time audio communication apps on the Bandwidth platform. Please refer to the (BandwidthRTC documentation)[https://dev.bandwidth.com/docs/voice/programmable-voice/bxml/connect] for learning more about the product.

## Quick Start

```swift
import BandwidthRTC

class CallService {
    let brtc = BandwidthRTC()

    func startCall(token: String) async throws {
        brtc.onStreamAvailable = { stream in
            // Handle incoming remote audio stream
            print("Remote stream available: \(stream.streamId)")
        }

        brtc.onStreamUnavailable = { streamId in
            print("Remote stream removed: \(streamId)")
        }

        brtc.onReady = { metadata in
            print("Connected — endpointId: \(metadata.endpointId ?? "unknown")")
        }

        try await brtc.connect(authParams: RtcAuthParams(endpointToken: token))
        let localStream = try await brtc.publish(audio: true)
        print("Publishing local audio: \(localStream.streamId)")
    }

    func endCall() {
        brtc.disconnect()
    }
}
```

## Samples

A number of samples using Bandwidth WebRTC Swift may be found within [Bandwidth-Samples](https://github.com/Bandwidth-Samples).

## Compatibility

Bandwidth WebRTC Swift follows [SemVer 2.0.0](https://semver.org/#semantic-versioning-200).