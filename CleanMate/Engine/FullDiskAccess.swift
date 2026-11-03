import Foundation

/// Full Disk Access of this process: the app's own, or for the command line tool the one of the app that runs it
/// (Terminal, an AI agent's app), since macOS checks the process responsible for the tool.
enum FullDiskAccess {
    private nonisolated static let known = Locked<Bool?>(nil)

    /// The last answer of `refresh()`, probed once on first use. The app refreshes it in the background each time it
    /// becomes active (`FullDiskAccessStatus`), so views and scans never touch the disk to read it.
    nonisolated static var isGranted: Bool {
        if let granted = known.withLock({ $0 }) { return granted }
        return refresh()
    }

    /// Probes again and remembers the answer.
    @discardableResult
    nonisolated static func refresh() -> Bool {
        let granted = probe()
        known.withLock { $0 = granted }
        return granted
    }

    /// ~/.Trash is only readable with Full Disk Access on recent macOS. One `opendir` and one `readdir` (the first
    /// block of entries: "." at least when readable), never a listing: a Trash of 50,000 files costs the same as an
    /// empty one.
    nonisolated static func probe(trash: String = NSHomeDirectory() + "/.Trash") -> Bool {
        guard let folder = opendir(trash) else { return false }
        defer { closedir(folder) }
        return readdir(folder) != nil
    }
}
