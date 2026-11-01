import Foundation

/// Local caches of cloud sync apps: Google Drive (DriveFS), Dropbox and OneDrive. Their content caches often take
/// GBs Finder doesn't show, and each app downloads again what it needs, so they are deleted (regenerable), unticked,
/// never while the app runs and never a file a process has open. Never the synced files, sign-ins, settings nor the
/// apps' metadata databases (`DriveFS/<account>/metadata_sqlite_db`, `~/.dropbox/instance*/*.dbx`).
nonisolated enum CloudSyncCaches {
    // MARK: Google Drive

    static let driveFolder = "~/Library/Application Support/Google/DriveFS"
    /// The app and its helpers / File Provider extension (`com.google.drivefs.fpext`).
    static let driveBundleIDs = ["com.google.drivefs*"]
    static let driveProcessNames = ["Google Drive*"]
    /// Cache and log entries changed within this time are kept: 7 days.
    static let driveMinAge: TimeInterval = 7 * 86_400

    /// `content_cache` of each signed-in account (`DriveFS/<account id>/`) and DriveFS's logs; the account folder's
    /// databases and settings stay. Files made available offline are downloaded again when opened. A file not uploaded
    /// yet may only exist in the cache (Drive warns about pending uploads when quit), so only entries nothing inside
    /// changed for `driveMinAge` are listed (a pending upload is recent), and the note asks to let uploads finish.
    static let googleDrive = CleanerItem(
        id: "google-drive-cache", title: "Google Drive cache",
        note: "Files available offline are downloaded again when opened. Quit Google Drive only after it finishes uploading",
        paths: [driveFolder + "/*/content_cache", driveFolder + "/Logs"], minAge: driveMinAge, selectedByDefault: false,
        showsWhenEmpty: false, runningAppBundleIDs: driveBundleIDs, runningProcessNames: driveProcessNames,
        skipsOpenFiles: true)

    // MARK: Dropbox

    static let dropboxBundleIDs = ["com.getdropbox.dropbox*", "com.dropbox.*"]
    static let dropboxProcessNames = ["Dropbox"]
    static let dropboxCacheName = ".dropbox.cache"
    /// Largest `~/.dropbox/info.json` read: real ones hold a few paths.
    static let infoLimit = 64 << 10

    /// `.dropbox.cache` of each Dropbox folder `~/.dropbox/info.json` names (temporary and recently deleted copies
    /// Dropbox clears itself after a few days) and Dropbox's logs. A Dropbox folder in ~/Library/CloudStorage is only
    /// read with Full Disk Access (macOS asks otherwise) and only its `.dropbox.cache` (`allowsDropboxCache`).
    static func dropbox(hasFullDiskAccess: @escaping @Sendable () -> Bool = { FullDiskAccess.isGranted }) -> CleanerItem {
        CleanerItem(id: "dropbox-cache", title: "Dropbox cache",
                    note: "Temporary copies Dropbox makes again when needed; your synced files are kept",
                    paths: ["~/.dropbox/logs"], selectedByDefault: false,
                    configFolders: ConfigFolders(read: { dropboxCaches(home: $0, hasFullDiskAccess: hasFullDiskAccess()) },
                                                 allows: { $0.allowsDropboxCache($1) }),
                    showsWhenEmpty: false, runningAppBundleIDs: dropboxBundleIDs,
                    runningProcessNames: dropboxProcessNames, skipsOpenFiles: true,
                    allowsEntry: { $0.allowsDropboxCache($1) })
    }

    /// `<folder>/.dropbox.cache` for the personal and business folders in `~/.dropbox/info.json`, as written there
    /// (checked later like any configured folder). None without a readable regular file; a folder in a privacy-protected
    /// place (CloudStorage, Documents…) is left out without Full Disk Access.
    static func dropboxCaches(home: URL, hasFullDiskAccess: Bool) -> [String] {
        let path = home.appending(path: ".dropbox/info.json").path
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= infoLimit,
              let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let skipped = ProtectedFolders.skipped(home: home, hasFullDiskAccess: hasFullDiskAccess)
        return ["personal", "business"].compactMap { account -> String? in
            guard let folder = (json[account] as? [String: Any])?["path"] as? String, folder.hasPrefix("/"),
                  !ProtectedFolders.contains(skipped, URL(fileURLWithPath: folder)) else { return nil }
            return folder + "/" + dropboxCacheName
        }
    }

    // MARK: OneDrive

    /// Sandboxed container of the OneDrive app; its Caches are listed here, not under "Sandboxed app caches".
    static let oneDriveContainer = "com.microsoft.OneDrive-mac"
    static let oneDriveBundleIDs = ["com.microsoft.OneDrive*"]
    static let oneDriveProcessNames = ["OneDrive*"]

    /// The updater's logs and the app container's Caches; never the container's settings, the sync engine's
    /// databases nor the synced files (~/Library/CloudStorage). Both folders are privacy-protected: the item is only
    /// in the catalog with Full Disk Access. Caches of in-flight downloads (`keptCaches`) stay.
    static let oneDrive = CleanerItem(id: "onedrive-cache", title: "OneDrive cache & logs",
                    note: "Recreated as needed; your synced files are kept",
                    paths: ["~/Library/Group Containers/UBF8T346G9.OneDriveStandaloneSuite/OneDriveStandaloneUpdater/Logs",
                            "~/Library/Containers/\(oneDriveContainer)/Data/Library/Caches"],
                    excluded: CleanerGroup.keptCaches, selectedByDefault: false, showsWhenEmpty: false,
                    runningAppBundleIDs: oneDriveBundleIDs, runningProcessNames: oneDriveProcessNames, skipsOpenFiles: true)
}
