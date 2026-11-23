import Foundation
import Testing
@testable import CleanMate

/// A save that fails part way (full disk, I/O error) keeps what was saved before: the list of items moved to the
/// Trash, the activity log's lifetime totals, the caches.
struct SaveFailureTests {
    struct DiskFull: Error {}

    /// Writes the first bytes, then fails like a full disk.
    static let failingWriter: AtomicFile.Writer = { handle, data in
        try handle.write(contentsOf: data.prefix(10))
        throw DiskFull()
    }

    let fm = FileManager.default
    let root = TestTemp.url("CleanMateSaveFailure")
    var home: URL { root.appending(path: "home") }

    /// A file "in the Trash" (a folder of the test) and the item that says it was moved there.
    func trashed(_ name: String) throws -> TrashedItem {
        let inTrash = root.appending(path: "Trash/\(name)")
        try fm.createDirectory(at: inTrash.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: inTrash)
        return TrashedItem(original: home.appending(path: "Downloads/\(name)"), inTrash: inTrash, size: 1)
    }

    func leftovers(next url: URL) -> [String] {
        let names = (try? fm.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []
        return names.filter { $0.hasPrefix(AtomicFile.temporaryPrefix(url)) }
    }

    @Test func failedTrashRecordsWriteKeepsTheOldListAndIsLogged() throws {
        defer { try? fm.removeItem(at: root) }
        let first = try trashed("a.zip"), second = try trashed("b.zip")
        #expect(TrashRecords.add([first], module: "Large & Old Files", home: home))
        let url = TrashRecords.url(home: home)
        let before = try Data(contentsOf: url)

        #expect(!TrashRecords.add([second], module: "Large & Old Files", home: home, writer: Self.failingWriter))
        #expect(try Data(contentsOf: url) == before)
        #expect(TrashRecords.inTrash(home: home).map(\.trashed) == [first.inTrash.path])
        #expect(leftovers(next: url).isEmpty)
        let lines = ActivityLog.read(home: home).split(separator: "\n").map { ActivityLog.entry($0) }
        #expect(lines.contains { $0.reason == TrashRecords.saveFailedReason })

        #expect(!TrashRecords.update(home: home, writer: Self.failingWriter) { $0 = [] })
        #expect(TrashRecords.inTrash(home: home).count == 1)
        // The next save that works keeps both.
        #expect(TrashRecords.add([second], module: "Large & Old Files", home: home))
        #expect(TrashRecords.inTrash(home: home).count == 2)
    }

    @Test func updateWithoutAFileSucceedsWithoutMakingOne() {
        defer { try? fm.removeItem(at: root) }
        var seen: [TrashRecords.Record]?
        #expect(TrashRecords.update(home: home, create: false) { seen = $0 })
        #expect(seen == [] && !fm.fileExists(atPath: TrashRecords.url(home: home).path))
    }

    /// A rotation that can't save the totals or move the log keeps both logs and the lifetime total as they were.
    @Test func failedRotationKeepsTheLogsAndTheLifetimeTotal() throws {
        defer { try? fm.removeItem(at: root) }
        let log = ActivityLog.url(home: home)
        let old = log.deletingPathExtension().appendingPathExtension("1.log")
        ActivityLog.record(module: "Large & Old Files", item: "first", size: 100, mode: .delete, home: home)
        #expect(ActivityLog.rotate(log))
        ActivityLog.record(module: "Large & Old Files", item: "second", size: 200, mode: .delete, home: home)
        #expect(ActivityLog.freed(home: home).deleted == 300)
        let (logBefore, oldBefore) = (try Data(contentsOf: log), try Data(contentsOf: old))

        #expect(!ActivityLog.rotate(log, writer: Self.failingWriter))
        #expect(try Data(contentsOf: log) == logBefore && Data(contentsOf: old) == oldBefore)
        #expect(ActivityLog.freed(home: home).deleted == 300)

        #expect(!ActivityLog.rotate(log, move: { _, _ in errno = EIO; return -1 }))
        #expect(try Data(contentsOf: log) == logBefore && Data(contentsOf: old) == oldBefore)
        #expect(ActivityLog.freed(home: home).deleted == 300) // the totals saved before the move were put back

        #expect(ActivityLog.rotate(log))
        #expect(!fm.fileExists(atPath: log.path) && ActivityLog.freed(home: home).deleted == 300)
        #expect(leftovers(next: log).isEmpty)
    }

    @Test func atomicWriteFailureLeavesTheFileAsItWas() throws {
        defer { try? fm.removeItem(at: root) }
        let url = root.appending(path: "cache.json")
        #expect(AtomicFile.save(Data("old".utf8), to: url))
        #expect(throws: DiskFull.self) { try AtomicFile.write(Data("new data".utf8), to: url, writer: Self.failingWriter) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "old" && leftovers(next: url).isEmpty)
        #expect(!AtomicFile.save(nil, to: url)) // couldn't be encoded
        #expect(AtomicFile.save(Data("new".utf8), to: url))
        #expect(try String(contentsOf: url, encoding: .utf8) == "new")
    }
}
