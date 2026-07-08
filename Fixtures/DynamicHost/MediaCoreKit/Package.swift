// swift-tools-version: 6.3

import PackageDescription

/// The dynamic intermediary of the layered-app consumption fixture:
/// MediaCore is the single owner of the SwiftVLC dependency. libVLC itself
/// remains a separate dynamic binary framework, while the wrapper lives in
/// its own package so static feature targets consume the dynamic product
/// across a package boundary.
let package = Package(
  name: "MediaCoreKit",
  platforms: [.iOS(.v18)],
  products: [
    .library(name: "MediaCore", type: .dynamic, targets: ["MediaCore"])
  ],
  dependencies: [
    .package(path: "../../..")
  ],
  targets: [
    .target(
      name: "MediaCore",
      dependencies: [.product(name: "SwiftVLC", package: "SwiftVLC_LGPL")]
    )
  ]
)
