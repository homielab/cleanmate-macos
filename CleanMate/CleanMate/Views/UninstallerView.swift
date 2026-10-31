import QuickLook
import SwiftUI

/// Uninstaller: apps on the left, the selected app's files (or leftovers of removed apps) on the right; with several
/// apps ticked, the batch panel lists them for one confirmation.
struct UninstallerView: View {
    @ObservedObject var model: UninstallerModel
    @Environment(\.locale) private var locale
    @State private var confirming = false
    @State private var confirmingBatch = false
    @State private var previewURL: URL?
    @AppStorage(Preferences.uninstallerSort) private var sort = UninstallerModel.AppSort.name
    @AppStorage(Preferences.uninstallerUnused) private var unused = UninstallerModel.UnusedFilter.all

    var body: some View {
        HStack(spacing: 0) {
            appList.frame(width: 280)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(Text(Module.uninstaller.title))
        .trashUndo(model)
        .onAppearAndChange(of: unused) { model.unused = $0 }
        .searchable(text: $model.search, placement: .toolbar, prompt: Text("Search Apps"))
        .toolbar {
            Menu("Sort By", systemImage: "arrow.up.arrow.down") {
                Picker("Sort By", selection: $sort) {
                    Text("Name").tag(UninstallerModel.AppSort.name)
                    Text("Size").tag(UninstallerModel.AppSort.size)
                    Text("Last Used").tag(UninstallerModel.AppSort.lastUsed)
                }
                .pickerStyle(.inline)
            }
            .help("Sort By")
            Menu("Show", systemImage: unused == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill") {
                Picker("Show", selection: $unused) {
                    Text("All Apps").tag(UninstallerModel.UnusedFilter.all)
                    Text("Not Used for 3 Months").tag(UninstallerModel.UnusedFilter.months3)
                    Text("Not Used for 6 Months").tag(UninstallerModel.UnusedFilter.months6)
                    Text("Not Used for a Year").tag(UninstallerModel.UnusedFilter.year1)
                }
                .pickerStyle(.inline)
            }
            .help("Show apps not used for a while (apps with no last-opened date are left out)")
            Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }
                .disabled(model.loadingApps || model.working)
        }
        .task { if model.apps.isEmpty || model.apps.contains(where: { model.appSizes[$0.url] == nil }) { await model.loadApps() } }
        .task { if model.hiddenItems == nil { await model.loadHiddenConfig() } }
        .task { if model.extensionItems == nil { await model.loadExtensions() } }
        .task(id: model.selection) { await model.loadEntries() }
        .task(id: model.dataGeneration) { await model.measureAppData() }
        .task(id: [AnyHashable(model.appTicks), AnyHashable(model.dataGeneration)]) { await model.loadBatch() }
        .quickLookPreview($previewURL)
        .dropDestination(for: URL.self) { urls, _ in model.drop(urls) }
        .alert("Can’t Select This Item", isPresented: Binding(get: { model.dropRejection != nil }, set: { if !$0 { model.dropRejection = nil } }),
               presenting: model.dropRejection) { _ in
            Button("OK", role: .cancel) {}
        } message: { rejection in
            switch rejection {
            case .notApp: Text("Drop an app (.app) on the window to select it.")
            case .notListed: Text("This app is not in the list. Only apps in Applications or ~/Applications can be uninstalled here; Apple’s apps and CleanMate are not listed.")
            }
        }
        .alert(outcomeTitle, isPresented: Binding(get: { model.outcome != nil }, set: { if !$0 { model.outcome = nil } }),
               presenting: model.outcome) { outcome in
            switch outcome {
            case .appNotTrashed(let app), .appLocked(let app):
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
            case .removed(let report):
                TrashReportButtons(report: report) { await model.undo(report) }
            case .batch(let result):
                TrashReportButtons(report: result.report) { await model.undo(result.report) }
            default:
                EmptyView()
            }
            Button("OK", role: .cancel) {}
        } message: { outcome in
            switch outcome {
            case .removed(let report):
                Text(verbatim: [String(localized: "Empty the Trash to free the space."),
                                report.skipped > 0 ? String(localized: "Skipped (in use or not permitted): \(report.skipped)") : nil,
                                report.locked > 0 ? String(localized: "Locked in Finder (turn off Locked in Get Info): \(report.locked)") : nil]
                    .compactMap { $0 }.joined(separator: " "))
            case .restored(let result):
                if result.skipped > 0 {
                    Text("Left in the Trash (gone from it, something already in its place, or not permitted): \(result.skipped)")
                }
            case .appTrashCancelled:
                Text("Nothing was moved to the Trash.")
            case .appLocked:
                Text("It is locked in Finder. Select it, choose File > Get Info, turn off Locked, then try again. Nothing was moved.")
            case .appNotTrashed:
                Text("It may belong to the system or another user, for example an App Store app. Drag it to the Trash in Finder, which asks for your password, then remove its leftovers here. Nothing was moved.")
            case .batch(let result):
                Text(verbatim: Self.batchMessage(result))
            }
        }
    }

    private var outcomeTitle: Text {
        switch model.outcome {
        case .removed(let report): Text("Moved \(report.freed, format: .fileSize) to the Trash")
        case .restored(let result): Text("Put back from the Trash: \(result.restored)")
        case .appNotTrashed(let app), .appLocked(let app): Text("Couldn’t move \(app.name) to the Trash")
        case .appTrashCancelled(let app): Text("Uninstall of \(app.name) cancelled")
        case .batch(let result) where result.removed.isEmpty: Text("No apps were uninstalled")
        case .batch(let result): Text("Moved \(result.report.freed, format: .fileSize) to the Trash")
        case nil: Text(verbatim: "")
        }
    }

    /// Apps uninstalled, then each app left with its reason, then the usual Trash lines.
    static func batchMessage(_ result: UninstallerModel.BatchResult) -> String {
        let report = result.report
        let skipped = result.skipped.map { app, reason in
            switch reason {
            case .running: String(localized: "\(app.name) is open: quit it, then uninstall it.")
            case .locked: String(localized: "\(app.name) is locked in Finder: turn off Locked in Get Info, then try again.")
            case .cancelled: String(localized: "\(app.name) was not moved: the password prompt was cancelled.")
            case .notTrashed: String(localized: "\(app.name) couldn’t be moved to the Trash: it may belong to the system or another user.")
            }
        }
        return ([result.removed.isEmpty ? nil : String(localized: "Uninstalled: \(result.removed.count)")] + skipped
                + [result.removed.isEmpty ? nil : String(localized: "Empty the Trash to free the space."),
                   report.skipped > 0 ? String(localized: "Skipped (in use or not permitted): \(report.skipped)") : nil,
                   report.locked > 0 ? String(localized: "Locked in Finder (turn off Locked in Get Info): \(report.locked)") : nil])
            .compactMap { $0 }.joined(separator: " ")
    }

    private var appList: some View {
        List(selection: $model.selection) {
            Section {
                Label("Leftovers of Removed Apps", systemImage: "questionmark.folder").tag(UninstallerModel.Selection.leftovers)
                Label("Unknown Hidden Config", systemImage: "exclamationmark.triangle")
                    .badge(model.hiddenItems?.count ?? 0)
                    .tag(UninstallerModel.Selection.hiddenConfig)
                Label("Extensions", systemImage: "puzzlepiece.extension")
                    .badge(model.extensionItems?.count ?? 0)
                    .tag(UninstallerModel.Selection.extensions)
            }
            Section {
                ForEach(UninstallerModel.sorted(model.filteredApps, by: sort, sizes: model.totalSizes)) { app in
                    HStack {
                        Toggle(isOn: ticked(app.url)) { EmptyView() }
                            .toggleStyle(SelectionCheckboxStyle())
                            .accessibilityLabel(Text(verbatim: app.name))
                            .disabled(model.working)
                            .help("Tick several apps to uninstall them together")
                        AppIcon(url: app.url, size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name).lineLimit(1)
                            Group {
                                sizeText(app).lineLimit(1)
                                if let lastUsed = app.lastUsed, app.lastUsedIsEstimate {
                                    Text("Last used ≈ \(lastUsed, format: .relative(presentation: .named))").lineLimit(1)
                                        .help("Estimated from when the app's settings, cache or support files last changed")
                                } else if let lastUsed = app.lastUsed {
                                    Text("Last used \(lastUsed, format: Date.FormatStyle(date: .abbreviated, time: .omitted))").lineLimit(1)
                                } else {
                                    Text("Last used: Unknown").lineLimit(1)
                                        .help("macOS has no record of when this app was last opened")
                                }
                            }
                            .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .contain) // the checkbox stays its own element
                    .tag(UninstallerModel.Selection.app(app.url))
                }
                if model.hiddenUndatedCount > 0 {
                    HStack {
                        Text("\(model.hiddenUndatedCount) apps with no last-opened date are hidden")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button("Show") { model.showUndated = true }.controlSize(.small)
                    }
                }
                if let fixes = UninstallerModel.noMatchFixes(appCount: model.apps.count, shownCount: model.filteredApps.count,
                                                             search: model.search, unused: unused) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("No Matching Apps", systemImage: "magnifyingglass").foregroundStyle(.secondary)
                        HStack {
                            if fixes.contains(.clearSearch) { Button("Clear Search") { model.search = "" } }
                            if fixes.contains(.showAll) { Button("Show All Apps") { unused = .all } }
                        }
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                appsHeader
            }
        }
        .overlay { if model.loadingApps { ProgressView().accessibilityLabel("Loading…") } }
    }

    /// "Applications" with a checkbox: on when every listed app is ticked, mixed when some are; it ticks or unticks the
    /// listed apps.
    private var appsHeader: some View {
        let listed = model.filteredApps.map(\.url)
        let all = !listed.isEmpty && listed.allSatisfy(model.appTicks.contains)
        let any = listed.contains(where: model.appTicks.contains)
        // Two sources that disagree make the checkbox mixed, like Smart Scan's group headers.
        let sources = [Binding { any } set: { model.tickListed($0) }, Binding { all } set: { model.tickListed($0) }]
        return HStack(spacing: 6) {
            Toggle(sources: sources, isOn: \.self) { EmptyView() }
                .toggleStyle(SelectionCheckboxStyle())
                .disabled(listed.isEmpty || model.working)
                .accessibilityLabel(Text("Select All Apps"))
            Text("Applications")
            Spacer()
            if model.appTicks.count > 0 {
                Text("\(model.appTicks.count) ticked").monospacedDigit()
            }
        }
    }

    private func ticked(_ url: URL) -> Binding<Bool> {
        Binding(get: { model.appTicks.contains(url) },
                set: { if $0 { model.appTicks.insert(url) } else { model.appTicks.remove(url) } })
    }

    /// "45 MB · data 1.2 GB" once the app's ~/Library data is measured and not empty.
    private func sizeText(_ app: InstalledApp) -> Text {
        let size = model.appSizes[app.url]?.formatted(.fileSize.locale(locale)) ?? "…"
        guard let data = model.appDataSizes[app.url], data > 0 else { return Text(verbatim: size) }
        return Text("\(size) · data \(data.formatted(.fileSize.locale(locale)))")
    }

    @ViewBuilder private var detail: some View {
        switch model.selection {
        case nil where model.batchMode:
            batchPanel
        case nil:
            EmptyStateView(title: Text(Module.uninstaller.title), systemImage: Module.uninstaller.systemImage) {
                VStack(spacing: 8) {
                    Text("Select an app to see its files in your Library. The app and the files you keep ticked go to the Trash. Apple’s apps are not listed.")
                    Text("To reset an app instead, untick the app itself: only its data goes to the Trash and the app stays. Files left by apps you already removed are under “Leftovers of Removed Apps” on the left.")
                }
            }
        case .leftovers:
            VStack(spacing: 0) {
                header {
                    Image(systemName: "questionmark.folder").font(.largeTitle).foregroundStyle(.secondary)
                } text: {
                    Text("Leftovers of Removed Apps").font(.title2.bold())
                    Text("Library items named after apps that are no longer installed. Nothing is selected for you: check each item before removing it.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                entryList(empty: Text("No Leftovers Found"))
                footer(button: Text("Move to Trash…"))
            }
        case .hiddenConfig:
            VStack(spacing: 0) {
                header {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                } text: {
                    Text("Unknown Hidden Config").font(.title2.bold())
                    Text("Hidden items in your home folder and in ~/.config that CleanMate doesn’t recognize.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("CleanMate doesn’t remove these items. Check them and deal with them yourself if needed.")
                        .font(.callout)
                }
                hiddenList
            }
        case .extensions:
            VStack(spacing: 0) {
                header {
                    Image(systemName: "puzzlepiece.extension").font(.largeTitle).foregroundStyle(.secondary)
                } text: {
                    Text("Extensions").font(.title2.bold())
                    Text("Preference panes, Quick Look and Spotlight plug-ins, services, screen savers, input methods and internet plug-ins in your Library. They often stay behind after an app is removed.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Nothing is selected for you: check each item before removing it. Apple’s items can’t be selected.")
                        .font(.callout)
                }
                extensionList
                footer(button: Text("Move to Trash…"))
            }
        case .app:
            if let app = model.selectedApp {
                VStack(spacing: 0) {
                    header {
                        AppIcon(url: app.url, size: 48)
                    } text: {
                        Text(app.name).font(.title2.bold())
                        Text(verbatim: [app.version, app.bundleID].compactMap { $0 }.joined(separator: " · "))
                            .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        if model.batchMode {
                            Button("Show the \(model.appTicks.count) Ticked Apps") { model.selection = nil }
                                .buttonStyle(.link).font(.callout)
                        }
                        if model.isRunning(app) {
                            HStack {
                                Text("The app is open. Quit it before uninstalling.").foregroundStyle(.orange)
                                Button("Quit App") { model.quit(app) }.buttonStyle(.link)
                            }
                            .font(.callout)
                        }
                        if model.entries.contains(where: { $0.kind != .data }) {
                            Text("Items marked “Possibly related” and config in your home folder, ~/.config or ~/.local/share aren’t selected for you: check them before removing.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    entryList(app: app, empty: Text("No Related Files Found"))
                    footer(button: model.trashApp ? Text("Uninstall…") : Text("Reset…"), app: app)
                }
            }
        }
    }

    /// Several ticked apps: each with its app + data size, one Uninstall for all. Only data surely the app's goes.
    private var batchPanel: some View {
        let apps = model.tickedApps
        let largest = apps.map(batchSize).max() ?? 0
        let open = apps.filter(model.isRunning)
        return VStack(spacing: 0) {
            header {
                Image(systemName: "square.stack.3d.up").font(.largeTitle).foregroundStyle(.tint)
            } text: {
                Text("\(apps.count) Apps Ticked").font(.title2.bold())
                Text("Each app goes to the Trash with the data in your Library that surely belongs to it. Items marked “Possibly related” and config in your home folder are kept: select an app on its own to review them.")
                    .font(.callout).foregroundStyle(.secondary)
                if !open.isEmpty {
                    Text("Open apps are skipped. Quit them to uninstall them too.").font(.callout).foregroundStyle(.orange)
                }
            }
            List {
                ForEach(apps) { app in
                    batchRow(app, largest: largest)
                }
            }
            batchFooter(apps)
        }
    }

    /// App bundle + its `.data` entries; the bundle alone while the data is loading.
    private func batchSize(_ app: InstalledApp) -> Int64 {
        (model.batchData[app.url] ?? []).reduce(model.appSizes[app.url] ?? 0) { $0 + $1.size }
    }

    private func batchRow(_ app: InstalledApp, largest: Int64) -> some View {
        let running = model.isRunning(app)
        let data = model.batchData[app.url]
        let size = model.appSizes[app.url] != nil && data != nil ? batchSize(app) : nil
        return HStack {
            Toggle(isOn: ticked(app.url)) { EmptyView() }
            .toggleStyle(SelectionCheckboxStyle())
            .accessibilityLabel(Text(verbatim: "\(app.name), \(size?.formatted(.fileSize.locale(locale)) ?? "…")"))
            .disabled(model.working)
            AppIcon(url: app.url, size: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).lineLimit(1)
                Group {
                    if running {
                        HStack {
                            Text("Open: it will be skipped").foregroundStyle(.orange)
                            Button("Quit App") { model.quit(app) }.buttonStyle(.link)
                        }
                    } else if let data {
                        Text("App and \(data.count) data items")
                    } else {
                        Text("Looking for its data…")
                    }
                }
                .font(.subheadline).foregroundStyle(.secondary)
            }
            .help(app.url.path)
            Spacer()
            Text(size?.formatted(.fileSize.locale(locale)) ?? "…").sizeColumnStyle(emphasized: !running)
            SizeBar(size: size ?? 0, largest: largest, tint: running ? .secondary : .accentColor)
            Button("Show Files", systemImage: "list.bullet") { model.selection = .app(app.url) }
                .labelStyle(.iconOnly).buttonStyle(.borderless).help("Show Files")
        }
        .padding(.vertical, 3)
    }

    private func batchFooter(_ apps: [InstalledApp]) -> some View {
        // Open apps are skipped: neither counted nor in the size.
        let going = apps.filter { !model.isRunning($0) }
        let size = model.batchSize
        let sizeText = size?.formatted(.fileSize.locale(locale)) ?? "…"
        let open = apps.filter(model.isRunning).map(\.name)
        return HStack {
            Text("Selected: \(going.count) apps, \(sizeText)").monospacedDigit()
            Spacer()
            if model.working { ProgressView().controlSize(.small).accessibilityLabel("Moving to Trash…") }
            Button("Uninstall \(going.count) Apps…") { confirmingBatch = true }
                .keyboardShortcut(.defaultAction)
                .disabled(model.working || size == nil || going.isEmpty)
        }
        .padding()
        .background(.bar)
        .focusedSceneValue(\.confirming, confirmingBatch)
        .confirmationDialog(Text("Uninstall \(going.count) apps (\(sizeText))?"), isPresented: $confirmingBatch) {
            Button("Uninstall", role: .destructive) { Task { await model.removeBatch() } }
        } message: {
            let names = going.map(\.name).formatted(.list(type: .and).locale(locale))
            if open.isEmpty {
                Text("\(names) go to the Trash with their data in your Library. You can put them back from the Trash until it is emptied.")
            } else {
                Text("\(names) go to the Trash with their data in your Library. Open apps are skipped: \(open.formatted(.list(type: .and).locale(locale))). You can put them back from the Trash until it is emptied.")
            }
        }
    }

    /// Read-only list: no checkbox, no footer, nothing here can be removed.
    private var hiddenList: some View {
        // Arrow keys move the highlight, Space opens Quick Look like Large Files; nothing here can be ticked.
        List(model.hiddenItems ?? [], selection: $model.highlighted) { item in
            HStack {
                AppIcon(url: item.url, size: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Text(verbatim: (item.url.path as NSString).abbreviatingWithTildeInPath)
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    // Reasons on one line when they fit, else one per line (never wrapped mid-reason).
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) { reasons(item) }
                        VStack(alignment: .leading, spacing: 0) { reasons(item) }
                    }
                    .font(.subheadline)
                }
                .help(item.url.path)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(model.hiddenSizes[item.url]?.formatted(.fileSize.locale(locale)) ?? "…")
                        .sizeColumnStyle(emphasized: false) // read-only list: nothing here is selected
                    if let modified = item.modified {
                        Text(modified, format: Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale))
                            .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Button("Quick Look", systemImage: "eye") { previewURL = item.url }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).help("Quick Look")
                Button("Reveal in Finder", systemImage: "magnifyingglass") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).help("Reveal in Finder")
            }
            .padding(.vertical, 3)
        }
        .onSpaceKey {
            previewURL = previewURL == nil ? model.hiddenItems?.first { model.highlighted.contains($0.url) }?.url : nil
            return true
        }
        .overlay {
            if model.hiddenItems == nil {
                ProgressView().accessibilityLabel("Loading…")
            } else if model.hiddenItems?.isEmpty == true {
                EmptyStateView(title: Text("No Unknown Items Found"), systemImage: "checkmark.circle")
            }
        }
    }

    /// Like `hiddenList`, plus a checkbox (never pre-ticked) on items that may go to the Trash.
    private var extensionList: some View {
        List(model.extensionItems ?? [], selection: $model.highlighted) { item in
            HStack {
                Toggle(isOn: checked(item.url)) {
                    Text(verbatim: "\(item.name), \(model.extensionSizes[item.url]?.formatted(.fileSize.locale(locale)) ?? "…")")
                }
                .labelsHidden()
                .toggleStyle(SelectionCheckboxStyle())
                .disabled(!item.trashable || model.isInUse(item) || model.working)
                AppIcon(url: item.url, size: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 6) {
                        Text(kindName(item.kind)).foregroundStyle(.secondary).fixedSize()
                        if let owner = item.owner {
                            Text(verbatim: "·").foregroundStyle(.secondary).fixedSize()
                            Text(verbatim: owner).foregroundStyle(.secondary).lineLimit(1)
                        } else if item.appRemoved {
                            Text(verbatim: "·").foregroundStyle(.secondary).fixedSize()
                            Text("App removed").foregroundStyle(.orange).fixedSize()
                        }
                    }
                    .font(.subheadline)
                }
                .help(item.url.path)
                // The text column gets the width before the size/date column, else VI "Bảng tuỳ chọn" wrapped
                // next to "Ứng dụng đã gỡ"; the size/date column is fixed so it never truncates instead.
                .layoutPriority(1)
                Spacer()
                if item.trashable && model.isInUse(item) {
                    Text("Close System Settings to move").font(.subheadline).foregroundStyle(.orange)
                    Button("Quit System Settings") { model.quitSystemSettings() }.controlSize(.small)
                }
                VStack(alignment: .trailing, spacing: 2) {
                    Text(model.extensionSizes[item.url]?.formatted(.fileSize.locale(locale)) ?? "…")
                        .sizeColumnStyle(emphasized: model.checked.contains(item.url))
                    if let modified = item.modified {
                        Text(modified, format: Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale))
                            .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .fixedSize()
                Button("Quick Look", systemImage: "eye") { previewURL = item.url }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).help("Quick Look")
                Button("Reveal in Finder", systemImage: "magnifyingglass") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).help("Reveal in Finder")
            }
            .padding(.vertical, 3)
            .selectionRow(isOn: model.checked.contains(item.url),
                          enabled: item.trashable && !model.isInUse(item) && !model.working,
                          highlight: { model.highlighted = [item.url] }) {
                checked(item.url).wrappedValue.toggle()
            }
        }
        .spaceToggles(model)
        .overlay {
            if model.extensionItems == nil {
                ProgressView().accessibilityLabel("Loading…")
            } else if model.extensionItems?.isEmpty == true {
                EmptyStateView(title: Text("No Extensions Found"), systemImage: "checkmark.circle")
            }
        }
    }

    private func kindName(_ kind: ExtensionItem.Kind) -> LocalizedStringKey {
        switch kind {
        case .preferencePane: "Preference Pane"
        case .quickLook: "Quick Look Plug-in"
        case .service: "Service"
        case .screenSaver: "Screen Saver"
        case .inputMethod: "Input Method"
        case .internetPlugin: "Internet Plug-in"
        case .spotlight: "Spotlight Importer"
        }
    }

    @ViewBuilder private func reasons(_ item: HiddenConfigItem) -> some View {
        Text("Not recognized").fixedSize()
        if item.hasExecutable { Text("Contains a program or script").foregroundStyle(.orange).fixedSize() }
        if item.isRecent { Text("Changed in the last \(HiddenConfig.recentDays) days").foregroundStyle(.orange).fixedSize() }
    }

    private func header<Icon: View, Content: View>(@ViewBuilder icon: () -> Icon, @ViewBuilder text: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            icon()
            VStack(alignment: .leading, spacing: 4) { text() }
            Spacer()
        }
        .padding()
    }

    private func entryList(app: InstalledApp? = nil, empty: Text) -> some View {
        // Bars compare against the largest item in this list, the app bundle included.
        let largest = max(app.flatMap { model.appSizes[$0.url] } ?? 0, model.entries.lazy.compactMap(\.size).max() ?? 0)
        // Arrow keys move the row highlight, Space ticks/unticks it (like Smart Scan); checkboxes still take clicks.
        return List(selection: $model.highlighted) {
            if let app {
                // Unticked: reset, only the ticked data goes and the app stays.
                row(url: app.url, folder: Text("Application"), size: model.appSizes[app.url], checked: model.trashApp, largest: largest,
                    isOn: $model.trashApp, enabled: !model.working)
                .tag(app.url)
            }
            ForEach(model.entries) { entry in
                row(url: entry.url, folder: location(entry), size: entry.size,
                    checked: model.checked.contains(entry.url), largest: largest, isOn: checked(entry.url))
                .tag(entry.url)
            }
        }
        .spaceToggles(model)
        .overlay {
            if model.loadingEntries {
                ProgressView().accessibilityLabel("Loading…")
            } else if model.entries.isEmpty && app == nil {
                EmptyStateView(title: empty, systemImage: "checkmark.circle")
            }
        }
    }

    /// The entry's folder (`~/.config`, `~/.local/share`, `~` for config), and whether it is only a suggestion.
    private func location(_ entry: AppDataEntry) -> Text {
        entry.orphan ? Text("\(entry.location) · No app with this name is installed")
            : entry.kind == .suggested ? Text("\(entry.location) · Possibly related") : Text(verbatim: entry.location)
    }

    /// The checkbox's (hidden) label is item name + size, so VoiceOver reads both on the checkbox.
    /// A click anywhere on the row ticks it, like Smart Scan.
    private func row(url: URL, folder: Text, size: Int64?, checked: Bool, largest: Int64,
                     isOn: Binding<Bool>, enabled: Bool = true) -> some View {
        HStack {
            Toggle(isOn: isOn) {
                Text(verbatim: "\(url.lastPathComponent), \(size?.formatted(.fileSize.locale(locale)) ?? "…")")
            }
            .labelsHidden()
            .toggleStyle(SelectionCheckboxStyle())
            .disabled(!enabled)
            AppIcon(url: url, size: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                folder.font(.subheadline).foregroundStyle(.secondary)
            }
            .help(url.path)
            Spacer()
            Text(size?.formatted(.fileSize.locale(locale)) ?? "…").sizeColumnStyle(emphasized: checked)
            SizeBar(size: size ?? 0, largest: largest, tint: checked ? .accentColor : .secondary)
            Button("Reveal in Finder", systemImage: "magnifyingglass") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
        }
        .padding(.vertical, 3)
        .selectionRow(isOn: checked, enabled: enabled, highlight: { model.highlighted = [url] }) { isOn.wrappedValue.toggle() }
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Show in Space Lens") { ModuleRouter.shared.spaceLensItem = url }
        }
    }

    private func footer(button: Text, app: InstalledApp? = nil) -> some View {
        let count = model.checkedEntries.count
        let size = model.checkedSize.formatted(.fileSize.locale(locale))
        let uninstalling = app != nil && model.trashApp
        return HStack {
            // A ticked app row is in `size` too, so count it.
            Text("Selected: \(count + (uninstalling ? 1 : 0)) items, \(size)").monospacedDigit()
            Spacer()
            if model.working { ProgressView().controlSize(.small).accessibilityLabel("Moving to Trash…") }
            Button { confirming = true } label: { button }
                .keyboardShortcut(.defaultAction)
                .disabled(model.working || model.loadingEntries
                          || app.map(model.isRunning) == true || (!uninstalling && count == 0))
        }
        .padding()
        .background(.bar)
        .focusedSceneValue(\.confirming, confirming)
        .confirmationDialog(
            app.map { app in
                uninstalling ? Text("Move \(app.name) and \(count) related items (\(size)) to the Trash?")
                    : Text("Move \(count) data items (\(size)) of \(app.name) to the Trash and keep the app?")
            } ?? Text("Move \(count) items (\(size)) to the Trash?"),
            isPresented: $confirming
        ) {
            Button(role: .destructive) { Task { await model.remove() } } label: {
                if app == nil { Text("Move to Trash") } else if uninstalling { Text("Uninstall") } else { Text("Reset") }
            }
        } message: {
            Text("You can put them back from the Trash until it is emptied.")
        }
    }

    private func checked(_ url: URL) -> Binding<Bool> {
        Binding(
            get: { model.checked.contains(url) },
            set: { if $0 { model.checked.insert(url) } else { model.checked.remove(url) } })
    }
}

private extension View {
    func spaceToggles(_ model: UninstallerModel) -> some View {
        onSpaceKey {
            guard !model.highlighted.isEmpty else { return false }
            model.toggle(urls: model.highlighted)
            return true
        }
    }
}

private struct AppIcon: View {
    let url: URL
    let size: CGFloat

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .frame(width: size, height: size)
            .accessibilityHidden(true) // the name beside it is read instead
    }
}
