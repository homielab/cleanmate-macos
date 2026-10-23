import Foundation
import Observation

/// Large & Old Files: scan the home folder (or the chosen scope inside it) once (≥ the smallest size option), then filter in memory.
@Observable
final class LargeFilesModel {
    enum Phase { case idle, scanning, results, trashing, done(CleanReport) }

    static let sizeOptions: [Int64] = [50, 100, 500, 1_000, 5_000].map { $0 * 1_000_000 }
    /// A folder scope also offers 1 and 10 MB; the whole home stays at 50 MB or more (far too many files below).
    static let folderSizeOptions: [Int64] = [1, 10].map { $0 * 1_000_000 } + sizeOptions
    /// Months without use; 0 = any age.
    static let ageOptions = [0, 3, 6, 12, 24]

    var phase = Phase.idle
    var files: [LargeFile] = [] {
        didSet { (nameRanks, locationRanks) = (nil, nil) }
    }
    /// Name / location → position in `localizedStandardCompare` order, built on the first sort by that column after a
    /// scan; later sorts compare Ints instead of strings.
    @ObservationIgnored private var nameRanks: [String: Int]?
    @ObservationIgnored private var locationRanks: [String: Int]?
    /// Ticked for the Trash. Never pre-filled.
    var checked: Set<URL> = []
    /// A size below what the files were scanned at scans again; a larger one only filters.
    var minSize = sizeOptions[0] {
        didSet { if minSize < scannedMinSize { scan() } }
    }
    /// Smallest size the current files were scanned at.
    private(set) var scannedMinSize = sizeOptions[0]
    /// Sizes the Size menu offers for the current scope.
    var sizeChoices: [Int64] { scope == nil ? Self.sizeOptions : Self.folderSizeOptions }
    var minAgeMonths = 0
    /// nil = all kinds.
    var kind: FileKind?
    /// Toolbar search: file name or location; "" = no search.
    var search = ""
    /// Only files with an identical copy among the scanned files; turning it on finds them once per scan.
    var duplicatesOnly = false {
        didSet { if duplicatesOnly != oldValue { duplicatesOnly ? findDuplicates() : stopFindingDuplicates() } }
    }
    /// Same-content groups of the current scan, nil until found (the filter has not been on since the scan).
    var duplicateGroups: [[URL]]? {
        didSet { duplicateIndex = Dictionary((duplicateGroups ?? []).enumerated().flatMap { i, g in g.map { ($0, i) } }) { a, _ in a } }
    }
    /// File → its index in `duplicateGroups`; kept so the filter does no work per file.
    private(set) var duplicateIndex: [URL: Int] = [:]
    /// Fraction of bytes read while finding duplicates; nil when not running.
    var duplicateProgress: Double?
    /// Hashes by (path, size, inode, modification date): a new scan only reads files that are new or changed.
    @ObservationIgnored private var duplicateHashes: [DuplicateFinder.Key: Data] = [:]
    /// Where hashes persist across launches; nil = memory only. Never the real cache under a test host.
    @ObservationIgnored var hashCacheURL: URL? =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil ? DuplicateFinder.HashCache.defaultURL : nil
    @ObservationIgnored private var hashCacheLoaded = false
    @ObservationIgnored private var duplicateTask: Task<Void, Never>?
    /// Bumped by every start/stop: a stopped search that is still finishing never writes its result.
    @ObservationIgnored private var duplicateRun = 0
    /// Injected by tests.
    @ObservationIgnored var findDuplicateFiles: @Sendable ([URL], [DuplicateFinder.Key: Data], @escaping @Sendable (Double) -> Void) async throws -> DuplicateFinder.Result = {
        try await DuplicateFinder.find($0, cache: $1, progress: $2)
    }
    /// Files and folders checked so far by the running scan (the total is unknown up front).
    var scannedCount = 0
    /// Entries the last finished scan of the same scope checked; 0 = unknown (first scan).
    var estimatedCount = 0
    /// Determinate progress of the running scan, or nil when there is no estimate.
    var scanFraction: Double? { Self.fraction(checked: scannedCount, estimate: estimatedCount) }
    /// The last scan left out folders macOS protects (no Full Disk Access): the view shows a note.
    var skippedProtected = false
    /// The home folder; tests and snapshots set a fake one.
    @ObservationIgnored var home = SafetyPolicy.current.homeURL
    /// Folder scanned; nil = the whole home folder.
    private(set) var scope: URL?
    /// Scope of the files shown: a cancelled scan puts `scope` back to it, so a label never names other files.
    @ObservationIgnored private var scannedScope: URL?
    /// The scope is a folder macOS protects and there is no Full Disk Access: nothing was scanned.
    var needsAccess = false
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
        if let folder, !LargeFileScanner.allowsRoot(folder, home: home) { return false }
        if case .trashing = phase { return true }
        if undoing { return true }
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
              LargeFileScanner.allowsRoot(url, home: home),
              !excluded.map({ Self.folder($0).path.lowercased() }).contains(where: { lower == $0 || lower.hasPrefix($0 + "/") }),
              !ProtectedFolders.contains(ProtectedFolders.skipped(home: home, hasFullDiskAccess: hasFullDiskAccess()), url),
              url != Self.folder(home.path)
        else { return }
        scope = url
    }
    /// "Undo"; tests pass their own so the real Trash is never touched.
    @ObservationIgnored var restore: ([TrashedItem]) async -> TrashUndo.Result = { await TrashUndo.restore($0, module: "Large & Old Files") }
    /// Injectable for tests.
    /// Saves exclusions ("Never Clean This"); tests inject a throwaway defaults domain.
    @ObservationIgnored var exclude: ([URL]) -> [URL] = { Preferences.exclude($0) }
    @ObservationIgnored var hasFullDiskAccess: () -> Bool = { FullDiskAccess.isGranted }
    /// Injected by tests (e.g. a slow scan); args: root, minimum size, skipped folders, progress.
    @ObservationIgnored var scanFiles: @Sendable (URL, Int64, Set<String>, @escaping @Sendable (Int) -> Void) async throws -> [LargeFile] = {
        try await LargeFileScanner.scan(root: $0, minSize: $1, skipping: $2, progress: $3)
    }
    /// Injected by tests so the real Trash is never touched.
    @ObservationIgnored var trashFiles: ([LargeFile]) async -> CleanReport = { await LargeFileScanner.trash($0) }
    /// The window's, set by the view: ⌘Z after a move to the Trash.
    @ObservationIgnored weak var undoManager: UndoManager?
    /// "Undo" is putting files back: a scan now could miss them.
    private(set) var undoing = false
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    /// Bumped by every scan: an older scan that is still finishing never writes over a newer one.
    @ObservationIgnored private var generation = 0
    /// What a cancelled scan restores; kept from before the first of back-to-back scans, never `.scanning`.
    @ObservationIgnored private var beforeScan = Phase.idle

    var visibleFiles: [LargeFile] { files(of: kind) }

    /// Files passing the size, age and search filters, of `kind` (nil = all kinds).
    func files(of kind: FileKind?) -> [LargeFile] {
        let cutoff = minAgeMonths == 0 ? nil : Calendar.current.date(byAdding: .month, value: -minAgeMonths, to: .now)
        let search = search.trimmingCharacters(in: .whitespaces)
        return files.filter {
            $0.matches(minSize: minSize, unusedSince: cutoff) && (kind == nil || $0.kind == kind)
                && (search.isEmpty || $0.name.localizedStandardContains(search) || $0.location.localizedStandardContains(search))
                && (!duplicatesOnly || duplicateIndex[$0.url] != nil)
        }
    }

    /// Copies in the file's duplicate group (2+), nil when it has none or duplicates are not found yet.
    func duplicateCount(of url: URL) -> Int? {
        duplicateIndex[url].map { duplicateGroups?[$0].count ?? 0 }
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

    /// `files` (already in the table's sort order) with each duplicate group kept together, groups in order of their first file.
    func groupedByDuplicates(_ files: [LargeFile]) -> [LargeFile] {
        var order: [Int] = []
        var groups: [Int: [LargeFile]] = [:]
        for file in files {
            let group = duplicateIndex[file.url] ?? -1
            if groups[group] == nil { order.append(group) }
            groups[group, default: []].append(file)
        }
        return order.flatMap { groups[$0] ?? [] }
    }

    /// Hashes same-size files once per scan; nothing is ticked. Turning the filter off stops it (found again next time).
    private func findDuplicates() {
        guard duplicateGroups == nil, duplicateTask == nil else { return }
        duplicateRun += 1
        let urls = files.map(\.url)
        let (find, current, cacheURL) = (findDuplicateFiles, duplicateRun, hashCacheURL)
        duplicateProgress = 0
        duplicateTask = Task {
            if !hashCacheLoaded, let cacheURL {
                hashCacheLoaded = true
                duplicateHashes.merge(await DuplicateFinder.HashCache.load(from: cacheURL)) { current, _ in current }
            }
            var result: DuplicateFinder.Result?
            do {
                result = try await find(urls, duplicateHashes) { fraction in
                    Task { @MainActor in if current == self.duplicateRun, self.duplicateTask != nil { self.duplicateProgress = fraction } }
                }
            } catch let cancelled as DuplicateFinder.Cancelled { // keep hashes finished before the stop
                duplicateHashes.merge(cancelled.hashes) { current, _ in current }
                if let cacheURL { await DuplicateFinder.HashCache.save(duplicateHashes, to: cacheURL) }
            } catch {}
            if let result, let cacheURL { await DuplicateFinder.HashCache.save(result.hashes, to: cacheURL) }
            guard current == duplicateRun else { return } // stopped, or a newer search owns the state now
            duplicateProgress = nil
            duplicateTask = nil
            guard let result else { return }
            duplicateHashes = result.hashes
            duplicateGroups = result.groups
        }
    }

    private func stopFindingDuplicates() {
        duplicateRun += 1
        duplicateTask?.cancel()
        duplicateTask = nil
        duplicateProgress = nil
    }

    /// Only ticked files that the current filters still show are trashed.
    var checkedFiles: [LargeFile] { visibleFiles.filter { checked.contains($0.url) } }
    var checkedSize: Int64 { checkedFiles.reduce(0) { $0 + $1.size } }
    /// Every shown file is ticked (false when nothing is shown): the bottom bar's button reads "Deselect All".
    var allVisibleChecked: Bool {
        let visible = visibleFiles
        return !visible.isEmpty && visible.allSatisfy { checked.contains($0.url) }
    }

    /// Select All/Deselect All: only the shown files; ticks on files a filter hides stay as they are.
    func setVisibleChecked(_ on: Bool) {
        let urls = visibleFiles.map(\.url)
        if on { checked.formUnion(urls) } else { checked.subtract(urls) }
    }

    /// The copy each duplicate group keeps: oldest modification date (the original), tie → shortest path.
    /// Counted over the whole group, so a copy hidden by search/kind/age can be the kept one.
    var keptCopies: Set<URL> { Set(keptCopyByGroup.compactMap(\.self)) }

    /// Kept copy of each group in `duplicateGroups`, same order.
    private var keptCopyByGroup: [URL?] {
        let byURL = Dictionary(files.map { ($0.url, $0) }) { a, _ in a }
        return (duplicateGroups ?? []).map { group in
            group.compactMap { byURL[$0] }.min { ($0.modified, $0.url.path.count) < ($1.modified, $1.url.path.count) }?.url
        }
    }

    /// Select Extra Copies: ticks every shown duplicate except the kept copy of its group, and unticks kept
    /// copies: one ticked earlier, maybe hidden by a filter then, would leave no copy once shown again.
    func checkExtraCopies() {
        let keep = keptCopies
        checked.formUnion(visibleFiles.map(\.url).filter { duplicateIndex[$0] != nil && !keep.contains($0) })
        checked.subtract(keep)
    }

    /// Names of duplicate groups whose every copy would go to the Trash: the confirmation warns before nothing is left.
    /// Also with the Duplicates filter off once groups are known: Select All ticks every copy just the same.
    var groupsLosingEveryCopy: [String] {
        guard let groups = duplicateGroups else { return [] }
        let trashed = Set(checkedFiles.map(\.url))
        return zip(groups, keptCopyByGroup).filter { $0.0.allSatisfy(trashed.contains) }
            .compactMap { ($0.1 ?? $0.0.first)?.lastPathComponent }
    }

    /// "Never Clean This": `urls` join Settings › Exclusions and leave the list; false when none could.
    func neverClean(_ urls: Set<URL>) -> Bool {
        let gone = Set(exclude(Array(urls)))
        guard !gone.isEmpty else { return false }
        files.removeAll { gone.contains($0.url) }
        checked.subtract(gone)
        if duplicateGroups != nil { duplicateGroups = duplicateGroups?.map { $0.filter { !gone.contains($0) } }.filter { $0.count > 1 } }
        return true
    }

    /// `checked / estimate`, capped at 99% until the scan finishes (this run may check more than the last one).
    static func fraction(checked: Int, estimate: Int) -> Double? {
        estimate > 0 ? min(Double(checked) / Double(estimate), 0.99) : nil
    }

    /// Ignored while trashing (the listing would show files that are about to go) or undoing (it would miss files coming back).
    func scan() {
        if case .trashing = phase { return }
        if undoing { return }
        undoManager?.removeAllActions(withTarget: self)
        scanTask?.cancel()
        generation += 1
        let current = generation
        if case .scanning = phase {} else { beforeScan = phase }
        phase = .scanning
        scannedCount = 0
        let root = scope ?? home
        let threshold = scope == nil ? Self.sizeOptions[0] : min(minSize, Self.sizeOptions[0])
        let skipping = ProtectedFolders.skipped(home: home, hasFullDiskAccess: hasFullDiskAccess())
        stopFindingDuplicates()
        // Listing a protected folder without Full Disk Access would make macOS prompt: ask for access instead.
        if ProtectedFolders.contains(skipping, root) {
            needsAccess = true
            scannedScope = scope
            files = []
            checked = []
            duplicateGroups = nil
            skippedProtected = false
            phase = .results
            return
        }
        // Same folder and same Full Disk Access state → roughly the same number of entries as last time.
        let scopeKey = "\(root.path)|\(skipping.isEmpty ? "full" : "limited")"
        estimatedCount = (Preferences.dictionary(Preferences.largeFilesLastCount) as [String: Int])[scopeKey] ?? 0
        let scanFiles = scanFiles
        scanTask = Task {
            do {
                let found = try await scanFiles(root, threshold, skipping) { count in
                    // Parallel walk: reports may land out of order.
                    Task { @MainActor in if current == self.generation { self.scannedCount = max(self.scannedCount, count) } }
                }
                guard current == generation else { return } // a newer scan owns the state now
                try Task.checkCancellation()
                files = found.sorted { $0.size > $1.size }
                scannedMinSize = threshold
                scannedScope = scope
                needsAccess = false
                skippedProtected = !skipping.isEmpty
                checked = []
                duplicateGroups = nil
                if duplicatesOnly { findDuplicates() }
                // shortcut: progress arrives every 500 entries, so this undercounts by < 500; fine for an estimate.
                Preferences.update(Preferences.largeFilesLastCount) { (counts: inout [String: Int]) in counts[scopeKey] = scannedCount }
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
                if duplicatesOnly { findDuplicates() } // stopped when the scan started
            }
        }
    }

    func cancel() { scanTask?.cancel() }

    /// Only from results: not twice, nor after a new scan started behind the dialog (⌘R).
    func trash() async {
        guard case .results = phase else { return }
        let selection = checkedFiles
        phase = .trashing
        stopFindingDuplicates() // its result would bring back groups of trashed files
        let report = await trashFiles(selection)
        files = []
        checked = []
        duplicateGroups = nil
        phase = .done(report)
        if !report.trashed.isEmpty {
            undoManager?.registerTrashUndo(self, name: String(localized: "Move to Trash")) { await $0.undoTrash() }
        }
        Attention.finished()
    }

    /// "Undo" on the done screen: puts the files just trashed back. Once only; the list stays empty (scan again).
    func undoTrash() async {
        guard case .done(var report) = phase, report.undo == nil, !report.trashed.isEmpty else { return }
        undoManager?.removeAllActions(withTarget: self) // the button ran it, or ⌘Z did
        let items = report.trashed
        report.trashed = []
        phase = .done(report)
        undoing = true
        let result = await restore(items)
        undoing = false
        guard case .done = phase else { return } // a new scan started meanwhile
        report.undo = result
        phase = .done(report)
    }
}

extension LargeFilesModel: TrashUndoing {}
