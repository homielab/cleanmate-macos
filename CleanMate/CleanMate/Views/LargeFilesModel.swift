import Foundation
import Combine

/// Large & Old Files: scan the home folder (or the chosen scope inside it) once (≥ the smallest size option), then filter in memory.
final class LargeFilesModel: ObservableObject {
    /// A move to the Trash goes back to `.results`: the list stays, without the files moved (`lastTrash` says what went).
    enum Phase { case idle, scanning, results, trashing }

    static let sizeOptions: [Int64] = [50, 100, 500, 1_000, 5_000].map { $0 * 1_000_000 }
    /// A folder scope also offers 1 and 10 MB; the whole home stays at 50 MB or more (far too many files below).
    static let folderSizeOptions: [Int64] = [1, 10].map { $0 * 1_000_000 } + sizeOptions
    /// Months without use the Last Used menu offers; any time and a number of days are offered too.
    static let ageOptions = [1, 3, 6, 12, 24]
    /// Days the user may type for Last Used: a day to 100 years.
    static let customDays = 1...36_500

    /// Last Used: any time, or not used for some months (the menu) or a number of days (typed).
    enum UnusedFor: Hashable {
        case anyTime, months(Int), days(Int)

        /// Files last used before this date match; nil = any time.
        func cutoff(from now: Date = .now, calendar: Calendar = .current) -> Date? {
            switch self {
            case .anyTime: nil
            case .months(let months): calendar.date(byAdding: .month, value: -months, to: now)
            case .days(let days): calendar.date(byAdding: .day, value: -days, to: now)
            }
        }
    }

    @Published var phase = Phase.idle
    @Published var files: [LargeFile] = [] {
        didSet { (nameRanks, locationRanks) = (nil, nil) }
    }
    /// Name / location → position in `localizedStandardCompare` order, built on the first sort by that column after a
    /// scan; later sorts compare Ints instead of strings.
    private var nameRanks: [String: Int]?
    private var locationRanks: [String: Int]?
    /// Ticked for the Trash. Never pre-filled.
    @Published var checked: Set<URL> = []
    /// A size below what the files were scanned at scans again; a larger one only filters.
    @Published var minSize = sizeOptions[0] {
        didSet { if minSize < scannedMinSize { scan() } }
    }
    /// Smallest size the current files were scanned at.
    @Published private(set) var scannedMinSize = sizeOptions[0]
    /// Sizes the Size menu offers for the current scope.
    var sizeChoices: [Int64] { scope == nil ? Self.sizeOptions : Self.folderSizeOptions }
    @Published var unusedFor = UnusedFor.anyTime
    /// nil = all kinds.
    @Published var kind: FileKind?
    /// Toolbar search: file name or location; "" = no search.
    @Published var search = ""
    /// Duplicates › Duplicate Files replaces the file list with its own search of the scan's scope (down to 1 MB,
    /// not limited to the large files listed); turning it on searches once per scan.
    @Published var duplicatesShown = false {
        didSet {
            guard duplicatesShown != oldValue else { return }
            if duplicatesShown {
                similarPhotosShown = false
                findDuplicates()
            } else {
                duplicates.reset()
            }
        }
    }
    /// Duplicates › Similar Photos replaces the file list; turning it on searches the scan's scope once per scan.
    @Published var similarPhotosShown = false {
        didSet {
            guard similarPhotosShown != oldValue else { return }
            if similarPhotosShown {
                duplicatesShown = false
                findSimilarPhotos()
            } else {
                similarPhotos.reset()
            }
        }
    }
    /// The Duplicates menu: all files, identical files, or similar photos.
    enum Listing: Hashable { case allFiles, duplicates, similarPhotos }
    var listing: Listing {
        get { similarPhotosShown ? .similarPhotos : duplicatesShown ? .duplicates : .allFiles }
        set {
            switch newValue {
            case .allFiles: (duplicatesShown, similarPhotosShown) = (false, false)
            case .duplicates: duplicatesShown = true
            case .similarPhotos: similarPhotosShown = true
            }
        }
    }
    let duplicates = DuplicatesModel()
    let similarPhotos = SimilarPhotosModel()
    private var subModelChanges: [AnyCancellable] = []
    init() {
        // The sidebar badge and the Duplicates menu follow the duplicates and similar photos too.
        subModelChanges = [duplicates.objectWillChange.sink { [weak self] in self?.objectWillChange.send() },
                           similarPhotos.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }]
        duplicates.onTrashed = { [weak self] urls in self?.dropTrashed(urls) }
        similarPhotos.onTrashed = { [weak self] urls in self?.dropTrashed(urls) }
    }

    /// Duplicate Files or Similar Photos is moving files to the Trash or putting them back: no scan now.
    var subModelChanging: Bool { duplicates.isChanging || similarPhotos.isChanging }
    /// Files and folders checked so far by the running scan (the total is unknown up front).
    @Published var scannedCount = 0
    /// Entries the last finished scan of the same scope checked; 0 = unknown (first scan).
    @Published var estimatedCount = 0
    /// Where the entry count of each scope persists (`Preferences.largeFilesLastCount`); nil = memory only.
    /// Never the real preferences under a test host.
    var lastCountDefaults: UserDefaults? =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil ? .standard : nil
    private var memoryLastCounts: [String: Int] = [:]
    /// Most scopes whose entry count is kept: home, the presets and the recent folders, with and without Full Disk Access.
    static let lastCountLimit = 20
    /// Shortest time between two `scannedCount` updates while scanning.
    nonisolated static let progressInterval = Duration.milliseconds(100)
    /// Determinate progress of the running scan, or nil when there is no estimate.
    var scanFraction: Double? { Self.fraction(checked: scannedCount, estimate: estimatedCount) }
    /// The last scan left out folders macOS protects (no Full Disk Access): the view shows a note.
    @Published var skippedProtected = false
    /// The home folder; tests and snapshots set a fake one.
    var home = SafetyPolicy.current.homeURL
    /// The scan's rules for `home` (tests set their own home); external volumes as mounted now.
    private var policy: SafetyPolicy {
        SafetyPolicy(home: home, temp: FileManager.default.temporaryDirectory, excluded: Preferences.excluded)
    }

    /// External volumes the Scope menu offers (mounted in /Volumes, browsable, not the startup disk), by name.
    static func externalVolumes() -> [URL] {
        let policy = SafetyPolicy.current
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsBrowsableKey],
                                                         options: [.skipHiddenVolumes]) ?? []
        return urls.filter { url in
            (try? url.resourceValues(forKeys: [.volumeIsBrowsableKey]))?.volumeIsBrowsable != false
                && policy.allowsExternalRoot(url)
        }
        .map { folder($0.path) }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
    /// Folder scanned; nil = the whole home folder.
    @Published private(set) var scope: URL?
    /// Scope of the files shown: a cancelled scan puts `scope` back to it, so a label never names other files.
    private var scannedScope: URL?
    /// The scope is a folder macOS protects and there is no Full Disk Access: nothing was scanned.
    @Published var needsAccess = false
    /// Presets of the Scope menu, relative to home.
    static let scopePresets = ["Downloads", "Desktop", "Documents"]

    /// One URL form per folder path, so menu tags and `scope` compare equal.
    static func folder(_ path: String) -> URL { URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL }

    /// `~/Downloads`-style name of the scope, nil for the whole home folder.
    var scopeName: String? {
        scope.map { LargeFile.displayLocation(of: $0.appending(path: "_"), home: home) } // a file inside it → its folder
    }

    /// Scans `folder` (nil or the home folder = all of home) when the scan accepts it; false for a folder outside
    /// home, in ~/Library or hidden. Ignored while trashing or undoing, like `scan()`.
    @discardableResult
    func setScope(_ folder: URL?) -> Bool {
        if let folder, !LargeFileScanner.allowsRoot(folder, policy: policy) { return false }
        if case .trashing = phase { return true }
        if undoing || subModelChanging { return true }
        let url = folder.map { Self.folder($0.path) }
        scope = url == Self.folder(home.path) ? nil : url
        if scope == nil { minSize = max(minSize, Self.sizeOptions[0]) } // only raises: no scan from `didSet`
        scan()
        return true
    }

    /// Restores the scope saved by the view before the first scan; a folder that is gone, outside home, in
    /// ~/Library or hidden, excluded, or protected without Full Disk Access silently falls back to the home folder.
    func restoreScope(_ path: String, excluded: [String] = Preferences.excluded) {
        guard case .idle = phase else { return }
        scope = nil
        guard !path.isEmpty else { return }
        let url = Self.folder(path)
        var isFolder: ObjCBool = false
        let lower = url.path.lowercased()
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue,
              LargeFileScanner.allowsRoot(url, policy: policy),
              !excluded.map({ Self.folder($0).path.lowercased() }).contains(where: { lower == $0 || lower.hasPrefix($0 + "/") }),
              !ProtectedFolders.contains(ProtectedFolders.skipped(home: home, hasFullDiskAccess: hasFullDiskAccess()), url),
              url != Self.folder(home.path)
        else { return }
        scope = url
    }
    /// "Undo"; tests pass their own so the real Trash is never touched.
    var restore: ([TrashedItem]) async -> TrashUndo.Result = { await TrashUndo.restore($0, module: "Large & Old Files") }
    /// Injectable for tests.
    /// Saves exclusions ("Never Clean This"); tests inject a throwaway defaults domain.
    var exclude: ([URL]) -> [URL] = { Preferences.exclude($0) }
    var hasFullDiskAccess: () -> Bool = { FullDiskAccess.isGranted }
    /// Folders macOS protects are left out without Full Disk Access (Similar Photos says so).
    var skipsProtectedFolders: Bool {
        !ProtectedFolders.skipped(home: home, hasFullDiskAccess: hasFullDiskAccess()).isEmpty
    }
    /// Injected by tests (e.g. a slow scan); args: root, minimum size, skipped folders, progress.
    var scanFiles: @Sendable (URL, Int64, Set<String>, @escaping @Sendable (Int) -> Void) async throws -> [LargeFile] = {
        try await LargeFileScanner.scan(root: $0, minSize: $1, skipping: $2, progress: $3)
    }
    /// Injected by tests so the real Trash is never touched.
    var trashFiles: ([LargeFile]) async -> CleanReport = { await LargeFileScanner.trash($0) }
    /// Injected by tests so no real iCloud file is touched.
    var removeDownloadFiles: ([URL]) async -> ICloudDownloads.Report = { await ICloudDownloads.remove($0) }
    /// A Remove Download is running: its buttons are off.
    @Published private(set) var removingDownloads = false
    /// The last Remove Download's result, for the notice; `downloadRemovals` counts them so each one shows.
    @Published private(set) var downloadsRemoved: ICloudDownloads.Report?
    @Published private(set) var downloadRemovals = 0
    /// The window's, set by the view: ⌘Z after a move to the Trash.
    weak var undoManager: UndoManager?
    /// "Undo" is putting files back: a scan now could miss them.
    @Published private(set) var undoing = false
    /// The last move to the Trash, shown above the list (what went, what didn't, "Undo") until the next scan or
    /// until dismissed. Set by `trash()` (tests and snapshots set it directly).
    @Published var lastTrash: CleanReport?
    /// Space the last move frees once the Trash is emptied.
    private(set) var lastTrashFreed: Int64 = 0
    /// Stop was clicked while moving to the Trash: the move ends after the file under way.
    @Published private(set) var stoppingTrash = false
    /// The move to the Trash under way, for Stop.
    private var trashRun: TrashRun?
    /// The rows that move took out of the list: "Undo" lists again those put back.
    private var trashedRows: [LargeFile] = []
    private var scanTask: Task<Void, Never>?
    /// Bumped by every scan: an older scan that is still finishing never writes over a newer one.
    private var generation = 0
    /// What a cancelled scan restores; kept from before the first of back-to-back scans, never `.scanning`.
    private var beforeScan = Phase.idle

    var visibleFiles: [LargeFile] { files(of: kind) }

    /// Files passing the size, age and search filters, of `kind` (nil = all kinds).
    func files(of kind: FileKind?) -> [LargeFile] {
        let cutoff = unusedFor.cutoff()
        let search = search.trimmingCharacters(in: .whitespaces)
        return files.filter {
            $0.matches(minSize: minSize, unusedSince: cutoff) && (kind == nil || $0.kind == kind)
                && (search.isEmpty || $0.name.localizedStandardContains(search) || $0.location.localizedStandardContains(search))
        }
    }

    /// `files.sorted(using: order)`, same order, but Name and Location compare precomputed ranks.
    func sorted(_ files: [LargeFile], using order: [KeyPathComparator<LargeFile>]) -> [LargeFile] {
        let byName = order.contains { $0.keyPath == \LargeFile.name }
        let byLocation = order.contains { $0.keyPath == \LargeFile.location }
        guard byName || byLocation else { return files.sorted(using: order) }
        if byName, nameRanks == nil { nameRanks = Self.ranks(self.files.map(\.name)) }
        if byLocation, locationRanks == nil { locationRanks = Self.ranks(self.files.map(\.location)) }
        let (names, locations) = (nameRanks ?? [:], locationRanks ?? [:])
        // Rank columns, direction and key path checks hoisted out of the comparison: touching the comparators (key path
        // `==`, copies) 800k times cost more than the string compares saved.
        let ranks: [(ranks: [Int], forward: Bool)?] = order.map { comparator in
            switch comparator.keyPath {
            case \LargeFile.name: (files.map { names[$0.name] ?? 0 }, comparator.order == .forward)
            case \LargeFile.location: (files.map { locations[$0.location] ?? 0 }, comparator.order == .forward)
            default: nil
            }
        }
        if ranks.count == 1, let (rank, forward) = ranks[0] { // the Table's usual single-column sort
            return files.indices.sorted { forward ? rank[$0] < rank[$1] : rank[$0] > rank[$1] }.map { files[$0] }
        }
        return files.indices.sorted { a, b in
            for i in ranks.indices {
                if let (rank, forward) = ranks[i] {
                    if rank[a] != rank[b] { return (rank[a] < rank[b]) == forward }
                } else {
                    let result = order[i].compare(files[a], files[b])
                    if result != .orderedSame { return result == .orderedAscending }
                }
            }
            return false
        }.map { files[$0] }
    }

    /// Each distinct string → its index in `localizedStandardCompare` order; strings comparing equal share a rank.
    static func ranks(_ strings: [String]) -> [String: Int] {
        var ranks: [String: Int] = [:]
        var rank = 0
        var previous: String?
        for string in Set(strings).sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            if let previous, previous.localizedStandardCompare(string) != .orderedSame { rank += 1 }
            ranks[string] = rank
            previous = string
        }
        return ranks
    }

    /// Only ticked files that the current filters still show are trashed (never one in iCloud Drive).
    var checkedFiles: [LargeFile] { visibleFiles.filter { $0.trashable && checked.contains($0.url) } }
    var checkedSize: Int64 { checkedFiles.reduce(0) { $0 + $1.size } }

    /// Every shown file is ticked (false when nothing is shown): the bottom bar's button reads "Deselect All".
    var allVisibleChecked: Bool {
        let visible = visibleFiles.filter(\.trashable)
        return !visible.isEmpty && visible.allSatisfy { checked.contains($0.url) }
    }

    /// Select All/Deselect All: only the shown files the Trash takes; ticks on files a filter hides stay as they are.
    func setVisibleChecked(_ on: Bool) {
        let urls = visibleFiles.filter(\.trashable).map(\.url)
        if on { checked.formUnion(urls) } else { checked.subtract(urls) }
    }

    /// ⌘A / ⇧⌘A, like the bottom bar's button: Select All or Deselect All, on the shown files.
    func setCheckedByKey(_ on: Bool) { setVisibleChecked(on) }

    /// "Never Clean This": `urls` join Settings › Exclusions and leave the list; false when none could.
    func neverClean(_ urls: Set<URL>) -> Bool {
        let gone = Set(exclude(Array(urls)))
        guard !gone.isEmpty else { return false }
        files.removeAll { gone.contains($0.url) }
        checked.subtract(gone)
        return true
    }

    /// Files among `urls` whose download Remove Download may take now (iCloud says every change is uploaded).
    func removableDownloads(_ urls: Set<URL>) -> [LargeFile] {
        files.filter { urls.contains($0.url) && $0.icloud?.allowsRemovingDownload == true }
    }

    /// Remove Download: each file's local copy goes, the file stays in iCloud. Only from results, with Full Disk
    /// Access (iCloud Drive is only listed with it), never twice at once. Removed files leave the list; a file kept
    /// shows its state as read right before.
    func removeDownloads(of selection: [LargeFile]) async {
        guard case .results = phase, !removingDownloads, hasFullDiskAccess() else { return }
        let urls = selection.filter { $0.icloud?.allowsRemovingDownload == true }.map(\.url)
        guard !urls.isEmpty else { return }
        removingDownloads = true
        let report = await removeDownloadFiles(urls)
        removingDownloads = false
        let gone = Set(report.removed)
        files = files.compactMap { file in
            if gone.contains(file.url) { return nil }
            guard let state = report.kept[file.url] else { return file }
            var file = file
            file.icloud = state ?? .notUploaded // no longer readable as an iCloud file: never offered again
            return file
        }
        checked.subtract(gone)
        downloadsRemoved = report
        downloadRemovals += 1
    }

    /// `checked / estimate`, capped at 99% until the scan finishes (this run may check more than the last one).
    static func fraction(checked: Int, estimate: Int) -> Double? {
        estimate > 0 ? min(Double(checked) / Double(estimate), 0.99) : nil
    }

    /// Ignored while trashing (the listing would show files that are about to go) or undoing (it would miss files coming back).
    func scan() {
        if case .trashing = phase { return }
        if undoing || subModelChanging { return }
        undoManager?.removeAllActions(withTarget: self)
        lastTrash = nil
        trashedRows = []
        scanTask?.cancel()
        generation += 1
        let current = generation
        if case .scanning = phase {} else { beforeScan = phase }
        phase = .scanning
        scannedCount = 0
        let root = scope ?? home
        let threshold = scope == nil ? Self.sizeOptions[0] : min(minSize, Self.sizeOptions[0])
        let skipping = ProtectedFolders.skipped(home: home, hasFullDiskAccess: hasFullDiskAccess())
        duplicates.reset()
        similarPhotos.reset()
        // Listing a protected folder without Full Disk Access would make macOS prompt: ask for access instead.
        if ProtectedFolders.contains(skipping, root) {
            needsAccess = true
            scannedScope = scope
            files = []
            checked = []
            skippedProtected = false
            phase = .results
            return
        }
        // Same folder and same Full Disk Access state → roughly the same number of entries as last time.
        let scopeKey = "\(root.path)|\(skipping.isEmpty ? "full" : "limited")"
        estimatedCount = lastCounts[scopeKey] ?? 0
        let scanFiles = scanFiles
        // Highest count reported, and when the view last got one: at most ~10 redraws a second, since every
        // change of a published property redraws the window (reports come every 500 entries).
        let progress = Locked((count: 0, shown: ContinuousClock.now - .seconds(1)))
        scanTask = Task {
            do {
                let found = try await scanFiles(root, threshold, skipping) { count in
                    // Parallel walk: reports may land out of order.
                    let show: Int? = progress.withLock { state in
                        state.count = max(state.count, count)
                        guard ContinuousClock.now - state.shown >= Self.progressInterval else { return nil }
                        state.shown = .now
                        return state.count
                    }
                    guard let show else { return }
                    Task { @MainActor in if current == self.generation { self.scannedCount = max(self.scannedCount, show) } }
                }
                guard current == generation else { return } // a newer scan owns the state now
                try Task.checkCancellation()
                files = found.sorted { $0.size > $1.size }
                scannedMinSize = threshold
                scannedScope = scope
                needsAccess = false
                skippedProtected = !skipping.isEmpty
                checked = []
                if duplicatesShown { findDuplicates() }
                if similarPhotosShown { findSimilarPhotos() }
                // shortcut: progress arrives every 500 entries, so this undercounts by < 500; fine for an estimate.
                storeLastCount(progress.withLock { $0.count }, for: scopeKey)
                phase = .results
                Attention.finished()
            } catch {
                guard current == generation else { return }
                phase = beforeScan // cancelled: back to what was shown before, earlier results untouched
                if case .idle = beforeScan {} else {
                    // The scope and size those results were scanned at, not the ones of the cancelled scan.
                    scope = scannedScope
                    minSize = max(minSize, scannedMinSize) // only raises: no scan from `didSet`
                }
                if duplicatesShown { findDuplicates() } // stopped when the scan started
                if similarPhotosShown { findSimilarPhotos() }
            }
        }
    }

    func cancel() { scanTask?.cancel() }

    /// Duplicates in the scope of the files shown, with the same skips; not where Full Disk Access is needed.
    private func findDuplicates() {
        guard !needsAccess else { return }
        if case .results = phase {} else { return }
        duplicates.find(in: scannedScope ?? home, policy: policy,
                        skipping: ProtectedFolders.skipped(home: home, hasFullDiskAccess: hasFullDiskAccess()))
    }

    /// Similar photos in the scope of the files shown, with the same skips; not where Full Disk Access is needed.
    private func findSimilarPhotos() {
        guard !needsAccess else { return }
        if case .results = phase {} else { return }
        similarPhotos.find(in: scannedScope ?? home, policy: policy,
                           skipping: ProtectedFolders.skipped(home: home, hasFullDiskAccess: hasFullDiskAccess()))
    }

    /// Files moved to the Trash (or excluded) by Duplicate Files or Similar Photos leave the file list.
    private func dropTrashed(_ urls: [URL]) {
        let gone = Set(urls)
        guard !gone.isEmpty else { return }
        files.removeAll { gone.contains($0.url) }
        checked.subtract(gone)
    }

    /// Entry count of each scan scope (`"<path>|full"` or `"<path>|limited"`) from the last finished scans.
    var lastCounts: [String: Int] {
        guard let defaults = lastCountDefaults else { return memoryLastCounts }
        return Preferences.dictionary(Preferences.largeFilesLastCount, defaults: defaults)
    }

    private func storeLastCount(_ count: Int, for key: String) {
        guard let defaults = lastCountDefaults else {
            memoryLastCounts = Self.recordingLastCount(count, for: key, in: memoryLastCounts, home: home)
            return
        }
        Preferences.update(Preferences.largeFilesLastCount, defaults: defaults) { (counts: inout [String: Int]) in
            counts = Self.recordingLastCount(count, for: key, in: counts, home: home)
        }
    }

    /// `counts` with `count` stored under `key`, scopes outside `home` and /Volumes dropped (only those can be
    /// scanned; older versions also kept other paths) and at most `limit` scopes: `key` plus the others in path
    /// order. Pure string work: never touches a folder macOS may guard.
    static func recordingLastCount(_ count: Int, for key: String, in counts: [String: Int], home: URL,
                                   limit: Int = lastCountLimit) -> [String: Int] {
        let homePath = home.standardizedFileURL.path
        func insideHome(_ scopeKey: String) -> Bool {
            guard let bar = scopeKey.lastIndex(of: "|") else { return false }
            let path = URL(fileURLWithPath: String(scopeKey[..<bar])).standardizedFileURL.path
            return path == homePath || path.hasPrefix(homePath + "/") || path.hasPrefix("/Volumes/")
        }
        let others = counts.keys.filter { $0 != key && insideHome($0) }.sorted().prefix(max(limit - 1, 0))
        var result = Dictionary(uniqueKeysWithValues: others.map { ($0, counts[$0]!) })
        result[key] = count
        return result
    }

    /// Only from results: not twice, nor after a new scan started behind the dialog (⌘R). The list stays: the files
    /// moved leave it, the others stay listed, nothing is scanned again.
    func trash() async {
        guard case .results = phase else { return }
        let selection = checkedFiles
        phase = .trashing
        duplicates.reset() // a search's result would bring back groups of trashed files
        similarPhotos.reset()
        let run = TrashRun()
        trashRun = run
        let trashFiles = trashFiles
        let report = await TrashRun.$current.withValue(run) { await trashFiles(selection) }
        trashRun = nil
        stoppingTrash = false
        let gone = Set(report.trashed.map(\.original))
        trashedRows = selection.filter { gone.contains($0.url) }
        lastTrashFreed = trashedRows.reduce(0) { $0 + $1.size }
        dropTrashed(Array(gone))
        // The files a Stop left (the last ones the engine would have moved) keep their tick.
        let left = Set(selection.filter(\.trashable).suffix(report.stopped).map(\.url))
        checked.subtract(selection.map(\.url).filter { !left.contains($0) })
        lastTrash = report
        phase = .results
        if !report.trashed.isEmpty {
            undoManager?.registerTrashUndo(self, name: String(localized: "Move to Trash")) { await $0.undoTrash() }
        }
        Attention.finished()
    }

    /// Stop (or ⌘.) while moving to the Trash: the file under way finishes, the others stay listed and ticked, and the
    /// note says how many were left.
    func stopTrash() {
        guard case .trashing = phase, let trashRun, !stoppingTrash else { return }
        trashRun.stop()
        stoppingTrash = true
    }

    /// Closes the note of the last move to the Trash; its ⌘Z goes too (Moved Items still puts files back).
    func dismissTrashReport() {
        guard !undoing else { return }
        undoManager?.removeAllActions(withTarget: self)
        lastTrash = nil
        trashedRows = []
    }

    /// "Undo" in the note of the last move (or ⌘Z): puts the files just trashed back, once. Those back at their place
    /// are listed again.
    func undoTrash() async {
        guard var report = lastTrash, report.undo == nil, !report.trashed.isEmpty, !undoing else { return }
        undoManager?.removeAllActions(withTarget: self) // the button ran it, or ⌘Z did
        let items = report.trashed
        report.trashed = []
        lastTrash = report
        undoing = true
        let result = await restore(items)
        undoing = false
        report.undo = result
        lastTrash = report
        let listed = Set(files.map(\.url))
        let back = trashedRows.filter { !listed.contains($0.url) && FileManager.default.fileExists(atPath: $0.url.path) }
        trashedRows = []
        guard !back.isEmpty else { return }
        files += back
    }
}

extension LargeFilesModel: TrashUndoing {}
