import Foundation
import Testing
@testable import CleanMate

/// Folder sizes kept between scans, in a throwaway folder and cache file: the app's own cache file is never touched.
struct FolderSizeCacheTests {
    let fm = FileManager.default
    let root = FileManager.default.temporaryDirectory.appending(path: "CleanMateFolderSizes-\(UUID().uuidString)")
    var home: URL { root.appending(path: "home") }
    var file: URL { root.appending(path: "cache/folder-sizes.json") }
    let old = Date.now.addingTimeInterval(-200 * 86_400)

    func write(_ url: URL, bytes: Int, date: Date? = nil) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
        if let date { try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }
    }

    /// A second scan takes a stale project's size from the cache (a change deep inside goes unseen), measures again
    /// once the folder's own date changed, and a new cache on the same file starts from what the last one saved.
    @Test func secondScanReusesSizesUntilTheFolderChanges() async throws {
        defer { try? fm.removeItem(at: root) }
        let project = home.appending(path: "Developer/app"), modules = project.appending(path: "node_modules")
        try write(project.appending(path: "package.json"), bytes: 100, date: old)
        try write(modules.appending(path: "react/index.js"), bytes: 40_000)
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: modules.path)
        let policy = SafetyPolicy(home: home, temp: root.appending(path: "tmp"))
        let sizes = FolderSizeCache(file: file)
        func scan(_ sizes: FolderSizeCache) async -> Int64 {
            await Scanner.scan(StaleNodeModules.item(home: home, hasFullDiskAccess: { true }, running: { [] }, sizes: sizes),
                               policy: policy, openPaths: EndToEndCleanTests.ownOpenPaths).size
        }
        let first = await scan(sizes)
        #expect(first == Scanner.fileSize(modules.appending(path: "react/index.js")) && sizes.count == 1)
        #expect(fm.fileExists(atPath: file.path))

        try write(modules.appending(path: "react/index.js"), bytes: 400_000) // deeper than the folder's own date
        #expect(await scan(sizes) == first)
        #expect(await scan(FolderSizeCache(file: file)) == first) // read back from the file

        try fm.setAttributes([.modificationDate: old.addingTimeInterval(60)], ofItemAtPath: modules.path)
        let measured = Scanner.fileSize(modules.appending(path: "react/index.js"))
        #expect(await scan(sizes) == measured && measured > first)
        try fm.createDirectory(at: modules.appending(path: "vue"), withIntermediateDirectories: true) // a new subfolder
        try fm.setAttributes([.modificationDate: old.addingTimeInterval(60)], ofItemAtPath: modules.path)
        try write(modules.appending(path: "react/extra.js"), bytes: 40_000)
        #expect(await scan(sizes) > measured) // same date, one more link: measured again
    }

    /// At most `limit` folders: the least recently used go first; a size read counts as a use.
    @Test func keepsTheMostRecentlyUsed() throws {
        defer { try? fm.removeItem(at: root) }
        let sizes = FolderSizeCache(file: file, limit: 3)
        var folders: [(URL, FolderSizeCache.Fingerprint)] = []
        for index in 0..<5 {
            let folder = root.appending(path: "f\(index)")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let fingerprint = try #require(FolderSizeCache.Fingerprint(folder))
            folders.append((folder, fingerprint))
            sizes.remember(folder, fingerprint, size: Int64(index), partlyUnreadable: false, now: Date(timeIntervalSince1970: Double(index)))
        }
        #expect(sizes.size(of: folders[0].0, folders[0].1, now: Date(timeIntervalSince1970: 10))?.size == 0)
        sizes.save()
        let reloaded = FolderSizeCache(file: file, limit: 3)
        #expect(reloaded.count == 3)
        #expect([0, 3, 4].allSatisfy { reloaded.size(of: folders[$0].0, folders[$0].1) != nil })
        #expect(reloaded.size(of: folders[1].0, folders[1].1) == nil && reloaded.size(of: folders[2].0, folders[2].1) == nil)
        #expect(FolderSizeCache.Fingerprint(root.appending(path: "missing")) == nil)
    }

    /// Without a file nothing is written; an unreadable file is no cache.
    @Test func memoryOnlyAndBrokenFile() throws {
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let memory = FolderSizeCache(file: nil)
        let fingerprint = try #require(FolderSizeCache.Fingerprint(root))
        memory.remember(root, fingerprint, size: 7, partlyUnreadable: true)
        memory.save()
        let known = memory.size(of: root, fingerprint)
        #expect(known?.size == 7 && known?.partlyUnreadable == true)
        try write(file, bytes: 10)
        #expect(FolderSizeCache(file: file).count == 0)
    }

    /// A size saved by a version that measured differently (no `version`, counting store links and clones) is measured again.
    @Test func olderRecordsAreMeasuredAgain() throws {
        defer { try? fm.removeItem(at: root) }
        let folder = home.appending(path: "Developer/app/node_modules")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let fingerprint = try #require(FolderSizeCache.Fingerprint(folder))
        let old = #"{"\#(folder.standardizedFileURL.path)":{"seconds":\#(fingerprint.seconds),"nanoseconds":\#(fingerprint.nanoseconds),"links":\#(fingerprint.links),"size":999,"partlyUnreadable":false,"used":0}}"#
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(old.utf8).write(to: file)
        let sizes = FolderSizeCache(file: file)
        #expect(sizes.count == 1 && sizes.size(of: folder, fingerprint) == nil)
        sizes.remember(folder, fingerprint, size: 5, partlyUnreadable: false)
        #expect(sizes.size(of: folder, fingerprint)?.size == 5)
    }
}
