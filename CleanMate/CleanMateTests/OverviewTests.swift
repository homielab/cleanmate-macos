import Foundation
import Testing
@testable import CleanMate

/// Overview on a throwaway home and activity log; drives are injected (tests can't mount one).
@Suite(.timeLimit(.minutes(2)))
struct OverviewTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "CleanMateOverview-\(UUID().uuidString)")
    var home: URL { root.appending(path: "home") }
    static let now = Date(timeIntervalSince1970: 1_768_478_400) // 2026-01-15 12:00 UTC

    func file(_ path: String, bytes: Int) throws {
        let url = home.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
    }

    @Test func overviewIsTheFirstModule() {
        #expect(Module.allCases.first == .overview)
        #expect(Module.allCases.count == 8) // ⌘1…⌘8
        #expect(Module.allCases.last == .maintenance)
        #expect(Module.overview.badge(hasResults: true, size: 5, files: 5) == nil)
    }

    /// Same 30-day figure as the menu bar (`freed(after:).deleted`); trashed and restored lines don't count; the last
    /// cleanup is the newest run of deleted lines.
    @Test func cleanupsMatchTheMenuBarFigure() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = ActivityLog.cleanups(now: Self.now, home: home)
        #expect(empty == ActivityLog.Cleanups() && empty.lastDate == nil)
        func record(_ size: Int64, _ mode: RemovalMode = .delete, daysAgo: Double, minutes: Double = 0) {
            ActivityLog.record(module: "Smart Scan", item: "c", size: size, mode: mode, home: home,
                               date: Self.now.addingTimeInterval(-daysAgo * 86_400 + minutes * 60))
        }
        record(1_000, daysAgo: 40)
        record(2_000, daysAgo: 10)
        record(50_000, .trash, daysAgo: 2)
        record(300, daysAgo: 1)                  // last cleanup: these three, each ≤ 5 min after the previous
        record(400, daysAgo: 1, minutes: 4)
        record(500, daysAgo: 1, minutes: 8)
        ActivityLog.recordRestored(module: "Smart Scan", item: "c", size: 50_000, home: home, date: Self.now)
        let cleanups = ActivityLog.cleanups(now: Self.now, home: home)
        let menuBar = ActivityLog.freed(after: Self.now.addingTimeInterval(-30 * 86_400), home: home).deleted
        #expect(cleanups.last30Days == menuBar && menuBar == 3_200)
        #expect(cleanups.total == 4_200)
        #expect(cleanups.lastBytes == 1_200)
        let lastDate = try #require(cleanups.lastDate)
        #expect(abs(lastDate.timeIntervalSince(Self.now.addingTimeInterval(-86_400 + 8 * 60))) < 1)
    }

    /// The bar chart's days: the 30 calendar days ending today, oldest first, deleted lines summed per day, 0 on the
    /// others; trashed lines and older days left out. The model hands them on as `freedByDay`.
    @MainActor @Test func freedByDaySumsDeletedLinesPerCalendarDay() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        func record(_ size: Int64, _ mode: RemovalMode = .delete, at date: Date) {
            ActivityLog.record(module: "Smart Scan", item: "c", size: size, mode: mode, home: home, date: date)
        }
        let today = utc.startOfDay(for: Self.now)                          // 2026-01-15 00:00 UTC
        record(9_000, at: today.addingTimeInterval(-31 * 86_400))          // before the first day
        record(1_000, at: today.addingTimeInterval(-29 * 86_400 + 60))     // the first day
        record(200, at: today.addingTimeInterval(-3 * 86_400 + 600))
        record(300, at: today.addingTimeInterval(-3 * 86_400 + 86_000))    // same day, 23:53
        record(70_000, .trash, at: today.addingTimeInterval(-2 * 86_400))
        record(40, at: today.addingTimeInterval(60))                       // today

        let days = ActivityLog.cleanups(now: Self.now, home: home, calendar: utc).byDay
        #expect(days.count == ActivityLog.chartDays)
        #expect(days.first?.date == today.addingTimeInterval(-29 * 86_400) && days.last?.date == today)
        #expect(zip(days, days.dropFirst()).allSatisfy { $1.date.timeIntervalSince($0.date) == 86_400 })
        #expect(days.map(\.bytes).reduce(0, +) == 1_540)
        #expect(days[0].bytes == 1_000 && days[26].bytes == 500 && days[27].bytes == 0 && days[29].bytes == 40)

        let model = OverviewModel(center: NotificationCenter())
        model.home = home
        model.readDisks = { [] }
        model.measure = { _, _, _ in (0, [:]) }
        model.now = { Self.now }
        model.calendar = utc
        model.startIfNeeded()
        model.cancel()
        #expect(model.freedByDay == days)
    }

    @Test func drivesAreTheStartupDiskThenLocalWritableExternalOnes() {
        func info(_ name: String, local: Bool = true, readOnly: Bool = false, backup: Bool = false) -> OverviewModel.MountInfo {
            OverviewModel.MountInfo(volume: .init(name: name, total: 1_000, available: 400), isLocal: local,
                                    isReadOnly: readOnly, isBackup: backup)
        }
        let infos: [String: OverviewModel.MountInfo] = [
            "/Users/me": info("Macintosh HD"),
            "/Volumes/Zeta": info("Zeta"),
            "/Volumes/alpha": info("alpha"),
            "/Volumes/Share": info("Share", local: false),
            "/Volumes/Installer": info("Installer", readOnly: true),
            "/Volumes/Backup": info("Backup", backup: true),
            "/Volumes/Zeta/inner": info("inner"),
            "/Users/me/OrbStack": info("OrbStack"),
        ]
        let mounts = ["/", "/Volumes/Zeta", "/Volumes/alpha", "/Volumes/Share", "/Volumes/Installer", "/Volumes/Backup",
                      "/Volumes/Zeta/inner", "/Users/me/OrbStack", "/Volumes/Gone"].map { URL(fileURLWithPath: $0) }
        let disks = OverviewModel.disks(home: URL(fileURLWithPath: "/Users/me"), mounts: mounts) { infos[$0.path] }
        #expect(disks.map(\.volume.name) == ["Macintosh HD", "alpha", "Zeta"])
        #expect(disks.first?.usedFraction == 0.6)
    }

    @Test func driveOverNinetyPercentUsedIsAlmostFull() {
        #expect(SpaceLensModel.Volume(total: 100, available: 11).level == .normal)
        #expect(SpaceLensModel.Volume(total: 100, available: 9).level == .low)
        #expect(SpaceLensModel.Volume(total: 100, available: 4).level == .critical)
    }

    /// Folders only (hidden ones too), largest first, at most 12; protected folders are left out without Full Disk
    /// Access; Space Lens then lists the home and a folder inside without measuring them again.
    @MainActor @Test func largestFoldersAreMeasuredAndHandedToSpaceLens() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try file("Big/inner/data.bin", bytes: 3_000_000)
        try file(".hidden/data.bin", bytes: 2_000_000)
        try file("Documents/secret.bin", bytes: 9_000_000) // protected: left out without Full Disk Access
        try file("loose.bin", bytes: 5_000_000)           // a file, not a folder
        for index in 0..<13 { try file("small\(index)/f.bin", bytes: 10_000 + index * 4_096) }
        try FileManager.default.createDirectory(at: home.appending(path: "Empty"), withIntermediateDirectories: true)

        let center = NotificationCenter()
        let spaceLens = SpaceLensModel(center: center)
        spaceLens.home = home
        spaceLens.hasFullDiskAccess = { false }
        let calls = Counter()
        spaceLens.measure = { calls.add(); return try await SpaceLens.measure($0, links: $1, skipping: $2) }
        let model = OverviewModel(center: center)
        model.home = home
        model.hasFullDiskAccess = { false }
        model.readDisks = { [] }
        model.spaceLens = spaceLens
        model.startIfNeeded()
        #expect(model.measuring)
        while model.measuring { try await Task.sleep(for: .milliseconds(5)) }

        #expect(model.measured && model.skippedProtected)
        #expect(model.folders.count == OverviewModel.folderLimit)
        #expect(model.folders.prefix(2).map(\.name) == ["Big", ".hidden"])
        #expect(!model.folders.contains { ["Documents", "loose.bin", "Empty"].contains($0.name) })
        #expect(model.folders.map(\.sortSize) == model.folders.map(\.sortSize).sorted(by: >))

        func settle() async throws { while spaceLens.measuring { try await Task.sleep(for: .milliseconds(5)) } }
        spaceLens.start(at: home)
        try await settle()
        #expect(calls.value == 0)
        #expect(spaceLens.items.first { $0.name == "Big" }?.size == model.folders.first?.size)
        spaceLens.open(home.appending(path: "Big"))
        try await settle()
        #expect(calls.value == 0) // Big/inner (≥ 1 MB) remembered too

        // A clean elsewhere: the Overview measures again next time it is shown.
        center.post(name: ActivityLog.didRecord, object: "Smart Scan")
        model.startIfNeeded()
        #expect(model.measuring)
        model.cancel()
        #expect(!model.measuring)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}
