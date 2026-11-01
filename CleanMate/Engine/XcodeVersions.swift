import Foundation

/// Old Xcode versions (15–30 GB each) kept in /Applications or ~/Applications after an upgrade or a beta: any `*.app`
/// directly there whose `Info.plist` names Xcode's bundle id, whatever it is called (`Xcode.app`, `Xcode-15.4.app`,
/// `Xcode-beta.app`, `Xcode-16.0.0.app` from xcodes). Only real folders, never through a symlink.
/// Kept, never listed (asked at scan and again right before removal): the version `xcode-select` points to, one an
/// app-folder symlink points to (`Xcode.app` → `Xcode-16.0.app`), the newest release (a beta never counts as the
/// newest when a release is installed) and any version whose `CFBundleShortVersionString` can't be read. So with one
/// Xcode nothing is listed. Unticked, moved to the Trash so Undo puts it back. Root-owned or non-writable ones are
/// locked rows with a reason (never a password prompt), and so is one a program runs from (`Xcode`, `xcodebuild`,
/// `Simulator`, `ibtoold`… whose executable is inside it), matched by path, not by name.
nonisolated enum XcodeVersions {
    static let id = "xcode-old-versions"
    static let bundleID = "com.apple.dt.Xcode"
    /// Where `xcode-select -s` records the developer folder (readable by every user).
    static let selectLink = "/var/db/xcode_select_link"
    /// The folder `xcode-select -p` falls back to when nothing was selected.
    static let defaultDeveloperFolder = "/Applications/Xcode.app/Contents/Developer"
    /// Largest plist read: Xcode's are a few KB.
    static let plistLimit = 1 << 20

    /// One Xcode app.
    struct Install: Equatable, Sendable {
        let url: URL
        /// `CFBundleShortVersionString`: `15.4`, `16.0`.
        let version: String?
        /// `ProductBuildVersion` of `Contents/version.plist`: `15F31d`.
        let build: String?
        /// `licenseType` of `Contents/Resources/LicenseInfo.plist` is `Beta` (a release says `GM`); without that file,
        /// the app's name says beta.
        let isBeta: Bool

        var parsedVersion: AndroidSDKComponents.Version? { version.flatMap(AndroidSDKComponents.Version.init) }
    }

    /// The Xcode app at `url`, or nil: not a real `*.app` folder or not Xcode's bundle id (the name doesn't matter).
    static func install(at url: URL) -> Install? {
        var info = stat()
        guard url.pathExtension.lowercased() == "app", !url.lastPathComponent.hasPrefix("."),
              lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        let contents = url.appending(path: "Contents")
        guard let plist = dictionary(contents.appending(path: "Info.plist")),
              plist["CFBundleIdentifier"] as? String == bundleID else { return nil }
        let license = text(dictionary(contents.appending(path: "Resources/LicenseInfo.plist"))?["licenseType"])
        return Install(url: url, version: text(plist["CFBundleShortVersionString"]),
                       build: text(dictionary(contents.appending(path: "version.plist"))?["ProductBuildVersion"]),
                       isBeta: (license ?? url.lastPathComponent).lowercased().contains("beta"))
    }

    /// The Xcode apps directly in each of `folders` (never deeper), by path.
    static func installs(in folders: [URL]) -> [Install] {
        folders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
                .compactMap { install(at: folder.appending(path: $0)) }
        }
    }

    /// The developer folder `xcode-select -p` prints, as recorded and with symlinks resolved: `selectLink`'s target, or
    /// `defaultDeveloperFolder` when nothing was selected. `DEVELOPER_DIR` set in one shell is not seen.
    static func selectedFolders(link: String = selectLink) -> [String] {
        let folder = (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) ?? defaultDeveloperFolder
        return [folder, URL(fileURLWithPath: folder).resolvingSymlinksInPath().path]
    }

    /// Targets of the symlinks directly in `folders` (`Xcode.app` → `Xcode-16.0.app`), resolved.
    static func linkTargets(in folders: [URL]) -> Set<String> {
        var targets = Set<String>()
        for folder in folders {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
                let url = folder.appending(path: name)
                var info = stat()
                guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK else { continue }
                targets.insert(url.resolvingSymlinksInPath().path)
            }
        }
        return targets
    }

    /// Paths of the `installs` to keep: the one a `selected` folder is in (or is), the ones `linked` names, every
    /// version that can't be read, and the newest release (all copies of it; the newest beta when no release is
    /// installed).
    static func kept(_ installs: [Install], selected: [String], linked: Set<String>) -> Set<String> {
        var kept = Set<String>()
        for install in installs {
            let own = [install.url.standardizedFileURL.path, install.url.resolvingSymlinksInPath().path]
            if install.parsedVersion == nil || own.contains(where: linked.contains)
                || selected.contains(where: { path in own.contains { path == $0 || path.hasPrefix($0 + "/") } }) {
                kept.insert(own[0])
            }
        }
        let releases = installs.filter { !$0.isBeta && $0.parsedVersion != nil }
        let pool = releases.isEmpty ? installs : releases
        if let newest = pool.compactMap(\.parsedVersion).max() {
            for install in pool where install.parsedVersion == newest { kept.insert(install.url.standardizedFileURL.path) }
        }
        return kept
    }

    /// The Xcode apps in `folders` the item lists: not kept, and allowed by `SafetyPolicy.allowsXcodeApp` (locked
    /// rows are listed, so ownership is checked by `locksEntry`).
    static func find(in folders: [URL], policy: SafetyPolicy, selected: [String]) -> [URL] {
        let found = installs(in: folders)
        guard found.count > 1 else { return [] }
        let kept = kept(found, selected: selected, linked: linkTargets(in: folders))
        return found.map(\.url).filter {
            !kept.contains($0.standardizedFileURL.path) && policy.allowsXcodeApp($0, writableOnly: false)
        }
    }

    /// `url` is one `find` lists now.
    static func allows(_ url: URL, policy: SafetyPolicy, folders: [URL], selected: [String]) -> Bool {
        let path = url.standardizedFileURL.path
        return find(in: folders, policy: policy, selected: selected).contains { $0.standardizedFileURL.path == path }
    }

    /// `Xcode 15.4 (15F31d)`, `Xcode 16.0 beta (16A5171c)`; dated when it was installed (its folder last changed).
    static func label(of url: URL) -> (title: String, date: Date?)? {
        guard let install = install(at: url) else { return nil }
        var title = "Xcode " + (install.version ?? url.deletingPathExtension().lastPathComponent)
        if install.isBeta { title += " beta" }
        if let build = install.build { title += " (\(build))" }
        return (title, (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)
    }

    /// The Smart Scan item. `folders` (the ones searched, /Applications and ~/Applications), `owner`, `selected` (the
    /// developer folder) and `running` (paths programs run from) are injected by tests, which must never reach the real
    /// /Applications.
    static func item(folders: @escaping @Sendable (SafetyPolicy) -> [URL] = { $0.applicationFolders },
                     owner: @escaping SafetyPolicy.OwnerID = SafetyPolicy.ownerID,
                     selected: @escaping @Sendable () -> [String] = { selectedFolders() },
                     running: @escaping @Sendable () -> [String] = RunningProcesses.usedPaths,
                     sizes: FolderSizeCache = .shared) -> CleanerItem {
        // Unticked: an older Xcode may be kept on purpose (an older SDK or Swift). To the Trash, so Undo puts it back.
        // Not skipped while Xcode runs: the running one is kept; only a version a program runs from is locked.
        var item = CleanerItem(id: id, title: "Old Xcode versions",
                               note: "Xcode apps other than the one xcode-select uses and the newest release. Download them again from developer.apple.com or the App Store. Moved to the Trash",
                               paths: [], mode: .trash, selectedByDefault: false, showsWhenEmpty: false,
                               entryLabel: label(of:), selectableEntries: true,
                               findEntries: { _, policy in find(in: folders(policy), policy: policy, selected: selected()) },
                               allowsEntry: { policy, url in
                                   allows(url, policy: policy, folders: folders(policy), selected: selected())
                               },
                               entrySizes: sizes)
        item.locksEntry = {
            let admin = String(localized: "Administrator privileges required — delete with Finder")
            let inUse = OldRuntimes.locks(reason: String(localized: "A program runs from this version, so it is kept"),
                                          running: running)()
            return { url in MacOSInstallers.isWritable(url, owner: owner) ? inUse(url) : admin }
        }
        return item
    }

    // MARK: - Files

    /// A regular plist file of at most `plistLimit` (not through a symlink); nil when it can't be read.
    private static func dictionary(_ url: URL) -> [String: Any]? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= plistLimit else { return nil }
        return NSDictionary(contentsOf: url) as? [String: Any]
    }

    private static func text(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
