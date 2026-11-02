import AppKit

/// What `cleanmate list` and `cleanmate scan` report: the Smart Scan catalog (Privacy on request) and a read-only scan
/// of it made like the app's Smart Scan (`SmartScanModel.scan`): same items, `SafetyPolicy`, Settings › Exclusions,
/// running apps and open files. Nothing is ticked, cleaned, logged or saved. Field names are a contract shared with the
/// Linux tool: change them only together.
nonisolated enum HeadlessScan {
    /// Entries listed per item; the others are only counted (`Item.moreEntries`).
    static let maxEntries = 50
    /// The contract's group names, in catalog order.
    static let groupNames = ["system", "user", "dev", "ai", "apps", "privacy"]

    /// Contract group name of a catalog group id.
    static func groupName(_ groupID: String) -> String {
        switch groupID {
        case "system-junk": "system"
        case "trash": "user"
        case "developer": "dev"
        case "ai-tools": "ai"
        case "applications": "apps"
        default: groupID.hasPrefix("privacy-") ? "privacy" : groupID
        }
    }

    // MARK: - Reports

    struct ListItem: Codable, Equatable, Sendable {
        var id: String
        var group: String
        var name: String
        var description: String
        var selectedByDefault: Bool
        /// "delete" (removed permanently) or "trash" (moved to the Trash).
        var disposal: String
        /// Deleted for good and may hold the user's data (`dataLossIDs`): `clean` takes it only when named with `--only`.
        var dataLoss = false
        /// Not scanned (or only partly) without Full Disk Access.
        var needsFullDiskAccess: Bool
    }

    struct ListReport: Codable, Equatable, Sendable {
        var version: String
        var items: [ListItem]
    }

    struct Entry: Codable, Equatable, Sendable {
        /// `~/…` inside the home folder.
        var path: String
        var size: Int64
        /// What the entry is, as the app shows it above the path (a Docker volume's name and driver, a simulator…);
        /// absent when the path says it.
        var name: String? = nil
        /// Records to erase in a database entry (Privacy history); absent otherwise.
        var records: Int? = nil
        /// Why this entry is skipped (a running app uses it); absent when it is cleaned with its item.
        var reason: String? = nil
    }

    struct Item: Codable, Equatable, Sendable {
        var id: String
        var group: String
        var name: String
        /// Bytes the app would clean: without locked entries, unless every entry is locked.
        var size: Int64
        /// `size` is only a maximum (the tool's own prune may keep part of it); counted in `totalUpTo`.
        var sizeIsUpperBound: Bool
        /// Ticked when the app scans: the item's default or the user's own tick.
        var selectedByDefault: Bool
        var disposal: String
        /// May hold the user's data (`dataLossIDs`): `clean` takes it only when named with `--only`.
        var dataLoss = false
        /// The app would not clean it now; `reason` says why.
        var locked: Bool
        var reason: String?
        /// Largest first, at most `maxEntries`.
        var entries: [Entry]
        /// Entries left out of `entries`; absent when none.
        var moreEntries: Int? = nil
        /// Records to erase (Privacy history and similar); absent when the item has none.
        var records: Int? = nil
        /// A folder could not be read without Full Disk Access; absent otherwise.
        var needsFullDiskAccess: Bool? = nil

        enum CodingKeys: String, CodingKey {
            case id, group, name, size, sizeIsUpperBound, selectedByDefault, disposal, dataLoss, locked, reason, entries,
                 moreEntries, records, needsFullDiskAccess
        }

        /// `reason` is written as `null` when there is none (the contract's field is always present).
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(group, forKey: .group)
            try container.encode(name, forKey: .name)
            try container.encode(size, forKey: .size)
            try container.encode(sizeIsUpperBound, forKey: .sizeIsUpperBound)
            try container.encode(selectedByDefault, forKey: .selectedByDefault)
            try container.encode(disposal, forKey: .disposal)
            try container.encode(dataLoss, forKey: .dataLoss)
            try container.encode(locked, forKey: .locked)
            try container.encode(reason, forKey: .reason)
            try container.encode(entries, forKey: .entries)
            try container.encodeIfPresent(moreEntries, forKey: .moreEntries)
            try container.encodeIfPresent(records, forKey: .records)
            try container.encodeIfPresent(needsFullDiskAccess, forKey: .needsFullDiskAccess)
        }
    }

    struct Report: Codable, Equatable, Sendable {
        var version: String
        var fullDiskAccess: Bool
        /// ISO 8601, UTC.
        var scannedAt: String
        /// Bytes of the items ticked by default that are not locked, as the app's "Selected" total.
        var total: Int64
        /// The same for items whose size is only a maximum.
        var totalUpTo: Int64
        var items: [Item]
    }

    // MARK: - Options and sources

    struct Options: Equatable, Sendable {
        /// Item ids; nil = every item.
        var only: [String]? = nil
        /// Contract group names; nil = every group.
        var groups: [String]? = nil
        /// Privacy items too (browser history, cookies, recent items).
        var privacy = false
    }

    enum OptionError: Error, Equatable {
        case unknownItem(String)
        case unknownGroup(String)
        /// A Privacy item or the privacy group was named without `--privacy`.
        case needsPrivacy(String)
    }

    /// Where the scan (and `HeadlessClean`) reads the Mac's state; tests inject a fake home and fixed apps, processes and settings.
    struct Sources: Sendable {
        var policy: @Sendable () -> SafetyPolicy = { .current }
        var hasFullDiskAccess: @Sendable () -> Bool = { FullDiskAccess.isGranted }
        var smartScan: @Sendable (_ hasFullDiskAccess: Bool) -> [CleanerGroup] = { CleanerGroup.smartScan(hasFullDiskAccess: $0) }
        var privacy: @Sendable () -> [CleanerGroup] = { CleanerGroup.privacy }
        /// Smart Scan groups turned off in Settings.
        var disabledGroups: @Sendable () -> Set<String> = { Preferences.disabledGroups() }
        /// The user's own ticks (`Preferences.overrides`).
        var overrides: @Sendable () -> [String: Bool] = { Preferences.overrides }
        /// Bundle id → name of each running app.
        var runningApps: @Sendable () -> [String: String] = { HeadlessScan.currentRunningApps() }
        var processNames: @Sendable () -> Set<String> = { RunningProcesses.names() }
        var readOpenFiles: @Sendable (String) -> Set<String> = { RunningProcesses.openPaths(under: $0) }
        var scanItem: @Sendable (CleanerItem, SafetyPolicy, @escaping OpenPaths) async -> ItemScan = {
            await Scanner.scan($0, policy: $1, openPaths: $2)
        }
        var blockedByExclusion: @Sendable (CleanerItem, SafetyPolicy) async -> Bool = {
            await Cleaner.blockedByExclusion($0, policy: $1)
        }
        var now: @Sendable () -> Date = { .now }
        var version: @Sendable () -> String = { HeadlessScan.appVersion }
        /// Moves an item to the Trash for `cleanmate clean`; tests use a fake Trash folder.
        var trash: @Sendable (URL) throws -> URL? = CleanReport.moveToTrash
        /// Spotlight's last-opened date of a file, for `cleanmate large`.
        var spotlightLastUsed: @Sendable (URL) -> Date? = { LargeFileScanner.spotlightLastUsedDate($0) }
    }

    /// The app's version (`appBundle`).
    static var appVersion: String {
        appBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    /// CleanMate.app: the main bundle in the app and its tests; for the tool in CleanMate.app/Contents/Helpers (run
    /// through a symlink on the PATH, too), the app holding its executable.
    static var appBundle: Bundle {
        if Bundle.main.bundleURL.pathExtension == "app" { return .main }
        let app = Bundle.main.executableURL?.resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.flatMap { $0.pathExtension == "app" ? Bundle(url: $0) : nil } ?? .main
    }

    static func currentRunningApps() -> [String: String] {
        // NSWorkspace documents `runningApplications` as safe to read from any thread.
        Dictionary(NSWorkspace.shared.runningApplications.compactMap { app in
            app.bundleIdentifier.map { ($0, app.localizedName ?? $0) }
        }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - list

    /// Every Smart Scan item as the app knows it with Full Disk Access; Privacy items only with `privacy`.
    static func list(privacy: Bool, sources: Sources = Sources()) -> ListReport {
        let withoutAccess = Set(sources.smartScan(false).flatMap(\.items).map(\.id))
        let overrides = sources.overrides()
        let groups = sources.smartScan(true) + (privacy ? sources.privacy() : [])
        let items = groups.flatMap { group in
            group.items.map { item in
                ListItem(id: item.id, group: groupName(group.id), name: english(item.title),
                         description: item.note.map(english) ?? "",
                         selectedByDefault: overrides[item.id] ?? item.selectedByDefault, disposal: disposal(item),
                         dataLoss: dataLossIDs.contains(item.id),
                         needsFullDiskAccess: !withoutAccess.contains(item.id) && !group.id.hasPrefix("privacy-")
                            || readsProtectedFolder(item))
            }
        }
        return ListReport(version: sources.version(), items: items)
    }

    /// Folders macOS guards with Full Disk Access, relative to the home folder.
    static let protectedFolders = ProtectedFolders.relativePaths + [".Trash", "Library/Safari", "Library/Mail", "Library/Messages",
                                                                    "Library/Cookies"]

    static func readsProtectedFolder(_ item: CleanerItem) -> Bool {
        item.paths.contains { path in
            protectedFolders.contains { path == "~/" + $0 || path.hasPrefix("~/" + $0 + "/") }
        }
    }

    /// Names and descriptions are printed in English, whatever the Mac's language: scripts and agents match on them.
    static func english(_ resource: LocalizedStringResource) -> String {
        var english = resource
        english.locale = Locale(identifier: "en")
        return String(localized: english)
    }

    static func disposal(_ item: CleanerItem) -> String { item.mode == .trash ? "trash" : "delete" }

    /// Items deleted for good whose content may be the user's own data, not junk: a Docker volume holds databases, a
    /// stopped container the files written inside it. A tick in the app (seen there entry by entry) is not consent for
    /// a script or an AI agent, so `cleanmate clean` takes them only when named with `--only`. Every other item that
    /// is deleted outright holds only what its app or tool rebuilds or downloads again.
    static let dataLossIDs: Set<String> = ["docker-containers", "docker-volumes"]

    /// Why `clean` left an item that may hold data, with how to clean it.
    static func dataLossReason(_ id: String) -> String { "May hold data: name it with --only \(id) to clean it" }

    // MARK: - scan

    /// Checks `options` against the whole catalog (as with Full Disk Access, plus Privacy).
    static func validate(_ options: Options, sources: Sources = Sources()) throws {
        let smartIDs = Set(sources.smartScan(true).flatMap(\.items).map(\.id))
        let privacyIDs = Set(sources.privacy().flatMap(\.items).map(\.id))
        for id in options.only ?? [] {
            if privacyIDs.contains(id) && !smartIDs.contains(id) {
                if !options.privacy { throw OptionError.needsPrivacy(id) }
            } else if !smartIDs.contains(id) {
                throw OptionError.unknownItem(id)
            }
        }
        for group in options.groups ?? [] {
            guard groupNames.contains(group) else { throw OptionError.unknownGroup(group) }
            if group == "privacy" && !options.privacy { throw OptionError.needsPrivacy(group) }
        }
    }

    /// Scans like the app's Smart Scan, read-only. `options` must have passed `validate`.
    static func scan(_ options: Options = Options(), sources: Sources = Sources()) async -> Report {
        await scanned(options, sources: sources).report
    }

    /// A scanned catalog item, for `HeadlessClean`.
    struct Scanned: Sendable {
        var item: CleanerItem
        var scan: ItemScan
    }

    /// `scan`, with each reported item's catalog item and scan (by id; absent for the Full Disk Access placeholders).
    static func scanned(_ options: Options, sources: Sources) async -> (report: Report, items: [String: Scanned]) {
        let hasAccess = sources.hasFullDiskAccess()
        let policy = sources.policy()
        let only = options.only.map(Set.init)
        let named = options.groups.map(Set.init)
        let off = sources.disabledGroups()
        func wanted(_ item: CleanerItem, in group: CleanerGroup) -> Bool {
            (only?.contains(item.id) ?? true) && (named?.contains(groupName(group.id)) ?? true)
        }
        // A group turned off in Settings is scanned only when asked for by name (its group or one of its items).
        let catalog = sources.smartScan(hasAccess).filter { group in
            !off.contains(group.id) || named?.contains(groupName(group.id)) == true
                || group.items.contains { only?.contains($0.id) == true }
        } + (options.privacy ? sources.privacy() : [])
        let groups = catalog.map { group in
            CleanerGroup(id: group.id, title: group.title, systemImage: group.systemImage,
                         items: group.items.filter { wanted($0, in: group) })
        }.filter { !$0.items.isEmpty }

        let overrides = sources.overrides()
        let apps = sources.runningApps()
        let processes = sources.processNames()
        let openFiles = OpenFiles(read: sources.readOpenFiles) // read when the first item needs it, if any does
        let openPaths: OpenPaths = { await openFiles.paths(under: $0) }
        let scanItem = sources.scanItem, blockedByExclusion = sources.blockedByExclusion
        let results = await withTaskGroup(of: (String, ItemScan, Bool).self) { tasks in
            for item in groups.flatMap(\.items) {
                tasks.addTask { (item.id, await scanItem(item, policy, openPaths), await blockedByExclusion(item, policy)) }
            }
            return await tasks.reduce(into: [String: (ItemScan, Bool)]()) { $0[$1.0] = ($1.1, $1.2) }
        }

        var items: [Item] = []
        var details: [String: Scanned] = [:]
        for group in groups {
            let scanned = group.items.compactMap { item -> (Item, Int)? in
                guard let (scan, blocked) = results[item.id],
                      item.showsWhenEmpty || scan.hasData || scan.permissionDenied || only?.contains(item.id) == true
                else { return nil }
                let running = item.runningBlocker(apps: apps.keys, processes: processes).map { apps[$0] ?? $0 }
                let report = report(item, group: group.id, scan: scan, blocked: blocked, running: running,
                                    selected: overrides[item.id] ?? item.selectedByDefault, home: policy.homeURL)
                details[item.id] = Scanned(item: item, scan: scan)
                return (report, scan.records ?? 0)
            }
            // Biggest first, as the app sorts results; ties keep catalog order.
            items += scanned.enumerated().sorted { a, b in
                let (ka, kb) = ((a.element.0.size, a.element.1), (b.element.0.size, b.element.1))
                return ka != kb ? ka > kb : a.offset < b.offset
            }.map(\.element.0)
        }
        // Named items that exist only with Full Disk Access: listed so the caller learns why they are missing.
        if !hasAccess, let only {
            let present = Set(groups.flatMap(\.items).map(\.id))
            for group in sources.smartScan(true) {
                for item in group.items where only.contains(item.id) && !present.contains(item.id)
                    && (named?.contains(groupName(group.id)) ?? true) {
                    items.append(Item(id: item.id, group: groupName(group.id), name: english(item.title), size: 0,
                                      sizeIsUpperBound: item.sizeIsUpperBound,
                                      selectedByDefault: overrides[item.id] ?? item.selectedByDefault,
                                      disposal: disposal(item), dataLoss: dataLossIDs.contains(item.id), locked: true,
                                      reason: needsAccess, entries: [],
                                      needsFullDiskAccess: true))
                }
            }
        }

        let counted = items.filter { $0.selectedByDefault && !$0.locked }
        let report = Report(version: sources.version(), fullDiskAccess: hasAccess,
                      scannedAt: sources.now().formatted(.iso8601),
                      total: counted.filter { !$0.sizeIsUpperBound }.reduce(0) { $0 + $1.size },
                      totalUpTo: counted.filter(\.sizeIsUpperBound).reduce(0) { $0 + $1.size }, items: items)
        return (report, details)
    }

    static let needsAccess = "Needs Full Disk Access"
    static let blockedReason = "Blocked by a folder in Exclusions"

    /// One scanned item as the app would show and clean it.
    static func report(_ item: CleanerItem, group: String, scan: ItemScan, blocked: Bool, running: String?, selected: Bool,
                       home: URL) -> Item {
        var reason: String?
        if let running {
            reason = "\(running) is running"
        } else if blocked {
            reason = blockedReason
        } else if scan.permissionDenied && !scan.hasData {
            reason = needsAccess
        } else if scan.allEntriesLocked {
            reason = scan.entries.first?.lockReason
        }
        let size = scan.allEntriesLocked ? scan.size : cleanable(item, scan).size
        let entries = scan.entries.sorted { $0.size > $1.size }
        return Item(id: item.id, group: groupName(group), name: english(item.title), size: size,
                    sizeIsUpperBound: item.sizeIsUpperBound, selectedByDefault: selected, disposal: disposal(item),
                    dataLoss: dataLossIDs.contains(item.id), locked: reason != nil, reason: reason,
                    entries: entries.prefix(maxEntries).map {
                        Entry(path: displayPath($0.url, home: home), size: $0.size, name: $0.title, records: $0.isDatabase ? $0.records : nil,
                              reason: $0.lockReason)
                    },
                    moreEntries: entries.count > maxEntries ? entries.count - maxEntries : nil,
                    records: scan.records, needsFullDiskAccess: scan.permissionDenied ? true : nil)
    }

    /// The scan as the app cleans it: without its locked entries (`SmartScanModel.selectedScan`).
    static func cleanable(_ item: CleanerItem, _ scan: ItemScan) -> ItemScan {
        guard scan.entries.contains(where: { $0.lockReason != nil }) else { return scan }
        var scan = scan
        scan.entries.removeAll { $0.lockReason != nil }
        if item.entryCommand != nil { scan.measuredSize = nil } // its entries are what is removed: their sum counts
        return scan
    }

    /// `~/…` for a path in `home`, else the full path.
    static func displayPath(_ url: URL, home: URL) -> String {
        let path = url.path
        // `resolvingSymlinksInPath` drops a leading /private (/private/var → /var): realpath gives the other spelling.
        let real = realpath(home.path, nil).map { pointer in defer { free(pointer) }; return String(cString: pointer) }
        for root in Set([home.path, home.standardizedFileURL.path, home.resolvingSymlinksInPath().path, real].compactMap { $0 }) {
            if path == root { return "~" }
            if path.hasPrefix(root + "/") { return "~/" + path.dropFirst(root.count + 1) }
        }
        return path
    }
}
