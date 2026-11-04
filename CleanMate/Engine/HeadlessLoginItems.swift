import Foundation

/// What `cleanmate login-items` does, with the engine of the app's Login Items: lists the launch agents in
/// ~/Library/LaunchAgents, /Library/LaunchAgents and /Library/LaunchDaemons, removes one of the user's own
/// (`LaunchAgents.remove`: its plist goes to the Trash, kept in `TrashRecords`, and it is stopped) and puts one back
/// (`TrashRecords`, then loaded again, as the app's Undo does). The system's agents and daemons are only listed:
/// changing them needs an administrator, and the tool never asks for a password.
nonisolated enum HeadlessLoginItems {
    struct Item: Codable, Equatable, Sendable {
        var label: String
        /// "user", "system-agent" or "system-daemon".
        var scope: String
        var path: String
        /// The program it runs; null when the plist names none.
        var program: String?
        /// The program is gone: the app that installed it was removed.
        var programMissing: Bool
        /// The app it belongs to; null when unknown.
        var owner: String?
        /// "running", "loaded", "not-loaded", "disabled" or "unknown" (a daemon: launchctl can't tell without root).
        var state: String
        var pid: Int?
        /// `login-items remove` may move it: one of the user's own, not one CleanMate keeps.
        var removable: Bool

        enum CodingKeys: String, CodingKey { case label, scope, path, program, programMissing, owner, state, pid, removable }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(label, forKey: .label)
            try container.encode(scope, forKey: .scope)
            try container.encode(path, forKey: .path)
            try container.encode(program, forKey: .program)
            try container.encode(programMissing, forKey: .programMissing)
            try container.encode(owner, forKey: .owner)
            try container.encode(state, forKey: .state)
            try container.encode(pid, forKey: .pid)
            try container.encode(removable, forKey: .removable)
        }
    }

    struct ListReport: Codable, Equatable, Sendable {
        var version: String
        var durationMs: Int
        var count: Int
        /// The user's first, then by label.
        var items: [Item]
    }

    /// `login-items remove` and `login-items restore`.
    struct ActionReport: Codable, Equatable, Sendable {
        var version: String
        var durationMs: Int
        /// "remove" or "restore".
        var action: String
        var label: String
        /// The plist's place (`~/…`).
        var path: String?
        /// Where it is in the Trash (remove), or was (restore).
        var trashed: String?
        /// Nothing changed; `reason` says why.
        var skipped: Bool
        var reason: String?
        var log: String

        enum CodingKeys: String, CodingKey { case version, durationMs, action, label, path, trashed, skipped, reason, log }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(version, forKey: .version)
            try container.encode(durationMs, forKey: .durationMs)
            try container.encode(action, forKey: .action)
            try container.encode(label, forKey: .label)
            try container.encode(path, forKey: .path)
            try container.encode(trashed, forKey: .trashed)
            try container.encode(skipped, forKey: .skipped)
            try container.encode(reason, forKey: .reason)
            try container.encode(log, forKey: .log)
        }
    }

    static let module = "Login Items"

    static func scope(_ scope: LaunchAgent.Scope) -> String {
        switch scope {
        case .user: "user"
        case .systemAgent: "system-agent"
        case .systemDaemon: "system-daemon"
        }
    }

    static func item(_ agent: LaunchAgent, policy: SafetyPolicy) -> Item {
        let (state, pid): (String, Int?) = switch agent.state {
        case .running(let pid): ("running", pid)
        case .loaded: ("loaded", nil)
        case .notLoaded: ("not-loaded", nil)
        case .disabled: ("disabled", nil)
        case .unknown: ("unknown", nil)
        }
        return Item(label: agent.label, scope: scope(agent.scope), path: HeadlessScan.displayPath(agent.url, home: policy.homeURL),
                    program: agent.program, programMissing: agent.programMissing, owner: agent.owner?.path, state: state,
                    pid: pid, removable: removable(agent, policy: policy))
    }

    static func removable(_ agent: LaunchAgent, policy: SafetyPolicy) -> Bool {
        agent.isUser && policy.allowsLaunchAgent(agent.url, label: agent.label)
    }

    static func list(sources: HeadlessScan.Sources) async -> ListReport {
        let started = ContinuousClock.now
        let policy = sources.policy()
        let agents = await sources.loginItems(policy)
            .sorted { ($0.isUser ? 0 : 1, $0.label.lowercased()) < ($1.isUser ? 0 : 1, $1.label.lowercased()) }
        let items = agents.map { item($0, policy: policy) }
        return ListReport(version: sources.version(), durationMs: HeadlessScan.milliseconds(ContinuousClock.now - started),
                          count: items.count, items: items)
    }

    enum Lookup {
        case found(LaunchAgent)
        /// Not one of the user's own, or one CleanMate keeps: only listed.
        case notRemovable(LaunchAgent)
        case notFound
    }

    /// The agent with `label` (exact, else without regard to case), the user's own first.
    static func find(_ label: String, sources: HeadlessScan.Sources) async -> Lookup {
        let policy = sources.policy()
        let agents = await sources.loginItems(policy)
        let exact = agents.filter { $0.label == label }
        let matches = exact.isEmpty ? agents.filter { $0.label.lowercased() == label.lowercased() } : exact
        guard let agent = matches.first(where: { removable($0, policy: policy) }) ?? matches.first else { return .notFound }
        return removable(agent, policy: policy) ? .found(agent) : .notRemovable(agent)
    }

    /// Moves the agent's plist to the Trash and stops it (`LaunchAgents.remove`).
    static func remove(_ agent: LaunchAgent, sources: HeadlessScan.Sources) async -> ActionReport {
        let started = ContinuousClock.now
        let policy = sources.policy()
        let home = policy.homeURL
        let trash = sources.trash
        let outcome = await LaunchAgents.remove(agent, policy: policy, trash: trash, run: sources.launchctl)
        return ActionReport(version: sources.version(), durationMs: HeadlessScan.milliseconds(ContinuousClock.now - started),
                            action: "remove", label: agent.label, path: HeadlessScan.displayPath(agent.url, home: home),
                            trashed: outcome.trashed?.inTrash.path, skipped: !outcome.succeeded,
                            reason: outcome.failure.map { $0 == .changed ? HeadlessClean.changedReason : $0.english },
                            log: HeadlessScan.displayPath(ActivityLog.url(home: home), home: home))
    }

    /// The label of a plist CleanMate moved to the Trash: its `Label`, else its old file name without `.plist`.
    static func label(of record: TrashRecords.Record) -> String {
        let original = URL(fileURLWithPath: record.original)
        let dict = LaunchAgents.read(URL(fileURLWithPath: record.trashed)) ?? [:]
        return LaunchAgents.info(dict, fileName: original.lastPathComponent).label
    }

    /// The newest login item CleanMate moved to the Trash (here or in the app) with `label` that is still there.
    static func trashed(_ label: String, home: URL) -> TrashRecords.Record? {
        let records = TrashRecords.inTrash(home: home).filter { $0.moduleName == module }
        let newestFirst = records.reversed()
        return newestFirst.first { self.label(of: $0) == label }
            ?? newestFirst.first { self.label(of: $0).lowercased() == label.lowercased() }
    }

    /// Puts the plist back at its exact place (never over another file), then loads it again when it is the user's
    /// own agent with its own label, as the app's Undo does (`LaunchAgents.restore`). nil: none in the Trash.
    static func restore(_ label: String, sources: HeadlessScan.Sources) async -> ActionReport? {
        let started = ContinuousClock.now
        let policy = sources.policy()
        let home = policy.homeURL
        guard let record = trashed(label, home: home) else { return nil }
        let found = self.label(of: record)
        let outcome = TrashRecords.restore([record.trashed], home: home)[record.trashed] ?? .notInTrash
        let original = URL(fileURLWithPath: record.original)
        if outcome == .restored, policy.allowsLaunchAgent(original, label: found),
           let dict = LaunchAgents.read(original), LaunchAgents.info(dict, fileName: original.lastPathComponent).label == found {
            _ = await sources.launchctl(["bootstrap", "gui/\(getuid())", original.path]) // fails when it was disabled: fine
        }
        return ActionReport(version: sources.version(), durationMs: HeadlessScan.milliseconds(ContinuousClock.now - started),
                            action: "restore", label: found, path: HeadlessScan.displayPath(original, home: home),
                            trashed: record.trashed, skipped: outcome != .restored, reason: outcome.reason,
                            log: HeadlessScan.displayPath(ActivityLog.url(home: home), home: home))
    }
}
