import Foundation
import Combine

/// Maintenance: runs one `MaintenanceTask` at a time and keeps each task's last result for this session; lists
/// Time Machine's local snapshots and deletes them after the user confirms.
final class MaintenanceModel: ObservableObject {
    enum Status: Equatable {
        case running
        case succeeded(Date)
        case failed(Date)
        /// The user stopped it (Stop, ⌘., Quit Anyway): its tool was ended and the steps after it never ran.
        case stopped(Date)
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

    /// The search field's text: filters the tasks and the snapshots section by their title and description.
    @Published var search = ""

    /// The tasks shown: Homebrew's only when it is installed, and only those matching `search`.
    var tasks: [MaintenanceTask] {
        MaintenanceTask.allCases.filter { ($0 != .homebrew || brewInstalled) && Self.matches($0, search) }
    }

    /// Overview › Suggestions asked for the local snapshots: the form scrolls to them once, then clears it.
    @Published var revealsSnapshots = false

    /// Overview › Suggestions: clears the search so the snapshots section shows, and scrolls to it.
    func revealSnapshots() {
        search = ""
        revealsSnapshots = true
    }

    /// The local snapshots section is shown: no search, or one that matches its title or description.
    var showsSnapshots: Bool { Self.matches(search, Self.snapshotsTitle, Self.snapshotsSummary) }

    /// Title and description of the local snapshots section, shared with the view.
    static let snapshotsTitle: LocalizedStringResource = "Time Machine local snapshots"
    static let snapshotsSummary: LocalizedStringResource = "Copies of your disk that Time Machine keeps on this Mac between backups. macOS deletes them by itself when it needs the space; deleting them now frees it at once. Backups on your Time Machine disk are not touched. Each deletion is recorded in Settings › Activity."

    /// `task` matches `search` (empty matches all): in its title or description, in the app's language or in English.
    nonisolated static func matches(_ task: MaintenanceTask, _ search: String) -> Bool {
        matches(search, task.title, task.summary)
    }

    nonisolated private static func matches(_ search: String, _ texts: LocalizedStringResource...) -> Bool {
        let search = search.trimmingCharacters(in: .whitespaces)
        guard !search.isEmpty else { return true }
        return texts.contains { text in
            String(localized: text).localizedStandardContains(search) || text.key.localizedStandardContains(search)
        }
    }

    /// The task now running; Run is disabled for every task until it ends.
    var running: MaintenanceTask? { results.first { $0.value.status == .running }?.key }

    /// Snapshots are being deleted.
    var deletingSnapshots: Bool { snapshotResult?.status == .running }

    /// A task runs or snapshots are being deleted: every Run and Delete button is disabled.
    var busy: Bool { running != nil || deletingSnapshots }

    /// The task started by `start`, which `stop` cancels.
    private var runTask: Task<Void, Never>?

    /// Runs `task` (see `run`) so that `stop()` can end it.
    func start(_ task: MaintenanceTask) {
        guard !busy else { return }
        runTask = Task { await run(task) }
    }

    /// Stop: ends the running task's tool and its children (SIGTERM, SIGKILL after `ShellCommand.termGrace`); the
    /// steps after it don't run. What the tool already did stays done.
    func stop() {
        guard running != nil else { return }
        runTask?.cancel()
    }

    /// `stop()`, then waits until the task has ended (before quitting: the tool would outlive CleanMate).
    func stopAndWait() async {
        stop()
        await runTask?.value
    }

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
        var output = "", succeeded = true, stopped = false
        for var command in task.commands {
            if Task.isCancelled { stopped = true; break }
            let tool = (command.executable as NSString).lastPathComponent
            if let deadline { command.timeout = min(command.timeout, deadline - .now) }
            let outcome = command.timeout > .zero
                ? await runCommand(command) { chunk in if task.streamsOutput { self.show(chunk, of: task) } }
                : nil
            if Task.isCancelled { // stopped by the user: the tool was ended; keep what it printed until then
                output = outcome.map { output + $0.output } ?? results[task]?.output ?? output
                stopped = true
                break
            }
            guard let outcome else {
                output += String(localized: "\(tool) is missing or took too long and was stopped.") + "\n"
                succeeded = false
                break
            }
            output += outcome.output
            results[task]?.output = output
            if !outcome.succeeded { succeeded = false; break }
        }
        if stopped { succeeded = false }
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if succeeded, let line = task.closingLine(output: output) { text += text.isEmpty ? line : "\n\n" + line }
        let date = now()
        results[task] = Result(status: stopped ? .stopped(date) : succeeded ? .succeeded(date) : .failed(date), output: text)
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
