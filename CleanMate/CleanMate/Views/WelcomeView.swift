import SwiftUI
import Combine

/// The update setting the welcome guide changes: Sparkle's own automatic-check setting, through `AppUpdater`.
protocol UpdateCheckSetting: AnyObject {
    var automaticallyChecks: Bool { get set }
}

extension AppUpdater: UpdateCheckSetting {}

/// The welcome guide: what CleanMate does, Full Disk Access, then language, scan reminder and update checks.
/// Shown once on a new install; Help › Getting Started… opens it again. It writes the same settings as
/// Settings › General, and only those the user changes.
final class WelcomeModel: ObservableObject {
    enum Step: Int, CaseIterable {
        case about, fullDiskAccess, options
    }

    @Published private(set) var step = Step.about
    /// Which way the last step change went, so the pages slide the right way.
    private(set) var forward = true
    @Published private(set) var hasFullDiskAccess: Bool
    @Published private(set) var reminderDenied = false

    @Published var language: AppLanguage {
        didSet { if language != oldValue { AppLanguage.set(language, defaults: defaults) } }
    }

    /// Turning a reminder on asks for notification permission the first time, as in Settings.
    @Published var reminder: ScanReminder.Frequency {
        didSet {
            guard reminder != oldValue else { return }
            defaults.set(reminder.rawValue, forKey: Preferences.scanReminder)
            reminderTask = Task { reminderDenied = !(await reminders.update()) }
        }
    }

    /// Sparkle's setting: left untouched, Sparkle still asks on the second launch.
    var automaticallyChecks: Bool {
        get { updater.automaticallyChecks }
        set {
            objectWillChange.send()
            updater.automaticallyChecks = newValue
        }
    }

    /// The last notification update; tests wait for it.
    private(set) var reminderTask: Task<Void, Never>?
    private let defaults: UserDefaults
    private let updater: any UpdateCheckSetting
    private let reminders: ScanReminderScheduler
    private let readAccess: () -> Bool
    private var observer: AnyCancellable?

    init(defaults: UserDefaults = .standard, domain: String = Bundle.main.bundleIdentifier ?? "",
         updater: any UpdateCheckSetting = AppUpdater.shared, reminders: ScanReminderScheduler = .shared,
         readAccess: @escaping () -> Bool = { FullDiskAccess.isGranted }, center: NotificationCenter = .default) {
        self.defaults = defaults
        self.updater = updater
        self.reminders = reminders
        self.readAccess = readAccess
        hasFullDiskAccess = readAccess()
        language = AppLanguage.current(defaults: defaults, domain: domain)
        reminder = ScanReminder.frequency(defaults: defaults)
        // Access is granted in System Settings: read it again when the user comes back.
        observer = center.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refreshAccess() } }
    }

    /// A new install sees the guide at launch; tests and UI snapshots never do. Versions before the guide set
    /// `fullDiskAccessPrompted` at every launch, so its users are not new.
    nonisolated static func showsAtLaunch(defaults: UserDefaults = .standard,
                                          environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["XCTestConfigurationFilePath"] == nil
            && !defaults.bool(forKey: Preferences.welcomeShown)
            && !defaults.bool(forKey: Preferences.fullDiskAccessPrompted)
    }

    func refreshAccess() {
        let granted = readAccess()
        if granted != hasFullDiskAccess { hasFullDiskAccess = granted }
    }

    /// Notification permission may have changed in System Settings; never asks while the reminder is off.
    func refreshNotifications() {
        reminderTask = Task { reminderDenied = !(await reminders.refresh()) }
    }

    func next() {
        guard let step = Step(rawValue: step.rawValue + 1) else { return }
        forward = true
        self.step = step
    }

    func back() {
        guard let step = Step(rawValue: step.rawValue - 1) else { return }
        forward = false
        self.step = step
    }

    /// Skip, Get Started or Restart: the guide does not show at launch any more. Not set when it opens, so a
    /// "Quit & Reopen" from System Settings partway through shows it again.
    func finish() {
        defaults.set(true, forKey: Preferences.welcomeShown)
    }
}

struct WelcomeView: View {
    static let size = CGSize(width: 580, height: 500)
    static let barHeight: CGFloat = 52
    /// Room for a page above the button bar and its divider.
    static var pageHeight: CGFloat { size.height - barHeight - 1 }

    @StateObject private var model: WelcomeModel
    /// Get Started: the window shows the Overview.
    private let onStart: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: @autoclosure @escaping () -> WelcomeModel = WelcomeModel(), onStart: @escaping () -> Void = {}) {
        _model = StateObject(wrappedValue: model())
        self.onStart = onStart
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                page(model.step)
                    .id(model.step)
                    .transition(transition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            Divider()
            buttons.padding(.horizontal, 16).frame(height: Self.barHeight)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    /// Pages slide in the direction of travel; with Reduce Motion they only cross-fade.
    private var transition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let edges: (Edge, Edge) = model.forward ? (.trailing, .leading) : (.leading, .trailing)
        return .asymmetric(insertion: .move(edge: edges.0).combined(with: .opacity),
                           removal: .move(edge: edges.1).combined(with: .opacity))
    }

    @ViewBuilder private func page(_ step: WelcomeModel.Step) -> some View {
        switch step {
        case .about: WelcomeAboutPage()
        case .fullDiskAccess: WelcomeAccessPage(model: model)
        case .options: WelcomeOptionsPage(model: model, finish: model.finish)
        }
    }

    private var buttons: some View {
        HStack {
            if model.step != .options {
                Button("Skip") { close() }
                    .keyboardShortcut(.cancelAction)
            }
            Spacer()
            StepDots(step: model.step)
            Spacer()
            if model.step != .about {
                Button("Back") { move(model.back) }
            }
            if model.step == .options {
                Button("Get Started") {
                    onStart()
                    close()
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Continue") { move(model.next) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func move(_ change: () -> Void) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3), change)
    }

    private func close() {
        model.finish()
        dismiss()
    }
}

/// Where the user is: three dots, the current one filled.
private struct StepDots: View {
    let step: WelcomeModel.Step

    var body: some View {
        HStack(spacing: 6) {
            ForEach(WelcomeModel.Step.allCases, id: \.self) { item in
                Circle()
                    .fill(item == step ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Step \(step.rawValue + 1) of \(WelcomeModel.Step.allCases.count)"))
    }
}

/// Step 1: what CleanMate does and how it removes things.
struct WelcomeAboutPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Welcome to CleanMate").font(.title).bold()
            WelcomeRow(systemImage: Module.smartScan.systemImage, title: Text(Module.smartScan.title),
                       text: Text("System junk, developer leftovers, AI tool data and app caches in one scan."))
            WelcomeRow(systemImage: Module.privacy.systemImage, title: Text(Module.privacy.title),
                       text: Text("Browsing history, cookies and other traces, browser by browser."))
            WelcomeRow(systemImage: Module.uninstaller.systemImage, title: Text(Module.uninstaller.title),
                       text: Text("Removes apps together with the files they leave behind."))
            WelcomeRow(systemImage: Module.spaceLens.systemImage, title: Text(Module.spaceLens.title),
                       text: Text("Shows what takes up space on your disk, folder by folder."))
            Divider()
            WelcomeRow(systemImage: "checkmark.shield", title: Text("Nothing goes without your OK"),
                       text: Text("You see everything first, and nothing is removed until you confirm. Caches and junk that rebuild themselves are deleted; your own files and apps go to the Trash, and Undo puts them back."))
            Text("Open source. CleanMate collects no data: its only network connection is the update check, which you can turn off.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct WelcomeRow: View {
    let systemImage: String
    let title: Text
    let text: Text

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                title.bold()
                text.foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Step 2: why Full Disk Access matters, the button to grant it, and its status read again when the user comes back.
struct WelcomeAccessPage: View {
    @ObservedObject var model: WelcomeModel
    /// While the app is in front: the user may grant access without switching away (System Settings in another Space).
    private let poll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield").font(.system(size: 44)).foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Allow Full Disk Access").font(.title).bold()
            Text("macOS keeps some folders private until you allow Full Disk Access. Without it, Smart Scan skips the Trash, app containers and Group Containers (Telegram, Podcasts, Office…), old files in Downloads, old screenshots, Mail attachments, iPhone backups and Safari data.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                if model.hasFullDiskAccess {
                    Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Label("Not granted", systemImage: "xmark.circle").foregroundStyle(.secondary)
                }
                Button("Open System Settings…") { FullDiskAccess.openSettings() }
                    .disabled(model.hasFullDiskAccess)
            }
            .font(.headline)
            Text("In Privacy & Security › Full Disk Access, turn on CleanMate, then come back here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Text("Optional: CleanMate works without it and cleans everything else. You can grant it later from Settings › General.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: model.refreshAccess)
        .onReceive(poll) { _ in if NSApp.isActive { model.refreshAccess() } }
        .onChange(of: model.hasFullDiskAccess) { granted in
            if granted { announceForAccessibility(String(localized: "Full Disk Access granted")) }
        }
    }
}

/// Step 3: the settings most people want to choose first, with the same keys as Settings › General.
private struct WelcomeOptionsPage: View {
    @ObservedObject var model: WelcomeModel
    let finish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("Your Preferences").font(.title).bold().padding(.top, 24)
            Form {
                Section {
                    LabeledContent("Language") {
                        HStack {
                            if model.language != AppLanguage.atLaunch {
                                Button("Restart") {
                                    finish()
                                    AppLanguage.relaunch()
                                }
                            }
                            Picker("Language", selection: $model.language) {
                                Text("Same as your Mac").tag(AppLanguage.system)
                                Text(verbatim: "English").tag(AppLanguage.english)
                                Text(verbatim: "Tiếng Việt").tag(AppLanguage.vietnamese)
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                } footer: {
                    if model.language != AppLanguage.atLaunch {
                        Text("Restart CleanMate to use the new language. Your Mac's language does not change.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    LabeledContent("Remind me to scan") {
                        HStack {
                            if model.reminderDenied { TurnOnNotificationsButton() }
                            Picker("Remind me to scan", selection: $model.reminder) {
                                Text("Off").tag(ScanReminder.Frequency.off)
                                Text("Weekly").tag(ScanReminder.Frequency.weekly)
                                Text("Monthly").tag(ScanReminder.Frequency.monthly)
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                } footer: {
                    Text("A notification reminds you to run Smart Scan; it never cleans by itself.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Toggle("Automatically check for updates", isOn: $model.automaticallyChecks)
                } footer: {
                    Text("Checking for updates is CleanMate’s only network connection: it asks GitHub whether a new version is out. Nothing about you or your Mac is sent.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Text("All of these can be changed later in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
        }
        .onAppear(perform: model.refreshNotifications)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshNotifications()
        }
    }
}
