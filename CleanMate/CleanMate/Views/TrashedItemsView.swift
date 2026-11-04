import SwiftUI
import UniformTypeIdentifiers

/// "View Moved Items…": opens Moved to the Trash on the main window (`ModuleRouter.showTrashedItems`), from a done
/// screen, an alert or Settings.
struct ViewMovedItemsButton: View {
    var body: some View {
        Button("View Moved Items…") { ModuleRouter.shared.showTrashedItems() }
            .help("See everything CleanMate moved to the Trash and put items back, also after CleanMate was quit.")
    }
}

/// The sheet: everything CleanMate moved to the Trash that is still there, newest first, with its old place, size,
/// date and source; put back one item or every item shown, or show it in the Trash in Finder.
struct TrashedItemsView: View {
    @StateObject private var model: TrashedItemsModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @FocusState private var searchFocused: Bool
    @State private var confirmingAll = false
    @ObservedObject private var bin = TrashBin.shared

    init(model: TrashedItemsModel = TrashedItemsModel()) {
        _model = StateObject(wrappedValue: model)
    }

    /// A source's name in `locale`'s language: the module as the sidebar shows it, "Command Line", or "Unknown" for an
    /// older record that did not keep one.
    static func sourceTitle(_ source: String, locale: Locale) -> String {
        var resource = source.isEmpty ? LocalizedStringResource("Unknown") : LocalizedStringResource(String.LocalizationValue(source))
        resource.locale = locale
        return String(localized: resource)
    }

    /// Why an item stayed in the Trash, as shown under its row.
    static func reasonText(_ outcome: TrashRecords.PutBack) -> Text {
        switch outcome {
        case .restored, .notInTrash: Text("No longer in the Trash.")
        case .folderIsSymlink: Text("Its folder is now a link to another place, so it was not put back. Drag it out of the Trash in Finder instead.")
        case .occupied: Text("An item with the same name is already there. Nothing was replaced.")
        case .folderChanged: Text("Its folder was moved, renamed or removed, or is now on another disk.")
        case .failed: Text("Couldn’t put it back. Try again, or drag it out of the Trash in Finder.")
        }
    }

    var body: some View {
        let shown = model.shown
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Moved to the Trash").font(.headline)
                Text("Everything CleanMate moved to the Trash that is still there. Put an item back to return it to where it was.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let broken = model.brokenFile { brokenNotice(broken) }
            }
            HStack {
                Picker("Source", selection: $model.source) {
                    Text("All Sources").tag(String?.none)
                    ForEach(model.sources, id: \.self) { source in
                        Text(verbatim: Self.sourceTitle(source, locale: locale)).tag(String?.some(source))
                    }
                }
                .fixedSize()
                TextField("Search Items", text: $model.search)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
            }
            .disabled(model.rows.isEmpty)
            list(shown)
            HStack {
                status
                Spacer()
                OpenTrashButton()
                EmptyTrashButton(bin: bin)
                Button("Put Back All Shown…") { confirmingAll = true }
                    .disabled(shown.isEmpty || model.working)
                    .help("Put every item in the list back where it was.")
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 680, height: 520)
        .task { await model.load() }
        // ⌘F: the search field, as in the module lists.
        .onFindKey { _ in searchFocused = true; return true }
        .confirmationDialog(Text("Put back everything shown (\(shown.count))?"), isPresented: $confirmingAll) {
            Button("Put Back") { Task { await model.restore(shown) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each item returns to where it was. Nothing already there is replaced.")
        }
        // Emptied here: the items are gone, so is their list.
        .onChange(of: bin.emptiedCount) { _ in Task { await model.load() } }
        .onChange(of: model.restoredCount) { count in
            if let count { announceForAccessibility(String(localized: "Put back from the Trash: \(count)")) }
        }
    }

    @ViewBuilder private func list(_ shown: [TrashedItemsModel.Row]) -> some View {
        if model.loaded && model.rows.isEmpty {
            EmptyStateView(title: Text("Nothing from CleanMate in the Trash"), systemImage: "trash") {
                Text("Files, apps and folders that CleanMate moves to the Trash are listed here until the Trash is emptied, so you can put them back. Caches and other items deleted permanently are not.")
            }
            .frame(maxHeight: .infinity)
        } else {
            let largest = shown.map(\.record.size).max() ?? 0
            List(shown) { row in
                rowView(row, largest: largest)
            }
            .overlay {
                if !model.loaded {
                    ProgressView().controlSize(.small)
                } else if shown.isEmpty {
                    Text("No matching items").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func rowView(_ row: TrashedItemsModel.Row, largest: Int64) -> some View {
        let failure = model.failures[row.id]
        return HStack(spacing: 10) {
            Image(nsImage: Self.icon(row))
                .resizable()
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: row.name).lineLimit(1).truncationMode(.middle)
                Text(verbatim: HeadlessScan.displayPath(row.original.deletingLastPathComponent(), home: model.home))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Text(verbatim: details(row)).font(.caption).foregroundStyle(.secondary)
                if let failure {
                    Label { Self.reasonText(failure) } icon: { Image(systemName: "exclamationmark.triangle") }
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .help(row.record.original)
            // One VoiceOver element per row (the buttons stay their own): name, old place, size, source, date, reason.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText(row, failure: failure))
            Spacer()
            Text(row.record.size, format: .fileSize)
                .sizeColumnStyle(emphasized: false)
                .accessibilityHidden(true)
            SizeBar(size: row.record.size, largest: largest, tint: .secondary)
                .accessibilityHidden(true)
            Button("Reveal in Finder", systemImage: "magnifyingglass") { reveal(row) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Show it in the Trash in Finder.")
            Button("Put Back") { Task { await model.restore([row]) } }
                .disabled(model.working)
                .accessibilityLabel(Text("Put Back \(row.name)"))
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Put Back") { Task { await model.restore([row]) } }.disabled(model.working)
            Button("Reveal in Finder") { reveal(row) }
        }
    }

    /// "Source · date" under the old place.
    private func details(_ row: TrashedItemsModel.Row) -> String {
        let date = row.date?.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)) ?? "–"
        return Self.sourceTitle(row.source, locale: locale) + " · " + date
    }

    private func accessibilityText(_ row: TrashedItemsModel.Row, failure: TrashRecords.PutBack?) -> Text {
        let place = HeadlessScan.displayPath(row.original.deletingLastPathComponent(), home: model.home)
        var text = Text(verbatim: row.name + ", ") + Text("from \(place)") + Text(verbatim: ", ")
            + Text(row.record.size, format: .fileSize) + Text(verbatim: ", " + details(row))
        if let failure { text = text + Text(verbatim: ". ") + Self.reasonText(failure) }
        return text
    }

    /// Shows the item in the Trash; when it is gone from there (emptied meanwhile), the list is read again.
    private func reveal(_ row: TrashedItemsModel.Row) {
        if FileManager.default.fileExists(atPath: row.inTrash.path) {
            NSWorkspace.shared.activateFileViewerSelecting([row.inTrash])
        } else {
            Task { await model.load() }
        }
    }

    /// One line when the list of moved items couldn't be read and a new one was started.
    private func brokenNotice(_ url: URL) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Label {
                Text("CleanMate’s list of moved items couldn’t be read, so a new one was started. Items moved before that are still in the Trash: put them back from Finder.")
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .buttonStyle(.link)
                .help("Show the unreadable list, kept as it was.")
        }
        .font(.callout)
    }

    @ViewBuilder private var status: some View {
        Group {
            if model.working {
                ProgressView("Putting back…").controlSize(.small)
            } else if let count = model.restoredCount {
                Text("Put back from the Trash: \(count)")
            } else if model.loaded && !model.rows.isEmpty {
                let total = model.rows.reduce(0) { $0 + $1.record.size }
                Text("In the Trash: \(model.rows.count) (\(total, format: .fileSize))")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    /// An app shows its own icon; other items their type's (looked up once per type).
    @MainActor static func icon(_ row: TrashedItemsModel.Row) -> NSImage {
        let ext = row.inTrash.pathExtension.lowercased()
        if ext == "app" {
            return IconCache.image("trashed:" + row.inTrash.path) { NSWorkspace.shared.icon(forFile: row.inTrash.path) } ?? NSImage()
        }
        if row.isFolder && ext.isEmpty {
            return IconCache.image("type:folder") { NSWorkspace.shared.icon(for: .folder) } ?? NSImage()
        }
        return IconCache.image("ext:" + ext) { NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data) } ?? NSImage()
    }
}
