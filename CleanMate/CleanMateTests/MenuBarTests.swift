import Foundation
import Testing
@testable import CleanMate

/// The menu bar item's last-scan line and Scan Now, on a throwaway defaults domain.
@MainActor
struct MenuBarTests {
    let suite = TestDefaults.suite("CleanMateMenuBarTests")
    var defaults: UserDefaults { UserDefaults(suiteName: suite)! }
    static let date = Date(timeIntervalSince1970: 1_768_478_400) // 2026-01-15 12:00 UTC

    @Test func lastScanIsStoredAndACleanAddsWhatItFreed() {
        defer { TestDefaults.remove(suite) }
        #expect(LastScan.read(defaults: defaults) == nil)
        LastScan.recordClean(freed: 10, defaults: defaults) // no scan yet: nothing to add to
        #expect(LastScan.read(defaults: defaults) == nil)
        LastScan(date: Self.date, size: 5_000_000).save(defaults: defaults)
        #expect(LastScan.read(defaults: defaults) == LastScan(date: Self.date, size: 5_000_000))
        LastScan.recordClean(freed: 3_000_000, defaults: defaults)
        LastScan.recordClean(freed: 1_000_000, defaults: defaults) // a second clean of the same results
        #expect(LastScan.read(defaults: defaults) == LastScan(date: Self.date, size: 5_000_000, cleaned: 4_000_000))
    }

    /// What the scan found is kept apart from what was ticked: the menu shows the junk found.
    @Test func lastScanKeepsTheTotalFound() {
        defer { TestDefaults.remove(suite) }
        LastScan(date: Self.date, size: 2_000_000, found: 5_000_000).save(defaults: defaults)
        let read = LastScan.read(defaults: defaults)
        #expect(read == LastScan(date: Self.date, size: 2_000_000, found: 5_000_000))
        #expect(read?.junk == 5_000_000)
        #expect(LastScan(date: Self.date, size: 2_000_000).junk == 2_000_000) // saved before the total was kept
    }

    @Test func lastScanLineSaysTheJunkFoundAndWhatWasCleaned() {
        let en = Locale(identifier: "en_US"), vi = Locale(identifier: "vi")
        let found = SmartScanView.lastScanLine(LastScan(date: Self.date, size: 1_000_000, found: 5_000_000), locale: en)
        #expect(found.hasPrefix("Junk found: 5 MB (scanned Jan") && found.hasSuffix(")"), "\(found)")
        #expect(SmartScanView.lastScanLine(LastScan(date: Self.date, size: 0), locale: en).hasPrefix("No junk found (scanned "))
        let cleaned = SmartScanView.lastScanLine(LastScan(date: Self.date, size: 5_000_000, cleaned: 4_000_000), locale: en)
        #expect(cleaned.hasPrefix("Junk found: 5 MB, cleaned 4 MB (scanned "), "\(cleaned)")
        let foundVI = SmartScanView.lastScanLine(LastScan(date: Self.date, size: 5_000_000), locale: vi)
        #expect(foundVI.hasPrefix("Rác tìm thấy: 5 MB (quét lúc "), "\(foundVI)")
    }

    /// Like ⌘R: off while a confirmation is open or something is being removed.
    @Test func scanNowIsDisabledDuringAConfirmationOrAClean() {
        #expect(ModuleRouter.canScanNow(sheetOpen: false, busy: false))
        #expect(!ModuleRouter.canScanNow(sheetOpen: true, busy: false))
        #expect(!ModuleRouter.canScanNow(sheetOpen: false, busy: true))
    }

    @Test func modelReportsFinishedScansAndCleans() async {
        let item = CleanerItem(id: "menubar.cache", title: "Cache", paths: ["/nonexistent"])
        let model = SmartScanModel.isolated(module: .smartScan) { [CleanerGroup(id: "g", title: "G", systemImage: "x", items: [item])] }
        model.appBundleIDs = { [] }
        model.processNames = { [] }
        model.blockedByExclusion = { _ in false }
        model.scanItem = { _, _ in ItemScan(measuredSize: 4096) }
        model.cleanItem = { _, _, _ in var report = CleanReport(); report.freed = 4096; return report }
        model.logHome = FileManager.default.temporaryDirectory.appending(path: "CleanMateMenuBarTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: model.logHome) }
        var scanned: [Int64] = [], freed: [Int64] = []
        model.scanFinished = { scanned.append($0.selectedSize) }
        model.cleanFinished = { freed.append($0.freed) }
        await model.scan()
        #expect(scanned == [4096])
        await model.clean()
        #expect(freed == [4096])
    }
}
