import Foundation

/// Folder variables users set in their shell profile (`export CARGO_HOME=~/dev/cargo`). An app opened from Finder
/// doesn't get the shell's environment, so the profile files are READ, never run or sourced. Only simple
/// top-level `[export ]NAME=value` lines for `variables` and `PATH` are taken; any other line (and its content) is ignored.
nonisolated enum ShellEnvironment {
    /// Only for items cleaned by removing files: a cleaning command (`go clean -modcache`) wouldn't see the variable,
    /// so it would leave the extra folder shown (no GOPATH for that reason).
    static let variables: Set<String> = [
        "NVM_DIR", "RUSTUP_HOME", "CARGO_HOME", "GRADLE_USER_HOME", "HF_HOME", "HF_HUB_CACHE",
        "ANDROID_AVD_HOME", "ANDROID_EMULATOR_HOME", "OLLAMA_MODELS", "FIREBASE_EMULATORS_PATH", "FIREBASE_DEBUG_PATH", "PUB_CACHE",
        "FVM_CACHE_PATH", "PYENV_ROOT", "RBENV_ROOT",
        // Where PyTorch, Whisper, sentence-transformers and Keras keep downloaded models (`AIModelCaches`).
        "TORCH_HOME", "SENTENCE_TRANSFORMERS_HOME", "KERAS_HOME", "XDG_CACHE_HOME",
        // Android SDK folders (scanned for system images and old components) and where AVDs are kept (only read: which images they use).
        "ANDROID_HOME", "ANDROID_SDK_ROOT", "ANDROID_USER_HOME", "ANDROID_SDK_HOME", "ANDROID_PREFS_ROOT",
        // Build tool caches (`DeveloperCatalog`).
        "DENO_DIR", "ZIG_GLOBAL_CACHE_DIR", "CCACHE_DIR", "SCCACHE_DIR", "POETRY_CACHE_DIR", "PRE_COMMIT_HOME", "PIPX_HOME",
    ]
    /// zsh's load order (later wins); the bash files only fill variables no zsh file sets.
    /// shortcut: ZDOTDIR, `source`d files, /etc/zshenv and .zlogin are not read; add them if users ask.
    static let zshFiles = [".zshenv", ".zprofile", ".zshrc"]
    static let bashFiles = [".profile", ".bash_profile"]

    /// XDG base folders other profile lines build on (`export NVM_DIR="$XDG_DATA_HOME/nvm"`), relative to home
    /// when the profile leaves them unset (the XDG spec's defaults).
    static let xdgDefaults = ["XDG_DATA_HOME": ".local/share", "XDG_CACHE_HOME": ".cache", "XDG_CONFIG_HOME": ".config"]

    /// Variables set by `text` (one profile file), last assignment wins. A value is kept only when it is literal
    /// apart from `~`, `$HOME` and `$NAME`/`${NAME}` for an XDG folder or a listed variable already known from an
    /// earlier simple line (`known`, then this file in order; XDG folders default to the spec): anything with `$(`,
    /// backticks, `${NAME:-…}` or an unknown variable is skipped, and so is every line that is indented or inside an
    /// `if`/`case`/loop/function block (it may not run). Such a skipped line also makes its names unknown for later
    /// lines, so a reference never falls back to an older or default value the shell may not have.
    /// shortcut: that only holds within one file (a later file sees the earlier files' last readable values).
    /// `PATH` follows the same rules, except that `$PATH` starts empty (the folders earlier lines added) and a skipped
    /// line keeps it: it only adds folders to look tools up in, so an unreadable line just leaves its own folders out.
    static func parse(_ text: String, home: String, known: [String: String] = [:]) -> [String: String] {
        var found: [String: String] = [:]
        var env = xdgDefaults.mapValues { home + "/" + $0 }.merging(known) { $1 }
        env["HOME"] = home
        env["PATH"] = env["PATH"] ?? ""
        var depth = 0
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let word = line.prefix { !$0.isWhitespace && $0 != ";" }
            if ["if", "case", "for", "while", "until", "select"].contains(word) || line.hasSuffix("{") { depth += 1 }
            let last = line.split(whereSeparator: { $0.isWhitespace || $0 == ";" }).last ?? ""
            // A one-line `if …; then …; fi` opens and closes on the same line.
            if ["fi", "esac", "done", "}"].contains(word) || ["fi", "esac", "done", "}"].contains(last) {
                depth = max(0, depth - 1)
            }
            let match = line.wholeMatch(of: /(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)/)
            let name = match.map { String($0.1) } ?? ""
            if depth == 0, raw.first?.isWhitespace == false, let match, variables.contains(name) || xdgDefaults[name] != nil || name == "PATH",
               let value = value(String(match.2), home: home, env: env) {
                env[name] = value
                found[name] = value
            } else {
                for set in line.matches(of: /(?:^|[\s;&|(])([A-Za-z_][A-Za-z0-9_]*)=/) where !["HOME", "PATH"].contains(String(set.1)) {
                    env[String(set.1)] = nil
                }
            }
        }
        return found
    }

    /// The literal value of an assignment's right-hand side, nil when it needs a real shell to know.
    static func value(_ raw: String, home: String, env: [String: String] = [:]) -> String? {
        var text: String
        var rest: Substring
        var literal = false
        if let quote = raw.first, quote == "\"" || quote == "'" {
            guard let end = raw.dropFirst().firstIndex(of: quote) else { return nil }
            text = String(raw[raw.index(after: raw.startIndex)..<end])
            rest = raw[raw.index(after: end)...]
            if quote == "\"", text.contains("\\") { return nil }
            literal = quote == "'" // no expansion at all
        } else {
            let end = raw.firstIndex(where: \.isWhitespace) ?? raw.endIndex
            text = String(raw[..<end])
            rest = raw[end...]
            if text.contains(where: { ";&|<>()\"'\\*?[".contains($0) }) { return nil }
            if text == "~" || text.hasPrefix("~/") { text = home + text.dropFirst() } // `~` only unquoted
        }
        let tail = rest.trimmingCharacters(in: .whitespaces)
        guard tail.isEmpty || tail.hasPrefix("#") else { return nil } // `; cmd`, a second word…
        if !literal {
            // Known names only; an unknown one keeps its `$` and is refused below. Values in `env` hold no `$`.
            text = text.replacing(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)/) { match in
                let name = String(match.1 ?? match.2 ?? "")
                return name == "HOME" ? home : env[name] ?? String(match.0)
            }
        }
        guard !text.isEmpty, !text.contains("$"), !text.contains("`") else { return nil }
        return text
    }

    /// Every variable from the profile files in `home` (zsh files, then bash ones as fallback), each file seeing the
    /// values the earlier ones in its chain set.
    static func read(home: URL) -> [String: String] {
        func values(_ files: [String]) -> [String: String] {
            files.reduce(into: [:]) { found, name in
                // Read only, never logged: these files may hold secrets next to the variables.
                guard let text = try? String(contentsOf: home.appending(path: name), encoding: .utf8) else { return }
                found.merge(parse(text, home: home.path, known: found)) { $1 }
            }
        }
        return values(zshFiles).merging(values(bashFiles)) { zsh, _ in zsh }
    }

    /// Names any line of the profile files assigns (`NAME=`), readable or not: a name here but not in `read` is set in
    /// a way only a real shell knows. Comment lines don't count.
    static func assigned(home: URL) -> Set<String> {
        var names = Set<String>()
        for name in zshFiles + bashFiles {
            guard let text = try? String(contentsOf: home.appending(path: name), encoding: .utf8) else { continue }
            for line in text.split(whereSeparator: \.isNewline) where !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                for set in line.matches(of: /(?:^|[\s;&|(])([A-Za-z_][A-Za-z0-9_]*)=/) { names.insert(String(set.1)) }
            }
        }
        return names
    }

    /// `read`, reused while the files' dates and sizes stay the same: a scan asks once per item.
    static func cached(home: URL) -> [String: String] {
        let stamp = [home.path] + (zshFiles + bashFiles).map { name in
            let values = try? home.appending(path: name).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return "\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values?.fileSize ?? -1)"
        }
        return cache.withLock { cache in
            if cache?.stamp == stamp, let values = cache?.values { return values }
            let values = read(home: home)
            cache = (stamp, values)
            return values
        }
    }
    private static let cache = Locked<(stamp: [String], values: [String: String])?>(nil)

    /// Folders the profile adds to `PATH`: absolute, strictly inside `home`, existing folders, neither a symlink nor
    /// reached through one below `home`. Where tools installed for the shell only (`~/.cargo/bin`, nvm, pnpm) live.
    static func pathFolders(home: URL) -> [String] {
        let base = home.standardizedFileURL.path
        return (cached(home: home)["PATH"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)).standardizedFileURL.path }
            .filter { path in
                guard path.hasPrefix(base + "/") else { return false }
                var current = base, info = stat()
                for part in path.dropFirst(base.count).split(separator: "/") {
                    current += "/" + part
                    guard lstat(current, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return false }
                }
                return true
            }
    }

    /// The folder `name` points to, only when it is absolute, strictly inside home, an existing folder, allowed by
    /// `policy` itself and not reached through a symlink (same rules as `PathLookup`).
    static func folder(_ name: String, policy: SafetyPolicy) -> URL? {
        cached(home: policy.homeURL)[name].flatMap { checkedFolder($0, policy: policy) }
    }

    /// `value` as a folder under the rules of `folder` (also for a folder named in a tool's settings file);
    /// `allows` replaces `SafetyPolicy.allows` (see `ConfigFolders.allows`).
    static func checkedFolder(_ value: String, policy: SafetyPolicy,
                              allows: (@Sendable (SafetyPolicy, URL) -> Bool)? = nil) -> URL? {
        guard value.hasPrefix("/"), !value.contains(where: { "*?[".contains($0) }) else { return nil }
        let url = URL(fileURLWithPath: value).standardizedFileURL
        var isFolder: ObjCBool = false
        guard url.path.hasPrefix(policy.homeURL.standardizedFileURL.path + "/"),
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue,
              allows?(policy, url) ?? policy.allows(url), !policy.rootThroughSymlink(url) else { return nil }
        return url
    }
}
