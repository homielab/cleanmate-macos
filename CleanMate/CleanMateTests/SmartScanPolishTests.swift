import AppKit
import Foundation
import os
import Testing
@testable import CleanMate

/// Smart Scan with long entry lists, the skipped items after a clean, and icons refreshed after an app is installed again.
struct SmartScanPolishTests {
    static func entries(_ count: Int) -> [ScanEntry] {
        (0..<count).map { ScanEntry(url: URL(fileURLWithPath: "/Users/Shared/node_modules/\($0)"), size: Int64(count - $0)) }
    }

    @Test func longListsArePaged() {
        let all = Self.entries(2000)
        let first = CleanerItemRow.page(all, count: CleanerItemRow.pageSize)
        #expect(first.shown.count == 200 && first.hidden == 1800)
        #expect(first.hiddenSize == all.dropFirst(200).reduce(0) { $0 + $1.size })
        let more = CleanerItemRow.page(all, count: CleanerItemRow.pageSize * 2) // "Show 200 More"
        #expect(more.shown.count == 400 && more.hidden == 1600)
        let everything = CleanerItemRow.page(all, count: all.count) // "Show All"
        #expect(everything.shown.count == 2000 && everything.hidden == 0)
    }

    /// ⌘A ticks the entries the list doesn't show yet.
    @MainActor @Test func selectAllCountsHiddenEntries() async {
        let item = CleanerItem(id: "nm", title: "node_modules", paths: ["/nonexistent"], selectableEntries: true)
        let model = SmartScanModel.isolated(module: .smartScan) { [CleanerGroup(id: "g", title: "G", systemImage: "x", items: [item])] }
        model.processNames = { [] }
        model.appBundleIDs = { [] }
        let all = Self.entries(2000)
        model.scanItem = { _, _ in ItemScan(entries: all) }
        await model.scan()
        model.setSelected(item, false)
        #expect(!model.hasSelection)
        model.setFocusedGroups(true)
        #expect(model.isFullySelected(item))
        #expect(model.selectedScan(item)?.entries.count == 2000)
    }

    @MainActor @Test(.timeLimit(.minutes(1))) func rescanSkippedScansOnlyThoseItems() async throws {
        let home = TestTemp.url("CleanMateRescanSkipped")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let done = CleanerItem(id: "done", title: "Done", paths: ["/nonexistent"])
        let inUse = CleanerItem(id: "inuse", title: "In use", paths: ["/nonexistent"])
        let model = SmartScanModel.isolated(module: .smartScan) {
            [CleanerGroup(id: "g", title: "G", systemImage: "x", items: [done]),
             CleanerGroup(id: "h", title: "H", systemImage: "y", items: [inUse])]
        }
        model.processNames = { [] }
        model.appBundleIDs = { [] }
        model.logHome = home
        model.freeSpace = { nil }
        let scanned = OSAllocatedUnfairLock(initialState: [String]())
        model.scanItem = { item, _ in
            scanned.withLock { $0.append(item.id) }
            return ItemScan(measuredSize: 1000)
        }
        let cleaned = OSAllocatedUnfairLock(initialState: [String]())
        model.cleanItem = { item, _, _ in
            cleaned.withLock { $0.append(item.id) }
            var report = CleanReport()
            if item.id == "inuse" { report.skipped = 1 } else { report.freed = 1000 }
            return report
        }
        await model.scan()
        #expect(model.selected == ["done", "inuse"])
        await model.clean()
        guard case .done = model.phase else { Issue.record("phase \(model.phase)"); return }
        #expect(model.skippedItemIDs == ["inuse"])
        #expect(model.cleanedGroups.map(\.id) == ["g"])

        scanned.withLock { $0 = [] }
        model.rescanSkipped()
        await until(model) { if case .results = $0.phase { true } else { false } }
        #expect(scanned.withLock { $0 } == ["inuse"])
        #expect(model.groups.map(\.id) == ["h"] && Set(model.scans.keys) == ["inuse"])
        // Nothing is cleaned until the review's Clean button.
        #expect(cleaned.withLock { $0 } == ["done", "inuse"])
    }

    @Test func restrictKeepsOnlyTheGivenItems() {
        let a = CleanerItem(id: "a", title: "A", paths: []), b = CleanerItem(id: "b", title: "B", paths: [])
        let groups = [CleanerGroup(id: "g", title: "G", systemImage: "x", items: [a, b]),
                      CleanerGroup(id: "h", title: "H", systemImage: "y", items: [a])]
        #expect(SmartScanModel.restrict(groups, to: nil).count == 2)
        let only = SmartScanModel.restrict(groups, to: ["b"])
        #expect(only.map(\.id) == ["g"] && only[0].items.map(\.id) == ["b"])
    }

    /// An app bundle replaced (installed again) shows its new icon without relaunching CleanMate.
    @MainActor @Test func iconOfAReplacedBundleIsLookedUpAgain() throws {
        let root = TestTemp.url("CleanMateIconCache")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "Fake.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: app.path)
        let old = NSImage(size: NSSize(width: 1, height: 1)), new = NSImage(size: NSSize(width: 2, height: 2))
        let key = "test:" + app.path
        #expect(IconCache.image(key, file: app) { old } === old)
        #expect(IconCache.image(key, file: app) { new } === old) // cached
        try FileManager.default.removeItem(at: app) // reinstalled: a new bundle in its place
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000_000)], ofItemAtPath: app.path)
        #expect(IconCache.image(key, file: app) { new } === new)
    }

    /// A new scan (and an app launching or quitting) drops the cached icons.
    @MainActor @Test func iconCacheIsDroppedOnClear() {
        let a = NSImage(size: NSSize(width: 1, height: 1)), b = NSImage(size: NSSize(width: 2, height: 2))
        let key = "test:quit-\(UUID().uuidString)"
        #expect(IconCache.image(key) { a } === a)
        IconCache.clear()
        #expect(IconCache.image(key) { b } === b)
    }
}
