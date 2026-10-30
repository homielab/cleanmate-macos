import CoreServices
import Foundation

/// Files and folders at the top level of ~/Downloads that nothing suggests are still used: every date of the entry
/// (and, for a folder, of everything inside) is older than the downloads age. Installers are left to `OldInstallers`,
/// which has its own age, so no file shows in both items.
nonisolated enum OldDownloads {
    static let folder = "~/Downloads"
    /// A folder holding more items than this is kept: its dates are read again right before it is moved, and a tree
    /// that large (a project, a photo library export) deserves a look in Finder rather than a checkbox.
    static let walkLimit = 10_000

    /// The per-entry check of one scan or one removal: true keeps the entry (see `skips(_:cutoff:)`).
    /// `screenshotFolder` (`OldScreenshots.folder`) in Downloads: `OldScreenshots` lists its screenshots (same age),
    /// so this item leaves them out, and keeps the top-level folder holding them.
    static func skips(olderThan days: Int, screenshotFolder: String? = nil, now: Date = .now) -> @Sendable (URL) -> Bool {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let prefix = folder.lowercased() + "/"
        let shots = screenshotFolder.map { $0.lowercased() }
        let inDownloads = shots == folder.lowercased()
        let holder = shots.flatMap { $0.hasPrefix(prefix) ? $0.dropFirst(prefix.count).split(separator: "/").first.map(String.init) : nil }
        return { url in
            skips(url, cutoff: cutoff) || inDownloads && OldScreenshots.isScreenshot(url)
                || holder == url.lastPathComponent.lowercased()
        }
    }

    /// Whether `url` is kept: hidden (`.DS_Store`, `.localized`), a download in progress or next to one, touched at
    /// or after `cutoff` or of unknown age (`lastTouched`), or an installer (`OldInstallers` lists it).
    static func skips(_ url: URL, cutoff: Date) -> Bool {
        guard !url.lastPathComponent.hasPrefix("."), !OldInstallers.isDownloading(url),
              let touched = lastTouched(url), touched < cutoff else { return true }
        return !OldInstallers.skips(url)
    }

    /// Name and last-touched date shown in the entry's row.
    static func label(of url: URL) -> (title: String, date: Date?)? {
        (url.lastPathComponent, lastTouched(url))
    }

    /// The newest date that shows `url` was used: modified, created, added to Downloads, last opened (Finder's "Last
    /// opened", from Spotlight, when it has one) and, for a file, last read (macOS sets the access date on the first
    /// read after a change); for a folder, also modified, created and (files) read for everything inside.
    /// A folder's own access date is left out: listing it (Finder, Spotlight, this scan) sets it.
    /// nil when unknown, which keeps the entry: not a regular file or folder (a symlink), or a folder with an unreadable
    /// item, a socket or pipe (a running process), another volume or more than `limit` items inside (the folder counts).
    static func lastTouched(_ url: URL, limit: Int = walkLimit) -> Date? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        let type = info.st_mode & S_IFMT
        guard type == S_IFREG || type == S_IFDIR, var newest = touched(info) else { return nil }
        if let added = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate {
            newest = max(newest, added)
        }
        if let opened = lastOpened(url) { newest = max(newest, opened) }
        guard type == S_IFDIR else { return newest }
        guard let inside = newestInside(url.path, device: info.st_dev, limit: limit) else { return nil }
        return max(newest, inside)
    }

    /// Modified and created dates, and the access date of a regular file; nil for a socket or pipe.
    private static func touched(_ info: stat) -> Date? {
        let type = info.st_mode & S_IFMT
        guard type != S_IFSOCK, type != S_IFIFO else { return nil }
        var times = [info.st_mtimespec, info.st_birthtimespec]
        if type == S_IFREG { times.append(info.st_atimespec) }
        return times.map { Date(timeIntervalSince1970: Double($0.tv_sec) + 1.0e-9 * Double($0.tv_nsec)) }.max()
    }

    /// Spotlight's last-used date (set when the file is opened from Finder or with `open`), nil when it has none.
    private static func lastOpened(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, "kMDItemLastUsedDate" as CFString) as? Date
    }

    /// Newest `touched` date of everything below the folder `path`, nil when one is unknown (see `lastTouched`).
    private static func newestInside(_ path: String, device: dev_t, limit: Int) -> Date? {
        guard let stream = path.withCString({ path -> UnsafeMutablePointer<FTS>? in
            var paths: [UnsafeMutablePointer<CChar>?] = [UnsafeMutablePointer(mutating: path), nil]
            return fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil)
        }) else { return nil }
        defer { fts_close(stream) }
        var newest = Date.distantPast
        var count = 0
        while let entry = fts_read(stream) {
            switch Int32(entry.pointee.fts_info) {
            case FTS_DP: continue // seen at its FTS_D
            case FTS_D, FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT: break
            default: return nil // unreadable folder, stat error, cycle
            }
            count += 1
            guard count <= limit, let info = entry.pointee.fts_statp?.pointee, info.st_dev == device,
                  let date = touched(info) else { return nil }
            newest = max(newest, date)
        }
        return newest
    }
}
