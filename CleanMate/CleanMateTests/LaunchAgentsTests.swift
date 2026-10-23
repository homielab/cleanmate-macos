import Foundation
import Testing
@testable import CleanMate

/// Pure parsing and the safety rule only: no real agent is ever stopped, disabled or trashed.
struct LaunchAgentsTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "CleanMateAgents-\(UUID().uuidString)")
    var home: URL { root.appending(path: "home") }
    var policy: SafetyPolicy { SafetyPolicy(home: home, temp: root.appending(path: "tmp")) }

    @Test func parsesLaunchctlList() {
        let output = "PID\tStatus\tLabel\n50336\t0\tme.limcare.tunnel\n-\t0\tcom.ollama.ollama\n-\t-9\tcom.apple.progressd\n"
        let (loaded, pids) = LaunchAgents.parseList(output)
        #expect(loaded == ["me.limcare.tunnel", "com.ollama.ollama", "com.apple.progressd"])
        #expect(pids == ["me.limcare.tunnel": 50336])
    }

    @Test func parsesPrintDisabled() {
        let output = """
            disabled services = {
            \t"com.docker.helper" => enabled
            \t"com.foo.agent" => disabled
            \t"com.old.agent" => true
            \t"com.on.agent" => false
            }
            """
        #expect(LaunchAgents.parseDisabled(output) == ["com.foo.agent", "com.old.agent"])
    }

    @Test func stateRunningBeatsLoadedBeatsDisabled() {
        let loaded: Set = ["a", "b"], pids = ["a": 12], disabled: Set = ["a", "b", "c"]
        #expect(LaunchAgents.state(of: "a", loaded: loaded, pids: pids, disabled: disabled) == .running(pid: 12))
        #expect(LaunchAgents.state(of: "b", loaded: loaded, pids: pids, disabled: disabled) == .loaded)
        #expect(LaunchAgents.state(of: "c", loaded: loaded, pids: pids, disabled: disabled) == .disabled)
        #expect(LaunchAgents.state(of: "d", loaded: loaded, pids: pids, disabled: disabled) == .notLoaded)
    }

    @Test func infoFallsBackToFileNameAndProgramArguments() {
        let a = LaunchAgents.info(["ProgramArguments": ["/usr/bin/x", "-y"]], fileName: "com.foo.x.plist")
        #expect(a.label == "com.foo.x" && a.program == "/usr/bin/x")
        let b = LaunchAgents.info(["Label": "L", "Program": "/p", "ProgramArguments": ["/q"]], fileName: "f.plist")
        #expect(b.label == "L" && b.program == "/p")
    }

    @Test func ownerFromAppBundleThenBundleIDPrefix() {
        let apps = ["com.vendor.App": URL(fileURLWithPath: "/Applications/App.app")]
        let lookup: (String) -> URL? = { apps[$0] }
        #expect(LaunchAgents.owner(program: "/Applications/Foo.app/Contents/MacOS/helper", label: "x.y.z", appForID: lookup)
            == URL(fileURLWithPath: "/Applications/Foo.app"))
        #expect(LaunchAgents.owner(program: "/usr/local/bin/x", label: "com.vendor.App.helper.agent", appForID: lookup)
            == URL(fileURLWithPath: "/Applications/App.app"))
        // Two-part prefixes (`com.vendor`) never count as an owner.
        #expect(LaunchAgents.owner(program: nil, label: "com.vendor", appForID: { _ in URL(fileURLWithPath: "/x.app") }) == nil)
    }

    @Test func ownerFromAssociatedBundleIdentifiers() {
        // `/bin/sh -c …` daemon whose label isn't the app's bundle id (RustDesk), id given as a string or an array.
        let lookup: (String) -> URL? = { $0 == "com.carriez.rustdesk" ? URL(fileURLWithPath: "/Applications/RustDesk.app") : nil }
        for dict: [String: Any] in [["AssociatedBundleIdentifiers": "com.carriez.rustdesk"],
                                    ["AssociatedBundleIdentifiers": ["com.other.gone", "com.carriez.rustdesk"]]] {
            #expect(LaunchAgents.owner(program: "/bin/sh", label: "com.carriez.RustDesk_service",
                                       associated: LaunchAgents.associatedIDs(dict), appForID: lookup)
                == URL(fileURLWithPath: "/Applications/RustDesk.app"))
        }
        #expect(LaunchAgents.associatedIDs([:]).isEmpty)
    }

    @Test func onlyNonAppleUserAgentPlistsMayBeChanged() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let agents = home.appending(path: "Library/LaunchAgents")
        try FileManager.default.createDirectory(at: agents.appending(path: "sub"), withIntermediateDirectories: true)
        for name in ["com.foo.agent.plist", "com.apple.thing.plist", "sub/com.foo.nested.plist", "notes.txt"] {
            try Data("x".utf8).write(to: agents.appending(path: name))
        }
        try FileManager.default.createSymbolicLink(
            at: agents.appending(path: "link.plist"), withDestinationURL: agents.appending(path: "com.foo.agent.plist"))
        let ok = agents.appending(path: "com.foo.agent.plist")
        #expect(policy.allowsLaunchAgent(ok, label: "com.foo.agent"))
        #expect(!policy.allowsLaunchAgent(ok, label: "com.apple.Finder"))
        #expect(!policy.allowsLaunchAgent(ok, label: "com.foo/../x"))
        #expect(!policy.allowsLaunchAgent(ok, label: ""))
        #expect(!policy.allowsLaunchAgent(agents.appending(path: "com.apple.thing.plist"), label: "com.apple.thing"))
        #expect(!policy.allowsLaunchAgent(agents.appending(path: "sub/com.foo.nested.plist"), label: "com.foo.nested"))
        #expect(!policy.allowsLaunchAgent(agents.appending(path: "notes.txt"), label: "notes"))
        #expect(!policy.allowsLaunchAgent(agents.appending(path: "link.plist"), label: "link"))
        #expect(!policy.allowsLaunchAgent(URL(fileURLWithPath: "/Library/LaunchAgents/com.foo.agent.plist"), label: "com.foo.agent"))
    }

    @Test func refusedAgentsAreNeverTouched() async {
        let agent = LaunchAgent(
            url: URL(fileURLWithPath: "/Library/LaunchDaemons/com.foo.d.plist"), label: "com.foo.d", scope: .systemDaemon,
            program: nil, programMissing: false, owner: nil, state: .unknown)
        #expect(await !LaunchAgents.disable(agent, policy: policy))
        #expect(await !LaunchAgents.enable(agent, policy: policy))
        #expect(await !LaunchAgents.remove(agent, policy: policy))
    }

    actor Calls {
        var all: [[String]] = []
        func add(_ arguments: [String]) { all.append(arguments) }
    }

    func plist(_ name: String, label: String?) throws -> LaunchAgent {
        let folder = home.appending(path: "Library/LaunchAgents")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        try PropertyListSerialization.data(fromPropertyList: label.map { ["Label": $0] } ?? [:], format: .xml, options: 0)
            .write(to: url)
        return LaunchAgent(url: url, label: label ?? (name as NSString).deletingPathExtension, scope: .user, program: nil,
                           programMissing: false, owner: nil, state: .loaded)
    }

    /// Acts by the plist's own Label, even when it differs from the file name.
    @Test func actsByTheParsedLabel() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = try plist("helper.plist", label: "com.foo.helper")
        let calls = Calls()
        #expect(await LaunchAgents.disable(agent, policy: policy) { await calls.add($0); return true })
        #expect(await LaunchAgents.enable(agent, policy: policy) { await calls.add($0); return true })
        let service = "gui/\(getuid())/com.foo.helper"
        #expect(await calls.all == [["bootout", service], ["disable", service], ["enable", service],
                                    ["bootstrap", "gui/\(getuid())", agent.url.path]])
    }

    /// A label another plist of the folder also declares, or a plist rewritten since the scan, is never sent to
    /// launchctl: disable would persist for (and bootout stop) the other agent; Remove only trashes the file.
    @Test func refusesALabelThatIsNotThisAgents() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let copy = try plist("copy.plist", label: "com.foo.real")
        _ = try plist("com.foo.real.plist", label: "com.foo.real")
        var changed = try plist("changed.plist", label: "com.foo.new")
        changed = LaunchAgent(url: changed.url, label: "com.foo.old", scope: .user, program: nil,
                              programMissing: false, owner: nil, state: .loaded)
        let unreadable = try plist("broken.plist", label: nil)
        try Data("x".utf8).write(to: unreadable.url)
        let calls = Calls()
        for agent in [copy, changed, unreadable] {
            #expect(await !LaunchAgents.disable(agent, policy: policy) { await calls.add($0); return true })
            #expect(await !LaunchAgents.enable(agent, policy: policy) { await calls.add($0); return true })
        }
        #expect(await LaunchAgents.remove(copy, policy: policy) { await calls.add($0); return true })
        #expect(!FileManager.default.fileExists(atPath: copy.url.path))
        #expect(await calls.all.isEmpty)
    }

    @Test func removeTrashesThenBootsOutItsOwnLabel() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = try plist("com.foo.solo.plist", label: "com.foo.solo")
        let calls = Calls()
        #expect(await LaunchAgents.remove(agent, policy: policy) { await calls.add($0); return false })
        #expect(!FileManager.default.fileExists(atPath: agent.url.path))
        #expect(await calls.all == [["bootout", "gui/\(getuid())/com.foo.solo"]])
    }
}
