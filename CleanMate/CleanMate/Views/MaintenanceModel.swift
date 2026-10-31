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

    /// Homebrew is installed: the Homebrew task is listed. Read again with `checkBrew()`.
    @Published private(set) var brewInstalled = !MaintenanceModel.isTesting && MaintenanceTask.brewPath != nil
    /// A `brew` command runs outside CleanMate: the Homebrew task can't run until it ends.
    @Published private(set) var brewRunning = false

    nonisolated private static var isTesting: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

    /// Runs one command, handing what it prints to the second argument as it comes (tasks with `streamsOutput`);
    /// nil = missing, timed out or cancelled. Tests inject a fake; under XCTest the default runs nothing.
    var runCommand: (ShellCommand, @escaping @Sendable (String) async -> Void) async -> ShellCommand.Outcome? = { command, onOutput in
        MaintenanceModel.isTesting ? nil : await command.outcome(onOutput: onOutput)
    }

    /// Like `runCommand`: under XCTest the default finds no Homebrew.
    var readBrew: @Sendable () async -> MaintenanceTask.BrewState = {
        MaintenanceModel.isTesting ? .init(installed: false, running: false) : await MaintenanceTask.brewState()
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

    /// The tasks shown: Homebrew's only when it is installed.
    var tasks: [MaintenanceTask] { MaintenanceTask.allCases.filter { $0 != .homebrew || brewInstalled } }

    /// The task now running; Run is disabled for every task until it ends.
    var running: MaintenanceTask? { results.first { $0.value.status == .running }?.key }

    /// Snapshots are being deleted.
    var deletingSnapshots: Bool { snapshotResult?.status == .running }

    /// A task runs or snapshots are being deleted: every Run and Delete button is disabled.
    var busy: Bool { running != nil || deletingSnapshots }

    /// Reads again whether Homebrew is installed and a `brew` command runs (not while the Homebrew task runs: its own
    /// brew would lock it).
    func checkBrew() async {
        guard running != .homebrew else { return }
        let state = await readBrew()
        guard running != .homebrew else { return }
        brewInstalled = state.installed
        brewRunning = state.running
    }

    /// Checks Homebrew every few seconds while Maintenance is shown, so the Homebrew row unlocks when brew ends.
    func watchBrew() async {
        while !Task.isCancelled {
            await checkBrew()
            try? await Task.sleep(for: .seconds(3))
        }
    }

    /// Runs `task`'s commands in order, stopping at the first that fails, then records one Activity line.
    /// Ignored while another task runs or snapshots are being deleted, and the Homebrew task while brew runs or
    /// when Homebrew is gone (checked again first). Tasks with `streamsOutput` show the output while it comes.
    func run(_ task: MaintenanceTask) async {
        guard !busy else { return }
        let previous = results[task]
        results[task] = Result(status: .running)
        if task == .homebrew {
            let state = await readBrew()
            brewInstalled = state.installed
            brewRunning = state.running
            guard state.installed, !state.running else { results[task] = previous; return }
        }
        let deadline = task.timeLimit.map { ContinuousClock.now + $0 }
        var output = "", succeeded = true
        for var command in task.commands {
            let tool = (command.executable as NSString).lastPathComponent
            if let deadline { command.timeout = min(command.timeout, deadline - .now) }
            let outcome = command.timeout > .zero
                ? await runCommand(command) { chunk in if task.streamsOutput { self.show(chunk, of: task) } }
                : nil
            guard let outcome else {
                output += String(localized: "\(tool) is missing or took too long and was stopped.") + "\n"
                succeeded = false
                break
            }
            output += outcome.output
            results[task]?.output = output
            if !outcome.succeeded { succeeded = false; break }
        }
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if succeeded, let line = task.closingLine(output: output) { text += text.isEmpty ? line : "\n\n" + line }
        let date = now()
        results[task] = Result(status: succeeded ? .succeeded(date) : .failed(date), output: text)
        record(task, succeeded)
    }

    /// Adds what a running task's tool just printed to its output.
    private func show(_ chunk: String, of task: MaintenanceTask) {
        guard results[task]?.status == .running else { return }
        results[task]?.output += chunk
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
            let outcome = await runCommand(command) { _ in }
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
