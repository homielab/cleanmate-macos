import Foundation
import os
import Testing
@testable import CleanMate

/// End-to-end safety: builds a fake home with junk for every Smart Scan + Privacy item that has paths, plus
/// bait that must never be touched, then really scans and cleans *every* item (ticked by default or not).
/// Never touches the real home or Trash and runs no external tool (only /usr/bin/sqlite3 on fake databases
/// and /usr/bin/true as a stub size probe): `command`s are removed and probes are stubbed.
struct EndToEndCleanTests {
    /// Bait: path in the fake home → content. Must survive byte for byte.
    static let bait = [
        ".ssh/id_ed25519", ".ssh/config", ".gnupg/pubring.kbx", "Library/Keychains/login.keychain-db",
        "Documents/report.txt", "Desktop/notes.txt",
        // A video library's media and databases next to its render files
        "Movies/junk-video-render-files.fcpbundle/CurrentVersion.flexolibrary/db",
        "Movies/junk-video-render-files.fcpbundle/Event/CurrentVersion.fcpevent",
        "Movies/junk-video-render-files.fcpbundle/Event/Original Media/clip.mov",
        "Movies/junk-video-render-files.fcpbundle/Event/Transcoded Media/clip.mov",
        // Browser bookmarks, passwords, extensions
        "Library/Safari/Bookmarks.plist",
        "Library/Application Support/Google/Chrome/Default/Bookmarks",
        "Library/Application Support/Google/Chrome/Default/Login Data",
        "Library/Application Support/Google/Chrome/Default/Extensions/abc/manifest.json",
        "Library/Application Support/Microsoft Edge/Default/Bookmarks",
        "Library/Application Support/Google/Chrome Beta/Default/Login Data",
        "Library/Application Support/Google/Chrome Beta/Default/Bookmarks",
        "Library/Application Support/Firefox/Profiles/Default/logins.json",
        "Library/Application Support/Firefox/Profiles/Default/key4.db",
        // AI tool credentials, settings and memory
        ".claude/.credentials.json", ".claude/settings.json", ".claude/CLAUDE.md",
        ".claude/projects/Default/memory/MEMORY.md",
        ".codex/auth.json", ".codex/config.toml", ".gemini/oauth_creds.json", ".gemini/settings.json",
        ".config/github-copilot/hosts.json", ".ollama/id_ed25519", ".ollama/models/blob",
        ".ollama/models/blobs/sha256-" + String(repeating: "a", count: 64),
        // Orca's accounts, keys, profiles, history and session index next to its caches and logs
        "Library/Application Support/orca/agent-session-authority.key",
        "Library/Application Support/orca/orca-e2ee-keypair.json", "Library/Application Support/orca/Cookies",
        "Library/Application Support/orca/claude-accounts/a/auth.json",
        "Library/Application Support/orca/profiles/default/settings.json",
        "Library/Application Support/orca/terminal-history/1.log",
        "Library/Application Support/orca/ai-vault/session-search.sqlite",
        "Library/Application Support/orca/Partitions/orca-browser/Local Storage/leveldb/000003.log",
        // Windsurf, opencode and its forks (Kilo, MiMoCode), Cline and Cursor: logins, settings, chats, memories and
        // histories next to their junk
        ".codeium/windsurf/cascade/chat.pb", ".codeium/windsurf/memories/global.md", ".codeium/windsurf/user_settings.pb",
        ".codeium/windsurf/ws-browser-profile/Default/Cookies", ".codeium/windsurf/ws-browser-profile/Default/Login Data",
        ".codeium/windsurf/ws-browser-profile/Default/History", ".codeium/windsurf/skills/a/SKILL.md",
        ".local/share/opencode/auth.json", ".local/share/opencode/opencode.db", ".local/share/opencode/snapshot/a/HEAD",
        ".local/share/opencode/tool-output/a.txt",
        ".local/share/kilo/kilo.db", ".local/share/kilo/repos/r/HEAD", ".config/kilo/kilo.jsonc",
        ".local/share/mimocode/mimocode.db", ".local/share/mimocode/auth.json", ".local/share/mimocode/snapshot/a/HEAD",
        ".local/share/mimocode/builtin_skills/b/s/SKILL.md", ".local/state/mimocode/model.json",
        ".cline/data/secrets.json", ".cline/data/cache/user_input_history.jsonl", ".cline/data/db/sessions.db",
        ".cline/data/sessions/session_1/messages.json", ".cline/data/settings/providers.json",
        ".cursor/mcp.json", ".cursor/extensions/ext/package.json", ".cursor/ai-tracking/ai-code-tracking.db",
        ".cursor/projects/Default/terminals/1.txt", ".factory/settings.json",
        // OrbStack's keys, settings and machines next to its caches and logs
        ".orbstack/ssh/id_ed25519", ".orbstack/vmconfig.json", ".orbstack/config/docker.json",
        "Library/Group Containers/HUJDZ9NVLN.dev.orbstack/data/data.img",
        // ZCode's login, settings, task index, agent data and session history next to its caches and logs
        ".zcode/v2/credentials.json", ".zcode/v2/tasks-index.sqlite", ".zcode/cli/config.json", ".zcode/cli/db/state.db",
        ".zcode/cli/rollout/model-io-session_1.jsonl", ".zcode/cli/memories/m.md",
        "Library/Application Support/ZCode/session/Cookies", "Library/Application Support/ZCode/Preferences",
        // Firebase CLI login, other downloaded tools and a project's own log next to its debug logs
        ".config/configstore/firebase-tools.json", ".cache/firebase/crashlytics/buildtools/b.jar",
        ".cache/firebase/universal-maker/universal-maker", ".cache/firebase/extensions/a/1.0.0/extension.yaml",
        ".cache/firebase/other.log", "Developer/app/firebase-debug.log", "Developer/app/firebase.json",
        // Kept on purpose by catalog items
        "Library/Caches/com.apple.bird/state", "Library/Logs/CleanMate/activity.log",
        "Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.FavoriteItems.sfl3",
        // Found on a real home: unsent rclone uploads, a save in progress, Continue's selected models
        "Library/Caches/rclone/vfs/remote/unsent.txt", "Library/Caches/TemporaryItems/NSIRD_app/save.tmp",
        ".continue/index/globalContext.json",
        // Poetry's project virtualenvs live under its cache folder
        "Library/Caches/pypoetry/virtualenvs/app-AbC123-py3.12/bin/python",
        // Installed toolchains next to the download caches of nvm and rustup
        ".nvm/versions/node/v22.0.0/bin/node", ".rustup/toolchains/stable-aarch64-apple-darwin/bin/rustc",
        // The global Python and Ruby versions and the Go SDK in use next to old ones
        ".pyenv/versions/3.12.0/bin/python3", ".pyenv/shims/python3", ".rbenv/versions/3.3.0/bin/ruby", ".rbenv/shims/ruby",
        "sdk/go1.99.0/bin/go",
        // Torch kernels and hub repos, Keras settings and a sentence-transformers folder without a model next to models
        ".cache/torch/kernels/kernel.bin", ".cache/torch/hub/pytorch_vision_main/hubconf.py", ".keras/keras.json",
        ".cache/torch/sentence_transformers/plain/model.bin",
        "Developer/tools/TORCH_HOME/kernels/kernel.bin", "Developer/tools/KERAS_HOME/keras.json",
        // Hugging Face login next to its model cache
        ".cache/huggingface/token", ".cache/huggingface/stored_tokens",
        // Google Updater itself, its settings and logs next to its downloaded packages
        "Library/Application Support/Google/GoogleUpdater/157.0.8089.0/GoogleUpdater.app/Contents/MacOS/GoogleUpdater",
        "Library/Application Support/Google/GoogleUpdater/prefs.json",
        "Library/Application Support/Google/GoogleUpdater/updater.log",
        "Library/Application Support/Google/GoogleUpdater/updater_history.jsonl",
        // Newest and unversioned IDE folders next to old versions
        "Library/Application Support/JetBrains/GoLand2099.1/options/ide.general.xml",
        "Library/Caches/JetBrains/GoLand2099.1/index/data", "Library/Logs/JetBrains/GoLand2099.1/idea.log",
        "Library/Application Support/JetBrains/IntelliJServer/settings.json", "Library/Caches/JetBrains/Daemon/data",
        "Library/Application Support/Google/AndroidStudio2099.1/options/other.xml",
        "Library/Caches/Google/AndroidStudio2099.1/caches/data",
        // Android emulator data next to its quick-boot snapshots
        ".android/avd/Pixel.avd/userdata-qemu.img", ".android/avd/Pixel.avd/userdata-qemu.img.qcow2",
        ".android/avd/Pixel.avd/sdcard.img", ".android/avd/Pixel.avd/config.ini",
        ".android/avd/Pixel.avd/hardware-qemu.ini", ".android/avd/Pixel.ini",
        // The Android SDK next to system images no AVD uses: the image an AVD uses and the other SDK packages
        "Library/Android/sdk/system-images/android-35/google_apis/arm64-v8a/package.xml",
        "Library/Android/sdk/system-images/android-35/google_apis/arm64-v8a/system.img",
        "Library/Android/sdk/platforms/android-35/android.jar", "Library/Android/sdk/build-tools/35.0.0/aapt2",
        "Library/Android/sdk/ndk/27.1.12297006/source.properties", "Library/Android/sdk/emulator/emulator",
        // A user project, tool settings and app settings in their usual places
        "Developer/app/.git/config", "Developer/app/src/main.swift", "Developer/app/node_modules/x/index.js",
        "Developer/app/build/out.o", "Developer/app/.venv/bin/python", "Developer/app/target/debug/app",
        ".config/sometool/config", "Library/Application Support/ExampleApp/settings.json",
        "Library/Preferences/com.example.app.plist", ".zshrc", ".gitconfig", ".npmrc", ".cargo/config.toml",
        ".gradle/gradle.properties",
        // Tool data next to the junk in folders set by shell variables (`shellTools`)
        "Developer/tools/NVM_DIR/versions/node/v22.0.0/bin/node",
        "Developer/tools/RUSTUP_HOME/toolchains/stable-aarch64-apple-darwin/bin/rustc",
        "Developer/tools/PYENV_ROOT/versions/3.12.0/bin/python3", "Developer/tools/RBENV_ROOT/versions/3.3.0/bin/ruby",
        "Developer/tools/CARGO_HOME/config.toml", "Developer/tools/CARGO_HOME/bin/cargo",
        "Developer/tools/GRADLE_USER_HOME/gradle.properties", "Developer/tools/HF_HOME/token",
        "Developer/tools/HF_HUB_CACHE/version.txt", "Developer/tools/ANDROID_AVD_HOME/Pixel.avd/config.ini",
        "Developer/tools/ANDROID_AVD_HOME/Pixel.avd/userdata-qemu.img",
        "Developer/tools/ANDROID_EMULATOR_HOME/avd/Pixel.avd/config.ini",
        "Developer/tools/OLLAMA_MODELS/blobs/sha256-" + String(repeating: "b", count: 64),
    ]
    /// The image the bait AVDs use (bait itself, in the default SDK).
    static let avdConfig = Data("\nimage.sysdir.1=system-images/android-35/google_apis/arm64-v8a/\n".utf8)
    /// Every shell folder variable is set in the fake `.zprofile` to `~/Developer/tools/<NAME>`.
    static let shellTools = "~/Developer/tools/"

    /// A Firefox places.sqlite (real table and column names, WAL like Firefox): bookmark "Bank" (place 1) in
    /// folder "Work", keyword search (place 3), a page with a non-download annotation (place 5), visits on every
    /// page, a download (place 4, two `downloads/*` annotations), typed input and page metadata.
    static let firefoxPlaces = """
        PRAGMA journal_mode=WAL;
        CREATE TABLE moz_origins(id INTEGER PRIMARY KEY, prefix TEXT NOT NULL, host TEXT NOT NULL, frecency INTEGER NOT NULL, UNIQUE(prefix, host));
        CREATE TABLE moz_places(id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR, rev_host LONGVARCHAR, visit_count INTEGER DEFAULT 0, hidden INTEGER DEFAULT 0 NOT NULL, typed INTEGER DEFAULT 0 NOT NULL, frecency INTEGER DEFAULT -1 NOT NULL, last_visit_date INTEGER, guid TEXT, foreign_count INTEGER DEFAULT 0 NOT NULL, url_hash INTEGER DEFAULT 0 NOT NULL, origin_id INTEGER REFERENCES moz_origins(id));
        CREATE TABLE moz_historyvisits(id INTEGER PRIMARY KEY, from_visit INTEGER, place_id INTEGER, visit_date INTEGER, visit_type INTEGER, session INTEGER);
        CREATE TABLE moz_inputhistory(place_id INTEGER NOT NULL, input LONGVARCHAR NOT NULL, use_count INTEGER, PRIMARY KEY(place_id, input));
        CREATE TABLE moz_bookmarks(id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER DEFAULT NULL, parent INTEGER, position INTEGER, title LONGVARCHAR, guid TEXT);
        CREATE TABLE moz_keywords(id INTEGER PRIMARY KEY AUTOINCREMENT, keyword TEXT UNIQUE, place_id INTEGER, post_data TEXT);
        CREATE TABLE moz_anno_attributes(id INTEGER PRIMARY KEY, name VARCHAR(32) UNIQUE NOT NULL);
        CREATE TABLE moz_annos(id INTEGER PRIMARY KEY, place_id INTEGER NOT NULL, anno_attribute_id INTEGER, content LONGVARCHAR);
        CREATE TABLE moz_places_metadata(id INTEGER PRIMARY KEY, place_id INTEGER NOT NULL, referrer_place_id INTEGER, created_at INTEGER NOT NULL DEFAULT 0, search_query_id INTEGER);
        CREATE TABLE moz_places_metadata_search_queries(id INTEGER PRIMARY KEY, terms TEXT NOT NULL UNIQUE);
        INSERT INTO moz_origins VALUES(1,'https://','bank.example',1),(2,'https://','visited.example',1),(3,'https://','search.example',1),(4,'https://','note.example',1);
        INSERT INTO moz_places(id,url,visit_count,last_visit_date,origin_id) VALUES(1,'https://bank.example/',5,100,1),(2,'https://visited.example/',3,200,2),(3,'https://search.example/?q=%s',1,300,3),(4,'https://visited.example/file.zip',1,400,2),(5,'https://note.example/',0,NULL,4);
        INSERT INTO moz_historyvisits VALUES(1,0,1,100,1,0),(2,0,2,200,1,0),(3,0,3,300,1,0),(4,0,4,400,7,0);
        INSERT INTO moz_inputhistory VALUES(2,'vis',1);
        INSERT INTO moz_bookmarks VALUES(1,2,NULL,0,0,'',  'root________'),(2,2,NULL,1,0,'Work','folder'),(3,1,1,2,0,'Bank','bm');
        INSERT INTO moz_keywords(keyword,place_id) VALUES('s',3);
        INSERT INTO moz_anno_attributes VALUES(1,'downloads/destinationFileURI'),(2,'downloads/metaData'),(3,'note/kept');
        INSERT INTO moz_annos VALUES(1,4,1,'file:///x.zip'),(2,4,2,'{}'),(3,5,3,'keep');
        INSERT INTO moz_places_metadata VALUES(1,2,NULL,200,1);
        INSERT INTO moz_places_metadata_search_queries VALUES(1,'secret');
        """

    @Test func cleaningEveryItemRemovesOnlyItsJunk() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "CleanMateE2E-\(UUID().uuidString)")
        let home = root.appending(path: "home"), temp = root.appending(path: "tmp"), trash = root.appending(path: "Trash")
        // Hard guard: everything happens inside a fresh temp folder, never in the real home.
        let realHome = (NSHomeDirectory() as NSString).resolvingSymlinksInPath
        let resolvedRoot = (root.path as NSString).resolvingSymlinksInPath
        try #require(resolvedRoot.hasPrefix((fm.temporaryDirectory.path as NSString).resolvingSymlinksInPath + "/"))
        try #require(!resolvedRoot.hasPrefix(realHome + "/") && !fm.fileExists(atPath: root.path))
        defer { try? fm.removeItem(at: root) }
        for dir in [home, temp, trash] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        let policy = SafetyPolicy(home: home, temp: temp)
        try #require(policy.homeURL.path.hasPrefix(root.path))

        let old = Date.now.addingTimeInterval(-400 * 86_400)
        func write(_ url: URL, _ data: Data) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }

        // Every item that has paths, commands removed, probes stubbed to report only this item's junk.
        let items = (CleanerGroup.smartScan(ages: .default, hasFullDiskAccess: true) + CleanerGroup.privacy).flatMap(\.items)
            .filter { !$0.paths.isEmpty }.map { item in
                // Projects are dated up to the fake home, and no real node process counts.
                var item = Self.ownOpenFiles(item.id == "stale-node-modules"
                    ? StaleNodeModules.item(home: home, hasFullDiskAccess: { true }, running: { [] })
                    : item.id == "stale-build-dirs"
                    ? StaleBuildFolders.item(home: home, hasFullDiskAccess: { true }, running: { [] })
                    : item.id == "vscode-stale-workspaces" ? EditorWorkspaces.item(home: home, hasFullDiskAccess: { true }) : item)
                item.command = nil
                if item.probe != nil {
                    let junk = "junk-" + item.id
                    item.probe = SizeProbe(command: ShellCommand(executable: "/usr/bin/true"), parse: { _ in .only([junk]) })
                }
                return item
            }
        #expect(items.count > 80)
        #expect(items.filter { !$0.shellFolders.isEmpty }.count >= 6)

        // Junk: each path made concrete (leading `*` → "Default", so `*.avd` → "Default.avd"; other `*` removed)
        // gets one entry per included pattern, or a folder.
        for item in items {
            let shellPaths = item.shellFolders.flatMap { name, subs in subs.map { Self.shellTools + name + ($0.isEmpty ? "" : "/" + $0) } }
            for path in item.paths + shellPaths {
                let concrete = path.split(separator: "/", omittingEmptySubsequences: false)
                    .map { $0.hasPrefix("*") ? "Default" + $0.dropFirst() : $0.replacingOccurrences(of: "*", with: "") }.joined(separator: "/")
                let folder = policy.expand(concrete)
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                if item.id == "group-caches" { // a group with no known creator is never cleaned
                    try (["MCMMetadataCreator": "com.example.app"] as NSDictionary).write(to: folder
                        .deletingLastPathComponent().deletingLastPathComponent().appending(path: ".com.apple.containermanagerd.metadata.plist"))
                }
                if item.id == VideoRenderFiles.id { // a library in each folder: only its render files go
                    try write(folder.appending(path: "junk-\(item.id).fcpbundle/Event/Render Files/r.mov"),
                              Data(repeating: 1, count: 4096))
                    continue
                }
                if item.findEntries != nil { // a stale project in each folder: only its node_modules or target goes
                    let project = folder.appending(path: "junk-\(item.id)")
                    let (manifest, built) = item.id == "stale-build-dirs" ? ("Cargo.toml", "target") : ("package.json", "node_modules")
                    try write(project.appending(path: manifest), Data("{}".utf8))
                    try write(project.appending(path: built + "/dep/index.js"), Data(repeating: 1, count: 4096))
                    for url in [project.appending(path: built + "/dep"), project.appending(path: built)] {
                        try fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
                    }
                    continue
                }
                if item.id == OldScreenshots.id { // an old screenshot on the Desktop
                    let shot = folder.appending(path: "Screenshot 2020-01-01 at 10.00.00.png")
                    try write(shot, Data(repeating: 1, count: 4096))
                    try OldDownloadsTests.stamp(shot, modified: old, read: old, created: old, added: old)
                    continue
                }
                if item.id == AbandonedDownloads.id { // a download Chrome gave up on long ago
                    let part = folder.appending(path: "junk.dmg.crdownload")
                    try write(part, Data(repeating: 1, count: 4096))
                    try OldDownloadsTests.stamp(part, modified: old, read: old, created: old, added: old)
                    continue
                }
                if item.id == OldRuntimes.nodeID { // a Node version other than nvm's default (v22.0.0, bait)
                    try write(folder.appending(path: "v1.0.0/bin/node"), Data(repeating: 1, count: 4096))
                    continue
                }
                if item.id == OldRuntimes.goID { // a Go SDK other than the one in use (go1.99.0, bait)
                    try write(folder.appending(path: "go1.0.0/bin/go"), Data(repeating: 1, count: 4096))
                    continue
                }
                if item.id == AIModelCaches.id { // a model of the library this folder belongs to
                    let path = folder.path
                    let junk = path.hasSuffix("/checkpoints") ? "junk.pth"
                        : path.hasSuffix("/whisper") ? "junk.pt"
                        : path.hasSuffix("sentence_transformers") || path.hasSuffix("SENTENCE_TRANSFORMERS_HOME") ? "junk/modules.json"
                        : "models/junk.h5"
                    try write(folder.appending(path: junk), Data(repeating: 1, count: 4096))
                    continue
                }
                if item.id == AndroidSystemImages.id { // an installed image no AVD uses
                    try write(folder.appending(path: "junk-\(item.id)/package.xml"), Data("<package/>".utf8))
                    try write(folder.appending(path: "junk-\(item.id)/system.img"), Data(repeating: 1, count: 4096))
                    continue
                }
                if item.id == "vscode-stale-workspaces" { // workspace data of a project folder that is gone
                    let gone = URL(fileURLWithPath: home.appending(path: "gone-project").path).absoluteString
                    try write(folder.appending(path: "junk-\(item.id)/workspace.json"), Data(#"{"folder":"\#(gone)"}"#.utf8))
                    try write(folder.appending(path: "junk-\(item.id)/state.vscdb"), Data(repeating: 1, count: 4096))
                    continue
                }
                guard let included = item.included else {
                    // Old IDE versions only lists a version older than the newest (bait above) of its product.
                    let name = item.id != "old-ide-versions" ? "junk-\(item.id)"
                        : folder.lastPathComponent == "Google" ? "AndroidStudio2020.1" : "GoLand2020.1"
                    try write(folder.appending(path: "\(name)/data.bin"), Data(repeating: 1, count: 4096))
                    try fm.setAttributes([.modificationDate: old], ofItemAtPath: folder.appending(path: name).path)
                    if item.id == "old-downloads" { // also created, added and read long ago
                        for path in ["\(name)/data.bin", name] {
                            try OldDownloadsTests.stamp(folder.appending(path: path), modified: old, read: old, created: old, added: old)
                        }
                    }
                    continue
                }
                for pattern in included {
                    let url = folder.appending(path: pattern.replacingOccurrences(of: "*", with: "x"))
                    if item.database != nil, pattern == "places.sqlite" {
                        try? fm.removeItem(at: url)
                        _ = try await sqlite(url, Self.firefoxPlaces)
                    } else if item.database?.applies(to: url) == true {
                        try? fm.removeItem(at: url)
                        _ = try await sqlite(url, """
                            CREATE TABLE urls(id); CREATE TABLE visits(id); INSERT INTO urls VALUES(1); INSERT INTO visits VALUES(1);
                            CREATE TABLE downloads(id); CREATE TABLE downloads_url_chains(id); CREATE TABLE autofill(id);
                            CREATE TABLE autofill_profiles(id); INSERT INTO downloads VALUES(1);
                            INSERT INTO downloads_url_chains VALUES(1); INSERT INTO autofill VALUES(1);
                            INSERT INTO autofill_profiles VALUES(1);
                            """)
                    } else if !fm.fileExists(atPath: url.path) {
                        try write(url, Data(repeating: 2, count: 4096))
                    }
                }
            }
        }
        var baitData: [String: Data] = [:]
        for path in Self.bait {
            // An AVD's settings name the image it uses: an AVD that can't be read would keep every system image.
            baitData[path] = Data("bait \(path)".utf8) + (path.hasSuffix(".avd/config.ini") ? Self.avdConfig : Data())
            try write(home.appending(path: path), baitData[path]!)
        }
        // AVD folders made for the snapshots item get their settings too, kept like bait.
        let tools = String(Self.shellTools.dropFirst(2))
        for avds in [".android/avd", tools + "ANDROID_AVD_HOME", tools + "ANDROID_EMULATOR_HOME/avd"] {
            for name in try fm.contentsOfDirectory(atPath: home.appending(path: avds).path) where name.hasSuffix(".avd") {
                let path = avds + "/" + name + "/config.ini"
                guard baitData[path] == nil else { continue }
                baitData[path] = Self.avdConfig
                try write(home.appending(path: path), Self.avdConfig)
            }
        }
        // nvm's default alias names the bait version: without one no Node version is listed.
        for nvm in [".nvm", tools + "NVM_DIR"] {
            let path = nvm + "/alias/default"
            baitData[path] = Data("v22.0.0\n".utf8)
            try write(home.appending(path: path), baitData[path]!)
        }
        // The version files of pyenv and rbenv and rustup's settings name the bait versions: without them none is listed.
        let defaults = [(".pyenv", "version", "3.12.0\n"), (tools + "PYENV_ROOT", "version", "3.12.0\n"),
                        (".rbenv", "version", "3.3.0\n"), (tools + "RBENV_ROOT", "version", "3.3.0\n"),
                        (".rustup", "settings.toml", "default_toolchain = \"stable-aarch64-apple-darwin\"\n"),
                        (tools + "RUSTUP_HOME", "settings.toml", "default_toolchain = \"stable-aarch64-apple-darwin\"\n")]
        for (root, name, text) in defaults {
            let path = root + "/" + name
            baitData[path] = Data(text.utf8)
            try write(home.appending(path: path), baitData[path]!)
        }
        // The profile puts the bait Go SDK on PATH.
        let profile = "export PATH=\"$HOME/sdk/go1.99.0/bin:$PATH\"\n" + ShellEnvironment.variables.sorted().map { "export \($0)=\(Self.shellTools)\($0)\n" }.joined()
        baitData[".zprofile"] = Data(profile.utf8)
        try write(home.appending(path: ".zprofile"), baitData[".zprofile"]!)
        // An old folder in the temp folder holding a socket/pipe of a running process (ssh-agent, VS Code): kept.
        let agent = temp.appending(path: "ssh-agent-old"), pipe = agent.appending(path: "agent.1")
        try fm.createDirectory(at: agent, withIntermediateDirectories: true)
        try #require(mkfifo(pipe.path, 0o600) == 0)
        for url in [pipe, agent] { try fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path) }

        // Scan everything in parallel first, then clean everything one by one, like the app (sequential scans
        // doubled the suite's time).
        func scanAll() async -> [String: ItemScan] {
            await withTaskGroup(of: (String, ItemScan).self) { group in
                for item in items { group.addTask { (item.id, await Scanner.scan(item, policy: policy, openPaths: Self.ownOpenPaths)) } }
                return await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
            }
        }
        let scans = await scanAll()
        for item in items {
            let scan = scans[item.id]!
            #expect(scan.hasData && !scan.entries.isEmpty, "nothing found for \(item.id)")
            #expect(!scan.permissionDenied, "\(item.id)")
            if !item.shellFolders.isEmpty { // junk in the folders set in .zprofile is found too
                #expect(scan.entries.contains { $0.url.path.contains("/Developer/tools/") }, "\(item.id): shell folder not scanned")
            }
        }
        let moveToFakeTrash: @Sendable (URL) throws -> URL? = { url in
            let target = trash.appending(path: UUID().uuidString)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }
        for item in items {
            let scan = scans[item.id]!
            let report = await Cleaner.clean(item, scan: scan, policy: policy, trash: moveToFakeTrash, openPaths: Self.ownOpenPaths)
            #expect(report.skipped == 0, "\(item.id) skipped \(report.skipped)")
            // Freed = the scanned size of what went (a database erase: how much the file shrank), never negative.
            #expect(report.freed >= 0 && report.upTo == (item.sizeIsUpperBound ? report.freed : 0), "\(item.id)")
            if item.database == nil { #expect(report.freed == scan.size, "\(item.id) freed \(report.freed) of \(scan.size)") }
        }

        // Junk gone: a rescan finds nothing for any item.
        let rescans = await scanAll()
        for item in items {
            let after = rescans[item.id]!
            #expect(after.entries.isEmpty, "\(item.id) left \(after.entries.map(\.url.lastPathComponent))")
        }
        // Trash-mode entries are in the fake Trash.
        let trashed = items.filter { $0.mode == .trash }.reduce(0) { $0 + scans[$1.id]!.entries.count }
        #expect(trashed > 0)
        #expect(try fm.contentsOfDirectory(atPath: trash.path).count == trashed)
        #expect(fm.fileExists(atPath: pipe.path), "running process's pipe removed")
        // Bait intact, byte for byte.
        for (path, data) in baitData {
            #expect(fm.contents(atPath: home.appending(path: path).path) == data, "bait changed: \(path)")
        }
        // Databases are kept; only the erased records are gone.
        let webData = home.appending(path: "Library/Application Support/Google/Chrome/Default/Web Data")
        #expect(try await sqlite(webData, "SELECT count(*) FROM autofill; SELECT count(*) FROM autofill_profiles;") == "0\n1")
        let betaWebData = home.appending(path: "Library/Application Support/Google/Chrome Beta/Default/Web Data")
        #expect(try await sqlite(betaWebData, "SELECT count(*) FROM autofill; SELECT count(*) FROM autofill_profiles;") == "0\n1")
        let history = home.appending(path: "Library/Application Support/Google/Chrome/Default/History")
        #expect(try await sqlite(history, "SELECT count(*) FROM visits; SELECT count(*) FROM urls;") == "0\n0")
        // Firefox: history and downloads gone, bookmarks (with their URL), folders and keywords kept.
        let places = home.appending(path: "Library/Application Support/Firefox/Profiles/Default/places.sqlite")
        #expect(try await sqlite(places, """
            SELECT count(*) FROM moz_historyvisits; SELECT group_concat(url, ' ') FROM moz_places;
            SELECT group_concat(b.title, ',') FROM moz_bookmarks b LEFT JOIN moz_places p ON p.id = b.fk;
            SELECT url FROM moz_bookmarks JOIN moz_places p ON p.id = fk;
            """) == "0\nhttps://bank.example/ https://search.example/?q=%s https://note.example/\n,Work,Bank\nhttps://bank.example/")
    }

    /// A whole Smart Scan clean of files of known size: "Freed" is their total (what went to the Trash included and
    /// shown apart), whatever the volume's free space did meanwhile, and the activity log records the same bytes.
    @MainActor @Test func freedIsTheSizeOfWhatWasRemovedNotTheFreeSpaceChange() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "CleanMateFreed-\(UUID().uuidString)")
        let home = root.appending(path: "home"), temp = root.appending(path: "tmp"), trash = root.appending(path: "Trash")
        defer { try? fm.removeItem(at: root) }
        for dir in [home, temp, trash] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        let policy = SafetyPolicy(home: home, temp: temp)
        // Whole 4 KB blocks of non-zero bytes: the allocated size the scan measures is exactly the byte count.
        let files = ["Library/Caches/junk/a.bin": 40_960, "Library/Caches/junk/b.bin": 81_920, "Library/Caches/old/c.bin": 16_384]
        for (path, bytes) in files {
            let url = home.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 7, count: bytes).write(to: url)
        }
        let deleted = CleanerItem(id: "freed-delete", title: "Junk", paths: ["~/Library/Caches/junk"])
        let trashed = CleanerItem(id: "freed-trash", title: "Old", paths: ["~/Library/Caches/old"], mode: .trash)
        let model = SmartScanModel(module: .smartScan) {
            [CleanerGroup(id: "a", title: "A", systemImage: "x", items: [deleted]),
             CleanerGroup(id: "b", title: "B", systemImage: "x", items: [trashed])]
        }
        model.processNames = { [] }
        model.appBundleIDs = { [] }
        model.blockedByExclusion = { _ in false }
        model.scanItem = { await Scanner.scan($0, policy: policy, openPaths: $1) }
        model.cleanItem = { item, scan, _ in
            await Cleaner.clean(item, scan: scan, policy: policy, trash: { url in
                let target = trash.appending(path: UUID().uuidString)
                try FileManager.default.moveItem(at: url, to: target)
                return target
            })
        }
        model.logHome = home
        // Free space dropped during the clean (another app wrote more than was removed).
        var reads: [Int64] = [5_000_000_000, 4_999_000_000]
        model.freeSpace = { reads.isEmpty ? nil : reads.removeFirst() }

        await model.scan()
        #expect(model.selected == [deleted.id, trashed.id])
        await model.clean()
        guard case .done(let report) = model.phase else { Issue.record("phase \(model.phase)"); return }
        #expect(report.freed == 139_264 && report.upTo == 0 && report.skipped == 0)
        #expect(model.cleanedGroups.map(\.freed) == [122_880, 16_384])
        #expect(model.cleanedGroups.map(\.trashed) == [0, 16_384])
        #expect(model.freeSpaceChange == .init(before: 5_000_000_000, after: 4_999_000_000))
        #expect(files.keys.allSatisfy { !fm.fileExists(atPath: home.appending(path: $0).path) })
        let logged = ActivityLog.freed(home: home)
        #expect(logged.deleted == 122_880 && logged.trashed == 16_384)
    }

    /// Mail attachment copies: only with Full Disk Access, unticked, trash mode, skipped while Mail runs; only old
    /// entries of Mail Downloads (container and legacy path) go to the (fake) Trash, Mail's messages and the rest stay.
    @Test func mailDownloadsOnlyWithFullDiskAccess() async throws {
        #expect(!CleanerGroup.smartScan(ages: .default, hasFullDiskAccess: false).flatMap(\.items).contains { $0.id == "mail-downloads" })
        let item = try #require(CleanerGroup.smartScan(ages: .default, hasFullDiskAccess: true).flatMap(\.items)
            .first { $0.id == "mail-downloads" })
        #expect(item.mode == .trash && !item.selectedByDefault && item.runningAppBundleIDs == ["com.apple.mail"])

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "CleanMateE2E-\(UUID().uuidString)")
        let home = root.appending(path: "home")
        try #require(!(root.path as NSString).resolvingSymlinksInPath.hasPrefix((NSHomeDirectory() as NSString).resolvingSymlinksInPath + "/"))
        defer { try? fm.removeItem(at: root) }
        let policy = SafetyPolicy(home: home, temp: root.appending(path: "tmp"))
        let old = Date.now.addingTimeInterval(-400 * 86_400)
        func write(_ path: String, date: Date = old) throws {
            let url = home.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("data \(path)".utf8).write(to: url)
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        let container = "Library/Containers/com.apple.mail/Data/Library/"
        let junk = [container + "Mail Downloads/1A2B/invoice.pdf", "Library/Mail Downloads/old.zip"]
        let bait = [container + "Mail Downloads/9F8E/opened-today.pdf", "Library/Mail/V10/INBOX.mbox/Messages/1.emlx",
                    "Downloads/invoice.pdf"]
        for path in junk { try write(path) }
        // A folder's own date counts too: Mail's per-message folder is as old as the copy inside.
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: home.appending(path: container + "Mail Downloads/1A2B").path)
        for path in bait { try write(path, date: .now) }
        try write(container + "Caches/com.apple.mail/Cache.db") // old, but not Mail Downloads

        let scan = await Scanner.scan(item, policy: policy, openPaths: Self.ownOpenPaths)
        #expect(Set(scan.entries.map(\.url.lastPathComponent)) == ["1A2B", "old.zip"])
        let trash = root.appending(path: "Trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        #expect(await Cleaner.clean(item, scan: scan, policy: policy, trash: { url in
            let target = trash.appending(path: UUID().uuidString)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }, openPaths: Self.ownOpenPaths).skipped == 0)
        #expect(try fm.contentsOfDirectory(atPath: trash.path).count == 2)
        #expect(await Scanner.scan(item, policy: policy, openPaths: Self.ownOpenPaths).entries.isEmpty)
        for path in bait + [container + "Caches/com.apple.mail/Cache.db"] {
            #expect(fm.fileExists(atPath: home.appending(path: path).path), "bait gone: \(path)")
        }
    }

    /// iPhone/iPad backups: only with Full Disk Access, unticked, Trash, skipped while a backup runs; each old
    /// backup folder is one entry named from its Info.plist; a backup written in the last hour and .DS_Store stay.
    @Test func deviceBackupsOnlyWithFullDiskAccess() async throws {
        #expect(!CleanerGroup.smartScan(ages: .default, hasFullDiskAccess: false).flatMap(\.items).contains { $0.id == "device-backups" })
        let item = try #require(CleanerGroup.smartScan(ages: .default, hasFullDiskAccess: true).flatMap(\.items)
            .first { $0.id == "device-backups" })
        #expect(item.paths == ["~/Library/Application Support/MobileSync/Backup"])
        #expect(item.mode == .trash && !item.selectedByDefault && item.minAge == 3600)
        #expect(item.runningProcessNames.contains("AppleMobileBackup"))

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "CleanMateE2E-\(UUID().uuidString)")
        let home = root.appending(path: "home")
        try #require(!(root.path as NSString).resolvingSymlinksInPath.hasPrefix((NSHomeDirectory() as NSString).resolvingSymlinksInPath + "/"))
        defer { try? fm.removeItem(at: root) }
        let policy = SafetyPolicy(home: home, temp: root.appending(path: "tmp"))
        let backups = home.appending(path: "Library/Application Support/MobileSync/Backup")
        let old = Date.now.addingTimeInterval(-400 * 86_400), backedUp = Date(timeIntervalSince1970: 1_700_000_000)
        func backup(_ udid: String, date: Date) throws {
            let folder = backups.appending(path: udid)
            try fm.createDirectory(at: folder.appending(path: "ab"), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 8192).write(to: folder.appending(path: "ab/abcdef"))
            try (["Device Name": "Old iPhone", "Product Type": "iPhone10,3", "Last Backup Date": backedUp] as NSDictionary)
                .write(to: folder.appending(path: "Info.plist"))
            for path in ["ab/abcdef", "ab", "Info.plist", ""] {
                try fm.setAttributes([.modificationDate: date], ofItemAtPath: folder.appending(path: path).path)
            }
        }
        try backup("00008030-OLD", date: old)
        try backup("00008110-NOW", date: .now) // a backup in progress or just made
        try Data("finder".utf8).write(to: backups.appending(path: ".DS_Store"))

        let scan = await Scanner.scan(item, policy: policy, openPaths: Self.ownOpenPaths)
        let entry = try #require(scan.entries.first)
        #expect(scan.entries.count == 1 && entry.url.lastPathComponent == "00008030-OLD")
        #expect(entry.title == "Old iPhone (iPhone10,3)" && entry.date == backedUp)
        let trash = root.appending(path: "Trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        #expect(await Cleaner.clean(item, scan: scan, policy: policy, trash: { url in
            let target = trash.appending(path: UUID().uuidString)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }, openPaths: Self.ownOpenPaths).skipped == 0)
        #expect(try fm.contentsOfDirectory(atPath: trash.path).count == 1)
        #expect(try Set(fm.contentsOfDirectory(atPath: backups.path)) == ["00008110-NOW", ".DS_Store"])
    }

    /// Info.plist of a backup: device name + product type and date; fallbacks; nil when unusable.
    @Test func deviceBackupLabel() throws {
        func plist(_ info: [String: Any]) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
        }
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        let full = try #require(MobileBackups.label(fromInfoPlist: plist(["Device Name": "Minh’s iPad ",
            "Product Type": "iPad13,1", "Last Backup Date": date, "Display Name": "x"])))
        #expect(full.title == "Minh’s iPad (iPad13,1)" && full.date == date)
        #expect(MobileBackups.label(fromInfoPlist: try plist(["Display Name": "Phone"]))?.title == "Phone")
        #expect(MobileBackups.label(fromInfoPlist: try plist(["Product Type": "iPhone9,1"]))?.title == "iPhone9,1")
        #expect(MobileBackups.label(fromInfoPlist: try plist(["Device Name": "  ", "Last Backup Date": date])) == nil)
        #expect(MobileBackups.label(fromInfoPlist: Data("not a plist".utf8)) == nil)
        #expect(MobileBackups.label(fromInfoPlist: try plist(["Device Name": "A"]))?.date == nil)
    }

    /// Downloaded iOS/iPadOS updates: Finder folders always, Configurator's cache only with FDA; unticked, Trash,
    /// skipped while Finder/Configurator update a device; only `*.ipsw` is listed and cleaned, named by version.
    @Test func iosUpdatesOnlyIpsw() async throws {
        func item(fda: Bool) throws -> CleanerItem {
            try #require(CleanerGroup.smartScan(ages: .default, hasFullDiskAccess: fda).flatMap(\.items).first { $0.id == "ios-updates" })
        }
        #expect(try item(fda: false).paths == DeviceFirmware.finderFolders)
        let item = try item(fda: true)
        #expect(item.paths == DeviceFirmware.finderFolders + [DeviceFirmware.configuratorFolder])
        #expect(item.mode == .trash && !item.selectedByDefault && item.selectableEntries && !item.showsWhenEmpty)
        #expect(item.runningProcessNames.contains("AppleMobileDeviceHelper") && item.runningAppBundleIDs == ["com.apple.configurator.ui"])

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "CleanMateE2E-\(UUID().uuidString)")
        let home = root.appending(path: "home")
        try #require(!(root.path as NSString).resolvingSymlinksInPath.hasPrefix((NSHomeDirectory() as NSString).resolvingSymlinksInPath + "/"))
        defer { try? fm.removeItem(at: root) }
        let policy = SafetyPolicy(home: home, temp: root.appending(path: "tmp"))
        for path in item.paths { #expect(policy.allows(policy.expand(path).appending(path: "x.ipsw")), "\(path)") }
        let iphone = policy.expand(DeviceFirmware.finderFolders[0]), configurator = policy.expand(DeviceFirmware.configuratorFolder)
        try fm.createDirectory(at: iphone, withIntermediateDirectories: true)
        try fm.createDirectory(at: configurator, withIntermediateDirectories: true)
        for url in [iphone.appending(path: "iPhone15,2_18.1_22B83_Restore.ipsw"), configurator.appending(path: "iPad_Pro_17.0_21A329_Restore.ipsw"),
                    iphone.appending(path: "notes.txt"), iphone.appending(path: ".DS_Store"), configurator.appending(path: "x.ipsw.download")] {
            try Data(repeating: 1, count: 4096).write(to: url)
        }
        let scan = await Scanner.scan(item, policy: policy, openPaths: Self.ownOpenPaths)
        #expect(Set(scan.entries.map(\.title)) == ["iPhone · 18.1 (22B83)", "iPad · 17.0 (21A329)"])
        let trash = root.appending(path: "Trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        #expect(await Cleaner.clean(item, scan: scan, policy: policy, trash: { url in
            let target = trash.appending(path: UUID().uuidString)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }, openPaths: Self.ownOpenPaths).skipped == 0)
        #expect(try Set(fm.contentsOfDirectory(atPath: iphone.path)) == ["notes.txt", ".DS_Store"])
        #expect(try fm.contentsOfDirectory(atPath: configurator.path) == ["x.ipsw.download"])
    }

    @Test func iosUpdateLabel() {
        #expect(DeviceFirmware.label(fileName: "iPhone15,2_18.1_22B83_Restore.ipsw") == "iPhone · 18.1 (22B83)")
        #expect(DeviceFirmware.label(fileName: "iPad13,1_iPad13,2_17.4.1_21E237_Restore.ipsw") == "iPad · 17.4.1 (21E237)")
        #expect(DeviceFirmware.label(fileName: "iPhone16,1_18.0_22A5297f_Restore.ipsw") == "iPhone · 18.0 (22A5297f)")
        #expect(DeviceFirmware.label(fileName: "update.ipsw") == nil)
        #expect(DeviceFirmware.label(fileName: "iPhone_Restore.ipsw") == nil)
    }

    /// DerivedData and DeviceSupport list one tickable entry per project / OS version.
    @Test func xcodeEntryLabels() throws {
        let items = CleanerGroup.developer.items
        for id in ["xcode-derived-data", "xcode-device-support"] {
            let item = try #require(items.first { $0.id == id })
            #expect(item.selectableEntries && item.selectedByDefault && item.entryLabel != nil && item.command == nil)
        }
        #expect(XcodeData.projectName(fileName: "MyApp-fxvkpmzmhadblvcrrkwkvjsvuagj") == "MyApp")
        #expect(XcodeData.projectName(fileName: "My-App-fxvkpmzmhadblvcrrkwkvjsvuagj") == "My-App")
        #expect(XcodeData.projectName(fileName: "ModuleCache.noindex") == nil)
        #expect(XcodeData.projectName(fileName: "MyApp-short") == nil)
        #expect(XcodeData.deviceSupportLabel(fileName: "iPhone15,2 18.1 (22B83)", folder: "iOS DeviceSupport") == "iOS 18.1 (22B83)")
        #expect(XcodeData.deviceSupportLabel(fileName: "18.1 (22B83) arm64e", folder: "iOS DeviceSupport") == "iOS 18.1 (22B83)")
        #expect(XcodeData.deviceSupportLabel(fileName: "Watch6,1 10.0 (21R356)", folder: "watchOS DeviceSupport") == "watchOS 10.0 (21R356)")
        #expect(XcodeData.deviceSupportLabel(fileName: "Logs", folder: "iOS DeviceSupport") == nil)

        let root = FileManager.default.temporaryDirectory.appending(path: "CleanMate329-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appending(path: "MyApp-fxvkpmzmhadblvcrrkwkvjsvuagj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let used = Date(timeIntervalSince1970: 1_700_000_000)
        try PropertyListSerialization.data(fromPropertyList: ["WorkspacePath": NSHomeDirectory() + "/Dev/MyApp/MyApp.xcodeproj",
                                                              "LastAccessedDate": used], format: .xml, options: 0)
            .write(to: project.appending(path: "info.plist"))
        let label = try #require(XcodeData.derivedDataLabel(of: project))
        #expect(label.title == "MyApp · ~/Dev/MyApp/MyApp.xcodeproj" && label.date == used)
        #expect(XcodeData.derivedDataLabel(of: root.appending(path: "Other-fxvkpmzmhadblvcrrkwkvjsvuagj"))?.title == "Other")
        #expect(XcodeData.derivedDataLabel(of: root.appending(path: "ModuleCache.noindex"))?.title.hasPrefix("ModuleCache · ") == true)
    }

    /// Sandboxed app caches: without Full Disk Access nothing under ~/Library/Containers is in Smart Scan; with it,
    /// only `Data/Library/Caches` of containers that are not Apple's nor a running app's is cleaned.
    @Test func sandboxedCachesOnlyWithFullDiskAccess() async throws {
        let without = CleanerGroup.smartScan(ages: .default, hasFullDiskAccess: false).flatMap(\.items)
        #expect(!without.contains { $0.paths.contains { $0.contains("Containers") } })

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "CleanMateE2E-\(UUID().uuidString)")
        let home = root.appending(path: "home")
        try #require(!(root.path as NSString).resolvingSymlinksInPath.hasPrefix((NSHomeDirectory() as NSString).resolvingSymlinksInPath + "/"))
        defer { try? fm.removeItem(at: root) }
        let policy = SafetyPolicy(home: home, temp: root.appending(path: "tmp"))
        let containers = home.appending(path: "Library/Containers")
        func write(_ path: String) throws {
            let url = containers.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("data \(path)".utf8).write(to: url)
        }
        let junk = ["com.example.app/Data/Library/Caches/com.example.app/Cache.db", "com.example.app/Data/Library/Caches/blob.bin",
                    // iOS app: container named by UUID, bundle id only in containermanagerd's metadata
                    "0A1B2C3D-UUID/Data/Library/Caches/images/1.png"]
        let bait = ["com.example.app/Data/Documents/doc.txt", "com.example.app/Data/Library/Application Support/db.sqlite",
                    "com.example.app/Data/Library/Preferences/com.example.app.plist",
                    "com.example.app/Data/Library/Caches/TemporaryItems/save.tmp",
                    "com.apple.Notes/Data/Library/Caches/com.apple.Notes/Cache.db",
                    "com.example.running/Data/Library/Caches/Cache.db",
                    "com.example.running.helper/Data/Library/Caches/Cache.db", // helper of a running app
                    "com.example.ios-running-uuid/Data/Library/Caches/Cache.db"]
        for path in junk + bait { try write(path) }
        try (["MCMMetadataIdentifier": "com.example.ios"] as NSDictionary)
            .write(to: containers.appending(path: "0A1B2C3D-UUID/.com.apple.containermanagerd.metadata.plist"))
        let runningUUID = containers.appending(path: "com.example.ios-running-uuid/.com.apple.containermanagerd.metadata.plist")
        try (["MCMMetadataIdentifier": "com.example.ios.running"] as NSDictionary).write(to: runningUUID)

        let item = try #require(CleanerGroup.smartScan(ages: .default, hasFullDiskAccess: true, runningApps: {
            ["com.example.running", "com.example.ios.running"]
        }).flatMap(\.items).first { $0.id == "sandbox-caches" })
        let scan = await Scanner.scan(item, policy: policy, openPaths: Self.ownOpenPaths)
        #expect(Set(scan.entries.map { $0.url.pathComponents.suffix(5).joined(separator: "/") })
                == ["com.example.app/Data/Library/Caches/com.example.app", "com.example.app/Data/Library/Caches/blob.bin",
                    "0A1B2C3D-UUID/Data/Library/Caches/images"])
        #expect(await Cleaner.clean(item, scan: scan, policy: policy, openPaths: Self.ownOpenPaths).skipped == 0)
        for path in junk { #expect(!fm.fileExists(atPath: containers.appending(path: path).path), "\(path) left") }
        for path in bait {
            #expect(fm.contents(atPath: containers.appending(path: path).path) == Data("data \(path)".utf8), "bait changed: \(path)")
        }

        // An app launched between scan and clean keeps its caches.
        try write("com.example.app/Data/Library/Caches/again.bin")
        let rescan = await Scanner.scan(item, policy: policy, openPaths: Self.ownOpenPaths)
        let launched = try #require(CleanerGroup.smartScan(ages: .default, hasFullDiskAccess: true, runningApps: { ["com.example.app"] })
            .flatMap(\.items).first { $0.id == "sandbox-caches" })
        #expect(await Cleaner.clean(launched, scan: rescan, policy: policy, openPaths: Self.ownOpenPaths).skipped == 1)
        #expect(fm.fileExists(atPath: containers.appending(path: "com.example.app/Data/Library/Caches/again.bin").path))
    }

    /// User caches: the cache folder of a running app (bundle id or `<id>.helper`) is neither listed nor removed.
    @Test func userCachesSkipRunningApps() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "CleanMateE2E-\(UUID().uuidString)")
        let home = root.appending(path: "home")
        try #require(!(root.path as NSString).resolvingSymlinksInPath.hasPrefix((NSHomeDirectory() as NSString).resolvingSymlinksInPath + "/"))
        defer { try? fm.removeItem(at: root) }
        let policy = SafetyPolicy(home: home, temp: root.appending(path: "tmp"))
        let caches = home.appending(path: "Library/Caches")
        for path in ["com.example.app/c.db", "com.example.app.helper/c.db", "com.example.application/c.db",
                     "com.example.other/c.db", "SomeTool/c.db", "loose.bin"] {
            let url = caches.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(path.utf8).write(to: url)
        }
        func item(running: Set<String>) throws -> CleanerItem {
            try #require(CleanerGroup.smartScan(ages: .default, runningApps: { running }).flatMap(\.items).first { $0.id == "user-caches" })
        }
        let scan = await Scanner.scan(try item(running: ["com.Example.App"]), policy: policy, openPaths: Self.ownOpenPaths)
        #expect(Set(scan.entries.map(\.url.lastPathComponent))
                == ["com.example.application", "com.example.other", "SomeTool", "loose.bin"])

        // Launched between scan and clean: kept; once the app quits its caches are listed again.
        let all = await Scanner.scan(try item(running: []), policy: policy, openPaths: Self.ownOpenPaths)
        #expect(all.entries.count == 6)
        #expect(await Cleaner.clean(try item(running: ["com.example.app"]), scan: all, policy: policy, openPaths: Self.ownOpenPaths).skipped == 2)
        #expect(fm.fileExists(atPath: caches.appending(path: "com.example.app/c.db").path))
        #expect(fm.fileExists(atPath: caches.appending(path: "com.example.app.helper/c.db").path))
        #expect(!fm.fileExists(atPath: caches.appending(path: "SomeTool").path))
        #expect(await Scanner.scan(try item(running: []), policy: policy, openPaths: Self.ownOpenPaths).entries.count == 2)
    }

    /// User caches: a folder named like a running app (case-insensitive) is kept, unless the name is generic
    /// (`Electron`) or shorter than 4 characters; bundle ids still match as before.
    @Test func userCachesSkipRunningAppNames() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "CleanMateE2E-\(UUID().uuidString)")
        let home = root.appending(path: "home")
        try #require(!(root.path as NSString).resolvingSymlinksInPath.hasPrefix((NSHomeDirectory() as NSString).resolvingSymlinksInPath + "/"))
        defer { try? fm.removeItem(at: root) }
        let policy = SafetyPolicy(home: home, temp: root.appending(path: "tmp"))
        let caches = home.appending(path: "Library/Caches")
        for path in ["Foo Bar/c.db", "Electron/c.db", "Abc/c.db", "com.example.app/c.db", "Other/c.db"] {
            let url = caches.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(path.utf8).write(to: url)
        }
        func item(ids: Set<String>, names: Set<String>) throws -> CleanerItem {
            try #require(CleanerGroup.smartScan(ages: .default, runningAppNames: { names }, runningApps: { ids })
                .flatMap(\.items).first { $0.id == "user-caches" })
        }
        let scan = await Scanner.scan(try item(ids: ["com.example.app"], names: ["foo bar", "Electron", "Abc"]), policy: policy, openPaths: Self.ownOpenPaths)
        #expect(Set(scan.entries.map(\.url.lastPathComponent)) == ["Electron", "Abc", "Other"])

        // Launched between scan and clean: kept.
        let all = await Scanner.scan(try item(ids: [], names: []), policy: policy, openPaths: Self.ownOpenPaths)
        #expect(all.entries.count == 5)
        #expect(await Cleaner.clean(try item(ids: [], names: ["FOO BAR"]), scan: all, policy: policy, openPaths: Self.ownOpenPaths).skipped == 1)
        #expect(fm.fileExists(atPath: caches.appending(path: "Foo Bar/c.db").path))
        #expect(!fm.fileExists(atPath: caches.appending(path: "Electron/c.db").path))
    }

    /// Old temporary files: a running app's folder in $TMPDIR (bundle id or `<id>.*`) is neither listed nor removed.
    @Test func tempFilesSkipRunningApps() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "CleanMateE2E-\(UUID().uuidString)")
        let tmp = root.appending(path: "tmp")
        defer { try? fm.removeItem(at: root) }
        let policy = SafetyPolicy(home: root.appending(path: "home"), temp: tmp)
        for path in ["com.example.app/helper", "com.example.app.XPC/helper", "com.example.other/x", "loose.bin"] {
            let url = tmp.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(path.utf8).write(to: url)
        }
        func item(running: Set<String>) throws -> CleanerItem {
            try #require(CleanerGroup.smartScan(ages: CleanupAges(temp: 0), runningApps: { running }).flatMap(\.items).first { $0.id == "temp-files" })
        }
        let scan = await Scanner.scan(try item(running: ["com.Example.App"]), policy: policy, openPaths: Self.ownOpenPaths)
        #expect(Set(scan.entries.map(\.url.lastPathComponent)) == ["com.example.other", "loose.bin"])

        // Launched between scan and clean: kept.
        let all = await Scanner.scan(try item(running: []), policy: policy, openPaths: Self.ownOpenPaths)
        #expect(all.entries.count == 4)
        #expect(await Cleaner.clean(try item(running: ["com.example.app"]), scan: all, policy: policy, openPaths: Self.ownOpenPaths).skipped == 2)
        #expect(fm.fileExists(atPath: tmp.appending(path: "com.example.app/helper").path))
        #expect(fm.fileExists(atPath: tmp.appending(path: "com.example.app.XPC/helper").path))
        #expect(!fm.fileExists(atPath: tmp.appending(path: "loose.bin").path))
    }

    /// This process's open files only: any other process walking $TMPDIR (a scan, a backup) holds these
    /// tests' folders open for a moment, which the real check rightly counts. Every test scanning or cleaning an item
    /// that checks open files (`skipsOpenFiles`, Safari history) passes it.
    static let ownOpenPaths: @Sendable (String) -> Set<String> = { RunningProcesses.openPaths(under: $0, only: [getpid()]) }

    /// `item` with Safari history's open-file check reading this process only, like `ownOpenPaths`.
    static func ownOpenFiles(_ item: CleanerItem) -> CleanerItem {
        guard item.id == "safari-history" else { return item }
        var item = item
        item.skipsEntry = { { CleanerGroup.historyInUse($0, openPaths: ownOpenPaths) } }
        return item
    }

    /// An old $TMPDIR entry that is, or holds, a file a process has open (here: this test) is neither listed
    /// nor removed; once closed it is cleaned.
    @Test func tempFilesSkipOpenFiles() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "CleanMateE2E-\(UUID().uuidString)")
        let tmp = root.appending(path: "tmp")
        defer { try? fm.removeItem(at: root) }
        let policy = SafetyPolicy(home: root.appending(path: "home"), temp: tmp)
        let old = Date.now.addingTimeInterval(-30 * 86_400)
        for path in ["held/inner/open.bin", "open.bin", "closed.bin"] {
            let url = tmp.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(path.utf8).write(to: url)
        }
        for path in ["held/inner/open.bin", "held/inner", "held", "open.bin", "closed.bin"] {
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: tmp.appending(path: path).path)
        }
        let item = try #require(CleanerGroup.smartScan(ages: CleanupAges(temp: 1)).flatMap(\.items).first { $0.id == "temp-files" })
        let all = await Scanner.scan(item, policy: policy, openPaths: Self.ownOpenPaths)
        #expect(Set(all.entries.map(\.url.lastPathComponent)) == ["held", "open.bin", "closed.bin"])

        let handles = try ["held/inner/open.bin", "open.bin"].map { try FileHandle(forReadingFrom: tmp.appending(path: $0)) }
        let scan = await Scanner.scan(item, policy: policy, openPaths: Self.ownOpenPaths)
        #expect(Set(scan.entries.map(\.url.lastPathComponent)) == ["closed.bin"])
        // Opened between scan and clean: kept.
        #expect(await Cleaner.clean(item, scan: all, policy: policy, openPaths: Self.ownOpenPaths).skipped == 2)
        #expect(fm.fileExists(atPath: tmp.appending(path: "held/inner/open.bin").path))
        #expect(fm.fileExists(atPath: tmp.appending(path: "open.bin").path))
        #expect(!fm.fileExists(atPath: tmp.appending(path: "closed.bin").path))

        for handle in handles { try handle.close() }
        let after = await Scanner.scan(item, policy: policy, openPaths: Self.ownOpenPaths)
        #expect(after.entries.count == 2)
        #expect(await Cleaner.clean(item, scan: after, policy: policy, openPaths: Self.ownOpenPaths).skipped == 0)
        #expect(!fm.fileExists(atPath: tmp.appending(path: "held").path))
        #expect(!fm.fileExists(atPath: tmp.appending(path: "open.bin").path))
    }

    /// A user cache folder holding a file a process has open (a CLI daemon's cache) is neither listed nor removed.
    @Test func userCachesSkipOpenFiles() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "CleanMateE2E-\(UUID().uuidString)")
        let caches = root.appending(path: "home/Library/Caches")
        defer { try? fm.removeItem(at: root) }
        let policy = SafetyPolicy(home: root.appending(path: "home"), temp: root.appending(path: "tmp"))
        for path in ["com.example.daemon/db/open.bin", "com.example.idle/cache.bin"] {
            let url = caches.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(path.utf8).write(to: url)
        }
        let item = try #require(CleanerGroup.smartScan(ages: .default).flatMap(\.items).first { $0.id == "user-caches" })
        let all = await Scanner.scan(item, policy: policy, openPaths: Self.ownOpenPaths)
        #expect(Set(all.entries.map(\.url.lastPathComponent)) == ["com.example.daemon", "com.example.idle"])

        let handle = try FileHandle(forReadingFrom: caches.appending(path: "com.example.daemon/db/open.bin"))
        defer { try? handle.close() }
        #expect(await Scanner.scan(item, policy: policy, openPaths: Self.ownOpenPaths).entries.map(\.url.lastPathComponent) == ["com.example.idle"])
        // Opened between scan and clean: kept.
        #expect(await Cleaner.clean(item, scan: all, policy: policy, openPaths: Self.ownOpenPaths).skipped == 1)
        #expect(fm.fileExists(atPath: caches.appending(path: "com.example.daemon/db/open.bin").path))
        #expect(!fm.fileExists(atPath: caches.appending(path: "com.example.idle").path))
    }

    /// Cleaning 300 temp entries reads the open-file table once, not once per entry.
    @Test func tempFilesCleanReadsOpenFilesOnce() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "CleanMateE2E-\(UUID().uuidString)")
        let tmp = root.appending(path: "tmp")
        defer { try? fm.removeItem(at: root) }
        let policy = SafetyPolicy(home: root.appending(path: "home"), temp: tmp)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let old = Date.now.addingTimeInterval(-30 * 86_400)
        for i in 0..<300 {
            let url = tmp.appending(path: "f\(i).bin")
            try Data([1]).write(to: url)
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
        let item = try #require(CleanerGroup.smartScan(ages: CleanupAges(temp: 1)).flatMap(\.items).first { $0.id == "temp-files" })
        let scan = await Scanner.scan(item, policy: policy, openPaths: Self.ownOpenPaths)
        #expect(scan.entries.count == 300)
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let held = RunningProcesses.withoutPrivate(tmp.appending(path: "f7.bin").path)
        let start = ContinuousClock.now
        let files = OpenFiles(maxAge: OpenFiles.cleanMaxAge) { _ in // the clean's table, as Smart Scan passes it
            reads.withLock { $0 += 1 }
            return [held]
        }
        let report = await Cleaner.clean(item, scan: scan, policy: policy, openPaths: { await files.paths(under: $0) })
        let elapsed = ContinuousClock.now - start
        print("BENCH clean 300 temp entries: \(elapsed), open-file reads: \(reads.withLock { $0 })")
        // One read, then one more per 2 s of cleaning (a fixed `<= 2` failed when a busy machine took > 4 s).
        #expect(reads.withLock { $0 } <= 1 + Int(elapsed / .seconds(2)))
        #expect(report.skipped == 1)
        #expect(fm.fileExists(atPath: tmp.appending(path: "f7.bin").path))
        #expect(try fm.contentsOfDirectory(atPath: tmp.path) == ["f7.bin"])
    }

    /// Running apps are read once per scan (not per entry), but anew before each removal.
    @Test func tempFilesReadRunningAppsOncePerScanFreshAtClean() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "CleanMateE2E-\(UUID().uuidString)")
        let tmp = root.appending(path: "tmp")
        defer { try? fm.removeItem(at: root) }
        let policy = SafetyPolicy(home: root.appending(path: "home"), temp: tmp)
        for path in ["com.example.app/helper", "a.bin", "b.bin", "c.bin"] {
            let url = tmp.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(path.utf8).write(to: url)
        }
        let state = OSAllocatedUnfairLock(initialState: (reads: 0, running: Set<String>()))
        let item = try #require(CleanerGroup.smartScan(ages: CleanupAges(temp: 0), runningApps: {
            state.withLock { $0.reads += 1; return $0.running }
        }).flatMap(\.items).first { $0.id == "temp-files" })
        let scan = await Scanner.scan(item, policy: policy, openPaths: Self.ownOpenPaths)
        #expect(scan.entries.count == 4)
        #expect(state.withLock { $0.reads } == 1)

        state.withLock { $0 = (0, ["com.example.app"]) } // launched after the scan, same item
        #expect(await Cleaner.clean(item, scan: scan, policy: policy, openPaths: Self.ownOpenPaths).skipped == 1)
        #expect(state.withLock { $0.reads } == 4)
        #expect(fm.fileExists(atPath: tmp.appending(path: "com.example.app/helper").path))
        #expect(!fm.fileExists(atPath: tmp.appending(path: "a.bin").path))
    }

    /// App group caches: only with Full Disk Access (the test above checks no "Containers" path without it);
    /// only `Library/Caches` of groups that are not Apple's, have a known creator, and whose vendor has no app running.
    @Test func groupCachesOnlyWithFullDiskAccess() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "CleanMateE2E-\(UUID().uuidString)")
        let home = root.appending(path: "home")
        try #require(!(root.path as NSString).resolvingSymlinksInPath.hasPrefix((NSHomeDirectory() as NSString).resolvingSymlinksInPath + "/"))
        defer { try? fm.removeItem(at: root) }
        let policy = SafetyPolicy(home: home, temp: root.appending(path: "tmp"))
        let groups = home.appending(path: "Library/Group Containers")
        func write(_ path: String) throws {
            let url = groups.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("data \(path)".utf8).write(to: url)
        }
        let creators = ["ABCDE12345.com.example.shared": "com.example.app", "group.org.sample.app": "org.sample.app.Widget",
                        "group.com.apple.notes": "com.apple.Notes", "74J34U3R6X.com.apple.iWork": "com.apple.iWork.Numbers",
                        "group.is.workflow.my.app": "com.apple.siriactionsd", "group.tvappservices.container": "com.apple.news",
                        "group.is.shortcuts.clone": "is.workflow.other", "UBF8T346G9.Office": "com.microsoft.Excel"]
        let junk = ["ABCDE12345.com.example.shared/Library/Caches/com.example.app/Cache.db",
                    "ABCDE12345.com.example.shared/Library/Caches/blob.bin", "group.org.sample.app/Library/Caches/images/1.png"]
        let bait = ["ABCDE12345.com.example.shared/Library/Application Support/db.sqlite",
                    "ABCDE12345.com.example.shared/Library/Preferences/ABCDE12345.com.example.shared.plist",
                    "ABCDE12345.com.example.shared/Library/Caches/TemporaryItems/save.tmp", "ABCDE12345.com.example.shared/data.bin",
                    "group.com.apple.notes/Library/Caches/Paper", "74J34U3R6X.com.apple.iWork/Library/Caches/Fonts/a.ttf",
                    "group.is.workflow.my.app/Library/Caches/lock", "group.tvappservices.container/Library/Caches/c.db",
                    "group.is.shortcuts.clone/Library/Caches/c.db",
                    // Microsoft group created by Excel while Word runs: same vendor, kept
                    "UBF8T346G9.Office/Library/Caches/c.db",
                    // no containermanagerd metadata: owner unknown, kept
                    "XYZ9876543.net.unknown.app/Library/Caches/c.db"]
        for path in junk + bait { try write(path) }
        for (group, creator) in creators {
            try (["MCMMetadataIdentifier": group, "MCMMetadataCreator": creator] as NSDictionary)
                .write(to: groups.appending(path: "\(group)/.com.apple.containermanagerd.metadata.plist"))
        }

        func item(running: Set<String>) throws -> CleanerItem {
            try #require(CleanerGroup.smartScan(ages: .default, hasFullDiskAccess: true, runningApps: { running })
                .flatMap(\.items).first { $0.id == "group-caches" })
        }
        let scan = await Scanner.scan(try item(running: ["com.microsoft.Word"]), policy: policy, openPaths: Self.ownOpenPaths)
        #expect(Set(scan.entries.map { $0.url.pathComponents.suffix(4).joined(separator: "/") })
                == ["ABCDE12345.com.example.shared/Library/Caches/com.example.app", "ABCDE12345.com.example.shared/Library/Caches/blob.bin",
                    "group.org.sample.app/Library/Caches/images"])
        #expect(await Cleaner.clean(try item(running: ["com.microsoft.Word"]), scan: scan, policy: policy, openPaths: Self.ownOpenPaths).skipped == 0)
        for path in junk { #expect(!fm.fileExists(atPath: groups.appending(path: path).path), "\(path) left") }
        for path in bait {
            #expect(fm.contents(atPath: groups.appending(path: path).path) == Data("data \(path)".utf8), "bait changed: \(path)")
        }

        // Another app of the group's vendor launched between scan and clean: the group keeps its caches.
        try write("ABCDE12345.com.example.shared/Library/Caches/again.bin")
        let rescan = await Scanner.scan(try item(running: []), policy: policy, openPaths: Self.ownOpenPaths)
        #expect(await Cleaner.clean(try item(running: ["com.example.other"]), scan: rescan, policy: policy, openPaths: Self.ownOpenPaths).skipped == 1)
        #expect(fm.fileExists(atPath: groups.appending(path: "ABCDE12345.com.example.shared/Library/Caches/again.bin").path))
    }
}
