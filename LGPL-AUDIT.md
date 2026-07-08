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

## Notes

- `Vendor/libvlc.xcframework` remains a local/release artifact and is not
  committed.
- The verifier now fails if future packaging reintroduces AppleDouble sidecars,
  `.a`, `.la`, `Resources/share/doc`, `Resources/share/man`, or obvious
  GPL-sensitive component filenames.
- `Package.swift` is pinned to the fork `v0.10.2` release asset and checksum
  above; the binary artifact remains ignored locally and is shipped only as a
  GitHub Release asset.
