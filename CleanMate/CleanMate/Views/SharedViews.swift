import SwiftUI

// Small views used by more than one module.

/// "Open Trash" on done screens once something went to the Trash. Finder opens ~/.Trash, so CleanMate needs no Full Disk Access.
struct OpenTrashButton: View {
    var body: some View {
        Button("Open Trash") { NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash")) }
    }
}

/// "Open Trash" (once something went to the Trash) and "Undo" after a module's move to the Trash.
/// Undo puts back what that move moved; hidden once it ran (`report.undo`) or when nothing can be put back.
struct TrashReportButtons: View {
    let report: CleanReport
    let undo: () async -> Void

    var body: some View {
        if report.freed > 0 { OpenTrashButton() }
        if report.undo == nil && !report.trashed.isEmpty {
            Button("Undo") { Task { await undo() } }
                .help("Put the items just moved to the Trash back where they were.")
        }
    }
}

extension UndoManager {
    /// Edit › Undo <name> / ⌘Z for a move to the Trash, running the same undo as the "Undo" button.
    /// Replaces the target's earlier action; no redo. A focused text field (e.g. the search) undoes its own
    /// typing first: those groups are newer on the window's stack.
    func registerTrashUndo<T: AnyObject>(_ target: T, name: String, _ undo: @escaping @MainActor (T) async -> Void) {
        removeAllActions(withTarget: target)
        registerUndo(withTarget: target) { target in Task { await undo(target) } }
        setActionName(name)
    }
}

/// A model whose moves to the Trash get Edit › Undo / ⌘Z.
protocol TrashUndoing: AnyObject {
    var undoManager: UndoManager? { get set }
}

extension View {
    /// Hands the window's UndoManager to `model`; leaving the module drops its ⌘Z (no undo for a module not shown).
    func trashUndo(_ model: some TrashUndoing) -> some View { modifier(TrashUndoLink(model: model)) }
}

private struct TrashUndoLink<Model: TrashUndoing>: ViewModifier {
    let model: Model
    @Environment(\.undoManager) private var undoManager

    func body(content: Content) -> some View {
        content
            .onChange(of: undoManager, initial: true) { model.undoManager = undoManager }
            .onDisappear {
                undoManager?.removeAllActions(withTarget: model)
                // A move still running when the module is left must not register ⌘Z for a module not shown.
                model.undoManager = nil
            }
    }
}

/// How "Undo" went: items put back, and those left in the Trash.
struct UndoTrashResult: View {
    let result: TrashUndo.Result

    var body: some View {
        Text("Put back from the Trash: \(result.restored)")
        if result.skipped > 0 {
            Text("Left in the Trash (gone from it, something already in its place, or not permitted): \(result.skipped)")
        }
    }
}

/// Shown by Large & Old Files and Space Lens when folders in `ProtectedFolders` were not entered (no Full Disk Access).
struct ProtectedFoldersNote: View {
    var body: some View {
        HStack {
            Image(systemName: "lock.shield").foregroundStyle(.orange)
            Text("Some folders were skipped — grant Full Disk Access to scan everything.")
                .help("Without Full Disk Access, macOS asks before each of Desktop, Documents, Downloads, Movies, Music, Pictures, iCloud Drive and other apps' data, so CleanMate leaves them out.")
            Spacer()
            Button("Open Settings…") { FullDiskAccess.openSettings() }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// Name, "X available of Y" and a capacity bar tinted by `Volume.level` (Space Lens, Smart Scan idle screen).
struct VolumeGauge: View {
    let volume: SpaceLensModel.Volume

    var body: some View {
        Gauge(value: Double(volume.used), in: 0...Double(max(volume.total, 1))) {
            Label(volume.name, systemImage: "internaldrive")
        } currentValueLabel: {
            Text("\(volume.available, format: .fileSize) available of \(volume.total, format: .fileSize)")
                .monospacedDigit()
        }
        .gaugeStyle(.linearCapacity)
        .tint(volume.level == .critical ? Color.red : volume.level == .low ? Color.orange : Color.accentColor)
    }
}

/// Size column text in lists: body size, aligned digits, primary when the row is selected/ticked so the eye lands on it.
extension View {
    func sizeColumnStyle(emphasized: Bool) -> some View {
        font(.body).monospacedDigit().foregroundStyle(emphasized ? .primary : .secondary)
    }
}

extension View {
    /// One VoiceOver element with `label` for a row that has no control in it; nil leaves the children as they are.
    @ViewBuilder func accessibilityReadsAsOne(_ label: String?) -> some View {
        if let label { accessibilityElement(children: .ignore).accessibilityLabel(label) } else { self }
    }
}

/// Small bar beside a size: `size` as a share of `largest` (the largest item in view), same Capsule look as Space
/// Lens' share column. Decorative: VoiceOver reads the size text beside it instead.
struct SizeBar: View {
    let size: Int64
    let largest: Int64
    var tint: Color = .accentColor

    private var fraction: Double { largest > 0 ? Double(size) / Double(largest) : 0 }

    var body: some View {
        Capsule().fill(.quaternary)
            .overlay(alignment: .leading) {
                GeometryReader { bar in
                    Capsule().fill(tint).frame(width: bar.size.width * min(max(fraction, 0), 1))
                }
            }
            .frame(width: 48, height: 6)
            .accessibilityHidden(true)
    }
}

/// Icons looked up once per key (file extension, bundle id) for the app's lifetime, not on every redraw of a long list.
// shortcut: never evicted, so an app installed/removed later keeps its old answer until relaunch.
@MainActor enum IconCache {
    private static var images: [String: NSImage?] = [:]

    static func image(_ key: String, _ make: () -> NSImage?) -> NSImage? {
        if let cached = images[key] { return cached }
        let image = make()
        images[key] = image
        return image
    }
}

extension View {
    /// "Added to Exclusions": a short capsule at the bottom after "Never Clean This", also read by VoiceOver.
    /// Bump `count` to show it; it fades out by itself after 2 s.
    func exclusionNotice(_ count: Int) -> some View {
        overlay(alignment: .bottom) {
            ExclusionNotice(count: count)
        }
    }
}

private struct ExclusionNotice: View {
    let count: Int
    @State private var shown = false

    var body: some View {
        Group {
            if shown {
                Label("Added to Exclusions", systemImage: "checkmark.circle.fill")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 4)
                    .padding(.bottom, 56) // above the bottom bar's buttons
                    .transition(.opacity)
            }
        }
        .animation(.default, value: shown)
        .task(id: count) {
            guard count > 0 else { return }
            shown = true
            AccessibilityNotification.Announcement(String(localized: "Added to Exclusions")).post()
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { shown = false }
        }
    }
}
