import Foundation

/// macOS installer apps (`Install macOS Sequoia.app`, 12–15 GB each) left in /Applications or ~/Applications after an
/// upgrade or after making a USB installer. Only Apple's real installer bundles the user can move to the Trash without
/// a password (`SafetyPolicy.allowsMacOSInstaller`); never one in /Library/Updates, /System or Downloads ("Old installers").
nonisolated enum MacOSInstallers {
    static let id = "macos-installers"
    /// Bundle id of every macOS installer app: `com.apple.InstallAssistant.macOSSequoia`, `….ElCapitan`.
    static let bundleIDPrefix = "com.apple.InstallAssistant"
    /// File names of the installer apps (compared case-insensitively), followed by the release name and `.app`.
    static let namePrefixes = ["Install macOS ", "Install OS X "]
    /// The installer app and the tools that run from it: while one runs, the item is skipped.
    static let processNames = ["InstallAssistant*", "Install macOS*", "Install OS X*", "startosinstall", "createinstallmedia",
                               "osinstallersetupd"]

    /// The Smart Scan item. `folders` (the ones searched, /Applications and ~/Applications) and `owner` are injected by
    /// tests, which must never reach the real /Applications.
    static func item(folders: @escaping @Sendable (SafetyPolicy) -> [URL] = { $0.applicationFolders },
                     owner: @escaping SafetyPolicy.OwnerID = SafetyPolicy.ownerID) -> CleanerItem {
        // Unticked: the user may keep one to install again or make a USB installer. To the Trash, so Undo puts it back.
        CleanerItem(id: id, title: "macOS installers",
                    note: "Install macOS apps in Applications, downloaded again from the App Store when needed. Moved to the Trash",
                    paths: [], mode: .trash, selectedByDefault: false, showsWhenEmpty: false,
                    runningAppBundleIDs: [bundleIDPrefix + "*"], runningProcessNames: processNames,
                    entryLabel: label(of:), selectableEntries: true,
                    findEntries: { _, policy in find(in: folders(policy)) },
                    allowsEntry: { policy, url in policy.allowsMacOSInstaller(url, owner: owner) })
    }

    /// `Install macOS <name>.app` or `Install OS X <name>.app`, any case.
    static func isInstallerName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".app") && namePrefixes.contains { prefix in
            lower.hasPrefix(prefix.lowercased()) && lower.count > prefix.count + 4
        }
    }

    /// Installer-named entries directly in each of `folders` (never deeper); `allowsMacOSInstaller` checks the rest.
    static func find(in folders: [URL]) -> [URL] {
        folders.flatMap { folder -> [URL] in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            return names.sorted().filter(isInstallerName).map { folder.appending(path: $0) }
        }
    }

    /// "Install macOS Sequoia · 20.1.01": the app name and the macOS version older installers record in
    /// `SharedSupport/InstallInfo.plist`, else the installer's own version; just the name when neither is readable.
    static func label(of url: URL) -> (title: String, date: Date?)? {
        let name = url.deletingPathExtension().lastPathComponent
        let contents = url.appending(path: "Contents")
        let imageInfo = NSDictionary(contentsOf: contents.appending(path: "SharedSupport/InstallInfo.plist"))?["System Image Info"]
        let version = (imageInfo as? [String: Any])?["version"] as? String
            ?? NSDictionary(contentsOf: contents.appending(path: "Info.plist"))?["CFBundleShortVersionString"] as? String
        guard let version = version?.trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty else { return (name, nil) }
        return ("\(name) · \(version)", nil)
    }
}
