import Foundation
import Testing
@testable import CleanMate

/// Overview on a throwaway home and activity log; drives are injected (tests can't mount one).
@Suite(.timeLimit(.minutes(2)))
struct OverviewTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "CleanMateOverview-\(UUID().uuidString)")
    var home: URL { root.appending(path: "home") }
    static let now = Date(timeIntervalSince1970: 1_768_478_400) // 2026-01-15 12:00 UTC

    func file(_ path: String, bytes: Int) throws {
        let url = home.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
    }

    @Test func overviewIsTheFirstModule() {
        #expect(Module.allCases.first == .overview)
        #expect(Module.allCases.count == 8) // ⌘1…⌘8
        #expect(Module.allCases.last == .maintenance)
        #expect(Module.overview.badge(hasResults: true, size: 5, files: 5) == nil)
    }

    /// Same 30-day figure as the menu bar (`freed(after:).deleted`); trashed and restored lines don't count; the last
    /// cleanup is the newest run of deleted lines.
    @Test func cleanupsMatchTheMenuBarFigure() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = ActivityLog.cleanups(now: Self.now, home: home)
        #expect(empty == ActivityLog.Cleanups() && empty.lastDate == nil)
        func record(_ size: Int64, _ mode: RemovalMode = .delete, daysAgo: Double, minutes: Double = 0) {
            ActivityLog.record(module: "Smart Scan", item: "c", size: size, mode: mode, home: home,
                               date: Self.now.addingTimeInterval(-daysAgo * 86_400 + minutes * 60))
        }
        record(1_000, daysAgo: 40)
        record(2_000, daysAgo: 10)
        record(50_000, .trash, daysAgo: 2)
        record(300, daysAgo: 1)                  // last cleanup: these three, each ≤ 5 min after the previous
        record(400, daysAgo: 1, minutes: 4)
        record(500, daysAgo: 1, minutes: 8)
        ActivityLog.recordRestored(module: "Smart Scan", item: "c", size: 50_000, home: home, date: Self.now)
        let cleanups = ActivityLog.cleanups(now: Self.now, home: home)
        let menuBar = ActivityLog.freed(after: Self.now.addingTimeInterval(-30 * 86_400), home: home).deleted
        #expect(cleanups.last30Days == menuBar && menuBar == 3_200)
        #expect(cleanups.total == 4_200)
        #expect(cleanups.lastBytes == 1_200)
        let lastDate = try #require(cleanups.lastDate)
        #expect(abs(lastDate.timeIntervalSince(Self.now.addingTimeInterval(-86_400 + 8 * 60))) < 1)
    }

    /// The bar chart's days: the 30 calendar days ending today, oldest first, deleted lines summed per day, 0 on the
    /// others; trashed lines and older days left out. The model hands them on as `freedByDay`.
    @MainActor @Test func freedByDaySumsDeletedLinesPerCalendarDay() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        func record(_ size: Int64, _ mode: RemovalMode = .delete, at date: Date) {
            ActivityLog.record(module: "Smart Scan", item: "c", size: size, mode: mode, home: home, date: date)
        }
        let today = utc.startOfDay(for: Self.now)                          // 2026-01-15 00:00 UTC
        record(9_000, at: today.addingTimeInterval(-31 * 86_400))          // before the first day
        record(1_000, at: today.addingTimeInterval(-29 * 86_400 + 60))     // the first day
        record(200, at: today.addingTimeInterval(-3 * 86_400 + 600))
        record(300, at: today.addingTimeInterval(-3 * 86_400 + 86_000))    // same day, 23:53
        record(70_000, .trash, at: today.addingTimeInterval(-2 * 86_400))
        record(40, at: today.addingTimeInterval(60))                       // today

        let days = ActivityLog.cleanups(now: Self.now, home: home, calendar: utc).byDay
        #expect(days.count == ActivityLog.chartDays)
        #expect(days.first?.date == today.addingTimeInterval(-29 * 86_400) && days.last?.date == today)
        #expect(zip(days, days.dropFirst()).allSatisfy { $1.date.timeIntervalSince($0.date) == 86_400 })
        #expect(days.map(\.bytes).reduce(0, +) == 1_540)
        #expect(days[0].bytes == 1_000 && days[26].bytes == 500 && days[27].bytes == 0 && days[29].bytes == 40)

        let model = OverviewModel(center: NotificationCenter())
        model.home = home
        model.readDisks = { [] }
        model.measure = { _, _, _ in (0, [:]) }
        model.now = { Self.now }
        model.calendar = utc
        model.startIfNeeded()
        model.cancel()
        #expect(model.freedByDay == days)
    }

    @Test func drivesAreTheStartupDiskThenLocalWritableExternalOnes() {
        func info(_ name: String, local: Bool = true, readOnly: Bool = false, backup: Bool = false) -> OverviewModel.MountInfo {
            OverviewModel.MountInfo(volume: .init(name: name, total: 1_000, available: 400), isLocal: local,
                                    isReadOnly: readOnly, isBackup: backup)
        }
        let infos: [String: OverviewModel.MountInfo] = [
            "/Users/me": info("Macintosh HD"),
            "/Volumes/Zeta": info("Zeta"),
            "/Volumes/alpha": info("alpha"),
            "/Volumes/Share": info("Share", local: false),
            "/Volumes/Installer": info("Installer", readOnly: true),
            "/Volumes/Backup": info("Backup", backup: true),
            "/Volumes/Zeta/inner": info("inner"),
            "/Users/me/OrbStack": info("OrbStack"),
        ]
        let mounts = ["/", "/Volumes/Zeta", "/Volumes/alpha", "/Volumes/Share", "/Volumes/Installer", "/Volumes/Backup",
                      "/Volumes/Zeta/inner", "/Users/me/OrbStack", "/Volumes/Gone"].map { URL(fileURLWithPath: $0) }
        let disks = OverviewModel.disks(home: URL(fileURLWithPath: "/Users/me"), mounts: mounts) { infos[$0.path] }
        #expect(disks.map(\.volume.name) == ["Macintosh HD", "alpha", "Zeta"])
        #expect(disks.first?.usedFraction == 0.6)
    }

    @Test func driveOverNinetyPercentUsedIsAlmostFull() {
        #expect(SpaceLensModel.Volume(total: 100, available: 11).level == .normal)
        #expect(SpaceLensModel.Volume(total: 100, available: 9).level == .low)
        #expect(SpaceLensModel.Volume(total: 100, available: 4).level == .critical)
    }

    /// Folders only (hidden ones too), largest first, at most 12; protected folders are left out without Full Disk
    /// Access; Space Lens then lists the home and a folder inside without measuring them again.
    @MainActor @Test func largestFoldersAreMeasuredAndHandedToSpaceLens() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try file("Big/inner/data.bin", bytes: 3_000_000)
        try file(".hidden/data.bin", bytes: 2_000_000)
        try file("Documents/secret.bin", bytes: 9_000_000) // protected: left out without Full Disk Access
        try file("loose.bin", bytes: 5_000_000)           // a file, not a folder
        for index in 0..<13 { try file("small\(index)/f.bin", bytes: 10_000 + index * 4_096) }
        try FileManager.default.createDirectory(at: home.appending(path: "Empty"), withIntermediateDirectories: true)

        let center = NotificationCenter()
        let spaceLens = SpaceLensModel(center: center)
        spaceLens.home = home
        spaceLens.hasFullDiskAccess = { false }
        let calls = Counter()
        spaceLens.measure = { calls.add(); return try await SpaceLens.measure($0, links: $1, skipping: $2) }
        let model = OverviewModel(center: center)
        model.home = home
        model.hasFullDiskAccess = { false }
        model.readDisks = { [] }
        model.spaceLens = spaceLens
        model.startIfNeeded()
        #expect(model.measuring)
        while model.measuring { try await Task.sleep(for: .milliseconds(5)) }

        #expect(model.measured && model.skippedProtected)
        #expect(model.folders.count == OverviewModel.folderLimit)
        #expect(model.folders.prefix(2).map(\.name) == ["Big", ".hidden"])
        #expect(!model.folders.contains { ["Documents", "loose.bin", "Empty"].contains($0.name) })
        #expect(model.folders.map(\.sortSize) == model.folders.map(\.sortSize).sorted(by: >))

        func settle() async throws { while spaceLens.measuring { try await Task.sleep(for: .milliseconds(5)) } }
        spaceLens.start(at: home)
        try await settle()
        #expect(calls.value == 0)
        #expect(spaceLens.items.first { $0.name == "Big" }?.size == model.folders.first?.size)
        spaceLens.open(home.appending(path: "Big"))
        try await settle()
        #expect(calls.value == 0) // Big/inner (≥ 1 MB) remembered too

        // A clean elsewhere: the Overview measures again next time it is shown.
        center.post(name: ActivityLog.didRecord, object: "Smart Scan")
        model.startIfNeeded()
        #expect(model.measuring)
        model.cancel()
        #expect(!model.measuring)
    }

    /// After a clean only the folders holding what was removed are measured again; the others keep their size. A clean
    /// with no paths (a command) measures everything again; skipped items change nothing.
    @MainActor @Test func cleanMeasuresAgainOnlyTheFoldersItTouched() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["A", "B", "C"] { try file("\(name)/data.bin", bytes: 10) }
        let calls = Locked([String: Int]()), sizes = Locked(["A": Int64(3_000), "B": 2_000, "C": 1_000])
        let center = NotificationCenter()
        let model = OverviewModel(center: center)
        model.home = home
        model.hasFullDiskAccess = { true }
        model.readDisks = { [] }
        model.measure = { url, _, _ in
            let name = url.lastPathComponent
            calls.withLock { $0[name, default: 0] += 1 }
            return (sizes.withLock { $0[name] ?? 0 }, [:])
        }
        model.startIfNeeded()
        await until(model) { $0.measured && !$0.measuring }
        #expect(calls.withLock { $0 } == ["A": 1, "B": 1, "C": 1])

        sizes.withLock { $0["B"] = 500 }
        center.post(name: ActivityLog.didRecord, object: "Large & Old Files",
                    userInfo: [ActivityLog.pathsKey: [home.appending(path: "B/data.bin").path]])
        center.post(name: ActivityLog.didRecord, object: "Smart Scan", userInfo: [ActivityLog.pathsKey: [String]()])
        #expect(model.changedFolders == [home.standardizedFileURL.appending(path: "B").path])
        model.startIfNeeded()
        #expect(model.measuring)
        await until(model) { !$0.measuring }
        #expect(calls.withLock { $0 } == ["A": 1, "B": 2, "C": 1])
        #expect(model.folders.map(\.name) == ["A", "C", "B"] && model.folders.map(\.size) == [3_000, 1_000, 500])
        #expect(model.homeSize == 4_500)

        model.startIfNeeded() // nothing removed since: nothing measured
        #expect(!model.measuring && model.changedFolders.isEmpty)

        center.post(name: ActivityLog.didRecord, object: "Smart Scan") // a command: where is not known
        model.startIfNeeded()
        await until(model) { !$0.measuring }
        #expect(calls.withLock { $0 } == ["A": 2, "B": 3, "C": 2])
    }

    /// Stop ends the measure at once: the progress row goes, and the folder walk is cancelled and returns within a second.
    @MainActor @Test func stopEndsTheMeasureWithinASecond() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try file("A/data.bin", bytes: 10)
        let entered = SignalCount(), left = SignalCount()
        let model = OverviewModel(center: NotificationCenter())
        model.home = home
        model.hasFullDiskAccess = { true }
        model.readDisks = { [] }
        model.measure = { _, _, _ in
            entered.add()
            defer { left.add() }
            // A walk that checks for cancellation as `SpaceLens.measure` does, and would otherwise run for minutes.
            for _ in 0..<60_000 {
                try Task.checkCancellation()
                try? await Task.sleep(for: .milliseconds(1))
            }
            return (1, [:])
        }
        model.startIfNeeded()
        await entered.reach(1)
        #expect(model.measuring && model.progress?.total == 1 && model.progress?.current == "A")
        let start = ContinuousClock.now
        model.cancel()
        #expect(!model.measuring && model.progress == nil)
        await left.reach(1)
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    /// Saved sizes come back as written, only for the same home; a missing, damaged or older-format file reads as nil.
    @Test func savedFolderSizesRoundTrip() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "Application Support/CleanMate/home-folders.json")
        #expect(HomeFolderSizes.read(from: file, home: home) == nil)
        let sizes = HomeFolderSizes(home: home.standardizedFileURL.path, date: Self.now,
                                    folders: [.init(name: "Library", size: 9_000), .init(name: ".cache", size: 4_000)],
                                    homeSize: 13_500, skippedProtected: true)
        sizes.write(to: file) // creates the folder
        #expect(HomeFolderSizes.read(from: file, home: home) == sizes)
        #expect(HomeFolderSizes.read(from: file, home: root.appending(path: "other")) == nil)

        try Data("{\"version\":1,\"home\":".utf8).write(to: file)
        #expect(HomeFolderSizes.read(from: file, home: home) == nil)
        var older = sizes
        older.version = HomeFolderSizes.currentVersion + 1
        older.write(to: file)
        #expect(HomeFolderSizes.read(from: file, home: home) == nil)
    }

    /// The sizes saved by the last launch show at once, marked with when they were measured; the new measure then
    /// replaces them and is saved for the next launch.
    @MainActor @Test func savedSizesShowBeforeTheMeasureEnds() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try file("Big/data.bin", bytes: 10)
        try file("Small/data.bin", bytes: 10)
        let sizesFile = root.appending(path: "home-folders.json")
        let measuredAt = Self.now.addingTimeInterval(-86_400)
        HomeFolderSizes(home: home.standardizedFileURL.path, date: measuredAt,
                        folders: [.init(name: "Small", size: 7_000), .init(name: "Big", size: 5_000)],
                        homeSize: 12_000, skippedProtected: false).write(to: sizesFile)

        let gate = Gate()
        let model = OverviewModel(center: NotificationCenter())
        model.home = home
        model.hasFullDiskAccess = { true }
        model.readDisks = { [] }
        model.now = { Self.now }
        model.sizesFile = sizesFile
        model.measure = { url, _, _ in
            while !gate.isOpen { try await Task.sleep(for: .milliseconds(5)) }
            return (url.lastPathComponent == "Big" ? 80_000 : 3_000, [:])
        }
        model.startIfNeeded()
        #expect(model.measuring && !model.measured)
        #expect(model.folders.map(\.name) == ["Small", "Big"] && model.folders.map(\.size) == [7_000, 5_000])
        #expect(model.folders.first?.url.standardizedFileURL.path == home.appending(path: "Small").standardizedFileURL.path)
        #expect(model.homeSize == 12_000 && model.savedSizesDate == measuredAt)

        gate.open()
        while model.measuring { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.folders.map(\.name) == ["Big", "Small"] && model.folders.map(\.size) == [80_000, 3_000])
        #expect(model.savedSizesDate == nil)
        let saved = try #require(HomeFolderSizes.read(from: sizesFile, home: home))
        #expect(saved.date == Self.now && saved.folders.map(\.size) == [80_000, 3_000] && saved.homeSize == 83_000)
    }

    /// A damaged file: nothing shows until the measure ends, as without one, and the file is written again.
    @MainActor @Test func damagedSavedSizesMeasureAsBefore() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try file("Big/data.bin", bytes: 10)
        let sizesFile = root.appending(path: "home-folders.json")
        try Data("not json".utf8).write(to: sizesFile)
        let model = OverviewModel(center: NotificationCenter())
        model.home = home
        model.hasFullDiskAccess = { true }
        model.readDisks = { [] }
        model.sizesFile = sizesFile
        model.measure = { _, _, _ in (4_000, [:]) }
        model.startIfNeeded()
        #expect(model.folders.isEmpty && model.savedSizesDate == nil)
        while model.measuring { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.folders.map(\.size) == [4_000])
        #expect(HomeFolderSizes.read(from: sizesFile, home: home)?.folders.map(\.name) == ["Big"])
    }

    /// The last Smart Scan is read with the drives each time the Overview shows; none under tests by default.
    @MainActor @Test func lastScanIsReadWhenShown() {
        let model = OverviewModel(center: NotificationCenter())
        #expect(model.readLastScan() == nil && model.sizesFile == nil)
        var last: LastScan?
        model.home = home
        model.readDisks = { [] }
        model.measure = { _, _, _ in (0, [:]) }
        model.readLastScan = { last }
        model.startIfNeeded()
        model.cancel()
        #expect(model.lastScan == nil)
        last = LastScan(date: Self.now, size: 5_000, cleaned: 4_000)
        model.startIfNeeded()
        #expect(model.lastScan == last)
    }

    // MARK: Suggestions

    static let gb: Int64 = 1_000_000_000

    /// Apps whose last use was `daysAgo` days before `now`.
    static func app(_ name: String, daysAgo: Double?) -> InstalledApp {
        InstalledApp(url: URL(filePath: "/Applications/\(name).app"), name: name, bundleID: "com.test.\(name)",
                     version: nil, lastUsed: daysAgo.map { now.addingTimeInterval(-$0 * 86_400) })
    }

    /// Trash 1 GB, Docker 5 GB and 3 apps not opened for 90 days: three suggestions, largest first, each opening its
    /// module with the right filter. Without Full Disk Access the external Trash and Downloads are never read.
    @MainActor @Test func trashDockerAndUnusedAppsMakeThreeSuggestions() async throws {
        let protectedReads = Counter()
        var sources = OverviewSuggestions.Sources.none
        sources.trash = { Self.gb }
        sources.docker = { 5 * Self.gb }
        sources.externalTrash = { protectedReads.add(); return 9 * Self.gb }
        sources.downloads = { protectedReads.add(); return (4, 9 * Self.gb) }
        let apps = [Self.app("Old1", daysAgo: 100), Self.app("Old2", daysAgo: 200), Self.app("Old3", daysAgo: 400),
                    Self.app("Recent", daysAgo: 10), Self.app("Undated", daysAgo: nil)]
        let sizes: [URL: Int64] = [apps[0].url: 600_000_000, apps[1].url: 300_000_000]
        sources.appSize = { $0 == apps[2].url ? 100_000_000 : 50 * Self.gb } // only Old3 is not measured yet

        let found = await OverviewSuggestions.read(lastScan: nil, snapshots: LocalSnapshots(count: 0),
                                                   hasFullDiskAccess: false, apps: apps, appSizes: sizes,
                                                   now: Self.now, sources: sources)
        #expect(found.map(\.id) == ["docker", "trash", "unused-apps"])
        #expect(found.map(\.size) == [5 * Self.gb, Self.gb, Self.gb])
        #expect(found[2].count == 3)
        #expect(found.map(\.target) == [.smartScanGroup("developer"), .smartScanGroup("trash"), .uninstallerUnused])
        #expect(found.map(\.target.module) == [.smartScan, .smartScan, .uninstaller])
        #expect(protectedReads.value == 0)

        // The Uninstaller opens on apps unused for 3 months, from every source, largest first, for this session only.
        let keys = [Preferences.uninstallerUnused, Preferences.uninstallerSource, Preferences.uninstallerSort]
        let saved = keys.map { UserDefaults.standard.string(forKey: $0) }
        let uninstaller = UninstallerModel()
        uninstaller.applyFilters(unused: .all, source: .appStore)
        uninstaller.showUnusedSuggestion()
        uninstaller.applyFilters(unused: .all, source: .appStore) // the view reapplies the saved filters
        #expect(uninstaller.unused == .months3 && uninstaller.source == .all && uninstaller.sort(.name) == .size)
        #expect(keys.map { UserDefaults.standard.string(forKey: $0) } == saved)
        uninstaller.suggestedFilter = false
        uninstaller.applyFilters(unused: .all, source: .appStore)
        #expect(uninstaller.unused == .all && uninstaller.source == .appStore && uninstaller.sort(.name) == .name)
        #expect(Suggestion.Target.maintenanceSnapshots.module == .maintenance)
    }

    /// With Full Disk Access the external Trash and old downloads count too; Docker not running adds nothing; the
    /// app list is read when the Uninstaller has not loaded it.
    @Test func fullDiskAccessAddsExternalTrashAndDownloads() async {
        var sources = OverviewSuggestions.Sources.none
        sources.externalTrash = { 2 * Self.gb }
        sources.downloads = { (7, 3 * Self.gb) }
        sources.apps = { [Self.app("Old", daysAgo: 120)] }
        sources.appSize = { _ in 400_000_000 }
        let found = await OverviewSuggestions.read(lastScan: nil, snapshots: nil, hasFullDiskAccess: true, apps: nil,
                                                   appSizes: [:], now: Self.now, sources: sources)
        #expect(found.map(\.id) == ["downloads", "external-trash", "unused-apps"]) // empty Trash (0) left out
        #expect(found[0].count == 7 && found[0].target == .smartScanGroup("system-junk"))
        #expect(found[1].target == .smartScanGroup("trash"))
        #expect(found[2].size == 400_000_000 && found[2].count == 1)
    }

    /// The last Smart Scan's groups count while the scan is under 30 days old; the Trash group is measured live
    /// instead; under 100 MB is left out; at most 5, largest first, snapshots (no size) kept last.
    @Test func lastScanGroupsRankedAndCapped() async throws {
        let groups: [String: Int64] = ["developer": 12 * Self.gb, "system-junk": 3 * Self.gb,
                                       "applications": 2 * Self.gb, "ai-tools": 50_000_000,
                                       "trash": 40 * Self.gb, "unknown-group": 50 * Self.gb]
        let recent = LastScan(date: Self.now.addingTimeInterval(-86_400), size: 0, groups: groups)
        var sources = OverviewSuggestions.Sources.none
        sources.trash = { 4 * Self.gb }
        let found = await OverviewSuggestions.read(lastScan: recent, snapshots: LocalSnapshots(count: 3),
                                                   hasFullDiskAccess: false, apps: [], appSizes: [:],
                                                   now: Self.now, sources: sources)
        #expect(found.count == OverviewSuggestions.limit)
        #expect(found.map(\.id) == ["junk-developer", "trash", "junk-system-junk", "junk-applications", "snapshots"])
        #expect(found[0].target == .smartScanGroup("developer") && found[0].systemImage == "hammer")
        let snapshots = try #require(found.last)
        #expect(snapshots.size == nil && snapshots.count == 3 && snapshots.target == .maintenanceSnapshots)

        let old = LastScan(date: Self.now.addingTimeInterval(-31 * 86_400), size: 0, groups: groups)
        #expect(OverviewSuggestions.junk(old, now: Self.now).isEmpty)
        #expect(OverviewSuggestions.junk(LastScan(date: Self.now, size: 5), now: Self.now).isEmpty) // older record

        let none = await OverviewSuggestions.read(lastScan: nil, snapshots: .unreadable, hasFullDiskAccess: true,
                                                  apps: [], appSizes: [:], now: Self.now, sources: .none)
        #expect(none.isEmpty)
    }

    /// Read in the background when the Overview first shows, not again within 10 minutes, again after; ⌘R and a
    /// clean elsewhere read them at once.
    @MainActor @Test func suggestionsReadAgainAfterTenMinutesOrAClean() async throws {
        let reads = Counter()
        let clock = Locked(Self.now)
        let center = NotificationCenter()
        let model = OverviewModel(center: center)
        model.home = home
        model.readDisks = { [] }
        model.measure = { _, _, _ in (0, [:]) }
        model.now = { clock.withLock { $0 } }
        model.hasFullDiskAccess = { false }
        var sources = OverviewSuggestions.Sources.none
        sources.trash = { reads.add(); return 2 * Self.gb }
        model.suggestionSources = sources
        func settle() async throws { while model.suggesting { try await Task.sleep(for: .milliseconds(5)) } }

        #expect(model.suggestions == nil)
        model.startIfNeeded()
        #expect(model.suggesting)
        try await settle()
        #expect(reads.value == 1 && model.suggestions?.map(\.id) == ["trash"])

        clock.withLock { $0 += 9 * 60 }
        model.startIfNeeded()
        try await settle()
        #expect(reads.value == 1)

        clock.withLock { $0 += 2 * 60 }
        model.startIfNeeded()
        try await settle()
        #expect(reads.value == 2)

        model.refresh()
        try await settle()
        #expect(reads.value == 3)

        center.post(name: ActivityLog.didRecord, object: "Uninstaller")
        model.startIfNeeded()
        try await settle()
        #expect(reads.value == 4)
        model.cancel()
    }

    /// The last scan keeps what each group found and loses what a clean of those results freed.
    @Test func lastScanGroupsRoundTripAndShrinkWhenCleaned() {
        let suite = TestDefaults.suite("CleanMateOverviewTests")
        defer { TestDefaults.remove(suite) }
        guard let defaults = UserDefaults(suiteName: suite) else { Issue.record("no defaults"); return }
        LastScan(date: Self.now, size: 9, groups: ["developer": 5_000, "applications": 700]).save(defaults: defaults)
        #expect(LastScan.read(defaults: defaults)?.groups == ["developer": 5_000, "applications": 700])
        LastScan.recordClean(freed: 1_900, freedByGroup: ["developer": 1_000, "applications": 900, "ai-tools": 5],
                             defaults: defaults)
        let read = LastScan.read(defaults: defaults)
        #expect(read?.groups == ["developer": 4_000, "applications": 0] && read?.cleaned == 1_900)
    }

    /// Smart Scan per group: what was found (exact sizes only, live items left out) and what a clean freed; a
    /// suggestion unfolds its group, clears the search and scans when there are no results.
    @MainActor @Test func smartScanFoundAndFreedPerGroupAndReveal() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let a = CleanerItem(id: "s390.a", title: "A", paths: ["/nonexistent"])
        let b = CleanerItem(id: "s390.b", title: "B", paths: ["/nonexistent"])
        let upTo = CleanerItem(id: "s390.up", title: "Up", paths: ["/nonexistent"], sizeIsUpperBound: true)
        let live = CleanerItem(id: "s390.live", title: "Live", paths: ["/nonexistent"])
        let model = SmartScanModel.isolated(module: .smartScan) {
            [CleanerGroup(id: "g1", title: "G1", systemImage: "x", items: [a, upTo, live]),
             CleanerGroup(id: "g2", title: "G2", systemImage: "x", items: [b])]
        }
        model.processNames = { [] }
        model.appBundleIDs = { [] }
        model.logHome = home // not the real activity log
        let sizes: [String: Int64] = ["s390.a": 100, "s390.b": 30, "s390.up": 500, "s390.live": 7]
        model.scanItem = { item, _ in ItemScan(measuredSize: sizes[item.id] ?? 0) }
        model.collapsedGroups = ["g2"]
        model.search = "zzz"
        #expect(model.foundByGroup().isEmpty)

        model.reveal(group: "g2")
        #expect(model.revealedGroup == nil && model.search.isEmpty && model.collapsedGroups.isEmpty) // after the scan
        for _ in 0..<3000 { if case .results = model.phase { break }; try await Task.sleep(for: .milliseconds(5)) }
        guard case .results = model.phase else { Issue.record("phase \(model.phase)"); return }
        #expect(model.revealedGroup == "g2")
        #expect(model.foundByGroup(leavingOut: ["s390.live"]) == ["g1": 100, "g2": 30])

        model.reveal(group: "g1", measuredAt: .now.addingTimeInterval(-60)) // results newer than the suggestion
        guard case .results = model.phase else { Issue.record("phase \(model.phase)"); return }
        #expect(model.revealedGroup == "g1")

        model.cleanItem = { item, scan, _ in CleanReport(freed: item.id == "s390.b" ? 0 : scan.size) }
        model.selected = ["s390.a", "s390.b", "s390.live"]
        await model.clean()
        #expect(model.freedByGroup() == ["g1": 107])
        #expect(model.freedByGroup(leavingOut: ["s390.live"]) == ["g1": 100])
    }

    /// A suggestion measured after the results shown scans again, then opens its group; a group turned off in
    /// Settings is not scanned: the model asks, and turning it on scans and opens it.
    @MainActor @Test func suggestionRescansOldResultsAndAsksForAGroupTurnedOff() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let a = CleanerItem(id: "s409.a", title: "A", paths: ["/nonexistent"])
        let b = CleanerItem(id: "s409.b", title: "B", paths: ["/nonexistent"])
        let model = SmartScanModel.isolated(module: .smartScan) {
            [CleanerGroup(id: "g1", title: "G1", systemImage: "x", items: [a]),
             CleanerGroup(id: "g2", title: "G2", systemImage: "x", items: [b])]
        }
        var off: Set<String> = ["g2"]
        model.disabledGroups = { off }
        model.enableGroup = { off.remove($0) }
        model.processNames = { [] }
        model.appBundleIDs = { [] }
        model.logHome = home
        let scans = Counter()
        model.scanItem = { _, _ in scans.add(); return ItemScan(measuredSize: 10) }
        let waitForReveal = {
            for _ in 0..<3000 where model.revealedGroup == nil { try await Task.sleep(for: .milliseconds(5)) }
        }

        model.startScan()
        for _ in 0..<3000 { if case .results = model.phase { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(scans.value == 1)
        let first = try #require(model.resultsDate)

        model.reveal(group: "g1", measuredAt: first.addingTimeInterval(30)) // the suggestion is newer
        #expect(model.revealedGroup == nil)
        try await waitForReveal()
        #expect(scans.value == 2 && model.revealedGroup == "g1")

        model.revealedGroup = nil
        model.reveal(group: "g2")
        #expect(model.offGroupAsked == "g2" && model.revealedGroup == nil && scans.value == 2)
        model.turnOnAskedGroup()
        #expect(off.isEmpty && model.offGroupAsked == nil)
        try await waitForReveal()
        #expect(model.revealedGroup == "g2" && scans.value == 4) // both groups scanned again
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}

private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    var isOpen: Bool { lock.withLock { opened } }
    func open() { lock.withLock { opened = true } }
}
