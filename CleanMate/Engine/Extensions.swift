import Foundation

// Extensions: plug-ins in ~/Library and /Library that often stay behind after an app is removed.
// Listed with their owning app when known, never ticked for the user; Apple's and CleanMate's are not listed. The ones
// the user ticks go to the Trash only through `SafetyPolicy.allowsUserExtension` (~/Library) or, with the admin
// password, `allowsSystemExtension` (/Library). Never reads /System.

nonisolated struct ExtensionItem: Identifiable, Hashable, Sendable {
    enum Kind: CaseIterable, Sendable {
        case preferencePane, quickLook, service, screenSaver, inputMethod, internetPlugin, spotlight, audio

        /// Folders of a Library (~/Library or /Library) holding this kind.
        var folders: [String] {
            switch self {
            case .preferencePane: ["PreferencePanes"]
            case .quickLook: ["QuickLook"]
            case .service: ["Services"]
            case .screenSaver: ["Screen Savers"]
            case .inputMethod: ["Input Methods"]
            case .internetPlugin: ["Internet Plug-Ins"]
            case .spotlight: ["Spotlight"]
            case .audio: ["Audio/Plug-Ins/Components", "Audio/Plug-Ins/HAL", "Audio/Plug-Ins/VST", "Audio/Plug-Ins/VST3"]
            }
        }

        /// Only entries with one of `fileExtensions` are listed: these folders also hold caches and vendor folders.
        var listsOnlyBundles: Bool { self == .spotlight || self == .audio }

        /// `fileExtensions` allowed in `folder` (its last path component): each audio folder takes its own format.
        func fileExtensions(in folder: String) -> Set<String> {
            guard self == .audio else { return fileExtensions }
            return switch folder {
            case "Components": ["component"]
            case "HAL": ["driver"]
            case "VST": ["vst"]
            case "VST3": ["vst3"]
            default: []
            }
        }

        /// Lowercased name extensions an item of this kind may have to be moved to the Trash.
        var fileExtensions: Set<String> {
            switch self {
            case .preferencePane: ["prefpane"]
            case .quickLook: ["qlgenerator"]
            case .service: ["workflow"]
            case .screenSaver: ["saver"]
            case .inputMethod: ["app", "bundle"]
            case .internetPlugin: ["plugin", "webplugin"]
            case .spotlight: ["mdimporter"]
            case .audio: ["component", "driver", "vst", "vst3"]
            }
        }
    }

    let url: URL
    let kind: Kind
    let modified: Date?
    /// `CFBundleIdentifier` of the bundle's Info.plist; nil for items without one (Automator `.workflow`).
    let bundleID: String?
    /// Name of the installed app with this bundle id, or else of one from the same vendor.
    let owner: String?
    /// Has a third-party bundle id but no installed app of its vendor is left.
    let appRemoved: Bool
    /// In /Library: root's, moved with the admin password (Finder), put back only with Finder's Put Back.
    var system = false

    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
    /// Gets a checkbox: right name extension for its kind and neither Apple's nor CleanMate's. `allowsUserExtension` /
    /// `allowsSystemExtension` still check it again (symlink, exclusions…) right before it goes.
    var trashable: Bool {
        kind.fileExtensions(in: url.deletingLastPathComponent().lastPathComponent).contains(url.pathExtension.lowercased())
            && !(bundleID.map { SafetyPolicy.isApple($0) || SafetyPolicy.isCleanMate($0) } ?? false)
    }
}

nonisolated enum Extensions {
    /// Extensions of this Mac's ~/Library and of the policy's `systemLibrary` (/Library), off the main thread. Owners:
    /// apps in the application folders and /System/Applications, plus `running` (bundle id → name) for apps open from
    /// anywhere else.
    @concurrent static func list(policy: SafetyPolicy = .current, running: [String: String] = [:]) async -> [ExtensionItem] {
        let folders = policy.applicationFolders + [URL(fileURLWithPath: "/System/Applications")]
        var apps: [String: String] = [:]
        for url in folders.flatMap({ Uninstaller.appURLs(in: $0) }) {
            if let id = Bundle(url: url)?.bundleIdentifier { apps[id] = url.deletingPathExtension().lastPathComponent }
        }
        apps.merge(running) { installed, _ in installed }
        var items = list(library: policy.homeURL.appending(path: "Library"), apps: apps)
        if let system = policy.systemLibrary { items += list(library: URL(fileURLWithPath: system), apps: apps, system: true) }
        return items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Moves the ticked extensions to the Trash (never deletes), re-checking the policy and `inUse` (a pane while
    /// System Settings is open) right before each one; either one skips it. ~/Library ones one by one (kept for Undo);
    /// /Library ones last, in ONE `recycleAll` (one admin password prompt, `Uninstaller.trashSystem`), not kept for
    /// Undo. `trash` and `recycleAll` are injectable so tests use a fake Trash folder.
    @concurrent static func trash(_ items: [AppDataEntry], policy: SafetyPolicy = .current, inUse: @escaping @Sendable (URL) -> Bool = { _ in false },
                                  trash: @Sendable (URL) throws -> URL? = CleanReport.moveToTrash,
                                  recycleAll: SafeRemoval.BatchMove = Uninstaller.recycleAll) async -> CleanReport {
        let system = items.filter { policy.isSystemLibraryItem($0.url) }
        var report = CleanReport.trashing(items.filter { !policy.isSystemLibraryItem($0.url) }.map { ($0.url, $0.size) },
                                          module: "Uninstaller", home: policy.homeURL,
                                          allows: { policy.allowsUserExtension($0) && !inUse($0) }, trash: trash)
        report += await Uninstaller.trashSystem(system, policy: policy, move: recycleAll) {
            policy.allowsSystemExtension($0) && !inUse($0)
        }
        return report
    }

    /// Extensions of ~/Library and /Library whose bundle id is `bundleID` or under it (`<bundleID>.quicklook`), that
    /// the policy allows: the Uninstaller's scan of one app adds them to its data. None for an id not shaped like
    /// `com.vendor.app` or Apple's.
    static func owned(by bundleID: String, policy: SafetyPolicy) -> [(url: URL, system: Bool)] {
        let id = bundleID.lowercased()
        guard AppMatcher.isBundleIDShaped(id), !SafetyPolicy.isApple(id), !SafetyPolicy.isCleanMate(id) else { return [] }
        let libraries = [(policy.homeURL.appending(path: "Library"), false)]
            + (policy.systemLibrary.map { [(URL(fileURLWithPath: $0), true)] } ?? [])
        return libraries.flatMap { library, system in
            list(library: library, apps: [:], system: system).compactMap { item in
                guard let own = item.bundleID?.lowercased(), own == id || own.hasPrefix(id + "."),
                      system ? policy.allowsSystemExtension(item.url) : policy.allowsUserExtension(item.url)
                else { return nil }
                return (url: item.url, system: system)
            }
        }
    }

    /// Items directly inside each extension folder of `library` (hidden ones skipped; Spotlight and Audio: only
    /// bundles of their kind, not `Assets`/`ExtensionsCache` or vendor folders), Apple's and CleanMate's left out (by
    /// name or bundle id). `apps`: bundle id → name of every installed app. `system`: `library` is /Library. Symlinks
    /// are never followed.
    static func list(library: URL, apps: [String: String], system: Bool = false) -> [ExtensionItem] {
        let fm = FileManager.default
        var items: [ExtensionItem] = []
        for (kind, folder) in ExtensionItem.Kind.allCases.flatMap({ kind in kind.folders.map { (kind, library.appending(path: $0)) } }) {
            let urls = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isSymbolicLinkKey],
                                                    options: .skipsHiddenFiles)) ?? []
            let allowed = kind.fileExtensions(in: folder.lastPathComponent)
            for url in urls where !kind.listsOnlyBundles || allowed.contains(url.pathExtension.lowercased()) {
                let name = url.lastPathComponent
                guard !SafetyPolicy.isApple(name), !SafetyPolicy.isCleanMate(name) else { continue }
                // A symlink is listed but not opened: reading through it could reach a TCC-protected folder.
                let isLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
                let id = isLink ? nil : bundleID(of: url)
                if let id, SafetyPolicy.isApple(id) || SafetyPolicy.isCleanMate(id) { continue }
                let owner = id.flatMap { owner(of: $0, apps: apps) }
                let removed = id.map { id in
                    owner == nil && AppMatcher.isBundleIDShaped(id.lowercased()) && !SafetyPolicy.isApple(id)
                        && !AppMatcher.sharedVendors.contains(AppMatcher.vendor(id)) && !shipsOwnApp(url, vendor: AppMatcher.vendor(id))
                } ?? false
                items.append(ExtensionItem(
                    url: url, kind: kind,
                    modified: try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                    bundleID: id, owner: owner, appRemoved: removed, system: system))
            }
        }
        return items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// `CFBundleIdentifier` of `Contents/Info.plist` (or a flat bundle's `Info.plist`); read directly so no bundle is cached or loaded.
    static func bundleID(of url: URL) -> String? {
        for path in ["Contents/Info.plist", "Info.plist"] {
            guard let data = try? Data(contentsOf: url.appending(path: path)),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
            return (plist["CFBundleIdentifier"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        return nil
    }

    /// Self-contained product (e.g. SwitchResX's pane carries its own apps in `Contents/PlugIns`): an `.app` of the
    /// same vendor inside the bundle means the product is still installed, so it is not "App removed".
    static func shipsOwnApp(_ url: URL, vendor: String) -> Bool {
        ["PlugIns", "Resources", "Helpers", "Library/LoginItems", "MacOS"].contains { folder in
            let urls = (try? FileManager.default.contentsOfDirectory(at: url.appending(path: "Contents/" + folder),
                                                                     includingPropertiesForKeys: nil)) ?? []
            return urls.contains { $0.pathExtension == "app" && bundleID(of: $0).map(AppMatcher.vendor) == vendor }
        }
    }

    /// The app with exactly this bundle id, else the first (by name) of the same vendor (`com.vendor`).
    static func owner(of id: String, apps: [String: String]) -> String? {
        if let name = apps.first(where: { $0.key.caseInsensitiveCompare(id) == .orderedSame })?.value { return name }
        let vendor = AppMatcher.vendor(id)
        guard !AppMatcher.sharedVendors.contains(vendor) else { return nil }
        return apps.filter { AppMatcher.vendor($0.key) == vendor }.values
            .min { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
