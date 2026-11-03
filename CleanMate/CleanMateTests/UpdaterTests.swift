import Foundation
import Sparkle
import Testing
@testable import CleanMate

/// Sparkle configuration. Nothing here starts the updater or reaches the network.
@MainActor
struct UpdaterTests {
    private var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }

    @Test func updaterNeverStartsUnderTests() {
        #expect(!AppUpdater.startsUpdater(environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]))
        #expect(AppUpdater.startsUpdater(environment: [:]))
        // The test host app's window asked it to start: under tests it must not.
        AppUpdater.shared.start()
        #expect(!AppUpdater.shared.isStarted)
    }

    /// Opened at login with the window hidden: Sparkle doesn't start (no prompt or update alert alone at login);
    /// the user opening the window starts it, once.
    @Test func hiddenLoginLaunchStartsTheUpdaterOnlyWhenTheWindowOpens() {
        var starts = 0
        let updater = AppUpdater(environment: [:]) { starts += 1 }
        updater.windowShown(launchingHidden: true)
        #expect(!updater.isStarted && starts == 0)
        updater.windowShown(launchingHidden: false)
        #expect(updater.isStarted && starts == 1)
        updater.windowShown(launchingHidden: false) // the window opened again
        #expect(starts == 1)
    }

    @Test func feedIsTheLatestGitHubRelease() {
        #expect(info["SUFeedURL"] as? String == "https://github.com/homielab/cleanmate-macos/releases/latest/download/appcast.xml")
    }

    @Test func updatesAreVerifiedWithAnEdDSAKey() throws {
        let key = try #require(info["SUPublicEDKey"] as? String)
        #expect(Data(base64Encoded: key)?.count == 32)
        #expect(info["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
    }

    /// Sparkle asks on the second launch only when the app does not preset automatic checks.
    @Test func automaticChecksAreLeftToTheUsersAnswer() {
        #expect(info["SUEnableAutomaticChecks"] == nil)
        #expect(info["SUAutomaticallyUpdate"] == nil)
    }

    @Test func noSystemProfileIsSent() throws {
        #expect(info["SUEnableSystemProfiling"] as? Bool == false)
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main,
                                 userDriver: SPUStandardUserDriver(hostBundle: .main, delegate: nil), delegate: nil)
        #expect(AppUpdater.Delegate().allowedSystemProfileKeys(for: updater) == [])
    }
}
