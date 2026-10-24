import Foundation

/// Ollama's local models: `<models>/manifests/<registry>/<namespace>/<model>/<tag>` is a small JSON file naming the
/// layers of one model; the layers themselves are `<models>/blobs/sha256-<hex>`, shared by every model that uses them
/// (two tags of one model, a model made with `ollama create FROM` another). One entry per manifest; removing it also
/// removes the blobs no other manifest names (`ownBlobs`), which is what `ollama rm` does without needing the server.
/// shortcut: a blob shared by several models counts in none of their sizes, so removing all of them frees a bit more.
nonisolated enum OllamaModels {
    /// One level per manifest path component under `manifests`: registry, namespace, model; the entries are tags.
    static let manifestFolders = "~/.ollama/models/manifests/*/*/*"
    /// The same below `OLLAMA_MODELS` (the models folder itself).
    static let shellFolders = ["OLLAMA_MODELS": ["manifests/*/*/*"]]

    /// Downloads `ollama pull` left unfinished: the data written so far, `blobs/sha256-<hex>-partial` (renamed to the
    /// blob when done), and the state of each download part, `…-partial-<n>` (removed when done). No manifest names
    /// them; a pull started again downloads them anew.
    static let partialFolder = "~/.ollama/models/blobs"
    static let partialShellFolders = ["OLLAMA_MODELS": ["blobs"]]
    static let partialNames = ["sha256-*-partial", "sha256-*-partial-*"]

    /// Largest manifest read: real ones are about 1 KB; anything bigger is not one.
    static let manifestLimit = 1 << 20

    /// `llama3.2:latest`, `user/model:tag`, or `hf.co/user/model:tag` as `ollama list` shows it; date = when pulled.
    static func label(of manifest: URL) -> (title: String, date: Date?)? {
        let parts = manifest.pathComponents.suffix(4)
        guard parts.count == 4 else { return nil }
        let (registry, namespace, model, tag) = (parts[parts.startIndex], parts[parts.startIndex + 1],
                                                 parts[parts.startIndex + 2], parts[parts.startIndex + 3])
        let name = registry == "registry.ollama.ai"
            ? (namespace == "library" ? model : namespace + "/" + model)
            : [registry, namespace, model].joined(separator: "/")
        let date = (try? manifest.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return (name + ":" + tag, date)
    }

    /// `<models>/manifests` of a manifest at `<models>/manifests/<registry>/<namespace>/<model>/<tag>`.
    static func manifestsFolder(of manifest: URL) -> URL? {
        let folder = (0..<4).reduce(manifest) { url, _ in url.deletingLastPathComponent() }
        return folder.lastPathComponent == "manifests" ? folder : nil
    }

    /// Blobs of `manifest` that no other manifest of the same models folder names. Empty when `manifest` is not a
    /// readable manifest, or when another manifest can't be read (what it uses is unknown, so every blob is kept).
    @Sendable static func ownBlobs(of manifest: URL) -> [URL] {
        guard let manifests = manifestsFolder(of: manifest), let own = digests(in: manifest), !own.isEmpty,
              let others = FileManager.default.enumerator(at: manifests, includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsHiddenFiles]) else { return [] }
        let path = manifest.standardizedFileURL.path
        var used = Set<String>()
        for case let url as URL in others where url.standardizedFileURL.path != path {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            guard let names = digests(in: url) else { return [] }
            used.formUnion(names)
        }
        let blobs = manifests.deletingLastPathComponent().appending(path: "blobs")
        return own.subtracting(used).sorted().map { blobs.appending(path: $0) }
    }

    /// Blob file names (`sha256-<64 hex>`) of a manifest's config and layers; nil when it is not a regular file
    /// (a symlink, a folder), too large, or not a manifest. A digest of any other form is not a blob name.
    static func digests(in manifest: URL) -> Set<String>? {
        struct Layer: Decodable { let digest: String }
        struct Manifest: Decodable { let config: Layer?; let layers: [Layer] }
        var info = stat()
        guard lstat(manifest.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= manifestLimit,
              let data = FileManager.default.contents(atPath: manifest.path),
              let parsed = try? JSONDecoder().decode(Manifest.self, from: data) else { return nil }
        return Set(([parsed.config].compactMap { $0 } + parsed.layers).compactMap { layer in
            guard let match = layer.digest.wholeMatch(of: #/sha256[:-]([0-9a-fA-F]{64})/#) else { return nil }
            return "sha256-" + match.1.lowercased()
        })
    }
}
