import Foundation
import Combine

/// Space Lens: children of the current folder with their sizes, measured in parallel and remembered for the session.
final class SpaceLensModel: ObservableObject {
    typealias Volume = DiskVolume

    /// Injectable for tests: folders inside it open with the full breadcrumb from it.
    var home = SafetyPolicy.current.homeURL
    /// Mount point of the external drive holding a folder (`SafetyPolicy.externalVolume`): folders on it open with the
    /// breadcrumb from the drive. Injectable for tests, which can't mount a drive.
    var externalVolume: (URL) -> URL? = { url in
        SafetyPolicy.current.externalVolume(SafetyPolicy.normalize(url)).map { URL(fileURLWithPath: $0) }
    }
    /// Root of the startup disk: a folder outside home and off external drives opens with the breadcrumb from it.
    /// Injectable for tests.
    var disk = URL(fileURLWithPath: "/")
    /// Paths volumes are mounted on, "/" left out: never measured inside a folder. Injectable for tests.
    var mountPoints: () -> Set<String> = { SpaceLens.mountPoints(SafetyPolicy.mountPoints()) }
    /// Where browsing started (home, a drive, the startup disk or a chosen folder); `path` holds the folders opened below it.
    @Published private(set) var root = SafetyPolicy.current.homeURL
    @Published private(set) var path: [URL] = []
    @Published private(set) var items: [SpaceItem] = []
    @Published private(set) var measuring = false
    @Published private(set) var trashing = false
    /// `trashing` is an undo: the bottom bar says "Putting back…".
    @Published private(set) var undoing = false
    /// Stop was clicked while moving to the Trash: the move ends after the item under way.
    @Published private(set) var stoppingTrash = false
    /// The move to the Trash under way, for Stop.
    private var trashRun: TrashRun?
    /// "Show Hidden Files": off leaves hidden items out of the table and the donut's own slices, but in the total.
    /// The view keeps the setting.
    @Published var showsHidden = true
    /// Toolbar search over the current folder's names; "" = all. Cleared when the folder changes.
    @Published var search = ""
    /// Item to select in the table once listed, set by `reveal`; the view clears it.
    @Published var revealed: URL?
    @Published var volume = Volume() // settable so UISnapshots can pin it (the real disk's free space changes between runs)
    /// Cleared (another folder or root) also drops its ⌘Z.
    @Published var report: CleanReport? { didSet { if report == nil { undoManager?.removeAllActions(withTarget: self) } } }
    /// The window's, set by the view: ⌘Z after a move to the Trash.
    weak var undoManager: UndoManager?
    /// The current listing left out folders macOS protects (no Full Disk Access): the view shows a note.
    @Published private(set) var skippedProtected = false
    /// The folder shown can't be read (macOS refused): its empty list is not an empty folder.
    @Published private(set) var unreadable = false
    /// Injectable for tests.
    var hasFullDiskAccess: () -> Bool = { FullDiskAccess.isGranted }
    /// "Undo"; tests pass their own so the real Trash is never touched.
    var restore: ([TrashedItem]) async -> TrashUndo.Result = { await TrashUndo.restore($0, module: "Space Lens") }
    /// Saves exclusions ("Never Clean This"); tests inject a throwaway defaults domain.
    var exclude: ([URL]) -> [URL] = { Preferences.exclude($0) }
    /// Injectable for tests, so they never move real files to the Trash.
    var trashItems: ([SpaceItem]) async -> CleanReport = { await SpaceLens.trash($0) }
    /// Injectable for tests, to count how often folders are measured.
    var measure: @Sendable (URL, SpaceLens.HardLinks, Set<String>) async throws -> (size: Int64, folders: [String: Int64]) = {
        try await SpaceLens.measure($0, links: $1, skipping: $2)
    }
    /// Folders not entered by the last listing; when it changes (access granted) remembered sizes are dropped.
    private var skipping: Set<String> = []

    /// Session cache: folder path → allocated size.
    private var sizes: [String: Int64] = [:]
    /// Session cache per finished listing: folder path → its child folders' sizes, hard-linked ones included.
    /// Only valid as a whole: those sizes depend on which sibling counted a shared hard link first.
    private var listings: [String: [String: Int64]] = [:]
    private var task: Task<Void, Never>?
    private var started = false
    /// Another module removed files: remembered sizes may be wrong, measure again next time Space Lens is shown.
    private var stale = false
    /// Bumped by `invalidate`: a listing measured before another module's clean never refills the caches.
    private(set) var cacheEpoch = 0
    private var observer: (any NSObjectProtocol)?

    /// `center`: tests pass their own, so cleans recorded by tests running in parallel don't invalidate the cache.
    init(center: NotificationCenter = .default) {
        observer = center.addObserver(forName: ActivityLog.didRecord, object: nil, queue: .main) {
            [weak self] note in
            // Space Lens' own trash already updates the cache precisely.
            guard note.object as? String != "Space Lens" else { return }
            MainActor.assumeIsolated { self?.invalidate() }
        }
    }

    var current: URL { path.last ?? root }
    var breadcrumb: [URL] { [root] + path }
    /// Whole folder, search ignored: the donut and Share column keep the folder's real proportions.
    var total: Int64 { items.reduce(0) { $0 + ($1.size ?? 0) } }
    /// Items the table lists: those whose name matches `search`, hidden ones only with `showsHidden`.
    var shown: [SpaceItem] {
        let search = search.trimmingCharacters(in: .whitespaces)
        let visible = showsHidden ? items : items.filter { !$0.isHidden }
        return search.isEmpty ? visible : visible.filter { $0.name.localizedStandardContains(search) }
    }

    /// Whether `item` can be opened: a folder macOS lets CleanMate read without asking, not another volume — except
    /// an external drive, which opens as its own location (`open`).
    func canOpen(_ item: SpaceItem) -> Bool {
        item.isFolder && !item.isProtected && (!item.isMountPoint || externalVolume(item.url)?.standardizedFileURL == item.url.standardizedFileURL)
    }

    /// Title of the Move to Trash confirmation: adds up measured sizes only and says when some are not measured.
    nonisolated static func trashTitle(_ items: [SpaceItem]) -> LocalizedStringResource {
        let measured = items.compactMap(\.size)
        let bytes = measured.reduce(0, +)
        if measured.isEmpty { return "Move \(items.count) items (not measured yet) to the Trash?" }
        if measured.count < items.count { return "Move \(items.count) items (at least \(bytes, format: .fileSize)) to the Trash?" }
        return "Move \(items.count) items (\(bytes, format: .fileSize)) to the Trash?"
    }

    /// Starts at the home folder the first time the module is shown; measures again if other modules cleaned since.
    func startIfNeeded() {
        if !started {
            start(at: root)
        } else if stale {
            rescan()
        }
    }

    func invalidate() {
        sizes = [:]
        listings = [:]
        stale = true
        cacheEpoch += 1
    }

    /// Opens `item`'s folder the way "Choose Folder…" does; the view selects `item` once it is listed.
    func reveal(_ item: URL) {
        start(at: item.deletingLastPathComponent())
        revealed = item
    }

    func start(at url: URL) {
        started = true
        stale = false // load() below measures afresh: invalidate() already dropped what was remembered
        revealed = nil
        (root, path) = trail(to: url)
        report = nil
        search = ""
        loadVolume()
        load()
    }

    /// A folder inside home opens as home + each folder down to it, so the breadcrumb can go up; one on an external
    /// drive, as the drive + each folder down to it; anywhere else, as the startup disk + each folder down to it.
    /// Only the folder shown is measured, never its parents. With a locked folder (no Full Disk Access) on the way
    /// it opens alone: never list a locked parent.
    private func trail(to url: URL) -> (URL, [URL]) {
        var base = home.standardizedFileURL, target = url.standardizedFileURL
        if !target.pathComponents.starts(with: base.pathComponents) {
            if let volume = externalVolume(url) {
                (base, target) = (volume, URL(fileURLWithPath: SafetyPolicy.normalize(url)))
            } else {
                base = disk.standardizedFileURL
            }
        }
        guard target.pathComponents.starts(with: base.pathComponents) else { return (url, []) }
        var folder = base
        let path = target.pathComponents.dropFirst(base.pathComponents.count).map { folder = folder.appending(path: $0); return folder }
        let skipping = ProtectedFolders.skipped(home: home, hasFullDiskAccess: hasFullDiskAccess())
        if path.dropLast().contains(where: { skipping.contains($0.path) }) { return (url, []) }
        return (base, path)
    }

    func open(_ folder: URL) {
        // An external drive listed in /Volumes opens as the Location menu opens it: its gauge, breadcrumb and Trash.
        if let volume = externalVolume(folder), volume.standardizedFileURL == folder.standardizedFileURL {
            start(at: volume)
            return
        }
        path.append(folder)
        revealed = nil
        report = nil
        search = ""
        load()
    }

    /// Goes back to `breadcrumb[index]`.
    func go(to index: Int) {
        path = Array(path.prefix(index))
        revealed = nil
        report = nil
        search = ""
        load()
    }

    /// Forgets every remembered size and measures the current folder again.
    func rescan() {
        sizes = [:]
        listings = [:]
        stale = false
        loadVolume()
        load()
    }

    /// Stops measuring; sizes found so far stay, and the folders not measured yet say "Cancelled".
    func cancel() {
        task?.cancel()
        if measuring {
            for index in items.indices where items[index].isFolder && items[index].size == nil && items[index].failure == nil
                && !items[index].isProtected && !items[index].isMountPoint {
                items[index].failure = .cancelled
            }
        }
        measuring = false
    }

    /// Some folders of the listing shown were left unmeasured by Stop: "Measure Again" shows.
    var hasCancelled: Bool { !measuring && items.contains(where: \.isCancelled) }

    /// "Measure Again" after Stop: measures the folders left, keeping the sizes already known.
    func measureAgain() {
        guard !measuring else { return }
        if !stale { for item in items where item.isFolder { if let size = item.size { sizes[item.url.path] = size } } }
        load()
    }

    func trash(_ selection: [SpaceItem]) async {
        // The context menu stays enabled while trashing; an empty pick must not replace the real report with "Zero kB".
        // Measuring again (e.g. ⌘R behind the confirmation): the confirmed list may be stale, so nothing moves.
        guard !trashing, !measuring, !selection.isEmpty else { return }
        task?.cancel()
        trashing = true
        undoManager?.removeAllActions(withTarget: self)
        let folder = current
        let run = TrashRun()
        trashRun = run
        let trashItems = trashItems
        let result = await TrashRun.$current.withValue(run) { await trashItems(selection) }
        trashRun = nil
        stoppingTrash = false
        trashing = false
        if current == folder { // moved elsewhere meanwhile: no report about another folder
            report = result
            if !result.trashed.isEmpty {
                undoManager?.registerTrashUndo(self, name: String(localized: "Move to Trash")) { await $0.undoTrash() }
            }
        } else if !result.trashed.isEmpty {
            // The items are in the Trash all the same: Edit › Undo still puts them back, like Large Files and the
            // Uninstaller. Dropped by the next folder change, as with a report.
            let items = result.trashed
            undoManager?.registerTrashUndo(self, name: String(localized: "Move to Trash")) { await $0.undoTrash(items) }
        }
        forget(selection.map(\.url))
    }

    /// Stop (or ⌘.) while moving to the Trash: the item under way finishes, the others stay; the report says how many.
    func stopTrash() {
        guard trashing, !undoing, let trashRun, !stoppingTrash else { return }
        trashRun.stop()
        stoppingTrash = true
    }

    /// "Never Clean This": `urls` join Settings › Exclusions and stay listed (Move to Trash refuses them now);
    /// false when none could.
    func neverClean(_ urls: Set<URL>) -> Bool { !exclude(Array(urls)).isEmpty }

    /// ⌘Z for a move that finished in another folder than the one shown: no report to update.
    func undoTrash(_ items: [TrashedItem]) async {
        guard !trashing else { return }
        _ = await putBack(items)
        forget(items.map(\.original))
    }

    /// "Undo" next to the trash report: puts the items back and measures their folders again.
    func undoTrash() async {
        guard !trashing, var report, report.undo == nil, !report.trashed.isEmpty else { return }
        let items = report.trashed
        report.trashed = []
        self.report = report
        let folder = current
        report.undo = await putBack(items)
        if current == folder { self.report = report } // see trash(_:)
        forget(items.map(\.original))
    }

    private func putBack(_ items: [TrashedItem]) async -> TrashUndo.Result {
        undoManager?.removeAllActions(withTarget: self) // the button ran it, or ⌘Z did
        trashing = true // no new trash meanwhile; also shows progress
        undoing = true
        task?.cancel()
        defer { trashing = false; undoing = false }
        return await restore(items)
    }

    /// `urls` and every folder containing them changed size (trashed or put back): drop what was measured, reload.
    private func forget(_ urls: [URL]) {
        for url in urls {
            sizes = sizes.filter { !$0.key.hasPrefix(url.path + "/") && $0.key != url.path }
            listings = listings.filter { !$0.key.hasPrefix(url.path + "/") && $0.key != url.path }
            var parent = url.deletingLastPathComponent()
            while parent.path != "/" {
                sizes[parent.path] = nil
                listings[parent.path] = nil
                parent = parent.deletingLastPathComponent()
            }
        }
        loadVolume()
        load()
    }

    /// The part of `selection` still listed: after a trash or reload the table would keep URLs that are gone,
    /// and items hidden by the search must not be moved to the Trash unseen.
    func pruned(_ selection: Set<URL>) -> Set<URL> {
        selection.isEmpty ? selection : selection.intersection(shown.map(\.url))
    }

    /// Child folder sizes of `folder` measured elsewhere (the Overview's largest folders) the way `load` measures
    /// them: one `HardLinks` shared by the listing, `skipping` left out. Kept as if Space Lens had listed `folder`,
    /// so opening it or a folder inside is instant; dropped when something was cleaned since `epoch` (`cacheEpoch`).
    func remember(listing: [String: Int64], folders: [String: Int64], of folder: URL, skipping: Set<String>, epoch: Int) {
        guard epoch == cacheEpoch else { return }
        if skipping != self.skipping { sizes = [:]; listings = [:]; self.skipping = skipping }
        sizes.merge(folders) { $1 }
        listings[folder.standardizedFileURL.path] = listing
    }

    private func loadVolume() { volume = Volume.read(root) }

    private func load() {
        task?.cancel()
        let folder = current
        let skipping = ProtectedFolders.skipped(home: home, hasFullDiskAccess: hasFullDiskAccess())
        if skipping != self.skipping { sizes = [:]; listings = [:] }
        self.skipping = skipping
        skippedProtected = ProtectedFolders.skips(skipping, inside: folder)
        items = []
        unreadable = false
        measuring = true
        let listing = listings[folder.path]
        let measure = self.measure
        let epoch = cacheEpoch
        let mounts = mountPoints()
        // Walks never enter a mount point: the startup disk's data volume shares the system volume's device number,
        // so `fts`'s same-device rule alone would count it again inside /System.
        let fenced = skipping.union(mounts)
        // Outside home and off external drives every item is view-only: say why next to it.
        let base = folder.standardizedFileURL
        let locks = !base.pathComponents.starts(with: home.standardizedFileURL.pathComponents) && externalVolume(folder) == nil
        let (home, disk) = (self.home, self.disk)
        task = Task {
            let links = SpaceLens.HardLinks() // one per listing: siblings don't count a shared hard link twice
            var listed = await SpaceLens.list(folder, links: links, mounts: mounts)
            guard !Task.isCancelled else { return }
            for index in listed.indices {
                if locks { listed[index].viewOnly = SpaceLens.viewOnly(listed[index], home: home, disk: disk) }
                guard listed[index].isFolder else { continue }
                listed[index].isProtected = skipping.contains(listed[index].url.standardizedFileURL.path)
                let path = listed[index].url.path
                listed[index].size = listed[index].isMountPoint ? nil : listing?[path] ?? sizes[path]
                if listed[index].size == nil, !listed[index].isProtected, !listed[index].isMountPoint {
                    listed[index].isUnreadable = SpaceLens.isUnreadable(listed[index].url)
                }
            }
            items = listed
            if listed.isEmpty { unreadable = SpaceLens.isUnreadable(folder) }
            // Revealed item not listed (e.g. gone since): the folder stays open with nothing selected, silently.
            if let revealed, !listed.contains(where: { $0.url.standardizedFileURL == revealed.standardizedFileURL }) { self.revealed = nil }
            // firstIndex(where:) per result was O(n²) URL compares: 1.2 s for a folder of 3k subfolders.
            let indexByURL = Dictionary(listed.indices.map { (listed[$0].url, $0) }) { first, _ in first }
            typealias Measured = Result<(size: Int64, folders: [String: Int64]), SpaceLens.MeasureFailure>
            await withTaskGroup(of: (URL, Measured).self) { group in
                for item in listed where item.size == nil && !item.isProtected && !item.isMountPoint && !item.isUnreadable {
                    group.addTask {
                        do { return (item.url, .success(try await measure(item.url, links, fenced))) }
                        catch { return (item.url, .failure(SpaceLens.MeasureFailure(error, at: item.url))) }
                    }
                }
                for await (url, result) in group {
                    guard !Task.isCancelled, let index = indexByURL[url], items.indices.contains(index) else { continue }
                    switch result {
                    case .success(let measured):
                        if epoch == cacheEpoch { sizes.merge(measured.folders) { $1 } }
                        items[index].size = measured.size
                    case .failure(let failure):
                        items[index].failure = failure
                    }
                }
            }
            guard !Task.isCancelled else { return } // a cancelled listing is not remembered: its sizes are partial
            items.removeAll { $0.failure == .notFound } // gone since it was listed
            if epoch == cacheEpoch { listings[folder.path] = Dictionary(items.filter(\.isFolder).compactMap { item in item.size.map { (item.url.path, $0) } }) { $1 } }
            measuring = false
            Attention.finished()
        }
    }
}

extension SpaceLensModel: TrashUndoing {}
