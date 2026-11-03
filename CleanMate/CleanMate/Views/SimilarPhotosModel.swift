import Combine
import Foundation

/// Duplicates › Similar Photos in Large & Old Files: lists the photos in the scan's scope, groups those that look
/// alike, and moves the ticked ones to the Trash. Nothing is ticked for the user.
final class SimilarPhotosModel: ObservableObject {
    enum Phase { case idle, listing, analyzing, results, trashing, done(CleanReport) }

    @Published var phase = Phase.idle
    @Published var groups: [SimilarPhotos.Group] = []
    /// Sort By in the toolbar.
    @Published var order = SimilarPhotos.GroupOrder.space
    /// Ticked for the Trash. Never pre-filled.
    @Published var checked: Set<URL> = []
    /// Toolbar search: photo name or location; "" = no search.
    @Published var search = ""
    /// Image files checked so far while listing.
    @Published private(set) var listed = 0
    /// Photos analyzed (or answered from the cache) and their total while analyzing.
    @Published private(set) var analyzed = 0
    @Published private(set) var total = 0
    /// "Undo" is putting photos back.
    @Published private(set) var undoing = false
    /// The window's, set by the view: ⌘Z after a move to the Trash.
    weak var undoManager: UndoManager?
    /// Called with the photos just moved to the Trash, so Large & Old Files drops them from its list.
    var onTrashed: ([URL]) -> Void = { _ in }

    /// Injected by tests: root, policy, skipped folders, progress.
    var listPhotos: @Sendable (URL, SafetyPolicy, Set<String>, @escaping @Sendable (Int) -> Void) async throws -> [LargeFile] = {
        try await SimilarPhotos.photos(in: $0, policy: $1, skipping: $2, progress: $3)
    }
    var findSimilar: @Sendable ([LargeFile], [DuplicateFinder.Key: SimilarPhotos.Print],
                                @escaping @Sendable (Int, Int) -> Void) async throws -> SimilarPhotos.Result = {
        try await SimilarPhotos.find($0, cache: $1, progress: $2)
    }
    /// Injected by tests so the real Trash is never touched.
    var trashPhotos: ([SimilarPhotos.Photo], SafetyPolicy) async -> CleanReport = { await SimilarPhotos.trash($0, policy: $1) }
    var restore: ([TrashedItem]) async -> TrashUndo.Result = { await TrashUndo.restore($0, module: SimilarPhotos.module) }
    /// Where prints persist across launches; nil = memory only. Never the real cache under a test host.
    var cacheURL: URL? =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil ? SimilarPhotos.Cache.defaultURL : nil

    private var prints: [DuplicateFinder.Key: SimilarPhotos.Print] = [:]
    private var cacheLoaded = false
    private var task: Task<Void, Never>?
    /// Bumped by every start/stop: a stopped search still finishing never writes its result.
    private var run = 0
    /// What the last search looked at, for Find Again.
    private var last: (root: URL, policy: SafetyPolicy, skipping: Set<String>)?

    var isSearching: Bool {
        switch phase {
        case .listing, .analyzing: true
        default: false
        }
    }

    /// Moving to the Trash or putting back: quitting now would stop it partway.
    var isChanging: Bool {
        if case .trashing = phase { return true }
        return undoing
    }

    /// Lists and groups the photos under `root`. Ignored while trashing or undoing.
    func find(in root: URL, policy: SafetyPolicy, skipping: Set<String>) {
        guard !isChanging else { return }
        stop()
        last = (root, policy, skipping)
        groups = []
        checked = []
        listed = 0
        (analyzed, total) = (0, 0)
        phase = .listing
        let current = run
        let (list, find, cacheURL) = (listPhotos, findSimilar, cacheURL)
        let shown = Locked(ContinuousClock.now - .seconds(1))
        let due = { @Sendable in Self.due(shown) }
        task = Task {
            do {
                let files = try await list(root, policy, skipping) { count in
                    guard due() else { return }
                    Task { @MainActor in if current == self.run { self.listed = max(self.listed, count) } }
                }
                guard current == run else { return }
                phase = .analyzing
                total = files.count
                if !cacheLoaded, let cacheURL {
                    cacheLoaded = true
                    prints.merge(await SimilarPhotos.Cache.load(from: cacheURL)) { current, _ in current }
                }
                let result: SimilarPhotos.Result
                do {
                    result = try await find(files, prints) { done, total in
                        guard done == total || due() else { return }
                        Task { @MainActor in if current == self.run { (self.analyzed, self.total) = (done, total) } }
                    }
                } catch let cancelled as SimilarPhotos.Cancelled { // keep prints finished before the stop
                    prints.merge(cancelled.prints) { _, new in new }
                    if let cacheURL { await SimilarPhotos.Cache.save(prints, to: cacheURL) }
                    throw CancellationError()
                }
                prints = result.prints
                if let cacheURL { await SimilarPhotos.Cache.save(result.prints, to: cacheURL) }
                guard current == run else { return }
                groups = result.groups
                phase = .results
                task = nil
                Attention.finished()
            } catch {
                guard current == run else { return }
                phase = .idle
                task = nil
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

    /// Searches the same place again.
    func findAgain() {
        guard let last else { return }
        find(in: last.root, policy: last.policy, skipping: last.skipping)
    }

    /// Stops a running search (back to idle); results and done screens stay.
    func stop() {
        run += 1
        task?.cancel()
        task = nil
        if isSearching { phase = .idle }
    }

    /// Back to nothing found (a new Large & Old Files scan, or leaving Similar Photos). Ignored while changing files.
    func reset() {
        guard !isChanging else { return }
        stop()
        undoManager?.removeAllActions(withTarget: self)
        groups = []
        checked = []
        phase = .idle
    }

    var photoCount: Int { groups.reduce(0) { $0 + $1.photos.count } }

    /// `groups` in the chosen `order`, as listed.
    var sortedGroups: [SimilarPhotos.Group] { order.sorted(groups) }

    /// `sortedGroups` with a photo whose name or location matches the search, each whole: the suggested photo stays
    /// in view next to the ones found.
    var shownGroups: [SimilarPhotos.Group] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return sortedGroups }
        return sortedGroups.filter { group in
            group.photos.contains { $0.name.localizedStandardContains(query) || $0.location.localizedStandardContains(query) }
        }
    }

    /// Ticked photos of the shown groups: what Move to Trash takes. A tick in a group the search hides stays, unused.
    var checkedPhotos: [SimilarPhotos.Photo] { shownGroups.flatMap(\.photos).filter { checked.contains($0.url) } }
    var checkedSize: Int64 { checkedPhotos.reduce(0) { $0 + $1.size } }

    /// Select All but Suggested and ⌘A: ticks every photo but the suggested one of each shown group.
    func checkAllButSuggested() {
        for group in shownGroups {
            checked.formUnion(group.photos.map(\.url))
            checked.remove(group.suggested.url)
        }
    }

    /// Deselect All and ⇧⌘A: unticks the shown groups.
    func uncheckAll() { checked.subtract(shownGroups.flatMap { $0.photos.map(\.url) }) }

    /// Names of the shown groups whose every photo is ticked (their suggested photo's): the confirmation warns.
    var groupsLosingEveryPhoto: [String] {
        shownGroups.filter { $0.photos.allSatisfy { checked.contains($0.url) } }.map(\.suggested.name)
    }

    /// Only from results: not twice.
    func trash() async {
        guard case .results = phase, let policy = last?.policy else { return }
        let selection = checkedPhotos
        guard !selection.isEmpty else { return }
        phase = .trashing
        let report = await trashPhotos(selection, policy)
        let gone = Set(report.trashed.map(\.original))
        groups = groups.map { SimilarPhotos.Group(photos: $0.photos.filter { !gone.contains($0.url) }) }.filter { $0.photos.count >= 2 }
        checked = []
        phase = .done(report)
        onTrashed(Array(gone))
        if !report.trashed.isEmpty {
            undoManager?.registerTrashUndo(self, name: String(localized: "Move to Trash")) { await $0.undoTrash() }
        }
        Attention.finished()
    }

    /// "Undo" on the done screen: puts the photos just trashed back. Once only; Find Again shows them again.
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

extension SimilarPhotosModel: TrashUndoing {}
