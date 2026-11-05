import Foundation

/// "Other caches in ~/.cache": the folders command-line tools keep in `~/.cache` (node-gyp, electron, nx, expo…) that
/// no other item names, one unticked row each, deleted (the tool makes them again). Folders another item owns are
/// left to that item (`ownedNames`), so nothing is counted twice and their own rules (only part of a folder, a
/// process lock) still hold. Folders holding sign-ins (`gh`, `gcloud`, `op`, Hugging Face's token…) are never-touch
/// trees of `SafetyPolicy`, so no item lists them. A folder a program has a file open in is kept.
nonisolated enum DotCaches {
    static let id = "other-dot-caches"
    static let folder = "~/.cache"

    /// Top-level `~/.cache` names other items scan (their paths, and the `XDG_CACHE_HOME` folders they read).
    static func ownedNames(of items: [CleanerItem]) -> Set<String> {
        Set(items.filter { $0.id != id }.flatMap { item -> [String] in
            let paths = item.paths.compactMap { path -> String? in
                guard path.hasPrefix(folder + "/") else { return nil }
                return String(path.dropFirst(folder.count + 1))
            }
            return paths + (item.shellFolders["XDG_CACHE_HOME"] ?? [])
        }.compactMap { path in
            path.split(separator: "/").first.map(String.init).flatMap { $0.contains("*") || $0.isEmpty ? nil : $0 }
        })
    }

    static func item(owned: Set<String>) -> CleanerItem {
        CleanerItem(id: id, title: "Other caches in ~/.cache",
                    note: "One row per tool; not ticked by default",
                    paths: [folder], excluded: owned, selectedByDefault: false, showsWhenEmpty: false,
                    skipsOpenFiles: true, skipsEntry: { skips },
                    skipNote: "Files and hidden names directly in ~/.cache",
                    selectableEntries: true,
                    about: "Caches command-line tools keep in ~/.cache that CleanMate has no item of its own for (node-gyp, Electron, Playwright, Expo…), one row per tool. Each tool downloads or builds them again when it needs them; folders holding sign-ins are never listed")
    }

    /// Only real folders: a file, a symlink or a hidden name directly in `~/.cache` is skipped.
    @Sendable static func skips(_ url: URL) -> Bool {
        var info = stat()
        return url.lastPathComponent.hasPrefix(".") || lstat(url.path, &info) != 0 || info.st_mode & S_IFMT != S_IFDIR
    }
}
