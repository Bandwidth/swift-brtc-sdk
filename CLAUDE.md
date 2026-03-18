# CLAUDE.md — Bandwidth RTC Swift SDK

## What this repo is

A Swift iOS SDK (`BandwidthRTC`) that wraps WebRTC to provide real-time audio calling via the Bandwidth BRTC gateway. Distributed as a signed XCFramework. iOS 17+, Swift 5.9+, SPM-only.

---

## Repo structure

```
Sources/BandwidthRTC/
├── BandwidthRTC.swift               # Main public client class
├── Exports.swift                    # Re-exports WebRTC types
├── Types/                           # All public data types and enums
├── Signaling/                       # WebSocket actor + JSON-RPC 2.0 message types
│   └── RPC/
├── WebRTC/                          # Dual peer connection management
├── Media/                           # MixingAudioDevice (custom RTCAudioDevice)
└── Utilities/                       # Logger

Plugins/GenerateSDKVersion/          # Build plugin — reads VERSION file, generates SDKVersion+Generated.swift
Tests/BandwidthRTCTests/
├── *Tests.swift                     # Unit tests
└── Mocks/                           # Protocol-backed mocks for all major dependencies

.github/
├── workflows/
│   ├── build.yml                    # Runs on every push; enforces version bump on PRs
│   ├── draft_release.yml            # Runs on push to main; creates draft GitHub release
│   └── release_publish.yml         # Runs when release is published; builds + attaches XCFramework
└── actions/build-xcframework/       # Composite action: Xcode setup → archive → zip

VERSION                              # Single source of truth for the SDK version (e.g. 1.0.1)
```

---

## Architecture

### Main client: `BandwidthRTC.swift`
- `public final class BandwidthRTCClient` is the only public entry point
- Dependencies (`SignalingClient`, `PeerConnectionManager`, `MixingAudioDevice`) are injected via constructor — use mocks in tests
- Event callbacks are simple optional closures set as properties: `onStreamAvailable`, `onReady`, `onRemoteDisconnected`, etc.

### Signaling: `SignalingClient.swift`
- An `actor` — all signaling state is protected by actor isolation
- Sends JSON-RPC 2.0 requests over WebSocket; correlates responses by auto-incremented ID via `CheckedContinuation`
- Server notifications (e.g. `sdpOffer`, `ready`) are dispatched to registered handlers via `onEvent(method:handler:)`
- Default gateway: `wss://gateway.pv.prod.global.aws.bandwidth.com/prod/gateway-service/api/v1/endpoints`

### Peer connections: `PeerConnectionManager.swift`
- Maintains two `RTCPeerConnection`s: one **publish** (send-only) and one **subscribe** (receive-only)
- Both connect on `connect()` with an empty initial SDP handshake; tracks are added only on `publish()`
- Protocol-backed (`PeerConnectionManagerProtocol`) for test injection

### Audio: `MixingAudioDevice.swift`
- Implements `RTCAudioDevice` — owns `AVAudioSession` configuration
- Recording: taps `AVAudioEngine` input node → delivers PCM to WebRTC + fires `onLocalAudioLevel` callback
- Playout: `AVAudioSourceNode` pulls Int16 PCM from WebRTC → Float32 → fires `onRemoteAudioLevel` callback
- Fixed 48kHz / mono / 10ms (480 samples) — pre-allocated buffers, no heap alloc on audio thread

### Testability pattern
All major subsystems are abstracted behind protocols:
- `SignalingClientProtocol` → `MockSignalingClient`
- `PeerConnectionManagerProtocol` → `MockPeerConnectionManager`
- `WebSocketProtocol` → `MockWebSocket`

Tests live in `Tests/BandwidthRTCTests/`. Pass mocks into `BandwidthRTCClient` init; never use real network or WebRTC in unit tests.

---

## Versioning

**The `VERSION` file is the single source of truth.** No hardcoded version strings anywhere.

> ⚠️ **Every PR must bump `VERSION`.** CI (`build.yml`) checks that the version on the branch is strictly greater than `origin/main` and **will fail** if it is not. Increment patch for bug fixes, minor for new features, major for breaking changes.

- `VERSION` contains a plain semver string (e.g. `1.0.1`)
- The `GenerateSDKVersion` build plugin reads `VERSION` at build time and generates `SDKVersion+Generated.swift` — this is how `SDKVersion.current` gets its value for both local and CI builds
- Do **not** add a committed `SDKVersion.swift` to Sources — the plugin generates that symbol into its work directory

### Flow
```
Bump VERSION in PR → CI enforces it's higher than main → merge → draft release created automatically → publish release → XCFramework built and attached
```

---

## CI/CD

### `build.yml` — runs on every branch push (not tags)
1. On non-main branches: checks `VERSION` > `origin/main:VERSION` (fails with hint if not)
2. Reads `VERSION` → passes as `marketing_version` to composite action
3. Builds XCFramework (runs unit tests too)
4. Uploads artifact `BandwidthRTC-{VERSION}` (3-day retention)

### `draft_release.yml` — runs on push to main/master
1. Reads `VERSION`
2. If a draft release tagged `v{VERSION}` already exists: updates it with auto-generated notes
3. If a published release tagged `v{VERSION}` already exists: fails with an error (bump `VERSION`)
4. Otherwise: creates a new draft release tagged `v{VERSION}` with auto-generated notes

### `release_publish.yml` — runs when a release is published
1. Reads `VERSION`
2. Builds XCFramework (no tests)
3. Uploads `BandwidthRTC.xcframework.zip` to the release assets
4. Creates annotated major (`v{MAJOR}`) and minor (`v{MAJOR}.{MINOR}`) version tags if they don't already exist

### `build-xcframework` composite action
Inputs: `marketing_version`, `run_tests` (default false)
Output: `zip_path`

Steps: select Xcode → cache simulator runtime → optionally run tests → archive iOS + iOS Simulator → create XCFramework → zip

Key xcodebuild flags: `BUILD_LIBRARY_FOR_DISTRIBUTION=YES`, `CODE_SIGN_IDENTITY=""`, `OTHER_SWIFT_FLAGS="-Xfrontend -no-verify-emitted-module-interface"`

---

## Key conventions

- **No storyboards, no UIKit** — SDK only, no app target
- **Swift concurrency throughout** — use `async/await`; callbacks are `@Sendable`
- **`@unchecked Sendable`** on public types that wrap WebRTC objects (WebRTC itself is not Sendable)
- **No force unwraps** in production code
- **Logging via `Logger.shared`** — levels: `.off .error .warn .info .debug .trace`; default is `.warn`
- **JSON-RPC types** are in `Signaling/RPC/` — each method gets its own file with `Params` and `Result` structs
- **`BandwidthRTCError`** is the only error type surfaced to callers — map internal errors before throwing

---

## Dependencies

| Package | Version | Purpose |
|---|---|---|
| `stasel/WebRTC` | `114.0.0` (exact) | Core WebRTC engine |

No other external dependencies. Do not add dependencies without a strong reason.

---

## Things to avoid

- Do not add a committed `SDKVersion.swift` to Sources — `SDKVersion.current` is generated by the build plugin from `VERSION`
- Do not add git-tag-based versioning logic — `VERSION` file is intentional
- Do not add a CI step that overwrites `SDKVersion.swift` — the plugin handles it at build time
- Do not modify `AVAudioSession` category/mode outside of `MixingAudioDevice` — it owns the audio session
- Do not use `release-drafter` or similar — `draft_release.yml` handles releases directly
