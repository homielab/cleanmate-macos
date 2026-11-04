import Foundation

/// What `cleanmate uninstall` does, like the app's Uninstaller: lists the apps it may remove (name, bundle id, source,
/// size of the app and of its data, last used) and the data left by apps already removed, and uninstalls one app the
/// same way (`Uninstaller.trash`): the app and its own data (`.data` entries, as a batch uninstall takes them; never
/// suggestions or config) go to the Trash, launch agents among them are stopped, a Homebrew cask's record is cleared,
/// every move is logged and kept in `TrashRecords` so `cleanmate restore` puts it back. An open app is never moved; an
/// app macOS won't let CleanMate move (an App Store app owned by root) is left, never with a password prompt.
nonisolated enum HeadlessApps {
    // MARK: - Reports

    struct App: Codable, Equatable, Sendable {
        var name: String
        var bundleId: String
        var path: String
        var version: String?
        /// "appStore", "homebrew", "setapp" or "downloaded" (`InstalledApp.Source`).
        var source: String
        /// Bytes of the app bundle.
        var size: Int64
        /// Bytes of its data in ~/Library and its config in ~, ~/.config and ~/.local/share: everything its detail in
        /// the app lists, suggestions included.
        var dataSize: Int64
        /// ISO 8601; null when nothing tells.
        var lastUsed: String?
        /// `lastUsed` is the newest change of its data (Spotlight doesn't know), so only an estimate.
        var lastUsedIsEstimate: Bool
        /// Open now: `uninstall` leaves it unless `--quit`.
        var running: Bool

        enum CodingKeys: String, CodingKey {
            case name, bundleId, path, version, source, size, dataSize, lastUsed, lastUsedIsEstimate, running
        }

        /// Absent values are written as `null`.
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(bundleId, forKey: .bundleId)
            try container.encode(path, forKey: .path)
            try container.encode(version, forKey: .version)
            try container.encode(source, forKey: .source)
            try container.encode(size, forKey: .size)
            try container.encode(dataSize, forKey: .dataSize)
            try container.encode(lastUsed, forKey: .lastUsed)
            try container.encode(lastUsedIsEstimate, forKey: .lastUsedIsEstimate)
            try container.encode(running, forKey: .running)
        }
    }

    /// Data in ~/Library, or a config folder, that belongs to an app (or an app no longer installed).
    struct DataItem: Codable, Equatable, Sendable {
        /// `~/…`.
        var path: String
        var size: Int64
        /// "data": surely the app's; "suggested": only starts like its name; "config": in ~, ~/.config or
        /// ~/.local/share. Leftovers of removed apps are "data" or "config".
        var kind: String
    }

    /// `cleanmate uninstall`: the apps (none with `--leftovers`) and the leftovers of removed apps.
    struct ListReport: Codable, Equatable, Sendable {
        var version: String
        var fullDiskAccess: Bool
        var durationMs: Int
        /// Sorted by name.
        var apps: [App]
        /// Largest first.
        var leftovers: [DataItem]
        var leftoversSize: Int64
    }

    /// One thing `uninstall` moved (or would move) to the Trash.
    struct Moved: Codable, Equatable, Sendable {
        /// `~/…` inside the home folder.
        var path: String
        var size: Int64
        /// "app", "data" or "config".
        var kind: String
        /// Where it is now in the Trash: the argument for `cleanmate restore`. Null in a dry run or when not moved.
        var trashed: String?
        var skipped: Bool
        var reason: String?

        enum CodingKeys: String, CodingKey { case path, size, kind, trashed, skipped, reason }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(path, forKey: .path)
            try container.encode(size, forKey: .size)
            try container.encode(kind, forKey: .kind)
            try container.encode(trashed, forKey: .trashed)
            try container.encode(skipped, forKey: .skipped)
            try container.encode(reason, forKey: .reason)
        }
    }

    /// `cleanmate uninstall APP` and `uninstall --leftovers PATH…`.
    struct UninstallReport: Codable, Equatable, Sendable {
        var version: String
        var dryRun: Bool
        var durationMs: Int
        /// The app uninstalled (or whose data went with `--leftovers-only`); null for leftovers of removed apps.
        var app: App?
        /// Items moved to the Trash (in a dry run: to move), and their bytes.
        var count: Int
        var size: Int64
        var items: [Moved]
        /// The app's data that is not taken: suggestions and config, which may be another app's. Check them in the app.
        var notRemoved: [DataItem]
        /// Homebrew casks whose app went to the Trash but whose record `brew uninstall --cask` didn't clear.
        var casksLeft: [String]
        /// The activity log (`~/…`); null in a dry run, which writes nothing.
        var log: String?

        enum CodingKeys: String, CodingKey { case version, dryRun, durationMs, app, count, size, items, notRemoved, casksLeft, log }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(version, forKey: .version)
            try container.encode(dryRun, forKey: .dryRun)
            try container.encode(durationMs, forKey: .durationMs)
            try container.encode(app, forKey: .app)
            try container.encode(count, forKey: .count)
            try container.encode(size, forKey: .size)
            try container.encode(items, forKey: .items)
            try container.encode(notRemoved, forKey: .notRemoved)
            try container.encode(casksLeft, forKey: .casksLeft)
            try container.encode(log, forKey: .log)
        }
    }

    struct Options: Equatable, Sendable {
        /// Name, bundle id or path of the app.
        var app: String
        /// Only the app's data; the app and its launch agents stay (the app's Reset).
        var leftoversOnly = false
        /// Ask an open app to quit first, and wait for it as the app's "Quit and Uninstall" does.
        var quit = false
        var dryRun = false
        var yes = false
    }

    // MARK: - list

    /// Every app the Uninstaller lists, measured, and the leftovers of removed apps (only those with `leftoversOnly`).
    /// Read-only. Without Full Disk Access the folders macOS protects are not read, as in the app.
    static func list(leftoversOnly: Bool = false, sources: HeadlessScan.Sources) async -> ListReport {
        let started = ContinuousClock.now
        let policy = sources.policy()
        let hasAccess = sources.hasFullDiskAccess()
        let running = sources.runningApps()
        var apps: [App] = []
        if !leftoversOnly {
            let installed = await sources.installedApps(policy)
            let ids = Uninstaller.allBundleIDs(policy: policy).union(running.keys).union(installed.map(\.bundleID))
            let skipped = ProtectedFolders.skipped(home: policy.homeURL, hasFullDiskAccess: hasAccess)
            let matches = await Uninstaller.dataMatches(of: installed, otherBundleIDs: ids, skipped: skipped,
                                                        allApps: Uninstaller.allAppURLs(policy: policy), policy: policy)
            let sizes = await measure(Set(installed.map(\.url)).union(matches.values.joined()))
            apps = installed.map { app in
                summary(app, size: sizes[app.url] ?? 0, dataSize: (matches[app.url] ?? []).reduce(0) { $0 + (sizes[$1] ?? 0) },
                        running: running[app.bundleID] != nil, home: policy.homeURL)
            }
        }
        let leftovers = await removedAppsData(sources: sources).map { item($0, home: policy.homeURL) }
        return ListReport(version: sources.version(), fullDiskAccess: hasAccess,
                          durationMs: HeadlessScan.milliseconds(ContinuousClock.now - started), apps: apps,
                          leftovers: leftovers, leftoversSize: leftovers.reduce(0) { $0 + $1.size })
    }

    /// Data of apps no longer installed, as the app's "Leftovers of Removed Apps" lists it.
    static func removedAppsData(sources: HeadlessScan.Sources) async -> [AppDataEntry] {
        let policy = sources.policy()
        let installed = Uninstaller.allBundleIDs(policy: policy).union(sources.runningApps().keys)
        return await Uninstaller.leftovers(installedBundleIDs: installed, isRegistered: sources.isRegistered, policy: policy)
    }

    /// Allocated sizes of `urls`, measured at the same time.
    static func measure(_ urls: Set<URL>) async -> [URL: Int64] {
        await withTaskGroup(of: (URL, Int64).self) { group in
            for url in urls { group.addTask { (url, await Uninstaller.size(of: url)) } }
            return await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
        }
    }

    static func summary(_ app: InstalledApp, size: Int64, dataSize: Int64, running: Bool, home: URL) -> App {
        App(name: app.name, bundleId: app.bundleID, path: app.url.path, version: app.version, source: app.source.rawValue,
            size: size, dataSize: dataSize, lastUsed: app.lastUsed?.formatted(.iso8601),
            lastUsedIsEstimate: app.lastUsedIsEstimate, running: running)
    }

    static func item(_ entry: AppDataEntry, home: URL) -> DataItem {
        DataItem(path: HeadlessScan.displayPath(entry.url, home: home), size: entry.size, kind: kind(entry.kind))
    }

    static func kind(_ kind: AppDataEntry.Kind) -> String {
        switch kind {
        case .data: "data"
        case .suggested: "suggested"
        case .config: "config"
        }
    }

    // MARK: - Finding the app

    enum Match: Equatable {
        case found(InstalledApp)
        case notFound(similar: [String])
        case ambiguous([InstalledApp])
    }

    /// The app named by `query`: its bundle id, any name it goes by (`Visual Studio Code`, `Code`; `.app` optional),
    /// or the path of its bundle, all without regard to case.
    static func find(_ query: String, in apps: [InstalledApp], home: URL) -> Match {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        var found: [InstalledApp]
        if trimmed.contains("/") {
            let path = SafetyPolicy.normalize(HeadlessFiles.resolve(trimmed, home: home)).lowercased()
            found = apps.filter { SafetyPolicy.normalize($0.url).lowercased() == path }
        } else {
            let name = trimmed.lowercased().hasSuffix(".app") ? String(trimmed.dropLast(4)).lowercased() : trimmed.lowercased()
            found = apps.filter { $0.bundleID.lowercased() == trimmed.lowercased() }
            if found.isEmpty { found = apps.filter { $0.names.contains { $0.lowercased() == name } } }
        }
        switch found.count {
        case 1: return .found(found[0])
        case 0:
            let word = trimmed.lowercased()
            let similar = apps.filter { $0.name.lowercased().contains(word) || $0.bundleID.lowercased().contains(word) }
            return .notFound(similar: similar.prefix(5).map(\.name))
        default: return .ambiguous(found)
        }
    }

    // MARK: - uninstall

    /// What `uninstall APP` will take, worked out before anything moves.
    struct Plan: Sendable {
        var app: InstalledApp
        var summary: App
        /// The app's own data (`.data`): goes with it.
        var data: [AppDataEntry]
        /// Suggestions and config: listed, never taken.
        var notTaken: [AppDataEntry]
        var leftoversOnly: Bool
        var appSize: Int64

        var size: Int64 { (leftoversOnly ? 0 : appSize) + data.reduce(0) { $0 + $1.size } }
        var count: Int { (leftoversOnly ? 0 : 1) + data.count }
    }

    /// The app's data as its detail in the app lists it: every other installed or running app (Apple's, nested and
    /// unlisted ones too) shields its own.
    static func plan(_ app: InstalledApp, among apps: [InstalledApp], leftoversOnly: Bool, sources: HeadlessScan.Sources) async -> Plan {
        let policy = sources.policy()
        let running = sources.runningApps()
        let others = apps.filter { $0.url != app.url }
        let ids = Uninstaller.allBundleIDs(policy: policy).union(running.keys).union(others.map(\.bundleID))
        let names = Set(others.flatMap(\.names))
            .union(Uninstaller.otherAppNames(than: app.url, in: Uninstaller.allAppURLs(policy: policy)))
        let data = await Uninstaller.data(of: app, otherBundleIDs: ids, otherAppNames: names, policy: policy)
        // Like the app's Reset, data only keeps the app's launch agents: they go with its login items.
        let own = data.filter { $0.kind == .data && !(leftoversOnly && $0.folder == "LaunchAgents") }
        let appSize = await Uninstaller.size(of: app.url)
        let summary = summary(app, size: appSize, dataSize: data.reduce(0) { $0 + $1.size }, running: running[app.bundleID] != nil,
                              home: policy.homeURL)
        return Plan(app: app, summary: summary, data: own, notTaken: data.filter { !own.contains($0) },
                    leftoversOnly: leftoversOnly, appSize: appSize)
    }

    /// Why the app stayed (`Uninstaller.trash` threw), and the exit code: the app's own words.
    static func failure(_ error: Uninstaller.AppTrashError, app: InstalledApp, running: Bool) -> (message: String, isRunning: Bool) {
        if running { return (runningMessage(app.name), true) }
        let reason = switch error {
        case .appStore:
            "\(app.name) came from the App Store, and macOS only lets you remove it yourself: remove it in Launchpad or "
                + "drag it to the Trash in Finder. Its data then shows in `cleanmate uninstall --leftovers`."
        case .locked:
            "\(app.name) is locked in Finder. Select it, choose File > Get Info, turn off Locked, then try again."
        case .brewBusy:
            "\(app.name) was installed with Homebrew, and a brew command is running now. Wait until it finishes, then try again."
        case .notTrashed, .cancelled:
            "\(app.name) couldn’t be moved to the Trash: it may belong to the system or another user. Drag it to the Trash "
                + "in Finder, which asks for your password, then remove its leftovers with `cleanmate uninstall --leftovers`."
        }
        return (reason + " Nothing was moved.", false)
    }

    static func runningMessage(_ name: String) -> String {
        "\(name) is open: quit it, then uninstall it, or add --quit to ask it to quit first. Nothing was moved."
    }

    /// Never asks for a password: an app the user can't move is left (`.appStore` or `.notTrashed`).
    static let refuseRecycle: @Sendable (URL) async throws -> URL? = { _ in throw CocoaError(.fileWriteNoPermission) }

    /// Moves the plan's app (unless `leftoversOnly`) and data to the Trash through `Uninstaller.trash`, the app's path,
    /// with the open check made right before the app moves.
    static func uninstall(_ plan: Plan, sources: HeadlessScan.Sources) async throws(Uninstaller.AppTrashError) -> CleanReport {
        let policy = sources.policy()
        let app = plan.leftoversOnly ? nil : plan.app.url
        let id = plan.app.bundleID
        return try await Uninstaller.trash(
            app: app, data: plan.data, policy: policy, cask: app.flatMap { HomebrewCasks.cask(for: $0) },
            appStore: app.map(Uninstaller.hasAppStoreReceipt) ?? false, launchctl: sources.launchctl,
            moveToTrash: sources.trash, recycle: refuseRecycle, isRunning: { _ in sources.runningApps()[id] != nil })
    }

    /// The report of a move (`report` nil: a dry run) of `app` (nil for leftovers) and `data`.
    static func report(app: (url: URL, size: Int64)?, data: [AppDataEntry], summary: App?, notTaken: [AppDataEntry],
                       moved report: CleanReport?, started: ContinuousClock.Instant, sources: HeadlessScan.Sources) -> UninstallReport {
        let home = sources.policy().homeURL
        let targets = (app.map { [(url: $0.url, size: $0.size, kind: "app")] } ?? [])
            + data.map { (url: $0.url, size: $0.size, kind: $0.kind == .config ? "config" : "data") }
        var result = UninstallReport(version: sources.version(), dryRun: report == nil, durationMs: 0, app: summary, count: 0,
                                     size: 0, items: [], notRemoved: notTaken.map { item($0, home: home) },
                                     casksLeft: report?.casksLeft ?? [],
                                     log: report == nil ? nil : HeadlessScan.displayPath(ActivityLog.url(home: home), home: home))
        for target in targets {
            var moved = Moved(path: HeadlessScan.displayPath(target.url, home: home), size: target.size, kind: target.kind,
                              trashed: nil, skipped: false, reason: nil)
            if let report {
                if let trashed = report.trashed.first(where: { $0.original == target.url }) {
                    moved.trashed = trashed.inTrash.path
                } else if let failure = report.failures.first(where: { $0.url == target.url }) {
                    moved.skipped = true
                    moved.reason = failure.reason == .changed ? HeadlessClean.changedReason : failure.reason.english
                }
            }
            if !moved.skipped {
                result.count += 1
                result.size += target.size
            }
            result.items.append(moved)
        }
        result.durationMs = HeadlessScan.milliseconds(ContinuousClock.now - started)
        return result
    }

    // MARK: - Leftovers of removed apps

    static let notLeftover = "Not a leftover of a removed app: see `cleanmate uninstall --leftovers`"

    /// The leftovers named by `arguments` (each must be listed by `removedAppsData`), and the others with why not.
    static func pickLeftovers(_ arguments: [String], sources: HeadlessScan.Sources) async -> (picked: [AppDataEntry], refused: [Moved]) {
        let home = sources.policy().homeURL
        let leftovers = await removedAppsData(sources: sources)
        var byPath: [String: AppDataEntry] = [:]
        for entry in leftovers { byPath[SafetyPolicy.normalize(entry.url).lowercased()] = entry }
        var picked: [AppDataEntry] = [], refused: [Moved] = [], seen = Set<String>()
        for argument in arguments {
            let url = HeadlessFiles.resolve(argument, home: home)
            let key = SafetyPolicy.normalize(url).lowercased()
            guard seen.insert(key).inserted else { continue }
            if let entry = byPath[key] {
                picked.append(entry)
            } else {
                refused.append(Moved(path: HeadlessScan.displayPath(url, home: home), size: 0, kind: "data", trashed: nil,
                                     skipped: true, reason: notLeftover))
            }
        }
        return (picked, refused)
    }
}
