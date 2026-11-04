import Foundation

/// What the Shortcuts actions report: numbers the next action can use, and the same in one text in CleanMate's language.
nonisolated enum ShortcutsSummary {
    /// Junk of one Smart Scan group, as Smart Scan would clean it.
    struct Group: Equatable, Sendable {
        /// The command line's group name (`HeadlessScan.groupName`).
        var id: String
        var title: String
        var size: Int64
        var items: Int
    }

    /// A Shortcuts scan (`ScanJunkIntent`).
    struct Scan: Equatable, Sendable {
        /// Ticked items that can be cleaned, like Smart Scan's "Selected"; items in use, excluded or out of reach are not counted.
        var junk: Int64
        /// Part of `junk` is an upper bound (a store that only cleans what it no longer needs).
        var upTo: Bool
        var items: Int
        /// Groups with junk, in catalog order.
        var groups: [Group]
        var fullDiskAccess: Bool
    }

    /// Titles of the Smart Scan groups by their command line name, in CleanMate's language.
    static func groupTitles(locale: Locale = AppLanguage.locale()) -> [String: String] {
        Dictionary(CleanerGroup.smartScan(hasFullDiskAccess: true).map { group in
            var title = group.title
            title.locale = locale
            return (HeadlessScan.groupName(group.id), String(localized: title))
        }, uniquingKeysWith: { first, _ in first })
    }

    /// The scan as Smart Scan would clean it: the items ticked (in the app or by default) and not locked.
    static func scan(_ report: HeadlessScan.Report, titles: [String: String]) -> Scan {
        let counted = report.items.filter { $0.selectedByDefault && !$0.locked && $0.size > 0 }
        var order: [String] = []
        var groups: [String: Group] = [:]
        for item in counted {
            if groups[item.group] == nil {
                order.append(item.group)
                groups[item.group] = Group(id: item.group, title: titles[item.group] ?? item.group, size: 0, items: 0)
            }
            groups[item.group]?.size += item.size
            groups[item.group]?.items += 1
        }
        return Scan(junk: report.total + report.totalUpTo, upTo: report.totalUpTo > 0, items: counted.count,
                    groups: order.compactMap { groups[$0] }, fullDiskAccess: report.fullDiskAccess)
    }

    /// "Junk ready to clean: 1.2 GB (14 items)", a line per group, and a note when Full Disk Access is off.
    static func text(_ scan: Scan, locale: Locale = AppLanguage.locale()) -> String {
        let size = { (bytes: Int64) in bytes.formatted(.fileSize.locale(locale)) }
        var lines: [String] = []
        if scan.junk > 0 {
            let items = itemCount(scan.items, locale: locale)
            lines.append(localized(scan.upTo ? "Junk ready to clean: up to \(size(scan.junk)) (\(items))"
                                             : "Junk ready to clean: \(size(scan.junk)) (\(items))", locale))
            lines += scan.groups.map { "\($0.title): \(size($0.size)) (\(itemCount($0.items, locale: locale)))" }
        } else {
            lines.append(localized("No junk to clean.", locale))
        }
        if !scan.fullDiskAccess {
            lines.append(localized("Full Disk Access is off, so some items were not scanned. Turn it on in CleanMate’s Settings.", locale))
        }
        return lines.joined(separator: "\n")
    }

    /// "120 GB free of 500 GB" and the junk the last Smart Scan found.
    static func spaceText(_ volume: DiskVolume, last: LastScan?, locale: Locale = AppLanguage.locale()) -> String {
        let size = { (bytes: Int64) in bytes.formatted(.fileSize.locale(locale)) }
        let free = localized("\(size(volume.available)) free of \(size(volume.total))", locale)
        let scan = last.map { SmartScanView.lastScanLine($0, locale: locale) } ?? localized("Smart Scan has not run yet.", locale)
        return free + "\n" + scan
    }

    static func itemCount(_ count: Int, locale: Locale) -> String { localized("\(count) items", locale) }

    private static func localized(_ resource: LocalizedStringResource, _ locale: Locale) -> String {
        var resource = resource
        resource.locale = locale
        return String(localized: resource)
    }
}
