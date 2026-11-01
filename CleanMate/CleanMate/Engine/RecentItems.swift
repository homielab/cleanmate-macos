import AppKit

/// The Recent Items lists macOS keeps in `~/Library/Application Support/com.apple.sharedfilelist`: the Apple menu's
/// recent applications, documents and servers (`com.apple.LSSharedFileList.Recent*.sfl*`) and each app's Open Recent
/// menu (`com.apple.LSSharedFileList.ApplicationRecentDocuments/<bundle id>.sfl*`, the bundle id lowercased). Removed
/// files are recreated empty by macOS. One entry per list, named after it or its app; an app that is open keeps its
/// list (it writes it back when it quits). The Finder sidebar lists beside them (FavoriteItems, FavoriteVolumes,
/// iCloudItems, ProjectsItems, NetworkBrowser…) are the user's own and never listed.
nonisolated enum RecentItems {
    static let id = "recent-items"
    static let folderName = "com.apple.sharedfilelist"
    static let appFolderName = "com.apple.LSSharedFileList.ApplicationRecentDocuments"
    static let folder = "~/Library/Application Support/" + folderName
    /// `.sfl2` (macOS 10.13), `.sfl3` (macOS 13), `.sfl4` (macOS 26) and later formats.
    static let fileNames = ["*.sfl[0-9]"]
    static let systemListPrefix = "com.apple.LSSharedFileList.Recent"

    /// `runningApps`: bundle ids of the open apps, read once per scan and again before each removal.
    static func item(runningApps: @escaping @Sendable () -> Set<String> = { [] },
                     appURL: @escaping @Sendable (String) -> URL? = {
                         NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
                     }) -> CleanerItem {
        CleanerItem(id: id, title: "Recent items",
                    note: "Recent documents, apps and servers in the Apple menu and each app's Open Recent menu. Skips apps that are open",
                    paths: [folder, folder + "/" + appFolderName], included: fileNames, selectedByDefault: false,
                    showsWhenEmpty: false,
                    skipsEntry: {
                        let apps = Set(runningApps().map { $0.lowercased() })
                        return { skips($0, runningApps: apps) }
                    },
                    entryLabel: { label(of: $0, appURL: appURL) }, selectableEntries: true,
                    allowsEntry: { policy, url in isRecentList(url) && policy.allows(url) })
    }

    /// Whether `url` is a recent items list: a regular `*.sfl<N>` file directly in the shared file list folder whose
    /// name starts with `com.apple.LSSharedFileList.Recent`, or any one directly in its per-app folder.
    static func isRecentList(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard fileNames.contains(where: { fnmatch($0, name, 0) == 0 }) else { return false }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return false }
        let parent = url.deletingLastPathComponent()
        switch parent.lastPathComponent {
        case folderName: return name.hasPrefix(systemListPrefix)
        case appFolderName: return parent.deletingLastPathComponent().lastPathComponent == folderName
        default: return false
        }
    }

    /// The bundle id an app's list is named after (lowercased), nil for the Apple menu's lists.
    static func bundleID(of url: URL) -> String? {
        guard url.deletingLastPathComponent().lastPathComponent == appFolderName else { return nil }
        return url.deletingPathExtension().lastPathComponent.lowercased()
    }

    /// Whether an app's list must be kept: that app, or the app a helper `<id>.*` belongs to, is open.
    /// `runningApps` lowercased.
    static func skips(_ url: URL, runningApps: Set<String>) -> Bool {
        guard let id = bundleID(of: url) else { return false }
        return runningApps.contains { AppMatcher.belongs(id, to: $0) }
    }

    /// The app's name (its bundle id when it is not installed) or the Apple menu list's name, and when it last changed.
    static func label(of url: URL, appURL: (String) -> URL?) -> (title: String, date: Date?)? {
        let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if let id = bundleID(of: url) {
            let name = appURL(id).map { FileManager.default.displayName(atPath: $0.path) }
                .map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 }
            return (name ?? id, date)
        }
        let list = url.deletingPathExtension().lastPathComponent.dropFirst(systemListPrefix.count)
        let title: String
        switch list {
        case "Applications": title = String(localized: "Recent applications")
        case "Documents": title = String(localized: "Recent documents")
        case "Servers": title = String(localized: "Recent servers")
        case "Hosts": title = String(localized: "Recent network hosts")
        default: return nil
        }
        return (title, date)
    }
}
