import AppKit
import ServiceManagement

/// What CleanMate needs from `SMAppService`; tests pass a fake so they never add the test host to Login Items.
protocol LoginItemService: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemService {}

/// Settings › General › Open at login: CleanMate itself as a login item (`SMAppService.mainApp`), off by default.
/// macOS keeps the setting, so it is read again each time it is shown; nothing is stored in CleanMate's defaults.
final class OpenAtLogin {
    enum State: Equatable {
        case off, on
        /// Registered but not allowed yet, or refused: the user allows it in System Settings › General › Login Items.
        case needsApproval
    }

    static let shared = OpenAtLogin()
    private let service: any LoginItemService

    init(service: any LoginItemService = SMAppService.mainApp) {
        self.service = service
    }

    var state: State { Self.state(service.status) }

    nonisolated static func state(_ status: SMAppService.Status) -> State {
        switch status {
        case .enabled: .on
        case .requiresApproval: .needsApproval
        default: .off
        }
    }

    /// Adds or removes CleanMate from Login Items and returns the state macOS reports afterwards. A refused
    /// registration counts as needing approval: System Settings is where the user can allow it.
    @discardableResult
    func set(_ on: Bool) -> State {
        do {
            if on { try service.register() } else if service.status != .notRegistered { try service.unregister() }
        } catch {
            if on, state != .on { return .needsApproval }
        }
        return state
    }

    /// Turning the menu bar item off also turns this off: CleanMate would start at login with nothing to show.
    func menuBarChanged(on: Bool) {
        if !on, state != .off { set(false) }
    }

    static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// CleanMate as a menu bar app: started at login with no window, and with **Menu bar only** out of the
/// Dock and ⌘Tab while its window is closed. It never scans nor cleans by itself in either case.
final class BackgroundMode {
    static let shared = BackgroundMode()

    /// Started at login with the menu bar item on: the first main window is hidden (made transparent, then closed
    /// once ContentView has set up), and the app stays out of the Dock until a window is opened.
    private(set) var launchingHidden = false
    private var observers: [NSObjectProtocol] = []
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// macOS marks the open-application event of a login item launch with `keyAELaunchedAsLogInItem`.
    nonisolated static func isLoginLaunch(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    /// A login launch starts with no window only while the menu bar item is on: otherwise nothing would show.
    nonisolated static func startsHidden(loginLaunch: Bool, defaults: UserDefaults) -> Bool {
        loginLaunch && defaults.bool(forKey: Preferences.showMenuBarExtra)
    }

    /// Menu bar only takes effect only with the menu bar item on, so CleanMate can always be reopened.
    nonisolated static func menuBarOnly(defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: Preferences.showMenuBarExtra) && defaults.bool(forKey: Preferences.menuBarOnly)
    }

    /// In the Dock while the main window is open, and with it closed unless Menu bar only is on.
    nonisolated static func policy(windowOpen: Bool, defaults: UserDefaults) -> NSApplication.ActivationPolicy {
        windowOpen || !menuBarOnly(defaults: defaults) ? .regular : .accessory
    }

    private static func isMain(_ window: Any?) -> Bool {
        (window as? NSWindow)?.identifier?.rawValue.hasPrefix("main") == true
    }

    /// From `applicationDidFinishLaunching`: hides a login launch and follows the main window to and from the Dock.
    func start(loginLaunch: Bool) {
        if Self.startsHidden(loginLaunch: loginLaunch, defaults: defaults) {
            launchingHidden = true
            NSApp.setActivationPolicy(.accessory)
            ModuleRouter.mainWindow?.alphaValue = 0
            hideLaunchWindow()
            // Should no window ever come (none restored), the Dock and window rules apply again.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.launchingHidden = false }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, Self.isMain(note.object), !self.launchingHidden,
                      Self.policy(windowOpen: false, defaults: self.defaults) == .accessory else { return }
                NSApp.setActivationPolicy(.accessory)
            }
        })
        // Also when Finder or `open` brings the window back, not only the menu bar.
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, Self.isMain(note.object), !self.launchingHidden else { return }
                Self.showInDock()
            }
        })
    }

    /// The login launch's window: closed once ContentView has appeared (it keeps the action that reopens the window
    /// and starts the updater), so CleanMate shows only in the menu bar. Called at launch and by ContentView.
    func hideLaunchWindow() {
        guard launchingHidden, let window = ModuleRouter.mainWindow else { return }
        window.alphaValue = 0
        guard ModuleRouter.shared.openMainWindow != nil else { return }
        // Next turn of the run loop: not from inside SwiftUI's onAppear.
        DispatchQueue.main.async { [weak self] in
            window.close()
            window.alphaValue = 1
            self?.launchingHidden = false
        }
    }

    /// A setting changed in Settings or the welcome guide: the Dock icon follows at once.
    func apply() {
        guard !launchingHidden else { return }
        let open = ModuleRouter.mainWindow?.isVisible == true
        let policy = Self.policy(windowOpen: open, defaults: defaults)
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    /// Before the window comes front: back in the Dock and ⌘Tab, with the app's menus.
    static func showInDock() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    }
}
