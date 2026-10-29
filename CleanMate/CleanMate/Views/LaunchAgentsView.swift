import SwiftUI

extension LaunchAgent.State {
    var title: LocalizedStringResource {
        switch self {
        case .running: "Running"
        case .loaded: "Loaded"
        case .notLoaded: "Not Loaded"
        case .disabled: "Disabled"
        case .unknown: "—"
        }
    }
}

/// Login Items: the user's launch agents (disable, enable, remove) plus read-only agents and daemons in /Library.
struct LaunchAgentsView: View {
    @ObservedObject var model: LaunchAgentsModel
    @State private var selection: URL?
    @State private var removing: LaunchAgent?

    private var selected: LaunchAgent? { model.agents.first { $0.url == selection } }

    var body: some View {
        VStack(spacing: 0) {
            loginItemsNote
            Divider()
            Table(of: LaunchAgent.self, selection: $selection) {
                TableColumn("Name") { agent in
                    Label {
                        Text(agent.label).lineLimit(1).truncationMode(.middle).help(agent.url.path)
                    } icon: {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: agent.owner?.path ?? agent.url.path))
                            .resizable()
                            .frame(width: 20, height: 20)
                            .accessibilityHidden(true)
                    }
                    .padding(.vertical, 3)
                }
                .width(min: 180, ideal: 230)
                TableColumn("App") { agent in
                    Text(agent.owner.map { FileManager.default.displayName(atPath: $0.path) } ?? "—")
                        .foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 120)
                TableColumn("Status") { agent in
                    HStack(spacing: 4) {
                        Text(agent.state.title)
                        if agent.programMissing {
                            Text("Program Missing")
                                .font(.subheadline)
                                .padding(.horizontal, 4)
                                .background(.orange.opacity(0.2), in: .capsule)
                        }
                    }
                }
                .width(min: 80, ideal: 180) // room for "Chưa nạp" + "Thiếu chương trình"
                TableColumn("Program") { agent in
                    Text(agent.program ?? "—").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).help(agent.program ?? "")
                }
            } rows: {
                // No section headers over the "No Launch Agents Found" overlay.
                if !model.agents.isEmpty {
                    Section {
                        ForEach(model.agents(.user)) { TableRow($0) }
                    } header: {
                        Text("Your Launch Agents")
                    }
                    Section {
                        ForEach(model.agents(.systemAgent) + model.agents(.systemDaemon)) { TableRow($0) }
                    } header: {
                        Text("System Agents & Daemons — require administrator, manage in System Settings")
                    }
                }
            }
            .contextMenu(forSelectionType: URL.self) { urls in
                if let agent = model.agents.first(where: { urls.contains($0.url) }) {
                    actions(agent).disabled(model.working)
                    Divider()
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([agent.url]) }
                }
            } primaryAction: { urls in
                NSWorkspace.shared.activateFileViewerSelecting(Array(urls))
            }
            .overlay {
                if model.agents.isEmpty {
                    if model.loading {
                        ProgressView().accessibilityLabel("Loading…")
                    } else {
                        ContentUnavailableView("No Launch Agents Found", systemImage: "gearshape.2",
                                               description: Text("Nothing in ~/Library/LaunchAgents or in /Library starts at login."))
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("Disabled agents stay off after you log in again; removed ones go to the Trash.")
                    .foregroundStyle(.secondary)
                Spacer()
                if let agent = selected, agent.isUser { actions(agent) }
                Button("Refresh") { Task { await model.load() } }
            }
            .disabled(model.working)
            .padding()
            .background(.bar)
        }
        .navigationTitle(Text(Module.loginItems.title))
        .task { await model.loadIfNeeded() }
        .focusedSceneValue(\.confirming, removing != nil)
        .confirmationDialog(
            Text("Remove “\(removing?.label ?? "")”?"),
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { agent in
            Button("Move to Trash", role: .destructive) { Task { await model.remove(agent) } }
        } message: { _ in
            Text("The agent is stopped and its file is moved to the Trash. To restore it, put the file back and log in again.")
        }
        .alert(
            Text("Couldn’t change “\(model.failed?.label ?? "")”"),
            isPresented: Binding(get: { model.failed != nil }, set: { if !$0 { model.failed = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text("launchctl refused the change, or the agent’s file couldn’t be changed or moved to the Trash (it may be locked or not yours). Click Refresh to see its current state, or manage it in System Settings › General › Login Items & Extensions.")
        }
    }

    @ViewBuilder private func actions(_ agent: LaunchAgent) -> some View {
        if agent.isUser {
            if agent.state == .disabled || agent.state == .notLoaded {
                Button("Enable") { Task { await model.enable(agent) } }
            } else {
                Button("Disable") { Task { await model.disable(agent) } }
            }
            Button("Remove…") { removing = agent }
        }
    }

    private var loginItemsNote: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Login Items & Background Items").font(.headline)
                Text("Apps that open at login and items allowed in the background are managed by macOS. Turn them off in System Settings › General › Login Items & Extensions.")
                    .foregroundStyle(.secondary)
            }
            // Fills the row so the text wraps; `.fixedSize(vertical:)` + `Spacer` here blew the window layout up.
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Open Login Items Settings") { LaunchAgentsModel.openLoginItemsSettings() }
        }
        .padding()
    }
}
