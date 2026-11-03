import AppKit
import Foundation
import ServiceManagement
import Testing
@testable import CleanMate

/// Stands in for `SMAppService.mainApp`: tests never add the test host to Login Items.
final class FakeLoginItem: LoginItemService {
    var status: SMAppService.Status
    /// What `register` leaves: `.requiresApproval` when the user has not allowed CleanMate in System Settings.
    var registersAs: SMAppService.Status = .enabled
    var refuses = false
    private(set) var registers = 0
    private(set) var unregisters = 0

    init(_ status: SMAppService.Status = .notRegistered) { self.status = status }

    struct Refused: Error {}

    func register() throws {
        registers += 1
        if refuses { throw Refused() }
        status = registersAs
    }

    func unregister() throws {
        unregisters += 1
        status = .notRegistered
    }
}

/// Open at login, the login launch with no window, and the Dock icon with Menu bar only.
@MainActor
final class BackgroundModeTests {
    let suite = TestDefaults.suite("CleanMateBackgroundModeTests")
    let defaults: UserDefaults

    init() { defaults = UserDefaults(suiteName: suite)! }

    deinit { TestDefaults.remove(suite) }

    @Test func openAtLoginIsOffByDefaultAndFollowsTheService() {
        let service = FakeLoginItem()
        let login = OpenAtLogin(service: service)
        #expect(login.state == .off)
        #expect(login.set(true) == .on)
        #expect(service.registers == 1 && service.status == .enabled)
        #expect(login.set(false) == .off)
        #expect(service.unregisters == 1 && service.status == .notRegistered)
        // Not registered: nothing to remove, macOS is not asked.
        login.set(false)
        #expect(service.unregisters == 1)
    }

    @Test func refusedOrUnapprovedLoginNeedsApproval() {
        let service = FakeLoginItem()
        service.registersAs = .requiresApproval
        let login = OpenAtLogin(service: service)
        #expect(login.set(true) == .needsApproval)
        #expect(login.state == .needsApproval)

        let refused = FakeLoginItem()
        refused.refuses = true
        #expect(OpenAtLogin(service: refused).set(true) == .needsApproval)
        #expect(OpenAtLogin.state(.notFound) == .off)
    }

    @Test func turningTheMenuBarItemOffRemovesTheLoginItem() {
        let service = FakeLoginItem(.enabled)
        let login = OpenAtLogin(service: service)
        login.menuBarChanged(on: true)
        #expect(service.unregisters == 0)
        login.menuBarChanged(on: false)
        #expect(service.unregisters == 1 && login.state == .off)
        login.menuBarChanged(on: false)
        #expect(service.unregisters == 1)
    }

    static func openEvent(loginItem: Bool) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
                                           targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        if loginItem {
            event.setParam(NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)), forKeyword: AEKeyword(keyAEPropData))
        }
        return event
    }

    @Test func onlyALoginItemLaunchStartsHiddenAndOnlyWithTheMenuBarItem() {
        #expect(BackgroundMode.isLoginLaunch(Self.openEvent(loginItem: true)))
        #expect(!BackgroundMode.isLoginLaunch(Self.openEvent(loginItem: false)))
        #expect(!BackgroundMode.isLoginLaunch(nil))

        #expect(!BackgroundMode.startsHidden(loginLaunch: true, defaults: defaults), "no menu bar item: the window shows")
        defaults.set(true, forKey: Preferences.showMenuBarExtra)
        #expect(BackgroundMode.startsHidden(loginLaunch: true, defaults: defaults))
        #expect(!BackgroundMode.startsHidden(loginLaunch: false, defaults: defaults))
    }

    @Test func dockIconLeavesOnlyWithTheWindowClosedInMenuBarOnlyMode() {
        // Default (and 1.7 users): always in the Dock.
        #expect(BackgroundMode.policy(windowOpen: false, defaults: defaults) == .regular)
        defaults.set(true, forKey: Preferences.menuBarOnly)
        #expect(BackgroundMode.policy(windowOpen: false, defaults: defaults) == .regular, "menu bar item off: never hidden")
        defaults.set(true, forKey: Preferences.showMenuBarExtra)
        #expect(BackgroundMode.policy(windowOpen: false, defaults: defaults) == .accessory)
        #expect(BackgroundMode.policy(windowOpen: true, defaults: defaults) == .regular)
    }
}
