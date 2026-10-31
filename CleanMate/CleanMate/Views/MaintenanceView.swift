import SwiftUI

/// Maintenance: one row per task with what it does, a Run button, its status and the tools' output.
struct MaintenanceView: View {
    @ObservedObject var model: MaintenanceModel
    @State private var confirming: MaintenanceTask?

    var body: some View {
        Form {
            Section {
                ForEach(MaintenanceTask.allCases) { task in
                    MaintenanceRow(task: task, result: model.results[task], canRun: model.running == nil) {
                        if task.asksFirst { confirming = task } else { Task { await model.run(task) } }
                    }
                }
            } footer: {
                Text("These tasks need no administrator password and remove none of your files. Each run is recorded in Settings › Activity.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text(Module.maintenance.title))
        .focusedSceneValue(\.confirming, confirming != nil)
        .confirmationDialog(
            Text("Restart Finder and Dock?"),
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            presenting: confirming
        ) { task in
            Button("Restart") { Task { await model.run(task) } }
        } message: { _ in
            Text("Finder windows close and open again, and the Dock disappears for a moment. A copy in progress in Finder stops.")
        }
    }
}

private struct MaintenanceRow: View {
    let task: MaintenanceTask
    let result: MaintenanceModel.Result?
    let canRun: Bool
    let run: () -> Void
    @State private var showsOutput = false

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
                    status.font(.callout).padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Run", action: run).disabled(!canRun)
            }
            if let output = result?.output, !output.isEmpty, result?.status != .running {
                DisclosureGroup("Output", isExpanded: $showsOutput) {
                    Text(verbatim: output)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, 40)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var status: some View {
        switch result?.status {
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
