import Foundation

/// Downloads a browser or download tool gave up on, left at the top level of ~/Downloads: Chrome, Edge and Brave
/// `.crdownload`, Firefox `.part`, Safari `.download` (a folder), aria2 `.aria2` and qBittorrent `.!qB`. Often several
/// GB (a disk image, a video), and `OldInstallers` and `OldDownloads` deliberately skip them. Each one is an entry,
/// moved to the Trash with the file of the real name Firefox and aria2 keep next to it.
nonisolated enum AbandonedDownloads {
    static let id = "abandoned-downloads"
    static let folder = "~/Downloads"
    /// Untouched (`OldDownloads.lastTouched`) for this many days: a download still running writes to its file.
    static let days = 7
    /// Unfinished-download extensions (any case) of regular files; Safari's `.download` is a folder (`folderExtension`).
    static let fileExtensions = ["crdownload", "part", "aria2", "!qb"]
    static let folderExtension = "download"
    /// Extensions whose download has a file of the real name next to it: Firefox creates it empty when the download
    /// starts (a full one is a file of its own), aria2 writes the data into it and keeps its progress in `.aria2`.
    static let mateExtensions = ["part", "aria2"]

    /// Lowercased extension of `name` after its last dot ("" when none); `URL.pathExtension` leaves out `!qB`.
    static func pathExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    /// Whether `url` is an unfinished download by name and type: a regular file with one of `fileExtensions`, or a
    /// folder named `*.download`. Not a symlink, not hidden, not a bare extension (`.part`).
    static func isUnfinished(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let ext = pathExtension(name)
        guard !name.hasPrefix("."), !ext.isEmpty, name.count > ext.count + 1 else { return false }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        switch info.st_mode & S_IFMT {
        case S_IFREG: return fileExtensions.contains(ext)
        case S_IFDIR: return ext == folderExtension
        default: return false
        }
    }

    /// The file of the real name that goes with `url`: `movie.mkv` next to `movie.mkv.part` (only when empty) or
    /// `movie.mkv.aria2` (any size). A regular file, never a symlink, a folder or a hidden name; nil when none.
    static func mate(of url: URL) -> URL? {
        let name = url.lastPathComponent
        let ext = pathExtension(name)
        guard mateExtensions.contains(ext) else { return nil }
        let base = String(name.dropLast(ext.count + 1))
        guard !base.isEmpty, !base.hasPrefix(".") else { return nil }
        let mate = url.deletingLastPathComponent().appending(path: base)
        var info = stat()
        guard lstat(mate.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return ext == "aria2" || info.st_size == 0 ? mate : nil
    }

    /// The per-entry check of one scan or one removal: true keeps `url`: not an unfinished download, or it or its
    /// mate touched (`OldDownloads.lastTouched`: modified, created, added, opened, read) within `days` of `now`, or
    /// of unknown age.
    static func skips(now: Date = .now) -> @Sendable (URL) -> Bool {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return { url in
            guard isUnfinished(url), let touched = lastTouched(url) else { return true }
            return touched >= cutoff
        }
    }

    /// The newest `OldDownloads.lastTouched` of `url` and its mate; nil when either is unknown.
    static func lastTouched(_ url: URL) -> Date? {
        guard let touched = OldDownloads.lastTouched(url) else { return nil }
        guard let mate = mate(of: url) else { return touched }
        return OldDownloads.lastTouched(mate).map { max(touched, $0) }
    }

    /// Name and last-touched date (of the download and its mate) shown in the entry's row.
    static func label(of url: URL) -> (title: String, date: Date?)? {
        (url.lastPathComponent, lastTouched(url))
    }

    /// The mate moved along with the entry (`CleanerItem.entryFiles`).
    @Sendable static func files(of url: URL) -> EntryFiles {
        EntryFiles(own: mate(of: url).map { [$0] } ?? [])
    }

    /// `SafetyPolicy.allowsOldDownload` for the entry and its mate: a mate in Exclusions keeps both.
    static func allows(_ url: URL, policy: SafetyPolicy) -> Bool {
        policy.allowsOldDownload(url) && mate(of: url).map(policy.allowsOldDownload) != false
    }

    /// The Smart Scan item: unticked, one checkbox each, to the Trash, never open (still downloading).
    static func item() -> CleanerItem {
        CleanerItem(id: id, title: "Abandoned downloads",
                    note: "Unfinished downloads (.crdownload, .part, .download, .aria2, .!qB) in Downloads not modified or opened for 7 days. Moved to the Trash",
                    paths: [folder], minAge: Double(days) * 86_400, mode: .trash, selectedByDefault: false,
                    showsWhenEmpty: false, skipsOpenFiles: true, skipsEntry: { skips() },
                    entryLabel: label(of:), selectableEntries: true, entryFiles: files(of:),
                    allowsEntry: { allows($1, policy: $0) })
    }
}
