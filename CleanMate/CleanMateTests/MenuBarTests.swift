import Foundation
import Testing
@testable import CleanMate

/// The menu bar item's last-scan line and Scan Now, on a throwaway defaults domain.
@MainActor
struct MenuBarTests {
    let suite = "CleanMateMenuBarTests-\(UUID().uuidString)"
    var defaults: UserDefaults { UserDefaults(suiteName: suite)! }
    static let date = Date(timeIntervalSince1970: 1_768_478_400) // 2026-01-15 12:00 UTC

    @Test func lastScanIsStoredAndACleanAddsWhatItFreed() {
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(LastScan.read(defaults: defaults) == nil)
        LastScan.recordClean(freed: 10, defaults: defaults) // no scan yet: nothing to add to
        #expect(LastScan.read(defaults: defaults) == nil)
        LastScan(date: Self.date, size: 5_000_000).save(defaults: defaults)
        #expect(LastScan.read(defaults: defaults) == LastScan(date: Self.date, size: 5_000_000))
        LastScan.recordClean(freed: 3_000_000, defaults: defaults)
        LastScan.recordClean(freed: 1_000_000, defaults: defaults) // a second clean of the same results
        #expect(LastScan.read(defaults: defaults) == LastScan(date: Self.date, size: 5_000_000, cleaned: 4_000_000))
    }

    @Test func lastScanLineSaysWhatTheScanFoundOrWhatWasCleaned() {
        let en = Locale(identifier: "en_US"), vi = Locale(identifier: "vi")
        let found = SmartScanView.lastScanLine(LastScan(date: Self.date, size: 5_000_000), locale: en)
        #expect(found.hasPrefix("Last scan Jan") && found.hasSuffix(": 5 MB to clean"), "\(found)")
        #expect(SmartScanView.lastScanLine(LastScan(date: Self.date, size: 0), locale: en).hasSuffix(": nothing to clean"))
        let cleaned = SmartScanView.lastScanLine(LastScan(date: Self.date, size: 5_000_000, cleaned: 4_000_000), locale: en)
        #expect(cleaned.hasSuffix(": cleaned 4 MB"), "\(cleaned)")
        let foundVI = SmartScanView.lastScanLine(LastScan(date: Self.date, size: 5_000_000), locale: vi)
        #expect(foundVI.hasPrefix("Lần quét gần nhất") && foundVI.contains("có thể dọn 5 MB"), "\(foundVI)")
    }

    /// Like ⌘R: off while a confirmation is open or something is being removed.
    @Test func scanNowIsDisabledDuringAConfirmationOrAClean() {
        #expect(ModuleRouter.canScanNow(sheetOpen: false, busy: false))
        #expect(!ModuleRouter.canScanNow(sheetOpen: true, busy: false))
        #expect(!ModuleRouter.canScanNow(sheetOpen: false, busy: true))
    }

    @Test func modelReportsFinishedScansAndCleans() async {
        let item = CleanerItem(id: "menubar.cache", title: "Cache", paths: ["/nonexistent"])
        let model = SmartScanModel(module: .smartScan) { [CleanerGroup(id: "g", title: "G", systemImage: "x", items: [item])] }
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
