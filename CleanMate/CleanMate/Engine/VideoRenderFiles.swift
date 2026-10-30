import Foundation

/// Render files of Final Cut Pro and iMovie libraries: often many GB per library, and the app renders them again when
/// a project is played or exported. One entry per library (a `*.fcpbundle` or `*.imovielibrary` in Movies, Desktop or
/// Documents, or one folder down), measured as the total of its events' `Render Files` folders; unticked, so people
/// keep the renders of projects they are working on, and deleted (regenerable). Only the `Render Files` folders go
/// (`SafetyPolicy.allowsRenderFiles`, through `CleanerItem.entryParts`), never the library, its media (`Original
/// Media`, `Transcoded Media`), databases (`CurrentVersion.fcpevent`, `CurrentVersion.flexolibrary`) or anything
/// else. Skipped while Final Cut Pro or iMovie runs. Libraries on other drives, and every library without Full Disk
/// Access (macOS asks before listing these folders, `ProtectedFolders`), are not scanned.
nonisolated enum VideoRenderFiles {
    static let id = "video-render-files"
    static let renderFolder = "Render Files"
    static let libraryExtensions: Set = ["fcpbundle", "imovielibrary"]
    static let folders = ["~/Movies", "~/Desktop", "~/Documents"]
    /// `folders` as the first path component below the home folder, lowercased (APFS ignores case).
    static let folderNames: Set = ["movies", "desktop", "documents"]
    /// Final Cut Pro and its trial (`com.apple.FinalCutTrial`), iMovie.
    static let bundleIDs = ["com.apple.FinalCut*", "com.apple.iMovieApp"]
    static let processNames = ["Final Cut Pro*", "iMovie"]

    /// The Smart Scan item. `hasFullDiskAccess` is injected by tests.
    static func item(hasFullDiskAccess: @escaping @Sendable () -> Bool = { FullDiskAccess.isGranted }) -> CleanerItem {
        CleanerItem(id: id, title: "Final Cut Pro and iMovie render files",
                    note: "Rendered again when a project is played or exported; the first open is slower",
                    paths: folders, selectedByDefault: false, showsWhenEmpty: false,
                    runningAppBundleIDs: bundleIDs, runningProcessNames: processNames, skipsOpenFiles: true,
                    entryLabel: label(of:), selectableEntries: true,
                    findEntries: { roots, policy in
                        libraries(in: roots, home: policy.homeURL, hasFullDiskAccess: hasFullDiskAccess())
                    },
                    allowsEntry: { $0.allowsVideoLibrary($1) },
                    entryParts: { policy, library in renderFolders(in: library).filter(policy.allowsRenderFiles) })
    }

    /// `name` is a Final Cut Pro or iMovie library's (not hidden).
    static func isLibrary(_ name: String) -> Bool {
        !name.hasPrefix(".") && libraryExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// Libraries directly in each of `roots` or in a folder there (not hidden, not a package, not a symlink). Roots
    /// macOS guards are skipped without Full Disk Access.
    static func libraries(in roots: [URL], home: URL, hasFullDiskAccess: Bool) -> [URL] {
        let skipped = ProtectedFolders.skipped(home: home, hasFullDiskAccess: hasFullDiskAccess)
        func children(_ folder: URL) -> [URL] {
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
                .filter { !$0.hasPrefix(".") }.map { folder.appending(path: $0) }
                .filter { url in var info = stat(); return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR }
        }
        var found: [URL] = []
        for root in roots where !ProtectedFolders.contains(skipped, root) {
            for child in children(root) {
                if isLibrary(child.lastPathComponent) { found.append(child); continue }
                guard (try? child.resourceValues(forKeys: [.isPackageKey]))?.isPackage == false else { continue }
                found += children(child).filter { isLibrary($0.lastPathComponent) }
            }
        }
        return found
    }

    /// `Render Files` of each event in `library` that exists (checked by `SafetyPolicy.allowsRenderFiles` afterwards).
    static func renderFolders(in library: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(atPath: library.path)) ?? []).sorted()
            .filter { !$0.hasPrefix(".") }.map { library.appending(path: $0).appending(path: renderFolder) }
            .filter { url in var info = stat(); return lstat(url.path, &info) == 0 }
    }

    /// `<library> — Final Cut Pro` / `— iMovie`, dated by the newest change to the library or a folder directly in it
    /// (an event, the library database).
    static func label(of library: URL) -> (title: String, date: Date?)? {
        let app = library.pathExtension.lowercased() == "imovielibrary" ? "iMovie" : "Final Cut Pro"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: library.path)) ?? []
        let date = ([library] + names.map { library.appending(path: $0) }).compactMap { url -> Date? in
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
        }.max()
        return (library.deletingPathExtension().lastPathComponent + " — " + app, date)
    }
}
