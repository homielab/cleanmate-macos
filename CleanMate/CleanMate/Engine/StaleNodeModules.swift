import Foundation

/// `node_modules` folders of JavaScript projects nobody worked on for `days` days. `npm install` (or Bun, pnpm, Yarn)
/// brings one back, but needs the network: one entry per project, unticked, moved to the Trash.
/// A project is a folder holding `package.json` and `node_modules`, found in the usual project folders up to `depth`
/// levels down; it is stale when its manifest, lockfiles, Git index and `node_modules` folder itself, and those of
/// every folder above it in the home folder (a package of a monorepo, a project inside a repository), are all older.
nonisolated enum StaleNodeModules {
    static let folderName = "node_modules"
    static let manifest = "package.json"
    /// Where projects usually live. Documents and Desktop only with Full Disk Access (macOS asks otherwise).
    static let folders = ["~/Developer", "~/Projects", "~/Code", "~/src", "~/Documents", "~/Desktop"]
    /// Folder levels below each of `folders` where a project may be (`~/Developer/client/app` = 2).
    static let depth = 4
    /// Folders read at most per scan: a huge Documents folder is not walked to the end (a few tenths of a second).
    static let folderLimit = 20_000
    /// Not worked on for this long. A constant, not a Settings age: the folder is slow to download again.
    static let days = 90
    /// Files that change when a project's dependencies change or work on it is committed (`.git/index`).
    static let markers = ["package.json", "package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml",
                          "bun.lock", "bun.lockb", ".git/index"]
    /// Tools whose processes keep a project in use while they run in it (pnpm, npm and Yarn run as `node`).
    static let tools: Set = ["node", "bun", "pnpm", "npm", "npx", "yarn", "deno"]
    /// Folder name extensions that are bundles, never walked (a package's node_modules belongs to the app).
    static let bundleExtensions: Set = ["app", "bundle", "framework", "plugin", "xcodeproj", "xcworkspace", "photoslibrary",
                                         "musiclibrary", "tvlibrary", "photolibrary", "fcpbundle", "logicx", "band"]

    /// The Smart Scan item. `home`, `hasFullDiskAccess`, `running` (`RunningProcesses.folders`) and `now` are injected
    /// by tests.
    static func item(home: URL = URL(fileURLWithPath: NSHomeDirectory()),
                     hasFullDiskAccess: @escaping @Sendable () -> Bool = { FullDiskAccess.isGranted },
                     running: @escaping @Sendable () -> [String] = { RunningProcesses.folders(ofProcessesNamed: isTool) },
                     now: @escaping @Sendable () -> Date = { .now }) -> CleanerItem {
        CleanerItem(id: "stale-node-modules", title: "Stale node_modules",
                    note: "Projects whose package.json, lockfile and Git index were not modified for 90 days. Moved to the Trash; npm install brings them back",
                    paths: folders, mode: .trash, selectedByDefault: false, showsWhenEmpty: false, skipsOpenFiles: true,
                    skipsEntry: {
                        let busy = running(), cutoff = now().addingTimeInterval(-Double(days) * 86_400)
                        return { url in
                            let project = url.deletingLastPathComponent()
                            return isUsed(project, by: busy) || lastWorkedOn(url, home: home).map { $0 >= cutoff } ?? true
                        }
                    },
                    entryLabel: { url in
                        (url.deletingLastPathComponent().lastPathComponent, lastWorkedOn(url, home: home))
                    },
                    selectableEntries: true,
                    findEntries: { roots, policy in
                        let skipped = ProtectedFolders.skipped(home: policy.homeURL, hasFullDiskAccess: hasFullDiskAccess())
                        return find(in: roots.filter { !ProtectedFolders.contains(skipped, $0) }, skipping: skipped)
                    },
                    allowsEntry: { $0.allowsNodeModules($1) })
    }

    /// `node`, `node22`, `bun`, `pnpm`…
    static func isTool(_ name: String) -> Bool {
        tools.contains(name) || name.hasPrefix("node") && RunningProcesses.isInterpreter(name)
    }

    /// `node_modules` folders next to a `package.json`, in `roots` and up to `depth` folder levels below them, by path.
    /// Never follows a symlink, never enters a hidden folder, a `node_modules` (nested ones are a package's own), a
    /// bundle, a folder of `skipping` or another volume; stops after `folderLimit` folders, or when cancelled.
    static func find(in roots: [URL], skipping: Set<String> = [], depth: Int = depth,
                     folderLimit: Int = folderLimit) -> [URL] {
        var found: [URL] = []
        var read = 0
        for root in roots {
            let rootPath = root.standardizedFileURL.path
            var info = stat()
            guard lstat(rootPath, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
            let device = info.st_dev
            var level = [rootPath]
            for current in 0...depth {
                var next: [String] = []
                for folder in level {
                    guard read < folderLimit, !Task.isCancelled else { return found.sorted { $0.path < $1.path } }
                    read += 1
                    let children = entries(of: folder)
                    if children[manifest] == UInt8(DT_REG), children[folderName] == UInt8(DT_DIR) {
                        found.append(URL(fileURLWithPath: folder + "/" + folderName, isDirectory: true))
                    }
                    guard current < depth else { continue }
                    for (name, type) in children where type == UInt8(DT_DIR) && !name.hasPrefix(".") && name != folderName
                        && !bundleExtensions.contains((name as NSString).pathExtension.lowercased()) {
                        let path = folder + "/" + name
                        guard !skipping.contains(path), lstat(path, &info) == 0, info.st_dev == device else { continue }
                        next.append(path)
                    }
                }
                level = next.sorted()
            }
        }
        return found.sorted { $0.path < $1.path }
    }

    /// Names in `folder` with their `readdir` type (`DT_DIR`, `DT_REG`, `DT_LNK`…): no stat per entry.
    private static func entries(of folder: String) -> [String: UInt8] {
        guard let dir = opendir(folder) else { return [:] }
        defer { closedir(dir) }
        var names: [String: UInt8] = [:]
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                String(decoding: bytes.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != ".", name != ".." { names[name] = entry.pointee.d_type }
        }
        return names
    }

    /// Newest modification date of the `markers` of the project holding `nodeModules` and of each folder above it below
    /// `home`, and of `nodeModules` itself; nil when `nodeModules` is gone.
    /// A `.git` file (a worktree, a submodule) leads to its own Git folder's index.
    static func lastWorkedOn(_ nodeModules: URL, home: URL) -> Date? {
        var info = stat()
        let path = nodeModules.standardizedFileURL.path
        guard lstat(path, &info) == 0 else { return nil }
        var newest = info.st_mtimespec
        func consider(_ file: String) {
            var info = stat()
            if lstat(file, &info) == 0, (info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec) > (newest.tv_sec, newest.tv_nsec) {
                newest = info.st_mtimespec
            }
        }
        let homePath = home.standardizedFileURL.path
        var folder = (path as NSString).deletingLastPathComponent
        while folder.hasPrefix(homePath + "/") {
            for marker in markers { consider(folder + "/" + marker) }
            if let gitFolder = gitFolder(linkedFrom: folder + "/.git") { consider(gitFolder + "/index") }
            folder = (folder as NSString).deletingLastPathComponent
        }
        return Date(timeIntervalSince1970: Double(newest.tv_sec) + Double(newest.tv_nsec) * 1e-9)
    }

    /// The Git folder a `.git` file names (`gitdir: <path>`, relative to the file's folder or absolute); nil for a
    /// `.git` folder or anything else.
    static func gitFolder(linkedFrom file: String) -> String? {
        var info = stat()
        guard lstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size < 4096,
              let text = try? String(contentsOfFile: file, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first, line.hasPrefix("gitdir:") else { return nil }
        let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        if target.hasPrefix("/") { return target }
        return (((file as NSString).deletingLastPathComponent as NSString).appendingPathComponent(target) as NSString).standardizingPath
    }

    /// Whether one of `folders` (where node, Bun, pnpm… run, or paths they were given) is `project` or inside it.
    static func isUsed(_ project: URL, by folders: [String]) -> Bool {
        let path = RunningProcesses.withoutPrivate(project.standardizedFileURL.path)
        return folders.contains { $0 == path || $0.hasPrefix(path + "/") }
    }
}
