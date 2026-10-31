import Foundation

/// Old versions of the extensions of VS Code and its forks. Each extension update installs the new version next to the
/// old one in `~/.vscode/extensions` (`<publisher>.<name>-<version>[-<platform>]`), and the old folders often stay:
/// 100–500 MB a version for the large ones (Pylance, C/C++, Copilot). One entry per extension and editor, measured as
/// the total of its old versions (`CleanerItem.entryParts`); unticked, deleted (the editor keeps the version in use and
/// can install any version again). Skipped while one of the editors runs.
/// Old = a version with a higher version of the same extension in the same folder that is not marked obsolete, or one
/// the editor marked obsolete in `.obsolete` (uninstalled or replaced, removed by the editor at its next start). A
/// version `extensions.json` names is never old. Never touched: `extensions.json`, `.obsolete`, the newest version
/// still installed, folders not named like an extension version, symlinks.
nonisolated enum EditorExtensions {
    static let id = "editor-old-extensions"
    /// The editor's folder in the home folder, with the name shown in an entry's label.
    static let editors: [(folder: String, name: String)] = [
        (".vscode", "VS Code"), (".vscode-insiders", "VS Code Insiders"), (".vscode-oss", "VSCodium"),
        (".cursor", "Cursor"), (".windsurf", "Windsurf"),
    ]
    static let paths = editors.map { "~/\($0.folder)/extensions" }
    static let obsoleteFile = ".obsolete"
    static let installedFile = "extensions.json"
    /// VS Code's target platforms, the optional last part of a platform-specific extension's folder name.
    static let platforms: Set = ["darwin-x64", "darwin-arm64", "linux-x64", "linux-arm64", "linux-armhf", "alpine-x64",
                                 "alpine-arm64", "win32-x64", "win32-arm64", "win32-ia32", "web", "universal"]
    /// Largest `.obsolete` or `extensions.json` read (a few KB to a few hundred KB in practice).
    static let fileLimit = 8 << 20

    /// An extension version folder's name, parsed.
    struct Version: Equatable {
        /// `<publisher>.<name>` as written in the folder name.
        let extensionID: String
        let numbers: [Int]
        /// `extensionID` lowercased: the same extension whatever the case.
        var key: String { extensionID.lowercased() }
    }

    /// `ms-python.python-2024.4.1` or `ms-vscode.cpptools-1.20.5-darwin-arm64`; nil for anything else (`extensions.json`,
    /// `.obsolete`, a folder being installed).
    static func parse(_ name: String) -> Version? {
        guard let match = name.wholeMatch(of: /([A-Za-z0-9][A-Za-z0-9-]*\.[A-Za-z0-9][A-Za-z0-9-]*)-(\d{1,9})\.(\d{1,9})\.(\d{1,9})(?:-([a-z0-9]+(?:-[a-z0-9]+)?))?/),
              match.5.map({ platforms.contains(String($0)) }) ?? true,
              let major = Int(match.2), let minor = Int(match.3), let patch = Int(match.4) else { return nil }
        return Version(extensionID: String(match.1), numbers: [major, minor, patch])
    }

    /// Real folders (not symlinks) directly in `root` named like an extension version.
    static func versions(in root: URL) -> [(url: URL, version: Version)] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted().compactMap { name in
            guard let version = parse(name) else { return nil }
            let url = root.appending(path: name)
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
            return (url, version)
        }
    }

    /// Folder names (lowercased) the editor marked obsolete: `.obsolete` is a JSON map of folder name to `true`.
    static func obsolete(in root: URL) -> Set<String> {
        guard let map = json(root.appending(path: obsoleteFile)) as? [String: Any] else { return [] }
        return Set(map.compactMap { $0.value as? Bool == true ? $0.key.lowercased() : nil })
    }

    /// Folder names (lowercased) of the installed extensions `extensions.json` lists (`relativeLocation`, or the last
    /// part of `location`).
    static func installed(in root: URL) -> Set<String> {
        guard let list = json(root.appending(path: installedFile)) as? [[String: Any]] else { return [] }
        return Set(list.flatMap { entry -> [String] in
            var paths = [entry["relativeLocation"] as? String, entry["location"] as? String]
            if let location = entry["location"] as? [String: Any] {
                paths += [location["path"] as? String, location["fsPath"] as? String]
            }
            return paths.compactMap { $0 }.map { ($0 as NSString).lastPathComponent.lowercased() }.filter { !$0.isEmpty }
        })
    }

    /// The old version folders in `root`, by extension (`Version.key`).
    static func oldVersions(in root: URL) -> [String: [URL]] {
        let found = versions(in: root)
        guard !found.isEmpty else { return [:] }
        let obsolete = obsolete(in: root), installed = installed(in: root)
        let current = found.filter { !obsolete.contains($0.url.lastPathComponent.lowercased()) }
        var old: [String: [URL]] = [:]
        for (url, version) in found where !installed.contains(url.lastPathComponent.lowercased()) {
            let replaced = current.contains {
                $0.version.key == version.key && version.numbers.lexicographicallyPrecedes($0.version.numbers)
            }
            if replaced || obsolete.contains(url.lastPathComponent.lowercased()) { old[version.key, default: []].append(url) }
        }
        return old
    }

    /// `folder` is the extensions folder of one of `editors` in `home`.
    static func isExtensionsFolder(_ folder: URL, home: URL) -> Bool {
        let path = folder.standardizedFileURL.path
        return editors.contains { home.appending(path: $0.folder + "/extensions").standardizedFileURL.path == path }
    }

    /// One entry per extension in each of `roots`: its highest old version, standing for all of them.
    static func find(in roots: [URL], policy: SafetyPolicy) -> [URL] {
        roots.filter { isExtensionsFolder($0, home: policy.homeURL) }.flatMap { root in
            oldVersions(in: root).values.compactMap { urls -> URL? in
                urls.filter(policy.allows).max { a, b in
                    let x = parse(a.lastPathComponent)?.numbers ?? [], y = parse(b.lastPathComponent)?.numbers ?? []
                    return x == y ? a.lastPathComponent < b.lastPathComponent : x.lexicographicallyPrecedes(y)
                }
            }
        }.sorted { $0.path < $1.path }
    }

    /// An entry `find` gives: a folder named like an extension version in an editor's extensions folder that is not
    /// reached through a symlink.
    static func allowsEntry(_ entry: URL, policy: SafetyPolicy) -> Bool {
        let root = entry.deletingLastPathComponent()
        return parse(entry.lastPathComponent) != nil && isExtensionsFolder(root, home: policy.homeURL)
            && !policy.rootThroughSymlink(root) && policy.allows(entry)
    }

    /// The old versions of `entry`'s extension, listed again from disk (asked at scan and right before removal).
    static func parts(of entry: URL, policy: SafetyPolicy) -> [URL] {
        let root = entry.deletingLastPathComponent()
        guard allowsEntry(entry, policy: policy), let version = parse(entry.lastPathComponent) else { return [] }
        return (oldVersions(in: root)[version.key] ?? []).filter(policy.allows)
    }

    /// `<publisher>.<name> — <editor> · N old versions`, dated by the newest old version.
    static func label(of entry: URL) -> (title: String, date: Date?)? {
        let root = entry.deletingLastPathComponent()
        guard let version = parse(entry.lastPathComponent) else { return nil }
        let folder = root.deletingLastPathComponent().lastPathComponent
        let editor = editors.first { $0.folder == folder }?.name ?? folder
        let count = max(1, oldVersions(in: root)[version.key]?.count ?? 0)
        let date = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return ("\(version.extensionID) — \(editor) · " + String(localized: "\(count) old versions"), date)
    }

    /// The Smart Scan item.
    static func item() -> CleanerItem {
        CleanerItem(id: id, title: "Old versions of code editor extensions",
                    note: "Versions left behind by extension updates in VS Code, Cursor, Windsurf and VSCodium; the version in use is kept",
                    paths: paths, selectedByDefault: false, showsWhenEmpty: false,
                    runningAppBundleIDs: EditorWorkspaces.bundleIDs, runningProcessNames: EditorWorkspaces.processNames,
                    skipsOpenFiles: true, entryLabel: label(of:), selectableEntries: true,
                    findEntries: { roots, policy in find(in: roots, policy: policy) },
                    allowsEntry: { policy, url in allowsEntry(url, policy: policy) },
                    entryParts: { policy, entry in parts(of: entry, policy: policy) })
    }

    /// A regular file of at most `fileLimit` (not through a symlink) parsed as JSON; nil otherwise.
    private static func json(_ file: URL) -> Any? {
        var info = stat()
        guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= fileLimit,
              let data = FileManager.default.contents(atPath: file.path) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
