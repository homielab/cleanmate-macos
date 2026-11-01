import Foundation

/// Paths of open files under a folder (`RunningProcesses.openPaths(under:)`), as the scanner and cleaner ask for them
/// (`skipsOpenFiles`). Tests pass one reading their own process only, or one that counts calls.
typealias OpenPaths = @Sendable (String) async -> Set<String>

/// One read of the open-file table shared by every item of a scan or clean pass: reading it lists every fd of every
/// process (20–130 ms, more with many open files), so each `skipsOpenFiles` item reading it per root added up.
/// The table is read whole (`read("/")`) on the first request, then each folder is filtered from that copy.
/// `maxAge` re-reads it once older than that (the cleaner: an app opening a file mid-clean keeps it); nil keeps it
/// for the whole pass (the scan: the cleaner checks again before removing anything).
nonisolated final class OpenFiles: Sendable {
    /// How old the table the cleaner checks an entry against may be.
    static let cleanMaxAge = Duration.seconds(2)

    private struct Snapshot {
        let paths: Task<[String], Never>
        let at: ContinuousClock.Instant
        var byFolder: [String: Set<String>] = [:]
    }

    private let maxAge: Duration?
    private let read: @Sendable (String) -> Set<String>
    private let snapshot = Locked<Snapshot?>(nil)

    init(maxAge: Duration? = nil, read: @escaping @Sendable (String) -> Set<String> = { RunningProcesses.openPaths(under: $0) }) {
        self.maxAge = maxAge
        self.read = read
    }

    /// Open paths strictly under `folder`, like `RunningProcesses.openPaths(under:)` but from the shared table.
    /// Concurrent callers wait for the same read; none blocks a thread while it runs.
    func paths(under folder: String) async -> Set<String> {
        let current = snapshot.withLock { snapshot -> Snapshot in
            if let held = snapshot, maxAge.map({ held.at.duration(to: .now) <= $0 }) ?? true { return held }
            let read = read
            // Age counts from the start of the read: a file opened while it runs may be missing from it.
            let fresh = Snapshot(paths: Task.detached { Array(read("/")) }, at: .now)
            snapshot = fresh
            return fresh
        }
        let prefix = RunningProcesses.withoutPrivate(folder.hasSuffix("/") ? folder : folder + "/")
        if let known = current.byFolder[prefix] { return known }
        let found = Set(await current.paths.value.filter { $0.hasPrefix(prefix) })
        snapshot.withLock { snapshot in
            if snapshot?.at == current.at { snapshot?.byFolder[prefix] = found }
        }
        return found
    }

    /// `paths(under:)` of a new table, for one scan or clean on its own.
    static func reader(maxAge: Duration? = nil) -> OpenPaths {
        let files = OpenFiles(maxAge: maxAge)
        return { await files.paths(under: $0) }
    }
}
