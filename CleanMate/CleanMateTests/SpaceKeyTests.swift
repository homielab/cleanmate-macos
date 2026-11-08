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

        func byX<T: NSView>(_ views: [T]) -> [T] { views.sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX } }
        var monitors: [ListKeyMonitorView] = [], tables: [NSTableView] = []
        try await eventually("the two lists and their key monitors are attached", timeout: .seconds(30)) {
            monitors = byX(all(ListKeyMonitorView.self, in: host))
            tables = byX(all(NSTableView.self, in: host))
            return monitors.count == 2 && tables.count == 2
        }
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

    /// ⌘A / ⇧⌘A tick in the focused list only (a focused search field keeps ⌘A for its text); ⌘F needs no list focus.
    @Test func selectAllNeedsTheListFocusedAndFindDoesNot() async throws {
        let list = List(["a"], id: \.self) { Text($0) }
            .onSelectAllKeys { _ in true }
            .onFindKey { _ in true }
        let host = NSHostingView(rootView: list.frame(width: 300, height: 300))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        var monitors: [ListKeyMonitorView] = []
        try await eventually("the list key monitors are attached", timeout: .seconds(30)) {
            monitors = all(ListKeyMonitorView.self, in: host)
            return monitors.first { $0.keys == .selectAll } != nil && monitors.first { $0.keys == .find } != nil
        }

        let selectAll = try #require(monitors.first { $0.keys == .selectAll })
        let find = try #require(monitors.first { $0.keys == .find })
        let table = try #require(all(NSTableView.self, in: host).first)
        let a = try space(window, modifiers: .command, key: "a", code: 0)
        let shiftA = try space(window, modifiers: [.command, .shift], key: "A", code: 0)
        let f = try space(window, modifiers: .command, key: "f", code: 3)

        #expect(!selectAll.handles(a)) // nothing focused: the key goes on to Edit › Select All
        #expect(find.handles(f))
        window.makeFirstResponder(table)
        #expect(selectAll.handles(a) && selectAll.handles(shiftA))
        #expect(!selectAll.handles(try space(window, modifiers: [.command, .option], key: "a", code: 0)))
        #expect(!selectAll.handles(try space(window, key: "a", code: 0))) // typing "a"
        let plainSpace = try space(window)
        #expect(!selectAll.handles(f) && !find.handles(a) && !find.handles(plainSpace))
        #expect(!find.handles(try space(window, modifiers: [.command, .shift], key: "F", code: 3)))
        selectAll.blocked = true
        find.blocked = true
        #expect(!selectAll.handles(a) && !find.handles(f))
    }
}
