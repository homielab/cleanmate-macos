import Foundation
import Testing
@testable import CleanMate

/// `cleanmate uninstall`, `cleanmate privacy` and `cleanmate login-items` in a fake home with fake apps, a fake Trash
/// and a fake launchctl: never /Applications, the real Trash or the real launch agents. Only what is named moves, an
/// open app or a running browser is left with the reason, and what moves can be put back.
struct CommandLineModulesTests {
    typealias Fixture = CommandLineToolTests.Fixture

    /// launchctl calls, answered with success.
    final class Launchctl: Sendable {
        let calls = Locked<[[String]]>([])
        var runner: LaunchAgents.Runner {
            { arguments in
                self.calls.withLock { $0.append(arguments) }
                return true
            }
        }
        var recorded: [[String]] { calls.withLock { $0 } }
    }

    /// Fake apps in the fake home's Applications, their data and the data of a removed app.
    final class Apps {
        let fixture: Fixture
        let launchctl = Launchctl()
        /// Set to make the "running" app quit.
        let quit = Locked(false)
        var home: URL { fixture.home }

        init() throws {
            fixture = try Fixture()
            try app("Fake", id: "com.example.fake", bytes: 8_192)
            try app("Running App", id: "com.example.running", bytes: 4_096)
            try file("Library/Application Support/com.example.fake/state.bin", 12_288)
            try file("Library/Preferences/com.example.fake.plist", 4_096)
            try file("Library/Caches/com.example.running/cache.bin", 4_096)
            try file("Library/Caches/org.oldvendor.gone/old.bin", 16_384)
        }

        @discardableResult
        func app(_ name: String, id: String, bytes: Int, appStore: Bool = false) throws -> URL {
            let url = home.appending(path: "Applications/\(name).app")
            let plist = ["CFBundleIdentifier": id, "CFBundleShortVersionString": "1.0", "CFBundlePackageType": "APPL"]
            try FileManager.default.createDirectory(at: url.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: url.appending(path: "Contents/Info.plist"))
            try Data(repeating: 1, count: bytes).write(to: url.appending(path: "Contents/MacOS/\(name)"))
            if appStore {
                try FileManager.default.createDirectory(at: url.appending(path: "Contents/_MASReceipt"), withIntermediateDirectories: true)
                try Data(repeating: 2, count: 64).write(to: url.appending(path: "Contents/_MASReceipt/receipt"))
            }
            return url
        }

        func file(_ path: String, _ bytes: Int) throws {
            let url = home.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 7, count: bytes).write(to: url)
        }

        func exists(_ path: String) -> Bool { fixture.exists(path) }

        func sources(refusesApps: Bool = false) -> HeadlessScan.Sources {
            var sources = fixture.sources(fullDiskAccess: true)
            let applications = home.appending(path: "Applications"), quit = quit, trash = fixture.trash
            sources.installedApps = { await Uninstaller.installedApps(policy: $0, folders: [applications]) }
            sources.isRegistered = { _ in false }
            sources.runningApps = { quit.withLock { $0 } ? [:] : ["com.example.running": "Running App"] }
            sources.quitApp = { _ in }
            sources.quitTimeout = .milliseconds(300)
            sources.launchctl = launchctl.runner
            sources.trash = { url in
                // An App Store app owned by root: the move is refused.
                if refusesApps && url.pathExtension == "app" { throw CocoaError(.fileWriteNoPermission) }
                let target = trash.appending(path: url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: target)
                return target
            }
            return sources
        }
    }

    static func run(_ arguments: [String], _ sources: HeadlessScan.Sources, answer: String? = nil) async
        -> (Int32, CommandLineToolTests.Printed) {
        await CommandLineToolTests.run(arguments, sources, answer: answer)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ printed: CommandLineToolTests.Printed) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(printed.stdout.utf8))
    }

    // MARK: - uninstall

    @Test func uninstallListsAppsWithSizesAndLeftovers() async throws {
        let apps = try Apps()
        let (code, printed) = await Self.run(["uninstall", "--json"], apps.sources())
        try #require(code == 0, "\(printed.stderr)")
        let report = try Self.decode(HeadlessApps.ListReport.self, printed)
        #expect(report.version == "9.9" && report.fullDiskAccess && report.durationMs >= 0)
        #expect(report.apps.map(\.name) == ["Fake", "Running App"])
        let fake = try #require(report.apps.first)
        #expect(fake.bundleId == "com.example.fake" && fake.source == "downloaded" && fake.version == "1.0" && !fake.running)
        #expect(fake.path.hasSuffix("/Applications/Fake.app") && fake.path.hasPrefix("/"))
        #expect(fake.size >= 8_192 && fake.dataSize == 12_288 + 4_096)
        #expect(report.apps[1].running && report.apps[1].dataSize == 4_096)
        let gone = try #require(report.leftovers.first { $0.path == "~/Library/Caches/org.oldvendor.gone" })
        #expect(gone.size == 16_384 && gone.kind == "data")
        #expect(!report.leftovers.contains { $0.path.contains("com.example.fake") || $0.path.contains("com.example.running") })
        #expect(report.leftoversSize == report.leftovers.reduce(0) { $0 + $1.size })
        // The JSON always has lastUsed, null or a date.
        let raw = try #require(JSONSerialization.jsonObject(with: Data(printed.stdout.utf8)) as? [String: Any])
        #expect((raw["apps"] as? [[String: Any]])?.allSatisfy { $0.keys.contains("lastUsed") } == true)

        // --leftovers lists only the leftovers; text lists both. Read-only: nothing moved, nothing logged.
        let (_, leftovers) = await Self.run(["uninstall", "--leftovers", "--json"], apps.sources())
        let only = try Self.decode(HeadlessApps.ListReport.self, leftovers)
        #expect(only.apps.isEmpty && only.leftovers == report.leftovers)
        let (_, text) = await Self.run(["uninstall"], apps.sources())
        #expect(text.stdout.contains("com.example.fake") && text.stdout.contains("Downloaded")
                && text.stdout.contains("~/Library/Caches/org.oldvendor.gone") && text.stdout.contains("open"))
        #expect(apps.exists("Applications/Fake.app") && apps.fixture.inTrash.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: ActivityLog.url(home: apps.home).path))
    }

    @Test func uninstallMovesTheAppAndItsDataToTheTrashAndRestorePutsThemBack() async throws {
        let apps = try Apps()
        // A dry run moves nothing and logs nothing.
        let (dryCode, dry) = await Self.run(["uninstall", "--dry-run", "--json", "fake"], apps.sources())
        try #require(dryCode == 0, "\(dry.stderr)")
        let plan = try Self.decode(HeadlessApps.UninstallReport.self, dry)
        #expect(plan.dryRun && plan.log == nil && plan.count == 3 && plan.items.allSatisfy { $0.trashed == nil })
        #expect(apps.exists("Applications/Fake.app") && apps.fixture.inTrash.isEmpty)

        let (code, printed) = await Self.run(["uninstall", "--yes", "--json", "com.example.fake"], apps.sources())
        try #require(code == 0, "\(printed.stderr)")
        let report = try Self.decode(HeadlessApps.UninstallReport.self, printed)
        #expect(!report.dryRun && report.app?.bundleId == "com.example.fake" && report.count == 3)
        #expect(report.items.map(\.kind) == ["app", "data", "data"] && report.items.allSatisfy { !$0.skipped })
        #expect(Set(report.items.map(\.path)) == ["~/Applications/Fake.app", "~/Library/Application Support/com.example.fake",
                                                    "~/Library/Preferences/com.example.fake.plist"])
        #expect(report.size == report.items.reduce(0) { $0 + $1.size } && report.durationMs >= 0)
        #expect(report.log == "~/Library/Logs/CleanMate/activity.log")
        #expect(Set(apps.fixture.inTrash) == ["Fake.app", "com.example.fake", "com.example.fake.plist"])
        #expect(!apps.exists("Applications/Fake.app") && !apps.exists("Library/Preferences/com.example.fake.plist"))
        // The running app and the removed app's leftovers stay.
        #expect(apps.exists("Applications/Running App.app") && apps.exists("Library/Caches/org.oldvendor.gone/old.bin"))

        // Recorded like the app's Uninstaller, so `cleanmate restore` puts everything back.
        let records = TrashRecords.inTrash(home: apps.home)
        #expect(records.count == 3 && records.allSatisfy { $0.moduleName == "Uninstaller" })
        let trashed = report.items.compactMap(\.trashed)
        #expect(Set(trashed) == Set(records.map(\.trashed)))
        let restored = try await CommandLineToolTests.restoreReport(trashed, apps.sources())
        #expect(restored.count == 3)
        #expect(apps.exists("Applications/Fake.app/Contents/Info.plist") && apps.exists("Library/Preferences/com.example.fake.plist")
                && apps.exists("Library/Application Support/com.example.fake/state.bin"))
    }

    @Test func leftoversOnlyKeepsTheApp() async throws {
        let apps = try Apps()
        let (code, printed) = await Self.run(["uninstall", "--leftovers-only", "--yes", "--json", "Fake.app"], apps.sources())
        try #require(code == 0, "\(printed.stderr)")
        let report = try Self.decode(HeadlessApps.UninstallReport.self, printed)
        #expect(report.count == 2 && !report.items.contains { $0.kind == "app" })
        #expect(apps.exists("Applications/Fake.app") && !apps.exists("Library/Preferences/com.example.fake.plist"))
    }

    @Test func anOpenAppIsNeverMovedAndHasItsOwnExitCode() async throws {
        let apps = try Apps()
        let (code, printed) = await Self.run(["uninstall", "--yes", "--json", "Running", "App"], apps.sources())
        #expect(code == CommandLineTool.Exit.appRunning.rawValue && code == 5)
        #expect(printed.stdout.isEmpty && printed.stderr.contains("is open") && printed.stderr.contains("--quit"))
        #expect(printed.stderr.contains("Nothing was moved"))
        // --quit: still open after the wait → the same code, nothing moved.
        let (stillOpen, notQuit) = await Self.run(["uninstall", "--yes", "--quit", "com.example.running"], apps.sources())
        #expect(stillOpen == 5 && notQuit.stderr.contains("did not quit"))
        #expect(apps.exists("Applications/Running App.app") && apps.exists("Library/Caches/com.example.running/cache.bin"))
        #expect(apps.fixture.inTrash.isEmpty && TrashRecords.inTrash(home: apps.home).isEmpty)

        // It quits when asked: then it goes.
        var sources = apps.sources()
        let quit = apps.quit
        sources.quitApp = { id in if id == "com.example.running" { quit.withLock { $0 = true } } }
        let (quitCode, quitPrinted) = await Self.run(["uninstall", "--yes", "--quit", "--json", "Running App"], sources)
        try #require(quitCode == 0, "\(quitPrinted.stderr)")
        #expect(!apps.exists("Applications/Running App.app") && apps.fixture.inTrash.contains("Running App.app"))
    }

    @Test func anAppStoreAppIsLeftWithoutAPasswordPrompt() async throws {
        let apps = try Apps()
        try apps.app("Store", id: "com.example.store", bytes: 4_096, appStore: true)
        let (code, printed) = await Self.run(["uninstall", "--yes", "Store"], apps.sources(refusesApps: true))
        #expect(code == 1 && printed.stderr.contains("App Store") && printed.stderr.contains("Nothing was moved"))
        #expect(apps.exists("Applications/Store.app") && apps.fixture.inTrash.isEmpty)
    }

    @Test func uninstallAsksOrNeedsYesAndNamesAnApp() async throws {
        let apps = try Apps()
        let (noYes, refused) = await Self.run(["uninstall", "Fake"], apps.sources())
        #expect(noYes == 4 && refused.stderr.contains("--yes") && apps.exists("Applications/Fake.app"))
        let (declined, asked) = await Self.run(["uninstall", "Fake"], apps.sources(), answer: "n")
        #expect(declined == 0 && asked.stderr.contains("Proceed? [y/N]") && asked.stderr.contains("Nothing was moved"))
        #expect(apps.exists("Applications/Fake.app"))
        let (missing, unknown) = await Self.run(["uninstall", "--yes", "Nope"], apps.sources())
        #expect(missing == 2 && unknown.stderr.contains("no app `Nope`"))
        for arguments in [["uninstall", "--yes"], ["uninstall", "--quit"], ["uninstall", "--leftovers", "--quit"], ["uninstall", "--bogus"]] {
            let (usage, _) = await Self.run(arguments, apps.sources())
            #expect(usage == 2, "\(arguments)")
        }
    }

    @Test func removingLeftoversTakesOnlyListedOnes() async throws {
        let apps = try Apps()
        let (code, printed) = await Self.run(["uninstall", "--leftovers", "--yes", "--json", "~/Library/Caches/org.oldvendor.gone",
                                              "~/Library/Preferences/com.example.fake.plist"], apps.sources())
        try #require(code == 0, "\(printed.stderr)")
        let report = try Self.decode(HeadlessApps.UninstallReport.self, printed)
        #expect(report.app == nil && report.count == 1 && report.items.count == 2)
        #expect(report.items[1].skipped && report.items[1].reason == HeadlessApps.notLeftover)
        #expect(!apps.exists("Library/Caches/org.oldvendor.gone") && apps.exists("Library/Preferences/com.example.fake.plist"))
        #expect(TrashRecords.inTrash(home: apps.home).map(\.moduleName) == ["Uninstaller"])
    }

    // MARK: - privacy

    /// A browser whose app runs (its cookies are skipped) and one that doesn't.
    static func privacySources(_ fixture: Fixture) throws -> HeadlessScan.Sources {
        for path in ["Library/Caches/cli-cookies/c.bin", "Library/Caches/cli-other-cookies/c.bin"] {
            let url = fixture.home.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 3, count: 8_192).write(to: url)
        }
        let cookies = CleanerItem(id: "test-cookies", title: "Cookies", note: "Signs you out of websites",
                                  paths: ["~/Library/Caches/cli-cookies"], runningAppBundleIDs: ["com.example.running"])
        let other = CleanerItem(id: "other-cookies", title: "Cookies", paths: ["~/Library/Caches/cli-other-cookies"],
                                selectedByDefault: false)
        let groups = fixture.privacy + [CleanerGroup(id: "privacy-running", title: "Running Browser", systemImage: "x", items: [cookies]),
                                        CleanerGroup(id: "privacy-other", title: "Other Browser", systemImage: "x", items: [other])]
        var sources = fixture.sources(fullDiskAccess: true)
        sources.privacy = { groups }
        return sources
    }

    @Test func privacyListsTheItemsAndMarksARunningBrowserSkipped() async throws {
        let fixture = try Fixture()
        let sources = try Self.privacySources(fixture)
        let (code, printed) = await Self.run(["privacy", "--json"], sources)
        try #require(code == 0, "\(printed.stderr)")
        let report = try Self.decode(HeadlessPrivacy.Report.self, printed)
        #expect(report.items.map(\.id) == ["cli-history", "test-cookies", "other-cookies"] && report.durationMs >= 0)
        #expect(report.items.map(\.browser) == ["Browser", "Running Browser", "Other Browser"])
        let running = report.items[1]
        #expect(running.skipped && running.reason == "Running App is running" && running.signsOut && running.size == 8_192)
        #expect(!report.items[0].skipped && report.items[0].size == 4_096 && !report.items[0].signsOut)
        #expect(report.total == 4_096) // ticked and not skipped
        let (_, text) = await Self.run(["privacy"], sources)
        #expect(text.stdout.contains("skipped: Running App is running") && text.stdout.contains("Running Browser"))
        // Read-only.
        #expect(fixture.exists("Library/Caches/cli-history/f.bin") && fixture.exists("Library/Caches/cli-cookies/c.bin"))
    }

    @Test func eraseSkipsARunningBrowserAndSaysSo() async throws {
        let fixture = try Fixture()
        let sources = try Self.privacySources(fixture)
        let (code, printed) = await Self.run(["privacy", "--erase", "--yes", "--json", "cli-history", "test-cookies"], sources)
        try #require(code == 0, "\(printed.stderr)")
        let report = try Self.decode(HeadlessClean.Report.self, printed)
        #expect(report.durationMs != nil && !report.dryRun)
        let cookies = try #require(report.items.first { $0.id == "test-cookies" })
        #expect(cookies.locked && cookies.reason == "Running App is running" && cookies.freed == 0)
        #expect(report.items.first { $0.id == "cli-history" }?.freed == 4_096)
        #expect(!fixture.exists("Library/Caches/cli-history/f.bin") && fixture.exists("Library/Caches/cli-cookies/c.bin"))
        #expect(ActivityLog.read(home: fixture.home).contains("\tPrivacy\tBrowsing history\t"))

        // Cookies that do go: the app's warning, before (terminal) or alongside (--yes).
        let (declined, asked) = await Self.run(["privacy", "--erase", "other-cookies"], sources, answer: "no")
        #expect(declined == 0 && asked.stderr.contains(HeadlessPrivacy.cookieWarning) && asked.stderr.contains("Nothing was erased"))
        #expect(fixture.exists("Library/Caches/cli-other-cookies/c.bin"))
        let (erased, warned) = await Self.run(["privacy", "--erase", "--yes", "other-cookies"], sources)
        #expect(erased == 0 && warned.stderr.contains(HeadlessPrivacy.cookieWarning) && !fixture.exists("Library/Caches/cli-other-cookies/c.bin"))
    }

    @Test func eraseNeedsYesAndPrivacyIDs() async throws {
        let fixture = try Fixture()
        let sources = try Self.privacySources(fixture)
        let (noYes, refused) = await Self.run(["privacy", "--erase", "cli-history"], sources)
        #expect(noYes == 4 && refused.stderr.contains("--yes"))
        for ids in [["cli-caches"], ["nope"]] {
            let (code, printed) = await Self.run(["privacy", "--erase", "--yes"] + ids, sources)
            #expect(code == 2 && printed.stderr.contains("not a Privacy item"), "\(ids)")
        }
        #expect(fixture.exists("Library/Caches/cli-history/f.bin") && fixture.exists("Library/Caches/cli-junk/a.bin"))
        let (dryCode, dry) = await Self.run(["privacy", "--erase", "--dry-run", "--json"], sources)
        // Without ids: the items ticked in the app (not the unticked other-cookies, not the skipped one).
        let plan = try Self.decode(HeadlessClean.Report.self, dry)
        #expect(dryCode == 0 && plan.dryRun && plan.freed == 4_096 && !plan.items.contains { $0.id == "other-cookies" })
        #expect(fixture.exists("Library/Caches/cli-history/f.bin"))
    }

    // MARK: - login-items

    @Test func loginItemsRemoveThenRestoreGivesBackTheSameFile() async throws {
        let apps = try Apps()
        let folder = apps.home.appending(path: "Library/LaunchAgents")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let plist = folder.appending(path: "com.example.agent.plist")
        let contents = try PropertyListSerialization.data(
            fromPropertyList: ["Label": "com.example.agent", "ProgramArguments": ["/usr/bin/true", "--flag"], "RunAtLoad": true],
            format: .xml, options: 0)
        try contents.write(to: plist)
        var sources = apps.sources()
        sources.loginItems = { policy in
            await LaunchAgents.scan(appForID: { _ in nil }, policy: policy, scopes: [.user], read: { _ in "" })
        }

        let (listCode, listed) = await Self.run(["login-items", "--json"], sources)
        try #require(listCode == 0, "\(listed.stderr)")
        let list = try Self.decode(HeadlessLoginItems.ListReport.self, listed)
        let item = try #require(list.items.first { $0.label == "com.example.agent" })
        #expect(item.scope == "user" && item.removable && item.program == "/usr/bin/true" && item.state == "not-loaded")
        #expect(list.durationMs >= 0 && list.count == list.items.count)

        let (noYes, _) = await Self.run(["login-items", "remove", "com.example.agent"], sources)
        #expect(noYes == 4 && FileManager.default.fileExists(atPath: plist.path))
        let (removeCode, removed) = await Self.run(["login-items", "remove", "--yes", "--json", "com.example.agent"], sources)
        try #require(removeCode == 0, "\(removed.stderr)")
        let removal = try Self.decode(HeadlessLoginItems.ActionReport.self, removed)
        #expect(removal.action == "remove" && !removal.skipped && removal.path == "~/Library/LaunchAgents/com.example.agent.plist")
        #expect(removal.trashed == apps.fixture.trash.appending(path: "com.example.agent.plist").path)
        #expect(!FileManager.default.fileExists(atPath: plist.path))
        #expect(apps.launchctl.recorded.contains(["bootout", "gui/\(getuid())/com.example.agent"]))
        #expect(TrashRecords.inTrash(home: apps.home).map(\.moduleName) == ["Login Items"])

        let (restoreCode, restored) = await Self.run(["login-items", "restore", "--json", "com.example.agent"], sources)
        try #require(restoreCode == 0, "\(restored.stderr)")
        let restore = try Self.decode(HeadlessLoginItems.ActionReport.self, restored)
        #expect(restore.action == "restore" && !restore.skipped && restore.label == "com.example.agent")
        #expect(try Data(contentsOf: plist) == contents)
        #expect(apps.launchctl.recorded.last == ["bootstrap", "gui/\(getuid())", plist.path])
        #expect(TrashRecords.inTrash(home: apps.home).isEmpty)

        // Nothing left in the Trash to put back; no such item to remove.
        let (again, _) = await Self.run(["login-items", "restore", "com.example.agent"], sources)
        #expect(again == 1)
        let (unknown, _) = await Self.run(["login-items", "remove", "--yes", "com.example.none"], sources)
        #expect(unknown == 2)
    }
}
