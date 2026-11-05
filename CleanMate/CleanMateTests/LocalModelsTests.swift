import Foundation
import Testing
@testable import CleanMate

/// Models of llama.cpp, Jan, GPT4All, Draw Things and ComfyUI in Smart Scan › AI Tools: one row per model, unticked, to
/// a fake Trash with its side files; everything else in the app's folders stays. Everything happens in a throwaway home.
final class LocalModelsTests {
    let fm = FileManager.default
    let root = TestTemp.url("CleanMateLocalModels")
    var home: URL { root.appending(path: "home") }
    var trash: URL { root.appending(path: "Trash") }
    var policy: SafetyPolicy { SafetyPolicy(home: home, temp: root.appending(path: "tmp")) }

    init() throws {
        for dir in ["home", "tmp", "Trash"] { try fm.createDirectory(at: root.appending(path: dir), withIntermediateDirectories: true) }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func file(_ path: String, _ data: Data = Data(repeating: 1, count: 40_000)) throws -> URL {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    func text(_ path: String, _ text: String) throws { try file(path, Data(text.utf8)) }
    func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    func item(_ app: LocalModels.App, hasFullDiskAccess: Bool = true) -> CleanerItem {
        LocalModels.item(app, hasFullDiskAccess: hasFullDiskAccess)
    }

    func scan(_ item: CleanerItem) async -> ItemScan {
        await Scanner.scan(item, policy: policy, openPaths: EndToEndCleanTests.ownOpenPaths)
    }

    func paths(_ scan: ItemScan) -> [String] { scan.entries.map(\.url.standardizedFileURL.path).sorted() }
    func paths(_ urls: [URL]) -> [String] { urls.map(\.standardizedFileURL.path).sorted() }
    func titles(_ scan: ItemScan, _ item: CleanerItem) -> Set<String> {
        Set(scan.entries.compactMap { item.entryLabel?($0.url)?.title })
    }

    var moveToFakeTrash: @Sendable (URL) throws -> URL? {
        let trash = trash
        return { url in
            let target = trash.appending(path: UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }
    }

    /// `scan` with only the entry at `url` ticked, cleaned into the fake Trash.
    func clean(_ item: CleanerItem, _ scan: ItemScan, only url: URL) async -> CleanReport {
        var one = scan
        one.entries = scan.entries.filter { $0.url.standardizedFileURL.path == url.standardizedFileURL.path }
        return await Cleaner.clean(item, scan: one, policy: policy, trash: moveToFakeTrash,
                                   openPaths: EndToEndCleanTests.ownOpenPaths)
    }

    @Test func catalogItems() throws {
        let items = CleanerGroup.aiTools(hasFullDiskAccess: true).items
        for app in LocalModels.App.allCases {
            let item = try #require(items.first { $0.id == app.id })
            #expect(!item.selectedByDefault && item.selectableEntries && item.mode == .trash && !item.showsWhenEmpty)
            #expect(item.skipsOpenFiles && item.findEntries != nil && item.allowsEntry != nil && item.entryParts != nil)
            #expect(item.about != nil && item.afterClean != nil && item.note != nil && item.configFolders != nil)
            #expect(item.command == nil && item.included == nil && item.minAge == nil && item.entryFiles == nil)
            #expect(!item.runningAppBundleIDs.isEmpty || !item.runningProcessNames.isEmpty)
        }
        #expect(items.first { $0.id == "jan-models" }?.runningAppBundleIDs == ["jan.ai.app"])
        #expect(items.first { $0.id == "drawthings-models" }?.runningAppBundleIDs == ["com.liuliu.draw-things"])
        #expect(items.first { $0.id == "llamacpp-models" }?.runningProcessNames.contains("llama-server") == true)
        #expect(ShellEnvironment.variables.isSuperset(of: ["LLAMA_CACHE", "HF_XET_CACHE"]))
    }

    /// llama.cpp: each `.gguf` in its cache, `~/.cache/llama.cpp` and `LLAMA_CACHE`, trashed with its `.etag`, `.json`
    /// and `.lock`; manifests, downloads in progress, Hugging Face-style folders and hidden files stay. Undo puts back.
    @Test func llamaCppModels() async throws {
        let item = item(.llamaCpp)
        let cache = "Library/Caches/llama.cpp/"
        let gemma = try file(cache + "ggml-org_gemma-3-1b-it-GGUF_gemma-3-1b-it-Q4_K_M.gguf")
        let sides = try [".etag", ".json", ".lock"].map { try file(cache + gemma.lastPathComponent + $0, Data("\"x\"".utf8)) }
        let qwen = try file(cache + "Qwen_Qwen3-8B-GGUF_Qwen3-8B-Q4_K_M.gguf")
        let dot = try file(".cache/llama.cpp/tiny.gguf")
        let custom = try file("models/llama/phi-4-Q4_K_M.gguf")
        try text(".zprofile", "export LLAMA_CACHE=\"$HOME/models/llama\"\n")
        let kept = try [
            cache + "manifest=ggml-org_gemma-3-1b-it-GGUF=latest.json", cache + "next.gguf.downloadInProgress",
            cache + ".hidden.gguf", cache + "models--ggml-org--gemma/blobs/abc", cache + "notes.txt",
            ".config/llama.cpp/settings.json",
        ].map { try file($0) }

        let found = await scan(item)
        #expect(paths(found) == paths([gemma, qwen, dot, custom]))
        #expect(titles(found, item) == ["ggml-org_gemma-3-1b-it-GGUF_gemma-3-1b-it-Q4_K_M", "Qwen_Qwen3-8B-GGUF_Qwen3-8B-Q4_K_M",
                                        "tiny", "phi-4-Q4_K_M"])

        let report = await clean(item, found, only: gemma)
        #expect(report.skipped == 0 && report.trashed.count == 4)
        #expect(!exists(gemma) && !sides.contains(where: exists))
        #expect(([qwen, dot, custom] + kept).allSatisfy(exists))
        let undo = await TrashUndo.restore(report.trashed, module: "Smart Scan", home: home)
        #expect(undo == TrashUndo.Result(restored: 4, skipped: 0))
        #expect(([gemma] + sides).allSatisfy(exists))
    }

    /// Jan: a model folder (settings file plus weights) in llamacpp, mlx, the old models folders and a moved data
    /// folder, named by its id; an imported model (settings only), chats, extensions and backends stay.
    @Test func janModels() async throws {
        let item = item(.jan)
        let data = "Library/Application Support/Jan/data/"
        try text(data + "llamacpp/models/Qwen3-4B-Q4_K_M/model.yml", "model_path: model.gguf\n")
        try file(data + "llamacpp/models/Qwen3-4B-Q4_K_M/model.gguf")
        try file(data + "llamacpp/models/Qwen3-4B-Q4_K_M/mmproj.gguf")
        try text(data + "mlx/models/mlx-community/Qwen3-4B-4bit/model.yml", "x")
        try file(data + "mlx/models/mlx-community/Qwen3-4B-4bit/model.safetensors")
        try text(data + "mlx/models/mlx-community/Qwen3-4B-4bit/config.json", "{}")
        try text("jan/models/tinyllama/model.json", "{}")
        try file("jan/models/tinyllama/tinyllama-1.1b.Q4_K_M.gguf")
        try text("JanData/llamacpp/models/moved/model.yml", "x")
        try file("JanData/llamacpp/models/moved/model.gguf")
        try text("Library/Application Support/Jan/settings.json", #"{"data_folder":"\#(home.path)/JanData"}"#)
        let qwen = home.appending(path: data + "llamacpp/models/Qwen3-4B-Q4_K_M")
        let mlx = home.appending(path: data + "mlx/models/mlx-community/Qwen3-4B-4bit")
        let old = home.appending(path: "jan/models/tinyllama")
        let moved = home.appending(path: "JanData/llamacpp/models/moved")
        let kept = try [
            data + "llamacpp/models/imported/model.yml", data + "threads/abc/messages.jsonl",
            data + "extensions/x/index.js", data + "llamacpp/backends/b1/llama-server", data + "llamacpp/models/loose.gguf",
            data + "llamacpp/models/.hidden/model.gguf",
        ].map { try file($0) }

        let found = await scan(item)
        #expect(paths(found) == paths([qwen, mlx, old, moved]))
        #expect(titles(found, item) == ["Qwen3-4B-Q4_K_M", "mlx-community/Qwen3-4B-4bit", "tinyllama", "moved"])

        let report = await clean(item, found, only: qwen)
        #expect(report.skipped == 0 && report.trashed.count == 1 && !exists(qwen))
        #expect(([mlx, old, moved] + kept).allSatisfy(exists))
    }

    /// GPT4All: each finished `.gguf` in its folder and the `modelPath` of its settings; unfinished downloads, chats,
    /// LocalDocs, logs and online model files stay.
    @Test func gpt4allModels() async throws {
        let item = item(.gpt4all)
        let folder = "Library/Application Support/nomic.ai/GPT4All/"
        let llama = try file(folder + "Llama-3.2-3B-Instruct-Q4_0.gguf")
        let moved = try file("Models/mistral-7b-instruct-v0.1.Q4_0.gguf")
        try text(".config/nomic.ai/GPT4All.ini", "[General]\nmodelPath=\"\(home.path)/Models/\"\nfontSize=Small\n")
        let kept = try [
            folder + "incomplete-Phi-3-mini-4k-instruct.Q4_0.gguf", folder + "localdocs_v3.db", folder + "gpt4all-abc.chat",
            folder + "log.txt", folder + "gpt4all-gpt-4o.rmodel", folder + "sub/inner.gguf",
        ].map { try file($0) }

        let found = await scan(item)
        #expect(paths(found) == paths([llama, moved]))
        #expect(titles(found, item) == ["Llama-3.2-3B-Instruct-Q4_0", "mistral-7b-instruct-v0.1.Q4_0"])
        let report = await clean(item, found, only: llama)
        #expect(report.skipped == 0 && report.trashed.count == 1 && !exists(llama))
        #expect(([moved] + kept).allSatisfy(exists))

        // Only `[General] modelPath`, quotes optional.
        try text(".config/nomic.ai/GPT4All.ini", "[Other]\nmodelPath=/a\n[General]\nmodelPath=/b/c\n")
        #expect(LocalModels.gpt4allModelPath(home: home) == "/b/c")
        try text(".config/nomic.ai/GPT4All.ini", "[Other]\nmodelPath=/a\n")
        #expect(LocalModels.gpt4allModelPath(home: home) == nil)
    }

    /// Draw Things: each `.ckpt` with its tensor data, only with Full Disk Access (its container); the custom model
    /// lists stay.
    @Test func drawThingsModels() async throws {
        let models = "Library/Containers/com.liuliu.draw-things/Data/Documents/Models/"
        let sdxl = try file(models + "sd_xl_base_1.0_f16.ckpt")
        let data = try file(models + "sd_xl_base_1.0_f16.ckpt-tensordata")
        let lora = try file(models + "detail_lora_f16.ckpt")
        let kept = try [models + "custom.json", models + "custom_lora.json", models + "notes.txt"].map { try file($0) }

        #expect(await scan(item(.drawThings, hasFullDiskAccess: false)).entries.isEmpty)
        #expect(LocalModels.configured(.drawThings, home: home, hasFullDiskAccess: false).isEmpty)
        let item = item(.drawThings)
        let found = await scan(item)
        #expect(paths(found) == paths([sdxl, lora]))
        #expect(titles(found, item) == ["sd_xl_base_1.0_f16", "detail_lora_f16"])
        #expect(found.entries.first { $0.url.lastPathComponent == sdxl.lastPathComponent }?.size ?? 0 >= 80_000)
        let report = await clean(item, found, only: sdxl)
        #expect(report.skipped == 0 && report.trashed.count == 2 && !exists(sdxl) && !exists(data))
        #expect(([lora] + kept).allSatisfy(exists))
    }

    /// ComfyUI: each weight file in a category folder of `~/ComfyUI/models` and of ComfyUI Desktop's install (in
    /// Documents: only with Full Disk Access), named with its category; placeholders, configs, files at the top of
    /// `models`, workflows, images and custom nodes stay.
    @Test func comfyUIModels() async throws {
        let manual = try file("ComfyUI/models/checkpoints/v1-5-pruned-emaonly.safetensors")
        let lora = try file("ComfyUI/models/loras/style/pixel.safetensors")
        let vae = try file("Documents/ComfyUI/models/vae/ae.sft")
        try text("Library/Application Support/ComfyUI/config.json", #"{"basePath":"\#(home.path)/Documents/ComfyUI"}"#)
        let kept = try [
            "ComfyUI/models/checkpoints/put_checkpoints_here", "ComfyUI/models/configs/v1-inference.yaml",
            "ComfyUI/models/top.safetensors", "ComfyUI/models/.cache/x.safetensors", "ComfyUI/custom_nodes/n/model.safetensors",
            "Documents/ComfyUI/user/default/workflows/a.json", "Documents/ComfyUI/output/ComfyUI_00001_.png",
            "Documents/ComfyUI/input/photo.safetensors",
        ].map { try file($0) }

        #expect(paths(await scan(item(.comfyUI, hasFullDiskAccess: false))) == paths([manual, lora]))
        let item = item(.comfyUI)
        let found = await scan(item)
        #expect(paths(found) == paths([manual, lora, vae]))
        #expect(titles(found, item) == ["v1-5-pruned-emaonly.safetensors (checkpoints)", "pixel.safetensors (loras)",
                                        "ae.sft (vae)"])
        let report = await clean(item, found, only: vae)
        #expect(report.skipped == 0 && report.trashed.count == 1 && !exists(vae))
        #expect(([manual, lora] + kept).allSatisfy(exists))
    }

    /// Only Documents and Desktop are opened up for ComfyUI's install; the other never-touch trees stay closed.
    @Test func documentsOnlyForComfyUI() throws {
        for path in ["Documents/ComfyUI/models/vae/a.sft", "Desktop/ComfyUI/models/vae/a.sft"] {
            let url = try file(path)
            #expect(policy.allowsInDocuments(url) && !policy.allows(url))
        }
        for path in ["Pictures/a.sft", ".ssh/id", "Library/Mobile Documents/a.sft"] {
            #expect(!policy.allowsInDocuments(try file(path)))
        }
        for path in ["Documents", "Desktop"] { #expect(!policy.allowsInDocuments(home.appending(path: path))) }
        // A ComfyUI install in Documents is never read for another app.
        try file("Documents/models/a.gguf")
        try text(".config/nomic.ai/GPT4All.ini", "[General]\nmodelPath=\(home.path)/Documents/models\n")
        #expect(LocalModels.roots(.gpt4all, policy: policy, hasFullDiskAccess: true).allSatisfy { !$0.path.contains("Documents") })
    }

    /// Checked again right before removal: a Jan folder whose settings file went is kept; a models folder through a
    /// symlink is never listed; another home's model is never allowed.
    @Test func checkedAgainBeforeRemoval() async throws {
        let item = item(.jan)
        let data = "Library/Application Support/Jan/data/llamacpp/models/"
        try text(data + "a/model.yml", "x")
        let weights = try file(data + "a/model.gguf")
        let found = await scan(item)
        #expect(found.entries.count == 1)
        try fm.removeItem(at: home.appending(path: data + "a/model.yml"))
        let report = await clean(item, found, only: weights.deletingLastPathComponent())
        #expect(report.skipped == 1 && report.trashed.isEmpty && exists(weights))

        let target = try file("elsewhere/b.gguf")
        try fm.createDirectory(at: home.appending(path: ".cache"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: home.appending(path: ".cache/llama.cpp"), withDestinationURL: target.deletingLastPathComponent())
        #expect(await scan(self.item(.llamaCpp)).entries.isEmpty)

        let other = SafetyPolicy(home: root.appending(path: "other"), temp: root.appending(path: "tmp"))
        let mine = try file("Library/Caches/llama.cpp/c.gguf")
        #expect(self.item(.llamaCpp).allowsEntry?(policy, mine) == true)
        #expect(self.item(.llamaCpp).allowsEntry?(other, mine) == false)
    }

    /// Dated by the later of the weights' last read and last change; a settings file read at each start doesn't count.
    @Test func datedByLastUse() async throws {
        let data = "Library/Application Support/Jan/data/llamacpp/models/old/"
        let yml = try file(data + "model.yml")
        let weights = try file(data + "model.gguf")
        let read = Date(timeIntervalSince1970: 1_720_000_000), changed = Date(timeIntervalSince1970: 1_700_000_000)
        func set(_ url: URL, access: Date, modified: Date) {
            var times = [timeval(tv_sec: Int(access.timeIntervalSince1970), tv_usec: 0),
                         timeval(tv_sec: Int(modified.timeIntervalSince1970), tv_usec: 0)]
            utimes(url.path, &times)
        }
        set(weights, access: read, modified: changed)
        set(yml, access: .now, modified: .now)
        #expect(await scan(item(.jan)).entries.first?.date == read)
        set(weights, access: changed, modified: read)
        #expect(LocalModels.label(.jan, of: weights.deletingLastPathComponent())?.date == read)
    }

    /// While the app runs the item is locked: shown, not ticked, not cleaned.
    @MainActor @Test func lockedWhileTheAppRuns() async throws {
        let item = item(.jan)
        try text("Library/Application Support/Jan/data/llamacpp/models/m/model.yml", "x")
        let model = try file("Library/Application Support/Jan/data/llamacpp/models/m/model.gguf")
        let smartScan = SmartScanModel.isolated(module: .smartScan) { [CleanerGroup(id: "g", title: "G", systemImage: "x", items: [item])] }
        smartScan.appBundleIDs = { ["jan.ai.app"] } // read again right before the clean
        smartScan.runningApps = ["jan.ai.app"]
        smartScan.processNames = { ["zsh"] }
        let policy = policy
        smartScan.logHome = home
        smartScan.scanItem = { await Scanner.scan($0, policy: policy, openPaths: $1) }
        smartScan.cleanItem = { await Cleaner.clean($0, scan: $1, policy: policy, openPaths: $2) }
        await smartScan.scan()
        #expect(smartScan.isRunning(item) && smartScan.selected.isEmpty)
        smartScan.selected = [item.id]
        await smartScan.clean()
        guard case .done(let report) = smartScan.phase else { Issue.record("not done"); return }
        #expect(report.skipped == 1 && exists(model))
        smartScan.appBundleIDs = { [] }
        smartScan.runningApps = []
        #expect(!smartScan.isRunning(item))
        #expect(LocalModels.App.allCases.allSatisfy { app in
            self.item(app).runningBlocker(apps: app.bundleIDs, processes: app.processNames) != nil
        })
    }
}
