import Foundation
import Testing
@testable import CleanMate

/// Caches of Zalo, Canva, the new Microsoft Teams and WhatsApp: only folders the app makes again are listed and
/// deleted, never messages, received media, databases, cookies, local storage or sign-in. Everything happens in a
/// throwaway fake home.
final class ChatAppCachesTests {
    private let fm = FileManager.default
    private let root = TestTemp.url("CleanMateChatApps")
    private var home: URL { root.appending(path: "home") }
    private var policy: SafetyPolicy { SafetyPolicy(home: home, temp: root.appending(path: "tmp")) }

    init() throws {
        for dir in ["home", "tmp"] { try fm.createDirectory(at: root.appending(path: dir), withIntermediateDirectories: true) }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func file(_ path: String) throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 20_000).write(to: url)
    }

    private func exists(_ path: String) -> Bool { fm.fileExists(atPath: home.appending(path: path).path) }

    /// Scans then cleans `item`; returns the listed entries relative to the home folder.
    private func scanAndClean(_ item: CleanerItem) async -> [String] {
        let scan = await Scanner.scan(item, policy: policy, openPaths: EndToEndCleanTests.ownOpenPaths)
        _ = await Cleaner.clean(item, scan: scan, policy: policy, openPaths: EndToEndCleanTests.ownOpenPaths)
        guard let real = realpath(home.path, nil) else { return [] }
        defer { free(real) }
        let base = String(cString: real) + "/"
        return scan.entries.map { String($0.url.path.dropFirst(base.count)) }.sorted()
    }

    @Test func itemsAreTickedDeletedAndHiddenWhenEmpty() throws {
        let items = CleanerGroup.applications(hasFullDiskAccess: true).items
        for id in ["zalo", "canva", "teams-new", "whatsapp", "slack", "slack-app-store", "discord", "signal", "notion",
                   "figma", "postman", "obsidian"] {
            let item = try #require(items.first { $0.id == id }, "\(id)")
            #expect(item.selectedByDefault && item.mode == .delete && !item.showsWhenEmpty, "\(id)")
            #expect(item.note != nil && item.about != nil && item.command == nil, "\(id)")
        }
        // Teams and WhatsApp live in their containers: macOS asks without Full Disk Access.
        let withoutAccess = CleanerGroup.applications().items.map(\.id)
        #expect(withoutAccess.contains("zalo") && withoutAccess.contains("canva"))
        #expect(!withoutAccess.contains("teams-new") && !withoutAccess.contains("whatsapp")
                && !withoutAccess.contains("slack-app-store"))
        #expect(withoutAccess.contains("slack") && withoutAccess.contains("obsidian"))
    }

    /// Chromium caches of ZaloData and its partitions, and Zalo's `~/Library/Caches` folder. Messages, received photos
    /// and files (`media`, whose chat folders are also named `Cache`), sign-in and the legacy `ZaloPC` folder stay.
    @Test func zaloListsOnlyCaches() async throws {
        let data = "Library/Application Support/ZaloData"
        try file(data + "/Cache/Cache_Data/data_1")
        try file(data + "/Code Cache/js/a")
        try file(data + "/GPUCache/data_0")
        try file(data + "/DawnGraphiteCache/data_0")
        try file(data + "/Partitions/zalo/Service Worker/CacheStorage/x")
        try file("Library/Caches/com.vng.zalo/Cache.db")
        let kept = [data + "/media/12345/678/Cache/photo.jpg", data + "/media/12345/db/msg.db",
                    data + "/IndexedDB/https_chat.zalo.me_0.indexeddb.leveldb/000003.log",
                    data + "/Local Storage/leveldb/000003.log", data + "/Cookies", data + "/Preferences",
                    data + "/Partitions/zalo/IndexedDB/x", "Library/Application Support/ZaloPC/Cache/x"]
        for path in kept { try file(path) }
        let listed = await scanAndClean(ChatAppCaches.zalo)
        #expect(listed == [data + "/Cache/Cache_Data", data + "/Code Cache/js", data + "/DawnGraphiteCache/data_0",
                           data + "/GPUCache/data_0", data + "/Partitions/zalo/Service Worker/CacheStorage/x",
                           "Library/Caches/com.vng.zalo/Cache.db"])
        for path in listed { #expect(!exists(path), "\(path)") }
        for path in kept { #expect(exists(path), "\(path)") }
    }

    @Test func canvaListsOnlyCaches() async throws {
        let data = "Library/Application Support/Canva"
        try file(data + "/Cache/Cache_Data/data_1")
        try file(data + "/Partitions/canva/Code Cache/js/a")
        try file("Library/Caches/com.canva.CanvaDesktop/Cache.db")
        let kept = [data + "/Local Storage/leveldb/000003.log", data + "/Partitions/canva/Cookies",
                    data + "/Partitions/canva/IndexedDB/x", data + "/Session Storage/000003.log", data + "/config.json"]
        for path in kept { try file(path) }
        let listed = await scanAndClean(ChatAppCaches.canva)
        #expect(listed == [data + "/Cache/Cache_Data", data + "/Partitions/canva/Code Cache/js",
                           "Library/Caches/com.canva.CanvaDesktop/Cache.db"])
        for path in listed { #expect(!exists(path), "\(path)") }
        for path in kept { #expect(exists(path), "\(path)") }
    }

    /// The container's Caches and Logs, and the web view's caches of each profile; cookies, local storage, IndexedDB
    /// and caches the system keeps (`com.apple.nsurlsessiond`) stay.
    @Test func teamsListsOnlyContainerCachesAndLogs() async throws {
        let library = "Library/Containers/com.microsoft.teams2/Data/Library"
        let web = library + "/Application Support/Microsoft/MSTeams/EBWebView"
        try file(library + "/Caches/com.microsoft.teams2/Cache.db")
        try file(library + "/Logs/MSTeams_2026.log")
        try file(web + "/GraphiteDawnCache/data_0")
        try file(web + "/WV2Profile_tfw/Service Worker/CacheStorage/x")
        try file(web + "/WV2Profile_tfw/GPUCache/data_0")
        let kept = [library + "/Caches/com.apple.nsurlsessiond/Downloads/x", web + "/WV2Profile_tfw/Cookies",
                    web + "/WV2Profile_tfw/IndexedDB/x", web + "/WV2Profile_tfw/Local Storage/leveldb/000003.log",
                    library + "/Application Support/Microsoft/MSTeams/app_settings.json"]
        for path in kept { try file(path) }
        let listed = await scanAndClean(ChatAppCaches.teams)
        #expect(listed == [library + "/Caches/com.microsoft.teams2", library + "/Logs/MSTeams_2026.log",
                           web + "/GraphiteDawnCache/data_0", web + "/WV2Profile_tfw/GPUCache/data_0",
                           web + "/WV2Profile_tfw/Service Worker/CacheStorage/x"].sorted())
        for path in listed { #expect(!exists(path), "\(path)") }
        for path in kept { #expect(exists(path), "\(path)") }
    }

    /// Scans and cleans `item` with `caches` and `kept` made under `data`; only `caches` (and `extra`, relative to
    /// the home folder) are listed and deleted.
    private func expectOnlyCaches(_ item: CleanerItem, data: String, caches: [String], kept: [String],
                                  extra: [String] = []) async throws {
        for path in caches { try file(data + "/" + path) }
        for path in extra { try file(path) }
        for path in kept { try file(data + "/" + path) }
        let listed = await scanAndClean(item)
        #expect(!listed.isEmpty, "\(item.id)")
        for path in caches { #expect(!exists(data + "/" + path), "\(item.id) \(path)") }
        for path in extra { #expect(!exists(path), "\(item.id) \(path)") }
        for path in kept { #expect(exists(data + "/" + path), "\(item.id) \(path)") }
        for entry in listed { #expect(!kept.contains { (data + "/" + $0).hasPrefix(entry) }, "\(item.id) \(entry)") }
    }

    /// Slack (downloaded): Chromium caches, partitions and logs; IndexedDB, Local Storage, Cookies, storage stay.
    @Test func slackListsOnlyCachesAndLogs() async throws {
        try await expectOnlyCaches(ChatAppCaches.slack, data: "Library/Application Support/Slack",
            caches: ["Cache/Cache_Data/data_1", "Code Cache/js/a", "GPUCache/data_0", "logs/default/browser.log",
                     "Service Worker/CacheStorage/x", "Partitions/app/Cache/data_1"],
            kept: ["IndexedDB/https_app.slack.com_0.indexeddb.leveldb/000003.log", "Local Storage/leveldb/000003.log",
                   "Cookies", "storage/root-state.json", "Partitions/app/IndexedDB/x", "Preferences"],
            extra: ["Library/Caches/com.tinyspeck.slackmacgap/Cache.db"])
    }

    /// Slack from the App Store: the same folders inside its container, and the container's Caches.
    @Test func slackAppStoreListsOnlyCachesAndLogs() async throws {
        let library = "Library/Containers/com.tinyspeck.slackmacgap/Data/Library"
        try await expectOnlyCaches(ChatAppCaches.slackAppStore, data: library + "/Application Support/Slack",
            caches: ["Cache/Cache_Data/data_1", "Code Cache/js/a", "logs/default/browser.log"],
            kept: ["IndexedDB/x", "Local Storage/leveldb/000003.log", "Cookies", "storage/root-state.json"],
            extra: [library + "/Caches/com.tinyspeck.slackmacgap/Cache.db"])
    }

    /// Discord: the app's modules (`0.0.*/modules`, which hold folders named `Cache` too) stay.
    @Test func discordListsOnlyCaches() async throws {
        try await expectOnlyCaches(ChatAppCaches.discord, data: "Library/Application Support/discord",
            caches: ["Cache/Cache_Data/data_1", "Code Cache/js/a", "GPUCache/data_0", "DawnGraphiteCache/data_0"],
            kept: ["0.0.350/modules/discord_desktop_core/core.asar", "0.0.350/Cache/x", "Local Storage/leveldb/000003.log",
                   "IndexedDB/x", "Cookies", "settings.json"],
            extra: ["Library/Caches/com.hnc.Discord/Cache.db"])
    }

    /// Signal: messages (`sql/db.sqlite`), attachments, the key (`config.json`) and the phone link stay.
    @Test func signalListsOnlyCaches() async throws {
        try await expectOnlyCaches(ChatAppCaches.signal, data: "Library/Application Support/Signal",
            caches: ["Cache/Cache_Data/data_1", "Code Cache/js/a", "GPUCache/data_0"],
            kept: ["sql/db.sqlite", "attachments.noindex/ab/abcdef", "attachments.noindex/Cache/x", "config.json",
                   "IndexedDB/x", "Local Storage/leveldb/000003.log", "ephemeral.json", "logs/app.log"])
    }

    /// Notion: its offline pages database (`notion.db`) and IndexedDB stay.
    @Test func notionListsOnlyCaches() async throws {
        try await expectOnlyCaches(ChatAppCaches.notion, data: "Library/Application Support/Notion",
            caches: ["Cache/Cache_Data/data_1", "Code Cache/js/a", "Partitions/notion/Cache/data_1"],
            kept: ["notion.db", "IndexedDB/x", "Partitions/notion/IndexedDB/x", "Local Storage/leveldb/000003.log",
                   "Cookies"],
            extra: ["Library/Caches/notion.id/Cache.db"])
    }

    /// Figma: caches at the top and in each `DesktopProfile`; its settings and sign-in stay.
    @Test func figmaListsOnlyCaches() async throws {
        try await expectOnlyCaches(ChatAppCaches.figma, data: "Library/Application Support/Figma",
            caches: ["Cache/Cache_Data/data_1", "DesktopProfile/v35/Code Cache/js/a", "DesktopProfile/v35/GPUCache/data_0"],
            kept: ["settings.json", "DesktopProfile/v35/Local Storage/leveldb/000003.log", "DesktopProfile/v35/Cookies",
                   "DesktopProfile/v35/IndexedDB/x"],
            extra: ["Library/Caches/com.figma.Desktop/Cache.db"])
    }

    /// Postman: caches of each user partition and logs; collections (`userPartitionData`, IndexedDB, `storage`) stay.
    @Test func postmanListsOnlyCachesAndLogs() async throws {
        let user = "Partitions/3e2ac323-6701-463f-b2c7-8863614e3d74"
        try await expectOnlyCaches(ChatAppCaches.postman, data: "Library/Application Support/Postman",
            caches: [user + "/Cache/Cache_Data/data_1", user + "/Code Cache/js/a", user + "/GPUCache/data_0",
                     "logs/main.log"],
            kept: [user + "/IndexedDB/x", user + "/userPartitionData/x", user + "/Local Storage/leveldb/000003.log",
                   user + "/Cookies", "storage/x", "Postman_Config/x", "Partitions/postman_user_cookies_x/Cookies"],
            extra: ["Library/Caches/com.postmanlabs.mac/Cache.db"])
    }

    /// Obsidian: the vault list, downloaded app versions and settings stay (vaults are elsewhere).
    @Test func obsidianListsOnlyCaches() async throws {
        try await expectOnlyCaches(ChatAppCaches.obsidian, data: "Library/Application Support/obsidian",
            caches: ["DawnGraphiteCache/data_0", "DawnWebGPUCache/data_0", "Service Worker/CacheStorage/x"],
            kept: ["obsidian.json", "obsidian-1.13.7.asar", "9388526dd4aae1e8.json", "IndexedDB/x",
                   "Local Storage/leveldb/000003.log", "Cookies", "Service Worker/Database/x"],
            extra: ["Library/Caches/md.obsidian/Cache.db"])
    }

    /// Only the container's Caches; chats and media are in the group container, never listed.
    @Test func whatsAppListsOnlyContainerCaches() async throws {
        let library = "Library/Containers/net.whatsapp.WhatsApp/Data/Library"
        let group = "Library/Group Containers/group.net.whatsapp.WhatsApp.shared"
        try file(library + "/Caches/net.whatsapp.WhatsApp/Cache.db")
        let kept = [group + "/ChatStorage.sqlite", group + "/Message/Media/123@s.whatsapp.net/a.jpg",
                    library + "/Application Support/x", library + "/Preferences/net.whatsapp.WhatsApp.plist"]
        for path in kept { try file(path) }
        let listed = await scanAndClean(ChatAppCaches.whatsApp)
        #expect(listed == [library + "/Caches/net.whatsapp.WhatsApp"])
        for path in listed { #expect(!exists(path), "\(path)") }
        for path in kept { #expect(exists(path), "\(path)") }
    }

    /// No size counted twice: "User caches" leaves Zalo's and Canva's folders out, "Sandboxed app caches" the
    /// Teams and WhatsApp containers.
    @Test func otherItemsLeaveTheirFoldersOut() {
        #expect(CleanerGroup.ownedCachePaths.isSuperset(of: ["com.vng.zalo", "com.canva.CanvaDesktop",
            "com.tinyspeck.slackmacgap", "com.hnc.Discord", "org.whispersystems.signal-desktop", "notion.id",
            "com.figma.Desktop", "com.postmanlabs.mac", "md.obsidian"]))
        for container in ["com.microsoft.teams2", "net.whatsapp.WhatsApp", "com.tinyspeck.slackmacgap"] {
            let entry = home.appending(path: "Library/Containers/\(container)/Data/Library/Caches/x")
            #expect(CleanerGroup.skipsSandboxCache(entry, runningApps: []), "\(container)")
        }
    }

    /// Without the app there is nothing to list, and the hidden items show no row.
    @Test func nothingListedWithoutTheApps() async throws {
        try file("Library/Application Support/Google/Chrome/Default/Cache/x")
        for item in ChatAppCaches.all + ChatAppCaches.fullDiskAccess {
            #expect(await Scanner.scan(item, policy: policy, openPaths: EndToEndCleanTests.ownOpenPaths).entries.isEmpty)
        }
    }

    /// Each item is locked while its app, a helper or its process runs; other apps don't lock it.
    @MainActor @Test func lockedWhileTheAppRuns() {
        let model = SmartScanModel.isolated(module: .smartScan) { [] }
        let cases: [(CleanerItem, apps: [String], processes: [String])] = [
            (ChatAppCaches.zalo, ["com.vng.zalo", "com.vng.zalo.helper"], ["Zalo"]),
            (ChatAppCaches.canva, ["com.canva.CanvaDesktop", "com.canva.CanvaDesktop.helper"], ["Canva"]),
            (ChatAppCaches.teams, ["com.microsoft.teams2", "com.microsoft.teams2.notificationcenter"], ["MSTeams"]),
            (ChatAppCaches.whatsApp, ["net.whatsapp.WhatsApp", "net.whatsapp.WhatsApp.ShareExtension"], ["WhatsApp"]),
            (ChatAppCaches.slack, ["com.tinyspeck.slackmacgap", "com.tinyspeck.slackmacgap.helper"], ["Slack"]),
            (ChatAppCaches.slackAppStore, ["com.tinyspeck.slackmacgap"], ["Slack"]),
            (ChatAppCaches.discord, ["com.hnc.Discord", "com.hnc.Discord.helper.Renderer"], ["Discord"]),
            (ChatAppCaches.signal, ["org.whispersystems.signal-desktop", "org.whispersystems.signal-desktop.helper"], ["Signal"]),
            (ChatAppCaches.notion, ["notion.id", "notion.id.helper"], ["Notion"]),
            (ChatAppCaches.figma, ["com.figma.Desktop", "com.figma.Desktop.helper"], ["Figma"]),
            (ChatAppCaches.postman, ["com.postmanlabs.mac", "com.postmanlabs.mac.helper"], ["Postman"]),
            (ChatAppCaches.obsidian, ["md.obsidian", "md.obsidian.helper"], ["Obsidian"]),
        ]
        for (item, apps, processes) in cases {
            model.runningApps = ["com.google.Chrome", "com.apple.finder"]
            model.runningProcesses = ["Google Chrome"]
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
