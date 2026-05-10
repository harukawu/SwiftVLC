# AGENTS.md

This file records the working rules for the iOS-only SwiftVLC rebuild. It is
intended to be reviewed before implementation starts.

## Review Gate

- Do not change build logic, package manifests, Swift source, tests, release
  scripts, or README content beyond the initial planning documents until the
  repo owner has reviewed and approved this file.
- Treat `AGENTS.md` as the source of truth for process decisions during this
  rebuild. If a later task needs to violate it, stop and ask first.

## Core Principles

- Keep the rebuild iOS-only. Do not spend implementation effort preserving,
  rebuilding, or releasing macOS, tvOS, visionOS, or Mac Catalyst support unless
  that work is required to remove an obsolete reference cleanly.
- Make LGPL compliance the central technical constraint. The iOS libVLC product
  must be dynamically linked in framework form, and the build must avoid GPL-only
  VLC code paths, modules, and contribs.
- Prefer explicit build configuration over implicit defaults. Any LGPL/GPL
  switch, disabled dependency, selected platform, pinned commit, or packaging
  assumption should be visible in scripts and documented in the README.
- Preserve the public Swift API unless a change is necessary for dynamic
  framework loading, iOS-only packaging, or test reliability.
- Keep changes small and reviewable. Each task should be a single coherent unit,
  and `TODO.md` must be updated in the same commit as the task's code or docs.
- Verify artifacts, not just scripts. Final checks must inspect the produced
  xcframework/framework contents, linkage type, platform slices, symbols or
  load commands where useful, and the absence of static `.a` products.
- Run the Swift Testing suite against the rebuilt artifact. If the test command
  changes because the package becomes iOS-only, document the exact replacement
  command and make it reproducible.
- Run a GPL-focused source and artifact scan before declaring the rebuild done.
  Record the command, scope, and result in the final work log or TODO update.
- Keep generated binaries out of commits unless the repo owner explicitly asks
  for a checked-in artifact. Scripts and documentation should make the framework
  reproducible from source.
- Do not use destructive Git commands or reset user changes. Work with the
  current branch state and stop if unrelated changes block the requested work.

## Commit Discipline

- Work happens on the dedicated branch for this rebuild.
- After finishing each task, update `TODO.md` to mark the task complete and
  summarize the verification performed.
- Commit the task's implementation and its `TODO.md` update together.
- Use focused commit messages that name the task, for example:
  `Build iOS dynamic libVLC framework`.

## Verification Baseline

The final rebuild should, at minimum, prove:

- `Vendor/libvlc.xcframework` contains iOS device and iOS simulator framework
  slices only.
- The slices contain dynamic framework binaries, not static archives.
- Package resolution and iOS test execution use the rebuilt local artifact.
- SwiftVLC tests pass against the rebuilt artifact.
- The README documents source rebuild steps, license/copyright attribution,
  LGPL dynamic-linking intent, disabled GPL components, and reproduction steps.
- A GPL scan has been run over the relevant build scripts, patched VLC source,
  generated metadata, and final framework artifact.
