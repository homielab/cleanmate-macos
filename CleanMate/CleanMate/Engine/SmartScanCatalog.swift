import AppKit

extension CleanerGroup {
    /// Smart Scan with the age thresholds set in Settings, the current Full Disk Access state and running apps.
    nonisolated static var smartScan: [CleanerGroup] {
        // NSWorkspace documents `runningApplications` as safe to read from any thread.
        smartScan(ages: .current, hasFullDiskAccess: FullDiskAccess.isGranted, screenshotFolder: OldScreenshots.folder(),
                  runningAppNames: {
            Set(NSWorkspace.shared.runningApplications.flatMap { app in
                [app.localizedName, app.bundleURL?.deletingPathExtension().lastPathComponent].compactMap { $0 }
            })
        }) {
            Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        }
    }

    /// Smart Scan: user-account junk that apps recreate on demand.
    /// Without Full Disk Access nothing in ~/Library/Containers or Group Containers is listed: reading it would make macOS ask.
    /// `runningApps` is read once per scan of the user, sandboxed, group cache and temp items, and again right
    /// before removing each of their entries. `runningAppNames` (display and .app file names) is read with it for
    /// user caches only: sandboxed and group caches are named by bundle/group id, never by app name.
    /// `screenshotFolder`: where screenshots are saved (`OldScreenshots.folder`), Desktop unless given.
    nonisolated static func smartScan(ages: CleanupAges, hasFullDiskAccess: Bool = false,
                                      screenshotFolder: String? = OldScreenshots.defaultFolder,
                                      runningAppNames: @escaping @Sendable () -> Set<String> = { [] },
                                      runningApps: @escaping @Sendable () -> Set<String> = { [] }) -> [CleanerGroup] { [
        CleanerGroup(id: "system-junk", title: "System Junk", systemImage: "internaldrive", items: [
            // A running app's cache folder (by bundle id, helpers `<id>.*` included; or by app name) is kept,
            // and so is one holding a file any process has open (a CLI daemon, a helper).
            CleanerItem(id: "user-caches", title: "User caches", note: "Skips caches of apps that are open",
                        paths: ["~/Library/Caches"], excluded: keptCaches.union(ownedCachePaths).union(notCaches),
                        skipsOpenFiles: true, skipsEntry: {
                            let apps = runningApps()
                            let names = Set(runningAppNames().filter(AppMatcher.isDistinctive).map { $0.lowercased() })
                            return { skipsUserCache($0, runningApps: apps, runningAppNames: names) }
                        }),
        ] + (hasFullDiskAccess ? [
            // Only `Data/Library/Caches` of each container; never Apple's containers nor a running app's
            // (its helpers `<id>.*` included).
            CleanerItem(id: "sandbox-caches", title: "Sandboxed app caches", paths: ["~/Library/Containers/*/Data/Library/Caches"],
                        excluded: keptCaches, showsWhenEmpty: false, skipsEntry: {
                            let apps = runningApps()
                            return { skipsSandboxCache($0, runningApps: apps) }
                        }),
            // Only `Library/Caches` of each app group container; never Apple's nor one whose vendor has an app running.
            CleanerItem(id: "group-caches", title: "App group caches", paths: ["~/Library/Group Containers/*/Library/Caches"],
                        excluded: keptCaches, showsWhenEmpty: false, skipsEntry: {
                            let apps = runningApps()
                            return { skipsGroupCache($0, runningApps: apps) }
                        }),
            // Deliberate exception to "never Apple's containers": only Mail's copies of opened attachments
            // (the originals stay in the messages). Moved to the Trash, unticked, old ones only, never while Mail runs.
            // Needs Full Disk Access like the container itself; the legacy path is listed under the same rule.
            CleanerItem(id: "mail-downloads", title: "Mail attachment copies",
                        note: "Opened attachments not modified for \(ages.logs) days. Moved to the Trash",
                        paths: ["~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads", "~/Library/Mail Downloads"],
                        minAge: Double(ages.logs) * 86_400, mode: .trash, selectedByDefault: false, showsWhenEmpty: false,
                        runningAppBundleIDs: ["com.apple.mail"]),
            // Finder's iPhone/iPad backups: tens of GB each, often of a device long sold. Needs Full Disk Access
            // (MobileSync is privacy-protected). Each backup folder is one entry named by its Info.plist; unticked,
            // to the Trash, never while a backup runs nor one written to in the last hour. Hidden names (.DS_Store) stay.
            CleanerItem(id: "device-backups", title: "iPhone & iPad backups",
                        note: "Backups made by Finder. Moved to the Trash", paths: [MobileBackups.folder],
                        minAge: 3600, mode: .trash, selectedByDefault: false, showsWhenEmpty: false,
                        runningProcessNames: MobileBackups.processNames,
                        skipsEntry: { { $0.lastPathComponent.hasPrefix(".") } },
                        entryLabel: MobileBackups.label(of:), selectableEntries: true),
            // Installers left in Downloads (`OldInstallers`): user files, so unticked, one checkbox each, to the Trash.
            // Only with Full Disk Access: reading ~/Downloads without it makes macOS ask (`ProtectedFolders`).
            // Top-level regular files only, old ones, never open (a mounted image) nor still downloading.
            CleanerItem(id: "old-installers", title: "Old installers",
                        note: "Disk images, packages and zipped apps in Downloads older than \(ages.installers) days. Moved to the Trash",
                        paths: [OldInstallers.folder], minAge: Double(ages.installers) * 86_400,
                        included: OldInstallers.patterns, mode: .trash, selectedByDefault: false, showsWhenEmpty: false,
                        skipsOpenFiles: true, skipsEntry: { OldInstallers.skips }, selectableEntries: true),
            // Everything else at the top level of Downloads (`OldDownloads`) that was neither modified, added nor
            // opened for the downloads age, folders by everything inside them: user files, so unticked, one checkbox
            // each, to the Trash, never open, still downloading or an installer (listed just above).
            CleanerItem(id: "old-downloads", title: "Old downloads",
                        note: "Files and folders in Downloads not modified, added or opened for \(ages.downloads) days. Moved to the Trash",
                        paths: [OldDownloads.folder], minAge: Double(ages.downloads) * 86_400, mode: .trash,
                        selectedByDefault: false, showsWhenEmpty: false, skipsOpenFiles: true,
                        skipsEntry: { [days = ages.downloads] in
                            OldDownloads.skips(olderThan: days, screenshotFolder: screenshotFolder)
                        },
                        entryLabel: OldDownloads.label(of:), selectableEntries: true,
                        allowsEntry: { $0.allowsOldDownload($1) }),
            // Screenshots and screen recordings where macOS saves them (`OldScreenshots`), untouched for the downloads
            // age: user files, so unticked, one checkbox each, to the Trash. Only with Full Disk Access: Desktop is
            // protected like Downloads.
        ] + [OldScreenshots.item(days: ages.downloads, folder: screenshotFolder)].compactMap { $0 } + [
            // Unfinished downloads at the top level of Downloads untouched for 7 days (`AbandonedDownloads`), which the
            // two Downloads items above skip: user files, so unticked, one checkbox each, to the Trash with the file of
            // the real name Firefox and aria2 keep next to them, never open (still downloading).
            AbandonedDownloads.item(),
        ] : []) + [
            // Downloaded iOS/iPadOS updates: only `*.ipsw`, one entry each, unticked (slow to download again),
            // to the Trash, never while Finder or Apple Configurator updates a device. Configurator's cache is a
            // deliberate exception to "never Apple's containers" (like Mail): that one folder, only with FDA.
            CleanerItem(id: "ios-updates", title: "iOS & iPadOS updates",
                        note: "Downloaded by Finder or Apple Configurator, downloaded again when needed. Moved to the Trash",
                        paths: DeviceFirmware.finderFolders + (hasFullDiskAccess ? [DeviceFirmware.configuratorFolder] : []),
                        included: ["*.ipsw"], mode: .trash, selectedByDefault: false, showsWhenEmpty: false,
                        runningAppBundleIDs: [DeviceFirmware.configuratorBundleID],
                        runningProcessNames: DeviceFirmware.processNames, skipsOpenFiles: true, // a download in progress
                        entryLabel: DeviceFirmware.label(of:), selectableEntries: true),
            // "CleanMate": our own activity log (`ActivityLog`) is never cleaned.
            CleanerItem(id: "old-logs", title: "Old logs", note: "Not modified for \(ages.logs) days",
                        paths: ["~/Library/Logs"], minAge: Double(ages.logs) * 86_400,
                        excluded: ["DiagnosticReports", "CleanMate", "JetBrains"]), // JetBrains: "Old IDE versions"
            CleanerItem(id: "crash-reports", title: "Crash reports", paths: ["~/Library/Logs/DiagnosticReports"]),
            // A running app's own folder in $TMPDIR (bundle id or `<id>.*`, e.g. helpers unpacked at launch) is kept.
            // An entry that is, or holds, a file any process has open is kept too, whatever its mtime.
            CleanerItem(id: "temp-files", title: "Old temporary files", note: "Not modified for \(ages.temp) days",
                        paths: ["$TMPDIR"], minAge: Double(ages.temp) * 86_400, skipsOpenFiles: true, skipsEntry: {
                            let apps = runningApps()
                            return { url in
                                let name = url.lastPathComponent.lowercased() // once per entry, not per app
                                return apps.contains { AppMatcher.belongs(name, to: $0) }
                            }
                        }),
        ]),
        developer,
        aiTools(sessionDays: ages.sessions),
        applications(hasFullDiskAccess: hasFullDiskAccess),
        CleanerGroup(id: "trash", title: "Trash", systemImage: "trash", items: [
            // Unticked by default: emptying the Trash cannot be undone.
            CleanerItem(id: "empty-trash", title: "Empty Trash", note: "Permanently deletes everything in the Trash",
                        paths: ["~/.Trash"], selectedByDefault: false),
        ] + (hasFullDiskAccess ? [
            // What was deleted from an external drive stays in that drive's Trash (`ExternalTrash`): one entry per
            // drive, unticked like the Trash above. Only with Full Disk Access: reading a drive without it makes macOS ask.
            CleanerItem(id: "external-trash", title: "Trash on external drives",
                        note: "Permanently deletes everything in the Trash of each ticked drive", paths: [],
                        selectedByDefault: false, showsWhenEmpty: false, skipsOpenFiles: true, selectableEntries: true,
                        externalTrash: true),
        ] : [])),
    ] }

    /// Bundle id of the app owning `…/Containers/<container>/Data/Library/Caches/<entry>`: containermanagerd's
    /// metadata (iOS apps' containers are named by UUID), else the folder name; nil when `url` is not such an entry.
    nonisolated static func containerBundleID(_ url: URL) -> String? {
        let container = url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        guard container.deletingLastPathComponent().lastPathComponent == "Containers" else { return nil }
        let metadata = NSDictionary(contentsOf: container.appending(path: ".com.apple.containermanagerd.metadata.plist"))
        return metadata?["MCMMetadataIdentifier"] as? String ?? container.lastPathComponent
    }

    /// Whether `…/Containers/<container>/Data/Library/Caches/<entry>` must be kept: not such an entry, Apple's, or
    /// its bundle id is a running app's or a helper of one (`com.vendor.app.helper` while `com.vendor.app` runs).
    /// The container of an app item that lists its Caches itself (`CloudSyncCaches.oneDrive`) is kept too: counted once.
    nonisolated static func skipsSandboxCache(_ url: URL, runningApps: Set<String>) -> Bool {
        guard let id = containerBundleID(url) else { return true }
        let container = url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().lastPathComponent
        if ownedContainers.contains(container) || ownedContainers.contains(id) { return true }
        return SafetyPolicy.isApple(id) || runningApps.contains { AppMatcher.belongs(id.lowercased(), to: $0) }
    }

    /// Whether `~/Library/Caches/<folder>[/…]` belongs to a running app: `<folder>` is its bundle id or `<id>.something`
    /// (`com.vendor.app.helper` while `com.vendor.app` runs), or — case-insensitively — one of `runningAppNames`
    /// (lowercased, already filtered by `AppMatcher.isDistinctive`: ≥ 4 characters, not `Google`/`Electron`…).
    nonisolated static func skipsUserCache(_ url: URL, runningApps: Set<String>, runningAppNames: Set<String> = []) -> Bool {
        let parts = url.pathComponents
        guard let i = parts.indices.last(where: { $0 > 0 && parts[$0] == "Caches" && parts[$0 - 1] == "Library" }),
              i + 1 < parts.count else { return false }
        if DeveloperTools.isIDECache(parts[(i + 1)...]) { return true }
        let name = parts[i + 1].lowercased()
        return runningAppNames.contains(name) || runningApps.contains { AppMatcher.belongs(name, to: $0) }
    }

    /// Whether `…/Group Containers/<group>/Library/Caches/<entry>` must be kept: not such an entry, no creator in
    /// containermanagerd's metadata (cannot tell whose it is), Apple's (by id or creator, Shortcuts is `is.workflow`),
    /// or an app of the same vendor is running. Vendor = `com.vendor` of the creator and of the group id without its
    /// `<TEAMID>.`/`group.` prefix: a group is shared by several apps of one vendor (`UBF8T346G9.Office`, created by
    /// Excel, is used by Word and Outlook too), so any running `com.microsoft.*` app keeps it.
    nonisolated static func skipsGroupCache(_ url: URL, runningApps: Set<String>) -> Bool {
        let group = url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard group.deletingLastPathComponent().lastPathComponent == "Group Containers",
              let metadata = NSDictionary(contentsOf: group.appending(path: ".com.apple.containermanagerd.metadata.plist")),
              let creator = metadata["MCMMetadataCreator"] as? String, !creator.isEmpty else { return true }
        let id = AppMatcher.identifier(group.lastPathComponent, in: "Group Containers")
        let vendors = Set([creator.lowercased(), id].filter { $0.contains(".") }.map(AppMatcher.vendor))
        guard !vendors.isEmpty, !SafetyPolicy.isApple(group.lastPathComponent), !SafetyPolicy.isApple(creator),
              vendors.isDisjoint(with: AppMatcher.sharedVendors) else { return true }
        return runningApps.contains { vendors.contains(AppMatcher.vendor($0)) }
    }

    /// Containers whose `Data/Library/Caches` an app item lists, kept out of "Sandboxed app caches".
    nonisolated static let ownedContainers: Set = [CloudSyncCaches.oneDriveContainer]

    /// Not caches though under ~/Library/Caches: Poetry's default virtualenvs (`{cache-dir}/virtualenvs`), one
    /// per project; removing them breaks `poetry run` until `poetry install`. The rest of `pypoetry` is still listed.
    nonisolated static let notCaches: Set<String> = ["pypoetry/virtualenvs"]

    /// Caches holding iCloud/sync state or in-flight downloads: wiping them forces a re-sync or breaks transfers.
    /// rclone: its VFS cache holds files written to a mount but not uploaded yet. TemporaryItems: saves in progress.
    nonisolated static let keptCaches: Set<String> = [
        "rclone", "TemporaryItems",
        "com.apple.bird", "CloudKit", "com.apple.akd", "com.apple.nsurlsessiond", "com.apple.homed",
        "FamilyCircle", "com.apple.containermanagerd", "com.apple.ap.adprivacyd",
        Bundle.main.bundleIdentifier ?? "com.homielab.CleanMate",
    ]
}
