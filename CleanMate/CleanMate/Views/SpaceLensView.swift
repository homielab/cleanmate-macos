import Charts
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Space Lens: browse a folder's children by size, drill into folders, move picked items to the Trash.
struct SpaceLensView: View {
    @ObservedObject var model: SpaceLensModel
    @State private var sortOrder = [KeyPathComparator(\SpaceItem.sortSize, order: .reverse)]
    @State private var selection: Set<URL> = []
    /// Selected URLs the policy allows, checked off the main thread once per selection change (a folder on an external
    /// drive is walked), not per render; `model.trash` re-checks each item.
    @State private var allowed: Set<URL> = []
    @State private var choosingFolder = false
    /// Folders chosen with "Choose Folder…", newest first, one path per line.
    @AppStorage(Preferences.spaceLensRecentFolders) private var recentFolders = ""
    @State private var confirming = false
    @State private var excludedCount = 0
    @State private var previewURL: URL?
    /// The id, not the slice: sizes keep arriving while measuring, and a stored slice would go stale.
    @State private var hovered: SpaceLens.Slice.ID?

    var body: some View {
        VStack(spacing: 0) {
            overview
            Divider()
            if model.skippedProtected {
                ProtectedFoldersNote()
                Divider()
            }
            table
        }
        .navigationTitle(Text(Module.spaceLens.title))
        .focusedSceneValue(\.moveToTrash, moveToTrash)
        .task { model.startIfNeeded() }
        .trashUndo(model)
        .onChange(of: model.current) { _ in selection = [] }
        .onAppearAndChange(of: model.items.count) { _ in // count only: sizes update items often
            selection = model.pruned(selection)
            if let url = model.revealed, let item = model.items.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                selection = [item.url]
                model.revealed = nil
            }
        }
        .onChange(of: model.search) { _ in selection = model.pruned(selection) }
        .searchable(text: $model.search, placement: .toolbar, prompt: Text("Search Items"))
        .task(id: selection) {
            allowed.formIntersection(selection) // until checked, nothing newly picked is movable
            let checked = await SpaceLens.allowed(selection)
            if !Task.isCancelled { allowed = checked }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { model.go(to: model.path.count - 1) } label: { Label("Back", systemImage: "chevron.left") }
                    .disabled(model.path.isEmpty)
                    .keyboardShortcut("[", modifiers: .command)
            }
            ToolbarItem {
                Menu {
                    Button("Home") { model.start(at: SafetyPolicy.current.homeURL) }
                    ForEach(volumes, id: \.self) { url in
                        Button(FileManager.default.displayName(atPath: url.path)) { model.start(at: url) }
                    }
                    let recent = Preferences.recentFolders(recentFolders)
                    if !recent.isEmpty {
                        Section("Recent") {
                            ForEach(recent, id: \.self) { path in
                                Button((path as NSString).abbreviatingWithTildeInPath) { model.start(at: URL(filePath: path)) }
                            }
                        }
                    }
                    Divider()
                    Button("Choose Folder…") { choosingFolder = true }
                } label: {
                    Label("Location", systemImage: "folder")
                }
            }
            ToolbarItem {
                Button { model.rescan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .disabled(model.trashing)
            }
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            model.start(at: url)
            recentFolders = Preferences.addingRecentFolder(url.standardizedFileURL.path, to: recentFolders)
        }
    }

    private var volumes: [URL] {
        FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
    }

    // MARK: Disk overview and breadcrumb

    private var overview: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                VolumeGauge(volume: model.volume)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(model.breadcrumb.enumerated()), id: \.offset) { index, url in
                            if index > 0 { Image(systemName: "chevron.right").foregroundStyle(.tertiary).imageScale(.small).accessibilityHidden(true) }
                            let crumb = Label {
                                Text(FileManager.default.displayName(atPath: url.path))
                            } icon: {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
                            }
                            // Current folder: plain primary text, not a disabled (faded) button; parents: secondary links.
                            Group {
                                if index == model.path.count {
                                    crumb.foregroundStyle(.primary)
                                } else {
                                    Button { model.go(to: index) } label: { crumb }
                                        .buttonStyle(.borderless)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .help(url.path)
                        }
                    }
                }
            }
            donut
        }
        .padding()
    }

    // MARK: Donut

    /// One color per own slice: up to `SpaceLens.top + 1` (when the ninth item is shown instead of "Other").
    static let colors: [Color] = [.blue, .purple, .pink, .orange, .yellow, .green, .teal, .indigo, .mint]

    /// Share of each child at a glance; clicking a folder slice drills in like double-clicking its row.
    /// Hidden from VoiceOver: the table's Share column reads the same numbers.
    @ViewBuilder private var donut: some View {
        let slices = SpaceLens.slices(model.items)
        if !slices.isEmpty {
            if #available(macOS 14, *) {
                donutChart(slices)
            } else {
                shareBar(slices)
            }
        }
    }

    @available(macOS 14, *)
    private func donutChart(_ slices: [SpaceLens.Slice]) -> some View {
        let colors = Self.sliceColors(slices)
        let active = slices.first { $0.id == hovered }
        return Chart(slices) { slice in
            SectorMark(angle: .value("Size", slice.size), innerRadius: .ratio(0.6), angularInset: 1)
                .foregroundStyle(slice.item.flatMap { colors[$0.url] } ?? Color.gray)
                .opacity(active == nil || active == slice ? 1 : 0.4)
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                let frame = proxy.plotFrame.map { geometry[$0] } ?? geometry.frame(in: .local)
                sliceHitArea(slices) { SpaceLens.slice(at: $0, in: frame, of: slices) }
            }
        }
        .overlay {
            if let hovered = active {
                hoveredLabel(hovered)
                    .frame(width: 70)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: 120, height: 120)
        .accessibilityHidden(true)
    }

    /// macOS 13 has no donut mark: the same slices, colors, hover and clicks as one stacked bar.
    private func shareBar(_ slices: [SpaceLens.Slice]) -> some View {
        let colors = Self.sliceColors(slices)
        let active = slices.first { $0.id == hovered }
        return VStack(spacing: 4) {
            Chart(slices) { slice in
                BarMark(x: .value("Size", slice.size))
                    .foregroundStyle(slice.item.flatMap { colors[$0.url] } ?? Color.gray)
                    .opacity(active == nil || active == slice ? 1 : 0.4)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .overlay {
                GeometryReader { geometry in
                    sliceHitArea(slices) { SpaceLens.slice(atFraction: $0.x / max(geometry.size.width, 1), of: slices) }
                }
            }
            .frame(height: 16)
            // Kept in the layout while nothing is hovered, so the bar does not jump.
            hoveredLabel(active ?? slices[0]).opacity(active == nil ? 0 : 1)
        }
        .frame(width: 200)
        .accessibilityHidden(true)
    }

    /// Hover highlights the slice under the pointer; a click on a folder slice opens it.
    private func sliceHitArea(_ slices: [SpaceLens.Slice], at slice: @escaping (CGPoint) -> SpaceLens.Slice?) -> some View {
        Rectangle().fill(.clear).contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let point) = phase { hovered = slice(point)?.id } else { hovered = nil }
            }
            .onTapGesture { point in
                if let item = slice(point)?.item, item.isFolder, !item.isProtected {
                    hovered = nil
                    model.open(item.url)
                }
            }
    }

    private func hoveredLabel(_ slice: SpaceLens.Slice) -> some View {
        VStack(spacing: 0) {
            Text(slice.item.map { $0.name } ?? String(localized: "Other")).lineLimit(1).truncationMode(.middle)
            Text(slice.size, format: .fileSize).monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    /// The donut color of each item drawn as its own slice; everything else is gray like "Other".
    private static func sliceColors(_ slices: [SpaceLens.Slice]) -> [URL: Color] {
        Dictionary(slices.enumerated().compactMap { index, slice in
            slice.item.map { ($0.url, colors[index % colors.count]) }
        }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: Children

    private var table: some View {
        let items = model.shown.sorted(using: sortOrder)
        let total = model.total
        let colors = Self.sliceColors(SpaceLens.slices(model.items))
        return Table(items, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { item in
                Label {
                    Text(item.name).help(item.url.path)
                } icon: {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().frame(width: 20, height: 20)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 3)
            }
            TableColumn("Size", value: \.sortSize) { item in
                if let size = item.size {
                    Text(size, format: .fileSize).sizeColumnStyle(emphasized: true)
                } else if item.isProtected {
                    Image(systemName: "lock").foregroundStyle(.secondary)
                        .accessibilityLabel("Not measured")
                        .help("Not measured: macOS asks before CleanMate can look inside without Full Disk Access.")
                } else if model.measuring {
                    ProgressView().controlSize(.small).accessibilityLabel("Measuring…")
                } else {
                    Text(verbatim: "—").foregroundStyle(.secondary)
                }
            }
            .width(min: 70, ideal: 90)
            TableColumn("Share") { item in
                let fraction = total > 0 ? Double(item.size ?? 0) / Double(total) : 0
                HStack {
                    // Same color as its donut slice; drawn by hand because Table cells ignore a ProgressView's tint.
                    Capsule().fill(.quaternary)
                        .overlay(alignment: .leading) {
                            GeometryReader { bar in
                                Capsule().fill(colors[item.url] ?? .gray).frame(width: bar.size.width * fraction)
                            }
                        }
                        .frame(height: 6)
                        .accessibilityHidden(true) // the percent text beside it is read instead
                    Text(fraction, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                        .foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                }
            }
            .width(min: 120, ideal: 180)
        }
        .contextMenu(forSelectionType: URL.self) { urls in
            if urls.count == 1, let item = items.first(where: { urls.contains($0.url) }), item.isFolder, !item.isProtected {
                Button("Open") { model.open(item.url) }
            }
            Button("Quick Look") { previewURL = urls.first }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(Array(urls)) }
            Button("Move to Trash…") {
                selection = urls
                Task {
                    let checked = await SpaceLens.allowed(urls)
                    guard selection == urls else { return } // picked something else meanwhile
                    allowed = checked
                    confirming = !checked.isEmpty
                }
            }
            .disabled(!canTrash(urls) || model.trashing || model.measuring)
            if urls.contains(where: Preferences.canExclude) {
                Divider()
                // Stays listed, but Move to Trash now refuses it like any excluded item.
                Button("Never Clean This") {
                    if model.neverClean(urls) {
                        let picked = selection
                        Task {
                            let checked = await SpaceLens.allowed(picked)
                            if selection == picked { allowed = checked }
                        }
                        excludedCount += 1
                    }
                }
            }
        } primaryAction: { urls in
            if urls.count == 1, let item = items.first(where: { urls.contains($0.url) }), item.isFolder, !item.isProtected {
                model.open(item.url)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting(Array(urls))
            }
        }
        .onSpaceKey {
            previewURL = previewURL == nil ? items.first { selection.contains($0.url) }?.url : nil
            return true
        }
        .quickLookPreview($previewURL, in: items.map(\.url))
        .exclusionNotice(excludedCount)
        .overlay {
            if model.items.isEmpty && !model.measuring {
                EmptyStateView(title: Text("Empty or Not Readable"), systemImage: "folder")
            } else if items.isEmpty && !model.items.isEmpty {
                EmptyStateView(title: Text("No Matching Items"), systemImage: "magnifyingglass")
            }
        }
        .safeAreaInset(edge: .bottom) { bottomBar(items) }
        .focusedSceneValue(\.confirming, confirming)
        .confirmationDialog(
            Text(SpaceLensModel.trashTitle(trashable(in: items))),
            isPresented: $confirming
        ) {
            Button("Move to Trash", role: .destructive) {
                let picked = trashable(in: items)
                guard !picked.isEmpty else { return }
                Task {
                    await model.trash(picked)
                    selection = model.pruned(selection)
                }
            }
        } message: {
            Text("You can put them back from the Trash until it is emptied.")
        }
    }

    private func bottomBar(_ items: [SpaceItem]) -> some View {
        HStack {
            Text("Total: \(model.total, format: .fileSize)").monospacedDigit()
            if model.measuring {
                ProgressView().controlSize(.small).accessibilityLabel("Measuring…")
                Button("Stop") { model.cancel() }
            } else if model.undoing {
                ProgressView("Putting back…").controlSize(.small)
            } else if model.trashing {
                ProgressView("Moving to Trash…").controlSize(.small)
            } else if let report = model.report {
                // One line per note: side by side they wrapped to 3 lines and cut the Move button in VI.
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Moved \(report.freed, format: .fileSize) to the Trash").foregroundStyle(.secondary)
                        TrashReportButtons(report: report) { await model.undoTrash() }.buttonStyle(.link)
                    }
                    Group {
                        if report.skipped > 0 { Text("Skipped (in use or not permitted): \(report.skipped)") }
                        if report.locked > 0 { Text("Locked in Finder (turn off Locked in Get Info): \(report.locked)") }
                        if let result = report.undo { UndoTrashResult(result: result) }
                    }.foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Move to Trash…") { confirming = !allowed.isEmpty }
                .fixedSize()
                .disabled(allowed.isEmpty || model.trashing || model.measuring) // same as ⌘⌫
                .help("Only items inside your home folder or on a writable external drive can be moved to the Trash — not ~/Library, hidden items or the home's top-level folders. On an external drive, a folder moves only when it holds no hidden items, packages or links.")
        }
        .padding()
        .background(.bar)
    }

    /// File › Move to Trash… (⌘⌫): opens the same confirmation as the button; nil (disabled) with nothing trashable selected or while busy.
    private var moveToTrash: (() -> Void)? {
        allowed.isEmpty || model.trashing || model.measuring ? nil : { confirming = true }
    }

    /// Selected items the Space Lens policy lets the user move to the Trash (no disk reads: uses `allowed`).
    private func trashable(in items: [SpaceItem]) -> [SpaceItem] {
        items.filter { allowed.contains($0.url) && selection.contains($0.url) }
    }

    /// Context menu rows: the selection uses the cache; a right-clicked unselected row is one check, stopping at the
    /// first allowed, without walking an external folder (the menu item checks it fully before confirming).
    private func canTrash(_ urls: Set<URL>) -> Bool {
        if urls == selection { return !allowed.isEmpty }
        let policy = SafetyPolicy.current
        return urls.contains { policy.allowsSpaceLensItem($0, deep: false) }
    }
}
