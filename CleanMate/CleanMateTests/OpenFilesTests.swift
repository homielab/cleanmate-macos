import Foundation
import Testing
@testable import CleanMate

/// The open-file table is read once per scan and once per clean, shared by every `skipsOpenFiles` item, and an open
/// file is still never listed or removed.
struct OpenFilesTests {
    let fm = FileManager.default

    /// A reader that counts its calls and returns `paths` for "/".
    private func counting(_ paths: Set<String>) -> (Locked<[String]>, @Sendable (String) -> Set<String>) {
        let calls = Locked<[String]>([])
        return (calls, { folder in calls.withLock { $0.append(folder) }; return folder == "/" ? paths : [] })
    }

    @Test func oneReadSharedByConcurrentCallers() async {
        let (calls, read) = counting(["/Users/u/A/x", "/Users/u/A/y/z", "/Users/u/AB/w", "/var/folders/t/T/s"])
        let files = OpenFiles(read: read)
        let found = await withTaskGroup(of: Set<String>.self) { group in
            for folder in ["/Users/u/A", "/Users/u/A/", "/private/var/folders/t/T", "/Users/u/none"] {
                for _ in 0..<5 { group.addTask { await files.paths(under: folder) } }
            }
            return await group.reduce(into: [Set<String>]()) { $0.append($1) }
        }
        #expect(calls.withLock { $0 } == ["/"])
        #expect(Set(found) == [["/Users/u/A/x", "/Users/u/A/y/z"], ["/var/folders/t/T/s"], []])
        #expect(await files.paths(under: "/Users/u/A") == ["/Users/u/A/x", "/Users/u/A/y/z"])
        #expect(calls.withLock { $0.count } == 1)
    }

    @Test func readAgainOnceOlderThanMaxAge() async {
        let (calls, read) = counting(["/a/b"])
        let files = OpenFiles(maxAge: .zero, read: read)
        _ = await files.paths(under: "/a")
        try? await Task.sleep(for: .milliseconds(5))
        #expect(await files.paths(under: "/a") == ["/a/b"])
        #expect(calls.withLock { $0.count } == 2)
    }

    /// Three items that skip open files: one table read for the whole scan and one for the whole clean (never the
    /// scan's). A file open at scan time is not listed; one opened after the scan is not removed.
    @MainActor @Test func smartScanReadsTheTableOncePerPass() async throws {
        let root = fm.temporaryDirectory.appending(path: "CleanMateOpenFiles-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let home = root.appending(path: "home"), temp = root.appending(path: "tmp")
        func write(_ path: String) throws -> URL {
            let url = home.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: 4096).write(to: url)
            return url
        }
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        let heldAtScan = try write("B/b1"), heldAtClean = try write("C/c1")
        let removed = try [write("A/a1"), write("A/a2"), write("B/b2"), write("C/c2"), write("D/d1")]
        let items = ["A", "B", "C"].map { CleanerItem(id: "open.\($0)", title: "\($0)", paths: ["~/\($0)"], skipsOpenFiles: true) }
            + [CleanerItem(id: "open.D", title: "D", paths: ["~/D"])]
        let policy = SafetyPolicy(home: home, temp: temp)
        let model = SmartScanModel(module: .smartScan) { [CleanerGroup(id: "g", title: "G", systemImage: "x", items: items)] }
        model.processNames = { [] }
        model.appBundleIDs = { [] }
        model.blockedByExclusion = { _ in false }
        model.logHome = home
        model.freeSpace = { nil }
        let reads = Locked(0)
        model.readOpenFiles = { reads.withLock { $0 += 1 }; return EndToEndCleanTests.ownOpenPaths($0) }
        model.scanItem = { await Scanner.scan($0, policy: policy, openPaths: $1) }
        model.cleanItem = { await Cleaner.clean($0, scan: $1, policy: policy, openPaths: $2) }

        let scanHandle = try FileHandle(forReadingFrom: heldAtScan)
        await model.scan()
        try scanHandle.close()
        #expect(reads.withLock { $0 } == 1)
        #expect(model.scans["open.B"]?.entries.map(\.url.lastPathComponent) == ["b2"])
        #expect(model.scans["open.C"]?.entries.count == 2)

        let cleanHandle = try FileHandle(forReadingFrom: heldAtClean)
        defer { try? cleanHandle.close() }
        await model.clean()
        #expect(reads.withLock { $0 } == 2)
        guard case .done(let report) = model.phase else { Issue.record("not done: \(model.phase)"); return }
        #expect(report.skipped == 1)
        #expect(fm.fileExists(atPath: heldAtClean.path) && fm.fileExists(atPath: heldAtScan.path))
        for url in removed { #expect(!fm.fileExists(atPath: url.path), "left: \(url.lastPathComponent)") }
    }

    /// No item skips open files: the table is never read.
    @MainActor @Test func noReadWithoutSkipsOpenFiles() async throws {
        let model = SmartScanModel(module: .smartScan) {
            [CleanerGroup(id: "g", title: "G", systemImage: "x", items: [CleanerItem(id: "t", title: "T", paths: ["~/T"])])]
        }
        model.processNames = { [] }
        model.blockedByExclusion = { _ in false }
        let reads = Locked(0)
        model.readOpenFiles = { _ in reads.withLock { $0 += 1 }; return [] }
        model.scanItem = { item, openPaths in
            _ = item.skipsOpenFiles ? await openPaths("/") : []
            return ItemScan(measuredSize: 1)
        }
        await model.scan()
        #expect(reads.withLock { $0 } == 0)
    }
}
