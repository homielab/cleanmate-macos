import Charts
import SwiftUI

/// First module: drives, free space over time, what CleanMate freed and the largest folders in the home folder.
/// Nothing here removes files.
struct OverviewView: View {
    @ObservedObject var model: OverviewModel

    var body: some View {
        Form {
            Section("Drives") {
                ForEach(model.disks) { DiskRow(disk: $0) }
            }
            historySection
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

    private var historySection: some View {
        Section {
            let points = model.history
            if points.count < 2 {
                Text("Shows here after a few days of use.").foregroundStyle(.secondary)
            } else {
                HistoryTrend(points: points)
                FreeSpaceChart(points: points)
            }
        } header: {
            Text("Free space over time")
        } footer: {
            Text("Free space on the startup disk, recorded once a day while you use CleanMate.")
                .font(.caption).foregroundStyle(.secondary)
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

/// The free-space history in words, like the Linux app: where it went and how fast.
private struct HistoryTrend: View {
    let points: [DiskHistory.Point]

    var body: some View {
        let first = points[0], last = points[points.count - 1]
        VStack(alignment: .leading, spacing: 2) {
            Text("\(first.available, format: .fileSize) free on \(first.date, format: .dateTime.day().month()) → \(last.available, format: .fileSize) on \(last.date, format: .dateTime.day().month()).")
                .monospacedDigit()
            switch DiskHistory.trend(points) {
            case .losing(let perWeek, let weeksLeft)?:
                Text("Losing about \(perWeek, format: .fileSize) a week.").foregroundColor(.orange)
                    + Text(verbatim: " ")
                    + Text("At this rate the disk is full in about \(weeksLeft) weeks.").foregroundColor(.secondary)
            case .gaining(let perWeek)?:
                Text("Gaining about \(perWeek, format: .fileSize) a week.").foregroundStyle(.secondary)
            case .stable(let days)?:
                Text("Stable over the last \(days) days.").foregroundStyle(.secondary)
            case nil:
                EmptyView()
            }
        }
    }
}

/// Free space per day as a line in the accent color; hovering shows the nearest day's date and free space.
private struct FreeSpaceChart: View {
    let points: [DiskHistory.Point]
    @State private var hovered: DiskHistory.Point?
    /// Where the hovered reading is drawn, and the chart's width: the label sits beside it, inside the chart.
    @State private var hoveredX: CGFloat = 0
    @State private var width: CGFloat = 0

    /// Lowest and highest value of the y axis: 10 % above and below the readings, a flat line in the middle.
    private var domain: ClosedRange<Double> {
        let values = points.map { Double($0.available) }
        let low = values.min() ?? 0, high = values.max() ?? 0
        let margin = high > low ? (high - low) * 0.1 : max(high * 0.05, 1)
        return max(low - margin, 0)...(high + margin)
    }

    var body: some View {
        let domain = domain
        VStack(alignment: .leading, spacing: 4) {
            hoverLabel(hovered ?? points[points.count - 1]).opacity(hovered == nil ? 0 : 1)
            Chart {
                ForEach(points) { point in
                    AreaMark(x: .value("Date", point.date), yStart: .value("Free space", domain.lowerBound),
                             yEnd: .value("Free space", Double(point.available)))
                        .foregroundStyle(Color.accentColor.opacity(0.15))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Date", point.date), y: .value("Free space", Double(point.available)))
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.monotone)
                        .accessibilityLabel(Text(point.date, format: .dateTime.day().month()))
                        .accessibilityValue(Text(point.available, format: .fileSize))
                }
                if let point = hovered ?? points.last {
                    PointMark(x: .value("Date", point.date), y: .value("Free space", Double(point.available)))
                        .foregroundStyle(Color.accentColor)
                        .symbolSize(40)
                }
                if let hovered {
                    RuleMark(x: .value("Date", hovered.date)).foregroundStyle(Color.secondary.opacity(0.5))
                }
            }
            .chartYScale(domain: domain)
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let bytes = value.as(Double.self) { Text(Int64(bytes), format: .fileSize) }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                    AxisGridLine()
                    // A Text, not `format:`, so the dates follow the app language, not the system's.
                    AxisValueLabel {
                        if let date = value.as(Date.self) { Text(date, format: .dateTime.day().month(.abbreviated)) }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            guard case .active(let location) = phase else { hovered = nil; return }
                            let plot = geometry[proxy.plotAreaFrame]
                            guard let date: Date = proxy.value(atX: location.x - plot.minX),
                                  let nearest = points.min(by: {
                                      abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
                                  }) else { hovered = nil; return }
                            hovered = nearest
                            hoveredX = plot.minX + (proxy.position(forX: nearest.date) ?? 0)
                            width = geometry.size.width
                        }
                }
            }
            .frame(height: 130)
        }
        .padding(.vertical, 4)
    }

    /// "12 Oct: 182 GB free", starting at the hovered reading on the left half, ending at it on the right half.
    private func hoverLabel(_ point: DiskHistory.Point) -> some View {
        let leftHalf = hoveredX < width / 2
        return Text("\(point.date, format: .dateTime.day().month().year()): \(point.available, format: .fileSize) free")
            .font(.caption).monospacedDigit()
            .lineLimit(1)
            .padding(.leading, leftHalf ? max(hoveredX - 6, 0) : 0)
            .padding(.trailing, leftHalf ? 0 : max(width - hoveredX - 6, 0))
            .frame(maxWidth: .infinity, alignment: leftHalf ? .leading : .trailing)
            .accessibilityHidden(true)
    }
}
