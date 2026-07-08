# LGPL-Oriented libVLC Rebuild Audit

Date: 2026-07-08

Scope: the local ignored `Vendor/libvlc.xcframework` rebuilt from VLC commit
`c833c4be0` by `./scripts/build-libvlc.sh --ios-only`, after merging upstream
SwiftVLC `0c86d84...9065ad6` for the fork `v0.10.0` release.

This is an engineering audit for the fork's LGPL-oriented iOS dynamic-framework
rebuild. It is not legal advice.

## Build Configuration

- `scripts/build-libvlc.sh` invokes VLC's Apple build with `--enable-shared`.
- The patched VLC `extras/package/apple/build.conf` contains
  `--disable-gpl` and `--disable-gnuv3`.
- GPL-sensitive contribs are explicitly disabled: `dvdcss`, `dvdread`,
  `dvdnav`, `x264`, `x265`, `faad`/`faad2`, `dca`, `mpeg2`, and `postproc`.
- Scan command:

```bash
rg -n -- "--enable-(gpl|gnuv3|dvdcss|libdvdcss|dvdread|dvdnav|x264|x265|faad|faad2|dca|libdca|mpeg2|libmpeg2|postproc)([^A-Za-z0-9_-]|$)" scripts/build-libvlc.sh scripts/.build-libvlc/vlc/extras/package/apple/build.conf
```

Result: no matches.

```bash
rg -n -- "--disable-(gpl|gnuv3|dvdcss|libdvdcss|dvdread|dvdnav|x264|x265|faad|faad2|dca|libdca|mpeg2|libmpeg2|postproc)([^A-Za-z0-9_-]|$)" scripts/build-libvlc.sh scripts/.build-libvlc/vlc/extras/package/apple/build.conf
```

Result: required disable options are present in both our wrapper script and the
patched VLC build config.

## Artifact Scan

Validation command:

```bash
./scripts/verify-libvlc-xcframework.sh Vendor/libvlc.xcframework
```

Result: dynamic iOS libVLC xcframework verification passed.

Additional scans:

```bash
find Vendor/libvlc.xcframework \( -name '*.a' -o -name '*.la' \) -print
find Vendor/libvlc.xcframework \( -path '*/Resources/share/doc' -o -path '*/Resources/share/man' \) -print
rg --files Vendor/libvlc.xcframework | rg -i "dvdcss|dvdread|dvdnav|x264|x265|faad|libdca|dca_plugin|mpeg2|postproc|gpl|gnuv3"
```

Results: no static archives, no libtool archives, no non-runtime VLC doc/man
resources, and no GPL-sensitive component filenames were found in the packaged
xcframework.

Mach-O/linkage scans:

```bash
file Vendor/libvlc.xcframework/*/libvlc.framework/libvlc
otool -D Vendor/libvlc.xcframework/*/libvlc.framework/libvlc
otool -L Vendor/libvlc.xcframework/*/libvlc.framework/libvlc
otool -l Vendor/libvlc.xcframework/*/libvlc.framework/libvlc
```

Results: device and simulator binaries are Mach-O dynamically linked shared
libraries; install names are `@rpath/libvlc.framework/libvlc`; dependencies are
runtime-relative or system paths; iOS device and simulator slices report minimum
OS 18.0.

## Test Verification

Command:

```bash
xcodebuild test -scheme SwiftVLC -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug -derivedDataPath /private/tmp/SwiftVLC-v010-tests -skipPackagePluginValidation -skipMacroValidation -collect-test-diagnostics never CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Result: passed. Swift Testing reported 1496 tests in 123 suites. The upstream
native volume-event assertion is skipped on iOS simulator because that backend
applies volume changes without emitting `MediaPlayerAudioVolume`; `MapEventTests`
still covers the C event mapping and `PlayerTypedAccessorsTests` verifies the
live native volume setter reaches libVLC.

Upstream static-artifact comparison:

```bash
git worktree add --detach /private/tmp/SwiftVLC-upstream-v010 upstream/main
xcodebuild test -scheme SwiftVLC -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug -derivedDataPath /private/tmp/SwiftVLC-upstream-v010-tests -skipPackagePluginValidation -skipMacroValidation -collect-test-diagnostics never -only-testing:SwiftVLCTests/Integration/EventBridgeTests CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Result: upstream SwiftVLC `9065ad6` with its static `harflabs` v0.10.0
`libvlc.xcframework` reproduced the same iOS Simulator behavior:
`EventBridgeTests.Volume changed event` failed while waiting for
`volume changed event received`. The upstream artifact resolved to static
`libvlc.a` slices, including
`SourcePackages/artifacts/swiftvlc-upstream-v010/libvlc/libvlc.xcframework/ios-arm64_x86_64-simulator/libvlc.a`.
This confirms the fork's conditional skip documents a simulator/backend event
emission limitation, not a regression introduced by dynamic LGPL packaging.

## Release Dry Run

Command:

```bash
./scripts/release.sh 0.10.0 --dry-run
```

Result: dry run completed without pushing. The stripped zip was 112 MB. The
upload artifact was then rebuilt persistently and verified before upload:

```text
/private/tmp/SwiftVLC-release-v0.10.0.4bAhzz/libvlc.xcframework.zip
```

Final release asset checksum:

```text
b95c6c0978334ed0a24e08c4010b139e15f657add6c3e1c0ea72e209d0a708cf
```

Release URL:

```text
https://github.com/harukawu/SwiftVLC/releases/download/v0.10.0/libvlc.xcframework.zip
```

## Patch Release v0.10.1

The `v0.10.0` zip was later found to contain AppleDouble `._*` sidecar entries
introduced by the archive step, even though the local `Vendor/libvlc.xcframework`
tree did not contain them. This is packaging noise rather than a static-linking
or LGPL issue, but plugin-like sidecar filenames are confusing and should not be
published.

Release guardrails added for `v0.10.1`:

- `./scripts/verify-libvlc-xcframework.sh` now rejects AppleDouble sidecars in
  addition to `.a`, `.la`, doc/man payloads, GPL-sensitive names, assertion
  builds, wrong Mach-O types, bad install names, and build-path load commands.
- `./scripts/release.sh` now zips with
  `COPYFILE_DISABLE=1 ditto --norsrc --noextattr` and rejects zip entries
  matching AppleDouble sidecars, static archives, or libtool archives before
  computing the SwiftPM checksum.

Commands:

```bash
find Vendor/libvlc.xcframework \( -name '._*' -o -name '*.a' -o -name '*.la' \) -print | wc -l
./scripts/verify-libvlc-xcframework.sh Vendor/libvlc.xcframework
./scripts/release.sh 0.10.1 --dry-run
zipinfo -1 /private/tmp/SwiftVLC-release-v0.10.1.J6Foz8/libvlc.xcframework.zip | grep -E '(^|/)\._' || true
zipinfo -1 /private/tmp/SwiftVLC-release-v0.10.1.J6Foz8/libvlc.xcframework.zip | grep -E '(^|/)[^/]+\.(a|la)$' || true
swift package compute-checksum /private/tmp/SwiftVLC-release-v0.10.1.J6Foz8/libvlc.xcframework.zip
```

Results: the local artifact has zero AppleDouble, static archive, or libtool
archive entries; the stricter verifier passed; the dry run completed; the final
zip has no AppleDouble, `.a`, or `.la` entries.

Final release asset:

```text
/private/tmp/SwiftVLC-release-v0.10.1.J6Foz8/libvlc.xcframework.zip
```

Size:

```text
117,848,653 bytes
```

SwiftPM checksum:

```text
3cb62b70d3d20f0e17f70c8f78d08877be068dd1bb574413092ff13ba6c43bb1
```

Release URL:

```text
https://github.com/harukawu/SwiftVLC/releases/download/v0.10.1/libvlc.xcframework.zip
```

## Patch Release v0.10.2

A consumer iOS device build reported:

```text
libvlc.framework: code object is not signed at all
In subcomponent: libvlc.framework/libvlccore.dylib
```

Root cause: Xcode re-signs `libvlc.framework` when embedding it into an app, but
it does not sign loose nested dylibs/plugins first. The `v0.10.1` artifact
contained valid dynamic frameworks, but the embedded libVLC Mach-O files were
unsigned. `codesign` therefore rejected the framework bundle during the app's
device `CodeSign` phase.

Release guardrails added for `v0.10.2`:

- `./scripts/sign-libvlc-xcframework.sh` ad-hoc signs nested Mach-O files first,
  then signs each containing `libvlc.framework` slice.
- `./scripts/build-libvlc.sh` signs future local `Vendor/libvlc.xcframework`
  outputs before verification.
- `./scripts/release.sh` re-signs stripped release copies before verification
  and zipping.
- `./scripts/verify-libvlc-xcframework.sh` now runs
  `codesign --verify --deep --strict` on each framework slice.

Commands:

```bash
codesign -dv --verbose=4 Vendor/libvlc.xcframework/ios-arm64/libvlc.framework/libvlccore.dylib
./scripts/sign-libvlc-xcframework.sh Vendor/libvlc.xcframework
./scripts/verify-libvlc-xcframework.sh Vendor/libvlc.xcframework
./scripts/release.sh 0.10.2 --dry-run
zipinfo -1 /private/tmp/SwiftVLC-release-v0.10.2.U3PkRu/libvlc.xcframework.zip | grep -E '(^|/)\._' || true
zipinfo -1 /private/tmp/SwiftVLC-release-v0.10.2.U3PkRu/libvlc.xcframework.zip | grep -E '(^|/)[^/]+\.(a|la)$' || true
swift package compute-checksum /private/tmp/SwiftVLC-release-v0.10.2.U3PkRu/libvlc.xcframework.zip
ditto -x -k /private/tmp/SwiftVLC-release-v0.10.2.U3PkRu/libvlc.xcframework.zip /private/tmp/SwiftVLC-v0102-sign-verify.wv7oVV
codesign --force --sign - --timestamp=none --preserve-metadata=identifier,entitlements,flags --generate-entitlement-der /private/tmp/SwiftVLC-v0102-sign-verify.wv7oVV/libvlc.xcframework/ios-arm64/libvlc.framework
codesign --verify --deep --strict --verbose=2 /private/tmp/SwiftVLC-v0102-sign-verify.wv7oVV/libvlc.xcframework/ios-arm64/libvlc.framework
```

Results: the local artifact and stripped release copy pass deep strict code
signature verification for both iOS framework slices. An extracted copy of the
final upload zip also accepts the same Xcode-style framework signing command that
consumer app builds use. The release zip still has no AppleDouble, `.a`, or
`.la` entries.

Final release asset:

```text
/private/tmp/SwiftVLC-release-v0.10.2.U3PkRu/libvlc.xcframework.zip
```

Size:

```text
119,232,982 bytes
```

SwiftPM checksum:

```text
0e97d0699b56566ea7ace44cc303e5c10da4eb84c1684181fd113e9bb8588719
```

Release URL:

```text
https://github.com/harukawu/SwiftVLC/releases/download/v0.10.2/libvlc.xcframework.zip
```

## Patch Release v0.10.3

After updating a consumer test app to `v0.10.2`, the app compiled and signed but
failed to install on a physical iPhone:

```text
Info.plist from bundle at path .../testVLC.app/Frameworks/libvlc.framework had none of the keys that we expect
```

Root cause: `libvlc.framework` is an iOS-style shallow framework with its
canonical `Info.plist` at the framework root, but it also carries VLC runtime
data under a top-level `Resources/` directory. With that directory present,
`codesign` uses the deep-framework plist location. Because
`Resources/Info.plist` was missing, the framework signature reported
`Info.plist=not bound`, and the iOS installer could not validate the framework
bundle metadata. Once the plist was mirrored into `Resources/Info.plist`, the
installer moved to the next validation error until the framework signing
identifier was also made to match `CFBundleIdentifier` (`org.videolan.libvlc`).

Release guardrails added for `v0.10.3`:

- `./scripts/build-libvlc.sh` mirrors the root framework plist to
  `Resources/Info.plist` whenever VLC runtime resources create that directory.
- `./scripts/sign-libvlc-xcframework.sh` performs the same mirror repair for
  existing artifacts, signs nested Mach-O files, then signs `libvlc.framework`
  with the framework `CFBundleIdentifier`.
- `./scripts/verify-libvlc-xcframework.sh` now rejects artifacts whose framework
  signing identifier does not match `CFBundleIdentifier`, whose code signature
  does not bind plist entries, or whose `Resources/Info.plist` does not mirror
  the root plist.

Commands:

```bash
./scripts/sign-libvlc-xcframework.sh Vendor/libvlc.xcframework
codesign -dv --verbose=4 Vendor/libvlc.xcframework/ios-arm64/libvlc.framework
./scripts/verify-libvlc-xcframework.sh Vendor/libvlc.xcframework
./scripts/release.sh 0.10.3 --dry-run
swift package compute-checksum /private/tmp/SwiftVLC-release-v0.10.3.c7lOIX/libvlc.xcframework.zip
ditto -x -k /private/tmp/SwiftVLC-release-v0.10.3.c7lOIX/libvlc.xcframework.zip /private/tmp/SwiftVLC-v0103-zip-verify.14r0C9
./scripts/verify-libvlc-xcframework.sh /private/tmp/SwiftVLC-v0103-zip-verify.14r0C9/libvlc.xcframework
xcrun devicectl device install app --device 00008150-0016659C0C2B401C /private/tmp/testVLC-v0103-zip-sim.app
```

Results: both iOS framework slices pass deep strict code-signature verification,
report `Identifier=org.videolan.libvlc`, and report `Info.plist entries=10`.
An app copy using the extracted final `v0.10.3` zip installed successfully on
the connected iPhone. The release zip still has no AppleDouble, `.a`, or `.la`
entries.

Final release asset:

```text
/private/tmp/SwiftVLC-release-v0.10.3.c7lOIX/libvlc.xcframework.zip
```

Size:

```text
119,234,380 bytes
```

SwiftPM checksum:

```text
450f4a8c91a5a8f8530d11ee83365166c68e7d6dcc9cd2c00a42ed19e2ae4ccb
```

Release URL:

```text
https://github.com/harukawu/SwiftVLC/releases/download/v0.10.3/libvlc.xcframework.zip
```

## Patch Release v0.10.4

After `v0.10.3`, the consumer test app compiled and installed on a physical
iPhone but crashed at launch:

```text
Library not loaded: @loader_path/libvlccore.dylib
Reason: ... libvlc.framework/libvlccore.dylib (code signature invalid)
```

Root cause: the release artifact can carry ad-hoc signatures for nested VLC
dylibs, which is enough for Xcode's framework signing and iOS package
inspection. At runtime on a physical device, dyld requires loadable nested code
inside the app bundle to be signed by the consuming app's signing identity.
Xcode re-signs `libvlc.framework` itself but does not re-sign loose nested
dylibs/plugins inside that framework.

Release guardrails and integration added for `v0.10.4`:

- `./scripts/sign-libvlc-embedded-framework.sh` is intended for consuming iOS
  app targets as a Run Script build phase after SwiftPM embeds package
  frameworks.
- The script signs `libvlccore.dylib` and VLC plugin dylibs with
  `EXPANDED_CODE_SIGN_IDENTITY`, mirrors `Resources/Info.plist`, re-signs
  `libvlc.framework` with `org.videolan.libvlc`, and verifies the result.
- README and DocC now document the required Run Script phase. The binary
  artifact remains LGPL-oriented, iOS-only, dynamic, and generated outside Git.

Commands:

```bash
TARGET_BUILD_DIR=/private/tmp \
FRAMEWORKS_FOLDER_PATH=testVLC-v0104-script.app/Frameworks \
EXPANDED_CODE_SIGN_IDENTITY=D8CB58D8A6C0B3D33C6C8785F1901CCA09B479FA \
CODE_SIGNING_ALLOWED=YES \
PLATFORM_NAME=iphoneos \
scripts/sign-libvlc-embedded-framework.sh

xcrun devicectl device install app --device 00008150-0016659C0C2B401C /private/tmp/testVLC-v0104-script.app
xcrun devicectl device process launch --device 00008150-0016659C0C2B401C --terminate-existing --console --timeout 8 com.haruka.testVLC
./scripts/release.sh 0.10.4 --dry-run
swift package compute-checksum /private/tmp/SwiftVLC-release-v0.10.4.AGj70d/libvlc.xcframework.zip
```

Results: the script signed 344 nested Mach-O files in `libvlc.framework` with
the app's Apple Development identity. The script-signed app installed on the
connected iPhone and launched without the immediate dyld
`libvlccore.dylib` signature crash; `devicectl` timed out after 8 seconds
because the app remained running. The release zip still has no AppleDouble,
`.a`, or `.la` entries.

Final release asset:

```text
/private/tmp/SwiftVLC-release-v0.10.4.AGj70d/libvlc.xcframework.zip
```

Size:

```text
119,234,380 bytes
```

SwiftPM checksum:

```text
8e464b850fcce2c3175e3839985fbfadb24f54ae1ca0ea47bf4376121e175f3c
```

Release URL:

```text
https://github.com/harukawu/SwiftVLC/releases/download/v0.10.4/libvlc.xcframework.zip
```

### Consumer Clean-Build Signing Follow-Up

After `v0.10.4`, a local-package consumer app exposed an additional Xcode
ordering issue. A clean app build can run user script phases before
`libvlc.framework` exists under `testVLC.app/Frameworks`, and Xcode can later
embed the binary target from `SourcePackages/artifacts` rather than from the
already processed `TARGET_BUILD_DIR/libvlc.framework`.

Mitigation:

- `./scripts/sign-libvlc-embedded-framework.sh` now signs every relevant
  DerivedData copy it can find: SwiftPM's `SourcePackages/artifacts`
  xcframework slice, the `TARGET_BUILD_DIR` framework, and the embedded app
  framework when present.
- README and DocC document local package use via `SWIFTVLC_SCRIPT` and include
  a clear failure path when the helper script cannot be found.

Commands:

```bash
bash -n scripts/sign-libvlc-embedded-framework.sh

xcodebuild -quiet \
  -project /Users/haruka/Developer/Xcode/Test/testVLC/testVLC.xcodeproj \
  -scheme testVLC \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /private/tmp/testVLC-local-dd-clean3 \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  clean build

codesign -dv --verbose=4 \
  /private/tmp/testVLC-local-dd-clean3/Build/Products/Debug-iphoneos/testVLC.app/Frameworks/libvlc.framework/libvlccore.dylib

xcrun devicectl device install app \
  --device 00008150-0016659C0C2B401C \
  /private/tmp/testVLC-local-dd-clean3/Build/Products/Debug-iphoneos/testVLC.app

xcrun devicectl device process launch \
  --device 00008150-0016659C0C2B401C \
  --terminate-existing \
  --console \
  --timeout 8 \
  com.haruka.testVLC
```

Result: the clean build passed, the final app copy of
`libvlc.framework/libvlccore.dylib` was signed with TeamIdentifier
`CP95PW5V2S`, the app installed on the connected iPhone, and launch stayed alive
until the `devicectl` console timeout instead of failing in dyld.

## Notes

- `Vendor/libvlc.xcframework` remains a local/release artifact and is not
  committed.
- The verifier now fails if future packaging reintroduces AppleDouble sidecars,
  `.a`, `.la`, `Resources/share/doc`, `Resources/share/man`, obvious
  GPL-sensitive component filenames, unsigned nested code, unbound framework
  plist entries, or mismatched framework signing identifiers.
- Physical iOS app targets must run
  `./scripts/sign-libvlc-embedded-framework.sh` during their own build so dyld
  accepts nested libVLC dylibs/plugins at runtime.
- `Package.swift` is pinned to the fork `v0.10.4` release asset and checksum
  above; the binary artifact remains ignored locally and is shipped only as a
  GitHub Release asset.
