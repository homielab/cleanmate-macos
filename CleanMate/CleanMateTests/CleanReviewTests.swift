import Foundation
import Testing
@testable import CleanMate

/// The review shown by Clean… (what goes to the Trash, what is deleted for good, what is skipped) and the search over
/// Smart Scan / Privacy results.
@MainActor
struct CleanReviewTests {
    static func entry(_ path: String, _ size: Int64, title: String? = nil, lock: String? = nil) -> ScanEntry {
        var entry = ScanEntry(url: URL(fileURLWithPath: path), size: size, title: title)
        entry.lockReason = lock
        return entry
    }

    // Ids under a test prefix: a tick remembered by `setReviewed` is put back to its default before the test ends.
    let caches = CleanerItem(id: "review-test.caches", title: "Caches", paths: [])
    let downloads = CleanerItem(id: "review-test.downloads", title: "Old Downloads", paths: [], mode: .trash,
                                selectableEntries: true)
    let pnpm = CleanerItem(id: "review-test.pnpm", title: "pnpm Store", paths: [], sizeIsUpperBound: true)
    let running = CleanerItem(id: "review-test.running", title: "Running App", paths: [], runningAppBundleIDs: ["test.review.app"])
    let logs = CleanerItem(id: "review-test.logs", title: "Logs", paths: [])

    func model() -> SmartScanModel {
        let model = SmartScanModel.isolated(module: .smartScan) { [
            CleanerGroup(id: "system", title: "System", systemImage: "gear", items: [caches, running, logs]),
            CleanerGroup(id: "files", title: "Files", systemImage: "doc", items: [downloads, pnpm]),
        ] }
        model.runningApps = ["test.review.app"]
        model.runningProcesses = []
        model.appBundleIDs = { ["test.review.app"] }
        model.scans = [
            caches.id: ItemScan(entries: [Self.entry("/Users/Shared/Library/Caches/com.example.app", 1000)]),
            downloads.id: ItemScan(entries: [Self.entry("/Users/Shared/Downloads/setup.dmg", 4000),
                                             Self.entry("/Users/Shared/Downloads/Café.zip", 2000),
                                             Self.entry("/Users/Shared/Downloads/open.pkg", 500, lock: "In use")]),
            pnpm.id: ItemScan(entries: [Self.entry("/Users/Shared/.pnpm-store", 9000)]),
            running.id: ItemScan(entries: [Self.entry("/Users/Shared/Library/Running", 300)]),
            logs.id: ItemScan(entries: [Self.entry("/Users/Shared/Library/Logs", 700)]),
        ]
        model.phase = .results
        model.selected = [caches.id, downloads.id, pnpm.id, running.id]
        return model
    }

    @Test func reviewSplitsTrashAndPermanentAndMatchesTheSelectedTotal() {
        let model = model()
        let review = model.review(of: model.selectedIDs)
        #expect(review.groups.map(\.id) == ["system", "files"])
        #expect(review.groups[0].rows.map(\.id) == [caches.id]) // the running app is skipped, Logs was never ticked
        #expect(review.groups[1].rows.map(\.id) == [pnpm.id, downloads.id]) // biggest first, as in the results
        #expect(review.skipped.map(\.id) == [running.id])
        let downloadsRow = review.groups[1].rows[1]
        #expect(downloadsRow.total.size == 6000 && downloadsRow.lockedCount == 1) // the locked entry is not counted
        #expect(review.trash == .init(size: 6000))
        #expect(review.delete == .init(size: 1000, upTo: 9000))
        #expect(review.trash.size + review.delete.size == model.selectedSize)
        #expect(review.trash.upTo + review.delete.upTo == model.selectedUpToSize)
        #expect(review.hasSelection)
    }

    @Test func untickingInTheReviewKeepsTheRowAndItsLeftOutEntries() {
        let model = model()
        let ids = model.selectedIDs
        model.setEntry(downloads, URL(fileURLWithPath: "/Users/Shared/Downloads/Café.zip"), false)
        var review = model.review(of: ids)
        #expect(review.trash == .init(size: 4000) && review.groups[1].rows[1].isPartial)

        model.setReviewed(downloads, false)
        review = model.review(of: ids)
        #expect(review.groups[1].rows.map(\.id) == [pnpm.id, downloads.id]) // still listed, to tick again
        #expect(!review.groups[1].rows[1].isOn && review.trash == .init())
        #expect(model.selectedSize == 1000) // the list and the sidebar badge follow

        model.setReviewed(downloads, true) // the entry left out by hand stays out
        #expect(model.review(of: ids).trash == .init(size: 4000))

        for item in [caches, downloads, pnpm] { model.setReviewed(item, false) }
        #expect(!model.review(of: ids).hasSelection)
        for item in [caches, downloads, pnpm] { model.setReviewed(item, true) } // back to the defaults
        #expect(Preferences.overrides[downloads.id] == nil)
    }

    @Test func searchMatchesNamesPathsAndEntryLabels() {
        let scan = ItemScan(entries: [Self.entry("/Users/Shared/Downloads/Café.zip", 1),
                                      Self.entry("/Users/Shared/Downloads/x.dmg", 1, title: "Xcode Installer")])
        let match = { (query: String) in SmartScanModel.searchMatch(titles: ["Old Downloads", "Old Downloads"], scan: scan, query: query) }
        #expect(match("") == .whole && match("  ") == .whole)
        #expect(match("old down") == .whole) // name, any case
        #expect(match("cafe") == .entries([URL(fileURLWithPath: "/Users/Shared/Downloads/Café.zip")])) // diacritics ignored
        #expect(match("xcode") == .entries([URL(fileURLWithPath: "/Users/Shared/Downloads/x.dmg")])) // entry label
        #expect(match("/Users/Shared/Downloads").map { if case .entries(let urls) = $0 { urls.count } else { 0 } } == 2)
        #expect(match("nothing") == nil)
        // Either title finds the item: the one shown (Vietnamese) or the English one.
        #expect(SmartScanModel.searchMatch(titles: ["Bộ nhớ đệm", "Caches"], scan: nil, query: "bo nho") == .whole)
        #expect(SmartScanModel.searchMatch(titles: ["Bộ nhớ đệm", "Caches"], scan: nil, query: "caches") == .whole)
    }

    @Test func searchFiltersGroupsAndTicksOnlyWhatItFinds() {
        let model = model()
        model.search = "logs"
        #expect(model.shownGroups.map(\.id) == ["system"] && model.shownGroups[0].items.map(\.id) == [logs.id])
        model.setFocusedGroups(true) // nothing highlighted: every shown group
        #expect(model.selected.contains(logs.id))
        model.setFocusedGroups(false)
        #expect(!model.selected.contains(logs.id) && model.selected.contains(caches.id)) // caches is not shown

        model.search = "setup"
        #expect(model.shownGroups.map(\.id) == ["files"] && model.shownGroups[0].items.map(\.id) == [downloads.id])
        model.setFocusedGroups(false) // only the entry found, not the whole item
        let setup = URL(fileURLWithPath: "/Users/Shared/Downloads/setup.dmg")
        #expect(model.selected.contains(downloads.id) && !model.isEntrySelected(downloads, setup))
        #expect(model.isEntrySelected(downloads, URL(fileURLWithPath: "/Users/Shared/Downloads/Café.zip")))
        model.setFocusedGroups(true)
        #expect(model.isFullySelected(downloads))

        model.search = "nothing"
        #expect(model.shownGroups.isEmpty)
        model.search = ""
        #expect(model.shownGroups.map(\.id) == model.visibleGroups.map(\.id)) // clearing the search shows everything
        #expect(model.shownGroups.flatMap(\.items).count == 5)
        model.setSelected(logs, true) // back to the default
        #expect(Preferences.overrides[logs.id] == nil)
    }

    @Test func selectAllKeysActOnTheHighlightedGroup() {
        let model = model()
        model.highlighted = [logs.id]
        model.setFocusedGroups(false) // ⇧⌘A: the System group only
        #expect(!model.selected.contains(caches.id) && model.selected.contains(downloads.id) && model.selected.contains(pnpm.id))
        model.setFocusedGroups(true) // ⌘A: System again, the running app stays locked
        #expect(model.selected.isSuperset(of: [caches.id, logs.id]))
        for item in [caches, running, logs] { model.setSelected(item, true) } // back to the defaults
        #expect(Preferences.overrides[running.id] == nil)
    }
}
