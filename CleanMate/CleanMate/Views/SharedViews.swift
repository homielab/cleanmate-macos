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
            .onAppearAndChange(of: undoManager) { model.undoManager = $0 }
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

/// Large checkbox for lists where the tick decides what gets cleaned: a 20 pt square, accent-filled when on or mixed
/// (`Toggle(sources:)`), faded when disabled; a click on the label ticks too. `lockReason`: a lock badge on the box,
/// with the reason as its tooltip, for a row that cannot be ticked. VoiceOver sees a native checkbox.
struct SelectionCheckboxStyle: ToggleStyle {
    var lockReason: Text? = nil

    func makeBody(configuration: Configuration) -> some View {
        SelectionCheckbox(configuration: configuration, lockReason: lockReason)
    }

    /// The SF Symbol for each state.
    static func symbol(isOn: Bool, isMixed: Bool) -> String {
        isMixed ? "minus.square.fill" : isOn ? "checkmark.square.fill" : "square"
    }
}

private struct SelectionCheckbox: View {
    let configuration: ToggleStyleConfiguration
    let lockReason: Text?
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        // Like a native checkbox, a click on mixed ticks everything.
        Button { configuration.isOn = configuration.isMixed || !configuration.isOn } label: {
            HStack(spacing: 8) {
                box
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(lockReason ?? Text(verbatim: ""))
        .accessibilityRepresentation {
            // Mixed shows as mixed: two sources that disagree.
            let on = Binding { configuration.isOn } set: { configuration.isOn = $0 }
            let sources = configuration.isMixed
                ? [Binding { true } set: { on.wrappedValue = $0 }, Binding { false } set: { on.wrappedValue = $0 }]
                : [on]
            Toggle(sources: sources, isOn: \.self) { configuration.label }
                .toggleStyle(.checkbox)
        }
    }

    private var box: some View {
        let ticked = configuration.isOn || configuration.isMixed
        return Image(systemName: SelectionCheckboxStyle.symbol(isOn: configuration.isOn, isMixed: configuration.isMixed))
            .resizable()
            .scaledToFit()
            .symbolRenderingMode(.palette)
            .foregroundStyle(ticked ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary),
                             ticked ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            .frame(width: 20, height: 20)
            .opacity(isEnabled ? 1 : 0.4)
            .overlay(alignment: .bottomTrailing) {
                if lockReason != nil {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.orange)
                        .padding(2)
                        .background(Color(nsColor: .windowBackgroundColor), in: Circle())
                        .offset(x: 5, y: 5)
                }
            }
            .frame(width: 22, height: 22)
    }
}

extension View {
    /// A list row ticked by a click anywhere on it — its buttons, links and selectable text keep their own clicks —
    /// and tinted while ticked. VoiceOver keeps using the row's own checkbox, so the row is not read twice.
    /// `toggle` nil: a row without a checkbox, only padded like the others. `highlight`: run on every click, locked
    /// rows too — the tap takes the click from the List, so the row must take the List's highlight (Space) itself.
    @ViewBuilder func selectionRow(isOn: Bool, enabled: Bool = true, highlight: (() -> Void)? = nil,
                                   toggle: (() -> Void)?) -> some View {
        let padded = padding(.horizontal, 6)
        if let toggle {
            padded
                .background(isOn && enabled ? Color.accentColor.opacity(0.08) : .clear, in: .rect(cornerRadius: 6))
                .contentShape(Rectangle())
                .onTapGesture {
                    highlight?()
                    if enabled { toggle() }
                }
        } else {
            padded
        }
    }
}

/// Small bar beside a size: `size` as a share of `largest` (the largest item in view), same Capsule look as Space
/// Lens' share column. Decorative: VoiceOver reads the size text beside it instead.
struct SizeBar: View {
    let size: Int64
    let largest: Int64
    var tint: Color = .accentColor
    var height: CGFloat = 6
    var width: CGFloat = 48

    private var fraction: Double { largest > 0 ? Double(size) / Double(largest) : 0 }

    var body: some View {
        Capsule().fill(.quaternary)
            .overlay(alignment: .leading) {
                GeometryReader { bar in
                    Capsule().fill(tint).frame(width: bar.size.width * min(max(fraction, 0), 1))
                }
            }
            .frame(width: width, height: height)
            .accessibilityHidden(true)
    }
}

/// Fades in and rises 6 pt when `shown` turns true, `order` × 60 ms after the first one (capped, so a long list
/// is in within a second). With Reduce Motion, rising motion and delays are suppressed: it only fades in.
private struct RevealModifier: ViewModifier {
    let shown: Bool
    let order: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: (shown || reduceMotion) ? 0 : 6)
            .animation(
                reduceMotion
                    ? .easeOut(duration: 0.2)
                    : .easeOut(duration: 0.3).delay(0.1 + Double(min(order, 8)) * 0.06),
                value: shown
            )
    }
}

extension View {
    /// Fades in and rises 6 pt when `shown` turns true, `order` × 60 ms after the first one (capped, so a long list
    /// is in within a second). Other changes `shown` brings (a `SizeBar` growing) run on the same curve.
    /// With Reduce Motion it only fades in without rising motion.
    func reveal(_ shown: Bool, order: Int) -> some View {
        modifier(RevealModifier(shown: shown, order: order))
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
            announceForAccessibility(String(localized: "Added to Exclusions"))
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { shown = false }
        }
    }
}

/// Empty, idle and done screens: large icon, title, description and actions, centered, like the system's
/// empty-state view (macOS 14+). The icon and title can be any view (the done screens' animated ones).
struct EmptyStateView<Icon: View, Title: View, Description: View, Actions: View>: View {
    let icon: Icon
    let title: Title
    let description: Description
    let actions: Actions

    init(@ViewBuilder icon: () -> Icon, @ViewBuilder title: () -> Title, @ViewBuilder description: () -> Description,
         @ViewBuilder actions: () -> Actions) {
        self.icon = icon()
        self.title = title()
        self.description = description()
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 7) {
                icon
                    .font(.system(size: 34))
                    .padding(.bottom, 18)
                    .accessibilityHidden(true)
                title
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                VStack(spacing: 19) { description }
                    .font(.title3)
                    .lineSpacing(3)
                    .frame(maxWidth: 360)
            }
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            HStack(spacing: 8) { actions }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyStateView where Icon == Image, Title == Text {
    init(title: Text, systemImage: String, @ViewBuilder description: () -> Description,
         @ViewBuilder actions: () -> Actions) {
        self.init(icon: { Image(systemName: systemImage) }, title: { title }, description: description,
                  actions: actions)
    }
}

extension EmptyStateView where Icon == Image, Title == Text, Actions == EmptyView {
    init(title: Text, systemImage: String, @ViewBuilder description: () -> Description) {
        self.init(title: title, systemImage: systemImage, description: description) { EmptyView() }
    }
}

extension EmptyStateView where Icon == Image, Title == Text, Description == EmptyView, Actions == EmptyView {
    init(title: Text, systemImage: String) {
        self.init(title: title, systemImage: systemImage) { EmptyView() }
    }
}

/// A byte count in `.fileSize`, with aligned digits. `countsUp`: counts from 0 to `value` once when it appears
/// (ease-out, `duration`), in `value`'s unit all the way so the unit never jumps; not with Reduce Motion. A later
/// change of `value` (a refresh) rolls the digits instead. `label` wraps the number, e.g. `Text("Freed \($0)")`.
/// The last frame is exactly `label(Text(value, format: .fileSize))`.
struct CountingBytes: View {
    let value: Int64
    private let countsUp: Bool
    private let duration: Double
    private let label: (Text) -> Text
    var onCountingChange: ((Bool) -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Double
    @State private var counting: Bool

    init(_ value: Int64, countsUp: Bool, duration: Double = 0.8, label: @escaping (Text) -> Text = { $0 }) {
        self.init(value, countsUp: countsUp, duration: duration, onCountingChange: nil, label: label)
    }

    init(_ value: Int64, countsUp: Bool, duration: Double = 0.8, onCountingChange: ((Bool) -> Void)?, label: @escaping (Text) -> Text = { $0 }) {
        self.value = value
        self.countsUp = countsUp
        self.duration = duration
        self.onCountingChange = onCountingChange
        self.label = label
        let counts = countsUp && value > 0
        _shown = State(initialValue: counts ? 0 : Double(value))
        _counting = State(initialValue: counts)
    }

    var isCounting: Bool {
        counting && !reduceMotion
    }

    var body: some View {
        Group {
            if isCounting {
                Text(verbatim: "").modifier(CountUp(shown: shown, target: value, label: label))
            } else {
                label(Text(value, format: .fileSize)).contentTransition(.numericText())
            }
        }
        .monospacedDigit()
        .animation(reduceMotion ? nil : .default, value: value)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label(Text(value, format: .fileSize)))
        .task(id: reduceMotion) {
            if reduceMotion {
                shown = Double(value)
                counting = false
                return
            }
            guard counting else { return }
            withAnimation(.easeOut(duration: duration)) { shown = Double(value) }
            try? await Task.sleep(for: .seconds(duration))
            counting = false // same text as the last frame: nothing moves
        }
        .onChange(of: reduceMotion) { isReduce in
            if isReduce {
                shown = Double(value)
                counting = false
            }
        }
        .background(
            Color.clear
                .onAppear { onCountingChange?(isCounting) }
                .onChange(of: isCounting) { onCountingChange?($0) }
        )
    }

    /// The text at `shown` bytes on the way to `target`: in `target`'s unit, then `target` in `.fileSize` once there.
    nonisolated static func text(_ shown: Double, target: Int64, locale: Locale) -> String {
        if shown >= Double(target) { return target.formatted(.fileSize.locale(locale)) }
        return Int64(max(shown, 0)).formatted(
            .byteCount(style: .file, allowedUnits: unit(of: target), spellsOutZero: false).locale(locale))
    }

    /// The unit `.fileSize` writes `bytes` in (decimal, like Finder).
    nonisolated static func unit(of bytes: Int64) -> ByteCountFormatStyle.Units {
        switch bytes {
        case ..<1_000: .bytes
        case ..<1_000_000: .kb
        case ..<1_000_000_000: .mb
        case ..<1_000_000_000_000: .gb
        default: .tb
        }
    }
}

/// Draws `content(grown)` with `grown` false on its first frame and true right after, animated (ease-out,
/// `duration`): bars and charts grow from 0. Only when `animates`; with Reduce Motion `grown` is true from the start
/// and the content fades in instead.
struct GrowsIn<Content: View>: View {
    private let animates: Bool
    private let duration: Double
    private let content: (Bool) -> Content
    var onGrownChange: ((Bool) -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var grown: Bool
    @State private var visible: Bool

    init(animates: Bool, duration: Double = 0.6, @ViewBuilder content: @escaping (Bool) -> Content) {
        self.init(animates: animates, duration: duration, onGrownChange: nil, content: content)
    }

    init(animates: Bool, duration: Double = 0.6, onGrownChange: ((Bool) -> Void)?, @ViewBuilder content: @escaping (Bool) -> Content) {
        self.animates = animates
        self.duration = duration
        self.onGrownChange = onGrownChange
        self.content = content
        _grown = State(initialValue: !animates)
        _visible = State(initialValue: !animates)
    }

    var isGrown: Bool {
        grown || reduceMotion || !animates
    }

    var body: some View {
        content(isGrown)
            .opacity(visible ? 1 : 0)
            .onAppear {
                if reduceMotion || !animates {
                    grown = true
                    withAnimation(animates ? .easeOut(duration: duration) : nil) {
                        visible = true
                    }
                    return
                }
                guard !grown || !visible else { return }
                withAnimation(.easeOut(duration: duration)) {
                    grown = true
                    visible = true
                }
            }
            .onChange(of: reduceMotion) { isReduce in
                if isReduce {
                    withAnimation(nil) {
                        grown = true
                        visible = true
                    }
                }
            }
            .background(
                Color.clear
                    .onAppear { onGrownChange?(isGrown) }
                    .onChange(of: isGrown) { onGrownChange?($0) }
            )
    }
}

/// Redraws the number on every animation frame of `shown`.
private struct CountUp: ViewModifier, Animatable {
    var shown: Double
    let target: Int64
    let label: (Text) -> Text
    @Environment(\.locale) private var locale

    var animatableData: Double {
        get { shown }
        set { shown = newValue }
    }

    func body(content: Content) -> some View {
        label(Text(verbatim: CountingBytes.text(shown, target: target, locale: locale)))
    }
}

/// Opens CleanMate's Settings window, on `tab` (a `SettingsView` tag) when given: SwiftUI's environment action on
/// macOS 14+, where AppKit's `showSettingsWindow:` only logs a warning; that AppKit action on macOS 13, which has no
/// environment action.
struct OpenSettingsButton<Label: View>: View {
    private let tab: String?
    private let label: Label

    init(tab: String? = nil, @ViewBuilder label: () -> Label) {
        self.tab = tab
        self.label = label()
    }

    var body: some View {
        if #available(macOS 14, *) {
            OpenSettingsEnvironmentButton(tab: tab, label: label)
        } else {
            Button {
                Self.select(tab)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: { label }
        }
    }

    fileprivate static func select(_ tab: String?) {
        if let tab { UserDefaults.standard.set(tab, forKey: Preferences.settingsTab) }
    }
}

extension OpenSettingsButton where Label == Text {
    /// "Open Settings…".
    init(tab: String? = nil) {
        self.init(tab: tab) { Text("Open Settings…") }
    }
}

@available(macOS 14, *)
private struct OpenSettingsEnvironmentButton<Label: View>: View {
    let tab: String?
    let label: Label
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
            OpenSettingsButton<Label>.select(tab)
            openSettings()
        } label: { label }
    }
}

/// VoiceOver announcement (SwiftUI's `AccessibilityNotification` needs macOS 14).
@MainActor func announceForAccessibility(_ text: String) {
    NSAccessibility.post(element: NSApp.keyWindow ?? NSApp as Any, notification: .announcementRequested,
                         userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
}

extension View {
    /// Runs `action` when the view appears and whenever `value` changes (`onChange(of:initial: true)` needs macOS 14).
    func onAppearAndChange<V: Equatable>(of value: V, perform action: @escaping (V) -> Void) -> some View {
        onAppear { action(value) }.onChange(of: value, perform: action)
    }

    /// Space on this list or table while it has the keyboard focus and no confirmation is shown; `action` returns
    /// false to let the key through. An AppKit key monitor, installed while the view is in a window: SwiftUI's
    /// key-press modifier needs macOS 14.
    func onSpaceKey(_ action: @escaping () -> Bool) -> some View {
        modifier(SpaceKeyModifier(action: action))
    }
}

private struct SpaceKeyModifier: ViewModifier {
    let action: () -> Bool
    @FocusedValue(\.confirming) private var confirming

    func body(content: Content) -> some View {
        content.background(SpaceKeyMonitor(action: action, blocked: confirming == true))
    }
}

/// An empty view behind the list; its frame tells which list in the window it belongs to.
private struct SpaceKeyMonitor: NSViewRepresentable {
    let action: () -> Bool
    let blocked: Bool

    func makeNSView(context: Context) -> SpaceKeyMonitorView { SpaceKeyMonitorView() }

    func updateNSView(_ view: SpaceKeyMonitorView, context: Context) {
        view.action = action
        view.blocked = blocked
    }
}

final class SpaceKeyMonitorView: NSView {
    var action: () -> Bool = { false }
    var blocked = false
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil } // clicks go to the list

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.handles(event) else { return event }
                return self.action() ? nil : event
            }
        } else if window == nil, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    /// Space without ⌘, ⌥ or ⌃ in this view's window, no sheet or confirmation shown, and the focused view is the
    /// table (SwiftUI `List` and `Table` are `NSTableView`s) this view sits behind, not another list in the window.
    func handles(_ event: NSEvent) -> Bool {
        guard !blocked, let window, event.window === window, window.attachedSheet == nil,
              event.keyCode == 49, event.modifierFlags.isDisjoint(with: [.command, .option, .control]),
              let table = window.firstResponder as? NSTableView else { return false }
        let list = table.enclosingScrollView ?? table
        let listFrame = list.convert(list.bounds, to: nil)
        return convert(bounds, to: nil).contains(CGPoint(x: listFrame.midX, y: listFrame.midY))
    }
}
