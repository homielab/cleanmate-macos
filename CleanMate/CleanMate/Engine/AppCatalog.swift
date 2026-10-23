import Foundation

// AI tools, browsers and popular apps: one item per tool/app, shown only when it left something behind.
// Only caches, logs and old sessions are listed. Logins, settings, memory, profiles, cookies and history are
// never listed (sessions are only touched past the Settings age); see the safety test in EngineTests.

extension CleanerGroup {
    /// AI session transcripts are user history: only those untouched for `sessionDays` (Settings, default 30),
    /// unticked, moved to the Trash.
    nonisolated static func aiTools(sessionDays: Int = CleanupAges.default.sessions) -> CleanerGroup {
        func sessions(_ id: String, _ name: String, _ paths: [String], excluded: Set<String> = [],
                      apps: [String] = [], processes: [String] = [],
                      label: CleanerItem.EntryLabel? = nil) -> CleanerItem {
            sessionItem(id, name, paths, days: sessionDays, excluded: excluded, apps: apps, processes: processes, label: label)
        }
        return CleanerGroup(id: "ai-tools", title: "AI Tools", systemImage: "brain", items: [
        // Claude Code: never ~/.claude/{.credentials.json,settings.json,CLAUDE.md,plugins,skills}, nor projects/*/memory.
        cache("claude-code-cache", "Claude Code", [
            "~/.claude/cache", "~/.claude/debug", "~/.claude/statsig",
            "~/Library/Caches/claude-cli-nodejs", "~/.cache/claude-cli-nodejs",
        ]),
        sessions("claude-code-sessions", "Claude Code", [
            "~/.claude/projects/*", "~/.claude/file-history", "~/.claude/todos", "~/.claude/session-env",
            "~/.claude/shell-snapshots",
        ], excluded: ["memory"], processes: ["claude"], label: AISessions.claudeLabel(of:)),
        app("claude-desktop", "Claude Desktop", bundle: ["com.anthropic.claudefordesktop"],
            chromium("~/Library/Application Support/Claude")
                + ["~/Library/Application Support/Claude/Crashpad/completed",
                   "~/Library/Caches/com.anthropic.claudefordesktop"]),
        sessions("claude-desktop-sessions", "Claude Desktop", [
            "~/Library/Application Support/Claude/local-agent-mode-sessions",
            "~/Library/Application Support/Claude/claude-code-sessions",
        ], apps: ["com.anthropic.claudefordesktop"]),
        // Codex: never auth.json, config.toml, memories*, AGENTS.md.
        cache("codex-cache", "Codex", ["~/.codex/cache", "~/.codex/log"]),
        sessions("codex-sessions", "Codex", ["~/.codex/sessions/*/*", "~/.codex/archived_sessions"],
                 processes: ["codex"]),
        app("codex-app", "Codex app", bundle: ["com.openai.codex"],
            chromium("~/Library/Application Support/Codex") + ["~/Library/Caches/com.openai.codex"]),
        // Gemini CLI / Antigravity: never settings.json, oauth_creds.json, the *oauth-token files.
        cache("gemini-cache", "Gemini CLI & Antigravity", [
            "~/.gemini/logs", "~/.gemini/antigravity*/log", "~/.gemini/antigravity*/crashes",
        ]),
        sessions("gemini-sessions", "Gemini CLI & Antigravity", [
            "~/.gemini/tmp", "~/.gemini/antigravity*/conversations", "~/.gemini/antigravity*/brain",
        ], processes: ["gemini"]),
        app("antigravity", "Antigravity", bundle: ["com.google.antigravity"], vscode("Antigravity")),
        app("cursor", "Cursor", bundle: ["com.todesktop.230313mzl4w4u92"],
            vscode("Cursor") + ["~/Library/Caches/com.todesktop.230313mzl4w4u92"]),
        app("windsurf", "Windsurf", bundle: ["com.exafunction.windsurf"],
            vscode("Windsurf") + ["~/Library/Caches/com.exafunction.windsurf"]),
        app("zed", "Zed", bundle: ["dev.zed.Zed"],
            ["~/Library/Caches/Zed", "~/Library/Application Support/Zed/hang_traces"]),
        // GitHub Copilot: ~/.config/github-copilot holds the login, never listed.
        cache("copilot-cache", "GitHub Copilot CLI", ["~/.copilot/logs"]),
        sessions("copilot-sessions", "GitHub Copilot CLI", ["~/.copilot/session-state"], processes: ["copilot"]),
        // globalContext.json: the selected profile and models (settings, not index).
        cache("continue-cache", "Continue", ["~/.continue/index"], excluded: ["globalContext.json"]),
        sessions("continue-sessions", "Continue", ["~/.continue/sessions"], excluded: ["sessions.json"]),
        // Ollama: logs only, never ~/.ollama/models or its id_ed25519 key.
        app("ollama", "Ollama", bundle: ["com.electron.ollama"], ["~/.ollama/logs"]),
        // LM Studio: app caches only; models live in ~/.lmstudio (older versions: ~/.cache/lm-studio).
        app("lm-studio", "LM Studio", bundle: ["ai.elementlabs.lmstudio"],
            chromium("~/Library/Application Support/LM Studio")),
    ])
    }

    /// Chrome/Edge/Brave Beta/Dev/Canary/Nightly: own bundle id and data folder (same name under Caches and
    /// Application Support), so each is its own item, skipped only while that channel runs. Also used by Privacy.
    nonisolated static let browserChannels: [(id: String, name: String, bundle: String, folder: String)] = [
        ("chrome-beta", "Google Chrome Beta", "com.google.Chrome.beta", "Google/Chrome Beta"),
        ("chrome-dev", "Google Chrome Dev", "com.google.Chrome.dev", "Google/Chrome Dev"),
        ("chrome-canary", "Google Chrome Canary", "com.google.Chrome.canary", "Google/Chrome Canary"),
        ("edge-beta", "Microsoft Edge Beta", "com.microsoft.edgemac.Beta", "Microsoft Edge Beta"),
        ("edge-dev", "Microsoft Edge Dev", "com.microsoft.edgemac.Dev", "Microsoft Edge Dev"),
        ("edge-canary", "Microsoft Edge Canary", "com.microsoft.edgemac.Canary", "Microsoft Edge Canary"),
        ("brave-beta", "Brave Beta", "com.brave.Browser.beta", "BraveSoftware/Brave-Browser-Beta"),
        ("brave-nightly", "Brave Nightly", "com.brave.Browser.nightly", "BraveSoftware/Brave-Browser-Nightly"),
    ]

    nonisolated static let applications = CleanerGroup(id: "applications", title: "Applications",
                                                       systemImage: "macwindow", items: [
        // Browsers: ~/Library/Caches/<browser> is all cache; Application Support only for the cache folders.
        app("safari", "Safari", bundle: ["com.apple.Safari"], ["~/Library/Caches/com.apple.Safari"]),
        browser("chrome", "Google Chrome", bundle: "com.google.Chrome", caches: "Google/Chrome", support: "Google/Chrome"),
        browser("edge", "Microsoft Edge", bundle: "com.microsoft.edgemac", caches: "Microsoft Edge", support: "Microsoft Edge"),
        browser("brave", "Brave", bundle: "com.brave.Browser", caches: "BraveSoftware/Brave-Browser",
                support: "BraveSoftware/Brave-Browser"),
        browser("arc", "Arc", bundle: "company.thebrowser.Browser", caches: "Arc", support: "Arc/User Data"),
        // Firefox profiles (Application Support) are never touched; its cache2 folders live here.
        app("firefox", "Firefox", bundle: CleanerGroup.firefoxBundleIDs, ["~/Library/Caches/Firefox"]),
        browser("opera", "Opera", bundle: "com.operasoftware.Opera", caches: "com.operasoftware.Opera",
                support: "com.operasoftware.Opera"),
        browser("vivaldi", "Vivaldi", bundle: "com.vivaldi.Vivaldi", caches: "Vivaldi", support: "Vivaldi"),
    ] + browserChannels.map { browser($0.id, $0.name, bundle: $0.bundle, caches: $0.folder, support: $0.folder) }
    // On-device AI model, GBs per channel: unticked, deleted (Chrome downloads it again when an AI feature
    // is used, so the Trash would free nothing); skipped while that channel runs.
    + [("chrome", "Google Chrome", "com.google.Chrome", "Google/Chrome"),
          ("edge", "Microsoft Edge", "com.microsoft.edgemac", "Microsoft Edge")].flatMap { stable in
        // Stable then its Beta/Dev/Canary; Edge keeps its model (Phi-4-mini) in EdgeLLMOnDeviceModel.
        [stable] + browserChannels.filter { $0.id.hasPrefix(stable.0 + "-") }.map { ($0.id, $0.name, $0.bundle, $0.folder) }
    }.map { id, name, bundle, folder in
        id.hasPrefix("edge")
            ? chromeModel(id, name, bundle: bundle, support: folder, folder: "EdgeLLMOnDeviceModel",
                          note: "Edge downloads it again when an AI feature is used")
            : chromeModel(id, name, bundle: bundle, support: folder)
    } + [
        // Google Updater: crx_cache only holds update packages already installed (metadata.json maps them to
        // app ids). Never its version folders (the updater itself), prefs.json or logs. Skipped while it runs.
        CleanerItem(id: "google-updater-cache", title: "Google Updater: downloaded updates",
                    note: "Update packages already installed; downloaded again if needed",
                    paths: ["~/Library/Application Support/Google/GoogleUpdater/crx_cache"], showsWhenEmpty: false,
                    runningProcessNames: ["GoogleUpdater"]),

        app("vscode", "Visual Studio Code", bundle: ["com.microsoft.VSCode"],
            vscode("Code") + ["~/Library/Caches/com.microsoft.VSCode"]),
        app("slack", "Slack", bundle: ["com.tinyspeck.slackmacgap"],
            chromium("~/Library/Application Support/Slack") + ["~/Library/Caches/com.tinyspeck.slackmacgap"]),
        app("discord", "Discord", bundle: ["com.hnc.Discord"],
            chromium("~/Library/Application Support/discord") + ["~/Library/Caches/com.hnc.Discord"]),
        // New Teams (com.microsoft.teams2): its container's Caches go with "Sandboxed app caches";
        // its Group Containers caches go with "App group caches".
        app("teams", "Microsoft Teams (classic)", bundle: ["com.microsoft.teams"],
            chromium("~/Library/Application Support/Microsoft/Teams") + ["~/Library/Caches/com.microsoft.teams"]),
        app("zoom", "Zoom", bundle: ["us.zoom.xos"], ["~/Library/Caches/us.zoom.xos"]),
        app("spotify", "Spotify", bundle: ["com.spotify.client"], ["~/Library/Caches/com.spotify.client"]),
        // Telegram Desktop (not the App Store build): tdata also holds the login, so only its cache folders.
        app("telegram", "Telegram", bundle: ["com.tdesktop.Telegram"], [
            "~/Library/Application Support/Telegram Desktop/tdata/user_data*/cache",
            "~/Library/Application Support/Telegram Desktop/tdata/user_data*/media_cache",
            "~/Library/Caches/com.tdesktop.Telegram",
        ]),
        app("notion", "Notion", bundle: ["notion.id"],
            chromium("~/Library/Application Support/Notion") + ["~/Library/Caches/notion.id"]),
        app("figma", "Figma", bundle: ["com.figma.Desktop"],
            chromium("~/Library/Application Support/Figma") + chromium("~/Library/Application Support/Figma/DesktopProfile/*")
                + ["~/Library/Caches/com.figma.Desktop"]),
        app("obsidian", "Obsidian", bundle: ["md.obsidian"], chromium("~/Library/Application Support/obsidian")),
        app("postman", "Postman", bundle: ["com.postmanlabs.mac"],
            chromium("~/Library/Application Support/Postman") + ["~/Library/Caches/com.postmanlabs.mac"]),
        app("signal", "Signal", bundle: ["org.whispersystems.signal-desktop"],
            chromium("~/Library/Application Support/Signal")),
    ])

    /// `~/Library/Caches` paths owned by a separate item (`Google/Chrome`, `Homebrew`), kept out of "User caches"
    /// so nothing is counted twice; the rest of their top folder (`Google/…`) is still listed. Cut at a `*`.
    /// "Old IDE versions" is left out: it would own all of `Google`; `skipsUserCache` keeps its folders instead.
    nonisolated static let ownedCachePaths = Set([developer, aiTools(), applications].flatMap(\.items)
        .filter { $0.id != oldIDEVersions }.flatMap(\.paths)
        .compactMap { path -> String? in
            guard path.hasPrefix("~/Library/Caches/") else { return nil }
            let parts = path.dropFirst("~/Library/Caches/".count).split(separator: "/").prefix { !$0.contains("*") }
            return parts.isEmpty ? nil : parts.joined(separator: "/")
        })

    /// Chromium/Electron cache folders, in the data folder itself, its profiles (Default, Profile 1…) and partitions.
    /// Never Cookies, Local Storage, IndexedDB, History or Preferences.
    nonisolated private static func chromium(_ root: String) -> [String] {
        let folders = ["Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache", "GraphiteDawnCache",
                       "GrShaderCache", "ShaderCache", "GPUPersistentCache", "Service Worker/CacheStorage",
                       "Service Worker/ScriptCache"]
        return [root, root + "/*", root + "/Partitions/*"].flatMap { base in folders.map { base + "/" + $0 } }
    }

    /// VS Code and its forks: Chromium caches plus compiled code and downloaded extension packages.
    nonisolated private static func vscode(_ name: String) -> [String] {
        let root = "~/Library/Application Support/" + name
        return chromium(root) + [root + "/CachedData", root + "/CachedExtensionVSIXs"]
    }

    nonisolated private static func browser(_ id: String, _ name: String, bundle: String, caches: String,
                                            support: String) -> CleanerItem {
        app(id, name, bundle: [bundle],
            ["~/Library/Caches/" + caches] + chromium("~/Library/Application Support/" + support))
    }

    nonisolated private static func chromeModel(_ id: String, _ name: String, bundle: String,
                                                support: String, folder: String = "OptGuideOnDeviceModel",
                                                note: LocalizedStringResource =
                                                    "Chrome downloads it again when an AI feature is used") -> CleanerItem {
        CleanerItem(id: id + "-ai-model", title: "\(name): on-device AI model", note: note,
                    paths: ["~/Library/Application Support/\(support)/\(folder)"], selectedByDefault: false,
                    showsWhenEmpty: false, runningAppBundleIDs: [bundle])
    }

    /// App names are not translated.
    nonisolated private static func app(_ id: String, _ name: String, bundle: [String], _ paths: [String]) -> CleanerItem {
        CleanerItem(id: id, title: LocalizedStringResource(String.LocalizationValue(name)),
                    note: "Caches only; sign-ins, history and settings are kept", paths: paths,
                    showsWhenEmpty: false, runningAppBundleIDs: bundle)
    }

    nonisolated private static func cache(_ id: String, _ name: String, _ paths: [String],
                                          excluded: Set<String> = []) -> CleanerItem {
        CleanerItem(id: id, title: "\(name): cache & logs",
                    note: "Recreated as needed; sign-ins, settings and memory are kept", paths: paths,
                    excluded: excluded, showsWhenEmpty: false)
    }

    nonisolated private static func sessionItem(_ id: String, _ name: String, _ paths: [String], days: Int,
                                                excluded: Set<String>, apps: [String], processes: [String],
                                                label: CleanerItem.EntryLabel?) -> CleanerItem {
        // One tickable entry per session file/folder; Codex, Gemini, Copilot and Continue folder names
        // carry no project (a day, a hash or a session id), so only Claude Code entries get a label.
        CleanerItem(id: id, title: "\(name): old sessions",
                    note: "Chat transcripts and checkpoints not modified for \(days) days. Moved to the Trash",
                    paths: paths, minAge: Double(days) * 86_400, excluded: excluded, mode: .trash, selectedByDefault: false,
                    showsWhenEmpty: false, runningAppBundleIDs: apps, runningProcessNames: processes,
                    entryLabel: label, selectableEntries: true)
    }
}
