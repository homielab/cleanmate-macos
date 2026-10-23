import Foundation
import Testing
@testable import CleanMate

/// Empty states and messages: no real file is read, scanned or removed.
struct EmptyStatesTests {
    private func en(_ r: LocalizedStringResource) -> String {
        var r = r
        r.locale = Locale(identifier: "en")
        return String(localized: r)
    }

    @MainActor @Test func uninstallerDeselectsAnAppHiddenBySearchOrRemoved() async {
        let bar = InstalledApp(url: URL(fileURLWithPath: "/Applications/Barista.app"), name: "Barista", bundleID: "com.foo.Bar",
                               version: nil, lastUsed: nil)
        let tea = InstalledApp(url: URL(fileURLWithPath: "/Applications/Tea.app"), name: "Tea", bundleID: "com.foo.Tea",
                               version: nil, lastUsed: nil)
        let model = UninstallerModel()
        model.installedApps = { [bar, tea] }
        model.appSize = { _ in 1 }
        await model.loadApps()
        model.selection = .app(bar.url)
        model.search = "bar"
        #expect(model.selection == .app(bar.url))
        model.search = "tea"
        #expect(model.selection == nil && model.selectedApp == nil)
        model.selection = .leftovers
        model.search = "zzz"
        #expect(model.selection == .leftovers) // only app rows are filtered
        model.search = ""
        model.selection = .app(tea.url)
        model.installedApps = { [bar] } // Tea deleted in Finder, then Refresh
        await model.loadApps()
        #expect(model.selection == nil)
    }

    @Test func spaceLensTrashTitleAddsUpMeasuredItemsOnly() {
        let mb = Int64(5_000_000)
        func item(_ name: String, _ size: Int64?) -> SpaceItem {
            SpaceItem(url: URL(fileURLWithPath: "/tmp/\(name)"), isFolder: true, size: size)
        }
        #expect(en(SpaceLensModel.trashTitle([item("a", mb)])) == "Move 1 item (5 MB) to the Trash?")
        #expect(en(SpaceLensModel.trashTitle([item("a", mb), item("b", nil)])) == "Move 2 items (at least 5 MB) to the Trash?")
        #expect(en(SpaceLensModel.trashTitle([item("a", nil), item("b", nil)])) == "Move 2 items (not measured yet) to the Trash?")
        #expect(en(SpaceLensModel.trashTitle([item("a", nil)])) == "Move 1 item (not measured yet) to the Trash?")
    }

    @MainActor @Test func privacySelectionCountsRecords() {
        let history = CleanerItem(id: "h", title: "H", paths: ["/nonexistent"])
        let cookies = CleanerItem(id: "c", title: "C", paths: ["/nonexistent"])
        let model = SmartScanModel(module: .privacy) { [CleanerGroup(id: "g", title: "G", systemImage: "x", items: [history, cookies])] }
        model.scans["h"] = ItemScan(entries: [ScanEntry(url: URL(fileURLWithPath: "/tmp/h.db"), size: 0, isDatabase: true, records: 42)])
        model.scans["c"] = ItemScan(entries: [ScanEntry(url: URL(fileURLWithPath: "/tmp/c"), size: 1000)])
        model.selected = ["h"]
        #expect(model.selectedRecords == 42 && model.selectedSize == 0 && model.hasSelection)
        model.selected = ["h", "c"]
        #expect(model.selectedRecords == 42 && model.selectedSize == 1000)
        model.selected = ["c"]
        #expect(model.selectedRecords == 0)
        #expect(en("\(42) records") == "42 records")
    }

    /// Sidebar badge: only after a scan, only when > 0, only Smart Scan/Privacy (size) and Large & Old Files (count).
    @Test @MainActor func sidebarBadge() {
        #expect(Module.smartScan.badge(hasResults: true, size: 5) == .size(5))
        #expect(Module.privacy.badge(hasResults: true, size: 7) == .size(7))
        #expect(Module.largeFiles.badge(hasResults: true, files: 3) == .files(3))
        #expect(Module.smartScan.badge(hasResults: false, size: 5) == nil)
        #expect(Module.largeFiles.badge(hasResults: false, files: 3) == nil)
        #expect(Module.privacy.badge(hasResults: true, size: 0) == nil) // records only
        #expect(Module.largeFiles.badge(hasResults: true, files: 0) == nil)
        for module in [Module.uninstaller, .spaceLens, .loginItems] {
            #expect(module.badge(hasResults: true, size: 5, files: 3) == nil)
        }
    }
}
