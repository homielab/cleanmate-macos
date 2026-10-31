import Charts
import SwiftUI

/// First module: drives, free space over time, what CleanMate freed, space outside the user's folders, the largest
/// folders in the home folder and whether macOS's protections are on. Nothing here removes files or changes a setting.
struct OverviewView: View {
    @ObservedObject var model: OverviewModel

    var body: some View {
        Form {
            Section("Drives") {
                let animates = !model.introduced.contains(.drives)
                ForEach(model.disks) { disk in
                    DiskRow(disk: disk, animates: animates)
                        .onAppear { model.introduced.insert(.drives) }
                }
            }
            historySection
            freedSection
            outsideSection
            foldersSection
            securitySection
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
                GrowsIn(animates: !model.introduced.contains(.history)) { FreeSpaceChart(points: points, grown: $0) }
                    .onAppear { model.introduced.insert(.history) }
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
                // Counts up the first time it shows in a session; Refresh then rolls the digits.
                let animates = !model.introduced.contains(.freed)
                HStack(alignment: .top, spacing: 10) {
                    FreedCard(symbol: "calendar", title: Text("Last 30 days"), bytes: cleanups.last30Days,
                              countsUp: animates)
                    FreedCard(symbol: "sum", title: Text("In total"), bytes: cleanups.total, countsUp: animates)
                    FreedCard(symbol: "sparkles", title: Text("Last cleanup"), bytes: cleanups.lastBytes,
                              countsUp: animates,
                              detail: Text(date, format: Date.FormatStyle(date: .abbreviated, time: .shortened)))
                }
                .fixedSize(horizontal: false, vertical: true) // same height for all three
                .padding(.vertical, 4)
                .onAppear { model.introduced.insert(.freed) }
                let days = model.freedByDay
                if days.contains(where: { $0.bytes > 0 }) {
                    GrowsIn(animates: animates) { FreedByDayChart(days: days, grown: $0) }
                } else {
                    Text("Nothing was cleaned in the last 30 days.").foregroundStyle(.secondary)
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

    /// Local snapshots, purgeable space and everything outside the home folder: space no folder in the list explains.
    private var outsideSection: some View {
        Section {
            let purgeable = model.purgeable, system = model.systemAndApps
            let largest = max(purgeable ?? 0, system ?? 0)
            SnapshotsRow(snapshots: model.snapshots)
            if let purgeable {
                OutsideRow(symbol: "icloud.and.arrow.down", title: Text("Purgeable space"),
                           value: Text(purgeable, format: .fileSize), size: purgeable, largest: largest,
                           note: Text("macOS can free \(purgeable, format: .fileSize) when it needs space (downloaded iCloud files, snapshots, system caches). It is already counted as available."))
            }
            if let system {
                let note = Text("In use on the startup disk outside your home folder: macOS, apps, other users and local snapshots. For information only.")
                OutsideRow(symbol: "macwindow", title: Text("System and apps"),
                           value: Text(system, format: .fileSize), size: system, largest: largest,
                           note: model.skippedProtected
                               ? note + Text(verbatim: " ") + Text("Includes the folders skipped without Full Disk Access.")
                               : note)
            }
        } header: {
            HStack {
                Text("Space outside your folders")
                Spacer()
                if model.measuring { ProgressView().controlSize(.small) }
            }
        } footer: {
            Text("In use, but in none of your folders. Shown for information; local snapshots can be deleted in Maintenance.")
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

    private var securitySection: some View {
        Section {
            if let security = model.security {
                ForEach(security.checks) { SecurityRow(check: $0, xprotect: security.xprotect) }
            } else {
                Text("Checking…").foregroundStyle(.secondary)
            }
        } header: {
            Text("System protection")
        } footer: {
            Text("Read from macOS. CleanMate does not change these settings.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A protection: green when on, orange when off (with what that means and where to turn it on), grey when unknown.
private struct SecurityRow: View {
    let check: SecurityStatus.Check
    let xprotect: SecurityStatus.XProtect?

    private var symbol: (name: String, color: Color) {
        switch check.state {
        case .on: ("checkmark.shield.fill", .green)
        case .off: ("exclamationmark.shield.fill", .orange)
        case .unknown: ("questionmark.circle", .secondary)
        }
    }

    private var value: Text {
        if check.kind == .xprotect, let xprotect {
            guard let date = xprotect.date else { return Text("Version \(xprotect.version)") }
            return Text("Version \(xprotect.version), \(date, format: .dateTime.day().month().year())")
        }
        switch check.state {
        case .on: return Text("On")
        case .off: return Text("Off")
        case .unknown: return Text("Unknown")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: symbol.name).foregroundStyle(symbol.color).frame(width: 20)
                    .accessibilityHidden(true)
                Text(check.kind.title)
                Spacer()
                value.foregroundStyle(check.state == .off ? Color.orange : Color.secondary).monospacedDigit()
            }
            .help(Text(check.kind.help))
            .accessibilityElement(children: .combine)
            if let reminder = check.reminder {
                HStack(alignment: .firstTextBaseline) {
                    Text(reminder).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if let url = check.settingsURL {
                        Button("Open System Settings…") { openSettingsPane(url) }.controlSize(.small)
                    }
                }
                .padding(.leading, 28)
            }
        }
        .padding(.vertical, 2)
    }
}

/// The pane, else System Settings itself (an older macOS that doesn't know the pane).
private func openSettingsPane(_ url: URL) {
    if !NSWorkspace.shared.open(url) {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
}

/// A row of "Space outside your folders": icon, name and size, and a line saying what it is and what to do.
private struct OutsideRow: View {
    let symbol: String
    let title: Text
    let value: Text
    /// nil: no size bar (the value is not a size).
    var size: Int64?
    var largest: Int64 = 0
    let note: Text
    var help: Text?
    var action: (title: LocalizedStringKey, perform: () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let help { line.help(help) } else { line }
            HStack(alignment: .firstTextBaseline) {
                note.font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if let action {
                    Button(action.title, action: action.perform).controlSize(.small)
                }
            }
            .padding(.leading, 28)
        }
        .padding(.vertical, 2)
    }

    private var line: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
                .accessibilityHidden(true)
            title
            Spacer()
            value.sizeColumnStyle(emphasized: false)
            if let size {
                SizeBar(size: size, largest: largest)
            } else {
                Color.clear.frame(width: 48, height: 6) // keeps the value in line with the sized rows
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Time Machine's local snapshots: how many and from when, and "Delete…" to Maintenance, where they are deleted.
/// Their size needs admin rights to measure, so none is shown.
private struct SnapshotsRow: View {
    let snapshots: LocalSnapshots?

    var body: some View {
        let title = Text("Time Machine local snapshots")
        let about = Text("Copies of your disk that Time Machine keeps on this Mac between backups.")
        let help = Text("Measuring their size needs administrator rights.")
        switch snapshots {
        case nil:
            OutsideRow(symbol: "clock.arrow.circlepath", title: title, value: Text("Checking…"), note: about)
        case let list? where !list.readable:
            OutsideRow(symbol: "clock.arrow.circlepath", title: title, value: Text("Unknown"),
                       note: Text("Couldn’t list them."))
        case let list? where list.count == 0:
            OutsideRow(symbol: "clock.arrow.circlepath", title: title, value: Text("None"), note: about)
        case let list?:
            OutsideRow(symbol: "clock.arrow.circlepath", title: title, value: Text("\(list.count) snapshots"),
                       note: dates(list) + Text("macOS deletes them by itself when it needs the space. To delete them now: Maintenance."),
                       help: help, action: ("Delete…", { ModuleRouter.shared.requested = .maintenance }))
        }
    }

    /// "From 12 Oct 2026 to 30 Oct 2026. ", or nothing when no date could be read.
    private func dates(_ list: LocalSnapshots) -> Text {
        guard let oldest = list.oldest, let newest = list.newest else { return Text(verbatim: "") }
        let format = Date.FormatStyle.dateTime.day().month().year()
        return Text("From \(oldest, format: format) to \(newest, format: format).") + Text(verbatim: " ")
    }
}

/// A drive: name, used / total / available, and a capacity bar tinted like `VolumeGauge` (orange past 90 % used).
private struct DiskRow: View {
    let disk: OverviewModel.Disk
    /// The bar fills from 0 when the row first shows.
    var animates = false

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
                    .contentTransition(.numericText()) // Refresh rolls the digits
                    .animation(.default, value: volume.available)
            }
            Spacer()
            GrowsIn(animates: animates) { grown in
                SizeBar(size: grown ? volume.used : 0, largest: volume.total, tint: tint, height: 8, width: 160)
            }
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
/// `grown` false: drawn along the bottom of the chart, so it rises into place when it turns true.
private struct FreeSpaceChart: View {
    let points: [DiskHistory.Point]
    var grown = true
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
        let y = { (point: DiskHistory.Point) in grown ? Double(point.available) : domain.lowerBound }
        VStack(alignment: .leading, spacing: 4) {
            ChartHoverLabel(text: hoverText(hovered ?? points[points.count - 1]), x: hoveredX, width: width)
                .opacity(hovered == nil ? 0 : 1)
            Chart {
                ForEach(points) { point in
                    AreaMark(x: .value("Date", point.date), yStart: .value("Free space", domain.lowerBound),
                             yEnd: .value("Free space", y(point)))
                        .foregroundStyle(Color.accentColor.opacity(0.15))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Date", point.date), y: .value("Free space", y(point)))
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.monotone)
                        .accessibilityLabel(Text(point.date, format: .dateTime.day().month()))
                        .accessibilityValue(Text(point.available, format: .fileSize))
                }
                if let point = hovered ?? points.last {
                    PointMark(x: .value("Date", point.date), y: .value("Free space", y(point)))
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

    /// "12 Oct 2026: 182 GB free".
    private func hoverText(_ point: DiskHistory.Point) -> Text {
        Text("\(point.date, format: .dateTime.day().month().year()): \(point.available, format: .fileSize) free")
    }
}

/// Above a chart: the hovered value, starting at `x` (where it is drawn) on the left half of the chart's `width`,
/// ending at it on the right half.
private struct ChartHoverLabel: View {
    let text: Text
    let x: CGFloat
    let width: CGFloat

    var body: some View {
        let leftHalf = x < width / 2
        text
            .font(.caption).monospacedDigit()
            .lineLimit(1)
            .padding(.leading, leftHalf ? max(x - 6, 0) : 0)
            .padding(.trailing, leftHalf ? 0 : max(width - x - 6, 0))
            .frame(maxWidth: .infinity, alignment: leftHalf ? .leading : .trailing)
            .accessibilityHidden(true)
    }
}

/// "Freed by CleanMate": a large number with its icon and name, and a line under it (the last cleanup's date).
private struct FreedCard: View {
    let symbol: String
    let title: Text
    let bytes: Int64
    let countsUp: Bool
    var detail: Text?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label { title } icon: { Image(systemName: symbol) }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            CountingBytes(bytes, countsUp: countsUp, duration: 0.6)
                .font(.title.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6) // a narrow window shrinks the number instead of cutting it
            if let detail {
                detail.font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

/// Bytes deleted per day over the last 30 days as accent bars; hovering shows the day's date and size.
/// `grown` false: every bar at 0, so they grow when it turns true.
private struct FreedByDayChart: View {
    let days: [ActivityLog.Cleanups.Day]
    var grown = true
    @State private var hovered: ActivityLog.Cleanups.Day?
    @State private var hoveredX: CGFloat = 0
    @State private var width: CGFloat = 0

    var body: some View {
        // Fixed from the real sizes, so the axis stays put while the bars grow.
        let top = Double(max(days.map(\.bytes).max() ?? 0, 1))
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                Text("Freed per day, last 30 days")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(hovered == nil ? 1 : 0)
                ChartHoverLabel(text: hoverText(hovered ?? days[days.count - 1]), x: hoveredX, width: width)
                    .opacity(hovered == nil ? 0 : 1)
            }
            Chart(days) { day in
                BarMark(x: .value("Date", day.date, unit: .day), y: .value("Freed", grown ? Double(day.bytes) : 0))
                    .foregroundStyle(hovered == nil || hovered == day ? Color.accentColor : Color.accentColor.opacity(0.4))
                    .accessibilityLabel(Text(day.date, format: .dateTime.day().month()))
                    .accessibilityValue(Text(day.bytes, format: .fileSize))
            }
            .chartYScale(domain: 0...top)
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        // No label on the baseline: "Zero KB" says nothing the bars don't.
                        if let bytes = value.as(Double.self), bytes > 0 { Text(Int64(bytes), format: .fileSize) }
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
                            // A bar spans its whole day: the nearest is the one whose middle is closest.
                            guard let date: Date = proxy.value(atX: location.x - plot.minX),
                                  let nearest = days.min(by: {
                                      abs(Self.middle($0).timeIntervalSince(date)) < abs(Self.middle($1).timeIntervalSince(date))
                                  }) else { hovered = nil; return }
                            hovered = nearest
                            hoveredX = plot.minX + (proxy.position(forX: Self.middle(nearest)) ?? 0)
                            width = geometry.size.width
                        }
                }
            }
            .frame(height: 110)
        }
        .padding(.vertical, 4)
    }

    private static func middle(_ day: ActivityLog.Cleanups.Day) -> Date { day.date.addingTimeInterval(43_200) }

    /// "12 Oct 2026: 1.2 GB freed".
    private func hoverText(_ day: ActivityLog.Cleanups.Day) -> Text {
        Text("\(day.date, format: .dateTime.day().month().year()): \(day.bytes, format: .fileSize) freed")
    }
}
