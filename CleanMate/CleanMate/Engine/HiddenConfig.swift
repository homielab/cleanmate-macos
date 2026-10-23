import Foundation

// Hidden config: hidden items directly in ~ and items directly in ~/.config that no known tool or app explains.
// Read-only: listed with a warning, never ticked, never removed. Never goes into ~/Library, Documents or Desktop (no TCC prompt).

nonisolated struct HiddenConfigItem: Identifiable, Hashable, Sendable {
    let url: URL
    let modified: Date?
    /// An executable file or a script (`#!`): the item itself, or a file directly inside it.
    let hasExecutable: Bool
    /// The item, or something directly inside it, changed in the last `recentDays` days.
    let isRecent: Bool

    var id: URL { url }
    /// Worth a closer look: runs code or changed recently.
    var isNotable: Bool { hasExecutable || isRecent }
}

nonisolated enum HiddenConfig {
    static let recentDays = 7
    /// macOS' own entries, never listed (`.Trash` is not even read).
    static let skipped: Set = [".trash", ".ds_store", ".cfusertextencoding", ".localized", ".file", ".volumeicon.icns"]
    /// Well-known dotfiles and folders of shells, editors and common developer tools (lowercased, without the dot).
    static let standard: Set = [
        "zshrc", "zprofile", "zshenv", "zlogin", "zlogout", "zsh", "zsh_sessions", "zcompdump", "zcompcache", "bashrc",
        "bash_profile", "bash_sessions", "profile", "inputrc", "hushlogin", "lesshst", "viminfo", "vimrc", "vim", "nvim",
        "emacs", "emacs.d", "nanorc", "wget-hsts", "curlrc", "netrc", "oh-my-zsh", "p10k", "tmux", "tmux.conf",
        "gitconfig", "gitignore", "gitignore_global", "git-credentials", "ssh", "gnupg", "password-store", "config", "local", "cache",
        "docker", "kube", "aws", "azure", "gcloud", "terraform.d", "npmrc", "npm", "nvm", "node-gyp", "yarnrc", "yarn",
        "pnpm-state", "bun", "deno", "cargo", "rustup", "pyenv", "rbenv", "gem", "bundle", "cocoapods", "swiftpm",
        "gradle", "m2", "android", "jdks", "sdkman", "lldb", "lldbinit", "gdbinit", "subversion", "vscode", "cursor",
        "ipython", "jupyter", "matplotlib", "keras", "conda", "condarc", "pip", "pypirc", "python_history",
        "node_repl_history", "ts_node_repl_history", "irb_history", "sqlite_history", "psql_history", "mysql_history",
        "rediscli_history", "dbshell", "mongodb", "expo", "fastlane", "streamlit", "supabase", "homebrew", "colima",
        "lima", "minikube", "helm", "vagrant.d", "ollama", "anaconda", "huggingface", "mcp", "agents",
        // Libraries and SDKs that write here on their own behalf (npm, JVM/Compose, Android emulator, Python models).
        "configstore", "simple-update-notifier", "jgit", "hawtjni", "openjfx", "skiko", "lemminx", "insightface",
        "emulator_console_auth_token", "ddlocalbackups", "ddpreview", "appstoreconnect",
        // Common CLIs and AI coding tools.
        "b2_account_info", "rclone", "prisma", "flameshot", "osxphotos", "acli", "dbvis", "codeium", "windsurf", "junie",
        "factory", "devin", "kilo", "qwen", "marscode", "aider", "goose", "opencode", "zed",
    ]

    /// `~/.name` and `~/.config/name` that the Smart Scan and Privacy catalogs clean, lowercased without the dot.
    static func catalogNames() -> Set<String> {
        let groups = CleanerGroup.smartScan(ages: .default) + CleanerGroup.privacy
        var names = Set<String>()
        for path in groups.flatMap(\.items).flatMap(\.paths) {
            for prefix in ["~/.config/", "~/."] where path.hasPrefix(prefix) {
                if let first = path.dropFirst(prefix.count).split(separator: "/").first { names.insert(first.lowercased()) }
                break
            }
        }
        return names
    }

    /// App names (lowercased, also without spaces) and the distinctive parts of their bundle ids (`com.vendor.app` →
    /// `vendor`, `app`), for every app in the application folders, /System/Applications and running.
    static func appNames(policy: SafetyPolicy = .current, running: Set<String> = []) -> Set<String> {
        let folders = policy.applicationFolders + [URL(fileURLWithPath: "/System/Applications")]
        var names = Set<String>()
        var ids = running
        for url in folders.flatMap({ Uninstaller.appURLs(in: $0) }) {
            let name = url.deletingPathExtension().lastPathComponent.lowercased()
            names.formUnion([name, name.replacingOccurrences(of: " ", with: ""), name.replacingOccurrences(of: " ", with: "-")])
            if let id = Bundle(url: url)?.bundleIdentifier { ids.insert(id) }
        }
        for id in ids { names.formUnion(id.lowercased().split(separator: ".").dropFirst().map(String.init)) }
        return names.filter { $0.count >= 3 }.subtracting(AppMatcher.genericNames)
    }

    /// Whether `name` (an entry of ~ or ~/.config) belongs to something in `known`: the whole name without the dot,
    /// or its first part (`.zshrc.bak`, `.claude.json`, `.vscode-shared`), or a shell/REPL history file.
    static func isKnown(_ name: String, known: Set<String>) -> Bool {
        var base = name.lowercased()
        if base.hasPrefix(".") { base.removeFirst() }
        guard !base.isEmpty else { return true }
        if known.contains(base) || base.hasSuffix("history") { return true }
        let first = base.split(whereSeparator: { "-_.".contains($0) }).first.map(String.init) ?? base
        return known.contains(first)
    }

    /// Everything known on this Mac: standard dotfiles, catalog paths, command-line tools, apps.
    static func knownNames(policy: SafetyPolicy = .current, running: Set<String> = []) -> Set<String> {
        standard.union(catalogNames()).union(Uninstaller.commandLineTools(home: policy.homeURL))
            .union(appNames(policy: policy, running: running))
    }

    /// Unknown hidden config items of this Mac, off the main thread.
    @concurrent static func strange(policy: SafetyPolicy = .current, running: Set<String>) async -> [HiddenConfigItem] {
        await strange(home: policy.homeURL, known: knownNames(policy: policy, running: running))
    }

    /// Unknown hidden items of ~ and items of ~/.config, by name. Only names and level-1 metadata are read;
    /// a symlink is listed but never followed.
    @concurrent static func strange(home: URL, known: Set<String>, now: Date = .now) async -> [HiddenConfigItem] {
        let fm = FileManager.default
        let homeEntries = ((try? fm.contentsOfDirectory(atPath: home.path)) ?? []).filter { $0.hasPrefix(".") }
            .map { home.appending(path: $0) }
        let config = home.appending(path: ".config")
        let configEntries = ((try? fm.contentsOfDirectory(atPath: config.path)) ?? []).map { config.appending(path: $0) }
        let cutoff = now.addingTimeInterval(-Double(recentDays) * 86_400)
        return (homeEntries + configEntries)
            .filter { !skipped.contains($0.lastPathComponent.lowercased()) && !isKnown($0.lastPathComponent, known: known) }
            .map { item(at: $0, cutoff: cutoff) }
            .sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
    }

    static func item(at url: URL, cutoff: Date) -> HiddenConfigItem {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .contentModificationDateKey]
        let values = try? url.resourceValues(forKeys: keys)
        var files = [url]
        if values?.isDirectory == true, values?.isSymbolicLink != true {
            files += (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys))) ?? []
        }
        let dates = files.compactMap { try? $0.resourceValues(forKeys: keys).contentModificationDate }
        return HiddenConfigItem(url: url, modified: values?.contentModificationDate,
                                hasExecutable: files.contains(where: isExecutable),
                                isRecent: dates.contains { $0 >= cutoff })
    }

    /// A regular file (not a symlink) with an execute bit, or starting with `#!`.
    static func isExecutable(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return false }
        if let mode = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int,
           mode & 0o111 != 0 { return true }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 2)) == Data("#!".utf8)
    }
}
