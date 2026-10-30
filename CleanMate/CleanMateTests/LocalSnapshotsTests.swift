import Foundation
import Testing
@testable import CleanMate

/// The Overview's "Space outside your folders": the `tmutil` parser on real output, purgeable space and the space
/// outside the home folder with injected drives. No command runs here.
@Suite(.timeLimit(.minutes(1)))
struct LocalSnapshotsTests {
    static let utc = TimeZone(identifier: "UTC")!

    func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text)!
    }

    @Test func snapshotListGivesCountAndDates() {
        let output = """
        Snapshots for disk /:
        com.apple.TimeMachine.2026-10-30-101112.local
        com.apple.TimeMachine.2026-10-28-230501.local
        com.apple.TimeMachine.2026-10-29-080000.local

        """
        let list = LocalSnapshots.parse(output, timeZone: Self.utc)
        #expect(list.readable && list.count == 3)
        #expect(list.oldest == date("2026-10-28T23:05:01Z"))
        #expect(list.newest == date("2026-10-30T10:11:12Z"))
    }

    /// Before macOS 10.15: no header, no ".local"; other snapshots are not Time Machine's; a name without a
    /// readable date still counts.
    @Test func olderFormatsAndOtherNames() {
        let output = """
        com.apple.TimeMachine.2019-05-01-120000
        com.apple.os.update-ABCDEF
        com.apple.TimeMachine.something.local
        """
        let list = LocalSnapshots.parse(output, timeZone: Self.utc)
        #expect(list.count == 2)
        #expect(list.oldest == date("2019-05-01T12:00:00Z") && list.newest == list.oldest)
    }

    @Test func noSnapshotsOrNoOutput() {
        let empty = LocalSnapshots.parse("Snapshots for disk /:\n")
        #expect(empty == LocalSnapshots() && empty.readable && empty.oldest == nil)
        #expect(LocalSnapshots.parse("") == LocalSnapshots())
        #expect(LocalSnapshots.parse(nil) == .unreadable)
    }

    @Test func purgeableIsTheDifferenceNeverNegative() {
        typealias Volume = SpaceLensModel.Volume
        #expect(Volume.purgeable(important: 50_000_000_000, available: 38_000_000_000) == 12_000_000_000)
        #expect(Volume.purgeable(important: 10, available: 20) == 0)
        #expect(Volume.purgeable(important: nil, available: 20) == 0)
        #expect(Volume.purgeable(important: 20, available: nil) == 0)
    }

    /// Under 100 MB of purgeable space the row is left out; the startup disk (first drive) is the one read.
    @MainActor @Test func purgeableUnderOneHundredMegabytesIsHidden() throws {
        let home = TestTemp.url("CleanMatePurgeable")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let model = OverviewModel(center: NotificationCenter())
        model.home = home
        model.measure = { _, _, _ in (0, [:]) }
        func drives(_ purgeable: Int64) -> [OverviewModel.Disk] {
            [.init(url: URL(fileURLWithPath: "/"), volume: .init(name: "Macintosh HD", total: 500, available: 100,
                                                                 purgeable: purgeable)),
             .init(url: URL(fileURLWithPath: "/Volumes/X"), volume: .init(name: "X", total: 500, available: 100,
                                                                          purgeable: 9_000_000_000))]
        }
        model.readDisks = { drives(99_999_999) }
        model.refresh()
        model.cancel()
        #expect(model.purgeable == nil)
        model.readDisks = { drives(100_000_000) }
        model.refresh()
        model.cancel()
        #expect(model.purgeable == 100_000_000)
    }

    /// Space in use outside the home folder = used on the startup disk − the measured home (its folders and the
    /// files directly in it); the snapshot list comes from the injected reader.
    @MainActor @Test func systemAndAppsIsUsedSpaceMinusTheHomeFolder() async throws {
        let home = TestTemp.url("CleanMateOutside")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appending(path: "Big"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appending(path: "Small"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 40_960).write(to: home.appending(path: "loose.bin"))
        let model = OverviewModel(center: NotificationCenter())
        model.home = home
        model.hasFullDiskAccess = { true }
        model.measure = { url, _, _ in (url.lastPathComponent == "Big" ? 300_000 : 100_000, [:]) }
        model.readDisks = {
            [.init(url: home, volume: .init(name: "Macintosh HD", total: 2_000_000, available: 1_000_000))]
        }
        let snapshots = LocalSnapshots(count: 2, oldest: .distantPast, newest: .now)
        model.readSnapshots = { snapshots }
        #expect(model.systemAndApps == nil) // home not measured yet
        model.refresh()
        while model.measuring || model.snapshots == nil { try await Task.sleep(for: .milliseconds(5)) }
        let homeSize = try #require(model.homeSize)
        #expect(homeSize >= 400_000 + 40_960)
        #expect(model.systemAndApps == 1_000_000 - homeSize)
        #expect(model.snapshots == snapshots)

        // A home larger than the used space (clones counted twice): no row rather than a negative size.
        model.readDisks = { [.init(url: home, volume: .init(name: "Macintosh HD", total: 2_000_000, available: 1_900_000))] }
        model.refresh()
        while model.measuring { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.systemAndApps == nil)
    }
}
