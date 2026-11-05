import Foundation

/// Models that local AI apps downloaded, one row per model, unticked, moved to the Trash (files the user chose to
/// download, so Undo can bring them back), dated when last used (the later of the weight files' last read and change).
/// Each item is skipped while its app runs, and a model a program holds open is kept. Only files are read.
///
/// Where each app keeps them, from its documentation and source:
/// - llama.cpp: `LLAMA_CACHE`, else `~/Library/Caches/llama.cpp` (`~/.cache/llama.cpp` on Linux-style setups); a
///   model is a `*.gguf` at the top, with its `.etag`, `.json` and `.lock` side files. Newer builds download into the
///   Hugging Face cache instead (the Hugging Face item); `manifest=*.json` and `*.downloadInProgress` are kept.
/// - Jan: `<data>/llamacpp/models/<id>/` and `<data>/mlx/models/<id>/` (older: `<data>/models/<id>/`,
///   `~/jan/models/<id>/`), where `<data>` is `~/Library/Application Support/Jan/data` or the `data_folder` of Jan's
///   `settings.json`. A model is a folder holding `model.yml` (older: `model.json`) and its weights; an imported model
///   (settings pointing to a file elsewhere) has no weights there and is not listed.
/// - GPT4All: the `modelPath` of `~/.config/nomic.ai/GPT4All.ini`, else `~/Library/Application Support/nomic.ai/GPT4All`;
///   a model is a `*.gguf` at the top. Kept: `incomplete-*` (downloads not finished), chats, LocalDocs, logs.
/// - Draw Things: `~/Library/Containers/com.liuliu.draw-things/Data/Documents/Models` (only with Full Disk Access:
///   reading another app's container makes macOS ask); a model is a `*.ckpt` with its `*.ckpt-tensordata`. Kept: the
///   `custom*.json` lists. A models folder moved outside the container (a bookmark) is not read.
/// - ComfyUI: `<basePath>/models` of ComfyUI Desktop's `config.json` (by default in Documents: only with Full Disk
///   Access) and `~/ComfyUI/models` (a manual install); a model is a weight file in a category folder
///   (`checkpoints/x.safetensors`, up to two folders deeper). Kept: placeholders, configs, YAML and JSON files.
nonisolated enum LocalModels {
    /// Largest settings file read: real ones are a few KB.
    static let settingsLimit = 1 << 20

    enum App: CaseIterable, Sendable {
        case llamaCpp, jan, gpt4all, drawThings, comfyUI

        var id: String {
            switch self {
            case .llamaCpp: "llamacpp-models"
            case .jan: "jan-models"
            case .gpt4all: "gpt4all-models"
            case .drawThings: "drawthings-models"
            case .comfyUI: "comfyui-models"
            }
        }

        var name: String {
            switch self {
            case .llamaCpp: "llama.cpp"
            case .jan: "Jan"
            case .gpt4all: "GPT4All"
            case .drawThings: "Draw Things"
            case .comfyUI: "ComfyUI"
            }
        }

        /// Default models folders that need no Full Disk Access.
        var paths: [String] {
            switch self {
            case .llamaCpp: ["~/Library/Caches/llama.cpp", "~/.cache/llama.cpp"]
            case .jan: ["llamacpp/models", "mlx/models", "models"].map { LocalModels.janData + "/" + $0 } + ["~/jan/models"]
            case .gpt4all: ["~/Library/Application Support/nomic.ai/GPT4All"]
            case .drawThings: []
            case .comfyUI: ["~/ComfyUI/models"]
            }
        }

        /// Below each folder `configured` returns.
        var subpaths: [String] {
            switch self {
            case .jan: ["llamacpp/models", "mlx/models", "models"]
            case .comfyUI: ["models"]
            default: [""]
            }
        }

        /// Extensions of a model's weight files (lowercased).
        var weights: Set<String> {
            switch self {
            case .llamaCpp, .gpt4all: ["gguf"]
            case .jan: ["gguf", "safetensors", "bin"]
            case .drawThings: ["ckpt"]
            case .comfyUI: ["ckpt", "pt", "pt2", "pth", "bin", "safetensors", "sft", "pkl", "gguf", "onnx"]
            }
        }

        /// Folder levels between a models folder and a model (1: at its top).
        var depths: ClosedRange<Int> {
            switch self {
            case .llamaCpp, .gpt4all, .drawThings: 1...1
            case .jan: 1...3
            case .comfyUI: 2...4
            }
        }

        var bundleIDs: [String] {
            switch self {
            case .llamaCpp, .comfyUI: []
            case .jan: ["jan.ai.app"]
            case .gpt4all: ["gpt4all"]
            case .drawThings: ["com.liuliu.draw-things"]
            }
        }

        var processNames: [String] {
            switch self {
            case .llamaCpp: ["llama-server", "llama-cli", "llama-run", "llama-mtmd-cli"]
            case .jan: []
            case .gpt4all: ["gpt4all"]
            case .drawThings: []
            case .comfyUI: ["ComfyUI"]
            }
        }
    }

    static let janData = "~/Library/Application Support/Jan/data"
    /// Jan's settings (current, then before its rename), holding `data_folder` when the user moved its data.
    static let janSettings = ["Library/Application Support/Jan/settings.json", "Library/Application Support/jan.ai.app/settings.json"]
    static let gpt4allSettings = ".config/nomic.ai/GPT4All.ini"
    static let drawThingsModels = "Library/Containers/com.liuliu.draw-things/Data/Documents/Models"

    static var ids: [String] { App.allCases.map(\.id) }

    /// One model: `url` is its row, `parts` what goes to the Trash (`url` first), `weights` its weight files.
    struct Model: Equatable, Sendable {
        let url: URL
        let parts: [URL]
        let weights: [URL]
    }

    // MARK: - Folders

    /// Models folders the app's own settings or the shell profile name, as absolute paths (checked by the scan like a
    /// `shellFolders` folder), plus the defaults that need Full Disk Access. Without it, none inside a folder whose
    /// reading makes macOS ask (`ProtectedFolders`) is returned.
    static func configured(_ app: App, home: URL, hasFullDiskAccess: Bool) -> [String] {
        let found: [String]
        switch app {
        case .llamaCpp: found = [ShellEnvironment.cached(home: home)["LLAMA_CACHE"]].compactMap { $0 }
        case .jan: found = janSettings.compactMap { (settings(home.appending(path: $0)))?["data_folder"] as? String }
        case .gpt4all: found = [gpt4allModelPath(home: home)].compactMap { $0 }
        case .drawThings: found = [home.appending(path: drawThingsModels).path]
        case .comfyUI: found = CleanerGroup.comfyUIInstalls(home: home)
        }
        let skipped = ProtectedFolders.skipped(home: home, hasFullDiskAccess: hasFullDiskAccess)
        return found.filter { !$0.isEmpty && !ProtectedFolders.contains(skipped, URL(fileURLWithPath: $0)) }
    }

    /// `[General] modelPath=` of GPT4All's settings (Qt's ini format), quotes removed.
    static func gpt4allModelPath(home: URL) -> String? {
        guard let text = text(home.appending(path: gpt4allSettings)) else { return nil }
        var section = ""
        for line in text.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("[") { section = line; continue }
            guard section == "[General]", line.hasPrefix("modelPath=") else { continue }
            var value = String(line.dropFirst("modelPath=".count)).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// The app's models folders now: its defaults and the configured ones (checked like `ShellEnvironment.checkedFolder`),
    /// existing real folders not reached through a symlink, each once. The scan reads the same through the item's
    /// `paths` and `configFolders`; this is asked again for each model checked.
    static func roots(_ app: App, policy: SafetyPolicy, hasFullDiskAccess: Bool) -> [URL] {
        let defaults = app.paths.map(policy.expand)
        let configured = configured(app, home: policy.homeURL, hasFullDiskAccess: hasFullDiskAccess)
            .compactMap { ShellEnvironment.checkedFolder($0, policy: policy, allows: folderAllows(app)) }
            .flatMap { base in app.subpaths.map { $0.isEmpty ? base : base.appending(path: $0) } }
        var seen = Set<String>()
        let skipped = ProtectedFolders.skipped(home: policy.homeURL, hasFullDiskAccess: hasFullDiskAccess)
        return (defaults + configured).map(\.standardizedFileURL).filter {
            !ProtectedFolders.contains(skipped, $0) && isFolder($0) && !policy.rootThroughSymlink($0)
                && allows(app, policy, $0) && seen.insert($0.path).inserted
        }
    }

    /// ComfyUI's install may be in Documents or Desktop; every other app's folder is checked by `SafetyPolicy.allows`.
    static func folderAllows(_ app: App) -> (@Sendable (SafetyPolicy, URL) -> Bool)? {
        guard app == .comfyUI else { return nil }
        return { policy, url in policy.allowsInDocuments(url) }
    }

    private static func allows(_ app: App, _ policy: SafetyPolicy, _ url: URL) -> Bool {
        app == .comfyUI ? policy.allowsInDocuments(url) : policy.allows(url)
    }

    // MARK: - Listing

    /// The models of `app` in its models folder `root`.
    static func models(_ app: App, in root: URL) -> [Model] {
        func walk(_ folder: URL, depth: Int) -> [Model] {
            children(of: folder).flatMap { name -> [Model] in
                let url = folder.appending(path: name)
                if app.depths.contains(depth), let model = model(app, at: url) { return [model] }
                guard depth < app.depths.upperBound, isFolder(url) else { return [] }
                return walk(url, depth: depth + 1)
            }
        }
        return walk(root, depth: 1)
    }

    /// The model `url` is, by its own shape only (its place below a models folder is checked by `model(_:at:roots:)`).
    static func model(_ app: App, at url: URL) -> Model? {
        let name = url.lastPathComponent
        guard !name.hasPrefix(".") else { return nil }
        switch app {
        case .jan:
            guard isFolder(url), ["model.yml", "model.json"].contains(where: { isFile(url.appending(path: $0)) }) else { return nil }
            let weights = children(of: url).map { url.appending(path: $0) }.filter { isWeight($0, of: app) }
            return weights.isEmpty ? nil : Model(url: url, parts: [url], weights: weights)
        case .gpt4all:
            guard !name.lowercased().hasPrefix("incomplete"), isWeight(url, of: app) else { return nil }
            return Model(url: url, parts: [url], weights: [url])
        case .llamaCpp:
            guard isWeight(url, of: app) else { return nil }
            let sides = [".etag", ".json", ".lock"].map { URL(fileURLWithPath: url.path + $0) }.filter(isFile)
            return Model(url: url, parts: [url] + sides, weights: [url])
        case .drawThings:
            guard isWeight(url, of: app) else { return nil }
            let data = URL(fileURLWithPath: url.path + "-tensordata")
            return Model(url: url, parts: [url] + (isFile(data) || isFolder(data) ? [data] : []), weights: [url])
        case .comfyUI:
            guard isWeight(url, of: app) else { return nil }
            return Model(url: url, parts: [url], weights: [url])
        }
    }

    /// The model `url` is when it lies where `models(_:in:)` lists one in one of `roots`: at an allowed depth, every
    /// folder between a real, not hidden folder that is not a model itself.
    static func model(_ app: App, at url: URL, roots: [URL]) -> Model? {
        let path = url.standardizedFileURL.path
        for root in roots {
            let base = root.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { continue }
            let parts = path.dropFirst(base.count + 1).split(separator: "/").map(String.init)
            guard app.depths.contains(parts.count), !parts.contains(where: { $0.hasPrefix(".") }) else { continue }
            var folder = URL(fileURLWithPath: base)
            var ok = true
            for part in parts.dropLast() {
                folder.append(path: part)
                if !isFolder(folder) || model(app, at: folder) != nil { ok = false; break }
            }
            if ok, let model = model(app, at: URL(fileURLWithPath: path)) { return model }
        }
        return nil
    }

    static func find(_ app: App, policy: SafetyPolicy, hasFullDiskAccess: Bool) -> [URL] {
        roots(app, policy: policy, hasFullDiskAccess: hasFullDiskAccess).flatMap { models(app, in: $0) }
            .filter { $0.parts.allSatisfy { allows(app, policy, $0) } }.map(\.url)
    }

    /// The model at `url`, listed now with all its parts allowed; nil otherwise.
    static func listed(_ app: App, at url: URL, policy: SafetyPolicy, hasFullDiskAccess: Bool) -> Model? {
        guard let model = model(app, at: url, roots: roots(app, policy: policy, hasFullDiskAccess: hasFullDiskAccess)),
              model.parts.allSatisfy({ allows(app, policy, $0) }) else { return nil }
        return model
    }

    // MARK: - Labels

    /// The name the app shows (file name without its extension, Jan's model id, a ComfyUI file with its category),
    /// dated when last used.
    static func label(_ app: App, of url: URL) -> (title: String, date: Date?)? {
        guard let model = model(app, at: url) else { return nil }
        let parts = url.standardizedFileURL.pathComponents
        let title: String
        switch app {
        case .jan:
            // The model id: the path below its `models` folder (`author/name` for some).
            guard let index = parts.dropLast().lastIndex(of: "models") else { return (url.lastPathComponent, lastUsed(model)) }
            title = parts[(index + 1)...].joined(separator: "/")
        case .comfyUI:
            // The category folder right below `models` (`checkpoints`, `loras`).
            let index = parts.indices.last { parts[$0] == "models" && parts.count - $0 >= 3 }
            let file = url.lastPathComponent
            title = index.map { "\(file) (\(parts[$0 + 1]))" } ?? file
        default:
            title = url.deletingPathExtension().lastPathComponent
        }
        return (title, lastUsed(model))
    }

    /// The latest last read or change of the model's weight files: loading a model reads them, a download writes them.
    static func lastUsed(_ model: Model) -> Date? {
        model.weights.compactMap { url -> Date? in
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(max(info.st_atimespec.tv_sec, info.st_mtimespec.tv_sec)))
        }.max()
    }

    // MARK: - Item

    /// `hasFullDiskAccess`: also the folders inside one macOS asks about (Draw Things' container, a ComfyUI install in
    /// Documents).
    static func item(_ app: App, hasFullDiskAccess: Bool) -> CleanerItem {
        CleanerItem(id: app.id, title: "\(app.name): downloaded models", note: note(app), paths: app.paths, mode: .trash,
                    selectedByDefault: false,
                    configFolders: ConfigFolders(read: { configured(app, home: $0, hasFullDiskAccess: hasFullDiskAccess) },
                                                 subpaths: app.subpaths, allows: folderAllows(app)),
                    showsWhenEmpty: false, runningAppBundleIDs: app.bundleIDs, runningProcessNames: app.processNames,
                    skipsOpenFiles: true, entryLabel: { label(app, of: $0) }, selectableEntries: true,
                    findEntries: { _, policy in find(app, policy: policy, hasFullDiskAccess: hasFullDiskAccess) },
                    allowsEntry: { policy, url in listed(app, at: url, policy: policy, hasFullDiskAccess: hasFullDiskAccess) != nil },
                    entryParts: { policy, url in
                        listed(app, at: url, policy: policy, hasFullDiskAccess: hasFullDiskAccess)?.parts ?? []
                    },
                    about: about(app), afterClean: afterClean(app))
    }

    private static func note(_ app: App) -> LocalizedStringResource {
        switch app {
        case .llamaCpp: "Models llama.cpp downloaded; downloaded again when you run it with the same model"
        case .jan: "Models downloaded in Jan; downloaded again from its Hub"
        case .gpt4all: "Models downloaded in GPT4All; downloaded again from its Models page"
        case .drawThings: "Image models downloaded in Draw Things; downloaded again from its model list"
        case .comfyUI: "Model files in ComfyUI's models folder; downloaded again from where you got them"
        }
    }

    private static func about(_ app: App) -> LocalizedStringResource {
        switch app {
        case .llamaCpp:
            "A model file llama.cpp downloaded into its own cache (llama-cli or llama-server with -hf or a model URL), with the files that record where it came from. Your settings are kept."
        case .jan:
            "A model Jan downloaded from its Hub, with its settings file. Your chats, assistants and Jan's settings are kept; a model you imported from a file elsewhere is not listed."
        case .gpt4all:
            "A model file GPT4All downloaded. Your chats, LocalDocs collections and settings are kept, and so are downloads not finished."
        case .drawThings:
            "A model Draw Things downloaded (an image model, a LoRA, an encoder or an upscaler) with its tensor data. Your images, projects and settings are kept."
        case .comfyUI:
            "A model file in the models folder of a ComfyUI install (a checkpoint, LoRA, VAE or upscaler). Your workflows, images, custom nodes and settings are kept."
        }
    }

    private static func afterClean(_ app: App) -> LocalizedStringResource {
        switch app {
        case .llamaCpp:
            "Moved to the Trash. llama.cpp downloads the model again from Hugging Face the next time you start it with the same -hf model or URL."
        case .jan: "Moved to the Trash. Download the model again from Jan's Hub."
        case .gpt4all: "Moved to the Trash. Download the model again from the Models page in GPT4All."
        case .drawThings:
            "Moved to the Trash. Pick the model again in Draw Things to download it; a model you imported must be imported again."
        case .comfyUI:
            "Moved to the Trash. Download the model again with ComfyUI Manager, or from Hugging Face or Civitai, into the same models folder."
        }
    }

    // MARK: - Files

    private static func children(of url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    /// A real folder (not a symlink).
    private static func isFolder(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    /// A regular file (not a symlink).
    private static func isFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }

    /// A regular, not hidden file with one of the app's weight extensions.
    private static func isWeight(_ url: URL, of app: App) -> Bool {
        !url.lastPathComponent.hasPrefix(".") && app.weights.contains(url.pathExtension.lowercased()) && isFile(url)
    }

    /// A regular file of at most `settingsLimit`, as text.
    private static func text(_ url: URL) -> String? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= settingsLimit,
              let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// A regular file of at most `settingsLimit` holding a JSON object.
    private static func settings(_ url: URL) -> [String: Any]? {
        text(url).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }
}
