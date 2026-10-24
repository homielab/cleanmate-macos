import AppKit
import Observation

/// Uninstaller: list of apps, the selected app's data (or leftovers of removed apps), ticked items go to the Trash.
@Observable
final class UninstallerModel {
    /// `hiddenConfig` is read-only: `remove()` ignores it. `extensions` items are never ticked for the user.
    enum Selection: Hashable { case app(URL), leftovers, hiddenConfig, extensions }
    enum Outcome { case removed(CleanReport), appNotTrashed(InstalledApp), appTrashCancelled(InstalledApp), appLocked(InstalledApp), restored(TrashUndo.Result) }
    /// Why a file dropped on the window was not selected.
    enum DropRejection { case notApp, notListed }
    /// Order of the app list, remembered in `Preferences.uninstallerSort`.
    enum AppSort: String, CaseIterable { case name, size, lastUsed }
    /// "Not used for" filter of the app list, remembered in `Preferences.uninstallerUnused`.
    enum UnusedFilter: String, CaseIterable { case all, months3, months6, year1 }

    var apps: [InstalledApp] = []
    var loadingApps = false
    /// Filled in the background after the list appears.
    var appSizes: [URL: Int64] = [:]
    /// Total size of each app's data in ~/Library and config in ~, ~/.config and ~/.local/share (same rule as its detail, suggestions
    /// included), measured in the background after `appSizes`.
    var appDataSizes: [URL: Int64] = [:]
    /// Bumped when `appDataSizes` must be (re)measured: the view's `.task(id:)` runs `measureAppData`, cancelled on leaving.
    var dataGeneration = 0
    /// Size of each matched data entry, measured once per session; cleared with `appDataSizes` (`invalidateAppData`).
    @ObservationIgnored private var dataEntrySizes: [URL: Int64] = [:]
    /// Injected by tests. For each app, the data entries it would list. Arguments: all listed apps, every bundle id
    /// installed or running. Without Full Disk Access the protected folders (Containers…) are not listed: they would prompt.
    @ObservationIgnored var appDataMatches: ([InstalledApp], Set<String>) async -> [URL: [URL]] = { apps, ids in
        let skipped = ProtectedFolders.skipped(home: SafetyPolicy.current.homeURL, hasFullDiskAccess: FullDiskAccess.isGranted)
        return await Uninstaller.dataMatches(of: apps, otherBundleIDs: ids, skipped: skipped, allApps: Uninstaller.allAppURLs())
    }
    /// An app hidden by the search is deselected, so the detail, Uninstall and Return never act on an app not in the list.
    var search = "" { didSet { deselectUnlistedApp() } }
    /// Set by the view from `@AppStorage`; an app it hides is deselected like the search does.
    var unused = UnusedFilter.all { didSet { if unused != oldValue { deselectUnlistedApp() } } }
    /// A new selection drops the old one's rows at once (and any load still finishing for it): Uninstall must never
    /// send one app with another's ticked data before `loadEntries` runs.
    var selection: Selection? {
        didSet {
            guard selection != oldValue else { return }
            trashApp = true
            highlighted = []
            entries = []
            checked = []
            entriesGeneration += 1
        }
    }
    /// Rows highlighted in the detail list (arrow keys); Space ticks them via `toggle(urls:)`.
    var highlighted: Set<URL> = []
    /// The selected app's own row is ticked. Unticked: `remove()` resets the app (moves only its ticked data).
    var trashApp = true
    /// Data and config of the selected app, or leftovers of removed apps.
    var entries: [AppDataEntry] = []
    var loadingEntries = false
    var checked: Set<URL> = []
    var working = false
    var outcome: Outcome?
    var dropRejection: DropRejection?
    /// Unknown hidden items of ~ and ~/.config (warning only, never removed); nil until first loaded.
    var hiddenItems: [HiddenConfigItem]?
    /// Filled in the background after `hiddenItems`.
    var hiddenSizes: [URL: Int64] = [:]
    /// Extensions in ~/Library; nil until first loaded.
    var extensionItems: [ExtensionItem]?
    /// Filled in the background after `extensionItems`.
    var extensionSizes: [URL: Int64] = [:]
    /// Bundle ids of running apps, kept current through NSWorkspace launch/terminate notifications.
    var runningApps = SmartScanModel.currentRunningApps()
    /// Source of `runningApps` on launch/quit and right before extensions go; injected by tests.
    @ObservationIgnored var appBundleIDs: @Sendable () -> Set<String> = SmartScanModel.currentRunningApps
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Bumped by every loadEntries: an older load still finishing (cancellation is not honoured
    /// by the file walk) never clears `loadingEntries` or writes entries of a previous selection.
    @ObservationIgnored private var entriesGeneration = 0
    /// Injected by tests (sample data instead of the real ~/Library).
    /// Arguments: the app, bundle ids and names of every other installed/running app.
    @ObservationIgnored var appData: (InstalledApp, Set<String>, Set<String>) async -> [AppDataEntry] = {
        await Uninstaller.data(of: $0, otherBundleIDs: $1, otherAppNames: $2)
    }
    /// Injected by tests (sample leftovers instead of the real ~/Library). Argument: bundle ids of installed/running apps.
    @ObservationIgnored var leftovers: (Set<String>) async -> [AppDataEntry] = { installed in
        await Uninstaller.leftovers(installedBundleIDs: installed) { id in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
        }
    }
    /// The window's, set by the view: ⌘Z after Uninstall or Reset.
    @ObservationIgnored weak var undoManager: UndoManager?
    /// "Undo"; tests pass their own so the real Trash is never touched.
    @ObservationIgnored var restore: ([TrashedItem]) async -> TrashUndo.Result = { await TrashUndo.restore($0, module: "Uninstaller") }
    /// Injected by tests so nothing real goes to the Trash. Arguments: the app (if any), the ticked data.
    @ObservationIgnored var trash: (URL?, [AppDataEntry]) async throws(Uninstaller.AppTrashError) -> CleanReport = {
        try await Uninstaller.trash(app: $0, data: $1)
    }

    /// Injected by tests (a fake home instead of the real one).
    @ObservationIgnored var hiddenConfig: () async -> [HiddenConfigItem] = {
        await HiddenConfig.strange(running: SmartScanModel.currentRunningApps())
    }
    /// Injected by tests (sample data instead of the real ~/Library).
    @ObservationIgnored var extensions: () async -> [ExtensionItem] = {
        let running = NSWorkspace.shared.runningApplications.compactMap { app in
            app.bundleIdentifier.map { ($0, app.localizedName ?? $0) }
        }
        return await Extensions.list(running: Dictionary(running) { first, _ in first })
    }
    /// Injected by tests so nothing real goes to the Trash. Arguments: the ticked extensions, and whether one is
    /// in use right now (checked again just before each).
    @ObservationIgnored var trashExtensions: ([AppDataEntry], @escaping @Sendable (URL) -> Bool) async -> CleanReport = {
        await Extensions.trash($0, inUse: $1)
    }

    /// Injected by tests. Lists the installed apps.
    @ObservationIgnored var installedApps: () async -> [InstalledApp] = { await Uninstaller.installedApps() }
    /// Injected by tests. Size of an app bundle; returns 0 when its task is cancelled (the file walk stops).
    @ObservationIgnored var appSize: @Sendable (URL) async -> Int64 = { await Uninstaller.size(of: $0) }

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { self.runningApps = self.appBundleIDs() } }
            })
        }
    }

    var filteredApps: [InstalledApp] { Self.filtered(apps, search: search, unused: unused) }

    /// Search (name or bundle id) and "not used for" filter. An app with no last-used date (Spotlight never saw it
    /// opened) counts as unused for long: it is the likeliest to be forgotten.
    nonisolated static func filtered(_ apps: [InstalledApp], search: String, unused: UnusedFilter, now: Date = .now) -> [InstalledApp] {
        let months = switch unused { case .all: 0; case .months3: 3; case .months6: 6; case .year1: 12 }
        let cutoff = months == 0 ? nil : Calendar.current.date(byAdding: .month, value: -months, to: now)
        return apps.filter { app in
            (search.isEmpty || app.name.localizedStandardContains(search) || app.bundleID.localizedStandardContains(search))
                && (cutoff.map { cutoff in app.lastUsed.map { $0 < cutoff } ?? true } ?? true)
        }
    }

    /// What clears an Applications list emptied by the search and/or the "not used for" filter; nil when rows show or
    /// no app was found at all (loading, or nothing installed): then "no match" would be wrong.
    enum NoMatchFix: Equatable { case clearSearch, showAll }
    nonisolated static func noMatchFixes(appCount: Int, shownCount: Int, search: String, unused: UnusedFilter) -> [NoMatchFix]? {
        guard appCount > 0, shownCount == 0 else { return nil }
        return (search.isEmpty ? [] : [.clearSearch]) + (unused == .all ? [] : [.showAll])
    }

    /// Sort key of the Size order: app + data once the data is measured, else the app alone.
    var totalSizes: [URL: Int64] {
        appSizes.merging(appDataSizes) { $0 + $1 }.filter { appSizes[$0.key] != nil }
    }

    /// Size: largest first; last used: oldest first. Apps whose size/date is not known yet go last; ties by name.
    nonisolated static func sorted(_ apps: [InstalledApp], by sort: AppSort, sizes: [URL: Int64]) -> [InstalledApp] {
        apps.sorted { a, b in
            switch sort {
            case .name: break
            case .size:
                let (x, y) = (sizes[a.url], sizes[b.url])
                if x != y { return x.map { x in y.map { x > $0 } ?? true } ?? false }
            case .lastUsed:
                if a.lastUsed != b.lastUsed { return a.lastUsed.map { x in b.lastUsed.map { x < $0 } ?? true } ?? false }
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private func deselectUnlistedApp() {
        if case .app(let url) = selection, !filteredApps.contains(where: { $0.url == url }) { selection = nil }
    }

    var selectedApp: InstalledApp? {
        guard case .app(let url) = selection else { return nil }
        return apps.first { $0.url == url }
    }

    /// URL of the listed app that `url` is (symlinks, `..` and trailing slashes resolved), nil if none.
    nonisolated static func listedApp(for url: URL, in apps: [InstalledApp]) -> URL? {
        func key(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
        let dropped = key(url)
        return apps.first { key($0.url) == dropped }?.url
    }

    /// Selects a dropped app like a click in the list; never removes anything. Ignored while removing or loading.
    @discardableResult
    func drop(_ urls: [URL]) -> Bool {
        guard !working, !loadingApps, let url = urls.first else { return false }
        guard let app = Self.listedApp(for: url, in: apps) else {
            dropRejection = url.pathExtension.lowercased() == "app" ? .notListed : .notApp
            return false
        }
        search = "" // so the selected row is visible in the list
        selection = .app(app)
        return true
    }

    func isRunning(_ app: InstalledApp) -> Bool { runningApps.contains(app.bundleID) }

    func quit(_ app: InstalledApp) {
        NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).forEach { $0.terminate() }
    }

    nonisolated static let systemSettingsID = "com.apple.systempreferences"

    /// A preference pane while System Settings is open: it may be loaded there, so it gets no checkbox.
    func isInUse(_ item: ExtensionItem) -> Bool { item.kind == .preferencePane && runningApps.contains(Self.systemSettingsID) }

    func quitSystemSettings() {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.systemSettingsID).forEach { $0.terminate() }
    }

    /// Space on highlighted rows, like Smart Scan: ticks them all if any tickable one is off, else unticks them.
    /// Rows without a working checkbox (Apple's or wrong-type extension, pane while System Settings is open, while moving) are left alone.
    func toggle(urls: Set<URL>) {
        guard !working else { return }
        let app = selectedApp.map(\.url).flatMap { urls.contains($0) ? $0 : nil }
        let tickable = selection == .extensions
            ? tickableExtensions.map(\.url)
            : entries.map(\.url)
        let rows = tickable.filter(urls.contains)
        let on = rows.contains { !checked.contains($0) } || (app != nil && !trashApp)
        if on { checked.formUnion(rows) } else { checked.subtract(rows) }
        if app != nil { trashApp = on }
    }

    /// Extensions whose checkbox works: trashable, and not a pane while System Settings is open.
    private var tickableExtensions: [ExtensionItem] { (extensionItems ?? []).filter { $0.trashable && !isInUse($0) } }

    var checkedEntries: [AppDataEntry] {
        guard selection == .extensions else { return entries.filter { checked.contains($0.url) } }
        return tickableExtensions.filter { checked.contains($0.url) }
            .map { AppDataEntry(url: $0.url, size: extensionSizes[$0.url] ?? 0) }
    }
    /// Ticked data plus the app itself when its row is ticked.
    var checkedSize: Int64 {
        checkedEntries.reduce((trashApp ? selectedApp : nil).flatMap { appSizes[$0.url] } ?? 0) { $0 + $1.size }
    }

    /// Refresh button and ⌘R: app list, app data, hidden config and extensions, all again.
    func refresh() {
        invalidateAppData()
        Task { await loadApps() }
        Task { await loadHiddenConfig() }
        Task { await loadExtensions() }
    }

    func loadApps() async {
        loadingApps = true
        apps = await installedApps()
        loadingApps = false
        deselectUnlistedApp() // removed outside CleanMate: show the empty state, not a blank detail
        let appSize = appSize
        await withTaskGroup(of: (URL, Int64).self) { group in
            for app in apps where appSizes[app.url] == nil {
                group.addTask { (app.url, await appSize(app.url)) }
            }
            // A cancelled walk returns 0: never record it, so the next load measures that app again.
            for await (url, size) in group where !Task.isCancelled { appSizes[url] = size }
        }
        if !Task.isCancelled { dataGeneration += 1 } // app sizes known: measure the data next
    }

    /// Forgets measured data sizes (after Uninstall, Reset, Undo, Refresh) and measures again.
    func invalidateAppData() {
        appDataSizes = [:]
        dataEntrySizes = [:]
        dataGeneration += 1
    }

    /// Measures the data of every listed app not measured yet, shown apps first, once all app sizes are known.
    /// One listing of ~/Library for all apps; each entry measured once, all apps' entries in parallel; an app's
    /// total is recorded as soon as all its entries are. A cancelled walk is never recorded.
    func measureAppData() async {
        let generation = dataGeneration
        let pending = apps.filter { appDataSizes[$0.url] == nil }
        guard !loadingApps, !pending.isEmpty, apps.allSatisfy({ appSizes[$0.url] != nil }) else { return }
        let shown = Set(filteredApps.map(\.url))
        let ordered = pending.filter { shown.contains($0.url) } + pending.filter { !shown.contains($0.url) }
        let ids = Uninstaller.allBundleIDs().union(runningApps).union(apps.map(\.bundleID))
        let matches = await appDataMatches(apps, ids)
        guard !Task.isCancelled, generation == dataGeneration else { return }
        var waiting = ordered.map { (url: $0.url, entries: Set(matches[$0.url] ?? [])) }
        func recordFinished() {
            waiting.removeAll { app in
                guard app.entries.allSatisfy({ dataEntrySizes[$0] != nil }) else { return false }
                appDataSizes[app.url] = app.entries.reduce(0) { $0 + (dataEntrySizes[$1] ?? 0) }
                return true
            }
        }
        recordFinished()
        let appSize = appSize
        await withTaskGroup(of: (URL, Int64).self) { group in
            var queued = Set<URL>()
            for app in waiting {
                for url in app.entries where dataEntrySizes[url] == nil && queued.insert(url).inserted {
                    group.addTask { (url, await appSize(url)) }
                }
            }
            for await (url, size) in group {
                guard !Task.isCancelled, generation == dataGeneration else { group.cancelAll(); return }
                dataEntrySizes[url] = size
                recordFinished()
            }
        }
    }

    /// Lists unknown hidden config items, then measures them in the background (a cancelled walk is never recorded).
    func loadHiddenConfig() async {
        let items = await hiddenConfig()
        guard !Task.isCancelled else { return }
        hiddenItems = items
        await measure(items.map(\.url), into: \.hiddenSizes)
    }

    /// Lists extensions in ~/Library, then measures them in the background (a cancelled walk is never recorded).
    func loadExtensions() async {
        let items = await extensions()
        guard !Task.isCancelled else { return }
        extensionItems = items
        await measure(items.map(\.url), into: \.extensionSizes)
    }

    private func measure(_ urls: [URL], into sizes: ReferenceWritableKeyPath<UninstallerModel, [URL: Int64]>) async {
        let appSize = appSize
        await withTaskGroup(of: (URL, Int64).self) { group in
            for url in urls where self[keyPath: sizes][url] == nil {
                group.addTask { (url, await appSize(url)) }
            }
            for await (url, size) in group where !Task.isCancelled { self[keyPath: sizes][url] = size }
        }
    }

    /// Loads what the current selection would remove: the app's data (ticked; suggestions and config not) or leftovers
    /// (never ticked).
    func loadEntries() async {
        entriesGeneration += 1
        let current = entriesGeneration
        entries = []
        checked = []
        loadingEntries = selection != nil
        guard let selection else { return }
        defer { if current == entriesGeneration { loadingEntries = false } }
        switch selection {
        case .hiddenConfig, .extensions:
            return // shown from `hiddenItems`/`extensionItems`; nothing to tick
        case .app:
            guard let app = selectedApp else { return }
            // All installed apps (incl. Apple's, nested and unlisted ones) and running ones, not just the listed apps.
            let others = apps.filter { $0.url != app.url }
            let ids = Uninstaller.allBundleIDs().union(runningApps).union(others.map(\.bundleID))
            let names = Set(others.flatMap(\.names)).union(Uninstaller.otherAppNames(than: app.url, in: Uninstaller.allAppURLs()))
            let found = await appData(app, ids, names)
            guard !Task.isCancelled, current == entriesGeneration else { return }
            entries = found
            checked = Set(found.filter { $0.kind == .data }.map(\.url)) // suggestions and config: never ticked for the user
        case .leftovers:
            let installed = Uninstaller.allBundleIDs().union(runningApps)
            let found = await leftovers(installed)
            guard !Task.isCancelled, current == entriesGeneration else { return }
            entries = found
        }
    }

    /// Moves the selected app (if its row is ticked) and the ticked items to the Trash.
    /// App unticked = reset: only its data goes, the bundle stays and its data is listed again.
    func remove() async {
        if selection == .hiddenConfig { return } // read-only: never removed
        if selection == .extensions { return await removeExtensions() }
        let selected = selectedApp
        runningApps = appBundleIDs() // a launch may not have been notified yet
        // Also for a reset: an open app rewrites its data while it goes (the view only allows this once it has quit).
        if let selected, isRunning(selected) { return }
        guard !working else { return }
        let app = trashApp ? selected : nil
        let data = checkedEntries
        if app == nil && data.isEmpty { return }
        working = true
        defer { working = false }
        undoManager?.removeAllActions(withTarget: self)
        let removing = selection
        let report: CleanReport
        do { report = try await trash(app?.url, data) } catch {
            if let app {
                switch error {
                case .cancelled: outcome = .appTrashCancelled(app)
                case .locked: outcome = .appLocked(app)
                case .notTrashed: outcome = .appNotTrashed(app)
                }
            }
            Attention.finished()
            return
        }
        outcome = .removed(report)
        invalidateAppData() // data of the reset/removed app (and any entry it shared) changed
        if !report.trashed.isEmpty {
            undoManager?.registerTrashUndo(self, name: app == nil ? String(localized: "Reset") : String(localized: "Uninstall")) { await $0.undo(report) }
        }
        Attention.finished()
        // The user may have picked another app meanwhile: leave that selection and its entries alone.
        if let app {
            apps.removeAll { $0.url == app.url }
            if selection == removing { selection = nil }
        } else if selection == removing {
            await loadEntries() // leftovers, or the reset app's data
        }
    }

    /// Moves the ticked extensions to the Trash, then lists them again.
    private func removeExtensions() async {
        runningApps = appBundleIDs()
        let data = checkedEntries
        guard !working, !data.isEmpty else { return }
        working = true
        undoManager?.removeAllActions(withTarget: self)
        let ids = appBundleIDs
        // Same test as `isInUse`: the item's kind, not its name extension.
        let panes = Set((extensionItems ?? []).filter { $0.kind == .preferencePane }.map(\.url))
        let report = await trashExtensions(data) { url in
            panes.contains(url) && ids().contains(Self.systemSettingsID)
        }
        working = false
        outcome = .removed(report)
        if !report.trashed.isEmpty {
            undoManager?.registerTrashUndo(self, name: String(localized: "Move to Trash")) { await $0.undo(report) }
        }
        Attention.finished()
        checked.subtract(data.map(\.url))
        await loadExtensions()
    }

    /// "Undo" in the result alert: puts the app and its data back, then lists them again. Launch agents
    /// booted out by the removal stay unloaded until the next login (or until the app loads them again).
    func undo(_ report: CleanReport) async {
        guard !working, !report.trashed.isEmpty else { return }
        undoManager?.removeAllActions(withTarget: self) // the button ran it, or ⌘Z did
        working = true
        let result = await restore(report.trashed)
        working = false
        outcome = .restored(result)
        invalidateAppData()
        await loadApps()
        if selection == .extensions { await loadExtensions() } else if selection != nil { await loadEntries() }
    }
}

extension UninstallerModel: TrashUndoing {}
