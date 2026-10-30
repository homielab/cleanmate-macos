import Foundation
import Testing
@testable import CleanMate

@MainActor
struct LowDiskWarningTests {
    static let gb: Int64 = 1_000_000_000

    @MainActor
    final class Setup {
        let defaults: UserDefaults
        let suite = "CleanMateLowDiskWarningTests-\(UUID().uuidString)"
        let center: FakeReminderCenter
        var now = ScanReminderTests.date(2026, 11, 2, 9)
        var volume = SpaceLensModel.Volume(name: "Macintosh HD", total: 100 * gb, available: 8 * gb)
        lazy var checker = LowDiskWarningChecker(center: center, defaults: defaults, now: { [unowned self] in now },
                                                 calendar: ScanReminderTests.calendar, volume: { [unowned self] in volume })

        /// `percent` nil leaves the setting unset (the default).
        init(_ percent: Int?, center: FakeReminderCenter? = nil) {
            defaults = UserDefaults(suiteName: suite)!
            self.center = center ?? FakeReminderCenter(status: .allowed)
            if let percent { defaults.set(percent, forKey: Preferences.lowDiskWarning) }
        }

        var warning: ScanReminder.Request? { center.pending[LowDiskWarning.requestID] }

        func free(_ gigabytes: Int64) { volume.available = gigabytes * gb }

        deinit { defaults.removePersistentDomain(forName: suite) }
    }

    @Test func tenPercentByDefault() {
        let setup = Setup(nil)
        #expect(LowDiskWarning.percent(defaults: setup.defaults) == 10)
        setup.defaults.set(7, forKey: Preferences.lowDiskWarning) // not a Settings choice
        #expect(LowDiskWarning.percent(defaults: setup.defaults) == 10)
        setup.defaults.set(0, forKey: Preferences.lowDiskWarning)
        #expect(LowDiskWarning.percent(defaults: setup.defaults) == 0)
    }

    @Test func warnsWithTheFreeSpaceUnderTheThreshold() async throws {
        let setup = Setup(10)
        #expect(await setup.checker.check())
        let warning = try #require(setup.warning)
        #expect(warning.components == nil) // shown now, not on a schedule
        #expect(!warning.title.isEmpty)
        #expect(warning.body.contains("Macintosh HD"))
        #expect(warning.body.contains((8 * Self.gb).formatted(.byteCount(style: .file))))
        #expect(warning.body.contains(LowDiskWarning.share(8)))
    }

    @Test func noWarningAboveTheThresholdOrWhenOff() async {
        let above = Setup(10)
        above.free(12)
        #expect(await !above.checker.check())
        let off = Setup(0)
        off.free(1)
        #expect(await !off.checker.check())
        #expect(above.center.pending.isEmpty && off.center.calls == 0)
        // An unreadable disk never warns.
        let unknown = Setup(20)
        unknown.volume = SpaceLensModel.Volume()
        #expect(await !unknown.checker.check())
    }

    @Test func thresholdIsStrictAndThePercentRoundsDown() async throws {
        let setup = Setup(10)
        setup.volume.available = 10 * Self.gb // exactly 10 %: not below
        #expect(await !setup.checker.check())
        setup.volume.available = 10 * Self.gb - 1
        #expect(await setup.checker.check())
        #expect(try #require(setup.warning).body.contains(LowDiskWarning.share(9)))
    }

    @Test func atMostOneWarningADay() async {
        let setup = Setup(10)
        #expect(await setup.checker.check())
        setup.now = ScanReminderTests.date(2026, 11, 2, 23, 59)
        #expect(await !setup.checker.check())
        setup.now = ScanReminderTests.date(2026, 11, 3, 0, 1)
        #expect(await setup.checker.check())
    }

    @Test func asksOnceWhenDueAndNeverPostsWhenDenied() async {
        let undecided = Setup(10, center: FakeReminderCenter(grants: true))
        undecided.free(50)
        #expect(await !undecided.checker.check())
        #expect(undecided.center.prompts == 0) // nothing due, nothing asked
        undecided.free(5)
        #expect(await undecided.checker.check())
        #expect(undecided.center.prompts == 1)

        let denied = Setup(10, center: FakeReminderCenter(grants: false))
        #expect(await !denied.checker.check())
        #expect(denied.center.pending.isEmpty)
        // Allowed later in System Settings: the warning is still due today.
        denied.center.status = .allowed
        #expect(await denied.checker.check())
    }

    @Test func settingsAskWhenTurnedOnAndReportDenied() async {
        let setup = Setup(0, center: FakeReminderCenter(grants: false))
        #expect(await setup.checker.update())
        #expect(await setup.checker.refresh())
        #expect(setup.center.calls == 0)
        setup.defaults.set(15, forKey: Preferences.lowDiskWarning)
        #expect(await setup.checker.refresh()) // not asked yet, and refresh never prompts
        #expect(setup.center.prompts == 0)
        #expect(await !setup.checker.update())
        #expect(setup.center.prompts == 1)
        #expect(await !setup.checker.refresh())
    }

    @Test func noCenterUnderTests() async {
        #expect(await !LowDiskWarningChecker.shared.check())
    }
}
