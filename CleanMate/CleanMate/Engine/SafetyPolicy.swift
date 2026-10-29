import Foundation

/// Hard blocklist checked by the scanner and again right before every removal.
/// A path is allowed only if it is strictly inside the home or user temp folder, is not one of the
/// protected folders itself (or a parent of one), is not inside a never-touch tree, and is on the same volume as
/// that home or temp folder (never another filesystem mounted inside it, e.g. CoreDevice's DeviceFS),
/// and holds no other volume's mount point below it.
nonisolated struct SafetyPolicy: Sendable {
    let homeURL: URL
    let tempURL: URL
    private let allowedRoots: [String]
    /// May not be removed themselves (or via a parent), but their contents may.
    private let protectedFolders: [String]
    /// Never touched at all, nor anything inside.
    private let protectedTrees: [String]
    /// Folders the user excluded in Settings: never listed nor removed by any module, nor via a parent.
    let excluded: [String]
    /// Device id of a path, without following a last-component symlink; nil when it does not exist.
    typealias DeviceID = @Sendable (String) -> dev_t?
    static let deviceID: DeviceID = { path in
        var info = stat()
        return lstat(path, &info) == 0 ? info.st_dev : nil
    }
    private let device: DeviceID
    /// Paths every volume is mounted on. getfsstat, the thread-safe getmntinfo: no tree walk, no disk I/O.
    typealias MountPoints = @Sendable () -> [String]
    static let mountPoints: MountPoints = {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        let list = UnsafeMutablePointer<statfs>.allocate(capacity: Int(count))
        defer { list.deallocate() }
        let got = getfsstat(list, Int32(MemoryLayout<statfs>.stride) * count, MNT_NOWAIT)
        return (0..<Int(max(got, 0))).map { index in
            withUnsafeBytes(of: list[index].f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        }
    }
    private let mounts: MountPoints
    /// `device` of each of `allowedRoots`.
    private let rootDevices: [dev_t?]

    /// Read on every use so exclusions added in Settings apply to the next scan and removal.
    static var current: SafetyPolicy {
        SafetyPolicy(home: URL(fileURLWithPath: NSHomeDirectory()), temp: FileManager.default.temporaryDirectory,
                     excluded: Preferences.excluded)
    }

    /// `device` and `mounts` are injected by tests (they can't mount a volume).
    init(home: URL, temp: URL, excluded: [String] = [], device: @escaping DeviceID = SafetyPolicy.deviceID,
         mounts: @escaping MountPoints = SafetyPolicy.mountPoints) {
        homeURL = home
        tempURL = temp
        let home = (home.path as NSString).resolvingSymlinksInPath
        let temp = (temp.path as NSString).resolvingSymlinksInPath
        allowedRoots = [home, temp]
        self.device = device
        self.mounts = mounts
        rootDevices = allowedRoots.map(device)
        protectedFolders = [home.lowercased(), temp.lowercased()] + [
            "Library", "Library/Caches", "Library/Logs", "Library/Logs/DiagnosticReports",
            "Library/Application Support", "Library/Containers", "Library/Group Containers",
            "Library/Preferences", "Library/Developer", ".Trash", "Downloads", "Applications",
            ".config", ".local", ".local/share", ".local/state", ".cache",
        ].map { (home + "/" + $0).lowercased() }
        protectedTrees = [
            ".ssh", ".gnupg", ".aws", ".kube", "Library/Keychains", "Documents", "Desktop", "Pictures",
            "Movies", "Music", "Library/Mobile Documents", "Library/CloudStorage", "Library/Mail",
            "Library/Messages",
        ].map { (home + "/" + $0).lowercased() }
        self.excluded = excluded.map { ($0 as NSString).resolvingSymlinksInPath }
    }

    /// `path` (normalized) is an excluded folder, inside one, or a parent of one. Case-insensitive like APFS.
    private func isExcluded(_ path: String) -> Bool {
        let path = path.lowercased()
        // "/" (the startup disk) holds everything: "//" would match nothing.
        return excluded.map { $0.lowercased() }.contains {
            $0 == path || path.hasPrefix($0 == "/" ? $0 : $0 + "/") || $0.hasPrefix(path + "/")
        }
    }

    /// `url` (symlinks resolved, as a tool would follow them) is an excluded folder, inside one, or holds one.
    func overlapsExclusion(_ url: URL) -> Bool { isExcluded((url.path as NSString).resolvingSymlinksInPath) }

    func expand(_ path: String) -> URL {
        if path == "~" { return homeURL }
        if path.hasPrefix("~/") { return homeURL.appending(path: String(path.dropFirst(2))) }
        if path == "$TMPDIR" { return tempURL }
        if path.hasPrefix("$TMPDIR/") { return tempURL.appending(path: String(path.dropFirst(8))) }
        return URL(fileURLWithPath: path)
    }

    /// `expand`, then every path component containing `*` replaced by the matching non-hidden entries (fnmatch).
    func roots(_ path: String) -> [URL] {
        let url = expand(path)
        guard path.contains("*") else { return [url] }
        var found = [URL(fileURLWithPath: "/")]
        for part in url.pathComponents.dropFirst() {
            found = found.flatMap { base -> [URL] in
                guard part.contains("*") else { return [base.appending(path: part)] }
                let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
                return names.sorted().filter { !$0.hasPrefix(".") && fnmatch(part, $0, 0) == 0 }
                    .map { base.appending(path: $0) }
            }
        }
        return found
    }

    /// A scan root (`expand`/`roots` output) that goes through a symlink below the home or temp folder (the root
    /// itself or a folder between): its target could be anywhere in the home, outside the protected trees, so it is
    /// never scanned. The home/temp folder's own path (`/var` → `/private/var`) is trusted. Outside both: true.
    func rootThroughSymlink(_ url: URL) -> Bool {
        let path = url.path
        guard let base = [homeURL.path, tempURL.path].first(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return true }
        var current = base
        for part in path.dropFirst(base.count).split(separator: "/") {
            current += "/" + part
            var info = stat()
            if lstat(current, &info) == 0, info.st_mode & S_IFMT == S_IFLNK { return true }
        }
        return false
    }

    /// `path` (normalized) holds another volume's mount point somewhere below it: trashing or removing it would
    /// take that volume's files along (a moved folder carries the mount with it). Case-insensitive like APFS.
    private func holdsMount(_ path: String) -> Bool {
        let prefix = path.lowercased() + "/"
        return mounts().contains { $0.lowercased().hasPrefix(prefix) }
    }

    func allows(_ url: URL) -> Bool {
        let path = Self.normalize(url)
        guard let root = allowedRoots.firstIndex(where: { path.hasPrefix($0 + "/") }), !isExcluded(path) else { return false }
        // Another volume mounted inside (a mount point or anything on it): never listed, measured nor removed.
        if let rootDevice = rootDevices[root], let entryDevice = device(path), entryDevice != rootDevice { return false }
        if holdsMount(path) { return false }
        // APFS is case-insensitive by default: `~/documents` or `~/.SSH` is the protected folder itself.
        let key = path.lowercased()
        for folder in protectedFolders + protectedTrees where folder == key || folder.hasPrefix(key + "/") {
            return false
        }
        return !protectedTrees.contains { key.hasPrefix($0 + "/") }
    }

    /// Separate, narrower rule for files the user picked by hand (Large & Old Files), which are only ever
    /// moved to the Trash: documents, Desktop, Movies… are allowed, but only a regular file strictly inside
    /// the home folder, never under ~/Library (iCloud Drive, CloudStorage, Keychains, Mail…), never under a
    /// hidden folder (.ssh, .gnupg, .Trash…) or a hidden file, and never inside a package or app bundle.
    func allowsUserFile(_ url: URL) -> Bool {
        guard let path = userLocation(url) else { return false }
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values?.isRegularFile == true && values?.isSymbolicLink != true
    }

    /// Space Lens rule for an item the user picked by hand, only ever moved to the Trash: same places as
    /// `allowsUserFile`, but folders are allowed too — except the top-level folders of the home itself
    /// (Documents, Desktop, Downloads, Developer…), whose contents may be trashed but not the folder.
    /// The subset of `urls` that `allowsSpaceLensItem` accepts, with one policy for the whole batch.
    func allowedSpaceLensItems(_ urls: Set<URL>) -> Set<URL> { urls.filter(allowsSpaceLensItem) }

    func allowsSpaceLensItem(_ url: URL) -> Bool {
        guard let path = userLocation(url) else { return false }
        let values = try? URL(fileURLWithPath: path).resourceValues(
            forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isSymbolicLink != true else { return false }
        if values?.isDirectory == true {
            return (path as NSString).deletingLastPathComponent != allowedRoots[0]
        }
        return values?.isRegularFile == true
    }

    /// Normalized path of `url` if it is strictly inside the home folder and on the home's volume, not under ~/Library, not hidden nor
    /// under a hidden folder, and not inside a package or app bundle; nil otherwise.
    private func userLocation(_ url: URL) -> String? {
        let path = Self.normalize(url)
        guard let home = allowedRoots.first, path.hasPrefix(home + "/"), !isExcluded(path) else { return nil }
        let parts = path.dropFirst(home.count + 1).split(separator: "/")
        guard parts.first?.lowercased() != "library", !parts.contains(where: { $0.hasPrefix(".") }) else { return nil }
        // Another volume mounted inside the home (NFS/SMB/OrbStack…), or its mount point: never trashed.
        if let homeDevice = rootDevices[0], device(path) != homeDevice { return nil }
        if holdsMount(path) { return nil }
        var folder = URL(fileURLWithPath: home)
        for part in parts.dropLast() {
            folder.append(path: String(part))
            if (try? folder.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true { return nil }
        }
        return path
    }

    /// Folders whose apps the Uninstaller lists: /Applications and ~/Applications, directly or up to
    /// `appSubfolderDepth` plain (non-bundle) subfolders down.
    static let appSubfolderDepth = 3  // `Vendor/Suite/Tools/App.app`

    var applicationFolders: [URL] {
        [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: allowedRoots[0]).appending(path: "Applications")]
    }

    /// ~/Library subfolders whose direct children (named after an app) the Uninstaller may remove.
    static let appDataFolders = [
        "Application Support", "Caches", "Preferences", "Containers", "Group Containers", "Saved Application State",
        "Logs", "HTTPStorages", "WebKit", "LaunchAgents",
    ]

    /// Anything of Apple's (`com.apple.…`, `group.com.apple.…`, `<team>.com.apple.…`) is never listed or removed.
    static func isApple(_ name: String) -> Bool {
        let name = name.lowercased()
        return name == "com.apple" || name.contains("com.apple.")
    }

    /// Uninstaller rule for app bundles, only ever moved to the Trash: a real (not symlinked) `*.app` folder that is
    /// in /Applications or ~/Applications or at most `appSubfolderDepth` plain subfolders down (`Vendor/App.app`), never
    /// inside another bundle, not an Apple app and not CleanMate itself.
    func allowsApp(_ url: URL) -> Bool {
        let url = URL(fileURLWithPath: Self.normalize(url))
        guard url.pathExtension == "app", !isExcluded(url.path),
              let folder = applicationFolders.first(where: { url.path.hasPrefix($0.path + "/") }) else { return false }
        let between = url.deletingLastPathComponent().path.dropFirst(folder.path.count).split(separator: "/")
        guard between.count <= Self.appSubfolderDepth else { return false }
        var dir = folder
        for part in between {
            dir.append(path: String(part))
            if part.hasPrefix(".") || (try? dir.resourceValues(forKeys: [.isPackageKey]))?.isPackage != false { return false }
        }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true,
              let id = Bundle(url: url)?.bundleIdentifier else { return false }
        return !Self.isApple(id) && id != Bundle.main.bundleIdentifier
    }

    /// Uninstaller rule for an app's data, only ever moved to the Trash: one entry directly inside one of
    /// `appDataFolders` of ~/Library (never the folder itself), not hidden, not Apple's, and allowed by `allows`.
    func allowsAppData(_ url: URL) -> Bool {
        let path = Self.normalize(url)
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let library = allowedRoots[0] + "/Library/"
        guard Self.appDataFolders.contains(where: { parent == library + $0 }), !name.hasPrefix("."), !Self.isApple(name)
        else { return false }
        return allows(URL(fileURLWithPath: path))
    }

    /// Hidden items of the home folder that are never one app's config, whatever app is named like them: shell and login
    /// files, keys, stores shared by developer tools, and the folders `allows` already refuses. Lowercased.
    static let sharedHomeItems: Set = [
        ".config", ".cache", ".local", ".trash", ".ssh", ".gnupg", ".aws", ".kube", ".cfusertextencoding", ".ds_store",
        ".zshrc", ".zshenv", ".zprofile", ".zlogin", ".zlogout", ".zsh_history", ".zsh_sessions", ".oh-my-zsh",
        ".bashrc", ".bash_profile", ".bash_history", ".bash_sessions", ".profile", ".inputrc", ".hushlogin",
        ".gitconfig", ".git-credentials", ".netrc", ".npmrc", ".npm", ".yarnrc", ".cargo", ".rustup", ".gradle", ".m2",
        ".nvm", ".pyenv", ".rbenv", ".gem", ".bun", ".deno", ".android", ".swiftpm", ".cocoapods", ".password-store",
        ".vim", ".vimrc", ".viminfo", ".lesshst", ".python_history", ".node_repl_history",
    ]

    /// Folders of the home folder whose non-hidden items can be an app's config or data (XDG config and data homes).
    static let appConfigFolders = [".config", ".local/share", ".local/state"]

    /// Uninstaller rule for an app's config outside ~/Library, only ever moved to the Trash: a hidden item directly in
    /// the home folder (`~/.cursor`, never a `sharedHomeItems` one) or a non-hidden item directly in ~/.config,
    /// ~/.local/share or ~/.local/state (`~/.config/zed`, `~/.local/state/zed`; a symlinked ~/.config, ~/.local or ~/.local/share is never
    /// followed), not a symlink itself, not Apple's, and allowed by `allows` (never ~/.config, ~/.cache, ~/.local,
    /// ~/.local/share, ~/.Trash themselves nor anything in .ssh, .gnupg, .aws, .kube).
    func allowsAppConfig(_ url: URL) -> Bool {
        let path = Self.normalize(url)
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let home = allowedRoots[0]
        let inHome = parent == home && name.hasPrefix(".") && name.count > 1 && !Self.sharedHomeItems.contains(name.lowercased())
        let inConfig = Self.appConfigFolders.contains { parent == home + "/" + $0 } && !name.hasPrefix(".")
        guard inHome || inConfig, !Self.isApple(name) else { return false }
        let real = URL(fileURLWithPath: path)
        guard (try? real.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == false else { return false }
        return allows(real)
    }

    /// Uninstaller rule for a user extension, only ever moved to the Trash: one entry directly inside one of the
    /// `ExtensionItem.Kind` folders of ~/Library, with that kind's name extension, not hidden, not a symlink, not Apple's
    /// (name or `CFBundleIdentifier`), and allowed by `allows`.
    func allowsUserExtension(_ url: URL) -> Bool {
        let path = Self.normalize(url)
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let library = allowedRoots[0] + "/Library/"
        guard let kind = ExtensionItem.Kind.allCases.first(where: { parent == library + $0.folder }),
              kind.fileExtensions.contains((name as NSString).pathExtension.lowercased()),
              !name.hasPrefix("."), !Self.isApple(name) else { return false }
        let real = URL(fileURLWithPath: path)
        guard (try? real.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == false,
              !(Extensions.bundleID(of: real).map(Self.isApple) ?? false) else { return false }
        return allows(real)
    }

    /// Login Items rule for a user launch agent, which is only ever disabled through `launchctl` or moved to the Trash:
    /// a `.plist` directly in ~/Library/LaunchAgents (`allowsAppData`), not a symlink, with a label that is not Apple's
    /// and can't name another service (no `/`).
    func allowsLaunchAgent(_ url: URL, label: String) -> Bool {
        let path = Self.normalize(url)
        guard path.hasSuffix(".plist"), (path as NSString).deletingLastPathComponent == allowedRoots[0] + "/Library/LaunchAgents",
              !label.isEmpty, !label.contains("/"), !Self.isApple(label), allowsAppData(URL(fileURLWithPath: path))
        else { return false }
        return (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == false
    }

    /// Resolves `..` and symlinks in the parent folders, but not the last component:
    /// removing a symlink only removes the link, while a symlinked parent could point anywhere.
    static func normalize(_ url: URL) -> String {
        var path = url.path
        let parts = path.split(separator: "/")
        if parts.contains(".") || parts.contains("..") {
            // `link/..` and `link/.` go through the link's target, but standardizingPath cuts them lexically (leaving
            // `link` last, unresolved, while removeItem follows it): resolve them on disk; unresolvable → "/" (refused).
            let throughLast = parts.last == "." || parts.last == ".."
            guard let real = realpath(throughLast ? path : (path as NSString).deletingLastPathComponent, nil)
            else { return "/" }
            defer { free(real) }
            path = String(cString: real) + (throughLast ? "" : "/" + (path as NSString).lastPathComponent)
        }
        path = (path as NSString).standardizingPath
        guard path != "/" else { return path }
        let parent = ((path as NSString).deletingLastPathComponent as NSString).resolvingSymlinksInPath
        return (parent as NSString).appendingPathComponent((path as NSString).lastPathComponent)
    }
}
