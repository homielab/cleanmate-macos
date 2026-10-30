import Foundation
import Testing
@testable import CleanMate

/// Free-space history: stores kept in memory (no real file), a fixed UTC calendar.
struct DiskHistoryTests {
    static let now = Date(timeIntervalSince1970: 1_768_478_400) // 2026-01-15 12:00 UTC
    static let gb: Int64 = 1_000_000_000
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func point(daysAgo: Double, free: Int64, total: Int64 = 500 * gb) -> DiskHistory.Point {
        .init(date: now.addingTimeInterval(-daysAgo * 86_400), available: free, total: total)
    }

    @Test func testsNeverWriteTheRealFile() {
        #expect(DiskHistory.shared.file == nil)
    }

    /// One reading a day, the latest of the day wins; the oldest go past `limit`.
    @Test func oneReadingPerDayAndAtMostTheLimit() {
        let history = DiskHistory(file: nil)
        history.record(Self.point(daysAgo: 1, free: 10 * Self.gb), calendar: Self.calendar)
        history.record(Self.point(daysAgo: 0.1, free: 20 * Self.gb), calendar: Self.calendar) // today 09:36
        history.record(Self.point(daysAgo: 0, free: 30 * Self.gb), calendar: Self.calendar)   // today 12:00 replaces it
        #expect(history.points.map(\.available) == [10 * Self.gb, 30 * Self.gb])

        for day in 0..<450 { history.record(Self.point(daysAgo: Double(450 - day), free: Int64(day)), calendar: Self.calendar) }
        history.record(Self.point(daysAgo: 0, free: 7), calendar: Self.calendar)
        let points = history.points
        #expect(points.count == DiskHistory.limit)
        #expect(points.last?.available == 7)
        #expect(points.map(\.date) == points.map(\.date).sorted())
        #expect(DiskHistory.text(points).split(separator: "\n").count == DiskHistory.limit)
    }

    /// Lines of seconds, free bytes and size; broken lines are skipped; at most `limit` read back.
    @Test func fileTextRoundTrips() {
        let points = [Self.point(daysAgo: 2, free: 5), Self.point(daysAgo: 1, free: 6, total: 9)]
        let text = DiskHistory.text(points)
        #expect(text == "1768305600\t5\t500000000000\n1768392000\t6\t9\n")
        #expect(DiskHistory.parse(text + "garbage\n12\tx\t3\n1\t-1\t5\n") == points)
        let many = (0..<500).map { "\($0 * 86_400)\t\($0)\t1000\n" }.joined()
        #expect(DiskHistory.parse(many).count == DiskHistory.limit)
        #expect(DiskHistory.parse(many).first?.available == 100)
    }

    /// The file store creates its folder and reads back what it saved.
    @Test func fileStoreSavesAndReadsBack() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "CleanMateDiskHistory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "CleanMate/disk-history.tsv")
        DiskHistory(file: file).record(Self.point(daysAgo: 0, free: 42), calendar: Self.calendar)
        #expect(DiskHistory(file: file).points == [Self.point(daysAgo: 0, free: 42)])
    }

    @Test func chartShowsTheLastThirtyDays() {
        let points = [31, 30, 29, 10, 0].map { Self.point(daysAgo: Double($0), free: Int64($0)) }
        let recent = DiskHistory.recent(points, now: Self.now, calendar: Self.calendar)
        #expect(recent.map(\.available) == [29, 10, 0])
    }

    /// Same rule as the Linux app: over 100 MB a week down is losing, up is gaining, else stable.
    @Test func trendSentenceCases() {
        let gb = Self.gb
        #expect(DiskHistory.trend([], calendar: Self.calendar) == nil)
        #expect(DiskHistory.trend([Self.point(daysAgo: 0.3, free: gb), Self.point(daysAgo: 0, free: 2 * gb)],
                                  calendar: Self.calendar) == nil) // one day only
        #expect(DiskHistory.trend([Self.point(daysAgo: 14, free: 100 * gb), Self.point(daysAgo: 0, free: 90 * gb)],
                                  calendar: Self.calendar) == .losing(perWeek: 5 * gb, weeksLeft: 18))
        #expect(DiskHistory.trend([Self.point(daysAgo: 7, free: 90 * gb), Self.point(daysAgo: 0, free: 92 * gb)],
                                  calendar: Self.calendar) == .gaining(perWeek: 2 * gb))
        #expect(DiskHistory.trend([Self.point(daysAgo: 20, free: 90 * gb), Self.point(daysAgo: 3, free: 50 * gb),
                                   Self.point(daysAgo: 0, free: 90 * gb + 50_000_000)],
                                  calendar: Self.calendar) == .stable(days: 20))
    }

    /// The Overview reads the injected store when shown: only the last 30 days.
    @MainActor @Test func overviewShowsTheInjectedHistory() {
        let model = OverviewModel(center: NotificationCenter())
        model.home = FileManager.default.temporaryDirectory.appending(path: "CleanMateOverview-\(UUID().uuidString)")
        model.readDisks = { [] }
        model.now = { Self.now }
        model.measure = { _, _, _ in (0, [:]) }
        model.diskHistory = DiskHistory(file: nil, points: [Self.point(daysAgo: 40, free: 1), Self.point(daysAgo: 2, free: 2),
                                                            Self.point(daysAgo: 0, free: 3)])
        model.startIfNeeded()
        model.cancel()
        #expect(model.history.map(\.available) == [2, 3])
    }
}
