import Foundation
import Testing
@testable import CleanMate

/// Media caches of Telegram, Spotify and Apple Podcasts: only the media and cache folders are listed and deleted, never
/// Telegram's database, keys or sign-in, nor Podcasts' library. Everything happens in a throwaway fake home.
final class MediaAppCachesTests {
    private let fm = FileManager.default
    private let root = TestTemp.url("CleanMateMediaApps")
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

    @Test func itemsAreUntickedDeletedAndHiddenWhenEmpty() throws {
        let items = CleanerGroup.applications(hasFullDiskAccess: true).items
        for id in ["telegram-media-cache", "spotify-storage", "podcasts-episodes", "podcasts-cache"] {
            let item = try #require(items.first { $0.id == id }, "\(id)")
            #expect(!item.selectedByDefault && item.mode == .delete && !item.showsWhenEmpty && item.note != nil, "\(id)")
            #expect(item.skipsOpenFiles && item.command == nil, "\(id)")
        }
        // Telegram's folder is another app's group container: macOS asks without Full Disk Access.
        // Podcasts' too (an Apple group container is guarded the same way).
        for id in ["telegram-media-cache", "podcasts-episodes", "podcasts-cache"] {
            #expect(!CleanerGroup.applications().items.contains { $0.id == id }, "\(id)")
        }
        #expect(CleanerGroup.applications().items.contains { $0.id == "spotify-storage" })
    }

    /// Media and cache of each account in each channel; the database, keys, settings and the group's other folders stay.
    /// Not under the group's Library/Caches, so "App group caches" never lists them again.
    @Test func telegramListsOnlyMediaAndCache() async throws {
        let group = "Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram"
        try file(group + "/stable/account-123/postbox/media/photo1")
        try file(group + "/appstore/account-456/postbox/media/video2")
        try file(group + "/stable/account-123/cache/c1")
        let kept = [group + "/stable/account-123/postbox/db/db_sqlite", group + "/stable/.tempkeyEncrypted",
                    group + "/stable/accounts-metadata/guard_db/x", group + "/appstore/account-456/notificationsKey",
                    group + "/Library/Caches/x"]
        for path in kept { try file(path) }
        let listed = await scanAndClean(MediaAppCaches.telegram)
        #expect(listed == [group + "/appstore/account-456/postbox/media/video2", group + "/stable/account-123/cache/c1",
                           group + "/stable/account-123/postbox/media/photo1"])
        #expect(!listed.contains { $0.contains("postbox/db") || $0.contains("Library/Caches") })
        for path in listed { #expect(!exists(path), "\(path)") }
        for path in kept { #expect(exists(path), "\(path)") }
    }

    @Test func spotifyListsOnlyStorage() async throws {
        let support = "Library/Application Support/Spotify"
        try file(support + "/PersistentCache/Storage/0a/0a1b")
        let kept = [support + "/prefs", support + "/Users/me-user/prefs", support + "/PersistentCache/index.dat"]
        for path in kept { try file(path) }
        let listed = await scanAndClean(MediaAppCaches.spotify)
        #expect(listed == [support + "/PersistentCache/Storage/0a"])
        for path in listed { #expect(!exists(path), "\(path)") }
        for path in kept { #expect(exists(path), "\(path)") }
    }

    /// Episode files directly in `Library/Cache` go with "downloaded episodes", its other entries with "cache"; neither
    /// lists the other's, and the library database, settings and downloads in progress (`Library/Caches`) stay.
    @Test func podcastsSplitsEpisodesFromCache() async throws {
        let cache = "Library/Group Containers/243LU875E5.groups.com.apple.podcasts/Library/Cache"
        let group = "Library/Group Containers/243LU875E5.groups.com.apple.podcasts"
        let episodes = [cache + "/0A1B2C3D-0000-4000-8000-000000000001.mp3", cache + "/0A1B2C3D-0000-4000-8000-000000000002.M4A",
                        cache + "/0A1B2C3D-0000-4000-8000-000000000003.mp4"]
        let cached = [cache + "/Assets/Artwork/Show-1-600x600-bb.heic", cache + "/Assets/StreamedMedia/s1",
                      cache + "/JSStoreDataProvider/ListenNowFooter.json"]
        let kept = [group + "/Documents/MTLibrary.sqlite", group + "/Documents/MTLibrary.sqlite-wal",
                    group + "/Library/Preferences/243LU875E5.groups.com.apple.podcasts.plist",
                    group + "/Library/Caches/com.apple.nsurlsessiond/Downloads/com.apple.podcasts/d.tmp",
                    group + "/PodcastContentService/SyncToAppChangeSets/c"]
        for path in episodes + cached + kept { try file(path) }

        let cacheListed = await scanAndClean(MediaAppCaches.podcastsPlaybackCache)
        #expect(cacheListed == [cache + "/Assets", cache + "/JSStoreDataProvider"])
        for path in episodes + kept { #expect(exists(path), "\(path)") }
        for path in cached { #expect(!exists(path), "\(path)") }

        let episodesListed = await scanAndClean(MediaAppCaches.podcastEpisodes)
        #expect(episodesListed == episodes.sorted())
        for path in episodes { #expect(!exists(path), "\(path)") }
        for path in kept { #expect(exists(path), "\(path)") }
        #expect(exists(cache), "the folder itself stays")
    }

    @MainActor @Test func lockedWhileTheAppRuns() {
        let model = SmartScanModel(module: .smartScan) { [] }
        let cases: [(CleanerItem, apps: [String], processes: [String])] = [
            (MediaAppCaches.telegram, ["ru.keepcoder.Telegram", "org.telegram.desktop"], ["Telegram"]),
            (MediaAppCaches.spotify, ["com.spotify.client"], ["Spotify"]),
            (MediaAppCaches.podcastEpisodes, ["com.apple.podcasts", "com.apple.podcasts.widget"], ["Podcasts", "podcastsd"]),
            (MediaAppCaches.podcastsPlaybackCache, ["com.apple.podcasts"], ["Podcasts", "podcastsd"]),
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
