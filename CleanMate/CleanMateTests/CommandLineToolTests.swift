import Foundation
import Testing
@testable import CleanMate

/// The `cleanmate` command line tool: its JSON matches the contract and what the app's Smart Scan finds in the same
/// fake home, a scan deletes nothing and logs nothing, and a clean removes only what it was asked to, like the app.
struct CommandLineToolTests {
    /// What the tool printed.
    final class Printed: Sendable {
        let out = Locked("")
        let err = Locked("")
        /// Stdin is a terminal where this is typed (nil: not a terminal).
        let answer: String?
        init(answer: String? = nil) { self.answer = answer }
        var output: CommandLineTool.Output {
            CommandLineTool.Output(out: { text in self.out.withLock { $0 += text } },
                                   err: { text in self.err.withLock { $0 += text } }, color: false, progress: false,
                                   interactive: answer != nil, readLine: { self.answer })
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
                     "Library/Caches/cli-upto/e.bin": 20_480, "Library/Caches/cli-history/f.bin": 4_096,
                     "Library/Caches/cli-bait/keep.bin": 4_096]
        /// The fake Trash `clean` moves to.
        var trash: URL { root.appending(path: "Trash") }

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
            try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        }

        func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: home.appending(path: path).path) }
        var inTrash: [String] { (try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? [] }

        deinit { try? FileManager.default.removeItem(at: root) }

        func sources(fullDiskAccess: Bool = false, disabled: Set<String> = []) -> HeadlessScan.Sources {
            let policy = policy, groups = groups, privacy = privacy, trash = trash
            return HeadlessScan.Sources(
                policy: { policy }, hasFullDiskAccess: { fullDiskAccess }, smartScan: { _ in groups }, privacy: { privacy },
                disabledGroups: { disabled }, overrides: { [:] }, runningApps: { ["com.example.running": "Running App"] },
                processNames: { [] }, readOpenFiles: EndToEndCleanTests.ownOpenPaths,
                scanItem: { await Scanner.scan($0, policy: $1, openPaths: $2) }, blockedByExclusion: { _, _ in false },
                now: { Date(timeIntervalSince1970: 1_800_000_000) }, version: { "9.9" },
                trash: { url in
                    let target = trash.appending(path: url.lastPathComponent)
                    try FileManager.default.moveItem(at: url, to: target)
                    return target
                })
        }
    }

    static func run(_ arguments: [String], _ sources: HeadlessScan.Sources, answer: String? = nil) async -> (Int32, Printed) {
        let printed = Printed(answer: answer)
        return (await CommandLineTool.run(arguments, sources: sources, output: printed.output), printed)
    }

    static func scanReport(_ arguments: [String], _ sources: HeadlessScan.Sources) async throws -> HeadlessScan.Report {
        let (code, printed) = await run(["scan", "--json"] + arguments, sources)
        try #require(code == 0, "\(printed.stderr)")
        return try JSONDecoder().decode(HeadlessScan.Report.self, from: Data(printed.stdout.utf8))
    }

    static func cleanReport(_ arguments: [String], _ sources: HeadlessScan.Sources) async throws -> HeadlessClean.Report {
        let (code, printed) = await run(["clean", "--json"] + arguments, sources)
        try #require(code == 0, "\(printed.stderr)")
        return try JSONDecoder().decode(HeadlessClean.Report.self, from: Data(printed.stdout.utf8))
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
                          ["list", "extra"], ["--version", "extra"], ["scan", "--json=yes"], ["scan", "--dry-run"],
                          ["scan", "--yes"], ["list", "--yes"], ["clean", "--yes=1"], ["clean", "--only", "nope", "--yes"],
                          ["clean", "--only", "cli-history", "--yes"], ["clean", "extra"]] {
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

    // MARK: - clean

    /// `clean --yes --only … --json`: the named items go (the Trash item into the Trash), everything else stays, and the
    /// activity log gets the app's lines, which Settings › Activity and the Overview read.
    @Test func cleanRemovesOnlyTheNamedItemsAndLogsLikeTheApp() async throws {
        let fixture = try Fixture()
        let (code, printed) = await Self.run(["clean", "--yes", "--only", "cli-caches,cli-old", "--json"], fixture.sources())
        #expect(code == 0 && printed.stderr.isEmpty)
        let report = try JSONDecoder().decode(HeadlessClean.Report.self, from: Data(printed.stdout.utf8))
        #expect(report.version == "9.9" && !report.dryRun && report.log == "~/Library/Logs/CleanMate/activity.log")
        #expect(report.items.map(\.id) == ["cli-caches", "cli-old"])
        #expect(report.items[0] == HeadlessClean.Item(id: "cli-caches", name: "Junk caches", freed: 49_152, trashed: 0,
                                                      skipped: [], locked: false, reason: nil))
        #expect(report.items[1] == HeadlessClean.Item(id: "cli-old", name: "Old files", freed: 16_384, trashed: 16_384,
                                                      skipped: [], locked: false, reason: nil))
        #expect(report.freed == 65_536 && report.inTrash == 16_384 && report.upTo == 0)
        // The contract's `reason` and `log` are always there.
        let raw = try #require(JSONSerialization.jsonObject(with: Data(printed.stdout.utf8)) as? [String: Any])
        #expect(Set(raw.keys) == ["version", "dryRun", "freed", "upTo", "inTrash", "items", "log"])
        #expect((raw["items"] as? [[String: Any]])?.allSatisfy { $0["reason"] is NSNull } == true)

        #expect(!fixture.exists("Library/Caches/cli-junk/a.bin") && !fixture.exists("Library/Caches/cli-junk/b.bin"))
        #expect(!fixture.exists("Library/Caches/cli-old/c.bin") && fixture.inTrash == ["c.bin"])
        for path in ["Library/Caches/cli-bait/keep.bin", "Library/Caches/cli-running/d.bin", "Library/Caches/cli-upto/e.bin",
                     "Library/Caches/cli-history/f.bin"] {
            #expect(fixture.exists(path), "\(path)")
        }

        let logged = ActivityLog.freed(home: fixture.home)
        #expect(logged.deleted == 49_152 && logged.trashed == 16_384)
        let lines = ActivityLog.read(home: fixture.home).split(separator: "\n")
        let entries = lines.map { ActivityLog.entry($0, locale: Locale(identifier: "en")) }
        #expect(entries.map(\.moduleKey) == ["Smart Scan", "Smart Scan"])
        #expect(entries.map(\.item) == ["Junk caches", "Old files"] && entries.map(\.kind) == ["deleted", "trashed"])
        #expect(entries.map(\.bytes) == [49_152, 16_384] && entries.allSatisfy { $0.date != nil })
        let overview = ActivityLog.cleanups(home: fixture.home)
        #expect(overview.total == 49_152 && overview.lastBytes == 49_152 && overview.last30Days == 49_152)
    }

    /// `--dry-run` reports what a clean would do (the items ticked by default) and changes nothing, log included.
    /// It needs no --yes.
    @Test func dryRunReportsTheDefaultSelectionAndTouchesNothing() async throws {
        let fixture = try Fixture()
        let report = try await Self.cleanReport(["--dry-run"], fixture.sources())
        #expect(report.dryRun && report.log == nil)
        // Ticked by default: caches, the "up to" item and the locked one (reported); not the unticked Trash item.
        #expect(report.items.map(\.id) == ["cli-caches", "cli-upto", "cli-running"])
        #expect(report.freed == 49_152 + 20_480 && report.upTo == 20_480 && report.inTrash == 0)
        let running = try #require(report.items.first { $0.id == "cli-running" })
        #expect(running.locked && running.reason == "Running App is running" && running.freed == 0)
        #expect(running.skipped == [HeadlessClean.Skipped(path: "~/Library/Caches/cli-running/d.bin", reason: "Running App is running")])
        #expect(try await Self.cleanReport(["--dry-run", "--only", "cli-old"], fixture.sources()).inTrash == 16_384)

        for path in fixture.files.keys { #expect(fixture.exists(path), "\(path)") }
        #expect(fixture.inTrash.isEmpty && !FileManager.default.fileExists(atPath: ActivityLog.url(home: fixture.home).path))
        let (_, text) = await Self.run(["clean", "--dry-run"], fixture.sources())
        #expect(text.stdout.contains("Dry run: nothing was deleted") && text.stdout.contains("Would free 70 KB"))
    }

    /// Without a terminal, clean without --yes deletes nothing and exits 4; on a terminal it asks first.
    @Test func cleanNeedsYesOrAConfirmation() async throws {
        let fixture = try Fixture()
        let scans = Locked(0)
        var sources = fixture.sources()
        let scanItem = sources.scanItem
        sources.scanItem = { scans.withLock { $0 += 1 }; return await scanItem($0, $1, $2) }
        let (code, printed) = await Self.run(["clean", "--only", "cli-caches"], sources)
        #expect(code == 4 && printed.stdout.isEmpty && printed.stderr.contains("--yes") && scans.withLock { $0 } == 0)

        let (declined, asked) = await Self.run(["clean", "--only", "cli-caches,cli-old"], sources, answer: "")
        #expect(declined == 0 && asked.stdout.isEmpty && asked.stderr.contains("Proceed? [y/N]"))
        #expect(asked.stderr.contains("About to clean 2 items: 49 KB deleted (junk apps rebuild), 16 KB moved to the Trash."))
        #expect(asked.stderr.contains("Nothing was deleted") && asked.stderr.contains("No Undo"))
        for path in fixture.files.keys { #expect(fixture.exists(path), "\(path)") }
        #expect(!FileManager.default.fileExists(atPath: ActivityLog.url(home: fixture.home).path))

        let (accepted, cleaned) = await Self.run(["clean", "--only", "cli-caches"], sources, answer: "y")
        #expect(accepted == 0 && cleaned.stdout.contains("Freed 49 KB") && !fixture.exists("Library/Caches/cli-junk/a.bin"))
    }

    /// An item whose app runs is kept and reported, also when the app was opened after the scan; a Privacy item is
    /// cleaned only when named.
    @Test func runningAppsAndPrivacyAreKept() async throws {
        let fixture = try Fixture()
        let reads = Locked(0)
        var sources = fixture.sources()
        // Not running at the scan, running when the clean starts.
        sources.runningApps = { reads.withLock { $0 += 1; return $0 == 1 ? [:] : ["com.example.running": "Running App"] } }
        let report = try await Self.cleanReport(["--yes", "--only", "cli-running,cli-upto"], sources)
        let running = try #require(report.items.first { $0.id == "cli-running" })
        #expect(running.locked && running.reason == "Running App is running" && running.freed == 0)
        #expect(running.skipped.map(\.reason) == ["Running App is running"])
        #expect(fixture.exists("Library/Caches/cli-running/d.bin") && !fixture.exists("Library/Caches/cli-upto/e.bin"))
        #expect(report.freed == 20_480 && report.upTo == 20_480)

        // --privacy alone adds nothing to the default selection; the privacy group or the item's id does.
        #expect(try await !Self.cleanReport(["--yes", "--privacy"], fixture.sources()).items.contains { $0.id == "cli-history" })
        #expect(fixture.exists("Library/Caches/cli-history/f.bin"))
        let privacy = try await Self.cleanReport(["--yes", "--privacy", "--group", "privacy"], fixture.sources())
        #expect(privacy.items.map(\.id) == ["cli-history"] && !fixture.exists("Library/Caches/cli-history/f.bin"))
        #expect(ActivityLog.read(home: fixture.home).contains("\tPrivacy\tBrowsing history\t"))
        #expect(fixture.exists("Library/Caches/cli-bait/keep.bin"))
    }

    /// What the cleaner kept gets a path and a reason; a tool's item without a listed entry gets one line.
    @Test func keptEntriesAreListed() throws {
        let fixture = try Fixture()
        let home = fixture.home
        let item = CleanerItem(id: "x", title: "X", paths: ["~/Library/Caches/cli-junk"])
        let a = home.appending(path: "Library/Caches/cli-junk/a.bin"), gone = home.appending(path: "Library/Caches/cli-junk/gone")
        let scan = ItemScan(entries: [ScanEntry(url: a, size: 1), ScanEntry(url: gone, size: 1)])
        #expect(HeadlessClean.kept(item, scan, CleanReport(), home: home).isEmpty)
        #expect(HeadlessClean.kept(item, scan, CleanReport(skipped: 1), home: home)
                == [HeadlessClean.Skipped(path: "~/Library/Caches/cli-junk/a.bin", reason: HeadlessClean.keptReason)])
        #expect(HeadlessClean.kept(item, scan, CleanReport(skipped: 1, changed: [a]), home: home)
                == [HeadlessClean.Skipped(path: "~/Library/Caches/cli-junk/a.bin", reason: HeadlessClean.changedReason)])
        let tool = CleanerItem(id: "t", title: "T", paths: ["~/.tool"], command: ShellCommand(executable: "/usr/bin/true", arguments: []))
        #expect(HeadlessClean.kept(tool, scan, CleanReport(skipped: 1), home: home)
                == [HeadlessClean.Skipped(path: "~/.tool", reason: HeadlessClean.keptReason)])
    }
}
