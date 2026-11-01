import Foundation
import UserNotifications

/// Settings › General › "Remind me to scan": a local notification, repeated weekly or monthly, that opens Smart Scan.
/// macOS schedules and shows it: no network, nothing leaves the Mac. Off by default.
nonisolated enum ScanReminder {
    enum Frequency: String, CaseIterable, Sendable {
        case off, weekly, monthly
    }

    /// The one pending request; adding it again replaces it.
    static let requestID = "scanReminder"
    /// Reminders come at 10:00 local time.
    static let hour = 10
    /// Highest day of the month used: every month has it, so a monthly reminder never skips a month.
    static let lastDay = 28

    /// What the notification center gets: Sendable, so tests can inspect it without UserNotifications objects.
    struct Request: Equatable, Sendable {
        var id = requestID
        var title: String
        var body: String
        /// Matched by a repeating calendar trigger; nil = shown now, once (the low-disk warning).
        var components: DateComponents?
    }

    static func frequency(defaults: UserDefaults = .standard) -> Frequency {
        defaults.string(forKey: Preferences.scanReminder).flatMap(Frequency.init) ?? .off
    }

    /// Trigger components for a reminder about one period after `anchor`: 10:00 on the anchor's weekday (weekly) or
    /// day of the month, at most the 28th (monthly). Before 10:00 the day before is used, so that day's 10:00 is
    /// already past and the first reminder never comes the same day. nil when off.
    static func components(_ frequency: Frequency, anchor: Date, calendar: Calendar = .current) -> DateComponents? {
        var day = anchor
        if calendar.component(.hour, from: anchor) < hour, let previous = calendar.date(byAdding: .day, value: -1, to: anchor) {
            day = previous
        }
        switch frequency {
        case .off: return nil
        case .weekly: return DateComponents(hour: hour, minute: 0, weekday: calendar.component(.weekday, from: day))
        case .monthly: return DateComponents(day: min(calendar.component(.day, from: day), lastDay), hour: hour, minute: 0)
        }
    }

    static func request(_ frequency: Frequency, anchor: Date, calendar: Calendar = .current) -> Request? {
        components(frequency, anchor: anchor, calendar: calendar).map {
            Request(title: String(localized: "Time for a Smart Scan"),
                    body: String(localized: "Scan your Mac to see how much space you can free up."),
                    components: $0)
        }
    }
}

/// Notification permission, as far as the reminder cares.
nonisolated enum ReminderAuthorization: Sendable {
    case notDetermined, denied, allowed
}

/// The parts of `UNUserNotificationCenter` the reminder uses; tests inject a fake so they never touch the real one.
protocol ReminderCenter {
    func authorization() async -> ReminderAuthorization
    /// Shows the system prompt (only the first time); true when allowed.
    func requestAuthorization() async -> Bool
    func add(_ request: ScanReminder.Request) async
    func removePending(id: String)
}

/// The real notification center, reached only when a method is called.
nonisolated struct SystemReminderCenter: ReminderCenter {
    func authorization() async -> ReminderAuthorization {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                let status: ReminderAuthorization = switch settings.authorizationStatus {
                case .notDetermined: .notDetermined
                case .denied: .denied
                default: .allowed // authorized, provisional
                }
                continuation.resume(returning: status)
            }
        }
    }

    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    func add(_ request: ScanReminder.Request) async {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        let trigger = request.components.map { UNCalendarNotificationTrigger(dateMatching: $0, repeats: true) }
        let notification = UNNotificationRequest(identifier: request.id, content: content, trigger: trigger)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            UNUserNotificationCenter.current().add(notification) { _ in continuation.resume() }
        }
    }

    func removePending(id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }
}

/// Keeps the pending reminder in line with Settings, and moves it one period away whenever CleanMate launches or
/// Smart Scan finishes, so it only comes when the app has gone unused that long.
final class ScanReminderScheduler {
    /// No center under tests: they must never reach the real notification center.
    static let shared = ScanReminderScheduler(
        center: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil ? SystemReminderCenter() : nil)

    private let center: (any ReminderCenter)?
    private let defaults: UserDefaults
    private let now: () -> Date
    private let calendar: Calendar

    init(center: (any ReminderCenter)?, defaults: UserDefaults = .standard, now: @escaping () -> Date = { .now },
         calendar: Calendar = .current) {
        self.center = center
        self.defaults = defaults
        self.now = now
        self.calendar = calendar
    }

    /// Settings changed (or shown): off removes the reminder; on asks for permission the first time, then schedules it.
    /// Returns false when notifications are not allowed, so Settings shows how to allow them.
    @discardableResult
    func update() async -> Bool {
        guard let center else { return true }
        let frequency = ScanReminder.frequency(defaults: defaults)
        guard frequency != .off else {
            center.removePending(id: ScanReminder.requestID)
            return true
        }
        var status = await center.authorization()
        if status == .notDetermined { status = await center.requestAuthorization() ? .allowed : .denied }
        return await schedule(frequency, status: status)
    }

    /// Settings shown, or CleanMate back in front (permission may have changed in System Settings): `update` while
    /// reminders are on; does nothing while they are off.
    func refresh() async -> Bool {
        ScanReminder.frequency(defaults: defaults) == .off ? true : await update()
    }

    /// Launch and finished Smart Scan: moves the reminder one period from now. Never asks for permission, and does
    /// not touch the notification center at all while reminders are off.
    func postpone() async {
        guard let center else { return }
        let frequency = ScanReminder.frequency(defaults: defaults)
        guard frequency != .off else { return }
        await schedule(frequency, status: await center.authorization())
    }

    @discardableResult
    private func schedule(_ frequency: ScanReminder.Frequency, status: ReminderAuthorization) async -> Bool {
        guard let center else { return true }
        guard status == .allowed else {
            center.removePending(id: ScanReminder.requestID)
            return false
        }
        if let request = ScanReminder.request(frequency, anchor: now(), calendar: calendar) { await center.add(request) }
        return true
    }
}
