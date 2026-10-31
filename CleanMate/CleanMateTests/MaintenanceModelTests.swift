import Foundation
import Testing
@testable import CleanMate

/// Maintenance with a fake command runner and activity recorder: no real tool runs, nothing is written to the real log.
@MainActor
struct MaintenanceModelTests {
    nonisolated static let date = Date(timeIntervalSince1970: 1_768_478_400)
    nonisolated static let twoSnapshots = LocalSnapshots.parse("""
        Snapshots for disk /:
        com.apple.TimeMachine.2026-10-30-101112.local
        com.apple.TimeMachine.2026-10-28-230501.local
        """)

    /// A model whose runner answers from `outcomes` (by executable + arguments) and remembers every call.
    @MainActor final class Fake {
        var calls: [String] = []
        var recorded: [(MaintenanceTask, Bool)] = []
        var recordedSnapshots: [(String, Bool)] = []
        /// What the snapshot list reads, in order; the last one repeats.
        var lists: [LocalSnapshots] = [MaintenanceModelTests.twoSnapshots]
        var reads = 0
        var outcomes: [String: ShellCommand.Outcome?] = [:]

        func model() -> MaintenanceModel {
            let model = MaintenanceModel()
            model.runCommand = { command in
                let line = ([(command.executable as NSString).lastPathComponent] + command.arguments).joined(separator: " ")
                self.calls.append(line)
                return self.outcomes[line] ?? ShellCommand.Outcome(succeeded: true, output: "")
            }
            model.record = { self.recorded.append(($0, $1)) }
            model.recordSnapshot = { self.recordedSnapshots.append(($0.stamp, $1)) }
            model.readSnapshots = {
                await MainActor.run {
                    self.reads += 1
                    return self.lists[min(self.reads, self.lists.count) - 1]
                }
            }
            model.now = { MaintenanceModelTests.date }
            return model
        }
    }

    @Test func tasksRunTheirCommandsInOrder() async {
        let fake = Fake()
        let model = fake.model()
        await model.run(.launchServices)
        await model.run(.quickLook)
        await model.run(.finderAndDock)
        #expect(fake.calls == [
            "lsregister -gc", "lsregister -r -f -apps local,system,user",
            "qlmanage -r", "qlmanage -r cache",
            "killall Finder", "killall Dock",
        ])
        #expect(fake.recorded.map(\.0) == [.launchServices, .quickLook, .finderAndDock])
        #expect(fake.recorded.map(\.1) == [true, true, true])
        #expect(model.results[.quickLook] == .init(status: .succeeded(Self.date)))
        #expect(model.running == nil)
    }

    /// Font cache: the user's registry only, then the font server; icon cache: only the user's caches, then the Dock.
    @Test func fontAndIconCacheTasks() async {
        let fake = Fake()
        let model = fake.model()
        await model.run(.fontCache)
        await model.run(.iconCache)
        let dir = MaintenanceTask.userCacheDir
        #expect(dir.hasPrefix("/") && dir.hasSuffix("/C/"))
        #expect(fake.calls == [
            "atsutil databases -removeUser", "atsutil server -shutdown", "atsutil server -ping",
            "rm -rf \(dir)com.apple.dock.iconcache \(dir)com.apple.iconservices \(dir)com.apple.iconservices.store",
            "killall Dock",
        ])
        #expect(fake.recorded.map(\.0) == [.fontCache, .iconCache] && fake.recorded.allSatisfy(\.1))
        #expect(MaintenanceTask.iconCachePaths(in: "/var/folders/x/C").allSatisfy { $0.hasPrefix("/var/folders/x/C/com.apple.") })
    }

    @Test func outputOfEveryStepIsKept() async {
        let fake = Fake()
        fake.outcomes["qlmanage -r"] = .init(succeeded: true, output: "qlmanage: resetting quicklookd\n")
        fake.outcomes["qlmanage -r cache"] = .init(succeeded: true, output: "cache reset\n")
        let model = fake.model()
        await model.run(.quickLook)
        #expect(model.results[.quickLook] == .init(status: .succeeded(Self.date),
                                                    output: "qlmanage: resetting quicklookd\ncache reset"))
    }

    /// A failing step stops the task: Dock is not restarted when Finder could not be, and the line says "failed".
    @Test func aFailingStepStopsTheTask() async {
        let fake = Fake()
        fake.outcomes["killall Finder"] = .init(succeeded: false, output: "No matching processes belonging to you were found\n")
        let model = fake.model()
        await model.run(.finderAndDock)
        #expect(fake.calls == ["killall Finder"])
        #expect(model.results[.finderAndDock] == .init(status: .failed(Self.date),
                                                        output: "No matching processes belonging to you were found"))
        #expect(fake.recorded.count == 1 && fake.recorded[0].0 == .finderAndDock && !fake.recorded[0].1)
    }

    /// Missing tool or timeout (nil outcome): failed, with a line naming the tool.
    @Test func aMissingToolFails() async {
        let fake = Fake()
        fake.outcomes["lsregister -gc"] = .some(nil)
        let model = fake.model()
        await model.run(.launchServices)
        #expect(fake.calls == ["lsregister -gc"])
        #expect(model.results[.launchServices]?.status == .failed(Self.date))
        #expect(model.results[.launchServices]?.output.contains("lsregister") == true)
    }

    /// One task at a time: Run on another task while one runs does nothing.
    @Test func onlyOneTaskRunsAtATime() async {
        let fake = Fake()
        let model = fake.model()
        let (gate, open) = AsyncStream.makeStream(of: Void.self)
        let base = model.runCommand
        model.runCommand = { command in
            if command.arguments == ["-gc"] { for await _ in gate { break } }
            return await base(command)
        }
        let first = Task { await model.run(.launchServices) }
        while model.running == nil { await Task.yield() }
        #expect(model.running == .launchServices)
        #expect(model.results[.launchServices]?.status == .running)
        await model.run(.quickLook)
        #expect(model.results[.quickLook] == nil)
        open.yield()
        await first.value
        #expect(fake.calls == ["lsregister -gc", "lsregister -r -f -apps local,system,user"])
        #expect(model.running == nil)
    }

    /// Under XCTest the default runner never starts a real tool.
    @Test func defaultRunnerRunsNothingInTests() async {
        let model = MaintenanceModel()
        let outcome = await model.runCommand(ShellCommand(executable: "/usr/bin/true"))
        #expect(outcome == nil)
    }

    /// `outcome()` keeps standard error and the exit result, unlike `output()`; a missing tool gives nil.
    @Test func outcomeKeepsErrorsAndExitCode() async {
        let failing = ShellCommand(executable: "/bin/sh", arguments: ["-c", "echo out; echo err >&2; exit 3"])
        #expect(await failing.outcome() == .init(succeeded: false, output: "out\nerr\n"))
        #expect(await failing.output() == nil)
        #expect(await ShellCommand(executable: "/bin/echo", arguments: ["hi"]).outcome() == .init(succeeded: true, output: "hi\n"))
        #expect(await ShellCommand(executable: "/no/such/tool").outcome() == nil)
    }

    /// Only the tasks restarting the Dock ask first; no task needs root (no sudo, no osascript with administrator privileges).
    @Test func tasksAreSafeToRun() {
        #expect(MaintenanceTask.allCases.filter(\.asksFirst) == [.finderAndDock, .iconCache])
        for task in MaintenanceTask.allCases {
            for command in task.commands {
                #expect(command.executable.hasPrefix("/"), "\(task) runs \(command.executable) from PATH")
                #expect(!["sudo", "osascript", "purge", "mdutil", "dscacheutil"].contains((command.executable as NSString).lastPathComponent))
            }
        }
        #expect(FileManager.default.isExecutableFile(atPath: MaintenanceTask.lsregister))
    }

    /// Activity lines of a task: "ran"/"failed" with no size; they never count as freed space.
    @Test func activityLinesDoNotCountAsFreed() throws {
        let home = TestTemp.url("CleanMateMaintenance")
        defer { try? FileManager.default.removeItem(at: home) }
        ActivityLog.recordTask(module: "Maintenance", item: ActivityLog.english(MaintenanceTask.quickLook.title), succeeded: true,
                               home: home, date: Self.date)
        ActivityLog.recordTask(module: "Maintenance", item: ActivityLog.english(MaintenanceTask.finderAndDock.title),
                               succeeded: false, home: home, date: Self.date)
        let lines = ActivityLog.read(home: home).split(separator: "\n")
        #expect(lines.map { ActivityLog.entry($0, locale: Locale(identifier: "en")).kind } == ["ran", "failed"])
        #expect(ActivityLog.entry(lines[0], locale: Locale(identifier: "en")).item == "Reset Quick Look")
        #expect(ActivityLog.entry(lines[0], locale: Locale(identifier: "vi")).module == "Bảo trì")
        let freed = ActivityLog.freed(home: home)
        #expect(freed.deleted == 0 && freed.trashed == 0 && freed.since == nil)
        #expect(ActivityLog.cleanups(now: Self.date, home: home) == ActivityLog.Cleanups())
        #expect(ActivitySettings.isTask("ran") && ActivitySettings.isTask("failed") && !ActivitySettings.isTask("deleted"))
        #expect(ActivitySettings.kindLabel("ran", locale: Locale(identifier: "en")).title == "Ran")
    }

    // MARK: Time Machine local snapshots

    /// Nothing is deleted until the user confirms: asking runs no command, cancelling forgets the request.
    @Test func snapshotDeletionNeedsConfirmation() async throws {
        let fake = Fake()
        let model = fake.model()
        await model.loadSnapshots()
        let list = try #require(model.snapshots?.list)
        await model.confirmDeletion() // nothing asked yet
        model.askToDelete(list)
        #expect(model.pendingDeletion == list)
        #expect(fake.calls.isEmpty)
        model.cancelDeletion()
        await model.confirmDeletion()
        #expect(model.pendingDeletion == nil && model.snapshotResult == nil)
        model.askToDelete([])
        #expect(model.pendingDeletion == nil)
        #expect(fake.calls.isEmpty && fake.recordedSnapshots.isEmpty)
    }

    /// Confirmed: `tmutil deletelocalsnapshots <date>` per snapshot, oldest first, one Activity line each, then the
    /// list is read again.
    @Test func confirmedDeletionRunsTmutilWithEachSnapshotDate() async {
        let fake = Fake()
        fake.lists = [Self.twoSnapshots, LocalSnapshots.parse("Snapshots for disk /:\n")]
        fake.outcomes["tmutil deletelocalsnapshots 2026-10-28-230501"] = .init(succeeded: true, output: "Deleted local snapshot '2026-10-28-230501'\n")
        let model = fake.model()
        await model.loadSnapshots()
        model.askToDelete(model.snapshots!.list)
        await model.confirmDeletion()
        #expect(fake.calls == ["tmutil deletelocalsnapshots 2026-10-28-230501", "tmutil deletelocalsnapshots 2026-10-30-101112"])
        #expect(fake.recordedSnapshots.map(\.0) == ["2026-10-28-230501", "2026-10-30-101112"])
        #expect(fake.recordedSnapshots.map(\.1) == [true, true])
        #expect(model.snapshotResult == .init(status: .succeeded(Self.date), output: "Deleted local snapshot '2026-10-28-230501'"))
        #expect(fake.reads == 2 && model.snapshots?.count == 0)
        #expect(model.pendingDeletion == nil && !model.busy)
    }

    /// One snapshot that can't be deleted (in use by a backup) doesn't stop the others; the result says failed.
    @Test func aFailedDeletionDoesNotStopTheOthers() async {
        let fake = Fake()
        fake.outcomes["tmutil deletelocalsnapshots 2026-10-28-230501"] = .init(succeeded: false, output: "Failed to delete local snapshot '2026-10-28-230501'\n")
        fake.outcomes["tmutil deletelocalsnapshots 2026-10-30-101112"] = .some(nil)
        let model = fake.model()
        await model.loadSnapshots()
        model.askToDelete(model.snapshots!.list)
        await model.confirmDeletion()
        #expect(fake.calls.count == 2)
        #expect(fake.recordedSnapshots.map(\.1) == [false, false])
        #expect(model.snapshotResult?.status == .failed(Self.date))
        #expect(model.snapshotResult?.output.contains("Failed to delete") == true)
        #expect(model.snapshotResult?.output.contains("tmutil") == true)
    }

    /// While snapshots are being deleted no task runs and nothing else can be asked, and the other way round.
    @Test func deletionAndTasksDoNotOverlap() async {
        let fake = Fake()
        let model = fake.model()
        await model.loadSnapshots()
        let list = model.snapshots!.list
        let (deleteGate, openDelete) = AsyncStream.makeStream(of: Void.self)
        let (taskGate, openTask) = AsyncStream.makeStream(of: Void.self)
        let base = model.runCommand
        model.runCommand = { command in
            if command.arguments.first == "deletelocalsnapshots" { for await _ in deleteGate { break } }
            if command.arguments == ["-gc"] { for await _ in taskGate { break } }
            return await base(command)
        }
        model.askToDelete([list[0]])
        let deletion = Task { await model.confirmDeletion() }
        while !model.deletingSnapshots { await Task.yield() }
        #expect(model.busy)
        await model.run(.quickLook)
        model.askToDelete([list[1]])
        #expect(model.results[.quickLook] == nil && model.pendingDeletion == nil)
        openDelete.yield()
        await deletion.value
        #expect(fake.calls == ["tmutil deletelocalsnapshots 2026-10-28-230501"])

        let task = Task { await model.run(.launchServices) }
        while model.running == nil { await Task.yield() }
        model.askToDelete(list)
        #expect(model.pendingDeletion == nil)
        openTask.yield()
        await task.value
    }

    /// Under XCTest the default list reads nothing, so `tmutil` never runs.
    @Test func defaultSnapshotReaderRunsNothingInTests() async {
        let model = MaintenanceModel()
        await model.loadSnapshots()
        #expect(model.snapshots == .unreadable)
    }

    /// The Activity line of a deletion: "ran"/"failed" with the snapshot date, shown in the app's language.
    @Test func snapshotActivityLine() throws {
        let home = TestTemp.url("CleanMateMaintenanceSnapshot")
        defer { try? FileManager.default.removeItem(at: home) }
        ActivityLog.recordTask(module: "Maintenance", item: ActivityLog.english("Delete local snapshot \("2026-10-28-230501")"),
                               succeeded: true, home: home, date: Self.date)
        let line = try #require(ActivityLog.read(home: home).split(separator: "\n").first)
        #expect(ActivityLog.entry(line, locale: Locale(identifier: "en")).item == "Delete local snapshot 2026-10-28-230501")
        #expect(ActivityLog.entry(line, locale: Locale(identifier: "vi")).item == "Xoá snapshot cục bộ 2026-10-28-230501")
        #expect(ActivityLog.entry(line, locale: Locale(identifier: "en")).kind == "ran")
    }
}
