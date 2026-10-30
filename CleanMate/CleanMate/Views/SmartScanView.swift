import Combine
import SwiftUI

/// Scan → results → clean screen shared by Smart Scan and Privacy.
struct SmartScanView: View {
    @ObservedObject var model: SmartScanModel
    let module: Module
    @State private var confirming = false
    @State private var excludedCount = 0
    @State private var hasFullDiskAccess = FullDiskAccess.isGranted
    /// Idle-screen overview source; snapshots inject fixed values instead of reading the disk.
    var readOverview: @MainActor () -> Overview = { Self.readOverview() }
    @State private var overview: Overview?
    @AppStorage(Preferences.disabledScanGroups) private var disabledText = ""

    struct Overview {
        var volume: SpaceLensModel.Volume
        var freed30Days: Int64
    }

    /// "Freed X in the last 30 days"; nil when nothing was freed. Shared with the menu bar extra.
    static func freedLine(_ bytes: Int64) -> String? {
        bytes > 0 ? String(localized: "Freed \(bytes, format: .fileSize) in the last 30 days") : nil
    }

    /// Menu bar item: the last finished Smart Scan and what it found, or what cleaning it freed.
    nonisolated static func lastScanLine(_ last: LastScan, locale: Locale = .current) -> String {
        let date = last.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
        let size = { (bytes: Int64) in bytes.formatted(.fileSize.locale(locale)) }
        var resource: LocalizedStringResource = if let cleaned = last.cleaned {
            "Last scan \(date): cleaned \(size(cleaned))"
        } else if last.size > 0 {
            "Last scan \(date): \(size(last.size)) to clean"
        } else {
            "Last scan \(date): nothing to clean"
        }
        resource.locale = locale
        return String(localized: resource)
    }

    /// Bytes deleted in the last 30 days (Smart Scan overview and menu bar extra).
    static var freedLast30Days: Int64 { ActivityLog.freed(after: .now.addingTimeInterval(-30 * 86_400)).deleted }

    static func readOverview() -> Overview {
        Overview(volume: .read(SafetyPolicy.current.homeURL),
                 freed30Days: freedLast30Days)
    }

    var body: some View {
        Group {
            switch model.phase {
            case .idle:
                EmptyStateView(title: Text(module.title), systemImage: module.systemImage) {
                    switch module {
                    case .smartScan:
                        Text("Find caches, old logs, crash reports, temporary files, developer junk, AI tool and app caches that are safe to remove.")
                    case .privacy:
                        Text("Erase browsing history, cookies and form data per browser, recent items and shell history. Passwords, bookmarks and extensions are never touched.")
                    case .overview, .largeFiles, .uninstaller, .spaceLens, .loginItems:
                        EmptyView() // has its own view
                    }
                } actions: {
                    VStack(spacing: 20) {
                        scanButton("Scan").buttonStyle(.borderedProminent)
                        if allGroupsOff {
                            Text("Every group is turned off in Settings › Scan Groups.").foregroundStyle(.secondary)
                            OpenSettingsButton()
                        }
                        if module == .smartScan, let overview {
                            idleOverview(overview)
                        }
                    }
                }
            case .cleaning:
                ProgressView(value: Double(model.scannedItems), total: Double(max(model.totalItems, 1))) {
                    Text("Cleaning…")
                } currentValueLabel: {
                    Text("Cleaning item \(min(model.scannedItems + 1, model.totalItems))/\(model.totalItems): \(model.cleaningItem.map { Text($0) } ?? Text(verbatim: ""))")
                }
                .frame(maxWidth: 360)
            case .scanning, .results:
                results
            case .done(let report):
                EmptyStateView(title: Text("Freed \(report.freed, format: .fileSize)"), systemImage: "checkmark.circle") {
                    if module == .privacy {
                        Text("The selected traces were erased.")
                    }
                    let trashed = model.cleanedGroups.reduce(Int64(0)) { $0 + $1.trashed }
                    if let result = report.undo {
                        UndoTrashResult(result: result)
                    } else if trashed > 0 {
                        Text("\(trashed, format: .fileSize) of it is in the Trash: empty the Trash to free that space.")
                    }
                    if report.upTo > 0 {
                        Text("\(report.upTo, format: .fileSize) of it came from caches that share files with your projects, so less space may be freed.")
                    }
                    if report.skipped > 0 {
                        Text("Skipped (in use or not permitted): \(report.skipped)")
                    }
                    if !model.cleanedGroups.isEmpty {
                        cleanedGroups
                    }
                    if let change = model.freeSpaceChange {
                        // Reference only: other apps, Spotlight and snapshots change it too.
                        Text("Free space: \(change.before, format: .fileSize) → \(change.after, format: .fileSize)")
                            .font(.caption)
                            .padding(.top, 4)
                    }
                } actions: {
                    scanButton("Scan Again").disabled(model.undoing)
                    if model.cleanedGroups.contains(where: { $0.trashed > 0 }) { OpenTrashButton() }
                    if report.undo == nil && !report.trashed.isEmpty {
                        Button("Undo") { Task { await model.undoTrash() } }
                            .help("Put the items just moved to the Trash back where they were.")
                    }
                }
            }
        }
        .navigationTitle(Text(module.title))
        .trashUndo(model)
        .onAppear {
            hasFullDiskAccess = FullDiskAccess.isGranted
            if module == .smartScan { overview = readOverview() }
        }
        // record() may post off the main thread; hop to main before touching @State.
        .onReceive(NotificationCenter.default.publisher(for: ActivityLog.didRecord).receive(on: RunLoop.main)) { _ in
            if module == .smartScan { overview = readOverview() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasFullDiskAccess = FullDiskAccess.isGranted
        }
    }

    /// Safari data is protected by macOS: explain how to grant access instead of failing silently.
    private var fullDiskAccessBanner: some View {
        HStack(alignment: .top) {
            Image(systemName: "lock.shield").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Full Disk Access is needed for Safari").bold()
                Text("Open System Settings > Privacy & Security > Full Disk Access, turn on CleanMate, then scan again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Settings…") { FullDiskAccess.openSettings() }
        }
    }

    private var results: some View {
        // Arrow keys move the row selection, Space ticks/unticks it; controls inside rows still take clicks.
        List(selection: $model.highlighted) {
            if module == .privacy && !hasFullDiskAccess {
                fullDiskAccessBanner
            }
            if offCount > 0 {
                HStack {
                    Text("Groups turned off in Settings: \(offCount)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    OpenSettingsButton().controlSize(.small)
                }
            }
            ForEach(model.visibleGroups) { group in
                // Bars compare items within their group: one huge item (DerivedData) would flatten every bar list-wide.
                let largest = group.items.compactMap { model.scans[$0.id]?.size }.max() ?? 0
                // Section(isExpanded:) needs macOS 14; the header draws the disclosure arrow anyway.
                Section {
                    if !model.collapsedGroups.contains(group.id) {
                        ForEach(group.items) { item in
                            CleanerItemRow(item: item, scan: model.scans[item.id], isOn: selection(item),
                                           isRunning: model.isRunning(item), isBlocked: model.blocked.contains(item.id),
                                           quit: { model.quitApps(of: item) },
                                           groupImage: group.systemImage, largestInGroup: largest,
                                           entryOn: item.selectableEntries ? { url in entrySelection(item, url) } : nil,
                                           selectedSize: model.partialSelectedSize(item),
                                           highlight: { model.highlighted = [item.id] },
                                           neverClean: { url in
                                               if model.neverClean(item, url) { excludedCount += 1 }
                                           })
                                .tag(item.id)
                        }
                    }
                } header: {
                    groupHeader(group)
                }
            }
        }
        .onSpaceKey {
            guard !model.highlighted.isEmpty else { return false }
            model.toggle(ids: model.highlighted)
            return true
        }
        .exclusionNotice(excludedCount)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("Selected: \(selectedTotal)")
                    .monospacedDigit()
                Spacer()
                if isScanning {
                    ProgressView(value: model.scanFraction) {
                        Text("Scanning…")
                    } currentValueLabel: {
                        Text(verbatim: "\(model.scannedItems)/\(model.totalItems)")
                    }
                    .frame(maxWidth: 240)
                    Button("Stop") { model.cancelScan() }
                } else {
                    scanButton("Scan Again")
                }
                Button(module == .privacy ? LocalizedStringKey("Erase…") : "Clean…") { confirming = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isScanning || !model.hasSelection)
            }
            .padding()
            .background(.bar)
        }
        .focusedSceneValue(\.confirming, confirming)
        .confirmationDialog(
            module == .privacy ? Text("Erase the selected data?")
                : Text("Clean \(selectedTotal)?"),
            isPresented: $confirming
        ) {
            Button(module == .privacy ? LocalizedStringKey("Erase") : "Clean", role: .destructive) { Task { await model.clean() } }
        } message: {
            switch module {
            case .smartScan:
                Text("Selected items are deleted permanently, except those marked “Moved to the Trash”. Apps and tools recreate caches as needed.")
            case .privacy:
                Text("Selected data is deleted permanently, not moved to the Trash, and cannot be recovered. Erasing cookies signs you out of websites.")
            case .overview, .largeFiles, .uninstaller, .spaceLens, .loginItems:
                EmptyView()
            }
        }
    }

    private var isScanning: Bool {
        if case .scanning = model.phase { true } else { false }
    }

    private var selectedTotal: Text {
        Self.totalText(.init(size: model.selectedSize, upTo: model.selectedUpToSize, records: model.selectedRecords))
    }

    /// Sure bytes, plus "up to" bytes of items whose size is only a maximum (pnpm store),
    /// plus records of database items (only records when there are no bytes).
    static func totalText(_ total: SmartScanModel.Total) -> Text {
        let bytes = total.upTo == 0 ? Text(total.size, format: .fileSize)
            : Text("\(total.size, format: .fileSize) + up to \(total.upTo, format: .fileSize)")
        guard total.records > 0 else { return bytes }
        let recordsText = Text("\(total.records) records")
        return total.size == 0 && total.upTo == 0 ? recordsText : Text("\(bytes) + \(recordsText)")
    }

    private func expanded(_ group: CleanerGroup) -> Binding<Bool> {
        Binding { !model.collapsedGroups.contains(group.id) } set: { open in
            if open { model.collapsedGroups.remove(group.id) } else { model.collapsedGroups.insert(group.id) }
        }
    }

    /// Group checkbox (on: every selectable item ticked, mixed: some), then the group name and the total of its
    /// scanned items, read as one element. A click anywhere on the header but the arrow ticks or unticks the group.
    private func groupHeader(_ group: CleanerGroup) -> some View {
        let allOn = model.isAllSelected(group)
        let canSelect = !model.selectableItems(in: group).isEmpty
        let isExpanded = expanded(group)
        let set = { (on: Bool) in model.setSelected(group, on) }
        // Two sources that disagree make the checkbox mixed: some items ticked, not all.
        let sources = [Binding { model.isAnySelected(group) } set: { set($0) }, Binding { allOn } set: { set($0) }]
        return HStack {
            // Plain macOS lists don't draw the native disclosure (only .sidebar does), so the header carries its own.
            Button { withAnimation { isExpanded.wrappedValue.toggle() } } label: {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel(isExpanded.wrappedValue ? Text("Collapse \(Text(group.title))") : Text("Expand \(Text(group.title))"))
            HStack {
                Toggle(sources: sources, isOn: \.self) { EmptyView() }
                    .toggleStyle(SelectionCheckboxStyle())
                    .disabled(!canSelect)
                    .accessibilityLabel(Text("Select All in \(Text(group.title))"))
                HStack {
                    Label { Text(group.title).foregroundStyle(.primary) } icon: {
                        Image(systemName: group.systemImage).foregroundStyle(.tint)
                    }
                    .font(.headline)
                    Spacer()
                    Self.totalText(model.total(of: group.items)).monospacedDigit().foregroundStyle(.primary)
                }
                .accessibilityElement(children: .combine)
            }
            .selectionRow(isOn: false, enabled: canSelect) { set(!allOn) }
        }
    }

    /// Done screen: what each group freed, and how much of it went to the Trash.
    private var cleanedGroups: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(model.cleanedGroups) { group in
                GridRow {
                    Label { Text(group.title) } icon: { Image(systemName: group.systemImage) }
                        .foregroundStyle(.primary) // not the description's faded grey
                    Group {
                        if group.trashed == 0 {
                            Text(group.freed, format: .fileSize)
                        } else if group.trashed == group.freed {
                            Text("\(group.freed, format: .fileSize) moved to the Trash")
                        } else {
                            Text("\(group.freed, format: .fileSize) (\(group.trashed, format: .fileSize) moved to the Trash)")
                        }
                    }
                    .monospacedDigit()
                    .foregroundStyle(.primary) // same size as the title, not the description's faded grey
                    .gridColumnAlignment(.trailing)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .fixedSize()
        .padding(.top, 8)
    }

    /// Smart Scan idle screen: free space on the home volume and what cleaning freed in the last 30 days.
    private func idleOverview(_ overview: Overview) -> some View {
        VStack(spacing: 8) {
            VolumeGauge(volume: overview.volume)
            if let line = Self.freedLine(overview.freed30Days) {
                Label(line, systemImage: "sparkles")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 320)
    }

    private func scanButton(_ title: LocalizedStringKey) -> some View {
        Button(title) { model.startScan() }.disabled(allGroupsOff)
    }

    /// Smart Scan groups turned off in Settings; 0 for Privacy.
    private var offCount: Int {
        module == .smartScan ? model.disabledCount(Preferences.disabledGroups(text: disabledText)) : 0
    }

    private var allGroupsOff: Bool { offCount > 0 && offCount == model.catalogGroupIDs.count }

    private func selection(_ item: CleanerItem) -> Binding<Bool> {
        Binding(get: { model.selected.contains(item.id) }, set: { model.setSelected(item, $0) })
    }

    private func entrySelection(_ item: CleanerItem, _ url: URL) -> Binding<Bool> {
        Binding(get: { model.isEntrySelected(item, url) }, set: { model.setEntry(item, url, $0) })
    }
}

struct CleanerItemRow: View {
    @Environment(\.locale) private var locale
    let item: CleanerItem
    let scan: ItemScan?
    @Binding var isOn: Bool
    let isRunning: Bool
    /// Its tool folder overlaps Settings › Exclusions, so it is never cleaned.
    var isBlocked = false
    let quit: () -> Void
    /// Icon for items that are not tied to an app (the group's SF Symbol).
    var groupImage = "folder"
    /// Largest size in the item's group, the full length of its `SizeBar`.
    var largestInGroup: Int64 = 0
    /// Folded by default; UISnapshots passes true to show the path rows.
    @State var isExpanded = false
    /// Per-entry tick for items with `selectableEntries`; nil = the item is ticked as a whole.
    var entryOn: ((URL) -> Binding<Bool>)? = nil
    /// Bytes of the ticked entries when only some are ticked; nil = the whole item (or none) is ticked.
    var selectedSize: Int64? = nil
    /// A click on the row or one of its entries highlights the item, as a click on a List row does.
    var highlight: (() -> Void)? = nil
    /// "Never Clean This" on an entry; nil hides it (UISnapshots).
    var neverClean: ((URL) -> Void)? = nil

    // shortcut: only the largest entries are listed (the rest get one summary row), so huge folders don't slow the List; add paging if users need all.
    private let shownLimit = 200

    /// The size column's text; nil while the item is still scanning.
    /// `selectedSize`: some entries left out, shown as "selected of total", like the "Selected" total.
    static func sizeText(item: CleanerItem, scan: ItemScan?, selectedSize: Int64? = nil, locale: Locale = .current) -> String? {
        guard let scan else { return nil }
        if let records = scan.records { return String(localized: "\(records) records", locale: locale) }
        if scan.unmeasured { return String(localized: "Size unknown", locale: locale) }
        let size = scan.size.formatted(.fileSize.locale(locale))
        if let selectedSize {
            // String(localized:locale:) only formats with `locale`; the resource's locale also picks the language (vi).
            var text: LocalizedStringResource = "\(selectedSize.formatted(.fileSize.locale(locale))) of \(size)"
            text.locale = locale
            return String(localized: text)
        }
        return item.sizeIsUpperBound ? String(localized: "Up to \(size)", locale: locale) : size
    }

    /// VoiceOver reads the row as one element: title, note, size.
    static func accessibilityLabel(item: CleanerItem, scan: ItemScan?, selectedSize: Int64? = nil, locale: Locale = .current) -> String {
        [String(localized: item.title), item.note.map { String(localized: $0) },
         sizeText(item: item, scan: scan, selectedSize: selectedSize, locale: locale)].compactMap { $0 }.joined(separator: ", ")
    }

    /// An entry's checkbox reads "label or file name, date, size": never the long path.
    static func accessibilityLabel(entry: ScanEntry, locale: Locale = .current) -> String {
        [entry.title ?? entry.url.lastPathComponent,
         entry.date?.formatted(.dateTime.year().month().day().locale(locale)),
         entry.size.formatted(.fileSize.locale(locale))].compactMap { $0 }.joined(separator: ", ")
    }

    /// A row with no checkbox and no file (a Docker image) has no control in it, so VoiceOver reads it as one
    /// element "name, size"; nil leaves the row's children as they are.
    static func rowAccessibilityLabel(entry: ScanEntry, selectable: Bool, locale: Locale = .current) -> String? {
        selectable || entry.url.isFileURL ? nil : accessibilityLabel(entry: entry, locale: locale)
    }

    var body: some View {
        let entries = scan?.entries ?? []
        DisclosureGroup(isExpanded: $isExpanded) {
            // Selectable items list every entry: none is cleaned without being seen.
            let shown = entryOn == nil ? Array(entries.prefix(shownLimit)) : entries
            ForEach(shown) { entry in
                let on = entryOn?(entry.url)
                HStack {
                    if let on {
                        Toggle(isOn: on) { EmptyView() }
                            .toggleStyle(SelectionCheckboxStyle())
                            .disabled(isLocked)
                            .accessibilityLabel(Self.accessibilityLabel(entry: entry, locale: locale))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        if let title = entry.title { // e.g. an iPhone backup's device and date
                            HStack(spacing: 6) {
                                Text(verbatim: title)
                                if let date = entry.date {
                                    Text(date, format: .dateTime.year().month().day()).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if entry.url.isFileURL { // not a Docker image: those have no file
                            Text(entry.url.path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                                .foregroundStyle(entry.title == nil ? .primary : .secondary)
                                .accessibilityHidden(entry.title != nil) // the label names it; the path is long
                        }
                    }
                    Spacer()
                    if entry.url.isFileURL { // own column before the sizes, so it lines up in every row
                        Button("Reveal in Finder", systemImage: "magnifyingglass") {
                            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Reveal in Finder")
                    }
                    Group {
                        if !entry.isDatabase {
                            Text(entry.size, format: .fileSize)
                        } else if let records = entry.records {
                            Text("\(records) records")
                        } else {
                            Text("Count unknown (quit the app and scan again)")
                        }
                    }
                    .sizeColumnStyle(emphasized: false)
                    .frame(minWidth: 72, alignment: .trailing) // fixed width keeps the magnifier column straight
                    .accessibilityHidden(entryOn != nil) // the checkbox already reads the size
                    Color.clear.frame(width: 48, height: 1).accessibilityHidden(true) // the item's SizeBar column: sizes line up
                }
                .frame(minHeight: 28)
                .selectionRow(isOn: on?.wrappedValue == true, enabled: !isLocked, highlight: highlight,
                              toggle: on.map { on in { on.wrappedValue.toggle() } })
                .padding(.leading, 42) // under the item title, past the checkbox and icon
                .accessibilityReadsAsOne(Self.rowAccessibilityLabel(entry: entry, selectable: entryOn != nil, locale: locale))
                .contextMenu {
                    if let neverClean, Preferences.canExclude(entry.url) {
                        Button("Never Clean This") { neverClean(entry.url) }
                    }
                }
            }
            if entries.count > shown.count {
                let rest = entries.dropFirst(shown.count)
                Text("and \(rest.count) more (\(rest.reduce(0) { $0 + $1.size }, format: .fileSize))")
                    .foregroundStyle(.secondary)
            }
        } label: {
            let ticked = isOn && !isLocked
            HStack {
                // The links sit outside the Toggle's label: a disabled Toggle disables its label too.
                VStack(alignment: .leading, spacing: 4) {
                    // With entry ticks the checkbox shows mixed when only some are on; ticking it ticks them all.
                    Toggle(sources: [$isOn] + (entryOn.map { on in entries.map { on($0.url) } } ?? []), isOn: \.self) {
                        // Icon on the title line, so it lines up with the checkbox; the note sits under the title.
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                icon.frame(width: 16, height: 16).accessibilityHidden(true)
                                Text(item.title)
                            }
                            if let note = item.note {
                                Text(note).font(.subheadline).foregroundStyle(.secondary).padding(.leading, 22)
                            }
                        }
                    }
                    .toggleStyle(SelectionCheckboxStyle(lockReason: isLocked ? lockReason : nil))
                    .disabled(isLocked)
                    .accessibilityLabel(Self.accessibilityLabel(item: item, scan: scan, selectedSize: selectedSize, locale: locale))
                    Group {
                        if isRunning && item.runningAppBundleIDs.isEmpty {
                            Text("The tool is running, so it is skipped. Close its sessions and scan again")
                                .foregroundStyle(.orange)
                        } else if isRunning {
                            HStack {
                                Text("The app is open, so it is skipped").foregroundStyle(.orange)
                                Button("Quit App") { quit() }
                                    .buttonStyle(.link)
                            }
                        }
                        if isBlocked {
                            HStack {
                                Text("Blocked by a folder in Exclusions").foregroundStyle(.orange)
                                OpenSettingsButton(tab: SettingsView.exclusionsTab) { Text("Open Exclusions…") }
                                    .buttonStyle(.link)
                            }
                        }
                        if scan?.permissionDenied == true {
                            HStack {
                                Text("Needs Full Disk Access").foregroundStyle(.secondary)
                                Button("Open Settings…") { FullDiskAccess.openSettings() }
                                    .buttonStyle(.link)
                            }
                        } else if scan?.partlyUnreadable == true {
                            Text("Some items could not be read — the size may be larger").foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                    .padding(.leading, 52) // under the title, past the checkbox and icon
                }
                Spacer()
                if let size = Self.sizeText(item: item, scan: scan, selectedSize: selectedSize, locale: locale) {
                    Text(verbatim: size)
                        .sizeColumnStyle(emphasized: ticked)
                        .fontWeight(ticked ? .semibold : .regular)
                        .accessibilityHidden(true) // read as part of the Toggle's label
                    // The bar keeps the whole item: it compares what was found across the group, as for unticked items.
                    SizeBar(size: scan?.size ?? 0, largest: largestInGroup, tint: ticked ? .accentColor : .secondary, height: 8)
                        .opacity(scan?.records != nil || scan?.unmeasured == true ? 0 : 1) // no bytes to compare
                } else {
                    ProgressView().controlSize(.small).accessibilityLabel("Scanning…") // still scanning
                }
            }
            .padding(.vertical, 8)
            .frame(minHeight: 36)
            .selectionRow(isOn: isOn, enabled: !isLocked, highlight: highlight) {
                // Like the checkbox: mixed (some entries left out) ticks them all.
                let mixed = isOn && entries.contains { entryOn?($0.url).wrappedValue == false }
                isOn = mixed || !isOn
            }
            .padding(.leading, 2) // room between the disclosure arrow and the checkbox
        }
    }

    @MainActor private static func appIcon(_ bundleID: String) -> NSImage? {
        IconCache.image("app:" + bundleID) {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
        }
    }

    private var isLocked: Bool { scan?.hasData != true || isRunning || isBlocked }

    /// Why a locked row cannot be ticked, for the lock badge on its checkbox; nil for an item that found nothing.
    private var lockReason: LocalizedStringKey? {
        if isRunning {
            item.runningAppBundleIDs.isEmpty ? "The tool is running, so it is skipped. Close its sessions and scan again"
                : "The app is open, so it is skipped"
        } else if isBlocked {
            "Blocked by a folder in Exclusions"
        } else if scan?.permissionDenied == true {
            "Needs Full Disk Access"
        } else {
            nil
        }
    }

    /// The app's own icon when the item belongs to an installed app, else the group's symbol.
    @ViewBuilder private var icon: some View {
        if let image = item.runningAppBundleIDs.lazy.compactMap(Self.appIcon).first {
            Image(nsImage: image).resizable()
        } else {
            Image(systemName: groupImage).foregroundStyle(.secondary)
        }
    }
}
