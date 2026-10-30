import Foundation
import Testing
@testable import CleanMate

/// Models of PyTorch Hub, Whisper, sentence-transformers and Keras in Smart Scan: one entry per model file or folder,
/// unticked, deleted on its own; a model a program has open is kept, folders set in the shell profile are scanned, and
/// the rest of these folders (torch kernels and hub repos, `keras.json`) is never touched. Everything happens in a
/// throwaway fake home.
struct AIModelCachesTests {
    private struct Home {
        let root = TestTemp.url("CleanMateAIModels")
        var home: URL { root.appending(path: "home") }
        var policy: SafetyPolicy { SafetyPolicy(home: home, temp: root.appending(path: "tmp")) }

        init() throws {
            for dir in ["home", "tmp"] {
                try FileManager.default.createDirectory(at: root.appending(path: dir), withIntermediateDirectories: true)
            }
        }

        @discardableResult
        func file(_ path: String, _ text: String? = nil) throws -> URL {
            let url = home.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (text.map { Data($0.utf8) } ?? Data(repeating: 1, count: 40_000)).write(to: url)
            return url
        }

        /// A sentence-transformers model folder `<folder>/<name>` with its weights and `modules.json`.
        @discardableResult
        func sentenceModel(_ folder: String, _ name: String) throws -> URL {
            try file("\(folder)/\(name)/model.safetensors")
            try file("\(folder)/\(name)/modules.json", "[]")
            return home.appending(path: "\(folder)/\(name)")
        }

        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private var item: CleanerItem {
        get throws { try #require(CleanerGroup.aiTools().items.first { $0.id == AIModelCaches.id }) }
    }

    private static let noOpenFiles: OpenPaths = { _ in [] }

    private func scan(_ box: Home, openPaths: @escaping OpenPaths = noOpenFiles) async throws -> ItemScan {
        await Scanner.scan(try item, policy: box.policy, openPaths: openPaths)
    }

    private func paths(_ scan: ItemScan) -> [String] { scan.entries.map(\.url.standardizedFileURL.path).sorted() }

    @Test func catalogItem() throws {
        let item = try item
        let ids = CleanerGroup.aiTools().items.map(\.id)
        #expect(ids.firstIndex(of: AIModelCaches.id) == ids.firstIndex(of: "lmstudio-models").map { $0 + 1 })
        #expect(!item.selectedByDefault && item.selectableEntries && item.mode == .delete && !item.showsWhenEmpty)
        #expect(item.skipsOpenFiles && item.allowsEntry != nil && item.entryLabel != nil)
        #expect(item.command == nil && item.probe == nil && item.included == nil && item.minAge == nil)
        #expect(item.runningProcessNames.isEmpty && item.runningAppBundleIDs.isEmpty)
        #expect(item.paths == ["~/.cache/torch/hub/checkpoints", "~/.cache/whisper", "~/.cache/torch/sentence_transformers", "~/.keras"])
        #expect(Set(item.shellFolders.keys) == ["TORCH_HOME", "XDG_CACHE_HOME", "SENTENCE_TRANSFORMERS_HOME", "KERAS_HOME"])
        #expect(Set(item.shellFolders.keys).isSubset(of: ShellEnvironment.variables))
    }

    /// Each checkpoint file, Whisper `.pt` file, sentence-transformers model folder and the Keras `models` and
    /// `datasets` folders are listed once with their library's name; ticking one removes only that one. Torch kernels
    /// and hub repo checkouts, `keras.json`, other Whisper files, hidden names, symlinks and folders without a
    /// sentence-transformers marker stay.
    @Test func listsEachModelAndRemovesOnlyTheTickedOne() async throws {
        let box = try Home()
        defer { box.remove() }
        let item = try item
        let resnet = try box.file(".cache/torch/hub/checkpoints/resnet50-0676ba61.pth")
        let vit = try box.file(".cache/torch/hub/checkpoints/vit_b_16-c867db91.pth")
        let large = try box.file(".cache/whisper/large-v3.pt")
        let base = try box.file(".cache/whisper/base.en.pt")
        let minilm = try box.sentenceModel(".cache/torch/sentence_transformers", "sentence-transformers_all-MiniLM-L6-v2")
        let mpnet = box.home.appending(path: ".cache/torch/sentence_transformers/sentence-transformers_all-mpnet-base-v2")
        try box.file(".cache/torch/sentence_transformers/sentence-transformers_all-mpnet-base-v2/pytorch_model.bin")
        try box.file(".cache/torch/sentence_transformers/sentence-transformers_all-mpnet-base-v2/config_sentence_transformers.json", "{}")
        let models = try box.file(".keras/models/vgg16_weights.h5").deletingLastPathComponent()
        let datasets = try box.file(".keras/datasets/mnist.npz").deletingLastPathComponent()
        let target = try box.file("Documents/weights.pth")
        try FileManager.default.createSymbolicLink(at: box.home.appending(path: ".cache/torch/hub/checkpoints/linked.pth"),
                                                   withDestinationURL: target)
        let protected = try [
            ".cache/torch/kernels/kernel.bin", ".cache/torch/hub/pytorch_vision_main/hubconf.py",
            ".cache/torch/hub/checkpoints/.DS_Store", ".cache/whisper/notes.txt", ".cache/whisper/.hidden.pt",
            ".cache/torch/sentence_transformers/plain-folder/model.bin", ".cache/torch/sentence_transformers/loose.json",
            ".keras/keras.json", ".keras/other/data.bin", ".keras/models.bak",
        ].map { try box.file($0) } + [target]

        let found = try await scan(box)
        #expect(paths(found) == [resnet, vit, large, base, minilm, mpnet, models, datasets].map(\.standardizedFileURL.path).sorted())
        let labels = Set(found.entries.compactMap { item.entryLabel?($0.url)?.title })
        #expect(labels == ["resnet50-0676ba61.pth — PyTorch Hub", "vit_b_16-c867db91.pth — PyTorch Hub",
                           "large-v3 — Whisper", "base.en — Whisper",
                           "sentence-transformers_all-MiniLM-L6-v2 — sentence-transformers",
                           "sentence-transformers_all-mpnet-base-v2 — sentence-transformers",
                           "models — Keras", "datasets — Keras"])
        #expect(found.entries.allSatisfy { item.entryLabel?($0.url)?.date != nil && $0.size >= 40_000 })

        var ticked = found
        ticked.entries = found.entries.filter { [large.lastPathComponent, minilm.lastPathComponent].contains($0.url.lastPathComponent) }
        #expect(ticked.entries.count == 2)
        let report = await Cleaner.clean(item, scan: ticked, policy: box.policy, openPaths: Self.noOpenFiles)
        #expect(report.skipped == 0 && report.freed == ticked.entries.reduce(0) { $0 + $1.size })
        #expect(!box.exists(large) && !box.exists(minilm) && box.exists(large.deletingLastPathComponent()))
        #expect(([resnet, vit, base, mpnet, models, datasets] + protected).allSatisfy(box.exists))
    }

    /// A model a program has open (being loaded or downloaded) is not listed, and is kept at clean when opened since.
    @Test func keepsModelsInUse() async throws {
        let box = try Home()
        defer { box.remove() }
        let item = try item
        let open = try box.file(".cache/whisper/medium.pt")
        let free = try box.file(".cache/whisper/small.pt")
        let model = try box.sentenceModel(".cache/torch/sentence_transformers", "in-use")
        let openPaths: OpenPaths = { _ in
            [RunningProcesses.withoutPrivate(open.standardizedFileURL.path),
             RunningProcesses.withoutPrivate(model.appending(path: "model.safetensors").standardizedFileURL.path)]
        }
        let found = try await scan(box, openPaths: openPaths)
        #expect(paths(found) == [free.standardizedFileURL.path])

        let everything = try await scan(box)
        #expect(everything.entries.count == 3)
        let report = await Cleaner.clean(item, scan: everything, policy: box.policy, openPaths: openPaths)
        #expect(report.skipped == 2)
        #expect(box.exists(open) && box.exists(model) && !box.exists(free))
    }

    /// `TORCH_HOME`, `XDG_CACHE_HOME`, `SENTENCE_TRANSFORMERS_HOME` and `KERAS_HOME` from the profile move the folders:
    /// their models are listed besides the defaults' (only the library's own subfolders: torch kernels stay), a folder
    /// outside home is ignored, and one two variables point to lists nothing.
    @Test func followsProfileVariables() async throws {
        let box = try Home()
        defer { box.remove() }
        try box.file(".zshrc", """
            export TORCH_HOME=~/ml/torch
            export XDG_CACHE_HOME="$HOME/xdg"
            export SENTENCE_TRANSFORMERS_HOME=$HOME/ml/st
            export KERAS_HOME=\(box.root.appending(path: "outside/keras").path)
            """)
        let outside = box.root.appending(path: "outside/keras/models/m.h5")
        try FileManager.default.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 1000).write(to: outside)
        let def = try box.file(".cache/torch/hub/checkpoints/default.pth")
        let torch = try box.file("ml/torch/hub/checkpoints/moved.pth")
        let torchST = try box.sentenceModel("ml/torch/sentence_transformers", "torch-home-model")
        let xdgTorch = try box.file("xdg/torch/hub/checkpoints/xdg.pth")
        let whisper = try box.file("xdg/whisper/tiny.pt")
        let st = try box.sentenceModel("ml/st", "moved-model")
        let kept = try [
            "ml/torch/kernels/k.bin", "ml/torch/hub/repo/hubconf.py", "ml/st/project/config.json", "xdg/other/x.pt",
        ].map { try box.file($0) }

        let found = try await scan(box)
        #expect(paths(found) == [def, torch, torchST, xdgTorch, whisper, st].map(\.standardizedFileURL.path).sorted())
        _ = await Cleaner.clean(try item, scan: found, policy: box.policy, openPaths: Self.noOpenFiles)
        #expect(![def, torch, torchST, xdgTorch, whisper, st].contains(where: box.exists))
        #expect((kept + [outside]).allSatisfy(box.exists))

        // Keras and sentence-transformers set to the same folder: which library owns it is unknown.
        try box.file(".zshrc", "export KERAS_HOME=~/ml/shared\nexport SENTENCE_TRANSFORMERS_HOME=~/ml/shared\n")
        let shared = try box.sentenceModel("ml/shared", "models")
        let again = try await scan(box)
        #expect(again.entries.isEmpty)
        #expect(!AIModelCaches.allows(box.policy, shared))
    }
}
