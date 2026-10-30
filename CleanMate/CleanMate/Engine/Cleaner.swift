import Foundation

extension FormatStyle where Self == ByteCountFormatStyle {
    /// File sizes in the UI. "0 bytes" instead of the spelled-out "Zero kB". In `Text` (`Text(x, format:)` or
    /// `"\(x, format: .fileSize)"`) SwiftUI applies the environment locale; elsewhere pass `.locale(locale)`.
    nonisolated static var fileSize: Self { .byteCount(style: .file, spellsOutZero: false) }
}

// MARK: - Clean

nonisolated struct CleanReport: Sendable {
    /// Bytes of what was removed or moved to the Trash, measured by the scan (a command item: its scan size minus
    /// a rescan right after). Never the volume's free-space change, which other processes and APFS make noisy.
    var freed: Int64 = 0
    /// Part of `freed` from items whose size is an upper bound (files shared with projects as APFS clones or hard
    /// links, pnpm prune): the space really freed may be smaller.
    var upTo: Int64 = 0
    /// Entries or items not removed (in use, not permitted, refused by the safety policy, command failed).
    var skipped = 0
    /// Not moved because locked in Finder (`Scanner.isLocked`): reported apart from `skipped` so the user knows why.
    var locked = 0
    /// What went to the Trash and where it landed, for "Undo". Only `trashing` and the uninstaller fill it;
    /// Smart Scan doesn't (most of it is deleted outright).
    var trashed: [TrashedItem] = []
    /// Set once "Undo" ran; `trashed` is emptied at the same time so it can't run twice.
    var undo: TrashUndo.Result?

    static func += (lhs: inout CleanReport, rhs: CleanReport) {
        lhs.freed += rhs.freed
        lhs.upTo += rhs.upTo
        lhs.skipped += rhs.skipped
        lhs.locked += rhs.locked
        lhs.trashed += rhs.trashed
    }

    /// `FileManager.trashItem`, returning where the item now is inside the Trash.
    static let moveToTrash: @Sendable (URL) throws -> URL? = { url in
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }

    /// Moves each item to the Trash (never deletes) if `allows` it right before, logging each one moved.
    /// `trash` is injectable so tests use a fake Trash folder.
    static func trashing(_ items: [(url: URL, size: Int64)], module: LocalizedStringResource, home: URL,
                         allows: (URL) -> Bool, trash: (URL) throws -> URL? = moveToTrash) -> CleanReport {
        var report = CleanReport()
        for (url, size) in items {
            guard allows(url) else { report.skipped += 1; continue }
            // A folder that only contains a locked file still moves; the locked item itself can't.
            if Scanner.isLocked(url) { report.locked += 1; continue }
            do {
                let inTrash = try trash(url)
                report.freed += size
                if let inTrash { report.trashed.append(TrashedItem(original: url, inTrash: inTrash, size: size)) }
                ActivityLog.record(module: module, item: url.path, size: size, mode: .trash, home: home)
            } catch {
                report.skipped += 1
            }
        }
        return report
    }
}

/// One item moved to the Trash: where it was and where it is now.
nonisolated struct TrashedItem: Sendable, Equatable {
    let original: URL
    let inTrash: URL
    let size: Int64
    /// The old folder with symlinks resolved, read when moved: "Undo" refuses a folder that now leads elsewhere.
    let folder: String
    /// Volume of `folder` when moved: "Undo" refuses a folder now on another volume (a drive mounted there since).
    let volume: dev_t?

    init(original: URL, inTrash: URL, size: Int64) {
        self.original = original
        self.inTrash = inTrash
        self.size = size
        folder = TrashUndo.resolved(original.deletingLastPathComponent())
        volume = SafetyPolicy.deviceID(folder)
    }
}

/// Puts back the last move to the Trash of a module. In memory only: gone when CleanMate quits.
nonisolated enum TrashUndo {
    struct Result: Sendable, Equatable {
        var restored = 0
        /// Not put back: gone from the Trash, something already at the old place, its folder gone, or the move failed.
        var skipped = 0
    }

    /// Moves each item from the Trash back to its old place, only when the Trash copy still exists, nothing is at
    /// the old place (never overwrites) and the old folder is still there, still resolving to the same place (not
    /// swapped for a symlink since) on the same volume (no drive mounted on it or above it since;
    /// `device` is injected by tests). The safety policy is not asked again: the old place is where the module's
    /// own policy allowed the item to be taken from a moment ago. Each one put back is logged as
    /// "restored", which `ActivityLog.freed` takes off the trashed total. `logName` is the log's item column: the path,
    /// or the name the move was logged under (Smart Scan logs one line per catalog item, not per file).
    @concurrent static func restore(_ items: [TrashedItem], module: LocalizedStringResource,
                                    home: URL = SafetyPolicy.current.homeURL,
                                    logName: @Sendable (URL) -> String = { $0.path },
                                    device: SafetyPolicy.DeviceID = SafetyPolicy.deviceID) async -> Result {
        var result = Result()
        for item in items {
            var info = stat()
            var isFolder: ObjCBool = false
            guard lstat(item.inTrash.path, &info) == 0, lstat(item.original.path, &info) != 0, errno == ENOENT,
                  FileManager.default.fileExists(atPath: item.original.deletingLastPathComponent().path, isDirectory: &isFolder),
                  isFolder.boolValue, resolved(item.original.deletingLastPathComponent()) == item.folder,
                  device(item.folder) == item.volume
            else { result.skipped += 1; continue }
            do {
                // moveItem never replaces an existing item, so a file appearing meanwhile is not overwritten.
                try FileManager.default.moveItem(at: item.inTrash, to: item.original)
                result.restored += 1
                ActivityLog.recordRestored(module: module, item: logName(item.original), size: item.size, home: home)
            } catch {
                result.skipped += 1
            }
        }
        return result
    }

    static func resolved(_ folder: URL) -> String { (folder.path as NSString).resolvingSymlinksInPath }
}

nonisolated enum Cleaner {
    /// Removes what `scan` found for `item`. Every path is re-checked against `policy` right before removal, and
    /// against `minAge` (nothing inside modified since the cutoff, measured again now).
    /// `trash` moves a `.trash` entry to the Trash and returns where it went (`report.trashed`, for Undo); tests pass
    /// a fake one so the real Trash is never touched.
    /// `openPaths` lists open files under a folder (`skipsOpenFiles`): Smart Scan passes one table shared by the items
    /// of a clean, read when it starts (never the scan's) and again every `OpenFiles.cleanMaxAge`.
    @concurrent static func clean(_ item: CleanerItem, scan: ItemScan, policy: SafetyPolicy = .current,
                                  trash: @Sendable (URL) throws -> URL? = CleanReport.moveToTrash,
                                  openPaths: OpenPaths = OpenFiles.reader(maxAge: OpenFiles.cleanMaxAge)
    ) async -> CleanReport {
        var report = await remove(item, scan: scan, policy: policy, trash: trash, openPaths: openPaths)
        if item.sizeIsUpperBound { report.upTo = report.freed }
        return report
    }

    /// The item runs an installed tool whose folder overlaps Settings › Exclusions, so it is never cleaned: the tool
    /// removes what it likes in its folder, ignoring exclusions. Checked by the scan too, to lock the row.
    /// Raw roots and printed folder: refused ones are still the tool's.
    static func blockedByExclusion(_ item: CleanerItem, policy: SafetyPolicy = .current) async -> Bool {
        guard item.command?.resolvedPath != nil, !policy.excluded.isEmpty else { return false }
        let located = await item.locate?.printed()
        return (item.paths.flatMap(policy.roots) + [located].compactMap { $0 }).contains(where: policy.overlapsExclusion)
    }

    /// Free bytes on the volume holding `path` (statfs, not URL resource values: those are cached per URL).
    /// Shown before and after a clean for reference only; never used for what was freed.
    static func freeSpace(_ path: String) -> Int64? {
        var info = statfs()
        return statfs(path, &info) == 0 ? Int64(info.f_bavail) * Int64(info.f_bsize) : nil
    }

    private static func remove(_ item: CleanerItem, scan: ItemScan, policy: SafetyPolicy,
                               trash: @Sendable (URL) throws -> URL?,
                               openPaths: OpenPaths) async -> CleanReport {
        if item.probe?.precondition() == false { return CleanReport(skipped: 1) } // e.g. Docker stopped since the scan
        if item.externalTrash { return await ExternalTrash.empty(item, scan: scan, policy: policy, openPaths: openPaths) }
        if let entryCommand = item.entryCommand {
            guard item.command?.resolvedPath != nil, !(await blockedByExclusion(item, policy: policy)) else {
                return CleanReport(skipped: 1)
            }
            var report = CleanReport()
            for entry in scan.entries {
                if let command = entryCommand(entry.url), await command.run() {
                    report.freed += entry.size
                } else {
                    report.skipped += 1
                }
            }
            item.probe?.forgetOutput()
            return report
        }
        if let command = item.command, command.resolvedPath != nil {
            if await blockedByExclusion(item, policy: policy) { return CleanReport(skipped: 1) }
            let ok = await command.run()
            item.probe?.forgetOutput()
            let after = await Scanner.scan(item, policy: policy)
            return CleanReport(freed: max(0, scan.size - after.size), skipped: ok ? 0 : 1)
        }
        // A command item without paths has no files of its own, and a probe-measured scan (`.bytes`) lists no files:
        // their entries (if any) are display-only, so a tool uninstalled since the scan skips the item.
        if item.command != nil && item.paths.isEmpty || scan.measuredSize != nil { return CleanReport(skipped: 1) }
        var report = CleanReport()
        // Open files: asked of `openPaths` per entry; Smart Scan's table is at most `OpenFiles.cleanMaxAge` old, not
        // read per entry (~30 ms a read: seconds for hundreds of entries). A file opened since that read may be missed,
        // like one opened just after its check; an open file is not lost when unlinked.
        // Globbed once per item (a Chromium item has ~1000 roots), only when a check below needs them; the scan's
        // own roots, so a folder from `shellFolders`/`locate` is checked like one from `paths`.
        // A `.only` probe is asked again now: a name no longer reported since the scan (a simulator made
        // available again) keeps its entry; no answer keeps them all.
        var only: Set<String>? = nil
        if let probe = item.probe {
            if case .only(let names)? = await probe.output().flatMap(probe.parse) { only = names } else { only = [] }
        }
        let roots = item.skipsOpenFiles || !item.excluded.isEmpty || only != nil ? await Scanner.roots(for: item, policy: policy) : []
        let rootPaths = roots.map(\.standardizedFileURL.path)
        for entry in scan.entries {
            let open = item.skipsOpenFiles ? await RunningProcesses.openPaths(under: roots, read: openPaths) : []
            // A fresh check per entry: an app launched since the scan (or during this loop) keeps its entry.
            // `included` and `excluded` again too: only names the item may remove, whatever the scan handed in.
            guard item.allowsEntry?(policy, entry.url) ?? policy.allows(entry.url), item.skipsEntry?()(entry.url) != true,
                  item.locksEntry?()(entry.url) == nil, !RunningProcesses.holdsOpenFile(entry.url, openPaths: open),
                  item.included?.contains(where: { fnmatch($0, entry.url.lastPathComponent, 0) == 0 }) != false,
                  !isExcluded(entry.url, excluded: item.excluded, roots: rootPaths),
                  only.map({ isListed(entry.url, names: $0, roots: rootPaths) }) != false
            else { report.skipped += 1; continue }
            // Re-checked now: something written inside since the scan keeps the entry. Before a database erase
            // too, which would otherwise wipe a database in use.
            if let minAge = item.minAge, await Scanner.entry(at: entry.url, olderThan: .now.addingTimeInterval(-minAge)) == nil {
                report.skipped += 1
                continue
            }
            if let database = item.database, database.applies(to: entry.url) {
                report += await erase(database, in: entry.url)
                continue
            }
            // Read before the entry goes (an Ollama manifest names its blobs), removed after it: a failure in
            // between leaves unused files, never an entry missing its files. Only what no entry still on disk uses:
            // a shared blob goes with the last of its models removed here, and is kept while an unticked one uses it.
            let files = item.entryFiles?(entry.url).own ?? []
            func remove(_ url: URL, size: Int64) throws {
                switch item.mode {
                case .delete: try FileManager.default.removeItem(at: url)
                case .trash:
                    if let inTrash = try trash(url) {
                        report.trashed.append(TrashedItem(original: url, inTrash: inTrash, size: size))
                    }
                }
            }
            do {
                try remove(entry.url, size: entry.size - entry.filesSize)
                report.freed += entry.size - entry.filesSize
            } catch {
                report.skipped += 1 // permission / SIP / in use: leave it
                continue
            }
            var parent = entry.url.deletingLastPathComponent()
            for _ in 0..<item.removesEmptyParents {
                guard policy.allows(parent), rmdir(parent.path) == 0 else { break }
                parent = parent.deletingLastPathComponent()
            }
            // Each file counts as it is now: one shared at scan and removed with the last of its models counts too.
            for file in files {
                var info = stat()
                guard lstat(file.path, &info) == 0 else { continue } // already gone
                let size = Int64(info.st_blocks) * 512
                guard info.st_mode & S_IFMT == S_IFREG, policy.allows(file), !Scanner.isLocked(file),
                      (try? remove(file, size: size)) != nil else {
                    report.skipped += 1 // kept, so not freed
                    continue
                }
                report.freed += size
            }
        }
        return report
    }

    /// Whether `url` is, or lies inside, a top-level child of one of `roots` named in `names`.
    static func isListed(_ url: URL, names: Set<String>, roots: [String]) -> Bool {
        let path = url.standardizedFileURL.path
        return names.contains { name in roots.contains { path == $0 + "/" + name || path.hasPrefix($0 + "/" + name + "/") } }
    }

    /// Whether `url` is one of `excluded` (a path under the shallowest of `roots` holding it, else its own name), lies
    /// inside one, or holds one: never handed in by a scan, which lists such a folder child by child.
    static func isExcluded(_ url: URL, excluded: Set<String>, roots: [String]) -> Bool {
        guard !excluded.isEmpty else { return false }
        let path = url.standardizedFileURL.path
        let relative = roots.filter { path.hasPrefix($0 + "/") }.min { $0.count < $1.count }
            .map { String(path.dropFirst($0.count + 1)) } ?? url.lastPathComponent
        var prefix = ""
        for part in relative.split(separator: "/") {
            prefix += prefix.isEmpty ? part : "/" + part
            if excluded.contains(prefix) { return true }
        }
        return excluded.contains { $0.hasPrefix(relative + "/") }
    }

    private static func erase(_ database: DatabaseErase, in url: URL) async -> CleanReport {
        // sqlite3 would create an empty database at a missing path (e.g. removed since the scan).
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return CleanReport() }
        // ...and would write through a symlink or into a hard-linked file put there since the scan.
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { return CleanReport(skipped: 1) }
        // ...and VACUUM would turn an empty file into a 4 KB database without tables.
        guard info.st_size > 0 else { return CleanReport() }
        var sql = database.erase
        if !database.tables.isEmpty {
            guard let names = await ShellCommand(executable: DatabaseErase.sqlite, arguments:
                    [url.path, DatabaseErase.tableQuery], timeout: .seconds(10)).output()
            else { return CleanReport(skipped: 1) }
            sql = "BEGIN; " + database.matching(names).map { "DELETE FROM \($0); " }.joined() + "COMMIT;"
        }
        // stat, not URL resource values: those are cached per URL, so "after" would read the "before" size.
        let size = { var now = stat(); return lstat(url.path, &now) == 0 ? Int64(now.st_blocks) * 512 : 0 }
        let before = size()
        guard await ShellCommand(executable: DatabaseErase.sqlite, arguments: ["-bail", url.path, sql],
                                 timeout: .seconds(60)).run() else { return CleanReport(freed: max(0, before - size()), skipped: 1) }
        // Records are erased; VACUUM only shrinks the file. Skipped without room for its copy, and its failure is
        // not a skip: freed then stays ~0, which is the truth.
        let free = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity ?? 0
        if Int64(free) > before {
            _ = await ShellCommand(executable: DatabaseErase.sqlite, arguments: [url.path, database.vacuum],
                                   timeout: .seconds(60)).run()
        }
        return CleanReport(freed: max(0, before - size()))
    }
}
