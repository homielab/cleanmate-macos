import AppKit
import Combine

/// Login Items: launch agents with their state; the user's own can be disabled, enabled or removed.
final class LaunchAgentsModel: ObservableObject {
    @Published private(set) var agents: [LaunchAgent] = []
    @Published private(set) var loading = false
    @Published private(set) var working = false
    /// Set when an action or its Undo failed, shown as an alert with the reason.
    @Published var problem: Problem?
    /// The agent last moved to the Trash, until its Undo or another action: the bar offers "Undo".
    @Published private(set) var removed: Removed?
    /// Edit › Undo / ⌘Z of the last removal.
    var undoManager: UndoManager?
    private var started = false
    /// Bumped by every load: a slower, older listing never replaces a newer one.
    private var generation = 0
    /// Injected by tests (sample agents instead of the real ones).
    var scan: () async -> [LaunchAgent] = {
        await LaunchAgents.scan { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    /// Runs a launchctl action; injected by tests so no real launchctl runs.
    var run: (_ action: (LaunchAgent, SafetyPolicy) async -> LaunchAgents.Outcome, _ agent: LaunchAgent) async -> LaunchAgents.Outcome = {
        await $0($1, .current)
    }
    /// Puts a removed agent's plist back and loads it again; injected by tests.
    var restore: (TrashedItem, String) async -> TrashUndo.Outcome = { await LaunchAgents.restore($0, label: $1) }

    /// Why an action on `label` failed: launchctl's error, the file system's, or Undo's.
    struct Problem: Identifiable {
        let id = UUID()
        var label: String
        var kind: Kind
        enum Kind { case action(CleanFailure.Reason), undo(TrashUndo.Outcome) }
    }

    /// An agent moved to the Trash by "Remove…".
    struct Removed: Equatable {
        var label: String
        var trashed: TrashedItem
    }

    /// Toolbar search: label, app or program; "" = no search.
    @Published var search = ""

    /// The agents of `scope` the search finds (all without a search).
    func agents(_ scope: LaunchAgent.Scope) -> [LaunchAgent] {
        agents.filter { $0.scope == scope && Self.matches($0, search) }
    }

    nonisolated static func matches(_ agent: LaunchAgent, _ search: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        let app = agent.owner.map { FileManager.default.displayName(atPath: $0.path) }
        return [agent.label, app, agent.program].contains { $0?.localizedStandardContains(query) == true }
    }

    func loadIfNeeded() async {
        if !started { await load() }
    }

    func load() async {
        started = true
        generation += 1
        let current = generation
        loading = true
        let found = await scan()
        guard current == generation else { return }
        agents = found
        loading = false
    }

    func disable(_ agent: LaunchAgent) async { await perform(agent) { await LaunchAgents.disable($0, policy: $1) } }
    func enable(_ agent: LaunchAgent) async { await perform(agent) { await LaunchAgents.enable($0, policy: $1) } }
    func remove(_ agent: LaunchAgent) async { await perform(agent) { await LaunchAgents.remove($0, policy: $1) } }

    private func perform(_ agent: LaunchAgent, _ action: (LaunchAgent, SafetyPolicy) async -> LaunchAgents.Outcome) async {
        guard !working else { return } // one launchctl action at a time (e.g. Disable + Move to Trash on the same agent)
        working = true
        let outcome = await run(action, agent)
        working = false
        if let reason = outcome.failure { problem = Problem(label: agent.label, kind: .action(reason)) }
        if let trashed = outcome.trashed {
            removed = Removed(label: agent.label, trashed: trashed)
            undoManager?.registerTrashUndo(self, name: String(localized: "Remove")) { await $0.undoRemove() }
        } else if outcome.succeeded {
            // Disable or Enable: an Undo of an older removal would now act on a list that changed under it.
            dropUndo()
        }
        await load()
    }

    /// "Undo" of the last removal: the plist back from the Trash, loaded again. Why not, as an alert.
    func undoRemove() async {
        guard let removed, !working else { return }
        dropUndo()
        working = true
        let outcome = await restore(removed.trashed, removed.label)
        working = false
        if outcome != .restored { problem = Problem(label: removed.label, kind: .undo(outcome)) }
        await load()
    }

    private func dropUndo() {
        removed = nil
        undoManager?.removeAllActions(withTarget: self)
    }

    static func openLoginItemsSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }
}

extension LaunchAgentsModel: TrashUndoing {}
