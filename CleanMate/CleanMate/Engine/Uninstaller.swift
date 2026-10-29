import AppKit

// Uninstaller: apps in /Applications and ~/Applications (and up to three subfolders down) plus their data in ~/Library and
// their config in ~, ~/.config and ~/.local/share, and data left behind by apps already removed. Everything goes to the Trash; Apple's apps
// and data are never listed.

nonisolated struct InstalledApp: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let bundleID: String
    let version: String?
    /// Spotlight's last-used date, when known.
    let lastUsed: Date?
    /// `CFBundleName` and `CFBundleExecutable`: folders are often named after these (`Code` for Visual Studio Code).
    var bundleName: String? = nil
    var executableName: String? = nil

    var id: URL { url }
    /// Every name the app goes by, for `otherAppNames` of the other apps.
    var names: [String] { [name] + [bundleName, executableName].compactMap { $0 } }
}

/// One item directly inside a ~/Library data folder (`SafetyPolicy.appDataFolders`), or an app's config item directly in
/// ~, ~/.config, ~/.local/share or ~/.local/state (`SafetyPolicy.allowsAppConfig`).
nonisolated struct AppDataEntry: Identifiable, Hashable, Sendable {
    /// `data`: surely the app's (ticked when listed). `suggested`: a folder that only starts like the app's name.
    /// `config`: outside ~/Library. Only `data` is ticked for the user.
    enum Kind: Sendable { case data, suggested, config }

    let url: URL
    let size: Int64
    var kind: Kind = .data
    /// A `config` item in a leftovers list that no installed app or command-line tool is named after.
    var orphan = false

    var id: URL { url }
    var folder: String { url.deletingLastPathComponent().lastPathComponent }
    /// Where the item is, as shown: its ~/Library folder, `~/.config`, `~/.local/share`, `~/.local/state` or `~`.
    var location: String {
        guard kind == .config else { return folder }
        let parent = url.deletingLastPathComponent()
        return SafetyPolicy.appConfigFolders.first { parent.path.hasSuffix("/" + $0) }.map { "~/" + $0 } ?? "~"
    }
}

nonisolated enum AppMatcher {
    /// Folders where a folder named exactly like the app also counts (vendors use bundle ids elsewhere).
    static let nameFolders: Set = ["Application Support", "Caches", "Logs"]
    /// Names shared by several apps of a vendor or too vague to belong to one app.
    static let genericNames: Set = [
        "google", "microsoft", "apple", "adobe", "mozilla", "jetbrains", "electron", "java", "oracle", "common", "shared",
        "default", "helper", "update", "updater", "crashpad", "crashreporter", "cache", "caches", "logs", "data", "temp",
        "plugins", "support", "settings", "config", "app", "main", "launcher", "runner", "client", "agent", "service",
        "desktop", "studio", "browser", "editor", "player",
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

    /// Folders where a folder that only starts with the app's first word (`BraveSoftware` for Brave Browser) is offered,
    /// never ticked.
    static let suggestionFolders: Set = ["Application Support"]

    /// `name` lowercased as folders spell it: as is, without spaces (`diskdrill`), spaces as `-` or `_` (`beekeeper-studio`).
    static func variants(_ name: String) -> Set<String> {
        let lower = name.lowercased().trimmingCharacters(in: .whitespaces)
        guard lower.contains(" ") else { return [lower] }
        return [lower, lower.replacing(" ", with: ""), lower.replacing(" ", with: "-"), lower.replacing(" ", with: "_")]
    }

    /// What one app's folders may be named, worked out once per app.
    struct Names: Sendable {
        let bundleID: String
        /// Lowercased folder names that surely stand for the app: `variants` of its name and `CFBundleName` (3+ characters)
        /// and of its `CFBundleExecutable` (4+ characters), never `genericNames`.
        let exact: Set<String>
        /// The first word of the app's name, lowercased, when `isDistinctive`: suggested folders start with it.
        let prefix: String?

        init(bundleID: String, name: String, bundleName: String? = nil, executableName: String? = nil) {
            self.bundleID = bundleID
            var exact = Set<String>()
            for name in [name, bundleName].compactMap({ $0 }) { exact.formUnion(variants(name).filter { $0.count >= 3 }) }
            if let executableName { exact.formUnion(variants(executableName).filter { $0.count >= 4 }) }
            self.exact = exact.subtracting(genericNames)
            let word = name.split(separator: " ").first.map { $0.lowercased() }
            prefix = word.flatMap { isDistinctive($0) ? $0 : nil }
        }

        init(_ app: InstalledApp) {
            self.init(bundleID: app.bundleID, name: app.name, bundleName: app.bundleName, executableName: app.executableName)
        }
    }

    /// Another app goes by `name` (lowercased) too, in any `variants` spelling, or by a longer name of its family whose
    /// first words spell it: `Barista Pro` for `barista`, `Disk Drill Pro` for `diskdrill`.
    static func isClaimed(_ name: String, byOther otherAppNames: Set<String>) -> Bool {
        otherAppNames.contains { other in
            let words = other.lowercased().split(separator: " ").map(String.init)
            guard words.count > 1 else { return words.first == name }
            if variants(other).contains(name) { return true }
            return (1..<words.count).contains { count in
                ["", " ", "-", "_"].contains { words.prefix(count).joined(separator: $0) == name }
            }
        }
    }

    /// Whether the entry `name` in Library `folder` belongs to the app: by bundle id (unless a longer installed bundle
    /// id claims it, e.g. `com.foo.App.Pro`), or — only in `nameFolders` — a folder named like the app (`Names.exact`)
    /// that no other installed app shares (same name, or a family name such as `Barista` for `Barista Pro`).
    static func matches(name: String, folder: String, bundleID: String, appName: String, bundleName: String? = nil,
                        executableName: String? = nil, otherBundleIDs: Set<String>, otherAppNames: Set<String> = []) -> Bool {
        kind(name: name, folder: folder, app: Names(bundleID: bundleID, name: appName, bundleName: bundleName,
                                                    executableName: executableName),
             otherBundleIDs: otherBundleIDs, otherAppNames: otherAppNames) == .data
    }

    /// How the Library entry `name` belongs to the app: `.data` (`matches`), `.suggested` (in `suggestionFolders`, not
    /// reverse-DNS, starts with `Names.prefix`, and no other app has a name starting with it), or nil.
    static func kind(name: String, folder: String, app: Names, otherBundleIDs: Set<String>,
                     otherAppNames: Set<String>) -> AppDataEntry.Kind? {
        guard !SafetyPolicy.isApple(name) else { return nil }
        return kind(id: identifier(name, in: folder), lowerName: name.lowercased(), folder: folder, app: app,
                    otherBundleIDs: otherBundleIDs, otherAppNames: otherAppNames)
    }

    /// `kind` for a non-Apple entry whose `identifier` is `id`, computed once per entry by the scan of every app.
    static func kind(id: String, lowerName: String, folder: String, app: Names, otherBundleIDs: Set<String>,
                     otherAppNames: Set<String>) -> AppDataEntry.Kind? {
        let bundleID = app.bundleID
        if belongs(id, to: bundleID) {
            let rest = id.dropFirst(bundleID.count + 1)
            if releaseChannels.contains(where: { rest == $0 || rest.hasPrefix($0 + ".") }) { return nil }
            let claimed = otherBundleIDs.contains { other in
                other.count > bundleID.count && belongs(other.lowercased(), to: bundleID) && belongs(id, to: other)
            }
            return claimed ? nil : .data
        }
        guard nameFolders.contains(folder) else { return nil }
        // Other app names are checked last: the scan of every app's data calls this for each app × entry.
        if app.exact.contains(lowerName) { return isClaimed(lowerName, byOther: otherAppNames) ? nil : .data }
        guard suggestionFolders.contains(folder), let prefix = app.prefix, lowerName.hasPrefix(prefix),
              lowerName.count > prefix.count, !isBundleIDShaped(lowerName) else { return nil }
        return otherAppNames.contains { variants($0).contains { $0.hasPrefix(prefix) } } ? nil : .suggested
    }

    /// Config of command-line tools that a desktop app of the same name doesn't own (Claude Code's `~/.claude`, Gemini
    /// CLI's `~/.gemini`, Copilot's editor sign-in in `~/.config/github-copilot`…), even when the CLI isn't found.
    static let toolConfigNames: Set = ["claude", "codex", "gemini", "copilot", "github-copilot", "continue", "aider", "goose"]

    /// The `Names.exact` name the config item `name` stands for: `~/.config/<name>`, `~/.local/share/<name>`, `~/.<name>`
    /// or `~/.<name>-…` (`inConfigFolder` false: `name` has its dot), unless another app goes by that name; nil when it isn't the app's.
    static func configName(_ name: String, inConfigFolder: Bool, app: Names, otherAppNames: Set<String>) -> String? {
        let lower = name.lowercased()
        let stem = inConfigFolder ? lower : String(lower.dropFirst())
        guard inConfigFolder || lower.hasPrefix("."), !SafetyPolicy.isApple(lower), !genericNames.contains(stem),
              !toolConfigNames.contains(stem) else { return nil }
        let matched = app.exact.contains(stem) ? stem
            : inConfigFolder ? nil : app.exact.first { stem.hasPrefix($0 + "-") }
        guard let matched, !toolConfigNames.contains(matched), !isClaimed(matched, byOther: otherAppNames) else { return nil }
        return matched
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

    /// Folders of the XDG homes that tools and desktop environments share; never offered as orphans.
    static let sharedConfigNames: Set = ["fonts", "applications", "icons", "mime", "themes", "locale", "bash-completion",
                                         "zsh", "fish", "systemd", "autostart", "dconf", "pulse", "gtk-3.0", "gtk-4.0", "trash"]

    /// A folder directly in `~/.config`, `~/.local/share` or `~/.local/state` that no installed app is named after (any
    /// `Names.exact`, its first word, or a part of a bundle id) and no command-line tool in `tools` (lowercased) is
    /// called. CLI data (`toolConfigNames`) and shared XDG folders never count: nothing is guessed.
    static func isOrphanConfig(_ name: String, appNames: [Names], installedBundleIDs: Set<String>, tools: Set<String>) -> Bool {
        let stem = name.lowercased()
        guard !name.hasPrefix("."), !SafetyPolicy.isApple(stem), stem.count >= 2, !genericNames.contains(stem),
              !toolConfigNames.contains(stem), !sharedConfigNames.contains(stem), !tools.contains(stem) else { return false }
        if appNames.contains(where: { $0.exact.contains(stem) || $0.prefix == stem }) { return false }
        let parts = Set(installedBundleIDs.union(appNames.map(\.bundleID)).flatMap { $0.lowercased().split(separator: ".").map(String.init) })
        return !parts.contains(stem)
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
                let info = bundle.infoDictionary
                apps.append(InstalledApp(
                    url: url, name: url.deletingPathExtension().lastPathComponent, bundleID: id,
                    version: info?["CFBundleShortVersionString"] as? String,
                    lastUsed: NSMetadataItem(url: url)?.value(forAttribute: "kMDItemLastUsedDate") as? Date,
                    bundleName: info?["CFBundleName"] as? String, executableName: info?["CFBundleExecutable"] as? String))
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

    /// Hidden items directly in the home folder and items directly in ~/.config or ~/.local/share that
    /// `allowsAppConfig`: (name, whether in ~/.config or ~/.local/share, url).
    static func configItems(policy: SafetyPolicy) -> [(name: String, inConfig: Bool, url: URL)] {
        let home = policy.homeURL
        let names = { (dir: URL) in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] }
        let folders = SafetyPolicy.appConfigFolders.map { home.appending(path: $0) }
        return (names(home).filter { $0.hasPrefix(".") }.map { (name: $0, inConfig: false, url: home.appending(path: $0)) }
                + folders.flatMap { folder in names(folder).map { (name: $0, inConfig: true, url: folder.appending(path: $0)) } })
            .filter { policy.allowsAppConfig($0.url) }
    }

    /// Every command folder the config rule checks: `toolFolders`, the process `PATH` and macOS's own bin folders.
    static var configToolFolders: [String] {
        toolFolders + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    }

    /// Command-line tools in `folders` (`~` is the policy's home): lowercased name → paths. A config item named like
    /// one belongs to that tool, not to an app, unless every one of them is (a link into) the app's own bundle.
    static func toolPaths(home: URL, folders: [String] = configToolFolders) -> [String: [String]] {
        var tools: [String: [String]] = [:]
        for folder in Set(folders) where !folder.isEmpty {
            let path = folder.hasPrefix("~/") ? home.appending(path: String(folder.dropFirst(2))).path : folder
            for name in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
                tools[name.lowercased(), default: []].append((path as NSString).appendingPathComponent(name))
            }
        }
        return tools
    }

    /// A tool named `name` is installed and not all of its copies lie inside `app`'s bundle.
    static func isForeignTool(_ name: String, app: URL, tools: [String: [String]]) -> Bool {
        guard let paths = tools[name] else { return false }
        let bundle = app.resolvingSymlinksInPath().path + "/"
        return !paths.allSatisfy { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path.hasPrefix(bundle) }
    }

    /// The Library entries and config items one app would list, with how each belongs to it.
    private static func classify(_ app: InstalledApp, library: [LibraryItem], config: [(name: String, inConfig: Bool, url: URL)],
                                 otherBundleIDs: Set<String>, otherAppNames: Set<String>,
                                 tools: [String: [String]]) -> [(url: URL, kind: AppDataEntry.Kind)] {
        let names = AppMatcher.Names(app)
        let data = library.compactMap { item in
            AppMatcher.kind(id: item.id, lowerName: item.lowerName, folder: item.folder, app: names,
                            otherBundleIDs: otherBundleIDs, otherAppNames: otherAppNames).map { (url: item.url, kind: $0) }
        }
        let configs = config.compactMap { item -> (url: URL, kind: AppDataEntry.Kind)? in
            guard let matched = AppMatcher.configName(item.name, inConfigFolder: item.inConfig, app: names,
                                                      otherAppNames: otherAppNames) else { return nil }
            let stem = item.inConfig ? item.name.lowercased() : String(item.name.lowercased().dropFirst())
            guard !isForeignTool(matched, app: app.url, tools: tools), !isForeignTool(stem, app: app.url, tools: tools)
            else { return nil }
            return (url: item.url, kind: .config)
        }
        return data + configs
    }

    /// A non-Apple Library entry with the per-entry work of `AppMatcher.kind` done once.
    private struct LibraryItem { let id: String; let lowerName: String; let folder: String; let url: URL }

    private static func libraryItems(policy: SafetyPolicy, skipped: Set<String> = []) -> [LibraryItem] {
        dataFolderItems(policy: policy, skipped: skipped).filter { !SafetyPolicy.isApple($0.name) }.map {
            LibraryItem(id: AppMatcher.identifier($0.name, in: $0.folder), lowerName: $0.name.lowercased(), folder: $0.folder,
                        url: $0.url)
        }
    }

    /// The app's data in ~/Library and its config in ~, ~/.config and ~/.local/share, largest first. `otherBundleIDs`/`otherAppNames`:
    /// every other installed or running app (all names it goes by), whose data must never be picked. `tools` defaults
    /// to `toolPaths`.
    @concurrent static func data(of app: InstalledApp, otherBundleIDs: Set<String>, otherAppNames: Set<String> = [],
                                 tools: [String: [String]]? = nil, policy: SafetyPolicy = .current) async -> [AppDataEntry] {
        let found = classify(app, library: libraryItems(policy: policy), config: configItems(policy: policy),
                             otherBundleIDs: otherBundleIDs, otherAppNames: otherAppNames,
                             tools: tools ?? toolPaths(home: policy.homeURL))
        var entries: [AppDataEntry] = []
        for item in found { entries.append(AppDataEntry(url: item.url, size: await size(of: item.url), kind: item.kind)) }
        return entries.sorted { $0.size > $1.size }
    }

    /// For every app, the entries `data(of:)` would list for it with their kind (same rules; other app names are all
    /// names of the other apps in `apps` plus the names of `allApps`), from ONE listing for all apps. Never measures sizes.
    /// `skipped`: folders not to list (`ProtectedFolders` without Full Disk Access: listing them would prompt).
    /// `allApps`: app bundles not in `apps` whose names count too (`allAppURLs`).
    @concurrent static func classifiedMatches(of apps: [InstalledApp], otherBundleIDs: Set<String>, skipped: Set<String> = [],
                                              allApps: [URL] = [], tools: [String: [String]]? = nil,
                                              policy: SafetyPolicy = .current) async -> [URL: [(url: URL, kind: AppDataEntry.Kind)]] {
        let library = libraryItems(policy: policy, skipped: skipped)
        let config = configItems(policy: policy)
        let tools = tools ?? toolPaths(home: policy.homeURL)
        var result: [URL: [(url: URL, kind: AppDataEntry.Kind)]] = [:]
        for app in apps {
            let names = Set(apps.lazy.filter { $0.url != app.url }.flatMap(\.names)).union(otherAppNames(than: app.url, in: allApps))
            result[app.url] = classify(app, library: library, config: config, otherBundleIDs: otherBundleIDs,
                                       otherAppNames: names, tools: tools)
        }
        return result
    }

    /// `classifiedMatches` without the kinds: what each app row's data size adds up.
    @concurrent static func dataMatches(of apps: [InstalledApp], otherBundleIDs: Set<String>, skipped: Set<String> = [],
                                        allApps: [URL] = [], tools: [String: [String]]? = nil,
                                        policy: SafetyPolicy = .current) async -> [URL: [URL]] {
        await classifiedMatches(of: apps, otherBundleIDs: otherBundleIDs, skipped: skipped, allApps: allApps, tools: tools,
                                policy: policy).mapValues { $0.map(\.url) }
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

    /// Homebrew installs (Apple silicon, Intel).
    static let brewPrefixes = ["/opt/homebrew", "/usr/local"]

    /// Lowercased names of installed Homebrew formulae and casks: the folders in `<prefix>/Cellar` and `Caskroom`, the
    /// same list `brew list` prints, read without running brew. A package's config folder is often named after the
    /// package rather than its command (`helix` installs `hx`).
    static func brewPackageNames(prefixes: [String] = brewPrefixes) -> Set<String> {
        Set(prefixes.flatMap { prefix in
            ["Cellar", "Caskroom"].flatMap { folder in
                ((try? FileManager.default.contentsOfDirectory(atPath: prefix + "/" + folder)) ?? [])
                    .filter { !$0.hasPrefix(".") }.map { $0.lowercased() }
            }
        })
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

    /// Data in ~/Library of apps that are no longer installed, largest first, then config and state folders (`~/.config`,
    /// `~/.local/share`, `~/.local/state`) that no installed app, command-line tool or Homebrew package is named after
    /// (`orphanConfig`).
    /// `tools` defaults to `commandLineTools`; `appNames` to the apps found in the application folders; `toolFolders`: where tool names are looked up.
    @concurrent static func leftovers(installedBundleIDs: Set<String>, tools: Set<String>? = nil,
                                      appNames: [AppMatcher.Names]? = nil, toolFolders: [String] = configToolFolders,
                                      brewPrefixes: [String] = brewPrefixes,
                                      isRegistered: @Sendable (String) -> Bool,
                                      policy: SafetyPolicy = .current) async -> [AppDataEntry] {
        let agents = policy.homeURL.appending(path: "Library/LaunchAgents")
        let tools = tools ?? commandLineTools(home: policy.homeURL, folders: userToolFolders)
        let entries = await dataEntries(policy: policy) {
            AppMatcher.isLeftover(name: $0, folder: $1, installedBundleIDs: installedBundleIDs, tools: tools,
                                  isRegistered: isRegistered)
                && ($1 != "LaunchAgents" || !agentIsActive(agents.appending(path: $0)))
        }
        let names = appNames ?? allAppURLs(policy: policy).compactMap { url -> AppMatcher.Names? in
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
            let info = bundle.infoDictionary
            return AppMatcher.Names(bundleID: id, name: url.deletingPathExtension().lastPathComponent,
                                    bundleName: info?["CFBundleName"] as? String, executableName: info?["CFBundleExecutable"] as? String)
        }
        let foreign = Set(toolPaths(home: policy.homeURL, folders: toolFolders).keys).union(tools)
            .union(brewPackageNames(prefixes: brewPrefixes))
        var orphans: [AppDataEntry] = []
        for item in configItems(policy: policy) where item.inConfig
            && AppMatcher.isOrphanConfig(item.name, appNames: names, installedBundleIDs: installedBundleIDs, tools: foreign) {
            orphans.append(AppDataEntry(url: item.url, size: await size(of: item.url), kind: .config, orphan: true))
        }
        return entries + orphans.sorted { $0.size > $1.size }
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

    /// Moves the app (if any) and then its data and config to the Trash, re-checking the policy (`allowsAppData` or
    /// `allowsAppConfig`) right before each item, and that
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
                                       allows: { policy.allowsAppData($0) || policy.allowsAppConfig($0) }, trash: moveToTrash)
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
