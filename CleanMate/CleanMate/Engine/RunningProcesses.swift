import Foundation

/// Names of the user's running command-line tools (`claude`, `codex`, `gemini`…), for items whose tool has no
/// bundle id. Read from the kernel (`proc_listpids` + `KERN_PROCARGS2`), never by running `ps`.
nonisolated enum RunningProcesses {
    /// For each process: the last path component of argv[0] (what `ps -o comm` shows) and of the executable,
    /// plus argv[1] when argv[0] is an interpreter (`node …/bin/gemini`), plus the tool whose install path
    /// (`installPaths`) appears in the executable or any argument.
    /// argv[0] matters: the native Claude Code binary is `~/.local/share/claude/versions/<version>`, so its
    /// executable name (`proc_name`) is the version number, while argv[0] is `claude`.
    /// Processes of other users cannot be read and are left out.
    static func names() -> Set<String> {
        var names = Set<String>()
        let extra = shellInstallPaths(policy: .current)
        for pid in allPIDs() where pid > 0 {
            names.formUnion(argumentNames(arguments(of: pid), extra: extra))
        }
        return names
    }

    /// The raw `KERN_PROCARGS2` buffer of `pid`, empty when it cannot be read.
    private static func arguments(of pid: pid_t) -> [UInt8] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        return Array(buffer.prefix(size))
    }

    static let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3"]

    /// Install paths that name the tool whatever the process or script is called: a wrapper script (`~/.claude/local/claude`)
    /// or a global npm install runs `node …/node_modules/@anthropic-ai/claude-code/cli.js`, whose script name is `cli.js`.
    static let installPaths: [(path: String, name: String)] = [
        ("/@anthropic-ai/claude-code/", "claude"), ("/.local/share/claude/versions/", "claude"),
        ("/@openai/codex/", "codex"), ("/@google/gemini-cli/", "gemini"), ("/@github/copilot/", "copilot"),
        // Yarn run by node: a project's pinned release (`.yarn/releases/yarn-4.5.0.cjs`) or the npm package's yarn.js.
        ("/.yarn/releases/yarn-", "yarn"), ("/node_modules/yarn/bin/", "yarn"),
        // Homebrew: `bin/brew` runs `bash …/Library/Homebrew/brew.sh`, which runs `ruby … …/Library/Homebrew/brew.rb`.
        ("/Library/Homebrew/brew.sh", "brew"), ("/Library/Homebrew/brew.rb", "brew"),
        // Firebase emulators: `java -jar ~/.cache/firebase/emulators/cloud-firestore-emulator-v1.19.jar`, or a
        // downloaded binary run from that folder; the unpacked `ui-v*` folder is not kept open, so a path is the only sign.
        (CleanerGroup.firebaseEmulatorsPath, "firebase-emulators"),
    ]

    /// `installPaths` moved by a shell profile variable: emulators run from `FIREBASE_EMULATORS_PATH` (checked like
    /// any `shellFolders` folder, so never outside home).
    static func shellInstallPaths(policy: SafetyPolicy) -> [(path: String, name: String)] {
        ShellEnvironment.folder("FIREBASE_EMULATORS_PATH", policy: policy).map { [($0.path + "/", "firebase-emulators")] } ?? []
    }

    /// `node`, `node22`, `python3.12`…
    static func isInterpreter(_ name: String) -> Bool {
        interpreters.contains(name) || interpreters.contains { name.hasPrefix($0) && name.dropFirst($0.count).allSatisfy { $0.isNumber || $0 == "." } }
    }

    /// The executable path and every argument of a `KERN_PROCARGS2` buffer: Int32 argc, executable path, NUL padding,
    /// then argv strings (a JVM's main class sits after many options); empty runs are padding.
    static func argumentStrings(_ buffer: [UInt8]) -> [String] {
        guard buffer.count > 4 else { return [] }
        let argc = buffer.prefix(4).withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var strings: [String] = []
        var start = 4
        while start < buffer.count, strings.count < 1 + max(argc, 0) {
            let end = buffer[start...].firstIndex(of: 0) ?? buffer.count
            if end > start { strings.append(String(decoding: buffer[start..<end], as: UTF8.self)) }
            start = end + 1
        }
        return strings
    }

    /// Working folder and absolute-path arguments (a script, `--prefix <folder>`) of each readable process whose
    /// `argumentNames` include one `named` accepts, without the `/private` prefix.
    static func folders(ofProcessesNamed named: (String) -> Bool) -> [String] {
        var folders: [String] = []
        for pid in allPIDs() where pid > 0 {
            let buffer = arguments(of: pid)
            guard argumentNames(buffer).contains(where: named) else { continue }
            if let folder = workingFolder(of: pid) { folders.append(folder) }
            folders += argumentStrings(buffer).dropFirst().filter { $0.hasPrefix("/") }
        }
        return folders.map(withoutPrivate)
    }

    /// Executable path, working folder and absolute-path arguments of every readable process, without the `/private`
    /// prefix: what runs from, or works in, a folder (`node` of an nvm version, the Dart VM of a Flutter SDK).
    static func usedPaths() -> [String] {
        var paths: [String] = []
        for pid in allPIDs() where pid > 0 {
            if let folder = workingFolder(of: pid) { paths.append(folder) }
            let strings = argumentStrings(arguments(of: pid))
            paths += strings.prefix(1) + strings.dropFirst().filter { $0.hasPrefix("/") }
        }
        return paths.map(withoutPrivate)
    }

    /// The current folder of `pid` (`PROC_PIDVNODEPATHINFO`); nil when the process cannot be read.
    static func workingFolder(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return path.isEmpty ? nil : path
    }

    /// Names a process goes by, from a `KERN_PROCARGS2` buffer (see `names`).
    static func argumentNames(_ buffer: [UInt8], extra: [(path: String, name: String)] = []) -> Set<String> {
        let strings = argumentStrings(buffer)
        let base = strings.map { $0.split(separator: "/").last.map(String.init) ?? $0 }
        var names = Set(base.prefix(2))
        if base.count > 2, isInterpreter(base[1]) { names.insert(base[2]) }
        if base.count > 3, isInterpreter(base[1]), base[2] == "-m" { names.insert(base[3]) } // `python3 -m pip`
        for (path, name) in installPaths + extra where strings.contains(where: { $0.contains(path) }) { names.insert(name) }
        // The Gradle daemon is `java … org.gradle.launcher.daemon.bootstrap.GradleDaemon <version>`.
        if strings.contains("org.gradle.launcher.daemon.bootstrap.GradleDaemon") { names.insert("GradleDaemon") }
        // The Kotlin compile daemon is `java … org.jetbrains.kotlin.daemon.KotlinCompileDaemon …`.
        if strings.contains("org.jetbrains.kotlin.daemon.KotlinCompileDaemon") { names.insert("KotlinCompileDaemon") }
        // sdkmanager and avdmanager are scripts that run `java … com.android.sdklib.tool.…Cli`.
        if strings.contains("com.android.sdklib.tool.sdkmanager.SdkManagerCli") { names.insert("sdkmanager") }
        if strings.contains("com.android.sdklib.tool.AvdManagerCli") { names.insert("avdmanager") }
        return names
    }
}

nonisolated extension RunningProcesses {
    /// Paths of files any readable process has open under `root` (`$TMPDIR` by default), without the `/private`
    /// prefix. Read from libproc (`PROC_PIDLISTFDS` + `PROC_PIDFDVNODEPATHINFO`), never `lsof`;
    /// processes that cannot be read (other users, exited meanwhile) are left out. `only` reads just those processes
    /// (tests: their own, so another process walking `$TMPDIR` cannot hold their folders).
    static func openPaths(under root: String = NSTemporaryDirectory(), only: [pid_t]? = nil) -> Set<String> {
        let prefix = withoutPrivate(root.hasSuffix("/") ? root : root + "/")
        let pids = only ?? allPIDs()
        let fdSize = MemoryLayout<proc_fdinfo>.stride
        var paths = Set<String>()
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: 256)
        for pid in pids where pid > 0 {
            var size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard size > 0 else { continue }
            if Int(size) / fdSize + 16 > fds.count { fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / fdSize + 16) }
            size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * fdSize))
            for fd in fds.prefix(max(0, Int(size)) / fdSize) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var info = vnode_fdinfowithpath()
                let infoSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, infoSize) == infoSize else { continue }
                let path = withoutPrivate(withUnsafeBytes(of: info.pvip.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) })
                if path.hasPrefix(prefix) { paths.insert(path) }
            }
        }
        return paths
    }

    /// Every process id (`proc_listpids`), with room for processes started between the two calls.
    static func allPIDs() -> [pid_t] {
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytes > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size + 64)
        let filled = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(max(0, Int(filled)) / MemoryLayout<pid_t>.size))
    }

    /// `/private/var/…` → `/var/…`: the kernel reports the resolved path, `$TMPDIR` and scan URLs use `/var`.
    static func withoutPrivate(_ path: String) -> String {
        path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }

    /// Open paths under any of an item's `roots` (`Scanner.roots`), asked of `read` per root.
    static func openPaths(under roots: [URL], read: OpenPaths) async -> Set<String> {
        var paths = Set<String>()
        for root in roots { paths.formUnion(await read(root.path)) }
        return paths
    }

    /// Whether `url` is, or is a folder holding, one of `openPaths`.
    static func holdsOpenFile(_ url: URL, openPaths: Set<String>) -> Bool {
        let path = withoutPrivate(url.standardizedFileURL.path)
        return openPaths.contains { $0 == path || $0.hasPrefix(path + "/") }
    }
}
