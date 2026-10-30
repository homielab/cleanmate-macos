import Foundation

/// Settings › General › "Warn when free space is below": a local notification when the disk holding the home folder
/// (the one the menu bar item shows) has less free space than the chosen share of its size. Checked at launch, after
/// Smart Scan scans or cleans, and every hour while CleanMate runs; at most one warning a day. No network.
nonisolated enum LowDiskWarning {
    /// The warning in the notification center; a new one replaces the last.
    static let requestID = "lowDiskWarning"
    /// Settings choices, in percent of the disk's size; 0 = off.
    static let choices = [0, 5, 10, 15, 20]
    static let defaultPercent = 10
    /// Between two checks while CleanMate runs.
    static let checkInterval: TimeInterval = 3600

    /// The threshold in Settings; the default when unset or not one of `choices`.
    static func percent(defaults: UserDefaults = .standard) -> Int {
        guard let value = defaults.object(forKey: Preferences.lowDiskWarning) as? Int, choices.contains(value) else {
            return defaultPercent
        }
        return value
    }

    /// Free space under `percent` of the disk's size; never for an unreadable disk or while off.
    static func isLow(_ volume: SpaceLensModel.Volume, below percent: Int) -> Bool {
        percent > 0 && volume.total > 0 && volume.available * 100 < volume.total * Int64(percent)
    }

    /// Whole percent free, rounded down: 9.8 % free under a 10 % threshold reads "9%", never "10%".
    static func freePercent(_ volume: SpaceLensModel.Volume) -> Int {
        volume.total > 0 ? Int(volume.available * 100 / volume.total) : 0
    }

    /// "10%" in the app's language.
    static func share(_ percent: Int) -> String {
        (Double(percent) / 100).formatted(.percent.precision(.fractionLength(0)))
    }

    static func request(_ volume: SpaceLensModel.Volume) -> ScanReminder.Request {
        let size = volume.available.formatted(.byteCount(style: .file))
        let free = share(freePercent(volume))
        let body = volume.name.isEmpty
            ? String(localized: "Your disk has \(size) free (\(free)). Open CleanMate to free up space.")
            : String(localized: "“\(volume.name)” has \(size) free (\(free)). Open CleanMate to free up space.")
        return ScanReminder.Request(id: requestID, title: String(localized: "Your disk is almost full"), body: body,
                                    components: nil)
    }
}

/// Checks free space and posts the warning through the same notification center as the scan reminder.
final class LowDiskWarningChecker {
    /// No center under tests: they must never reach the real notification center.
    static let shared = LowDiskWarningChecker(
        center: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil ? SystemReminderCenter() : nil)

    private let center: (any ReminderCenter)?
    private let defaults: UserDefaults
    private let now: () -> Date
    private let calendar: Calendar
    private let volume: () -> SpaceLensModel.Volume
    /// A check waiting for the notification center: another one (timer, scan) must not post a second warning.
    private var checking = false

    init(center: (any ReminderCenter)?, defaults: UserDefaults = .standard, now: @escaping () -> Date = { .now },
         calendar: Calendar = .current,
         volume: @escaping () -> SpaceLensModel.Volume = { .read(SafetyPolicy.current.homeURL) }) {
        self.center = center
        self.defaults = defaults
        self.now = now
        self.calendar = calendar
        self.volume = volume
    }

    /// Posts the warning when free space is under the threshold and none was posted today. macOS asks for permission
    /// the first time a warning is due. Returns true when one was posted.
    @discardableResult
    func check() async -> Bool {
        guard let center, !checking, !warnedToday else { return false }
        let disk = volume()
        guard LowDiskWarning.isLow(disk, below: LowDiskWarning.percent(defaults: defaults)) else { return false }
        checking = true
        defer { checking = false }
        var status = await center.authorization()
        if status == .notDetermined { status = await center.requestAuthorization() ? .allowed : .denied }
        guard status == .allowed else { return false }
        await center.add(LowDiskWarning.request(disk))
        defaults.set(now(), forKey: Preferences.lowDiskWarned)
        return true
    }

    /// Settings changed: turning the warning on asks for permission the first time. Returns false when notifications
    /// are not allowed, so Settings shows how to allow them.
    func update() async -> Bool {
        guard let center, LowDiskWarning.percent(defaults: defaults) > 0 else { return true }
        var status = await center.authorization()
        if status == .notDetermined { status = await center.requestAuthorization() ? .allowed : .denied }
        return status != .denied
    }

    /// Settings shown, or CleanMate back in front: false when the warning is on but notifications are turned off.
    /// Never asks for permission.
    func refresh() async -> Bool {
        guard let center, LowDiskWarning.percent(defaults: defaults) > 0 else { return true }
        return await center.authorization() != .denied
    }

    private var warnedToday: Bool {
        (defaults.object(forKey: Preferences.lowDiskWarned) as? Date).map { calendar.isDate($0, inSameDayAs: now()) } ?? false
    }
}
