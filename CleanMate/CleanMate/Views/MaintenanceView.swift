import SwiftUI

/// Maintenance: one row per task with what it does, a Run button, its status and the tools' output; then Time Machine's
/// local snapshots, each with a Delete button.
struct MaintenanceView: View {
    @ObservedObject var model: MaintenanceModel
    @State private var confirming: MaintenanceTask?

    var body: some View {
        Form {
            Section {
                ForEach(model.tasks) { task in
                    let brewBusy = task == .homebrew && model.brewRunning && model.running != .homebrew
                    MaintenanceRow(task: task, result: model.results[task], canRun: !model.busy && !brewBusy,
                                   note: brewBusy ? Text("Homebrew is already running. This can run when it finishes.") : nil) {
                        if task.asksFirst { confirming = task } else { Task { await model.run(task) } }
                    }
                }
            } footer: {
                Text("These tasks need no administrator password and remove none of your files. Each run is recorded in Settings › Activity.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LocalSnapshotsSection(model: model)
        }
        .formStyle(.grouped)
        .navigationTitle(Text(Module.maintenance.title))
        .task { await model.loadSnapshots() }
        .task { await model.watchBrew() }
        .focusedSceneValue(\.confirming, confirming != nil || model.pendingDeletion != nil)
        .confirmationDialog(
            Text(confirming == .iconCache ? LocalizedStringKey("Clear the icon cache and restart the Dock?") : "Restart Finder and Dock?"),
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            presenting: confirming
        ) { task in
            Button("Restart") { Task { await model.run(task) } }
        } message: { task in
            if task == .iconCache {
                Text("The Dock disappears for a moment. Icons may look blank briefly while macOS draws them again.")
            } else {
                Text("Finder windows close and open again, and the Dock disappears for a moment. A copy in progress in Finder stops.")
            }
        }
    }
}

private struct MaintenanceRow: View {
    let task: MaintenanceTask
    let result: MaintenanceModel.Result?
    let canRun: Bool
    /// Why Run is off (brew already running).
    var note: Text?
    let run: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: task.systemImage)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title).font(.headline)
                    Text(task.summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let note {
                        Label { note } icon: { Image(systemName: "lock.fill") }
                            .font(.callout).foregroundStyle(.secondary).padding(.top, 2)
                    }
                    MaintenanceStatus(status: result?.status).font(.callout).padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Run", action: run).disabled(!canRun)
            }
            MaintenanceOutput(result: result, live: task.streamsOutput).padding(.leading, 40)
        }
        .padding(.vertical, 4)
    }
}

/// Running, done at or failed at.
private struct MaintenanceStatus: View {
    let status: MaintenanceModel.Status?

    var body: some View {
        switch status {
        case .running?:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Running…").foregroundStyle(.secondary)
            }
        case .succeeded(let date)?:
            Label { Text("Done at \(date, format: .dateTime.hour().minute())") } icon: { Image(systemName: "checkmark.circle.fill") }
                .foregroundStyle(.green)
        case .failed(let date)?:
            Label { Text("Failed at \(date, format: .dateTime.hour().minute())") } icon: { Image(systemName: "xmark.octagon.fill") }
                .foregroundStyle(.red)
        case nil:
            EmptyView()
        }
    }
}

/// What the tools printed, folded; nothing when they printed nothing. `live`: shown while the task runs, unfolded
/// and kept scrolled to the end in a box of fixed height; otherwise only once it ends.
private struct MaintenanceOutput: View {
    let result: MaintenanceModel.Result?
    var live = false
    @State private var showsOutput = false

    var body: some View {
        let running = result?.status == .running
        if let output = result?.output, !output.isEmpty, live || !running {
            DisclosureGroup("Output", isExpanded: $showsOutput) {
                if live {
                    ScrollViewReader { proxy in
                        ScrollView {
                            text(output).id("end")
                        }
                        .frame(height: 180)
                        .onChange(of: output) { _ in proxy.scrollTo("end", anchor: .bottom) }
                    }
                } else {
                    text(output)
                }
            }
            .onAppearAndChange(of: running) { if $0 && live { showsOutput = true } }
        }
    }

    private func text(_ output: String) -> some View {
        Text(verbatim: output)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Time Machine's local snapshots of the startup disk: one row per snapshot with Delete, and Delete All. Both ask first.
private struct LocalSnapshotsSection: View {
    @ObservedObject var model: MaintenanceModel

    var body: some View {
        Section {
            summary
            if let list = model.snapshots?.list {
                ForEach(list) { snapshot in
                    HStack(spacing: 12) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.secondary)
                            .frame(width: 28)
                            .accessibilityHidden(true)
                        Text(snapshot.date, format: .dateTime.day().month().year().hour().minute())
                        Spacer()
                        Button("Delete…") { model.askToDelete([snapshot]) }
                            .controlSize(.small)
                            .disabled(model.busy)
                    }
                }
            }
        } footer: {
            Text("Copies of your disk that Time Machine keeps on this Mac between backups. macOS deletes them by itself when it needs the space; deleting them now frees it at once. Backups on your Time Machine disk are not touched. Each deletion is recorded in Settings › Activity.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog(
            title,
            isPresented: Binding(get: { model.pendingDeletion != nil }, set: { if !$0 { model.cancelDeletion() } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { Task { await model.confirmDeletion() } }
        } message: {
            Text("These are backup copies Time Machine keeps on this Mac. Deleting them can’t be undone. Backups on your Time Machine disk are not affected.")
        }
    }

    private var title: Text {
        let pending = model.pendingDeletion ?? []
        if pending.count == 1, let snapshot = pending.first {
            return Text("Delete the local snapshot of \(snapshot.date, format: .dateTime.day().month().year().hour().minute())?")
        }
        return Text("Delete all \(pending.count) local snapshots?")
    }

    /// Count, status of the last deletion and Delete All.
    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "externaldrive.badge.timemachine")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Time Machine local snapshots").font(.headline)
                    count.foregroundStyle(.secondary)
                    MaintenanceStatus(status: model.snapshotResult?.status).font(.callout).padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let list = model.snapshots?.list, list.count > 1 {
                    Button("Delete All…") { model.askToDelete(list) }.disabled(model.busy)
                }
            }
            MaintenanceOutput(result: model.snapshotResult).padding(.leading, 40)
        }
        .padding(.vertical, 4)
    }

    private var count: Text {
        switch model.snapshots {
        case nil: Text("Checking…")
        case let list? where !list.readable: Text("Couldn’t list them.")
        case let list? where list.count == 0: Text("None on this Mac.")
        case let list?: Text("\(list.count) snapshots")
        }
    }
}
