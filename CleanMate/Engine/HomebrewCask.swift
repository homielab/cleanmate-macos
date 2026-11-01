import Foundation

/// A Homebrew cask that installed an app: its token and the Homebrew prefix whose `brew` keeps its record.
nonisolated struct HomebrewCask: Hashable, Sendable {
    let token: String
    let prefix: String
    var brew: String { prefix + "/bin/brew" }
}

/// Apps installed with `brew install --cask`, found in `<prefix>/Caskroom` without running brew. Uninstalling such an
/// app moves it to the Trash like any app, then `brew uninstall --cask <token>` clears Homebrew's record of it, so
/// brew doesn't think the app is still installed and `brew upgrade` doesn't put it back.
nonisolated enum HomebrewCasks {
    /// Token as a Caskroom folder spells it (`visual-studio-code`, `zulu@17`); anything else is never passed to brew.
    static func isToken(_ name: String) -> Bool {
        name.wholeMatch(of: /[a-z0-9][a-z0-9@._+-]*/) != nil
    }

    /// The app paths each installed cask put in place, keyed by `key`: from `<token>/<version>/<App>.app` (the symlink
    /// brew leaves to the moved app, or a copy: `appdir/<App>.app`), the `app` artifacts of `.metadata/INSTALL_RECEIPT.json`,
    /// and, for older installs, the saved cask (`.metadata/<version>/<time>/Casks/<token>.json` or `.rb`).
    /// `appdir` comes from `.metadata/config.json` (default /Applications). An app claimed by two casks keeps the first by token.
    static func installed(prefixes: [String] = Uninstaller.brewPrefixes) -> [String: HomebrewCask] {
        let fm = FileManager.default
        var casks: [String: HomebrewCask] = [:]
        for prefix in prefixes {
            let caskroom = URL(fileURLWithPath: prefix).appending(path: "Caskroom", directoryHint: .isDirectory)
            let tokens = ((try? fm.contentsOfDirectory(atPath: caskroom.path)) ?? []).filter(isToken).sorted()
            for token in tokens {
                for path in appPaths(of: caskroom.appending(path: token, directoryHint: .isDirectory)) where casks[path] == nil {
                    casks[path] = HomebrewCask(token: token, prefix: prefix)
                }
            }
        }
        return casks
    }

    /// The cask that installed the app at `url`, if any.
    static func cask(for url: URL, in casks: [String: HomebrewCask]) -> HomebrewCask? {
        casks[key(url)]
    }

    /// The cask that installed the app at `url`, read from Caskroom now (right before an uninstall).
    static func cask(for url: URL, prefixes: [String] = Uninstaller.brewPrefixes) -> HomebrewCask? {
        cask(for: url, in: installed(prefixes: prefixes))
    }

    /// Lowercased resolved path: APFS is case-insensitive by default and `/var` is `/private/var`.
    static func key(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
    }

    /// `key`s of the apps one cask folder (`<prefix>/Caskroom/<token>`) points to.
    static func appPaths(of folder: URL) -> Set<String> {
        let fm = FileManager.default
        let metadata = folder.appending(path: ".metadata", directoryHint: .isDirectory)
        let appdir = self.appdir(config: metadata.appending(path: "config.json"))
        var paths = Set<String>()
        func add(_ target: String) {
            let expanded = (target as NSString).expandingTildeInPath
            let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : appdir.appending(path: expanded)
            if url.pathExtension.lowercased() == "app" { paths.insert(key(url)) }
        }
        // Version folders; `latest` is a symlink to one of them.
        let versions = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") && (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true }
        for version in versions {
            for name in (try? fm.contentsOfDirectory(atPath: version.path)) ?? [] where name.lowercased().hasSuffix(".app") {
                let item = version.appending(path: name)
                if let destination = try? fm.destinationOfSymbolicLink(atPath: item.path) {
                    add(destination.hasPrefix("/") ? destination : version.appending(path: destination).path)
                } else {
                    add(name)
                }
            }
        }
        let receipt = metadata.appending(path: "INSTALL_RECEIPT.json")
        if let data = try? Data(contentsOf: receipt),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            appTargets(artifacts: json["uninstall_artifacts"]).forEach(add)
        }
        guard paths.isEmpty else { return paths }
        for saved in savedCasks(in: metadata, token: folder.lastPathComponent) {
            guard let text = try? String(contentsOf: saved, encoding: .utf8) else { continue }
            if saved.pathExtension == "json" {
                let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
                appTargets(artifacts: json?["artifacts"]).forEach(add)
            } else {
                rubyAppTargets(text).forEach(add)
            }
        }
        return paths
    }

    /// `appdir` the cask was installed with: `explicit` (`--appdir`) over `default`; /Applications when unknown.
    static func appdir(config: URL) -> URL {
        let json = (try? Data(contentsOf: config)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let explicit = (json?["explicit"] as? [String: Any])?["appdir"] as? String
        let fallback = (json?["default"] as? [String: Any])?["appdir"] as? String
        let path = ((explicit ?? fallback ?? "/Applications") as NSString).expandingTildeInPath
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Where each `app` artifact lands: `{"app": ["Foo.app"]}` → `Foo.app`; `{"app": ["Foo/Foo.app", {"target": "Bar.app"}]}`
    /// → `Bar.app`. Relative to `appdir`, or absolute.
    static func appTargets(artifacts: Any?) -> [String] {
        ((artifacts as? [Any]) ?? []).compactMap { artifact -> String? in
            guard let app = (artifact as? [String: Any])?["app"] as? [Any], let source = app.first as? String else { return nil }
            let target = app.dropFirst().compactMap { ($0 as? [String: Any])?["target"] as? String }.first
            return target ?? (source as NSString).lastPathComponent
        }
    }

    /// `app "Foo.app"` and `app "Foo/Foo.app", target: "Bar.app"` lines of a cask file.
    static func rubyAppTargets(_ text: String) -> [String] {
        text.split(separator: "\n").compactMap { line -> String? in
            guard let match = line.firstMatch(of: /^\s*app\s+"([^"]+)"(?:\s*,\s*target:\s*"([^"]+)")?/) else { return nil }
            return match.2.map(String.init) ?? (String(match.1) as NSString).lastPathComponent
        }
    }

    /// `.metadata/<version>/<time>/Casks/<token>.{json,rb}` files.
    private static func savedCasks(in metadata: URL, token: String) -> [URL] {
        let fm = FileManager.default
        let versions = ((try? fm.contentsOfDirectory(atPath: metadata.path)) ?? []).filter { !$0.hasPrefix(".") }
        return versions.flatMap { version in
            let folder = metadata.appending(path: version, directoryHint: .isDirectory)
            return ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).flatMap { time in
                ["json", "rb"].map { folder.appending(path: "\(time)/Casks/\(token).\($0)") }
            }
        }.filter { fm.fileExists(atPath: $0.path) }
    }

    /// `brew uninstall --cask <token>` with the brew of the cask's prefix: never `--zap` (the app's data is the
    /// Uninstaller's job, through the Trash) nor `--force`. No auto-update; stdin is /dev/null, so a step that needs a
    /// password (a pkg receipt) fails instead of waiting.
    static func uninstallCommand(_ cask: HomebrewCask) -> ShellCommand {
        ShellCommand(executable: cask.brew, arguments: ["uninstall", "--cask", cask.token], timeout: .seconds(120),
                     environment: ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ENV_HINTS": "1"])
    }

    /// Runs `uninstallCommand`; false when brew is missing, fails or times out.
    static let uninstall: @Sendable (HomebrewCask) async -> Bool = { cask in
        isToken(cask.token) ? await uninstallCommand(cask).run() : false
    }

    /// A `brew` command is running (an install or upgrade may be using the cask right now).
    static let isBrewRunning: @Sendable () -> Bool = { RunningProcesses.names().contains("brew") }
}
