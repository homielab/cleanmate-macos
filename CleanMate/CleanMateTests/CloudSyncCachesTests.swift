import Foundation
import Testing
@testable import CleanMate

/// Caches of Google Drive, Dropbox and OneDrive: only the cache and log folders are listed and deleted, never the
/// synced files, databases or settings next to them. Everything happens in a throwaway fake home.
final class CloudSyncCachesTests {
    private let fm = FileManager.default
    private let root = TestTemp.url("CleanMateCloudSync")
    private var home: URL { root.appending(path: "home") }
    private var policy: SafetyPolicy { SafetyPolicy(home: home, temp: root.appending(path: "tmp")) }

    init() throws {
        for dir in ["home", "tmp"] { try fm.createDirectory(at: root.appending(path: dir), withIntermediateDirectories: true) }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    private func file(_ path: String, bytes: Int = 20_000) throws -> URL {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
        return url
    }

    /// Dates `path` and every folder above it up to `top` (excluded) `days` back, like a cache entry left alone.
    private func age(_ path: String, days: Double, below top: String) throws {
        var current = path
        while current != top, current.hasPrefix(top + "/") {
            try fm.setAttributes([.modificationDate: Date.now.addingTimeInterval(-days * 86_400)],
                                 ofItemAtPath: home.appending(path: current).path)
            current = (current as NSString).deletingLastPathComponent
        }
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

    @Test func itemsAreUntickedDeletedAndHiddenWhenEmpty() throws {
        let items = CleanerGroup.applications(hasFullDiskAccess: true).items
        for id in ["google-drive-cache", "dropbox-cache", "onedrive-cache"] {
            let item = try #require(items.first { $0.id == id }, "\(id)")
            #expect(!item.selectedByDefault && item.mode == .delete && !item.showsWhenEmpty && item.note != nil, "\(id)")
            #expect(item.skipsOpenFiles && item.command == nil, "\(id)")
        }
        // OneDrive's folders are other apps' containers: macOS asks without Full Disk Access.
        #expect(!CleanerGroup.applications().items.contains { $0.id == "onedrive-cache" })
        #expect(CleanerGroup.applications().items.contains { $0.id == "dropbox-cache" })
    }

    /// Only each account's content_cache and DriveFS's logs, and only entries untouched for 7 days: a file changed
    /// since (a pending upload) keeps its whole entry. The account's databases and settings stay.
    @Test func googleDriveListsOnlyOldContentCacheAndLogs() async throws {
        #expect(CloudSyncCaches.googleDrive.minAge == TimeInterval(7 * 86_400))
        let drive = "Library/Application Support/Google/DriveFS"
        let old = [(drive + "/123/content_cache/d10/d4/2381", drive + "/123/content_cache"),
                   (drive + "/456/content_cache/d2/9", drive + "/456/content_cache"),
                   (drive + "/Logs/drive_fs.txt", drive + "/Logs")]
        for (path, top) in old {
            try file(path, bytes: 100_000)
            try age(path, days: 8, below: top)
        }
        // Changed 6 days ago, or a pending upload written just now next to an old file: kept whole.
        try file(drive + "/123/content_cache/d11/7")
        try age(drive + "/123/content_cache/d11/7", days: 6, below: drive + "/123/content_cache")
        try file(drive + "/456/content_cache/d3/old")
        try age(drive + "/456/content_cache/d3/old", days: 30, below: drive + "/456/content_cache")
        try file(drive + "/456/content_cache/d3/pending")
        let kept = [
            drive + "/123/content_cache/d11/7", drive + "/456/content_cache/d3/old", drive + "/456/content_cache/d3/pending",
            drive + "/123/metadata_sqlite_db", drive + "/123/mirror_sqlite.db", drive + "/123/settings.json",
            drive + "/user_default/user_cache.db", drive + "/global_feature_config", "Library/CloudStorage/GoogleDrive-me/My Drive/a.txt",
        ]
        for path in kept where !exists(path) { try file(path) }
        let listed = await scanAndClean(CloudSyncCaches.googleDrive)
        #expect(listed == [drive + "/123/content_cache/d10", drive + "/456/content_cache/d2", drive + "/Logs/drive_fs.txt"])
        for path in listed { #expect(!exists(path), "\(path)") }
        for path in kept { #expect(exists(path), "\(path)") }
        #expect(exists(drive + "/123/content_cache") && exists(drive + "/Logs"))
    }

    private func writeDropboxInfo(personal: String, business: String? = nil) throws {
        var json: [String: Any] = ["personal": ["path": personal, "host": 1]]
        if let business { json["business"] = ["path": business] }
        try file(".dropbox/info.json")
        try JSONSerialization.data(withJSONObject: json).write(to: home.appending(path: ".dropbox/info.json"))
    }

    /// `.dropbox.cache` of the folders info.json names, in the home or in ~/Library/CloudStorage, and the logs; the
    /// synced files, Dropbox's databases and a `.dropbox.cache` of a folder Dropbox doesn't use stay.
    @Test func dropboxCacheFoundThroughInfoJson() async throws {
        try writeDropboxInfo(personal: home.path + "/Dropbox", business: home.path + "/Library/CloudStorage/Dropbox-Team")
        try file("Dropbox/.dropbox.cache/2026-10-30/old copy.docx", bytes: 200_000)
        try file("Library/CloudStorage/Dropbox-Team/.dropbox.cache/tmp.bin", bytes: 100_000)
        try file(".dropbox/logs/1/dropbox.log")
        let kept = [
            "Dropbox/Report.docx", "Dropbox/Photos/a.jpg", "Library/CloudStorage/Dropbox-Team/Plan.xlsx",
            ".dropbox/instance1/config.dbx", ".dropbox/instance1/sync/nucleus.sqlite3",
            "Old Dropbox/.dropbox.cache/x.bin", "Library/CloudStorage/GoogleDrive-me/.dropbox.cache/x.bin",
        ]
        for path in kept { try file(path) }
        let listed = await scanAndClean(CloudSyncCaches.dropbox { true })
        #expect(listed == [".dropbox/logs/1", "Dropbox/.dropbox.cache/2026-10-30",
                           "Library/CloudStorage/Dropbox-Team/.dropbox.cache/tmp.bin"])
        for path in listed { #expect(!exists(path), "\(path)") }
        for path in kept + [".dropbox/info.json"] { #expect(exists(path), "\(path)") }
        #expect(exists("Dropbox/.dropbox.cache") && exists("Library/CloudStorage/Dropbox-Team/.dropbox.cache"))
    }

    /// Without Full Disk Access a Dropbox folder in ~/Library/CloudStorage is not read (macOS would ask).
    @Test func dropboxInCloudStorageNeedsFullDiskAccess() async throws {
        try writeDropboxInfo(personal: home.path + "/Library/CloudStorage/Dropbox")
        try file("Library/CloudStorage/Dropbox/.dropbox.cache/tmp.bin")
        #expect(CloudSyncCaches.dropboxCaches(home: home, hasFullDiskAccess: false).isEmpty)
        #expect(await scanAndClean(CloudSyncCaches.dropbox { false }).isEmpty)
        #expect(exists("Library/CloudStorage/Dropbox/.dropbox.cache/tmp.bin"))
        #expect(CloudSyncCaches.dropboxCaches(home: home, hasFullDiskAccess: true)
            == [home.path + "/Library/CloudStorage/Dropbox/.dropbox.cache"])
    }

    /// A missing, broken or relative info.json names nothing; the Dropbox folder itself is never a scan root.
    @Test func dropboxInfoJsonIsReadStrictly() throws {
        #expect(CloudSyncCaches.dropboxCaches(home: home, hasFullDiskAccess: true).isEmpty)
        try file(".dropbox/info.json")
        #expect(CloudSyncCaches.dropboxCaches(home: home, hasFullDiskAccess: true).isEmpty)
        try writeDropboxInfo(personal: "Dropbox")
        #expect(CloudSyncCaches.dropboxCaches(home: home, hasFullDiskAccess: true).isEmpty)
    }

    /// The CloudStorage exception covers `Dropbox*/.dropbox.cache` and what it holds, nothing else.
    @Test func dropboxCacheIsTheOnlyCloudStorageException() {
        let policy = SafetyPolicy(home: URL(fileURLWithPath: "/Users/test"), temp: URL(fileURLWithPath: "/var/folders/xx/T"))
        let cloud = "/Users/test/Library/CloudStorage/"
        for path in ["Dropbox/.dropbox.cache", "Dropbox/.dropbox.cache/x", "Dropbox-Team/.dropbox.cache/a/b",
                     "dropbox/.Dropbox.Cache/x"] {
            #expect(policy.allowsDropboxCache(URL(fileURLWithPath: cloud + path)), "\(path)")
            #expect(!policy.allows(URL(fileURLWithPath: cloud + path)), "\(path)")
        }
        for path in ["", "Dropbox", "Dropbox/Report.docx", "Dropbox/Photos/.dropbox.cache/x", "GoogleDrive-me/.dropbox.cache/x",
                     "OneDrive-Personal/.dropbox.cache", "Dropbox/.dropbox.cache/../Report.docx", "Dropbox/.dropbox.cachex/x"] {
            #expect(!policy.allowsDropboxCache(URL(fileURLWithPath: cloud + path)), "\(path)")
        }
        #expect(policy.allowsDropboxCache(URL(fileURLWithPath: "/Users/test/.dropbox/logs/1")))
        #expect(!policy.allowsDropboxCache(URL(fileURLWithPath: "/Users/test/Documents/Dropbox/.dropbox.cache/x")))
        let excluded = SafetyPolicy(home: URL(fileURLWithPath: "/Users/test"), temp: URL(fileURLWithPath: "/var/folders/xx/T"),
                                    excluded: [cloud + "Dropbox"])
        #expect(!excluded.allowsDropboxCache(URL(fileURLWithPath: cloud + "Dropbox/.dropbox.cache/x")))
    }

    /// Only the updater's logs and the container's Caches; settings, the sync engine's data and in-flight downloads stay.
    /// The container's Caches are not listed again under "Sandboxed app caches".
    @Test func oneDriveListsOnlyCachesAndLogs() async throws {
        let group = "Library/Group Containers/UBF8T346G9.OneDriveStandaloneSuite"
        let container = "Library/Containers/com.microsoft.OneDrive-mac/Data"
        try file(group + "/OneDriveStandaloneUpdater/Logs/Updater.log")
        try file(container + "/Library/Caches/com.microsoft.OneDrive-mac/Cache.db")
        let kept = [
            group + "/OneDriveStandaloneUpdater/UpdaterSettings.plist", group + "/settings/Personal/global.ini",
            group + "/.849C9593-D756-4E56-8D6E-42412F2A707B/x", container + "/Library/Application Support/OneDrive/sync.db",
            container + "/Library/Caches/com.apple.nsurlsessiond/Downloads/x", "Library/CloudStorage/OneDrive-Personal/a.txt",
        ]
        for path in kept { try file(path) }
        let listed = await scanAndClean(CloudSyncCaches.oneDrive)
        #expect(listed == [container + "/Library/Caches/com.microsoft.OneDrive-mac",
                           group + "/OneDriveStandaloneUpdater/Logs/Updater.log"])
        for path in listed { #expect(!exists(path), "\(path)") }
        for path in kept { #expect(exists(path), "\(path)") }
        let entry = home.appending(path: container + "/Library/Caches/x")
        #expect(CleanerGroup.skipsSandboxCache(entry, runningApps: []))
    }

    /// Without the app there is nothing to list, and the hidden items show no row.
    @Test func nothingListedWithoutTheApps() async throws {
        try file("Library/Application Support/Google/Chrome/Default/Preferences")
        for item in [CloudSyncCaches.googleDrive, CloudSyncCaches.dropbox { true }, CloudSyncCaches.oneDrive] {
            #expect(await Scanner.scan(item, policy: policy, openPaths: EndToEndCleanTests.ownOpenPaths).entries.isEmpty)
        }
    }

    /// Each item is locked while its app, a helper or its File Provider extension runs; other apps don't lock it.
    @MainActor @Test func lockedWhileTheAppRuns() {
        let model = SmartScanModel(module: .smartScan) { [] }
        let cases: [(CleanerItem, apps: [String], processes: [String])] = [
            (CloudSyncCaches.googleDrive, ["com.google.drivefs", "com.google.drivefs.fpext"], ["Google Drive", "Google Drive Helper"]),
            (CloudSyncCaches.dropbox { true }, ["com.getdropbox.dropbox", "com.getdropbox.dropbox.fileprovider",
                                                "com.dropbox.DropboxMacUpdate"], ["Dropbox"]),
            (CloudSyncCaches.oneDrive, ["com.microsoft.OneDrive", "com.microsoft.OneDrive-mac",
                                        "com.microsoft.OneDriveStandaloneUpdater"], ["OneDrive", "OneDrive File Provider"]),
        ]
        for (item, apps, processes) in cases {
            model.runningApps = ["com.google.Chrome", "com.microsoft.Word", "com.apple.finder"]
            model.runningProcesses = ["Google Chrome", "Microsoft Word", "fileproviderd"]
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
