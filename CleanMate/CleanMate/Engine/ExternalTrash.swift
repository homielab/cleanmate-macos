import Foundation

/// The user's Trash on external drives: Finder moves what is deleted from a drive to `<drive>/.Trashes/<uid>` on that
/// drive, not to ~/.Trash. Smart Scan lists one entry per drive whose Trash holds something and empties the ticked ones.
nonisolated enum ExternalTrash {
    /// Finder's folder settings: a Trash holding only this is empty.
    static let finderFile = ".DS_Store"

    /// One entry per folder of `SafetyPolicy.externalTrashFolders` holding more than `finderFile`, measured whole and
    /// titled with the drive's name. A folder that is locked, unreadable or holds a file a process has open (Finder
    /// still moving files there) is left out.
    static func scan(_ item: CleanerItem, policy: SafetyPolicy,
                     openPaths: OpenPaths) async -> ItemScan {
        let folders = policy.externalTrashFolders()
        let open = item.skipsOpenFiles ? await RunningProcesses.openPaths(under: folders, read: openPaths) : []
        var result = ItemScan()
        for folder in folders where !Task.isCancelled {
            guard !Scanner.isLocked(folder), !RunningProcesses.holdsOpenFile(folder, openPaths: open),
                  let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
                  names.contains(where: { $0 != finderFile }),
                  var entry = await Scanner.entry(at: folder, olderThan: nil) else { continue }
            entry.title = driveName(of: folder)
            result.entries.append(entry)
        }
        result.entries.sort { $0.size > $1.size }
        return result
    }

    /// Name of the drive holding the Trash folder `<drive>/.Trashes/<uid>`: its mount point's name, as Finder shows it.
    static func driveName(of folder: URL) -> String {
        folder.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
    }

    /// Empties each scanned Trash folder that is still one of `externalTrashFolders` and holds no open file: every item
    /// in it is removed (never moved, through `SafeRemoval`), each one checked with `allowsExternalTrash` and skipped
    /// when locked. The folder itself stays. Freed = the scanned size less what is left.
    static func empty(_ item: CleanerItem, scan: ItemScan, policy: SafetyPolicy,
                      openPaths: OpenPaths) async -> CleanReport {
        let folders = Set(policy.externalTrashFolders().map(SafetyPolicy.normalize))
        var report = CleanReport()
        for entry in scan.entries {
            // Checked now, per drive: Finder may have started moving files there since the scan.
            let open = item.skipsOpenFiles ? await RunningProcesses.openPaths(under: [entry.url], read: openPaths) : []
            guard folders.contains(SafetyPolicy.normalize(entry.url)), !Scanner.isLocked(entry.url),
                  !RunningProcesses.holdsOpenFile(entry.url, openPaths: open),
                  let children = try? FileManager.default.contentsOfDirectory(at: entry.url, includingPropertiesForKeys: nil)
            else { report.skipped += 1; continue }
            for child in children {
                guard policy.allowsExternalTrash(child), !Scanner.isLocked(child),
                      (try? SafeRemoval.remove(child, allows: policy.allowsExternalTrash)) != nil
                else { report.skipped += 1; continue }
            }
            let left = await Scanner.entry(at: entry.url, olderThan: nil)?.size ?? 0
            report.freed += max(0, entry.size - left)
        }
        return report
    }
}
