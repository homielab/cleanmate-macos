import Foundation
import Testing
@testable import CleanMate

/// Smart Scan's "Trash on external drives": fake volumes in a temporary `volumesFolder`, with injected mount points and
/// mount flags, so no real drive or Trash is ever read or touched.
struct ExternalTrashTests {
    let fm = FileManager.default
    let root = FileManager.default.temporaryDirectory.appending(path: "CleanMateExternalTrash-\(UUID().uuidString)")
    var home: URL { root.appending(path: "home") }
    var volumes: URL { root.appending(path: "Volumes") }
    let uid = "\(getuid())"
    static let local = UInt32(MNT_LOCAL)

    @discardableResult func put(_ path: String, in base: URL, bytes: Int = 20_000) throws -> URL {
        let url = base.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
        return url
    }

    func policy(mounted names: [String], flags: [String: UInt32] = [:]) -> SafetyPolicy {
        let mounts = names.map { SafetyPolicy.normalize(volumes.appending(path: $0)) }
        let byPath = Dictionary(uniqueKeysWithValues: flags.map { (SafetyPolicy.normalize(volumes.appending(path: $0.key)), $0.value) })
        return SafetyPolicy(home: home, temp: root.appending(path: "tmp"), mounts: { ["/"] + mounts },
                            volumesFolder: volumes.path, flags: { byPath[$0] ?? Self.local })
    }

    var item: CleanerItem {
        get throws {
            try #require(CleanerGroup.smartScan(ages: .default, hasFullDiskAccess: true).flatMap(\.items)
                .first { $0.id == "external-trash" })
        }
    }

    /// Only with Full Disk Access (reading a drive without it makes macOS ask); unticked, deleted, one tick per drive.
    @Test func catalogItem() throws {
        #expect(!CleanerGroup.smartScan(ages: .default, hasFullDiskAccess: false).flatMap(\.items)
            .contains { $0.id == "external-trash" })
        let group = try #require(CleanerGroup.smartScan(ages: .default, hasFullDiskAccess: true).first { $0.id == "trash" })
        let item = try #require(group.items.first { $0.id == "external-trash" })
        #expect(item.externalTrash && item.paths.isEmpty && item.mode == .delete && !item.selectedByDefault)
        #expect(item.selectableEntries && !item.showsWhenEmpty && item.skipsOpenFiles && item.command == nil)
    }

    /// A drive's Trash is listed with the drive's name and size, and emptied (the folder stays); empty Trashes, other
    /// users' folders, read-only, network, browse-hidden and Time Machine volumes, unmounted folders and symlinked
    /// `.Trashes` or `<uid>` folders are never listed nor touched. A symlink in the Trash is removed, not its target.
    @Test func listsAndEmptiesOnlyTheUsersTrashOnEligibleDrives() async throws {
        defer { try? fm.removeItem(at: root) }
        let bait = try put("Projects/keep.txt", in: home)
        let ext = volumes.appending(path: "Ext")
        try put(".Trashes/\(uid)/movie.mov", in: ext)
        try put(".Trashes/\(uid)/Old Folder/a.zip", in: ext)
        try put(".Trashes/\(uid)/.DS_Store", in: ext, bytes: 100)
        try fm.createSymbolicLink(at: ext.appending(path: ".Trashes/\(uid)/link"), withDestinationURL: bait)
        let otherUser = try put(".Trashes/\(getuid() + 1)/theirs.mov", in: ext)
        let kept = try put("Movies/keep.mov", in: ext)
        try put(".Trashes/\(uid)/.DS_Store", in: volumes.appending(path: "Empty"), bytes: 100)
        var survivors = [bait, otherUser, kept]
        for name in ["ReadOnly", "Network", "Hidden", "TimeMachine", "Unmounted"] {
            survivors.append(try put(".Trashes/\(uid)/x.mov", in: volumes.appending(path: name)))
        }
        try put("Backups.backupdb/x", in: volumes.appending(path: "TimeMachine"), bytes: 10)
        let elsewhere = try put("Elsewhere/\(uid)/x.mov", in: home)
        survivors.append(elsewhere)
        let linkedFolder = volumes.appending(path: "LinkedFolder")
        try fm.createDirectory(at: linkedFolder.appending(path: ".Trashes"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: linkedFolder.appending(path: ".Trashes/\(uid)"),
                                  withDestinationURL: elsewhere.deletingLastPathComponent())
        let linkedTrashes = volumes.appending(path: "LinkedTrashes")
        try fm.createDirectory(at: linkedTrashes, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: linkedTrashes.appending(path: ".Trashes"),
                                  withDestinationURL: home.appending(path: "Elsewhere"))
        let snapshot = try put(".timemachine/snap/.Trashes/\(uid)/x.mov", in: volumes)
        survivors.append(snapshot)

        let policy = policy(mounted: ["Ext", "Empty", "ReadOnly", "Network", "Hidden", "TimeMachine", "LinkedFolder",
                                      "LinkedTrashes", ".timemachine/snap"],
                            flags: ["ReadOnly": Self.local | UInt32(MNT_RDONLY), "Network": 0,
                                    "Hidden": Self.local | UInt32(MNT_DONTBROWSE)])
        let folder = SafetyPolicy.normalize(ext.appending(path: ".Trashes/\(uid)"))
        #expect(policy.externalTrashFolders().map(SafetyPolicy.normalize)
            == [SafetyPolicy.normalize(volumes.appending(path: "Empty/.Trashes/\(uid)")), folder]) // by mount point
        for url in survivors + [ext.appending(path: ".Trashes"), ext.appending(path: ".Trashes/\(getuid() + 1)"),
                                linkedFolder.appending(path: ".Trashes/\(uid)"), linkedTrashes.appending(path: ".Trashes/\(uid)")] {
            #expect(!policy.allowsExternalTrash(url), "\(url.path)")
        }
        #expect(policy.allowsExternalTrash(ext.appending(path: ".Trashes/\(uid)/movie.mov")))

        let item = try item
        let scan = await Scanner.scan(item, policy: policy, openPaths: { _ in [] })
        let entry = try #require(scan.entries.first)
        #expect(scan.entries.count == 1 && SafetyPolicy.normalize(entry.url) == folder && entry.title == "Ext")
        #expect(entry.size >= 40_000)

        let report = await Cleaner.clean(item, scan: scan, policy: policy, openPaths: { _ in [] })
        #expect(report.skipped == 0 && report.freed == entry.size)
        #expect(try fm.contentsOfDirectory(atPath: folder).isEmpty)
        for url in survivors { #expect(fm.fileExists(atPath: url.path), "gone: \(url.path)") }
        #expect(await Scanner.scan(item, policy: policy, openPaths: { _ in [] }).entries.isEmpty)
    }

    /// A Trash holding a file a process has open (Finder still moving files there) is not listed, and one that became
    /// so since the scan is not emptied. Excluded drives are never listed either.
    @Test func skipsBusyAndExcludedTrashes() async throws {
        defer { try? fm.removeItem(at: root) }
        let busy = try put(".Trashes/\(uid)/copying.mov", in: volumes.appending(path: "Busy"))
        let policy = policy(mounted: ["Busy"])
        let open: @Sendable (String) -> Set<String> = { _ in [RunningProcesses.withoutPrivate(SafetyPolicy.normalize(busy))] }
        let item = try item
        #expect(await Scanner.scan(item, policy: policy, openPaths: open).entries.isEmpty)
        let scan = await Scanner.scan(item, policy: policy, openPaths: { _ in [] })
        #expect(scan.entries.count == 1)
        #expect(await Cleaner.clean(item, scan: scan, policy: policy, openPaths: open).skipped == 1)
        #expect(fm.fileExists(atPath: busy.path))

        let excluded = SafetyPolicy(home: home, temp: root.appending(path: "tmp"),
                                    excluded: [volumes.appending(path: "Busy").path],
                                    mounts: { ["/", SafetyPolicy.normalize(volumes.appending(path: "Busy"))] },
                                    volumesFolder: volumes.path, flags: { _ in Self.local })
        #expect(excluded.externalTrashFolders().isEmpty)
        #expect(await Cleaner.clean(item, scan: scan, policy: excluded, openPaths: { _ in [] }).skipped == 1)
        #expect(fm.fileExists(atPath: busy.path))
    }
}
