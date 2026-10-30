import Foundation

/// VS Code and its forks keep a folder per opened project in `User/workspaceStorage/<hash>`: extension state, search
/// indexes, chat history of Copilot or Cursor. Nothing removes it when the project folder is deleted, so these folders
/// pile up (hundreds of MB to GBs). One entry per folder whose `workspace.json` names a local folder or `.code-workspace`
/// file that no longer exists; unticked, moved to the Trash.
/// Kept: a folder without a readable `workspace.json` (an empty window), a remote or virtual workspace
/// (`vscode-remote://`, `vscode-vfs://`), a path on a drive that is not connected, and, without Full Disk Access, a path
/// in a privacy-protected folder (looking inside one would make macOS ask). `globalStorage`, `History` and settings are
/// never listed: they are outside `workspaceStorage`.
nonisolated enum EditorWorkspaces {
    /// `~/Library/Application Support/<folder>` of each editor, with the name shown in an entry's label.
    static let editors: [(folder: String, name: String)] = [
        ("Code", "VS Code"), ("Code - Insiders", "VS Code Insiders"), ("VSCodium", "VSCodium"),
        ("Cursor", "Cursor"), ("Windsurf", "Windsurf"),
    ]
    static let paths = editors.map { "~/Library/Application Support/\($0.folder)/User/workspaceStorage" }
    /// The editors, and their extension hosts (which write a workspace's state while it is open).
    static let bundleIDs = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium",
                            "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf"]
    static let processNames = ["Code", "Code - Insiders", "VSCodium", "Cursor", "Windsurf"].map { $0 + " Helper (Plugin)" }
    static let workspaceFile = "workspace.json"
    /// Largest `workspace.json` read: real ones hold one short URI.
    static let fileLimit = 64 << 10

    /// The Smart Scan item. `home` and `hasFullDiskAccess` are injected by tests; `volumesFolder` is where drives mount.
    static func item(home: URL = URL(fileURLWithPath: NSHomeDirectory()),
                     hasFullDiskAccess: @escaping @Sendable () -> Bool = { FullDiskAccess.isGranted },
                     volumesFolder: String = "/Volumes") -> CleanerItem {
        CleanerItem(id: "vscode-stale-workspaces", title: "Code editors: data of deleted projects",
                    note: "VS Code, Cursor, Windsurf and VSCodium data for project folders that no longer exist. Moved to the Trash",
                    paths: paths, mode: .trash, selectedByDefault: false, showsWhenEmpty: false,
                    runningAppBundleIDs: bundleIDs, runningProcessNames: processNames, skipsOpenFiles: true,
                    skipsEntry: {
                        let skipped = ProtectedFolders.skipped(home: home, hasFullDiskAccess: hasFullDiskAccess())
                        return { !isOrphaned($0, skipped: skipped, volumesFolder: volumesFolder) }
                    },
                    entryLabel: label(of:), selectableEntries: true)
    }

    /// The local project `entry` was opened for: a folder or a `.code-workspace` file. nil when there is none: no
    /// readable `workspace.json`, a remote or virtual workspace, a URI that is not an absolute `file://` path.
    static func project(of entry: URL) -> String? {
        let path = entry.appending(path: workspaceFile).path
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= fileLimit,
              let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uri = (json["folder"] ?? json["workspace"]) as? String,
              let url = URL(string: uri), url.scheme?.lowercased() == "file",
              url.host.map({ $0.isEmpty || $0 == "localhost" }) ?? true else { return nil }
        let project = url.path
        return project.hasPrefix("/") && project != "/" ? project : nil
    }

    /// `entry` is a real folder whose project is gone for sure: the path does not exist (ENOENT, not a permission
    /// error), is not on a drive that is not connected, and is not in a `skipped` protected folder.
    static func isOrphaned(_ entry: URL, skipped: Set<String>, volumesFolder: String = "/Volumes") -> Bool {
        var info = stat()
        guard lstat(entry.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              let project = project(of: entry),
              !ProtectedFolders.contains(skipped, URL(fileURLWithPath: project)) else { return false }
        let volumes = volumesFolder.hasSuffix("/") ? volumesFolder : volumesFolder + "/"
        if project.hasPrefix(volumes) {
            // `/Volumes/<drive>/…`: an unplugged drive is not a deleted project.
            guard let drive = project.dropFirst(volumes.count).split(separator: "/").first,
                  lstat(volumes + drive, &info) == 0 else { return false }
        }
        errno = 0
        return lstat(project, &info) != 0 && errno == ENOENT
    }

    /// `<project> — <editor>`, dated by when the editor last saved the workspace's state.
    static func label(of entry: URL) -> (title: String, date: Date?)? {
        guard let project = project(of: entry) else { return nil }
        let support = entry.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let editor = editors.first { $0.folder == support.lastPathComponent }?.name ?? support.lastPathComponent
        let state = entry.appending(path: "state.vscdb")
        let date = [state, entry].lazy
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.first
        return ((project as NSString).lastPathComponent + " — " + editor, date)
    }
}
