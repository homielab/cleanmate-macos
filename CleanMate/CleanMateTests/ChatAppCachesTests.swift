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
        for id in ["zalo", "canva", "teams-new", "whatsapp"] {
            let item = try #require(items.first { $0.id == id }, "\(id)")
            #expect(item.selectedByDefault && item.mode == .delete && !item.showsWhenEmpty, "\(id)")
            #expect(item.note != nil && item.about != nil && item.command == nil, "\(id)")
        }
        // Teams and WhatsApp live in their containers: macOS asks without Full Disk Access.
        let withoutAccess = CleanerGroup.applications().items.map(\.id)
        #expect(withoutAccess.contains("zalo") && withoutAccess.contains("canva"))
        #expect(!withoutAccess.contains("teams-new") && !withoutAccess.contains("whatsapp"))
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
        #expect(CleanerGroup.ownedCachePaths.isSuperset(of: ["com.vng.zalo", "com.canva.CanvaDesktop"]))
        for container in ["com.microsoft.teams2", "net.whatsapp.WhatsApp"] {
            let entry = home.appending(path: "Library/Containers/\(container)/Data/Library/Caches/x")
            #expect(CleanerGroup.skipsSandboxCache(entry, runningApps: []), "\(container)")
        }
    }

    /// Without the app there is nothing to list, and the hidden items show no row.
    @Test func nothingListedWithoutTheApps() async throws {
        try file("Library/Application Support/Google/Chrome/Default/Cache/x")
        for item in [ChatAppCaches.zalo, ChatAppCaches.canva, ChatAppCaches.teams, ChatAppCaches.whatsApp] {
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
