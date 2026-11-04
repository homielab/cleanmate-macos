import Foundation
import Combine

/// Moved to the Trash: what CleanMate moved to the Trash and is still there, from any module or the command line and
/// across launches (`TrashRecords`, the same records as `cleanmate restore`), newest first. Put back one item or every
/// item shown, under the same rules as Undo; an item that can't go back keeps its row with the reason.
final class TrashedItemsModel: ObservableObject {
    nonisolated struct Row: Identifiable, Equatable, Sendable {
        let record: TrashRecords.Record
        /// When it was moved; nil for a record without a date.
        let date: Date?
        let isFolder: Bool

        /// Its place in the Trash: unique, and what `TrashRecords.restore` takes.
        var id: String { record.trashed }
        var original: URL { URL(fileURLWithPath: record.original) }
        var inTrash: URL { URL(fileURLWithPath: record.trashed) }
        var name: String { original.lastPathComponent }
        /// The activity log's module (English) it was moved by; "" for an older record without one.
        var source: String { record.module ?? "" }
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var loaded = false
    @Published private(set) var working = false
    /// Source filter: a `Row.source`; nil = every source.
    @Published var source: String?
    @Published var search = ""
    /// Why an item was not put back, by its place in the Trash; cleared when the list is read again.
    @Published private(set) var failures: [String: TrashRecords.PutBack] = [:]
    /// Items put back by the last Put Back, for the status line.
    @Published private(set) var restoredCount: Int?
    /// The records file couldn't be read and was set aside (`TrashRecords.setAside`) in the last `brokenNoticeDays`:
    /// the window says items moved before then are not listed.
    @Published private(set) var brokenFile: URL?
    nonisolated static let brokenNoticeDays = 30

    let home: URL
    /// Injected by tests: the volume of a folder.
    var device: SafetyPolicy.DeviceID = SafetyPolicy.deviceID

    init(home: URL = SafetyPolicy.current.homeURL) {
        self.home = home
    }

    /// Modules in the order of the sidebar, then the command line; the filter lists the ones that have rows.
    nonisolated static let sourceOrder = ["Smart Scan", "Privacy", "Large & Old Files", "Similar Photos", "Uninstaller",
                                          "Space Lens", "Login Items", "Command Line"]

    /// The records still in the Trash as rows, newest first (records without a date last, newest written first).
    nonisolated static func rows(_ records: [TrashRecords.Record]) -> [Row] {
        let rows = records.enumerated().map { index, record in
            var info = stat()
            let isFolder = lstat(record.trashed, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
            return (index, Row(record: record, date: record.date.flatMap { try? Date($0, strategy: .iso8601) },
                               isFolder: isFolder))
        }
        return rows.sorted { a, b in
            switch (a.1.date, b.1.date) {
            case let (x?, y?) where x != y: x > y
            case (_?, nil): true
            case (nil, _?): false
            default: a.0 > b.0
            }
        }.map(\.1)
    }

    /// Rows of `source` (nil = all) whose name or old path contains `search`.
    nonisolated static func filter(_ rows: [Row], source: String?, search: String) -> [Row] {
        let search = search.trimmingCharacters(in: .whitespaces)
        return rows.filter {
            (source == nil || $0.source == source) && (search.isEmpty || $0.record.original.localizedStandardContains(search))
        }
    }

    /// The sources of `rows`, in `sourceOrder`; unknown modules after it, then "" (older records).
    nonisolated static func sources(_ rows: [Row]) -> [String] {
        let present = Set(rows.map(\.source))
        let known = sourceOrder.filter(present.contains)
        let other = present.subtracting(sourceOrder).subtracting([""]).sorted()
        return known + other + (present.contains("") ? [""] : [])
    }

    /// What the list shows with the filter and search.
    var shown: [Row] { Self.filter(rows, source: source, search: search) }

    var sources: [String] { Self.sources(rows) }

    /// Reads the records again. The file is never made by looking; an unreadable one is set aside (`TrashRecords.inTrash`).
    func load() async {
        let home = home
        (rows, brokenFile) = await Self.read(home: home)
        failures = [:]
        loaded = true
        if let source, !rows.contains(where: { $0.source == source }) { self.source = nil }
    }

    @concurrent private nonisolated static func read(home: URL) async -> ([Row], URL?) {
        let rows = rows(TrashRecords.inTrash(home: home))
        return (rows, recentlyBroken(home: home))
    }

    /// The newest records file set aside within `brokenNoticeDays` of `now`.
    nonisolated static func recentlyBroken(home: URL, now: Date = .now) -> URL? {
        guard let newest = TrashRecords.broken(home: home).first else { return nil }
        let since = now.addingTimeInterval(-Double(brokenNoticeDays) * 86_400)
        return TrashRecords.setAsideDate(newest) >= since ? newest : nil
    }

    /// Puts `items` back at their old places (`TrashRecords.restore`, logged "restored" under the module that moved
    /// them). Rows put back or no longer in the Trash leave the list; the others stay with the reason.
    func restore(_ items: [Row]) async {
        guard !working, !items.isEmpty else { return }
        working = true
        let home = home, device = device, paths = items.map(\.id)
        let outcomes = await Self.putBack(paths, home: home, device: device)
        working = false
        restoredCount = outcomes.values.count(where: { $0 == .restored })
        rows.removeAll { outcomes[$0.id]?.dropsRecord == true }
        for (path, outcome) in outcomes {
            failures[path] = outcome.dropsRecord ? nil : outcome
        }
    }

    @concurrent private nonisolated static func putBack(_ paths: [String], home: URL,
                                                       device: @escaping SafetyPolicy.DeviceID) async -> [String: TrashRecords.PutBack] {
        TrashRecords.restore(paths, home: home, device: device)
    }
}
