import CoreGraphics
import Darwin
import Foundation

// Space Lens: browse any folder by size. Sizes are allocated bytes like `du -x` (st_blocks × 512): symlinks are
// not followed, other volumes are not entered, and a hard-linked file is counted once per listing: `list` and every
// `measure` of its children share one `HardLinks`, so links between sibling folders (measured in parallel) count once,
// on whichever sibling reaches them first (like `du` given several folders).
// Folders holding a hard-linked file are never remembered for drilling in: entering one lists it afresh, so each
// child shows exactly `du -s` of it, whatever was counted first while measuring the parent.

nonisolated struct SpaceItem: Identifiable, Hashable, Sendable {
    let url: URL
    let isFolder: Bool
    /// nil while still being measured (or never, when `isProtected`).
    var size: Int64?
    /// A `ProtectedFolders` folder left unmeasured: listing its contents would make macOS ask for access.
    var isProtected = false

    var id: URL { url }
    var name: String { url.lastPathComponent }
    /// For sorting: items still being measured sort as smallest.
    var sortSize: Int64 { size ?? -1 }
}

nonisolated enum SpaceLens {
    /// Folders at least this big are remembered while measuring, so drilling into them is instant.
    static let cachedFolderMinSize: Int64 = 1_000_000

    /// One donut slice: a measured child, or "Other" (`item == nil`) for everything past the biggest `top`.
    struct Slice: Identifiable, Hashable {
        let item: SpaceItem?
        let size: Int64
        var id: String { item?.url.path ?? "" }
    }

    /// How many children the donut shows before grouping the rest into "Other".
    static let top = 8

    /// The biggest `top` measured, non-empty children by size, plus one "Other" slice summing the rest
    /// (no "Other" when only one item would go in it — that item is shown instead).
    static func slices(_ items: [SpaceItem], top: Int = SpaceLens.top) -> [Slice] {
        let measured = items.filter { ($0.size ?? 0) > 0 }.sorted { $0.size! > $1.size! }
        let shown = measured.count <= top + 1 ? measured[...] : measured.prefix(top)
        var slices = shown.map { Slice(item: $0, size: $0.size!) }
        let rest = measured.dropFirst(shown.count).reduce(Int64(0)) { $0 + $1.size! }
        if rest > 0 { slices.append(Slice(item: nil, size: rest)) }
        return slices
    }

    /// The slice under `point` in a donut drawn in `frame`: by angle clockwise from 12 o'clock (as `SectorMark`
    /// draws), only inside the ring (`innerRatio` of the radius out to the edge).
    static func slice(at point: CGPoint, in frame: CGRect, of slices: [Slice], innerRatio: Double = 0.6) -> Slice? {
        let dx = point.x - frame.midX, dy = point.y - frame.midY
        let radius = min(frame.width, frame.height) / 2
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance <= radius, distance >= radius * innerRatio else { return nil }
        var angle = atan2(dx, -dy)
        if angle < 0 { angle += 2 * .pi }
        return slice(atFraction: angle / (2 * .pi), of: slices)
    }

    /// The slice at `fraction` (0…1) of the way around the donut, or along the stacked bar drawn instead on macOS 13
    /// (left to right); nil outside 0…1.
    static func slice(atFraction fraction: Double, of slices: [Slice]) -> Slice? {
        let total = slices.reduce(0) { $0 + $1.size }
        guard total > 0, (0...1).contains(fraction) else { return nil }
        var end = 0.0
        for slice in slices {
            end += Double(slice.size) / Double(total)
            if fraction <= end { return slice }
        }
        return slices.last
    }

    /// Files with more than one hard link already counted, as (st_dev, st_ino). Shared by parallel measures.
    final class HardLinks: Sendable {
        private let seen = Locked(Set<[UInt64]>())

        /// True the first time a file is seen; always true for a file with a single link.
        func count(_ info: stat) -> Bool {
            info.st_nlink <= 1 || seen.withLock { $0.insert([UInt64(info.st_dev), info.st_ino]).inserted }
        }
    }

    /// Direct children of `folder`, hidden ones included (they take space too). Files carry their size; folders
    /// (not symlinks to folders) have nil, to be filled by `measure`. Unreadable folder → empty.
    @concurrent static func list(_ folder: URL, links: HardLinks = HardLinks()) async -> [SpaceItem] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap { name in
            let url = folder.appending(path: name)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return nil }
            let isFolder = info.st_mode & S_IFMT == S_IFDIR
            return SpaceItem(url: url, isFolder: isFolder, size: isFolder ? nil : links.count(info) ? Int64(info.st_blocks) * 512 : 0)
        }
    }

    /// Allocated size of `url` (file or whole folder tree), plus the sizes of every folder inside it of at least
    /// `cachedFolderMinSize` that holds no hard-linked file (keyed by path). Unreadable entries are skipped. Hard links already in `links` count 0.
    /// Folders whose path is in `skipping` (`ProtectedFolders.skipped`) count only their own entry. Throws `CancellationError`.
    /// `splitDepth` (tests): folder levels read in parallel; nil = `SpaceLens.splitDepth` for a big tree, 0 for a small one.
    @concurrent static func measure(_ url: URL, links: HardLinks = HardLinks(), skipping: Set<String> = [],
                                    splitDepth: Int? = nil) async throws -> (size: Int64, folders: [String: Int64]) {
        // A small tree is walked at once: split into tasks, it would queue behind the big siblings' tasks.
        let depth = splitDepth ?? (holds(url.path, moreThan: serialLimit, skipping: skipping) ? SpaceLens.splitDepth : 0)
        let result = try await measure(url.path, device: nil, depth: depth, links: links, skipping: skipping)
        return (result.size, result.folders)
    }

    /// Entries under which a measured item is walked serially (a fraction of a second).
    static let serialLimit = 10_000

    /// Whether the tree at `path` has more than `limit` entries; stats folders only, stops past `limit`, never
    /// enters `skipping` folders (macOS would ask for access) or other volumes.
    private static func holds(_ path: String, moreThan limit: Int, skipping: Set<String>) -> Bool {
        guard let stream = path.withCString({ path -> UnsafeMutablePointer<FTS>? in
            var paths: [UnsafeMutablePointer<CChar>?] = [UnsafeMutablePointer(mutating: path), nil]
            return fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV | FTS_NOSTAT, nil)
        }) else { return false }
        defer { fts_close(stream) }
        var count = 0
        while let entry = fts_read(stream) {
            count += 1
            if count > limit { return true }
            if Int32(entry.pointee.fts_info) == FTS_D, !skipping.isEmpty, skipping.contains(String(cString: entry.pointee.fts_path)) {
                fts_set(stream, entry, FTS_SKIP)
            }
        }
        return false
    }

    /// Folder levels below a measured item read in parallel; each folder past them gets one serial `walk`.
    /// One `fts` walk is bound by syscall latency (~/Developer, 1.8 M entries, took 30 s alone).
    static let splitDepth = 3

    /// `measure` of `path`, splitting its subfolders into parallel tasks for `depth` more levels. Anything `walk`
    /// treats specially (not a folder, unreadable, skipped, on another volume than `device`) goes to `walk` as is.
    /// `linked`: the tree holds a file with several hard links.
    @concurrent private static func measure(_ path: String, device: dev_t?, depth: Int, links: HardLinks,
                                            skipping: Set<String>) async throws -> (size: Int64, folders: [String: Int64], linked: Bool) {
        var info = stat()
        guard depth > 0, lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, (device ?? info.st_dev) == info.st_dev,
              !skipping.contains(path), let names = try? FileManager.default.contentsOfDirectory(atPath: path)
        else { return try walk(path, device: device, links: links, skipping: skipping) }
        try Task.checkCancellation()
        let device = info.st_dev
        let prefix = path.hasSuffix("/") ? path : path + "/" // as fts joins paths
        return try await withThrowingTaskGroup(of: (size: Int64, folders: [String: Int64], linked: Bool).self) { group in
            var size = Int64(info.st_blocks) * 512
            var folders: [String: Int64] = [:]
            var linked = false
            for name in names {
                let child = prefix + name
                var childInfo = stat()
                guard lstat(child, &childInfo) == 0 else { continue } // FTS_NS
                if childInfo.st_mode & S_IFMT == S_IFDIR {
                    group.addTask { try await measure(child, device: device, depth: depth - 1, links: links, skipping: skipping) }
                } else {
                    if childInfo.st_nlink > 1 { linked = true }
                    if links.count(childInfo) { size += Int64(childInfo.st_blocks) * 512 }
                }
            }
            for try await sub in group {
                size += sub.size
                folders.merge(sub.folders) { first, _ in first }
                linked = linked || sub.linked
            }
            // Same rule as `walk` at FTS_DP.
            if !linked, size >= cachedFolderMinSize { folders[path] = size }
            return (size, folders, linked)
        }
    }

    /// One serial `fts` walk of `path` (like `du -x`). A root folder on another volume than `device` counts only its own entry.
    private static func walk(_ path: String, device: dev_t?, links: HardLinks,
                             skipping: Set<String>) throws -> (size: Int64, folders: [String: Int64], linked: Bool) {
        guard let stream = path.withCString({ path -> UnsafeMutablePointer<FTS>? in
            var paths: [UnsafeMutablePointer<CChar>?] = [UnsafeMutablePointer(mutating: path), nil]
            return fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil)
        }) else { return (0, [:], false) }
        defer { fts_close(stream) }
        // sums[level] = bytes found so far directly in the folder being walked at that level.
        var sums: [Int64] = [0, 0]
        // linked[level]: the folder walked at that level holds a file with several hard links (see `folders` below).
        var linked = [false, false]
        var folders: [String: Int64] = [:]
        var total: Int64 = 0
        var count = 0
        while let entry = fts_read(stream) {
            count += 1
            // From the first entry: a walk under 1 000 entries (most of a split tree's) never looked before.
            if count % 1_000 == 1 { try Task.checkCancellation() }
            let level = Int(entry.pointee.fts_level)
            if sums.count < level + 2 {
                sums.append(contentsOf: repeatElement(0, count: level + 2 - sums.count))
                linked.append(contentsOf: repeatElement(false, count: level + 2 - linked.count))
            }
            let info = entry.pointee.fts_statp?.pointee
            let own = Int64(info?.st_blocks ?? 0) * 512
            var size: Int64
            switch Int32(entry.pointee.fts_info) {
            case FTS_D:
                sums[level + 1] = 0
                linked[level + 1] = false
                // fts only opens a folder on the next read; FTS_SKIP turns that read into its FTS_DP (own size only).
                if level == 0, let device, let info, info.st_dev != device {
                    fts_set(stream, entry, FTS_SKIP) // a mount point, as FTS_XDEV would treat it below a root
                } else if !skipping.isEmpty, skipping.contains(String(cString: entry.pointee.fts_path)) {
                    fts_set(stream, entry, FTS_SKIP)
                }
                continue
            case FTS_DP:
                size = own + sums[level + 1]
                // Not remembered when it holds a hard-linked file: its size here depends on which links were met
                // first in this walk (maybe outside it), and drilling in starts a new listing where they count again.
                if linked[level + 1] {
                    linked[level] = true
                } else if size >= cachedFolderMinSize {
                    folders[String(cString: entry.pointee.fts_path)] = size
                }
            case FTS_DNR:
                size = own
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                size = own
                if let info, info.st_nlink > 1 { linked[level] = true }
                if let info, !links.count(info) {
                    size = 0 // another hard link to a file already counted
                }
            default: // FTS_ERR, FTS_NS, FTS_DC: nothing readable to count
                continue
            }
            if level == 0 { total = size } else { sums[level] += size }
        }
        return (total, folders, linked[0])
    }

    /// Moves items to the Trash (never deletes), re-checking the Space Lens policy right before each one.
    @concurrent static func trash(_ items: [SpaceItem], policy: SafetyPolicy = .current) async -> CleanReport {
        CleanReport.trashing(items.map { ($0.url, $0.size ?? 0) }, module: "Space Lens", home: policy.homeURL,
                             allows: policy.allowsSpaceLensItem)
    }
}
