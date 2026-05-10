<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Assets/logo-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="Assets/logo-light.svg">
  <img alt="SwiftVLC" src="Assets/logo-light.svg" width="260">
</picture>

A Swift wrapper around [libVLC](https://www.videolan.org/vlc/libvlc.html).

This fork keeps the upstream Swift API surface but changes the bundled libVLC
distribution model for App Store-oriented iOS apps: libVLC is rebuilt as
dynamic iOS frameworks inside `libvlc.xcframework`, and the build scripts add
LGPL-oriented guardrails that keep GPL and GNUv3 contrib options disabled.

The Swift package manifest still carries upstream platform declarations for
source compatibility, but this fork's rebuilt binary artifact is currently
iOS-only: `ios-arm64` for devices and `ios-arm64_x86_64-simulator` for
simulators.

## Why?

AVFoundation is excellent for Apple's native media stack, but its
container, codec, subtitle, and network-protocol support is limited to
what Apple ships. Apps that need MKV, SSA/ASS subtitles, RTSP, SMB,
UPnP, or other VLC-backed formats and protocols need a broader engine.

[VLC](https://www.videolan.org/)'s engine, **libVLC**, supports a broad set of codecs, containers, subtitles, and network protocols through embeddable C APIs.

VideoLAN's Apple wrapper, [VLCKit](https://code.videolan.org/videolan/VLCKit), is written primarily in Objective-C. It uses delegates, KVO, `NSNotificationCenter`, and manual thread management, which is a faithful reflection of the era it was designed in.

**SwiftVLC** wraps libVLC 4.0 directly in Swift, with no Objective-C layer in between. It is built for `@Observable`, `async/await`, and `VideoView(player)`.

## SwiftVLC vs VLCKit

| | SwiftVLC | VLCKit |
|---|---|---|
| **Language** | Swift 6 | Objective-C |
| **Bindings** | Direct C → Swift | C → Objective-C → Swift bridging |
| **State management** | `@Observable`, drives SwiftUI directly | KVO, `NSNotificationCenter`, and delegates |
| **Concurrency** | `@MainActor`, `Sendable`, `async/await` | Manual thread dispatch, no isolation |
| **Video rendering** | `VideoView(player)` | App-supplied view setup plus drawable configuration |
| **Errors** | `throws(VLCError)`, typed and exhaustive | `NSError` codes |
| **Events** | `AsyncStream<PlayerEvent>` with multiple consumers | `NSNotificationCenter` |
| **libVLC generation** | 4.0 | 3.x stable line; 4.0 alpha packages exist |
| **SwiftUI PiP** | iOS via public AVKit sample buffers; macOS private backend is SPI opt-in | App-supplied integration |
| **Swift 6 safe** | Yes, with strict concurrency | No |

## Features

- `@Observable` player: state, current time, duration, tracks, and volume drive SwiftUI directly.
- `VideoView(player)` handles the rendering lifecycle in a single SwiftUI view.
- Typed errors via `throws(VLCError)` instead of error codes.
- Asynchronous media parsing: `try await media.parse()` with cancellation support.
- 10-band equalizer with libVLC's built-in presets.
- A-B looping, playback rate control, and subtitle and audio delay.
- Picture-in-Picture on iOS with full playback controls; macOS native PiP is available only through an explicit private-API SPI opt-in.
- Media discovery and renderer discovery through services exposed by the bundled libVLC plugins.
- 360° video with full viewpoint control over yaw, pitch, roll, and field of view.
- Asynchronous thumbnail generation at arbitrary timestamps.
- `MediaListPlayer` for playlist playback with loop and repeat modes.

## Requirements

- Swift 6.3+ / Xcode 26+
- Rebuilt libVLC artifact: iOS 18+ device and simulator slices
- Swift source compatibility follows the upstream manifest: iOS 18+ / macOS 15+ / tvOS 18+ / visionOS 2+ / Mac Catalyst 18+

## Installation

In Xcode, choose **File → Add Package Dependencies**, paste the repo
URL, and Xcode will pick up the latest release automatically:

```
https://github.com/harukawu/SwiftVLC.git
```

From a `Package.swift` manifest, add a dependency and pin to the
current release. The version string lives on the
[releases page](https://github.com/harukawu/SwiftVLC/releases).

```swift
.package(url: "https://github.com/harukawu/SwiftVLC.git", from: "x.y.z")
```

The pre-built libVLC xcframework downloads automatically via SPM once a fork
release has been published. It is intentionally kept out of Git and shipped as
a release asset, matching the upstream workflow.

## Quick Start

```swift
import SwiftUI
import SwiftVLC

struct PlayerView: View {
  @State private var player = Player()

  var body: some View {
    VideoView(player)
      .onAppear {
        try? player.play(url: URL(string: "https://example.com/video.mp4")!)
      }
  }
}
```

`Player.play(url:)` expects a direct media stream or file URL. It does
not auto-resolve `.pls` or classic `.m3u` playlist containers; use
`MediaListPlayer` or fetch and parse the playlist to its inner stream
URL before passing it to `Player`. HLS `.m3u8` URLs are supported here
because they are streaming manifests rather than playlists of separate
media URLs.

### Common Operations

```swift
// Playback
let player = Player()
try player.play(url: videoURL)
player.pause()
player.stop()
try player.seek(to: PlaybackPosition(0.5)) // Seek to 50%
try player.setPlaybackRate(1.5)            // 1.5x speed
try player.setAudioVolume(0.8)             // 80% volume
player.isMuted = true

// Tracks
player.selectedSubtitleTrack = player.subtitleTracks[1]

// Metadata
let media = try Media(url: videoURL)
let metadata = try await media.parse()
print(metadata.title, metadata.duration)

// Events
for await event in player.events {
  switch event {
  case .stateChanged(let state): ...
  case .timeChanged(let time): ...
  default: break
  }
}
```

## Documentation

The upstream API reference is hosted on Swift Package Index:
**[swiftpackageindex.com/harflabs/swiftvlc/documentation](https://swiftpackageindex.com/harflabs/swiftvlc/documentation)**

## Showcase Apps

The `Showcase/` directory contains separate folders, targets, and schemes for each showcase lane:

- **iOS.** Full-featured app target, also enabled for Mac Catalyst.
- **macOS.** Native macOS app target with the same showcase coverage, adapted into sidebar-driven Mac UI.
- **tvOS.** Native tvOS showcase app target with TV-focused focus navigation and Siri Remote controls.
- **visionOS.** Native visionOS app target with a focused simple playback showcase.

Showcase UI tests live under `Showcase/UITests/`. `iOSUITests` covers
the broad showcase flows, `macOSUITests` covers native macOS PiP, and
`tvOSUITests` is a placeholder target. The visionOS showcase does not
have a UI-test target.

## Testing

The core package uses a comprehensive
[Swift Testing](https://developer.apple.com/xcode/swift-testing/) suite
against the real libVLC binary, so regressions in the C bridge surface
immediately rather than hiding behind a fake. Showcase UI tests use
XCTest separately.

For this iOS-only dynamic-framework rebuild, prefer an iOS simulator test run.
`swift test` may still be useful for pure Swift iteration, but it does not
exercise the iOS binary target embedding path that matters for this fork.

```bash
xcrun simctl list devices available
xcodebuild -scheme SwiftVLC \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/SwiftVLC-DerivedData \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  test
```

See [ARCHITECTURE.md](ARCHITECTURE.md#testing-strategy) for test tags,
fixtures, and structure.

## Development Setup

```bash
git clone https://github.com/harukawu/SwiftVLC.git
cd SwiftVLC
./scripts/setup-dev.sh
xcodebuild -scheme SwiftVLC -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

`main` tracks the latest released `url + checksum` form of the libVLC binary
target. `setup-dev.sh` downloads `libvlc.xcframework.zip` into `Vendor/` and
idempotently flips `Package.swift` plus the Showcase package reference to
repo-local sources so package development and Showcase builds use the checkout
on disk. The `Vendor/` directory is ignored by Git; do not commit the generated
xcframework. `setup-dev.sh` and `release.sh` default to
`harukawu/SwiftVLC`; set `SWIFTVLC_GITHUB_REPO=owner/repo` if this fork moves.

| `setup-dev.sh` flag | Effect |
|---|---|
| *(none)* | Download the latest fork release if `Vendor/` is empty; otherwise keep existing. |
| `vX.Y.Z` *(positional)* | Pin to a specific release tag. |
| `--force` | Re-download even if `Vendor/` already exists. |
| `--skip-download` | Only flip local references (`Package.swift` and the Showcase app). Expects `Vendor/` to already exist, which is useful after running `build-libvlc.sh`. |

## Building libVLC from Source

Needed only when bumping `VLC_HASH`, modifying build patches, or preparing a release. Day-to-day Swift development doesn't require it.

```bash
brew install autoconf automake libtool cmake pkg-config gettext python@3
./scripts/build-libvlc.sh --ios-only
```

`--ios-only` is also the default, so `./scripts/build-libvlc.sh` is equivalent.
The script clones VLC at the pinned `VLC_HASH` into `scripts/.build-libvlc/`,
applies the source patches below, builds iOS device and simulator dynamic
libraries with `--enable-shared`, and assembles the result into
`Vendor/libvlc.xcframework`.

Expected output:

```text
Vendor/libvlc.xcframework/
  ios-arm64/libvlc.framework/libvlc
  ios-arm64/libvlc.framework/plugins/
  ios-arm64_x86_64-simulator/libvlc.framework/libvlc
  ios-arm64_x86_64-simulator/libvlc.framework/plugins/
```

The package must not contain static archives or libtool metadata:

```bash
./scripts/verify-libvlc-xcframework.sh Vendor/libvlc.xcframework
find Vendor/libvlc.xcframework -name '*.a' -o -name '*.la'
```

### Platform selection

| Flag | Platforms |
|---|---|
| *(default)* | iOS device + simulator |
| `--ios-only` | Explicit iOS device + simulator build |
| `--clean` / `--clean-build` | Wipe `scripts/.build-libvlc/` (the latter rebuilds afterwards) |
| `--hash=<sha>` | Override the pinned VLC commit |

Non-iOS platform flags are rejected in this fork. `Package.swift` keeps the
upstream platform declarations, but the release artifact produced here is
iOS-only.

### Source patches

VLC master requires local patches for SwiftVLC's supported Apple toolchain and
for this fork's licensing target. The script applies them in-tree on every
invocation, idempotently:

1. **LGPL-oriented contrib options.** Ensures VLC contrib bootstrap keeps
   `--disable-gpl` and `--disable-gnuv3`, and explicitly disables common
   GPL-only or GPL-sensitive contribs such as dvdcss/dvdread, x264/x265, faad,
   dca, mpeg2, and postproc.
2. **Dynamic framework build.** Invokes VLC's Apple build with
   `--enable-shared`, stages `libvlc.framework`, rewrites local install names
   to `@rpath`/`@loader_path`, and verifies there are no packaged `.a` or `.la`
   files.
3. **Bundled plugin discovery.** The C shim locates
   `libvlc.framework/plugins`, sanitizes stale build-tree plugin paths, sets
   `VLC_PLUGIN_PATH`, and sets `VLC_LIB_PATH` before `libvlc_new()`.
4. **Xcode 26 flags and deployment targets.** Adds missing SDK and minimum-OS
   flags so Apple SDK 26 toolchains do not stamp object files with a higher
   deployment target.
5. **Snapshot and sample-buffer stability.** Patches VLC's snapshot filter
   owner allocation and iOS sample-buffer display teardown so fast
   attach/play/detach flows do not race vout teardown.
6. **libtool 2.5 OBJC tag.** Adds `_LIBTOOLFLAGS = --tag=CC` to the
   `Makefile.am` files that contain `.m` sources. Older libtool versions
   inferred the tag; 2.5 refuses.
7. **Rust contribs disabled.** VLC's contribs pin `cargo-c 0.9.29`, which pulls
   `time 0.3.31` and fails type inference under the supported Rust toolchain.
   The only Rust contrib on Apple is `rav1e` (AV1 encoder); `dav1d` handles
   decoding.
8. **`dup3` / `pipe2`.** Forced unavailable via autoconf cache vars. iOS
   Simulator SDK 26 exports these Linux-only syscalls from libSystem, fooling
   configure into using them.

`git reset --hard` only runs when HEAD is not at `VLC_HASH`, so the patches and per-platform build dirs survive repeated runs.

## Releasing

Releases advance `main`: `release.sh` rewrites `Package.swift` to the new
remote xcframework URL + checksum, pins the Showcase app to that exact SwiftVLC
version, tags that commit, uploads the zip as a GitHub Release asset, and then
pushes `main` to that same commit. `setup-dev.sh` is what flips a working
checkout back to local sources for day-to-day development.

```bash
./scripts/build-libvlc.sh --ios-only     # produces Vendor/libvlc.xcframework
./scripts/release.sh X.Y.Z --dry-run     # strip + zip + checksum, no push
./scripts/release.sh X.Y.Z               # cut the release
```

What `release.sh` does:

1. Verifies both iOS slices are present in the xcframework.
2. Copies it to a temp dir, strips debug symbols, zips with `ditto`.
3. Computes SHA-256 via `swift package compute-checksum`.
4. Rewrites `Package.swift` to the remote URL and checksum, and pins the Showcase app to `SwiftVLC` exact version `X.Y.Z`.
5. Commits that change and tags it as `vX.Y.Z`.
6. Pushes the tag first so GitHub can attach the release asset to that exact commit.
7. Uploads the zip to a new GitHub Release.
8. Pushes `main` to the same commit, so `main` always references the latest published xcframework and Showcase package version.

Preflight refuses non-`main` branches, uncommitted changes in `Package.swift` or the Showcase project, pre-existing local or remote tags, and unauthenticated `gh`. If a pre-commit rewrite fails, the script restores `Package.swift` and the Showcase project before exiting. If the tag push succeeds but a later step fails, `origin/main` is still untouched; finish the GitHub Release (or delete the tag) before retrying.

## Architecture

For internals, including module design, C interop, the concurrency model, the event system, memory management, and the PiP rendering pipeline, see **[ARCHITECTURE.md](ARCHITECTURE.md)**.

## License

SwiftVLC's Swift, C shim, scripts, and documentation are licensed under the
MIT License. See [LICENSE](LICENSE). The upstream project copyright notice is
preserved there; modifications in this fork are copyright their respective
contributors.

libVLC and VLC source code are separate VideoLAN works with their own copyright
notices and license files. This fork builds the embeddable libVLC pieces as
dynamic frameworks and keeps GPL/GNUv3 contrib options disabled so downstream
apps can evaluate use under libVLC's LGPL terms. See the
[VLC licensing FAQ](https://www.videolan.org/legal.html), the pinned VLC source
checked out under `scripts/.build-libvlc/`, and the final GPL scan notes in
this repository before publishing an app. This README is engineering
documentation, not legal advice.

## Acknowledgments

SwiftVLC stands on the work of the [VideoLAN](https://www.videolan.org/) community. VLC and libVLC represent decades of media playback work by hundreds of contributors.

Thanks also to [VLCKit](https://code.videolan.org/videolan/VLCKit) for establishing libVLC on Apple platforms.
