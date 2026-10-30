import Foundation
import Testing
@testable import CleanMate

/// Ollama models, Orca and OrbStack in Smart Scan: only regenerable data, each model chosen on its own and removed
/// with the blobs no other model uses. Everything happens in a throwaway fake home.
struct OllamaModelsTests {
    private struct Home {
        let root = FileManager.default.temporaryDirectory.appending(path: "CleanMateOllama-\(UUID().uuidString)")
        var home: URL { root.appending(path: "home") }
        var policy: SafetyPolicy { SafetyPolicy(home: home, temp: root.appending(path: "tmp")) }
        var models: URL { home.appending(path: ".ollama/models") }

        init() throws {
            for dir in ["home", "tmp"] {
                try FileManager.default.createDirectory(at: root.appending(path: dir), withIntermediateDirectories: true)
            }
        }

        @discardableResult
        func file(_ url: URL, _ data: Data = Data(repeating: 1, count: 40_000)) throws -> URL {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            return url
        }

        func digest(_ n: Int) -> String { String(repeating: String(n), count: 64) }
        func blob(_ n: Int) -> URL { models.appending(path: "blobs/sha256-" + digest(n)) }

        /// A manifest at `manifests/<path>` naming blobs `config` and `layers`, each created too.
        @discardableResult
        func model(_ path: String, config: Int, layers: [Int]) throws -> URL {
            for n in [config] + layers where !FileManager.default.fileExists(atPath: blob(n).path) { try file(blob(n)) }
            let layer = { (n: Int) in #"{"mediaType":"application/vnd.ollama.image.model","digest":"sha256:\#(digest(n))","size":40000}"# }
            let json = #"{"schemaVersion":2,"config":\#(layer(config)),"layers":[\#(layers.map(layer).joined(separator: ","))]}"#
            return try file(models.appending(path: "manifests/" + path), Data(json.utf8))
        }

        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private var item: CleanerItem {
        get throws { try #require(CleanerGroup.aiTools().items.first { $0.id == "ollama-models" }) }
    }

    @Test func catalogItem() throws {
        let item = try item
        #expect(!item.selectedByDefault && item.selectableEntries && item.mode == .delete && !item.showsWhenEmpty)
        #expect(item.command == nil && item.probe == nil && item.database == nil && item.entryFiles != nil)
        #expect(item.runningAppBundleIDs == ["com.electron.ollama"] && item.runningProcessNames == ["ollama"])
        #expect(item.paths == ["~/.ollama/models/manifests/*/*/*"] && item.shellFolders["OLLAMA_MODELS"] != nil)
        #expect(ShellEnvironment.variables.contains("OLLAMA_MODELS"))
    }

    /// Two tags sharing their weights: removing one keeps the shared blobs; the last one takes them.
    /// The key, a blob of no model and a partial download are never touched.
    @Test func removesOnlyBlobsNoOtherModelUses() async throws {
        let box = try Home()
        defer { box.remove() }
        let item = try item
        let latest = try box.model("registry.ollama.ai/library/llama3.2/latest", config: 1, layers: [2, 3])
        let small = try box.model("registry.ollama.ai/library/llama3.2/1b", config: 4, layers: [2])
        let hf = try box.model("hf.co/user/model/Q4", config: 5, layers: [6])
        let key = try box.file(box.home.appending(path: ".ollama/id_ed25519"), Data("key".utf8))
        let orphan = try box.file(box.blob(7))
        let partial = try box.file(box.models.appending(path: "blobs/sha256-\(box.digest(8))-partial"))
        try box.file(box.models.appending(path: "manifests/registry.ollama.ai/library/llama3.2/.DS_Store"), Data())

        let scan = await Scanner.scan(item, policy: box.policy)
        let byName = Dictionary(uniqueKeysWithValues: scan.entries.map { ($0.url.lastPathComponent, $0) })
        #expect(Set(byName.keys) == ["latest", "1b", "Q4"])
        let blobSize = Scanner.fileSize(box.blob(1)), manifestSize = Scanner.fileSize(latest)
        #expect(blobSize > 0)
        // latest: its manifest + blobs 1 and 3 (2 is shared with 1b, counted in neither).
        #expect(byName["latest"]?.size == manifestSize + 2 * blobSize)
        #expect(byName["1b"]?.size == Scanner.fileSize(small) + blobSize)
        let labels = Set(scan.entries.compactMap { item.entryLabel?($0.url)?.title })
        #expect(labels == ["llama3.2:latest", "llama3.2:1b", "hf.co/user/model:Q4"])

        var onlyLatest = scan
        onlyLatest.entries = scan.entries.filter { $0.url.lastPathComponent == "latest" }
        let first = await Cleaner.clean(item, scan: onlyLatest, policy: box.policy)
        #expect(first.skipped == 0 && first.freed == byName["latest"]!.size)
        #expect(!box.exists(latest) && !box.exists(box.blob(1)) && !box.exists(box.blob(3)))
        #expect([small, hf, box.blob(2), box.blob(4), box.blob(5), box.blob(6)].allSatisfy(box.exists))

        // The shared blob now belongs to 1b alone and goes with it.
        let rescan = await Scanner.scan(item, policy: box.policy)
        var onlySmall = rescan
        onlySmall.entries = rescan.entries.filter { $0.url.lastPathComponent == "1b" }
        #expect(onlySmall.entries.first?.size == Scanner.fileSize(small) + 2 * blobSize)
        let second = await Cleaner.clean(item, scan: onlySmall, policy: box.policy)
        #expect(second.skipped == 0)
        #expect(!box.exists(small) && !box.exists(box.blob(2)) && !box.exists(box.blob(4)))
        #expect([hf, box.blob(5), box.blob(6), key, orphan, partial].allSatisfy(box.exists))
    }

    /// Another manifest that can't be read may use any blob: every blob is kept, only the manifest goes.
    /// Digests that are not `sha256:<64 hex>` (a path, another algorithm) never name a file.
    @Test func keepsBlobsWhenUnsure() async throws {
        let box = try Home()
        defer { box.remove() }
        let manifest = try box.model("registry.ollama.ai/library/a/latest", config: 1, layers: [2])
        let broken = try box.file(box.models.appending(path: "manifests/registry.ollama.ai/library/b/latest"), Data("{".utf8))
        #expect(OllamaModels.ownBlobs(of: manifest).isEmpty)
        try FileManager.default.removeItem(at: broken)
        #expect(OllamaModels.ownBlobs(of: manifest).map(\.path) == [box.blob(1), box.blob(2)].map(\.path))

        let odd = try box.file(box.models.appending(path: "manifests/registry.ollama.ai/library/c/latest"), Data(#"""
            {"config":{"digest":"sha256:../../../../Documents"},"layers":[{"digest":"sha512:\#(box.digest(3))"},{"digest":"sha256-\#(box.digest(9))"}]}
            """#.utf8))
        #expect(OllamaModels.digests(in: odd) == ["sha256-" + box.digest(9)])
        // A symlinked manifest, or a file outside a manifests tree, names nothing.
        let link = box.models.appending(path: "manifests/registry.ollama.ai/library/d/latest")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: manifest)
        #expect(OllamaModels.digests(in: link) == nil)
        #expect(OllamaModels.ownBlobs(of: box.home.appending(path: "x/y/z/w/v")).isEmpty)
    }

    /// A blob that turned into a symlink or folder since the scan is kept and reported, not followed.
    @Test func cleanRechecksBlobs() async throws {
        let box = try Home()
        defer { box.remove() }
        let item = try item
        let manifest = try box.model("registry.ollama.ai/library/a/latest", config: 1, layers: [2])
        let scan = await Scanner.scan(item, policy: box.policy)
        let target = try box.file(box.home.appending(path: "Documents/model.gguf"))
        try FileManager.default.removeItem(at: box.blob(2))
        try FileManager.default.createSymbolicLink(at: box.blob(2), withDestinationURL: target)
        let report = await Cleaner.clean(item, scan: scan, policy: box.policy)
        #expect(report.skipped == 1 && !box.exists(manifest) && !box.exists(box.blob(1)))
        #expect(box.exists(target) && (try? FileManager.default.destinationOfSymbolicLink(atPath: box.blob(2).path)) != nil)
    }

    private var partialItem: CleanerItem {
        get throws { try #require(CleanerGroup.aiTools().items.first { $0.id == "ollama-partial" }) }
    }

    @Test func partialCatalogItem() throws {
        let item = try partialItem
        #expect(!item.selectedByDefault && !item.selectableEntries && item.mode == .delete && !item.showsWhenEmpty)
        #expect(item.command == nil && item.probe == nil && item.database == nil && item.entryFiles == nil && item.minAge == nil)
        #expect(item.runningAppBundleIDs == ["com.electron.ollama"] && item.runningProcessNames == ["ollama"])
        #expect(item.paths == ["~/.ollama/models/blobs"] && item.shellFolders == ["OLLAMA_MODELS": ["blobs"]])
        #expect(item.included == ["sha256-*-partial", "sha256-*-partial-*"])
    }

    /// Unfinished pulls (`-partial` data, `-partial-<n>` part state) form one row with their total size and go;
    /// finished blobs, manifests, the key and other files in `blobs` stay.
    @Test func removesOnlyPartialDownloads() async throws {
        let box = try Home()
        defer { box.remove() }
        let item = try partialItem
        let manifest = try box.model("registry.ollama.ai/library/a/latest", config: 1, layers: [2])
        let orphan = try box.file(box.blob(3))
        let key = try box.file(box.home.appending(path: ".ollama/id_ed25519"), Data("key".utf8))
        let other = try box.file(box.models.appending(path: "blobs/notes-partial"))
        let data = try box.file(box.models.appending(path: "blobs/sha256-\(box.digest(4))-partial"), Data(repeating: 1, count: 300_000))
        let parts = try (0..<2).map { try box.file(box.models.appending(path: "blobs/sha256-\(box.digest(4))-partial-\($0)"),
                                                   Data(#"{"N":\#($0)}"#.utf8)) }
        let second = try box.file(box.models.appending(path: "blobs/sha256-\(box.digest(5))-partial"))
        let junk = [data, second] + parts

        let scan = await Scanner.scan(item, policy: box.policy)
        #expect(Set(scan.entries.map(\.url.lastPathComponent)) == Set(junk.map(\.lastPathComponent)))
        #expect(scan.size == junk.reduce(0) { $0 + Scanner.fileSize($1) } && scan.size > 300_000)
        // The models row never counts or removes them.
        let models = await Scanner.scan(try self.item, policy: box.policy)
        #expect(models.entries.map(\.url.lastPathComponent) == ["latest"])
        #expect(models.size == Scanner.fileSize(manifest) + Scanner.fileSize(box.blob(1)) + Scanner.fileSize(box.blob(2)))

        let report = await Cleaner.clean(item, scan: scan, policy: box.policy)
        #expect(report.skipped == 0 && report.freed == scan.size)
        #expect(!junk.contains(where: box.exists))
        #expect([manifest, box.blob(1), box.blob(2), orphan, key, other].allSatisfy(box.exists))
        #expect(await Scanner.scan(item, policy: box.policy).entries.isEmpty)
    }

    /// While `ollama` runs (a pull may be writing them), the row is locked: not ticked, not cleaned.
    @MainActor @Test func partialDownloadsKeptWhileOllamaRuns() async throws {
        let box = try Home()
        defer { box.remove() }
        let item = try partialItem
        let data = try box.file(box.models.appending(path: "blobs/sha256-\(box.digest(4))-partial"))
        let model = SmartScanModel(module: .smartScan) { [CleanerGroup(id: "g", title: "G", systemImage: "x", items: [item])] }
        model.appBundleIDs = { [] }
        model.runningApps = []
        model.processNames = { ["ollama", "zsh"] }
        let policy = box.policy // not this Mac's Exclusions, Trash or activity log
        model.logHome = box.home
        model.scanItem = { await Scanner.scan($0, policy: policy, openPaths: $1) }
        model.cleanItem = { await Cleaner.clean($0, scan: $1, policy: policy, openPaths: $2) }
        await model.scan()
        #expect(model.isRunning(item) && model.selected.isEmpty)
        model.selected = [item.id]
        await model.clean()
        guard case .done(let report) = model.phase else { Issue.record("not done"); return }
        #expect(report.skipped == 1 && box.exists(data))
        model.processNames = { ["zsh"] }
        await model.scan()
        #expect(!model.isRunning(item) && model.selected.isEmpty) // unticked by default
    }

    /// Orca and OrbStack: caches and logs only, skipped while the app (or a helper of OrbStack) runs.
    @Test func orcaAndOrbStackOnlyCachesAndLogs() throws {
        let orca = try #require(CleanerGroup.aiTools().items.first { $0.id == "orca" })
        #expect(orca.runningAppBundleIDs == ["com.stablyai.orca*"] && !orca.showsWhenEmpty)
        #expect(orca.runningProcessNames == ["orca-terminal-host"])
        let root = "~/Library/Application Support/orca/"
        let tops = Set(orca.paths.map { String($0.dropFirst(root.count).split(separator: "/").first ?? "") })
        #expect(tops.isSubset(of: ["Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache",
                                   "GraphiteDawnCache", "GrShaderCache", "ShaderCache", "GPUPersistentCache",
                                   "Service Worker", "*", "Partitions", "Crashpad", "logs"]))
        #expect(orca.paths.allSatisfy { $0.hasPrefix(root) } && orca.paths.contains(root + "logs"))
        let orb = try #require(CleanerGroup.developer.items.first { $0.id == "orbstack" })
        #expect(orb.paths == ["~/Library/Caches/dev.kdrag0n.MacVirt", "~/.orbstack/log"])
        #expect(orb.runningAppBundleIDs == ["dev.kdrag0n.MacVirt*"] && orb.skipsOpenFiles && orb.command == nil)
        #expect(CleanerGroup.ownedCachePaths.contains("dev.kdrag0n.MacVirt"))
    }
}
