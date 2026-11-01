import Foundation

/// macOS installer apps (`Install macOS Sequoia.app`, 12–15 GB each) left in /Applications or ~/Applications after an
/// upgrade or after making a USB installer. Only Apple's real installer bundles the user can move to the Trash without
/// a password (`SafetyPolicy.allowsMacOSInstaller`); never one in /Library/Updates, /System or Downloads ("Old installers").
/// Installers owned by root or in a non-writable folder are listed as locked rows with a reason so users see their size.
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
        // A root-owned or non-writable installer is listed as locked (checkbox disabled, lock icon and reason) so users
        // know where 12–15 GB went, but never asks for an admin password.
        var item = CleanerItem(id: id, title: "macOS installers",
                               note: "Install macOS apps in Applications, downloaded again from the App Store when needed. Moved to the Trash",
                               paths: [], mode: .trash, selectedByDefault: false, showsWhenEmpty: false,
                               runningAppBundleIDs: [bundleIDPrefix + "*"], runningProcessNames: processNames,
                               entryLabel: label(of:), selectableEntries: true,
                               findEntries: { _, policy in find(in: folders(policy)) },
                               allowsEntry: { policy, url in policy.allowsMacOSInstaller(url, writableOnly: false, owner: owner) })
        item.locksEntry = {
            let reason = String(localized: "Administrator privileges required — delete with Finder")
            return { url in
                isWritable(url, owner: owner) ? nil : reason
            }
        }
        return item
    }

    /// Whether the user can move the installer bundle to the Trash without an administrator password prompt:
    /// not owned by root, the app folder and its parent folder writable.
    static func isWritable(_ url: URL, owner: SafetyPolicy.OwnerID = SafetyPolicy.ownerID) -> Bool {
        let path = SafetyPolicy.normalize(url)
        let parent = (path as NSString).deletingLastPathComponent
        guard let uid = owner(path), uid != 0,
              access(parent, W_OK) == 0,
              access(path, W_OK) == 0 else {
            return false
        }
        return true
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

    /// "macOS Sonoma 14.6": for Big Sur+ installers, reads `DTPlatformVersion` (or maps `DTSDKBuild`) from `Contents/Info.plist`
    /// and drops the "Install " prefix; shows just the name when uncertain. For older installers (Mojave, El Capitan), reads
    /// the macOS version from `SharedSupport/InstallInfo.plist`. Never mounts `SharedSupport.dmg`.
    static func label(of url: URL) -> (title: String, date: Date?)? {
        let name = url.deletingPathExtension().lastPathComponent
        let contents = url.appending(path: "Contents")
        let sharedSupport = contents.appending(path: "SharedSupport")

        // Older installers (Mojave 10.14, El Capitan 10.11…): version recorded in InstallInfo.plist
        let imageInfo = NSDictionary(contentsOf: sharedSupport.appending(path: "InstallInfo.plist"))?["System Image Info"]
        if let legacyVersion = ((imageInfo as? [String: Any])?["version"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !legacyVersion.isEmpty {
            return ("\(name) · \(legacyVersion)", nil)
        }

        let info = NSDictionary(contentsOf: contents.appending(path: "Info.plist"))
        let dtPlatformVersion = (info?["DTPlatformVersion"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let shortVersion = (info?["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let dtsdkBuild = (info?["DTSDKBuild"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        let hasSharedSupportDMG = FileManager.default.fileExists(atPath: sharedSupport.appending(path: "SharedSupport.dmg").path)

        // Older installers without InstallInfo.plist where CFBundleShortVersionString was the OS version (10.x)
        if !hasSharedSupportDMG, let shortVersion, shortVersion.hasPrefix("10.") {
            return ("\(name) · \(shortVersion)", nil)
        }

        // Big Sur+ installers (Big Sur 11, Monterey 12, Ventura 13, Sonoma 14, Sequoia 15…):
        // CFBundleShortVersionString is the installer app version (e.g. 19.x, 20.x), NOT the macOS version.
        // Read DTPlatformVersion from Info.plist, fallback to mapping DTSDKBuild; never mount SharedSupport.dmg.
        let cleanName = displayName(for: name)
        let version: String? = {
            if let dtPlatformVersion, !dtPlatformVersion.isEmpty {
                return dtPlatformVersion
            }
            if let dtsdkBuild, let major = macosMajor(fromDarwinBuild: dtsdkBuild) {
                return major
            }
            return nil
        }()

        if let version, !version.isEmpty {
            return ("\(cleanName) \(version)", nil)
        }
        return (cleanName, nil)
    }

    /// Strips leading "Install " (case-insensitive), e.g. "Install macOS Sonoma" -> "macOS Sonoma".
    static func displayName(for name: String) -> String {
        for prefix in namePrefixes {
            if name.lowercased().hasPrefix(prefix.lowercased()) {
                let index = name.index(name.startIndex, offsetBy: "Install ".count)
                return String(name[index...])
            }
        }
        if name.lowercased().hasPrefix("install ") {
            let index = name.index(name.startIndex, offsetBy: "install ".count)
            return String(name[index...])
        }
        return name
    }

    /// Maps Darwin build prefix (from `DTSDKBuild`) to macOS major version:
    /// Darwin 24 = macOS 15 (Sequoia), 23 = 14 (Sonoma), 22 = 13 (Ventura), 21 = 12 (Monterey), 20 = 11 (Big Sur).
    static func macosMajor(fromDarwinBuild build: String) -> String? {
        let prefix = build.prefix(2)
        guard let darwin = Int(prefix) else { return nil }
        switch darwin {
        case 20: return "11"
        case 21: return "12"
        case 22: return "13"
        case 23: return "14"
        case 24: return "15"
        default:
            if darwin > 24 { return "\(darwin + 1)" }  // Darwin 25 = macOS 26 (Tahoe)
            return nil
        }
    }
}
