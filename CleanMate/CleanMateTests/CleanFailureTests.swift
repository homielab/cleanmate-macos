import Foundation
import Testing
@testable import CleanMate

/// Every item a clean, uninstall or Login Items action leaves in place says why: its reason reaches the report, the
/// done screen's list and the activity log. Only throwaway folders and fake Trashes; launchctl never runs.
@Suite(.timeLimit(.minutes(1)))
struct CleanFailureTests {
    let root = TestTemp.url("CleanMateFailures")
    var home: URL { root.appending(path: "home") }
    var policy: SafetyPolicy { SafetyPolicy(home: home, temp: root.appending(path: "tmp")) }

    @discardableResult
    func file(_ path: String) throws -> URL {
        let url = home.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4_096).write(to: url)
        return url
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func logLines() -> [[String]] {
        ActivityLog.readAll(home: home).split(separator: "\n").map {
            $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        }
    }

    /// A file macOS won't let go (EPERM), a drive without a Trash and a tool exiting 1: three reasons, each with its
    /// own text, counted and listed for the done screen, and three "failed" lines in Activity.
    @Test func threeFailuresKeepThreeReasons() async throws {
        defer { remove() }
        let denied = try file("Library/Caches/com.test.a/denied.bin")
        let offTrash = try file("Library/Caches/com.test.a/network.bin")
        var trashing = CleanerItem(id: "test-trash", title: "Test Caches", paths: ["~/Library/Caches/com.test.a"])
        trashing.mode = .trash
        let scan = ItemScan(entries: [ScanEntry(url: denied, size: 4_096), ScanEntry(url: offTrash, size: 4_096)])
        var report = await Cleaner.clean(trashing, scan: scan, policy: policy, trash: { url in
            if url.lastPathComponent == "denied.bin" { throw POSIXError(.EPERM) }
            throw CocoaError(.featureUnsupported) // FileManager.trashItem on a volume without a Trash
        }, openPaths: { _ in [] })
        var tool = CleanerItem(id: "test-tool", title: "Test Tool", paths: [])
        tool.command = ShellCommand(executable: "/bin/sh", arguments: ["-c", "echo first >&2; echo 'disk is busy' >&2; exit 1"])
        report += await Cleaner.clean(tool, scan: ItemScan(measuredSize: 0), policy: policy, openPaths: { _ in [] })

        #expect(report.failures.map(\.reason) == [
            .notPermitted, .noTrash, .command(ShellCommand.Failure(tool: "sh", kind: .exited(1), lastLine: "disk is busy")),
        ])
        #expect(report.failures.map(\.url) == [denied, offTrash, nil])
        #expect(Set(report.failures.map { String(localized: $0.reason.text) }).count == 3)
        #expect(String(localized: report.failures[2].reason.text).contains("exited with code 1: disk is busy"))
        #expect(report.failures[2].title.map { String(localized: $0) } == "Test Tool")
        #expect(report.notCleaned == 3 && report.freed == 0)
        #expect(FileManager.default.fileExists(atPath: denied.path) && FileManager.default.fileExists(atPath: offTrash.path))
        // The done screen: "3 items couldn't be cleaned", the list grouped by reason.
        let groups = CleanFailuresSheet.groups(report.failures)
        #expect(groups.map(\.reason) == report.failures.map(\.reason) && groups.allSatisfy { $0.items.count == 1 })
        #expect(groups[0].reason.needsFullDiskAccess && !groups[1].reason.needsFullDiskAccess)

        report.logFailures(module: "Smart Scan", home: home)
        let failed = logLines().filter { $0.count > 7 && $0[5] == "failed" }
        #expect(failed.count == 3)
        #expect(failed.map { $0[2] } == [denied.path, offTrash.path, "Test Tool"])
        #expect(failed.map { $0[7] } == ["Not permitted: macOS blocked access", "This drive has no Trash",
                                         "“sh” exited with code 1: disk is busy"])
        let entries = ActivityLog.readAll(home: home).split(separator: "\n").map { ActivityLog.entry($0) }
        #expect(entries.compactMap(\.reason).count == 3)
    }

    /// A real cache folder locked with chmod 000 (a throwaway fixture): left in place as "not permitted", with its path.
    @Test func unreadableFolderIsNotPermitted() async throws {
        let locked = try file("Library/Caches/com.test.b/locked/data.bin").deletingLastPathComponent()
        defer {
            chmod(locked.path, 0o755)
            remove()
        }
        #expect(chmod(locked.path, 0) == 0)
        let item = CleanerItem(id: "test-delete", title: "Test Caches", paths: ["~/Library/Caches/com.test.b"])
        let report = await Cleaner.clean(item, scan: ItemScan(entries: [ScanEntry(url: locked, size: 4_096)]),
                                         policy: policy, openPaths: { _ in [] })
        #expect(report.failures == [CleanFailure(locked, .notPermitted, title: "Test Caches")])
        #expect(String(localized: report.failures[0].reason.text) == "Not permitted: macOS blocked access")
        #expect(report.failures[0].reason.explanation.contains("Full Disk Access"))
        chmod(locked.path, 0o755)
        #expect(FileManager.default.fileExists(atPath: locked.appending(path: "data.bin").path))
    }

    @Test func reasonsFromErrors() {
        typealias Reason = CleanFailure.Reason
        #expect(Reason.from(SafeRemoval.Failure.failed(EACCES)) == .notPermitted)
        #expect(Reason.from(SafeRemoval.Failure.failed(EBUSY)) == .inUse)
        #expect(Reason.from(SafeRemoval.Failure.locked) == .locked)
        #expect(Reason.from(SafeRemoval.Failure.changed) == .changed)
        #expect(Reason.from(POSIXError(.EROFS)) == .readOnly)
        #expect(Reason.from(CocoaError(.fileWriteNoPermission)) == .notPermitted)
        #expect(Reason.from(CocoaError(.featureUnsupported)) == .noTrash)
        #expect(Reason.from(CocoaError(.ubiquitousFileUnavailable)) == .notDownloaded)
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
        #expect(Reason.from(wrapped) == .notPermitted)
        guard case .other(let text) = Reason.errno(ENAMETOOLONG) else { Issue.record("errno"); return }
        #expect(text == String(cString: strerror(ENAMETOOLONG)))
        #expect(Reason.changed.isSkip && Reason.modified.isSkip && !Reason.notPermitted.isSkip)
    }

    /// `attempt`: nil on success; else the exit code and the last line printed to standard error, or why it didn't run.
    @Test func commandFailureSaysWhy() async {
        #expect(await ShellCommand(executable: "/usr/bin/true").attempt() == nil)
        let failed = await ShellCommand(executable: "/bin/sh", arguments: ["-c", "echo out; echo 'Error: no space' >&2; echo ' ' >&2; exit 3"]).attempt()
        #expect(failed == ShellCommand.Failure(tool: "sh", kind: .exited(3), lastLine: "Error: no space"))
        let silent = await ShellCommand(executable: "/bin/sh", arguments: ["-c", "exit 1"]).attempt()
        #expect(silent == ShellCommand.Failure(tool: "sh", kind: .exited(1), lastLine: nil))
        #expect(String(localized: CleanFailure.Reason.command(silent!).text) == "“sh” exited with code 1")
        let slow = await ShellCommand(executable: "/bin/sleep", arguments: ["30"], timeout: .milliseconds(300)).attempt()
        #expect(slow?.kind == .timedOut)
        #expect(await ShellCommand(executable: "/nonexistent/tool").attempt()?.kind == .notInstalled)
    }

    /// Remove hands back what went to the Trash; restore puts the plist back and loads it again.
    @Test func removedAgentIsPutBackAndLoaded() async throws {
        defer { remove() }
        let url = home.appending(path: "Library/LaunchAgents/com.foo.back.plist")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["Label": "com.foo.back"], format: .xml, options: 0).write(to: url)
        let agent = LaunchAgent(url: url, label: "com.foo.back", scope: .user, program: nil, programMissing: false,
                                owner: nil, state: .loaded)
        let trash = root.appending(path: "Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let calls = Calls()
        let outcome = await LaunchAgents.remove(agent, policy: policy, trash: { url in
            let target = trash.appending(path: url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }, run: { await calls.add($0); return true })
        let trashed = try #require(outcome.trashed)
        #expect(outcome.succeeded && !FileManager.default.fileExists(atPath: url.path))
        #expect(await LaunchAgents.restore(trashed, label: "com.foo.back", policy: policy) { await calls.add($0); return true } == .restored)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(await calls.all == [["bootout", "gui/\(getuid())/com.foo.back"], ["bootstrap", "gui/\(getuid())", url.path]])
        // Again: nothing in the Trash any more.
        #expect(await LaunchAgents.restore(trashed, label: "com.foo.back", policy: policy) { _ in true } == .notInTrash)
    }

    /// A launchctl error is shown as launchctl said it; a file the system refused, with its errno's reason.
    @Test func launchctlErrorIsTheReason() async throws {
        defer { remove() }
        let url = home.appending(path: "Library/LaunchAgents/com.foo.err.plist")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["Label": "com.foo.err"], format: .xml, options: 0).write(to: url)
        let agent = LaunchAgent(url: url, label: "com.foo.err", scope: .user, program: nil, programMissing: false,
                                owner: nil, state: .loaded)
        let refused = ShellCommand.Failure(tool: "launchctl", kind: .exited(5), lastLine: "Input/output error")
        let disabled = await LaunchAgents.disable(agent, policy: policy) { _ in LaunchAgents.RunResult(failure: refused) }
        #expect(disabled.failure == .command(refused))
        let removed = await LaunchAgents.remove(agent, policy: policy, trash: { _ in throw POSIXError(.EPERM) }) { _ in true }
        #expect(removed.failure == .notPermitted && FileManager.default.fileExists(atPath: url.path))
        #expect(logLines().last?.last == "Not permitted: macOS blocked access")
    }

    actor Calls {
        var all: [[String]] = []
        func add(_ arguments: [String]) { all.append(arguments) }
    }

    /// Login Items: after Remove the bar offers Undo (⌘Z too), which puts the agent back; a failed Undo or action is
    /// an alert with its reason.
    @MainActor @Test func loginItemsUndoRemove() async throws {
        let agent = LaunchAgent(url: URL(fileURLWithPath: "/x/a.plist"), label: "a", scope: .user,
                                program: nil, programMissing: false, owner: nil, state: .loaded)
        let trashed = TrashedItem(original: agent.url, inTrash: URL(fileURLWithPath: "/x/.Trash/a.plist"), size: 1)
        let model = LaunchAgentsModel(), undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        model.scan = { [agent] }
        model.run = { _, _ in LaunchAgents.Outcome(trashed: trashed) } // never the real launchctl
        var restored: [String] = []
        model.restore = { _, label in restored.append(label); return .restored }
        undo.beginUndoGrouping()
        await model.remove(agent)
        undo.endUndoGrouping()
        #expect(model.removed == LaunchAgentsModel.Removed(label: "a", trashed: trashed) && model.problem == nil)
        #expect(undo.canUndo && undo.undoActionName == "Remove")
        await model.undoRemove()
        #expect(restored == ["a"] && model.removed == nil && model.problem == nil && !undo.canUndo)

        undo.beginUndoGrouping() // groupsByEvent is off: registering outside a group would raise
        await model.remove(agent)
        undo.endUndoGrouping()
        model.restore = { _, _ in .occupied }
        await model.undoRemove()
        guard case .undo(.occupied)? = model.problem?.kind else { Issue.record("undo problem"); return }
        #expect(LaunchAgentsView.message(try #require(model.problem?.kind)).contains("nothing was overwritten"))

        model.problem = nil
        model.run = { _, _ in .failed(.command(ShellCommand.Failure(tool: "launchctl", kind: .exited(5), lastLine: "Boom"))) }
        await model.disable(agent)
        guard case .action(let reason)? = model.problem?.kind else { Issue.record("action problem"); return }
        #expect(String(localized: reason.text) == "“launchctl” exited with code 5: Boom")
    }

    /// Reset that throws before anything moved: every ticked item is listed as not moved, with the reason.
    @MainActor @Test func failedResetStillHasAnOutcome() async {
        let app = InstalledApp(url: URL(filePath: "/nonexistent/A.app"), name: "A", bundleID: "com.test.a", version: nil, lastUsed: nil)
        let a = URL(filePath: "/nonexistent/Library/Caches/com.test.a"), b = URL(filePath: "/nonexistent/Library/Logs/A")
        let model = UninstallerModel()
        model.apps = [app]
        model.runningApps = []
        model.appBundleIDs = { [] }
        model.selection = .app(app.url)
        model.entries = [AppDataEntry(url: a, size: 1), AppDataEntry(url: b, size: 1)]
        model.prepareReset()
        model.trash = { _, _ throws(Uninstaller.AppTrashError) in throw .brewBusy }
        await model.reset()
        guard case .removed(let report)? = model.outcome else { Issue.record("no outcome"); return }
        #expect(report.notCleaned == 2 && Set(report.failures.compactMap(\.url)) == [a, b])
        #expect(report.failures.allSatisfy { $0.reason == .kept(String(localized: "a Homebrew command is running")) })
    }

    /// A duplicate search that fails says so (banner) instead of stopping silently; Try Again searches again.
    @MainActor @Test func duplicateSearchErrorIsShown() async {
        let model = LargeFilesModel()
        model.files = [LargeFile(url: URL(fileURLWithPath: "/a"), size: 1, lastUsed: .now, kind: .other)]
        model.phase = .results
        let calls = Locked(0)
        model.findDuplicateFiles = { _, _, _ in
            let call = calls.withLock { $0 += 1; return $0 }
            if call == 1 { throw CocoaError(.fileReadNoPermission) }
            return DuplicateFinder.Result(groups: [])
        }
        model.duplicatesOnly = true
        while model.duplicateError == nil { await Task.yield() }
        #expect(model.duplicateGroups == nil && model.duplicateProgress == nil)
        model.retryDuplicates()
        #expect(model.duplicateError == nil)
        while model.duplicateGroups == nil { await Task.yield() }
        #expect(model.duplicateError == nil && calls.withLock { $0 } == 2)
    }

    /// Space Lens: a folder macOS won't list is "Not Readable" and never measured, not an empty folder.
    @MainActor @Test func spaceLensTellsUnreadableFromEmpty() async throws {
        let locked = home.appending(path: "A/locked"), empty = home.appending(path: "A/empty")
        for folder in [locked, empty] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try file("A/locked/x.bin")
        defer {
            chmod(locked.path, 0o755)
            remove()
        }
        #expect(chmod(locked.path, 0) == 0)
        #expect(SpaceLens.isUnreadable(locked) && !SpaceLens.isUnreadable(empty))
        let model = SpaceLensModel(center: NotificationCenter())
        model.disk = home.appending(path: "A")
        model.hasFullDiskAccess = { true }
        func settle() async throws { while model.measuring { try await Task.sleep(for: .milliseconds(5)) } }
        model.start(at: home.appending(path: "A"))
        try await settle()
        let row = try #require(model.items.first { $0.url.lastPathComponent == "locked" })
        #expect(row.isUnreadable && row.size == nil)
        #expect(model.items.first { $0.url.lastPathComponent == "empty" }?.isUnreadable == false)
        #expect(!model.unreadable)
        model.open(locked)
        try await settle()
        #expect(model.items.isEmpty && model.unreadable)
        model.open(empty)
        try await settle()
        #expect(model.items.isEmpty && !model.unreadable)
    }
}
