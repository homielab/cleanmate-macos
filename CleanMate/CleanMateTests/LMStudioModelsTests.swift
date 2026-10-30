import Foundation
import Testing
@testable import CleanMate

/// LM Studio models in Smart Scan: one entry per `<publisher>/<model>` folder, chosen on its own and removed whole;
/// settings, conversations and the rest of `~/.lmstudio` are never listed. Everything happens in a throwaway fake home.
struct LMStudioModelsTests {
    private struct Home {
        let root = FileManager.default.temporaryDirectory.appending(path: "CleanMateLMStudio-\(UUID().uuidString)")
        var home: URL { root.appending(path: "home") }
        var policy: SafetyPolicy { SafetyPolicy(home: home, temp: root.appending(path: "tmp")) }

        init() throws {
            for dir in ["home", "tmp"] {
                try FileManager.default.createDirectory(at: root.appending(path: dir), withIntermediateDirectories: true)
            }
        }

        @discardableResult
        func file(_ path: String, _ data: Data = Data(repeating: 1, count: 40_000)) throws -> URL {
            let url = home.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            return url
        }

        /// A model folder `<models>/<name>` with a weights file and a small metadata file.
        @discardableResult
        func model(_ models: String, _ name: String) throws -> URL {
            try file(models + "/" + name + "/model-Q4_K_M.gguf")
            try file(models + "/" + name + "/README.md", Data("readme".utf8))
            return home.appending(path: models + "/" + name)
        }

        func settings(_ path: String, folder: String) throws {
            try file(path, Data(#"{"downloadsFolder":"\#(folder)","theme":"dark"}"#.utf8))
        }

        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private var item: CleanerItem {
        get throws { try #require(CleanerGroup.aiTools().items.first { $0.id == "lmstudio-models" }) }
    }

    @Test func catalogItem() throws {
        let item = try item
        #expect(!item.selectedByDefault && item.selectableEntries && item.mode == .delete && !item.showsWhenEmpty)
        #expect(item.command == nil && item.probe == nil && item.database == nil && item.entryFiles == nil)
        #expect(item.skipsOpenFiles && item.included == nil && item.minAge == nil && item.configFolders != nil)
        #expect(item.runningAppBundleIDs == ["ai.elementlabs.lmstudio"])
        #expect(Set(item.runningProcessNames).isSuperset(of: ["lms", "llmster", "LM Studio Helper"]))
        #expect(item.paths == ["~/.lmstudio/models/*", "~/.cache/lm-studio/models/*"])
    }

    /// Models in the current, the old and a moved models folder are listed once each with `publisher/model`; ticking
    /// one removes only that folder. Settings, conversations, extensions, the CLI, hub, `.internal`, hidden names,
    /// loose files and a folder named outside home are never touched.
    @Test func listsEachModelAndRemovesOnlyTheTickedOne() async throws {
        let box = try Home()
        defer { box.remove() }
        let item = try item
        let qwen = try box.model(".lmstudio/models/lmstudio-community", "Qwen3-8B-GGUF")
        let gemma = try box.model(".lmstudio/models/lmstudio-community", "gemma-3-4b-it-GGUF")
        let mlx = try box.model(".lmstudio/models/mlx-community", "Llama-3.2-3B-Instruct-4bit")
        let old = try box.model(".cache/lm-studio/models/TheBloke", "Mistral-7B-GGUF")
        let moved = try box.model("AI/models/bartowski", "phi-4-GGUF")
        let outside = box.root.appending(path: "outside/models/pub/model/m.gguf")
        try FileManager.default.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 1000).write(to: outside)
        // The moved folder, the default one again (counted once), and one outside home (ignored).
        try box.settings(".lmstudio/settings.json", folder: box.home.appending(path: "AI/models").path)
        try box.settings(".cache/lm-studio/settings.json", folder: box.home.appending(path: ".lmstudio/models").path)
        let protected = try [
            ".lmstudio/conversations/1.conversation.json", ".lmstudio/extensions/backends/llama.cpp/lib.dylib",
            ".lmstudio/bin/lms", ".lmstudio/hub/models/google/gemma/manifest.json", ".lmstudio/.internal/state.json",
            ".lmstudio/models/.internal/cache.json", ".lmstudio/models/.hidden/model/m.gguf",
            ".lmstudio/models/lmstudio-community/.DS_Store", ".lmstudio/models/lmstudio-community/loose.gguf",
            ".lmstudio/models/top.gguf", ".cache/lm-studio/models/m.gguf",
        ].map { try box.file($0) } + [box.home.appending(path: ".lmstudio/settings.json")]

        let scan = await Scanner.scan(item, policy: box.policy)
        #expect(scan.entries.map(\.url.standardizedFileURL.path).sorted()
                == [qwen, gemma, mlx, old, moved].map(\.standardizedFileURL.path).sorted())
        let labels = Set(scan.entries.compactMap { item.entryLabel?($0.url)?.title })
        #expect(labels == ["lmstudio-community/Qwen3-8B-GGUF", "lmstudio-community/gemma-3-4b-it-GGUF",
                           "mlx-community/Llama-3.2-3B-Instruct-4bit", "TheBloke/Mistral-7B-GGUF", "bartowski/phi-4-GGUF"])
        #expect(scan.entries.allSatisfy { item.entryLabel?($0.url)?.date != nil && $0.size >= 40_000 })

        var onlyQwen = scan
        onlyQwen.entries = scan.entries.filter { $0.url.lastPathComponent == "Qwen3-8B-GGUF" }
        let size = try #require(onlyQwen.entries.first?.size)
        let report = await Cleaner.clean(item, scan: onlyQwen, policy: box.policy)
        #expect(report.skipped == 0 && report.freed == size)
        #expect(!box.exists(qwen) && box.exists(qwen.deletingLastPathComponent()))
        #expect(([gemma, mlx, old, moved, outside] + protected).allSatisfy(box.exists))
    }

    /// A model folder that is a symlink (to Documents, say) is never listed or followed.
    @Test func skipsSymlinkedModels() async throws {
        let box = try Home()
        defer { box.remove() }
        let target = try box.file("Documents/weights/m.gguf")
        let link = box.home.appending(path: ".lmstudio/models/me/linked")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target.deletingLastPathComponent())
        let real = try box.model(".lmstudio/models/me", "real")
        let scan = await Scanner.scan(try item, policy: box.policy)
        #expect(scan.entries.map(\.url.lastPathComponent) == [real.lastPathComponent])
        #expect(LMStudioModels.skips(link) && !LMStudioModels.skips(real))
    }

    /// Only a regular JSON file's string `downloadsFolder` counts; anything else names no folder.
    @Test func readsTheMovedFolderOnlyFromAValidSettingsFile() throws {
        let box = try Home()
        defer { box.remove() }
        #expect(LMStudioModels.configuredFolders(home: box.home).isEmpty)
        try box.file(".lmstudio/settings.json", Data(#"{"downloadsFolder":42}"#.utf8))
        try box.file(".cache/lm-studio/settings.json", Data("{".utf8))
        #expect(LMStudioModels.configuredFolders(home: box.home).isEmpty)
        try box.settings(".lmstudio/settings.json", folder: "/Volumes/AI/models")
        #expect(LMStudioModels.configuredFolders(home: box.home) == ["/Volumes/AI/models"])
        // Read as written; the scan then keeps only an existing folder strictly inside home.
        #expect(ShellEnvironment.checkedFolder("/Volumes/AI/models", policy: box.policy) == nil)
        #expect(ShellEnvironment.checkedFolder(box.home.path, policy: box.policy) == nil)
    }

    /// While `lms` (or the app) runs, a model may be loaded: the row is locked, not ticked, not cleaned.
    @MainActor @Test func lockedWhileLMStudioRuns() async throws {
        let box = try Home()
        defer { box.remove() }
        let item = try item
        let model = try box.model(".lmstudio/models/pub", "model")
        let smartScan = SmartScanModel(module: .smartScan) { [CleanerGroup(id: "g", title: "G", systemImage: "x", items: [item])] }
        smartScan.appBundleIDs = { [] }
        smartScan.runningApps = []
        smartScan.processNames = { ["lms", "zsh"] }
        let policy = box.policy // not this Mac's Exclusions, Trash or activity log
        smartScan.logHome = box.home
        smartScan.scanItem = { await Scanner.scan($0, policy: policy, openPaths: $1) }
        smartScan.cleanItem = { await Cleaner.clean($0, scan: $1, policy: policy, openPaths: $2) }
        await smartScan.scan()
        #expect(smartScan.isRunning(item) && smartScan.selected.isEmpty)
        smartScan.selected = [item.id]
        await smartScan.clean()
        guard case .done(let report) = smartScan.phase else { Issue.record("not done"); return }
        #expect(report.skipped == 1 && box.exists(model))
        smartScan.processNames = { ["zsh"] }
        smartScan.runningApps = ["ai.elementlabs.lmstudio"]
        #expect(smartScan.isRunning(item))
        smartScan.runningApps = []
        await smartScan.scan()
        #expect(!smartScan.isRunning(item) && smartScan.selected.isEmpty) // unticked by default
    }
}
