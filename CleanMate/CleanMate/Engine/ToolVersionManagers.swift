import Foundation

/// Runtime versions installed by asdf (`~/.asdf/installs/<plugin>/<version>`, or under `ASDF_DATA_DIR`) and mise
/// (`~/.local/share/mise/installs/<tool>/<version>`, or under `MISE_DATA_DIR` / `$XDG_DATA_HOME/mise`): 0.1–1 GB each
/// for Node, Python, Ruby or Java, never removed by the tool. One entry per tool and version, unticked, deleted whole;
/// `asdf install` / `mise install` downloads it again. Kept, never listed (asked at scan and again right before removal):
/// - the newest version of each tool, per flavor (`temurin-21.0.2`, `zulu-17.0.9`: Java distributions), and the newest
///   release when a prerelease is newer; a folder whose name holds no version (`ref-main`, `latest`) is kept;
/// - every version pinned in the global settings (`~/.tool-versions`, mise's `config.toml`) or by a project in
///   `StaleProjects.folders` (`.tool-versions`, `mise.toml`, `.mise.toml`, `.mise/config.toml`…). The files of both tools
///   count for both (mise reads `.tool-versions` too). A partial version (`20`), `latest` or `lts` keeps the newest
///   installed match, or the version mise's alias link of that name points to; a pin CleanMate can't read
///   (`{{ env.NODE }}`, `sub-1:latest`) keeps every version of that tool, and a profile line setting where the
///   settings are in a way CleanMate can't read keeps everything;
/// - a version the profile's `PATH` runs from.
/// Only real folders are listed: mise's alias links (`latest`, `lts`, `20`) never. Shims, plugins, downloads and the
/// settings files are never touched. Skipped while `asdf` / `mise` runs; a version a program runs from is listed locked.
nonisolated enum ToolVersionManagers {
    typealias Version = AndroidSDKComponents.Version

    static let asdfID = "asdf-old-versions"
    static let miseID = "mise-old-versions"
    static let asdfPath = "~/.asdf/installs"
    static let misePath = "~/.local/share/mise/installs"
    static let asdfShellFolders = ["ASDF_DATA_DIR": ["installs"]]
    static let miseShellFolders = ["MISE_DATA_DIR": ["installs"], "XDG_DATA_HOME": ["mise/installs"]]
    /// Largest settings file read: real ones are a few KB.
    static let fileLimit = 256 * 1024

    // MARK: - Versions

    /// The flavor (`temurin-`, `pypy3.10-`, lower-cased; empty for most tools) and version of a version folder or pin
    /// (`20.11.1`, `v20`, `3.13.0rc1`, `temurin-21.0.2+13.0.LTS`); nil when it holds no version (`ref-main`, `lts`) or
    /// another sign (`sub-1:latest`, `{{ env.NODE }}`).
    static func parse(_ name: String) -> (flavor: String, version: Version)? {
        guard name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".+-_".contains($0)) }),
              let match = name.prefixMatch(of: /((?:[A-Za-z][A-Za-z0-9.]*-)*)[vV]?(?=\d)/),
              let version = Version(String(name[match.range.upperBound...])) else { return nil }
        return (String(match.1).lowercased(), version)
    }

    /// The names of `names` kept whatever the pins: the newest of each flavor and the newest release of each, and every
    /// name without a version.
    static func newest(_ names: [String]) -> Set<String> {
        var kept = Set<String>()
        var flavors: [String: [(name: String, version: Version)]] = [:]
        for name in names {
            if let parsed = parse(name) { flavors[parsed.flavor, default: []].append((name, parsed.version)) } else { kept.insert(name) }
        }
        for versions in flavors.values {
            if let top = versions.max(by: { $0.version < $1.version }) { kept.insert(top.name) }
            if let release = versions.filter({ $0.version.suffix.isEmpty }).max(by: { $0.version < $1.version }) {
                kept.insert(release.name)
            }
        }
        return kept
    }

    /// What `spec` (one pin of the tool in `folder`) keeps among `names`; nil when it can't be told.
    static func kept(by spec: String, folder: URL, names: [String]) -> Set<String>? {
        var spec = spec.trimmingCharacters(in: .whitespaces)
        for prefix in ["prefix:", "latest:"] where spec.hasPrefix(prefix) { spec.removeFirst(prefix.count) }
        if spec.isEmpty || spec == "system" || spec.hasPrefix("path:") || spec.hasPrefix("ref:") { return [] }
        if names.contains(spec) { return [spec] }
        // mise's alias link of that name in the tool folder (`lts` → `22.11.0`, `20` → `20.18.0`).
        if !spec.contains("/"), spec != ".", spec != "..", let target = linkTarget(folder.appending(path: spec)),
           names.contains(target) {
            return [target]
        }
        if spec == "latest" || spec == "stable" { return [] } // the newest, kept anyway
        if spec.hasPrefix("lts") {
            // Node's LTS lines are its even majors. The newest one may still be "Current" for its first six months, so
            // the newest of the two newest even majors installed are kept. Another tool's `lts` is taken as its newest.
            guard toolKey(folder.lastPathComponent) == "node" else { return [] }
            var newestOfMajor: [Int: (name: String, version: Version)] = [:]
            for name in names {
                guard let parsed = parse(name), parsed.flavor.isEmpty, let major = parsed.version.numbers.first,
                      major % 2 == 0 else { continue }
                if newestOfMajor[major].map({ $0.version < parsed.version }) ?? true { newestOfMajor[major] = (name, parsed.version) }
            }
            return Set(newestOfMajor.keys.sorted().suffix(2).compactMap { newestOfMajor[$0]?.name })
        }
        guard let pin = parse(spec) else { return nil }
        let matches = names.compactMap { name -> (name: String, version: Version)? in
            guard let parsed = parse(name), parsed.flavor == pin.flavor, parsed.version.isPinned(by: pin.version) else { return nil }
            return (name, parsed.version)
        }
        return matches.max(by: { $0.version < $1.version }).map { [$0.name] } ?? []
    }

    /// The folder name a link `url` in its own folder points to, nil when it is not such a link.
    private static func linkTarget(_ url: URL) -> String? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK,
              let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { return nil }
        let resolved = (target.hasPrefix("/") ? URL(fileURLWithPath: target) : url.deletingLastPathComponent().appending(path: target))
            .standardizedFileURL
        guard resolved.deletingLastPathComponent().path == url.deletingLastPathComponent().standardizedFileURL.path else { return nil }
        return resolved.lastPathComponent
    }

    /// The version folders of `names` in the tool folder `folder` kept: `newest`, then (only when something else is
    /// left) what the pins for that tool keep. Everything when the pins (nil) or one of them can't be read.
    static func keptNames(in folder: URL, names: [String], pins: () -> Pins?) -> Set<String> {
        var keeps = newest(names)
        guard keeps.count < names.count else { return keeps }
        guard let pins = pins() else { return Set(names) }
        for spec in pins.specs[toolKey(folder.lastPathComponent)] ?? [] {
            guard let found = kept(by: spec, folder: folder, names: names) else { return Set(names) }
            keeps.formUnion(found)
        }
        return keeps
    }

    // MARK: - Pins

    /// Version specs per tool (`toolKey`) from every settings file read.
    struct Pins: Equatable, Sendable {
        var specs: [String: Set<String>] = [:]

        mutating func add(_ found: [(tool: String, specs: [String])]) {
            for (tool, specs) in found where !specs.isEmpty { specs.forEach { self.specs[toolKey(tool), default: []].insert($0) } }
        }
    }

    /// asdf plugin names mise maps to its own tool names.
    static let aliases = ["nodejs": "node", "golang": "go"]

    /// A tool as both a pin and an install folder name it: `npm:@antfu/ni` and `npm-antfu-ni` are one tool, so are
    /// asdf's `nodejs` and mise's `node`.
    static func toolKey(_ name: String) -> String {
        var key = name.lowercased()
        if key.hasPrefix("core:") { key.removeFirst(5) }
        key = String(key.filter { $0.isLetter || $0.isNumber })
        return aliases[key] ?? key
    }

    /// `.tool-versions` lines: `<tool> <version>…`, `#` comments.
    static func toolVersionsPins(_ text: String) -> [(tool: String, specs: [String])] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let words = (line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
                .split(whereSeparator: \.isWhitespace).map(String.init)
            return words.count > 1 ? (words[0], Array(words.dropFirst())) : nil
        }
    }

    /// The `[tools]` of a mise TOML file: `node = "20"`, `python = ["3.11", "3.12"]` (also over several lines),
    /// `java = { version = "21" }`, `"npm:prettier" = "latest"` and `[tools.node]` tables with `version = "20"`.
    static func misePins(_ text: String) -> [(tool: String, specs: [String])] {
        var found: [(tool: String, specs: [String])] = []
        var section = "", open: (tool: String, value: String)?
        func specs(_ value: String) -> [String] {
            let value = value.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("{") {
                return value.firstMatch(of: /\bversion\s*=\s*(?:"([^"]*)"|'([^']*)')/).map { [String($0.1 ?? $0.2 ?? "")] } ?? []
            }
            let quoted = value.matches(of: /"([^"]*)"|'([^']*)'/).map { String($0.1 ?? $0.2 ?? "") }
            if !quoted.isEmpty || value.hasPrefix("[") { return quoted }
            return value.split(whereSeparator: { $0.isWhitespace || $0 == "#" }).first.map { [String($0)] } ?? []
        }
        func unquoted(_ key: Substring) -> String {
            key.count > 1 && (key.hasPrefix("\"") || key.hasPrefix("'")) ? String(key.dropFirst().dropLast()) : String(key)
        }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let pending = open {
                open = line.contains("]") ? nil : (pending.tool, pending.value + " " + line)
                if open == nil { found.append((pending.tool, specs(pending.value + " " + line))) }
                continue
            }
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                section = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] \t"))
                continue
            }
            guard let match = line.wholeMatch(of: /("[^"]*"|'[^']*'|[A-Za-z0-9_.:@\/-]+)\s*=\s*(.*)/) else { continue }
            let key = unquoted(match.1), value = String(match.2)
            if section == "tools" {
                if value.trimmingCharacters(in: .whitespaces).hasPrefix("["), !value.contains("]") {
                    open = (key, value)
                } else {
                    found.append((key, specs(value)))
                }
            } else if section.hasPrefix("tools."), key == "version" {
                found.append((unquoted(section.dropFirst(6)), specs(value)))
            }
        }
        return found
    }

    /// Adds the pins of the settings file `file` (`.tool-versions` or a mise TOML file) when it is a small regular file.
    static func read(_ file: URL, into pins: inout Pins) {
        var info = stat()
        guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= fileLimit,
              let data = FileManager.default.contents(atPath: file.path) else { return }
        let text = String(decoding: data, as: UTF8.self)
        pins.add(file.lastPathComponent.hasSuffix("tool-versions") ? toolVersionsPins(text) : misePins(text))
    }

    /// Settings files of a project folder, relative to it.
    static let projectFiles = [".tool-versions", "mise.toml", ".mise.toml", "mise.local.toml", ".mise.local.toml",
                               ".mise/config.toml", ".mise/config.local.toml", "mise/config.toml",
                               ".config/mise.toml", ".config/mise/config.toml"]

    /// Profile variables that move the global settings: one assigned in a way the profile reader can't follow keeps
    /// everything. The `*_FILENAME` ones rename the files CleanMate looks for, so they are never followed.
    static let configVariables = ["MISE_CONFIG_DIR", "MISE_GLOBAL_CONFIG_FILE", "XDG_CONFIG_HOME"]
    static let renamingVariables = ["ASDF_DEFAULT_TOOL_VERSIONS_FILENAME", "MISE_DEFAULT_TOOL_VERSIONS_FILENAME",
                                    "MISE_DEFAULT_CONFIG_FILENAME", "MISE_OVERRIDE_CONFIG_FILENAMES",
                                    "MISE_OVERRIDE_TOOL_VERSIONS_FILENAMES"]

    /// The global settings files: `~/.tool-versions`, `~/.mise.toml` and the other files mise reads in the home folder,
    /// `config.toml` (+ `config.local.toml`, `conf.d/*.toml`) in mise's settings folder, `MISE_GLOBAL_CONFIG_FILE`.
    /// nil when the profile sets where they are in a way CleanMate can't read.
    static func globalFiles(home: URL) -> [URL]? {
        let env = ShellEnvironment.cached(home: home), assigned = ShellEnvironment.assigned(home: home)
        guard !renamingVariables.contains(where: assigned.contains),
              !configVariables.contains(where: { assigned.contains($0) && env[$0] == nil }) else { return nil }
        var files = projectFiles.map { home.appending(path: $0) }
        var folders = [home.appending(path: ".config/mise")]
        if let base = env["XDG_CONFIG_HOME"] { folders.append(URL(fileURLWithPath: base).appending(path: "mise")) }
        if let folder = env["MISE_CONFIG_DIR"] { folders.append(URL(fileURLWithPath: folder)) }
        for folder in folders {
            files += [folder.appending(path: "config.toml"), folder.appending(path: "config.local.toml")]
            let confD = folder.appending(path: "conf.d")
            files += ((try? FileManager.default.contentsOfDirectory(atPath: confD.path)) ?? []).sorted()
                .filter { $0.hasSuffix(".toml") }.map { confD.appending(path: $0) }
        }
        if let file = env["MISE_GLOBAL_CONFIG_FILE"] { files.append(URL(fileURLWithPath: file)) }
        return files
    }

    /// Every pin of the global settings and of the projects in `StaleProjects.folders` below `home` (without what
    /// macOS guards when there is no Full Disk Access); nil when the global settings can't be found.
    static func pins(home: URL, hasFullDiskAccess: Bool) -> Pins? {
        guard let files = globalFiles(home: home) else { return nil }
        var pins = Pins()
        for file in files { read(file, into: &pins) }
        let skipped = ProtectedFolders.skipped(home: home, hasFullDiskAccess: hasFullDiskAccess)
        let roots = StaleProjects.folders.map { home.appending(path: String($0.dropFirst(2))) }
            .filter { !ProtectedFolders.contains(skipped, $0) }
        StaleProjects.visit(roots, skipping: skipped) { folder, children in
            for name in projectFiles {
                let first = String(name.split(separator: "/").first ?? "")
                guard children[first] == UInt8(name.contains("/") ? DT_DIR : DT_REG) else { continue }
                read(URL(fileURLWithPath: folder + "/" + name), into: &pins)
            }
        }
        return pins
    }

    /// Pins read for a scan, handed to the checks of the next `StaleProjects.reuseTime`: one walk for both items'
    /// entries, a fresh one for a later clean.
    final class PinCache: Sendable {
        static let shared = PinCache()
        private let cached = Locked<(key: String, started: ContinuousClock.Instant, pins: Pins?)?>(nil)

        func pins(home: URL, hasFullDiskAccess: Bool) -> Pins? {
            let key = home.standardizedFileURL.path + "\n\(hasFullDiskAccess)"
            if let hit = cached.withLock({ $0 }), hit.key == key, hit.started.duration(to: .now) < StaleProjects.reuseTime {
                return hit.pins
            }
            let started = ContinuousClock.now
            let pins = ToolVersionManagers.pins(home: home, hasFullDiskAccess: hasFullDiskAccess)
            cached.withLock { $0 = (key, started, pins) }
            return pins
        }
    }

    // MARK: - Entries

    /// The install folders scanned for a tool: `path` and the checked `shellFolders`.
    static func installRoots(path: String, shellFolders: [String: [String]], policy: SafetyPolicy) -> Set<String> {
        var found: Set = [policy.expand(path).standardizedFileURL.path]
        for (name, subpaths) in shellFolders {
            guard let folder = ShellEnvironment.folder(name, policy: policy) else { continue }
            for subpath in subpaths { found.insert(folder.appending(path: subpath).standardizedFileURL.path) }
        }
        return found
    }

    /// Real, not hidden folders in `folder` (`policy` allows them, when given), by name.
    private static func folders(in folder: URL, policy: SafetyPolicy? = nil) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted().filter { name in
            guard !name.hasPrefix(".") else { return false }
            guard let policy else {
                var info = stat()
                return lstat(folder.appending(path: name).path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
            }
            return OldRuntimes.isVersionFolder(folder.appending(path: name), policy: policy)
        }
    }

    /// The versions in the install folders of `roots` that are neither kept by `keptNames` nor run by the profile's PATH.
    static func find(in roots: [URL], installs: Set<String>, policy: SafetyPolicy, pins: () -> Pins?) -> [URL] {
        var seen = Set<String>(), found: [URL] = []
        var read: Pins??
        func cachedPins() -> Pins? {
            if let read { return read }
            let value = pins()
            read = .some(value)
            return value
        }
        for root in roots.map(\.standardizedFileURL) where installs.contains(root.path) && seen.insert(root.path).inserted {
            for tool in folders(in: root) {
                let folder = root.appending(path: tool)
                let names = folders(in: folder, policy: policy)
                let kept = keptNames(in: folder, names: names, pins: cachedPins)
                let onPath = OldRuntimes.pathVersions(home: policy.homeURL, versionsFolder: folder)
                found += names.filter { !kept.contains($0) }.map { folder.appending(path: $0) }
                    .filter { !onPath.contains($0.standardizedFileURL.path) }
            }
        }
        return found
    }

    /// `url` is `<install folder>/<tool>/<version>`, a real folder neither kept nor run by the profile's PATH.
    static func allows(_ url: URL, installs: Set<String>, policy: SafetyPolicy, pins: () -> Pins?) -> Bool {
        let url = url.standardizedFileURL, folder = url.deletingLastPathComponent()
        let root = folder.deletingLastPathComponent()
        guard installs.contains(root.path), folders(in: root).contains(folder.lastPathComponent),
              OldRuntimes.isVersionFolder(url, policy: policy) else { return false }
        let names = folders(in: folder, policy: policy)
        guard names.contains(url.lastPathComponent),
              !keptNames(in: folder, names: names, pins: pins).contains(url.lastPathComponent) else { return false }
        return !OldRuntimes.pathVersions(home: policy.homeURL, versionsFolder: folder).contains(url.path)
    }

    /// `node 20.11.1`, `python 3.12.0`, `java temurin-21.0.2+13.0.LTS`; dated when it was installed.
    static func label(of url: URL) -> (title: String, date: Date?)? {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return (url.deletingLastPathComponent().lastPathComponent + " " + url.lastPathComponent, date)
    }

    // MARK: - Items

    /// `hasFullDiskAccess`, `running`, `pins` and `sizes` are injected by tests.
    static func asdfItem(hasFullDiskAccess: @escaping @Sendable () -> Bool = { FullDiskAccess.isGranted },
                         running: @escaping @Sendable () -> [String] = RunningProcesses.usedPaths,
                         pins: PinCache = .shared, sizes: FolderSizeCache = .shared) -> CleanerItem {
        item(id: asdfID, title: "Old runtime versions (asdf)",
             note: "Versions other than the newest of each tool and those pinned in ~/.tool-versions or by a project in your project folders, installed again with asdf install",
             path: asdfPath, shellFolders: asdfShellFolders, process: "asdf",
             hasFullDiskAccess: hasFullDiskAccess, running: running, pins: pins, sizes: sizes)
    }

    static func miseItem(hasFullDiskAccess: @escaping @Sendable () -> Bool = { FullDiskAccess.isGranted },
                         running: @escaping @Sendable () -> [String] = RunningProcesses.usedPaths,
                         pins: PinCache = .shared, sizes: FolderSizeCache = .shared) -> CleanerItem {
        item(id: miseID, title: "Old runtime versions (mise)",
             note: "Versions other than the newest of each tool and those pinned in mise's settings or by a project in your project folders, installed again with mise install",
             path: misePath, shellFolders: miseShellFolders, process: "mise",
             hasFullDiskAccess: hasFullDiskAccess, running: running, pins: pins, sizes: sizes)
    }

    private static func item(id: String, title: LocalizedStringResource, note: LocalizedStringResource, path: String,
                             shellFolders: [String: [String]], process: String,
                             hasFullDiskAccess: @escaping @Sendable () -> Bool, running: @escaping @Sendable () -> [String],
                             pins: PinCache, sizes: FolderSizeCache) -> CleanerItem {
        @Sendable func read(_ policy: SafetyPolicy) -> Pins? { pins.pins(home: policy.homeURL, hasFullDiskAccess: hasFullDiskAccess()) }
        var item = CleanerItem(id: id, title: title, note: note, paths: [path], selectedByDefault: false,
                               shellFolders: shellFolders, showsWhenEmpty: false, runningProcessNames: [process],
                               skipsOpenFiles: true, entryLabel: label(of:), selectableEntries: true,
                               findEntries: { roots, policy in
                                   find(in: roots, installs: installRoots(path: path, shellFolders: shellFolders, policy: policy),
                                        policy: policy) { read(policy) }
                               },
                               allowsEntry: { policy, url in
                                   allows(url, installs: installRoots(path: path, shellFolders: shellFolders, policy: policy),
                                          policy: policy) { read(policy) }
                               },
                               entrySizes: sizes)
        item.locksEntry = OldRuntimes.locks(reason: String(localized: "A program runs from this version, so it is kept"),
                                            running: running)
        return item
    }
}
