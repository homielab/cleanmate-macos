import Foundation
import Testing
@testable import CleanMate

/// Third-party agents and daemons of the system Library, against a throwaway fake `/Library`: nothing real is moved,
/// no launchctl runs and no password is asked.
final class LaunchAgentsSystemTests {
    let root = TestTemp.url("CleanMateSystemAgents")
    deinit { try? FileManager.default.removeItem(at: root) }
    var home: URL { root.appending(path: "home") }
    var library: URL { root.appending(path: "Library") }
    var policy: SafetyPolicy { SafetyPolicy(home: home, temp: root.appending(path: "tmp"), systemLibrary: library) }
    var trash: URL { root.appending(path: "Trash") }
    let noLaunchctl: LaunchAgents.Reader = { _ in nil }

    @discardableResult
    func plist(_ path: String, label: String? = nil, program: String? = nil, associated: String? = nil) throws -> URL {
        let url = library.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var dict: [String: Any] = [:]
        if let label { dict["Label"] = label }
        if let program { dict["ProgramArguments"] = [program, "--run"] }
        if let associated { dict["AssociatedBundleIdentifiers"] = associated }
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0).write(to: url)
        return url
    }

    func scan(apps: [String: URL] = [:], processes: [String: Int] = [:]) async -> [LaunchAgent] {
        await LaunchAgents.scan(appForID: { apps[$0] }, policy: policy, scopes: [.systemAgent, .systemDaemon],
                                read: noLaunchctl, processes: { processes })
    }

    /// Moves into a fake Trash (a rename keeps the inode), as Finder would after the password.
    final class FakeFinder: @unchecked Sendable {
        let trash: URL
        var error: Error?
        private let lock = NSLock()
        private(set) var calls: [[URL]] = []
        init(trash: URL, error: Error? = nil) { self.trash = trash; self.error = error }

        func move(_ urls: [URL]) -> (moved: [URL: URL?], error: Error?) {
            lock.withLock { calls.append(urls) }
            if let error { return ([:], error) }
            try? FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            var moved: [URL: URL?] = [:]
            for url in urls {
                let target = trash.appending(path: url.lastPathComponent)
                if (try? FileManager.default.moveItem(at: url, to: target)) != nil { moved[url] = target }
            }
            return (moved, nil)
        }
    }

    @Test func policyAllowsOnlyThirdPartyPlistsOfTheSystemFolders() throws {
        let daemon = try plist("LaunchDaemons/com.vendor.helper.plist", label: "com.vendor.helper")
        let agent = try plist("LaunchAgents/com.vendor.agent.plist", label: "com.vendor.agent")
        #expect(policy.allowsSystemLaunchAgent(daemon, label: "com.vendor.helper"))
        #expect(policy.allowsSystemLaunchAgent(agent, label: "com.vendor.agent"))
        // Apple's or CleanMate's, by name or label; a label naming another service.
        let apple = try plist("LaunchDaemons/com.apple.thing.plist", label: "com.apple.thing")
        let own = try plist("LaunchDaemons/com.homielab.CleanMate.helper.plist", label: "com.homielab.CleanMate.helper")
        #expect(!policy.allowsSystemLaunchAgent(apple, label: "com.apple.thing"))
        #expect(!policy.allowsSystemLaunchAgent(daemon, label: "com.apple.mDNSResponder"))
        #expect(!policy.allowsSystemLaunchAgent(own, label: "com.homielab.CleanMate.helper"))
        #expect(!policy.allowsSystemLaunchAgent(daemon, label: "com.vendor/../x"))
        #expect(!policy.allowsSystemLaunchAgent(daemon, label: ""))
        // Hidden, nested, not a plist, a symlink, another Library folder.
        for path in ["LaunchDaemons/.com.vendor.x.plist", "LaunchDaemons/sub/com.vendor.x.plist", "LaunchDaemons/com.vendor.x.txt",
                     "PrivilegedHelperTools/com.vendor.x.plist"] {
            #expect(!policy.allowsSystemLaunchAgent(try plist(path, label: "com.vendor.x"), label: "com.vendor.x"), "\(path)")
        }
        let link = library.appending(path: "LaunchDaemons/com.vendor.link.plist")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: daemon)
        #expect(!policy.allowsSystemLaunchAgent(link, label: "com.vendor.helper"))
        // The user's own folder is `allowsLaunchAgent`'s; no system Library, nothing.
        let user = home.appending(path: "Library/LaunchAgents/com.vendor.agent.plist")
        try FileManager.default.createDirectory(at: user.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: agent, to: user)
        #expect(!policy.allowsSystemLaunchAgent(user, label: "com.vendor.agent"))
        #expect(!SafetyPolicy(home: home, temp: root.appending(path: "tmp")).allowsSystemLaunchAgent(daemon, label: "com.vendor.helper"))
    }

    @Test func scanListsThirdPartyItemsWithOwnerStateAndRemovedApp() async throws {
        let apps = root.appending(path: "Applications")
        let installed = apps.appending(path: "Tool.app")
        try FileManager.default.createDirectory(at: installed.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        let tool = installed.appending(path: "Contents/MacOS/tool")
        try Data("x".utf8).write(to: tool)
        try plist("LaunchDaemons/com.vendor.tool.plist", label: "com.vendor.tool", program: tool.path)
        // Its app was removed: the program inside it is gone.
        try plist("LaunchDaemons/com.gone.helper.plist", label: "com.gone.helper",
                  program: apps.appending(path: "Gone.app/Contents/MacOS/helper").path)
        // Owner from AssociatedBundleIdentifiers; program missing but the app is installed.
        try plist("LaunchAgents/com.other.agent.plist", label: "com.other.agent", program: "/nonexistent/agent",
                  associated: "com.other.App")
        try plist("LaunchDaemons/com.apple.hidden.plist", label: "com.apple.hidden")
        try plist("LaunchDaemons/com.vendor.applelabel.plist", label: "com.apple.sneaky")
        try plist("LaunchDaemons/com.homielab.CleanMate.helper.plist", label: "com.homielab.CleanMate.helper")

        let found = await scan(apps: ["com.other.App": installed], processes: [tool.path: 321])
        let byLabel = Dictionary(uniqueKeysWithValues: found.map { ($0.label, $0) })
        #expect(Set(byLabel.keys) == ["com.vendor.tool", "com.gone.helper", "com.other.agent", "com.homielab.CleanMate.helper"])
        let running = try #require(byLabel["com.vendor.tool"])
        #expect(running.scope == .systemDaemon && running.state == .running(pid: 321) && running.owner == installed)
        #expect(running.removable && !running.programMissing && !running.appRemoved)
        let gone = try #require(byLabel["com.gone.helper"])
        #expect(gone.state == .unknown && gone.programMissing && gone.appRemoved && gone.removable)
        let other = try #require(byLabel["com.other.agent"])
        #expect(other.scope == .systemAgent && other.owner == installed && other.programMissing && !other.appRemoved)
        #expect(byLabel["com.homielab.CleanMate.helper"]?.removable == false) // listed, never removed
    }

    @Test func removeMovesThePlistAfterOnePromptAndLogsIt() async throws {
        let url = try plist("LaunchDaemons/com.vendor.helper.plist", label: "com.vendor.helper")
        let agent = try #require(await scan().first)
        let finder = FakeFinder(trash: trash)
        let outcome = await LaunchAgents.removeSystem(agent, policy: policy, move: { finder.move($0) })
        #expect(outcome.succeeded && finder.calls.count == 1)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(outcome.trashed?.inTrash == trash.appending(path: url.lastPathComponent))
        #expect(ActivityLog.read(home: home).contains(url.path))
        #expect(TrashRecords.inTrash(home: home).isEmpty) // put back with Finder only, never by CleanMate
    }

    @Test func cancelledPasswordLeavesThePlistAndSaysSo() async throws {
        let url = try plist("LaunchDaemons/com.vendor.helper.plist", label: "com.vendor.helper")
        let agent = try #require(await scan().first)
        let finder = FakeFinder(trash: trash, error: CocoaError(.userCancelled))
        let outcome = await LaunchAgents.removeSystem(agent, policy: policy, move: { finder.move($0) })
        guard case .kept? = outcome.failure else { Issue.record("not kept: \(String(describing: outcome.failure))"); return }
        #expect(FileManager.default.fileExists(atPath: url.path) && outcome.trashed == nil)
        finder.error = FinderTrash.Failure.notAllowed
        guard case .other? = await LaunchAgents.removeSystem(agent, policy: policy, move: { finder.move($0) }).failure
        else { Issue.record("Finder refused"); return }
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// A label changed since the scan, an Apple or CleanMate plist, or the user's own agent never reach Finder; with
    /// two plists of one label only the one shown moves.
    @Test func removeRefusesChangedAndProtectedPlists() async throws {
        let url = try plist("LaunchDaemons/com.vendor.helper.plist", label: "com.vendor.helper")
        try plist("LaunchDaemons/com.vendor.twin.plist", label: "com.vendor.helper")
        try plist("LaunchDaemons/com.homielab.CleanMate.helper.plist", label: "com.homielab.CleanMate.helper")
        let found = await scan()
        let finder = FakeFinder(trash: trash)
        let move: SafeRemoval.BatchMove = { finder.move($0) }
        let agent = try #require(found.first { $0.url.lastPathComponent == url.lastPathComponent })
        let own = try #require(found.first { $0.label.hasPrefix("com.homielab") })
        #expect(await LaunchAgents.removeSystem(own, policy: policy, move: move).failure == .refused)
        let user = LaunchAgent(url: agent.url, label: agent.label, scope: .user, program: nil, programMissing: false,
                               owner: nil, state: .loaded)
        #expect(await LaunchAgents.removeSystem(user, policy: policy, move: move).failure == .refused)
        try plist("LaunchDaemons/com.vendor.helper.plist", label: "com.vendor.other")
        #expect(await LaunchAgents.removeSystem(agent, policy: policy, move: move).failure == .changed)
        #expect(finder.calls.isEmpty)

        try plist("LaunchDaemons/com.vendor.helper.plist", label: "com.vendor.helper")
        #expect(await LaunchAgents.removeSystem(agent, policy: policy, move: move).succeeded)
        #expect(finder.calls.count == 1)
        #expect(FileManager.default.fileExists(atPath: library.appending(path: "LaunchDaemons/com.vendor.twin.plist").path))
    }

    /// The bar says it stops after a restart: no Undo (moving it back needs the password), nothing to undo with ⌘Z.
    @MainActor @Test func modelOffersNoUndoForASystemRemoval() async {
        let agent = LaunchAgent(url: URL(fileURLWithPath: "/x/LaunchDaemons/a.plist"), label: "a", scope: .systemDaemon,
                                program: nil, programMissing: false, owner: nil, state: .unknown, removable: true)
        let trashed = TrashedItem(original: agent.url, inTrash: URL(fileURLWithPath: "/x/.Trash/a.plist"), size: 1)
        let model = LaunchAgentsModel(), undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        model.scan = { [agent] }
        model.run = { _, _ in LaunchAgents.Outcome(trashed: trashed) }
        var restored = 0
        model.restore = { _, _ in restored += 1; return .restored }
        undo.beginUndoGrouping()
        await model.remove(agent)
        undo.endUndoGrouping()
        #expect(model.removed == LaunchAgentsModel.Removed(label: "a", trashed: trashed, system: true) && undo.undoActionName.isEmpty)
        await model.undoRemove()
        #expect(restored == 0 && model.removed != nil)
    }
}
