import Foundation

/// "Empty Trash…" outside Smart Scan (the done screens of the modules that move files to the Trash, Moved to the
/// Trash): the same `empty-trash` item as Smart Scan, scanned and cleaned the same way, so it removes exactly what
/// Smart Scan's "Empty Trash" would. Deletes for good: always behind a confirmation.
nonisolated enum EmptyTrash {
    /// The activity log's module of an Empty Trash run here.
    static let module: LocalizedStringResource = "Trash"

    /// Smart Scan's `empty-trash` item (`SmartScanCatalog`).
    static var item: CleanerItem? {
        CleanerGroup.smartScan(ages: .current).first { $0.id == "trash" }?.items.first { $0.id == "empty-trash" }
    }

    /// What the Trash holds now, as Smart Scan measures it: entries and bytes. Nothing when it can't be read.
    @concurrent static func contents(policy: SafetyPolicy = .current) async -> (count: Int, size: Int64) {
        guard let item else { return (0, 0) }
        let scan = await Scanner.scan(item, policy: policy, openPaths: { _ in [] })
        return (scan.entries.count, scan.size)
    }

    /// Scans the Trash again and removes what it holds (`Cleaner.clean`, every entry checked by the policy right
    /// before), logged like Smart Scan's item: one line for what was deleted, one per entry left with why.
    @concurrent static func empty(policy: SafetyPolicy = .current,
                                  openPaths: OpenPaths = OpenFiles.reader(maxAge: OpenFiles.cleanMaxAge)) async -> CleanReport {
        guard let item else { return CleanReport() }
        let scan = await Scanner.scan(item, policy: policy, openPaths: openPaths)
        guard !scan.entries.isEmpty else { return CleanReport() }
        let report = await Cleaner.clean(item, scan: scan, policy: policy, openPaths: openPaths)
        let removed = Cleaner.removedCount(item, scan, report)
        let home = policy.homeURL
        if report.freed > 0 || removed > 0 {
            ActivityLog.record(module: module, item: ActivityLog.english(item.title), count: removed, size: report.freed,
                               mode: item.mode, paths: scan.entries.map(\.url.path), home: home)
        }
        report.logFailures(module: module, home: home)
        return report
    }
}
