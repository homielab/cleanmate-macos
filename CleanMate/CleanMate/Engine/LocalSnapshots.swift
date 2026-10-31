import Foundation

/// Time Machine's local snapshots of the startup disk: copies of the disk macOS keeps between backups, which take
/// space no folder shows. Listed and deleted with `tmutil` as a user could in Terminal, without admin rights.
/// Their size needs admin rights to measure, so only their number and dates are known.
nonisolated struct LocalSnapshots: Equatable, Sendable {
    /// One snapshot whose name carries a readable date: the only ones that can be deleted by date.
    struct Snapshot: Equatable, Hashable, Sendable, Identifiable {
        /// The date as in the name, "2026-10-30-101112": what `tmutil deletelocalsnapshots` takes.
        var stamp: String
        var date: Date
        var id: String { stamp }
    }

    /// Snapshots listed; 0 when there are none.
    var count = 0
    /// From the snapshot names; nil when none could be read.
    var oldest: Date?
    var newest: Date?
    /// false: `tmutil` failed or timed out, so nothing is known.
    var readable = true
    /// The snapshots with a readable date, oldest first.
    var list: [Snapshot] = []

    static let unreadable = LocalSnapshots(readable: false)

    /// `tmutil listlocalsnapshots /`: a header line ("Snapshots for disk /:", macOS 10.15 and later) and one
    /// line per snapshot, "com.apple.TimeMachine.2026-10-30-101112.local" (no ".local" before macOS 11). The date
    /// in the name is local time. Lines of other snapshots are not counted.
    static func parse(_ output: String?, timeZone: TimeZone = .current) -> LocalSnapshots {
        guard let output else { return .unreadable }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        var result = LocalSnapshots()
        for line in output.split(whereSeparator: \.isNewline) {
            let name = line.trimmingCharacters(in: .whitespaces)
            guard name.hasPrefix(prefix) else { continue }
            result.count += 1
            let stamp = String(name.dropFirst(prefix.count).prefix(17))
            guard stamp.wholeMatch(of: /\d{4}-\d{2}-\d{2}-\d{6}/) != nil, let date = formatter.date(from: stamp) else { continue }
            result.list.append(Snapshot(stamp: stamp, date: date))
            if result.oldest.map({ date < $0 }) ?? true { result.oldest = date }
            if result.newest.map({ date > $0 }) ?? true { result.newest = date }
        }
        result.list.sort { $0.date < $1.date }
        return result
    }

    private static let prefix = "com.apple.TimeMachine."

    /// Lists the startup disk's snapshots. Never asks for a password: listing needs no admin rights.
    @concurrent static func read() async -> LocalSnapshots {
        parse(await ShellCommand(executable: "/usr/bin/tmutil", arguments: ["listlocalsnapshots", "/"],
                                 timeout: .seconds(5)).output())
    }

    /// Deletes the snapshots taken at `snapshot`'s date. Needs no admin rights (checked on macOS 27). A large
    /// snapshot can take a while to delete.
    static func deleteCommand(_ snapshot: Snapshot) -> ShellCommand {
        ShellCommand(executable: "/usr/bin/tmutil", arguments: ["deletelocalsnapshots", snapshot.stamp],
                     timeout: .seconds(120))
    }
}
