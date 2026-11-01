import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CleanMate

/// Stands in for Sparkle: tests never touch the real updater's preferences.
final class FakeUpdateCheck: UpdateCheckSetting {
    var value: Bool
    private(set) var writes = 0

    init(_ value: Bool = false) { self.value = value }

    var automaticallyChecks: Bool {
        get { value }
        set { value = newValue; writes += 1 }
    }
}

/// Welcome guide: when it shows, what its last step writes, and the live Full Disk Access status.
@MainActor
final class WelcomeTests {
    let suite = "CleanMateWelcomeTests-\(UUID().uuidString)"
    let defaults: UserDefaults
    let center = FakeReminderCenter()
    let updater = FakeUpdateCheck()
    let notifications = NotificationCenter()
    var granted = false

    init() { defaults = UserDefaults(suiteName: suite)! }

    deinit { UserDefaults().removePersistentDomain(forName: suite) }

    func model() -> WelcomeModel {
        WelcomeModel(defaults: defaults, domain: suite, updater: updater,
                     reminders: ScanReminderScheduler(center: center, defaults: defaults),
                     readAccess: { [unowned self] in granted }, center: notifications)
    }

    var stored: [String: Any] { defaults.persistentDomain(forName: suite) ?? [:] }

    @Test func showsOnlyOnAFreshInstallOutsideTests() {
        #expect(WelcomeModel.showsAtLaunch(defaults: defaults, environment: [:]))
        #expect(!WelcomeModel.showsAtLaunch(defaults: defaults, environment: ["XCTestConfigurationFilePath": "/tmp/x"]))
        // Versions before the guide set this at every launch: their users are not new.
        defaults.set(true, forKey: Preferences.fullDiskAccessPrompted)
        #expect(!WelcomeModel.showsAtLaunch(defaults: defaults, environment: [:]))
    }

    @Test func closingTheGuideKeepsItFromShowingAgain() {
        let model = model()
        model.next()
        #expect(WelcomeModel.showsAtLaunch(defaults: defaults, environment: [:]), "opening it is not seeing it")
        model.finish()
        #expect(!WelcomeModel.showsAtLaunch(defaults: defaults, environment: [:]))
        #expect(defaults.bool(forKey: Preferences.welcomeShown))
    }

    @Test func stepsGoForwardAndBackWithinBounds() {
        let model = model()
        model.back()
        #expect(model.step == .about)
        model.next(); model.next(); model.next()
        #expect(model.step == .options && model.forward)
        model.back()
        #expect(model.step == .fullDiskAccess && !model.forward)
    }

    /// Reopened from the Help menu, it shows the current settings and writes nothing nor asks for anything.
    @Test func openingChangesNoSettingAndAsksNothing() async {
        AppLanguage.set(.vietnamese, defaults: defaults)
        defaults.set(ScanReminder.Frequency.weekly.rawValue, forKey: Preferences.scanReminder)
        updater.value = true
        let before = stored as NSDictionary
        let model = model()
        #expect(model.language == .vietnamese && model.reminder == .weekly && model.automaticallyChecks)
        model.next(); model.next()
        model.finish()
        defaults.removeObject(forKey: Preferences.welcomeShown)
        #expect(stored as NSDictionary == before)
        #expect(updater.writes == 0)
        #expect(center.prompts == 0)
    }

    /// Step 3 writes the keys Settings › General reads, and no others.
    @Test func optionsWriteTheSettingsKeys() async {
        let model = model()
        model.language = .vietnamese
        model.reminder = .monthly
        await model.reminderTask?.value
        model.automaticallyChecks = true

        #expect(AppLanguage.current(defaults: defaults, domain: suite) == .vietnamese)
        #expect(ScanReminder.frequency(defaults: defaults) == .monthly)
        #expect(defaults.string(forKey: Preferences.scanReminder) == "monthly") // @AppStorage in GeneralSettings
        #expect(updater.value && updater.writes == 1) // Sparkle's own setting, through AppUpdater
        #expect(Set(stored.keys) == [AppLanguage.key, Preferences.scanReminder])
        // The scan reminder asks for notifications the first time it is turned on, as in Settings.
        #expect(center.prompts == 1)
        #expect(center.pending[ScanReminder.requestID] != nil)
        #expect(!model.reminderDenied)

        model.language = .system
        model.reminder = .off
        await model.reminderTask?.value
        #expect(AppLanguage.current(defaults: defaults, domain: suite) == .system)
        #expect(stored[AppLanguage.key] == nil)
        #expect(center.pending.isEmpty)
    }

    @Test func refusedNotificationsShowTheButton() async {
        center.grants = false
        let model = model()
        model.reminder = .weekly
        await model.reminderTask?.value
        #expect(model.reminderDenied)
    }

    /// The status changes when the user comes back from System Settings, without restarting.
    @Test func fullDiskAccessIsReadAgainOnReturn() {
        let model = model()
        #expect(!model.hasFullDiskAccess)
        granted = true
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(model.hasFullDiskAccess)
        granted = false
        model.refreshAccess()
        #expect(!model.hasFullDiskAccess)
    }

    /// Steps 1 and 2 fit the sheet above its button bar in both languages.
    @Test(arguments: ["en", "vi"])
    func pagesFitTheSheet(language: String) {
        let pages: [(String, AnyView)] = [("about", AnyView(WelcomeAboutPage())),
                                          ("access", AnyView(WelcomeAccessPage(model: model())))]
        for (name, page) in pages {
            let host = NSHostingView(rootView: page
                .environment(\.locale, Locale(identifier: language))
                .frame(width: WelcomeView.size.width))
            let height = host.fittingSize.height
            #expect(height <= WelcomeView.pageHeight, "\(language) \(name): needs \(height) pt of \(WelcomeView.pageHeight)")
        }
    }
}
