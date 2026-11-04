import SwiftUI
import Combine

/// The user's Trash as the done screens show it: how much it holds, and "Empty Trash…" (`EmptyTrash`, the same item
/// as Smart Scan's). One for the app: emptying it from one screen updates every other.
final class TrashBin: ObservableObject {
    static let shared = TrashBin()

    /// Entries and bytes in the Trash at the last read; nil before the first.
    @Published private(set) var contents: (count: Int, size: Int64)?
    /// Something was moved to or from the Trash since the last read (any activity log line): read again when shown.
    @Published private(set) var stale = true
    @Published private(set) var emptying = false
    /// What the last Empty Trash here deleted, and how many times it ran: a screen shows "freed" for one run after it
    /// appeared, never for an older one.
    @Published private(set) var lastEmptied: CleanReport?
    @Published private(set) var emptiedCount = 0

    /// Injected by tests so the real Trash is never read or emptied.
    var read: () async -> (count: Int, size: Int64) = { await EmptyTrash.contents() }
    var emptyTrash: () async -> CleanReport = { await EmptyTrash.empty() }

    private var observer: NSObjectProtocol?

    init(center: NotificationCenter = .default) {
        observer = center.addObserver(forName: ActivityLog.didRecord, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.markStale() }
        }
    }

    /// The Trash may hold something: true until a read says it is empty.
    var hasItems: Bool { stale || (contents?.count ?? 0) > 0 }

    private func markStale() {
        if !stale { stale = true }
    }

    /// Reads the Trash again when something moved since the last read.
    func refreshIfStale() async {
        guard stale, !emptying else { return }
        await refresh()
    }

    func refresh() async {
        stale = false
        let read = await read()
        if !emptying { contents = read }
    }

    /// Deletes everything in the Trash for good. The caller asked for confirmation first.
    func empty() async {
        guard !emptying else { return }
        emptying = true
        let report = await emptyTrash()
        lastEmptied = report
        emptiedCount += 1
        emptying = false
        announceForAccessibility(String(localized: "Trash emptied: \(report.freed.formatted(.byteCount(style: .file))) freed"))
        await refresh()
    }
}

/// "Empty Trash…" next to "Open Trash": shown while the Trash holds something, asks before deleting for good.
/// `confirm`: the caller shows the confirmation itself (`emptyTrashConfirmation`), e.g. from an alert's buttons.
struct EmptyTrashButton: View {
    @ObservedObject var bin = TrashBin.shared
    var confirm: (() -> Void)?
    @State private var confirming = false

    var body: some View {
        if bin.hasItems || bin.emptying {
            Button("Empty Trash…") { if let confirm { confirm() } else { confirming = true } }
                .disabled(bin.emptying)
                .help("Delete everything in the Trash for good to free the space. This can’t be undone.")
                .emptyTrashConfirmation(isPresented: $confirming, bin: bin)
                .task(id: bin.stale) { await bin.refreshIfStale() }
        }
    }
}

extension View {
    /// The confirmation of Empty Trash: everything in it goes for good, also what the user put there.
    func emptyTrashConfirmation(isPresented: Binding<Bool>, bin: TrashBin = .shared) -> some View {
        confirmationDialog(Text("Empty the Trash?"), isPresented: isPresented) {
            Button("Empty Trash", role: .destructive) { Task { await bin.empty() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let size = bin.contents?.size, size > 0, !bin.stale {
                Text("Everything in the Trash (\(size, format: .fileSize)) is deleted for good, also what you put there yourself. This can’t be undone.")
            } else {
                Text("Everything in the Trash is deleted for good, also what you put there yourself. This can’t be undone.")
            }
        }
    }
}

/// Under "Moved … to the Trash": the space is not free until the Trash is emptied, then what emptying it freed.
/// Says "freed" only for an Empty Trash run while this screen was up.
struct TrashSpaceSummary: View {
    @ObservedObject var bin = TrashBin.shared
    /// `bin.emptiedCount` when this screen appeared.
    @State private var seen = TrashBin.shared.emptiedCount

    var body: some View {
        Group {
            if bin.emptying {
                Text("Emptying the Trash…")
            } else if bin.emptiedCount > seen, let report = bin.lastEmptied {
                Text("Trash emptied: \(report.freed, format: .fileSize) freed")
            } else if let contents = bin.contents, contents.size > 0 {
                Text("\(contents.size, format: .fileSize) in the Trash, not freed until it is emptied")
            } else {
                Text("Empty the Trash to free the space.")
            }
        }
        .task(id: bin.stale) { await bin.refreshIfStale() }
    }
}

/// "Stopped: N items weren’t moved" after Stop during a move to the Trash.
struct StoppedTrashSummary: View {
    let report: CleanReport

    var body: some View {
        if report.stopped > 0 {
            Text("Stopped: \(report.stopped) items weren’t moved to the Trash.")
        }
    }
}

/// The progress of a move to the Trash with Stop (⌘.): the item under way finishes, the rest stay where they are.
struct TrashProgress: View {
    let stopping: Bool
    var compact = false
    let stop: () -> Void

    var body: some View {
        if compact {
            HStack {
                ProgressView(stopping ? "Stopping after this item…" : "Moving to Trash…").controlSize(.small)
                if !stopping { stopButton }
            }
        } else {
            VStack(spacing: 12) {
                ProgressView(stopping ? "Stopping after this item…" : "Moving to Trash…")
                if !stopping { stopButton }
            }
        }
    }

    private var stopButton: some View {
        Button("Stop") { stop() }
            .help("Finish the item being moved and leave the rest where they are.")
    }
}
