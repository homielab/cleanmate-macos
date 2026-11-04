import Foundation
import Testing
@testable import CleanMate

/// The Shortcuts actions: Scan for Junk scans like `cleanmate scan` (Scan Groups, Exclusions, Full Disk Access) and
/// deletes nothing; Clean Selected Junk only ever opens the review; the texts read in CleanMate's language.
@MainActor
struct ShortcutsTests {
    typealias Fixture = CommandLineToolTests.Fixture
    static let en = Locale(identifier: "en_US"), vi = Locale(identifier: "vi")
    static let titles = ["system": "System Junk", "dev": "Developer Junk", "user": "Trash"]

    static func scan(_ sources: HeadlessScan.Sources, group: ShortcutsScanGroup? = nil) async -> ShortcutsSummary.Scan {
        ShortcutsSummary.scan(await ScanJunkIntent.scan(group, sources: sources), titles: titles)
    }

    @Test func scanReportsTheTickedJunkByGroupAndDeletesNothing() async throws {
        let fixture = try Fixture()
        let scan = await Self.scan(fixture.sources(fullDiskAccess: true))
        // cli-caches 48 KB (System Junk) and cli-upto 20 KB, an upper bound (Developer Junk); the running app's cache
        // is locked, Old files is not ticked, the empty item is hidden.
        #expect(scan.junk == 49_152 + 20_480 && scan.upTo && scan.items == 2 && scan.fullDiskAccess)
        #expect(scan.groups == [.init(id: "system", title: "System Junk", size: 49_152, items: 1),
                                .init(id: "dev", title: "Developer Junk", size: 20_480, items: 1)])
        for path in fixture.files.keys { #expect(fixture.exists(path), "\(path)") }
        #expect(fixture.inTrash.isEmpty)
    }

    @Test func scanKeepsToScanGroupsAndExclusions() async throws {
        let fixture = try Fixture()
        // A group turned off in Settings is not scanned, unless the shortcut asks for it.
        let withoutDev = await Self.scan(fixture.sources(fullDiskAccess: true, disabled: ["developer"]))
        #expect(withoutDev.groups.map(\.id) == ["system"] && withoutDev.junk == 49_152)
        let devOnly = await Self.scan(fixture.sources(fullDiskAccess: true, disabled: ["developer"]), group: .dev)
        #expect(devOnly.groups.map(\.id) == ["dev"] && devOnly.junk == 20_480)
        // An item whose folder is in Exclusions is locked: not counted.
        var sources = fixture.sources(fullDiskAccess: true)
        sources.blockedByExclusion = { item, _ in item.id == "cli-caches" }
        let excluded = await Self.scan(sources)
        #expect(excluded.groups.map(\.id) == ["dev"] && excluded.junk == 20_480)
    }

    @Test func scanSaysWhenFullDiskAccessIsOff() async throws {
        let fixture = try Fixture()
        let scan = await Self.scan(fixture.sources(fullDiskAccess: false))
        #expect(!scan.fullDiskAccess)
        let text = ShortcutsSummary.text(scan, locale: Self.en)
        #expect(text.hasSuffix("Full Disk Access is off, so some items were not scanned. Turn it on in CleanMate’s Settings."), "\(text)")
        let textVI = ShortcutsSummary.text(scan, locale: Self.vi)
        #expect(textVI.contains("Truy cập toàn bộ ổ đĩa") && !textVI.contains("Full Disk Access"), "\(textVI)")
    }

    @Test func textsReadInCleanMatesLanguage() {
        let scan = ShortcutsSummary.Scan(junk: 5_000_000, upTo: false, items: 3, groups: [
            .init(id: "system", title: "System Junk", size: 4_000_000, items: 2),
            .init(id: "dev", title: "Developer Junk", size: 1_000_000, items: 1),
        ], fullDiskAccess: true)
        #expect(ShortcutsSummary.text(scan, locale: Self.en)
                == "Junk ready to clean: 5 MB (3 items)\nSystem Junk: 4 MB (2 items)\nDeveloper Junk: 1 MB (1 item)")
        var upTo = scan
        upTo.upTo = true
        #expect(ShortcutsSummary.text(upTo, locale: Self.en).hasPrefix("Junk ready to clean: up to 5 MB (3 items)"))
        #expect(ShortcutsSummary.text(scan, locale: Self.vi).hasPrefix("Rác có thể dọn: 5 MB (3 mục)\n"))
        let none = ShortcutsSummary.Scan(junk: 0, upTo: false, items: 0, groups: [], fullDiskAccess: true)
        #expect(ShortcutsSummary.text(none, locale: Self.en) == "No junk to clean.")
        #expect(ShortcutsSummary.text(none, locale: Self.vi) == "Không có rác để dọn.")

        let volume = DiskVolume(name: "Macintosh HD", total: 500_000_000_000, available: 120_000_000_000)
        #expect(ShortcutsSummary.spaceText(volume, last: nil, locale: Self.en) == "120 GB free of 500 GB\nSmart Scan has not run yet.")
        let last = LastScan(date: Date(timeIntervalSince1970: 1_800_000_000), size: 1_000_000, found: 3_000_000)
        let space = ShortcutsSummary.spaceText(volume, last: last, locale: Self.vi)
        #expect(space.hasPrefix("Còn trống 120 GB / 500 GB\nRác tìm thấy: 3 MB (quét lúc "), "\(space)")
    }

    @Test func choicesMatchTheAppAndTheCommandLine() {
        #expect(Module.allCases.allSatisfy { Module.caseDisplayRepresentations[$0] != nil })
        #expect(ShortcutsScanGroup.allCases.allSatisfy { HeadlessScan.groupNames.contains($0.rawValue) })
        let catalog = Set(CleanerGroup.smartScan(hasFullDiskAccess: true).map { HeadlessScan.groupName($0.id) })
        #expect(Set(ShortcutsScanGroup.allCases.map(\.rawValue)) == catalog)
        #expect(Set(ShortcutsSummary.groupTitles(locale: Self.en).keys) == catalog)
    }

    // MARK: Clean Selected Junk

    static let item = CleanerItem(id: "shortcuts-test.cache", title: "Cache", paths: ["/nonexistent"])

    static func model() -> SmartScanModel {
        let model = SmartScanModel.isolated(module: .smartScan) {
            [CleanerGroup(id: "g", title: "G", systemImage: "x", items: [item])]
        }
        model.appBundleIDs = { [] }
        model.processNames = { [] }
        model.blockedByExclusion = { _ in false }
        model.scanItem = { _, _ in ItemScan(measuredSize: 4096) }
        model.cleanItem = { _, _, _ in Issue.record("Clean Selected Junk cleaned"); return CleanReport() }
        return model
    }

    @Test func cleanSelectedOpensTheReviewOnResultsAndNeverCleans() {
        let model = Self.model()
        model.scans = [Self.item.id: ItemScan(measuredSize: 4096)]
        model.selected = [Self.item.id]
        model.phase = .results
        model.requestReview()
        #expect(model.takeReviewRequest())
        #expect(!model.takeReviewRequest()) // once
        guard case .results = model.phase else { Issue.record("left the results"); return }
    }

    @Test func cleanSelectedScansFirstWithoutResults() async {
        let model = Self.model()
        model.requestReview()
        #expect(model.reviewRequested)
        #expect(!model.takeReviewRequest()) // the scan is starting: the request waits
        await until(model) { if case .results = $0.phase { true } else { false } }
        #expect(model.takeReviewRequest())
        guard case .results = model.phase else { Issue.record("left the results"); return }
    }

    @Test func cleanSelectedDropsTheRequestWithNothingTickedOrWhileCleaning() {
        let model = Self.model()
        model.phase = .results
        model.selected = []
        model.requestReview()
        #expect(!model.takeReviewRequest() && !model.reviewRequested)
        model.phase = .cleaning
        model.requestReview()
        #expect(!model.reviewRequested)
        model.phase = .scanning
        model.requestReview()
        model.cancelScan()
        #expect(!model.reviewRequested) // a stopped scan opens no review
    }
}
