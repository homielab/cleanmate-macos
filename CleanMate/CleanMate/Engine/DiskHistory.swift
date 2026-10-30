import Foundation

/// Free space on the startup disk over time, for the Overview chart: one reading per day (the latest of the day wins),
/// taken when CleanMate starts and when Smart Scan finishes a scan or a clean. The newest `limit` days are kept as
/// tab-separated lines (seconds since 1970, free bytes, disk size) in
/// `~/Library/Application Support/CleanMate/disk-history.tsv`; a read or write error means no history.
nonisolated final class DiskHistory: @unchecked Sendable {
    nonisolated struct Point: Equatable, Sendable, Identifiable {
        var date: Date
        var available: Int64
        var total: Int64
        var id: Date { date }
    }

    /// Where the free space is heading, from the first and last readings shown.
    nonisolated enum Trend: Equatable, Sendable {
        /// Free space shrinks by `perWeek` bytes a week: the disk is full in about `weeksLeft` weeks.
        case losing(perWeek: Int64, weeksLeft: Int64)
        case gaining(perWeek: Int64)
        /// Changed less than `weeklyChange` a week over `days` days.
        case stable(days: Int)
    }

    static let limit = 400
    /// The Overview charts this many days, today included.
    static let chartDays = 30
    /// Free space changing less than this a week counts as stable, as in the Linux app.
    static let weeklyChange: Int64 = 100 << 20

    /// The app's history; memory only under tests, which never touch the real file.
    static let shared = DiskHistory(
        file: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil ? defaultURL : nil)
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "CleanMate/disk-history.tsv")
    }

    /// nil: kept in memory only (tests).
    let file: URL?
    /// Oldest first; read from `file` on first use.
    private let state: Locked<[Point]?>

    init(file: URL?, points: [Point]? = nil) {
        self.file = file
        state = Locked(points ?? (file == nil ? [] : nil))
    }

    /// Every reading kept, oldest first.
    var points: [Point] {
        state.withLock { points in
            let loaded = points ?? load()
            points = loaded
            return loaded
        }
    }

    /// Adds `point`, replacing a reading from the same day, and saves (under the lock, so two records keep both).
    func record(_ point: Point, calendar: Calendar = .current) {
        state.withLock { points in
            let updated = Self.adding(point, to: points ?? load(), calendar: calendar)
            points = updated
            guard let file else { return }
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Self.text(updated).write(to: file, atomically: true, encoding: .utf8)
            } catch {}
        }
    }

    private func load() -> [Point] {
        file.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map(Self.parse) ?? []
    }

    /// Reads the disk holding `home` now; nothing is recorded when it can't be read.
    func recordNow(home: URL = SafetyPolicy.current.homeURL, now: Date = .now) {
        let volume = SpaceLensModel.Volume.read(home)
        guard volume.total > 0 else { return }
        record(Point(date: now, available: volume.available, total: volume.total))
    }

    /// The readings from the last `days` days (today included) of `now`.
    func recent(now: Date = .now, days: Int = chartDays, calendar: Calendar = .current) -> [Point] {
        Self.recent(points, now: now, days: days, calendar: calendar)
    }

    // MARK: Pure helpers

    static func adding(_ point: Point, to points: [Point], calendar: Calendar = .current) -> [Point] {
        let others = points.filter { !calendar.isDate($0.date, inSameDayAs: point.date) }
        return Array((others + [point]).sorted { $0.date < $1.date }.suffix(limit))
    }

    static func recent(_ points: [Point], now: Date, days: Int = chartDays, calendar: Calendar = .current) -> [Point] {
        guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now)) else { return points }
        return points.filter { $0.date >= start }
    }

    /// nil with fewer than two readings or all on one day. Days are calendar days between the first and last reading.
    static func trend(_ points: [Point], calendar: Calendar = .current) -> Trend? {
        guard let first = points.first, let last = points.last,
              let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: first.date),
                                                 to: calendar.startOfDay(for: last.date)).day, days > 0 else { return nil }
        let perWeek = (last.available - first.available) * 7 / Int64(days)
        if perWeek < -weeklyChange { return .losing(perWeek: -perWeek, weeksLeft: last.available / -perWeek) }
        if perWeek > weeklyChange { return .gaining(perWeek: perWeek) }
        return .stable(days: days)
    }

    static func text(_ points: [Point]) -> String {
        points.map { "\(Int64($0.date.timeIntervalSince1970))\t\($0.available)\t\($0.total)\n" }.joined()
    }

    /// Lines that don't read as three numbers are skipped.
    static func parse(_ text: String) -> [Point] {
        let points = text.split(separator: "\n").compactMap { line -> Point? in
            let fields = line.split(separator: "\t")
            guard fields.count >= 3, let seconds = Int64(fields[0]), let available = Int64(fields[1]),
                  let total = Int64(fields[2]), available >= 0, total > 0 else { return nil }
            return Point(date: Date(timeIntervalSince1970: TimeInterval(seconds)), available: available, total: total)
        }
        return Array(points.sorted { $0.date < $1.date }.suffix(limit))
    }
}
