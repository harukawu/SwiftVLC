import Foundation
import Testing

extension Tag {
  /// Tests that require a real libVLC instance.
  @Tag static var integration: Self
  /// Pure Swift logic tests (no libVLC needed).
  @Tag static var logic: Self
  /// Tests that require generated media fixtures.
  @Tag static var media: Self
  /// Tests running on @MainActor.
  @Tag static var mainActor: Self
  /// Async tests.
  @Tag static var async: Self
}

/// Runtime conditions for conditional test execution.
enum TestCondition {
  /// `false` on CI runners — headless environments lack video/audio
  /// output, so libVLC's h264 decoder cannot allocate frame buffers.
  static let canPlayMedia = ProcessInfo.processInfo.environment["CI"] == nil

  /// The iOS simulator audio backend applies volume changes but does not
  /// emit libVLC's `MediaPlayerAudioVolume` event for them. Keep the native
  /// event assertion on platforms where the backend reports it; setter and
  /// event-mapping coverage remain active on iOS.
  static let canObserveNativeVolumeEvents: Bool = {
    guard canPlayMedia else { return false }
#if os(iOS) && targetEnvironment(simulator)
    return false
#else
    return true
#endif
  }()
}
