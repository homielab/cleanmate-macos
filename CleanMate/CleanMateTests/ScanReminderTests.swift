import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CleanMate

/// Stands in for UNUserNotificationCenter: tests never reach the real one.
@MainActor
final class FakeReminderCenter: ReminderCenter {
    var status: ReminderAuthorization
    /// Answer to the permission prompt.
    var grants: Bool
    private(set) var prompts = 0
    private(set) var calls = 0
    private(set) var pending: [String: ScanReminder.Request] = [:]

    init(status: ReminderAuthorization = .notDetermined, grants: Bool = true) {
        self.status = status
        self.grants = grants
    }

    func authorization() async -> ReminderAuthorization { calls += 1; return status }

    func requestAuthorization() async -> Bool {
        calls += 1
        prompts += 1
        status = grants ? .allowed : .denied
        return grants
    }

    func add(_ request: ScanReminder.Request) async { calls += 1; pending[request.id] = request }

    func removePending(id: String) { calls += 1; pending[id] = nil }
}

@MainActor
struct ScanReminderTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")! // has daylight saving time
        return calendar
    }()

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// When the repeating trigger first fires after `anchor`, as macOS computes it.
    static func firstFire(_ components: DateComponents, after anchor: Date) -> Date? {
        calendar.nextDate(after: anchor, matching: components, matchingPolicy: .nextTime)
    }

    @MainActor
    final class Setup {
        let defaults: UserDefaults
        let suite = "CleanMateScanReminderTests-\(UUID().uuidString)"
        let center: FakeReminderCenter
        var now: Date
        lazy var scheduler = ScanReminderScheduler(center: center, defaults: defaults, now: { [unowned self] in now },
                                                   calendar: ScanReminderTests.calendar)

        init(_ frequency: ScanReminder.Frequency, center: FakeReminderCenter? = nil, now: Date) {
            defaults = UserDefaults(suiteName: suite)!
            self.center = center ?? FakeReminderCenter()
            self.now = now
            set(frequency)
        }

        func set(_ frequency: ScanReminder.Frequency) { defaults.set(frequency.rawValue, forKey: Preferences.scanReminder) }

        var request: ScanReminder.Request? { center.pending[ScanReminder.requestID] }

        deinit { defaults.removePersistentDomain(forName: suite) }
    }

    @Test func offByDefault() {
        let suite = "CleanMateScanReminderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(ScanReminder.frequency(defaults: defaults) == .off)
        defaults.set("hourly", forKey: Preferences.scanReminder) // unknown value
        #expect(ScanReminder.frequency(defaults: defaults) == .off)
    }

    @Test func weeklyAsksOnceThenSchedulesARepeatingReminderAWeekAway() async throws {
        let monday = Self.date(2026, 11, 2, 15, 30)
        let setup = Setup(.weekly, now: monday)
        #expect(await setup.scheduler.update())
        #expect(setup.center.prompts == 1)
        let request = try #require(setup.request)
        #expect(request.components == DateComponents(hour: 10, minute: 0, weekday: 2))
        #expect(Self.firstFire(request.components, after: monday) == Self.date(2026, 11, 9, 10))
        #expect(!request.title.isEmpty && !request.body.isEmpty)
        // Asked once: turning it on again does not prompt.
        #expect(await setup.scheduler.update())
        #expect(setup.center.prompts == 1)
    }

    @Test func offRemovesThePendingReminder() async {
        let setup = Setup(.monthly, now: Self.date(2026, 11, 2, 15))
        await setup.scheduler.update()
        #expect(setup.request?.components.day == 2)
        setup.set(.off)
        #expect(await setup.scheduler.update())
        #expect(setup.center.pending.isEmpty)
    }

    @Test func deniedSchedulesNothingAndReportsIt() async {
        let setup = Setup(.weekly, center: FakeReminderCenter(grants: false), now: Self.date(2026, 11, 2, 15))
        #expect(await !setup.scheduler.update())
        #expect(setup.center.pending.isEmpty)
        // Settings shown again: still denied, no second prompt.
        #expect(await !setup.scheduler.refresh())
        #expect(setup.center.prompts == 1)
        // Allowed later in System Settings: back in CleanMate, the reminder is scheduled.
        setup.center.status = .allowed
        #expect(await setup.scheduler.refresh())
        #expect(setup.request != nil)
    }

    @Test func aFinishedScanOrLaunchMovesTheReminder() async throws {
        let setup = Setup(.weekly, center: FakeReminderCenter(status: .allowed), now: Self.date(2026, 11, 2, 15))
        await setup.scheduler.update()
        setup.now = Self.date(2026, 11, 5, 12) // Thursday
        await setup.scheduler.postpone()
        let request = try #require(setup.request)
        #expect(request.components.weekday == 5)
        #expect(Self.firstFire(request.components, after: setup.now) == Self.date(2026, 11, 12, 10))
    }

    @Test func postponeNeverAsksAndLeavesTheCenterAloneWhileOff() async {
        let off = Setup(.off, now: Self.date(2026, 11, 2, 15))
        await off.scheduler.postpone()
        #expect(await off.scheduler.refresh())
        #expect(off.center.calls == 0)
        let undecided = Setup(.weekly, now: Self.date(2026, 11, 2, 15))
        await undecided.scheduler.postpone()
        #expect(undecided.center.prompts == 0 && undecided.center.pending.isEmpty)
    }

    @Test func noSchedulerCenterUnderTests() async {
        // The shared scheduler has no center in a test run, so app code under test never posts real notifications.
        #expect(await ScanReminderScheduler.shared.update())
    }

    /// Every hour of a year: the first reminder comes 6–7 days (weekly) or 27–31 days (monthly) later, at 10:00,
    /// never on the anchor's own day; the monthly one never asks for a day some months lack.
    @Test func firstReminderIsAboutOnePeriodAway() throws {
        let start = Self.date(2026, 1, 1, 0)
        let day: TimeInterval = 86_400
        for hours in stride(from: 0, to: 366 * 24, by: 1) {
            let anchor = start.addingTimeInterval(TimeInterval(hours) * 3600)
            let weekly = try #require(ScanReminder.components(.weekly, anchor: anchor, calendar: Self.calendar))
            let monthly = try #require(ScanReminder.components(.monthly, anchor: anchor, calendar: Self.calendar))
            #expect(try #require(monthly.day) <= 28)
            let week = try #require(Self.firstFire(weekly, after: anchor)).timeIntervalSince(anchor)
            let month = try #require(Self.firstFire(monthly, after: anchor)).timeIntervalSince(anchor)
            // ± 1 hour: a daylight saving change in between.
            #expect(week > 6 * day - 3600 && week <= 7 * day + 3600, "weekly from \(anchor): \(week / day) days")
            #expect(month >= 27 * day - 3600 && month <= 31 * day + 3600, "monthly from \(anchor): \(month / day) days")
        }
        #expect(ScanReminder.components(.off, anchor: start, calendar: Self.calendar) == nil)
    }
}

/// Settings › General must fit its window without scrolling, in English and Vietnamese, even with the reminder's
/// "notifications are off" row shown.
@MainActor
struct GeneralSettingsLayoutTests {
    @Test(arguments: ["en", "vi"], [false, true])
    func generalSettingsFitsWithoutScrolling(language: String, denied: Bool) async throws {
        let setup = ScanReminderTests.Setup(.weekly, center: FakeReminderCenter(status: .denied), now: .now)
        let host = NSHostingView(rootView: GeneralSettings(reminders: setup.scheduler, reminderDenied: denied)
            .environment(\.locale, Locale(identifier: language))
            .frame(width: SettingsView.size.width, height: SettingsView.size.height))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: SettingsView.size), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(200)) }
        let scroll = try #require(Self.scrollView(in: host))
        let content = try #require(scroll.documentView).frame.height
        let visible = scroll.contentView.bounds.height
        #expect(content <= visible + 1, "\(language), denied \(denied): General needs \(content) pt, shows \(visible) pt")
        window.close()
    }

    static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for subview in view.subviews { if let found = scrollView(in: subview) { return found } }
        return nil
    }
}
