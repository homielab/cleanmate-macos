import Foundation

/// Folders a tool makes again for projects nobody worked on for `days` days: JavaScript's `node_modules`
/// (`StaleNodeModules`), build folders (`StaleBuildFolders`: Cargo, Gradle, Flutter, Next.js…) and Terraform's
/// downloads (`StaleTerraform`).
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
    /// Dependencies and build output, never walked into (hidden ones such as `.venv` never are anyway, nor any folder
    /// found next to the file that makes it, such as Gradle's `build`): what they hold belongs to the project around them.
    static let unwalked: Set = ["node_modules", "target", "Pods", "venv"]
    /// A walk's result is handed to calls for the same folders this long after it started: both items of one scan.
    static let reuseTime = Duration.seconds(10)

    /// Names of the folders a tool makes that `folder` holds next to the file that makes them, from its `readdir`
    /// names and types (`children`), relative to `folder`: `node_modules` by `package.json`, `.terraform/providers` and
    /// `.terraform/modules` by a `*.tf` file (Terraform, OpenTofu), and the build folders of `buildFolders`. Only real
    /// folders next to regular files count (a symlink is neither).
    static func projectFolders(in folder: String, children: [String: UInt8]) -> [String] {
        let file = UInt8(DT_REG), directory = UInt8(DT_DIR)
        var found: [String] = []
        if children["package.json"] == file, children["node_modules"] == directory { found.append("node_modules") }
        found += buildFolders(in: folder, children: children)
        if children[".terraform"] == directory, children.contains(where: { $0.value == file && $0.key.hasSuffix(".tf") }) {
            for name in StaleTerraform.folderNames where isFolder(folder + "/.terraform/" + name) {
                found.append(".terraform/" + name)
            }
        }
        return found
    }

    /// The build folders `folder` holds, relative to it, each only next to the file that makes it:
    /// - Cargo: `target` by `Cargo.toml`; Maven: `target` by `pom.xml`; CocoaPods: `Pods` by `Podfile`;
    /// - Python: `.venv` or `venv` holding `pyvenv.cfg` by `pyproject.toml`, `setup.py` or a `requirements*.txt`;
    /// - Gradle and Android: `build` and `.gradle` by `build.gradle(.kts)` or `settings.gradle(.kts)`, and
    ///   `<module>/build` of each first-level module holding its own `build.gradle(.kts)` (Android's `app/build`);
    /// - SwiftPM: `.build` by `Package.swift`; Flutter and Dart: `.dart_tool` and `build` by `pubspec.yaml`;
    /// - with a `package.json`: `.next` by `next.config.*`, `.nuxt` and `.output` by `nuxt.config.*`, `.svelte-kit`
    ///   by `svelte.config.*`, `.angular/cache` by `angular.json`, `.turbo` by `turbo.json`;
    /// - Haskell: `.stack-work` by `stack.yaml`, `dist-newstyle` by `cabal.project` or a `*.cabal`;
    /// - Elixir: `_build` and `deps` by `mix.exs`; Zig: `.zig-cache` and `zig-cache` by `build.zig` (never `zig-out`,
    ///   what the project installs).
    /// Never a name such as `build`, `dist` or `out` without the file that makes it.
    static func buildFolders(in folder: String, children: [String: UInt8]) -> [String] {
        let file = UInt8(DT_REG), directory = UInt8(DT_DIR)
        func has(_ name: String) -> Bool { children[name] == file }
        func hasFile(where test: (String) -> Bool) -> Bool { children.contains { $0.value == file && test($0.key) } }
        func config(_ name: String) -> Bool { hasFile { $0.hasPrefix(name + ".config.") } }
        var found: [String] = []
        func add(_ names: String..., when condition: Bool) {
            guard condition else { return }
            for name in names where children[name] == directory && !found.contains(name) { found.append(name) }
        }
        add("target", when: has("Cargo.toml") || has("pom.xml"))
        add("Pods", when: has("Podfile"))
        if has("pyproject.toml") || has("setup.py") || hasFile(where: isRequirements) {
            for name in [".venv", "venv"] where children[name] == directory && isFile(folder + "/" + name + "/pyvenv.cfg") {
                found.append(name)
            }
        }
        let gradle = isGradleProject(children)
        add("build", ".gradle", when: gradle)
        if gradle {
            for (name, type) in children.sorted(by: { $0.key < $1.key }) where type == directory && !name.hasPrefix(".")
                && name != "build" && !bundleExtensions.contains((name as NSString).pathExtension.lowercased()) {
                let module = folder + "/" + name
                if gradleBuildFiles.contains(where: { isFile(module + "/" + $0) }), isFolder(module + "/build") {
                    found.append(name + "/build")
                }
            }
        }
        add(".build", when: has("Package.swift"))
        add(".dart_tool", "build", when: has("pubspec.yaml"))
        if has("package.json") {
            add(".next", when: config("next"))
            add(".nuxt", ".output", when: config("nuxt"))
            add(".svelte-kit", when: config("svelte"))
            if has("angular.json"), children[".angular"] == directory, isFolder(folder + "/.angular/cache") {
                found.append(".angular/cache")
            }
            add(".turbo", when: has("turbo.json"))
        }
        add(".stack-work", when: has("stack.yaml"))
        add("dist-newstyle", when: has("cabal.project") || hasFile(where: isCabalFile))
        add("_build", "deps", when: has("mix.exs"))
        add(".zig-cache", "zig-cache", when: has("build.zig"))
        return found
    }

    static let gradleBuildFiles = ["build.gradle", "build.gradle.kts"]
    static let gradleProjectFiles = gradleBuildFiles + ["settings.gradle", "settings.gradle.kts"]

    /// A Gradle project's folder: a regular `build.gradle(.kts)` or `settings.gradle(.kts)` among `children`.
    static func isGradleProject(_ children: [String: UInt8]) -> Bool {
        gradleProjectFiles.contains { children[$0] == UInt8(DT_REG) }
    }

    /// `requirements.txt`, `requirements-dev.txt`…
    static func isRequirements(_ name: String) -> Bool { name.hasPrefix("requirements") && name.hasSuffix(".txt") }

    /// `app.cabal`: a Cabal package description (not a file named only `.cabal`).
    static func isCabalFile(_ name: String) -> Bool { name.hasSuffix(".cabal") && name.count > ".cabal".count }

    /// Whether `path` is a real folder (`lstat`: a symlink is not).
    static func isFolder(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    /// Whether `path` is a regular file (`lstat`: a symlink is not).
    static func isFile(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }

    /// Whether `path` is a real folder that its project (`projectPath`) holds as one of its `projectFolders`.
    static func isProjectFolder(_ path: String) -> Bool {
        guard isFolder(path) else { return false }
        let project = projectPath(of: path)
        return projectFolders(in: project, children: entries(of: project)).contains(String(path.dropFirst(project.count + 1)))
    }

    /// The project holding a project folder: its parent, or two levels up for `<project>/.terraform/<name>`,
    /// `<project>/.angular/cache` and a Gradle module's `<project>/<module>/build` (both folders Gradle projects).
    static func projectPath(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent, parentName = (parent as NSString).lastPathComponent
        let grandparent = (parent as NSString).deletingLastPathComponent
        if parentName == ".terraform" || parentName == ".angular" && (path as NSString).lastPathComponent == "cache" {
            return grandparent
        }
        if (path as NSString).lastPathComponent == "build", gradleBuildFiles.contains(where: { isFile(parent + "/" + $0) }),
           gradleProjectFiles.contains(where: { isFile(grandparent + "/" + $0) }) {
            return grandparent
        }
        return parent
    }

    /// `~/Developer/app — app/build/`: the project's path from the home folder, as project names repeat (`app`, `ios`),
    /// and the folder's path in it.
    static func label(_ folder: URL, home: URL) -> String {
        let path = folder.standardizedFileURL.path, project = projectPath(of: path), homePath = home.standardizedFileURL.path
        let shown = project.hasPrefix(homePath + "/") ? "~" + project.dropFirst(homePath.count) : project
        return shown + " — " + path.dropFirst(project.count + 1) + "/"
    }

    /// Whether a folder between `home` and `path` is a project folder of the folder holding it: what a tool made is
    /// never walked into, so nothing found inside it is a project's.
    static func isInsideProjectFolder(_ path: String, home: String) -> Bool {
        guard path.hasPrefix(home + "/") else { return false }
        var parent = home
        for part in path.dropFirst(home.count + 1).split(separator: "/").dropLast() {
            if projectFolders(in: parent, children: entries(of: parent)).contains(String(part)) { return true }
            parent += "/" + part
        }
        return false
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
        // A Gradle module's `build` is found from its project and from the module itself.
        var seen = Set<String>()
        return found.filter { seen.insert($0.path).inserted }.sorted { $0.path < $1.path }
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
                            let names = projectFolders(in: folder, children: children)
                            for name in names {
                                found.append(URL(fileURLWithPath: folder + "/" + name, isDirectory: true))
                            }
                            guard current < depth else { continue }
                            var info = stat()
                            for (name, type) in children where type == UInt8(DT_DIR) && !name.hasPrefix(".")
                                && !unwalked.contains(name) && !names.contains(name)
                                && !bundleExtensions.contains((name as NSString).pathExtension.lowercased()) {
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

    /// Calls `visit` with each folder below `roots` and its `readdir` names and types, one level at a time, up to
    /// `depth` levels: never a symlink, a hidden folder, one of `unwalked`, a bundle, a folder of `skipping` or another
    /// volume, at most `folderLimit` folders in all. Where tools' settings files that pin versions are looked for
    /// (`AndroidSDKComponents`, `ToolVersionManagers`).
    static func visit(_ roots: [URL], skipping: Set<String> = [], depth: Int = depth, folderLimit: Int = folderLimit,
                      _ visit: (String, [String: UInt8]) -> Void) {
        var budget = folderLimit
        for root in roots {
            let rootPath = root.standardizedFileURL.path
            var info = stat()
            guard lstat(rootPath, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
            let device = info.st_dev
            var level = [rootPath]
            for current in 0...depth where !level.isEmpty {
                var next: [String] = []
                for folder in level {
                    guard budget > 0 else { return }
                    budget -= 1
                    let children = entries(of: folder)
                    visit(folder, children)
                    guard current < depth else { continue }
                    for (name, type) in children where type == UInt8(DT_DIR) && !name.hasPrefix(".")
                        && !unwalked.contains(name) && !bundleExtensions.contains((name as NSString).pathExtension.lowercased()) {
                        let path = folder + "/" + name
                        guard !skipping.contains(path), lstat(path, &info) == 0, info.st_dev == device else { continue }
                        next.append(path)
                    }
                }
                level = next.sorted()
            }
        }
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

    /// Newest modification date of `folder` itself, of the `markers` in each folder above it below `home` (its project,
    /// a Gradle module, the repository around them), and of the project's own files `projectFile` accepts
    /// (`requirements*.txt`, `next.config.mjs`); nil when `folder` is gone. A `.git` file (a worktree, a submodule) leads to its own Git folder's index.
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
        if let projectFile {
            let project = projectPath(of: path)
            for name in entries(of: project).keys where projectFile(name) { consider(project + "/" + name) }
        }
        var current = (path as NSString).deletingLastPathComponent
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

    /// "Skipped when" line of the items using `skipsEntry`.
    static let skipNote: LocalizedStringResource = "A project a build or package tool is running in, and a project worked on in the last \(days) days"

    /// The Smart Scan item's per-entry skip: a project a tool runs in (`running`, read once per scan) or one worked on
    /// within `days` before `now`.
    static func skipsEntry(running: @escaping @Sendable () -> [String], now: @escaping @Sendable () -> Date,
                           lastWorkedOn: @escaping @Sendable (URL) -> Date?) -> @Sendable () -> @Sendable (URL) -> Bool {
        {
            let busy = running(), cutoff = now().addingTimeInterval(-Double(days) * 86_400)
            return { url in
                isUsed(URL(fileURLWithPath: projectPath(of: url.standardizedFileURL.path)), by: busy)
                    || lastWorkedOn(url).map { $0 >= cutoff } ?? true
            }
        }
    }
}
