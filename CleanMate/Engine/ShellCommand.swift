import Foundation

nonisolated struct ShellCommand: Sendable {
    /// Absolute path, `~/…`, or a bare tool name looked up in `searchPaths`
    /// (apps launched from Finder don't get the shell's PATH).
    var executable: String
    var arguments: [String] = []
    var timeout: Duration = .seconds(60)
    /// Arguments decided at run time, put before `arguments`; nil = don't run (e.g. no local Docker socket).
    var leadingArguments: @Sendable () -> [String]? = { [] }
    /// false: `output()` also returns what a tool printed before exiting with a non-zero code (`spctl --status`
    /// exits 1 when assessments are disabled). Missing, killed or timed-out tools still give nil.
    var requiresSuccess = true
    /// Variables set for the tool on top of the app's own environment (`HOMEBREW_NO_AUTO_UPDATE`).
    var environment: [String: String] = [:]

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
        await execute(capture: false).finished.map { succeeded($0.status) } == true
    }

    /// Why a run of `tool` didn't succeed, as shown to the user.
    struct Failure: Error, Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            /// Not installed, or not ready to run (`leadingArguments` nil: no local Docker socket).
            case notInstalled, notReady
            case timedOut, cancelled
            /// Couldn't be started: the errno of posix_spawn.
            case notStarted(Int32)
            case exited(Int32)
            /// Killed by this signal.
            case killed(Int32)
        }
        /// The executable's name (`brew`, `docker`).
        var tool: String
        var kind: Kind
        /// The last non-empty line the tool printed to standard error, if any.
        var lastLine: String?
    }

    /// Runs the command like `run()`: nil when it succeeded, else why not, with the last line it printed to
    /// standard error (its standard output is not kept).
    @concurrent func attempt() async -> Failure? {
        let tool = (executable as NSString).lastPathComponent
        switch await execute(capture: true, errorsOnly: true) {
        case .finished(let status, let errors):
            guard !succeeded(status) else { return nil }
            let last = errors.split(whereSeparator: \.isNewline).last { !$0.allSatisfy(\.isWhitespace) }
                .map { String($0.trimmingCharacters(in: .whitespaces).prefix(300)) }
            let kind: Failure.Kind = status & 0x7f == 0 ? .exited((status >> 8) & 0xff) : .killed(status & 0x7f)
            return Failure(tool: tool, kind: kind, lastLine: last)
        case .missing: return Failure(tool: tool, kind: .notInstalled)
        case .notReady: return Failure(tool: tool, kind: .notReady)
        case .timedOut: return Failure(tool: tool, kind: .timedOut)
        case .cancelled: return Failure(tool: tool, kind: .cancelled)
        case .notStarted(let code): return Failure(tool: tool, kind: .notStarted(code))
        }
    }

    /// Standard output of a successful run; nil when missing, failing or timed out.
    @concurrent func output() async -> String? {
        guard let result = await execute(capture: true).finished, succeeded(result.status) else { return nil }
        return result.output
    }

    /// A finished run as shown to the user: exit code 0, and standard output and error interleaved as printed.
    struct Outcome: Sendable, Equatable {
        var succeeded: Bool
        var output: String
    }

    /// Exit result and everything the tool printed; nil when missing, timed out or cancelled. `requiresSuccess` is not used.
    @concurrent func outcome() async -> Outcome? {
        await execute(capture: true, includeErrors: true).finished.map { Outcome(succeeded: $0.status == 0, output: $0.output) }
    }

    /// Like `outcome()`, and hands what the tool prints to `onOutput` while it runs: whole lines, at most every
    /// `outputInterval` (the rest when it exits), so a long tool (brew) shows its progress live.
    @concurrent func outcome(onOutput: @escaping @Sendable (String) async -> Void) async -> Outcome? {
        await execute(capture: true, includeErrors: true, onOutput: onOutput).finished
            .map { Outcome(succeeded: $0.status == 0, output: $0.output) }
    }

    /// How often `outcome(onOutput:)` hands over new lines: about 10 times a second at most.
    static let outputInterval: Duration = .milliseconds(100)

    /// 0 = exited normally with code 0; low 7 bits 0 = exited normally (not killed by a signal).
    private func succeeded(_ status: Int32) -> Bool { status == 0 || (!requiresSuccess && status & 0x7f == 0) }

    /// How long output is still read after the tool exits: a background child it left behind may hold the
    /// pipe open forever.
    static let drainGrace: Duration = .milliseconds(300)

    /// How a run ended: its wait status and captured output ("" without `capture`), or why it didn't finish.
    private enum Run {
        case finished(status: Int32, output: String)
        case missing, notReady, timedOut, cancelled
        case notStarted(Int32)

        var finished: (status: Int32, output: String)? {
            if case .finished(let status, let output) = self { (status, output) } else { nil }
        }
    }

    /// `errorsOnly`: captures standard error alone (standard output goes to /dev/null).
    private func execute(capture: Bool, includeErrors: Bool = false, errorsOnly: Bool = false,
                         onOutput: (@Sendable (String) async -> Void)? = nil) async -> Run {
        guard let path = resolvedPath else { return .missing }
        guard let leading = leadingArguments() else { return .notReady }
        var environment = ProcessInfo.processInfo.environment.merging(self.environment) { $1 }
        // Script tools (`#!/usr/bin/env node`, brew) need their siblings on PATH.
        environment["PATH"] = ([(path as NSString).deletingLastPathComponent] + Self.searchPaths
            + [environment["PATH"] ?? ""]).joined(separator: ":")

        var fds: [Int32] = [-1, -1]
        if capture { guard pipe(&fds) == 0 else { return .notStarted(errno) } }
        defer { for fd in fds where fd >= 0 { close(fd) } }

        // posix_spawn, not Process: the tool gets its own process group (POSIX_SPAWN_SETPGROUP) so a timeout or
        // cancel kills the tool's children too (`sh -c` of simctl), with no setpgid-after-launch race.
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        if capture && !errorsOnly { posix_spawn_file_actions_adddup2(&actions, fds[1], 1) }
        else { posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0) }
        if includeErrors || errorsOnly { posix_spawn_file_actions_adddup2(&actions, fds[1], 2) }
        else { posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0) }
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
        let spawned = posix_spawn(&pid, path, &actions, &attributes, argv, envp)
        guard spawned == 0 else { return .notStarted(spawned) }

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
        // Bytes of `data` already handed to `onOutput`, and when.
        var sent = 0, sentAt = ContinuousClock.now
        while true {
            // Read while running so a full pipe buffer can't block the tool.
            while !atEOF {
                let count = read(reader, &buffer, buffer.count)
                if count > 0 { data.append(buffer, count: count) } else { atEOF = count == 0 || (errno != EAGAIN && errno != EINTR); break }
            }
            if let onOutput, ContinuousClock.now >= sentAt + Self.outputInterval,
               let newline = data[sent...].lastIndex(of: UInt8(ascii: "\n")) {
                await onOutput(String(decoding: data[sent...newline], as: UTF8.self))
                sent = newline + 1
                sentAt = .now
            }
            if exitedAt == nil, waitpid(pid, &status, WNOHANG) == pid { exitedAt = .now }
            if let exitedAt, atEOF || ContinuousClock.now >= exitedAt + Self.drainGrace {
                if let onOutput, sent < data.count { await onOutput(String(decoding: data[sent...], as: UTF8.self)) }
                break
            }
            // A cancelled scan stops waiting for slow tools (docker, xcrun) right away.
            if ContinuousClock.now >= deadline || Task.isCancelled {
                let cancelled = Task.isCancelled
                await Self.stop(group: pid, reaped: exitedAt != nil)
                return cancelled ? .cancelled : .timedOut
            }
            nap = min(nap * 2, .milliseconds(50))  // capped: long tools (brew, docker) poll thousands of times
            try? await Task.sleep(for: min(nap, exitedAt == nil ? .milliseconds(50) : .milliseconds(20)))
        }
        return .finished(status: status, output: capture ? String(decoding: data, as: UTF8.self) : "")
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
