import AppKit
import SwiftUI

/// Puts the main window back where it was, at the size it had, when it opens again (after a relaunch or after it was
/// closed), and saves its frame whenever it moves or resizes. SwiftUI's own frame restoration only works while macOS
/// restores windows, which "Close windows when quitting an application" (on by default) turns off.
struct WindowFrameKeeper: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowFrameKeeperView { WindowFrameKeeperView() }
    func updateNSView(_ view: WindowFrameKeeperView, context: Context) {}
}

final class WindowFrameKeeperView: NSView {
    private var observers: [NSObjectProtocol] = []

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard window != nil else { return }
        // On the next turn of the run loop, once SwiftUI has given the new window its default size: that size must
        // neither replace the saved frame nor be saved over it.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, self.observers.isEmpty else { return }
            let screens = NSScreen.screens.map(\.visibleFrame)
            if let frame = Self.restoredFrame(UserDefaults.standard.string(forKey: Preferences.mainWindowFrame), screens: screens) {
                window.setFrame(frame, display: true)
            }
            for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
                self.observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { note in
                    MainActor.assumeIsolated {
                        guard let window = note.object as? NSWindow, !window.styleMask.contains(.fullScreen) else { return }
                        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Preferences.mainWindowFrame)
                    }
                })
            }
        }
    }

    /// The saved frame (`NSStringFromRect`), moved and shrunk to fit the screen it is mostly on; on a screen that is no
    /// longer connected, the same size centred on the main screen (`screens[0]`). nil when nothing usable is saved.
    nonisolated static func restoredFrame(_ saved: String?, screens: [CGRect]) -> CGRect? {
        guard let saved, let main = screens.first else { return nil }
        let frame = NSRectFromString(saved)
        guard frame.width > 0, frame.height > 0 else { return nil }
        func overlap(_ screen: CGRect) -> CGFloat {
            let shared = screen.intersection(frame)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        let best = screens.max { overlap($0) < overlap($1) } ?? main
        let screen = overlap(best) > 0 ? best : main
        var result = frame
        result.size.width = min(frame.width, screen.width)
        result.size.height = min(frame.height, screen.height)
        if overlap(best) > 0 {
            result.origin.x = min(max(frame.minX, screen.minX), screen.maxX - result.width)
            result.origin.y = min(max(frame.minY, screen.minY), screen.maxY - result.height)
        } else {
            result.origin = CGPoint(x: screen.midX - result.width / 2, y: screen.midY - result.height / 2)
        }
        return result
    }
}
