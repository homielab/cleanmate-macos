import Foundation

// Declarative cleaner model shared by every module: group → item → paths (or a command).
// Later modules add items here (or their own catalogs) without touching the scanner/cleaner.

nonisolated enum RemovalMode: Sendable {
    /// Regenerable data (caches, logs, dev junk): removed permanently.
    case delete
    /// User files / uninstalled apps: moved to the Trash.
    case trash
}


/// Measures an item with a command instead of (or before) walking its folders.
nonisolated struct SizeProbe: Sendable {
    enum Result: Sendable {
        /// The reclaimable size reported by the tool (e.g. `docker system df`); no file list.
        case bytes(Int64)
        /// Only these top-level names inside the item's `paths` are measured and removed.
        case only(Set<String>)
    }

    var command: ShellCommand
    /// Checked first; false hides the item without running the command (e.g. Docker daemon not running).
    var precondition: @Sendable () -> Bool = { true }
    /// Parses the command's standard output; nil = nothing to report.
    var parse: @Sendable (String) -> Result?
    /// With `.bytes`: a second command whose parsed rows are listed in the expanded row (Docker's unused images).
    /// Display only: the item's command does the cleaning, these entries are never removed (see `Cleaner.remove`).
    /// The same command as `command` is not run again: the probe's output is parsed.
    var details: (command: ShellCommand, parse: @Sendable (String) -> [ScanEntry])? = nil
    /// What the command's output depends on (e.g. `folderDates`). Same value as the last run, less than `reuseLimit`
    /// ago → that run's output is reused from `Preferences.probeOutputs` instead of running the command (brew).
    var fingerprint: (@Sendable () -> String)? = nil

    /// Also covers what changes with time only (brew drops old logs and locks by age).
    static let reuseLimit: TimeInterval = 6 * 3600

    /// The command's output, or the saved one when `fingerprint` is unchanged (see above).
    func output(defaults: UserDefaults = .standard, now: Date = .now) async -> String? {
        guard let fingerprint else { return await command.output() }
        let current = fingerprint()
        if let saved = Self.reusable(defaults.dictionary(forKey: Preferences.probeOutputs)?[key] as? [String: Any],
                                     fingerprint: current, now: now) { return saved }
        guard let output = await command.output() else { return nil }
        var all = defaults.dictionary(forKey: Preferences.probeOutputs) ?? [:]
        all[key] = ["fingerprint": current, "output": output, "date": now]
        defaults.set(all, forKey: Preferences.probeOutputs)
        return output
    }

    /// Drops the saved output: after the item's own command ran (`brew cleanup`), the next run must be real even when
    /// what it removed is outside the fingerprinted folders.
    func forgetOutput(defaults: UserDefaults = .standard) {
        guard fingerprint != nil, var all = defaults.dictionary(forKey: Preferences.probeOutputs) else { return }
        all[key] = nil
        defaults.set(all, forKey: Preferences.probeOutputs)
    }

    private var key: String { ([command.executable] + command.arguments).joined(separator: " ") }

    /// The saved output when it was made with `fingerprint` within `reuseLimit` before `now` (a clock moved back
    /// counts as expired).
    static func reusable(_ saved: [String: Any]?, fingerprint: String, now: Date) -> String? {
        guard let saved, saved["fingerprint"] as? String == fingerprint, let date = saved["date"] as? Date,
              date <= now, now.timeIntervalSince(date) < reuseLimit else { return nil }
        return saved["output"] as? String
    }

    /// Modification dates of each folder and of its direct children: a file added or removed inside one of them
    /// (a download, a new version folder in `Cellar/<name>`) changes the result. Missing folders count too.
    static func folderDates(_ folders: [URL]) -> String {
        func date(_ url: URL) -> String {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                .map { "\($0.timeIntervalSinceReferenceDate)" } ?? "-"
        }
        return folders.map { folder in
            let children = (try? FileManager.default.contentsOfDirectory(at: folder,
                includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            return ([folder.path + "=" + date(folder)]
                + children.map { $0.lastPathComponent + "=" + date($0) }.sorted()).joined(separator: "\n")
        }.joined(separator: "\n")
    }
}

/// Asks an installed tool where its cache really is (`go env GOMODCACHE`, `npm config get cache`): users move
/// caches in config files the tool reads, which an app launched from Finder can't see in the shell's env.
nonisolated struct PathLookup: Sendable {
    var command: ShellCommand
    /// Appended to the printed folder (npm prints `~/.npm`, its cache is `~/.npm/_cacache`).
    var subpath = ""

    /// The folder from the first output line; nil when the tool is missing or fails, or when the folder is not
    /// strictly inside home, is refused by `policy` itself (e.g. `~/Library/Caches`, `~/Documents`), or is
    /// reached through a symlink.
    func root(policy: SafetyPolicy) async -> URL? {
        guard let url = await printed(),
              url.path.hasPrefix(policy.homeURL.standardizedFileURL.path + "/"), policy.allows(url),
              !policy.rootThroughSymlink(url) else { return nil }
        return url
    }

    /// The folder the tool printed (plus `subpath`), before any check; nil when the tool is missing or fails.
    func printed() async -> URL? {
        guard let line = await command.output()?.split(whereSeparator: \.isNewline).first?
                .trimmingCharacters(in: .whitespaces), line.hasPrefix("/") else { return nil }
        var url = URL(fileURLWithPath: line).standardizedFileURL
        if !subpath.isEmpty { url.append(path: subpath) }
        return url
    }
}

/// Folders named in a tool's settings file, read at each scan (see `CleanerItem.configFolders`).
nonisolated struct ConfigFolders: Sendable {
    var read: @Sendable (URL) -> [String]
    /// Below each folder read: `""` = the folder itself, `*` components allowed.
    var subpaths: [String] = [""]
}

/// Erases records inside a SQLite database with `/usr/bin/sqlite3` instead of removing the file.
nonisolated struct DatabaseErase: Sendable {
    /// Returns one number: the records `erase` would remove. Also checks the schema (a failing count lists the
    /// database with an unknown count, e.g. while the app holds a lock). Empty with `tables`: the records of every
    /// matching table this database has (a table renamed between versions, e.g. Chromium's autofill → autocomplete).
    var count: String
    /// Statements run on the database (one transaction). `vacuum` runs afterwards on its own.
    var erase = ""
    /// When set, `erase` is ignored: these tables (fnmatch patterns) are emptied in one transaction, skipping
    /// the ones this database doesn't have (Chromium's schema changes between versions).
    var tables: [String] = []
    /// Run after a successful erase so the space is really freed. Separate from the erase: it needs free
    /// space about the database's size, and when it fails (disk full) the records are still erased.
    var vacuum = "VACUUM;"
    /// When set, only entries with this name are databases; the item's other entries are removed as files.
    var file: String? = nil

    func applies(to url: URL) -> Bool { file == nil || url.lastPathComponent == file }

    /// Lists every table as hex, so a name with a quote or a newline is read back exactly.
    static let tableQuery = "SELECT hex(name) FROM sqlite_master WHERE type = 'table';"

    /// The tables in `tableQuery`'s output matching `tables`, quoted as SQL identifiers.
    func matching(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).compactMap { hex -> String? in
            let bytes = stride(from: 0, to: hex.count - 1, by: 2).compactMap {
                UInt8(hex.dropFirst($0).prefix(2), radix: 16)
            }
            guard let name = String(bytes: bytes, encoding: .utf8),
                  tables.contains(where: { fnmatch($0, name, 0) == 0 }) else { return nil }
            return "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
    }

    static let sqlite = "/usr/bin/sqlite3"
}

nonisolated struct CleanerItem: Identifiable, Sendable {
    let id: String
    let title: LocalizedStringResource
    var note: LocalizedStringResource? = nil
    /// Folders whose *contents* are cleaned; the folder itself is kept. `~` = home, `$TMPDIR` = user temp folder.
    /// A `*` path component matches every non-hidden folder there (e.g. browser profiles: `…/Chrome/*/GPUCache`).
    var paths: [String]
    /// Only top-level entries in which nothing was modified for this long (removed whole, never half a folder).
    /// nil = every top-level entry.
    var minAge: TimeInterval? = nil
    /// Names inside `paths` that are never touched: a top-level name (`keep`) or a nested path (`Google/Chrome`).
    /// A folder holding a nested one is listed child by child instead of whole, so it is never removed.
    var excluded: Set<String> = []
    /// When set, only top-level entries matching one of these fnmatch patterns (hidden names included), e.g.
    /// single files at the home root (`.zsh_history`) or `Cookies` in a browser profile. The folder itself is kept.
    /// Checked at scan and again before removal (an entry's own name).
    var included: [String]? = nil
    /// When set, matched entries are SQLite databases that are kept: only these records are erased
    /// (e.g. downloads inside Chromium's History, which also holds other data).
    var database: DatabaseErase? = nil
    var mode: RemovalMode = .delete
    var selectedByDefault = true
    /// When set and installed, cleaning runs this instead of removing files; `paths` are then only used to
    /// measure size. When the tool is not installed, the scanned entries are removed instead.
    var command: ShellCommand? = nil
    /// Optional command-based measurement (see `SizeProbe`). It only runs when `paths` is empty or one of them exists.
    var probe: SizeProbe? = nil
    /// Where the tool says its cache is, scanned besides `paths` (a folder inside one of them, or the same, counts once).
    var locate: PathLookup? = nil
    /// Folders under a variable set in the shell profile (`ShellEnvironment`), scanned besides `paths` like `locate`:
    /// `["CARGO_HOME": ["registry", "git"]]`; `""` = the folder itself, `*` components allowed.
    var shellFolders: [String: [String]] = [:]
    /// Folders the tool's own settings file names (LM Studio's models folder moved in its app), scanned besides `paths`
    /// like `shellFolders`: `read` gets the home folder and returns the folders as written, each checked like a
    /// `shellFolders` folder (`ShellEnvironment.checkedFolder`), then `subpaths` below it are scanned.
    var configFolders: ConfigFolders? = nil
    /// The measured size is only a maximum: the command may remove less (`pnpm store prune` keeps packages
    /// projects still use). Shown as "Up to …" and kept out of the selected total.
    var sizeIsUpperBound = false
    /// false: the item is hidden when there is nothing to clean (tool not installed, cache empty).
    var showsWhenEmpty = true
    /// The item is skipped while one of these apps is running (a trailing `*` matches a bundle id prefix).
    var runningAppBundleIDs: [String] = []
    /// The item is skipped while a command-line tool with one of these names runs (see `RunningProcesses`).
    var runningProcessNames: [String] = []
    /// An entry that is, or holds, a file any process has open under the item's folders is kept.
    /// The open-file table (libproc, ~30 ms) is read once per scan, and at clean once per item, refreshed every 2 s.
    var skipsOpenFiles = false
    /// Per-entry skip, checked at scan and again right before removal (e.g. the container of a running app).
    /// Makes the check: called once per scan (one snapshot, e.g. of running apps) and anew for each entry removed.
    var skipsEntry: (@Sendable () -> @Sendable (URL) -> Bool)? = nil
    /// Names a top-level entry in the expanded path list (an iPhone backup's device and date); read once at scan.
    var entryLabel: EntryLabel? = nil
    typealias EntryLabel = @Sendable (URL) -> (title: String, date: Date?)?
    /// Each entry gets its own checkbox in the expanded row and can be left out of the clean. The choice is
    /// per session only (never remembered), and every entry is listed (no 200-entry cap), so none is cleaned unseen.
    var selectableEntries = false
    /// Removes one entry with a command instead of deleting a path (Docker's untagged images: `docker rmi <id>`);
    /// nil for an entry it does not recognise, which is then skipped. The item's own `command` is not run.
    var entryCommand: (@Sendable (URL) -> ShellCommand?)? = nil
    /// Files outside `paths` that belong to one entry alone and go with it (an Ollama model's blobs that no other
    /// model uses). Asked at scan, where they count in the entry's size, and again right before removal; each one
    /// is removed after its entry, through `SafetyPolicy.allows`, and only when it is a regular file.
    var entryFiles: (@Sendable (URL) -> [URL])? = nil
    /// Lists, instead of `paths`, the user's Trash on each external drive (`ExternalTrash`): one entry per drive, named
    /// after it, checked with `SafetyPolicy.allowsExternalTrash` instead of `allows`, and emptied (the folder stays).
    var externalTrash = false
    /// Finds the entries in the item's folders (`Scanner.roots`) instead of listing their top-level children
    /// (`StaleNodeModules`, `StaleBuildFolders`: folders of projects a few levels down). Each one found is then checked
    /// like a listed entry (`allowsEntry`, `skipsEntry`, locked, open files) and measured whole.
    var findEntries: (@Sendable ([URL], SafetyPolicy) async -> [URL])? = nil
    /// Replaces `SafetyPolicy.allows` for the item's entries, at scan and again right before removal
    /// (`SafetyPolicy.allowsNodeModules`, `allowsBuildFolder`, which also reach projects in Documents and Desktop).
    var allowsEntry: (@Sendable (SafetyPolicy, URL) -> Bool)? = nil
    /// Sizes of the item's folder entries kept between scans (`FolderSizeCache`): an entry whose top level did not
    /// change since it was measured is not walked again. Only for items without `minAge` (a cached size has no date).
    var entrySizes: FolderSizeCache? = nil
}

nonisolated struct CleanerGroup: Identifiable, Sendable {
    let id: String
    let title: LocalizedStringResource
    let systemImage: String
    let items: [CleanerItem]
}
