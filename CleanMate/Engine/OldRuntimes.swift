import Foundation

/// Runtime versions installed by version managers, other than the one in use: Node.js (nvm, 100–200 MB each), Flutter
/// (fvm, 1–2 GB), Python (pyenv), Ruby (rbenv), Rust toolchains (rustup) and Go SDKs (golang.org/dl, `~/sdk`),
/// 0.3–2 GB each; the tool downloads them again. One entry per version, unticked, deleted whole. When the version in
/// use can't be told, nothing of that tool is listed. A version a program runs from (its `node`, the Dart VM of a
/// Flutter SDK, a global CLI installed in it) is listed locked. The tools' own files (`alias/`, `default`, `version`,
/// `settings.toml`, shims) and project files are never touched: only folders inside `versions`, `toolchains`, `~/sdk`.
nonisolated enum OldRuntimes {
    static let nodeID = "nvm-old-node"
    static let flutterID = "fvm-old-flutter"
    static let pythonID = "pyenv-old-python"
    static let rubyID = "rbenv-old-ruby"
    static let rustID = "rustup-old-toolchains"
    static let goID = "go-old-sdks"

    /// `v20.11.1`: the folders nvm installs in `versions/node`.
    static func isNodeVersion(_ name: String) -> Bool { name.wholeMatch(of: /v\d+\.\d+\.\d+/) != nil }

    /// A real folder (not a symlink, not hidden) allowed by `policy`.
    static func isVersionFolder(_ url: URL, policy: SafetyPolicy) -> Bool {
        var info = stat()
        return !url.lastPathComponent.hasPrefix(".") && lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
            && policy.allows(url)
    }

    /// Versions the profile's `PATH` runs from (`~/.nvm/versions/node/v18.20.4/bin`): paths of their folders.
    static func pathVersions(home: URL, versionsFolder: URL) -> Set<String> {
        let base = versionsFolder.standardizedFileURL.path + "/"
        return Set(ShellEnvironment.pathFolders(home: home).compactMap { path in
            guard path.hasPrefix(base), let name = path.dropFirst(base.count).split(separator: "/").first else { return nil }
            return base + name
        })
    }

    // MARK: nvm

    /// The version `nvm alias default` resolves to among `installed`, as nvm does: an alias file may name another alias
    /// (`lts/iron`, `lts/*` in `alias/lts/`), `node`/`stable` (newest installed), a full or partial version (`20`,
    /// `v20.11`: newest installed match) or `system` (none). `.some(nil)`: no nvm version is the default (`system`).
    /// nil when it can't be told: no default alias, a name that resolves to nothing installed, a loop.
    static func nodeDefault(nvmDir: URL, installed: [String]) -> String?? {
        let alias = nvmDir.appending(path: "alias")
        guard var name = firstLine(of: alias.appending(path: "default")) else { return nil }
        for _ in 0..<10 {
            if name == "system" { return .some(nil) }
            if name == "node" || name == "stable" { return newest(installed).map { .some($0) } }
            let parts = name.split(separator: "/", omittingEmptySubsequences: false)
            if !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
               let next = firstLine(of: alias.appending(path: name)) {
                name = next
                continue
            }
            let version = name.hasPrefix("v") ? name : "v" + name
            if installed.contains(version) { return .some(version) }
            return newest(installed.filter { $0.hasPrefix(version + ".") }).map { .some($0) }
        }
        return nil
    }

    /// The highest of `versions` (`v20.9.0` < `v20.11.1`).
    static func newest(_ versions: [String]) -> String? {
        func numbers(_ version: String) -> [Int] { version.dropFirst().split(separator: ".").map { Int($0) ?? 0 } }
        return versions.max { numbers($0).lexicographicallyPrecedes(numbers($1)) }
    }

    /// `url` is `<nvm>/versions/node/vX.Y.Z`, not the default version nor one the profile's PATH runs.
    static func allowsNode(_ url: URL, policy: SafetyPolicy) -> Bool {
        let folder = url.deletingLastPathComponent()
        guard isNodeVersion(url.lastPathComponent), isVersionFolder(url, policy: policy),
              folder.lastPathComponent == "node", folder.deletingLastPathComponent().lastPathComponent == "versions"
        else { return false }
        let nvmDir = folder.deletingLastPathComponent().deletingLastPathComponent()
        let installed = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter(isNodeVersion) ?? []
        guard let kept = nodeDefault(nvmDir: nvmDir, installed: installed) else { return false }
        return url.lastPathComponent != kept
            && !pathVersions(home: policy.homeURL, versionsFolder: folder).contains(url.standardizedFileURL.path)
    }

    // MARK: fvm

    /// The version `<cache>/default` (fvm's global version, a symlink) points to. `.some(nil)` when there is none; nil
    /// when it can't be told (`default` is not a symlink or points somewhere else than `versions/`).
    static func flutterDefault(cache: URL) -> String?? {
        let link = cache.appending(path: "default")
        var info = stat()
        guard lstat(link.path, &info) == 0 else { return errno == ENOENT ? .some(nil) : nil }
        guard info.st_mode & S_IFMT == S_IFLNK,
              let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else { return nil }
        let resolved = (target.hasPrefix("/") ? URL(fileURLWithPath: target) : cache.appending(path: target)).standardizedFileURL
        let versions = cache.appending(path: "versions").standardizedFileURL
        guard resolved.deletingLastPathComponent().path == versions.path else { return nil }
        return .some(resolved.lastPathComponent)
    }

    /// `url` is `<fvm cache>/versions/<version>`, not the global version nor one the profile's PATH runs.
    static func allowsFlutter(_ url: URL, policy: SafetyPolicy) -> Bool {
        let folder = url.deletingLastPathComponent()
        guard isVersionFolder(url, policy: policy), folder.lastPathComponent == "versions",
              let kept = flutterDefault(cache: folder.deletingLastPathComponent()) else { return false }
        return url.lastPathComponent != kept
            && !pathVersions(home: policy.homeURL, versionsFolder: folder).contains(url.standardizedFileURL.path)
    }

    // MARK: pyenv and rbenv

    /// The installed versions (folder names in `versions`) a version file names, as pyenv and rbenv read it: the first
    /// word of each line (`firstOnly`: of the first line, rbenv), `#` comments skipped, a `python-`/`ruby-` prefix
    /// dropped when no such folder exists, a partial version (`3.11`) keeping every installed match, `system` none. A
    /// name that is a link in `versions` (a pyenv-virtualenv env) keeps the version it lives in too. nil when it can't be
    /// told: no readable file, no version in it, or a name nothing installed matches.
    static func namedVersions(file: URL, versions: URL, prefix: String, firstOnly: Bool) -> Set<String>? {
        guard let text = smallText(file) else { return nil }
        let installed = (try? FileManager.default.contentsOfDirectory(atPath: versions.path))?.filter { !$0.hasPrefix(".") } ?? []
        var words = text.split(whereSeparator: \.isNewline).compactMap { line in
            line.split(whereSeparator: \.isWhitespace).first.map(String.init)
        }.filter { !$0.hasPrefix("#") }
        if firstOnly { words = Array(words.prefix(1)) }
        guard !words.isEmpty else { return nil }
        var kept = Set<String>()
        for word in words where word != "system" {
            guard word != ".", word != "..", !word.contains("/") else { return nil }
            let name = installed.contains(word) || !word.hasPrefix(prefix) ? word : String(word.dropFirst(prefix.count))
            let matches = installed.contains(name) ? [name] : installed.filter { $0.hasPrefix(name + ".") }
            guard !matches.isEmpty else { return nil }
            for match in matches {
                kept.insert(match)
                let target = versions.appending(path: match).resolvingSymlinksInPath().path
                let base = versions.resolvingSymlinksInPath().path + "/"
                if target.hasPrefix(base), let first = target.dropFirst(base.count).split(separator: "/").first {
                    kept.insert(String(first))
                }
            }
        }
        return kept
    }

    /// `url` is `<root>/versions/<name>`, not one the root's `version` file names nor one the profile's PATH runs, and
    /// (pyenv) holds no virtualenv in `envs/`: those are the user's environments, not downloaded again.
    static func allowsVersion(_ url: URL, policy: SafetyPolicy, prefix: String, firstOnly: Bool) -> Bool {
        let folder = url.deletingLastPathComponent()
        guard isVersionFolder(url, policy: policy), folder.lastPathComponent == "versions",
              let kept = namedVersions(file: folder.deletingLastPathComponent().appending(path: "version"), versions: folder,
                                       prefix: prefix, firstOnly: firstOnly)
        else { return false }
        let envs = (try? FileManager.default.contentsOfDirectory(atPath: url.appending(path: "envs").path)) ?? []
        return !kept.contains(url.lastPathComponent) && !envs.contains { !$0.hasPrefix(".") }
            && !pathVersions(home: policy.homeURL, versionsFolder: folder).contains(url.standardizedFileURL.path)
    }

    // MARK: rustup

    /// Toolchain names rustup's `settings.toml` keeps: `default_toolchain` and every value of `[overrides]` (a folder's
    /// pinned toolchain), each also with `-<default_host_triple>` (`stable` is installed as `stable-aarch64-apple-darwin`).
    /// Without a host triple a short name also ends with `-*`, matching any host (see `rustKeeps`). nil when it can't
    /// be told: no readable file or no default toolchain (`rustup default none`).
    static func rustKept(settings: URL) -> Set<String>? {
        guard let text = smallText(settings) else { return nil }
        var section = "", names: [String] = [], defaultName: String?, host: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { section = line; continue }
            guard let match = line.wholeMatch(of: /("[^"]*"|'[^']*'|[A-Za-z0-9_-]+)\s*=\s*("([^"]*)"|'([^']*)')\s*(#.*)?/) else { continue }
            let value = String(match.3 ?? match.4 ?? "")
            guard !value.isEmpty else { continue }
            if section == "[overrides]" { names.append(value) }
            if section.isEmpty, match.1 == "default_toolchain" { defaultName = value }
            if section.isEmpty, match.1 == "default_host_triple" { host = value }
        }
        guard let defaultName else { return nil }
        return Set((names + [defaultName]).flatMap { name in [name, name + "-" + (host ?? "*")] })
    }

    /// `kept` (from `rustKept`) holds the toolchain folder `name`.
    static func rustKeeps(_ kept: Set<String>, _ name: String) -> Bool {
        kept.contains(name) || kept.contains { $0.hasSuffix("-*") && name.hasPrefix($0.dropLast()) }
    }

    /// `url` is `<rustup>/toolchains/<name>`, not the default toolchain nor an override.
    static func allowsRust(_ url: URL, policy: SafetyPolicy) -> Bool {
        let folder = url.deletingLastPathComponent()
        guard isVersionFolder(url, policy: policy), folder.lastPathComponent == "toolchains",
              let kept = rustKept(settings: folder.deletingLastPathComponent().appending(path: "settings.toml")) else { return false }
        return !rustKeeps(kept, url.lastPathComponent)
            && !pathVersions(home: policy.homeURL, versionsFolder: folder).contains(url.standardizedFileURL.path)
    }

    // MARK: Go

    /// `go1.21.0`, `go1.22rc1`, `gotip`: the folders `golang.org/dl` wrappers download to in `~/sdk`.
    static func isGoVersion(_ name: some StringProtocol) -> Bool {
        String(name).wholeMatch(of: /go(\d+(\.\d+)*((rc|beta)\d+)?|tip)/) != nil
    }

    /// Bin folders a `go` command may be linked from besides the profile's `PATH` (`~` = home).
    static let goBinFolders = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/local/go/bin", "~/go/bin", "~/bin", "~/.local/bin"]

    /// Go's own settings (`go env -w GOROOT=…`), relative to home.
    static let goEnvFile = "Library/Application Support/go/env"

    /// The Go SDKs in `<home>/sdk` in use: every one a line of the shell profile or Go's settings names
    /// (`PATH=$HOME/sdk/go1.21.0/bin`, `GOROOT`, `alias go=go1.21.0`) and the one a `go` in a bin folder links into
    /// (`binFolders`: the profile's `PATH` is added). nil when it can't be told: a profile line picks the SDK folder
    /// with a variable (`$HOME/sdk/$GOVERSION`), or no `go` command is found and no line names an SDK. Comment lines
    /// don't count.
    static func goKept(home: URL, binFolders: [String] = goBinFolders) -> Set<String>? {
        var kept = Set<String>()
        for name in ShellEnvironment.zshFiles + ShellEnvironment.bashFiles + [goEnvFile] {
            guard let text = try? String(contentsOf: home.appending(path: name), encoding: .utf8) else { continue }
            for line in text.split(whereSeparator: \.isNewline) where !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                if line.contains("sdk/$") || line.contains("sdk/go$") || line.contains("sdk/go`") { return nil }
                kept.formUnion(line.split { !($0.isLetter || $0.isNumber || "._-".contains($0)) }.filter(isGoVersion).map(String.init))
            }
        }
        let sdk = home.appending(path: "sdk").resolvingSymlinksInPath().path + "/"
        let folders = ShellEnvironment.pathFolders(home: home)
            + binFolders.map { $0.hasPrefix("~/") ? home.path + $0.dropFirst() : $0 }
        var found = false
        for folder in folders {
            let command = URL(fileURLWithPath: folder).appending(path: "go")
            guard FileManager.default.isExecutableFile(atPath: command.path) else { continue }
            found = true
            let target = command.resolvingSymlinksInPath().path
            if target.hasPrefix(sdk), let first = target.dropFirst(sdk.count).split(separator: "/").first { kept.insert(String(first)) }
        }
        return found || !kept.isEmpty ? kept : nil
    }

    /// `url` is `<home>/sdk/go<version>`, not one in use (`goKept`).
    static func allowsGo(_ url: URL, policy: SafetyPolicy) -> Bool {
        guard isGoVersion(url.lastPathComponent), isVersionFolder(url, policy: policy),
              url.deletingLastPathComponent().standardizedFileURL.path == policy.homeURL.appending(path: "sdk").standardizedFileURL.path,
              let kept = goKept(home: policy.homeURL) else { return false }
        return !kept.contains(url.lastPathComponent)
    }

    // MARK: Items

    /// Locks an entry a program runs from or works in (`RunningProcesses.usedPaths`, read once per check). The kernel
    /// reports resolved paths, so a version reached through a symlink (`~/.nvm` linked elsewhere) is matched resolved too.
    static func locks(reason: String, running: @escaping @Sendable () -> [String]) -> @Sendable () -> @Sendable (URL) -> String? {
        {
            let paths = running()
            return { url in
                let own = Set([url.standardizedFileURL.path, url.resolvingSymlinksInPath().path])
                return paths.contains { path in own.contains { path == $0 || path.hasPrefix($0 + "/") } } ? reason : nil
            }
        }
    }

    /// `<prefix> <folder name>`, minus `dropping` at its start (`go1.21.0` → `Go 1.21.0`), dated by the folder.
    static func label(_ prefix: String, dropping: String = "") -> CleanerItem.EntryLabel {
        { url in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let name = url.lastPathComponent
            return (prefix + " " + (name.hasPrefix(dropping) ? String(name.dropFirst(dropping.count)) : name), date)
        }
    }

    /// `running` is injected by tests.
    static func nodeItem(running: @escaping @Sendable () -> [String] = RunningProcesses.usedPaths) -> CleanerItem {
        var item = CleanerItem(id: nodeID, title: "Old Node.js versions (nvm)",
                               note: "Node.js versions other than nvm's default, installed again with nvm install",
                               paths: ["~/.nvm/versions/node"], selectedByDefault: false,
                               shellFolders: ["NVM_DIR": ["versions/node"]], showsWhenEmpty: false, skipsOpenFiles: true,
                               entryLabel: label("Node"), selectableEntries: true,
                               allowsEntry: { policy, url in allowsNode(url, policy: policy) })
        item.locksEntry = locks(reason: String(localized: "A program runs from this version, so it is kept"),
                                running: running)
        return item
    }

    static func flutterItem(running: @escaping @Sendable () -> [String] = RunningProcesses.usedPaths) -> CleanerItem {
        var item = CleanerItem(id: flutterID, title: "Old Flutter SDKs (fvm)",
                               note: "Flutter versions other than fvm's global one, installed again with fvm install",
                               paths: ["~/fvm/versions"], selectedByDefault: false,
                               shellFolders: ["FVM_CACHE_PATH": ["versions"]], showsWhenEmpty: false, skipsOpenFiles: true,
                               entryLabel: label("Flutter"), selectableEntries: true,
                               allowsEntry: { policy, url in allowsFlutter(url, policy: policy) })
        item.locksEntry = locks(reason: String(localized: "A program runs from this version, so it is kept"),
                                running: running)
        return item
    }

    static func pythonItem(running: @escaping @Sendable () -> [String] = RunningProcesses.usedPaths) -> CleanerItem {
        versionItem(id: pythonID, title: "Old Python versions (pyenv)",
                    note: "Python versions other than pyenv's global ones, installed again with pyenv install",
                    paths: ["~/.pyenv/versions"], shell: ["PYENV_ROOT": ["versions"]], label: label("Python"),
                    allows: { policy, url in allowsVersion(url, policy: policy, prefix: "python-", firstOnly: false) },
                    running: running)
    }

    static func rubyItem(running: @escaping @Sendable () -> [String] = RunningProcesses.usedPaths) -> CleanerItem {
        versionItem(id: rubyID, title: "Old Ruby versions (rbenv)",
                    note: "Ruby versions other than rbenv's global one, installed again with rbenv install",
                    paths: ["~/.rbenv/versions"], shell: ["RBENV_ROOT": ["versions"]], label: label("Ruby"),
                    allows: { policy, url in allowsVersion(url, policy: policy, prefix: "ruby-", firstOnly: true) },
                    running: running)
    }

    static func rustItem(running: @escaping @Sendable () -> [String] = RunningProcesses.usedPaths) -> CleanerItem {
        versionItem(id: rustID, title: "Old Rust toolchains (rustup)",
                    note: "Toolchains other than rustup's default and overrides, installed again with rustup toolchain install",
                    paths: ["~/.rustup/toolchains"], shell: ["RUSTUP_HOME": ["toolchains"]], label: label("Rust"),
                    allows: { policy, url in allowsRust(url, policy: policy) }, running: running)
    }

    static func goItem(running: @escaping @Sendable () -> [String] = RunningProcesses.usedPaths) -> CleanerItem {
        versionItem(id: goID, title: "Old Go SDKs (golang.org/dl)",
                    note: "Go versions in ~/sdk other than the go you use, downloaded again with go<version> download",
                    paths: ["~/sdk"], shell: [:], label: label("Go", dropping: "go"),
                    allows: { policy, url in allowsGo(url, policy: policy) }, running: running)
    }

    private static func versionItem(id: String, title: LocalizedStringResource, note: LocalizedStringResource,
                                    paths: [String], shell: [String: [String]], label: @escaping CleanerItem.EntryLabel,
                                    allows: @escaping @Sendable (SafetyPolicy, URL) -> Bool,
                                    running: @escaping @Sendable () -> [String]) -> CleanerItem {
        var item = CleanerItem(id: id, title: title, note: note, paths: paths, selectedByDefault: false,
                               shellFolders: shell, showsWhenEmpty: false, skipsOpenFiles: true,
                               entryLabel: label, selectableEntries: true, allowsEntry: allows)
        item.locksEntry = locks(reason: String(localized: "A program runs from this version, so it is kept"), running: running)
        return item
    }

    /// The first line of a small regular file, trimmed; nil when missing, empty or unreadable.
    private static func firstLine(of file: URL) -> String? {
        guard let line = smallText(file)?.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces),
              !line.isEmpty else { return nil }
        return line
    }

    /// The text of a regular file of at most 64 KB; nil when missing, bigger, empty or unreadable.
    private static func smallText(_ file: URL) -> String? {
        var info = stat()
        guard stat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 65_536,
              let text = try? String(contentsOf: file, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}
