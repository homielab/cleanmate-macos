import Foundation

// Login items & launch agents: the user's agents in ~/Library/LaunchAgents can be disabled, enabled or removed
// (plist to the Trash) through `launchctl` in the user's own `gui/<uid>` domain. Third-party agents and daemons in
// /Library can only be removed: Finder moves the plist to the Trash with the admin password (`removeSystem`), and
// they stop starting after a restart. Anything of Apple's is never listed nor touched.

nonisolated struct LaunchAgent: Identifiable, Hashable, Sendable {
    enum Scope: Sendable, CaseIterable { case user, systemAgent, systemDaemon }
    enum State: Hashable, Sendable { case running(pid: Int), loaded, notLoaded, disabled, unknown }

    let url: URL
    let label: String
    let scope: Scope
    /// `Program` or the first of `ProgramArguments`.
    let program: String?
    /// The program no longer exists (`!Uninstaller.agentIsActive`), e.g. its app was removed.
    let programMissing: Bool
    /// The app the program lives in, or whose bundle id prefixes the label.
    let owner: URL?
    var state: State
    /// A system agent or daemon `removeSystem` may move (`SafetyPolicy.allowsSystemLaunchAgent`); false for the user's.
    var removable = false
    /// The program is gone and so is its app (or it has none): left behind by an app that was removed (`scan`).
    var appRemoved = false

    var id: URL { url }
    var isUser: Bool { scope == .user }
}

nonisolated enum LaunchAgents {
    static let launchctl = "/bin/launchctl"

    static func folder(_ scope: LaunchAgent.Scope, policy: SafetyPolicy = .current) -> URL {
        switch scope {
        case .user: policy.homeURL.appending(path: "Library/LaunchAgents")
        case .systemAgent: URL(fileURLWithPath: (policy.systemLibrary ?? "/Library") + "/LaunchAgents")
        case .systemDaemon: URL(fileURLWithPath: (policy.systemLibrary ?? "/Library") + "/LaunchDaemons")
        }
    }

    /// `Label` (or the file name without `.plist`) and the program of a launchd plist.
    static func info(_ dict: [String: Any], fileName: String) -> (label: String, program: String?) {
        let label = dict["Label"] as? String ?? (fileName as NSString).deletingPathExtension
        let program = dict["Program"] as? String ?? (dict["ProgramArguments"] as? [String])?.first
        return (label, program)
    }

    static func read(_ plist: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: plist) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// `launchctl list`: header line, then `PID<TAB>Status<TAB>Label` with PID `-` when not running.
    static func parseList(_ output: String) -> (loaded: Set<String>, pids: [String: Int]) {
        var loaded: Set<String> = []
        var pids: [String: Int] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3, fields[0] != "PID" else { continue }
            let label = fields[2...].joined(separator: "\t")
            loaded.insert(label)
            if let pid = Int(fields[0]) { pids[label] = pid }
        }
        return (loaded, pids)
    }

    /// `launchctl print-disabled`: lines `"label" => disabled` (`=> true` on older systems).
    static func parseDisabled(_ output: String) -> Set<String> {
        var disabled: Set<String> = []
        for line in output.split(separator: "\n") {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            let label = parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if value == "disabled" || value == "true" { disabled.insert(label) }
        }
        return disabled
    }

    static func state(of label: String, loaded: Set<String>, pids: [String: Int], disabled: Set<String>) -> LaunchAgent.State {
        if let pid = pids[label] { return .running(pid: pid) }
        if loaded.contains(label) { return .loaded }
        return disabled.contains(label) ? .disabled : .notLoaded
    }

    /// `AssociatedBundleIdentifiers` (a string or an array): the apps the plist declares itself part of.
    static func associatedIDs(_ dict: [String: Any]) -> [String] {
        let value = dict["AssociatedBundleIdentifiers"]
        return value as? [String] ?? (value as? String).map { [$0] } ?? []
    }

    /// The `.app` bundle containing `program`, else the first installed app of `associated`, else an installed app whose
    /// bundle id is the label or a prefix of it with at least 3 parts (`com.vendor.App.helper` → `com.vendor.App`).
    static func owner(program: String?, label: String, associated: [String] = [], appForID: (String) -> URL?) -> URL? {
        if let program, program.hasPrefix("/") {
            var url = URL(fileURLWithPath: "/")
            for part in URL(fileURLWithPath: program).pathComponents.dropFirst() {
                url.append(path: part)
                if url.pathExtension == "app" { return url }
            }
        }
        if let url = associated.lazy.compactMap(appForID).first { return url }
        var parts = label.split(separator: ".")
        while parts.count >= 3 {
            if let url = appForID(parts.joined(separator: ".")) { return url }
            parts.removeLast()
        }
        return nil
    }

    /// What a read-only `launchctl` run (`list`, `print-disabled`) printed; nil when it failed. Tests pass a fake.
    typealias Reader = @Sendable ([String]) async -> String?
    static let launchctlReader: Reader = {
        await ShellCommand(executable: launchctl, arguments: $0, timeout: .seconds(10)).output()
    }

    /// Path → pid of every running process whose path can be read (also root's, without root). Tests pass a fake.
    static let runningPrograms: @Sendable () -> [String: Int] = {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let found = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var programs: [String: Int] = [:]
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(max(found, 0)) where pid > 0 && proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
            programs[String(cString: buffer)] = Int(pid)
        }
        return programs
    }

    /// Every non-Apple plist of the folders of `scopes`. State from the user's GUI domain; a system agent or daemon
    /// whose program runs (`processes`) is running, a daemon's state is otherwise unknown (reading it needs root).
    @concurrent static func scan(appForID: @Sendable (String) -> URL?, policy: SafetyPolicy = .current,
                                 scopes: [LaunchAgent.Scope] = LaunchAgent.Scope.allCases,
                                 read: Reader = launchctlReader,
                                 processes: @Sendable () -> [String: Int] = runningPrograms) async -> [LaunchAgent] {
        let list = parseList(await read(["list"]) ?? "")
        let disabled = parseDisabled(await read(["print-disabled", "gui/\(getuid())"]) ?? "")
        let programs = scopes.contains(where: { $0 != .user }) ? processes() : [:]
        var agents: [LaunchAgent] = []
        for scope in scopes {
            let folder = folder(scope, policy: policy)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names.sorted() where name.hasSuffix(".plist") && !name.hasPrefix(".") && !SafetyPolicy.isApple(name) {
                let url = folder.appending(path: name)
                let dict = Self.read(url) ?? [:]
                let (label, program) = info(dict, fileName: name)
                guard !SafetyPolicy.isApple(label) else { continue }
                var state = scope == .systemDaemon
                    ? .unknown : state(of: label, loaded: list.loaded, pids: list.pids, disabled: disabled)
                if scope != .user, let program, let pid = programs[program] { state = .running(pid: pid) }
                let programMissing = !Uninstaller.agentIsActive(url)
                let owner = owner(program: program, label: label, associated: associatedIDs(dict), appForID: appForID)
                agents.append(LaunchAgent(
                    url: url, label: label, scope: scope, program: program, programMissing: programMissing, owner: owner,
                    state: state, removable: scope != .user && policy.allowsSystemLaunchAgent(url, label: label),
                    appRemoved: programMissing && !(owner.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)))
            }
        }
        return agents
    }

    /// How one `launchctl` run went: nil `failure` = it succeeded. Tests return `true` or `false`.
    struct RunResult: Sendable, ExpressibleByBooleanLiteral {
        var failure: ShellCommand.Failure?
        var succeeded: Bool { failure == nil }

        init(failure: ShellCommand.Failure?) { self.failure = failure }
        init(booleanLiteral succeeded: Bool) {
            failure = succeeded ? nil : ShellCommand.Failure(tool: "launchctl", kind: .exited(1))
        }
    }

    /// Runs `launchctl` with the arguments; tests inject a recorder so the real one is never called.
    typealias Runner = @Sendable ([String]) async -> RunResult
    static let launchctlRunner: Runner = {
        RunResult(failure: await ShellCommand(executable: launchctl, arguments: $0, timeout: .seconds(15)).attempt())
    }

    /// How an action on an agent went: why it failed, and what `remove` moved to the Trash (for "Undo").
    struct Outcome: Sendable {
        var failure: CleanFailure.Reason?
        var trashed: TrashedItem?
        var succeeded: Bool { failure == nil }

        static let done = Outcome()
        static func failed(_ reason: CleanFailure.Reason) -> Outcome { Outcome(failure: reason) }
    }

    private static func service(_ label: String) -> String { "gui/\(getuid())/\(label)" }

    /// The label launchctl may act on for `agent`, read again from its plist right before the action: nil when the
    /// plist can't be read or its `Label` changed since the scan (bootstrap would load another service than the one shown),
    /// or another plist in the same folder declares the same label (bootout/disable would hit that other agent too).
    static func ownedLabel(_ agent: LaunchAgent) -> String? {
        guard let dict = read(agent.url), info(dict, fileName: agent.url.lastPathComponent).label == agent.label
        else { return nil }
        let folder = agent.url.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let shared = names.contains { name in
            name.hasSuffix(".plist") && name != agent.url.lastPathComponent
                && info(read(folder.appending(path: name)) ?? [:], fileName: name).label == agent.label
        }
        return shared ? nil : agent.label
    }

    /// Why `agent` can't be acted on, before launchctl runs: not the user's own, or its plist changed (`ownedLabel`).
    private static func refusal(_ agent: LaunchAgent, policy: SafetyPolicy) -> CleanFailure.Reason? {
        guard policy.allowsLaunchAgent(agent.url, label: agent.label) else { return .refused }
        return ownedLabel(agent) == nil ? .changed : nil
    }

    /// Stops the agent and keeps it from starting at login (`bootout` + `disable`); undone by `enable`.
    @concurrent static func disable(_ agent: LaunchAgent, policy: SafetyPolicy = .current,
                                    run: Runner = launchctlRunner) async -> Outcome {
        if let reason = refusal(agent, policy: policy) { return .failed(reason) }
        _ = await run(["bootout", service(agent.label)]) // fails when it isn't loaded, which is fine
        return await run(["disable", service(agent.label)]).failure.map { .failed(.command($0)) } ?? .done
    }

    /// Re-enables the agent and loads it again (`enable` + `bootstrap`).
    @concurrent static func enable(_ agent: LaunchAgent, policy: SafetyPolicy = .current,
                                   run: Runner = launchctlRunner) async -> Outcome {
        if let reason = refusal(agent, policy: policy) { return .failed(reason) }
        if let failure = await run(["enable", service(agent.label)]).failure { return .failed(.command(failure)) }
        _ = await run(["bootstrap", "gui/\(getuid())", agent.url.path]) // fails when already loaded
        return .done
    }

    /// "Undo" of `remove`: puts the plist back from the Trash (`TrashUndo.putBack`, never over another file) and loads
    /// it again when it is the user's own agent with its own label. nil when put back, else why not.
    @concurrent static func restore(_ trashed: TrashedItem, label: String, policy: SafetyPolicy = .current,
                                    run: Runner = launchctlRunner) async -> TrashUndo.Outcome {
        let outcome = TrashUndo.putBack(trashed, module: "Login Items", home: policy.homeURL)
        guard outcome == .restored, policy.allowsLaunchAgent(trashed.original, label: label),
              let dict = read(trashed.original), info(dict, fileName: trashed.original.lastPathComponent).label == label
        else { return outcome }
        _ = await run(["bootstrap", "gui/\(getuid())", trashed.original.path]) // fails when it was disabled, which is fine
        return outcome
    }

    /// Moves the agent's plist to the Trash, then stops it (put it back and log in again to restore it). A plist whose
    /// label isn't its own (`ownedLabel`) is only trashed: booting out that label would stop another agent.
    /// The move is kept in `TrashRecords`, so `cleanmate restore` can put it back later. `trash`: tests use a fake Trash.
    @concurrent static func remove(_ agent: LaunchAgent, policy: SafetyPolicy = .current,
                                   trash: (URL) throws -> URL? = CleanReport.moveToTrash,
                                   run: Runner = launchctlRunner) async -> Outcome {
        let size = (try? agent.url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0
        guard policy.allowsLaunchAgent(agent.url, label: agent.label) else { return .failed(.refused) }
        let label = ownedLabel(agent) // read before the plist is gone
        // Only the plist checked moves (`SafeRemoval.trash`); every failure is logged "failed" with its reason.
        let inTrash: URL?
        do {
            inTrash = try SafeRemoval.trash(agent.url, allows: { policy.allowsLaunchAgent($0, label: agent.label) },
                                            move: trash)
        } catch {
            let reason = CleanFailure.Reason.from(error, at: agent.url)
            ActivityLog.recordFailed(module: "Login Items", item: agent.url.path, reason: reason.logText, home: policy.homeURL)
            return .failed(reason)
        }
        ActivityLog.record(module: "Login Items", item: agent.url.path, size: Int64(size), mode: .trash, home: policy.homeURL)
        let trashed = inTrash.map { TrashedItem(original: agent.url, inTrash: $0, size: Int64(size)) }
        if let trashed { TrashRecords.add([trashed], module: "Login Items", home: policy.homeURL) }
        if let label { _ = await run(["bootout", service(label)]) } // by label, so it works once the plist is gone
        return Outcome(trashed: trashed)
    }

    /// Moves a system agent's or daemon's plist to the Trash through Finder (`move`, one admin password prompt), after
    /// checking it against `allowsSystemLaunchAgent` and that its `Label` is still the one shown. Not stopped (that needs
    /// root): it no longer starts after a restart. Not kept for Undo or `cleanmate restore`: moving it back needs the
    /// password too, so Finder's Put Back does it. A cancelled prompt leaves it, saying so.
    @concurrent static func removeSystem(_ agent: LaunchAgent, policy: SafetyPolicy = .current,
                                         move: SafeRemoval.BatchMove = Uninstaller.recycleAll) async -> Outcome {
        let allows: (URL) -> Bool = { policy.allowsSystemLaunchAgent($0, label: agent.label) }
        guard !agent.isUser, allows(agent.url) else { return .failed(.refused) }
        guard let dict = read(agent.url), info(dict, fileName: agent.url.lastPathComponent).label == agent.label
        else { return .failed(.changed) }
        let size = Int64((try? agent.url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        let (results, moveError) = await SafeRemoval.trashAll([agent.url], allows: allows, move: move)
        let reason: CleanFailure.Reason
        switch results[agent.url] {
        case .success(let inTrash)?:
            ActivityLog.record(module: "Login Items", item: agent.url.path, size: size, mode: .trash, home: policy.homeURL)
            return Outcome(trashed: inTrash.map { TrashedItem(original: agent.url, inTrash: $0, size: size) })
        case .failure(let failure)?:
            let notMoved = if case .failed = failure { true } else { false }
            if notMoved, (moveError as? CocoaError)?.code == .userCancelled {
                reason = .kept(String(localized: "the admin password was not given"))
            } else if notMoved, let finder = moveError as? FinderTrash.Failure {
                reason = .other(finder.localizedDescription)
            } else {
                reason = .from(failure, at: agent.url)
            }
        case nil:
            reason = .refused
        }
        ActivityLog.recordFailed(module: "Login Items", item: agent.url.path, reason: reason.logText, home: policy.homeURL)
        return .failed(reason)
    }
}
