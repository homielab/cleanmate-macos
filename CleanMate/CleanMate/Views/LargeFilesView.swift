import QuickLook
import SwiftUI
import UniformTypeIdentifiers

extension FileKind {
    var title: LocalizedStringResource {
        switch self {
        case .video: "Videos"
        case .archive: "Archives"
        case .diskImage: "Disk Images"
        case .installer: "Installers"
        case .other: "Other"
        }
    }

    /// Name for one file in the Kind column; `title` (plural) stays for the filter.
    var singularTitle: LocalizedStringResource {
        switch self {
        case .video: "Video"
        case .archive: "Archive"
        case .diskImage: "Disk Image"
        case .installer: "Installer"
        case .other: "Other"
        }
    }
}

/// Large & Old Files: sortable table of big files in the home folder; ticked files go to the Trash.
struct LargeFilesView: View {
    @ObservedObject var model: LargeFilesModel
    @State private var sortOrder = [KeyPathComparator(\LargeFile.size, order: .reverse)]
    @State private var selection: Set<URL> = []
    @State private var previewURL: URL?
    @State private var confirming = false
    @State private var excludedCount = 0
    @State private var choosingFolder = false
    @State private var unsupportedFolder = false
    /// Folders chosen with "Choose Folder…", newest first, one path per line.
    @AppStorage(Preferences.largeFilesRecentFolders) private var recentFolders = ""
    /// The scope, kept across launches; empty = the whole home folder.
    @AppStorage(Preferences.largeFilesScope) private var savedScope = ""

    var body: some View {
        Group {
            switch model.phase {
            case .idle:
                EmptyStateView(title: Text(Module.largeFiles.title), systemImage: Module.largeFiles.systemImage) {
                    Text("Find big files in your home folder that you may have forgotten. Nothing is selected for you, and selected files go to the Trash.")
                } actions: {
                    Button("Scan") { model.scan() }.buttonStyle(.borderedProminent)
                }
            case .scanning:
                VStack(spacing: 12) {
                    if let fraction = model.scanFraction {
                        ProgressView(value: fraction) { scanningTitle }.frame(maxWidth: 320)
                    } else {
                        ProgressView { scanningTitle }
                    }
                    Text("Files checked: \(model.scannedCount)").foregroundStyle(.secondary).monospacedDigit()
                    Button("Stop") { model.cancel() }
                }
            case .trashing:
                ProgressView("Moving to Trash…")
            case .results:
                results
            case .done(let report):
                EmptyStateView(title: Text("Moved \(report.freed, format: .fileSize) to the Trash"), systemImage: "checkmark.circle") {
                    Text("Empty the Trash to free the space.")
                    if report.skipped > 0 {
                        Text("Skipped (in use or not permitted): \(report.skipped)")
                    }
                    if report.locked > 0 {
                        Text("Locked in Finder (turn off Locked in Get Info): \(report.locked)")
                    }
                    if let result = report.undo { UndoTrashResult(result: result) }
                } actions: {
                    Button("Scan Again") { model.scan() }.disabled(model.undoing)
                    TrashReportButtons(report: report) { await model.undoTrash() }
                }
            }
        }
        .navigationTitle(Text(Module.largeFiles.title))
        .navigationSubtitle(model.scopeName ?? "")
        .toolbar {
            // One icon-only item: the toolbar already overflows at 720 px.
            ToolbarItem(placement: .navigation) { scopeMenu }
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            if model.setScope(url) {
                recentFolders = Preferences.addingRecentFolder(LargeFilesModel.folder(url.path).path, to: recentFolders)
            } else {
                unsupportedFolder = true
            }
        }
        .alert("This Folder Can’t Be Scanned", isPresented: $unsupportedFolder) {
        } message: {
            Text("Choose a folder inside your home folder (outside Library and hidden folders) or on an external drive.")
        }
        .focusedSceneValue(\.moveToTrash, moveToTrash)
        .trashUndo(model)
        .onAppear { model.restoreScope(savedScope) }
        .onChange(of: model.scope) { scope in savedScope = scope?.path ?? "" }
    }

    private var scanningTitle: Text {
        if let name = model.scopeName { Text("Scanning \(name)…") } else { Text("Scanning your home folder…") }
    }

    /// Scope: the whole home, a few home folders, external drives, recently chosen folders, or "Choose Folder…".
    private var scopeMenu: some View {
        let presets = LargeFilesModel.scopePresets.map { model.home.appending(path: $0).path }
        let volumes = LargeFilesModel.externalVolumes()
        let recent = Preferences.recentFolders(recentFolders).filter { path in
            !presets.contains(path) && path != model.home.path
                && !volumes.contains { $0.path == LargeFilesModel.folder(path).path }
        }
        return Menu {
            Picker(selection: Binding(get: { model.scope }, set: { model.setScope($0) })) {
                Text("Home Folder").tag(URL?.none)
                ForEach(presets, id: \.self) { path in
                    Text(FileManager.default.displayName(atPath: path)).tag(URL?.some(LargeFilesModel.folder(path)))
                }
                if !volumes.isEmpty {
                    Divider()
                    ForEach(volumes, id: \.self) { volume in
                        Text(verbatim: FileManager.default.displayName(atPath: volume.path)).tag(URL?.some(volume))
                    }
                }
                if !recent.isEmpty {
                    Divider()
                    ForEach(recent, id: \.self) { path in
                        Text(verbatim: LargeFile.displayLocation(of: URL(filePath: path).appending(path: "_"), home: model.home))
                            .tag(URL?.some(LargeFilesModel.folder(path)))
                    }
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
            Divider()
            Button("Choose Folder…") { choosingFolder = true }
        } label: {
            Label("Scope", systemImage: model.scope == nil ? "house" : model.scope!.path.hasPrefix("/Volumes/") ? "externaldrive" : "folder")
        }
        .help(Text("Scope: \(model.scopeName ?? String(localized: "Home Folder"))"))
        .disabled(model.undoing || { if case .trashing = model.phase { true } else { false } }())
    }

    /// File › Move to Trash… (⌘⌫): opens the same confirmation as the button; nil (disabled) outside results or with nothing ticked.
    private var moveToTrash: (() -> Void)? {
        guard case .results = model.phase, !model.checkedFiles.isEmpty else { return nil }
        return { confirming = true }
    }

    private var results: some View {
        let sorted = model.sorted(model.visibleFiles, using: sortOrder)
        let files = model.duplicatesOnly ? model.groupedByDuplicates(sorted) : sorted
        let largest = files.lazy.map(\.size).max() ?? 0
        return Table(files, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("" as String) { file in // a Text title needs macOS 13.5
                Toggle(isOn: checked(file.url)) { Text(file.name) }
                    .labelsHidden()
                    .toggleStyle(SelectionCheckboxStyle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(model.checked.contains(file.url) ? Color.accentColor.opacity(0.08) : .clear,
                                in: .rect(cornerRadius: 6))
            }
            .width(32)
            TableColumn("Name", value: \.name) { file in
                Label {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(file.name).help(file.url.path)
                        if file.hardLinked {
                            Text("Hard link — moving it frees no space").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(nsImage: Self.icon(forExtension: file.url.pathExtension))
                        .resizable()
                        .frame(width: 20, height: 20)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 3)
            }
            .width(min: 120, ideal: 160)
            // Own column so the name is not cut by the label. Always present (a conditional column needs macOS 14.4)
            // and collapsed to zero width outside the duplicates view.
            TableColumn(model.duplicatesOnly ? LocalizedStringKey("Copies") : "") { file in
                if model.duplicatesOnly, let copies = model.duplicateCount(of: file.url) {
                    Text("\(copies) copies")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .fixedSize()
                }
            }
            .width(min: model.duplicatesOnly ? 60 : 0, ideal: model.duplicatesOnly ? 64 : 0,
                   max: model.duplicatesOnly ? nil : 0)
            TableColumn("Location", value: \.location) { file in
                Text(verbatim: file.location).truncationMode(.middle).foregroundStyle(.secondary)
                    .help(file.url.deletingLastPathComponent().path(percentEncoded: false))
            }
            .width(min: 80, ideal: 110)
            TableColumn("Kind") { file in
                Text(file.kind.singularTitle).foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)
            TableColumn("Size", value: \.size) { file in
                HStack(spacing: 8) {
                    Text(file.size, format: .fileSize).sizeColumnStyle(emphasized: model.checked.contains(file.url))
                    Spacer(minLength: 0)
                    SizeBar(size: file.size, largest: largest)
                }
            }
            .width(min: 110, ideal: 120)
            TableColumn("Last Used", value: \.lastUsed) { file in
                Text(file.lastUsed, format: Date.FormatStyle(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 110)
        }
        .contextMenu(forSelectionType: URL.self) { urls in
            Button("Quick Look") { previewURL = urls.first }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(Array(urls)) }
            if let url = urls.first { Button("Show in Space Lens") { ModuleRouter.shared.spaceLensItem = url } }
            if urls.contains(where: Preferences.canExclude) {
                Divider()
                Button("Never Clean This") {
                    if model.neverClean(urls) { selection.subtract(urls); excludedCount += 1 }
                }
            }
        } primaryAction: { urls in
            NSWorkspace.shared.activateFileViewerSelecting(Array(urls))
        }
        .onSpaceKey {
            previewURL = previewURL == nil ? files.first { selection.contains($0.url) }?.url : nil
            return true
        }
        .quickLookPreview($previewURL, in: files.map(\.url))
        .exclusionNotice(excludedCount)
        .overlay {
            if model.duplicatesOnly, let fraction = model.duplicateProgress {
                VStack(spacing: 12) {
                    ProgressView("Finding duplicates…", value: fraction).frame(maxWidth: 320)
                    Text("Only files of the same size are compared.").foregroundStyle(.secondary)
                    Button("Stop") { model.duplicatesOnly = false }
                }
            } else if model.needsAccess {
                EmptyStateView(title: Text("Full Disk Access Needed"), systemImage: "lock.shield") {
                    Text("macOS protects this folder. Grant Full Disk Access to scan it.")
                } actions: {
                    Button("Open Settings…") { FullDiskAccess.openSettings() }
                }
            } else if model.files.isEmpty {
                EmptyStateView(title: Text("No Large Files Found"), systemImage: "doc") {
                    if let name = model.scopeName {
                        Text("\(name) has no files of \(model.scannedMinSize, format: .fileSize) or more.")
                    } else {
                        Text("Your home folder has no files of \(model.scannedMinSize, format: .fileSize) or more.")
                    }
                }
            } else if files.isEmpty, model.duplicatesOnly, model.duplicateGroups?.isEmpty == true {
                EmptyStateView(title: Text("No Duplicate Files"), systemImage: "doc.on.doc") {
                    Text("No two large files have the same content.")
                }
            } else if files.isEmpty {
                EmptyStateView(title: Text("No Files Match the Filters"), systemImage: "line.3.horizontal.decrease.circle")
            }
        }
        .searchable(text: $model.search, placement: .toolbar, prompt: Text("Search Files"))
        .toolbar {
            // Filters mean nothing when the scan found no files at all.
            if !model.files.isEmpty {
                Picker("Kind", selection: $model.kind) {
                    Text("All Kinds").tag(FileKind?.none)
                    ForEach(FileKind.allCases, id: \.self) { kind in
                        let size = model.files(of: kind).reduce(Int64(0)) { $0 + $1.size }
                        Text("\(Text(kind.title)) (\(size, format: .fileSize))")
                            .tag(FileKind?.some(kind))
                    }
                }
            }
            // A folder with no file over 50 MB can still go down to 1 MB.
            if !model.files.isEmpty || model.scope != nil {
                Picker("Size", selection: $model.minSize) {
                    ForEach(model.sizeChoices, id: \.self) { size in
                        Text("At least \(size, format: .fileSize)").tag(size)
                    }
                }
            }
            if !model.files.isEmpty {
                Picker("Last Used", selection: $model.minAgeMonths) {
                    ForEach(LargeFilesModel.ageOptions, id: \.self) { months in
                        switch months {
                        case 0: Text("Any Time").tag(months)
                        case 12: Text("Over 1 year ago").tag(months)
                        case 24: Text("Over 2 years ago").tag(months)
                        default: Text("Over \(months) months ago").tag(months)
                        }
                    }
                }
                Picker("Duplicates", selection: $model.duplicatesOnly) {
                    Text("All Files").tag(false)
                    Text("Duplicates Only").tag(true)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.skippedProtected { ProtectedFoldersNote() }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("Selected: \(model.checkedFiles.count) files, \(model.checkedSize, format: .fileSize)")
                    .monospacedDigit()
                Spacer()
                // ⌘A stays the Table's own row selection (Quick Look, Reveal); ticking for the Trash is this button only.
                if model.duplicatesOnly {
                    // Never "Select All" here: it would tick every copy, the one to keep too.
                    let anyOn = !model.checkedFiles.isEmpty
                    Button(anyOn ? "Deselect All" : "Select Extra Copies") {
                        if anyOn { model.setVisibleChecked(false) } else { model.checkExtraCopies() }
                    }
                    .disabled(files.isEmpty)
                    .accessibilityHint(Text("Keeps the oldest copy of each file"))
                } else {
                    let allOn = model.allVisibleChecked
                    Button(allOn ? "Deselect All" : "Select All") { model.setVisibleChecked(!allOn) }
                        .disabled(files.isEmpty)
                        .accessibilityHint(Text("Only files that match the filters"))
                }
                Button("Scan Again") { model.scan() }
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

    /// Icon by file type (no disk read), looked up once per extension so 50k rows don't hit LaunchServices on every redraw.
    // shortcut: a file with a custom icon shows its type's icon instead.
    @MainActor private static func icon(forExtension ext: String) -> NSImage {
        let ext = ext.lowercased()
        return IconCache.image("ext:" + ext) { NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data) } ?? NSImage()
    }

    private func checked(_ url: URL) -> Binding<Bool> {
        Binding(
            get: { model.checked.contains(url) },
            set: { if $0 { model.checked.insert(url) } else { model.checked.remove(url) } })
    }
}
