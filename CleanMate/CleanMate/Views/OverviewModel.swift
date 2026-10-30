import Combine
import Foundation

/// Overview: drives and their free space, what CleanMate freed, and the largest folders in the home folder.
/// Read-only. Drives and freed space are read at once; folder sizes are measured in the background.
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

    @Published private(set) var disks: [Disk] = []
    @Published private(set) var cleanups = ActivityLog.Cleanups()
    /// Largest first, at most `folderLimit`; filled when measuring ends.
    @Published private(set) var folders: [SpaceItem] = []
    @Published private(set) var measuring = false
    /// The last measure finished (an empty `folders` then means an empty home folder).
    @Published private(set) var measured = false
    /// Folders macOS protects were left out (no Full Disk Access): the view shows a note.
    @Published private(set) var skippedProtected = false

    /// Injectable for tests: the folder measured and the activity log read.
    var home = SafetyPolicy.current.homeURL
    var hasFullDiskAccess: () -> Bool = { FullDiskAccess.isGranted }
    /// The end of "Last 30 days"; snapshots pin it.
    var now: () -> Date = { .now }
    /// The startup drive first, then external drives; tests pass their own.
    var readDisks: () -> [Disk] = { OverviewModel.mountedDisks() }
    var measure: @Sendable (URL, SpaceLens.HardLinks, Set<String>) async throws -> (size: Int64, folders: [String: Int64]) = {
        try await SpaceLens.measure($0, links: $1, skipping: $2)
    }
    /// Space Lens takes the sizes measured here, so opening a folder from the list is instant.
    weak var spaceLens: SpaceLensModel?

    private var task: Task<Void, Never>?
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

    /// When the Overview is shown: everything the first time or after a removal, else drives and freed space only.
    func startIfNeeded() {
        if !started || stale { refresh() } else { readQuick() }
    }

    /// "Refresh" and ⌘R: reads everything again.
    func refresh() {
        started = true
        stale = false
        readQuick()
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
        cleanups = ActivityLog.cleanups(now: now(), home: home)
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
            var listed = await SpaceLens.list(home, links: links).filter(\.isFolder)
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
