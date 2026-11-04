import Combine
import Foundation

/// Duplicates › Duplicate Files in Large & Old Files: searches the scan's scope on its own (`DuplicateScanner`, down
/// to the Size menu's `minSize`), lists groups of identical files with the copy suggested to keep first, and moves
/// the ticked ones to the Trash. Nothing is ticked for the user. Stop while comparing keeps the groups found so far.
final class DuplicatesModel: ObservableObject {
    enum Phase { case idle, listing, comparing, results, trashing, done(CleanReport) }

    @Published var phase = Phase.idle
    @Published var groups: [DuplicateScanner.Group] = []
    /// Ticked for the Trash. Never pre-filled.
    @Published var checked: Set<URL> = []
    /// Toolbar search: file name or location; "" = no search.
    @Published var search = ""
    /// The Size menu; another size searches the same place again.
    @Published var minSize = DuplicateScanner.defaultMinSize {
        didSet { if minSize != oldValue, last != nil { findAgain() } }
    }
    /// Entries checked so far while listing.
    @Published private(set) var listed = 0
    /// Bytes compared so far, of the bytes of every file with a same-size twin, while comparing.
    @Published private(set) var progress = DuplicateFinder.Progress(done: 0, total: 0)
    /// Stop was clicked while comparing: the search ends after the chunk under way and shows what it found.
    @Published private(set) var stopping = false
    /// The last search was stopped while comparing: `groups` holds what it found until then.
    @Published private(set) var stopped = false
    /// Why the last search failed (not a Stop): shown with Try Again.
    @Published private(set) var error: String?
    /// "Undo" is putting files back.
    @Published private(set) var undoing = false
    /// Stop was clicked while moving to the Trash: the move ends after the file under way.
    @Published private(set) var stoppingTrash = false
    private var trashRun: TrashRun?
    /// What the last move frees once the Trash is emptied: nothing for a hard link, only its own blocks for an APFS
    /// clone (`report.freed` is the files' sizes).
    private(set) var lastFreed: Int64 = 0
    /// The window's, set by the view: ⌘Z after a move to the Trash.
    weak var undoManager: UndoManager?
    /// Called with the files just moved to the Trash or excluded, so Large & Old Files drops them from its list.
    var onTrashed: ([URL]) -> Void = { _ in }

    /// Injected by tests: root, minimum size, policy, skipped folders, cached hashes, progress.
    var findDuplicates: @Sendable (URL, Int64, SafetyPolicy, Set<String>, [DuplicateFinder.Key: Data],
                                   @escaping @Sendable (DuplicateScanner.Progress) -> Void) async throws -> DuplicateScanner.Result = {
        try await DuplicateScanner.scan(root: $0, minSize: $1, policy: $2, skipping: $3, cache: $4, progress: $5)
    }
    /// Injected by tests so the real Trash is never touched.
    var trashFiles: ([LargeFile], SafetyPolicy) async -> CleanReport = { await LargeFileScanner.trash($0, policy: $1) }
    var restore: ([TrashedItem]) async -> TrashUndo.Result = { await TrashUndo.restore($0, module: "Large & Old Files") }
    /// Saves exclusions ("Never Clean This"); tests inject their own.
    var exclude: ([URL]) -> [URL] = { Preferences.exclude($0) }
    /// Where hashes persist across launches; nil = memory only. Never the real cache under a test host.
    var cacheURL: URL? =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil ? DuplicateFinder.HashCache.defaultURL : nil

    /// Hashes by (path, size, inode, modification date): a new search only reads files that are new or changed.
    private var hashes: [DuplicateFinder.Key: Data] = [:]
    private var cacheLoaded = false
    private var task: Task<Void, Never>?
    /// Bumped by every new search and reset: an older search still finishing never writes its result.
    private var run = 0
    /// What the last search looked at, for Find Again and the Size menu.
    private var last: (root: URL, policy: SafetyPolicy, skipping: Set<String>)?

    var isSearching: Bool {
        switch phase {
        case .listing, .comparing: true
        default: false
        }
    }

    /// Moving to the Trash or putting back: quitting now would stop it partway.
    var isChanging: Bool {
        if case .trashing = phase { return true }
        return undoing
    }

    /// Searches `root` for duplicates of at least `minSize`. Ignored while trashing or undoing.
    func find(in root: URL, policy: SafetyPolicy, skipping: Set<String>) {
        guard !isChanging else { return }
        cancelSearch()
        last = (root, policy, skipping)
        groups = []
        checked = []
        (listed, progress, stopping, stopped, error) = (0, .init(done: 0, total: 0), false, false, nil)
        phase = .listing
        let current = run
        let (find, cacheURL, minSize) = (findDuplicates, cacheURL, minSize)
        let shown = Locked(ContinuousClock.now - .seconds(1))
        let due = { @Sendable in Self.due(shown) }
        task = Task {
            if !cacheLoaded, let cacheURL {
                cacheLoaded = true
                hashes.merge(await DuplicateFinder.HashCache.load(from: cacheURL)) { current, _ in current }
            }
            guard current == run else { return }
            do {
                let result = try await find(root, minSize, policy, skipping, hashes) { step in
                    switch step {
                    case .listing(let count):
                        guard due() else { return }
                        Task { @MainActor in if current == self.run { self.listed = max(self.listed, count) } }
                    case .comparing(let compared):
                        // The first report (nothing compared yet) switches to comparing; the last one always shows.
                        guard compared.done == 0 || compared.done == compared.total || due() else { return }
                        Task { @MainActor in
                            guard current == self.run, self.isSearching else { return }
                            self.phase = .comparing
                            if compared.done >= self.progress.done || compared.total != self.progress.total { self.progress = compared }
                        }
                    }
                }
                hashes = result.hashes
                if let cacheURL { await DuplicateFinder.HashCache.save(result.hashes, to: cacheURL) }
                guard current == run else { return }
                groups = result.groups
                stopped = result.stopped
                stopping = false
                phase = .results
                task = nil
                if !result.stopped { Attention.finished() }
            } catch {
                guard current == run else { return }
                stopping = false
                task = nil
                if !(error is CancellationError) { self.error = error.localizedDescription }
                phase = .idle
            }
        }
    }

    /// At most one progress update per `LargeFilesModel.progressInterval` (~10 redraws a second).
    nonisolated private static func due(_ shown: Locked<ContinuousClock.Instant>) -> Bool {
        shown.withLock { last in
            guard ContinuousClock.now - last >= LargeFilesModel.progressInterval else { return false }
            last = .now
            return true
        }
    }

    /// Searches the same place again (Find Again, Try Again, another size).
    func findAgain() {
        guard let last else { return }
        find(in: last.root, policy: last.policy, skipping: last.skipping)
    }

    /// Stop (or ⌘.): while listing, back to idle; while comparing, the groups found so far are shown (`stopped`).
    func stop() {
        guard isSearching, !stopping else { return }
        if case .listing = phase {
            cancelSearch()
            phase = .idle
            return
        }
        stopping = true
        task?.cancel()
    }

    private func cancelSearch() {
        run += 1
        task?.cancel()
        task = nil
        stopping = false
    }

    /// Back to nothing found (a new Large & Old Files scan, or leaving Duplicate Files). Ignored while changing files.
    func reset() {
        guard !isChanging else { return }
        cancelSearch()
        undoManager?.removeAllActions(withTarget: self)
        groups = []
        checked = []
        (stopped, error) = (false, nil)
        phase = .idle
    }

    var fileCount: Int { groups.reduce(0) { $0 + $1.files.count } }

    /// Groups with a file whose name or location matches the search, each whole: the suggested copy stays in view
    /// next to the ones found.
    var shownGroups: [DuplicateScanner.Group] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return groups }
        return groups.filter { group in
            group.files.contains { $0.name.localizedStandardContains(query) || $0.location.localizedStandardContains(query) }
        }
    }

    /// Ticked files of the shown groups: what Move to Trash takes. A tick in a group the search hides stays, unused.
    var checkedFiles: [LargeFile] { shownGroups.flatMap(\.files).filter { checked.contains($0.url) } }

    /// What moving the ticked files frees: nothing for a hard link, only its own blocks for an APFS clone.
    var checkedSize: Int64 {
        shownGroups.reduce(0) { total, group in
            total + group.files.filter { checked.contains($0.url) }.reduce(0) { $0 + group.freed($1) }
        }
    }

    /// Select All but Suggested and ⌘A: ticks every copy but the suggested one of each shown group, and not a copy
    /// that frees nothing or less than its size (a hard link, an APFS clone); unticks the suggested ones.
    func checkAllButSuggested() {
        for group in shownGroups {
            checked.formUnion(group.files.dropFirst().filter { group.freed($0) == $0.size }.map(\.url))
            checked.remove(group.suggested.url)
        }
    }

    /// Deselect All and ⇧⌘A: unticks the shown groups.
    func uncheckAll() { checked.subtract(shownGroups.flatMap { $0.files.map(\.url) }) }

    /// Names of the shown groups whose every copy is ticked (their suggested copy's): the confirmation warns.
    var groupsLosingEveryCopy: [String] {
        shownGroups.filter { $0.files.allSatisfy { checked.contains($0.url) } }.map(\.suggested.name)
    }

    /// "Never Clean This": `urls` join Settings › Exclusions and leave the groups; false when none could.
    func neverClean(_ urls: Set<URL>) -> Bool {
        let gone = Set(exclude(Array(urls)))
        guard !gone.isEmpty else { return false }
        drop(gone)
        onTrashed(Array(gone))
        return true
    }

    /// Files gone from disk or from the list (here, in the file list or by Similar Photos) leave their groups.
    func drop(_ gone: Set<URL>) {
        guard !gone.isEmpty else { return }
        groups = DuplicateScanner.sorted(groups.compactMap { $0.removing(gone) })
        checked.subtract(gone)
    }

    /// Only from results: not twice.
    func trash() async {
        guard case .results = phase, let policy = last?.policy else { return }
        let selection = checkedFiles
        guard !selection.isEmpty else { return }
        phase = .trashing
        let run = TrashRun()
        trashRun = run
        let trashFiles = trashFiles
        let report = await TrashRun.$current.withValue(run) { await trashFiles(selection, policy) }
        trashRun = nil
        stoppingTrash = false
        let gone = Set(report.trashed.map(\.original))
        lastFreed = groups.reduce(0) { total, group in
            total + group.files.filter { gone.contains($0.url) }.reduce(0) { $0 + group.freed($1) }
        }
        drop(gone)
        checked = []
        phase = .done(report)
        onTrashed(Array(gone))
        if !report.trashed.isEmpty {
            undoManager?.registerTrashUndo(self, name: String(localized: "Move to Trash")) { await $0.undoTrash() }
        }
        Attention.finished()
    }

    /// Stop (or ⌘.) while moving to the Trash: the file under way finishes, the others stay; the done screen says
    /// how many were left.
    func stopTrash() {
        guard case .trashing = phase, let trashRun, !stoppingTrash else { return }
        trashRun.stop()
        stoppingTrash = true
    }

    /// "Undo" on the done screen: puts the files just trashed back. Once only; Find Again lists them again.
    func undoTrash() async {
        guard case .done(var report) = phase, report.undo == nil, !report.trashed.isEmpty else { return }
        undoManager?.removeAllActions(withTarget: self)
        let items = report.trashed
        report.trashed = []
        phase = .done(report)
        undoing = true
        let result = await restore(items)
        undoing = false
        guard case .done = phase else { return }
        report.undo = result
        phase = .done(report)
    }
}

extension DuplicatesModel: TrashUndoing {}
