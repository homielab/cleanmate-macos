import Foundation

/// What `cleanmate privacy` lists: the app's Privacy items (browsing history, cookies, form data per browser, recent
/// items, shell history) measured by the same read-only scan as `cleanmate scan --privacy`, each with its browser. An
/// item whose browser runs is skipped, as in the app. `privacy --erase` goes through `HeadlessClean`.
nonisolated enum HeadlessPrivacy {
    struct Item: Codable, Equatable, Sendable {
        var id: String
        /// The browser or place it belongs to, as the app groups it ("Safari", "Google Chrome", "System"…).
        var browser: String
        var name: String
        /// Bytes `--erase` would delete (history in a database: see `records`).
        var size: Int64
        /// Records to erase in a database; absent when the item has none.
        var records: Int?
        /// Ticked in the app: `privacy --erase` without ids erases these.
        var selectedByDefault: Bool
        /// Erasing it signs you out of websites (cookies).
        var signsOut: Bool
        /// Left as it is now; `reason` says why (its browser is running, or it needs Full Disk Access).
        var skipped: Bool
        var reason: String?
        /// Largest first.
        var entries: [HeadlessScan.Entry]

        enum CodingKeys: String, CodingKey {
            case id, browser, name, size, records, selectedByDefault, signsOut, skipped, reason, entries
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(browser, forKey: .browser)
            try container.encode(name, forKey: .name)
            try container.encode(size, forKey: .size)
            try container.encodeIfPresent(records, forKey: .records)
            try container.encode(selectedByDefault, forKey: .selectedByDefault)
            try container.encode(signsOut, forKey: .signsOut)
            try container.encode(skipped, forKey: .skipped)
            try container.encode(reason, forKey: .reason)
            try container.encode(entries, forKey: .entries)
        }
    }

    struct Report: Codable, Equatable, Sendable {
        var version: String
        var fullDiskAccess: Bool
        var durationMs: Int
        /// Bytes of the items ticked by default that are not skipped.
        var total: Int64
        var items: [Item]
    }

    /// The app's warning before erasing.
    static let cookieWarning = "Erasing cookies signs you out of websites."

    /// Cookie items (`safari-cookies`, `<browser>-cookies`, `firefox-cookies`).
    static func signsOut(_ id: String) -> Bool { id.hasSuffix("-cookies") }

    static func list(sources: HeadlessScan.Sources) async -> Report {
        let started = ContinuousClock.now
        var browsers: [String: String] = [:]
        for group in sources.privacy() {
            for item in group.items { browsers[item.id] = HeadlessScan.english(group.title) }
        }
        let scan = await HeadlessScan.scan(HeadlessScan.Options(groups: ["privacy"], privacy: true), sources: sources)
        let items = scan.items.map { item in
            Item(id: item.id, browser: browsers[item.id] ?? "Privacy", name: item.name, size: item.size, records: item.records,
                 selectedByDefault: item.selectedByDefault, signsOut: signsOut(item.id), skipped: item.locked,
                 reason: item.reason, entries: item.entries)
        }
        return Report(version: scan.version, fullDiskAccess: scan.fullDiskAccess,
                      durationMs: HeadlessScan.milliseconds(ContinuousClock.now - started),
                      total: items.filter { $0.selectedByDefault && !$0.skipped }.reduce(0) { $0 + $1.size }, items: items)
    }
}
