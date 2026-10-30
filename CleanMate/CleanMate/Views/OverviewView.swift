import SwiftUI

/// First module: drives, what CleanMate freed and the largest folders in the home folder. Nothing here removes files.
struct OverviewView: View {
    @ObservedObject var model: OverviewModel

    var body: some View {
        Form {
            Section("Drives") {
                ForEach(model.disks) { DiskRow(disk: $0) }
            }
            freedSection
            foldersSection
        }
        .formStyle(.grouped)
        .navigationTitle(Text(Module.overview.title))
        .task { model.startIfNeeded() }
        .toolbar {
            ToolbarItem {
                Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
        }
    }

    private var freedSection: some View {
        Section {
            let cleanups = model.cleanups
            if let date = cleanups.lastDate {
                LabeledContent("Last 30 days") { Text(cleanups.last30Days, format: .fileSize).monospacedDigit() }
                LabeledContent("In total") { Text(cleanups.total, format: .fileSize).monospacedDigit() }
                LabeledContent("Last cleanup") {
                    Text("\(cleanups.lastBytes, format: .fileSize) on \(date, format: Date.FormatStyle(date: .abbreviated, time: .shortened))")
                        .monospacedDigit()
                }
            } else {
                Text("Shows here after your first cleanup.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Freed by CleanMate")
        } footer: {
            Text("Counts what was deleted; items moved to the Trash are not included.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var foldersSection: some View {
        Section {
            if model.skippedProtected {
                HStack {
                    Image(systemName: "lock.shield").foregroundStyle(.orange)
                    Text("Some folders were skipped — grant Full Disk Access to scan everything.")
                        .help("Without Full Disk Access, macOS asks before each of Desktop, Documents, Downloads, Movies, Music, Pictures, iCloud Drive and other apps' data, so CleanMate leaves them out.")
                    Spacer()
                    Button("Open Settings…") { FullDiskAccess.openSettings() }
                }
            }
            if model.folders.isEmpty {
                if model.measuring {
                    Text("Measuring…").foregroundStyle(.secondary)
                } else if model.measured {
                    Text("Your home folder is empty.").foregroundStyle(.secondary)
                }
            }
            let largest = model.folders.first?.sortSize ?? 0
            ForEach(model.folders) { FolderRow(item: $0, largest: largest) }
        } header: {
            HStack {
                Text("Largest folders in your home")
                Spacer()
                if model.measuring { ProgressView().controlSize(.small) }
            }
        } footer: {
            if !model.folders.isEmpty {
                Text("Click a folder to explore it in Space Lens.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// A drive: name, used / total / available, and a capacity bar tinted like `VolumeGauge` (orange past 90 % used).
private struct DiskRow: View {
    let disk: OverviewModel.Disk

    private var tint: Color {
        switch disk.volume.level {
        case .critical: .red
        case .low: .orange
        case .normal: .accentColor
        }
    }

    var body: some View {
        let volume = disk.volume
        HStack(spacing: 10) {
            Image(nsImage: IconCache.image("volume:" + disk.url.path) { NSWorkspace.shared.icon(forFile: disk.url.path) }
                  ?? NSImage())
                .resizable().frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(volume.name.isEmpty ? disk.url.lastPathComponent : volume.name)
                    if volume.level != .normal {
                        Text("Almost full").font(.caption).bold().foregroundStyle(tint)
                    }
                }
                Text("\(volume.used, format: .fileSize) used of \(volume.total, format: .fileSize) · \(volume.available, format: .fileSize) available")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            SizeBar(size: volume.used, largest: volume.total, tint: tint, height: 8, width: 160)
            Text(disk.usedFraction, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
                .foregroundStyle(volume.level == .normal ? Color.secondary : tint)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(volume.name))
        .accessibilityValue(Text("\(disk.usedFraction, format: .percent.precision(.fractionLength(0))) used, \(volume.available, format: .fileSize) available of \(volume.total, format: .fileSize)"))
    }
}

/// A folder of the home: click → Space Lens opens it.
private struct FolderRow: View {
    let item: SpaceItem
    let largest: Int64

    var body: some View {
        Button { ModuleRouter.shared.spaceLensFolder = item.url } label: {
            HStack(spacing: 8) {
                Image(nsImage: IconCache.image("folder:" + item.url.path) { NSWorkspace.shared.icon(forFile: item.url.path) }
                      ?? NSImage())
                    .resizable().frame(width: 20, height: 20)
                Text(verbatim: FileManager.default.displayName(atPath: item.url.path))
                Spacer()
                Text(item.sortSize, format: .fileSize).sizeColumnStyle(emphasized: false)
                SizeBar(size: item.sortSize, largest: largest)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary).imageScale(.small)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open in Space Lens")
        .accessibilityHint(Text("Open in Space Lens"))
    }
}
