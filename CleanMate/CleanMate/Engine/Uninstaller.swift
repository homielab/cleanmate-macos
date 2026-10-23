import AppKit

// Uninstaller: apps in /Applications and ~/Applications (and up to two subfolders down) plus their data in ~/Library, and data left behind
// by apps already removed. Everything goes to the Trash; Apple's apps and data are never listed.

nonisolated struct InstalledApp: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let bundleID: String
    let version: String?
    /// Spotlight's last-used date, when known.
    let lastUsed: Date?

    var id: URL { url }
}

/// One item directly inside a ~/Library data folder (`SafetyPolicy.appDataFolders`).
nonisolated struct AppDataEntry: Identifiable, Hashable, Sendable {
    let url: URL
    let size: Int64

    var id: URL { url }
    var folder: String { url.deletingLastPathComponent().lastPathComponent }
}

nonisolated enum AppMatcher {
    /// Folders where a folder named exactly like the app also counts (vendors use bundle ids elsewhere).
    static let nameFolders: Set = ["Application Support", "Caches", "Logs"]
    /// Names shared by several apps of a vendor or too vague to belong to one app.
    static let genericNames: Set = [
        "google", "microsoft", "apple", "adobe", "mozilla", "jetbrains", "electron", "java", "oracle", "common", "shared",
        "default", "helper", "update", "updater", "crashpad", "crashreporter", "cache", "caches", "logs", "data", "temp",
        "plugins", "support", "settings", "config",
        "homebrew",  // the `brew` CLI's own Logs/Caches folders, not a Homebrew GUI app's
    ]
    /// `bundleID.<channel>` is a sibling app of another release channel (`com.google.Chrome.canary`,
    /// `com.google.chrome.for.testing`), not this app's data, even when that sibling isn't in /Applications.
    static let releaseChannels = ["beta", "canary", "dev", "nightly", "alpha", "preview", "insiders", "for.testing"]

    /// The lowercased identifier an entry name stands for: without `.plist`/`.savedState`/`.binarycookies`, and in
    /// Group Containers without the `group.` / `<TEAMID>.` / `<TEAMID>.groups.` prefix.
    static func identifier(_ name: String, in folder: String) -> String {
        var id = name
        for ext in [".plist", ".savedState", ".binarycookies"] where id.lowercased().hasSuffix(ext.lowercased()) {
            id = String(id.dropLast(ext.count))
        }
        if folder == "Group Containers" {
            let parts = id.split(separator: ".", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[0].count == 10, parts[0].allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) {
                id = parts[1]
            }
            for prefix in ["groups.", "group."] where id.lowercased().hasPrefix(prefix) { id = String(id.dropFirst(prefix.count)) }
        }
        return id.lowercased()
    }

    /// `id` is `bundleID` itself or `bundleID.something` (`com.foo.App.helper`), never just a shared prefix.
    static func belongs(_ id: String, to bundleID: String) -> Bool {
        let bundleID = bundleID.lowercased()
        return id == bundleID || id.hasPrefix(bundleID + ".")
    }

    static func isDistinctive(_ appName: String) -> Bool {
        appName.count >= 4 && !genericNames.contains(appName.lowercased())
    }

    /// Whether the entry `name` in Library `folder` belongs to the app: by bundle id (unless a longer installed bundle
    /// id claims it, e.g. `com.foo.App.Pro`), or — only in `nameFolders` — a folder named exactly like a distinctive app
    /// that no other installed app shares (same name, or a family name such as `Barista` for `Barista Pro`).
    static func matches(name: String, folder: String, bundleID: String, appName: String, otherBundleIDs: Set<String>,
                        otherAppNames: Set<String> = []) -> Bool {
        guard !SafetyPolicy.isApple(name) else { return false }
        return matches(id: identifier(name, in: folder), name: name, folder: folder, bundleID: bundleID, appName: appName,
                       otherBundleIDs: otherBundleIDs, otherAppNames: otherAppNames)
    }

    /// `matches` for a non-Apple `name` whose `identifier` is `id`, computed once per entry by the scan of every app.
    static func matches(id: String, name: String, folder: String, bundleID: String, appName: String,
                        otherBundleIDs: Set<String>, otherAppNames: Set<String>) -> Bool {
        if belongs(id, to: bundleID) {
            let rest = id.dropFirst(bundleID.count + 1)
            if releaseChannels.contains(where: { rest == $0 || rest.hasPrefix($0 + ".") }) { return false }
            return !otherBundleIDs.contains { other in
                other.count > bundleID.count && belongs(other.lowercased(), to: bundleID) && belongs(id, to: other)
            }
        }
        guard nameFolders.contains(folder), isDistinctive(appName), name.caseInsensitiveCompare(appName) == .orderedSame
        else { return false }
        // Checked last: the scan of every app's data calls this for each app × entry.
        let lowerName = appName.lowercased()
        return !otherAppNames.contains { $0.lowercased() == lowerName || $0.lowercased().hasPrefix(lowerName + " ") }
    }

    /// Vendors of system parts, CLI tools and SDKs shared by many apps (Shortcuts is `is.workflow`, Sparkle, analytics
    /// SDKs…): their data is never offered as a leftover, an installed app may still use it.
    static let sharedVendors: Set = [
        "is.workflow", "org.cups", "org.webkit", "org.swift", "org.llvm", "org.python", "net.java", "main.kts",
        "org.sparkle-project", "com.segment", "com.firebase", "com.crashlytics", "io.branch", "io.sentry", "io.macfuse",
    ]

    /// Reverse-DNS with at least three parts (`com.vendor.app`), so plain names never count as leftovers.
    static func isBundleIDShaped(_ id: String) -> Bool {
        id.wholeMatch(of: /[a-z]{2,}(\.[a-z0-9_-]+){2,}/) != nil
    }

    /// `com.vendor` of a bundle id.
    static func vendor(_ id: String) -> String {
        id.lowercased().split(separator: ".").prefix(2).joined(separator: ".")
    }

    /// Left behind by a removed app: named after a bundle id (not Apple's) of a vendor with no installed or running
    /// app (shared vendor data such as updaters stays), and unknown to LaunchServices. `tools`: lowercased names of
    /// installed or running command-line tools; a bundle id ending in one (`org.foo.tool`, as the Rust `directories`
    /// crate names config folders) is that tool's live data, not a leftover.
    static func isLeftover(name: String, folder: String, installedBundleIDs: Set<String>, tools: Set<String> = [],
                           isRegistered: (String) -> Bool) -> Bool {
        guard !SafetyPolicy.isApple(name) else { return false }
        let id = identifier(name, in: folder)
        guard isBundleIDShaped(id), let last = id.split(separator: ".").last, !tools.contains(String(last)) else { return false }
        let vendor = vendor(id)
        return !sharedVendors.contains(vendor) && !installedBundleIDs.contains { Self.vendor($0) == vendor } && !isRegistered(id)
    }
}

nonisolated enum Uninstaller {
    /// Apps that may be uninstalled (`SafetyPolicy.allowsApp`), sorted by name.
    @concurrent static func installedApps(policy: SafetyPolicy = .current) async -> [InstalledApp] {
        var apps: [InstalledApp] = []
        for folder in policy.applicationFolders {
            for url in appURLs(in: folder) where policy.allowsApp(url) {
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
                apps.append(InstalledApp(
                    url: url, name: url.deletingPathExtension().lastPathComponent, bundleID: id,
                    version: bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
                    lastUsed: NSMetadataItem(url: url)?.value(forAttribute: "kMDItemLastUsedDate") as? Date))
            }
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Allocated size of a file or folder (symlinks not followed).
    @concurrent static func size(of url: URL) async -> Int64 {
        await Scanner.entry(at: url, olderThan: nil, splitDepth: Scanner.splitDepth)?.size ?? 0
    }

    /// `.app` bundles in `folder` and up to `depth` plain subfolders down (`Vendor/App.app`); never looks inside a
    /// bundle, so helper apps nested in another app are not listed.
    static func appURLs(in folder: URL, depth: Int = SafetyPolicy.appSubfolderDepth) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                 options: .skipsHiddenFiles)) ?? []
        return urls.flatMap { url -> [URL] in
            if url.pathExtension == "app" { return [url] }
            guard depth > 0, let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isDirectory == true, values.isPackage != true else { return [] }  // symlinks aren't directories here
            return appURLs(in: url, depth: depth - 1)
        }
    }

    /// Bundle ids of every app on the Mac we can see (including Apple's and apps in subfolders such as Utilities or
    /// `Vendor/App.app`), to tell leftovers from live data.
    static func allBundleIDs(policy: SafetyPolicy = .current) -> Set<String> {
        Set(allAppURLs(policy: policy).compactMap { Bundle(url: $0)?.bundleIdentifier })
    }

    /// Every app bundle `allBundleIDs` reads, also the ones not listed (Apple's, excluded in Settings): their names
    /// shield name-matched data like their ids do.
    static func allAppURLs(policy: SafetyPolicy = .current) -> [URL] {
        (policy.applicationFolders + [URL(fileURLWithPath: "/System/Applications")]).flatMap { appURLs(in: $0) }
    }

    /// Names of `allAppURLs` other than `app`, for `otherAppNames`.
    static func otherAppNames(than app: URL, in urls: [URL]) -> Set<String> {
        Set(urls.filter { $0 != app }.map { $0.deletingPathExtension().lastPathComponent })
    }

    /// Allowed items directly in each `appDataFolders` folder: (folder, name, url). Folders in `skipped`
    /// (`ProtectedFolders` without Full Disk Access) are not listed.
    private static func dataFolderItems(policy: SafetyPolicy, skipped: Set<String> = []) -> [(folder: String, name: String, url: URL)] {
        SafetyPolicy.appDataFolders.flatMap { folder in
            let dir = policy.homeURL.appending(path: "Library/\(folder)")
            guard !ProtectedFolders.contains(skipped, dir) else { return [(folder: String, name: String, url: URL)]() }
            return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .map { (folder: folder, name: $0, url: dir.appending(path: $0)) }
                .filter { policy.allowsAppData($0.url) }
        }
    }

    private static func dataEntries(policy: SafetyPolicy, where keep: (String, String) -> Bool) async -> [AppDataEntry] {
        var entries: [AppDataEntry] = []
        for item in dataFolderItems(policy: policy) where keep(item.name, item.folder) {
            entries.append(AppDataEntry(url: item.url, size: await size(of: item.url)))
        }
        return entries.sorted { $0.size > $1.size }
    }

    /// The app's data in ~/Library, largest first. `otherBundleIDs`/`otherAppNames`: every other installed or running app,
    /// whose data must never be picked.
    @concurrent static func data(of app: InstalledApp, otherBundleIDs: Set<String>, otherAppNames: Set<String> = [],
                                 policy: SafetyPolicy = .current) async -> [AppDataEntry] {
        await dataEntries(policy: policy) {
            AppMatcher.matches(name: $0, folder: $1, bundleID: app.bundleID, appName: app.name, otherBundleIDs: otherBundleIDs,
                               otherAppNames: otherAppNames)
        }
    }

    /// For every app, the ~/Library entries `data(of:)` would list for it (same `AppMatcher` rule; other app names are
    /// the other apps in `apps`), from ONE listing of `appDataFolders` for all apps. Never measures sizes.
    /// `skipped`: folders not to list (`ProtectedFolders` without Full Disk Access: listing them would prompt).
    /// `allApps`: app bundles not in `apps` whose names count too (`allAppURLs`).
    @concurrent static func dataMatches(of apps: [InstalledApp], otherBundleIDs: Set<String>, skipped: Set<String> = [],
                                        allApps: [URL] = [], policy: SafetyPolicy = .current) async -> [URL: [URL]] {
        // Per-entry work done once, not once per app.
        let items = dataFolderItems(policy: policy, skipped: skipped).filter { !SafetyPolicy.isApple($0.name) }
            .map { (id: AppMatcher.identifier($0.name, in: $0.folder), name: $0.name, folder: $0.folder, url: $0.url) }
        var result: [URL: [URL]] = [:]
        for app in apps {
            let names = Set(apps.lazy.filter { $0.url != app.url }.map(\.name)).union(otherAppNames(than: app.url, in: allApps))
            result[app.url] = items.filter {
                AppMatcher.matches(id: $0.id, name: $0.name, folder: $0.folder, bundleID: app.bundleID, appName: app.name,
                                   otherBundleIDs: otherBundleIDs, otherAppNames: names)
            }.map(\.url)
        }
        return result
    }

    /// Bin folders of package managers and language toolchains; `~` is the policy's home. The process `PATH` is added
    /// too (a GUI app's is short, so these are listed explicitly).
    static let toolFolders = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/opt/local/bin", "~/.cargo/bin",
                              "~/.local/bin", "~/go/bin", "~/.bun/bin", "~/.deno/bin", "~/.npm-global/bin", "~/bin"]

    /// macOS's own command folders (`installer`, `chat`, `stats`…): their names say nothing about which apps a user has,
    /// so leftovers skip them (`userToolFolders`); Hidden config still counts them (`~/.config/git`).
    static let systemToolFolders = ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/libexec", "/System", "/Library/Apple",
                                    "/var/run/com.apple.security.cryptexd", "/private/var/run/com.apple.security.cryptexd"]

    /// `toolFolders` + the process `PATH`, minus `systemToolFolders`: what the leftovers rule matches tool names against.
    static var userToolFolders: [String] {
        (toolFolders + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init))
            .filter { !isSystemToolFolder($0) }
    }

    static func isSystemToolFolder(_ path: String) -> Bool {
        let path = path.hasSuffix("/") ? String(path.dropLast()) : path
        return systemToolFolders.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Lowercased names of command-line tools installed in `folders` or `running`, whose data is never a leftover.
    /// Vague names (`helper`, `updater`…, `AppMatcher.genericNames`) are left out: every app runs one.
    static func commandLineTools(home: URL, folders: [String] = toolFolders
                                     + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init),
                                 running: Set<String> = RunningProcesses.names()) -> Set<String> {
        var tools = Set(running.map { $0.lowercased() })
        for folder in folders where !folder.isEmpty {
            let path = folder.hasPrefix("~/") ? home.appending(path: String(folder.dropFirst(2))).path : folder
            for name in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] { tools.insert(name.lowercased()) }
        }
        return tools.subtracting(AppMatcher.genericNames)
    }

    /// Data in ~/Library of apps that are no longer installed, largest first. `tools` defaults to `commandLineTools`.
    @concurrent static func leftovers(installedBundleIDs: Set<String>, tools: Set<String>? = nil,
                                      isRegistered: @Sendable (String) -> Bool,
                                      policy: SafetyPolicy = .current) async -> [AppDataEntry] {
        let agents = policy.homeURL.appending(path: "Library/LaunchAgents")
        let tools = tools ?? commandLineTools(home: policy.homeURL, folders: userToolFolders)
        return await dataEntries(policy: policy) {
            AppMatcher.isLeftover(name: $0, folder: $1, installedBundleIDs: installedBundleIDs, tools: tools,
                                  isRegistered: isRegistered)
                && ($1 != "LaunchAgents" || !agentIsActive(agents.appending(path: $0)))
        }
    }

    /// A launch agent whose program still exists (or can't be read) is in use, whoever installed it.
    static func agentIsActive(_ plist: URL) -> Bool {
        guard let dict = LaunchAgents.read(plist),
              let program = LaunchAgents.info(dict, fileName: plist.lastPathComponent).program,
              program.hasPrefix("/") || program.hasPrefix("~") else { return true }
        return FileManager.default.fileExists(atPath: (program as NSString).expandingTildeInPath)
    }

    /// `launchctl bootout` by label for each plist directly in ~/Library/LaunchAgents (never /Library: needs admin) that
    /// `allowsLaunchAgent` and whose `Label` is its file name: a plist naming another service (another app's, Apple's)
    /// or a symlink is only trashed, never booted out, so no other app's agent is stopped.
    static func bootOutAgents(in data: [AppDataEntry], policy: SafetyPolicy, run: LaunchAgents.Runner) async {
        for entry in data where entry.url.pathExtension == "plist" {
            guard let dict = LaunchAgents.read(entry.url) else { continue }
            let label = LaunchAgents.info(dict, fileName: entry.url.lastPathComponent).label
            guard label.caseInsensitiveCompare(entry.url.deletingPathExtension().lastPathComponent) == .orderedSame,
                  policy.allowsLaunchAgent(entry.url, label: label) else { continue }
            _ = await run(["bootout", "gui/\(getuid())/\(label)"]) // fails when it isn't loaded, which is fine
        }
    }

    /// Why `trash` left everything in place: the app couldn't go to the Trash, the user cancelled the password prompt,
    /// or the app is locked in Finder (`Scanner.isLocked`; `recycle` refuses it too).
    enum AppTrashError: Error, Equatable { case notTrashed, cancelled, locked }

    /// `NSWorkspace.recycle`: like Finder, asks for an admin password when the app is owned by root or the App Store
    ///. Returns where the app now is inside the Trash; throws `CocoaError.userCancelled` if the prompt is cancelled.
    static let recycle: @Sendable (URL) async throws -> URL? = { url in try await NSWorkspace.shared.recycle([url])[url] }

    /// The app at `url` is open: a running app with its bundle id, or launched from that bundle.
    static let isRunning: @Sendable (URL) -> Bool = { url in
        let id = Bundle(url: url)?.bundleIdentifier
        let path = SafetyPolicy.normalize(url)
        return NSWorkspace.shared.runningApplications.contains { running in
            (id != nil && running.bundleIdentifier == id) || running.bundleURL.map { SafetyPolicy.normalize($0) == path } == true
        }
    }

    /// Moves the app (if any) and then its data to the Trash, re-checking the policy right before each item, and that
    /// the app is not open (`isRunning`) right before it goes (its size walk may take seconds).
    /// If `FileManager.trashItem` is refused for lack of permission (owned by root or another user, App Store), the
    /// app goes through `recycle` instead. If the app still isn't trashed, nothing else is touched and it throws.
    /// Launch agents among the data are booted out first, so they don't keep running a removed program until logout.
    /// `moveToTrash` (app and data) and `recycle` are injectable so tests never touch a real app or the real Trash.
    @concurrent static func trash(app: URL?, data: [AppDataEntry], policy: SafetyPolicy = .current,
                                  launchctl: LaunchAgents.Runner = LaunchAgents.launchctlRunner,
                                  moveToTrash: @Sendable (URL) throws -> URL? = CleanReport.moveToTrash,
                                  recycle: @Sendable (URL) async throws -> URL? = recycle,
                                  isRunning: @Sendable (URL) -> Bool = isRunning) async throws(AppTrashError) -> CleanReport {
        var report = CleanReport()
        if let app {
            guard policy.allowsApp(app) else { throw .notTrashed }
            guard !Scanner.isLocked(app) else { throw .locked }
            let size = await size(of: app)
            guard !isRunning(app) else { throw .notTrashed }
            let inTrash: URL?
            do { inTrash = try moveToTrash(app) } catch where isPermissionError(error) {
                guard policy.allowsApp(app), !isRunning(app) else { throw .notTrashed }
                do { inTrash = try await recycle(app) } catch {
                    throw (error as? CocoaError)?.code == .userCancelled ? .cancelled : .notTrashed
                }
            } catch { throw .notTrashed }
            report.freed += size
            if let inTrash { report.trashed.append(TrashedItem(original: app, inTrash: inTrash, size: size)) }
            ActivityLog.record(module: "Uninstaller", item: app.path, size: size, mode: .trash, home: policy.homeURL)
        }
        await bootOutAgents(in: data, policy: policy, run: launchctl)
        report += CleanReport.trashing(data.map { ($0.url, $0.size) }, module: "Uninstaller", home: policy.homeURL,
                                       allows: policy.allowsAppData, trash: moveToTrash)
        return report
    }

    /// No write permission (Cocoa or POSIX EACCES/EPERM, also as the underlying error).
    static func isPermissionError(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == CocoaError.fileWriteNoPermission.rawValue { return true }
        if error.domain == NSPOSIXErrorDomain, [Int(EACCES), Int(EPERM)].contains(error.code) { return true }
        return (error.userInfo[NSUnderlyingErrorKey] as? Error).map(isPermissionError) ?? false
    }
}
