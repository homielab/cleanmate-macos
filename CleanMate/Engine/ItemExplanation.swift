import AppKit

/// "Why is this safe?" for one cleaner item: what it is, where it lives, what cleaning does, when it is skipped.
/// Everything but `what` is read from the item's own rules (paths, mode, command, skips), so the text always matches
/// what the scan and the clean really do.
nonisolated struct ItemExplanation: Sendable {
    let what: LocalizedStringResource?
    /// Paths as the catalog writes them (`~` = home, `*` = any folder there); may be empty (`locationNote` then says).
    let paths: [String]
    let morePaths: Int
    let locationNote: LocalizedStringResource?
    let afterClean: [LocalizedStringResource]
    let skippedWhen: [LocalizedStringResource]

    static let shownPaths = 4

    /// `appName` names an app by bundle id (the app's file name, else the id itself).
    init(_ item: CleanerItem, appName: (String) -> String = ItemExplanation.appName(bundleID:)) {
        what = item.about ?? item.note
        paths = Array(item.paths.prefix(Self.shownPaths))
        morePaths = max(0, item.paths.count - Self.shownPaths)
        locationNote = Self.locationNote(item)
        afterClean = Self.afterClean(item)
        skippedWhen = Self.skippedWhen(item, appName: appName)
    }

    private static func locationNote(_ item: CleanerItem) -> LocalizedStringResource? {
        if item.externalTrash { return "The Trash folder of each external drive" }
        if item.findEntries != nil { return "Searched for inside these folders" }
        if !item.shellFolders.isEmpty || item.locate != nil || item.configFolders != nil {
            return "Also where the tool's own settings put it"
        }
        if item.paths.isEmpty, let tool = (item.probe?.command ?? item.command)?.executable {
            return "Found by asking \(URL(fileURLWithPath: tool).lastPathComponent)"
        }
        return nil
    }

    private static func afterClean(_ item: CleanerItem) -> [LocalizedStringResource] {
        var lines: [LocalizedStringResource] = []
        if let text = item.afterClean {
            lines.append(text)
        } else if item.externalTrash {
            lines.append("Deleted for good: emptying a Trash can't be undone")
        } else if item.entryCommand != nil {
            lines.append("Each ticked entry is removed with the tool's own command")
        } else if let command = item.command {
            let line = ([URL(fileURLWithPath: command.executable).lastPathComponent] + command.arguments).joined(separator: " ")
            lines.append("CleanMate runs the tool's own clean command: \(line)")
            if !item.paths.isEmpty { lines.append("Without the tool installed, the files are deleted instead") }
        } else if item.database != nil {
            lines.append("Only these records are erased, for good; the database and its other data stay")
        } else if item.mode == .trash {
            lines.append("Moved to the Trash: you can put it back until you empty the Trash")
        } else {
            lines.append("Deleted, not moved to the Trash. The app or tool creates it again when it needs it")
        }
        if !item.selectedByDefault { lines.append("Not ticked by default: it is cleaned only if you tick it") }
        return lines
    }

    private static func skippedWhen(_ item: CleanerItem, appName: (String) -> String) -> [LocalizedStringResource] {
        var lines: [LocalizedStringResource] = []
        let apps = item.runningAppBundleIDs.map { $0.hasSuffix("*") ? String($0.dropLast()) + "…" : appName($0) }
        if !apps.isEmpty { lines.append("While \(apps.formatted(.list(type: .or))) is open") }
        let tools = item.runningProcessNames.map { $0.hasSuffix("*") ? String($0.dropLast()) + "…" : $0 }
        if !tools.isEmpty { lines.append("While \(tools.formatted(.list(type: .or))) runs") }
        if item.skipsOpenFiles { lines.append("Files a program has open") }
        if let age = item.minAge {
            let days = Int(age / 86_400)
            let hours = max(1, Int(age / 3600))
            switch (days, hours) {
            case (1, _): lines.append("Anything changed in the last day")
            case (2..., _): lines.append("Anything changed in the last \(days) days")
            case (_, 1): lines.append("Anything changed in the last hour")
            default: lines.append("Anything changed in the last \(hours) hours")
            }
        }
        if let note = item.skipNote { lines.append(note) }
        if !item.excluded.isEmpty { lines.append("Some folders inside are always kept") }
        lines.append("Folders in Exclusions and folders macOS protects are never touched")
        return lines
    }

    /// The app's name from its bundle id; the id itself when it is not installed.
    static func appName(bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return url.deletingPathExtension().lastPathComponent
    }
}
