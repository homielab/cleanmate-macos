import Foundation

/// Entry labels for Xcode's DerivedData and DeviceSupport folders, so one project or OS version can be kept.
nonisolated enum XcodeData {
    /// "MyApp-fxvkpmzmhadblvcrrkwkvjsvuagj" → "MyApp"; nil for folders without Xcode's 28-letter hash
    /// (ModuleCache.noindex, SDKStatCaches.noindex…).
    static func projectName(fileName: String) -> String? {
        guard let dash = fileName.lastIndex(of: "-"), dash > fileName.startIndex else { return nil }
        let hash = fileName[fileName.index(after: dash)...]
        guard hash.count == 28, hash.allSatisfy({ ("a"..."z").contains($0) }) else { return nil }
        return String(fileName[..<dash])
    }

    /// Project name + workspace path (with ~) and last use, from the folder's `info.plist` when it can be read.
    /// Folders shared by all projects say so; the date is Xcode's `LastAccessedDate`.
    static func derivedDataLabel(of url: URL) -> (title: String, date: Date?)? { derivedDataLabel(of: url, locale: .current) }

    /// `locale` picks the language of "shared by all projects" (UISnapshots VI shots).
    static func derivedDataLabel(of url: URL, locale: Locale) -> (title: String, date: Date?)? {
        let name = url.lastPathComponent
        guard let project = projectName(fileName: name) else {
            let base = name.hasSuffix(".noindex") ? String(name.dropLast(".noindex".count)) : name
            return (base + " · " + String(localized: LocalizedStringResource("shared by all projects", locale: locale)), nil)
        }
        let info = (try? Data(contentsOf: url.appending(path: "info.plist")))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        let workspace = (info?["WorkspacePath"] as? String).map { ($0 as NSString).abbreviatingWithTildeInPath }
        return (workspace.map { "\(project) · \($0)" } ?? project, info?["LastAccessedDate"] as? Date)
    }

    /// "iPhone15,2 18.1 (22B83)" or "18.1 (22B83) arm64e" in "iOS DeviceSupport" → "iOS 18.1 (22B83)";
    /// nil when the name has no version and build.
    static func deviceSupportLabel(fileName: String, folder: String) -> String? {
        guard let match = fileName.firstMatch(of: /(\d+(?:\.\d+)+) \((\d+[A-Z]\d+[a-z]?)\)/) else { return nil }
        let platform = folder.hasSuffix(" DeviceSupport") ? String(folder.dropLast(" DeviceSupport".count)) : folder
        return "\(platform) \(match.1) (\(match.2))"
    }

    static func deviceSupportLabel(of url: URL) -> (title: String, date: Date?)? {
        deviceSupportLabel(fileName: url.lastPathComponent, folder: url.deletingLastPathComponent().lastPathComponent)
            .map { ($0, nil) }
    }
}
