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
    let mounts: MountPoints
    /// Where external volumes are mounted (`/Volumes`); a test passes a temporary folder.
    let volumesFolder: String
    /// Mount flags (statfs `f_flags`: `MNT_RDONLY`, `MNT_LOCAL`, `MNT_DONTBROWSE`…) of the volume holding a path; nil
    /// when it can't be read. Injected by tests: their folders sit on the startup disk's Data volume (`nobrowse`).
    typealias VolumeFlags = @Sendable (String) -> UInt32?
    static let volumeFlags: VolumeFlags = { path in
        var info = statfs()
        return statfs(path, &info) == 0 ? info.f_flags : nil
    }
    let flags: VolumeFlags
    /// `device` of each of `allowedRoots`.
    private let rootDevices: [dev_t?]

    /// Read on every use so exclusions added in Settings apply to the next scan and removal.
    static var current: SafetyPolicy {
        SafetyPolicy(home: URL(fileURLWithPath: NSHomeDirectory()), temp: FileManager.default.temporaryDirectory,
                     excluded: Preferences.excluded)
    }

    /// `device`, `mounts` and `flags` are injected by tests (they can't mount a volume).
    init(home: URL, temp: URL, excluded: [String] = [], device: @escaping DeviceID = SafetyPolicy.deviceID,
         mounts: @escaping MountPoints = SafetyPolicy.mountPoints, volumesFolder: String = "/Volumes",
         flags: @escaping VolumeFlags = SafetyPolicy.volumeFlags) {
        self.volumesFolder = Self.normalize(URL(fileURLWithPath: volumesFolder))
        self.flags = flags
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

    func allows(_ url: URL) -> Bool { allows(normalized: Self.normalize(url)) }

    /// `allows`, or the one exception to the CloudStorage never-touch tree: Dropbox's own cache in a Dropbox folder
    /// there, `~/Library/CloudStorage/Dropbox*/.dropbox.cache` and what it holds (never the synced files next to it),
    /// otherwise checked like `allows` (same volume, no mount inside, not excluded).
    func allowsDropboxCache(_ url: URL) -> Bool {
        let path = Self.normalize(url)
        if allows(normalized: path) { return true }
        guard let home = allowedRoots.first else { return false }
        let cloud = (home + "/Library/CloudStorage").lowercased()
        let key = path.lowercased()
        guard key.hasPrefix(cloud + "/") else { return false }
        let parts = key.dropFirst(cloud.count + 1).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0].hasPrefix("dropbox"), parts[1] == ".dropbox.cache" else { return false }
        return allows(normalized: path, skippingTree: cloud)
    }

    /// `allows` for a normalized path; `skippingTree` (lowercased) is left out of the never-touch trees.
    private func allows(normalized path: String, skippingTree: String? = nil) -> Bool {
        guard let root = allowedRoots.firstIndex(where: { path.hasPrefix($0 + "/") }), !isExcluded(path) else { return false }
        // Another volume mounted inside (a mount point or anything on it): never listed, measured nor removed.
        if let rootDevice = rootDevices[root], let entryDevice = device(path), entryDevice != rootDevice { return false }
        if holdsMount(path) { return false }
        // APFS is case-insensitive by default: `~/documents` or `~/.SSH` is the protected folder itself.
        let key = path.lowercased()
        let trees = skippingTree.map { tree in protectedTrees.filter { $0 != tree } } ?? protectedTrees
        for folder in protectedFolders + trees where folder == key || folder.hasPrefix(key + "/") {
            return false
        }
        return !trees.contains { key.hasPrefix($0 + "/") }
    }

    /// Separate, narrower rule for files the user picked by hand (Large & Old Files), which are only ever
    /// moved to the Trash: documents, Desktop, Movies… are allowed, but only a regular file strictly inside
    /// the home folder, never under ~/Library (iCloud Drive, CloudStorage, Keychains, Mail…), never under a
    /// hidden folder (.ssh, .gnupg, .Trash…) or a hidden file, and never inside a package or app bundle.
    /// On an external volume (`externalLocation`) the same rule applies: a regular file, not hidden nor under a hidden
    /// folder (.Trashes, .Spotlight-V100…), not inside a package, on that volume itself.
    func allowsUserFile(_ url: URL) -> Bool {
        guard let path = userLocation(url) ?? externalLocation(url) else { return false }
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values?.isRegularFile == true && values?.isSymbolicLink != true
    }

    /// The subset of `urls` that `allowsSpaceLensItem` accepts, with one policy for the whole batch.
    func allowedSpaceLensItems(_ urls: Set<URL>) -> Set<URL> { urls.filter { allowsSpaceLensItem($0) } }

    /// Space Lens rule for an item the user picked by hand, only ever moved to the Trash: same places as
    /// `allowsUserFile`, but folders are allowed too — except the top-level folders of the home itself
    /// (Documents, Desktop, Downloads, Developer…), whose contents may be trashed but not the folder.
    /// On an external drive (`externalLocation` of a local, writable, browsable drive that is not a Time Machine disk:
    /// the drive's own Trash takes it) a file follows `allowsUserFile`; a folder (not a package) only when everything
    /// in it would too (`externalFolderHoldsOnlyUserFiles`), which `deep: false` skips (a cheap first check for menus).
    func allowsSpaceLensItem(_ url: URL, deep: Bool = true) -> Bool {
        if let path = userLocation(url) {
            let values = try? URL(fileURLWithPath: path).resourceValues(
                forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isSymbolicLink != true else { return false }
            if values?.isDirectory == true {
                return (path as NSString).deletingLastPathComponent != allowedRoots[0]
            }
            return values?.isRegularFile == true
        }
        guard let path = externalLocation(url), let volume = externalVolume(path), holdsUserTrash(volume) else { return false }
        let values = try? URL(fileURLWithPath: path).resourceValues(
            forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
        guard values?.isSymbolicLink != true else { return false }
        if values?.isDirectory == true {
            return values?.isPackage != true && (!deep || externalFolderHoldsOnlyUserFiles(path, device: device(volume)))
        }
        return values?.isRegularFile == true
    }

    /// Finder's own metadata, which sits hidden next to the user's files: `.DS_Store` and AppleDouble `._name` files
    /// (written for every file copied to an exFAT/FAT drive). Moved along with the folder holding them.
    private static func isFinderMetadata(_ name: String) -> Bool { name == ".DS_Store" || name.hasPrefix("._") }

    /// Everything below the external folder `path` is what `allowsUserFile` accepts: regular files and plain folders,
    /// none hidden (besides `isFinderMetadata` files), no package, symlink or other volume, all readable. One `fts`
    /// walk, stopping at the first refusal. Exclusions inside and mount points below are refused before (`externalLocation`).
    private func externalFolderHoldsOnlyUserFiles(_ path: String, device volumeDevice: dev_t?) -> Bool {
        guard let volumeDevice, let stream = path.withCString({ path -> UnsafeMutablePointer<FTS>? in
            var paths: [UnsafeMutablePointer<CChar>?] = [UnsafeMutablePointer(mutating: path), nil]
            return fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil)
        }) else { return false }
        defer { fts_close(stream) }
        while true {
            errno = 0
            guard let entry = fts_read(stream) else { return errno == 0 } // end of the walk, or a read error
            guard entry.pointee.fts_level > 0 else { continue } // the folder itself: checked by the caller
            let name = String(cString: entry.pointee.fts_path).split(separator: "/").last.map(String.init) ?? ""
            guard let info = entry.pointee.fts_statp?.pointee, info.st_dev == volumeDevice else { return false }
            switch Int32(entry.pointee.fts_info) {
            case FTS_D:
                let url = URL(fileURLWithPath: String(cString: entry.pointee.fts_path))
                if name.hasPrefix(".") || (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage != false { return false }
            case FTS_DP:
                continue
            case FTS_F:
                if name.hasPrefix("."), !Self.isFinderMetadata(name) { return false }
            default: // symlink, unreadable folder, error, cycle, device or socket
                return false
            }
        }
    }

    /// Smart Scan rule for an old download (`OldDownloads`), only ever moved to the Trash: a direct child of the real
    /// ~/Downloads folder (not a symlink, so never elsewhere), not hidden, passing `allows`, and a regular file
    /// (`allowsUserFile`) or a real folder (`allowsSpaceLensItem`: not a symlink, not inside a package).
    func allowsOldDownload(_ url: URL) -> Bool {
        guard let home = allowedRoots.first else { return false }
        let downloads = home + "/Downloads"
        let path = Self.normalize(url)
        guard (path as NSString).deletingLastPathComponent.lowercased() == downloads.lowercased(),
              !(path as NSString).lastPathComponent.hasPrefix("."), allows(url) else { return false }
        var folder = stat(), info = stat()
        guard lstat(downloads, &folder) == 0, folder.st_mode & S_IFMT == S_IFDIR, lstat(path, &info) == 0 else { return false }
        switch info.st_mode & S_IFMT {
        case S_IFREG: return allowsUserFile(url)
        case S_IFDIR: return allowsSpaceLensItem(url)
        default: return false
        }
    }

    /// Smart Scan rule for a stale project's dependencies (`StaleNodeModules`), only ever moved to the Trash: a real
    /// folder named `node_modules` next to a regular `package.json` (see `allowsProjectFolder`).
    func allowsNodeModules(_ url: URL) -> Bool { allowsProjectFolder(url, named: [StaleNodeModules.folderName]) }

    /// Smart Scan rule for a stale project's build folder (`StaleBuildFolders`), only ever moved to the Trash: a real
    /// `target` next to a regular `Cargo.toml`, `Pods` next to a `Podfile`, or `.venv`/`venv` holding `pyvenv.cfg`
    /// next to a Python project file (see `allowsProjectFolder`).
    func allowsBuildFolder(_ url: URL) -> Bool { allowsProjectFolder(url, named: StaleBuildFolders.folderNames) }

    /// A folder named one of `names` that its parent holds as a project folder (`StaleProjects.isProjectFolder`),
    /// strictly inside the home folder, not under ~/Library, a hidden folder, a dependency or build folder
    /// (`StaleProjects.unwalked`) or a package (an app's bundled modules), on the home's volume with no other volume
    /// mounted inside, not excluded. Unlike `allows`, also inside Documents and Desktop, where people keep projects;
    /// never inside the other never-touch trees (Pictures, iCloud Drive, .ssh…).
    private func allowsProjectFolder(_ url: URL, named names: Set<String>) -> Bool {
        let path = Self.normalize(url)
        guard names.contains((path as NSString).lastPathComponent), let home = allowedRoots.first,
              path.hasPrefix(home + "/"), !isExcluded(path) else { return false }
        let parts = path.dropFirst(home.count + 1).split(separator: "/")
        guard parts.first?.lowercased() != "library",
              !parts.dropLast().contains(where: { $0.hasPrefix(".") || StaleProjects.unwalked.contains(String($0)) })
        else { return false }
        let key = path.lowercased()
        let projectTrees = ["Documents", "Desktop"].map { (home + "/" + $0).lowercased() }
        guard !protectedTrees.contains(where: { !projectTrees.contains($0) && key.hasPrefix($0 + "/") }) else { return false }
        if let homeDevice = rootDevices[0], device(path) != homeDevice { return false }
        if holdsMount(path) { return false }
        guard StaleProjects.isProjectFolder(path) else { return false }
        var folder = URL(fileURLWithPath: home)
        for part in parts.dropLast() {
            folder.append(path: String(part))
            if (try? folder.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true { return false }
        }
        return true
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

    /// Mount point of the volume mounted in `volumesFolder` (never the startup disk, which only links there) that
    /// holds the normalized `path` or is `path` itself; the innermost one when volumes are nested.
    func externalVolume(_ path: String) -> String? {
        mounts()
            .filter { $0.hasPrefix(volumesFolder + "/") && (path == $0 || path.hasPrefix($0 + "/")) }
            .max { $0.count < $1.count }
    }

    /// Large & Old Files scan root outside the home: an external volume (`externalVolume`) or a folder on it, not
    /// hidden nor under a hidden folder, not excluded nor inside an exclusion, and on that volume (not another one
    /// mounted inside).
    func allowsExternalRoot(_ url: URL) -> Bool {
        // Every symlink resolved (the root too), then the same form as `normalize` gives the files.
        guard let real = realpath(url.path, nil) else { return false }
        let path = Self.normalize(URL(fileURLWithPath: String(cString: real)))
        free(real)
        // Excluded or inside an exclusion; one inside the root is only skipped by the scan (`allowsUserFile`).
        let lower = path.lowercased()
        guard let volume = externalVolume(path),
              !excluded.map({ $0.lowercased() }).contains(where: { lower == $0 || lower.hasPrefix($0 + "/") })
        else { return false }
        guard !path.dropFirst(volume.count).split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { return false }
        return device(volume) != nil && device(path) == device(volume)
    }

    /// Normalized path of `url` if it is strictly inside an external volume (`externalVolume`) and on that volume, not
    /// hidden nor under a hidden folder, not excluded and not inside a package; nil otherwise.
    private func externalLocation(_ url: URL) -> String? {
        let path = Self.normalize(url)
        guard let volume = externalVolume(path), path != volume, !isExcluded(path) else { return nil }
        let parts = path.dropFirst(volume.count + 1).split(separator: "/")
        guard !parts.contains(where: { $0.hasPrefix(".") }) else { return nil }
        guard let volumeDevice = device(volume), device(path) == volumeDevice, !holdsMount(path) else { return nil }
        var folder = URL(fileURLWithPath: volume)
        for part in parts.dropLast() {
            folder.append(path: String(part))
            if (try? folder.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true { return nil }
        }
        return path
    }

    /// The current user's Trash folder (`.Trashes/<uid>`, where Finder puts what is deleted from that drive) on each
    /// external drive `holdsUserTrash` accepts, when `allowsExternalTrash` accepts it; by mount point.
    func externalTrashFolders() -> [URL] {
        mounts().filter(holdsUserTrash).sorted()
            .map { URL(fileURLWithPath: $0).appending(path: ".Trashes/\(getuid())") }
            .filter(allowsExternalTrash)
    }

    /// Smart Scan rule for an external drive's Trash, only ever emptied (its contents removed): the folder
    /// `<volume>/.Trashes/<uid>` of the current user or anything inside it, on a volume `holdsUserTrash` accepts. Neither
    /// `.Trashes` nor `<uid>` may be a symlink, `<uid>` must be owned by the user, and the item must be on that volume
    /// itself (no other volume mounted inside), not excluded. Another user's folder is never matched.
    func allowsExternalTrash(_ url: URL) -> Bool {
        let path = Self.normalize(url) // a symlinked `.Trashes` or `<uid>` above the item leaves the folder's path
        guard let volume = externalVolume(path), holdsUserTrash(volume), !isExcluded(path) else { return false }
        let trashes = volume + "/.Trashes", folder = trashes + "/\(getuid())"
        guard path == folder || path.hasPrefix(folder + "/") else { return false }
        var info = stat()
        guard lstat(trashes, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              lstat(folder, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { return false }
        guard let volumeDevice = device(volume), device(folder) == volumeDevice, device(path) == volumeDevice,
              !holdsMount(path) else { return false }
        return true
    }

    /// A mount point directly in `volumesFolder` (never `.timemachine` snapshots below it) of a local, writable,
    /// browsable volume that is not the startup disk nor a Time Machine backup disk: a drive whose own Trash
    /// (`.Trashes/<uid>`) takes what is deleted from it.
    private func holdsUserTrash(_ volume: String) -> Bool {
        guard volume.hasPrefix(volumesFolder + "/"), !volume.dropFirst(volumesFolder.count + 1).contains("/"),
              !volume.dropFirst(volumesFolder.count + 1).hasPrefix("."), let flags = flags(volume) else { return false }
        guard flags & UInt32(MNT_LOCAL) != 0,
              flags & UInt32(MNT_RDONLY | MNT_DONTBROWSE | MNT_ROOTFS) == 0 else { return false }
        var info = stat()
        return ["Backups.backupdb", ".com.apple.timemachine.donotpresent"].allSatisfy { lstat(volume + "/" + $0, &info) != 0 }
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
