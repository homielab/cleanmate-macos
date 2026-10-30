import Foundation

/// Node.js versions installed by nvm and Flutter SDKs installed by fvm, other than the one in use: 100–200 MB per Node
/// version, 1–2 GB per Flutter SDK, and `nvm install` / `fvm install` downloads them again. One entry per version,
/// unticked, deleted whole. A version a program runs from (its `node`, the Dart VM of a Flutter SDK, a global CLI
/// installed in it) is listed locked. `alias/`, `default`, `.nvmrc` and project files are never touched.
nonisolated enum OldRuntimes {
    static let nodeID = "nvm-old-node"
    static let flutterID = "fvm-old-flutter"

    /// `v20.11.1`: the folders nvm installs in `versions/node`.
    static func isNodeVersion(_ name: String) -> Bool { name.wholeMatch(of: /v\d+\.\d+\.\d+/) != nil }

    /// A real folder (not a symlink, not hidden) allowed by `policy`.
    static func isVersionFolder(_ url: URL, policy: SafetyPolicy) -> Bool {
        var info = stat()
        return !url.lastPathComponent.hasPrefix(".") && lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
            && policy.allows(url)
    }

    /// Versions the profile's `PATH` runs from (`~/.nvm/versions/node/v18.20.4/bin`): paths of their folders.
    static func pathVersions(home: URL, versionsFolder: URL) -> Set<String> {
        let base = versionsFolder.standardizedFileURL.path + "/"
        return Set(ShellEnvironment.pathFolders(home: home).compactMap { path in
            guard path.hasPrefix(base), let name = path.dropFirst(base.count).split(separator: "/").first else { return nil }
            return base + name
        })
    }

    // MARK: nvm

    /// The version `nvm alias default` resolves to among `installed`, as nvm does: an alias file may name another alias
    /// (`lts/iron`, `lts/*` in `alias/lts/`), `node`/`stable` (newest installed), a full or partial version (`20`,
    /// `v20.11`: newest installed match) or `system` (none). `.some(nil)`: no nvm version is the default (`system`).
    /// nil when it can't be told: no default alias, a name that resolves to nothing installed, a loop.
    static func nodeDefault(nvmDir: URL, installed: [String]) -> String?? {
        let alias = nvmDir.appending(path: "alias")
        guard var name = firstLine(of: alias.appending(path: "default")) else { return nil }
        for _ in 0..<10 {
            if name == "system" { return .some(nil) }
            if name == "node" || name == "stable" { return newest(installed).map { .some($0) } }
            let parts = name.split(separator: "/", omittingEmptySubsequences: false)
            if !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
               let next = firstLine(of: alias.appending(path: name)) {
                name = next
                continue
            }
            let version = name.hasPrefix("v") ? name : "v" + name
            if installed.contains(version) { return .some(version) }
            return newest(installed.filter { $0.hasPrefix(version + ".") }).map { .some($0) }
        }
        return nil
    }

    /// The highest of `versions` (`v20.9.0` < `v20.11.1`).
    static func newest(_ versions: [String]) -> String? {
        func numbers(_ version: String) -> [Int] { version.dropFirst().split(separator: ".").map { Int($0) ?? 0 } }
        return versions.max { numbers($0).lexicographicallyPrecedes(numbers($1)) }
    }

    /// `url` is `<nvm>/versions/node/vX.Y.Z`, not the default version nor one the profile's PATH runs.
    static func allowsNode(_ url: URL, policy: SafetyPolicy) -> Bool {
        let folder = url.deletingLastPathComponent()
        guard isNodeVersion(url.lastPathComponent), isVersionFolder(url, policy: policy),
              folder.lastPathComponent == "node", folder.deletingLastPathComponent().lastPathComponent == "versions"
        else { return false }
        let nvmDir = folder.deletingLastPathComponent().deletingLastPathComponent()
        let installed = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter(isNodeVersion) ?? []
        guard let kept = nodeDefault(nvmDir: nvmDir, installed: installed) else { return false }
        return url.lastPathComponent != kept
            && !pathVersions(home: policy.homeURL, versionsFolder: folder).contains(url.standardizedFileURL.path)
    }

    // MARK: fvm

    /// The version `<cache>/default` (fvm's global version, a symlink) points to. `.some(nil)` when there is none; nil
    /// when it can't be told (`default` is not a symlink or points somewhere else than `versions/`).
    static func flutterDefault(cache: URL) -> String?? {
        let link = cache.appending(path: "default")
        var info = stat()
        guard lstat(link.path, &info) == 0 else { return errno == ENOENT ? .some(nil) : nil }
        guard info.st_mode & S_IFMT == S_IFLNK,
              let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else { return nil }
        let resolved = (target.hasPrefix("/") ? URL(fileURLWithPath: target) : cache.appending(path: target)).standardizedFileURL
        let versions = cache.appending(path: "versions").standardizedFileURL
        guard resolved.deletingLastPathComponent().path == versions.path else { return nil }
        return .some(resolved.lastPathComponent)
    }

    /// `url` is `<fvm cache>/versions/<version>`, not the global version nor one the profile's PATH runs.
    static func allowsFlutter(_ url: URL, policy: SafetyPolicy) -> Bool {
        let folder = url.deletingLastPathComponent()
        guard isVersionFolder(url, policy: policy), folder.lastPathComponent == "versions",
              let kept = flutterDefault(cache: folder.deletingLastPathComponent()) else { return false }
        return url.lastPathComponent != kept
            && !pathVersions(home: policy.homeURL, versionsFolder: folder).contains(url.standardizedFileURL.path)
    }

    // MARK: Items

    /// Locks an entry a program runs from or works in (`RunningProcesses.usedPaths`, read once per check).
    static func locks(reason: String, running: @escaping @Sendable () -> [String]) -> @Sendable () -> @Sendable (URL) -> String? {
        {
            let paths = running()
            return { url in
                let path = url.standardizedFileURL.path
                return paths.contains { $0 == path || $0.hasPrefix(path + "/") } ? reason : nil
            }
        }
    }

    static func label(_ prefix: String) -> CleanerItem.EntryLabel {
        { url in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return (prefix + " " + url.lastPathComponent, date)
        }
    }

    /// `running` is injected by tests.
    static func nodeItem(running: @escaping @Sendable () -> [String] = RunningProcesses.usedPaths) -> CleanerItem {
        var item = CleanerItem(id: nodeID, title: "Old Node.js versions (nvm)",
                               note: "Node.js versions other than nvm's default, installed again with nvm install",
                               paths: ["~/.nvm/versions/node"], selectedByDefault: false,
                               shellFolders: ["NVM_DIR": ["versions/node"]], showsWhenEmpty: false, skipsOpenFiles: true,
                               entryLabel: label("Node"), selectableEntries: true,
                               allowsEntry: { policy, url in allowsNode(url, policy: policy) })
        item.locksEntry = locks(reason: String(localized: "A program runs from this version, so it is kept"),
                                running: running)
        return item
    }

    static func flutterItem(running: @escaping @Sendable () -> [String] = RunningProcesses.usedPaths) -> CleanerItem {
        var item = CleanerItem(id: flutterID, title: "Old Flutter SDKs (fvm)",
                               note: "Flutter versions other than fvm's global one, installed again with fvm install",
                               paths: ["~/fvm/versions"], selectedByDefault: false,
                               shellFolders: ["FVM_CACHE_PATH": ["versions"]], showsWhenEmpty: false, skipsOpenFiles: true,
                               entryLabel: label("Flutter"), selectableEntries: true,
                               allowsEntry: { policy, url in allowsFlutter(url, policy: policy) })
        item.locksEntry = locks(reason: String(localized: "A program runs from this version, so it is kept"),
                                running: running)
        return item
    }

    /// The first line of a small regular file, trimmed; nil when missing, empty or unreadable.
    private static func firstLine(of file: URL) -> String? {
        var info = stat()
        guard stat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 4096,
              let text = try? String(contentsOf: file, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces),
              !line.isEmpty else { return nil }
        return line
    }
}
