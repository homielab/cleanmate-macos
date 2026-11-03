import Foundation
import Testing
@testable import CleanMate

/// "Freed X" after a Smart Scan or Privacy clean, through a fake notification center.
@MainActor
struct CleanFinishedNoticeTests {
    static func report(_ freed: Int64) -> CleanReport { var report = CleanReport(); report.freed = freed; return report }

    @Test func postsOnlyWhileInTheBackgroundWithNotificationsAllowed() async {
        let center = FakeReminderCenter(status: .allowed)
        var active = true
        let notifier = CleanFinishedNotifier(center: center, isActive: { active })
        #expect(await !notifier.post(Self.report(5_000_000), module: .smartScan))
        #expect(center.pending.isEmpty)
        active = false
        #expect(await notifier.post(Self.report(5_000_000), module: .smartScan))
        let request = center.pending[CleanFinishedNotice.smartScanID]
        #expect(request?.components == nil)
        #expect(request?.title.hasSuffix("5 MB") == true, "\(String(describing: request))")
        #expect(center.prompts == 0)
    }

    /// Never asks for permission: without it, nothing is posted.
    @Test func neverAsksForPermission() async {
        for status in [ReminderAuthorization.notDetermined, .denied] {
            let center = FakeReminderCenter(status: status)
            let notifier = CleanFinishedNotifier(center: center, isActive: { false })
            #expect(await !notifier.post(Self.report(1_000), module: .privacy))
            #expect(center.pending.isEmpty && center.prompts == 0)
        }
    }

    @Test func onlySmartScanAndPrivacyPostAndAClickOpensThem() async {
        let center = FakeReminderCenter(status: .allowed)
        let notifier = CleanFinishedNotifier(center: center, isActive: { false })
        #expect(await !notifier.post(Self.report(1_000), module: .largeFiles))
        #expect(await notifier.post(Self.report(0), module: .privacy))
        #expect(Set(center.pending.keys) == [CleanFinishedNotice.privacyID])
        #expect(CleanFinishedNotice.module(forRequestID: CleanFinishedNotice.smartScanID) == .smartScan)
        #expect(CleanFinishedNotice.module(forRequestID: CleanFinishedNotice.privacyID) == .privacy)
        #expect(CleanFinishedNotice.module(forRequestID: ScanReminder.requestID) == nil)
    }

    @Test func titleSaysWhatWasFreedInTheAppLanguage() {
        let en = Locale(identifier: "en_US"), vi = Locale(identifier: "vi")
        #expect(CleanFinishedNotice.request(Self.report(5_000_000), module: .smartScan, locale: en)?.title == "Freed 5 MB")
        #expect(CleanFinishedNotice.request(Self.report(0), module: .smartScan, locale: en)?.title == "Cleaning finished")
        #expect(CleanFinishedNotice.request(Self.report(0), module: .privacy, locale: en)?.title == "Privacy items erased")
        let vietnamese = CleanFinishedNotice.request(Self.report(5_000_000), module: .smartScan, locale: vi)
        #expect(vietnamese?.title == "Đã giải phóng 5 MB", "\(String(describing: vietnamese))")
    }
}
