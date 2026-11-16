import Foundation
import Testing
@testable import CleanMate

/// Settings › Activity reads the log off the main thread and skips a log that did not change.
final class ActivitySnapshotTests {
    let root = TestTemp.url("CleanMateActivitySnapshot")
    var home: URL { root.appending(path: "home") }

    deinit { try? FileManager.default.removeItem(at: root) }

    @Test func stampChangesOnlyWhenTheLogDoes() {
        #expect(ActivityLog.stamp(home: home) == ActivityLog.stamp(home: home))
        ActivityLog.record(module: "Smart Scan", item: "a", size: 10, mode: .delete, home: home)
        let first = ActivityLog.stamp(home: home)
        #expect(first == ActivityLog.stamp(home: home))
        ActivityLog.record(module: "Smart Scan", item: "b", size: 10, mode: .delete, home: home)
        #expect(ActivityLog.stamp(home: home) != first)
    }

    @Test func snapshotOffTheMainThreadMatchesFreed() async {
        let now = Date.now
        ActivityLog.record(module: "Smart Scan", item: "old", size: 1_000, mode: .delete, home: home,
                           date: now.addingTimeInterval(-90 * 86_400))
        for (index, size) in [100, 200, 300].enumerated() {
            ActivityLog.record(module: "Smart Scan", item: "item\(index)", size: Int64(size), mode: index == 2 ? .trash : .delete,
                               home: home, date: now.addingTimeInterval(Double(index - 10)))
        }
        let home = home
        let snapshot = await Task.detached { ActivityLog.snapshot(home: home, now: now) }.value
        #expect(snapshot.entries.map(\.item) == ["item2", "item1", "item0", "old"])
        #expect(snapshot.entries.map(\.id) == Array(0..<4))
        let recent = ActivityLog.freed(after: now.addingTimeInterval(-30 * 86_400), home: home)
        let total = ActivityLog.freed(home: home)
        #expect(snapshot.recent == .init(deleted: recent.deleted, trashed: recent.trashed, since: recent.since))
        #expect(snapshot.total == .init(deleted: total.deleted, trashed: total.trashed, since: total.since))
        #expect(snapshot.recent.deleted == 300 && snapshot.recent.trashed == 300 && snapshot.total.deleted == 1_300)
    }

    /// Prints how long a snapshot of a log at the 1 MB rotation limit takes; never asserts on the time.
    @Test func measureALargeLog() {
        let now = Date.now
        let line = { (index: Int) in
            "\(Date.ISO8601FormatStyle(timeZone: .current).format(now.addingTimeInterval(Double(-index))))\tSmart Scan\t/Users/x/Library/Caches/app\(index)\t1\t10 KB\tdeleted\t10240\n"
        }
        let text = (0..<10_000).map(line).joined()
        try? FileManager.default.createDirectory(at: ActivityLog.url(home: home).deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: ActivityLog.url(home: home), atomically: true, encoding: .utf8)
        let clock = ContinuousClock()
        var snapshot = ActivityLog.Snapshot()
        let took = clock.measure { snapshot = ActivityLog.snapshot(home: home, now: now) }
        let stampTook = clock.measure { _ = ActivityLog.stamp(home: home) }
        print("ACTIVITY-SNAPSHOT bytes=\(text.utf8.count) entries=\(snapshot.entries.count) snapshot=\(took) stamp=\(stampTook)")
        #expect(snapshot.entries.count == 10_000)
    }
}
