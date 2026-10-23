import SwiftUI

@main
struct CleanMateApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @AppStorage(Preferences.showMenuBarExtra) private var showMenuBarExtra = false

    /// A String, not a literal: the app name is not translated and must not become a catalog key.
    private let appName = "CleanMate"

    var body: some Scene {
        // The main Window must stay the first scene: SwiftUI opens only the first scene at launch,
        // so a MenuBarExtra listed first started the app with no window.
        // Window (not WindowGroup): one main window only, no File › New Window, so two windows
        // can't scan/clean in parallel with separate models.
        Window(appName, id: "main") {
            ContentView()
        }
        .commands { AppCommands() }
        MenuBarExtra(appName, systemImage: "internaldrive", isInserted: $showMenuBarExtra) {
            MenuBarContent()
        }
        Settings {
            SettingsView()
        }
    }
}

/// A lone SwiftUI `Window` scene quits the app when it closes; keep running like a normal Mac app,
/// the Dock icon / `open` brings the window back.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Registered by ContentView (`isChanging`): a clean, move to the Trash, put back or launchctl change is running.
    /// One entry per set of models, keyed by its Smart Scan model, so reopening the window replaces instead of piling up.
    private(set) static var busyChecks: [ObjectIdentifier: () -> Bool?] = [:]

    /// Drops checks whose models are all gone (nil) before adding, so the list never outgrows the live models.
    static func registerBusyCheck(_ id: ObjectIdentifier, _ check: @escaping () -> Bool?) {
        busyChecks = busyChecks.filter { $0.value() != nil }
        busyChecks[id] = check
    }

    static var isBusy: Bool { busyChecks.values.contains { $0() == true } }

    /// ⌘Q or the menu bar's Quit during that asks first: quitting stops it partway, with no report and no Undo.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Self.isBusy else { return .terminateNow }
        let alert = Self.quitAlert()
        // A button holds one key: Return is Cancel's key equivalent, Esc is caught here.
        let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53, event.window === alert.window else { return event }
            alert.buttons[0].performClick(nil)
            return nil
        }
        defer { escape.map(NSEvent.removeMonitor) }
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    /// Cancel first and on Return, Quit Anyway with no key. NSAlert alone gives a button titled
    /// "Cancel" only Esc and any other first button only Return, so the keys depend on the language.
    static func quitAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(localized: "Quit while CleanMate is still working?")
        alert.informativeText = String(localized: "Cleaning or moving to the Trash stops partway: what is done stays done, the rest is left as it is, and there is no Undo.")
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Quit Anyway"))
        alert.layout() // NSAlert assigns its own keys on layout; set ours after
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""
        return alert
    }
}

private struct AppCommands: Commands {
    @FocusedValue(\.scanAgain) private var scanAgain
    @FocusedValue(\.stopScan) private var stopScan
    @FocusedValue(\.moveToTrash) private var moveToTrash
    @FocusedBinding(\.module) private var module
    @FocusedValue(\.confirming) private var confirming

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About CleanMate") {
                let credits = String(localized: "CleanMate collects no data. Its only network connection is the update check.")
                NSApplication.shared.orderFrontStandardAboutPanel(options: [
                    .credits: NSAttributedString(string: credits, attributes: [
                        .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ]),
                ])
            }
            CheckForUpdatesButton(updater: .shared)
        }
        // View menu: ⌘1…⌘6 pick a sidebar module.
        CommandGroup(before: .sidebar) {
            ForEach(Array(Module.allCases.enumerated()), id: \.element) { index, item in
                Button { module = item } label: { Text(item.title) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                    .disabled(module == nil || confirming == true)
            }
            Divider()
        }
        // ⌘⌫ like Finder, but it only opens the confirmation; disabled items don't eat the key, so text fields keep it.
        // Clean (Smart Scan) deliberately has no shortcut.
        CommandGroup(after: .newItem) {
            Button("Move to Trash…") { moveToTrash?() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(moveToTrash == nil || confirming == true)
        }
        CommandMenu("Scan") {
            Button("Scan Again") { scanAgain?() }
                .keyboardShortcut("r")
                .disabled(scanAgain == nil || confirming == true)
            Button("Stop") { stopScan?() }
                .keyboardShortcut(".")
                .disabled(stopScan == nil || confirming == true)
        }
    }
}

/// `.menu` style: the content is built when the menu opens, so free space is read then; no timers.
private struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let volume = SpaceLensModel.Volume.read(SafetyPolicy.current.homeURL)
        Label("\(volume.available, format: .fileSize) free", systemImage: volume.level == .normal ? "internaldrive" : "exclamationmark.triangle.fill")
            .foregroundStyle(volume.level == .critical ? Color.red : volume.level == .low ? Color.orange : Color.primary)
        if let freed = SmartScanView.freedLine(FreedCache.shared.bytes()) {
            Text(freed)
        }
        Divider()
        Button("Open Smart Scan") { show(.smartScan) }
        Button("Open CleanMate") { show(nil) }
        Divider()
        Button("Quit CleanMate") { NSApplication.shared.terminate(nil) }
    }

    private func show(_ module: Module?) {
        let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true })
        // A confirmation open (sheet on the window) keeps its module, like ⌘1…⌘6: only bring the window front.
        ModuleRouter.shared.requested = window?.attachedSheet == nil ? module : nil
        NSApp.activate()
        if let window {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }
}

/// The menu bar extra's "Freed … in the last 30 days": `freedLast30Days` reads both log files, so it is kept
/// until a removal is recorded, or an hour passes (lines older than 30 days drop out of the sum).
final class FreedCache {
    static let shared = FreedCache()
    private let read: () -> Int64
    private var cached: (bytes: Int64, at: Date)?
    private var observer: (any NSObjectProtocol)?

    init(center: NotificationCenter = .default, read: @escaping () -> Int64 = { SmartScanView.freedLast30Days }) {
        self.read = read
        observer = center.addObserver(forName: ActivityLog.didRecord, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cached = nil }
        }
    }

    func bytes(now: Date = .now) -> Int64 {
        if let cached, now.timeIntervalSince(cached.at) < 3600 { return cached.bytes }
        let bytes = read()
        cached = (bytes, now)
        return bytes
    }
}
