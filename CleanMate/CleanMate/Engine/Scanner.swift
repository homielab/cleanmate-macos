import Foundation

// MARK: - Scan

nonisolated struct ScanEntry: Identifiable, Hashable, Sendable {
    let url: URL
    var size: Int64
    /// The entry is a database whose records are erased (`CleanerItem.database`); `size` is then 0.
    var isDatabase = false
    /// Records to erase in that database; nil when they could not be counted.
    var records: Int? = nil
    /// Shown above the path when the item has an `entryLabel`.
    var title: String? = nil
    var date: Date? = nil
    /// A folder inside could not be read: `size` leaves it out, so the real size may be larger.
    var partlyUnreadable = false
    var id: URL { url }
}

nonisolated struct ItemScan: Sendable {
    var entries: [ScanEntry] = []
    /// A folder could not be read (e.g. ~/.Trash without Full Disk Access).
    var permissionDenied = false
    /// Size reported by a `SizeProbe` (no entries then).
    var measuredSize: Int64? = nil
    var size: Int64 { measuredSize ?? entries.reduce(0) { $0 + $1.size } }
    /// Records counted in database entries; nil when the item has none.
    var records: Int? {
        let databases = entries.filter(\.isDatabase)
        return databases.isEmpty ? nil : databases.compactMap(\.records).reduce(0, +)
    }
    /// A command-only item whose data can't be measured (e.g. the QuickLook cache, private to the system).
    var unmeasured = false
    /// Something to clean: bytes, a database with records to erase, or an unmeasurable command.
    var hasData: Bool { size > 0 || unmeasured || entries.contains(where: \.isDatabase) }
    /// Some entry has a folder that could not be read: `size` may be smaller than the real size.
    var partlyUnreadable: Bool { entries.contains(where: \.partlyUnreadable) }
}

nonisolated enum Scanner {
    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .contentModificationDateKey, .isVolumeKey,
        .fileResourceTypeKey,
    ]

    /// Modification date for age checks. A socket or pipe may belong to a running process however old its date
    /// (VS Code's git socket, an ssh-agent in $TMPDIR), so it never counts as old and its folder is kept.
    /// shortcut: a stale socket of a dead process is kept too; check its owner with lsof if that ever matters.
    private static func modified(_ values: URLResourceValues) -> Date {
        if values.fileResourceType == .socket || values.fileResourceType == .namedPipe { return .distantFuture }
        return values.contentModificationDate ?? .distantFuture
    }

    /// Every folder `item` lists: its globbed `paths`, `shellFolders`, `configFolders` and `locate`, nested ones
    /// dropped. Shared by the scan and the cleaner's open-file and `excluded` checks, so they cover the same folders.
    static func roots(for item: CleanerItem, policy: SafetyPolicy) async -> [URL] {
        // Deduplicated: a `*` can match a folder also listed on its own (`Chrome/*` and `Chrome/Network`).
        var seen = Set<String>()
        var roots = item.paths.flatMap(policy.roots).filter { seen.insert($0.standardizedFileURL.path).inserted }
            .filter { !policy.rootThroughSymlink($0) }
        func within(_ a: String, _ b: String) -> Bool { a == b || a.hasPrefix(b + "/") }
        // A root inside another root is listed by it already (`Claude/*/GPUCache` with `*` = `GPUPersistentCache`,
        // next to `Claude/GPUPersistentCache`): keeping both would count and remove the same files twice.
        // Not with a name filter (`included`, probe): there the outer root lists only some of its children.
        if item.included == nil, item.probe == nil {
            // Ancestor lookup in a set, not root × root: a Chromium app has ~1000 globbed roots (was ~1–4 s).
            let paths = Set(roots.map(\.standardizedFileURL.path))
            roots = roots.filter { root in
                var path = root.standardizedFileURL.path
                while let slash = path.lastIndex(of: "/"), slash > path.startIndex {
                    path = String(path[..<slash])
                    if paths.contains(path) { return false }
                }
                return true
            }
        }
        func below(_ base: URL, _ subpaths: [String]) -> [URL] {
            subpaths.flatMap { policy.roots($0.isEmpty ? base.path : base.path + "/" + $0) }.filter { !policy.rootThroughSymlink($0) }
        }
        var extra = item.shellFolders.sorted { $0.key < $1.key }.flatMap { name, subpaths -> [URL] in
            ShellEnvironment.folder(name, policy: policy).map { below($0, subpaths) } ?? []
        }
        if let config = item.configFolders {
            extra += config.read(policy.homeURL).compactMap { ShellEnvironment.checkedFolder($0, policy: policy) }
                .flatMap { below($0, config.subpaths) }
        }
        if let located = await item.locate?.root(policy: policy) { extra.append(located) }
        for located in extra.map(\.standardizedFileURL.path) {
            // Nested folders count once (`pnpm store path` → `…/store/v10`, under the default `…/store`).
            if !roots.contains(where: { within(located, $0.standardizedFileURL.path) }) {
                roots.removeAll { within($0.standardizedFileURL.path, located) }
                roots.append(URL(fileURLWithPath: located))
            }
        }
        return roots
    }

    /// Lists what `item` would remove, largest first. Never follows symlinks; unreadable files are skipped.
    /// When the task is cancelled it stops early and returns a partial result: callers must discard it.
    /// `openPaths` reads the open-file table under a folder (`skipsOpenFiles`), like `Cleaner.clean`'s.
    @concurrent static func scan(_ item: CleanerItem, policy: SafetyPolicy = .current, now: Date = .now,
                                 openPaths: @Sendable (String) -> Set<String> = { RunningProcesses.openPaths(under: $0) }) async -> ItemScan {
        if item.externalTrash { return await ExternalTrash.scan(item, policy: policy, openPaths: openPaths) }
        var result = ItemScan()
        let cutoff = item.minAge.map { now.addingTimeInterval(-$0) }
        let roots = await Self.roots(for: item, policy: policy)
        var only: Set<String>? = nil
        if item.paths.isEmpty, item.probe == nil, let command = item.command {
            result.unmeasured = command.resolvedPath != nil
            return result
        }
        if let probe = item.probe {
            // Don't even run e.g. xcrun when its data folder is absent (it may prompt to install tools).
            guard roots.isEmpty || roots.contains(where: { FileManager.default.fileExists(atPath: $0.path) }),
                  probe.precondition(),
                  let output = await probe.output(),
                  let parsed = probe.parse(output)
            else { return result }
            switch parsed {
            case .bytes(let bytes):
                result.measuredSize = bytes
                if let details = probe.details {
                    // The probe's own command again (`brew autoremove --dry-run`): its output is reused, not run twice.
                    let same = details.command.executable == probe.command.executable
                        && details.command.arguments == probe.command.arguments
                    let listed: String?
                    if same { listed = output } else { listed = await details.command.output() }
                    if let listed { result.entries = details.parse(listed).sorted { $0.size > $1.size } }
                }
                return result
            case .only(let names): only = names
            }
        }
        let skips = item.skipsEntry?()
        if let find = item.findEntries {
            let found = find(roots, policy).filter { url in
                (item.allowsEntry?(policy, url) ?? policy.allows(url)) && skips?(url) != true && !isLocked(url)
            }
            // One open-file read under the home folder, only when something was found (it lists every process).
            let open = item.skipsOpenFiles && !found.isEmpty ? openPaths(policy.homeURL.path) : []
            // One level deeper in parallel: pnpm keeps every package under one `.pnpm` folder (~100 k files).
            return await measure(found.filter { !RunningProcesses.holdsOpenFile($0, openPaths: open) }, of: item,
                                 into: result, policy: policy, cutoff: cutoff, split: 1)
        }
        let open = item.skipsOpenFiles ? RunningProcesses.openPaths(under: roots, read: openPaths) : []
        func listed(_ urls: [URL], under prefix: String) -> [URL] {
            urls.flatMap { url -> [URL] in
                let name = prefix + url.lastPathComponent
                let holdsExclusion = item.excluded.contains(where: { $0.hasPrefix(name + "/") })
                // Changed after the cutoff: `entry` drops it anyway, so skip the costlier checks below (
                // ~19 k `$TMPDIR` children, mostly new, took 3 s). Values were read with the listing.
                if let cutoff, item.database == nil, !holdsExclusion,
                   let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileResourceTypeKey]),
                   modified(values) >= cutoff { return [] }
                guard !item.excluded.contains(name), policy.allows(url), skips?(url) != true, !isLocked(url),
                      open.isEmpty || !RunningProcesses.holdsOpenFile(url, openPaths: open) else { return [] }
                if prefix.isEmpty, only?.contains(name) == false
                    || item.included?.contains(where: { fnmatch($0, name, 0) == 0 }) == false { return [] }
                guard holdsExclusion else { return [url] }
                // Holds a nested exclusion: list its children instead (a symlink or file is skipped whole).
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true,
                      let inner = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)
                else { return [] }
                return listed(inner, under: name + "/")
            }
        }
        // Every root listed first, then all their entries measured at once: a Chromium app has ~900 globbed roots of a
        // few entries each, measured one root after another before.
        var candidates: [URL] = []
        for root in roots where !Task.isCancelled {
            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys)
            } catch CocoaError.fileReadNoPermission {
                result.permissionDenied = true
                continue
            } catch {
                continue // missing folder
            }
            candidates += listed(children, under: "")
        }
        // An item filtered by its probe starts walking only once the tool answered, ~1–3 s into a Smart Scan whose other
        // walks fill the thread pool: one thread per entry left a simulator's 66 k-file `data` as the scan's tail.
        return await measure(candidates, of: item, into: result, policy: policy, cutoff: cutoff,
                             split: only != nil ? splitDepth : 0)
    }

    /// `result` with `candidates` measured at once (or their database records counted), labelled, largest first.
    private static func measure(_ candidates: [URL], of item: CleanerItem, into result: ItemScan, policy: SafetyPolicy,
                                cutoff: Date?, split: Int) async -> ItemScan {
        var result = result
        result.entries = await withTaskGroup(of: ScanEntry?.self) { group in
            for url in candidates {
                group.addTask {
                    if Task.isCancelled { return nil } // no walk or sqlite3 run for what the caller discards
                    guard let database = item.database, database.applies(to: url) else {
                        guard var found = await entry(at: url, olderThan: cutoff, splitDepth: split) else { return nil }
                        if let files = item.entryFiles?(url) {
                            found.size += files.filter(policy.allows).reduce(0) { $0 + fileSize($1) }
                        }
                        return found
                    }
                    return await records(in: url, database)
                }
            }
            var all: [ScanEntry] = []
            for await found in group { if let found { all.append(found) } }
            return all
        }
        if let label = item.entryLabel {
            for i in result.entries.indices {
                let found = label(result.entries[i].url)
                result.entries[i].title = found?.title
                result.entries[i].date = found?.date
            }
        }
        result.entries.sort { $0.size > $1.size }
        return result
    }

    /// Allocated bytes of a regular file (not through a symlink); 0 for anything else or a missing file.
    static func fileSize(_ url: URL) -> Int64 {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return 0 }
        return Int64(info.st_blocks) * 512
    }

    /// Locked (Finder "Locked", `uchg`) or SIP-protected (`sunlnk`/restricted, e.g. the daemons' `$TMPDIR/com.apple.*`
    /// folders): removing it can only fail, so it is never listed.
    static func isLocked(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE | SF_NOUNLINK | SF_RESTRICTED) != 0
    }

    /// A database entry with its record count; nil when it is not a file or has nothing to erase.
    private static func records(in url: URL, _ database: DatabaseErase) async -> ScanEntry? {
        // An empty file (Chrome leaves 0-byte History in some profiles) holds no records: nothing to list.
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { return nil }
        let run = { (sql: String) async -> String? in
            if let output = await ShellCommand(executable: DatabaseErase.sqlite, arguments: ["-readonly", url.path, sql],
                                               timeout: .seconds(10)).output() { return output }
            // A WAL database (Firefox's places.sqlite) can't be opened read-only once its -shm file is gone.
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return await ShellCommand(executable: DatabaseErase.sqlite, arguments: [url.path, sql], timeout: .seconds(10)).output()
        }
        var sql: String? = database.count
        if sql == "" {
            sql = await run(DatabaseErase.tableQuery).map {
                "SELECT 0" + database.matching($0).map { " + (SELECT count(*) FROM \($0))" }.joined() + ";"
            }
        }
        var output: String? = nil
        if let sql { output = await run(sql) }
        let count = output.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if count == 0 { return nil }
        return ScanEntry(url: url, size: 0, isDatabase: true, records: count)
    }

    /// The entry with its allocated size, or nil when something inside changed after `cutoff` (or when cancelled).
    /// `splitDepth`: see `Scanner.splitDepth`.
    static func entry(at url: URL, olderThan cutoff: Date?, splitDepth: Int = 0) async -> ScanEntry? {
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        var size = Int64(values.totalFileAllocatedSize ?? 0)
        var newest = modified(values)
        var unreadable = false
        if values.isDirectory == true && values.isSymbolicLink != true && values.isVolume != true {
            if let cutoff, newest >= cutoff { return nil } // the folder itself changed: nothing to walk
            // Its children are walked in parallel: one huge folder (pnpm's `v11`) would otherwise be walked on a single
            // thread; `splitDepth` folder levels deep too when asked (see `splitDepth`).
            let children: [URL]
            do { children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) }
            catch { (children, unreadable) = ([], true) }
            size = 0
            guard let device = SafetyPolicy.deviceID(url.path) else { return nil }
            let links = SpaceLens.HardLinks() // one per entry: a file linked twice inside it counts once, like `du -s`
            let trees = await withTaskGroup(of: (Int64, Date, Bool)?.self) { group in
                for child in children {
                    group.addTask {
                        guard cutoff == nil else { return tree(child, dates: true, device: device, links: links, stopAt: cutoff) }
                        return await undatedTree(child.path, device: device, links: links, depth: splitDepth)
                    }
                }
                var trees: [(Int64, Date, Bool)?] = []
                for await tree in group {
                    trees.append(tree)
                    // One newer child already keeps the whole entry: stop walking the others.
                    if let cutoff, let date = tree?.1, date >= cutoff { group.cancelAll(); break }
                }
                return trees
            }
            for tree in trees {
                guard let (bytes, date, skipped) = tree else { return nil } // cancelled
                size += bytes
                newest = max(newest, date)
                unreadable = unreadable || skipped
            }
        }
        if Task.isCancelled { return nil }
        if let cutoff, newest >= cutoff { return nil }
        return ScanEntry(url: url, size: size, partlyUnreadable: unreadable)
    }

    /// Allocated bytes of `url` and everything under it, with the newest modification date when `dates`
    /// (else `.distantPast`), and whether a folder inside could not be read (counted 0). nil when cancelled.
    /// Another volume mounted inside (a device other than `device`, the scanned entry's) counts 0 and is not walked.
    /// Symlinks count themselves, never their target.
    /// Walked with fts (one lstat per file) rather than URL resource values: st_blocks × 512 and st_mtimespec
    /// are the values `totalFileAllocatedSize` and `contentModificationDate` report (checked by `treeMatchesResourceValues`).
    /// A file with several hard links counts once per `links` (shared by the walks of one entry), like `du`.
    /// With `stopAt`, the walk stops at the first item modified at or after it (or a socket/pipe) and returns that
    /// partial size with `.distantFuture`: the entry is kept anyway.
    static func tree(_ url: URL, dates: Bool, device: dev_t, links: SpaceLens.HardLinks = .init(), stopAt: Date? = nil) -> (Int64, Date, Bool)? {
        guard let stream = url.path.withCString({ path -> UnsafeMutablePointer<FTS>? in
            var paths: [UnsafeMutablePointer<CChar>?] = [UnsafeMutablePointer(mutating: path), nil]
            return fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil)
        }) else { return (0, .distantPast, false) }
        defer { fts_close(stream) }
        var size: Int64 = 0
        var newest: timespec? = nil
        var socketOrPipe = false
        var unreadable = false
        let stop = stopAt?.timeIntervalSinceReferenceDate
        var count = 0
        while let entry = fts_read(stream) {
            count += 1
            if count % 1_000 == 1, Task.isCancelled { return nil } // from the first entry, see `SpaceLens.walk`
            switch Int32(entry.pointee.fts_info) {
            case FTS_DNR: unreadable = true
            case FTS_D, FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT: break
            default: continue // FTS_DP: counted at its FTS_D; FTS_NS, FTS_ERR, FTS_DC: unreadable, skipped
            }
            guard let info = entry.pointee.fts_statp?.pointee, info.st_dev == device else { continue }
            let type = info.st_mode & S_IFMT
            // A folder's own blocks are not counted: `totalFileAllocatedSize` is nil for folders.
            if type != S_IFDIR, links.count(info) { size += Int64(info.st_blocks) * 512 }
            guard dates else { continue }
            if type == S_IFSOCK || type == S_IFIFO { socketOrPipe = true } // see `modified`
            let time = info.st_mtimespec
            if let stop, socketOrPipe || referenceDateSeconds(time) >= stop { return (size, .distantFuture, unreadable) }
            if newest.map({ (time.tv_sec, time.tv_nsec) > ($0.tv_sec, $0.tv_nsec) }) ?? true { newest = time }
        }
        if socketOrPipe { return (size, .distantFuture, unreadable) }
        let date = newest.map { Date(timeIntervalSinceReferenceDate: referenceDateSeconds($0)) }
        return (size, date ?? .distantPast, unreadable)
    }

    /// Folder levels of an entry's child read in parallel before each deeper folder gets one `tree` walk, for the
    /// Uninstaller's sizes (one 230 k-file folder in an app's Application Support took 3.5 s on one thread).
    /// In a scan only for items filtered by a probe (they start late): thousands of entries already keep every
    /// core busy, and splitting all of them made a Smart Scan ~1.5× slower.
    static let splitDepth = 3

    /// `tree(path, dates: false)`, with folders `depth` levels down walked in parallel; same sizes and unreadable flag.
    /// Anything `tree` treats specially at its root (not a folder, another volume, unreadable) goes to `tree` as is.
    static func undatedTree(_ path: String, device: dev_t, links: SpaceLens.HardLinks, depth: Int,
                            root: Bool = true) async -> (Int64, Date, Bool)? {
        var info = stat()
        guard depth > 0, lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_dev == device,
              let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            // Below the root, `tree` (FTS_XDEV) neither counts nor enters a folder on another volume.
            if !root, lstat(path, &info) == 0, info.st_dev != device { return (0, .distantPast, false) }
            return tree(URL(fileURLWithPath: path), dates: false, device: device, links: links)
        }
        if Task.isCancelled { return nil }
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return await withTaskGroup(of: (Int64, Date, Bool)?.self) { group in
            var size: Int64 = 0
            var unreadable = false
            for name in names {
                let child = prefix + name
                var childInfo = stat()
                guard lstat(child, &childInfo) == 0 else { continue } // FTS_NS: skipped
                if childInfo.st_mode & S_IFMT == S_IFDIR {
                    group.addTask { await undatedTree(child, device: device, links: links, depth: depth - 1, root: false) }
                } else if childInfo.st_dev == device, links.count(childInfo) {
                    size += Int64(childInfo.st_blocks) * 512
                }
            }
            for await sub in group {
                guard let sub else { group.cancelAll(); return nil }
                size += sub.0
                unreadable = unreadable || sub.2
            }
            return (size, .distantPast, unreadable)
        }
    }

    /// Foundation's own conversion, so dates equal `contentModificationDate` to the last bit.
    private static func referenceDateSeconds(_ time: timespec) -> TimeInterval {
        (Double(time.tv_sec) - 978_307_200) + 1.0e-9 * Double(time.tv_nsec)
    }
}
