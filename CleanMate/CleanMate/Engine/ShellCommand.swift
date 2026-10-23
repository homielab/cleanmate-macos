import Foundation

nonisolated struct ShellCommand: Sendable {
    /// Absolute path, `~/…`, or a bare tool name looked up in `searchPaths`
    /// (apps launched from Finder don't get the shell's PATH).
    var executable: String
    var arguments: [String] = []
    var timeout: Duration = .seconds(60)
    /// Arguments decided at run time, put before `arguments`; nil = don't run (e.g. no local Docker socket).
    var leadingArguments: @Sendable () -> [String]? = { [] }

    static let searchPaths = [
        "/opt/homebrew/bin", "/usr/local/bin", "~/.docker/bin", "~/.local/bin", "~/.cargo/bin", "~/.bun/bin",
        "~/Library/pnpm", "/usr/local/go/bin", "~/go/bin", "/usr/bin", "/bin",
    ].map { ($0 as NSString).expandingTildeInPath }

    /// The executable that would run, or nil when the tool is not installed.
    var resolvedPath: String? {
        let candidates = executable.contains("/")
            ? [(executable as NSString).expandingTildeInPath]
            : Self.searchPaths.map { $0 + "/" + executable }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs the command; false when missing, failing or timed out (it is then terminated).
    @concurrent func run() async -> Bool {
        await execute(capture: false) != nil
    }

    /// Standard output of a successful run; nil when missing, failing or timed out.
    @concurrent func output() async -> String? {
        await execute(capture: true)
    }

    /// How long output is still read after the tool exits: a background child it left behind may hold the
    /// pipe open forever.
    static let drainGrace: Duration = .milliseconds(300)

    private func execute(capture: Bool) async -> String? {
        guard let path = resolvedPath, let leading = leadingArguments() else { return nil }
        var environment = ProcessInfo.processInfo.environment
        // Script tools (`#!/usr/bin/env node`, brew) need their siblings on PATH.
        environment["PATH"] = ([(path as NSString).deletingLastPathComponent] + Self.searchPaths
            + [environment["PATH"] ?? ""]).joined(separator: ":")

        var fds: [Int32] = [-1, -1]
        if capture { guard pipe(&fds) == 0 else { return nil } }
        defer { for fd in fds where fd >= 0 { close(fd) } }

        // posix_spawn, not Process: the tool gets its own process group (POSIX_SPAWN_SETPGROUP) so a timeout or
        // cancel kills the tool's children too (`sh -c` of simctl), with no setpgid-after-launch race.
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        if capture { posix_spawn_file_actions_adddup2(&actions, fds[1], 1) }
        else { posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0) }
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var noSignals = sigset_t(), allSignals = sigset_t()
        sigemptyset(&noSignals)
        sigfillset(&allSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        posix_spawnattr_setpgroup(&attributes, 0)
        // CLOEXEC_DEFAULT: only fds 0–2 reach the tool, never the app's other descriptors.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK
            | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = ([path] + leading + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, path, &actions, &attributes, argv, envp) == 0 else { return nil }

        let reader = fds[0]
        if capture {
            close(fds[1]); fds[1] = -1
            _ = fcntl(reader, F_SETFL, fcntl(reader, F_GETFL) | O_NONBLOCK)
        }
        var data = Data(), atEOF = !capture, status: Int32 = 0, exitedAt: ContinuousClock.Instant?
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let deadline = ContinuousClock.now + timeout
        // Poll from 1 ms, doubling up to 50 ms: most tools (sqlite3) exit in a few ms, a flat 50 ms nap made each run ≥ 50 ms.
        var nap = Duration.milliseconds(1)
        while true {
            // Read while running so a full pipe buffer can't block the tool.
            while !atEOF {
                let count = read(reader, &buffer, buffer.count)
                if count > 0 { data.append(buffer, count: count) } else { atEOF = count == 0 || (errno != EAGAIN && errno != EINTR); break }
            }
            if exitedAt == nil, waitpid(pid, &status, WNOHANG) == pid { exitedAt = .now }
            if let exitedAt, atEOF || ContinuousClock.now >= exitedAt + Self.drainGrace { break }
            // A cancelled scan stops waiting for slow tools (docker, xcrun) right away.
            if ContinuousClock.now >= deadline || Task.isCancelled {
                await Self.stop(group: pid, reaped: exitedAt != nil)
                return nil
            }
            nap = min(nap * 2, .milliseconds(50))  // capped: long tools (brew, docker) poll thousands of times
            try? await Task.sleep(for: min(nap, exitedAt == nil ? .milliseconds(50) : .milliseconds(20)))
        }
        guard status == 0 else { return nil }  // 0 = exited normally with code 0
        return capture ? String(decoding: data, as: UTF8.self) : ""
    }

    /// How long a timed-out or cancelled tool group gets after SIGTERM to stop cleanly before SIGKILL.
    static let termGrace: Duration = .seconds(2)

    /// SIGTERM the whole group so cleanup tools (brew, go clean, docker prune) can stop cleanly, SIGKILL whatever
    /// is still alive after `termGrace`, and reap the leader. Detached: a cancelled task's sleep would not wait.
    private static func stop(group pid: pid_t, reaped: Bool) async {
        await Task.detached {
            kill(-pid, SIGTERM)
            var status: Int32 = 0, reaped = reaped
            let deadline = ContinuousClock.now + termGrace
            while ContinuousClock.now < deadline {
                if !reaped, waitpid(pid, &status, WNOHANG) == pid { reaped = true }
                if reaped, kill(-pid, 0) != 0 { return }  // the whole group is gone
                try? await Task.sleep(for: .milliseconds(50))
            }
            kill(-pid, SIGKILL)
            if !reaped { waitpid(pid, &status, 0) }
        }.value
    }
}
