# Integration topology

How to consume SwiftVLC from a layered, multi-module iOS app without
duplicating the libVLC runtime.

## One libVLC per process

This fork ships `libvlc` as a dynamic iOS framework. A process should
load exactly one `libvlc.framework/libvlc` image: the libVLC core,
plugins, and Objective-C support classes are process-global, and multiple
copies can still produce undefined behavior rather than just wasted size:

- The Objective-C runtime sees every libVLC class twice and picks one
  arbitrarily (`Class X is implemented in both …` at launch).
- Each copy registers its own plugin registry and global state, so
  callbacks can cross between the two half-initialized runtimes.

The libVLC dynamic framework must therefore exist **exactly once** among
the images a process loads.

## The supported layered topology

SwiftVLC's library product is *automatic*-type. A single iOS app target
that depends on SwiftVLC directly links the Swift wrapper normally and
embeds the dynamic `libvlc.framework` once. Keep doing that for simple
apps; there is nothing extra to configure.

The rule only bites when SwiftVLC sits below several modules. The
supported shape is:

1. **One dynamic intermediary framework** (yours), in **its own
   package**, declares the SwiftVLC package dependency and re-exports
   whatever surface the rest of the app needs. libVLC remains a separate
   dynamic framework dependency rather than being folded into this
   wrapper.
2. **Static feature libraries**, in a separate package, depend on that
   framework's dynamic *product* — never on the SwiftVLC package. They
   may use SwiftVLC types freely through the intermediary's
   `@_exported import SwiftVLC`.
3. **The app** links the feature libraries plus the dynamic framework.
   It must not declare its own SwiftVLC package dependency either.

```
App ──▶ FeatureA (static) ─┐
    ──▶ FeatureB (static) ─┼──▶ MediaCore (dynamic) ──▶ SwiftVLC ──▶ libvlc
    ──▶ MediaCore ─────────┘
```

If feature libraries or the app add their own SwiftVLC dependency, Xcode
may add duplicate Swift wrapper or binary-framework linkage paths. Keep a
single ownership path to preserve the one-libVLC-image guarantee.

The wrapper's own package matters: the static feature targets and the
dynamic wrapper **cannot live in the same package**. Inside one
package, feature targets can only depend on the wrapper *target*, which
Xcode then needs both statically (for the features) and dynamically
(for the product) — that either fails outright ("linked as a static
library … but cannot be built dynamically because there is a package
product with the same name") or, with a differently named product,
produces an empty stub framework the app cannot link. A cross-package
dependency on the dynamic *product* links it dynamically, which is the
whole point.

## The executable proof

`Fixtures/DynamicHost` in the repository is this exact topology, kept
buildable as a regression fixture: a `MediaCoreKit` package whose
dynamic `MediaCore` product owns the SwiftVLC dependency, a `MediaKit`
package with static `FeatureA`/`FeatureB` products that consume it, and
an iOS host app linking all three.

```sh
Fixtures/DynamicHost/verify.sh            # build + single-copy audit
Fixtures/DynamicHost/verify.sh --launch   # additionally run the iOS app
                                          # in a simulator (local only)
```

The script builds the app for the iOS simulator, then runs `nm` over the
app executable and every dynamic framework the app loads, counting which
images define `_libvlc_new`. It passes only when exactly one image defines
it — `libvlc.framework/libvlc` — and the app executable and Swift wrapper
frameworks define none. With `--launch` it also boots a simulator and
checks the app's runtime output: both feature libraries observe the same
``VLCInstance/shared`` object, and the launch log contains no duplicate
Objective-C class warnings. CI runs the build-and-audit half on every
pull request that touches `Package.swift` or `Sources/`.
