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
    /// The app's cache file; memory only under tests, which never touch the real one.
    static let shared = FolderSizeCache(
        file: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil ? defaultURL : nil)
    static var defaultURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "\(Bundle.main.bundleIdentifier ?? "com.homielab.CleanMate")/folder-sizes.json")
    }

    /// What a folder was measured with: its modification time and link count, read with `lstat`.
    nonisolated struct Fingerprint: Equatable, Sendable {
        let seconds: Int
        let nanoseconds: Int
        let links: Int

        /// nil when `url` is not a folder (gone, a file, a symlink).
        init?(_ url: URL) {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
            (seconds, nanoseconds, links) = (info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec, Int(info.st_nlink))
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
    let limit: Int
    /// Path → record; nil until first read from `file`.
    private let records = Locked<[String: Record]?>(nil)

    /// `file`: where the sizes persist; nil = this run only.
    init(file: URL?, limit: Int = limit) {
        self.file = file
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
            guard let file else { return }
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
