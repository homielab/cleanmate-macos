import Foundation

/// Old Unity Editor versions (5–15 GB each) that Unity Hub installs side by side and never removes: each
/// `<version>` folder (`2022.3.10f1`, `6000.0.23f1`) directly in `/Applications/Unity/Hub/Editor`,
/// `~/Applications/Unity/Hub/Editor` and the install folder set in Unity Hub (`secondaryInstallPath.json`), holding a
/// real `Unity.app` whose `Info.plist` names the Unity Editor's bundle id. Only real folders, never through a symlink.
/// Kept, never listed (asked at scan and again right before removal): the newest version and the newest release (a
/// newer alpha or beta doesn't replace it), every version a project pins in `ProjectSettings/ProjectVersion.txt`
/// (`m_EditorVersion`) in `StaleProjects.folders` or in Unity Hub's project list (`projects-v1.json`, which also gives
/// each project's version), a version whose folder name and `Unity.app` disagree, and everything when Hub's project
/// list can't be read. So with one editor nothing is listed. Unticked, moved to the Trash so Undo puts it back.
/// Root-owned or non-writable ones are locked rows with a reason (never a password prompt), and so is one a program
/// runs from (that version's `Unity`, its bundled tools), matched by path.
nonisolated enum UnityEditors {
    static let id = "unity-old-editors"
    static let cachesID = "unity-caches"
    /// `com.unity3d.UnityEditor5.x` for every editor since Unity 5.
    static let editorBundleIDPrefix = "com.unity3d.UnityEditor"
    static let hubBundleID = "com.unity3d.unityhub"
    /// Where Hub installs editors below each application folder.
    static let hubEditorSubpath = "Unity/Hub/Editor"
    /// Hub's settings, below the home folder.
    static let hubSettings = "Library/Application Support/UnityHub"
    /// The install folder chosen in Hub › Settings › Installs: a JSON string (empty when not changed).
    static let secondaryInstallFile = "secondaryInstallPath.json"
    /// The projects Hub lists: `{"data": {"<path>": {"path": …, "version": "2022.3.10f1"}}}`.
    static let projectsFile = "projects-v1.json"
    static let projectVersionFile = "ProjectSettings/ProjectVersion.txt"
    /// Largest file read: Hub's project list of hundreds of projects stays well below.
    static let fileLimit = 4 << 20

    // MARK: - Versions

    /// A Unity version: `2022.3.10f1` (`f` final), `2023.1.0b5` (beta), `2021.3.0a12` (alpha), `2019.4.40f1c1` (a
    /// China build), `2017.4.3p2` (an old patch release).
    struct Version: Comparable, Hashable, Sendable {
        let major: Int, minor: Int, patch: Int
        /// x (experimental) < a < b < f < p.
        let stage: Int
        let build: Int
        let china: Int

        var isRelease: Bool { stage >= 3 }

        init?(_ text: String) {
            guard let match = text.trimmingCharacters(in: .whitespaces)
                    .wholeMatch(of: /(\d{1,5})\.(\d{1,4})\.(\d{1,4})([xabfp])(\d{1,4})(?:c(\d{1,4}))?/),
                  let major = Int(match.1), let minor = Int(match.2), let patch = Int(match.3),
                  let stage = "xabfp".firstIndex(of: Character(String(match.4))), let build = Int(match.5) else { return nil }
            (self.major, self.minor, self.patch) = (major, minor, patch)
            self.stage = "xabfp".distance(from: "xabfp".startIndex, to: stage)
            self.build = build
            china = match.6.flatMap { Int($0) } ?? 0
        }

        static func < (lhs: Version, rhs: Version) -> Bool {
            (lhs.major, lhs.minor, lhs.patch, lhs.stage, lhs.build, lhs.china)
                < (rhs.major, rhs.minor, rhs.patch, rhs.stage, rhs.build, rhs.china)
        }
    }

    // MARK: - Editors

    /// One installed editor.
    struct Install: Equatable, Sendable {
        let url: URL
        /// The folder name read as a version (Hub names each folder after its version).
        let version: Version?
        /// `CFBundleVersion` of `Unity.app`, when it reads as a version.
        let appVersion: Version?
    }

    /// The editor in the folder `url`, or nil: not a real, not hidden folder holding a real `Unity.app` with the Unity
    /// Editor's bundle id.
    static func install(at url: URL) -> Install? {
        var info = stat()
        guard !url.lastPathComponent.hasPrefix("."), lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        let app = url.appending(path: "Unity.app")
        guard lstat(app.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              let data = contents(app.appending(path: "Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              (plist["CFBundleIdentifier"] as? String)?.hasPrefix(editorBundleIDPrefix) == true else { return nil }
        return Install(url: url, version: Version(url.lastPathComponent),
                       appVersion: (plist["CFBundleVersion"] as? String).flatMap(Version.init))
    }

    /// The editors directly in each of `folders` (never deeper), by path; a folder listed twice counts once.
    static func installs(in folders: [URL]) -> [Install] {
        var seen = Set<String>()
        return folders.filter { seen.insert($0.standardizedFileURL.path).inserted }.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
                .compactMap { install(at: folder.appending(path: $0)) }
        }
    }

    /// The folders Hub installs editors in: `Unity/Hub/Editor` in each of `applications`, and the install folder set in
    /// Hub (an absolute path).
    static func editorFolders(applications: [URL], home: URL) -> [URL] {
        applications.map { $0.appending(path: hubEditorSubpath) } + [secondaryInstallFolder(home: home)].compactMap { $0 }
    }

    /// The install folder set in Hub's settings, nil when none is (or it isn't an absolute path).
    static func secondaryInstallFolder(home: URL) -> URL? {
        guard let data = contents(home.appending(path: hubSettings).appending(path: secondaryInstallFile)),
              let path = (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) as? String,
              path.hasPrefix("/"), path.count > 1 else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    /// Paths of the `installs` to keep: every version that can't be read or whose app says another one, the pinned
    /// ones, the newest and the newest release (all copies of each).
    static func kept(_ installs: [Install], pins: Set<Version>) -> Set<String> {
        var kept = Set<String>()
        for install in installs {
            let readable = install.version.map { version in install.appVersion.map { $0 == version } ?? true } ?? false
            if !readable || install.version.map(pins.contains) == true { kept.insert(install.url.standardizedFileURL.path) }
        }
        let versions = installs.compactMap(\.version)
        for newest in [versions.max(), versions.filter(\.isRelease).max()].compactMap({ $0 }) {
            for install in installs where install.version == newest { kept.insert(install.url.standardizedFileURL.path) }
        }
        return kept
    }

    /// The editors in `folders` the item lists: not kept, and allowed by `SafetyPolicy.allowsUnityEditor` (locked rows
    /// are listed, so ownership is checked by `locksEntry`). Nothing when the pins can't be read.
    static func find(in folders: [URL], policy: SafetyPolicy, pins: () -> Set<Version>?) -> [URL] {
        let found = installs(in: folders)
        guard found.count > 1, let pins = pins() else { return [] }
        let kept = kept(found, pins: pins)
        return found.map(\.url).filter {
            !kept.contains($0.standardizedFileURL.path) && policy.allowsUnityEditor($0, in: folders, writableOnly: false)
        }
    }

    /// `url` is one `find` lists now.
    static func allows(_ url: URL, policy: SafetyPolicy, folders: [URL], pins: () -> Set<Version>?) -> Bool {
        let path = url.standardizedFileURL.path
        return find(in: folders, policy: policy, pins: pins).contains { $0.standardizedFileURL.path == path }
    }

    /// `Unity 2022.3.10f1`; dated when it was installed (its folder last changed).
    static func label(of url: URL) -> (title: String, date: Date?)? {
        ("Unity " + url.lastPathComponent, (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)
    }

    // MARK: - Pins

    /// The editor version `ProjectVersion.txt` names (`m_EditorVersion: 2022.3.10f1`).
    static func projectVersion(_ text: String) -> Version? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "m_EditorVersion" {
                return Version(String(parts[1]))
            }
        }
        return nil
    }

    /// Project paths and versions in Hub's project list (each object with a `path`, wherever it is); nil when the file
    /// is there but can't be read, empty when there is none.
    static func hubProjects(home: URL) -> [(path: String, version: Version?)]? {
        let file = home.appending(path: hubSettings).appending(path: projectsFile)
        var info = stat()
        guard lstat(file.path, &info) == 0 else { return [] }
        guard let data = contents(file), let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var found: [(path: String, version: Version?)] = []
        func walk(_ value: Any) {
            if let object = value as? [String: Any] {
                if let path = object["path"] as? String, path.hasPrefix("/") {
                    found.append((path, (object["version"] as? String).flatMap(Version.init)))
                }
                object.values.forEach(walk)
            } else if let array = value as? [Any] {
                array.forEach(walk)
            }
        }
        walk(json)
        return found
    }

    /// Every version pinned by a project in `StaleProjects.folders` below `home` or in Hub's project list (without
    /// what macOS guards when there is no Full Disk Access); nil when Hub's list can't be read.
    static func pins(home: URL, hasFullDiskAccess: Bool) -> Set<Version>? {
        guard let hub = hubProjects(home: home) else { return nil }
        var pins = Set(hub.compactMap(\.version))
        let skipped = ProtectedFolders.skipped(home: home, hasFullDiskAccess: hasFullDiskAccess)
        func read(_ project: String) {
            if let data = contents(URL(fileURLWithPath: project).appending(path: projectVersionFile)),
               let version = projectVersion(String(decoding: data, as: UTF8.self)) {
                pins.insert(version)
            }
        }
        for project in hub where !ProtectedFolders.contains(skipped, URL(fileURLWithPath: project.path)) { read(project.path) }
        let roots = StaleProjects.folders.map { home.appending(path: String($0.dropFirst(2))) }
            .filter { !ProtectedFolders.contains(skipped, $0) }
        StaleProjects.visit(roots, skipping: skipped) { folder, children in
            if children["ProjectSettings"] == UInt8(DT_DIR) { read(folder) }
        }
        return pins
    }

    /// Pins read for a scan, handed to the checks of the next `StaleProjects.reuseTime`: one walk for all entries, a
    /// fresh one for a later clean.
    final class PinCache: Sendable {
        static let shared = PinCache()
        private let cached = Locked<(key: String, started: ContinuousClock.Instant, pins: Set<Version>?)?>(nil)

        func pins(home: URL, hasFullDiskAccess: Bool) -> Set<Version>? {
            let key = home.standardizedFileURL.path + "\n\(hasFullDiskAccess)"
            if let hit = cached.withLock({ $0 }), hit.key == key, hit.started.duration(to: .now) < StaleProjects.reuseTime {
                return hit.pins
            }
            let started = ContinuousClock.now
            let pins = UnityEditors.pins(home: home, hasFullDiskAccess: hasFullDiskAccess)
            cached.withLock { $0 = (key, started, pins) }
            return pins
        }
    }

    // MARK: - Items

    /// The Smart Scan item. `folders` (where editors are searched), `owner`, `running` (paths programs run from),
    /// `hasFullDiskAccess`, `pins` and `sizes` are injected by tests, which must never reach the real /Applications.
    static func item(folders: @escaping @Sendable (SafetyPolicy) -> [URL] = {
                         editorFolders(applications: $0.applicationFolders, home: $0.homeURL)
                     },
                     owner: @escaping SafetyPolicy.OwnerID = SafetyPolicy.ownerID,
                     running: @escaping @Sendable () -> [String] = RunningProcesses.usedPaths,
                     hasFullDiskAccess: @escaping @Sendable () -> Bool = { FullDiskAccess.isGranted },
                     pins: PinCache = .shared, sizes: FolderSizeCache = .shared) -> CleanerItem {
        @Sendable func read(_ policy: SafetyPolicy) -> Set<Version>? {
            pins.pins(home: policy.homeURL, hasFullDiskAccess: hasFullDiskAccess())
        }
        // Unticked: an older editor may be kept on purpose (a project outside the project folders). To the Trash, so
        // Undo puts it back. Not skipped while Unity runs: only a version a program runs from is locked.
        var item = CleanerItem(id: id, title: "Old Unity Editor versions",
                               note: "Unity Hub editors other than the newest and those your projects use. Install them again from Unity Hub. Moved to the Trash",
                               paths: [], mode: .trash, selectedByDefault: false, showsWhenEmpty: false,
                               entryLabel: label(of:), selectableEntries: true,
                               findEntries: { _, policy in find(in: folders(policy), policy: policy) { read(policy) } },
                               allowsEntry: { policy, url in
                                   allows(url, policy: policy, folders: folders(policy)) { read(policy) }
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

    /// Unity's package and build cache and the Asset Store packages it downloaded, in `~/Library/Unity`: one row
    /// each, unticked, deleted (downloaded again when a project needs them). Never `Licenses` nor anything else
    /// there. Skipped while the Unity Editor or Unity Hub runs; a file still open is kept.
    static func cachesItem() -> CleanerItem {
        CleanerItem(id: cachesID, title: "Unity caches",
                    note: "Unity's package and build cache and downloaded Asset Store packages, downloaded again when a project needs them",
                    paths: ["~/Library/Unity"], included: cacheNames, selectedByDefault: false,
                    showsWhenEmpty: false, runningAppBundleIDs: [editorBundleIDPrefix + "*", hubBundleID],
                    runningProcessNames: ["Unity", "Unity Hub"], skipsOpenFiles: true, entryLabel: cacheLabel(of:),
                    selectableEntries: true)
    }

    static let cacheNames = ["cache", "Asset Store-5.x"]

    static func cacheLabel(of url: URL) -> (title: String, date: Date?)? {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        switch url.lastPathComponent {
        case "cache": return (String(localized: "Package and build cache"), date)
        case "Asset Store-5.x": return (String(localized: "Downloaded Asset Store packages"), date)
        default: return nil
        }
    }

    // MARK: - Files

    /// A regular file of at most `fileLimit` (not through a symlink); nil when it can't be read.
    private static func contents(_ url: URL) -> Data? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= fileLimit else { return nil }
        return FileManager.default.contents(atPath: url.path)
    }
}
