import Foundation

/// Ollama's local models: `<models>/manifests/<registry>/<namespace>/<model>/<tag>` is a small JSON file naming the
/// layers of one model; the layers themselves are `<models>/blobs/sha256-<hex>`, shared by every model that uses them
/// (two tags of one model, a model made with `ollama create FROM` another). One entry per manifest; removing it also
/// removes the blobs no other manifest names (`ownBlobs`), which is what `ollama rm` does without needing the server.
/// A blob several models use counts once in the selected size when all of them are ticked (`blobs(of:)`), and goes
/// with the last of them removed.
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
    @Sendable static func ownBlobs(of manifest: URL) -> [URL] { blobs(of: manifest).own }

    /// `own`: as `ownBlobs`; `shared`: its other blobs, each with every manifest naming it (this one included).
    /// Both empty when `manifest` or another manifest can't be read.
    @Sendable static func blobs(of manifest: URL) -> EntryFiles {
        guard let manifests = manifestsFolder(of: manifest), let mine = digests(in: manifest), !mine.isEmpty,
              let others = FileManager.default.enumerator(at: manifests, includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsHiddenFiles]) else { return EntryFiles() }
        let path = manifest.standardizedFileURL.path
        var users: [String: Set<URL>] = [:]
        for case let url as URL in others where url.standardizedFileURL.path != path {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            guard let names = digests(in: url) else { return EntryFiles() }
            // Named below `manifests` as the scan names its entries (the enumerator may resolve `/var` to `/private/var`).
            let user = url.pathComponents.suffix(others.level).reduce(manifests) { $0.appending(path: $1) }
            for name in names.intersection(mine) { users[name, default: [manifest]].insert(user) }
        }
        let blobs = manifests.deletingLastPathComponent().appending(path: "blobs")
        return EntryFiles(own: mine.subtracting(users.keys).sorted().map { blobs.appending(path: $0) },
                          shared: Dictionary(uniqueKeysWithValues: users.map { (blobs.appending(path: $0.key), $0.value) }))
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
