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
        app("cursor", "Cursor", bundle: [cursorBundle],
            vscode("Cursor") + ["~/Library/Caches/com.todesktop.230313mzl4w4u92"]),
        // Cursor agent chats outside ~/Library: transcripts and saved tool output per project. Never
        // ~/.cursor/{extensions,mcp.json,hooks.json,skills-cursor,plugins,plans,ai-tracking}.
        sessions("cursor-sessions", "Cursor", ["~/.cursor/projects/*/agent-transcripts", "~/.cursor/projects/*/agent-tools"],
                 apps: [cursorBundle], processes: ["cursor-agent"], label: AISessions.cursorLabel(of:)),
        app("windsurf", "Windsurf", bundle: [windsurfBundle],
            vscode("Windsurf") + ["~/Library/Caches/com.exafunction.windsurf"]),
        // Windsurf and the Codeium extensions (same ~/.codeium, run by a language server): code search indexes
        // (embeddings, built again when a project is indexed) and Chromium caches of the browser profile. Never
        // cascade, memories, brain, implicit, code_tracker, skills, workflows, user_settings.pb, nor the profile's
        // cookies, logins or history.
        cache("windsurf-cache", "Windsurf", ["~/.codeium/database", "~/.codeium/windsurf/database"]
                + ["~/.codeium/ws-browser-profile", "~/.codeium/windsurf/ws-browser-profile"].flatMap(chromium),
              apps: [windsurfBundle], processes: codeiumServers),
        // Unticked like Playwright browsers: Chromium builds (Playwright layout, `chromium-1169`) Windsurf downloads
        // for its browser; it downloads one again when the browser is used.
        CleanerItem(id: "windsurf-browsers", title: "Windsurf: downloaded browsers",
                    note: "Chromium builds for Windsurf's browser, downloaded again when it is opened",
                    paths: ["~/.codeium/ws-browser", "~/.codeium/windsurf/ws-browser"], selectedByDefault: false,
                    showsWhenEmpty: false, runningAppBundleIDs: [windsurfBundle], runningProcessNames: codeiumServers),
        // opencode: models list, downloaded tools (rg) and plugin packages in its cache, and its logs. Never
        // auth.json, opencode.db (sessions), snapshot (undo history), tool-output, shell, repos.
        cache("opencode-cache", "opencode", ["~/.cache/opencode", "~/.local/share/opencode/log"],
              processes: ["opencode"], openFiles: true),
        // Kilo Code's CLI (`kilo`, formerly `kilocode`, also run as `kilo serve` by its editor extensions) and
        // MiMoCode (`mimo`) are opencode forks with the same layout: models list and downloaded tools in the cache,
        // logs next to their data. Never kilo.db / mimocode.db (sessions), auth.json, snapshot, storage,
        // tool-output, repos, builtin_skills, compose, ~/.config or ~/.local/state.
        cache("kilo-cache", "Kilo Code", ["~/.cache/kilo", "~/.local/share/kilo/log"],
              processes: ["kilo", "kilocode"], openFiles: true),
        cache("mimocode-cache", "MiMoCode", ["~/.cache/mimocode", "~/.local/share/mimocode/log"],
              processes: ["mimo"], openFiles: true),
        // Cline: logs only. Never secrets.json, settings, db (sessions.db indexes its sessions), sessions,
        // workspaces, data/cache (holds user_input_history.jsonl), cron, apps.
        cache("cline-cache", "Cline", ["~/.cline/data/logs"], processes: ["cline"], openFiles: true),
        // Orca: Electron caches, crash reports and logs only; never its accounts, keys, profiles, terminal history,
        // session index (ai-vault) nor the terminal host it unpacks (daemon-host). Skipped while Orca, a helper or
        // its terminal host (which keeps terminals alive after Orca quits, and writes the daemon log) runs.
        // Not `skipsOpenFiles`: the running check covers it, and `chromium` globs ~500 roots here, each one looked up in
        // the open-file table per entry while cleaning.
        running(app("orca", "Orca", bundle: ["com.stablyai.orca*"],
                    chromium(orca) + [orca + "/Crashpad/completed", orca + "/logs"]), processes: ["orca-terminal-host"]),
        // ZCode: Electron caches of its session folder (and partitions), daily app logs and the CLI's event logs.
        // Never v2/{credentials.json,provider_config.json,certs,runtime,tasks-index.sqlite*,visualizations},
        // cli/{config.json,db,memories,agents,plugins,rollout,artifacts,exec} (rollout holds model input and output
        // of sessions), skills, workspace, plugin-workspace, backup, computer-use, nor the session's cookies, Local
        // Storage or IndexedDB. Skipped while the app or its agent processes (`zcode-cli`) run, so today's log, still
        // being written, stays. Not `skipsOpenFiles`: `chromium` globs the partitions, one open-file lookup per root.
        cache("zcode-cache", "ZCode", chromium(zcode) + ["~/.zcode/v2/logs", "~/.zcode/cli/log"],
              apps: ["dev.zcode.app"], processes: ["zcode-cli"]),
        // Unticked like Windsurf's browsers: the Linux server, Node.js, node-pty and tools ZCode copies to remote
        // machines (SSH). It downloads them from its CDN (sha256-checked) into `components`, links them into
        // `releases/<version>/<platform>`, and downloads them again when the cache is missing; `staging` only holds
        // its temporary downloads. One entry (the folder itself): `releases` hard-links `components`, so measuring
        // them apart would count the files twice. ZCode creates the folder again when needed.
        CleanerItem(id: "zcode-remote-assets", title: "ZCode: remote server files",
                    note: "Server and tools ZCode installs on remote machines, downloaded again when it connects to one",
                    paths: ["~/Library/Application Support/ZCode"], included: ["remote-assets-cache"],
                    selectedByDefault: false, showsWhenEmpty: false, runningAppBundleIDs: ["dev.zcode.app"],
                    runningProcessNames: ["zcode-cli"]),
        app("zed", "Zed", bundle: ["dev.zed.Zed"],
            ["~/Library/Caches/Zed", "~/Library/Application Support/Zed/hang_traces"]),
        // GitHub Copilot: ~/.config/github-copilot holds the login, never listed.
        cache("copilot-cache", "GitHub Copilot CLI", ["~/.copilot/logs"]),
        sessions("copilot-sessions", "GitHub Copilot CLI", ["~/.copilot/session-state"], processes: ["copilot"]),
        // globalContext.json: the selected profile and models (settings, not index).
        cache("continue-cache", "Continue", ["~/.continue/index"], excluded: ["globalContext.json"]),
        sessions("continue-sessions", "Continue", ["~/.continue/sessions"], excluded: ["sessions.json"]),
        // Ollama: logs, never its id_ed25519 key.
        app("ollama", "Ollama", bundle: ["com.electron.ollama"], ["~/.ollama/logs"]),
        // Ollama models: GBs each, unticked, each one ticked on its own: one entry per tag (its manifest) plus the
        // blobs no other model uses, a shared blob counting once all its models are ticked (`OllamaModels`).
        // Deleted like the Chrome model (the Trash would free nothing).
        // Skipped while Ollama runs: its server reads them, and an app quit leaves `ollama serve` running.
        CleanerItem(id: "ollama-models", title: "Ollama: downloaded models",
                    note: "Downloaded again with ollama pull; a model made with ollama create must be made again",
                    paths: [OllamaModels.manifestFolders], selectedByDefault: false, shellFolders: OllamaModels.shellFolders,
                    showsWhenEmpty: false, runningAppBundleIDs: ["com.electron.ollama"], runningProcessNames: ["ollama"],
                    skipsEntry: { { $0.lastPathComponent.hasPrefix(".") } }, entryLabel: OllamaModels.label(of:),
                    selectableEntries: true, entryFiles: OllamaModels.blobs(of:)),
        // Interrupted `ollama pull`s: one unticked row, deleted (regenerable); never a finished blob or a manifest.
        // Skipped while Ollama runs: a pull in progress writes to them.
        CleanerItem(id: "ollama-partial", title: "Ollama: incomplete downloads",
                    note: "Left by an interrupted ollama pull; pulling the model again starts over",
                    paths: [OllamaModels.partialFolder], included: OllamaModels.partialNames, selectedByDefault: false,
                    shellFolders: OllamaModels.partialShellFolders, showsWhenEmpty: false,
                    runningAppBundleIDs: ["com.electron.ollama"], runningProcessNames: ["ollama"]),
        // LM Studio: app caches only; its models are the item below.
        app("lm-studio", "LM Studio", bundle: LMStudioModels.bundleIDs,
            chromium("~/Library/Application Support/LM Studio")),
        // LM Studio models: GBs each, unticked, one entry per `<publisher>/<model>` folder (`LMStudioModels`), deleted
        // whole like Ollama's (downloaded again in LM Studio). Skipped while the app, `lms` or `llmster` runs: a model
        // may be loaded or downloading.
        CleanerItem(id: "lmstudio-models", title: "LM Studio: downloaded models",
                    note: "Downloaded again from LM Studio's Discover tab; an imported model must be imported again",
                    paths: LMStudioModels.paths, selectedByDefault: false,
                    configFolders: ConfigFolders(read: LMStudioModels.configuredFolders(home:), subpaths: ["*"]),
                    showsWhenEmpty: false, runningAppBundleIDs: LMStudioModels.bundleIDs,
                    runningProcessNames: LMStudioModels.processNames, skipsOpenFiles: true,
                    skipsEntry: { LMStudioModels.skips }, entryLabel: LMStudioModels.label(of:), selectableEntries: true),
        // Models PyTorch Hub, Whisper, sentence-transformers and Keras downloaded (`AIModelCaches`): GBs each, unticked,
        // one entry per model file or folder, deleted (downloaded again on the next load). A model a program has open is
        // kept; Python runs for many other things, so no process name locks the item.
        CleanerItem(id: AIModelCaches.id, title: "PyTorch, Whisper and Keras models",
                    note: "Models and datasets Python libraries downloaded; downloaded again when a program loads them",
                    paths: AIModelCaches.paths, selectedByDefault: false, shellFolders: AIModelCaches.shellFolders,
                    showsWhenEmpty: false, skipsOpenFiles: true, entryLabel: AIModelCaches.label(of:),
                    selectableEntries: true, allowsEntry: AIModelCaches.allows),
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

    /// `hasFullDiskAccess`: OneDrive's folders (other apps' containers) and Dropbox folders in privacy-protected places
    /// are only read with it.
    /// `runningApps` and `isUpdating`: see `SparkleDownloads.item`.
    nonisolated static func applications(hasFullDiskAccess: Bool = false,
                                         runningApps: @escaping @Sendable () -> Set<String> = { [] },
                                         isUpdating: @escaping @Sendable () -> Bool = { false }) -> CleanerGroup {
        CleanerGroup(id: "applications", title: "Applications", systemImage: "macwindow", items: [
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
        // Zoom's own updater keeps the installers it downloaded (one per version, often hundreds of MB); Zoom
        // downloads the next one when it updates. Skipped while Zoom runs or an installer is open.
        CleanerItem(id: "zoom-updates", title: "Zoom: downloaded updates",
                    note: "Installers Zoom downloaded to update itself; downloaded again if needed",
                    paths: ["~/Library/Application Support/zoom.us/AutoUpdater"], showsWhenEmpty: false,
                    runningAppBundleIDs: ["us.zoom.xos"], skipsOpenFiles: true),
        // Microsoft AutoUpdate (Office, Edge, Teams…): update downloads and update info it caches per user; the
        // packages it installs from live in /Library (root's, never touched). Skipped while it or its daemon runs.
        CleanerItem(id: "microsoft-autoupdate", title: "Microsoft AutoUpdate cache",
                    note: "Update downloads and update information; downloaded again if needed",
                    paths: ["~/Library/Caches/com.microsoft.autoupdate2", "~/Library/Caches/com.microsoft.autoupdate.fba"],
                    showsWhenEmpty: false, runningAppBundleIDs: ["com.microsoft.autoupdate2", "com.microsoft.autoupdate*"],
                    runningProcessNames: ["Microsoft AutoUpdate", "Microsoft AU Daemon", "Microsoft Update Assistant",
                                          "msupdate"],
                    skipsOpenFiles: true),
        // Updates apps downloaded with Sparkle, one entry per app (`SparkleDownloads`).
        SparkleDownloads.item(runningApps: runningApps, isUpdating: isUpdating),

        app("vscode", "Visual Studio Code", bundle: ["com.microsoft.VSCode"],
            vscode("Code") + ["~/Library/Caches/com.microsoft.VSCode"]),
        // Per-project state of VS Code and its forks for project folders since deleted (`EditorWorkspaces`).
        EditorWorkspaces.item(),
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
        // Media cache Premiere Pro, After Effects, Media Encoder and Audition share: conformed audio, peak files and
        // the cache database, often tens of GB, rebuilt from the source media when a project opens. Only these three
        // folders at the default location (a folder chosen in Premiere's Preferences › Media Cache is not scanned),
        // never the rest of Adobe/Common, preferences or projects. Unticked (the next open is slower), deleted
        // (regenerable), the folders made again by the app. Skipped while an app using the cache runs; Creative Cloud
        // and its helpers (`AdobeIPCBroker`, `CCXProcess`) run all the time and never touch it.
        CleanerItem(id: "adobe-media-cache", title: "Adobe media cache",
                    note: "Premiere rebuilds it when a project is opened; the first open is slower",
                    paths: ["~/Library/Application Support/Adobe/Common"],
                    included: ["Media Cache Files", "Media Cache", "Peak Files"], selectedByDefault: false,
                    showsWhenEmpty: false, runningAppBundleIDs: adobeMediaBundleIDs,
                    runningProcessNames: adobeMediaProcessNames, skipsOpenFiles: true),
        // Final Cut Pro and iMovie render files (`VideoRenderFiles`): one entry per library, unticked, deleted.
        VideoRenderFiles.item(hasFullDiskAccess: { hasFullDiskAccess }),
        // Cloud sync apps' caches (`CloudSyncCaches`): unticked, deleted, skipped while the app runs.
        CloudSyncCaches.googleDrive,
        CloudSyncCaches.dropbox(hasFullDiskAccess: { hasFullDiskAccess }),
        // Media caches outside ~/Library/Caches (`MediaAppCaches`): unticked, deleted, skipped while the app runs.
        MediaAppCaches.spotify,
    ] + (hasFullDiskAccess ? [CloudSyncCaches.oneDrive, MediaAppCaches.telegram] + MediaAppCaches.podcasts : []))
    }

    /// Adobe apps that read and write the media cache. Bundle ids and executables carry the version
    /// (`com.adobe.PremierePro.25`, `Adobe Premiere Pro 2025`), hence the prefixes; `aerender` renders After Effects
    /// projects from the command line.
    nonisolated static let adobeMediaBundleIDs = [
        "com.adobe.Premiere*", "com.adobe.AfterEffects*", "com.adobe.ame*", "com.adobe.Audition*",
        "com.adobe.Character*", "com.adobe.Rush*",
    ]
    nonisolated static let adobeMediaProcessNames = [
        "Adobe Premiere*", "After Effects*", "Adobe After Effects*", "aerender", "Adobe Media Encoder*",
        "Adobe Audition*", "Character Animator*", "Adobe Character Animator*",
    ]

    /// `~/Library/Caches` paths owned by a separate item (`Google/Chrome`, `Homebrew`), kept out of "User caches"
    /// so nothing is counted twice; the rest of their top folder (`Google/…`) is still listed. Cut at a `*`.
    /// "Old IDE versions" is left out: it would own all of `Google`; `skipsUserCache` keeps its folders instead.
    nonisolated static let ownedCachePaths = Set([developer, aiTools(), applications()].flatMap(\.items)
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

    nonisolated private static let orca = "~/Library/Application Support/orca"
    nonisolated private static let zcode = "~/Library/Application Support/ZCode/session"
    nonisolated private static let cursorBundle = "com.todesktop.230313mzl4w4u92"
    nonisolated private static let windsurfBundle = "com.exafunction.windsurf"
    /// Codeium's language server, started by Windsurf and by the Codeium extensions of other editors.
    nonisolated private static let codeiumServers = ["language_server_macos_arm", "language_server_macos_x64"]

    /// `item`, also skipped while a command-line process with one of these names runs (a background helper).
    nonisolated private static func running(_ item: CleanerItem, processes: [String]) -> CleanerItem {
        var item = item
        item.runningProcessNames = processes
        return item
    }

    /// App names are not translated.
    nonisolated private static func app(_ id: String, _ name: String, bundle: [String], _ paths: [String]) -> CleanerItem {
        CleanerItem(id: id, title: LocalizedStringResource(String.LocalizationValue(name)),
                    note: "Caches only; sign-ins, history and settings are kept", paths: paths,
                    showsWhenEmpty: false, runningAppBundleIDs: bundle)
    }

    /// `openFiles`: keep an entry holding a file a process has open; only for items with a few roots (the
    /// open-file table is read once per root).
    nonisolated private static func cache(_ id: String, _ name: String, _ paths: [String],
                                          excluded: Set<String> = [], apps: [String] = [], processes: [String] = [],
                                          openFiles: Bool = false) -> CleanerItem {
        CleanerItem(id: id, title: "\(name): cache & logs",
                    note: "Recreated as needed; sign-ins, settings and memory are kept", paths: paths,
                    excluded: excluded, showsWhenEmpty: false, runningAppBundleIDs: apps, runningProcessNames: processes,
                    skipsOpenFiles: openFiles)
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
