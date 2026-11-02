import Foundation

/// What `cleanmate space`, `cleanmate large` and `cleanmate dupes` report: Space Lens and Large & Old Files without a window, read-only.
/// Same engines, scope and rules as the app (`SpaceLens.measure`, `LargeFileScanner.scan`): sizes like `du -x` with a
/// hard link counted once, Settings › Exclusions for large files, and without Full Disk Access the folders macOS
/// protects (`ProtectedFolders`) are never entered, so no "allow access" dialog appears. Nothing is moved or deleted.
nonisolated enum HeadlessFiles {
    // MARK: - Options

    struct SpaceOptions: Equatable, Sendable {
        /// The folder to look into, as typed (`~`, relative to the current folder); nil = the home folder.
        var path: String? = nil
        /// Children listed, biggest first.
        var limit = 20
    }

    struct LargeOptions: Equatable, Sendable {
        /// `--in`: the folder to search, as typed; nil = the home folder.
        var root: String? = nil
        /// Bytes; nil = `defaultMinSize`.
        var minSize: Int64? = nil
        /// Only files not used for this many days; nil = any age.
        var olderThanDays: Int? = nil
        /// Files listed, biggest first.
        var limit = 50
    }

    struct DupesOptions: Equatable, Sendable {
        /// `--in`: the folder to search, as typed; nil = the home folder.
        var root: String? = nil
        /// Bytes; nil = `defaultMinSize`.
        var minSize: Int64? = nil
        /// Groups listed, most wasted space first.
        var limit = 20
    }

    /// The default `--min-size`, also the smallest allowed for the whole home folder (as the app's Size menu).
    static let defaultMinSize: Int64 = 50_000_000
    /// The smallest `--min-size` for a folder (`--in`), as the app's Size menu offers for a folder scope.
    static let folderMinSize: Int64 = 1_000_000

    /// A folder argument the command can't use. `needsFullDiskAccess`: a folder macOS protects, without Full Disk
    /// Access (exit code 3); anything else is a usage error (exit code 2).
    struct PathError: Error, Equatable {
        let message: String
        var needsFullDiskAccess = false
    }

    // MARK: - Reports

    struct Skipped: Codable, Equatable, Sendable {
        var path: String
        var reason: String
    }

    struct SpaceChild: Codable, Equatable, Sendable {
        var path: String
        var name: String
        /// Allocated bytes; nil when `skipped`.
        var size: Int64?
        /// "folder" or "file" (a symlink is a file: it is not followed).
        var kind: String
        /// A folder macOS protects, not read without Full Disk Access.
        var skipped: Bool
        var reason: String?

        enum CodingKeys: String, CodingKey { case path, name, size, kind, skipped, reason }

        /// `size` and `reason` are written as `null` when absent.
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(path, forKey: .path)
            try container.encode(name, forKey: .name)
            try container.encode(size, forKey: .size)
            try container.encode(kind, forKey: .kind)
            try container.encode(skipped, forKey: .skipped)
            try container.encode(reason, forKey: .reason)
        }
    }

    struct SpaceReport: Codable, Equatable, Sendable {
        var version: String
        var fullDiskAccess: Bool
        /// ISO 8601, UTC.
        var scannedAt: String
        /// The folder, absolute, symlinks resolved.
        var path: String
        /// Allocated bytes of the whole folder, without what `skipped` holds.
        var size: Int64
        /// The biggest children first (at most the limit), then the skipped ones.
        var items: [SpaceChild]
        /// Children left out by the limit, and their bytes.
        var moreItems: Int
        var moreSize: Int64
        /// Folders macOS protects inside `path` that were not read (no Full Disk Access).
        var skipped: [Skipped]
    }

    struct LargeFileItem: Codable, Equatable, Sendable {
        var path: String
        var name: String
        var size: Int64
        /// video, archive, diskImage, installer or other.
        var kind: String
        /// ISO 8601, UTC.
        var modified: String
        /// Last opened, from Spotlight (ISO 8601, UTC); nil when Spotlight doesn't know.
        var lastUsed: String?
        /// Other hard links to the file exist: moving this one to the Trash frees nothing while they remain.
        var hardLinked: Bool

        enum CodingKeys: String, CodingKey { case path, name, size, kind, modified, lastUsed, hardLinked }

        /// `lastUsed` is written as `null` when Spotlight doesn't know.
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(path, forKey: .path)
            try container.encode(name, forKey: .name)
            try container.encode(size, forKey: .size)
            try container.encode(kind, forKey: .kind)
            try container.encode(modified, forKey: .modified)
            try container.encode(lastUsed, forKey: .lastUsed)
            try container.encode(hardLinked, forKey: .hardLinked)
        }
    }

    struct LargeReport: Codable, Equatable, Sendable {
        var version: String
        var fullDiskAccess: Bool
        /// ISO 8601, UTC.
        var scannedAt: String
        /// The folder searched, absolute, symlinks resolved.
        var root: String
        var minSize: Int64
        var olderThanDays: Int?
        /// Every file found and their bytes, also those past the limit.
        var count: Int
        var size: Int64
        /// The biggest first, at most the limit.
        var files: [LargeFileItem]
        var moreFiles: Int
        /// Folders macOS protects inside `root` that were not searched (no Full Disk Access).
        var skipped: [Skipped]

        enum CodingKeys: String, CodingKey {
            case version, fullDiskAccess, scannedAt, root, minSize, olderThanDays, count, size, files, moreFiles, skipped
        }

        /// `olderThanDays` is written as `null` when not given.
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(version, forKey: .version)
            try container.encode(fullDiskAccess, forKey: .fullDiskAccess)
            try container.encode(scannedAt, forKey: .scannedAt)
            try container.encode(root, forKey: .root)
            try container.encode(minSize, forKey: .minSize)
            try container.encode(olderThanDays, forKey: .olderThanDays)
            try container.encode(count, forKey: .count)
            try container.encode(size, forKey: .size)
            try container.encode(files, forKey: .files)
            try container.encode(moreFiles, forKey: .moreFiles)
            try container.encode(skipped, forKey: .skipped)
        }
    }

    struct DuplicateFile: Codable, Equatable, Sendable {
        var path: String
        /// ISO 8601, UTC.
        var modified: String
        /// Bytes moving this copy to the Trash frees: 0 for an APFS clone sharing its blocks or a file with other
        /// hard links, less than `size` for a partial clone.
        var freeable: Int64
        /// The oldest copy (earliest modified): the one kept when the others go.
        var oldest: Bool
    }

    struct DuplicateGroup: Codable, Equatable, Sendable {
        /// Bytes of each copy.
        var size: Int64
        var count: Int
        /// Bytes freed by moving every copy but the oldest to the Trash.
        var wasted: Int64
        /// Oldest first.
        var files: [DuplicateFile]
    }

    struct DupesReport: Codable, Equatable, Sendable {
        var version: String
        var fullDiskAccess: Bool
        /// ISO 8601, UTC.
        var scannedAt: String
        /// The folder searched, absolute, symlinks resolved.
        var root: String
        var minSize: Int64
        /// Every group found and their wasted bytes, also those past the limit.
        var count: Int
        var wasted: Int64
        /// Most wasted space first, at most the limit.
        var groups: [DuplicateGroup]
        var moreGroups: Int
        /// Folders macOS protects inside `root` that were not searched (no Full Disk Access).
        var skipped: [Skipped]
    }

    // MARK: - Folders

    /// `argument` as an absolute, standardized URL: nil → `home`, a leading `~` → `home`, relative → from `current`.
    static func resolve(_ argument: String?, home: URL, current: String = FileManager.default.currentDirectoryPath) -> URL {
        guard let argument, !argument.isEmpty, argument != "~" else { return home.standardizedFileURL }
        if argument.hasPrefix("~/") { return home.appending(path: String(argument.dropFirst(2))).standardizedFileURL }
        if argument.hasPrefix("/") { return URL(fileURLWithPath: argument).standardizedFileURL }
        return URL(fileURLWithPath: current).appending(path: argument).standardizedFileURL
    }

    /// Folders not to enter without Full Disk Access, for the home folder as given and with its symlinks resolved
    /// (`/var` → `/private/var`), so a path in either form is caught.
    static func protectedFolders(home: URL, hasFullDiskAccess: Bool) -> Set<String> {
        var homes = [home]
        if let real = realPath(home.path) { homes.append(URL(fileURLWithPath: real)) }
        return homes.reduce(into: Set<String>()) { $0.formUnion(ProtectedFolders.skipped(home: $1, hasFullDiskAccess: hasFullDiskAccess)) }
    }

    static func realPath(_ path: String) -> String? {
        realpath(path, nil).map { pointer in defer { free(pointer) }; return String(cString: pointer) }
    }

    /// The folder `argument` names, checked before anything inside it is read: a folder macOS protects (without Full
    /// Disk Access) is refused by its path alone, then again with its symlinks resolved; it must exist, be a folder
    /// and be readable. Returns it with its symlinks resolved.
    static func folder(_ argument: String?, home: URL, skipping: Set<String>) throws(PathError) -> URL {
        let url = resolve(argument, home: home)
        let shown = argument ?? "~"
        func protected() -> PathError {
            PathError(message: "\(shown) is a folder macOS protects: reading it needs Full Disk Access. Grant it to the "
                      + "app that runs cleanmate in System Settings › Privacy & Security › Full Disk Access, then reopen that app.",
                      needsFullDiskAccess: true)
        }
        if ProtectedFolders.contains(skipping, url) { throw protected() }
        guard let real = realPath(url.path) else {
            throw PathError(message: errno == ENOENT || errno == ENOTDIR ? "no such folder: \(shown)" : "can't read \(shown)")
        }
        let folder = URL(fileURLWithPath: real, isDirectory: true)
        if ProtectedFolders.contains(skipping, folder) { throw protected() }
        var info = stat()
        guard stat(real, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw PathError(message: "not a folder: \(shown)") }
        guard access(real, R_OK | X_OK) == 0 else { throw PathError(message: "can't read \(shown)") }
        return folder
    }

    /// The protected folders inside `folder` that exist (looked at, not entered), sorted, spelled from `folder`.
    /// `skipping` holds standardized paths, which drop a leading `/private` that `folder` (resolved) keeps.
    static func skipped(_ skipping: Set<String>, inside folder: URL) -> [Skipped] {
        let base = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        let prefixes = Set([base, folder.standardizedFileURL.path + "/"])
        let found = skipping.reduce(into: Set<String>()) { found, path in
            guard let prefix = prefixes.first(where: { path.hasPrefix($0) }) else { return }
            let inside = base + path.dropFirst(prefix.count)
            var info = stat()
            if lstat(inside, &info) == 0 { found.insert(inside) }
        }
        return found.sorted().map { Skipped(path: $0, reason: HeadlessScan.needsAccess) }
    }

    // MARK: - space

    /// The folder `space` measures; throws for a path it can't use.
    static func spaceFolder(_ options: SpaceOptions, sources: HeadlessScan.Sources) throws(PathError) -> URL {
        let home = sources.policy().homeURL
        return try folder(options.path, home: home,
                          skipping: protectedFolders(home: home, hasFullDiskAccess: sources.hasFullDiskAccess()))
    }

    /// Children of `folder` by size, like Space Lens lists it: one `HardLinks` for the listing, protected folders
    /// left out without Full Disk Access.
    static func space(_ folder: URL, limit: Int, sources: HeadlessScan.Sources) async -> SpaceReport {
        let access = sources.hasFullDiskAccess()
        let home = sources.policy().homeURL
        let skipping = protectedFolders(home: home, hasFullDiskAccess: access)
        let links = SpaceLens.HardLinks()
        var listed = await SpaceLens.list(folder, links: links)
        let isProtected = { (item: SpaceItem) in skipping.contains(item.url.standardizedFileURL.path) }
        let sizes = await withTaskGroup(of: (URL, Int64).self) { group in
            for item in listed where item.isFolder && !isProtected(item) {
                group.addTask { (item.url, (try? await SpaceLens.measure(item.url, links: links, skipping: skipping))?.size ?? 0) }
            }
            return await group.reduce(into: [URL: Int64]()) { $0[$1.0] = $1.1 }
        }
        for index in listed.indices where listed[index].isFolder {
            listed[index].isProtected = isProtected(listed[index])
            listed[index].size = sizes[listed[index].url]
        }
        let measured = listed.filter { !$0.isProtected }
            .sorted { ($0.size ?? 0, $1.name) > ($1.size ?? 0, $0.name) }
        let shown = measured.prefix(limit)
        let rest = measured.dropFirst(shown.count)
        var own = stat()
        let ownSize = lstat(folder.path, &own) == 0 ? Int64(own.st_blocks) * 512 : 0
        let items = shown.map { item in
            SpaceChild(path: item.url.path, name: item.name, size: item.size ?? 0, kind: item.isFolder ? "folder" : "file",
                      skipped: false, reason: nil)
        } + listed.filter(\.isProtected).sorted { $0.name < $1.name }.map { item in
            SpaceChild(path: item.url.path, name: item.name, size: nil, kind: "folder", skipped: true, reason: HeadlessScan.needsAccess)
        }
        return SpaceReport(version: sources.version(), fullDiskAccess: access, scannedAt: sources.now().formatted(.iso8601),
                           path: folder.path, size: ownSize + measured.reduce(0) { $0 + ($1.size ?? 0) }, items: items,
                           moreItems: rest.count, moreSize: rest.reduce(0) { $0 + ($1.size ?? 0) },
                           skipped: skipped(skipping, inside: folder))
    }

    // MARK: - large

    /// The folder `large` searches, checked like the app's Scope menu: the home folder, a folder in it (not in
    /// ~/Library nor hidden) or an external drive; `--min-size` at least 50 MB for the home folder, 1 MB for a folder.
    static func largeFolder(_ options: LargeOptions, sources: HeadlessScan.Sources) throws(PathError) -> URL {
        let policy = sources.policy()
        let home = policy.homeURL
        let skipping = protectedFolders(home: home, hasFullDiskAccess: sources.hasFullDiskAccess())
        _ = try folder(options.root, home: home, skipping: skipping)
        let url = resolve(options.root, home: home)
        guard LargeFileScanner.allowsRoot(url, policy: policy) else {
            throw PathError(message: "\(options.root ?? "~") can't be searched: large looks in your home folder (not in "
                            + "~/Library or hidden folders) or on an external drive")
        }
        let isHome = url.standardizedFileURL.path == home.standardizedFileURL.path
        let floor = isHome ? defaultMinSize : folderMinSize
        if let minSize = options.minSize, minSize < floor {
            throw PathError(message: "--min-size must be at least \(CommandLineTool.size(floor))"
                            + (isHome ? " for the whole home folder (use --in for a folder)" : ""))
        }
        return url
    }

    /// Large files under `root` as Large & Old Files finds them, biggest first. Throws when the scan fails.
    static func large(_ root: URL, options: LargeOptions, sources: HeadlessScan.Sources) async throws -> LargeReport {
        let access = sources.hasFullDiskAccess()
        let policy = sources.policy()
        let skipping = protectedFolders(home: policy.homeURL, hasFullDiskAccess: access)
        let minSize = options.minSize ?? defaultMinSize
        let opened = Locked([String: Date]())
        let spotlight = sources.spotlightLastUsed
        let found = try await LargeFileScanner.scan(root: root, minSize: minSize, policy: policy, skipping: skipping,
                                                    spotlightLastUsed: { url in
            let date = spotlight(url)
            if let date { opened.withLock { $0[url.path] = date } }
            return date
        })
        let now = sources.now()
        let cutoff = options.olderThanDays.map { now.addingTimeInterval(-Double($0) * 86_400) }
        let matches = found.filter { $0.matches(minSize: minSize, unusedSince: cutoff) }
            .sorted { ($0.size, $1.url.path) > ($1.size, $0.url.path) }
        let shown = matches.prefix(options.limit)
        let lastUsed = opened.withLock { $0 }
        let real = realPath(root.path) ?? root.path
        // ~/Library is never searched, with or without Full Disk Access: its protected folders aren't skipped by it.
        let library = [policy.homeURL, URL(fileURLWithPath: realPath(policy.homeURL.path) ?? policy.homeURL.path)]
            .map { $0.appending(path: "Library").standardizedFileURL.path + "/" }
        return LargeReport(version: sources.version(), fullDiskAccess: access, scannedAt: now.formatted(.iso8601), root: real,
                           minSize: minSize, olderThanDays: options.olderThanDays, count: matches.count,
                           size: matches.reduce(0) { $0 + $1.size },
                           files: shown.map { file in
                               LargeFileItem(path: file.url.path, name: file.name, size: file.size, kind: file.kind.rawValue,
                                             modified: file.modified.formatted(.iso8601),
                                             lastUsed: lastUsed[file.url.path]?.formatted(.iso8601), hardLinked: file.hardLinked)
                           },
                           moreFiles: matches.count - shown.count,
                           skipped: skipped(skipping, inside: URL(fileURLWithPath: real))
                            .filter { skipped in !library.contains { skipped.path.hasPrefix($0) } })
    }

    // MARK: - dupes

    /// The folder `dupes` searches: the same rules as `large` (`largeFolder`).
    static func dupesFolder(_ options: DupesOptions, sources: HeadlessScan.Sources) throws(PathError) -> URL {
        try largeFolder(LargeOptions(root: options.root, minSize: options.minSize), sources: sources)
    }

    /// Duplicates among the files `large` finds, as the Duplicates Only filter of Large & Old Files finds them
    /// (`DuplicateFinder`: same content by SHA-256, a hard-linked file counted once, APFS clones free nothing).
    /// Throws when the scan fails.
    static func dupes(_ root: URL, options: DupesOptions, sources: HeadlessScan.Sources) async throws -> DupesReport {
        let large = try await large(root, options: LargeOptions(root: options.root, minSize: options.minSize,
                                                                limit: Int.max), sources: sources)
        let found = try await DuplicateFinder.find(large.files.map { URL(fileURLWithPath: $0.path) })
        let byPath = Dictionary(large.files.map { ($0.path, $0) }) { a, _ in a }
        let groups = found.groups.compactMap { urls -> DuplicateGroup? in
            let files = urls.compactMap { byPath[$0.path] }
            guard files.count >= 2 else { return nil }
            let ordered = files.sorted { ($0.modified, $0.path) < ($1.modified, $1.path) }
            let copies = ordered.enumerated().map { index, file in
                DuplicateFile(path: file.path, modified: file.modified,
                              freeable: file.hardLinked ? 0 : found.privateSizes[URL(fileURLWithPath: file.path)] ?? file.size,
                              oldest: index == 0)
            }
            return DuplicateGroup(size: files[0].size, count: copies.count,
                                  wasted: copies.dropFirst().reduce(0) { $0 + $1.freeable }, files: copies)
        }.sorted { ($0.wasted, $0.size, $1.files[0].path) > ($1.wasted, $1.size, $0.files[0].path) }
        let shown = groups.prefix(options.limit)
        return DupesReport(version: large.version, fullDiskAccess: large.fullDiskAccess, scannedAt: large.scannedAt,
                           root: large.root, minSize: large.minSize, count: groups.count,
                           wasted: groups.reduce(0) { $0 + $1.wasted }, groups: Array(shown),
                           moreGroups: groups.count - shown.count, skipped: large.skipped)
    }

    // MARK: - Arguments

    /// `50MB`, `1.5GB`, `500M`, `2g`, `1000000` → bytes (1 MB = 1,000,000 bytes, as Finder and the app count); nil
    /// when it isn't a size.
    static func parseSize(_ text: String) -> Int64? {
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)
        let units: [(String, Double)] = [("tb", 1e12), ("gb", 1e9), ("mb", 1e6), ("kb", 1e3), ("t", 1e12), ("g", 1e9),
                                         ("m", 1e6), ("k", 1e3), ("b", 1)]
        let (number, scale) = units.first { lower.hasSuffix($0.0) }
            .map { (String(lower.dropLast($0.0.count)).trimmingCharacters(in: .whitespaces), $0.1) } ?? (lower, 1)
        guard !number.isEmpty, number.allSatisfy({ $0.isNumber || $0 == "." }), let value = Double(number), value > 0,
              value * scale < 9e18 else { return nil }
        return Int64((value * scale).rounded())
    }
}
