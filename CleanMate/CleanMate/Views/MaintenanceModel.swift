import Foundation
import Combine

/// Maintenance: runs one `MaintenanceTask` at a time and keeps each task's last result for this session; lists
/// Time Machine's local snapshots and deletes them after the user confirms.
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
    /// Time Machine's local snapshots of the startup disk; nil until first read.
    @Published private(set) var snapshots: LocalSnapshots?
    /// The last deletion of local snapshots in this session.
    @Published private(set) var snapshotResult: Result?
    /// Snapshots waiting for the user's confirmation; nothing is deleted before `confirmDeletion()`.
    @Published private(set) var pendingDeletion: [LocalSnapshots.Snapshot]?

    /// Runs one command; nil = missing, timed out or cancelled. Tests inject a fake; under XCTest the default runs nothing.
    var runCommand: (ShellCommand) async -> ShellCommand.Outcome? = { command in
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil ? await command.outcome() : nil
    }

    /// Adds the Activity line of a finished task; injected by tests (never the real log).
    var record: (MaintenanceTask, Bool) -> Void = { task, succeeded in
        ActivityLog.recordTask(module: Module.maintenance.title, item: ActivityLog.english(task.title), succeeded: succeeded)
    }

    /// Like `runCommand`: under XCTest the default lists nothing, so no command runs.
    var readSnapshots: @Sendable () async -> LocalSnapshots = {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil ? await LocalSnapshots.read() : .unreadable
    }

    /// Adds the Activity line of one snapshot deletion; injected by tests (never the real log).
    var recordSnapshot: (LocalSnapshots.Snapshot, Bool) -> Void = { snapshot, succeeded in
        ActivityLog.recordTask(module: Module.maintenance.title,
                               item: ActivityLog.english("Delete local snapshot \(snapshot.stamp)"), succeeded: succeeded)
    }

    var now: () -> Date = { .now }

    /// The task now running; Run is disabled for every task until it ends.
    var running: MaintenanceTask? { results.first { $0.value.status == .running }?.key }

    /// Snapshots are being deleted.
    var deletingSnapshots: Bool { snapshotResult?.status == .running }

    /// A task runs or snapshots are being deleted: every Run and Delete button is disabled.
    var busy: Bool { running != nil || deletingSnapshots }

    /// Runs `task`'s commands in order, stopping at the first that fails, then records one Activity line.
    /// Ignored while another task runs or snapshots are being deleted.
    func run(_ task: MaintenanceTask) async {
        guard !busy else { return }
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

    /// Lists the local snapshots again (each time Maintenance is shown, and after a deletion).
    func loadSnapshots() async {
        snapshots = await readSnapshots()
    }

    /// Asks the user to confirm deleting `list`; ignored when empty or busy.
    func askToDelete(_ list: [LocalSnapshots.Snapshot]) {
        guard !list.isEmpty, !busy else { return }
        pendingDeletion = list
    }

    func cancelDeletion() {
        pendingDeletion = nil
    }

    /// Deletes the confirmed snapshots one by one with `tmutil deletelocalsnapshots <date>`, one Activity line each.
    /// A failure doesn't stop the others (one may be in use by a backup). Then lists the snapshots again.
    func confirmDeletion() async {
        guard let list = pendingDeletion, !busy else { return }
        pendingDeletion = nil
        snapshotResult = Result(status: .running)
        var output = "", failed = false
        for snapshot in list {
            let command = LocalSnapshots.deleteCommand(snapshot)
            let outcome = await runCommand(command)
            let succeeded = outcome?.succeeded == true
            output += outcome?.output ?? String(localized: "\((command.executable as NSString).lastPathComponent) is missing or took too long and was stopped.") + "\n"
            if !succeeded { failed = true }
            recordSnapshot(snapshot, succeeded)
        }
        let date = now()
        snapshotResult = Result(status: failed ? .failed(date) : .succeeded(date),
                                output: output.trimmingCharacters(in: .whitespacesAndNewlines))
        await loadSnapshots()
    }
}
