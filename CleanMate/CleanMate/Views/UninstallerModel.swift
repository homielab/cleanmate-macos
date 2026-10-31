import AppKit
import Combine

/// Uninstaller: list of apps, the selected app's data (or leftovers of removed apps), ticked items go to the Trash.
final class UninstallerModel: ObservableObject {
    /// `hiddenConfig` is read-only: `remove()` ignores it. `extensions` items are never ticked for the user.
    enum Selection: Hashable { case app(URL), leftovers, hiddenConfig, extensions }
    enum Outcome { case removed(CleanReport), appNotTrashed(InstalledApp), appTrashCancelled(InstalledApp), appLocked(InstalledApp), restored(TrashUndo.Result), batch(BatchResult) }
    /// Why an app ticked for a batch uninstall stayed.
    enum SkipReason: Equatable { case running, locked, cancelled, notTrashed }
    /// Several ticked apps uninstalled at once: what went to the Trash, and the apps left with their reason.
    struct BatchResult {
        var report = CleanReport()
        var removed: [InstalledApp] = []
        var skipped: [(app: InstalledApp, reason: SkipReason)] = []
    }
    /// Why a file dropped on the window was not selected.
    enum DropRejection { case notApp, notListed }
    /// Order of the app list, remembered in `Preferences.uninstallerSort`.
    enum AppSort: String, CaseIterable { case name, size, lastUsed }
    /// "Not used for" filter of the app list, remembered in `Preferences.uninstallerUnused`.
    enum UnusedFilter: String, CaseIterable { case all, months3, months6, year1 }

    @Published var apps: [InstalledApp] = []
    @Published var loadingApps = false
    /// Filled in the background after the list appears.
    @Published var appSizes: [URL: Int64] = [:]
    /// Total size of each app's data in ~/Library and config in ~, ~/.config and ~/.local/share (same rule as its detail, suggestions
    /// included), measured in the background after `appSizes`.
    @Published var appDataSizes: [URL: Int64] = [:]
    /// Bumped when `appDataSizes` must be (re)measured: the view's `.task(id:)` runs `measureAppData`, cancelled on leaving.
    @Published var dataGeneration = 0
    /// Size of each matched data entry, measured once per session; cleared with `appDataSizes` (`invalidateAppData`).
    private var dataEntrySizes: [URL: Int64] = [:]
    /// Injected by tests. For each app, the data entries it would list. Arguments: all listed apps, every bundle id
    /// installed or running. Without Full Disk Access the protected folders (Containers…) are not listed: they would prompt.
    var appDataMatches: ([InstalledApp], Set<String>) async -> [URL: [URL]] = { apps, ids in
        let skipped = ProtectedFolders.skipped(home: SafetyPolicy.current.homeURL, hasFullDiskAccess: FullDiskAccess.isGranted)
        return await Uninstaller.dataMatches(of: apps, otherBundleIDs: ids, skipped: skipped, allApps: Uninstaller.allAppURLs())
    }
    /// An app hidden by the search is deselected, so the detail, Uninstall and Return never act on an app not in the list.
    @Published var search = "" { didSet { deselectUnlistedApp() } }
    /// Set by the view from `@AppStorage`; an app it hides is deselected like the search does.
    @Published var unused = UnusedFilter.all { didSet { if unused != oldValue { showUndated = false; deselectUnlistedApp() } } }
    /// A new selection drops the old one's rows at once (and any load still finishing for it): Uninstall must never
    /// send one app with another's ticked data before `loadEntries` runs.
    @Published var selection: Selection? {
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
    @Published var highlighted: Set<URL> = []
    /// Apps ticked in the list for a batch uninstall. Kept when the selection, search or filter changes; more than
    /// one shows the batch panel instead of an app's detail.
    @Published var appTicks: Set<URL> = [] {
        didSet { if batchMode, appTicks != oldValue, case .app = selection { selection = nil } } // show the batch panel
    }
    /// `.data` entries of each ticked app, loaded by `loadBatch` (suggestions and config are never part of a batch).
    @Published var batchData: [URL: [AppDataEntry]] = [:]
    /// The selected app's own row is ticked. Unticked: `remove()` resets the app (moves only its ticked data).
    @Published var trashApp = true
    /// Data and config of the selected app, or leftovers of removed apps.
    @Published var entries: [AppDataEntry] = []
    @Published var loadingEntries = false
    @Published var checked: Set<URL> = []
    @Published var working = false
    @Published var outcome: Outcome?
    @Published var dropRejection: DropRejection?
    /// Unknown hidden items of ~ and ~/.config (warning only, never removed); nil until first loaded.
    @Published var hiddenItems: [HiddenConfigItem]?
    /// Filled in the background after `hiddenItems`.
    @Published var hiddenSizes: [URL: Int64] = [:]
    /// Extensions in ~/Library; nil until first loaded.
    @Published var extensionItems: [ExtensionItem]?
    /// Filled in the background after `extensionItems`.
    @Published var extensionSizes: [URL: Int64] = [:]
    /// Bundle ids of running apps, kept current through NSWorkspace launch/terminate notifications.
    @Published var runningApps = SmartScanModel.currentRunningApps()
    /// Source of `runningApps` on launch/quit and right before extensions go; injected by tests.
    var appBundleIDs: @Sendable () -> Set<String> = SmartScanModel.currentRunningApps
    private var observers: [NSObjectProtocol] = []
    /// Bumped by every loadEntries: an older load still finishing (cancellation is not honoured
    /// by the file walk) never clears `loadingEntries` or writes entries of a previous selection.
    private var entriesGeneration = 0
    /// Injected by tests (sample data instead of the real ~/Library).
    /// Arguments: the app, bundle ids and names of every other installed/running app.
    var appData: (InstalledApp, Set<String>, Set<String>) async -> [AppDataEntry] = {
        await Uninstaller.data(of: $0, otherBundleIDs: $1, otherAppNames: $2)
    }
    /// Injected by tests (sample leftovers instead of the real ~/Library). Argument: bundle ids of installed/running apps.
    var leftovers: (Set<String>) async -> [AppDataEntry] = { installed in
        await Uninstaller.leftovers(installedBundleIDs: installed) { id in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
        }
    }
    /// The window's, set by the view: ⌘Z after Uninstall or Reset.
    weak var undoManager: UndoManager?
    /// "Undo"; tests pass their own so the real Trash is never touched.
    var restore: ([TrashedItem]) async -> TrashUndo.Result = { await TrashUndo.restore($0, module: "Uninstaller") }
    /// Injected by tests so nothing real goes to the Trash. Arguments: the app (if any), the ticked data.
    var trash: (URL?, [AppDataEntry]) async throws(Uninstaller.AppTrashError) -> CleanReport = {
        try await Uninstaller.trash(app: $0, data: $1)
    }

    /// Injected by tests (a fake home instead of the real one).
    var hiddenConfig: () async -> [HiddenConfigItem] = {
        await HiddenConfig.strange(running: SmartScanModel.currentRunningApps())
    }
    /// Injected by tests (sample data instead of the real ~/Library).
    var extensions: () async -> [ExtensionItem] = {
        let running = NSWorkspace.shared.runningApplications.compactMap { app in
            app.bundleIdentifier.map { ($0, app.localizedName ?? $0) }
        }
        return await Extensions.list(running: Dictionary(running) { first, _ in first })
    }
    /// Injected by tests so nothing real goes to the Trash. Arguments: the ticked extensions, and whether one is
    /// in use right now (checked again just before each).
    var trashExtensions: ([AppDataEntry], @escaping @Sendable (URL) -> Bool) async -> CleanReport = {
        await Extensions.trash($0, inUse: $1)
    }

    /// Injected by tests. Lists the installed apps.
    var installedApps: () async -> [InstalledApp] = { await Uninstaller.installedApps() }
    /// Injected by tests. Size of an app bundle; returns 0 when its task is cancelled (the file walk stops).
    var appSize: @Sendable (URL) async -> Int64 = { await Uninstaller.size(of: $0) }

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { self.runningApps = self.appBundleIDs() } }
            })
        }
    }

    /// The "not used for" filter also lists apps with no last-used date (off by default: not knowing is not "unused").
    @Published var showUndated = false { didSet { if showUndated != oldValue { deselectUnlistedApp() } } }

    var filteredApps: [InstalledApp] { Self.filtered(apps, search: search, unused: unused, includeUndated: showUndated) }

    /// Apps the "not used for" filter leaves out for having no last-used date (0 with no filter or `showUndated`).
    var hiddenUndatedCount: Int {
        guard unused != .all, !showUndated else { return 0 }
        return Self.filtered(apps, search: search, unused: .all).count { $0.lastUsed == nil }
    }

    /// Search (name or bundle id) and "not used for" filter. An app with no last-used date (`InstalledApp.lastUsed`)
    /// passes the filter only with `includeUndated`: it may well be in use.
    nonisolated static func filtered(_ apps: [InstalledApp], search: String, unused: UnusedFilter, includeUndated: Bool = false,
                                     now: Date = .now) -> [InstalledApp] {
        let months = switch unused { case .all: 0; case .months3: 3; case .months6: 6; case .year1: 12 }
        let cutoff = months == 0 ? nil : Calendar.current.date(byAdding: .month, value: -months, to: now)
        return apps.filter { app in
            (search.isEmpty || app.name.localizedStandardContains(search) || app.bundleID.localizedStandardContains(search))
                && (cutoff.map { cutoff in app.lastUsed.map { $0 < cutoff } ?? includeUndated } ?? true)
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

    /// Size: largest first; last used: oldest first. Apps whose size/date is not known go last; ties by name.
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

    /// Ticked apps in list order (also those the search or filter hides now: the batch panel lists them all).
    var tickedApps: [InstalledApp] { apps.filter { appTicks.contains($0.url) } }

    /// More than one app ticked: the batch panel replaces an app's detail.
    var batchMode: Bool { appTicks.count > 1 }

    /// The Applications header checkbox: ticks every listed app, or unticks them when all are ticked.
    func tickListed(_ on: Bool) {
        guard !working else { return }
        let listed = filteredApps.map(\.url)
        if on { appTicks.formUnion(listed) } else { appTicks.subtract(listed) }
    }

    /// App + `.data` size of each ticked app that is not open (open ones are skipped); nil while one is still
    /// measured or loading.
    var batchSize: Int64? {
        var total: Int64 = 0
        for app in tickedApps where !isRunning(app) {
            guard let size = appSizes[app.url], let data = batchData[app.url] else { return nil }
            total += data.reduce(size) { $0 + $1.size }
        }
        return total
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
        appTicks.formIntersection(apps.map(\.url)) // removed outside CleanMate
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
        batchData = [:]
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
            let found = await data(of: app)
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

    /// What the app's detail lists. All installed apps (incl. Apple's, nested and unlisted ones) and running ones
    /// shield their data, not just the listed apps.
    private func data(of app: InstalledApp) async -> [AppDataEntry] {
        let others = apps.filter { $0.url != app.url }
        let ids = Uninstaller.allBundleIDs().union(runningApps).union(others.map(\.bundleID))
        let names = Set(others.flatMap(\.names)).union(Uninstaller.otherAppNames(than: app.url, in: Uninstaller.allAppURLs()))
        return await appData(app, ids, names)
    }

    /// Loads the `.data` entries of ticked apps not loaded yet, for the batch panel's sizes and `removeBatch`.
    func loadBatch() async {
        for app in tickedApps where batchData[app.url] == nil {
            let found = await data(of: app).filter { $0.kind == .data }
            guard !Task.isCancelled else { return }
            if appTicks.contains(app.url) { batchData[app.url] = found }
        }
    }

    /// Uninstalls the ticked apps one by one through the same path as one app: the app, then its `.data` entries
    /// (never suggestions or config). An open app, one locked in Finder or one that can't go to the Trash is left
    /// with its reason; it doesn't stop the others. One Undo puts back everything moved.
    func removeBatch() async {
        guard !working else { return }
        let ticked = tickedApps
        guard !ticked.isEmpty else { return }
        runningApps = appBundleIDs() // a launch may not have been notified yet
        working = true
        defer { working = false }
        undoManager?.removeAllActions(withTarget: self)
        var result = BatchResult()
        for app in ticked {
            if isRunning(app) { result.skipped.append((app, .running)); continue }
            let ownData: [AppDataEntry]
            if let loaded = batchData[app.url] { ownData = loaded } else { ownData = await data(of: app).filter { $0.kind == .data } }
            do {
                result.report += try await trash(app.url, ownData)
                result.removed.append(app)
            } catch {
                let reason: SkipReason = switch error {
                case .locked: .locked
                case .cancelled: .cancelled
                case .notTrashed: .notTrashed
                }
                result.skipped.append((app, reason))
            }
        }
        let removed = Set(result.removed.map(\.url))
        apps.removeAll { removed.contains($0.url) }
        appTicks.subtract(removed)
        if case .app(let url) = selection, removed.contains(url) { selection = nil }
        outcome = .batch(result)
        invalidateAppData()
        if !result.report.trashed.isEmpty {
            undoManager?.registerTrashUndo(self, name: String(localized: "Uninstall")) { await $0.undo(result.report) }
        }
        Attention.finished()
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
            appTicks.remove(app.url)
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
