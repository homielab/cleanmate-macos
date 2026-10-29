import AppKit
import SwiftUI
import Testing
@testable import CleanMate

/// Space ticks or previews in the list that has the keyboard focus, and only there: two lists side by side
/// (Uninstaller), each with its own `onSpaceKey`, in an offscreen window.
@MainActor
struct SpaceKeyTests {
    private func space(_ window: NSWindow, modifiers: NSEvent.ModifierFlags = [], key: String = " ",
                       code: UInt16 = 49) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, characters: key,
                                      charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
    }

    private func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { ([$0 as? T].compactMap { $0 }) + all(type, in: $0) }
    }

    @Test func onlyTheFocusedListTakesSpace() async throws {
        let lists = HStack(spacing: 0) {
            List(["a"], id: \.self) { Text($0) }.onSpaceKey { true }
            List(["b"], id: \.self) { Text($0) }.onSpaceKey { true }
        }
        let host = NSHostingView(rootView: lists.frame(width: 600, height: 300))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))

        func byX<T: NSView>(_ views: [T]) -> [T] { views.sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX } }
        let monitors = byX(all(SpaceKeyMonitorView.self, in: host))
        let tables = byX(all(NSTableView.self, in: host))
        try #require(monitors.count == 2 && tables.count == 2)

        #expect(!monitors[0].handles(try space(window))) // nothing focused
        window.makeFirstResponder(tables[0])
        #expect(monitors[0].handles(try space(window)))
        #expect(!monitors[1].handles(try space(window))) // the other list
        #expect(!monitors[0].handles(try space(window, modifiers: .command)))
        #expect(!monitors[0].handles(try space(window, key: "a", code: 0)))
        window.makeFirstResponder(tables[1])
        let event = try space(window)
        #expect(monitors[1].handles(event))
        #expect(!monitors[0].handles(event))
        monitors[1].blocked = true // a confirmation is shown
        #expect(!monitors[1].handles(try space(window)))
    }
}
