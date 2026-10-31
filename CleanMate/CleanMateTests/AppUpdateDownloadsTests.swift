import Foundation
import Testing
@testable import CleanMate

/// Updates apps downloaded to update themselves: Zoom's installers, Microsoft AutoUpdate's cache and every app's
/// Sparkle folder. Only those folders are listed and deleted; everything happens in a throwaway fake home.
final class AppUpdateDownloadsTests {
    private let fm = FileManager.default
    private let root = TestTemp.url("CleanMateAppUpdates")
    private var home: URL { root.appending(path: "home") }
    private var policy: SafetyPolicy { SafetyPolicy(home: home, temp: root.appending(path: "tmp")) }
    private let sparkle = SparkleDownloads.folderName

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

    private func relative(_ entries: [ScanEntry]) -> [String] {
        let base = home.resolvingSymlinksInPath().path + "/"
        return entries.map { String($0.url.resolvingSymlinksInPath().path.dropFirst(base.count)) }.sorted()
    }

    private func scan(_ item: CleanerItem) async -> ItemScan {
        await Scanner.scan(item, policy: policy, openPaths: EndToEndCleanTests.ownOpenPaths)
    }

    private func clean(_ item: CleanerItem, _ scan: ItemScan) async -> CleanReport {
        await Cleaner.clean(item, scan: scan, policy: policy, openPaths: EndToEndCleanTests.ownOpenPaths)
    }

    private func sparkleItem(running: Set<String> = [], updating: Bool = false) -> CleanerItem {
        SparkleDownloads.item(runningApps: { running }, isUpdating: { updating }) {
            $0 == "com.example.app" ? URL(fileURLWithPath: "/Applications/Example.app") : nil
        }
    }

    private func item(_ id: String) throws -> CleanerItem {
        try #require(CleanerGroup.applications().items.first { $0.id == id }, "\(id)")
    }

    @Test func itemsAreTickedDeletedAndHiddenWhenEmpty() throws {
        for id in ["zoom-updates", "microsoft-autoupdate", SparkleDownloads.id] {
            let item = try item(id)
            #expect(item.selectedByDefault && item.mode == .delete && !item.showsWhenEmpty && item.note != nil, "\(id)")
            #expect(item.skipsOpenFiles && item.command == nil && item.minAge == nil, "\(id)")
        }
        #expect(try item("zoom-updates").runningAppBundleIDs == ["us.zoom.xos"])
        #expect(try item("microsoft-autoupdate").runningAppBundleIDs.contains("com.microsoft.autoupdate*"))
        #expect(try item(SparkleDownloads.id).runningProcessNames == ["Autoupdate", "Updater"])
        // Their cache folders are no longer counted in "User caches" too.
        #expect(CleanerGroup.ownedCachePaths.isSuperset(of: ["com.microsoft.autoupdate2", "com.microsoft.autoupdate.fba"]))
    }

    /// Zoom's AutoUpdater folder and Microsoft AutoUpdate's two cache folders are emptied; the rest of Zoom stays.
    @Test func zoomAndMicrosoftAutoUpdateListOnlyTheirFolders() async throws {
        let zoom = "Library/Application Support/zoom.us"
        let junk = [zoom + "/AutoUpdater/Zoom.pkg", zoom + "/AutoUpdater/6.2.0/Zoom.pkg",
                    "Library/Caches/com.microsoft.autoupdate2/Downloads/Word.pkg",
                    "Library/Caches/com.microsoft.autoupdate.fba/Cache.db"]
        let kept = [zoom + "/data/zoomus.enc.db", zoom + "/data/VirtualBkgnd_Custom/me.jpg", "Library/Caches/us.zoom.xos/c.db",
                    "Library/Application Support/Microsoft/Office/settings.plist"]
        for path in junk + kept { try file(path) }
        for id in ["zoom-updates", "microsoft-autoupdate"] {
            let item = try item(id)
            let found = await scan(item)
            #expect(await clean(item, found).skipped == 0, "\(id)")
        }
        for path in junk { #expect(!exists(path), "\(path)") }
        for path in kept { #expect(exists(path), "\(path)") }
        #expect(exists(zoom + "/AutoUpdater") && exists("Library/Caches/com.microsoft.autoupdate2"))
    }

    /// One entry per app's Sparkle folder, named after the app (its bundle id when not installed); hidden, symlinked,
    /// Apple's and folders another item lists (OrbStack) are skipped, and an open app keeps its folder.
    @Test func sparkleListsOneEntryPerAppAndSkipsOpenApps() async throws {
        let caches = "Library/Caches/"
        for path in ["com.example.app/\(sparkle)/PersistentDownloads/x/Example.zip",
                     "com.example.app/\(sparkle)/Installation/abc/Example.app/Contents/Info.plist",
                     "com.solo.tool/\(sparkle)/PersistentDownloads/u.zip",
                     "com.open.app/\(sparkle)/PersistentDownloads/u.zip",
                     ".hidden/\(sparkle)/u.zip", "com.apple.thing/\(sparkle)/u.zip",
                     "dev.kdrag0n.MacVirt/\(sparkle)/PersistentDownloads/u.zip",
                     "com.example.app/Cache.db", "com.plain/Cache.db"] { try file(caches + path) }
        try file("elsewhere/\(sparkle)/keep.zip")
        try fm.createSymbolicLink(at: home.appending(path: caches + "linked"), withDestinationURL: home.appending(path: "elsewhere"))

        let found = await scan(sparkleItem(running: ["com.open.app"]))
        #expect(relative(found.entries) == [caches + "com.example.app/" + sparkle, caches + "com.solo.tool/" + sparkle])
        let titles = Set(found.entries.compactMap(\.title))
        #expect(titles == ["Example", "com.solo.tool"])
        #expect(found.entries.allSatisfy { $0.date != nil })

        // Launched between scan and clean: kept.
        #expect(await clean(sparkleItem(running: ["com.example.app"]), found).skipped == 1)
        #expect(exists(caches + "com.example.app/" + sparkle))
        #expect(!exists(caches + "com.solo.tool"), "its cache folder was left empty: removed too")

        // Once it quits it goes; the rest of its cache folder, other apps and the bait stay.
        let again = await scan(sparkleItem())
        #expect(relative(again.entries) == [caches + "com.example.app/" + sparkle, caches + "com.open.app/" + sparkle])
        #expect(await clean(sparkleItem(), again).skipped == 0)
        for path in ["com.example.app/\(sparkle)", "com.open.app/\(sparkle)"] { #expect(!exists(caches + path), "\(path)") }
        for path in ["com.example.app/Cache.db", "com.plain/Cache.db", ".hidden/\(sparkle)/u.zip", "com.apple.thing/\(sparkle)/u.zip",
                     "dev.kdrag0n.MacVirt/\(sparkle)/PersistentDownloads/u.zip"] {
            #expect(exists(caches + path), "\(path)")
        }
        #expect(exists("elsewhere/\(sparkle)/keep.zip"))
    }

    /// CleanMate is always open, so its own folder is only kept while it updates itself.
    @Test func ownSparkleFolderKeptWhileUpdating() async throws {
        let own = "Library/Caches/\(SparkleDownloads.ownBundleID)/\(sparkle)"
        try file(own + "/PersistentDownloads/CleanMate.zip")
        let running: Set = [SparkleDownloads.ownBundleID]
        #expect(await scan(sparkleItem(running: running, updating: true)).entries.isEmpty)
        let found = await scan(sparkleItem(running: running))
        #expect(relative(found.entries) == [own])
        // An update found between scan and clean: kept.
        #expect(await clean(sparkleItem(running: running, updating: true), found).skipped == 1)
        #expect(exists(own + "/PersistentDownloads/CleanMate.zip"))
        #expect(await clean(sparkleItem(running: running), found).skipped == 0)
        #expect(!exists(own))
    }

    /// An update still being written (a file a process has open) keeps its app's folder.
    @Test func sparkleSkipsAFolderWithAnOpenFile() async throws {
        let path = "Library/Caches/com.example.app/\(sparkle)/PersistentDownloads/partial.zip"
        try file(path)
        let handle = try FileHandle(forReadingFrom: home.appending(path: path))
        #expect(await scan(sparkleItem()).entries.isEmpty)
        try handle.close()
        #expect(await scan(sparkleItem()).entries.count == 1)
    }

    /// "User caches" lists an app's cache folder holding a Sparkle folder child by child, leaving the Sparkle folder
    /// to its own item; other folders are still listed whole.
    @Test func userCachesLeaveSparkleFolders() async throws {
        let caches = "Library/Caches/"
        for path in ["com.example.app/\(sparkle)/PersistentDownloads/u.zip", "com.example.app/Cache.db",
                     "com.example.app/fsCachedData/a", "com.plain/Cache.db"] { try file(caches + path) }
        let userCaches = try #require(CleanerGroup.smartScan(ages: .default).flatMap(\.items).first { $0.id == "user-caches" })
        let found = await scan(userCaches)
        #expect(relative(found.entries) == [caches + "com.example.app/Cache.db", caches + "com.example.app/fsCachedData",
                                            caches + "com.plain"])
        #expect(await clean(userCaches, found).skipped == 0)
        #expect(exists(caches + "com.example.app/\(sparkle)/PersistentDownloads/u.zip"))
        // A folder handed in whole that holds a Sparkle folder now is kept.
        let cachesRoot = home.appending(path: caches).path
        #expect(Cleaner.isExcluded(home.appending(path: caches + "com.example.app"), excluded: userCaches.excluded,
                                   roots: [cachesRoot]))
        #expect(!Cleaner.isExcluded(home.appending(path: caches + "com.other"), excluded: userCaches.excluded,
                                    roots: [cachesRoot]))
    }

    /// `*` in an exclusion matches one name; the rest must exist below the folder for it to be listed child by child.
    @Test func wildcardExclusions() throws {
        let excluded: Set = ["*/org.sparkle-project.Sparkle", "pypoetry/virtualenvs"]
        #expect(Cleaner.isExcluded("com.a/org.sparkle-project.Sparkle", excluded: excluded))
        #expect(!Cleaner.isExcluded("com.a/b/org.sparkle-project.Sparkle", excluded: excluded))
        #expect(!Cleaner.isExcluded("com.a", excluded: excluded))
        #expect(Cleaner.isExcluded("pypoetry/virtualenvs", excluded: excluded))
        try file("com.a/org.sparkle-project.Sparkle/x")
        try file("com.b/x")
        #expect(Cleaner.holdsExclusion(home.appending(path: "com.a"), relative: "com.a", excluded: excluded))
        #expect(!Cleaner.holdsExclusion(home.appending(path: "com.b"), relative: "com.b", excluded: excluded))
        #expect(Cleaner.holdsExclusion(home.appending(path: "pypoetry"), relative: "pypoetry", excluded: excluded))
    }
}
