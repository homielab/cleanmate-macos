import CoreServices
import CryptoKit
import Foundation
import Synchronization
import UniformTypeIdentifiers

// Large & Old Files: user files found by walking the home folder, moved to the Trash only when the user ticks them.

nonisolated enum FileKind: String, CaseIterable, Sendable {
    case video, archive, diskImage, installer, other

    static let archiveExtensions: Set = ["zip", "tar", "gz", "tgz", "bz2", "tbz", "xz", "txz", "zst", "7z", "rar", "lz", "lzma", "cab", "jar", "war", "xip"]
    static let diskImageExtensions: Set = ["iso", "img", "toast", "vmdk", "vdi", "vhd", "vhdx", "qcow2", "raw", "sparseimage", "ipsw"]
    static let installerExtensions: Set = ["dmg", "pkg", "mpkg", "exe", "msi", "apk", "deb", "rpm", "appimage"]

    init(fileExtension: String) {
        let ext = fileExtension.lowercased()
        if Self.installerExtensions.contains(ext) { self = .installer }
        else if Self.diskImageExtensions.contains(ext) { self = .diskImage }
        else if Self.archiveExtensions.contains(ext) { self = .archive }
        else if UTType(filenameExtension: ext)?.conforms(to: .movie) == true { self = .video }
        else { self = .other }
    }
}

nonisolated struct LargeFile: Identifiable, Hashable, Sendable {
    let url: URL
    let size: Int64
    /// See `LargeFileScanner.lastUsed`: Spotlight's last-opened date when known, else last access, never older than last modification.
    let lastUsed: Date
    let kind: FileKind
    /// Stored: sorting the table by name read `url.lastPathComponent` in every comparison (1.5 s for 50k files).
    let name: String
    /// Containing folder, `~`-abbreviated (`displayLocation`); stored so the Location column does no work per render.
    let location: String
    /// Last content change; picks which duplicate copy to keep. Defaults to `lastUsed` when unknown.
    let modified: Date
    /// The file has other hard links (nlink > 1): moving this one to the Trash frees nothing while another remains.
    /// Labelled in the list, still counted in the sizes and still movable.
    let hardLinked: Bool

    init(url: URL, size: Int64, lastUsed: Date, kind: FileKind, modified: Date? = nil, hardLinked: Bool = false,
         home: URL = URL(fileURLWithPath: NSHomeDirectory())) {
        (self.url, self.size, self.lastUsed, self.kind, name) = (url, size, lastUsed, kind, url.lastPathComponent)
        self.hardLinked = hardLinked
        self.modified = modified ?? lastUsed
        location = Self.displayLocation(of: url, home: home)
    }

    /// Folder containing `url`, with the `home` prefix shown as `~`: `~/Downloads`, `~` for files directly in home,
    /// the full path for folders outside home.
    static func displayLocation(of url: URL, home: URL) -> String {
        let folder = url.deletingLastPathComponent().standardizedFileURL.path(percentEncoded: false)
        let trimmed = { (path: String) in path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path }
        let (dir, root) = (trimmed(folder), trimmed(home.standardizedFileURL.path(percentEncoded: false)))
        if dir == root { return "~" }
        if dir.hasPrefix(root + "/") { return "~" + dir.dropFirst(root.count) }
        return dir
    }

    var id: URL { url }

    /// Not used since `cutoff` (nil = any age) and at least `minSize` bytes.
    func matches(minSize: Int64, unusedSince cutoff: Date?) -> Bool {
        size >= minSize && (cutoff.map { lastUsed < $0 } ?? true)
    }
}

nonisolated enum LargeFileScanner {
    /// Folders never walked: regenerable dev trees whose files the user does not manage by hand.
    static let skippedFolderNames: Set = ["node_modules", "Pods", "DerivedData"]

    /// A scan root that is not the home folder or a folder inside it.
    struct OutsideHomeError: Error {}

    /// The home folder or a folder inside it, not in ~/Library or a hidden folder: the only places `allowsUserFile`
    /// lists files from, so any other root would find nothing (or, outside home, nothing it may trash).
    static func allowsRoot(_ root: URL, home: URL) -> Bool {
        let (path, base) = (root.standardizedFileURL.path, home.standardizedFileURL.path)
        if path == base { return true }
        guard path.hasPrefix(base + "/") else { return false }
        let parts = path.dropFirst(base.count + 1).split(separator: "/")
        return parts.first?.lowercased() != "library" && !parts.contains { $0.hasPrefix(".") }
    }

    /// Regular files of at least `minSize` bytes under `root` (the home folder or a folder in it, else
    /// `OutsideHomeError`), skipping ~/Library, hidden
    /// files and folders, other volumes mounted inside it, and package contents (.app, .photoslibrary…). Throws `CancellationError` when cancelled.
    /// `progress` gets the number of entries checked so far, every 500 entries.
    /// `spotlightLastUsed` is only asked for files already over `minSize` (one Spotlight lookup each); injectable for tests.
    /// Folders whose path is in `skipping` (`ProtectedFolders.skipped`) are not entered.
    @concurrent static func scan(root: URL, minSize: Int64, policy: SafetyPolicy = .current, skipping: Set<String> = [],
                                 spotlightLastUsed: @escaping @Sendable (URL) -> Date? = spotlightLastUsedDate,
                                 progress: (@Sendable (Int) -> Void)? = nil) async throws -> [LargeFile] {
        guard allowsRoot(root, home: policy.homeURL) else { throw OutsideHomeError() }
        let walk = Walk(minSize: minSize, policy: policy, skipping: skipping, spotlightLastUsed: spotlightLastUsed,
                        progress: progress, library: policy.homeURL.appending(path: "Library").standardizedFileURL.path)
        // The enumerator lists a root's files under its real path (/var → /private/var); the parallel levels do the same.
        let real = realpath(root.path, nil).map { defer { free($0) }; return String(cString: $0) } ?? root.path
        return try await walk.tree(URL(fileURLWithPath: real, isDirectory: true), depth: splitDepth)
    }

    /// Folder levels below the root listed in parallel before each deeper folder gets one enumerator walk (the
    /// home took 2.4 s on one thread). Results keep the single walk's order.
    static let splitDepth = 3

    private static let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .totalFileAllocatedSizeKey,
                                                 .contentAccessDateKey, .contentModificationDateKey, .isVolumeKey]

    private final class Walk: Sendable {
        let minSize: Int64
        let policy: SafetyPolicy
        let skipping: Set<String>
        let spotlightLastUsed: @Sendable (URL) -> Date?
        let progress: (@Sendable (Int) -> Void)?
        let library: String
        let checked = Mutex(0)

        init(minSize: Int64, policy: SafetyPolicy, skipping: Set<String>, spotlightLastUsed: @escaping @Sendable (URL) -> Date?,
             progress: (@Sendable (Int) -> Void)?, library: String) {
            (self.minSize, self.policy, self.skipping, self.spotlightLastUsed, self.progress, self.library)
                = (minSize, policy, skipping, spotlightLastUsed, progress, library)
        }

        /// Counts one entry checked; reports every 500 like the single walk did.
        func tick() {
            let count = checked.withLock { $0 += 1; return $0 }
            if count % 500 == 0 { progress?(count) }
        }

        /// The files under `folder` (not itself) in enumerator order: `depth` levels listed in parallel, then one
        /// `FileManager` enumerator per folder, with the same skips (hidden, packages, other volumes, `skipping`…).
        func tree(_ folder: URL, depth: Int) async throws -> [LargeFile] {
            guard depth > 0, let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
            else { return try enumerate(folder) }
            return try await withThrowingTaskGroup(of: (Int, [LargeFile]).self) { group in
                var parts: [(Int, [LargeFile])] = []
                for (index, name) in names.enumerated() where !name.hasPrefix(".") {
                    try Task.checkCancellation()
                    let url = folder.appending(path: name)
                    guard let values = try? url.resourceValues(forKeys: Set(keys + [.isPackageKey, .isHiddenKey])) else {
                        tick() // the enumerator lists (and counts) it too
                        continue
                    }
                    guard values.isHidden != true else { continue }
                    tick()
                    if values.isDirectory == true {
                        if !skips(url, values), values.isPackage != true {
                            let folder = folder.appending(path: name, directoryHint: .isDirectory)
                            group.addTask { (index, try await self.tree(folder, depth: depth - 1)) }
                        }
                    } else if let file = file(url, values) {
                        parts.append((index, [file]))
                    }
                }
                for try await part in group { parts.append(part) }
                return parts.sorted { $0.0 < $1.0 }.flatMap(\.1)
            }
        }

        func enumerate(_ folder: URL) throws -> [LargeFile] {
            guard let enumerator = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true })
            else { return [] }
            var found: [LargeFile] = []
            while let url = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                tick()
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                if values.isDirectory == true {
                    if skips(url, values) { enumerator.skipDescendants() }
                    continue
                }
                if let file = file(url, values) { found.append(file) }
            }
            return found
        }

        /// A folder not walked. Another volume mounted in the home (OrbStack's NFS share, CoreDevice's DeviceFS) is
        /// not walked, like Space Lens (`du -x`): it is not on this disk, and a network share can take minutes to list.
        func skips(_ url: URL, _ values: URLResourceValues) -> Bool {
            let path = url.standardizedFileURL.path
            return values.isVolume == true || path == library || skipping.contains(path)
                || skippedFolderNames.contains(url.lastPathComponent)
        }

        func file(_ url: URL, _ values: URLResourceValues) -> LargeFile? {
            // Allocated size: iCloud files evicted to the cloud take no space and are not listed.
            guard values.isRegularFile == true, let size = values.totalFileAllocatedSize, Int64(size) >= minSize,
                  policy.allowsUserFile(url) else { return nil }
            let used = lastUsed(spotlight: spotlightLastUsed(url), accessed: values.contentAccessDate,
                                modified: values.contentModificationDate)
            var info = stat()
            return LargeFile(url: url, size: Int64(size), lastUsed: used,
                             kind: FileKind(fileExtension: url.pathExtension), modified: values.contentModificationDate,
                             hardLinked: lstat(url.path, &info) == 0 && info.st_nlink > 1, home: policy.homeURL)
        }
    }

    /// Spotlight's `kMDItemLastUsedDate` (last opened by the user), when the file is indexed and has one.
    static func spotlightLastUsedDate(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    /// Spotlight's last-opened date replaces the access date (atime is often not updated), but a later modification
    /// still counts as use (a program can rewrite a file without "opening" it), so: max(lastUsed ?? atime, mtime).
    static func lastUsed(spotlight: Date?, accessed: Date?, modified: Date?) -> Date {
        [spotlight ?? accessed, modified].compactMap { $0 }.max() ?? .distantPast
    }

    /// Moves files to the Trash (never deletes), re-checking the user-file policy right before each one.
    @concurrent static func trash(_ files: [LargeFile], policy: SafetyPolicy = .current) async -> CleanReport {
        CleanReport.trashing(files.map { ($0.url, $0.size) }, module: "Large & Old Files", home: policy.homeURL,
                             allows: policy.allowsUserFile)
    }
}

/// Duplicates among the large files: only files of equal byte size are read, and only to compare SHA-256 hashes.
nonisolated enum DuplicateFinder {
    /// A file's content is assumed unchanged while its path, byte size, modification date and inode are (hash cache key).
    struct Key: Hashable, Sendable, Codable {
        let path: String
        let size: Int64
        let modified: Date
        let inode: UInt64
    }

    struct Result: Sendable {
        /// Groups of 2+ files with the same content, largest first; paths sorted within a group.
        var groups: [[URL]] = []
        /// Every hash known after this run (the cache passed in plus new ones), to pass to the next run.
        var hashes: [Key: Data] = [:]
        /// Files read in full this run (not answered from the cache nor ruled out by their head).
        var hashedCount = 0
    }

    /// Thrown instead of `CancellationError` by `find`: carries the cache passed in plus every full-file hash
    /// finished before the stop (never a partial or head hash), so the next run does not read those files again.
    struct Cancelled: Error { let hashes: [Key: Data] }

    /// One file on disk: a hard link's inode, or an APFS clone ID shared by whole-file clones (`number` vs `clone`).
    private struct Inode: Hashable { let device: Int32, number: UInt64, clone: Bool }

    /// Hard links to one file (same device + inode) and APFS clones that still share every block (Finder
    /// Duplicate, `cp -c`) count once: trashing one of them frees nothing. A clone changed after cloning shares only
    /// some blocks; APFS cannot say how many, so it is still reported as a duplicate.
    /// `progress` gets the fraction of bytes to read done so far. Throws `Cancelled` when cancelled.
    @concurrent static func find(_ urls: [URL], cache: [Key: Data] = [:],
                                 progress: (@Sendable (Double) -> Void)? = nil) async throws -> Result {
        var result = Result(hashes: cache)
        do {
            try findGroups(urls, cache: cache, into: &result, progress: progress)
        } catch is CancellationError {
            throw Cancelled(hashes: result.hashes)
        }
        return result
    }

    private static func findGroups(_ urls: [URL], cache: [Key: Data], into result: inout Result,
                                   progress: (@Sendable (Double) -> Void)?) throws {
        var seen = Set<Inode>()
        var bySize: [Int64: [(url: URL, key: Key)]] = [:]
        for url in urls {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  seen.insert(Inode(device: info.st_dev, number: info.st_ino, clone: false)).inserted,
                  cloneID(of: url).map({ seen.insert(Inode(device: info.st_dev, number: $0, clone: true)).inserted }) ?? true
            else { continue }
            let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
            bySize[info.st_size, default: []].append((url, Key(path: url.path, size: info.st_size, modified: modified, inode: info.st_ino)))
        }
        let candidates = bySize.filter { $0.value.count >= 2 }.sorted { $0.key > $1.key }
        let total = candidates.reduce(0.0) { $0 + Double($1.key) * Double($1.value.count) }
        var done = 0.0
        var reported = 0.0
        func report(_ fraction: Double) {
            let fraction = min(fraction, 1) // a file that grew while being read
            if fraction - reported >= 0.01 { reported = fraction; progress?(fraction) } // ~100 updates, not one per MB
        }
        // Every candidate counts toward progress once settled: hashed, cached, ruled out by its head, or unreadable.
        func settled(_ size: Int64) {
            done += Double(size)
            if total > 0 { report(done / total) }
        }
        for (size, files) in candidates {
            var pending = files
            // Head pass: a file whose first `headSize` bytes no other file of its size shares is not read in full.
            // Skipped when a cached hash is in the group: that file's head is unknown.
            if size > headSize, !files.contains(where: { cache[$0.key] != nil }) {
                var heads: [Data: Int] = [:]
                var headOf: [URL: Data] = [:]
                for file in files {
                    try Task.checkCancellation()
                    guard let head = try sha256(of: file.url, limit: headSize) else { continue }
                    headOf[file.url] = head
                    heads[head, default: 0] += 1
                }
                pending = files.filter { headOf[$0.url].map { heads[$0, default: 0] >= 2 } ?? false }
                for _ in pending.count..<files.count { settled(size) }
            }
            var byHash: [Data: [URL]] = [:]
            for file in pending {
                try Task.checkCancellation()
                let hash: Data
                if let cached = cache[file.key] {
                    hash = cached
                } else {
                    let base = done
                    guard let read = try sha256(of: file.url, progress: { bytes in
                        if total > 0 { report((base + Double(bytes)) / total) }
                    }) else { settled(size); continue } // unreadable: never reported as a duplicate
                    hash = read
                    result.hashedCount += 1
                }
                result.hashes[file.key] = hash
                byHash[hash, default: []].append(file.url)
                settled(size)
            }
            result.groups += byHash.values.filter { $0.count >= 2 }
                .map { $0.sorted { $0.path < $1.path } }.sorted { $0[0].path < $1[0].path }
        }
    }

    /// Hashes kept across launches in `~/Library/Caches/<bundle id>/hashes.json`. Any read/write error = no cache.
    /// Smart Scan's "User caches" never cleans this folder (`keptCaches`, and the app is running).
    enum HashCache {
        static let limit = 10_000
        static var defaultURL: URL {
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appending(path: "\(Bundle.main.bundleIdentifier ?? "com.homielab.CleanMate")/hashes.json")
        }

        /// Only 32-byte (SHA-256) values: a bad one shared by two files would group them as duplicates.
        @concurrent static func load(from url: URL) async -> [Key: Data] { read(url) }

        private static func read(_ url: URL) -> [Key: Data] {
            ((try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([Key: Data].self, from: $0) } ?? [:])
                .filter { $0.value.count == 32 }
        }

        /// Serializes read-merge-write so two saves at once (a stopped search finishing while a new one ends)
        /// keep both sets of hashes instead of the later write dropping the earlier one.
        private static let lock = NSLock()

        /// Merges into what is on disk (new values win), drops entries whose file is gone or changed and any value that
        /// is no full SHA-256, keeps the `limit` most recently modified, writes atomically.
        @concurrent static func save(_ hashes: [Key: Data], to url: URL, limit: Int = limit) async {
            lock.withLock {
                let live = read(url).merging(hashes) { _, new in new }.filter { key, value in
                    var info = stat()
                    return value.count == 32 && lstat(key.path, &info) == 0 && info.st_size == key.size && info.st_ino == key.inode
                        && Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9) == key.modified
                }
                let kept = live.count <= limit ? live
                    : Dictionary(uniqueKeysWithValues: live.sorted { $0.key.modified > $1.key.modified }.prefix(limit).map { ($0.key, $0.value) })
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? JSONEncoder().encode(kept).write(to: url, options: .atomic)
            }
        }
    }

    /// The APFS clone ID when the file shares all its blocks with its clones, else nil (not a clone, changed since
    /// cloning, or not APFS). Measured on macOS 26: `clonefile` gives original and clone the same ID with
    /// `EF_SHARES_ALL_BLOCKS`; a plain copy gets its own ID with no flags; writing to a clone gives it a new ID and
    /// leaves both with only `EF_MAY_SHARE_BLOCKS`.
    static func cloneID(of url: URL) -> UInt64? {
        var attrs = attrlist()
        attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        attrs.forkattr = attrgroup_t(ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_EXT_FLAGS)
        // u_int32 length, attribute_set_t returned, u_int64 clone ID, u_int64 extended flags
        var buffer = [UInt8](repeating: 0, count: 64)
        guard getattrlist(url.path, &attrs, &buffer, buffer.count, UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW)) == 0
        else { return nil }
        return buffer.withUnsafeBytes { raw in
            let returned = raw.loadUnaligned(fromByteOffset: 4, as: attribute_set_t.self)
            let offset = 4 + MemoryLayout<attribute_set_t>.size
            guard returned.forkattr & attrs.forkattr == attrs.forkattr,
                  raw.loadUnaligned(fromByteOffset: offset + 8, as: UInt64.self) & UInt64(EF_SHARES_ALL_BLOCKS) != 0
            else { return nil }
            return raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
        }
    }

    /// Bytes read from the start of each same-size file before reading any in full.
    static let headSize = 64 * 1024

    /// SHA-256 of the file's first `limit` bytes read in 1 MB chunks, checking for cancellation between chunks; nil when
    /// it cannot be read.
    /// Reading moves the access date forward (when it is not after the modification date), which the Last Used column
    /// relies on, so the previous access date is put back.
    static func sha256(of url: URL, limit: Int = .max, progress: (Int) -> Void = { _ in }) throws -> Data? {
        var before = stat()
        guard lstat(url.path, &before) == 0, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer {
            try? handle.close()
            var after = stat()
            if lstat(url.path, &after) == 0, after.st_atimespec.tv_sec != before.st_atimespec.tv_sec
                || after.st_atimespec.tv_nsec != before.st_atimespec.tv_nsec {
                var attrs = attrlist()
                attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
                attrs.commonattr = attrgroup_t(ATTR_CMN_ACCTIME)
                var time = before.st_atimespec
                _ = setattrlist(url.path, &attrs, &time, MemoryLayout<timespec>.size, UInt32(FSOPT_NOFOLLOW))
            }
        }
        var hasher = SHA256()
        var read = 0
        while read < limit {
            try Task.checkCancellation()
            // Each chunk is autoreleased: without a pool per chunk a hash holds the whole file (3.3 GB peak).
            let count: Int? = autoreleasepool {
                let chunk: Data?
                do { chunk = try handle.read(upToCount: min(1 << 20, limit - read)) } catch { return nil }
                guard let chunk else { return 0 } // nil or empty: end of file
                hasher.update(data: chunk)
                return chunk.count
            }
            guard let count else { return nil }
            guard count > 0 else { break }
            read += count
            progress(read)
        }
        return Data(hasher.finalize())
    }
}
