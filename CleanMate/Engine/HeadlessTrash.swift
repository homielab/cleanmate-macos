import Foundation

/// What `cleanmate trash` and `cleanmate restore` do: move exactly the files and folders named to the Trash, and put
/// them back. Each path must be in the home folder and pass the Space Lens rule (`SafetyPolicy.allowsSpaceLensItem`:
/// not in ~/Library, not hidden, not inside a package, not a top-level folder of the home), Settings › Exclusions, and
/// without Full Disk Access stay out of the folders macOS protects; a symlink is refused (name what it points to).
/// The move goes through `CleanReport.trashing` (`SafeRemoval.trash`: only the item checked moves) and is logged.
/// Nothing is ever deleted. Each move, the app's too, is kept in a small record (`TrashRecords`) so `restore --list`
/// shows what CleanMate moved and `restore` puts back only that, to its old place, never over something already there.
nonisolated enum HeadlessTrash {
    /// The activity log's module for both commands.
    static let module: LocalizedStringResource = "Command Line"

    // MARK: - Reports

    struct TrashItem: Codable, Equatable, Sendable {
        /// Absolute, as given (`~` and a relative path resolved).
        var path: String
        /// Allocated bytes (a hard link counted once in a folder); nil when not found or a symlink.
        var size: Int64?
        /// "folder" or "file"; nil when not found.
        var kind: String?
        /// Where it is now in the Trash: the argument for `cleanmate restore`. nil when not moved.
        var trashed: String?
        var skipped: Bool
        var reason: String?

        enum CodingKeys: String, CodingKey { case path, size, kind, trashed, skipped, reason }

        /// Absent values are written as `null`.
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(path, forKey: .path)
            try container.encode(size, forKey: .size)
            try container.encode(kind, forKey: .kind)
            try container.encode(trashed, forKey: .trashed)
            try container.encode(skipped, forKey: .skipped)
            try container.encode(reason, forKey: .reason)
        }
    }

    struct TrashReport: Codable, Equatable, Sendable {
        var version: String
        /// Items moved to the Trash, and their bytes (still on disk until the Trash is emptied).
        var count: Int
        var size: Int64
        /// One per path, in the order given.
        var items: [TrashItem]
        /// The activity log (`~/…`).
        var log: String
    }

    struct RestoreItem: Codable, Equatable, Sendable {
        /// The Trash path given, absolute.
        var trashed: String
        /// Its old place; nil when `trash` did not move it.
        var path: String?
        var skipped: Bool
        var reason: String?

        enum CodingKeys: String, CodingKey { case trashed, path, skipped, reason }

        /// Absent values are written as `null`.
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(trashed, forKey: .trashed)
            try container.encode(path, forKey: .path)
            try container.encode(skipped, forKey: .skipped)
            try container.encode(reason, forKey: .reason)
        }
    }

    struct RestoreReport: Codable, Equatable, Sendable {
        var version: String
        /// Items put back.
        var count: Int
        var items: [RestoreItem]
        /// The activity log (`~/…`).
        var log: String
    }

    /// One item `cleanmate restore --list` shows: moved to the Trash by CleanMate and still there.
    struct ListItem: Codable, Equatable, Sendable {
        /// Where it is in the Trash: the argument for `cleanmate restore`.
        var trashed: String
        /// Its old place.
        var path: String
        /// Bytes when moved.
        var size: Int64
        /// "folder" or "file".
        var kind: String
        /// When it was moved (ISO 8601); nil for a record written before dates were kept (text shows "–").
        var date: String?
        /// What moved it: the activity log's module, like "Command Line", "Large & Old Files", "Smart Scan" or
        /// "Login Items"; "unknown" for a record written before it was kept.
        var source: String

        enum CodingKeys: String, CodingKey { case trashed, path, size, kind, date, source }

        /// Absent values are written as `null`.
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(trashed, forKey: .trashed)
            try container.encode(path, forKey: .path)
            try container.encode(size, forKey: .size)
            try container.encode(kind, forKey: .kind)
            try container.encode(date, forKey: .date)
            try container.encode(source, forKey: .source)
        }
    }

    /// `cleanmate restore --list`. `version` is the app's, like every other command's.
    struct ListReport: Codable, Equatable, Sendable {
        var version: String
        /// Items listed.
        var count: Int
        /// Newest first.
        var items: [ListItem]
    }

    /// Items listed by `restore --list` when no `--limit` is given.
    static let listLimit = 200

    // MARK: - Checks

    /// A path to move, checked: `reason` set when it is skipped.
    struct Target: Sendable {
        var url: URL
        var item: TrashItem
        var movable: Bool { !item.skipped }
    }

    static let notFound = "Not found"
    static let notRecorded = "Not moved to the Trash by CleanMate (or put back already): see `cleanmate restore --list`"
    static let symlinkReason = "A symlink: name the file or folder it points to"
    static let outsideHome = "Outside your home folder"
    static let homeReason = "Your home folder itself: name what is inside it"
    static let excludedReason = "Excluded in Settings › Exclusions"
    static let libraryReason = "In ~/Library: CleanMate never moves files from there"
    static let hiddenReason = "Hidden (like ~/.ssh): CleanMate never moves hidden files or folders"
    static let topFolderReason = "A top-level folder of your home folder: name what is inside it"
    static let protectedReason = "Protected by CleanMate's safety rules: inside an app or package, on another volume, "
        + "or not a regular file or folder"

    /// Checks each path in `arguments` (duplicates once) without moving anything, and measures the movable ones.
    static func targets(_ arguments: [String], sources: HeadlessScan.Sources) async -> [Target] {
        let policy = sources.policy()
        let home = policy.homeURL
        let skipping = HeadlessFiles.protectedFolders(home: home, hasFullDiskAccess: sources.hasFullDiskAccess())
        var seen = Set<String>()
        var targets: [Target] = []
        for argument in arguments {
            let url = HeadlessFiles.resolve(argument, home: home)
            guard seen.insert(SafetyPolicy.normalize(url).lowercased()).inserted else { continue }
            var item = TrashItem(path: url.path, size: nil, kind: nil, trashed: nil, skipped: true, reason: nil)
            item.reason = refusal(url, policy: policy, skipping: skipping)
            var info = stat()
            if lstat(url.path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK {
                let isFolder = info.st_mode & S_IFMT == S_IFDIR
                item.kind = isFolder ? "folder" : "file"
                if item.reason == nil {
                    item.size = isFolder ? (try? await SpaceLens.measure(url, skipping: skipping))?.size ?? 0
                        : Int64(info.st_blocks) * 512
                    item.skipped = false
                }
            }
            targets.append(Target(url: url, item: item))
        }
        return targets
    }

    /// Why `url` can't be moved, or nil. It must be under the home folder as written and with its folders' symlinks
    /// resolved. A folder macOS protects is refused by its path, before anything in it is read.
    static func refusal(_ url: URL, policy: SafetyPolicy, skipping: Set<String>) -> String? {
        let home = policy.homeURL
        let homes = Set([home.standardizedFileURL.path, HeadlessFiles.realPath(home.path) ?? home.path])
        let path = url.standardizedFileURL.path
        if homes.contains(path) { return homeReason }
        guard homes.contains(where: { path.hasPrefix($0 + "/") }) else { return outsideHome }
        if ProtectedFolders.contains(skipping, url) { return HeadlessScan.needsAccess }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return notFound }
        if info.st_mode & S_IFMT == S_IFLNK { return symlinkReason }
        let real = URL(fileURLWithPath: SafetyPolicy.normalize(url))
        guard let base = homes.first(where: { real.path.hasPrefix($0 + "/") }) else { return outsideHome }
        if ProtectedFolders.contains(skipping, real) { return HeadlessScan.needsAccess }
        if policy.overlapsExclusion(real) { return excludedReason }
        if inHome(real, policy: policy) && policy.allowsSpaceLensItem(real) { return nil }
        let parts = real.path.dropFirst(base.count + 1).split(separator: "/")
        if parts.first?.lowercased() == "library" { return libraryReason }
        if parts.contains(where: { $0.hasPrefix(".") }) { return hiddenReason }
        if parts.count == 1 && info.st_mode & S_IFMT == S_IFDIR { return topFolderReason }
        return protectedReason
    }

    /// `url` (its folders' symlinks resolved) is inside the home folder: never another drive, unlike Space Lens.
    static func inHome(_ url: URL, policy: SafetyPolicy) -> Bool {
        // The form `SafetyPolicy.normalize` gives (`resolvingSymlinksInPath`: /private/var → /var).
        let home = (policy.homeURL.path as NSString).resolvingSymlinksInPath
        return SafetyPolicy.normalize(url).lowercased().hasPrefix(home.lowercased() + "/")
    }

    // MARK: - trash

    /// Moves the movable `targets` to the Trash through `CleanReport.trashing`, checked again right before each move,
    /// logs each one and keeps a record of where it went for `restore` (`TrashRecords`, through `trashing`).
    static func trash(_ targets: [Target], sources: HeadlessScan.Sources) -> TrashReport {
        let policy = sources.policy()
        let home = policy.homeURL
        var report = TrashReport(version: sources.version(), count: 0, size: 0, items: [],
                                 log: HeadlessScan.displayPath(ActivityLog.url(home: home), home: home))
        let run = TrashRun.currentID // one command, one run of records
        for target in targets {
            var item = target.item
            defer { report.items.append(item) }
            guard target.movable, let size = item.size else { continue }
            // The real path: what is checked, moved and put back (a symlinked folder above it never leads elsewhere).
            let url = URL(fileURLWithPath: SafetyPolicy.normalize(target.url))
            let moved = CleanReport.trashing([(url, size)], module: module, home: home,
                                             allows: { inHome($0, policy: policy) && policy.allowsSpaceLensItem($0) },
                                             trash: sources.trash, run: run)
            item.skipped = true
            if moved.locked > 0 {
                item.reason = "Locked in Finder: unlock it in its Get Info window first"
            } else if !moved.changed.isEmpty {
                item.reason = "Changed while it was checked: nothing was moved"
            } else if !moved.failed.isEmpty {
                item.reason = "Something else reached the Trash in its place: look in the Trash"
            } else if moved.skipped > 0 {
                item.reason = "Could not move it to the Trash"
            } else {
                item.skipped = false
                report.count += 1
                report.size += size
                if let trashed = moved.trashed.first {
                    item.trashed = trashed.inTrash.path
                } else {
                    item.reason = "Moved, but macOS did not say where: put it back from the Trash in Finder"
                }
            }
        }
        return report
    }

    // MARK: - restore

    /// What CleanMate moved to the Trash (the app and the command line) and is still there, newest first, at most
    /// `limit`. Read-only: no record file is made or changed.
    static func list(limit: Int = listLimit, sources: HeadlessScan.Sources) -> ListReport {
        let items = TrashRecords.inTrash(home: sources.policy().homeURL).reversed().prefix(limit).map { record in
            var info = stat()
            let isFolder = lstat(record.trashed, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
            return ListItem(trashed: record.trashed, path: record.original, size: record.size,
                            kind: isFolder ? "folder" : "file", date: record.date, source: record.source)
        }
        return ListReport(version: sources.version(), count: items.count, items: Array(items))
    }

    /// Puts back each item CleanMate moved and `TrashRecords` knows (the app's moves too), by its path in the Trash:
    /// only when it is still the item moved, nothing is at its old place (never overwritten) and its old folder is
    /// still the same real folder (not a symlink now, same volume). Each one put back is logged "restored" under the
    /// module and item its move was logged with, and leaves the record.
    static func restore(_ arguments: [String], sources: HeadlessScan.Sources) -> RestoreReport {
        let home = sources.policy().homeURL
        var report = RestoreReport(version: sources.version(), count: 0, items: [],
                                   log: HeadlessScan.displayPath(ActivityLog.url(home: home), home: home))
        TrashRecords.update(home: home, create: false) { records in
            var seen = Set<String>()
            for argument in arguments {
                let url = HeadlessFiles.resolve(argument, home: home)
                guard seen.insert(url.path).inserted else { continue }
                var item = RestoreItem(trashed: url.path, path: nil, skipped: true, reason: nil)
                defer { report.items.append(item) }
                guard let index = records.firstIndex(where: { $0.matches(url) }) else {
                    item.reason = notRecorded
                    continue
                }
                let record = records[index]
                item.path = record.original
                let outcome = TrashRecords.putBack(record, home: home)
                item.reason = outcome.reason
                if outcome == .restored {
                    item.skipped = false
                    report.count += 1
                }
                if outcome.dropsRecord { records.remove(at: index) }
            }
        }
        return report
    }
}
