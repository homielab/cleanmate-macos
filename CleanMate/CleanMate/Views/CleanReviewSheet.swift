import SwiftUI

/// Clean… / Erase…: every ticked item by group before anything is removed, with whether it goes to the Trash or is
/// deleted for good and its size, then the total of each kind. A tick changed here changes the list behind it (and the
/// sidebar badge); an item unticked here stays listed so it can be ticked again. Items that will be skipped (app open,
/// tool running, blocked by an exclusion, every entry locked) are listed with the reason.
struct CleanReviewSheet: View {
    @ObservedObject var model: SmartScanModel
    let module: Module
    /// Items ticked when the sheet opened (`SmartScanModel.selectedIDs`).
    let ids: Set<String>
    @Environment(\.dismiss) private var dismiss

    /// Entries listed under an item; the rest get one summary row, as in the results list.
    private let shownLimit = 100

    var body: some View {
        let review = model.review(of: ids)
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(module == .privacy ? "Review Before Erasing" : "Review Before Cleaning").font(.headline)
                Text("Untick anything you want to keep.").font(.callout).foregroundStyle(.secondary)
            }
            List {
                ForEach(review.groups) { group in
                    let largest = group.rows.map { $0.total.size + $0.total.upTo }.max() ?? 0
                    Section {
                        ForEach(group.rows) { row in
                            itemRow(row, groupImage: group.systemImage, largest: largest)
                        }
                    } header: {
                        Label { Text(group.title) } icon: { Image(systemName: group.systemImage).foregroundStyle(.tint) }
                    }
                }
                if !review.skipped.isEmpty {
                    Section {
                        ForEach(review.skipped) { item in
                            skippedRow(item)
                        }
                    } header: {
                        Label("Skipped", systemImage: "lock")
                    }
                }
            }
            .frame(minHeight: 220, idealHeight: 380)
            summary(review)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(module == .privacy ? LocalizedStringKey("Erase") : "Clean") {
                    dismiss()
                    Task { await model.clean() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!review.hasSelection)
            }
        }
        .padding(20)
        .frame(width: 620)
    }

    /// "To the Trash" or "Deleted permanently", with its symbol.
    static func modeLabel(_ mode: RemovalMode) -> some View {
        Group {
            switch mode {
            case .trash:
                Label { modeText(mode) } icon: { Image(systemName: "trash") }
            case .delete:
                Label { modeText(mode) } icon: { Image(systemName: "xmark.bin").foregroundStyle(.orange) }
            }
        }
        .labelStyle(.titleAndIcon)
    }

    static func modeText(_ mode: RemovalMode) -> Text {
        mode == .trash ? Text("To the Trash") : Text("Deleted permanently")
    }

    @ViewBuilder private func itemRow(_ row: SmartScanModel.Review.Row, groupImage: String, largest: Int64) -> some View {
        let files = row.entries.filter(\.url.isFileURL)
        if files.isEmpty {
            itemLabel(row, groupImage: groupImage, largest: largest)
        } else {
            DisclosureGroup {
                ForEach(files.prefix(shownLimit)) { entry in
                    HStack {
                        Text(entry.url.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(entry.url.path)
                        Spacer()
                        Group {
                            if let records = entry.records {
                                Text("\(records) records")
                            } else {
                                Text(entry.size, format: .fileSize)
                            }
                        }
                        .sizeColumnStyle(emphasized: false)
                        Color.clear.frame(width: 48, height: 1).accessibilityHidden(true) // the SizeBar column
                    }
                    .font(.callout)
                    .foregroundStyle(row.isOn ? .primary : .secondary)
                    .padding(.leading, 34) // under the item name, past the checkbox and icon
                }
                if files.count > shownLimit {
                    let rest = files.dropFirst(shownLimit)
                    Text("and \(rest.count) more (\(rest.reduce(0) { $0 + $1.size }, format: .fileSize))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 34)
                }
            } label: {
                itemLabel(row, groupImage: groupImage, largest: largest)
            }
        }
    }

    private func itemLabel(_ row: SmartScanModel.Review.Row, groupImage: String, largest: Int64) -> some View {
        let isOn = Binding { model.selected.contains(row.id) } set: { model.setReviewed(row.item, $0) }
        return HStack {
            Toggle(isOn: isOn) { EmptyView() }
                .toggleStyle(SelectionCheckboxStyle())
                // VoiceOver reads "name, to the Trash / deleted permanently, size".
                .accessibilityLabel(Text(row.item.title) + Text(verbatim: ", ") + Self.modeText(row.item.mode)
                    + Text(verbatim: ", ") + SmartScanView.totalText(row.total))
            CleanerItemIcon(item: row.item, groupImage: groupImage)
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.item.title)
                HStack(spacing: 10) {
                    Self.modeLabel(row.item.mode)
                    if row.isPartial {
                        Text("Some entries left out")
                    }
                    if row.lockedCount > 0 {
                        Text("\(row.lockedCount) in use or locked, skipped").foregroundStyle(.orange)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .accessibilityHidden(true) // read by the checkbox
            Spacer()
            SmartScanView.totalText(row.total)
                .sizeColumnStyle(emphasized: row.isOn)
                .fontWeight(row.isOn ? .semibold : .regular)
                .accessibilityHidden(true)
            SizeBar(size: row.total.size + row.total.upTo, largest: largest, tint: row.isOn ? .accentColor : .secondary)
                .opacity(row.total.size + row.total.upTo == 0 ? 0 : 1) // records only: no bytes to compare
        }
        .padding(.vertical, 4)
        .selectionRow(isOn: row.isOn) { isOn.wrappedValue.toggle() }
    }

    private func skippedRow(_ item: CleanerItem) -> some View {
        HStack {
            CleanerItemIcon(item: item, groupImage: "lock")
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                skipReason(item).font(.subheadline).foregroundStyle(.orange)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.leading, 6)
        .accessibilityElement(children: .combine)
    }

    private func skipReason(_ item: CleanerItem) -> Text {
        if model.isRunning(item) {
            item.runningAppBundleIDs.isEmpty ? Text("The tool is running, so it is skipped. Close its sessions and scan again")
                : Text("The app is open, so it is skipped")
        } else if model.blocked.contains(item.id) {
            Text("Blocked by a folder in Exclusions")
        } else if let reason = model.scans[item.id]?.entries.first?.lockReason {
            Text(verbatim: reason)
        } else {
            Text("Skipped")
        }
    }

    /// What goes to the Trash and what is deleted for good, each with what that means.
    private func summary(_ review: SmartScanModel.Review) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if review.trash != .init() {
                Label {
                    Text("\(SmartScanView.totalText(review.trash).bold()) to the Trash: you can put it back with Undo or from the Trash.")
                } icon: {
                    Image(systemName: "trash")
                }
            }
            if review.delete != .init() {
                Label {
                    Text("\(SmartScanView.totalText(review.delete).bold()) deleted permanently and can’t be recovered.") + Text(verbatim: " ")
                        + (module == .privacy ? Text("Erasing cookies signs you out of websites.")
                            : Text("Apps and tools recreate caches as needed."))
                } icon: {
                    Image(systemName: "xmark.bin").foregroundStyle(.orange)
                }
            }
        }
        .monospacedDigit()
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The app's own icon when the item belongs to an installed app, else the group's symbol.
struct CleanerItemIcon: View {
    let item: CleanerItem
    var groupImage = "folder"

    @MainActor static func appIcon(_ bundleID: String) -> NSImage? {
        IconCache.image("app:" + bundleID) {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
        }
    }

    var body: some View {
        if let image = item.runningAppBundleIDs.lazy.compactMap(Self.appIcon).first {
            Image(nsImage: image).resizable()
        } else {
            Image(systemName: groupImage).foregroundStyle(.secondary)
        }
    }
}
