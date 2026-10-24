import AppKit
import Observation

/// Scan → select → clean state for a list of cleaner groups (Smart Scan, Privacy).
@Observable
final class SmartScanModel {
    enum Phase { case idle, scanning, results, cleaning, done(CleanReport) }

    let module: Module
    /// Rebuilt from the catalog at every scan, so Settings changes (age thresholds) apply.
    private(set) var groups: [CleanerGroup]
    /// Entering results sorts each group's items once; while scanning they keep catalog order so rows don't jump.
    var phase = Phase.idle {
        didSet { if case .results = phase { groups = groups.map { Self.sortedBySize($0, scans: scans) } } }
    }
    var scans: [String: ItemScan] = [:]
    var selected: Set<String> = []
    /// Entries left out of a ticked item with `selectableEntries`: item id → entry URLs. Per session, never remembered.
    var excludedEntries: [String: Set<URL>] = [:]
    /// Ids of result groups the user folded away; per session, kept across rescans since group ids are stable.
    var collapsedGroups: Set<String> = []
    /// Item ids of the result rows highlighted with the keyboard/mouse (List selection), not the ticks.
    var highlighted: Set<String> = []
    /// Bundle ids of running apps, kept current through NSWorkspace launch/terminate notifications.
    var runningApps = SmartScanModel.currentRunningApps()
    /// Names of running command-line tools; no notification exists, so refreshed at each scan and before cleaning.
    var runningProcesses: Set<String> = []
    /// Source of `runningApps` when an app launches or quits and before cleaning. Injected by tests, so an app
    /// opening or quitting on the Mac mid-test can't swap their fake list for the real one.
    @ObservationIgnored var appBundleIDs: () -> Set<String> = SmartScanModel.currentRunningApps
    /// Injected by tests.
    @ObservationIgnored var processNames: () -> Set<String> = RunningProcesses.names
    /// Item ids whose tool folder overlaps Settings › Exclusions at the last scan: locked, unticked, not counted.
    var blocked: Set<String> = []
    /// The check `Cleaner` makes before running the item's command; tests pass a sandbox policy.
    @ObservationIgnored var blockedByExclusion: @Sendable (CleanerItem) async -> Bool = { await Cleaner.blockedByExclusion($0) }
    /// Injected by tests (e.g. a slow scan).
    @ObservationIgnored var scanItem: @Sendable (CleanerItem) async -> ItemScan = { await Scanner.scan($0) }
    /// Injected by tests (a sandbox policy and a fake Trash).
    /// Saves exclusions ("Never Clean This"); tests inject a throwaway defaults domain.
    @ObservationIgnored var exclude: ([URL]) -> [URL] = { Preferences.exclude($0) }
    /// Home whose activity log records each clean; tests pass a throwaway folder.
    @ObservationIgnored var logHome = SafetyPolicy.current.homeURL
    @ObservationIgnored var cleanItem: @Sendable (CleanerItem, ItemScan) async -> CleanReport = { await Cleaner.clean($0, scan: $1) }
    /// Items scanned so far / items to scan, for the progress bar.
    var scannedItems = 0
    var totalItems = 0
    /// Title of the item being cleaned; progress while cleaning reuses scannedItems/totalItems.
    var cleaningItem: LocalizedStringResource?  // optional, not "": an empty literal adds a "" key to the catalog
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    /// Bumped by every scan: an older scan that is still finishing never writes over a newer one.
    @ObservationIgnored private var generation = 0
    /// What a cancelled scan restores; kept from before the first of back-to-back scans, never a `.scanning` state.
    @ObservationIgnored private var beforeScan: (Phase, [CleanerGroup], [String: ItemScan], Set<String>, [String: Set<URL>], Set<String>)?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let catalog: () -> [CleanerGroup]
    /// Where each item's scan time from the last finished scan is kept; nil (custom catalogs, tests) = not kept.
    @ObservationIgnored var durationsKey: String?
    /// Group ids turned off in Settings › Scan Groups; only the real Smart Scan catalog reads them, so Privacy and
    /// tests' custom catalogs are never filtered unless a test injects a throwaway defaults domain.
    @ObservationIgnored var disabledGroups: () -> Set<String> = { [] }
    /// Ids of every catalog group, enabled or not, refreshed with each catalog read: the view counts the ones off.
    @ObservationIgnored private(set) var catalogGroupIDs: [String] = []
    /// Groups off right now: a group turned off after its scan is hidden, left out of the totals and not cleaned;
    /// turned back on, its already scanned results come back (no rescan needed: they are still in `scans`).
    private(set) var offGroups: Set<String> = []
    /// Item id → seconds from the last finished scan, read when a scan starts.
    @ObservationIgnored private var estimates: [String: Double] = [:]

    /// `catalog` defaults to the module's own (Privacy or Smart Scan).
    init(module: Module, catalog: (() -> [CleanerGroup])? = nil) {
        self.module = module
        durationsKey = catalog == nil ? Preferences.smartScanLastDurations : nil
        self.catalog = catalog ?? (module == .privacy ? { CleanerGroup.privacy } : { CleanerGroup.smartScan })
        let realSmartScan = catalog == nil && module == .smartScan
        if realSmartScan { disabledGroups = { Preferences.disabledGroups() } }
        groups = []
        groups = enabledGroups()
        if realSmartScan {
            observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                                                    queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDisabled() }
            })
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { self.runningApps = self.appBundleIDs() } }
            })
        }
    }

    nonisolated static func currentRunningApps() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    /// `pattern` is a bundle id or ends with `*` (`com.jetbrains.*`: every JetBrains IDE).
    nonisolated static func bundleID(_ id: String, matches pattern: String) -> Bool {
        pattern.hasSuffix("*") ? id.hasPrefix(pattern.dropLast()) : id == pattern
    }

    /// The item's app is open: it is not selected by default and is skipped when cleaning.
    /// Running, or blocked by an exclusion: the row's checkbox is locked and the item is never counted or cleaned.
    func isLocked(_ item: CleanerItem) -> Bool { isRunning(item) || blocked.contains(item.id) }

    func isRunning(_ item: CleanerItem) -> Bool {
        runningApps.contains { id in item.runningAppBundleIDs.contains { Self.bundleID(id, matches: $0) } }
            || item.runningProcessNames.contains(where: runningProcesses.contains)
    }

    /// The catalog without the groups turned off in Settings.
    private func enabledGroups() -> [CleanerGroup] {
        let all = catalog()
        catalogGroupIDs = all.map(\.id)
        let off = disabledGroups()
        offGroups = off
        return all.filter { !off.contains($0.id) }
    }

    /// Re-reads the groups turned off in Settings; set only on change so views don't redraw on every defaults write.
    func refreshDisabled() {
        let off = disabledGroups()
        if off != offGroups { offGroups = off }
    }

    /// Scanned groups still on in Settings.
    private var activeGroups: [CleanerGroup] { groups.filter { !offGroups.contains($0.id) } }

    /// How many catalog groups `disabled` turns off; every one off = nothing to scan.
    func disabledCount(_ disabled: Set<String>) -> Int { catalogGroupIDs.filter(disabled.contains).count }

    /// Asks the item's app to quit (it may still ask to save) and selects the item for when it has quit;
    /// not when it has nothing to clean or is blocked by an exclusion: those rows can't be ticked by hand either.
    func quitApps(of item: CleanerItem) {
        for app in NSWorkspace.shared.runningApplications where item.runningAppBundleIDs.contains(where: { Self.bundleID(app.bundleIdentifier ?? "", matches: $0) }) {
            app.terminate()
        }
        if scans[item.id]?.hasData == true && !blocked.contains(item.id) { selected.insert(item.id) }
    }

    /// Ticks or unticks `item` and remembers the choice for the next scans, across launches.
    func setSelected(_ item: CleanerItem, _ on: Bool) {
        if on { selected.insert(item.id) } else { selected.remove(item.id) }
        excludedEntries[item.id] = nil // ticking or unticking the item ticks or unticks every entry
        Preferences.remember(item, selected: on)
    }

    /// Ticked with none of its entries left out.
    func isFullySelected(_ item: CleanerItem) -> Bool {
        selected.contains(item.id) && excludedEntries[item.id]?.isEmpty != false
    }

    func isEntrySelected(_ item: CleanerItem, _ url: URL) -> Bool {
        selected.contains(item.id) && excludedEntries[item.id]?.contains(url) != true
    }

    /// Ticks or unticks one entry. Ticking one of an unticked item ticks the item with only that entry;
    /// unticking the last one unticks the item. Not remembered, unlike an item tick.
    func setEntry(_ item: CleanerItem, _ url: URL, _ on: Bool) {
        let all = Set(scans[item.id]?.entries.map(\.url) ?? [])
        var out = selected.contains(item.id) ? excludedEntries[item.id, default: []] : all
        if on { out.remove(url) } else { out.insert(url) }
        if out.isSuperset(of: all) {
            selected.remove(item.id)
            excludedEntries[item.id] = nil
        } else {
            selected.insert(item.id)
            excludedEntries[item.id] = out.isEmpty ? nil : out
        }
    }

    /// "Never Clean This": `url` joins Settings › Exclusions and leaves the item's entries, totals and selection.
    /// False when it can't be excluded (package, symlink…).
    func neverClean(_ item: CleanerItem, _ url: URL) -> Bool {
        guard !exclude([url]).isEmpty, var scan = scans[item.id] else { return false }
        scan.entries.removeAll { $0.url == url }
        scans[item.id] = scan
        excludedEntries[item.id]?.remove(url)
        // Nothing left to clean, or only entries the user left out: the item is no longer ticked.
        if !scan.hasData || excludedEntries[item.id]?.isSuperset(of: scan.entries.map(\.url)) == true {
            selected.remove(item.id)
            excludedEntries[item.id] = nil
        } else if excludedEntries[item.id]?.isEmpty == true {
            excludedEntries[item.id] = nil
        }
        return true
    }

    /// The item's scan as it will be cleaned: without the entries left out.
    func selectedScan(_ item: CleanerItem) -> ItemScan? {
        guard var scan = scans[item.id] else { return nil }
        if let out = excludedEntries[item.id] { scan.entries.removeAll { out.contains($0.url) } }
        return scan
    }

    /// Bytes to clean when only some of the item's entries are ticked; nil when it is ticked whole or not at all.
    func partialSelectedSize(_ item: CleanerItem) -> Int64? {
        selected.contains(item.id) && !isFullySelected(item) ? selectedScan(item)?.size : nil
    }

    /// Items a group's Select All/Deselect All acts on: the same rows whose checkbox is enabled.
    func selectableItems(in group: CleanerGroup) -> [CleanerItem] {
        group.items.filter { scans[$0.id]?.hasData == true && !isLocked($0) }
    }

    /// Every selectable item of `group` is ticked (false when none can be).
    func isAllSelected(_ group: CleanerGroup) -> Bool {
        let items = selectableItems(in: group)
        return !items.isEmpty && items.allSatisfy(isFullySelected)
    }

    /// Ticks every selectable item of `group`, or unticks every ticked one, remembered like a tick by hand.
    /// Deselect All also unticks a locked row still ticked (Quit App, an app opened after the scan):
    /// it would otherwise be cleaned once its app quits, after the user deselected the whole group.
    func setSelected(_ group: CleanerGroup, _ on: Bool) {
        let items = on ? selectableItems(in: group).filter { !isFullySelected($0) } : group.items.filter { selected.contains($0.id) }
        for item in items { setSelected(item, on) }
    }

    /// Space on highlighted rows, like Finder: ticks them all if any selectable one is off, else unticks them.
    /// Locked rows (no data, app running, blocked by an exclusion) are left alone.
    func toggle(ids: Set<String>) {
        let items = activeGroups.flatMap { selectableItems(in: $0) }.filter { ids.contains($0.id) }
        let on = items.contains { !isFullySelected($0) } // a partly ticked item counts as off
        for item in items where on ? !isFullySelected(item) : selected.contains(item.id) { setSelected(item, on) }
    }

    /// Bytes for sure, "up to" bytes and records; scanned items of a group, or the selection.
    struct Total: Equatable { var size: Int64 = 0, upTo: Int64 = 0, records = 0 }

    func total(of items: [CleanerItem]) -> Total {
        items.reduce(into: Total()) { total, item in
            guard let scan = scans[item.id] else { return }
            if item.sizeIsUpperBound { total.upTo += scan.size } else { total.size += scan.size }
            total.records += scan.records ?? 0
        }
    }

    /// What each group freed in the last clean, for the done screen; groups that freed nothing are left out.
    struct CleanedGroup: Identifiable { let id: String; let title: LocalizedStringResource; let systemImage: String
        var freed: Int64 = 0; var trashed: Int64 = 0 }
    var cleanedGroups: [CleanedGroup] = []

    private var items: [CleanerItem] { activeGroups.flatMap(\.items) }

    /// Scan progress 0…1: weighted by each item's time in the last finished scan, else items done / items.
    var scanFraction: Double {
        Self.fraction(done: Set(scans.keys), all: items.map(\.id), estimates: estimates)
            ?? Double(scannedItems) / Double(max(totalItems, 1))
    }

    /// Estimated time of the items done / of all items, capped at 99% until the scan finishes;
    /// an item without an estimate (new) counts as the average. nil when no item has one (first scan).
    static func fraction(done: Set<String>, all: [String], estimates: [String: Double]) -> Double? {
        let known = all.compactMap { estimates[$0] }
        guard !known.isEmpty else { return nil }
        let average = known.reduce(0, +) / Double(known.count)
        let weight = { (id: String) in estimates[id] ?? average }
        let total = all.reduce(0) { $0 + weight($1) }
        guard total > 0 else { return nil }
        return min(all.filter(done.contains).reduce(0) { $0 + weight($1) } / total, 0.99)
    }

    /// Groups as shown after a scan: items with nothing to clean are hidden unless `showsWhenEmpty`
    /// or a folder could not be read (the row then offers Full Disk Access, e.g. Safari, Chrome).
    /// While scanning every item is shown, so rows don't jump as results arrive.
    var visibleGroups: [CleanerGroup] {
        if case .scanning = phase { return activeGroups }
        return activeGroups.compactMap { group in
            let items = group.items.filter {
                $0.showsWhenEmpty || scans[$0.id]?.hasData == true || scans[$0.id]?.permissionDenied == true
            }
            return items.isEmpty ? nil : CleanerGroup(id: group.id, title: group.title, systemImage: group.systemImage, items: items)
        }
    }

    /// Biggest first. An upper-bound ("up to") item counts at its maximum, so a possibly large item isn't buried.
    /// Items without bytes (records only, unmeasured, unreadable) follow, most records first; ties keep catalog order.
    nonisolated static func sortedBySize(_ group: CleanerGroup, scans: [String: ItemScan]) -> CleanerGroup {
        let key = { (item: CleanerItem) in (scans[item.id]?.size ?? 0, scans[item.id]?.records ?? 0) }
        let items = group.items.enumerated().sorted { a, b in
            let (ka, kb) = (key(a.element), key(b.element))
            return ka != kb ? ka > kb : a.offset < b.offset
        }.map(\.element)
        return CleanerGroup(id: group.id, title: group.title, systemImage: group.systemImage, items: items)
    }

    /// Bytes the selected items will free for sure; items whose size is only a maximum are in `selectedUpToSize`.
    var selectedSize: Int64 { selectedSize(upperBound: false) }
    var selectedUpToSize: Int64 { selectedSize(upperBound: true) }

    private func selectedSize(upperBound: Bool) -> Int64 {
        items.filter { selected.contains($0.id) && !isLocked($0) && $0.sizeIsUpperBound == upperBound }
            .reduce(0) { $0 + (selectedScan($1)?.size ?? 0) }
    }

    /// Records the selected database items will erase (Privacy history etc. have no byte size).
    var selectedRecords: Int {
        items.filter { selected.contains($0.id) && !isLocked($0) }.reduce(0) { $0 + (selectedScan($1)?.records ?? 0) }
    }

    /// At least one selected item can be cleaned (privacy records have no size).
    var hasSelection: Bool {
        items.contains { selected.contains($0.id) && !isLocked($0) && selectedScan($0)?.hasData == true }
    }

    /// Starts a scan that `cancelScan()` can stop; ignored while cleaning.
    func startScan() {
        if case .cleaning = phase { return }
        scanTask?.cancel()
        scanTask = Task { await scan() }
    }

    func cancelScan() { scanTask?.cancel() }

    /// Scans every item, showing each result as soon as it is ready.
    /// When cancelled, nothing is kept: the previous phase, groups, results and selection come back.
    func scan() async {
        if case .cleaning = phase { return }
        let newGroups = enabledGroups()
        guard !newGroups.isEmpty else { return } // every group off in Settings: nothing to scan
        generation += 1
        let current = generation
        if case .scanning = phase {} else { beforeScan = (phase, groups, scans, selected, excludedEntries, blocked) }
        groups = newGroups
        scans = [:]
        selected = []
        excludedEntries = [:]
        blocked = []
        runningProcesses = processNames()
        phase = .scanning
        let newItems = items
        scannedItems = 0
        totalItems = newItems.count
        let overrides = Preferences.overrides
        let scanItem = scanItem
        let blockedByExclusion = blockedByExclusion
        estimates = durationsKey.map { Preferences.dictionary($0) } ?? [:]
        var durations: [String: Double] = [:]
        await withTaskGroup(of: (CleanerItem, ItemScan, Duration, Bool).self) { group in
            for item in newItems {
                group.addTask {
                    let start = ContinuousClock.now
                    let scan = await scanItem(item)
                    let took = start.duration(to: .now)
                    return (item, scan, took, await blockedByExclusion(item))
                }
            }
            for await (item, scan, took, isBlocked) in group where !Task.isCancelled && current == generation {
                scans[item.id] = scan
                if isBlocked { blocked.insert(item.id) }
                durations[item.id] = took / .seconds(1)
                if (overrides[item.id] ?? item.selectedByDefault) && !isLocked(item) && scan.hasData {
                    selected.insert(item.id)
                }
                scannedItems += 1
            }
        }
        guard current == generation else { return } // a newer scan owns the state now
        if Task.isCancelled, let beforeScan {
            (phase, groups, scans, selected, excludedEntries, blocked) = beforeScan
            return
        }
        // Re-read so a Privacy scan finished meanwhile keeps its own items' times (one shared key).
        if let durationsKey { Preferences.update(durationsKey) { (all: inout [String: Double]) in all.merge(durations) { $1 } } }
        phase = .results
        Attention.finished()
    }

    /// Entries removed, for the activity log. A run command (e.g. `docker image prune`) succeeds or fails as a
    /// whole: its `skipped` is 0 or 1 for the item, not per entry, and its entries may be display-only.
    nonisolated static func removedCount(_ item: CleanerItem, _ scan: ItemScan, _ result: CleanReport) -> Int {
        guard let command = item.command, item.paths.isEmpty || command.resolvedPath != nil else {
            return max(0, scan.entries.count - result.skipped)
        }
        return result.skipped > 0 ? 0 : max(result.freed > 0 ? 1 : 0, scan.entries.count)
    }

    /// Only from results: a second call, or one after a new scan started (⌘R behind the dialog), does nothing.
    func clean() async {
        guard case .results = phase else { return }
        phase = .cleaning
        runningApps = appBundleIDs()
        runningProcesses = processNames()
        refreshDisabled() // a group turned off since the scan is not cleaned
        var report = CleanReport()
        // Only what the "Selected" total counts: a ticked item with nothing left to clean never reaches the cleaner,
        // where a command item (Docker prune…) would run anyway.
        let todo = items.filter { selected.contains($0.id) && selectedScan($0)?.hasData == true }
        scannedItems = 0
        totalItems = todo.count
        var byGroup = groups.map { CleanedGroup(id: $0.id, title: $0.title, systemImage: $0.systemImage) }
        for item in todo {
            guard let scan = selectedScan(item) else { continue } // only the ticked entries
            cleaningItem = item.title
            defer { scannedItems += 1 }
            if isLocked(item) { report.skipped += 1; continue }
            let result = await cleanItem(item, scan)
            report += result
            if let index = groups.firstIndex(where: { $0.items.contains { $0.id == item.id } }) {
                byGroup[index].freed += result.freed
                if item.mode == .trash { byGroup[index].trashed += result.freed }
            }
            let removed = SmartScanModel.removedCount(item, scan, result)
            if result.freed > 0 || removed > 0 {
                ActivityLog.record(module: module.title, item: ActivityLog.english(item.title), count: removed,
                                   size: result.freed, mode: item.mode, home: logHome)
            }
        }
        scans = [:]
        selected = []
        excludedEntries = [:]
        cleanedGroups = byGroup.filter { $0.freed > 0 }
        phase = .done(report)
        Attention.finished()
    }
}
