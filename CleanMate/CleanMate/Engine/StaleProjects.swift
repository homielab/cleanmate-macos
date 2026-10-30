import Foundation

/// Folders a tool makes again for projects nobody worked on for `days` days: JavaScript's `node_modules`
/// (`StaleNodeModules`), Cargo's `target`, a Python virtual environment and CocoaPods' `Pods` (`StaleBuildFolders`).
/// A project is a folder holding such a folder next to the file that makes it (`projectFolders`), found in the usual
/// project folders up to `depth` levels down by one walk that both Smart Scan items share (`find(in:policy:…)`).
nonisolated enum StaleProjects {
    /// Where projects usually live. Documents and Desktop only with Full Disk Access (macOS asks otherwise).
    static let folders = ["~/Developer", "~/Projects", "~/Code", "~/src", "~/Documents", "~/Desktop"]
    /// Folder levels below each of `folders` where a project may be (`~/Developer/client/app` = 2).
    static let depth = 4
    /// Folders read at most per walk: a huge Documents folder is not walked to the end (a few tenths of a second).
    static let folderLimit = 20_000
    /// Not worked on for this long. A constant, not a Settings age: these folders are slow to make again.
    static let days = 90
    /// Folder name extensions that are bundles, never walked (a package's node_modules belongs to the app).
    static let bundleExtensions: Set = ["app", "bundle", "framework", "plugin", "xcodeproj", "xcworkspace", "photoslibrary",
                                         "musiclibrary", "tvlibrary", "photolibrary", "fcpbundle", "logicx", "band"]
    /// Dependencies and build output, never walked into (hidden ones such as `.venv` never are anyway): what they hold
    /// belongs to the project around them.
    static let unwalked: Set = ["node_modules", "target", "Pods", "venv"]
    /// A walk's result is handed to calls for the same folders this long after it started: both items of one scan.
    static let reuseTime = Duration.seconds(10)

    /// Names of the folders a tool makes that `folder` holds next to the file that makes them, from its `readdir`
    /// names and types (`children`): `node_modules` by `package.json`, `target` by `Cargo.toml`, `Pods` by `Podfile`,
    /// `.venv` or `venv` holding `pyvenv.cfg` by `pyproject.toml`, `setup.py` or a `requirements*.txt`. Only real
    /// folders next to regular files count (a symlink is neither).
    static func projectFolders(in folder: String, children: [String: UInt8]) -> [String] {
        let file = UInt8(DT_REG), directory = UInt8(DT_DIR)
        var found: [String] = []
        if children["package.json"] == file, children["node_modules"] == directory { found.append("node_modules") }
        if children["Cargo.toml"] == file, children["target"] == directory { found.append("target") }
        if children["Podfile"] == file, children["Pods"] == directory { found.append("Pods") }
        if children["pyproject.toml"] == file || children["setup.py"] == file
            || children.contains(where: { $0.value == file && isRequirements($0.key) }) {
            for name in [".venv", "venv"] where children[name] == directory {
                var info = stat()
                if lstat(folder + "/" + name + "/pyvenv.cfg", &info) == 0, info.st_mode & S_IFMT == S_IFREG { found.append(name) }
            }
        }
        return found
    }

    /// `requirements.txt`, `requirements-dev.txt`…
    static func isRequirements(_ name: String) -> Bool { name.hasPrefix("requirements") && name.hasSuffix(".txt") }

    /// Whether `path` is a real folder that its parent holds as one of its `projectFolders`.
    static func isProjectFolder(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return false }
        let parent = (path as NSString).deletingLastPathComponent
        return projectFolders(in: parent, children: entries(of: parent)).contains((path as NSString).lastPathComponent)
    }

    /// The project folders in `roots` (an item's `Scanner.roots`), leaving out what macOS guards without Full Disk
    /// Access: one walk for every item of a scan (see `shared`).
    static func find(in roots: [URL], policy: SafetyPolicy, hasFullDiskAccess: Bool) async -> [URL] {
        let skipped = ProtectedFolders.skipped(home: policy.homeURL, hasFullDiskAccess: hasFullDiskAccess)
        return await shared(in: roots.filter { !ProtectedFolders.contains(skipped, $0) }, skipping: skipped)
    }

    private static let walks = Locked<[String: (started: ContinuousClock.Instant, walk: Task<[URL], Never>)]>([:])

    /// `find(in:skipping:)`, walked once for the same folders: a call while that walk runs, or within `reuseTime` after
    /// it started, gets its result (Smart Scan scans node_modules and build folders at the same time).
    static func shared(in roots: [URL], skipping: Set<String>) async -> [URL] {
        let key = roots.map(\.standardizedFileURL.path).joined(separator: "\n") + "\n\n" + skipping.sorted().joined(separator: "\n")
        let walk = walks.withLock { walks in
            let now = ContinuousClock.now
            walks = walks.filter { $0.value.started.duration(to: now) < reuseTime }
            if let walk = walks[key]?.walk { return walk }
            let walk = Task { await find(in: roots, skipping: skipping) }
            walks[key] = (now, walk)
            return walk
        }
        return await walk.value
    }

    /// Project folders (`projectFolders`) in `roots` and up to `depth` folder levels below them, by path.
    /// Never follows a symlink, never enters a hidden folder, one of `unwalked`, a bundle, a folder of `skipping` or
    /// another volume; stops after `folderLimit` folders, shared by all roots, or when cancelled.
    /// Each root is walked by its own task, and the folders of each level are read in parallel.
    static func find(in roots: [URL], skipping: Set<String> = [], depth: Int = depth,
                     folderLimit: Int = folderLimit) async -> [URL] {
        let budget = Locked(folderLimit)
        let found = await withTaskGroup(of: [URL].self) { group in
            for root in roots { group.addTask { await walk(root, skipping: skipping, depth: depth, budget: budget) } }
            return await group.reduce(into: []) { $0 += $1 }
        }
        return found.sorted { $0.path < $1.path }
    }

    /// `find` in one root, taking the folders it reads from `budget`; a level's folders are read in path order, so
    /// the ones left out when the budget runs out are the last ones.
    private static func walk(_ root: URL, skipping: Set<String>, depth: Int, budget: Locked<Int>) async -> [URL] {
        let rootPath = root.standardizedFileURL.path
        var info = stat()
        guard lstat(rootPath, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return [] }
        let device = info.st_dev
        var found: [URL] = []
        var level = [rootPath]
        for current in 0...depth where !level.isEmpty && !Task.isCancelled {
            let taken = budget.withLock { left in
                let taken = min(left, level.count)
                left -= taken
                return taken
            }
            let folders = Array(level.prefix(taken))
            // A few slices per core: a level holds from one folder to thousands.
            let slice = max(1, (folders.count + 4 * ProcessInfo.processInfo.activeProcessorCount - 1)
                            / (4 * ProcessInfo.processInfo.activeProcessorCount))
            let read = await withTaskGroup(of: (found: [URL], next: [String]).self) { group in
                for start in stride(from: 0, to: folders.count, by: slice) {
                    group.addTask {
                        var found: [URL] = [], next: [String] = []
                        for folder in folders[start..<min(start + slice, folders.count)] {
                            let children = entries(of: folder)
                            for name in projectFolders(in: folder, children: children) {
                                found.append(URL(fileURLWithPath: folder + "/" + name, isDirectory: true))
                            }
                            guard current < depth else { continue }
                            var info = stat()
                            for (name, type) in children where type == UInt8(DT_DIR) && !name.hasPrefix(".")
                                && !unwalked.contains(name) && !bundleExtensions.contains((name as NSString).pathExtension.lowercased()) {
                                let path = folder + "/" + name
                                guard !skipping.contains(path), lstat(path, &info) == 0, info.st_dev == device else { continue }
                                next.append(path)
                            }
                        }
                        return (found, next)
                    }
                }
                return await group.reduce(into: (found: [URL](), next: [String]())) { $0.found += $1.found; $0.next += $1.next }
            }
            found += read.found
            level = taken < level.count ? [] : read.next.sorted()
        }
        return found
    }

    /// Names in `folder` with their `readdir` type (`DT_DIR`, `DT_REG`, `DT_LNK`…): no stat per entry.
    static func entries(of folder: String) -> [String: UInt8] {
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

    /// Newest modification date of `folder` itself, of the `markers` of the project holding it and of each folder above
    /// it below `home`, and of the project's own files `projectFile` accepts (`requirements*.txt`); nil when `folder` is
    /// gone. A `.git` file (a worktree, a submodule) leads to its own Git folder's index.
    static func lastWorkedOn(_ folder: URL, markers: [String], projectFile: ((String) -> Bool)? = nil, home: URL) -> Date? {
        var info = stat()
        let path = folder.standardizedFileURL.path
        guard lstat(path, &info) == 0 else { return nil }
        var newest = info.st_mtimespec
        func consider(_ file: String) {
            var info = stat()
            if lstat(file, &info) == 0, (info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec) > (newest.tv_sec, newest.tv_nsec) {
                newest = info.st_mtimespec
            }
        }
        let homePath = home.standardizedFileURL.path
        var current = (path as NSString).deletingLastPathComponent
        if let projectFile {
            for name in entries(of: current).keys where projectFile(name) { consider(current + "/" + name) }
        }
        while current.hasPrefix(homePath + "/") {
            for marker in markers { consider(current + "/" + marker) }
            if let gitFolder = gitFolder(linkedFrom: current + "/.git") { consider(gitFolder + "/index") }
            current = (current as NSString).deletingLastPathComponent
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

    /// Whether one of `folders` (where a project's tools run, or paths they were given) is `project` or inside it.
    static func isUsed(_ project: URL, by folders: [String]) -> Bool {
        let path = RunningProcesses.withoutPrivate(project.standardizedFileURL.path)
        return folders.contains { $0 == path || $0.hasPrefix(path + "/") }
    }

    /// The Smart Scan item's per-entry skip: a project a tool runs in (`running`, read once per scan) or one worked on
    /// within `days` before `now`.
    static func skipsEntry(running: @escaping @Sendable () -> [String], now: @escaping @Sendable () -> Date,
                           lastWorkedOn: @escaping @Sendable (URL) -> Date?) -> @Sendable () -> @Sendable (URL) -> Bool {
        {
            let busy = running(), cutoff = now().addingTimeInterval(-Double(days) * 86_400)
            return { url in
                isUsed(url.deletingLastPathComponent(), by: busy) || lastWorkedOn(url).map { $0 >= cutoff } ?? true
            }
        }
    }
}
