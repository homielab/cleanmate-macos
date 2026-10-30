import SwiftUI
import Combine

/// Sidebar modules.
enum Module: String, CaseIterable, Identifiable {
    case smartScan
    case privacy
    case largeFiles
    case uninstaller
    case spaceLens
    case loginItems

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .smartScan: "Smart Scan"
        case .privacy: "Privacy"
        case .largeFiles: "Large & Old Files"
        case .uninstaller: "Uninstaller"
        case .spaceLens: "Space Lens"
        case .loginItems: "Login Items"
        }
    }

    var systemImage: String {
        switch self {
        case .smartScan: "sparkles"
        case .privacy: "hand.raised"
        case .largeFiles: "doc.badge.clock"
        case .uninstaller: "xmark.app"
        case .spaceLens: "chart.pie"
        case .loginItems: "power"
        }
    }

    /// Sidebar badge after a scan: what Clean will free for Smart Scan/Privacy, files found for Large & Old Files.
    enum Badge: Equatable { case size(Int64), files(Int) }

    /// nil (no badge) without results or when there is nothing to show; other modules never get one.
    func badge(hasResults: Bool, size: Int64 = 0, files: Int = 0) -> Badge? {
        guard hasResults else { return nil }
        switch self {
        case .smartScan, .privacy: return size > 0 ? .size(size) : nil // Privacy records have no size: no badge
        case .largeFiles: return files > 0 ? .files(files) : nil
        case .uninstaller, .spaceLens, .loginItems: return nil
        }
    }
}

/// Module requested from outside the window (menu bar item, scan reminder); ContentView consumes it, also on first appearance.
final class ModuleRouter: ObservableObject {
    static let shared = ModuleRouter()
    @Published var requested: Module?
    /// "Show in Space Lens": Space Lens opens this item's folder with the item selected.
    @Published var spaceLensItem: URL?
    /// Menu bar "Scan Now": ContentView switches to Smart Scan and starts a scan, also on first appearance.
    @Published var scanRequested = false
    /// Reopens the main window after it was closed; kept by ContentView (the scan reminder has no SwiftUI environment).
    var openMainWindow: OpenWindowAction?

    /// Menu bar "Scan Now" is disabled, like ⌘R, while a confirmation (a sheet on the main window) is open, and while
    /// something is being cleaned or moved to the Trash.
    static func canScanNow(sheetOpen: Bool, busy: Bool) -> Bool { !sheetOpen && !busy }

    static var mainWindow: NSWindow? { NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) }

    var canScanNow: Bool { Self.canScanNow(sheetOpen: Self.mainWindow?.attachedSheet != nil, busy: AppDelegate.isBusy) }

    /// Opens the main window on Smart Scan and starts a scan.
    func scanNow(openWindow: OpenWindowAction? = nil) {
        guard canScanNow else { return }
        scanRequested = true
        show(.smartScan, openWindow: openWindow)
    }

    /// Brings the main window front (reopened if closed) on `module`, nil = the module already shown.
    func show(_ module: Module?, openWindow: OpenWindowAction? = nil) {
        let window = Self.mainWindow
        // A confirmation open (sheet on the window) keeps its module, like ⌘1…⌘6: only bring the window front.
        requested = window?.attachedSheet == nil ? module : nil
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
    @State private var selection: Module? = .smartScan
    @StateObject private var smartScan = SmartScanModel(module: .smartScan)
    @StateObject private var privacy = SmartScanModel(module: .privacy)
    @StateObject private var largeFiles = LargeFilesModel()
    @StateObject private var uninstaller = UninstallerModel()
    @StateObject private var spaceLens = SpaceLensModel()
    @StateObject private var loginItems = LaunchAgentsModel()
    @AppStorage(Preferences.fullDiskAccessPrompted) private var fullDiskAccessPrompted = false
    @State private var showsFullDiskAccess = false
    @Environment(\.openWindow) private var openWindow

    init() {}

    /// The scan benchmark's window: its own Smart Scan / Large & Old Files models, opened on `selection`.
    init(smartScan: SmartScanModel? = nil, largeFiles: LargeFilesModel? = nil, selection: Module) {
        if let smartScan { _smartScan = StateObject(wrappedValue: smartScan) }
        if let largeFiles { _largeFiles = StateObject(wrappedValue: largeFiles) }
        _selection = State(initialValue: selection)
    }

    var body: some View {
        NavigationSplitView {
            List(Module.allCases, selection: $selection) { module in
                Label { Text(module.title) } icon: { Image(systemName: module.systemImage) }
                    .badge(badgeText(module))
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch selection ?? .smartScan {
            case .smartScan: SmartScanView(model: smartScan, module: .smartScan)
            case .privacy: SmartScanView(model: privacy, module: .privacy)
            case .largeFiles: LargeFilesView(model: largeFiles)
            case .uninstaller: UninstallerView(model: uninstaller)
            case .spaceLens: SpaceLensView(model: spaceLens)
            case .loginItems: LaunchAgentsView(model: loginItems)
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .focusedSceneValue(\.scanAgain, scanAgain)
        .focusedSceneValue(\.stopScan, stopScan)
        .focusedSceneValue(\.module, $selection)
        .onAppear {
            // Read from the models at quit time, not mirrored by this view: closing the window mid-clean left
            // a mirrored flag stuck. Weak: a model a still-running task keeps alive after the window closed counts too.
            AppDelegate.registerBusyCheck(ObjectIdentifier(smartScan),
                                          Self.busyCheck(smartScan, privacy, largeFiles, uninstaller, spaceLens, loginItems))
        }
        .onAppearAndChange(of: router.requested) { _ in
            if let module = router.requested { selection = module; router.requested = nil }
        }
        .onAppearAndChange(of: router.scanRequested) { _ in
            guard router.scanRequested else { return }
            router.scanRequested = false
            selection = .smartScan
            scanAction(smartScan)?() // nil while it already scans or cleans
        }
        .onAppearAndChange(of: router.spaceLensItem) { _ in
            if let url = router.spaceLensItem { spaceLens.reveal(url); selection = .spaceLens; router.spaceLensItem = nil }
        }
        .onAppear {
            // Once, and only when missing; remembered even if the user picks Not Now.
            if !fullDiskAccessPrompted && !FullDiskAccess.isGranted { showsFullDiskAccess = true }
            fullDiskAccessPrompted = true
            AppUpdater.shared.start()  // after the window: see `start`
            router.openMainWindow = openWindow
        }
        .sheet(isPresented: $showsFullDiskAccess) { FullDiskAccessSheet() }
    }

    private func badgeText(_ module: Module) -> Text? {
        let badge: Module.Badge? = switch module {
        // Totals only with results: this view redraws on every change of any model, also mid-scan.
        case .smartScan: hasResults(smartScan) ? module.badge(hasResults: true, size: smartScan.selectedSize) : nil
        case .privacy: hasResults(privacy) ? module.badge(hasResults: true, size: privacy.selectedSize) : nil
        case .largeFiles:
            if case .results = largeFiles.phase { module.badge(hasResults: true, files: largeFiles.visibleFiles.count) } else { nil }
        case .uninstaller, .spaceLens, .loginItems: nil
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
        switch selection ?? .smartScan {
        case .smartScan: scanAction(smartScan)
        case .privacy: scanAction(privacy)
        case .largeFiles:
            switch largeFiles.phase {
            case .scanning, .trashing: nil
            default: largeFiles.undoing ? nil : { largeFiles.scan() } // scan() ignores it while putting back
            }
        case .uninstaller: uninstaller.loadingApps || uninstaller.working ? nil : { uninstaller.refresh() }
        case .spaceLens: spaceLens.trashing ? nil : { spaceLens.rescan() }
        case .loginItems: loginItems.loading || loginItems.working ? nil : { Task { await loginItems.load() } }
        }
    }

    /// Deleting, moving to the Trash, putting back or a launchctl change is under way: quitting now would stop it partway.
    /// nil = that model is gone (window closed, nothing running in it).
    static func isChanging(_ smartScan: SmartScanModel?, _ privacy: SmartScanModel?, _ largeFiles: LargeFilesModel?,
                           _ uninstaller: UninstallerModel?, _ spaceLens: SpaceLensModel?, _ loginItems: LaunchAgentsModel?) -> Bool {
        let cleaning = [smartScan, privacy].contains { if case .cleaning? = $0?.phase { true } else { false } }
        let trashingFiles = if case .trashing? = largeFiles?.phase { true } else { false }
        // Uninstaller `working` and Space Lens `trashing` also cover their Undo.
        return cleaning || trashingFiles || largeFiles?.undoing == true || uninstaller?.working == true
            || spaceLens?.trashing == true || loginItems?.working == true
    }

    /// `isChanging` over weak references, for `AppDelegate.isBusy`; nil once every model is gone.
    static func busyCheck(_ smartScan: SmartScanModel, _ privacy: SmartScanModel, _ largeFiles: LargeFilesModel,
                          _ uninstaller: UninstallerModel, _ spaceLens: SpaceLensModel, _ loginItems: LaunchAgentsModel) -> () -> Bool? {
        { [weak smartScan, weak privacy, weak largeFiles, weak uninstaller, weak spaceLens, weak loginItems] in
            let models: [AnyObject?] = [smartScan, privacy, largeFiles, uninstaller, spaceLens, loginItems]
            guard models.contains(where: { $0 != nil }) else { return nil }
            return isChanging(smartScan, privacy, largeFiles, uninstaller, spaceLens, loginItems)
        }
    }

    private func scanAction(_ model: SmartScanModel) -> (() -> Void)? {
        switch model.phase {
        case .scanning, .cleaning: nil
        default: { model.startScan() } // cancellable, so ⌘. can stop it
        }
    }

    /// ⌘.: stops the visible module's running scan; nil (menu item disabled) when nothing can be stopped.
    private var stopScan: (() -> Void)? {
        let running: Bool
        let stop: () -> Void
        switch selection ?? .smartScan {
        case .smartScan:
            if case .scanning = smartScan.phase { running = true } else { running = false }
            stop = { smartScan.cancelScan() }
        case .privacy:
            if case .scanning = privacy.phase { running = true } else { running = false }
            stop = { privacy.cancelScan() }
        case .largeFiles:
            if case .scanning = largeFiles.phase { running = true } else { running = false }
            stop = { largeFiles.cancel() }
        case .spaceLens:
            running = spaceLens.measuring && !spaceLens.trashing
            stop = { spaceLens.cancel() }
        case .uninstaller, .loginItems: // short loads with no stop button
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

    /// The visible module shows a delete/Trash/remove confirmation: Scan, Move to Trash and ⌘1…⌘6 wait for it.
    var confirming: Bool? {
        get { self[ConfirmingKey.self] }
        set { self[ConfirmingKey.self] = newValue }
    }

    /// The sidebar selection, for View > module (⌘1…⌘6).
    var module: Binding<Module?>? {
        get { self[ModuleKey.self] }
        set { self[ModuleKey.self] = newValue }
    }
}

/// Shown once at first launch when Full Disk Access is missing; it can be skipped.
private struct FullDiskAccessSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield").font(.system(size: 40)).foregroundStyle(.tint)
            Text("Allow Full Disk Access").font(.title2).bold()
            Text("CleanMate works without it, but some items can't be read: the Trash, Safari data and app containers. Turn on CleanMate in System Settings > Privacy & Security > Full Disk Access, then scan again.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("CleanMate only cleans inside your user account and collects no data.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("Not Now") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open System Settings") {
                    FullDiskAccess.openSettings()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

#Preview {
    ContentView()
}
