import AppKit

/// Bounces the Dock icon once when a long scan or clean finishes while CleanMate is in the background.
/// No notification permission, no sound. Call only on a real finish, never on cancel.
nonisolated enum Attention {
    /// Task-local so tests bind them without bouncing the real Dock or racing parallel tests;
    /// model tasks started inside `withValue` inherit them.
    @TaskLocal static var isActive: @MainActor @Sendable () -> Bool = { NSApp.isActive }
    @TaskLocal static var bounce: @MainActor @Sendable () -> Void = { _ = NSApp.requestUserAttention(.informationalRequest) }

    @MainActor static func finished() {
        if !isActive() { bounce() }
    }
}
