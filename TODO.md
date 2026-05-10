# TODO.md

This plan is split into small, single-purpose tasks. Implementation is blocked
until `AGENTS.md` has been reviewed and approved by the repo owner.

## Status Key

- `[ ]` Not started
- `[~]` In progress
- `[x]` Complete
- `[!]` Blocked or needs owner input

## Tasks

- `[x]` T00 - Planning gate
  - Create the rebuild branch.
  - Read the README and relevant build/release/setup scripts.
  - Add `AGENTS.md` and this task plan.
  - Stop for repo-owner review before build implementation.
  - Owner review completed. Keep non-iOS platform declarations in
    `Package.swift`, and keep rebuilt framework artifacts as local/release
    assets rather than committed binaries.

- `[x]` T01 - Baseline artifact and script audit
  - Record the current package platforms, binary target shape, generated
    artifact layout, and static archive assumptions.
  - Inspect the pinned VLC Apple build script for dynamic-library and
    LGPL/GPL-related options.
  - Update this TODO with the exact implementation decisions before editing.
  - Audit result:
    - `Package.swift` currently declares iOS, macOS, tvOS, visionOS, and Mac
      Catalyst platforms and a single remote `libvlc` binary target. Per owner
      decision, keep these platform declarations unchanged.
    - `Vendor/` is absent in this checkout, ignored by Git, and has no tracked
      files. Rebuilt frameworks remain local/release artifacts only.
    - `scripts/build-libvlc.sh` currently packages
      `static-lib/libvlc-full-static.a` into `libvlc.a` slices and creates the
      xcframework with `-library ... -headers ...`; release/setup scripts also
      contain static-archive assumptions.
    - The pinned VLC Apple build script at `c833c4be0` explicitly documents its
      default full-static mode, but already supports `--enable-shared`. In that
      mode it adds `--enable-shared`, skips `--disable-shared --enable-static`,
      runs `make install`, then exits before the static module-list and
      `libvlc-full-static.a` steps.
    - The pinned VLC Apple `build.conf` already passes `--disable-gpl` and
      `--disable-gnuv3` to contrib bootstrap. This rebuild should preserve those
      options, make the LGPL intent explicit in our wrapper script, and add
      guardrails/scans rather than relying on implicit upstream defaults.
  - Implementation decisions:
    - `scripts/build-libvlc.sh` will become an iOS-only builder: default and
      `--ios-only` remain valid, while non-iOS platform flags should fail with a
      clear message.
    - The build will invoke VLC's Apple script with `--enable-shared` for
      iphoneos arm64 and iphonesimulator arm64/x86_64.
    - Static archive collection, duplicate-symbol archive repair, `.a`
      deployment-target scanning, and release stripping of `.a` files will be
      replaced with dynamic-framework packaging and verification.
    - The final local output remains `Vendor/libvlc.xcframework`, but it should
      contain iOS framework slices, not static libraries.

- `[ ]` T02 - Narrow the package and scripts to iOS
  - Remove or disable non-iOS platform selection in `scripts/build-libvlc.sh`.
  - Update release/setup assumptions so they expect iOS device and simulator
    slices only.
  - Decide whether `Package.swift` should drop non-iOS platform declarations or
    merely stop publishing non-iOS binary slices, then apply the approved choice.

- `[ ]` T03 - Make the libVLC build explicitly LGPL-oriented
  - Add explicit build configuration for LGPL mode if supported by VLC's build
    system.
  - Disable or exclude GPL-only modules and contribs discovered during T01.
  - Add guardrails so accidental GPL-enabling options fail the build visibly.

- `[ ]` T04 - Build iOS dynamic framework slices
  - Replace static archive collection with dynamic framework assembly for iOS
    device and simulator.
  - Preserve headers/module-map behavior required by the `CLibVLC` target.
  - Produce `Vendor/libvlc.xcframework` from framework slices.

- `[ ]` T05 - Update Swift package integration
  - Point the local binary target at the rebuilt framework xcframework.
  - Adjust linker settings if dynamic frameworks remove or change explicit
    system framework/library requirements.
  - Confirm downstream iOS apps can embed the dynamic libVLC framework.

- `[ ]` T06 - Add dynamic-linkage validation
  - Add script-level checks that fail if `.a` files are produced or packaged.
  - Verify Mach-O load commands or file types show dynamic framework binaries.
  - Add a focused test if Swift-side runtime behavior needs coverage.

- `[ ]` T07 - Run and adapt the Swift Testing suite
  - Run the existing SwiftVLC tests against the rebuilt artifact.
  - If `swift test` is no longer the correct iOS-only command, document and use
    the reproducible iOS simulator test command.
  - Add tests only where dynamic packaging creates uncovered behavior.

- `[ ]` T08 - Update README for this fork
  - Explain that this fork is iOS-only and rebuilds libVLC as dynamic frameworks.
  - Document prerequisites, build commands, expected output layout, and test
    commands.
  - State SwiftVLC's license, libVLC's LGPL license, VideoLAN attribution, and
    the GPL-removal intent clearly.

- `[ ]` T09 - Final GPL and packaging scan
  - Scan scripts and patched VLC source configuration for GPL-enabling options.
  - Scan final artifact metadata and filenames for GPL-only components where
    practical.
  - Record the scan commands and results.

- `[ ]` T10 - Final verification summary
  - Confirm branch status and commit history are clean and task-sized.
  - Summarize artifact shape, test results, GPL scan result, and known residual
    risks.

## Owner Decisions

- Keep existing non-iOS platform declarations in `Package.swift`; this fork's
  rebuild/release artifact will be iOS-only.
- Do not commit generated framework artifacts. Keep them as local build outputs
  and release assets, matching the upstream repo's pattern.
