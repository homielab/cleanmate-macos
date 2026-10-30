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
        for pid in allPIDs() where pid > 0 {
            names.formUnion(argumentNames(arguments(of: pid)))
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
    ]

    /// `node`, `node22`, `python3.12`…
    static func isInterpreter(_ name: String) -> Bool {
        interpreters.contains(name) || interpreters.contains { name.hasPrefix($0) && name.dropFirst($0.count).allSatisfy { $0.isNumber || $0 == "." } }
    }

    /// Parses a `KERN_PROCARGS2` buffer: Int32 argc, executable path, NUL padding, then argv strings.
    static func argumentNames(_ buffer: [UInt8]) -> Set<String> {
        guard buffer.count > 4 else { return [] }
        let argc = buffer.prefix(4).withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var strings: [String] = []
        var start = 4
        // executable path + all arguments (a JVM's main class sits after many options); empty runs are padding.
        while start < buffer.count, strings.count < 1 + max(argc, 0) {
            let end = buffer[start...].firstIndex(of: 0) ?? buffer.count
            if end > start { strings.append(String(decoding: buffer[start..<end], as: UTF8.self)) }
            start = end + 1
        }
        let base = strings.map { $0.split(separator: "/").last.map(String.init) ?? $0 }
        var names = Set(base.prefix(2))
        if base.count > 2, isInterpreter(base[1]) { names.insert(base[2]) }
        if base.count > 3, isInterpreter(base[1]), base[2] == "-m" { names.insert(base[3]) } // `python3 -m pip`
        for (path, name) in installPaths where strings.contains(where: { $0.contains(path) }) { names.insert(name) }
        // The Gradle daemon is `java … org.gradle.launcher.daemon.bootstrap.GradleDaemon <version>`.
        if strings.contains("org.gradle.launcher.daemon.bootstrap.GradleDaemon") { names.insert("GradleDaemon") }
        // The Kotlin compile daemon is `java … org.jetbrains.kotlin.daemon.KotlinCompileDaemon …`.
        if strings.contains("org.jetbrains.kotlin.daemon.KotlinCompileDaemon") { names.insert("KotlinCompileDaemon") }
        return names
    }
}

nonisolated extension RunningProcesses {
    /// Paths of files any readable process has open under `root` (`$TMPDIR` by default), without the `/private`
    /// prefix. Read once per scan from libproc (`PROC_PIDLISTFDS` + `PROC_PIDFDVNODEPATHINFO`), never `lsof`;
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

    /// Open paths under any of an item's `roots` (`Scanner.roots`), read per root by `read` (tests count calls).
    static func openPaths(under roots: [URL], read: (String) -> Set<String> = { openPaths(under: $0) }) -> Set<String> {
        roots.reduce(into: []) { $0.formUnion(read($1.path)) }
    }

    /// Whether `url` is, or is a folder holding, one of `openPaths`.
    static func holdsOpenFile(_ url: URL, openPaths: Set<String>) -> Bool {
        let path = withoutPrivate(url.standardizedFileURL.path)
        return openPaths.contains { $0 == path || $0.hasPrefix(path + "/") }
    }
}
