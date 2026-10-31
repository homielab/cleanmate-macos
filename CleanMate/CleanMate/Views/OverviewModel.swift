import Combine
import Foundation

/// Overview: drives and their free space, free space over the last 30 days, what CleanMate freed, space outside
/// the user's folders, the largest folders in the home folder and whether macOS's protections are on.
/// Read-only. Drives and freed space are read at once; folder sizes, local snapshots and protections are read in the
/// background.
final class OverviewModel: ObservableObject {
    nonisolated struct Disk: Identifiable, Equatable, Sendable {
        let url: URL
        var volume: SpaceLensModel.Volume
        var id: URL { url }
        /// Share of the drive in use, 0…1.
        var usedFraction: Double { volume.total > 0 ? Double(volume.used) / Double(volume.total) : 0 }
    }

    /// What `disks` needs to know about a mounted volume; injectable for tests, which can't mount a drive.
    nonisolated struct MountInfo: Sendable {
        var volume = SpaceLensModel.Volume()
        var isLocal = true
        var isBrowsable = true
        var isReadOnly = false
        /// A Time Machine backup disk.
        var isBackup = false
    }

    /// At most this many folders are listed.
    static let folderLimit = 12
    /// Less purgeable space than this is not shown.
    static let purgeableMinimum: Int64 = 100_000_000

    @Published private(set) var disks: [Disk] = []
    @Published private(set) var cleanups = ActivityLog.Cleanups()
    /// Bytes deleted per day over the last 30 days, oldest first; empty before the first cleanup.
    var freedByDay: [ActivityLog.Cleanups.Day] { cleanups.byDay }
    /// Parts of the Overview that animate in the first time they show in a session (the numbers count up, bars and
    /// charts grow), then stay still when the Overview is shown again.
    enum Intro: CaseIterable { case drives, history, freed }
    /// Parts already shown; snapshots fill it so they render the still state.
    var introduced: Set<Intro> = []
    /// Free space on the startup disk over the last `DiskHistory.chartDays` days, oldest first.
    @Published private(set) var history: [DiskHistory.Point] = []
    /// Largest first, at most `folderLimit`; filled when measuring ends.
    @Published private(set) var folders: [SpaceItem] = []
    @Published private(set) var measuring = false
    /// The last measure finished (an empty `folders` then means an empty home folder).
    @Published private(set) var measured = false
    /// Folders macOS protects were left out (no Full Disk Access): the view shows a note.
    @Published private(set) var skippedProtected = false
    /// Gatekeeper, firewall, SIP, FileVault, XProtect; nil until first read.
    @Published private(set) var security: SecurityStatus?
    /// Time Machine's local snapshots of the startup disk; nil until first read.
    @Published private(set) var snapshots: LocalSnapshots?
    /// The home folder's size from the last measure: its folders plus the files directly in it.
    @Published private(set) var homeSize: Int64?

    /// Injectable for tests: the folder measured and the activity log read.
    var home = SafetyPolicy.current.homeURL
    var hasFullDiskAccess: () -> Bool = { FullDiskAccess.isGranted }
    /// The end of "Last 30 days" and of the free-space chart; snapshots pin it.
    var now: () -> Date = { .now }
    /// Days of the history and freed-per-day charts; tests pin the time zone.
    var calendar = Calendar.current
    /// Tests and snapshots pass one in memory.
    var diskHistory = DiskHistory.shared
    /// The startup drive first, then external drives; tests pass their own.
    var readDisks: () -> [Disk] = { OverviewModel.mountedDisks() }
    var measure: @Sendable (URL, SpaceLens.HardLinks, Set<String>) async throws -> (size: Int64, folders: [String: Int64]) = {
        try await SpaceLens.measure($0, links: $1, skipping: $2)
    }
    /// Tests pass their own; running under tests without one reads nothing (all unknown), so no command runs.
    var readSecurity: @Sendable () async -> SecurityStatus = {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil ? await SecurityStatus.read() : SecurityStatus()
    }
    /// Like `readSecurity`: under tests without one, no command runs.
    var readSnapshots: @Sendable () async -> LocalSnapshots = {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil ? await LocalSnapshots.read() : .unreadable
    }
    /// Space Lens takes the sizes measured here, so opening a folder from the list is instant.
    weak var spaceLens: SpaceLensModel?

    private var task: Task<Void, Never>?
    private var securityTask: Task<Void, Never>?
    private var snapshotsTask: Task<Void, Never>?
    private var started = false
    /// Something was removed since the last measure: measure again next time the Overview is shown.
    private var stale = false
    private var observer: (any NSObjectProtocol)?

    /// `center`: tests pass their own, so cleans recorded by tests running in parallel don't mark it stale.
    init(center: NotificationCenter = .default) {
        // Only marked: a clean records every item, and the Overview is not on screen while another module cleans.
        observer = center.addObserver(forName: ActivityLog.didRecord, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stale = true }
        }
    }

    /// When the Overview is shown: everything the first time or after a removal, else drives, freed space, local
    /// snapshots and protections only (a setting may have changed in System Settings meanwhile).
    func startIfNeeded() {
        if !started || stale { refresh() } else { readQuick(); readSnapshotList(); readSecurityStatus() }
    }

    /// "Refresh" and ⌘R: reads everything again.
    func refresh() {
        started = true
        stale = false
        readQuick()
        readSnapshotList()
        readSecurityStatus()
        measureFolders()
    }

    /// Stops measuring; the folders shown stay.
    func cancel() {
        task?.cancel()
        task = nil
        measuring = false
    }

    private func readQuick() {
        disks = readDisks()
        cleanups = ActivityLog.cleanups(now: now(), home: home, calendar: calendar)
        history = diskHistory.recent(now: now(), calendar: calendar)
    }

    /// Runs alongside the folder measure; ⌘. does not stop it (each command times out within seconds).
    private func readSecurityStatus() {
        securityTask?.cancel()
        let read = readSecurity
        securityTask = Task {
            let status = await read()
            guard !Task.isCancelled else { return }
            security = status
        }
    }

    /// Space macOS frees when it needs it on the startup disk; nil under `purgeableMinimum`.
    var purgeable: Int64? {
        guard let size = disks.first?.volume.purgeable, size >= Self.purgeableMinimum else { return nil }
        return size
    }

    /// Space in use on the startup disk outside the home folder (macOS, apps, other users, local snapshots); nil
    /// before the home folder is measured or when nothing is left.
    var systemAndApps: Int64? {
        guard let homeSize, let volume = disks.first?.volume, volume.total > 0 else { return nil }
        let size = volume.used - homeSize
        return size > 0 ? size : nil
    }

    /// Like the protections: alongside the folder measure, not stopped by ⌘. (`tmutil` times out within seconds).
    private func readSnapshotList() {
        snapshotsTask?.cancel()
        let read = readSnapshots
        snapshotsTask = Task {
            let list = await read()
            guard !Task.isCancelled else { return }
            snapshots = list
        }
    }

    private func measureFolders() {
        task?.cancel()
        let home = home.standardizedFileURL
        let skipping = ProtectedFolders.skipped(home: home, hasFullDiskAccess: hasFullDiskAccess())
        let measure = measure
        let epoch = spaceLens?.cacheEpoch
        measuring = true
        task = Task {
            // One per listing, as in Space Lens: sibling folders don't count a shared hard link twice.
            let links = SpaceLens.HardLinks()
            let entries = await SpaceLens.list(home, links: links)
            let looseFiles = entries.reduce(0) { $0 + ($1.isFolder ? 0 : $1.size ?? 0) }
            var listed = entries.filter(\.isFolder)
            for index in listed.indices {
                listed[index].isProtected = skipping.contains(listed[index].url.standardizedFileURL.path)
            }
            var nested: [String: Int64] = [:]
            await withTaskGroup(of: (URL, Int64, [String: Int64])?.self) { group in
                for item in listed where !item.isProtected {
                    group.addTask {
                        guard let result = try? await measure(item.url, links, skipping) else { return nil }
                        return (item.url, result.size, result.folders)
                    }
                }
                for await result in group {
                    guard let (url, size, folders) = result else { continue }
                    nested.merge(folders) { $1 }
                    if let index = listed.firstIndex(where: { $0.url == url }) { listed[index].size = size }
                }
            }
            guard !Task.isCancelled else { return }
            let sized = listed.filter { $0.size != nil }
            folders = Array(sized.filter { $0.sortSize > 0 }.sorted { $0.sortSize > $1.sortSize }.prefix(Self.folderLimit))
            skippedProtected = listed.contains(where: \.isProtected)
            homeSize = sized.reduce(looseFiles) { $0 + max($1.sortSize, 0) }
            measured = true
            measuring = false
            if let epoch {
                let listing = Dictionary(sized.map { ($0.url.path, $0.sortSize) }) { $1 }
                spaceLens?.remember(listing: listing, folders: nested, of: home, skipping: skipping, epoch: epoch)
            }
        }
    }

    /// The startup drive (holding `home`) first, then drives mounted directly in `volumesFolder` that are local,
    /// browsable and writable and not Time Machine backup disks, by name. Network shares, disk images mounted
    /// read-only and backup disks are left out.
    nonisolated static func disks(home: URL, mounts: [URL], volumesFolder: String = "/Volumes",
                                  info: (URL) -> MountInfo?) -> [Disk] {
        var external: [Disk] = []
        for url in mounts {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(volumesFolder + "/"), !path.dropFirst(volumesFolder.count + 1).contains("/"),
                  let mount = info(url), mount.isLocal, mount.isBrowsable, !mount.isReadOnly, !mount.isBackup,
                  mount.volume.total > 0 else { continue }
            external.append(Disk(url: url, volume: mount.volume))
        }
        external.sort { $0.volume.name.localizedStandardCompare($1.volume.name) == .orderedAscending }
        let startup = info(home).map { [Disk(url: home, volume: $0.volume)] } ?? []
        return startup + external
    }

    /// `disks` over the drives mounted now.
    nonisolated static func mountedDisks(home: URL = SafetyPolicy.current.homeURL) -> [Disk] {
        let keys: Set<URLResourceKey> = [.volumeIsLocalKey, .volumeIsBrowsableKey, .volumeIsReadOnlyKey]
        let mounts = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys),
                                                           options: [.skipHiddenVolumes]) ?? []
        return disks(home: home, mounts: mounts) { url in
            let values = try? url.resourceValues(forKeys: keys)
            var info = stat()
            let backup = ["Backups.backupdb", ".com.apple.timemachine.donotpresent"]
                .contains { lstat(url.path + "/" + $0, &info) == 0 }
            return MountInfo(volume: .read(url), isLocal: values?.volumeIsLocal ?? false,
                             isBrowsable: values?.volumeIsBrowsable ?? true, isReadOnly: values?.volumeIsReadOnly ?? false,
                             isBackup: backup)
        }
    }
}
