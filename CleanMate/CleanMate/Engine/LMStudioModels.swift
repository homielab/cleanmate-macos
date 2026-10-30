import Foundation

/// LM Studio's downloaded models: `<models>/<publisher>/<model>/` holds the files of one model (GGUF or MLX weights,
/// as on Hugging Face). One entry per model folder, removed whole: LM Studio downloads it again from Discover.
/// Its models folder is `~/.lmstudio/models` (`~/.cache/lm-studio/models` in older versions), or the one chosen in
/// My Models, kept as `downloadsFolder` in its `settings.json`. The rest of `~/.lmstudio` (settings, conversations,
/// extensions, the `lms` CLI, hub, `.internal`) is never listed.
nonisolated enum LMStudioModels {
    /// One level per publisher; the entries are the model folders inside.
    static let paths = ["~/.lmstudio/models/*", "~/.cache/lm-studio/models/*"]
    /// LM Studio's settings files (current, then older versions) and the key naming a models folder moved in My Models.
    static let settingsFiles = [".lmstudio/settings.json", ".cache/lm-studio/settings.json"]
    static let settingsKey = "downloadsFolder"
    /// Largest settings file read: real ones are a few KB.
    static let settingsLimit = 1 << 20

    /// The app, its CLI (`lms`), its headless daemon (`llmster`) and the app's own processes: any of them may have a
    /// model loaded or be downloading one.
    static let bundleIDs = ["ai.elementlabs.lmstudio"]
    static let processNames = ["lms", "llmster", "LM Studio", "LM Studio Helper"]

    /// Models folders named in LM Studio's settings files under `home`, as written (checked by the scan like a
    /// `shellFolders` folder). A settings file that is not a regular file, too large or not a JSON object names none.
    @Sendable static func configuredFolders(home: URL) -> [String] {
        settingsFiles.compactMap { name in
            let path = home.appending(path: name).path
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= settingsLimit,
                  let data = FileManager.default.contents(atPath: path),
                  let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let folder = settings[settingsKey] as? String, !folder.isEmpty else { return nil }
            return folder
        }
    }

    /// Only real model folders: a hidden name (`.DS_Store`, `.internal`), a file or a symlink is skipped.
    @Sendable static func skips(_ url: URL) -> Bool {
        var info = stat()
        return url.lastPathComponent.hasPrefix(".") || lstat(url.path, &info) != 0 || info.st_mode & S_IFMT != S_IFDIR
    }

    /// `publisher/model` as LM Studio's My Models shows it; date = when the folder last changed (downloaded).
    static func label(of model: URL) -> (title: String, date: Date?)? {
        let publisher = model.deletingLastPathComponent().lastPathComponent
        guard !publisher.isEmpty, publisher != "/" else { return nil }
        let date = (try? model.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return (publisher + "/" + model.lastPathComponent, date)
    }
}
