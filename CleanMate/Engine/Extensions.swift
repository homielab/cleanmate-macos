import Foundation

// Extensions: user-level plug-ins in ~/Library that often stay behind after an app is removed.
// Listed with their owning app when known, never ticked for the user; the ones the user ticks go to the Trash only
// through `SafetyPolicy.allowsUserExtension`. Never reads /Library.

nonisolated struct ExtensionItem: Identifiable, Hashable, Sendable {
    enum Kind: CaseIterable, Sendable {
        case preferencePane, quickLook, service, screenSaver, inputMethod, internetPlugin, spotlight

        /// Folder of ~/Library holding this kind.
        var folder: String {
            switch self {
            case .preferencePane: "PreferencePanes"
            case .quickLook: "QuickLook"
            case .service: "Services"
            case .screenSaver: "Screen Savers"
            case .inputMethod: "Input Methods"
            case .internetPlugin: "Internet Plug-Ins"
            case .spotlight: "Spotlight"
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

    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
    /// Gets a checkbox: right name extension for its kind and not Apple's. `allowsUserExtension` still checks it
    /// again (symlink, exclusions…) right before it goes.
    var trashable: Bool {
        kind.fileExtensions.contains(url.pathExtension.lowercased()) && !(bundleID.map(SafetyPolicy.isApple) ?? false)
    }
}

nonisolated enum Extensions {
    /// Extensions of this Mac's ~/Library, off the main thread. Owners: apps in the application folders and
    /// /System/Applications, plus `running` (bundle id → name) for apps open from anywhere else.
    @concurrent static func list(policy: SafetyPolicy = .current, running: [String: String] = [:]) async -> [ExtensionItem] {
        let folders = policy.applicationFolders + [URL(fileURLWithPath: "/System/Applications")]
        var apps: [String: String] = [:]
        for url in folders.flatMap({ Uninstaller.appURLs(in: $0) }) {
            if let id = Bundle(url: url)?.bundleIdentifier { apps[id] = url.deletingPathExtension().lastPathComponent }
        }
        apps.merge(running) { installed, _ in installed }
        return list(library: policy.homeURL.appending(path: "Library"), apps: apps)
    }

    /// Moves the ticked extensions to the Trash (never deletes), re-checking `allowsUserExtension` and `inUse` (a pane
    /// while System Settings is open) right before each one; either one skips it.
    /// `trash` is injectable so tests use a fake Trash folder.
    @concurrent static func trash(_ items: [AppDataEntry], policy: SafetyPolicy = .current, inUse: @Sendable (URL) -> Bool = { _ in false },
                                  trash: @Sendable (URL) throws -> URL? = CleanReport.moveToTrash) async -> CleanReport {
        CleanReport.trashing(items.map { ($0.url, $0.size) }, module: "Uninstaller", home: policy.homeURL,
                             allows: { policy.allowsUserExtension($0) && !inUse($0) }, trash: trash)
    }

    /// Items directly inside each extension folder of `library` (hidden ones skipped; Spotlight: only `*.mdimporter`,
    /// not its `Assets`/`ExtensionsCache`). `apps`: bundle id → name of every installed app. Symlinks are never followed.
    static func list(library: URL, apps: [String: String]) -> [ExtensionItem] {
        let fm = FileManager.default
        var items: [ExtensionItem] = []
        for kind in ExtensionItem.Kind.allCases {
            let folder = library.appending(path: kind.folder)
            let urls = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isSymbolicLinkKey],
                                                    options: .skipsHiddenFiles)) ?? []
            for url in urls where kind != .spotlight || url.pathExtension.lowercased() == "mdimporter" {
                // A symlink is listed but not opened: reading through it could reach a TCC-protected folder.
                let isLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
                let id = isLink ? nil : bundleID(of: url)
                let owner = id.flatMap { owner(of: $0, apps: apps) }
                let removed = id.map { id in
                    owner == nil && AppMatcher.isBundleIDShaped(id.lowercased()) && !SafetyPolicy.isApple(id)
                        && !AppMatcher.sharedVendors.contains(AppMatcher.vendor(id)) && !shipsOwnApp(url, vendor: AppMatcher.vendor(id))
                } ?? false
                items.append(ExtensionItem(
                    url: url, kind: kind,
                    modified: try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                    bundleID: id, owner: owner, appRemoved: removed))
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
