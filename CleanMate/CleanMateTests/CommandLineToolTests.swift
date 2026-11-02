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
        // An entry that is not a file (a Docker volume) carries the name the app shows.
        let volume = ItemScan(entries: [ScanEntry(url: URL(string: "docker-volume:1")!, size: 9, title: "postgres-data · local")])
        let volumes = HeadlessScan.report(item, group: "developer", scan: volume, blocked: false, running: nil, selected: false,
                                          home: home)
        #expect(volumes.entries.first?.name == "postgres-data · local" && report.entries.allSatisfy { $0.name == nil })

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
        // Only the items that may hold data are marked, and both are in the catalog, deleted for good.
        #expect(Set(list.items.filter(\.dataLoss).map(\.id)) == HeadlessScan.dataLossIDs)
        #expect(HeadlessScan.dataLossIDs.allSatisfy { byID[$0]?.disposal == "delete" && byID[$0]?.group == "dev" })
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

    /// An item that may hold data (Docker volumes) is cleaned only when named with --only: a tick in the app is not
    /// enough. `list` and `scan` mark it.
    @Test func itemsThatMayHoldDataAreCleanedOnlyWhenNamed() async throws {
        let fixture = try Fixture()
        let path = "Library/Caches/cli-volumes/db.bin"
        let file = fixture.home.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 8_192).write(to: file)
        let volumes = CleanerItem(id: "docker-volumes", title: "Docker: unused volumes", paths: ["~/Library/Caches/cli-volumes"],
                                  selectedByDefault: false)
        let groups = fixture.groups.map { group in
            group.id != "developer" ? group
                : CleanerGroup(id: group.id, title: group.title, systemImage: group.systemImage, items: group.items + [volumes])
        }
        var sources = fixture.sources()
        sources.smartScan = { _ in groups }
        sources.overrides = { ["docker-volumes": true] } // ticked in the app

        // Ticked but not named: reported, held, not counted.
        let reason = HeadlessScan.dataLossReason("docker-volumes")
        let held = HeadlessClean.Item(id: "docker-volumes", name: "Docker: unused volumes", freed: 0, trashed: 0, skipped: [],
                                      dataLoss: true, locked: true, reason: reason)
        let dryRun = try await Self.cleanReport(["--dry-run"], sources)
        #expect(dryRun.items.first { $0.id == "docker-volumes" } == held)
        #expect(dryRun.freed == 49_152 + 20_480 && dryRun.items.filter { $0.id != "docker-volumes" }.allSatisfy { !$0.dataLoss })
        #expect(try await Self.cleanReport(["--dry-run", "--group", "dev"], sources).items.first { $0.id == "docker-volumes" } == held)
        let (_, text) = await Self.run(["clean", "--dry-run"], sources)
        #expect(text.stdout.contains("skipped: \(reason)"))
        let (declined, asked) = await Self.run(["clean"], sources, answer: "n")
        #expect(declined == 0 && asked.stderr.contains("About to clean 2 items"))
        #expect(asked.stderr.contains("Not cleaned, may hold data (name with --only to clean): Docker: unused volumes"))

        // Named: cleaned like any item.
        let named = try await Self.cleanReport(["--dry-run", "--only", "docker-volumes"], sources)
        #expect(named.items == [HeadlessClean.Item(id: "docker-volumes", name: "Docker: unused volumes", freed: 8_192, trashed: 0,
                                                   skipped: [], dataLoss: true, locked: false, reason: nil)])

        // list and scan mark it, in JSON (always present) and text.
        let scan = try await Self.scanReport([], sources)
        #expect(scan.items.filter(\.dataLoss).map(\.id) == ["docker-volumes"])
        let (_, scanJSON) = await Self.run(["scan", "--json"], sources)
        let raw = try #require(JSONSerialization.jsonObject(with: Data(scanJSON.stdout.utf8)) as? [String: Any])
        #expect((raw["items"] as? [[String: Any]])?.allSatisfy { $0["dataLoss"] is Bool } == true)
        let (_, listJSON) = await Self.run(["list", "--json"], sources)
        let list = try JSONDecoder().decode(HeadlessScan.ListReport.self, from: Data(listJSON.stdout.utf8))
        #expect(list.items.filter(\.dataLoss).map(\.id) == ["docker-volumes"])
        for command in ["list", "scan"] {
            let (_, printed) = await Self.run([command], sources)
            let lines = printed.stdout.split(separator: "\n").filter { $0.contains(CommandLineTool.dataLossFlag) }
            #expect(lines.count == 1 && lines.first?.contains("Docker: unused volumes") == true, "\(command)")
        }

        // A real clean of the ticked items leaves it; naming it cleans it.
        let cleaned = try await Self.cleanReport(["--yes"], sources)
        #expect(cleaned.items.first { $0.id == "docker-volumes" } == held && fixture.exists(path))
        #expect(!fixture.exists("Library/Caches/cli-junk/a.bin"))
        let removed = try await Self.cleanReport(["--yes", "--only", "docker-volumes"], sources)
        #expect(removed.freed == 8_192 && !fixture.exists(path))
    }

    /// The real Docker volumes item against a fake `docker`: `scan` lists each volume with its name and marks the item
    /// `dataLoss`; `clean` leaves it unless named; named, it removes each unused volume with its own `docker volume rm`
    /// and keeps the locked one (a stopped container mounts it), reported with the reason.
    @Test func dockerVolumesAreCleanedOneByOneWhenNamed() async throws {
        let fixture = try Fixture()
        let log = fixture.root.appending(path: "docker-calls.txt")
        let df = fixture.root.appending(path: "df.json")
        let stopped = String(repeating: "c1f4cbb8", count: 8)
        try """
        {"Containers":[{"CreatedAt":"2026-10-19 11:43:56 +0700 +07","ID":"\(stopped)","Image":"postgres:18","Mounts":"api_pgdata","Names":"api-db-1","Size":"16kB","State":"exited","Status":"Exited (0) 2 days ago"}],\
        "Volumes":[{"Driver":"local","Labels":"","Links":"0","Name":"junk_cache","Size":"3MB"},\
        {"Driver":"local","Labels":"","Links":"0","Name":"old_redis","Size":"2MB"},\
        {"Driver":"local","Labels":"","Links":"1","Name":"api_pgdata","Size":"9MB"}]}
        """.write(to: df, atomically: true, encoding: .utf8)
        let script = fixture.root.appending(path: "docker")
        try """
        #!/bin/sh
        if [ "$1" = system ]; then cat '\(df.path)'; else echo "$@" >> '\(log.path)'; fi

        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        var volumes = try #require(CleanerGroup.developer.items.first { $0.id == "docker-volumes" })
        let fake = ShellCommand(executable: script.path, arguments: volumes.probe?.command.arguments ?? [])
        volumes.command = ShellCommand(executable: script.path)
        volumes.probe?.command = fake
        volumes.probe?.details?.command = fake
        volumes.probe?.precondition = { true }
        let entryCommand = try #require(volumes.entryCommand)
        volumes.entryCommand = { url in entryCommand(url).map { ShellCommand(executable: script.path, arguments: $0.arguments) } }
        let groups = fixture.groups.map { group in
            group.id != "developer" ? group
                : CleanerGroup(id: group.id, title: group.title, systemImage: group.systemImage, items: group.items + [volumes])
        }
        var sources = fixture.sources()
        sources.smartScan = { _ in groups }
        sources.overrides = { ["docker-volumes": true] } // ticked in the app
        func calls() -> String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }

        let scan = try await Self.scanReport(["--only", "docker-volumes"], sources)
        let item = try #require(scan.items.first)
        #expect(item.dataLoss && !item.locked && item.size == 5_000_000)
        #expect(item.entries.map(\.name) == ["api_pgdata · local", "junk_cache · local", "old_redis · local"])
        #expect(item.entries[0].reason?.contains("api-db-1") == true && item.entries[1].reason == nil)

        let held = try await Self.cleanReport(["--yes"], sources)
        #expect(held.items.first { $0.id == "docker-volumes" }?.reason == HeadlessScan.dataLossReason("docker-volumes"))
        #expect(calls().isEmpty)

        let preview = try await Self.cleanReport(["--dry-run", "--only", "docker-volumes"], sources)
        #expect(preview.freed == 5_000_000 && calls().isEmpty)
        let cleaned = try await Self.cleanReport(["--yes", "--only", "docker-volumes"], sources)
        let result = try #require(cleaned.items.first)
        #expect(result.freed == 5_000_000 && result.skipped.count == 1 && result.skipped[0].reason.contains("api-db-1"))
        #expect(calls() == "volume rm junk_cache\nvolume rm old_redis\n")
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

// MARK: - space and large

extension CommandLineToolTests {
    /// A fake home for `space` and `large`: folders of known sizes, a protected folder, an excluded one, a hard link.
    final class FilesFixture {
        let root = TestTemp.url("CleanMateCLIFiles")
        var home: URL { root.appending(path: "home") }
        /// `home` with its symlinks resolved (/var → /private/var): the form the reports print.
        var real: String { HeadlessFiles.realPath(home.path) ?? home.path }
        var excluded: URL { home.appending(path: "Media/Excluded") }
        /// Path in the fake home → bytes (whole 4 KB blocks, so the allocated size is the byte count).
        let files = ["Projects/app/build.bin": 3_002_368, "Projects/app/data.bin": 2_498_560,
                     "Media/movie.mov": 2_002_944, "Media/old.zip": 1_200_128, "Media/small.bin": 409_600,
                     "Media/Excluded/kept.iso": 1_503_232, "Media/node_modules/dep.bin": 1_605_632,
                     "Documents/secret.bin": 1_101_824, "Downloads/setup.dmg": 1_302_528, "top.bin": 40_960]
        /// Bytes of the files in Media (without the hard link) and in Projects.
        static let mediaFiles: Int64 = 2_002_944 + 1_200_128 + 409_600 + 1_503_232 + 1_605_632
        static let projectFiles: Int64 = 3_002_368 + 2_498_560
        let now = Date.now.addingTimeInterval(400 * 86_400)

        init() throws {
            let fm = FileManager.default
            for (path, bytes) in files {
                let url = home.appending(path: path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(repeating: 7, count: bytes).write(to: url)
            }
            try fm.createDirectory(at: home.appending(path: "Library/Caches"), withIntermediateDirectories: true)
            try fm.createDirectory(at: root.appending(path: "tmp"), withIntermediateDirectories: true)
            // A second link to build.bin in another folder: counted once by space, flagged by large.
            try fm.linkItem(at: home.appending(path: "Projects/app/build.bin"), to: home.appending(path: "Media/build-link.bin"))
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func sources(fullDiskAccess: Bool = false) -> HeadlessScan.Sources {
            let policy = SafetyPolicy(home: home, temp: root.appending(path: "tmp"), excluded: [excluded.path])
            let now = now, opened = home.appending(path: "Media/old.zip").path
            var sources = HeadlessScan.Sources()
            sources.policy = { policy }
            sources.hasFullDiskAccess = { fullDiskAccess }
            sources.now = { now }
            sources.version = { "9.9" }
            // Spotlight knows only old.zip, opened 10 days before "now".
            sources.spotlightLastUsed = { url in
                HeadlessFiles.realPath(url.path) == HeadlessFiles.realPath(opened) ? now.addingTimeInterval(-10 * 86_400) : nil
            }
            return sources
        }
    }

    static func spaceReport(_ arguments: [String], _ sources: HeadlessScan.Sources) async throws -> HeadlessFiles.SpaceReport {
        let (code, printed) = await run(["space", "--json"] + arguments, sources)
        try #require(code == 0, "\(printed.stderr)")
        return try JSONDecoder().decode(HeadlessFiles.SpaceReport.self, from: Data(printed.stdout.utf8))
    }

    static func largeReport(_ arguments: [String], _ sources: HeadlessScan.Sources) async throws -> HeadlessFiles.LargeReport {
        let (code, printed) = await run(["large", "--json"] + arguments, sources)
        try #require(code == 0, "\(printed.stderr)")
        return try JSONDecoder().decode(HeadlessFiles.LargeReport.self, from: Data(printed.stdout.utf8))
    }

    @Test func spaceListsTheBiggestChildrenFirstAndCountsAHardLinkOnce() async throws {
        let fixture = try FilesFixture()
        let report = try await Self.spaceReport([fixture.home.path], fixture.sources(fullDiskAccess: true))
        #expect(report.path == fixture.real && report.fullDiskAccess && report.version == "9.9" && report.skipped.isEmpty)
        #expect(report.items.map(\.name) == ["Media", "Projects", "Downloads", "Documents", "top.bin", "Library"])
        #expect(report.items.allSatisfy { !$0.skipped && $0.reason == nil && $0.path == fixture.real + "/" + $0.name })
        #expect(report.items.map(\.kind) == ["folder", "folder", "folder", "folder", "file", "folder"])
        let projects = try #require(report.items.first { $0.name == "Projects" }?.size)
        let media = try #require(report.items.first { $0.name == "Media" }?.size)
        // The hard link to build.bin counts in whichever sibling reaches it first, never in both (folders add a few KB).
        let files = FilesFixture.mediaFiles + FilesFixture.projectFiles
        #expect((0..<100_000).contains(media + projects - files))
        let all = files + 1_101_824 + 1_302_528 + 40_960
        #expect((0..<100_000).contains(report.size - all) && report.size >= report.items.compactMap(\.size).reduce(0, +))
        #expect(report.moreItems == 0 && report.moreSize == 0)

        let limited = try await Self.spaceReport(["--limit", "2", fixture.home.path], fixture.sources(fullDiskAccess: true))
        #expect(limited.items.map(\.name) == ["Media", "Projects"] && limited.moreItems == 4 && limited.size == report.size)
        #expect(limited.moreSize == report.items.dropFirst(2).compactMap(\.size).reduce(0, +))
        // `~/…` and a relative path inside it name the same folder.
        let media2 = try await Self.spaceReport([fixture.home.path + "/Media/../Media"], fixture.sources(fullDiskAccess: true))
        #expect(media2.path == fixture.real + "/Media" && media2.items.first?.name == "build-link.bin")
    }

    @Test func withoutFullDiskAccessProtectedFoldersAreSkippedAndNeverOpened() async throws {
        let fixture = try FilesFixture()
        let report = try await Self.spaceReport([fixture.home.path], fixture.sources())
        #expect(!report.fullDiskAccess)
        let skipped = report.items.filter(\.skipped)
        #expect(skipped.map(\.name) == ["Documents", "Downloads"])
        #expect(skipped.allSatisfy { $0.size == nil && $0.reason == "Needs Full Disk Access" && $0.kind == "folder" })
        #expect(report.items.suffix(2).allSatisfy { $0.skipped }) // after the measured ones, whatever the limit
        #expect(report.skipped.map(\.path) == [fixture.real + "/Documents", fixture.real + "/Downloads"])
        // Neither folder's files counted.
        #expect((0..<100_000).contains(report.size - FilesFixture.mediaFiles - FilesFixture.projectFiles - 40_960))
        // `size` and `reason` are written as null, not left out.
        let (_, printed) = await Self.run(["space", "--json", fixture.home.path], fixture.sources())
        #expect(printed.stdout.contains("\"size\" : null") && printed.stdout.contains("\"reason\" : null"))

        // A path in a protected folder is refused before it is read, also through a symlink.
        let link = fixture.root.appending(path: "docs-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.home.appending(path: "Documents"))
        for arguments in [["space", fixture.home.path + "/Documents"], ["space", fixture.home.path + "/Documents/none"],
                          ["space", link.path], ["large", "--in", fixture.home.path + "/Downloads"]] {
            let (code, printed) = await Self.run(arguments, fixture.sources())
            #expect(code == 3 && printed.stdout.isEmpty && printed.stderr.contains("Full Disk Access"), "\(arguments)")
        }
        let large = try await Self.largeReport(["--in", fixture.home.path, "--min-size", "50MB"], fixture.sources())
        #expect(large.skipped.map(\.path) == [fixture.real + "/Documents", fixture.real + "/Downloads"] && large.count == 0)

        // With Full Disk Access they are measured like any folder.
        let granted = try await Self.spaceReport([fixture.home.path + "/Documents"], fixture.sources(fullDiskAccess: true))
        #expect(granted.items.map(\.name) == ["secret.bin"] && granted.items[0].size == 1_101_824)
    }

    @Test func largeFiltersLikeLargeAndOldFiles() async throws {
        let fixture = try FilesFixture()
        let media = fixture.home.path + "/Media"
        let report = try await Self.largeReport(["--in", media, "--min-size", "1MB"], fixture.sources(fullDiskAccess: true))
        // Exclusions and node_modules left out; smaller than --min-size left out; biggest first.
        #expect(report.files.map(\.name) == ["build-link.bin", "movie.mov", "old.zip"])
        #expect(report.files.map(\.path) == ["build-link.bin", "movie.mov", "old.zip"].map { fixture.real + "/Media/" + $0 })
        #expect(report.files.map(\.hardLinked) == [true, false, false])
        #expect(report.files.map(\.kind) == ["other", "video", "archive"])
        #expect(report.count == 3 && report.size == 3_002_368 + 2_002_944 + 1_200_128 && report.moreFiles == 0)
        #expect(report.root == fixture.real + "/Media" && report.minSize == 1_000_000 && report.olderThanDays == nil)
        #expect(report.scannedAt == fixture.now.formatted(.iso8601))
        // lastUsed only from Spotlight, null otherwise; modified always.
        #expect(report.files.map { $0.lastUsed != nil } == [false, false, true])
        #expect(report.files.allSatisfy { (try? Date($0.modified, strategy: .iso8601)) != nil })
        let (_, printed) = await Self.run(["large", "--json", "--in", media, "--min-size", "1MB"], fixture.sources())
        #expect(printed.stdout.contains("\"lastUsed\" : null") && printed.stdout.contains("\"olderThanDays\" : null"))

        // --older-than: old.zip was opened 10 days ago, the others not for 400 days.
        let old = try await Self.largeReport(["--in", media, "--min-size=1MB", "--older-than", "30"], fixture.sources())
        #expect(old.files.map(\.name) == ["build-link.bin", "movie.mov"] && old.olderThanDays == 30)
        let none = try await Self.largeReport(["--in", media, "--min-size", "1MB", "--older-than", "500"], fixture.sources())
        #expect(none.count == 0)
        // --min-size and --limit.
        let big = try await Self.largeReport(["--in", media, "--min-size", "1.5MB", "--limit", "1"], fixture.sources())
        #expect(big.files.map(\.name) == ["build-link.bin"] && big.count == 2 && big.moreFiles == 1 && big.size == 3_002_368 + 2_002_944)
        // The whole home: the same rules, Library and protected folders aside.
        let home = try await Self.largeReport(["--min-size", "50MB"], fixture.sources(fullDiskAccess: true))
        #expect(home.count == 0 && home.minSize == 50_000_000 && home.skipped.isEmpty)
    }

    @Test func spaceAndLargeArgumentsAndExitCodes() async throws {
        let fixture = try FilesFixture()
        let home = fixture.home.path
        for arguments in [["space", home + "/nope"], ["space", home + "/top.bin"], ["space", home, home], ["space", "--limit", "0"],
                          ["space", "--limit", "x"], ["space", "--limit"], ["space", "--min-size", "1MB"], ["space", "--in", home],
                          ["large", "extra"], ["large", "--in", home + "/Library"], ["large", "--in", home + "/nope"],
                          ["large", "--in", home + "/.hidden"], ["large", "--in", "/usr"], ["large", "--min-size", "10MB"],
                          ["large", "--min-size", "abc"], ["large", "--min-size", "0"], ["large", "--in", home + "/Media", "--min-size", "500KB"],
                          ["large", "--older-than", "0"], ["large", "--older-than", "-3"], ["large", "--in", home, "--in", home],
                          ["large", "--json=1"]] {
            let (code, printed) = await Self.run(arguments, fixture.sources(fullDiskAccess: true))
            #expect(code == 2 && printed.stdout.isEmpty && printed.stderr.hasPrefix("cleanmate: "), "\(arguments)")
        }
        #expect(HeadlessFiles.parseSize("50MB") == 50_000_000 && HeadlessFiles.parseSize("1.5gb") == 1_500_000_000)
        #expect(HeadlessFiles.parseSize("500M") == 500_000_000 && HeadlessFiles.parseSize("2048") == 2048)
        #expect(HeadlessFiles.parseSize("1 GB") == 1_000_000_000 && HeadlessFiles.parseSize("MB") == nil)
        #expect(HeadlessFiles.parseSize("-1MB") == nil && HeadlessFiles.parseSize("1e3") == nil)
        let space = try CommandLineTool.parse(["space"])
        #expect(space == .space(HeadlessFiles.SpaceOptions(), json: false))
        let large = try CommandLineTool.parse(["large", "--limit=5", "--in", "a,b"])
        #expect(large == .large(HeadlessFiles.LargeOptions(root: "a,b", limit: 5), json: false))
        #expect(HeadlessFiles.resolve("~/x", home: URL(filePath: "/Users/me")).path == "/Users/me/x")
        #expect(HeadlessFiles.resolve(nil, home: URL(filePath: "/Users/me")).path == "/Users/me")
        #expect(HeadlessFiles.resolve("a/../b", home: URL(filePath: "/Users/me"), current: "/tmp/w").path == "/tmp/w/b")
    }

    @Test func spaceAndLargeTextIsReadable() async throws {
        let fixture = try FilesFixture()
        let (code, space) = await Self.run(["space", fixture.home.path, "--limit", "1"], fixture.sources())
        #expect(code == 0 && !space.stdout.contains("\u{1B}["))
        #expect(space.stdout.contains("Media/") && space.stdout.contains("skipped: Needs Full Disk Access"))
        #expect(space.stdout.contains("… 3 more") && space.stdout.contains("no Full Disk Access"))
        #expect(space.stdout.contains("Nothing was deleted"))
        let (_, large) = await Self.run(["large", "--in", fixture.home.path + "/Media", "--min-size", "1MB"], fixture.sources())
        #expect(large.stdout.contains("3 files, ") && large.stdout.contains(" (1 MB or larger) in "))
        #expect(large.stdout.contains("(hard link)") && large.stdout.contains("last used "))
        #expect(large.stdout.contains("/Media/movie.mov") && large.stdout.contains("2 MB"))
        let (_, help) = await Self.run(["--help"], fixture.sources())
        for flag in ["space [PATH]", "--limit", "--min-size", "--older-than", "--in PATH"] { #expect(help.stdout.contains(flag), "\(flag)") }
    }
}
