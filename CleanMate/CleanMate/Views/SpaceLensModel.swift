import Foundation
import Combine

/// Space Lens: children of the current folder with their sizes, measured in parallel and remembered for the session.
final class SpaceLensModel: ObservableObject {
    nonisolated struct Volume: Equatable, Sendable {
        var name = ""
        var total: Int64 = 0
        var available: Int64 = 0
        var used: Int64 { max(total - available, 0) }
        /// Reads the volume holding `url` (also used by the menu bar item and the Overview). Free space for important
        /// use, as Finder shows; plain free space on a volume that has no such figure.
        static func read(_ url: URL) -> Volume {
            let values = try? url.resourceValues(forKeys: [
                .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey])
            return Volume(name: values?.volumeName ?? "", total: Int64(values?.volumeTotalCapacity ?? 0),
                          available: values?.volumeAvailableCapacityForImportantUsage
                              ?? values?.volumeAvailableCapacity.map(Int64.init) ?? 0)
        }
        /// Free-space warning level: orange under 10% free, red under 5%.
        enum Level { case normal, low, critical }
        var level: Level {
            guard total > 0 else { return .normal }
            let free = Double(available) / Double(total)
            return free < 0.05 ? .critical : free < 0.10 ? .low : .normal
        }
    }

    /// Injectable for tests: folders inside it open with the full breadcrumb from it.
    var home = SafetyPolicy.current.homeURL
    /// Mount point of the external drive holding a folder (`SafetyPolicy.externalVolume`): folders on it open with the
    /// breadcrumb from the drive. Injectable for tests, which can't mount a drive.
    var externalVolume: (URL) -> URL? = { url in
        SafetyPolicy.current.externalVolume(SafetyPolicy.normalize(url)).map { URL(fileURLWithPath: $0) }
    }
    /// Where browsing started (home, a volume or a chosen folder); `path` holds the folders opened below it.
    @Published private(set) var root = SafetyPolicy.current.homeURL
    @Published private(set) var path: [URL] = []
    @Published private(set) var items: [SpaceItem] = []
    @Published private(set) var measuring = false
    @Published private(set) var trashing = false
    /// `trashing` is an undo: the bottom bar says "Putting back…".
    @Published private(set) var undoing = false
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
    /// Items the table lists: those whose name matches `search`.
    var shown: [SpaceItem] {
        let search = search.trimmingCharacters(in: .whitespaces)
        return search.isEmpty ? items : items.filter { $0.name.localizedStandardContains(search) }
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
    /// drive, as the drive + each folder down to it. Elsewhere, or with a locked folder (no Full Disk Access) on the
    /// way, it opens alone as before: never list a locked parent, and climbing to a disk root would measure system
    /// folders the user did not ask for.
    private func trail(to url: URL) -> (URL, [URL]) {
        var base = home.standardizedFileURL, target = url.standardizedFileURL
        if !target.pathComponents.starts(with: base.pathComponents), let volume = externalVolume(url) {
            (base, target) = (volume, URL(fileURLWithPath: SafetyPolicy.normalize(url)))
        }
        guard target.pathComponents.starts(with: base.pathComponents) else { return (url, []) }
        var folder = base
        let path = target.pathComponents.dropFirst(base.pathComponents.count).map { folder = folder.appending(path: $0); return folder }
        let skipping = ProtectedFolders.skipped(home: home, hasFullDiskAccess: hasFullDiskAccess())
        if path.dropLast().contains(where: { skipping.contains($0.path) }) { return (url, []) }
        return (base, path)
    }

    func open(_ folder: URL) {
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

    /// Stops measuring; sizes found so far stay.
    func cancel() {
        task?.cancel()
        measuring = false
    }

    func trash(_ selection: [SpaceItem]) async {
        // The context menu stays enabled while trashing; an empty pick must not replace the real report with "Zero kB".
        // Measuring again (e.g. ⌘R behind the confirmation): the confirmed list may be stale, so nothing moves.
        guard !trashing, !measuring, !selection.isEmpty else { return }
        task?.cancel()
        trashing = true
        undoManager?.removeAllActions(withTarget: self)
        let folder = current
        let result = await trashItems(selection)
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
        measuring = true
        let listing = listings[folder.path]
        let measure = self.measure
        let epoch = cacheEpoch
        task = Task {
            let links = SpaceLens.HardLinks() // one per listing: siblings don't count a shared hard link twice
            var listed = await SpaceLens.list(folder, links: links)
            guard !Task.isCancelled else { return }
            for index in listed.indices where listed[index].isFolder {
                listed[index].isProtected = skipping.contains(listed[index].url.standardizedFileURL.path)
                let path = listed[index].url.path
                listed[index].size = listing?[path] ?? sizes[path]
            }
            items = listed
            // Revealed item not listed (e.g. gone since): the folder stays open with nothing selected, silently.
            if let revealed, !listed.contains(where: { $0.url.standardizedFileURL == revealed.standardizedFileURL }) { self.revealed = nil }
            // firstIndex(where:) per result was O(n²) URL compares: 1.2 s for a folder of 3k subfolders.
            let indexByURL = Dictionary(listed.indices.map { (listed[$0].url, $0) }) { first, _ in first }
            await withTaskGroup(of: (URL, Int64, [String: Int64])?.self) { group in
                for item in listed where item.size == nil && !item.isProtected {
                    group.addTask {
                        guard let result = try? await measure(item.url, links, skipping)
                        else { return nil }
                        return (item.url, result.size, result.folders)
                    }
                }
                for await result in group {
                    guard let (url, size, folders) = result, !Task.isCancelled else { continue }
                    if epoch == cacheEpoch { sizes.merge(folders) { $1 } }
                    if let index = indexByURL[url], items.indices.contains(index) { items[index].size = size }
                }
            }
            guard !Task.isCancelled else { return } // a cancelled listing is not remembered: its sizes are partial
            if epoch == cacheEpoch { listings[folder.path] = Dictionary(items.filter(\.isFolder).compactMap { item in item.size.map { (item.url.path, $0) } }) { $1 } }
            measuring = false
            Attention.finished()
        }
    }
}

extension SpaceLensModel: TrashUndoing {}
