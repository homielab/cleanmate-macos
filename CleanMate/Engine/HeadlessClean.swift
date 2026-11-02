import Foundation

/// What `cleanmate clean` does: a fresh `HeadlessScan`, then a clean of the chosen items made like the app's Smart Scan
/// (`SmartScanModel.clean`): the same `Cleaner` (`SafetyPolicy`, Settings › Exclusions, open files, `SafeRemoval`),
/// running apps checked again, and the same activity log lines, so Settings › Activity and the Overview count it.
/// Items whose disposal is "trash" go to the Trash; the others (junk apps rebuild) are deleted. A dry run reports what
/// a clean would do and touches nothing. Field names are a contract shared with the Linux tool: change them only together.
nonisolated enum HeadlessClean {
    struct Skipped: Codable, Equatable, Sendable {
        /// `~/…` inside the home folder.
        var path: String
        var reason: String
    }

    struct Item: Codable, Equatable, Sendable {
        var id: String
        var name: String
        /// Bytes removed or moved to the Trash, measured by the scan; in a dry run, what a clean would remove.
        var freed: Int64
        /// Part of `freed` moved to the Trash.
        var trashed: Int64
        /// What was kept, and why.
        var skipped: [Skipped]
        /// May hold the user's data (`HeadlessScan.dataLossIDs`). Not named with `--only`, it is left `locked` with
        /// `HeadlessScan.dataLossReason`.
        var dataLoss = false
        /// Not cleaned at all; `reason` says why.
        var locked: Bool
        var reason: String?

        enum CodingKeys: String, CodingKey { case id, name, freed, trashed, skipped, dataLoss, locked, reason }

        /// `reason` is written as `null` when there is none (the contract's field is always present).
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(freed, forKey: .freed)
            try container.encode(trashed, forKey: .trashed)
            try container.encode(skipped, forKey: .skipped)
            try container.encode(dataLoss, forKey: .dataLoss)
            try container.encode(locked, forKey: .locked)
            try container.encode(reason, forKey: .reason)
        }
    }

    struct Report: Codable, Equatable, Sendable {
        var version: String
        var dryRun: Bool
        /// Bytes removed or moved to the Trash.
        var freed: Int64
        /// Part of `freed` from items whose size is only a maximum (the space really freed may be smaller).
        var upTo: Int64
        /// Part of `freed` moved to the Trash: still on disk until the Trash is emptied.
        var inTrash: Int64
        var items: [Item]
        /// The activity log (`~/…`); null in a dry run, which writes nothing.
        var log: String?

        enum CodingKeys: String, CodingKey { case version, dryRun, freed, upTo, inTrash, items, log }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(version, forKey: .version)
            try container.encode(dryRun, forKey: .dryRun)
            try container.encode(freed, forKey: .freed)
            try container.encode(upTo, forKey: .upTo)
            try container.encode(inTrash, forKey: .inTrash)
            try container.encode(items, forKey: .items)
            try container.encode(log, forKey: .log)
        }
    }

    /// The items a clean will go through, from a fresh scan.
    struct Plan: Sendable {
        struct Target: Sendable {
            /// The item as `cleanmate scan` reports it.
            var report: HeadlessScan.Item
            /// Absent for an item that exists only with Full Disk Access (reported locked).
            var scanned: HeadlessScan.Scanned?
            /// Ticked but not named, and it may hold data (`report.dataLoss`): reported, never cleaned.
            var heldForData = false
            var isPrivacy: Bool { report.group == "privacy" }
        }

        var version: String
        var home: URL
        var targets: [Target]

        /// Targets that will be cleaned (not locked or held, something found).
        var cleanable: [Target] {
            targets.filter { target in
                !target.report.locked && !target.heldForData && target.scanned.map { HeadlessScan.cleanable($0.item, $0.scan).hasData } == true
            }
        }

        /// Bytes the scan measured for the cleanable items deleted outright and moved to the Trash.
        var deleteSize: Int64 { cleanable.filter { $0.report.disposal != "trash" }.reduce(0) { $0 + $1.report.size } }
        var trashSize: Int64 { cleanable.filter { $0.report.disposal == "trash" }.reduce(0) { $0 + $1.report.size } }
        /// Ticked items left because they may hold data.
        var held: [Target] { targets.filter(\.heldForData) }
    }

    static let changedReason = "Changed since the scan"
    static let keptReason = "Kept by the safety checks: in use, modified since the scan or not permitted"

    /// Scans and picks the items to clean: the ones named with `--only`, else those ticked by default (the user's own
    /// ticks included) in the groups asked for. A Privacy item only when named (by id, or the privacy group); an item
    /// that may hold data only when named by id, never through a tick (it is listed, held).
    /// `options` must have passed `HeadlessScan.validate`.
    static func plan(_ options: HeadlessScan.Options, sources: HeadlessScan.Sources = HeadlessScan.Sources()) async -> Plan {
        let (report, scanned) = await HeadlessScan.scanned(options, sources: sources)
        let named = options.only.map(Set.init)
        let targets = report.items.compactMap { item -> Plan.Target? in
            var target = Plan.Target(report: item, scanned: scanned[item.id])
            if let named { return named.contains(item.id) ? target : nil }
            guard item.selectedByDefault, !target.isPrivacy || options.groups?.contains("privacy") == true else { return nil }
            target.heldForData = item.dataLoss
            // What the app would clean, plus the ticked items it can't, so the caller learns why.
            return item.locked || target.scanned?.scan.hasData == true ? target : nil
        }
        return Plan(version: report.version, home: sources.policy().homeURL, targets: targets)
    }

    /// Cleans `plan`'s items one by one, or only reports what it would do (`dryRun`). Running apps and open files are
    /// read again first: an app opened since the scan keeps its item.
    static func clean(_ plan: Plan, dryRun: Bool, sources: HeadlessScan.Sources = HeadlessScan.Sources()) async -> Report {
        let policy = sources.policy()
        let home = plan.home
        let apps = sources.runningApps()
        let processes = sources.processNames()
        // Read again for the clean, never the scan's table: files opened since the scan are kept.
        let openFiles = OpenFiles(maxAge: OpenFiles.cleanMaxAge, read: sources.readOpenFiles)
        let openPaths: OpenPaths = { await openFiles.paths(under: $0) }
        var report = Report(version: plan.version, dryRun: dryRun, freed: 0, upTo: 0, inTrash: 0, items: [],
                            log: dryRun ? nil : HeadlessScan.displayPath(ActivityLog.url(home: home), home: home))
        for target in plan.targets {
            var result = Item(id: target.report.id, name: target.report.name, freed: 0, trashed: 0, skipped: [],
                              dataLoss: target.report.dataLoss, locked: false, reason: nil)
            defer { report.items.append(result) }
            if target.heldForData {
                result.locked = true
                result.reason = HeadlessScan.dataLossReason(target.report.id)
                continue
            }
            let running = target.scanned?.item.runningBlocker(apps: apps.keys, processes: processes).map { apps[$0] ?? $0 }
            guard let scanned = target.scanned, !target.report.locked, running == nil else {
                let reason = target.report.reason ?? running.map { "\($0) is running" } ?? HeadlessScan.needsAccess
                result.locked = true
                result.reason = reason
                result.skipped = target.scanned.map { $0.scan.entries.map {
                    Skipped(path: HeadlessScan.displayPath($0.url, home: home), reason: $0.lockReason ?? reason)
                } } ?? []
                continue
            }
            let item = scanned.item
            // Entries locked by a running app (one profile of a browser…) stay, as in the app.
            result.skipped = scanned.scan.entries.compactMap { entry in
                entry.lockReason.map { Skipped(path: HeadlessScan.displayPath(entry.url, home: home), reason: $0) }
            }
            let todo = HeadlessScan.cleanable(item, scanned.scan)
            guard todo.hasData else { continue }
            let freed: Int64, upTo: Int64
            if dryRun {
                freed = todo.size
                upTo = item.sizeIsUpperBound ? freed : 0
            } else {
                let cleaned = await Cleaner.clean(item, scan: todo, policy: policy, trash: sources.trash, openPaths: openPaths)
                freed = cleaned.freed
                upTo = cleaned.upTo
                result.skipped += kept(item, todo, cleaned, home: home)
                // The app's lines (`SmartScanModel.clean`): one per item, and one per entry that changed since the scan.
                let module: LocalizedStringResource = target.isPrivacy ? "Privacy" : "Smart Scan"
                let removed = Cleaner.removedCount(item, todo, cleaned)
                if cleaned.freed > 0 || removed > 0 {
                    ActivityLog.record(module: module, item: ActivityLog.english(item.title), count: removed,
                                       size: cleaned.freed, mode: item.mode, home: home)
                }
                TrashRecords.add(cleaned.trashed, module: module, home: home) { _ in ActivityLog.english(item.title) }
                for url in cleaned.changed { ActivityLog.recordSkipped(module: module, item: url.path, home: home) }
                for url in cleaned.failed { ActivityLog.recordFailed(module: module, item: url.path, home: home) }
            }
            result.freed = freed
            result.trashed = item.mode == .trash ? freed : 0
            report.freed += freed
            report.upTo += upTo
            report.inTrash += result.trashed
        }
        return report
    }

    /// What the cleaner kept of `scan`, with a reason: entries that changed since the scan, then entries still on
    /// disk. The cleaner only counts the others (a tool's command failed, parts of an entry), so an item it kept
    /// something of without a listed entry gets one line for its folder.
    static func kept(_ item: CleanerItem, _ scan: ItemScan, _ report: CleanReport, home: URL) -> [Skipped] {
        let changed = Set(report.changed.map(\.path))
        var kept = report.changed.map { Skipped(path: HeadlessScan.displayPath($0, home: home), reason: changedReason) }
        guard report.skipped > kept.count else { return kept }
        // Entries are what is removed only for plain file items; a tool's entries may be display-only.
        let removesEntries = item.command == nil && item.database == nil && item.entryParts == nil && !item.externalTrash
            || item.entryCommand != nil
        if removesEntries {
            for entry in scan.entries where !changed.contains(entry.url.path) && exists(entry.url) {
                kept.append(Skipped(path: HeadlessScan.displayPath(entry.url, home: home), reason: keptReason))
            }
        }
        if kept.count == report.changed.count {
            kept.append(Skipped(path: item.paths.first ?? item.id, reason: keptReason))
        }
        return kept
    }

    /// Something is at `url` (a symlink counts, not followed).
    private static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }
}
