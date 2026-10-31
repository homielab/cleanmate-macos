import Foundation

/// Plain-text record of everything CleanMate removed: one tab-separated line per removed item
/// (date, module, item, entries, size, deleted/trashed/restored, size in bytes) in ~/Library/Logs/CleanMate/activity.log.
/// Maintenance tasks add a ran/failed line with size 0; only deleted/trashed/restored lines count in `freed`.
/// Kept out of Smart Scan's "Old logs". Rotated to activity.1.log past `maxSize`.
/// Module and Smart Scan item names are stored in English (= their String Catalog key) and translated
/// by `display` when shown, so switching the app language translates old entries too.
nonisolated enum ActivityLog {
    static let maxSize = 1_000_000
    /// Posted after every `record` (object: the module's localization key), so cached sizes elsewhere can be dropped and Settings › Activity reloads.
    static let didRecord = Notification.Name("CleanMate.ActivityLog.didRecord")
    /// Serializes size check + rotation + append across every `record` caller: two rotations racing
    /// would remove the activity.1.log the other just made.
    private static let lock = NSLock()
    /// Tests must never add lines to the user's real log: `record` refuses (and asserts) under a test host.
    static func writesRealLogInTests(_ home: URL,
                                     environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
            && home.standardizedFileURL.path == URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
    }

    static func url(home: URL = SafetyPolicy.current.homeURL) -> URL {
        home.appending(path: "Library/Logs/CleanMate/activity.log")
    }

    static func record(module: LocalizedStringResource, item: String, count: Int = 1, size: Int64, mode: RemovalMode,
                       home: URL = SafetyPolicy.current.homeURL, date: Date = .now, rotateAt: Int = maxSize) {
        log(module: module, item: item, count: count, size: size, action: mode == .delete ? "deleted" : "trashed",
            home: home, date: date, rotateAt: rotateAt)
    }

    /// An item put back from the Trash by "Undo": its "trashed" bytes no longer count in `freed`.
    static func recordRestored(module: LocalizedStringResource, item: String, size: Int64,
                               home: URL = SafetyPolicy.current.homeURL, date: Date = .now) {
        log(module: module, item: item, count: 1, size: size, action: "restored", home: home, date: date, rotateAt: maxSize)
    }

    /// A Maintenance task that was run: "ran" when every step succeeded, else "failed". Removes nothing, so size 0.
    static func recordTask(module: LocalizedStringResource, item: String, succeeded: Bool,
                           home: URL = SafetyPolicy.current.homeURL, date: Date = .now) {
        log(module: module, item: item, count: 1, size: 0, action: succeeded ? "ran" : "failed", home: home, date: date,
            rotateAt: maxSize)
    }

    private static func log(module: LocalizedStringResource, item: String, count: Int, size: Int64, action: String,
                            home: URL, date: Date, rotateAt: Int) {
        guard !writesRealLogInTests(home) else {
            // Loud in a test run: a test forgot to pass a throwaway home.
            assertionFailure("Test wrote to the real activity log: \(english(module)) \(item)")
            return
        }
        let fields = [
            Date.ISO8601FormatStyle(timeZone: .current).format(date),
            english(module), item, String(count), size.formatted(.fileSize), action, String(size),
        ]
        append(fields.map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
            .joined(separator: "\t") + "\n", to: url(home: home), rotateAt: rotateAt)
        NotificationCenter.default.post(name: didRecord, object: module.key)
    }

    /// Separates the English text, the catalog key and its arguments in the item column of an interpolated title.
    static let separator = "\u{1F}"

    /// English text of `resource`: the String Catalog key for plain strings, so `display` can look it up again.
    /// Interpolated titles ("Chrome: cache & logs") become "Chrome: cache & logs␟%@: cache & logs␟Chrome".
    static func english(_ resource: LocalizedStringResource) -> String {
        var english = resource
        english.locale = Locale(identifier: "en")
        let text = String(localized: english)
        let key = resource.key
        // shortcut: only `%@` arguments are recovered (all interpolated item titles today); others stay English.
        let parts = key.components(separatedBy: "%@")
        guard parts.count > 1, !parts.contains(where: { $0.contains("%") }),
              let regex = try? Regex(parts.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "(.*)")),
              let match = try? regex.wholeMatch(in: text) else { return text }
        let arguments = match.output.dropFirst().map { $0.substring.map(String.init) ?? "" }
        return ([text, key] + arguments).joined(separator: separator)
    }

    /// The String Catalog entry `key` in `locale`'s language (`key` itself when it has none).
    private static func localized(_ key: String, locale: Locale) -> String {
        var resource = LocalizedStringResource(String.LocalizationValue(key))
        resource.locale = locale
        return String(localized: resource)
    }

    /// `item` from the log in `locale`'s language: an interpolated title is formatted again from its key and
    /// arguments; the stored English text when the key's translation no longer takes those arguments.
    private static func interpolated(_ item: String, locale: Locale) -> String {
        let parts = item.components(separatedBy: separator)
        let format = localized(parts[1], locale: locale)
        let arguments = Array(parts.dropFirst(2))
        // Only `%@` / `%1$@` take the string arguments: a `%s` or `%d` from a damaged line would read them as C types.
        let objects = format.matches(of: /%(\d+\$)?@/).count
        guard objects == arguments.count, format.count(where: { $0 == "%" }) == objects else { return parts[0] }
        return String(format: format, locale: locale, arguments: arguments.map { $0 as CVarArg })
    }

    /// One row of Settings › Activity.
    struct Entry: Identifiable, Equatable {
        var id = 0
        var date: Date?
        /// The date column as written, shown when it doesn't parse.
        var dateText = ""
        /// Module in `locale`'s language; `moduleKey` is the column as written (English in current versions), used to filter.
        var module = ""
        var moduleKey = ""
        var item = ""
        /// Size as written (in the language of that time); `bytes` when the line has the raw column.
        var size = ""
        var bytes: Int64?
        /// "deleted", "trashed" or "restored"; "ran" or "failed" for a Maintenance task.
        var kind = ""
    }

    /// One log line for Settings › Activity: module and item translated to `locale`'s language when they are
    /// catalog keys; paths and lines written by older versions (already translated) show as they are.
    /// A line with fewer than 6 columns keeps its whole text in `item`.
    static func entry(_ line: Substring, id: Int = 0, locale: Locale = .current) -> Entry {
        var fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 6 else { return Entry(id: id, item: String(line)) }
        let moduleKey = fields[1]
        if fields[2].components(separatedBy: separator).count > 2 { fields[2] = interpolated(fields[2], locale: locale) }
        // Paths aren't keys; "%" would be read as a format specifier.
        for index in 1...2 where !fields[index].hasPrefix("/") && !fields[index].contains("%") {
            fields[index] = localized(fields[index], locale: locale)
        }
        return Entry(id: id, date: try? Date(fields[0], strategy: .iso8601), dateText: fields[0], module: fields[1],
                     moduleKey: moduleKey, item: fields[2], size: fields[4], bytes: fields.count > 6 ? Int64(fields[6]) : nil, kind: fields[5])
    }

    /// The log's text, oldest line first; empty when nothing was removed yet.
    static func read(home: URL = SafetyPolicy.current.homeURL) -> String {
        (try? String(contentsOf: url(home: home), encoding: .utf8)) ?? ""
    }

    /// activity.1.log then activity.log, oldest line first: Settings › Activity and `freed` still show what was
    /// rotated away. Under `lock`, so a rotation in between can't hide the lines just moved.
    static func readAll(home: URL = SafetyPolicy.current.homeURL) -> String {
        let current = url(home: home)
        let rotated = current.deletingPathExtension().appendingPathExtension("1.log")
        lock.lock()
        defer { lock.unlock() }
        return [rotated, current].compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    }

    /// Bytes removed since `cutoff`, counted from both log files (activity.1.log too). Only lines with the raw
    /// byte column (written by current versions) count: the formatted size column depends on the locale it was written in.
    /// `trashed` is still in the Trash; `since` is the oldest counted line.
    static func freed(after cutoff: Date = .distantPast, home: URL = SafetyPolicy.current.homeURL)
        -> (deleted: Int64, trashed: Int64, since: Date?) {
        var result: (deleted: Int64, trashed: Int64, since: Date?) = (0, 0, nil)
        // Trashed bytes counted so far per module + item: a "restored" line takes back only what its own "trashed"
        // line added in this window, never bytes trashed by something else.
        var counted: [String: Int64] = [:]
        for line in readAll(home: home).split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 7, let bytes = Int64(fields[6]), bytes >= 0,
                  let date = try? Date(String(fields[0]), strategy: .iso8601), date >= cutoff else { continue }
            let key = String(fields[1] + "\t" + fields[2])
            switch fields[5] {
            case "deleted": result.deleted += bytes
            case "trashed": result.trashed += bytes; counted[key, default: 0] += bytes
            case "restored": // put back by Undo
                let back = min(bytes, counted[key] ?? 0)
                result.trashed -= back
                counted[key]? -= back
            default: continue
            }
            result.since = min(result.since ?? date, date)
        }
        return result
    }

    /// Overview "Freed by CleanMate": bytes deleted (moved to the Trash doesn't count, as in `freed`).
    struct Cleanups: Equatable {
        /// Same figure as the menu bar: `freed(after: now − 30 days).deleted`.
        var last30Days: Int64 = 0
        var total: Int64 = 0
        /// The latest cleanup: deleted lines at most `cleanupGap` apart, ending with the newest one.
        var lastDate: Date?
        var lastBytes: Int64 = 0
    }

    /// Lines further apart than this belong to different cleanups.
    static let cleanupGap: TimeInterval = 5 * 60

    /// `Cleanups` from both log files in one read; the "deleted" lines `freed` counts, no others.
    static func cleanups(now: Date = .now, home: URL = SafetyPolicy.current.homeURL) -> Cleanups {
        var result = Cleanups()
        let cutoff = now.addingTimeInterval(-30 * 86_400)
        var lines: [(date: Date, bytes: Int64)] = []
        for line in readAll(home: home).split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 7, fields[5] == "deleted", let bytes = Int64(fields[6]), bytes >= 0,
                  let date = try? Date(String(fields[0]), strategy: .iso8601) else { continue }
            result.total += bytes
            if date >= cutoff { result.last30Days += bytes }
            lines.append((date, bytes))
        }
        lines.sort { $0.date < $1.date }
        guard var previous = lines.last?.date else { return result }
        result.lastDate = previous
        for line in lines.reversed() {
            guard previous.timeIntervalSince(line.date) <= cleanupGap else { break }
            result.lastBytes += line.bytes
            previous = line.date
        }
        return result
    }

    private static func append(_ line: String, to url: URL, rotateAt: Int) {
        lock.lock()
        defer { lock.unlock() }
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int, size > rotateAt {
            let old = url.deletingPathExtension().appendingPathExtension("1.log")
            try? manager.removeItem(at: old)
            try? manager.moveItem(at: url, to: old)
        }
        // O_APPEND: lines from modules cleaning at the same time don't overwrite each other.
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let data = Data(line.utf8)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }
}
