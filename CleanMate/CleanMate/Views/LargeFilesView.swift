import QuickLook
import SwiftUI
import UniformTypeIdentifiers

extension FileKind {
    var title: LocalizedStringResource {
        switch self {
        case .video: "Videos"
        case .audio: "Audio"
        case .image: "Images"
        case .document: "Documents"
        case .code: "Code & Projects"
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
        case .audio: "Audio"
        case .image: "Image"
        case .document: "Document"
        case .code: "Code"
        case .archive: "Archive"
        case .diskImage: "Disk Image"
        case .installer: "Installer"
        case .other: "Other"
        }
    }

    /// SF Symbol for the Kind menu and column.
    var systemImage: String {
        switch self {
        case .video: "film"
        case .audio: "music.note"
        case .image: "photo"
        case .document: "doc.text"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .archive: "archivebox"
        case .diskImage: "opticaldisc"
        case .installer: "shippingbox"
        case .other: "doc"
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
    @State private var confirmingPhotos = false
    /// Files whose download the confirmation asks to remove; empty = not asking.
    @State private var removingDownloads: [LargeFile] = []
    @State private var excludedCount = 0
    /// Last Used › Custom…: the number of days being typed.
    @State private var askingDays = false
    @State private var typedDays = ""
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
                TrashProgress(stopping: model.stoppingTrash) { model.stopTrash() }
            case .results:
                if model.similarPhotosShown, !model.needsAccess {
                    SimilarPhotosView(model: model.similarPhotos, scopeName: model.scopeName,
                                      skipsProtected: model.skipsProtectedFolders, confirming: $confirmingPhotos) {
                        listingMenu
                    }
                } else {
                    results
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
        .disabled(model.undoing || model.similarPhotos.isChanging || { if case .trashing = model.phase { true } else { false } }())
    }

    /// All files, identical copies only, or Similar Photos (which replaces the file list).
    private var listingMenu: some View {
        Picker("Duplicates", selection: $model.listing) {
            Text("All Files").tag(LargeFilesModel.Listing.allFiles)
            Text("Duplicates Only").tag(LargeFilesModel.Listing.duplicates)
            Text("Similar Photos").tag(LargeFilesModel.Listing.similarPhotos)
        }
        .disabled(model.similarPhotos.isChanging)
    }

    /// File › Move to Trash… (⌘⌫): opens the same confirmation as the button; nil (disabled) outside results or with nothing ticked.
    private var moveToTrash: (() -> Void)? {
        guard case .results = model.phase else { return nil }
        if model.similarPhotosShown {
            guard case .results = model.similarPhotos.phase, !model.similarPhotos.checkedPhotos.isEmpty else { return nil }
            return { confirmingPhotos = true }
        }
        guard !model.checkedFiles.isEmpty else { return nil }
        return { confirming = true }
    }

    private var results: some View {
        let sorted = model.sorted(model.visibleFiles, using: sortOrder)
        let files = model.duplicatesOnly ? model.groupedByDuplicates(sorted) : sorted
        let largest = files.lazy.map(\.size).max() ?? 0
        return Table(files, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("" as String) { file in // a Text title needs macOS 13.5
                Toggle(isOn: checked(file.url)) { EmptyView() }
                    .toggleStyle(SelectionCheckboxStyle())
                    .accessibilityLabel(Text(verbatim: file.name))
                    .disabled(!file.trashable)
                    .help(file.trashable ? Text(verbatim: "") : Text("Files in iCloud Drive never go to the Trash. Remove the download to free the space."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(model.checked.contains(file.url) ? Color.accentColor.opacity(0.08) : .clear,
                                in: .rect(cornerRadius: 6))
            }
            .width(32)
            TableColumn("Name", value: \.name) { file in
                HStack(spacing: 4) {
                    Label {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(file.name).help(file.url.path)
                            if let icloud = file.icloud { iCloudLine(file, icloud) }
                            if file.hardLinked {
                                Text("Hard link — moving it frees no space").font(.caption).foregroundStyle(.secondary)
                            } else if let freed = model.cloneFreedSize(of: file) {
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
                    } icon: {
                        Image(nsImage: Self.icon(forExtension: file.url.pathExtension))
                            .resizable()
                            .frame(width: 20, height: 20)
                            .accessibilityHidden(true)
                    }
                    .padding(.vertical, 3)
                    Spacer(minLength: 0)
                    QuickLookButton(url: file.url, preview: $previewURL)
                }
            }
            .width(min: 140, ideal: 180)
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
                Label { Text(file.kind.singularTitle) } icon: { Image(systemName: file.kind.systemImage) }
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 110)
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
            Button("Open") { FileOpener.open(Array(urls)) }.disabled(urls.count > FileOpener.limit)
            Button("Quick Look") { previewURL = urls.first }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(Array(urls)) }
            if let url = urls.first { Button("Show in Space Lens") { ModuleRouter.shared.spaceLensItem = url } }
            let removable = model.removableDownloads(urls)
            if !removable.isEmpty {
                Button("Remove Download") { removingDownloads = removable }.disabled(model.removingDownloads)
            }
            if urls.contains(where: Preferences.canExclude) {
                Divider()
                Button("Never Clean This") {
                    if model.neverClean(urls) { selection.subtract(urls); excludedCount += 1 }
                }
            }
        } primaryAction: { urls in
            FileOpener.open(files.map(\.url).filter(urls.contains)) // double-click or Return, like Finder
        }
        .onSpaceKey {
            previewURL = previewURL == nil ? files.first { selection.contains($0.url) }?.url : nil
            return true
        }
        .onSelectAllKeys { on in
            model.setCheckedByKey(on)
            return true
        }
        .onFindKey { focusToolbarSearch(in: $0) }
        .quickLookPreview($previewURL, in: files.map(\.url))
        .exclusionNotice(excludedCount)
        .overlay(alignment: .bottom) {
            DownloadsRemovedNotice(report: model.downloadsRemoved, count: model.downloadRemovals)
        }
        .overlay {
            if model.duplicatesOnly, let fraction = model.duplicateProgress {
                VStack(spacing: 12) {
                    ProgressView("Finding duplicates…", value: fraction).frame(maxWidth: 320)
                    Text("Only files of the same size are compared.").foregroundStyle(.secondary)
                    Button("Stop") { model.duplicatesOnly = false }
                }
            } else if model.duplicatesOnly, let error = model.duplicateError {
                EmptyStateView(title: Text("Couldn’t Finish Finding Duplicates"), systemImage: "exclamationmark.triangle") {
                    Text(verbatim: error)
                } actions: {
                    Button("Try Again") { model.retryDuplicates() }
                    Button("Show All Files") { model.duplicatesOnly = false }
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
                        Label { Text("\(Text(kind.title)) (\(size, format: .fileSize))") } icon: { Image(systemName: kind.systemImage) }
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
            if !model.files.isEmpty { lastUsedMenu }
            // Similar Photos looks for smaller files too: offered even when no large file was found.
            if !model.needsAccess { listingMenu }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if let report = model.lastTrash {
                    MovedToTrashNote(report: report, freed: model.lastTrashFreed, undoing: model.undoing) { await model.undoTrash() } dismiss: {
                        model.dismissTrashReport()
                    }
                }
                if model.skippedProtected { ProtectedFoldersNote() }
            }
        }
        // Last Used › Custom…
        .alert("Not Used for More Than", isPresented: $askingDays) {
            TextField("Days", text: $typedDays)
            Button("Apply") {
                if let days = Int(typedDays.trimmingCharacters(in: .whitespaces)), LargeFilesModel.customDays.contains(days) {
                    model.unusedFor = .days(days)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Show files not used for more than this many days (1 to 36,500).")
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("Selected: \(model.checkedFiles.count) files, \(model.checkedSize, format: .fileSize)")
                    .monospacedDigit()
                Spacer()
                // ⌘A / ⇧⌘A in the table do what this button does (`setCheckedByKey`); rows highlight with click and Shift-click.
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
        .focusedSceneValue(\.confirming, confirming || !removingDownloads.isEmpty)
        .confirmationDialog(removeDownloadTitle, isPresented: Binding(
            get: { !removingDownloads.isEmpty }, set: { if !$0 { removingDownloads = [] } })
        ) {
            Button("Remove Download") {
                let files = removingDownloads
                Task { await model.removeDownloads(of: files) }
            }
        } message: {
            Text("The files stay in iCloud Drive and download again when you open them.")
        }
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

    /// Any time, 1 month to 2 years, or Custom…: a number of days typed in a prompt (`.days(0)` is that item).
    private var lastUsedMenu: some View {
        typealias UnusedFor = LargeFilesModel.UnusedFor
        return Picker("Last Used", selection: Binding(get: { model.unusedFor }, set: { value in
            if value == .days(0) {
                if case .days(let days) = model.unusedFor { typedDays = String(days) } else { typedDays = "" }
                askingDays = true
            } else {
                model.unusedFor = value
            }
        })) {
            Text("Any Time").tag(UnusedFor.anyTime)
            ForEach(LargeFilesModel.ageOptions, id: \.self) { months in
                switch months {
                case 1: Text("Over 1 month ago").tag(UnusedFor.months(months))
                case 12: Text("Over 1 year ago").tag(UnusedFor.months(months))
                case 24: Text("Over 2 years ago").tag(UnusedFor.months(months))
                default: Text("Over \(months) months ago").tag(UnusedFor.months(months))
                }
            }
            Divider()
            if case .days(let days) = model.unusedFor { Text("Over \(days) days ago").tag(model.unusedFor) }
            Text("Custom…").tag(UnusedFor.days(0))
        }
    }

    private var removeDownloadTitle: Text {
        let size = removingDownloads.reduce(Int64(0)) { $0 + $1.size }
        if removingDownloads.count == 1, let file = removingDownloads.first {
            return Text("Remove the download of “\(file.name)” (\(size, format: .fileSize))?")
        }
        return Text("Remove the downloads of \(removingDownloads.count) files (\(size, format: .fileSize))?")
    }

    /// iCloud line under the name: Remove Download when every change is uploaded, else why it can't be removed.
    @ViewBuilder private func iCloudLine(_ file: LargeFile, _ status: ICloudStatus) -> some View {
        HStack(spacing: 6) {
            switch status {
            case .uploaded:
                Label { Text(verbatim: "iCloud") } icon: { Image(systemName: "icloud") }
                Button("Remove Download") { removingDownloads = [file] }
                    .buttonStyle(.link)
                    .disabled(model.removingDownloads)
                    .help("Free the space: the file stays in iCloud Drive and downloads again when you open it.")
            case .notUploaded:
                Label("iCloud — not uploaded yet", systemImage: "icloud.slash")
            case .syncing:
                Label("iCloud — syncing", systemImage: "arrow.triangle.2.circlepath.icloud")
            case .conflict:
                Label("iCloud — conflicting versions", systemImage: "exclamationmark.icloud")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .help(status.allowsRemovingDownload ? Text(verbatim: "")
              : Text("Only a file fully uploaded to iCloud can have its download removed."))
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

/// Shown for a few seconds after Remove Download: the space freed, and how many files were kept and why.
/// After Move to Trash, above the list: what went (and what didn't), Undo, Open Trash, View Moved Items.
private struct MovedToTrashNote: View {
    let report: CleanReport
    /// What the move frees (APFS clones count only their own blocks); `report.freed` is the files' sizes.
    let freed: Int64
    let undoing: Bool
    let undo: () async -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Moved \(freed, format: .fileSize) to the Trash")
                    .help(Text("Empty the Trash to free the space."))
                StoppedTrashSummary(report: report)
                NotCleanedSummary(report: report)
                if report.freed > 0 { TrashSpaceSummary().font(.caption).foregroundStyle(.secondary) }
                if let result = report.undo { UndoTrashResult(result: result).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            TrashReportButtons(report: report, undo: undo).disabled(undoing)
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .disabled(undoing)
                .help(Text("Close"))
                .accessibilityLabel(Text("Close"))
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
        .onAppear { announceForAccessibility(String(localized: "Moved \(freed.formatted(.byteCount(style: .file))) to the Trash")) }
    }
}

private struct DownloadsRemovedNotice: View {
    let report: ICloudDownloads.Report?
    let count: Int
    @State private var shown = false

    var body: some View {
        Group {
            if shown, let report {
                VStack(spacing: 2) {
                    Label {
                        if report.removed.isEmpty {
                            Text("No download removed")
                        } else {
                            Text("Downloads removed: \(report.freed, format: .fileSize) freed")
                        }
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    if !report.kept.isEmpty {
                        Text("Kept (not fully uploaded or changed): \(report.kept.count)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
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
            guard count > 0, let report else { return }
            shown = true
            announceForAccessibility(report.removed.isEmpty ? String(localized: "No download removed")
                : String(localized: "Downloads removed: \(report.freed.formatted(.byteCount(style: .file))) freed"))
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { shown = false }
        }
    }
}
