import Foundation
import Testing
@testable import CleanMate

/// The removal path checks and deletes through the same open folder: a symlink or another item swapped in between the
/// scan (or the check) and the removal is never followed, and what lies behind it is never touched.
@Suite(.serialized)
final class SafeRemovalTests {
    let root = TestTemp.url("CleanMateSafeRemoval")
    var home: URL { root.appending(path: "home") }
    var temp: URL { root.appending(path: "tmp") }
    var policy: SafetyPolicy { SafetyPolicy(home: home, temp: temp) }
    let fm = FileManager.default

    init() throws {
        for folder in [home, temp] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
    }

    deinit {
        // A test that locks a file leaves it undeletable until the flag is cleared.
        for case let url as URL in fm.enumerator(at: root, includingPropertiesForKeys: nil) ?? NSEnumerator() {
            lchflags(url.path, 0)
        }
        try? fm.removeItem(at: root)
    }

    @discardableResult
    func file(_ path: String, bytes: Int = 4_096) throws -> URL {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
        return url
    }

    func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// Stands for the user's documents: a folder the safety policy allows (so only the removal path protects it).
    func userDocs() throws -> (folder: URL, files: [URL]) {
        let files = [try file("Work/report.txt"), try file("Work/notes/plan.txt")]
        return (home.appending(path: "Work"), files)
    }

    // MARK: - Acceptance

    /// The cache folder the scan found is replaced by a symlink to the user's documents before the clean.
    @MainActor @Test func entrySwappedForSymlinkAfterScanIsSkippedAndLogged() async throws {
        try file("Library/Caches/app/cache.db")
        let docs = try userDocs()
        let item = CleanerItem(id: "t-safe.caches", title: "Caches", paths: ["~/Library/Caches"])
        let scan = await Scanner.scan(item, policy: policy)
        let entry = try #require(scan.entries.first)
        #expect(entry.url.lastPathComponent == "app" && entry.fileID != nil)

        try fm.removeItem(at: entry.url)
        try fm.createSymbolicLink(at: entry.url, withDestinationURL: docs.folder)
        let report = await Cleaner.clean(item, scan: scan, policy: policy)
        #expect(report.freed == 0 && report.skipped == 1 && report.changed == [entry.url])
        #expect(docs.files.allSatisfy(exists) && exists(entry.url)) // nothing removed, not even the link

        // The same through Smart Scan: the entry is left and logged with its reason.
        let model = SmartScanModel(module: .smartScan) { [CleanerGroup(id: "g", title: "G", systemImage: "x", items: [item])] }
        let policy = policy
        try fm.removeItem(at: entry.url)
        try file("Library/Caches/app/cache.db")
        model.logHome = home // not the real ~/Library/Logs/CleanMate/activity.log
        model.scanItem = { await Scanner.scan($0, policy: policy, openPaths: $1) }
        model.cleanItem = { item, scan, _ in await Cleaner.clean(item, scan: scan, policy: policy) }
        await model.scan()
        try #require(model.scans["t-safe.caches"]?.entries.count == 1)
        model.selected = ["t-safe.caches"]
        try fm.removeItem(at: entry.url)
        try fm.moveItem(at: docs.folder, to: entry.url) // a real folder this time, but not the one scanned
        await model.clean()
        #expect(docs.files.map { entry.url.appending(path: $0.path.dropFirst(docs.folder.path.count + 1)) }.allSatisfy(exists))
        let line = try #require(ActivityLog.read(home: home).split(separator: "\n").last)
        let logged = ActivityLog.entry(line, locale: Locale(identifier: "en"))
        #expect(logged.kind == "skipped" && logged.item == entry.url.path && logged.bytes == 0)
        #expect(ActivitySettings.kindLabel("skipped", locale: Locale(identifier: "vi")).title == "Bỏ qua: đã thay đổi sau khi quét")
        #expect(ActivityLog.freed(home: home).deleted == 0)
    }

    /// A folder inside the entry is swapped for a symlink: the link goes, never what it points to.
    @Test func symlinkInsideEntryIsRemovedNotFollowed() async throws {
        try file("Library/Caches/app/sub/1.bin")
        try file("Library/Caches/app/2.bin")
        let docs = try userDocs()
        let item = CleanerItem(id: "t-safe.inner", title: "Caches", paths: ["~/Library/Caches"])
        let scan = await Scanner.scan(item, policy: policy)
        let sub = home.appending(path: "Library/Caches/app/sub")
        try fm.removeItem(at: sub)
        try fm.createSymbolicLink(at: sub, withDestinationURL: docs.folder)
        let report = await Cleaner.clean(item, scan: scan, policy: policy)
        #expect(report.skipped == 0 && !exists(home.appending(path: "Library/Caches/app")))
        #expect(docs.files.allSatisfy(exists))
    }

    /// The item's folder (the entry's parent) is swapped for a symlink to a folder holding an item of the same name.
    @Test func parentSwappedForSymlinkRemovesNothingThroughIt() async throws {
        try file("Library/Caches/App/data/1.bin")
        let docs = try file("Work/data/keep.txt")
        let item = CleanerItem(id: "t-safe.parent", title: "App", paths: ["~/Library/Caches/App"])
        let scan = await Scanner.scan(item, policy: policy)
        let entry = try #require(scan.entries.first)
        let parent = entry.url.deletingLastPathComponent()
        try fm.removeItem(at: parent)
        try fm.createSymbolicLink(at: parent, withDestinationURL: home.appending(path: "Work"))
        let report = await Cleaner.clean(item, scan: scan, policy: policy)
        #expect(report.skipped == 1 && report.changed == [entry.url] && exists(docs))
        // Without what the scan saw too: O_NOFOLLOW on the folder refuses it.
        #expect(throws: SafeRemoval.Failure.changed) { try SafeRemoval.remove(entry.url, allows: self.policy.allows) }
        #expect(exists(docs))
    }

    /// A folder higher up swapped for a symlink into a protected folder: the real path is refused.
    @Test func ancestorSwappedIntoProtectedFolderIsRefused() throws {
        let entry = try file("Library/Caches/A/B/c.bin").deletingLastPathComponent()
        let docs = try file("Documents/A/B/c.bin")
        let ancestor = home.appending(path: "Library/Caches/A")
        #expect(policy.allows(entry))
        try fm.removeItem(at: ancestor)
        try fm.createSymbolicLink(at: ancestor, withDestinationURL: home.appending(path: "Documents/A"))
        #expect(throws: SafeRemoval.Failure.changed) { try SafeRemoval.remove(entry, allows: self.policy.allows) }
        #expect(throws: SafeRemoval.Failure.changed) { try SafeRemoval.check(entry, allows: self.policy.allows) }
        #expect(exists(docs))
    }

    /// Trash items take a path: checked through the folder first, so a swapped entry never reaches the Trash.
    @Test func swappedTrashEntryIsNeverMoved() async throws {
        try file("Backups/a/data")
        let docs = try userDocs()
        let item = CleanerItem(id: "t-safe.trash", title: "Backups", paths: ["~/Backups"], mode: .trash)
        let scan = await Scanner.scan(item, policy: policy)
        let entry = try #require(scan.entries.first)
        try fm.removeItem(at: entry.url)
        try fm.moveItem(at: docs.folder, to: entry.url)
        let moved = Locked<[URL]>([])
        let report = await Cleaner.clean(item, scan: scan, policy: policy) { url in moved.withLock { $0.append(url) }; return nil }
        #expect(moved.withLock { $0 }.isEmpty && report.skipped == 1 && report.changed == [entry.url])

        // Unchanged since the scan: moved as before.
        let again = await Scanner.scan(item, policy: policy)
        _ = await Cleaner.clean(item, scan: again, policy: policy) { url in moved.withLock { $0.append(url) }; return nil }
        #expect(moved.withLock { $0 } == [entry.url])
    }

    /// Recursive removal stays on the entry's volume: a folder on another device inside is never walked nor removed.
    @Test func neverLeavesTheEntrysVolume() throws {
        let entry = try file("Library/Caches/app/a.bin").deletingLastPathComponent()
        let mounted = try file("Library/Caches/app/mounted/device.bin")
        try file("Library/Caches/app/z/b.bin")
        // Tests can't mount: the open folder "mounted" reports another device.
        let device: SafeRemoval.Device = { fd in
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(fd, F_GETPATH, &buffer) == 0 else { return nil }
            return String(cString: buffer).hasSuffix("/mounted") ? 99 : SafeRemoval.device(fd)
        }
        #expect(throws: SafeRemoval.Failure.failed(EXDEV)) {
            try SafeRemoval.remove(entry, allows: self.policy.allows, device: device)
        }
        #expect(exists(mounted))
        #expect(!exists(entry.appending(path: "a.bin")) && !exists(entry.appending(path: "z")))
    }

    // MARK: - Removal

    @Test func removesTreesFilesAndLinksOnly() throws {
        let outside = try file("Work/keep.txt")
        let tree = try file("Library/Caches/t/a/b/c/1.bin").deletingLastPathComponent()
        try file("Library/Caches/t/2.bin")
        try fm.createSymbolicLink(at: tree.appending(path: "link"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: tree.appending(path: "folderLink"), withDestinationURL: outside.deletingLastPathComponent())
        let top = home.appending(path: "Library/Caches/t")
        try SafeRemoval.remove(top, allows: policy.allows)
        #expect(!exists(top) && exists(outside))

        let single = try file("Library/Caches/one.bin")
        try SafeRemoval.remove(single, regularFileOnly: true, allows: policy.allows)
        #expect(!exists(single))
    }

    @Test func refusesWhatPolicyOrScanRefuse() throws {
        let folder = try file("Library/Caches/f/1.bin").deletingLastPathComponent()
        let id = try #require(SafeRemoval.FileID(folder))
        #expect(throws: SafeRemoval.Failure.changed) { try SafeRemoval.remove(folder, allows: { _ in false }) }
        #expect(throws: SafeRemoval.Failure.changed) {
            try SafeRemoval.remove(folder, expected: SafeRemoval.FileID(device: id.device, inode: id.inode + 1),
                                   allows: self.policy.allows)
        }
        #expect(throws: SafeRemoval.Failure.changed) {
            try SafeRemoval.remove(folder, regularFileOnly: true, allows: self.policy.allows)
        }
        #expect(throws: SafeRemoval.Failure.failed(ENOTEMPTY)) {
            try SafeRemoval.removeEmptyFolder(folder, allows: self.policy.allows)
        }
        #expect(throws: SafeRemoval.Failure.failed(ENOENT)) {
            try SafeRemoval.remove(folder.appending(path: "missing"), allows: self.policy.allows)
        }
        #expect(exists(folder.appending(path: "1.bin")))
        try SafeRemoval.remove(folder, expected: id, allows: policy.allows)
        #expect(!exists(folder))
        let empty = home.appending(path: "Library/Caches/empty")
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        try SafeRemoval.removeEmptyFolder(empty, allows: policy.allows)
        #expect(!exists(empty))
    }

    /// A locked file stays (with its folders); everything else goes.
    @Test func lockedFileKeepsItsFoldersOnly() throws {
        let locked = try file("Library/Caches/l/keep/locked.bin")
        try file("Library/Caches/l/other/1.bin")
        try file("Library/Caches/l/2.bin")
        #expect(chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(locked.path, 0) }
        let top = home.appending(path: "Library/Caches/l")
        #expect(throws: SafeRemoval.Failure.failed(EPERM)) { try SafeRemoval.remove(top, allows: self.policy.allows) }
        #expect(exists(locked))
        #expect(try fm.contentsOfDirectory(atPath: top.path) == ["keep"])
    }
}

/// Deleting a fixture tree with `FileManager.removeItem` and with `SafeRemoval.remove`, alternately. Skipped unless
/// `TEST_RUNNER_CLEANMATE_BENCH=1`; works in a temporary folder only.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CLEANMATE_BENCH"] == "1"))
final class DeleteBenchmark {
    let root = TestTemp.url("CleanMateDeleteBench")
    deinit { try? FileManager.default.removeItem(at: root) }

    /// 200 folders × 4 subfolders × 25 files (20 000 files, 1 KB each), like a large cache.
    func fixture(_ name: String) throws -> URL {
        let top = root.appending(path: "home/Library/Caches/\(name)")
        let data = Data(count: 1_024)
        for a in 0..<200 {
            for b in 0..<4 {
                let folder = top.appending(path: "\(a)/\(b)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for c in 0..<25 { try data.write(to: folder.appending(path: "\(c).bin")) }
            }
        }
        return top
    }

    func seconds(_ work: () throws -> Void) rethrows -> Double {
        let start = ContinuousClock.now
        try work()
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    @Test func deleteTree() throws {
        let policy = SafetyPolicy(home: root.appending(path: "home"), temp: root.appending(path: "tmp"))
        var plain: [Double] = [], safe: [Double] = []
        for run in 0..<5 {
            let a = try fixture("plain\(run)"), b = try fixture("safe\(run)")
            plain.append(try seconds { try FileManager.default.removeItem(at: a) })
            safe.append(try seconds { try SafeRemoval.remove(b, allows: policy.allows) })
        }
        let median = { (values: [Double]) in values.sorted()[values.count / 2] }
        print(String(format: "BENCH delete 20000 files removeItem %.3f s, SafeRemoval %.3f s (median of 5)",
                     median(plain), median(safe)))
        #expect(median(safe) <= median(plain) * 1.1)
    }
}
