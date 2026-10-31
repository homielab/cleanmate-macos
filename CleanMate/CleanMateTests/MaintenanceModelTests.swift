import Foundation
import Testing
@testable import CleanMate

/// Maintenance with a fake command runner and activity recorder: no real tool runs, nothing is written to the real log.
@MainActor
struct MaintenanceModelTests {
    nonisolated static let date = Date(timeIntervalSince1970: 1_768_478_400)

    /// A model whose runner answers from `outcomes` (by executable + arguments) and remembers every call.
    @MainActor final class Fake {
        var calls: [String] = []
        var recorded: [(MaintenanceTask, Bool)] = []
        var outcomes: [String: ShellCommand.Outcome?] = [:]

        func model() -> MaintenanceModel {
            let model = MaintenanceModel()
            model.runCommand = { command in
                let line = ([(command.executable as NSString).lastPathComponent] + command.arguments).joined(separator: " ")
                self.calls.append(line)
                return self.outcomes[line] ?? ShellCommand.Outcome(succeeded: true, output: "")
            }
            model.record = { self.recorded.append(($0, $1)) }
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

    /// Only Restart Finder and Dock asks first; no task needs root (no sudo, no osascript with administrator privileges).
    @Test func tasksAreSafeToRun() {
        #expect(MaintenanceTask.allCases.filter(\.asksFirst) == [.finderAndDock])
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
}
