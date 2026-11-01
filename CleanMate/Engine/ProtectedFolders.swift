import Foundation

/// Home folders guarded by macOS privacy protection (TCC). Without Full Disk Access, listing what is inside one of
/// them makes macOS show an "allow access" dialog — one per folder, so a home-wide walk (Large & Old Files, Space Lens)
/// used to raise a chain of them. Without Full Disk Access these folders are not entered: looking at the folder itself
/// (lstat, its name in the home listing) is fine, only reading its contents prompts.
/// Smart Scan / Privacy touch none of them: their only protected path (Safari's container) fails silently, and
/// Smart Scan's sandboxed app caches (~/Library/Containers) are only in the catalog with Full Disk Access.
nonisolated enum ProtectedFolders {
    /// Relative to the home folder, with why each one prompts.
    static let relativePaths = [
        "Desktop", "Documents", "Downloads",            // Files and Folders
        "Movies", "Music", "Pictures",                  // media folders (Apple Music, Photos libraries)
        "Library/Mobile Documents",                     // iCloud Drive
        "Library/CloudStorage",                         // File Provider apps: Dropbox, Google Drive, OneDrive…
        "Library/Containers", "Library/Group Containers", // "data from other apps" (macOS 14+)
    ]

    /// Absolute paths not to enter: none with Full Disk Access.
    /// shortcut: a folder the user already allowed one by one is skipped too, until Full Disk Access is granted.
    static func skipped(home: URL, hasFullDiskAccess: Bool) -> Set<String> {
        hasFullDiskAccess ? [] : Set(relativePaths.map { home.appending(path: $0).standardizedFileURL.path })
    }

    /// True when walking `folder` passes one of the `skipped` folders (it is inside `folder`).
    static func skips(_ skipped: Set<String>, inside folder: URL) -> Bool {
        let path = folder.standardizedFileURL.path
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return skipped.contains { $0.hasPrefix(prefix) }
    }

    /// True when `folder` is one of the `skipped` folders or inside one: listing it would prompt.
    static func contains(_ skipped: Set<String>, _ folder: URL) -> Bool {
        let path = folder.standardizedFileURL.path
        return skipped.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
}
