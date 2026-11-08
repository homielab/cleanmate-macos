import Foundation

/// Caches of the creative apps — photo, video and design — that keep theirs outside the patterns the generic
/// items cover: Adobe Camera Raw (shared by Photoshop and Lightroom Classic), Capture One, DaVinci Resolve's
/// render cache (the one folder in ~/Movies CleanMate touches), Blender, Sketch and Affinity. Only what the app
/// makes again on its own is cleaned — never a catalog, a library, a project, presets or a document — each item
/// unticked (the next open or playback is slower), deleted (regenerable) and skipped while the app runs.
///
/// Not listed: Lightroom Classic's preview caches (`*.lrdata`/`.lrcat-data`) — they sit next to the user's
/// catalog in a never-touch tree, which catalog a preview folder belongs to cannot be told without reading the
/// catalog, and finding catalogs needs a Spotlight sweep; Capture One's catalog previews — they live inside the
/// catalog and are never touched; DaVinci Resolve's Gallery stills and proxy media — user data, or media whose
/// folder the project picks, so there is no default to read; Blender folders of versions no longer installed
/// hold settings beside their cache and cannot be told from the installed one's without running Blender.
nonisolated enum CreativeAppCaches {
    /// Adobe Camera Raw's preview cache, shared by Photoshop and Lightroom Classic, often tens of GB. The folder
    /// the user picks in Camera Raw's own preferences is not scanned: its preference key is not documented, and a
    /// folder on another volume would be refused by the safety policy anyway.
    static let cameraRaw = CleanerItem(
        id: "camera-raw-cache", title: "Adobe Camera Raw cache",
        note: "Preview renders of raw files Photoshop and Lightroom Classic share; made again when a photo is opened again. Photos are kept",
        paths: ["~/Library/Caches/Adobe Camera Raw"], selectedByDefault: false, showsWhenEmpty: false,
        runningAppBundleIDs: ["com.adobe.Photoshop*", "com.adobe.LightroomClassic*", "com.adobe.Lightroom*"],
        runningProcessNames: ["Adobe Photoshop*", "Lightroom*", "Adobe Lightroom*"], skipsOpenFiles: true,
        about: "The previews Camera Raw makes of your raw photos so they open quickly, in one cache Photoshop and Lightroom Classic share. It is rebuilt from the photos when they are opened again; the photos themselves are never touched.")

    /// Capture One: its own cache folder only. A catalog's previews live inside the catalog, which is never touched.
    static let captureOne = CleanerItem(
        id: "capture-one-cache", title: "Capture One cache",
        note: "Cached thumbnails and processed data, made again when a catalog opens; your catalogs and their previews are kept",
        paths: ["~/Library/Caches/com.captureone.captureone*"], selectedByDefault: false, showsWhenEmpty: false,
        runningAppBundleIDs: ["com.captureone.captureone*"], runningProcessNames: ["Capture One*"], skipsOpenFiles: true,
        about: "The thumbnails and processed data Capture One keeps in its cache folder to open catalogs quickly. It is rebuilt when a catalog is opened again; the catalogs themselves — with the previews inside them — are never touched.")

    /// DaVinci Resolve's render cache: the default cache folder in Movies, the one folder there CleanMate touches
    /// (`SafetyPolicy.allowsResolveCache`). Reading ~/Movies needs Full Disk Access, so like `VideoRenderFiles` the
    /// item is always in the catalog and its discovery waits for it.
    static func resolve(hasFullDiskAccess: @escaping @Sendable () -> Bool = { FullDiskAccess.isGranted }) -> CleanerItem {
        CleanerItem(
            id: "resolve-cache", title: "DaVinci Resolve render cache",
            note: "Cache clips of the timeline, made again when playback needs them; your projects, media and Gallery stills are kept",
            paths: ["~/Movies/DaVinci Resolve/CacheClip"], selectedByDefault: false, showsWhenEmpty: false,
            runningAppBundleIDs: ["com.blackmagic-design.DaVinciResolve*"], runningProcessNames: ["Resolve"],
            skipsOpenFiles: true,
            findEntries: { _, policy in
                let cache = policy.expand("~/Movies/DaVinci Resolve/CacheClip")
                guard hasFullDiskAccess(), isFolder(cache) else { return [] }
                return children(of: cache).map { cache.appending(path: $0) }.filter { policy.allowsResolveCache($0) }
            },
            allowsEntry: { policy, url in policy.allowsResolveCache(url) },
            about: "The cache clips Resolve writes while you play the timeline so it plays smoothly, in the default cache folder. They are made again when playback needs them; your projects, the media they use and the stills in the Gallery are never touched. A project set to keep its cache elsewhere is not scanned.")
    }

    /// Blender: the `cache` folder of every version's settings folder, at either layout the resource path takes.
    static let blender = CleanerItem(
        id: "blender-cache", title: "Blender cache",
        note: "Baked and physics cache files, made again by Blender when a scene needs them; your blend files and settings are kept",
        paths: ["~/Library/Application Support/Blender/*/*/cache", "~/Library/Application Support/Blender/*/cache"],
        selectedByDefault: false, showsWhenEmpty: false,
        runningAppBundleIDs: ["org.blenderfoundation.blender*"], runningProcessNames: ["Blender"], skipsOpenFiles: true,
        about: "The baked and physics cache files Blender keeps with each version's settings. Blender makes them again when a scene needs them; your blend files and the settings beside the cache are never touched.")

    static let sketch = CleanerItem(
        id: "sketch-cache", title: "Sketch cache",
        note: "Cached previews and support files, made again from your documents; your .sketch files are kept",
        paths: ["~/Library/Caches/com.bohemiancoding.sketch3"], selectedByDefault: false, showsWhenEmpty: false,
        runningAppBundleIDs: ["com.bohemiancoding.sketch3*"], runningProcessNames: ["Sketch"], skipsOpenFiles: true,
        about: "The previews and support files Sketch keeps in its cache folder. They are made again from your documents when Sketch needs them; the documents themselves are never touched.")

    /// Affinity: the caches of the sandboxed Designer, Photo and Publisher — a container path, so the item is only
    /// in the catalog with Full Disk Access. The direct-download builds keep one in ~/Library/Caches as well.
    static let affinity = CleanerItem(
        id: "affinity-cache", title: "Affinity cache",
        note: "Cached previews and renders of Affinity Designer, Photo and Publisher, made again from your documents; your files are kept",
        paths: ["~/Library/Containers/com.seriflabs.affinity*/Data/Library/Caches", "~/Library/Caches/com.seriflabs.affinity*"],
        selectedByDefault: false, showsWhenEmpty: false,
        runningAppBundleIDs: ["com.seriflabs.affinity*"], runningProcessNames: ["Affinity*"], skipsOpenFiles: true,
        about: "The previews and renders Affinity Designer, Photo and Publisher keep in their caches. They are made again from your documents when the app needs them; the documents themselves are never touched.")

    private static func children(of url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    /// A real folder (not a symlink).
    private static func isFolder(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }
}
