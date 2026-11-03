import SwiftUI

/// "N items couldn’t be cleaned" on a done screen, with "Show Details…": what was left in place and why
/// (`CleanReport.failures`). Nothing when everything went.
struct NotCleanedSummary: View {
    let report: CleanReport
    @State private var showing = false

    var body: some View {
        if report.notCleaned > 0 {
            HStack(spacing: 6) {
                Text("\(report.notCleaned) items couldn’t be cleaned")
                if !report.failures.isEmpty {
                    Button("Show Details…") { showing = true }
                        .buttonStyle(.link)
                        .help("See each item left in place, why, and what to do about it.")
                }
            }
            .sheet(isPresented: $showing) { CleanFailuresSheet(failures: report.failures) }
        }
    }
}

/// The items a clean, move to the Trash or uninstall left in place, grouped by reason, each reason with what to do
/// (grant Full Disk Access, quit the app, try again).
struct CleanFailuresSheet: View {
    let failures: [CleanFailure]
    @Environment(\.dismiss) private var dismiss

    /// One reason and the items it kept, in the order first met.
    nonisolated struct Group: Identifiable, Sendable {
        let id: String
        let reason: CleanFailure.Reason
        var items: [CleanFailure]
    }

    nonisolated static func groups(_ failures: [CleanFailure]) -> [Group] {
        var groups: [Group] = []
        for failure in failures {
            let key = String(localized: failure.reason.text)
            if let index = groups.firstIndex(where: { $0.id == key }) {
                groups[index].items.append(failure)
            } else {
                groups.append(Group(id: key, reason: failure.reason, items: [failure]))
            }
        }
        return groups
    }

    var body: some View {
        let groups = Self.groups(failures)
        VStack(alignment: .leading, spacing: 12) {
            Text("Items Not Cleaned").font(.title2).bold()
            Text("CleanMate left these in place. Each reason says what to do; then clean again.")
                .foregroundStyle(.secondary)
            List {
                ForEach(groups) { group in
                    Section {
                        ForEach(Array(group.items.enumerated()), id: \.offset) { _, failure in
                            FailureRow(failure: failure)
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.reason.text).font(.headline).foregroundStyle(.primary)
                            HStack {
                                Text(group.reason.hint).foregroundStyle(.secondary)
                                if group.reason.needsFullDiskAccess {
                                    Button("Open Settings…") { FullDiskAccess.openSettings() }.buttonStyle(.link)
                                }
                            }
                        }
                        .textCase(nil)
                        .padding(.vertical, 4)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 560, idealWidth: 620, minHeight: 360, idealHeight: 460)
    }
}

/// One item left in place: its icon, name and path (Reveal in Finder), or the catalog item for a tool's whole step.
private struct FailureRow: View {
    let failure: CleanFailure

    var body: some View {
        HStack(spacing: 8) {
            if let url = failure.url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Text(verbatim: (url.path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .help(url.path)
                }
                Spacer()
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(.link)
                    .disabled(!FileManager.default.fileExists(atPath: url.path))
            } else {
                Image(systemName: "terminal").frame(width: 20, height: 20).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(failure.title ?? "Cleaning step").lineLimit(1)
                Spacer()
            }
        }
        .padding(.vertical, 2)
    }
}
