import Foundation
import Testing
@testable import CleanMate

/// Caches of the creative apps: only what the app makes again is listed and deleted — never a catalog, a
/// document, a preset or the folders beside the cache — and each item is locked while its app runs. Everything
/// happens in a throwaway fake home.
final class CreativeAppCachesTests {
    private let fm = FileManager.default
    private let root = TestTemp.url("CleanMateCreativeApps")
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

    /// Scans then cleans `item`; returns the listed entries relative to the home folder.
    private func scanAndClean(_ item: CleanerItem) async -> [String] {
        let scan = await Scanner.scan(item, policy: policy, openPaths: EndToEndCleanTests.ownOpenPaths)
        _ = await Cleaner.clean(item, scan: scan, policy: policy, openPaths: EndToEndCleanTests.ownOpenPaths)
        guard let real = realpath(home.path, nil) else { return [] }
        defer { free(real) }
        let resolvedBase = String(cString: real) + "/"
        func relative(_ url: URL) -> String { // the home as the engine spells it: resolved or not
            let path = url.path
            for base in [resolvedBase, home.path + "/"] where path.hasPrefix(base) {
                return String(path.dropFirst(base.count))
            }
            return path
        }
        return scan.entries.map { relative($0.url) }.sorted()
    }

    @Test func itemsAreUntickedDeletedAndHiddenWhenEmpty() throws {
        let items = CleanerGroup.applications(hasFullDiskAccess: true).items
        for id in ["camera-raw-cache", "capture-one-cache", "resolve-cache", "blender-cache", "sketch-cache",
                   "affinity-cache"] {
            let item = try #require(items.first { $0.id == id }, "\(id)")
            #expect(item.mode == .delete && !item.selectedByDefault && !item.showsWhenEmpty, "\(id)")
            #expect(item.skipsOpenFiles, "\(id)")
        }
        // Affinity's cache is a sandbox container: without Full Disk Access the item is not in the catalog at all.
        // Resolve's stays (like the Final Cut libraries in ~/Movies): its discovery waits for Full Disk Access.
        let without = CleanerGroup.applications(hasFullDiskAccess: false).items
        #expect(!without.contains { $0.paths.contains { $0.contains("Containers") } })
        #expect(!without.contains { $0.id == "affinity-cache" })
        let resolve = try #require(without.first { $0.id == "resolve-cache" })
        #expect(resolve.findEntries != nil)
    }

    /// Camera Raw: the shared preview cache goes, the cache folder of another Adobe app and the rest of Caches stay.
    @Test func cameraRawListsOnlyItsCache() async throws {
        try file("Library/Caches/Adobe Camera Raw/Cache2/index.dat")
        try file("Library/Caches/Adobe Camera Raw/large.raw.jpg")
        try file("Library/Caches/com.adobe.LightroomClassicCC/Caches/c")
        let listed = await scanAndClean(CreativeAppCaches.cameraRaw)
        #expect(listed == ["Library/Caches/Adobe Camera Raw/Cache2", "Library/Caches/Adobe Camera Raw/large.raw.jpg"], "was: \(listed)")
        for path in listed { #expect(!exists(path), "\(path)") }
        #expect(exists("Library/Caches/com.adobe.LightroomClassicCC/Caches/c"))
    }

    /// Capture One: its cache folder goes, a catalog beside it (with the previews inside) stays.
    @Test func captureOneKeepsTheCatalog() async throws {
        try file("Library/Caches/com.captureone.captureone16/thumbs/t.db")
        try file("Pictures/Catalog.cocatalogdb/Previews/p.db")
        let listed = await scanAndClean(CreativeAppCaches.captureOne)
        #expect(listed == ["Library/Caches/com.captureone.captureone16/thumbs"], "was: \(listed)")
        #expect(!exists("Library/Caches/com.captureone.captureone16/thumbs"))
        #expect(exists("Pictures/Catalog.cocatalogdb/Previews/p.db"))
    }

    /// Resolve: the render cache under Movies goes (the one folder there CleanMate touches), the user's own media
    /// and the folder itself stay; the policy refuses the rest of Movies.
    @Test func resolveCleansOnlyItsCacheClip() async throws {
        try file("Movies/DaVinci Resolve/CacheClip/shot_01.dpx")
        try file("Movies/DaVinci Resolve/Gallery/still.dra")
        try file("Movies/holiday.mp4")
        let listed = await scanAndClean(CreativeAppCaches.resolve(hasFullDiskAccess: { true }))
        #expect(listed == ["Movies/DaVinci Resolve/CacheClip/shot_01.dpx"], "was: \(listed)")
        #expect(!exists("Movies/DaVinci Resolve/CacheClip/shot_01.dpx"))
        #expect(exists("Movies/DaVinci Resolve/CacheClip") && exists("Movies/DaVinci Resolve/Gallery/still.dra")
                && exists("Movies/holiday.mp4"))
        // The policy: inside CacheClip yes, the folder itself, the rest of Movies and another home no.
        #expect(policy.allowsResolveCache(home.appending(path: "Movies/DaVinci Resolve/CacheClip/a/b.dpx")))
        #expect(!policy.allowsResolveCache(home.appending(path: "Movies/DaVinci Resolve/CacheClip")))
        #expect(!policy.allowsResolveCache(home.appending(path: "Movies/DaVinci Resolve/Gallery/still.dra")))
        #expect(!policy.allowsResolveCache(home.appending(path: "Movies/holiday.mp4")))
        #expect(!policy.allowsResolveCache(root.appending(path: "other/Movies/DaVinci Resolve/CacheClip/a.dpx")))
    }

    /// Blender: the cache folder of every version's settings goes; settings and blend files beside it stay.
    @Test func blenderCleansEveryVersionsCache() async throws {
        try file("Library/Application Support/Blender/Blender/4.2/cache/physics.bphys")
        try file("Library/Application Support/Blender/Blender/3.6/cache/old.bphys")
        try file("Library/Application Support/Blender/Blender/4.2/config/userpref.blend")
        try file("Documents/scenes/scene.blend")
        let listed = await scanAndClean(CreativeAppCaches.blender)
        #expect(listed == ["Library/Application Support/Blender/Blender/3.6/cache/old.bphys",
                           "Library/Application Support/Blender/Blender/4.2/cache/physics.bphys"], "was: \(listed)")
        for path in listed { #expect(!exists(path), "\(path)") }
        #expect(exists("Library/Application Support/Blender/Blender/4.2/config/userpref.blend"))
        #expect(exists("Documents/scenes/scene.blend"))
    }

    /// Sketch and Affinity: the caches go, the documents stay; Affinity's container cache is found too.
    @Test func sketchAndAffinityCleanOnlyCaches() async throws {
        try file("Library/Caches/com.bohemiancoding.sketch3/Previews/p.png")
        try file("Documents/Design.sketch")
        try file("Library/Caches/com.seriflabs.affinityphoto2/tile.tmp")
        try file("Library/Containers/com.seriflabs.affinitydesigner2/Data/Library/Caches/gpu/t.bin")
        let sketchListed = await scanAndClean(CreativeAppCaches.sketch)
        #expect(sketchListed == ["Library/Caches/com.bohemiancoding.sketch3/Previews"], "was: \(sketchListed)")
        #expect(!exists("Library/Caches/com.bohemiancoding.sketch3/Previews/p.png"))
        #expect(exists("Documents/Design.sketch"))
        let affinity = await scanAndClean(CreativeAppCaches.affinity)
        #expect(affinity == ["Library/Caches/com.seriflabs.affinityphoto2/tile.tmp",
                             "Library/Containers/com.seriflabs.affinitydesigner2/Data/Library/Caches/gpu"])
        for path in affinity { #expect(!exists(path), "\(path)") }
        #expect(!exists("Documents/Design.sketch") == false)
    }

    /// Each item is locked while its app runs; other apps don't lock it.
    @MainActor @Test func lockedWhileTheAppRuns() {
        let model = SmartScanModel.isolated(module: .smartScan) { [] }
        let cases: [(CleanerItem, apps: [String], processes: [String])] = [
            (CreativeAppCaches.cameraRaw, ["com.adobe.Photoshop", "com.adobe.LightroomClassic"],
             ["Adobe Photoshop 2025", "Lightroom"]),
            (CreativeAppCaches.captureOne, ["com.captureone.captureone16"], ["Capture One"]),
            (CreativeAppCaches.resolve(), ["com.blackmagic-design.DaVinciResolve"], ["Resolve"]),
            (CreativeAppCaches.blender, ["org.blenderfoundation.blender"], ["Blender"]),
            (CreativeAppCaches.sketch, ["com.bohemiancoding.sketch3"], ["Sketch"]),
            (CreativeAppCaches.affinity, ["com.seriflabs.affinitydesigner2", "com.seriflabs.affinityphoto2"],
             ["Affinity Designer 2"]),
        ]
        for (item, apps, processes) in cases {
            model.runningApps = ["com.google.Chrome"]
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
