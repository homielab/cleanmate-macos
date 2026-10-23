import Foundation
import Synchronization

/// Folder variables users set in their shell profile (`export CARGO_HOME=~/dev/cargo`). An app opened from Finder
/// doesn't get the shell's environment, so the profile files are READ, never run or sourced. Only simple
/// top-level `[export ]NAME=value` lines for `variables` are taken; any other line (and its content) is ignored.
nonisolated enum ShellEnvironment {
    /// Only for items cleaned by removing files: a cleaning command (`go clean -modcache`) wouldn't see the variable,
    /// so it would leave the extra folder shown (no GOPATH for that reason).
    static let variables: Set<String> = [
        "NVM_DIR", "RUSTUP_HOME", "CARGO_HOME", "GRADLE_USER_HOME", "HF_HOME", "HF_HUB_CACHE",
        "ANDROID_AVD_HOME", "ANDROID_EMULATOR_HOME",
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
    static func parse(_ text: String, home: String, known: [String: String] = [:]) -> [String: String] {
        var found: [String: String] = [:]
        var env = xdgDefaults.mapValues { home + "/" + $0 }.merging(known) { $1 }
        env["HOME"] = home
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
            if depth == 0, raw.first?.isWhitespace == false, let match, variables.contains(name) || xdgDefaults[name] != nil,
               let value = value(String(match.2), home: home, env: env) {
                env[name] = value
                found[name] = value
            } else {
                for set in line.matches(of: /(?:^|[\s;&|(])([A-Za-z_][A-Za-z0-9_]*)=/) where String(set.1) != "HOME" {
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
    private static let cache = Mutex<(stamp: [String], values: [String: String])?>(nil)

    /// The folder `name` points to, only when it is absolute, strictly inside home, an existing folder, allowed by
    /// `policy` itself and not reached through a symlink (same rules as `PathLookup`).
    static func folder(_ name: String, policy: SafetyPolicy) -> URL? {
        guard let value = cached(home: policy.homeURL)[name], value.hasPrefix("/"), !value.contains(where: { "*?[".contains($0) }) else { return nil }
        let url = URL(fileURLWithPath: value).standardizedFileURL
        var isFolder: ObjCBool = false
        guard url.path.hasPrefix(policy.homeURL.standardizedFileURL.path + "/"),
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue,
              policy.allows(url), !policy.rootThroughSymlink(url) else { return nil }
        return url
    }
}
