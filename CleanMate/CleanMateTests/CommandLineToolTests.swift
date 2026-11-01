import Foundation
import Testing
@testable import CleanMate

/// The `cleanmate` command line tool: its JSON matches the contract and what the app's Smart Scan finds in the same
/// fake home, and a scan deletes nothing and logs nothing.
struct CommandLineToolTests {
    /// What the tool printed.
    final class Printed: Sendable {
        let out = Locked("")
        let err = Locked("")
        var output: CommandLineTool.Output {
            CommandLineTool.Output(out: { text in self.out.withLock { $0 += text } },
                                   err: { text in self.err.withLock { $0 += text } }, color: false, progress: false)
        }
        var stdout: String { out.withLock { $0 } }
        var stderr: String { err.withLock { $0 } }
    }

    /// A fake home with junk for a small catalog using the real group ids.
    final class Fixture {
        let root = TestTemp.url("CleanMateCLI")
        var home: URL { root.appending(path: "home") }
        var policy: SafetyPolicy { SafetyPolicy(home: home, temp: root.appending(path: "tmp")) }
        /// Path in the fake home → bytes (whole 4 KB blocks: the measured size is the byte count).
        let files = ["Library/Caches/cli-junk/a.bin": 40_960, "Library/Caches/cli-junk/b.bin": 8_192,
                     "Library/Caches/cli-old/c.bin": 16_384, "Library/Caches/cli-running/d.bin": 12_288,
                     "Library/Caches/cli-upto/e.bin": 20_480, "Library/Caches/cli-history/f.bin": 4_096]

        let caches = CleanerItem(id: "cli-caches", title: "Junk caches", note: "Rebuilt when needed",
                                 paths: ["~/Library/Caches/cli-junk"])
        let old = CleanerItem(id: "cli-old", title: "Old files", paths: ["~/Library/Caches/cli-old"], mode: .trash,
                              selectedByDefault: false)
        let running = CleanerItem(id: "cli-running", title: "Running app cache", paths: ["~/Library/Caches/cli-running"],
                                  runningAppBundleIDs: ["com.example.running"])
        let upTo = CleanerItem(id: "cli-upto", title: "Pruned store", paths: ["~/Library/Caches/cli-upto"],
                               sizeIsUpperBound: true)
        let empty = CleanerItem(id: "cli-empty", title: "Nothing here", paths: ["~/Library/Caches/cli-none"],
                                showsWhenEmpty: false)
        let history = CleanerItem(id: "cli-history", title: "Browsing history", paths: ["~/Library/Caches/cli-history"])

        var groups: [CleanerGroup] {
            [CleanerGroup(id: "system-junk", title: "System Junk", systemImage: "x", items: [caches, empty]),
             CleanerGroup(id: "developer", title: "Developer Junk", systemImage: "x", items: [running, upTo]),
             CleanerGroup(id: "trash", title: "Trash", systemImage: "x", items: [old])]
        }
        var privacy: [CleanerGroup] { [CleanerGroup(id: "privacy-test", title: "Browser", systemImage: "x", items: [history])] }

        init() throws {
            let fm = FileManager.default
            for (path, bytes) in files {
                let url = home.appending(path: path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(repeating: 7, count: bytes).write(to: url)
            }
            try fm.createDirectory(at: root.appending(path: "tmp"), withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func sources(fullDiskAccess: Bool = false, disabled: Set<String> = []) -> HeadlessScan.Sources {
            let policy = policy, groups = groups, privacy = privacy
            return HeadlessScan.Sources(
                policy: { policy }, hasFullDiskAccess: { fullDiskAccess }, smartScan: { _ in groups }, privacy: { privacy },
                disabledGroups: { disabled }, overrides: { [:] }, runningApps: { ["com.example.running": "Running App"] },
                processNames: { [] }, readOpenFiles: EndToEndCleanTests.ownOpenPaths,
                scanItem: { await Scanner.scan($0, policy: $1, openPaths: $2) }, blockedByExclusion: { _, _ in false },
                now: { Date(timeIntervalSince1970: 1_800_000_000) }, version: { "9.9" })
        }
    }

    static func run(_ arguments: [String], _ sources: HeadlessScan.Sources) async -> (Int32, Printed) {
        let printed = Printed()
        return (await CommandLineTool.run(arguments, sources: sources, output: printed.output), printed)
    }

    static func scanReport(_ arguments: [String], _ sources: HeadlessScan.Sources) async throws -> HeadlessScan.Report {
        let (code, printed) = await run(["scan", "--json"] + arguments, sources)
        try #require(code == 0, "\(printed.stderr)")
        return try JSONDecoder().decode(HeadlessScan.Report.self, from: Data(printed.stdout.utf8))
    }

    @MainActor @Test func scanJSONFollowsTheContractAndMatchesTheApp() async throws {
        let fixture = try Fixture()
        let (code, printed) = await Self.run(["scan", "--json"], fixture.sources())
        #expect(code == 0 && printed.stderr.isEmpty)
        let report = try JSONDecoder().decode(HeadlessScan.Report.self, from: Data(printed.stdout.utf8))
        #expect(report.version == "9.9" && !report.fullDiskAccess && report.scannedAt == "2027-01-15T08:00:00Z")
        // Hidden like in the app: empty items that hide when empty, and Privacy without --privacy.
        #expect(Set(report.items.map(\.id)) == ["cli-caches", "cli-running", "cli-upto", "cli-old"])
        #expect(report.items.map(\.group) == ["system", "dev", "dev", "user"])

        let caches = try #require(report.items.first { $0.id == "cli-caches" })
        #expect(caches.name == "Junk caches" && caches.size == 49_152 && caches.disposal == "delete" && caches.selectedByDefault)
        #expect(!caches.locked && caches.reason == nil && caches.moreEntries == nil)
        #expect(caches.entries.map(\.path) == ["~/Library/Caches/cli-junk/a.bin", "~/Library/Caches/cli-junk/b.bin"])
        let running = try #require(report.items.first { $0.id == "cli-running" })
        #expect(running.locked && running.reason == "Running App is running" && running.size == 12_288)
        let old = try #require(report.items.first { $0.id == "cli-old" })
        #expect(old.disposal == "trash" && !old.selectedByDefault)
        // Ticked, not locked: the sure total and the "up to" total apart.
        #expect(report.total == 49_152 && report.totalUpTo == 20_480)
        // The contract's `reason` is always there, null when the item is not locked.
        let raw = try #require(JSONSerialization.jsonObject(with: Data(printed.stdout.utf8)) as? [String: Any])
        let items = try #require(raw["items"] as? [[String: Any]])
        #expect(items.allSatisfy { $0.keys.contains("reason") })
        #expect(items.first { $0["id"] as? String == "cli-caches" }?["reason"] is NSNull)

        // The app's Smart Scan over the same catalog and home.
        let policy = fixture.policy
        let model = SmartScanModel(module: .smartScan) { fixture.groups }
        model.processNames = { [] }
        model.appBundleIDs = { ["com.example.running"] }
        model.runningApps = ["com.example.running"]
        model.selectionOverrides = { [:] }
        model.blockedByExclusion = { _ in false }
        model.readOpenFiles = EndToEndCleanTests.ownOpenPaths
        model.scanItem = { await Scanner.scan($0, policy: policy, openPaths: $1) }
        await model.scan()
        #expect(model.selectedSize == report.total && model.selectedUpToSize == report.totalUpTo)
        for item in report.items { #expect(model.scans[item.id]?.size == item.size, "\(item.id)") }
        #expect(Set(model.visibleGroups.flatMap(\.items).map(\.id)) == Set(report.items.map(\.id)))
        #expect(Set(report.items.filter(\.locked).map(\.id)) == Set(fixture.groups.flatMap(\.items).filter(model.isLocked).map(\.id)))

        // Read-only: every file is still there and nothing was logged.
        for path in fixture.files.keys { #expect(FileManager.default.fileExists(atPath: fixture.home.appending(path: path).path), "\(path)") }
        #expect(!FileManager.default.fileExists(atPath: ActivityLog.url(home: fixture.home).path))
    }

    @Test func privacyItemsOnlyWithTheFlag() async throws {
        let fixture = try Fixture()
        let sources = fixture.sources()
        #expect(try await Self.scanReport(["--privacy"], sources).items.contains { $0.id == "cli-history" && $0.group == "privacy" })
        #expect(try await Self.scanReport(["--only", "cli-history", "--privacy"], sources).items.map(\.id) == ["cli-history"])
        for arguments in [["scan", "--only", "cli-history"], ["scan", "--group", "privacy"]] {
            let (code, printed) = await Self.run(arguments, sources)
            #expect(code == 2 && printed.stderr.contains("--privacy") && printed.stdout.isEmpty, "\(arguments)")
        }

        let decode = { (data: String) in try JSONDecoder().decode(HeadlessScan.ListReport.self, from: Data(data.utf8)) }
        let (code, printed) = await Self.run(["list", "--json"], sources)
        let list = try decode(printed.stdout)
        #expect(code == 0 && list.version == "9.9" && !list.items.contains { $0.group == "privacy" })
        #expect(list.items.map(\.id) == ["cli-caches", "cli-empty", "cli-running", "cli-upto", "cli-old"])
        let caches = try #require(list.items.first)
        #expect(caches == HeadlessScan.ListItem(id: "cli-caches", group: "system", name: "Junk caches", description: "Rebuilt when needed",
                                                selectedByDefault: true, disposal: "delete", needsFullDiskAccess: false))
        let (_, withPrivacy) = await Self.run(["list", "--json", "--privacy"], sources)
        #expect(try decode(withPrivacy.stdout).items.last?.id == "cli-history")
    }

    @Test func groupsAndItemsNarrowTheScan() async throws {
        let fixture = try Fixture()
        let sources = fixture.sources()
        let dev = try await Self.scanReport(["--group=dev"], sources)
        #expect(Set(dev.items.map(\.id)) == ["cli-running", "cli-upto"] && dev.total == 0 && dev.totalUpTo == 20_480)
        let only = try await Self.scanReport(["--only", "cli-old,cli-caches"], sources)
        #expect(only.items.map(\.id) == ["cli-caches", "cli-old"])
        // A named item that is hidden when empty is still reported.
        #expect(try await Self.scanReport(["--only", "cli-empty"], sources).items.map(\.id) == ["cli-empty"])
        // A group turned off in Settings is skipped unless asked for by name.
        let disabled = fixture.sources(disabled: ["developer"])
        #expect(try await !Self.scanReport([], disabled).items.contains { $0.group == "dev" })
        #expect(try await Self.scanReport(["--group", "dev"], disabled).items.count == 2)
        #expect(try await Self.scanReport(["--only", "cli-upto"], disabled).items.map(\.id) == ["cli-upto"])
    }

    @Test func argumentsAndExitCodes() async throws {
        let fixture = try Fixture()
        let scans = Locked(0)
        var sources = fixture.sources()
        sources.scanItem = { _, _, _ in scans.withLock { $0 += 1 }; return ItemScan() }
        for arguments in [[], ["frobnicate"], ["--bogus"], ["scan", "--bogus"], ["scan", "--only"], ["scan", "--only", "--json"],
                          ["scan", "--only", "nope"], ["scan", "--group", "nope"], ["list", "--only", "cli-caches"],
                          ["list", "extra"], ["--version", "extra"], ["scan", "--json=yes"]] {
            let (code, printed) = await Self.run(arguments, sources)
            #expect(code == 2 && printed.stdout.isEmpty && printed.stderr.hasPrefix("cleanmate: "), "\(arguments)")
        }
        let (version, printedVersion) = await Self.run(["--version"], sources)
        #expect(version == 0 && printedVersion.stdout == "cleanmate 9.9\n")
        for arguments in [["--help"], ["-h"], ["help"], ["scan", "--help"]] {
            let (code, printed) = await Self.run(arguments, sources)
            #expect(code == 0 && printed.stdout.contains("Full Disk Access") && printed.stdout.contains("Exit codes"), "\(arguments)")
        }
        // --require-fda without Full Disk Access: exit 3 before scanning anything.
        let (denied, printedDenied) = await Self.run(["scan", "--require-fda"], sources)
        #expect(denied == 3 && printedDenied.stderr.contains("Full Disk Access") && scans.withLock { $0 } == 0)
        sources.hasFullDiskAccess = { true }
        #expect(await Self.run(["scan", "--require-fda", "--json"], sources).0 == 0)
    }

    @Test func textOutputNotesMissingFullDiskAccessWithoutColors() async throws {
        let fixture = try Fixture()
        let (code, printed) = await Self.run(["scan"], fixture.sources())
        #expect(code == 0 && !printed.stdout.contains("\u{1B}["))
        #expect(printed.stdout.contains("System Junk") && printed.stdout.contains("Running App is running"))
        #expect(printed.stdout.contains("no Full Disk Access"))
        let (_, granted) = await Self.run(["scan"], fixture.sources(fullDiskAccess: true))
        #expect(!granted.stdout.contains("no Full Disk Access"))
        #expect(CommandLineTool.scanText(HeadlessScan.Report(version: "1", fullDiskAccess: true, scannedAt: "", total: 0,
                                                             totalUpTo: 0, items: []), color: true).contains("\u{1B}[1m"))
    }

    /// Entries: largest first, at most 50, `~/` paths; a locked entry carries its reason and is left out of the size.
    @Test func itemEntriesAreCappedAndLockedOnesAnnotated() {
        let home = URL(filePath: "/Users/someone")
        let item = CleanerItem(id: "x", title: "X", paths: ["~/x"])
        var scan = ItemScan(entries: (1...55).map { ScanEntry(url: home.appending(path: "x/\($0)"), size: Int64($0)) })
        scan.entries[54].lockReason = "In use"
        let report = HeadlessScan.report(item, group: "developer", scan: scan, blocked: false, running: nil, selected: true, home: home)
        #expect(report.entries.count == 50 && report.moreEntries == 5)
        #expect(report.entries.first == HeadlessScan.Entry(path: "~/x/55", size: 55, reason: "In use"))
        #expect(report.size == (1...54).reduce(0, +) && !report.locked && report.group == "dev")
        #expect(HeadlessScan.displayPath(URL(filePath: "/Volumes/Drive/.Trashes/501"), home: home) == "/Volumes/Drive/.Trashes/501")

        let blocked = HeadlessScan.report(item, group: "developer", scan: scan, blocked: true, running: nil, selected: true, home: home)
        #expect(blocked.locked && blocked.reason == HeadlessScan.blockedReason)
        let unreadable = HeadlessScan.report(item, group: "trash", scan: ItemScan(permissionDenied: true), blocked: false,
                                             running: nil, selected: true, home: home)
        #expect(unreadable.locked && unreadable.needsFullDiskAccess == true && unreadable.reason == HeadlessScan.needsAccess)
    }

    /// The real catalogs: every group has a contract name and item ids are unique across Smart Scan and Privacy.
    @Test func realCatalogMapsToTheContract() {
        var sources = HeadlessScan.Sources()
        sources.smartScan = { CleanerGroup.smartScan(ages: .default, hasFullDiskAccess: $0) }
        sources.privacy = { CleanerGroup.privacy() }
        sources.overrides = { [:] }
        let list = HeadlessScan.list(privacy: true, sources: sources)
        #expect(list.items.count > 100)
        #expect(Set(list.items.map(\.id)).count == list.items.count)
        #expect(Set(list.items.map(\.group)) == Set(HeadlessScan.groupNames))
        #expect(list.items.allSatisfy { !$0.name.isEmpty && !$0.name.contains("%") && ["delete", "trash"].contains($0.disposal) })
        let byID = Dictionary(uniqueKeysWithValues: list.items.map { ($0.id, $0) })
        #expect(byID["user-caches"]?.needsFullDiskAccess == false && byID["mail-downloads"]?.needsFullDiskAccess == true)
        #expect(byID["empty-trash"]?.needsFullDiskAccess == true && byID["empty-trash"]?.group == "user")
    }
}
