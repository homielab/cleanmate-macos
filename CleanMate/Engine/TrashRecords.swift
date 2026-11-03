import Foundation

/// What CleanMate moved to the Trash, kept in `~/Library/Application Support/CleanMate/trashed.json` so that
/// `cleanmate restore` can list it and put it back after CleanMate quit: every move of the app and the command line
/// that "Undo" could put back (Large & Old Files, Space Lens, the Uninstaller, Smart Scan items that go to the Trash,
/// Login Items, `cleanmate trash`). Only the record is kept, never the item: an entry goes once its item is no longer in the Trash.
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
        /// the same name and `ActivityLog.freed` takes back what that move added. nil: a record written before modules were
        /// kept (shown as "unknown", logged back as "Command Line"), and `original`.
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
        /// The module the move was logged under; an older record without one is put back under "Command Line", the
        /// only thing that wrote records then.
        var moduleName: String { module ?? "Command Line" }
        /// What moved it, as listed: "unknown" for an older record without a module (never guessed).
        var source: String { module ?? "unknown" }
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

    /// Why a record's item was or wasn't put back by `putBack`.
    enum PutBack: Sendable, Equatable {
        case restored
        /// Emptied from the Trash, put back in Finder, or something else at its place in the Trash now.
        case notInTrash
        /// The old folder is a symlink now: never followed.
        case folderIsSymlink
        /// Something is at the old place: never overwritten.
        case occupied
        /// The old folder is gone, leads elsewhere now or is on another volume.
        case folderChanged
        case failed

        /// The record goes: its item is back or no longer in the Trash. Otherwise it stays, to try again later.
        var dropsRecord: Bool { self == .restored || self == .notInTrash }

        /// Why it was not put back, in English for the command line; nil when it was.
        var reason: String? {
            switch self {
            case .restored: nil
            case .notInTrash: "Not in the Trash any more"
            case .folderIsSymlink: "Its folder is a symlink now: nothing was moved"
            case .occupied: "Something is already at its place: nothing was overwritten"
            case .folderChanged: "Its folder was moved, removed or changed: nothing was moved"
            case .failed: "Could not put it back"
            }
        }
    }

    /// Puts `record`'s item back at its old place, only while it is still the item moved (device and inode), its old
    /// folder is not a symlink now, nothing is at the old place and the folder is the same real folder on the same
    /// volume (`TrashUndo.putBack`). Logged "restored" under the module and item its move was logged with, so
    /// `ActivityLog.freed` takes back what that move added. The caller drops the record (`dropsRecord`).
    static func putBack(_ record: Record, home: URL, device: SafetyPolicy.DeviceID = SafetyPolicy.deviceID) -> PutBack {
        guard record.isInTrash else { return .notInTrash }
        var info = stat()
        let folder = URL(fileURLWithPath: record.original).deletingLastPathComponent()
        if lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK { return .folderIsSymlink }
        let module = LocalizedStringResource(String.LocalizationValue(record.moduleName))
        switch TrashUndo.putBack(record.item, module: module, home: home, logName: { record.logItem ?? $0.path }, device: device) {
        case .restored: return .restored
        case .notInTrash: return .notInTrash
        case .occupied: return .occupied
        case .folderChanged: return .folderChanged
        case .failed: return .failed
        }
    }

    /// Puts back the records whose place in the Trash is one of `trashed` (as `inTrash` lists them), in one locked
    /// update of the file: what happened to each path. A path without a record counts as `notInTrash`.
    static func restore(_ trashed: [String], home: URL,
                        device: SafetyPolicy.DeviceID = SafetyPolicy.deviceID) -> [String: PutBack] {
        var outcomes: [String: PutBack] = [:]
        update(home: home, create: false) { records in
            for path in trashed where outcomes[path] == nil {
                guard let index = records.firstIndex(where: { $0.trashed == path }) else {
                    outcomes[path] = .notInTrash
                    continue
                }
                let outcome = putBack(records[index], home: home, device: device)
                outcomes[path] = outcome
                if outcome.dropsRecord { records.remove(at: index) }
            }
        }
        for path in trashed where outcomes[path] == nil { outcomes[path] = .notInTrash }
        return outcomes
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
