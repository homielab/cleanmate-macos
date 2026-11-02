import Foundation

/// What CleanMate moved to the Trash, kept in `~/Library/Application Support/CleanMate/trashed.json` so that
/// `cleanmate restore` can list it and put it back after CleanMate quit: every move of the app and the command line
/// that "Undo" could put back (Large & Old Files, Space Lens, the Uninstaller, Smart Scan items that go to the Trash,
/// `cleanmate trash`). Only the record is kept, never the item: an entry goes once its item is no longer in the Trash.
nonisolated enum TrashRecords {
    /// One move to the Trash, kept until it is put back or no longer in the Trash.
    struct Record: Codable, Equatable, Sendable {
        var original: String
        var trashed: String
        var size: Int64
        /// The old folder with symlinks resolved, and its volume, when moved (`TrashedItem`).
        var folder: String
        var volume: Int32?
        /// The item in the Trash: put back only while it is still this one.
        var device: Int32
        var inode: UInt64
        /// When it was moved (ISO 8601, local time zone).
        var date: String?
        /// The activity log's module (English) and item column of the move, so putting it back logs "restored" under
        /// the same name and `ActivityLog.freed` takes back what that move added. nil: "Command Line" and `original`.
        var module: String?
        var logItem: String?

        init(_ item: TrashedItem, id: SafeRemoval.FileID, date: Date = .now, module: String? = nil, logItem: String? = nil) {
            original = item.original.path
            trashed = item.inTrash.path
            size = item.size
            folder = item.folder
            volume = item.volume
            device = id.device
            inode = id.inode
            self.date = Date.ISO8601FormatStyle(timeZone: .current).format(date)
            self.module = module
            self.logItem = logItem
        }

        var id: SafeRemoval.FileID { SafeRemoval.FileID(device: device, inode: inode) }
        var item: TrashedItem {
            TrashedItem(original: URL(fileURLWithPath: original), inTrash: URL(fileURLWithPath: trashed), size: size,
                        folder: folder, volume: volume)
        }
        var moduleName: String { module ?? "Command Line" }
        /// The item is still at its place in the Trash.
        var isInTrash: Bool { SafeRemoval.FileID(URL(fileURLWithPath: trashed)) == id }

        /// `url` names this record's place in the Trash, as printed or with its symlinks resolved.
        func matches(_ url: URL) -> Bool {
            let path = url.standardizedFileURL.path
            if path == URL(fileURLWithPath: trashed).standardizedFileURL.path { return true }
            guard let real = HeadlessFiles.realPath(path) else { return false }
            return real == HeadlessFiles.realPath(trashed)
        }
    }

    /// At most this many records; the oldest go first.
    static let limit = 1_000

    /// `~/Library/Application Support/CleanMate/trashed.json` of `home`.
    static func url(home: URL) -> URL {
        home.appending(path: "Library/Application Support/CleanMate/trashed.json")
    }

    /// Keeps a record of each item moved, logged under `module` and `logName` (the activity log's item column: the
    /// path, or Smart Scan's item name). Items whose place in the Trash macOS did not say are left out. Never under a
    /// test host for the real home (like `ActivityLog`).
    static func add(_ items: [TrashedItem], module: LocalizedStringResource, home: URL, date: Date = .now,
                    logName: (URL) -> String = { $0.path }) {
        guard !items.isEmpty, !ActivityLog.writesRealLogInTests(home) else { return }
        let english = ActivityLog.english(module)
        let records = items.compactMap { item in
            SafeRemoval.FileID(item.inTrash).map { id in
                let name = logName(item.original)
                return Record(item, id: id, date: date, module: english, logItem: name == item.original.path ? nil : name)
            }
        }
        if !records.isEmpty { update(home: home) { $0 += records } }
    }

    /// The records of `home` whose item is still in the Trash, oldest first. Read-only: never creates or rewrites the
    /// file (a shared lock, so a write in progress is not read half-done).
    static func inTrash(home: URL) -> [Record] {
        let fd = open(url(home: home).path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        guard flock(fd, LOCK_SH) == 0 else { return [] }
        defer { flock(fd, LOCK_UN) }
        let data = (try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd()) ?? Data()
        return ((try? JSONDecoder().decode([Record].self, from: data)) ?? []).filter(\.isInTrash)
    }

    /// Reads, changes and writes the records under an exclusive lock, so two runs at once keep both changes. Records
    /// of items no longer in the Trash are dropped. An unreadable file counts as empty; a write error loses nothing else.
    /// `create` false: no file is made when there is none (`change` sees no records).
    static func update(home: URL, create: Bool = true, _ change: (inout [Record]) -> Void) {
        let url = url(home: home)
        if create {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let fd = open(url.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW | (create ? O_CREAT : 0), 0o600)
        guard fd >= 0 else {
            var none: [Record] = []
            change(&none)
            return
        }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { return }
        defer { flock(fd, LOCK_UN) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = (try? handle.readToEnd()) ?? Data()
        var records = (try? JSONDecoder().decode([Record].self, from: data)) ?? []
        change(&records)
        records.removeAll { !$0.isInTrash }
        records = Array(records.suffix(limit))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let out = try? encoder.encode(records) else { return }
        guard ftruncate(fd, 0) == 0, lseek(fd, 0, SEEK_SET) == 0 else { return }
        try? handle.write(contentsOf: out)
    }
}
