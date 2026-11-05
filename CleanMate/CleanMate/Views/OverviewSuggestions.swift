import Foundation

/// One line of Overview › Suggestions: where space can be won next. Its button opens the module where the user
/// decides; nothing is ever cleaned from the Overview.
nonisolated struct Suggestion: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Junk the last Smart Scan found in a group and that was not cleaned since; `title` is the group's.
        case junk(title: LocalizedStringResource)
        case trash, externalTrash, unusedApps, downloads, docker, snapshots
        /// Container VMs not run for at least `days` days (the most recently run of them).
        case containerVMs(days: Int)
        /// Models of local AI apps not used for at least `days` days (the most recently used of them).
        case unusedModels(days: Int)
    }

    /// Where the button leads (`ModuleRouter.open`).
    enum Target: Equatable, Sendable {
        /// Smart Scan, scrolled to this group id (scanning first when it has no results).
        case smartScanGroup(String)
        /// Smart Scan, scrolled to this item of this group (scanning first like `smartScanGroup`).
        case smartScanItem(group: String, item: String)
        /// Uninstaller, showing apps not used for 3 months, largest first.
        case uninstallerUnused
        /// Maintenance, at the local snapshots.
        case maintenanceSnapshots

        var module: Module {
            switch self {
            case .smartScanGroup, .smartScanItem: .smartScan
            case .uninstallerUnused: .uninstaller
            case .maintenanceSnapshots: .maintenance
            }
        }
    }

    let id: String
    let kind: Kind
    let systemImage: String
    /// When `size` was measured (the last Smart Scan's date for junk); Smart Scan rescans results older than this.
    var measuredAt: Date?
    /// Bytes to win; nil when unknown (local snapshots need admin rights to measure).
    var size: Int64?
    /// Apps, files or snapshots; nil for a size alone.
    var count: Int?
    let target: Target
}

/// Reads Overview › Suggestions in the background from data CleanMate already has or reads cheaply: the last Smart Scan
/// per group, the Trash, apps not opened for 3 months (the Uninstaller's list, no new Spotlight query), old installers
/// and downloads and the Trash of external drives (only with Full Disk Access: reading them without makes macOS ask),
/// unused Docker data (only while Docker runs; never started), container VMs not run for `vmIdleAge`, local AI models
/// not used for `modelIdleAge` and Time Machine's local snapshots.
nonisolated enum OverviewSuggestions {
    /// At most this many suggestions show.
    static let limit = 5
    /// Less than this is not worth a suggestion.
    static let minimum: Int64 = 100_000_000
    /// An older Smart Scan no longer says what is on the disk: its groups are not suggested.
    static let scanMaxAge: TimeInterval = 30 * 86_400
    /// Smart Scan items measured live here, so the last scan's groups leave them out (`LastScan.groups`).
    static let liveItems = Set(["empty-trash", "external-trash", "old-installers", "old-downloads", ContainerVMs.id])
        .union(dockerItems).union(LocalModels.ids)
    /// A container VM not run for longer than this is suggested.
    static let vmIdleAge: TimeInterval = 90 * 86_400
    /// A local AI model not used for longer than this is suggested.
    static let modelIdleAge: TimeInterval = 90 * 86_400
    static let dockerItems: Set<String> = ["docker-images", "docker-dangling", "docker-build-cache", "docker-containers",
                                           "docker-volumes"]
    /// The Trash has its own suggestion, measured live.
    static let skippedGroups: Set<String> = ["trash"]

    /// What is read live; tests pass their own.
    struct Sources: Sendable {
        /// Bytes in ~/.Trash.
        var trash: @Sendable () async -> Int64
        /// Bytes in the Trash of external drives; only asked with Full Disk Access.
        var externalTrash: @Sendable () async -> Int64
        /// Old installers and old downloads in Downloads (Settings › Smart Scan ages); only asked with Full Disk Access.
        var downloads: @Sendable () async -> (count: Int, size: Int64)
        /// Unused Docker images, volumes, containers and build cache; nil when Docker is not running.
        var docker: @Sendable () async -> Int64?
        /// The Uninstaller's app list, when it was not loaded yet.
        var apps: @Sendable () async -> [InstalledApp]
        var appSize: @Sendable (URL) async -> Int64
        /// Size and last run of each container VM that is not running (`ContainerVMs`).
        var containerVMs: @Sendable () async -> [(size: Int64, lastRun: Date?)] = { [] }
        /// Item id, size and last use of each model of a local AI app (`LocalModels`).
        var aiModels: @Sendable () async -> [(item: String, size: Int64, lastUsed: Date?)] = { [] }

        /// Nothing found, nothing run: the default under tests.
        static let none = Sources(trash: { 0 }, externalTrash: { 0 }, downloads: { (0, 0) }, docker: { nil },
                                  apps: { [] }, appSize: { _ in 0 })

        /// The Smart Scan items themselves, so the numbers match what Smart Scan shows.
        static let live = Sources(
            trash: { await scanSize(["empty-trash"], hasFullDiskAccess: false).size },
            externalTrash: { await scanSize(["external-trash"], hasFullDiskAccess: true).size },
            downloads: { await scanSize(["old-installers", "old-downloads"], hasFullDiskAccess: true) },
            docker: {
                guard DeveloperTools.dockerDaemonIsRunning() else { return nil }
                return await scanSize(dockerItems, hasFullDiskAccess: false).size
            },
            apps: { await Uninstaller.installedApps() },
            appSize: { await Uninstaller.size(of: $0) },
            containerVMs: {
                let items = CleanerGroup.smartScan(hasFullDiskAccess: false).flatMap(\.items).filter { $0.id == ContainerVMs.id }
                var found: [(size: Int64, lastRun: Date?)] = []
                for item in items {
                    let scan = await Scanner.scan(item, openPaths: { _ in [] })
                    found += scan.entries.filter { $0.lockReason == nil }.map { ($0.size, $0.date) }
                }
                return found
            },
            aiModels: {
                let ids = Set(LocalModels.ids)
                let items = CleanerGroup.smartScan(hasFullDiskAccess: FullDiskAccess.isGranted).flatMap(\.items)
                    .filter { ids.contains($0.id) }
                var found: [(item: String, size: Int64, lastUsed: Date?)] = []
                for item in items {
                    let scan = await Scanner.scan(item, openPaths: { _ in [] })
                    found += scan.entries.filter { $0.lockReason == nil }.map { (item.id, $0.size, $0.date) }
                }
                return found
            })

        /// Entries and bytes of these Smart Scan items. Open files are not read (no `lsof`): a file still open is
        /// counted, Smart Scan itself skips it.
        private static func scanSize(_ ids: Set<String>, hasFullDiskAccess: Bool) async -> (count: Int, size: Int64) {
            let items = CleanerGroup.smartScan(hasFullDiskAccess: hasFullDiskAccess).flatMap(\.items)
                .filter { ids.contains($0.id) }
            var total = (count: 0, size: Int64(0))
            for item in items {
                let scan = await Scanner.scan(item, openPaths: { _ in [] })
                total.count += scan.entries.count
                total.size += scan.size
            }
            return total
        }
    }

    /// Everything known now, then the live reads; at most `limit`, largest first, snapshots (no size) last.
    /// `apps`/`appSizes`: the Uninstaller's list and sizes when already loaded, else read through `sources`.
    @concurrent static func read(lastScan: LastScan?, snapshots: LocalSnapshots?, hasFullDiskAccess: Bool,
                                 apps loadedApps: [InstalledApp]?, appSizes: [URL: Int64], now: Date,
                                 sources: Sources) async -> [Suggestion] {
        var found = junk(lastScan, now: now)
        let trash = await sources.trash()
        found.append(Suggestion(id: "trash", kind: .trash, systemImage: "trash", size: trash,
                                target: .smartScanGroup("trash")))
        if hasFullDiskAccess {
            let external = await sources.externalTrash()
            found.append(Suggestion(id: "external-trash", kind: .externalTrash, systemImage: "externaldrive",
                                    size: external, target: .smartScanGroup("trash")))
            let downloads = await sources.downloads()
            found.append(Suggestion(id: "downloads", kind: .downloads, systemImage: "arrow.down.circle",
                                    size: downloads.size, count: downloads.count, target: .smartScanGroup("system-junk")))
        }
        if let docker = await sources.docker() {
            found.append(Suggestion(id: "docker", kind: .docker, systemImage: "shippingbox", size: docker,
                                    target: .smartScanGroup("developer")))
        }
        let idle = await sources.containerVMs().compactMap { vm in
            vm.lastRun.map { (size: vm.size, idle: now.timeIntervalSince($0)) }
        }.filter { $0.idle > vmIdleAge }
        if let latest = idle.map(\.idle).min() {
            found.append(Suggestion(id: "container-vms", kind: .containerVMs(days: Int(latest / 86_400)),
                                    systemImage: "server.rack", size: idle.reduce(0) { $0 + $1.size }, count: idle.count,
                                    target: .smartScanItem(group: "developer", item: ContainerVMs.id)))
        }
        let models = await sources.aiModels().compactMap { model in
            model.lastUsed.map { (item: model.item, size: model.size, idle: now.timeIntervalSince($0)) }
        }.filter { $0.idle > modelIdleAge }
        if let latest = models.map(\.idle).min() {
            // Opens the item holding the most of them.
            let bytes = Dictionary(grouping: models, by: \.item).mapValues { $0.reduce(0) { $0 + $1.size } }
            let item = bytes.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? models[0].item
            found.append(Suggestion(id: "ai-models", kind: .unusedModels(days: Int(latest / 86_400)), systemImage: "brain",
                                    size: models.reduce(0) { $0 + $1.size }, count: models.count,
                                    target: .smartScanItem(group: "ai-tools", item: item)))
        }
        let apps: [InstalledApp] = if let loadedApps { loadedApps } else { await sources.apps() }
        let unused = UninstallerModel.filtered(apps, search: "", unused: .months3, now: now)
        if !unused.isEmpty {
            var size: Int64 = 0
            for app in unused {
                if let known = appSizes[app.url] { size += known } else { size += await sources.appSize(app.url) }
            }
            found.append(Suggestion(id: "unused-apps", kind: .unusedApps, systemImage: "app.badge", size: size,
                                    count: unused.count, target: .uninstallerUnused))
        }
        if let snapshots, snapshots.count > 0 {
            found.append(Suggestion(id: "snapshots", kind: .snapshots, systemImage: "clock.arrow.circlepath",
                                    count: snapshots.count, target: .maintenanceSnapshots))
        }
        for index in found.indices where found[index].measuredAt == nil { found[index].measuredAt = now }
        return ranked(found)
    }

    /// The last Smart Scan's groups still holding junk, when the scan is recent enough.
    static func junk(_ lastScan: LastScan?, now: Date) -> [Suggestion] {
        guard let lastScan, let groups = lastScan.groups, now.timeIntervalSince(lastScan.date) <= scanMaxAge else { return [] }
        let catalog = CleanerGroup.smartScan(ages: .default)
        return groups.compactMap { id, size in
            guard !skippedGroups.contains(id), let group = catalog.first(where: { $0.id == id }) else { return nil }
            var suggestion = Suggestion(id: "junk-" + id, kind: .junk(title: group.title),
                                        systemImage: group.systemImage, size: size, target: .smartScanGroup(id))
            suggestion.measuredAt = lastScan.date
            return suggestion
        }
    }

    /// Sized ones of at least `minimum`, largest first, then the unsized; at most `limit`.
    static func ranked(_ found: [Suggestion]) -> [Suggestion] {
        let sized = found.filter { ($0.size ?? 0) >= minimum }.sorted { ($0.size ?? 0, $1.id) > ($1.size ?? 0, $0.id) }
        let unsized = found.filter { $0.size == nil }
        return Array((sized + unsized).prefix(limit))
    }
}
