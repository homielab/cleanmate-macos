import Foundation
import Testing
@testable import CleanMate

/// "Other caches in ~/.cache", RubyGems / Bundler / Carthage, and the caches of llama.cpp, Jan, GPT4All, ComfyUI,
/// Warp, Ghostty, Raycast, Amp, Kiro, Trae and Qwen Code, in a throwaway fake home.
struct DeveloperToolCachesTests {
    private struct Home {
        let root = TestTemp.url("CleanMateDevTools")
        var home: URL { root.appending(path: "home") }
        var policy: SafetyPolicy { SafetyPolicy(home: home, temp: root.appending(path: "tmp")) }

        init() throws {
            for dir in ["home", "tmp"] { try FileManager.default.createDirectory(at: root.appending(path: dir), withIntermediateDirectories: true) }
        }

        @discardableResult
        func file(_ path: String, _ data: Data = Data(repeating: 1, count: 40_000)) throws -> URL {
            let url = home.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            return url
        }

        func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: home.appending(path: path).path) }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private static var allItems: [CleanerItem] {
        [CleanerGroup.developer, .aiTools(), .applications(hasFullDiskAccess: true)].flatMap(\.items)
    }

    private func item(_ id: String) throws -> CleanerItem { try #require(Self.allItems.first { $0.id == id }) }

    private func names(_ scan: ItemScan) -> [String] { scan.entries.map(\.url.lastPathComponent).sorted() }

    private func relative(_ scan: ItemScan, in box: Home) -> [String] {
        let home = box.home.resolvingSymlinksInPath().path + "/"
        return scan.entries.map { $0.url.resolvingSymlinksInPath().path.replacingOccurrences(of: home, with: "") }.sorted()
    }

    private static let unknown = ["android", "electron", "expo", "kube", "ms-playwright", "node-gyp", "nx"]

    /// Each unknown folder is one unticked row with its size; folders other items own, sign-in folders, files,
    /// hidden names and a folder a program has a file open in are not listed, and cleaning removes only the rows.
    @Test func otherDotCachesListsUnknownFoldersOnly() async throws {
        let box = try Home()
        defer { box.remove() }
        let item = try item(DotCaches.id)
        #expect(!item.selectedByDefault && item.selectableEntries && item.skipsOpenFiles && item.mode == .delete)
        #expect(item.paths == ["~/.cache"] && !item.showsWhenEmpty)
        #expect(CleanerGroup.developer.items.last?.id == DotCaches.id)

        for name in Self.unknown { try box.file(".cache/\(name)/sub/data.bin") }
        let owned = [".cache/uv/archive-v0/a.bin", ".cache/zig/o/a.bin", ".cache/opencode/models.json",
                     ".cache/huggingface/hub/models--org--name/blobs/a", ".cache/puppeteer/chrome/a.bin",
                     ".cache/lm-studio/models/m.gguf", ".cache/torch/hub/checkpoints/m.pth", ".cache/firebase/emulators/ui-v1.zip",
                     ".cache/amp/logs/cli.log", ".cache/ghostty/sentry/a", ".cache/gem/specs/x", ".cache/pre-commit/repo1/a",
                     ".cache/claude-cli-nodejs/a"]
        let signIns = [".cache/gh/hosts.yml", ".cache/gcloud/credentials.db", ".cache/op/config", ".cache/keyring/k",
                       ".cache/1password/x", ".cache/huggingface/token", ".cache/huggingface/stored_tokens"]
        let other = [".cache/stray.log", ".cache/.hidden/a.bin", ".cache/busy/daemon.log"]
        for path in owned + signIns + other { try box.file(path) }
        let open = box.home.appending(path: ".cache/busy/daemon.log").resolvingSymlinksInPath().path
        let openPaths: OpenPaths = { _ in [open, open.replacingOccurrences(of: "/private/", with: "/")] }

        let scan = await Scanner.scan(item, policy: box.policy, openPaths: openPaths)
        #expect(names(scan) == Self.unknown)
        #expect(scan.entries.allSatisfy { $0.size >= 40_000 })
        for name in ["uv", "zig", "opencode", "huggingface", "puppeteer", "lm-studio", "torch", "firebase", "amp", "ghostty",
                     "gem", "pre-commit", "claude-cli-nodejs"] {
            #expect(item.excluded.contains(name), "\(name)")
        }
        let report = await Cleaner.clean(item, scan: scan, policy: box.policy, openPaths: openPaths)
        #expect(report.skipped == 0)
        #expect(Self.unknown.allSatisfy { !box.exists(".cache/\($0)") })
        #expect((owned + signIns + other).allSatisfy(box.exists))
    }

    /// Sign-in folders in ~/.cache are never-touch trees: refused themselves, inside and via a parent.
    @Test func signInFoldersAreNeverTouched() throws {
        let box = try Home()
        defer { box.remove() }
        for path in [".cache/gh/hosts.yml", ".cache/gcloud/a", ".cache/op/a", ".cache/keyring/a", ".cache/huggingface/token",
                     ".cache/huggingface/stored_tokens"] {
            let url = try box.file(path)
            #expect(!box.policy.allows(url), "\(path)")
            #expect(!box.policy.allows(url.deletingLastPathComponent()), "\(path)")
        }
        #expect(box.policy.allows(try box.file(".cache/huggingface/hub/models--a/x")))
        #expect(box.policy.allows(try box.file(".cache/kube/discovery/a")))
        #expect(box.policy.allows(try box.file(".cache/ghq/a")))
    }

    /// Owned names come from paths and `XDG_CACHE_HOME` folders, cut at the first component; globs are left out.
    @Test func ownedNames() {
        let items = [
            CleanerItem(id: "a", title: "a", paths: ["~/.cache/tool/sub", "~/Library/Caches/x", "~/.cachex/y"]),
            CleanerItem(id: "b", title: "b", paths: ["~/.cache/*/z"], shellFolders: ["XDG_CACHE_HOME": ["other/p"], "HOME": ["q"]]),
            CleanerItem(id: DotCaches.id, title: "self", paths: ["~/.cache/self"]),
        ]
        #expect(DotCaches.ownedNames(of: items) == ["tool", "other"])
    }

    /// Only downloaded `.gem` packages and the spec cache; installed gems, specifications and credentials stay.
    @Test func rubyGemsAndBundlerListCachesOnly() async throws {
        let box = try Home()
        defer { box.remove() }
        let gems = try item("rubygems-cache"), bundler = try item("bundler-cache")
        let listed = [".gem/specs", ".gem/ruby/3.3.0/cache/rails-7.2.0.gem", ".cache/gem/specs",
                      ".rbenv/versions/3.3.6/lib/ruby/gems/3.3.0/cache/rack-3.1.gem",
                      ".asdf/installs/ruby/3.4.1/lib/ruby/gems/3.4.0/cache/puma-6.gem",
                      ".local/share/mise/installs/ruby/3.4.1/lib/ruby/gems/3.4.0/cache/json-2.gem"]
        try box.file(".gem/specs/index.rubygems.org%443/quick/x.gemspec")
        try box.file(".cache/gem/specs/rubygems.org%443/specs.4.8")
        for path in listed where path.hasSuffix(".gem") { try box.file(path) }
        let kept = [".gem/credentials", ".gem/ruby/3.3.0/gems/rails-7.2.0/lib/rails.rb",
                    ".gem/ruby/3.3.0/specifications/rails-7.2.0.gemspec", ".gem/ruby/3.3.0/bin/rails",
                    ".rbenv/versions/3.3.6/lib/ruby/gems/3.3.0/gems/rack-3.1/lib/rack.rb",
                    ".rbenv/versions/3.3.6/lib/ruby/gems/3.3.0/cache/notes.txt", ".bundle/config", ".bundle/plugin/index"]
        for path in kept { try box.file(path) }
        try box.file(".bundle/cache/compact_index/rubygems.org.443.abc/versions")

        let scan = await Scanner.scan(gems, policy: box.policy, openPaths: { _ in [] })
        #expect(relative(scan, in: box) == listed.sorted())
        let bundlerScan = await Scanner.scan(bundler, policy: box.policy, openPaths: { _ in [] })
        #expect(relative(bundlerScan, in: box) == [".bundle/cache/compact_index"])
        #expect(await Cleaner.clean(gems, scan: scan, policy: box.policy, openPaths: { _ in [] }).skipped == 0)
        #expect(await Cleaner.clean(bundler, scan: bundlerScan, policy: box.policy, openPaths: { _ in [] }).skipped == 0)
        #expect(kept.allSatisfy(box.exists) && !box.exists(".bundle/cache/compact_index") && !box.exists(".gem/specs"))
    }

    /// `gem` and `bundle` run as `ruby <script>`.
    @Test func rubyScriptsAreNamed() {
        let gem = RunningProcesses.argumentNames(ToolVersionManagersTests.procArgs(["/opt/homebrew/opt/ruby/bin/ruby",
                                                                                   "/Users/me/.gem/bin/bundle", "install"]))
        #expect(gem.contains("bundle"))
        let versioned = RunningProcesses.argumentNames(ToolVersionManagersTests.procArgs(["/usr/local/bin/ruby3.3",
                                                                                         "/usr/local/bin/gem", "update"]))
        #expect(versioned.contains("gem"))
    }

    /// llama.cpp: only interrupted downloads; finished models and their etags stay, and "User caches" leaves the folder alone.
    @Test func llamaCppListsPartialDownloadsOnly() async throws {
        let box = try Home()
        defer { box.remove() }
        let item = try item("llamacpp-partial")
        try box.file("Library/Caches/llama.cpp/org_model_q4.gguf.downloadInProgress")
        let kept = ["Library/Caches/llama.cpp/org_model_q4.gguf", "Library/Caches/llama.cpp/org_model_q4.gguf.etag",
                    "Library/Caches/llama.cpp/manifest=org=model=latest.json"]
        for path in kept { try box.file(path) }
        let scan = await Scanner.scan(item, policy: box.policy, openPaths: { _ in [] })
        #expect(names(scan) == ["org_model_q4.gguf.downloadInProgress"] && !item.selectedByDefault)
        #expect(CleanerGroup.ownedCachePaths.contains("llama.cpp"))
        _ = await Cleaner.clean(item, scan: scan, policy: box.policy, openPaths: { _ in [] })
        #expect(kept.allSatisfy(box.exists))
    }

    /// ComfyUI's `temp` in the install its config.json names; the install's models, inputs and outputs stay.
    @Test func comfyUITempOfTheConfiguredInstall() async throws {
        let box = try Home()
        defer { box.remove() }
        let item = try item("comfyui")
        let base = box.home.appending(path: "AI/ComfyUI").path
        try box.file("Library/Application Support/ComfyUI/Cache/Cache_Data/f")
        try box.file("AI/ComfyUI/temp/ComfyUI_temp_abc_00001_.png")
        let kept = ["AI/ComfyUI/models/checkpoints/sd.safetensors", "AI/ComfyUI/output/ComfyUI_00001_.png",
                    "AI/ComfyUI/input/a.png", "AI/ComfyUI/user/default/comfy.settings.json",
                    "Library/Application Support/ComfyUI/config.json"]
        for path in kept { try box.file(path) }
        try box.file("Library/Application Support/ComfyUI/config.json", Data(#"{"basePath":"\#(base)","installState":"installed"}"#.utf8))
        #expect(CleanerGroup.comfyUIInstalls(home: box.home) == [base])
        let scan = await Scanner.scan(item, policy: box.policy, openPaths: { _ in [] })
        #expect(relative(scan, in: box)
                == ["AI/ComfyUI/temp/ComfyUI_temp_abc_00001_.png", "Library/Application Support/ComfyUI/Cache/Cache_Data"])
        _ = await Cleaner.clean(item, scan: scan, policy: box.policy, openPaths: { _ in [] })
        #expect(kept.allSatisfy(box.exists))
        // The default install in ~/Documents is a never-touch tree: its temp is not listed.
        let documents = box.home.appending(path: "Documents/ComfyUI").path
        try box.file("Library/Application Support/ComfyUI/config.json", Data(#"{"basePath":"\#(documents)"}"#.utf8))
        try box.file("Documents/ComfyUI/temp/ComfyUI_temp_abc_00002_.png")
        #expect(CleanerGroup.comfyUIInstalls(home: box.home) == [documents])
        #expect(await Scanner.scan(item, policy: box.policy, openPaths: { _ in [] }).entries.isEmpty)
    }

    /// Each item is locked while its tool runs (or its app is open), and only then.
    @Test func lockedWhileToolRuns() throws {
        let cases: [(id: String, apps: [String], processes: [String])] = [
            ("rubygems-cache", [], ["gem"]), ("bundler-cache", [], ["bundle"]), ("carthage-cache", [], ["carthage"]),
            ("llamacpp-partial", [], ["llama-server"]), ("jan", ["jan.ai.app"], []), ("jan-sessions", ["jan.ai.app"], []),
            ("gpt4all-cache", [], ["gpt4all"]), ("gpt4all-sessions", [], ["gpt4all"]), ("comfyui", [], ["ComfyUI"]),
            ("warp", ["dev.warp.Warp-Stable"], []), ("ghostty", [], ["ghostty"]), ("raycast", ["com.raycast.macos"], []),
            ("amp-cache", [], ["amp"]), ("kiro", ["dev.kiro.desktop"], []), ("kiro-cli-cache", [], ["kiro-cli"]),
            ("kiro-sessions", [], ["kiro-cli-chat"]), ("trae", ["cn.trae.app"], []), ("qwen-cache", [], ["qwen"]),
            ("qwen-sessions", [], ["qwen"]),
        ]
        for (id, apps, processes) in cases {
            let item = try item(id)
            #expect(item.runningBlocker(apps: apps, processes: processes) != nil, "\(id)")
            #expect(item.runningBlocker(apps: ["com.apple.Terminal"], processes: ["zsh", "node"]) == nil, "\(id)")
        }
        for id in ["jan-sessions", "gpt4all-sessions", "kiro-sessions", "qwen-sessions"] {
            let item = try item(id)
            #expect(item.mode == .trash && !item.selectedByDefault && item.minAge != nil && item.selectableEntries, "\(id)")
        }
    }
}
