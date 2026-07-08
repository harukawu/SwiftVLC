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

- `[x]` T02 - Narrow the package and scripts to iOS
  - Remove or disable non-iOS platform selection in `scripts/build-libvlc.sh`.
  - Update release/setup assumptions so they expect iOS device and simulator
    slices only.
  - Decide whether `Package.swift` should drop non-iOS platform declarations or
    merely stop publishing non-iOS binary slices, then apply the approved choice.
  - Completed:
    - `scripts/build-libvlc.sh` now documents iOS as its only rebuild target and
      rejects `--all`, tvOS, visionOS, macOS, and Catalyst build flags with a
      clear error.
    - `scripts/release.sh` now expects only `ios-arm64` and
      `ios-arm64_x86_64-simulator` slices and describes the release artifact as
      iOS-only.
    - `scripts/setup-dev.sh` has no platform-slice whitelist; its remaining
      static-archive cleanup path is tracked for the dynamic packaging work.
    - `Package.swift` platform declarations were left unchanged per owner
      decision.
    - `scripts/build-libvlc.sh --help` and unsupported platform flags now reach
      argument handling even when CPU-count probing is restricted.

- `[x]` T03 - Make the libVLC build explicitly LGPL-oriented
  - Add explicit build configuration for LGPL mode if supported by VLC's build
    system.
  - Disable or exclude GPL-only modules and contribs discovered during T01.
  - Add guardrails so accidental GPL-enabling options fail the build visibly.
  - Completed:
    - Added an idempotent VLC `build.conf` patch that ensures the base contrib
      options contain `--disable-gpl`, `--disable-gnuv3`, and explicit disables
      for common GPL-only or GPL-sensitive contribs such as dvdcss/dvdread,
      x264/x265, faad, dca, mpeg2, and postproc.
    - Added a verifier that fails the build if those required options are
      missing from `VLC_CONTRIB_OPTIONS_BASE` or if prohibited GPL-oriented
      `--enable-*` options appear in the VLC Apple build config.
    - Verified `scripts/build-libvlc.sh` syntax and help output after adding the
      guardrails.

- `[x]` T04 - Build iOS dynamic framework slices
  - Replace static archive collection with dynamic framework assembly for iOS
    device and simulator.
  - Preserve headers/module-map behavior required by the `CLibVLC` target.
  - Produce `Vendor/libvlc.xcframework` from framework slices.
  - Completed:
    - `scripts/build-libvlc.sh` now invokes VLC's Apple build with
      `--enable-shared` for iphoneos arm64 and iphonesimulator arm64/x86_64.
    - Static `.a` packaging was replaced with staging of
      `libvlc.framework` slices, simulator lipo merging for matching Mach-O
      files, and preservation of architecture-specific simulator plugins.
    - Framework staging copies VLC headers, removes `module.modulemap` and
      `CLibVLC.h` from the binary framework headers, strips libtool `.la`
      metadata, and rewrites local install names with `@rpath`/`@loader_path`.
    - The generated local artifact is
      `Vendor/libvlc.xcframework` with `ios-arm64` and
      `ios-arm64_x86_64-simulator` dynamic framework slices.
    - Verified `bash -n scripts/build-libvlc.sh`,
      `./scripts/build-libvlc.sh --ios-only`, no packaged `.a` or `.la`
      files, dynamic Mach-O file types, corrected plugin/core install names,
      and iOS deployment target `minos=18.0`.

- `[x]` T05 - Update Swift package integration
  - Point the local binary target at the rebuilt framework xcframework.
  - Adjust linker settings if dynamic frameworks remove or change explicit
    system framework/library requirements.
  - Confirm downstream iOS apps can embed the dynamic libVLC framework.
  - Completed:
    - Kept `Package.swift` in release `url + checksum` form per the
      local/release-asset workflow; `scripts/setup-dev.sh --skip-download`
      remains the local switch to `Vendor/libvlc.xcframework`.
    - Updated `setup-dev.sh` to validate the local iOS dynamic framework
      slices and reject packaged `.a` or `.la` files instead of running the
      obsolete static duplicate-symbol repair.
    - Added CLibVLC runtime helpers that locate
      `libvlc.framework/plugins` via `dladdr()` and append it to
      `VLC_PLUGIN_PATH` before `libvlc_new()` scans dynamic modules.
    - `VLCInstance` now prepares the bundled plugin path before creating an
      instance, including for custom argument lists that do not use
      `defaultArguments`.
    - Verified `bash -n scripts/setup-dev.sh` and `shim.c` syntax against the
      iphoneos and iphonesimulator SDKs. Full simulator build/test coverage is
      tracked in T07.

- `[x]` T06 - Add dynamic-linkage validation
  - Add script-level checks that fail if `.a` files are produced or packaged.
  - Verify Mach-O load commands or file types show dynamic framework binaries.
  - Add a focused test if Swift-side runtime behavior needs coverage.
  - Completed:
    - Added `scripts/verify-libvlc-xcframework.sh` for reusable validation of
      iOS dynamic framework slices, required architectures, install names,
      bundled plugin directories, header shape, absence of `.a`/`.la` files,
      and absence of build-directory Mach-O load paths.
    - Wired the verifier into `scripts/build-libvlc.sh`,
      `scripts/setup-dev.sh`, and `scripts/release.sh`.
    - Updated release stripping to operate on Mach-O files in the dynamic
      framework copy instead of static `.a` archives, then re-run validation.
    - Added an iOS-only Swift Testing check that the bundled dynamic plugin
      path is discoverable from the loaded `libvlc.framework`.
    - Verified `./scripts/verify-libvlc-xcframework.sh
      Vendor/libvlc.xcframework`, script syntax, and
      `./scripts/release.sh 0.0.0 --dry-run` (zip size 115 MB, checksum
      `82185963ed07dfb1261b04949d501282e0b60f13976a134d4743f7ddf20a130e`).

- `[x]` T07 - Run and adapt the Swift Testing suite
  - Run the existing SwiftVLC tests against the rebuilt artifact.
  - If `swift test` is no longer the correct iOS-only command, document and use
    the reproducible iOS simulator test command.
  - Add tests only where dynamic packaging creates uncovered behavior.
  - Completed:
    - Used a temporary local package pointing at the ignored
      `Vendor/libvlc.xcframework` and ran the iOS simulator suite with
      `xcodebuild -scheme SwiftVLC -destination 'platform=iOS Simulator,id=456344A1-4FFE-47AB-9B0E-DF4B1EB56C7E' -derivedDataPath /private/tmp/SwiftVLC-T07.REIsk2/DerivedData-patched-race-sync -skipPackagePluginValidation -skipMacroValidation test`.
    - Full result: 1,362 tests in 109 suites passed after 176.049 seconds;
      `xcodebuild` reported `** TEST SUCCEEDED **`.
    - Added iOS-only coverage that the dynamic bundled plugin path is
      discoverable and that stale `.build-libvlc` plugin paths are sanitized
      out of `VLC_PLUGIN_PATH`; `VLC_LIB_PATH` now points at the bundled
      `libvlc.framework/plugins` directory.
    - Stabilized real-audio pause/stop teardown by deferring native pause until
      libVLC timing is ready, while allowing `--no-audio` test instances to
      keep issuing early native pauses.
    - Added an iOS compile guard for the AppKit-only PiP probe view and a drain
      in the audio-output race test so deferred releases finish before the next
      real-audio coverage.
    - Patched VLC's iOS sample-buffer display setup during the libVLC build so
      setup completes on the main queue before vout teardown can free the
      display object; focused `VideoSurfaceRaceTests` and the full suite both
      passed with the rebuilt framework.

- `[x]` T08 - Update README for this fork
  - Explain that this fork is iOS-only and rebuilds libVLC as dynamic frameworks.
  - Document prerequisites, build commands, expected output layout, and test
    commands.
  - State SwiftVLC's license, libVLC's LGPL license, VideoLAN attribution, and
    the GPL-removal intent clearly.
  - Completed:
    - README now calls out this fork's iOS-only dynamic framework artifact,
      LGPL-oriented GPL/GNUv3 guardrails, local/release asset workflow, expected
      `Vendor/libvlc.xcframework` layout, simulator test command, and release
      process.
    - License section now separates SwiftVLC's MIT-licensed wrapper code from
      VideoLAN/libVLC licensing and points readers to VLC notices plus the final
      GPL scan before app publication.
    - `setup-dev.sh` and `release.sh` now default GitHub release operations to
      `harukawu/SwiftVLC`, with `SWIFTVLC_GITHUB_REPO=owner/repo` available as
      an override.

- `[x]` T09 - Final GPL and packaging scan
  - Scan scripts and patched VLC source configuration for GPL-enabling options.
  - Scan final artifact metadata and filenames for GPL-only components where
    practical.
  - Record the scan commands and results.
  - Completed:
    - Added packaging exclusions and verifier checks so
      `Resources/share/doc`, `Resources/share/man`, static archives, libtool
      archives, and obvious GPL-sensitive component filenames fail validation.
    - Rebuilt the ignored local `Vendor/libvlc.xcframework`; the stricter
      verifier passed for both iOS slices and deployment target minos remained
      18.0.
    - Final scan found no prohibited GPL/GNUv3 or GPL-sensitive `--enable-*`
      options, confirmed required disable options, and found no suspicious
      packaged filenames.
    - `./scripts/release.sh 0.0.0 --dry-run` passed; stripped release zip was
      115 MB with checksum
      `2b0d634e2d673053a5eb86f9b0a98ba07a545f68ed9d5881a861837bd7a89924`.
    - Detailed commands and results are recorded in `LGPL-AUDIT.md`.

- `[x]` T10 - Final verification summary
  - Confirm branch status and commit history are clean and task-sized.
  - Summarize artifact shape, test results, GPL scan result, and known residual
    risks.
  - Completed:
    - Branch: `codex-ios-dynamic-lgpl-rebuild`.
    - Commit stack is task-sized from T00 through T09, with the latest completed
      commit `3931f31 Record LGPL rebuild audit`; tracked worktree was clean
      before this final TODO update.
    - Local rebuilt artifact remains ignored at `Vendor/libvlc.xcframework`
      and is 336 MB with two slices:
      `ios-arm64` and `ios-arm64_x86_64-simulator`.
    - Latest rebuild completed in 4m22s, the stricter dynamic framework
      verifier passed, and both iOS slices reported deployment target
      `minos=18.0`.
    - Swift Testing coverage against the rebuilt dynamic framework passed:
      1,362 tests in 109 suites after 176.049 seconds via iOS simulator
      `xcodebuild`.
    - GPL/package scan is recorded in `LGPL-AUDIT.md`; no prohibited enable
      options, static/libtool archives, doc/man resources, or obvious
      GPL-sensitive component filenames were found in the final local artifact.
    - Residual risks:
      - This is an engineering scan, not legal advice; app publication should
        still review VideoLAN/libVLC notices and obligations.
      - `Package.swift` intentionally remains in release URL/checksum form; it
        will point at this fork's rebuilt binary only after running
        `release.sh` for a real fork release.
      - Non-iOS platform declarations remain in `Package.swift` per owner
        decision, but this fork's rebuilt/release artifact is iOS-only.

- `[x]` T11 - Add AI-generated branch notice
  - Add a clear README notice that this branch was generated by OpenAI Codex and
    that stability is not guaranteed.
  - Credit OpenAI Codex (GPT-5.5, xhigh) in the project documentation.
  - Completed:
    - README now includes an AI-generated branch notice near the top of the
      document.
    - README credits OpenAI Codex (GPT-5.5, xhigh) in the acknowledgements.
    - Verification: reviewed README rendering context and confirmed the tracked
      worktree was clean before this TODO update.

- `[x]` T12 - Publish v0.9.0 binary release
  - Package the rebuilt dynamic iOS `libvlc.xcframework` into a stripped release
    zip and compute the SwiftPM checksum.
  - Point `Package.swift` at the fork release asset and update user-facing
    package instructions to the published fork URL/version.
  - Tag `v0.9.0`, push the rebuild branch and tag, and upload the zip as a
    GitHub Release asset.
  - Completed:
    - Packaged a stripped release zip at
      `/private/tmp/SwiftVLC-release-v0.9.0.lVuQTK/libvlc.xcframework.zip`.
    - `./scripts/verify-libvlc-xcframework.sh` passed for both the source
      `Vendor/libvlc.xcframework` and the stripped release copy.
    - Zip size is 115 MB; SwiftPM checksum is
      `36aa38af07a9576fb2890a5fe50a417dac9e13ff5a3f97f85cd2973cc38c528a`.
    - `Package.swift` now points at the fork's `v0.9.0` GitHub Release asset,
      and package instructions now use `https://github.com/harukawu/SwiftVLC.git`
      with version `0.9.0`.
    - `swift package dump-package` passed and reported the updated binary
      target URL and checksum.

- `[x]` T13 - Merge upstream v0.10.0 source delta
  - Merge upstream `0c86d84...9065ad6` onto `codex-ios-dynamic-lgpl-rebuild`
    using `0c86d84` as the merge base, not the local fork-specific `v0.9.0`
    tag.
  - Preserve LGPL/iOS dynamic fork behavior while adopting upstream lifecycle,
    seek, PiP, event-stream, `VLCInstance` identity, Chromecast showcase, tests,
    fixtures, and documentation changes where compatible.
  - Completed:
    - Fetched upstream `main` into `refs/remotes/upstream/main` with
      `--no-tags`; verified merge base `0c86d849f31ca96e927d15be08966d846355a261`
      and upstream target `9065ad6338ddd2d689bf6220b45e90ab4695b3a8`.
    - Resolved conflicts in `Package.swift`, `VLCInstance`, player event tests,
      `build-libvlc.sh`, and `release.sh`, keeping the fork release URL until
      the v0.10.0 artifact checksum is known.
    - Kept `swiftvlc_prepare_bundled_plugins()` before `libvlc_new()` while
      adopting upstream application-name and HTTP user-agent parameters.
    - Reapplied the fork's native pause/teardown guard in the new upstream
      `Player+Teardown` layout and kept the audio-output pause gating tests.
    - Kept dynamic iOS packaging, `--enable-shared`, verifier guardrails,
      generated-binary policy, fork README notice, and branch-based release
      flow; intentionally did not import upstream static vendor-manifest
      workflow or manifest files.
    - Adapted the new DynamicHost fixture and CI workflows to iOS-only dynamic
      framework validation.
  - Verification:
    - `bash -n scripts/*.sh`
    - `bash -n Fixtures/DynamicHost/verify.sh`
    - `./scripts/build-libvlc.sh --help`
    - `./scripts/build-libvlc.sh --all` rejected non-iOS builds as expected.
    - `swift package dump-package`
    - `plutil -lint Fixtures/DynamicHost/DynamicHost.xcodeproj/project.pbxproj Showcase/SwiftVLCShowcase.xcodeproj/project.pbxproj`
    - YAML parse check for edited workflow files.
    - `xcodebuild -list -project Fixtures/DynamicHost/DynamicHost.xcodeproj`
      resolved the package graph and listed `DynamicHost-iOS` as the only host
      target.

- `[ ]` T14 - Publish v0.10.0 binary release
  - Rebuild the ignored dynamic iOS `Vendor/libvlc.xcframework` from the merged
    scripts with `./scripts/build-libvlc.sh --ios-only`.
  - Verify artifact shape, linkage, install names, deployment targets, absence
    of `.a`/`.la` and non-runtime docs/man payloads, and absence of
    GPL-sensitive filenames.
  - Run the iOS simulator Swift Testing suite against the rebuilt local
    artifact and focused merged-area coverage.
  - Run GPL-focused source/config/artifact scans and update `LGPL-AUDIT.md`
    with commands and results.
  - Run `./scripts/release.sh 0.10.0 --dry-run`, update `Package.swift`,
    README/DocC release references, and the Showcase package pin with the final
    checksum, then tag `v0.10.0`, push the rebuild branch/tag, and upload the
    release asset.

## Owner Decisions

- Keep existing non-iOS platform declarations in `Package.swift`; this fork's
  rebuild/release artifact will be iOS-only.
- Do not commit generated framework artifacts. Keep them as local build outputs
  and release assets, matching the upstream repo's pattern.
