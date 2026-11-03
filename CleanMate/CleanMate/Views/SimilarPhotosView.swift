import ImageIO
import QuickLook
import SwiftUI

/// Duplicates › Similar Photos: groups of photos that look alike, each with the photo suggested to keep first.
/// Nothing is ticked for the user; ticked photos go to the Trash.
struct SimilarPhotosView<Listing: View>: View {
    @ObservedObject var model: SimilarPhotosModel
    /// Where the photos were looked for, e.g. "~/Pictures"; nil = the home folder.
    let scopeName: String?
    @Binding var confirming: Bool
    /// The Duplicates menu, kept in the toolbar so the user can go back to the file list.
    @ViewBuilder let listingMenu: () -> Listing
    @State private var previewURL: URL?
    /// The List's selected rows: Space, Open and Reveal act on them; ticking is the checkboxes.
    @State private var highlighted: Set<URL> = []

    var body: some View {
        Group {
            switch model.phase {
            case .idle:
                EmptyStateView(title: Text("Similar Photos"), systemImage: "photo.on.rectangle.angled") {
                    Text("Find photos that look alike — bursts, edits, resized copies — and keep one. Photos are compared on this Mac; nothing is uploaded.")
                } actions: {
                    Button("Find Similar Photos") { model.findAgain() }.buttonStyle(.borderedProminent)
                }
            case .listing:
                VStack(spacing: 12) {
                    ProgressView { Text("Looking for photos…") }
                    Text("Files checked: \(model.listed)").foregroundStyle(.secondary).monospacedDigit()
                    Button("Stop") { model.stop() }
                }
            case .analyzing:
                VStack(spacing: 12) {
                    ProgressView(value: model.total > 0 ? Double(model.analyzed) / Double(model.total) : 0) {
                        Text("Comparing photos…")
                    }
                    .frame(maxWidth: 320)
                    Text("\(model.analyzed) of \(model.total) photos").foregroundStyle(.secondary).monospacedDigit()
                    Text("Photos are compared on this Mac; nothing is uploaded.").foregroundStyle(.secondary)
                    Button("Stop") { model.stop() }
                }
            case .trashing:
                ProgressView("Moving to Trash…")
            case .results:
                if model.groups.isEmpty {
                    EmptyStateView(title: Text("No Similar Photos"), systemImage: "photo.on.rectangle") {
                        if let scopeName {
                            Text("No two photos in \(scopeName) look alike.")
                        } else {
                            Text("No two photos in your home folder look alike.")
                        }
                    } actions: {
                        Button("Find Again") { model.findAgain() }
                    }
                } else {
                    results
                }
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
                    Button("Find Again") { model.findAgain() }.disabled(model.undoing)
                    TrashReportButtons(report: report) { await model.undoTrash() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar { listingMenu() }
        .trashUndo(model)
    }

    private var results: some View {
        let groups = model.shownGroups
        let largest = groups.lazy.flatMap(\.photos).map(\.size).max() ?? 0
        let urls = groups.flatMap { $0.photos.map(\.url) }
        return List(selection: $highlighted) {
            ForEach(groups) { group in
                Section {
                    ForEach(group.photos) { photo in
                        row(photo, suggested: photo.url == group.suggested.url, largest: largest)
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
        .overlay {
            if groups.isEmpty {
                EmptyStateView(title: Text("No Matching Photos"), systemImage: "magnifyingglass")
            }
        }
        .searchable(text: $model.search, placement: .toolbar, prompt: Text("Search Photos"))
        .toolbar {
            Picker("Sort By", selection: $model.order) {
                Text("Space to Free").tag(SimilarPhotos.GroupOrder.space)
                Text("Date").tag(SimilarPhotos.GroupOrder.date)
                Text("Number of Photos").tag(SimilarPhotos.GroupOrder.count)
            }
            .help("Sort groups by the space their extra photos take, their newest photo, or how many photos they have")
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("Selected: \(model.checkedPhotos.count) photos, \(model.checkedSize, format: .fileSize)")
                    .monospacedDigit()
                Spacer()
                // Never "Select All": it would tick the photo to keep too.
                let anyOn = !model.checkedPhotos.isEmpty
                Button(anyOn ? "Deselect All" : "Select All but Suggested") {
                    if anyOn { model.uncheckAll() } else { model.checkAllButSuggested() }
                }
                .accessibilityHint(Text("Keeps the suggested photo of each group"))
                Button("Find Again") { model.findAgain() }
                Button("Move to Trash…") { confirming = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.checkedPhotos.isEmpty)
            }
            .padding()
            .background(.bar)
        }
        .focusedSceneValue(\.confirming, confirming)
        .confirmationDialog(
            Text("Move \(model.checkedPhotos.count) photos (\(model.checkedSize, format: .fileSize)) to the Trash?"),
            isPresented: $confirming
        ) {
            Button("Move to Trash", role: .destructive) { Task { await model.trash() } }
        } message: {
            let lost = model.groupsLosingEveryPhoto
            if lost.isEmpty {
                Text("You can put them back from the Trash until it is emptied.")
            } else {
                Text("Every photo is selected in the group of \(lost, format: .list(type: .and)): none of them will be left. You can put them back from the Trash until it is emptied.")
            }
        }
    }

    private func groupHeader(_ group: SimilarPhotos.Group) -> some View {
        let urls = group.photos.map(\.url)
        let set = { (on: Bool) in if on { model.checked.formUnion(urls) } else { model.checked.subtract(urls) } }
        // Two sources: mixed while some but not all are ticked.
        let sources = [Binding { urls.contains { model.checked.contains($0) } } set: { set($0) },
                       Binding { urls.allSatisfy { model.checked.contains($0) } } set: { set($0) }]
        return HStack(spacing: 8) {
            Toggle(sources: sources, isOn: \.self) { EmptyView() }
                .toggleStyle(SelectionCheckboxStyle())
                .accessibilityLabel(Text("\(group.photos.count) similar photos"))
            Text("\(group.photos.count) similar photos")
            Spacer()
            Text("Extra copies: \(group.extraSize, format: .fileSize)").foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func row(_ photo: SimilarPhotos.Photo, suggested: Bool, largest: Int64) -> some View {
        let isOn = model.checked.contains(photo.url)
        return HStack(spacing: 10) {
            Toggle(isOn: checked(photo.url)) { EmptyView() }
                .toggleStyle(SelectionCheckboxStyle())
                .accessibilityLabel(Text(verbatim: photo.name))
            PhotoThumbnail(url: photo.url)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: photo.name).lineLimit(1).truncationMode(.middle).help(photo.url.path)
                    if suggested {
                        Text("Suggested to keep")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                            .fixedSize()
                            .help("Suggested: the most pixels, then the largest and newest file. Nothing is selected for you.")
                    }
                }
                HStack(spacing: 6) {
                    if photo.pixels > 0 { Text(verbatim: "\(photo.width) × \(photo.height)") }
                    Text(photo.modified, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
                    Text(verbatim: photo.location).lineLimit(1).truncationMode(.middle)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(photo.size, format: .fileSize).sizeColumnStyle(emphasized: isOn)
            SizeBar(size: photo.size, largest: largest)
            QuickLookButton(url: photo.url, preview: $previewURL)
        }
        .padding(.vertical, 2)
        .selectionRow(isOn: isOn, highlight: { highlighted = [photo.url] }) {
            if isOn { model.checked.remove(photo.url) } else { model.checked.insert(photo.url) }
        }
        .tag(photo.url)
    }

    private func checked(_ url: URL) -> Binding<Bool> {
        Binding(get: { model.checked.contains(url) }, set: { if $0 { model.checked.insert(url) } else { model.checked.remove(url) } })
    }
}

/// A small rendition of the photo, read off the main thread once per photo (the file's access date is put back).
private struct PhotoThumbnail: View {
    let url: URL
    @State private var image: CGImage?
    static let side: CGFloat = 56

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo").foregroundStyle(.tertiary)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .clipShape(.rect(cornerRadius: 6))
        .accessibilityHidden(true)
        .task(id: url) {
            if let cached = ThumbnailCache.shared.object(forKey: url as NSURL) {
                image = cached.image
                return
            }
            guard let made = await Self.make(url, pixels: Int(Self.side * 2)) else { return }
            ThumbnailCache.shared.setObject(ThumbnailCache.Box(made), forKey: url as NSURL)
            image = made
        }
    }

    @concurrent nonisolated static func make(_ url: URL, pixels: Int) async -> CGImage? {
        DuplicateFinder.keepingAccessDate(of: url) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
            else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                                            kCGImageSourceThumbnailMaxPixelSize: pixels,
                                            kCGImageSourceCreateThumbnailWithTransform: true]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
    }
}

/// Thumbnails already made this launch; NSCache drops them under memory pressure.
private enum ThumbnailCache {
    final class Box {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }
    @MainActor static let shared: NSCache<NSURL, Box> = {
        let cache = NSCache<NSURL, Box>()
        cache.countLimit = 2_000
        return cache
    }()
}
