import QuickLook
import SwiftUI

/// Duplicates › Duplicate Files: groups of identical files found by their own search of the scope, each with the copy
/// suggested to keep first. Nothing is ticked for the user; ticked files go to the Trash.
struct DuplicatesView<Listing: View>: View {
    @ObservedObject var model: DuplicatesModel
    /// Where the files were looked for, e.g. "~/Downloads"; nil = the home folder.
    let scopeName: String?
    /// Folders macOS protects (Desktop, Documents, Pictures…) are left out: no Full Disk Access.
    var skipsProtected = false
    @Binding var confirming: Bool
    /// The Duplicates menu, kept in the toolbar so the user can go back to the file list.
    @ViewBuilder let listingMenu: () -> Listing
    @State private var previewURL: URL?
    /// The List's selected rows: Space, Open and Reveal act on them; ticking is the checkboxes.
    @State private var highlighted: Set<URL> = []
    @State private var excludedCount = 0

    var body: some View {
        Group {
            switch model.phase {
            case .idle:
                if let error = model.error {
                    EmptyStateView(title: Text("Couldn’t Finish Finding Duplicates"), systemImage: "exclamationmark.triangle") {
                        Text(verbatim: error)
                    } actions: {
                        Button("Try Again") { model.findAgain() }.buttonStyle(.borderedProminent)
                    }
                } else {
                    EmptyStateView(title: Text("Duplicate Files"), systemImage: "doc.on.doc") {
                        Text("Find files with the same content anywhere in the scope, and keep one copy. Nothing is selected for you.")
                    } actions: {
                        Button("Find Duplicates") { model.findAgain() }.buttonStyle(.borderedProminent)
                    }
                }
            case .listing:
                VStack(spacing: 12) {
                    ProgressView { Text("Looking for files…") }
                    Text("Files checked: \(model.listed)").foregroundStyle(.secondary).monospacedDigit()
                    Button("Stop") { model.stop() }
                }
            case .comparing:
                VStack(spacing: 12) {
                    ProgressView(value: model.progress.fraction) { Text("Comparing files…") }.frame(maxWidth: 320)
                    Text("\(model.progress.done, format: .fileSize) of \(model.progress.total, format: .fileSize)")
                        .foregroundStyle(.secondary).monospacedDigit()
                    Text("Only files of the same size are compared.").foregroundStyle(.secondary)
                    Button(model.stopping ? "Stopping…" : "Stop") { model.stop() }.disabled(model.stopping)
                }
            case .trashing:
                TrashProgress(stopping: model.stoppingTrash) { model.stopTrash() }
            case .results:
                if model.groups.isEmpty {
                    EmptyStateView(title: Text("No Duplicate Files"), systemImage: "doc.on.doc") {
                        if let scopeName {
                            Text("No two files of \(model.minSize, format: .fileSize) or more in \(scopeName) have the same content.")
                        } else {
                            Text("No two files of \(model.minSize, format: .fileSize) or more in your home folder have the same content.")
                        }
                        if model.stopped { StoppedNote() }
                    } actions: {
                        Button("Find Again") { model.findAgain() }
                    }
                } else {
                    results
                }
            case .done(let report):
                EmptyStateView(title: Text("Moved \(model.lastFreed, format: .fileSize) to the Trash"), systemImage: "checkmark.circle") {
                    StoppedTrashSummary(report: report)
                    if report.freed > 0 { TrashSpaceSummary() }
                    NotCleanedSummary(report: report)
                    if let result = report.undo { UndoTrashResult(result: result) }
                } actions: {
                    Button("Find Again") { model.findAgain() }.disabled(model.undoing)
                    TrashReportButtons(report: report) { await model.undoTrash() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top, spacing: 0) {
            if skipsProtected && showsAccessNote { ProtectedFoldersNote() }
        }
        .toolbar {
            Picker("Size", selection: $model.minSize) {
                ForEach(DuplicateScanner.sizeOptions, id: \.self) { size in
                    Text("At least \(size, format: .fileSize)").tag(size)
                }
            }
            .disabled(model.isChanging)
            listingMenu()
        }
        .trashUndo(model)
    }

    /// The waiting and empty screens explain what was left out.
    private var showsAccessNote: Bool {
        switch model.phase {
        case .idle: true
        case .results: model.groups.isEmpty
        default: false
        }
    }

    private var results: some View {
        let groups = model.shownGroups
        let largest = groups.lazy.flatMap(\.files).map(\.size).max() ?? 0
        let urls = groups.flatMap { $0.files.map(\.url) }
        return List(selection: $highlighted) {
            ForEach(groups) { group in
                Section {
                    ForEach(group.files) { file in
                        row(file, in: group, largest: largest)
                    }
                } header: {
                    groupHeader(group)
                }
            }
        }
        .contextMenu(forSelectionType: URL.self) { selected in
            Button("Open") { FileOpener.open(urls.filter(selected.contains)) }.disabled(selected.count > FileOpener.limit)
            Button("Quick Look") { previewURL = urls.first(where: selected.contains) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls.filter(selected.contains)) }
            if selected.contains(where: Preferences.canExclude) {
                Divider()
                Button("Never Clean This") {
                    if model.neverClean(selected) { highlighted.subtract(selected); excludedCount += 1 }
                }
            }
        } primaryAction: { selected in
            FileOpener.open(urls.filter(selected.contains)) // double-click or Return, like Finder
        }
        .onSpaceKey {
            previewURL = previewURL == nil ? urls.first(where: highlighted.contains) : nil
            return true
        }
        .onSelectAllKeys { on in
            if on { model.checkAllButSuggested() } else { model.uncheckAll() }
            return true
        }
        .onFindKey { focusToolbarSearch(in: $0) }
        .quickLookPreview($previewURL, in: urls)
        .exclusionNotice(excludedCount)
        .overlay {
            if groups.isEmpty {
                EmptyStateView(title: Text("No Matching Files"), systemImage: "magnifyingglass")
            }
        }
        .searchable(text: $model.search, placement: .toolbar, prompt: Text("Search Files"))
        .safeAreaInset(edge: .top) {
            if model.stopped {
                StoppedNote()
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("Selected: \(model.checkedFiles.count) files, \(model.checkedSize, format: .fileSize)")
                    .monospacedDigit()
                Spacer()
                // Never "Select All": it would tick the copy to keep too.
                let anyOn = !model.checkedFiles.isEmpty
                Button(anyOn ? "Deselect All" : "Select All but Suggested") {
                    if anyOn { model.uncheckAll() } else { model.checkAllButSuggested() }
                }
                .accessibilityHint(Text("Keeps the suggested copy of each group"))
                Button("Find Again") { model.findAgain() }
                Button("Move to Trash…") { confirming = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.checkedFiles.isEmpty)
            }
            .padding()
            .background(.bar)
        }
        .focusedSceneValue(\.confirming, confirming)
        .confirmationDialog(
            Text("Move \(model.checkedFiles.count) files (\(model.checkedSize, format: .fileSize)) to the Trash?"),
            isPresented: $confirming
        ) {
            Button("Move to Trash", role: .destructive) { Task { await model.trash() } }
        } message: {
            let lost = model.groupsLosingEveryCopy
            if lost.isEmpty {
                Text("You can put them back from the Trash until it is emptied.")
            } else {
                Text("Every copy is selected: no copy of \(lost, format: .list(type: .and)) will be left. You can put them back from the Trash until it is emptied.")
            }
        }
    }

    private func groupHeader(_ group: DuplicateScanner.Group) -> some View {
        let urls = group.files.map(\.url)
        let set = { (on: Bool) in if on { model.checked.formUnion(urls) } else { model.checked.subtract(urls) } }
        // Two sources: mixed while some but not all are ticked.
        let sources = [Binding { urls.contains { model.checked.contains($0) } } set: { set($0) },
                       Binding { urls.allSatisfy { model.checked.contains($0) } } set: { set($0) }]
        return HStack(spacing: 8) {
            Toggle(sources: sources, isOn: \.self) { EmptyView() }
                .toggleStyle(SelectionCheckboxStyle())
                .accessibilityLabel(Text("\(group.files.count) copies"))
            Text("\(group.files.count) copies")
            Spacer()
            Text("Extra copies: \(group.extraSize, format: .fileSize)").foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func row(_ file: LargeFile, in group: DuplicateScanner.Group, largest: Int64) -> some View {
        let isOn = model.checked.contains(file.url)
        let freed = group.freed(file)
        return HStack(spacing: 10) {
            Toggle(isOn: checked(file.url)) { EmptyView() }
                .toggleStyle(SelectionCheckboxStyle())
                .accessibilityLabel(Text(verbatim: file.name))
            Image(nsImage: LargeFilesView.icon(forExtension: file.url.pathExtension))
                .resizable()
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: file.name).lineLimit(1).truncationMode(.middle).help(file.url.path)
                    if file.url == group.suggested.url {
                        Text("Suggested to keep")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                            .fixedSize()
                            .help("Suggested: a copy outside Downloads, then the oldest. Nothing is selected for you.")
                    }
                }
                HStack(spacing: 6) {
                    Text(file.modified, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
                    Text(verbatim: file.location).lineLimit(1).truncationMode(.middle)
                }
                .font(.caption).foregroundStyle(.secondary)
                if file.hardLinked {
                    Text("Hard link — moving it frees no space").font(.caption).foregroundStyle(.secondary)
                } else if freed < file.size {
                    Group {
                        if freed == 0 {
                            Text("APFS clone — moving it frees no space")
                        } else {
                            Text("APFS clone — moving it frees only \(freed, format: .fileSize)")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(file.size, format: .fileSize).sizeColumnStyle(emphasized: isOn)
            SizeBar(size: file.size, largest: largest)
            QuickLookButton(url: file.url, preview: $previewURL)
        }
        .padding(.vertical, 2)
        .selectionRow(isOn: isOn, highlight: { highlighted = [file.url] }) {
            if isOn { model.checked.remove(file.url) } else { model.checked.insert(file.url) }
        }
        .tag(file.url)
    }

    private func checked(_ url: URL) -> Binding<Bool> {
        Binding(get: { model.checked.contains(url) }, set: { if $0 { model.checked.insert(url) } else { model.checked.remove(url) } })
    }
}

/// Shown when the search was stopped while comparing: the groups found until then, not all of them.
private struct StoppedNote: View {
    var body: some View {
        Label {
            Text("Stopped: only the duplicates found before you stopped are shown. Find Again to compare every file.")
        } icon: {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
        }
        .font(.callout)
    }
}
