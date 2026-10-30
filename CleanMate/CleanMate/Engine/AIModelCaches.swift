import Foundation

/// Models Python libraries download on first use and load from disk afterwards: PyTorch Hub checkpoints
/// (`torch.hub.load_state_dict_from_url`), Whisper's `*.pt` files, sentence-transformers' model folders (its cache
/// before v3; newer versions use the Hugging Face cache, its own item) and Keras' `models` and `datasets` folders.
/// One entry per model file or folder, removed whole: the library downloads it again when a program loads it.
/// Where each library looks: `TORCH_HOME` (default `$XDG_CACHE_HOME/torch`), `$XDG_CACHE_HOME/whisper`,
/// `SENTENCE_TRANSFORMERS_HOME` (default `$TORCH_HOME/sentence_transformers`), `KERAS_HOME` (default `~/.keras`).
/// The rest of these folders (torch's `hub` repo checkouts and `kernels`, `keras.json`) is never listed.
nonisolated enum AIModelCaches {
    static let id = "ai-model-caches"

    enum Kind: Sendable {
        /// Each file in `hub/checkpoints`.
        case torchHub
        /// Each `*.pt` file.
        case whisper
        /// Each model folder (holding `modules.json` or `config_sentence_transformers.json`).
        case sentenceTransformers
        /// The `models` and `datasets` folders.
        case keras
    }

    /// A folder the entries of one kind sit in: `path` under home (`variable` nil) or below a profile variable's folder.
    struct Source: Sendable {
        let variable: String?
        let path: String
        let kind: Kind
    }

    static let sources: [Source] = [
        Source(variable: nil, path: "~/.cache/torch/hub/checkpoints", kind: .torchHub),
        Source(variable: nil, path: "~/.cache/whisper", kind: .whisper),
        Source(variable: nil, path: "~/.cache/torch/sentence_transformers", kind: .sentenceTransformers),
        Source(variable: nil, path: "~/.keras", kind: .keras),
        Source(variable: "TORCH_HOME", path: "hub/checkpoints", kind: .torchHub),
        Source(variable: "TORCH_HOME", path: "sentence_transformers", kind: .sentenceTransformers),
        Source(variable: "XDG_CACHE_HOME", path: "torch/hub/checkpoints", kind: .torchHub),
        Source(variable: "XDG_CACHE_HOME", path: "torch/sentence_transformers", kind: .sentenceTransformers),
        Source(variable: "XDG_CACHE_HOME", path: "whisper", kind: .whisper),
        Source(variable: "SENTENCE_TRANSFORMERS_HOME", path: "", kind: .sentenceTransformers),
        Source(variable: "KERAS_HOME", path: "", kind: .keras),
    ]
    static let paths = sources.filter { $0.variable == nil }.map(\.path)
    static let shellFolders: [String: [String]] = Dictionary(grouping: sources.compactMap { source in
        source.variable.map { ($0, source.path) }
    }, by: { $0.0 }).mapValues { $0.map { $0.1 } }

    static let kerasFolders: Set<String> = ["models", "datasets"]
    /// Files only a sentence-transformers model folder has: a folder set by mistake (`~/Developer`) lists nothing.
    static let sentenceTransformersMarkers = ["modules.json", "config_sentence_transformers.json"]

    /// The kind of entries each folder holds, by path (`/private` left out). A folder two kinds point to (two variables
    /// set to the same folder) holds none: which library owns it is unknown.
    static func kinds(policy: SafetyPolicy) -> [String: Kind] {
        let env = ShellEnvironment.cached(home: policy.homeURL)
        var found: [String: Set<Kind>] = [:]
        for source in sources {
            let base: String
            if let variable = source.variable {
                guard let value = env[variable], value.hasPrefix("/") else { continue }
                base = source.path.isEmpty ? value : value + "/" + source.path
            } else {
                base = policy.expand(source.path).path
            }
            found[key(base), default: []].insert(source.kind)
        }
        return found.compactMapValues { $0.count == 1 ? $0.first : nil }
    }

    /// Replaces `SafetyPolicy.allows` for the item's entries, at scan and before removal: allowed, and an entry of the
    /// kind its folder holds.
    @Sendable static func allows(_ policy: SafetyPolicy, _ url: URL) -> Bool {
        guard policy.allows(url), let kind = kinds(policy: policy)[key(url.deletingLastPathComponent().path)] else { return false }
        return accepts(url, kind)
    }

    /// Whether `url` is an entry of `kind`: never a hidden name or a symlink.
    static func accepts(_ url: URL, _ kind: Kind) -> Bool {
        let name = url.lastPathComponent
        guard !name.hasPrefix(".") else { return false }
        switch kind {
        case .torchHub: return isFile(url)
        case .whisper: return url.pathExtension == "pt" && isFile(url)
        case .sentenceTransformers: return isFolder(url) && isSentenceTransformersModel(url)
        case .keras: return kerasFolders.contains(name) && isFolder(url)
        }
    }

    /// `<name> — <library>` (a Whisper model without `.pt`); date = when it was downloaded (last modified).
    static func label(of url: URL) -> (title: String, date: Date?)? {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let name = url.lastPathComponent
        if isFolder(url) {
            return (name + " — " + (isSentenceTransformersModel(url) ? "sentence-transformers" : "Keras"), date)
        }
        if url.deletingLastPathComponent().lastPathComponent == "checkpoints" { return (name + " — PyTorch Hub", date) }
        return (url.deletingPathExtension().lastPathComponent + " — Whisper", date)
    }

    static func isSentenceTransformersModel(_ url: URL) -> Bool {
        sentenceTransformersMarkers.contains { isFile(url.appending(path: $0)) }
    }

    private static func key(_ path: String) -> String {
        RunningProcesses.withoutPrivate(URL(fileURLWithPath: path).standardizedFileURL.path)
    }

    private static func isFile(_ url: URL) -> Bool { fileType(url) == S_IFREG }
    private static func isFolder(_ url: URL) -> Bool { fileType(url) == S_IFDIR }
    private static func fileType(_ url: URL) -> mode_t? {
        var info = stat()
        return lstat(url.path, &info) == 0 ? info.st_mode & S_IFMT : nil
    }
}
