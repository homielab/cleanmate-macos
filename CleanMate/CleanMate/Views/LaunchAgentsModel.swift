import AppKit
import Combine

/// Login Items: launch agents with their state; the user's own can be disabled, enabled or removed.
final class LaunchAgentsModel: ObservableObject {
    @Published private(set) var agents: [LaunchAgent] = []
    @Published private(set) var loading = false
    @Published private(set) var working = false
    /// Set when an action failed, shown as an alert.
    @Published var failed: LaunchAgent?
    private var started = false
    /// Bumped by every load: a slower, older listing never replaces a newer one.
    private var generation = 0
    /// Injected by tests (sample agents instead of the real ones).
    var scan: () async -> [LaunchAgent] = {
        await LaunchAgents.scan { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    /// Runs a launchctl action; injected by tests so no real launchctl runs.
    var run: (_ action: (LaunchAgent, SafetyPolicy) async -> Bool, _ agent: LaunchAgent) async -> Bool = {
        await $0($1, .current)
    }

    func agents(_ scope: LaunchAgent.Scope) -> [LaunchAgent] { agents.filter { $0.scope == scope } }

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

    private func perform(_ agent: LaunchAgent, _ action: (LaunchAgent, SafetyPolicy) async -> Bool) async {
        guard !working else { return } // one launchctl action at a time (e.g. Disable + Move to Trash on the same agent)
        working = true
        let ok = await run(action, agent)
        working = false
        if !ok { failed = agent }
        await load()
    }

    static func openLoginItemsSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }
}
