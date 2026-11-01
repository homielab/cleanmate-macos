import Foundation

/// Size and free space of a volume (Space Lens, Overview, menu bar item, low-disk warning).
nonisolated struct DiskVolume: Equatable, Sendable {
    var name = ""
    var total: Int64 = 0
    var available: Int64 = 0
    /// Part of `available` macOS frees only when it needs the space (downloaded iCloud files, local snapshots,
    /// system caches); 0 when unknown.
    var purgeable: Int64 = 0
    var used: Int64 { max(total - available, 0) }
    /// Reads the volume holding `url` (also used by the menu bar item and the Overview). Free space for important
    /// use, as Finder shows; plain free space on a volume that has no such figure.
    static func read(_ url: URL) -> DiskVolume {
        let values = try? url.resourceValues(forKeys: [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey])
        let plain = values?.volumeAvailableCapacity.map(Int64.init)
        return DiskVolume(name: values?.volumeName ?? "", total: Int64(values?.volumeTotalCapacity ?? 0),
                          available: values?.volumeAvailableCapacityForImportantUsage ?? plain ?? 0,
                          purgeable: purgeable(important: values?.volumeAvailableCapacityForImportantUsage,
                                               available: plain))
    }
    /// Free space for important use minus plain free space, never below 0; 0 when either is unknown.
    static func purgeable(important: Int64?, available: Int64?) -> Int64 {
        guard let important, let available else { return 0 }
        return max(important - available, 0)
    }
    /// Free-space warning level: orange under 10% free, red under 5%.
    enum Level { case normal, low, critical }
    var level: Level {
        guard total > 0 else { return .normal }
        let free = Double(available) / Double(total)
        return free < 0.05 ? .critical : free < 0.10 ? .low : .normal
    }
}
