import Foundation
import Combine

/// Maintenance: runs one `MaintenanceTask` at a time and keeps each task's last result for this session.
final class MaintenanceModel: ObservableObject {
    enum Status: Equatable {
        case running
        case succeeded(Date)
        case failed(Date)
    }

    struct Result: Equatable {
        var status: Status
        /// What the tools printed, standard output and error together.
        var output = ""
    }

    @Published private(set) var results: [MaintenanceTask: Result] = [:]

    /// Runs one command; nil = missing, timed out or cancelled. Tests inject a fake; under XCTest the default runs nothing.
    var runCommand: (ShellCommand) async -> ShellCommand.Outcome? = { command in
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil ? await command.outcome() : nil
    }

    /// Adds the Activity line of a finished task; injected by tests (never the real log).
    var record: (MaintenanceTask, Bool) -> Void = { task, succeeded in
        ActivityLog.recordTask(module: Module.maintenance.title, item: ActivityLog.english(task.title), succeeded: succeeded)
    }

    var now: () -> Date = { .now }

    /// The task now running; Run is disabled for every task until it ends.
    var running: MaintenanceTask? { results.first { $0.value.status == .running }?.key }

    /// Runs `task`'s commands in order, stopping at the first that fails, then records one Activity line.
    /// Ignored while another task runs.
    func run(_ task: MaintenanceTask) async {
        guard running == nil else { return }
        results[task] = Result(status: .running)
        var output = "", succeeded = true
        for command in task.commands {
            guard let outcome = await runCommand(command) else {
                let tool = (command.executable as NSString).lastPathComponent
                output += String(localized: "\(tool) is missing or took too long and was stopped.") + "\n"
                succeeded = false
                break
            }
            output += outcome.output
            if !outcome.succeeded { succeeded = false; break }
        }
        let date = now()
        results[task] = Result(status: succeeded ? .succeeded(date) : .failed(date),
                               output: output.trimmingCharacters(in: .whitespacesAndNewlines))
        record(task, succeeded)
    }
}
