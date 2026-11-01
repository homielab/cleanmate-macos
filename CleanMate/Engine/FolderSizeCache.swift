import Foundation

/// Sizes of whole folders measured by earlier scans, so a folder whose top level did not change is not walked again: a
/// stale project's `node_modules` or `target` holds up to hundreds of thousands of files nobody touches
/// (`CleanerItem.entrySizes`). A folder counts as unchanged while its path, modification date and link count (its
/// subfolders, on APFS) are those it was measured with; a change only deeper inside goes unseen until the top level
/// changes too, which suits folders that installs and builds rewrite. At most `limit` folders, the least recently used
/// dropped first. Kept in `~/Library/Caches/<bundle id>/folder-sizes.json`, which Smart Scan never cleans (`keptCaches`);
/// any read or write error means no cache.
nonisolated final class FolderSizeCache: @unchecked Sendable {
    static let limit = 1_000
    /// Bumped when entries are measured another way: older records are measured again (2: `FreeableBytes`).
    static let version = 2
    /// The app's cache file; memory only under tests, which never touch the real one. The command line tool reads
    /// it but never writes it.
    static let shared = FolderSizeCache(
        file: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil ? defaultURL : nil,
        readOnly: AppIdentity.isCommandLineTool)
    static var defaultURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "\(AppIdentity.bundleID)/folder-sizes.json")
    }

    /// What a folder was measured with: its modification time and link count, read with `lstat`. With a `depth`
    /// (`CleanerItem.entrySizesDepth`), the newest modification time among the folder and everything up to `depth`
    /// levels inside it, and how many items those levels hold: a file added, removed or
    /// rewritten that deep changes it too, for caches a tool keeps writing into (Gradle).
    nonisolated struct Fingerprint: Equatable, Sendable {
        let seconds: Int
        let nanoseconds: Int
        let links: Int

        /// nil when `url` is not a folder (gone, a file, a symlink).
        init?(_ url: URL, depth: Int = 0) {
            if depth > 0 {
                guard let newest = Self.newest(url.path, depth: depth) else { return nil }
                (seconds, nanoseconds, links) = (newest.time.tv_sec, newest.time.tv_nsec, newest.items)
                return
            }
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
            (seconds, nanoseconds, links) = (info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec, Int(info.st_nlink))
        }

        private static let bufferSize = 64 * 1024

        /// The newest modification time among `path` and the items up to `depth` levels inside it, and how many items
        /// those levels hold, listed with `getattrlistbulk` (one call per folder). nil when `path` is not a folder.
        private static func newest(_ path: String, depth: Int) -> (time: timespec, items: Int)? {
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
            var newest = info.st_mtimespec, items = 0
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize, alignment: 8)
            defer { buffer.deallocate() }
            var attributes = attrlist()
            attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
            let common = attrgroup_t(ATTR_CMN_NAME | ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME)
            attributes.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | common
            var level = [path]
            for remaining in stride(from: depth, to: 0, by: -1) {
                var next: [String] = []
                for folder in level {
                    let fd = open(folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                    guard fd >= 0 else { continue }
                    defer { close(fd) }
                    let prefix = folder.hasSuffix("/") ? folder : folder + "/"
                    while true {
                        let count = getattrlistbulk(fd, &attributes, buffer, Self.bufferSize, 0)
                        guard count > 0 else { break }
                        var entry = buffer
                        for _ in 0..<count {
                            let length = Int(entry.loadUnaligned(as: UInt32.self))
                            defer { entry += length }
                            let returned = entry.loadUnaligned(fromByteOffset: 4, as: attribute_set_t.self)
                            guard returned.commonattr & common == common else { continue }
                            var field = entry + 4 + MemoryLayout<attribute_set_t>.size
                            let nameField = field
                            let name = field.loadUnaligned(as: attrreference_t.self)
                            field += MemoryLayout<attrreference_t>.size
                            let type = field.loadUnaligned(as: fsobj_type_t.self)
                            field += MemoryLayout<fsobj_type_t>.size
                            let time = field.loadUnaligned(as: timespec.self)
                            items += 1
                            if (time.tv_sec, time.tv_nsec) > (newest.tv_sec, newest.tv_nsec) { newest = time }
                            if remaining > 1, type == VDIR.rawValue {
                                let namePointer = (nameField + Int(name.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
                                next.append(prefix + String(cString: namePointer))
                            }
                        }
                    }
                }
                level = next
            }
            return (newest, items)
        }
    }

    /// One folder: what it was measured with, its size, and when a scan last used it (seconds since 1970).
    nonisolated struct Record: Codable, Equatable {
        var seconds: Int
        var nanoseconds: Int
        var links: Int
        var size: Int64
        var partlyUnreadable: Bool
        var used: Double
        /// nil in files written before `version` existed.
        var version: Int?
    }

    let file: URL?
    /// `file` is read, never written.
    let readOnly: Bool
    let limit: Int
    /// Path → record; nil until first read from `file`.
    private let records = Locked<[String: Record]?>(nil)

    /// `file`: where the sizes persist; nil = this run only.
    init(file: URL?, readOnly: Bool = false, limit: Int = limit) {
        self.file = file
        self.readOnly = readOnly
        self.limit = limit
    }

    /// The size `url` was measured at with `fingerprint`, marked as used `now`; nil when unknown or changed since.
    func size(of url: URL, _ fingerprint: Fingerprint, now: Date = .now) -> (size: Int64, partlyUnreadable: Bool)? {
        records.withLock { records in
            load(&records)
            let path = url.standardizedFileURL.path
            guard var record = records?[path], record.seconds == fingerprint.seconds,
                  record.nanoseconds == fingerprint.nanoseconds, record.links == fingerprint.links,
                  record.version == Self.version else { return nil }
            record.used = now.timeIntervalSince1970
            records?[path] = record
            return (record.size, record.partlyUnreadable)
        }
    }

    /// Keeps `size` for `url` as it was with `fingerprint` (read before measuring, so a change during the walk is a miss
    /// next time). Only in memory until `save`.
    func remember(_ url: URL, _ fingerprint: Fingerprint, size: Int64, partlyUnreadable: Bool, now: Date = .now) {
        records.withLock { records in
            load(&records)
            records?[url.standardizedFileURL.path] = Record(seconds: fingerprint.seconds, nanoseconds: fingerprint.nanoseconds,
                                                            links: fingerprint.links, size: size,
                                                            partlyUnreadable: partlyUnreadable, used: now.timeIntervalSince1970,
                                                            version: Self.version)
        }
    }

    /// Drops all but the `limit` most recently used folders and writes the rest to `file`, atomically.
    func save() {
        records.withLock { records in
            load(&records)
            guard var all = records else { return }
            if all.count > limit {
                all = Dictionary(uniqueKeysWithValues: all.sorted { ($0.value.used, $0.key) > ($1.value.used, $1.key) }.prefix(limit)
                    .map { ($0.key, $0.value) })
                records = all
            }
            guard let file, !readOnly else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(all).write(to: file, options: .atomic)
        }
    }

    /// Folders known now (tests).
    var count: Int {
        records.withLock { records in
            load(&records)
            return records?.count ?? 0
        }
    }

    private func load(_ records: inout [String: Record]?) {
        guard records == nil else { return }
        records = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String: Record].self, from: $0) } ?? [:]
    }
}
