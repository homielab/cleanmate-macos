import Foundation

/// What CleanMate moved to the Trash, kept in `~/Library/Application Support/CleanMate/trashed.json` so that
/// `cleanmate restore` can list it and put it back after CleanMate quit: every move of the app and the command line
/// that "Undo" could put back (Large & Old Files, Space Lens, the Uninstaller, Smart Scan items that go to the Trash,
/// Login Items, `cleanmate trash`). Only the record is kept, never the item: an entry goes once its item is no longer in the Trash.
/// Records are kept by run (one Move to Trash, clean or uninstall): a run is kept whole or dropped whole, so "Put Back"
/// never finds only the end of a big move. A file that can't be read is set aside, never overwritten.
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
        /// The move it was part of (`TrashRun`): the records of one run are kept or dropped together. nil: a record
        /// written before runs were kept, grouped by its date instead.
        var run: String?

        init(_ item: TrashedItem, id: SafeRemoval.FileID, date: Date = .now, module: String? = nil, logItem: String? = nil,
             run: String? = nil) {
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
            self.run = run
        }

        /// The run it is kept with: its run, else its date (an older record: one move wrote one date), else none.
        var runKey: String { run ?? date ?? "" }

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

    /// The records of at most this many runs are kept, newest first…
    static let runLimit = 20
    /// …and no more records than this, unless the newest run alone has more: it is still kept whole.
    static let recordLimit = 20_000

    /// What is kept of `records` (oldest first): whole runs, newest first, until `runLimit` runs or `recordLimit`
    /// records; the newest run is always kept whole. Records keep their order; a run is never cut.
    static func kept(_ records: [Record], runLimit: Int = runLimit, recordLimit: Int = recordLimit) -> [Record] {
        var counts: [String: Int] = [:]
        var newestFirst: [String] = []
        for record in records.reversed() {
            if counts[record.runKey] == nil { newestFirst.append(record.runKey) }
            counts[record.runKey, default: 0] += 1
        }
        var keep = Set<String>()
        var total = 0
        for run in newestFirst {
            let count = counts[run] ?? 0
            guard keep.count < runLimit, keep.isEmpty || total + count <= recordLimit else { break }
            keep.insert(run)
            total += count
        }
        return keep.count == newestFirst.count ? records : records.filter { keep.contains($0.runKey) }
    }

    /// `~/Library/Application Support/CleanMate/trashed.json` of `home`.
    static func url(home: URL) -> URL {
        home.appending(path: "Library/Application Support/CleanMate/trashed.json")
    }

    /// Keeps a record of each item moved, logged under `module` and `logName` (the activity log's item column: the
    /// path, or Smart Scan's item name). Items whose place in the Trash macOS did not say are left out. Never under a
    /// test host for the real home (like `ActivityLog`).
    /// `run`: the move they belong to (`TrashRun`); one clean or uninstall adding records in several calls passes one.
    static func add(_ items: [TrashedItem], module: LocalizedStringResource, home: URL, date: Date = .now,
                    run: String = TrashRun.currentID, logName: (URL) -> String = { $0.path }) {
        guard !items.isEmpty, !ActivityLog.writesRealLogInTests(home) else { return }
        let english = ActivityLog.english(module)
        let records = items.compactMap { item in
            SafeRemoval.FileID(item.inTrash).map { id in
                let name = logName(item.original)
                return Record(item, id: id, date: date, module: english, logItem: name == item.original.path ? nil : name,
                              run: run)
            }
        }
        if !records.isEmpty { update(home: home) { $0 += records } }
    }

    /// The records of `home` whose item is still in the Trash, oldest first. Never creates or rewrites the file (a
    /// shared lock, so a write in progress is not read half-done); one that can't be read is set aside (`setAside`).
    static func inTrash(home: URL) -> [Record] {
        let url = url(home: home)
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        guard flock(fd, LOCK_SH) == 0 else { return [] }
        let data = (try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd()) ?? Data()
        if let records = decode(data) {
            flock(fd, LOCK_UN)
            return records.filter(\.isInTrash)
        }
        // Unreadable: set aside under an exclusive lock, still this file and still unreadable (another run may have
        // set it aside meanwhile). Upgrading drops the shared lock, so it is read again.
        if flock(fd, LOCK_EX) == 0, isFile(fd, at: url), lseek(fd, 0, SEEK_SET) == 0,
           decode((try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd()) ?? Data()) == nil {
            setAside(url)
        }
        flock(fd, LOCK_UN)
        return []
    }

    /// The records in `data`; an empty file has none. nil: not a list of records (damaged, cut short, edited by hand).
    static func decode(_ data: Data) -> [Record]? {
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [] }
        return try? JSONDecoder().decode([Record].self, from: data)
    }

    /// `fd` is still the file at `url` (not set aside or replaced while waiting for its lock).
    private static func isFile(_ fd: Int32, at url: URL) -> Bool {
        var open = stat(), current = stat()
        return fstat(fd, &open) == 0 && lstat(url.path, &current) == 0
            && open.st_dev == current.st_dev && open.st_ino == current.st_ino
    }

    /// Prefix of a records file that couldn't be read, set aside next to it: `trashed.json.broken-<date>`.
    static let brokenPrefix = "trashed.json.broken-"

    /// Renames the unreadable records file to `trashed.json.broken-<yyyy-MM-dd>` (`-2`, `-3`… when taken), so a new
    /// one starts and the old one is kept for the user to look at. Its items stay in the Trash: Finder still puts
    /// them back. The caller holds the file's lock.
    @discardableResult static func setAside(_ url: URL, date: Date = .now) -> URL? {
        let day = Date.ISO8601FormatStyle(timeZone: .current).year().month().day().format(date)
        let folder = url.deletingLastPathComponent()
        for attempt in 1...100 {
            let target = folder.appending(path: brokenPrefix + day + (attempt == 1 ? "" : "-\(attempt)"))
            var info = stat()
            guard lstat(target.path, &info) != 0 else { continue }
            if rename(url.path, target.path) == 0 { return target }
            return nil
        }
        return nil
    }

    /// The records files set aside because they couldn't be read (`setAside`), newest first.
    static func broken(home: URL) -> [URL] {
        let folder = url(home: home).deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasPrefix(brokenPrefix) }
            .map { folder.appending(path: $0) }
            .sorted { setAsideDate($0) > setAsideDate($1) }
    }

    /// When `url` was set aside (its status change: a rename sets it).
    static func setAsideDate(_ url: URL) -> Date {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return .distantPast }
        return Date(timeIntervalSince1970: Double(info.st_ctimespec.tv_sec))
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
    /// of items no longer in the Trash are dropped, then whole runs beyond the limits (`kept`). An unreadable file is
    /// set aside (`setAside`) and a new one started, never overwritten; a write error loses nothing else.
    /// `create` false: no file is made when there is none (`change` sees no records).
    static func update(home: URL, create: Bool = true, _ change: (inout [Record]) -> Void) {
        let url = url(home: home)
        if create {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        // A file set aside or replaced while this waited for its lock is let go and the new one opened: at most twice
        // (set aside, then a new one made by another run).
        for _ in 0..<3 {
            let fd = open(url.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW | (create ? O_CREAT : 0), 0o600)
            guard fd >= 0 else { break }
            defer { close(fd) }
            guard flock(fd, LOCK_EX) == 0 else { return }
            defer { flock(fd, LOCK_UN) }
            guard isFile(fd, at: url) else { continue }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            guard var records = decode((try? handle.readToEnd()) ?? Data()) else {
                setAside(url)
                continue
            }
            write(&records, change, to: fd, handle: handle)
            return
        }
        var none: [Record] = []
        change(&none)
    }

    private static func write(_ records: inout [Record], _ change: (inout [Record]) -> Void, to fd: Int32,
                              handle: FileHandle) {
        change(&records)
        records.removeAll { !$0.isInTrash }
        records = kept(records)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let out = try? encoder.encode(records) else { return }
        guard ftruncate(fd, 0) == 0, lseek(fd, 0, SEEK_SET) == 0 else { return }
        try? handle.write(contentsOf: out)
    }
}
