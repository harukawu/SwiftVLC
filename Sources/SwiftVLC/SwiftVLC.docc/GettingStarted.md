# Getting started

This guide walks through adding SwiftVLC to a project, loading a
media, and rendering it on screen.

## Add the package

The quickest path is through Xcode. Choose **File → Add Package
Dependencies** and paste the repository URL; Xcode resolves the latest
release automatically.

```
https://github.com/harukawu/SwiftVLC.git
```

To add it from a `Package.swift` manifest, pin to the current release.
The version string lives on the
[releases page](https://github.com/harukawu/SwiftVLC/releases).

```swift
dependencies: [
    .package(url: "https://github.com/harukawu/SwiftVLC.git", from: "0.10.4")
],
targets: [
    .target(name: "MyApp", dependencies: ["SwiftVLC"])
]
```

SwiftVLC requires Swift 6.3 and supports iOS 18, macOS 15, tvOS 18,
visionOS 2, and macCatalyst 18.

## Add the iOS signing build phase

Physical iOS devices require the nested libVLC dylibs and plugins to be signed
with your app's signing identity. Add a Run Script phase near the end of your
iOS app target's Build Phases. The helper signs every DerivedData copy Xcode may
use for embedding, including SwiftPM's `SourcePackages/artifacts` slice, the
`TARGET_BUILD_DIR` product, and the embedded app copy if it already exists. For
local package development, you may set `SWIFTVLC_SCRIPT` directly to your
checkout's `scripts/sign-libvlc-embedded-framework.sh`.

```bash
set -euo pipefail

SWIFTVLC_SCRIPT="${SWIFTVLC_SCRIPT:-}"

if [ -z "$SWIFTVLC_SCRIPT" ]; then
  for search_root in \
    "${BUILD_DIR}/../../SourcePackages/checkouts" \
    "${SRCROOT}/.." \
    "${SRCROOT}/../.."
  do
    [ -d "$search_root" ] || continue
    SWIFTVLC_SCRIPT=$(find "$search_root" -path "*/scripts/sign-libvlc-embedded-framework.sh" -print -quit 2>/dev/null || true)
    [ -n "$SWIFTVLC_SCRIPT" ] && break
  done
fi

if [ ! -x "$SWIFTVLC_SCRIPT" ]; then
  echo "error: SwiftVLC signing script not found; set SWIFTVLC_SCRIPT to scripts/sign-libvlc-embedded-framework.sh" >&2
  exit 1
fi

"$SWIFTVLC_SCRIPT"
```

The script signs `libvlccore.dylib` and VLC plugin dylibs with
`EXPANDED_CODE_SIGN_IDENTITY`, then re-signs `libvlc.framework` with
`org.videolan.libvlc`. Without this phase, physical device launches can fail
with a dyld `code signature invalid` error for `libvlccore.dylib`.

## Prepare libVLC at launch

The first libVLC instance does one-time plugin and decoder setup. Start
that work when your app launches so the first playback screen does not
pay the cost while SwiftUI is pushing the view:

```swift
import SwiftUI
import SwiftVLC

@main
struct MyApp: App {
    init() {
        VLCInstance.prewarmShared()
    }

    var body: some Scene {
        WindowGroup { PlayerView() }
    }
}
```

If your app has an explicit loading phase, await
``VLCInstance/prepareShared(priority:)`` before presenting playback UI.

## Play a URL

```swift
import SwiftUI
import SwiftVLC

struct PlayerView: View {
    @State private var player = Player()

    var body: some View {
        VideoView(player)
            .task {
                try? player.play(url: URL(string: "https://example.com/stream.m3u8")!)
            }
    }
}
```

``VideoView`` hosts the player's output, and ``Player`` publishes its
state through `@Observable`, which is enough for SwiftUI to redraw as
playback progresses.

``Player/play(url:)`` expects a direct media stream or file URL. It
does not auto-resolve `.pls` or classic `.m3u` playlist containers; use
``MediaListPlayer`` or resolve the playlist to its inner stream URL
before handing it to ``Player``. HLS `.m3u8` URLs are supported here
because they are streaming manifests rather than playlists of separate
media URLs.

## Drive the UI from state

Most controls read a handful of observable properties directly:

```swift
Text(player.state.description)
ProgressView(value: player.position)
Button(player.isPlaying ? "Pause" : "Play") {
    player.togglePlayPause()
}
```

<doc:PlaybackEssentials> documents the full observable surface;
<doc:DisplayingVideo> covers sizing and aspect ratios.

## Handle errors as typed throws

Every throwing API throws ``VLCError`` specifically, so `catch`
clauses can match individual cases:

```swift
do {
    try player.play(url: url)
} catch .mediaCreationFailed(let source) {
    print("Bad URL: \(source)")
} catch {
    print("Playback error: \(error)")
}
```

See <doc:HandlingErrors> for the full case list.

## Next steps

- <doc:PlaybackEssentials>: the shape of ``Player``.
- <doc:WorkingWithMedia>: parsing metadata, tracks, and slaves.
- <doc:DisplayingVideo>: aspect ratios and layer lifecycle.
- <doc:PictureInPicture>: background playback and floating windows.
