import Foundation

/// UserDefaults keys for the Settings window, readable from engine code (UserDefaults is thread-safe).
nonisolated enum Preferences {
    /// [String]: folders and files never listed nor removed by any module (`SafetyPolicy.excluded`).
    static let excludedFolders = "excludedFolders"
    /// [String: Bool]: item id → selected, only for items whose choice differs from `selectedByDefault`.
    static let selectionOverrides = "selectionOverrides"
    static let oldLogsDays = "oldLogsDays"
    static let tempFilesDays = "tempFilesDays"
    static let sessionDays = "sessionDays"
    static let installerDays = "installerDays"
    static let downloadDays = "downloadDays"
    /// Bool: set at every launch by versions before the welcome guide, which showed a Full Disk Access sheet
    /// instead; no longer written. True means CleanMate was used before, so the guide is not shown at launch.
    static let fullDiskAccessPrompted = "fullDiskAccessPrompted"
    /// Bool: the welcome guide was closed (Skip, Get Started or Restart); it is not shown at launch any more.
    static let welcomeShown = "welcomeShown"
    /// Bool, off by default: free-space item in the menu bar.
    static let showMenuBarExtra = "showMenuBarExtra"
    /// [String: Int]: scan scope → entries checked by the last finished Large & Old Files scan (progress estimate),
    /// at most `LargeFilesModel.lastCountLimit` scopes, all inside the home folder.
    static let largeFilesLastCount = "largeFilesLastCount"
    /// String: folders last chosen as the Large & Old Files scope, newest first, one path per line.
    static let largeFilesRecentFolders = "largeFilesRecentFolders"
    /// String: path of the Large & Old Files scope, empty for the whole home folder.
    static let largeFilesScope = "largeFilesScope"
    /// String: folders last chosen in Space Lens › Location, same format as `largeFilesRecentFolders`.
    static let spaceLensRecentFolders = "spaceLensRecentFolders"
    /// Keys older versions wrote and nothing reads any more; removed at launch.
    static let obsolete = ["smartScanLastDurations"]
    /// String (`UninstallerModel.AppSort` raw value): order of the Uninstaller's app list, Name by default.
    static let uninstallerSort = "uninstallerSort"
    /// String (`UninstallerModel.UnusedFilter` raw value): "not used for" filter of the Uninstaller's app list, All by default.
    static let uninstallerUnused = "uninstallerUnused"

    /// String: ids of Smart Scan groups turned off in Settings › Smart Scan, one per line; never scanned nor shown.
    static let disabledScanGroups = "disabledScanGroups"
    /// [String: Any]: the last finished Smart Scan (`LastScan`), shown in the menu bar item.
    static let lastSmartScan = "lastSmartScan"
    /// String (`ScanReminder.Frequency` raw value): Settings › General › Remind me to scan, off by default.
    static let scanReminder = "scanReminder"
    /// Int: Settings › General › Warn when free space is below, in percent of the disk; 0 = off, 10 by default
    /// (`LowDiskWarning.percent`).
    static let lowDiskWarning = "lowDiskWarning"
    /// Date: when the last low-disk warning was posted (at most one a day).
    static let lowDiskWarned = "lowDiskWarned"
    /// Settings tab shown when the window opens.
    static let settingsTab = "settingsTab"

    /// [String: [String: Any]]: probe command → last output with its fingerprint and date (`SizeProbe.output`).
    static let probeOutputs = "probeOutputs"

    static let recentLimit = 5

    /// Smart Scan group ids turned off in Settings. `defaults` is injected by tests.
    static func disabledGroups(defaults: UserDefaults = .standard) -> Set<String> {
        disabledGroups(text: defaults.string(forKey: disabledScanGroups) ?? "")
    }

    static func disabledGroups(text: String) -> Set<String> { Set(text.split(separator: "\n").map(String.init)) }

    /// Paths of a recent-folders value (one per line, newest first), folders that no longer exist dropped.
    static func recentFolders(_ stored: String) -> [String] {
        stored.split(separator: "\n").map(String.init).filter {
            var isFolder: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0, isDirectory: &isFolder) && isFolder.boolValue
        }
    }

    /// `stored` with `path` moved to the front, missing folders dropped, at most `recentLimit` entries.
    static func addingRecentFolder(_ path: String, to stored: String) -> String {
        ([path] + recentFolders(stored).filter { $0 != path }).prefix(recentLimit).joined(separator: "\n")
    }

    static var excluded: [String] { UserDefaults.standard.stringArray(forKey: excludedFolders) ?? [] }

    /// A folder (not a package such as .app) or a regular file, never a symlink nor a missing path: what
    /// Settings › Exclusions and "Never Clean This" accept. `SafetyPolicy` refuses an excluded file, and its
    /// parent folders, the same way as an excluded folder.
    /// Never a "broad" path: the context menu must not exclude home, "/" or a parent of home.
    static func canExclude(_ url: URL) -> Bool { isExcludableItem(url) && !isBroad(url) }

    /// "/", `home` or a folder containing `home`: excluding it leaves every module with nothing to clean, so
    /// Settings › Exclusions asks first.
    static func isBroad(_ url: URL, home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> Bool {
        let path = url.standardizedFileURL.path, homePath = home.standardizedFileURL.path
        return path == "/" || path == homePath || homePath.hasPrefix(path + "/")
    }

    private static func isExcludableItem(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isRegularFileKey, .isSymbolicLinkKey]),
              values.isSymbolicLink != true else { return false }
        return values.isDirectory == true ? values.isPackage != true : values.isRegularFile == true
    }

    /// `paths` plus the excludable ones among `urls` (Settings › Exclusions add button and drag & drop),
    /// nothing added twice. Broad paths are accepted: Settings confirms them first.
    static func addingExcluded(_ urls: [URL], to paths: [String]) -> [String] {
        var result = paths
        for url in urls where isExcludableItem(url) {
            let path = url.standardizedFileURL.path
            if !result.contains(path) { result.append(path) }
        }
        return result
    }

    /// "Never Clean This": saves `urls` to the exclusion list; returns those now excluded. `defaults` is
    /// injected by tests so they never touch the real list.
    static func exclude(_ urls: [URL], defaults: UserDefaults = .standard) -> [URL] {
        let paths = addingExcluded(urls.filter(canExclude), to: defaults.stringArray(forKey: excludedFolders) ?? [])
        defaults.set(paths, forKey: excludedFolders)
        return urls.filter { paths.contains($0.standardizedFileURL.path) }
    }

    static var overrides: [String: Bool] { dictionary(selectionOverrides) }

    /// Remembers the user's choice for `item`; a choice equal to the default is forgotten so new defaults still apply.
    static func remember(_ item: CleanerItem, selected: Bool) {
        update(selectionOverrides) { (all: inout [String: Bool]) in all[item.id] = selected == item.selectedByDefault ? nil : selected }
    }

    /// The `[String: V]` stored under `key`; empty when missing or of another type.
    static func dictionary<V>(_ key: String, defaults: UserDefaults = .standard) -> [String: V] {
        defaults.dictionary(forKey: key) as? [String: V] ?? [:]
    }

    /// Re-reads the dictionary under `key`, applies `change` and stores it (other entries kept).
    static func update<V>(_ key: String, defaults: UserDefaults = .standard, _ change: (inout [String: V]) -> Void) {
        var all: [String: V] = dictionary(key, defaults: defaults)
        change(&all)
        defaults.set(all, forKey: key)
    }
}

/// The last finished Smart Scan, for the menu bar item: when, what its ticked items would free, and, once cleaned,
/// what the clean freed (the same bytes the activity log records).
nonisolated struct LastScan: Equatable, Sendable {
    var date: Date
    var size: Int64
    var cleaned: Int64?

    static func read(defaults: UserDefaults = .standard) -> LastScan? {
        let stored: [String: Any] = Preferences.dictionary(Preferences.lastSmartScan, defaults: defaults)
        guard let seconds = stored["date"] as? Double, let size = (stored["size"] as? NSNumber)?.int64Value else { return nil }
        return LastScan(date: Date(timeIntervalSince1970: seconds), size: size,
                        cleaned: (stored["cleaned"] as? NSNumber)?.int64Value)
    }

    func save(defaults: UserDefaults = .standard) {
        var stored: [String: Any] = ["date": date.timeIntervalSince1970, "size": NSNumber(value: size)]
        if let cleaned { stored["cleaned"] = NSNumber(value: cleaned) }
        defaults.set(stored, forKey: Preferences.lastSmartScan)
    }

    /// A clean of the last scan's results: keeps its date, adds what was freed.
    static func recordClean(freed: Int64, defaults: UserDefaults = .standard) {
        guard var last = read(defaults: defaults) else { return }
        last.cleaned = (last.cleaned ?? 0) + freed
        last.save(defaults: defaults)
    }
}

/// Age thresholds (in days) the user can change in Settings; the catalogs take them as parameters.
nonisolated struct CleanupAges: Sendable, Equatable {
    var logs = 7
    var temp = 3
    var sessions = 30
    /// Installers in ~/Downloads: kept longer than logs, a disk image from last week may still be wanted.
    var installers = 30
    /// Anything else in ~/Downloads: only what was neither modified, added nor opened for a season.
    var downloads = 90

    static let `default` = CleanupAges()

    /// Values the AI-sessions, installers and downloads steppers step through; contains their defaults (30, 90).
    static let steps = [7, 14, 30, 60, 90, 180, 365]

    /// Next step above/below `days`; an old saved value off the list (e.g. 37) snaps to its neighbour.
    static func step(from days: Int, up: Bool) -> Int {
        up ? steps.first { $0 > days } ?? steps.last!
           : steps.last { $0 < days } ?? steps.first!
    }

    static var current: CleanupAges {
        let defaults = UserDefaults.standard
        return CleanupAges(logs: defaults.object(forKey: Preferences.oldLogsDays) as? Int ?? Self.default.logs,
                           temp: defaults.object(forKey: Preferences.tempFilesDays) as? Int ?? Self.default.temp,
                           sessions: defaults.object(forKey: Preferences.sessionDays) as? Int ?? Self.default.sessions,
                           installers: defaults.object(forKey: Preferences.installerDays) as? Int ?? Self.default.installers,
                           downloads: defaults.object(forKey: Preferences.downloadDays) as? Int ?? Self.default.downloads)
    }
}
