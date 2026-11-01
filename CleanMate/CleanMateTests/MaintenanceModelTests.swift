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
        var commands: [ShellCommand] = []
        var brew = MaintenanceTask.BrewState(installed: true, running: false)

        func model() -> MaintenanceModel {
            let model = MaintenanceModel()
            model.runCommand = { command, onOutput in
                let line = ([(command.executable as NSString).lastPathComponent] + command.arguments).joined(separator: " ")
                self.calls.append(line)
                self.commands.append(command)
                let outcome = self.outcomes[line] ?? ShellCommand.Outcome(succeeded: true, output: "")
                if let output = outcome?.output, !output.isEmpty { await onOutput(output) }
                return outcome
            }
            model.readBrew = { await MainActor.run { self.brew } }
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
        model.runCommand = { command, onOutput in
            if command.arguments == ["-gc"] { for await _ in gate { break } }
            return await base(command, onOutput)
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
        let outcome = await model.runCommand(ShellCommand(executable: "/usr/bin/true")) { _ in }
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
        #expect(ActivitySettings.removedNothing("ran") && ActivitySettings.removedNothing("failed")
                && ActivitySettings.removedNothing("skipped") && !ActivitySettings.removedNothing("deleted"))
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
        model.runCommand = { command, onOutput in
            if command.arguments.first == "deletelocalsnapshots" { for await _ in deleteGate { break } }
            if command.arguments == ["-gc"] { for await _ in taskGate { break } }
            return await base(command, onOutput)
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

    // MARK: Homebrew

    /// `brew update`, `brew upgrade --formula`, `brew cleanup --prune=all` in that order; no auto-update after the
    /// update, no hints, no ask prompt; 15 minutes for the three together.
    @Test func homebrewRunsItsThreeStepsInOrder() async {
        let fake = Fake()
        fake.outcomes["brew upgrade --formula"] = .init(succeeded: true, output: "==> Upgrading 1 outdated package:\nwget 1.24 -> 1.25\n")
        let model = fake.model()
        await model.run(.homebrew)
        #expect(fake.calls == ["brew update", "brew upgrade --formula", "brew cleanup --prune=all"])
        #expect(fake.commands.allSatisfy { $0.environment["HOMEBREW_NO_ENV_HINTS"] == "1" && $0.executable.hasPrefix("/") })
        #expect(fake.commands.map { $0.environment["HOMEBREW_NO_AUTO_UPDATE"] } == [nil, "1", "1"])
        #expect(fake.commands[1].environment["HOMEBREW_NO_ASK"] == "1")
        #expect(fake.commands.allSatisfy { $0.timeout <= .seconds(900) && $0.timeout > .seconds(890) })
        #expect(!fake.calls.contains { $0.contains("--cask") || $0.contains("sudo") })
        #expect(model.results[.homebrew]?.status == .succeeded(Self.date))
        #expect(model.results[.homebrew]?.output.hasPrefix("==> Upgrading 1 outdated package:\nwget 1.24 -> 1.25\n\n") == true)
        #expect(fake.recorded.count == 1 && fake.recorded[0].0 == .homebrew && fake.recorded[0].1)
        #expect(MaintenanceTask.homebrew.streamsOutput && !MaintenanceTask.quickLook.streamsOutput)
    }

    /// Without Homebrew the task is not listed and Run does nothing; while a `brew` command runs it is locked.
    @Test func homebrewIsHiddenWithoutBrewAndLockedWhileBrewRuns() async {
        let fake = Fake()
        fake.brew = .init(installed: false, running: false)
        let model = fake.model()
        await model.checkBrew()
        #expect(!model.brewInstalled && !model.tasks.contains(.homebrew) && model.tasks.count == MaintenanceTask.allCases.count - 1)
        await model.run(.homebrew)
        #expect(fake.calls.isEmpty && model.results[.homebrew] == nil)

        fake.brew = .init(installed: true, running: true)
        await model.checkBrew()
        #expect(model.tasks.last == .homebrew && model.brewRunning)
        await model.run(.homebrew)
        #expect(fake.calls.isEmpty && model.results[.homebrew] == nil && fake.recorded.isEmpty && !model.busy)

        fake.brew.running = false
        await model.checkBrew()
        #expect(!model.brewRunning)
        await model.run(.homebrew)
        #expect(fake.calls.count == 3)
    }

    /// Under XCTest the default reader finds no Homebrew, so no real brew can run.
    @Test func defaultBrewReaderFindsNothingInTests() async {
        let model = MaintenanceModel()
        #expect(!model.brewInstalled)
        await model.checkBrew()
        #expect(!model.brewInstalled && !model.tasks.contains(.homebrew))
    }

    /// The closing line's figures: brew's own count of upgraded packages, else one "Upgrading <name>" per formula;
    /// every "freed approximately" brew reports, in its decimal units.
    @Test func homebrewSummaryReadsBrewsOutput() {
        #expect(MaintenanceTask.homebrewSummary("Already up-to-date.\n") == .init(upgraded: 0, freed: 0))
        let summary = MaintenanceTask.homebrewSummary("""
            ==> Upgrading 3 outdated packages:
            a 1 -> 2
            ==> Upgrading a
            ==> Upgrading b
            Removing: /opt/homebrew/Cellar/a/1... (10 files, 2MB)
            ==> This operation has freed approximately 512.5MB of disk space.
            ==> This operation has freed approximately 1GB of disk space.
            """)
        #expect(summary == .init(upgraded: 3, freed: 1_512_500_000))
        #expect(MaintenanceTask.homebrewSummary("==> Upgrading git\n  2.40 -> 2.41\n==> Upgrading node\n==> Upgrading git\n") == .init(upgraded: 2, freed: 0))
    }

    /// Lines come out while the tool runs: the tool waits (up to 10 s) until the first lines have been handed over.
    @Test func streamedOutputArrivesWhileTheToolRuns() async throws {
        let folder = TestTemp.url("CleanMateMaintenanceStream")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let flag = folder.appending(path: "go").path
        let chunks = Chunks()
        let command = ShellCommand(executable: "/bin/sh", arguments: ["-c", """
            echo one; echo two; i=0; while [ ! -f "$0" ] && [ $i -lt 200 ]; do sleep 0.05; i=$((i+1)); done; echo three; printf four
            """, flag], timeout: .seconds(30))
        let outcome = await command.outcome { chunk in
            await chunks.add(chunk)
            if chunk.contains("two") { FileManager.default.createFile(atPath: flag, contents: nil) }
        }
        #expect(outcome == .init(succeeded: true, output: "one\ntwo\nthree\nfour"))
        let received = await chunks.list
        #expect(received.joined() == "one\ntwo\nthree\nfour")
        #expect(received.count >= 2 && received.first?.hasPrefix("one\n") == true && received.first?.contains("three") == false)
    }

    actor Chunks {
        var list: [String] = []
        var outputs: [String] = []
        func add(_ chunk: String, output: String? = nil) {
            list.append(chunk)
            if let output { outputs.append(output) }
        }
    }

    /// A stand-in `brew` that logs its arguments, environment and stdin, and prints like brew; `upgrade` pauses after
    /// its first lines until the runner has handed them over (`go`, at most 10 s); `fail-<step>` in its folder makes
    /// that step exit 1.
    final class FakeBrew {
        let folder = TestTemp.url("CleanMateMaintenanceBrew")
        var brew: String { folder.appending(path: "brew").path }
        var log: [String] {
            ((try? String(contentsOf: folder.appending(path: "calls.log"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        init() throws {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try """
                #!/bin/sh
                dir="$(dirname "$0")"
                if read -r line; then stdin=open; else stdin=closed; fi
                echo "$* auto=${HOMEBREW_NO_AUTO_UPDATE:-} hints=${HOMEBREW_NO_ENV_HINTS:-} stdin=$stdin" >> "$dir/calls.log"
                case "$1" in
                  update) echo "Already up-to-date." ;;
                  upgrade) echo "==> Upgrading 2 outdated packages:"; echo "git 2.40 -> 2.41"
                           i=0; while [ ! -f "$dir/go" ] && [ $i -lt 200 ]; do sleep 0.05; i=$((i+1)); done
                           echo "==> Upgrading git"; echo "==> Upgrading node" ;;
                  cleanup) echo "Removing: /opt/homebrew/Cellar/git/2.40 (1,234 files, 50MB)"
                           echo "==> This operation has freed approximately 1.5GB of disk space." ;;
                esac
                if [ -f "$dir/fail-$1" ]; then echo "Error: boom" >&2; exit 1; fi
                """.write(to: folder.appending(path: "brew"), atomically: true, encoding: .utf8)
            chmod(brew, 0o755)
        }

        deinit { try? FileManager.default.removeItem(at: folder) }

        /// The real runner, with `brew` swapped for this one; every chunk and the model's output after it go to `chunks`.
        func runner(_ model: MaintenanceModel, chunks: Chunks) -> (ShellCommand, @escaping @Sendable (String) async -> Void) async -> ShellCommand.Outcome? {
            let brew = brew, go = folder.appending(path: "go").path
            return { command, onOutput in
                var command = command
                command.executable = brew
                return await command.outcome { chunk in
                    await onOutput(chunk)
                    await chunks.add(chunk, output: await MainActor.run { model.results[.homebrew]?.output })
                    if chunk.contains("git 2.40 -> 2.41") { FileManager.default.createFile(atPath: go, contents: nil) }
                }
            }
        }
    }

    /// The real runner against a stand-in brew: the three steps in order with stdin closed and the variables set, the
    /// output shown while brew runs, and the closing line with brew's figures.
    @Test func homebrewWithAStandInBrew() async throws {
        let brew = try FakeBrew()
        let fake = Fake()
        let model = fake.model()
        let chunks = Chunks()
        model.runCommand = brew.runner(model, chunks: chunks)
        await model.run(.homebrew)
        #expect(brew.log == [
            "update auto= hints=1 stdin=closed",
            "upgrade --formula auto=1 hints=1 stdin=closed",
            "cleanup --prune=all auto=1 hints=1 stdin=closed",
        ])
        let received = await chunks.list, outputs = await chunks.outputs
        // brew's first lines arrive before it goes on.
        #expect(received.contains { $0.hasSuffix("git 2.40 -> 2.41\n") && !$0.contains("==> Upgrading git") })
        // Live: each chunk is in the shown output as soon as it is handed over.
        #expect(outputs.count == received.count && zip(outputs, received).allSatisfy { $0.hasSuffix($1) })
        let result = try #require(model.results[.homebrew])
        #expect(result.status == .succeeded(Self.date))
        #expect(result.output.hasPrefix("Already up-to-date.\n==> Upgrading 2 outdated packages:"))
        let closing = try #require(MaintenanceTask.homebrew.closingLine(output: result.output))
        #expect(result.output.hasSuffix("1.5GB of disk space.\n\n" + closing))
        #expect(closing.contains("2") && closing.contains(Int64(1_500_000_000).formatted(.fileSize)))
    }

    /// brew exiting non-zero: its error is in the result, the steps after it don't run, and there is no closing line.
    @Test func aFailingBrewStepStopsTheChain() async throws {
        let brew = try FakeBrew()
        FileManager.default.createFile(atPath: brew.folder.appending(path: "fail-upgrade").path, contents: nil)
        let fake = Fake()
        let model = fake.model()
        model.runCommand = brew.runner(model, chunks: Chunks())
        await model.run(.homebrew)
        #expect(brew.log.map { $0.split(separator: " ")[0] } == ["update", "upgrade"])
        let result = try #require(model.results[.homebrew])
        #expect(result.status == .failed(Self.date))
        #expect(result.output.hasSuffix("==> Upgrading node\nError: boom"))
        #expect(fake.recorded.count == 1 && !fake.recorded[0].1)
    }
}
