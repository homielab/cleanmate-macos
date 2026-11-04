import SwiftUI
import Combine

/// Sidebar modules.
enum Module: String, CaseIterable, Identifiable {
    case overview
    case smartScan
    case privacy
    case largeFiles
    case uninstaller
    case spaceLens
    case loginItems
    case maintenance

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .overview: "Overview"
        case .smartScan: "Smart Scan"
        case .privacy: "Privacy"
        case .largeFiles: "Large & Old Files"
        case .uninstaller: "Uninstaller"
        case .spaceLens: "Space Lens"
        case .loginItems: "Login Items"
        case .maintenance: "Maintenance"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "house"
        case .smartScan: "sparkles"
        case .privacy: "hand.raised"
        case .largeFiles: "doc.badge.clock"
        case .uninstaller: "xmark.app"
        case .spaceLens: "chart.pie"
        case .loginItems: "power"
        case .maintenance: "wrench.and.screwdriver"
        }
    }

    /// Sidebar badge after a scan: what Clean will free for Smart Scan/Privacy; for Large & Old Files the files found,
    /// or in Duplicate Files what the ticked copies free once some are ticked.
    enum Badge: Equatable { case size(Int64), files(Int) }

    /// nil (no badge) without results or when there is nothing to show; other modules never get one.
    func badge(hasResults: Bool, size: Int64 = 0, files: Int = 0) -> Badge? {
        guard hasResults else { return nil }
        switch self {
        case .smartScan, .privacy: return size > 0 ? .size(size) : nil // Privacy records have no size: no badge
        case .largeFiles: return size > 0 ? .size(size) : files > 0 ? .files(files) : nil
        case .overview, .uninstaller, .spaceLens, .loginItems, .maintenance: return nil
        }
    }
}

/// Module requested from outside the window (menu bar item, scan reminder); ContentView consumes it, also on first appearance.
final class ModuleRouter: ObservableObject {
    static let shared = ModuleRouter()
    @Published var requested: Module?
    /// "Show in Space Lens": Space Lens opens this item's folder with the item selected.
    @Published var spaceLensItem: URL?
    /// Overview's largest folders: Space Lens opens this folder.
    @Published var spaceLensFolder: URL?
    /// Menu bar "Scan Now": ContentView switches to Smart Scan and starts a scan, also on first appearance.
    @Published var scanRequested = false
    /// Help › Getting Started…: ContentView opens the welcome guide, also on first appearance.
    @Published var welcomeRequested = false
    /// "View Moved Items…": ContentView opens Moved to the Trash, also on first appearance.
    @Published var trashedItemsRequested = false
    /// Overview › Suggestions: ContentView opens the module on what the suggestion is about.
    @Published var suggestion: Suggestion.Target?
    /// When the suggestion being opened was measured (`Suggestion.measuredAt`).
    var suggestionMeasuredAt: Date?
    /// Shortcuts' Clean Selected Junk: ContentView opens Smart Scan's review, also on first appearance.
    @Published var cleanReviewRequested = false
    /// Reopens the main window after it was closed; kept by ContentView (the scan reminder has no SwiftUI environment).
    var openMainWindow: OpenWindowAction?

    /// Menu bar "Scan Now" is disabled, like ⌘R, while a confirmation (a sheet on the main window) is open, and while
    /// something is being cleaned or moved to the Trash.
    static func canScanNow(sheetOpen: Bool, busy: Bool) -> Bool { !sheetOpen && !busy }

    static var mainWindow: NSWindow? { NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) }

    var canScanNow: Bool { Self.canScanNow(sheetOpen: Self.mainWindow?.attachedSheet != nil, busy: AppModels.shared.isChanging) }

    /// Opens the main window on Smart Scan and starts a scan.
    func scanNow(openWindow: OpenWindowAction? = nil) {
        guard canScanNow else { return }
        scanRequested = true
        show(.smartScan, openWindow: openWindow)
    }

    /// Shortcuts' Clean Selected Junk: Smart Scan's review of the ticked junk, scanning first without results. Only the
    /// review opens; nothing is removed until the user confirms there. A confirmation open on the window keeps it.
    func reviewClean() {
        guard Self.mainWindow?.attachedSheet == nil else { show(nil); NSSound.beep(); return }
        cleanReviewRequested = true
        show(.smartScan)
    }

    /// Opens the welcome guide on the main window (reopened if closed); settings are not changed by opening it.
    func showWelcome() {
        welcomeRequested = true
        show(nil)
    }

    /// Opens Moved to the Trash on the main window (reopened if closed), from a module, an alert or Settings.
    func showTrashedItems() {
        trashedItemsRequested = true
        show(nil)
    }

    /// Overview › Suggestions: the module where the user decides, showing what the suggestion is about. Nothing is
    /// ticked or cleaned. A confirmation open on the window keeps it.
    func open(_ target: Suggestion.Target, measuredAt: Date? = nil) {
        guard Self.mainWindow?.attachedSheet == nil else { NSSound.beep(); return }
        suggestionMeasuredAt = measuredAt
        suggestion = target
        show(target.module)
    }

    /// Brings the main window front (reopened if closed) on `module`, nil = the module already shown.
    func show(_ module: Module?, openWindow: OpenWindowAction? = nil) {
        let window = Self.mainWindow
        // A confirmation open (sheet on the window) keeps its module, like ⌘1…⌘8: only bring the window front.
        requested = window?.attachedSheet == nil ? module : nil
        BackgroundMode.showInDock() // out of it while the window was closed with Menu bar only
        NSApp.activate(ignoringOtherApps: true) // macOS 14+ ignores the flag, like `activate()` (macOS 14)
        if let window {
            window.makeKeyAndOrderFront(nil)
        } else {
            (openWindow ?? openMainWindow)?(id: "main")
        }
    }
}

struct ContentView: View {
    @ObservedObject private var router = ModuleRouter.shared
    @State private var selection: Module? = .overview
    /// Owned by the app, not this view: closing the window keeps results and running scans, reopening shows them.
    let models: AppModels
    @ObservedObject private var overview: OverviewModel
    @ObservedObject private var smartScan: SmartScanModel
    @ObservedObject private var privacy: SmartScanModel
    @ObservedObject private var largeFiles: LargeFilesModel
    @ObservedObject private var uninstaller: UninstallerModel
    @ObservedObject private var spaceLens: SpaceLensModel
    @ObservedObject private var loginItems: LaunchAgentsModel
    @ObservedObject private var maintenance: MaintenanceModel
    @State private var showsWelcome = false
    @State private var showsTrashedItems = false
    @Environment(\.openWindow) private var openWindow
    /// The app's own window: opens on the module shown last and keeps its frame. Off in the benchmark's window and in
    /// the test host, so tests never read or write the user's settings.
    private let remembers: Bool

    /// Opens on the module shown last (Overview the first time); the menu bar, a notification or the welcome guide
    /// still pick their own module once the window is up.
    init(models: AppModels = .shared) {
        let remembers = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        self.init(models: models, selection: remembers ? Self.lastModule() : .overview, remembers: remembers)
    }

    /// The scan benchmark's window: its own Smart Scan / Large & Old Files models, opened on `selection`.
    init(smartScan: SmartScanModel? = nil, largeFiles: LargeFilesModel? = nil, selection: Module) {
        self.init(models: AppModels(smartScan: smartScan ?? SmartScanModel(module: .smartScan),
                                    largeFiles: largeFiles ?? LargeFilesModel()), selection: selection, remembers: false)
    }

    private init(models: AppModels, selection: Module, remembers: Bool) {
        self.models = models
        self.remembers = remembers
        _selection = State(initialValue: selection)
        _overview = ObservedObject(wrappedValue: models.overview)
        _smartScan = ObservedObject(wrappedValue: models.smartScan)
        _privacy = ObservedObject(wrappedValue: models.privacy)
        _largeFiles = ObservedObject(wrappedValue: models.largeFiles)
        _uninstaller = ObservedObject(wrappedValue: models.uninstaller)
        _spaceLens = ObservedObject(wrappedValue: models.spaceLens)
        _loginItems = ObservedObject(wrappedValue: models.loginItems)
        _maintenance = ObservedObject(wrappedValue: models.maintenance)
    }

    /// The module saved by `remember`; Overview when none or one this version no longer has.
    static func lastModule(defaults: UserDefaults = .standard) -> Module {
        defaults.string(forKey: Preferences.lastModule).flatMap(Module.init(rawValue:)) ?? .overview
    }

    static func remember(_ module: Module?, defaults: UserDefaults = .standard) {
        guard let module else { return }
        defaults.set(module.rawValue, forKey: Preferences.lastModule)
    }

    var body: some View {
        NavigationSplitView {
            List(Module.allCases, selection: $selection) { module in
                Label { Text(module.title) } icon: { Image(systemName: module.systemImage) }
                    .badge(badgeText(module))
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch selection ?? .overview {
            case .overview: OverviewView(model: overview, cleanable: hasResults(smartScan) ? smartScan.selectedSize : nil)
            case .smartScan: SmartScanView(model: smartScan, module: .smartScan)
            case .privacy: SmartScanView(model: privacy, module: .privacy)
            case .largeFiles: LargeFilesView(model: largeFiles)
            case .uninstaller: UninstallerView(model: uninstaller)
            case .spaceLens: SpaceLensView(model: spaceLens)
            case .loginItems: LaunchAgentsView(model: loginItems)
            case .maintenance: MaintenanceView(model: maintenance)
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .focusedSceneValue(\.scanAgain, scanAgain)
        .focusedSceneValue(\.stopScan, stopScan)
        .focusedSceneValue(\.module, $selection)
        .onAppearAndChange(of: router.requested) { _ in
            if let module = router.requested { selection = module; router.requested = nil }
        }
        .onAppearAndChange(of: router.scanRequested) { _ in
            guard router.scanRequested else { return }
            router.scanRequested = false
            selection = .smartScan
            scanAction(smartScan)?() // nil while it already scans or cleans
        }
        .onAppearAndChange(of: router.cleanReviewRequested) { _ in
            guard router.cleanReviewRequested else { return }
            router.cleanReviewRequested = false
            selection = .smartScan
            smartScan.requestReview()
        }
        .onAppearAndChange(of: router.spaceLensItem) { _ in
            if let url = router.spaceLensItem { spaceLens.reveal(url); selection = .spaceLens; router.spaceLensItem = nil }
        }
        .onAppearAndChange(of: router.spaceLensFolder) { _ in
            if let url = router.spaceLensFolder { spaceLens.start(at: url); selection = .spaceLens; router.spaceLensFolder = nil }
        }
        .onAppearAndChange(of: router.suggestion) { _ in
            guard let target = router.suggestion else { return }
            router.suggestion = nil
            switch target {
            case .smartScanGroup(let group): smartScan.reveal(group: group, measuredAt: router.suggestionMeasuredAt)
            case .uninstallerUnused: uninstaller.showUnusedSuggestion()
            case .maintenanceSnapshots: maintenance.revealSnapshots()
            }
        }
        .onAppearAndChange(of: router.welcomeRequested) { _ in
            guard router.welcomeRequested else { return }
            router.welcomeRequested = false
            // A confirmation already open keeps the window: no sheet over a sheet.
            if ModuleRouter.mainWindow?.attachedSheet == nil { showsWelcome = true } else { NSSound.beep() }
        }
        .onAppearAndChange(of: router.trashedItemsRequested) { _ in
            guard router.trashedItemsRequested else { return }
            router.trashedItemsRequested = false
            Task {
                // Asked from an alert's button: the alert is still closing. Another confirmation open keeps the window.
                for _ in 0..<10 where ModuleRouter.mainWindow?.attachedSheet != nil {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if ModuleRouter.mainWindow?.attachedSheet == nil { showsTrashedItems = true } else { NSSound.beep() }
            }
        }
        .onAppear {
            if WelcomeModel.showsAtLaunch(), !BackgroundMode.shared.launchingHidden { showsWelcome = true }
            // After the window (see `start`); a login launch's hidden window waits for the user to open one. Next turn
            // of the run loop: this window may appear before `applicationDidFinishLaunching` marks a login launch.
            DispatchQueue.main.async { AppUpdater.shared.windowShown(launchingHidden: BackgroundMode.shared.launchingHidden) }
            router.openMainWindow = openWindow
            BackgroundMode.shared.hideLaunchWindow() // started at login: menu bar only
        }
        .sheet(isPresented: $showsWelcome) { WelcomeView { selection = .overview } }
        .sheet(isPresented: $showsTrashedItems) { TrashedItemsView() }
        .onChange(of: selection) { if remembers { Self.remember($0) } }
        .background { if remembers { WindowFrameKeeper() } }
    }

    private func badgeText(_ module: Module) -> Text? {
        let badge: Module.Badge? = switch module {
        // Totals only with results: this view redraws on every change of any model, also mid-scan.
        case .smartScan: hasResults(smartScan) ? module.badge(hasResults: true, size: smartScan.selectedSize) : nil
        case .privacy: hasResults(privacy) ? module.badge(hasResults: true, size: privacy.selectedSize) : nil
        case .largeFiles:
            if case .results = largeFiles.phase {
                if largeFiles.duplicatesShown {
                    if case .results = largeFiles.duplicates.phase {
                        module.badge(hasResults: true, size: largeFiles.duplicates.checkedSize, files: largeFiles.duplicates.fileCount)
                    } else { nil }
                } else {
                    module.badge(hasResults: true, files: largeFiles.similarPhotosShown ? largeFiles.similarPhotos.photoCount
                                                                                        : largeFiles.visibleFiles.count)
                }
            } else { nil }
        case .overview, .uninstaller, .spaceLens, .loginItems, .maintenance: nil
        }
        return switch badge {
        case .size(let size): Text(size, format: .fileSize)
        case .files(let count): Text(count, format: .number)
        case nil: nil
        }
    }

    private func hasResults(_ model: SmartScanModel) -> Bool {
        if case .results = model.phase { true } else { false }
    }

    /// ⌘R: scans the visible module again; nil (menu item disabled) while it is busy.
    private var scanAgain: (() -> Void)? {
        switch selection ?? .overview {
        case .overview: { overview.refresh() }
        case .smartScan: scanAction(smartScan)
        case .privacy: scanAction(privacy)
        case .largeFiles:
            switch largeFiles.phase {
            case .scanning, .trashing: nil
            default: largeFiles.undoing || largeFiles.subModelChanging ? nil : { largeFiles.scan() } // scan() ignores it while putting back
            }
        case .uninstaller: uninstaller.loadingApps || uninstaller.working ? nil : { uninstaller.refresh() }
        case .spaceLens: spaceLens.trashing ? nil : { spaceLens.rescan() }
        case .loginItems: loginItems.loading || loginItems.working ? nil : { Task { await loginItems.load() } }
        case .maintenance: nil // nothing to scan
        }
    }

    private func scanAction(_ model: SmartScanModel) -> (() -> Void)? {
        switch model.phase {
        case .scanning, .cleaning: nil
        default: model.undoing ? nil : { model.startScan() } // cancellable, so ⌘. can stop it
        }
    }

    /// ⌘.: stops the visible module's scan, clean or move to the Trash (after the item under way), Maintenance task or
    /// wait for an app to quit; nil (menu item disabled) when nothing can be stopped.
    private var stopScan: (() -> Void)? {
        let running: Bool
        let stop: () -> Void
        switch selection ?? .overview {
        case .overview:
            running = overview.measuring
            stop = { overview.cancel() }
        case .smartScan, .privacy:
            let model = selection == .privacy ? privacy : smartScan
            switch model.phase {
            case .scanning: running = true; stop = { model.cancelScan() }
            case .cleaning: running = !model.stoppingClean; stop = { model.stopClean() } // after the item being cleaned
            default: running = false; stop = {}
            }
        case .largeFiles:
            let photos = largeFiles.similarPhotos
            let duplicates = largeFiles.duplicates
            if case .scanning = largeFiles.phase {
                running = true
                stop = { largeFiles.cancel() }
            } else if case .trashing = largeFiles.phase {
                running = !largeFiles.stoppingTrash
                stop = { largeFiles.stopTrash() }
            } else if largeFiles.similarPhotosShown, case .trashing = photos.phase {
                running = !photos.stoppingTrash
                stop = { photos.stopTrash() }
            } else if largeFiles.duplicatesShown, case .trashing = duplicates.phase {
                running = !duplicates.stoppingTrash
                stop = { duplicates.stopTrash() }
            } else if largeFiles.duplicatesShown {
                running = duplicates.isSearching && !duplicates.stopping
                stop = { duplicates.stop() }
            } else {
                running = largeFiles.similarPhotosShown && largeFiles.similarPhotos.isSearching
                stop = { largeFiles.similarPhotos.stop() }
            }
        case .spaceLens:
            if spaceLens.trashing {
                running = !spaceLens.undoing && !spaceLens.stoppingTrash
                stop = { spaceLens.stopTrash() }
            } else {
                running = spaceLens.measuring
                stop = { spaceLens.cancel() }
            }
        case .maintenance:
            running = maintenance.running != nil
            stop = { maintenance.stop() }
        case .uninstaller: // "Quit and Uninstall" waiting for the app to quit, or the move to the Trash
            if uninstaller.movingToTrash {
                running = !uninstaller.stoppingTrash
                stop = { uninstaller.stopTrash() }
            } else {
                running = uninstaller.quitting != nil
                stop = { uninstaller.cancelQuit() }
            }
        case .loginItems: // short loads
            running = false
            stop = {}
        }
        return running ? stop : nil
    }
}

private struct ScanAgainKey: FocusedValueKey { typealias Value = () -> Void }
private struct StopScanKey: FocusedValueKey { typealias Value = () -> Void }
private struct MoveToTrashKey: FocusedValueKey { typealias Value = () -> Void }
private struct ModuleKey: FocusedValueKey { typealias Value = Binding<Module?> }
private struct ConfirmingKey: FocusedValueKey { typealias Value = Bool }

extension FocusedValues {
    /// The visible module's scan action, for File > Scan Again (⌘R).
    var scanAgain: (() -> Void)? {
        get { self[ScanAgainKey.self] }
        set { self[ScanAgainKey.self] = newValue }
    }

    /// The visible module's stop action, for Scan > Stop (⌘.).
    var stopScan: (() -> Void)? {
        get { self[StopScanKey.self] }
        set { self[StopScanKey.self] = newValue }
    }

    /// Large & Old Files / Space Lens: opens their Move to Trash confirmation, for File › Move to Trash… (⌘⌫).
    var moveToTrash: (() -> Void)? {
        get { self[MoveToTrashKey.self] }
        set { self[MoveToTrashKey.self] = newValue }
    }

    /// The visible module shows a delete/Trash/remove confirmation: Scan, Move to Trash and ⌘1…⌘8 wait for it.
    var confirming: Bool? {
        get { self[ConfirmingKey.self] }
        set { self[ConfirmingKey.self] = newValue }
    }

    /// The sidebar selection, for View > module (⌘1…⌘8).
    var module: Binding<Module?>? {
        get { self[ModuleKey.self] }
        set { self[ModuleKey.self] = newValue }
    }
}

#Preview {
    ContentView()
}
