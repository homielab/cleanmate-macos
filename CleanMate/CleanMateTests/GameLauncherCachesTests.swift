import Foundation
import Testing
@testable import CleanMate

/// Steam, Epic Games Launcher, Battle.net and GOG Galaxy caches: only the cache and log folders are emptied (the
/// folders stay), never games, downloads in progress, saves, settings, sign-ins or install manifests, and nothing in
/// ~/Library/Caches or ~/Library/Logs is listed again. Everything happens in a throwaway fake home.
final class GameLauncherCachesTests {
    private let fm = FileManager.default
    private let root = TestTemp.url("CleanMateGameLaunchers")
    private var home: URL { root.appending(path: "home") }
    private var policy: SafetyPolicy { SafetyPolicy(home: home, temp: root.appending(path: "tmp")) }

    init() throws {
        for dir in ["home", "tmp"] { try fm.createDirectory(at: root.appending(path: dir), withIntermediateDirectories: true) }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func file(_ path: String, bytes: Int = 20_000) throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    private func exists(_ path: String) -> Bool { fm.fileExists(atPath: home.appending(path: path).path) }

    /// Scans then cleans `item`; returns the scan and the listed entries relative to the home folder.
    private func scanAndClean(_ item: CleanerItem) async -> (scan: ItemScan, listed: [String]) {
        let scan = await Scanner.scan(item, policy: policy, openPaths: EndToEndCleanTests.ownOpenPaths)
        _ = await Cleaner.clean(item, scan: scan, policy: policy, openPaths: EndToEndCleanTests.ownOpenPaths)
        guard let real = realpath(home.path, nil) else { return (scan, []) }
        defer { free(real) }
        let base = String(cString: real) + "/"
        return (scan, scan.entries.map { String($0.url.path.dropFirst(base.count)) }.sorted())
    }

    @Test func itemsAreTickedDeletedAndHiddenWhenEmpty() async throws {
        let items = CleanerGroup.applications().items
        for id in ["steam-cache", "epic-games-cache", "battlenet-cache", "gog-galaxy-cache"] {
            let item = try #require(items.first { $0.id == id }, "\(id)")
            #expect(item.selectedByDefault && item.mode == .delete && !item.showsWhenEmpty && item.note != nil, "\(id)")
            #expect(item.skipsOpenFiles && item.command == nil && item.minAge == nil, "\(id)")
            // The row's icon is the first bundle id that resolves to an app: an exact one.
            #expect(item.runningAppBundleIDs.first?.hasSuffix("*") == false, "\(id)")
            #expect(await Scanner.scan(item, policy: policy, openPaths: EndToEndCleanTests.ownOpenPaths).entries.isEmpty)
        }
    }

    /// Never under ~/Library/Caches or ~/Library/Logs: "User caches" and "User logs" own those, so nothing is counted
    /// twice, and the launchers' folders there stay out of `ownedCachePaths`.
    @Test func nothingIsCountedTwiceWithUserCachesAndLogs() async throws {
        for item in GameLauncherCaches.all {
            for path in item.paths {
                #expect(path.hasPrefix("~/Library/Application Support/"), "\(item.id) \(path)")
            }
        }
        #expect(!CleanerGroup.ownedCachePaths.contains { $0.contains("epicgames") || $0.contains("valvesoftware") })
        try file("Library/Caches/com.epicgames.EpicGamesLauncher/webcache/c")
        try file("Library/Caches/com.valvesoftware.steam/c")
        try file("Library/Logs/Unreal Engine/EpicGamesLauncher/EpicGamesLauncher.log")
        for item in GameLauncherCaches.all {
            let scan = await Scanner.scan(item, policy: policy, openPaths: EndToEndCleanTests.ownOpenPaths)
            #expect(scan.entries.isEmpty, "\(item.id)")
        }
        let userCaches = try #require(CleanerGroup.smartScan(ages: .default).flatMap(\.items).first { $0.id == "user-caches" })
        let scan = await Scanner.scan(userCaches, policy: policy, openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(scan.entries.map(\.url.lastPathComponent).sorted() == ["com.epicgames.EpicGamesLauncher", "com.valvesoftware.steam"])
    }

    @Test func steamEmptiesOnlyItsCaches() async throws {
        let steam = "Library/Application Support/Steam"
        let caches = [
            steam + "/htmlcache/Cache/data_0", steam + "/config/htmlcache/Code Cache/js/a",
            steam + "/appcache/httpcache/00/abc", steam + "/appcache/librarycache/440/header.jpg",
            steam + "/depotcache/441_123.manifest", steam + "/logs/content_log.txt", steam + "/dumps/crash_1.dmp",
            steam + "/steamapps/shadercache/440/fozpipelinesv6/steam_pipeline_cache.foz",
        ]
        let kept = [
            steam + "/steamapps/common/Team Fortress 2/hl2_osx", steam + "/steamapps/appmanifest_440.acf",
            steam + "/steamapps/libraryfolders.vdf", steam + "/steamapps/downloading/440/state.bin",
            steam + "/steamapps/workshop/content/440/1/item.vpk", steam + "/userdata/123/440/remote/save.dat",
            steam + "/userdata/123/config/grid/440p.png", steam + "/config/config.vdf",
            steam + "/config/loginusers.vdf", steam + "/ssfn1234567890", steam + "/appcache/appinfo.vdf",
            steam + "/appcache/packageinfo.vdf", steam + "/registry.vdf",
            steam + "/Steam.AppBundle/Steam/Contents/MacOS/steam_osx",
        ]
        for path in caches { try file(path, bytes: 100_000) }
        for path in kept { try file(path) }
        let (scan, listed) = await scanAndClean(GameLauncherCaches.steam)
        #expect(listed == [
            steam + "/appcache/httpcache/00", steam + "/appcache/librarycache/440", steam + "/config/htmlcache/Code Cache",
            steam + "/depotcache/441_123.manifest", steam + "/dumps/crash_1.dmp", steam + "/htmlcache/Cache",
            steam + "/logs/content_log.txt", steam + "/steamapps/shadercache/440",
        ])
        #expect(scan.size >= 800_000 && scan.size < 1_000_000)
        for path in caches { #expect(!exists(path), "\(path)") }
        for path in kept { #expect(exists(path), "\(path)") }
        for folder in ["htmlcache", "config/htmlcache", "appcache/httpcache", "appcache/librarycache", "depotcache", "logs",
                       "dumps", "steamapps/shadercache"] {
            #expect(exists(steam + "/" + folder), "the folder itself stays: \(folder)")
        }
    }

    @Test func epicEmptiesOnlyWebCachesAndLogs() async throws {
        let epic = "Library/Application Support/Epic/EpicGamesLauncher"
        let caches = [epic + "/Saved/webcache/Cache/data_1", epic + "/Saved/webcache_4430/GPUCache/data_0",
                      epic + "/Saved/Logs/EpicGamesLauncher.log"]
        let kept = [epic + "/Saved/Config/Mac/GameUserSettings.ini", epic + "/Data/Manifests/ABC123.item",
                    epic + "/Saved/Data/x.dat", "Library/Application Support/Epic/UnrealEngine/5.4/Saved/Config/x.ini"]
        for path in caches + kept { try file(path) }
        let (_, listed) = await scanAndClean(GameLauncherCaches.epic)
        #expect(listed == [epic + "/Saved/Logs/EpicGamesLauncher.log", epic + "/Saved/webcache/Cache",
                           epic + "/Saved/webcache_4430/GPUCache"])
        for path in caches { #expect(!exists(path), "\(path)") }
        for path in kept { #expect(exists(path), "\(path)") }
        #expect(exists(epic + "/Saved/webcache") && exists(epic + "/Saved/Logs"))
    }

    @Test func battleNetAndGOGEmptyOnlyTheirCaches() async throws {
        let battle = "Library/Application Support/Battle.net"
        let gog = "Library/Application Support/GOG.com/Galaxy"
        try file(battle + "/BrowserCaches/common/Cache/data_0")
        try file(battle + "/Cache/c.idx")
        try file(battle + "/Logs/Battle.net-20261101.log")
        try file(gog + "/webcache/Cache/data_0")
        let kept = [battle + "/Battle.net.config", battle + "/12345.config", battle + "/Agent/product.db",
                    "Library/Application Support/Blizzard/StarCraft II/Variables.txt",
                    gog + "/plugins/installed/steam_x/manifest.json", gog + "/Storage/galaxy-2.0.db"]
        for path in kept { try file(path) }
        let battleListed = await scanAndClean(GameLauncherCaches.battleNet).listed
        #expect(battleListed == [battle + "/BrowserCaches/common", battle + "/Cache/c.idx",
                                 battle + "/Logs/Battle.net-20261101.log"])
        let gogListed = await scanAndClean(GameLauncherCaches.gogGalaxy).listed
        #expect(gogListed == [gog + "/webcache/Cache"])
        for path in battleListed + gogListed { #expect(!exists(path), "\(path)") }
        for path in kept { #expect(exists(path), "\(path)") }
    }

    @MainActor @Test func lockedWhileTheLauncherRuns() {
        let model = SmartScanModel.isolated(module: .smartScan) { [] }
        let cases: [(CleanerItem, apps: [String], processes: [String])] = [
            (GameLauncherCaches.steam, ["com.valvesoftware.steam", "com.valvesoftware.steam.helper"],
             ["steam_osx", "Steam Helper", "Steam Helper (Renderer)", "steamwebhelper"]),
            (GameLauncherCaches.epic, ["com.epicgames.EpicGamesLauncher"], ["EpicGamesLauncher", "EpicWebHelper"]),
            (GameLauncherCaches.battleNet, ["net.battle.app"], ["Battle.net", "Battle.net Helper"]),
            (GameLauncherCaches.gogGalaxy, ["com.gog.galaxy"], ["GOG Galaxy", "GOG Galaxy Helper"]),
        ]
        for (item, apps, processes) in cases {
            // A game, another Valve or Epic app, or Unreal Editor does not lock the launcher's caches.
            model.runningApps = ["com.valvesoftware.portal2", "com.epicgames.UnrealEditor", "com.apple.finder"]
            model.runningProcesses = ["Portal 2", "UnrealEditor", "Google Chrome"]
            #expect(!model.isLocked(item), "\(item.id)")
            for app in apps {
                model.runningApps = [app]
                #expect(model.isLocked(item), "\(item.id) \(app)")
            }
            model.runningApps = []
            for process in processes {
                model.runningProcesses = [process]
                #expect(model.isLocked(item), "\(item.id) \(process)")
            }
            model.runningProcesses = []
        }
    }
}
