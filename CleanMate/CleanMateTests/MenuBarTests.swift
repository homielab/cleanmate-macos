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

    /// Ticking results updates the saved "selected" figure: the menu bar and the Overview show the sidebar badge's
    /// number (`selectedSize`); a record already cleaned keeps its figures.
    @Test func selectedFigureFollowsTheTicks() async throws {
        defer { TestDefaults.remove(suite) }
        let defaults = defaults
        let a = CleanerItem(id: "m409.a", title: "A", paths: ["/nonexistent"])
        let b = CleanerItem(id: "m409.b", title: "B", paths: ["/nonexistent"])
        let model = SmartScanModel.isolated(module: .smartScan) {
            [CleanerGroup(id: "g", title: "G", systemImage: "x", items: [a, b])]
        }
        model.processNames = { [] }
        model.appBundleIDs = { [] }
        model.scanItem = { item, _ in ItemScan(measuredSize: item.id == "m409.a" ? 3_000_000 : 2_000_000) }
        model.scanFinished = { LastScan(date: Self.date, size: $0.selectedSize, found: $0.foundSize).save(defaults: defaults) }
        model.selectionChanged = { LastScan.recordSelection($0.selectedSize, defaults: defaults) }
        model.startScan()
        for _ in 0..<3000 { if case .results = model.phase { break }; try await Task.sleep(for: .milliseconds(5)) }
        guard case .results = model.phase else { Issue.record("phase \(model.phase)"); return }

        model.selected = ["m409.a"]
        let saved = try #require(LastScan.read(defaults: defaults))
        #expect(saved.size == model.selectedSize && saved.size == 3_000_000 && saved.junk == model.foundSize)
        let line = SmartScanView.lastScanLine(saved, locale: Locale(identifier: "en_US"))
        #expect(line.hasPrefix("Junk found: 5 MB · selected 3 MB"), "\(line)")

        LastScan.recordClean(freed: 3_000_000, defaults: defaults)
        LastScan.recordSelection(0, defaults: defaults)
        #expect(LastScan.read(defaults: defaults)?.size == 3_000_000)
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
        #expect(found.hasPrefix("Junk found: 5 MB · selected 1 MB (scanned Jan") && found.hasSuffix(")"), "\(found)")
        let all = SmartScanView.lastScanLine(LastScan(date: Self.date, size: 5_000_000, found: 5_000_000), locale: en)
        #expect(all.hasPrefix("Junk found: 5 MB (scanned Jan"), "\(all)")
        #expect(SmartScanView.lastScanLine(LastScan(date: Self.date, size: 0), locale: en).hasPrefix("No junk found (scanned "))
        let cleaned = SmartScanView.lastScanLine(LastScan(date: Self.date, size: 5_000_000, cleaned: 4_000_000), locale: en)
        #expect(cleaned.hasPrefix("Junk found: 5 MB, cleaned 4 MB (scanned "), "\(cleaned)")
        // Vietnamese words and date, also on an English Mac (the locale CleanMate's views pass).
        let viDate = Self.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(vi))
        let foundVI = SmartScanView.lastScanLine(LastScan(date: Self.date, size: 5_000_000), locale: vi)
        #expect(foundVI == "Rác tìm thấy: 5 MB (quét lúc \(viDate))", "\(foundVI)")
        let onEnglishMac = AppLanguage.locale(language: "vi", current: en)
        let cleanedVI = SmartScanView.lastScanLine(LastScan(date: Self.date, size: 5_000_000, cleaned: 4_000_000), locale: onEnglishMac)
        #expect(cleanedVI.hasPrefix("Rác tìm thấy: 5 MB, đã dọn 4 MB (quét lúc ") && !cleanedVI.contains("Jan"), "\(cleanedVI)")
        let noneVI = SmartScanView.lastScanLine(LastScan(date: Self.date, size: 0), locale: onEnglishMac)
        #expect(noneVI.hasPrefix("Không tìm thấy rác (quét lúc "), "\(noneVI)")
        let selectedVI = SmartScanView.lastScanLine(LastScan(date: Self.date, size: 1_000_000, found: 5_000_000), locale: vi)
        #expect(selectedVI == "Rác tìm thấy: 5 MB · đã chọn 1 MB (quét lúc \(viDate))", "\(selectedVI)")
        #expect(![foundVI, cleanedVI, noneVI, selectedVI].contains { $0.contains("Junk") })
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
