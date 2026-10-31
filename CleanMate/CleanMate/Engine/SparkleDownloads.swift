import AppKit

/// Updates downloaded by apps that update themselves with Sparkle: each keeps them in
/// `~/Library/Caches/<bundle id>/org.sparkle-project.Sparkle` (the downloaded archive, the extracted copy and the
/// installer), left behind once the update is installed, downloaded again when needed. One entry per app, named
/// after it, deleted (regenerable). An app that is open keeps its folder (an update waiting to be installed when it
/// quits); so does an app whose cache folder another item lists already (OrbStack), and CleanMate's own while it is
/// updating. Never while Sparkle's installer runs, nor a folder holding a file a process has open.
nonisolated enum SparkleDownloads {
    static let id = "sparkle-downloads"
    static let folderName = "org.sparkle-project.Sparkle"
    /// Kept out of "User caches", which would count these folders a second time.
    static let cachePattern = "*/" + folderName
    /// Sparkle's installer (`Autoupdate`) and its progress window (`Updater.app`), run from the folder while installing.
    static let processNames = ["Autoupdate", "Updater"]
    static let ownBundleID = Bundle.main.bundleIdentifier ?? "com.homielab.CleanMate"

    /// `runningApps`: bundle ids of the open apps; `isUpdating`: whether CleanMate is downloading or installing an
    /// update of itself (`AppUpdater.isUpdating`). Both are read once per scan and again before each removal.
    static func item(runningApps: @escaping @Sendable () -> Set<String> = { [] },
                     isUpdating: @escaping @Sendable () -> Bool = { false },
                     appURL: @escaping @Sendable (String) -> URL? = {
                         NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
                     }) -> CleanerItem {
        CleanerItem(id: id, title: "Downloaded app updates",
                    note: "Updates apps downloaded to install themselves; downloaded again if needed. Skips apps that are open",
                    paths: ["~/Library/Caches"], showsWhenEmpty: false, runningProcessNames: processNames,
                    skipsOpenFiles: true,
                    skipsEntry: {
                        let apps = runningApps(), updating = isUpdating()
                        return { skips($0, runningApps: apps, isUpdating: updating) }
                    },
                    entryLabel: { label(of: $0, appURL: appURL) },
                    findEntries: { roots, _ in roots.flatMap(find) },
                    // An app's cache folder left empty goes too (`rmdir` only).
                    removesEmptyParents: 1)
    }

    /// `<root>/<folder>/org.sparkle-project.Sparkle` for each non-hidden folder of `root`; real folders only, no symlink.
    static func find(in root: URL) -> [URL] {
        let children = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return children.filter { !$0.lastPathComponent.hasPrefix(".") && isFolder($0) }
            .map { $0.appending(path: folderName) }.filter(isFolder)
    }

    /// Whether the Sparkle folder `url` (`…/<bundle id>/org.sparkle-project.Sparkle`) must be kept: its app is open (a
    /// helper `<id>.*` of an open app too), it is Apple's, another item lists its app's cache folder, or it is
    /// CleanMate's own while CleanMate updates (CleanMate is always open, so that is the only check for it).
    static func skips(_ url: URL, runningApps: Set<String>, isUpdating: Bool) -> Bool {
        guard url.lastPathComponent == folderName else { return true }
        let bundle = url.deletingLastPathComponent().lastPathComponent
        if bundle.lowercased() == ownBundleID.lowercased() { return isUpdating }
        if SafetyPolicy.isApple(bundle) || CleanerGroup.ownedCachePaths.contains(bundle)
            || CleanerGroup.ownedCachePaths.contains(bundle + "/" + folderName) { return true }
        let id = bundle.lowercased()
        return runningApps.contains { AppMatcher.belongs(id, to: $0) }
    }

    /// The app's name (its bundle id when it is not installed any more) and when the folder last changed.
    static func label(of url: URL, appURL: (String) -> URL?) -> (title: String, date: Date?)? {
        let bundle = url.deletingLastPathComponent().lastPathComponent
        let name = appURL(bundle).map { FileManager.default.displayName(atPath: $0.path) }
            .map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 }
        let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return (name ?? bundle, date)
    }

    private static func isFolder(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }
}
