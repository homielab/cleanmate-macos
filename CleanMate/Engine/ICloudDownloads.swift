import Foundation

// Large & Old Files › Remove Download: the local copy of an iCloud Drive file goes, the file stays in iCloud.

/// iCloud state of a file that syncs with iCloud Drive (its own folder, or Desktop & Documents in iCloud).
nonisolated enum ICloudStatus: String, Sendable, CaseIterable {
    /// Every change is in iCloud: removing the download frees its space and loses nothing.
    case uploaded
    /// Not in iCloud yet: new, changed since the last upload, or excluded from sync.
    case notUploaded
    /// Uploading or downloading right now.
    case syncing
    /// iCloud holds conflicting versions of it.
    case conflict

    /// Only a file whose every change is in iCloud may have its download removed.
    var allowsRemovingDownload: Bool { self == .uploaded }

    static let keys: Set<URLResourceKey> = [
        .isUbiquitousItemKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey,
        .ubiquitousItemIsDownloadingKey, .ubiquitousItemHasUnresolvedConflictsKey, .ubiquitousItemIsExcludedFromSyncKey,
    ]

    /// nil when the file does not sync with iCloud. A conflict wins over a transfer, a transfer over the upload state:
    /// an uploaded file being downloaded again is not removable until it is done.
    init?(isUbiquitous: Bool?, isUploaded: Bool?, isUploading: Bool? = nil, isDownloading: Bool? = nil,
          hasConflicts: Bool? = nil, excludedFromSync: Bool? = nil) {
        guard isUbiquitous == true else { return nil }
        if hasConflicts == true { self = .conflict }
        else if isUploading == true || isDownloading == true { self = .syncing }
        else if isUploaded == true, excludedFromSync != true { self = .uploaded }
        else { self = .notUploaded }
    }

    init?(_ values: URLResourceValues) {
        self.init(isUbiquitous: values.isUbiquitousItem, isUploaded: values.ubiquitousItemIsUploaded,
                  isUploading: values.ubiquitousItemIsUploading, isDownloading: values.ubiquitousItemIsDownloading,
                  hasConflicts: values.ubiquitousItemHasUnresolvedConflicts,
                  excludedFromSync: values.ubiquitousItemIsExcludedFromSync)
    }

    /// The state read now, not a URL's cached values; nil when the file does not sync with iCloud or can't be read.
    static func current(of url: URL) -> ICloudStatus? {
        var url = url
        url.removeAllCachedResourceValues()
        return (try? url.resourceValues(forKeys: keys)).flatMap(ICloudStatus.init)
    }
}

nonisolated enum ICloudDownloads {
    /// `~/Library/Mobile Documents`: iCloud Drive and the iCloud folders of apps. macOS protects it (`ProtectedFolders`).
    static func folder(home: URL) -> URL { home.appending(path: "Library/Mobile Documents", directoryHint: .isDirectory) }

    /// Folders of `folder(home:)` that iCloud Drive shows in Finder: `com~apple~CloudDocs` and each app's `Documents`
    /// folder. An app's other folders hold its private data and are never listed. Reads the folder: only call it
    /// with Full Disk Access.
    static func roots(home: URL) -> [URL] {
        let base = folder(home: home)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? [])
            .filter { !$0.hasPrefix(".") }.sorted()
        return names.compactMap { name in
            let url = name.lowercased() == "com~apple~clouddocs"
                ? base.appending(path: name, directoryHint: .isDirectory)
                : base.appending(path: "\(name)/Documents", directoryHint: .isDirectory)
            var isFolder: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue ? url : nil
        }
    }

    /// Runs `body` with this thread never downloading dataless files or folders (iCloud items only in the cloud):
    /// listing such a folder fails instead of asking iCloud for it. Nothing in it is on the disk, so nothing is missed.
    static func withoutDownloading<T>(_ body: () throws -> T) rethrows -> T {
        let type = Int32(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES)
        let previous = getiopolicy_np(type, IOPOL_SCOPE_THREAD)
        setiopolicy_np(type, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer { if previous >= 0 { setiopolicy_np(type, IOPOL_SCOPE_THREAD, previous) } }
        return try body()
    }

    struct Report: Sendable, Equatable {
        /// Files whose download was removed: still in iCloud, no longer on the disk.
        var removed: [URL] = []
        /// Allocated bytes of the removed files, measured right before.
        var freed: Int64 = 0
        /// Files left downloaded, with their state read right before (nil: no longer an iCloud file, moved, not
        /// permitted, or macOS refused).
        var kept: [URL: ICloudStatus?] = [:]
    }

    /// `FileManager.evictUbiquitousItem`; tests inject their own.
    static let evict: @Sendable (URL) throws -> Void = { try FileManager.default.evictUbiquitousItem(at: $0) }

    /// Allocated bytes of the file now (what removing its download frees), 0 when unknown.
    static func allocatedSize(_ url: URL) -> Int64 {
        var url = url
        url.removeAllCachedResourceValues()
        return Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
    }

    /// Removes the local copy of each file; the file stays in iCloud Drive and downloads again when opened. Never
    /// deletes nor moves anything. Only a file `policy.allowsICloudDownload` accepts and whose iCloud state, read again
    /// right before (`status`), is `.uploaded`. Each one removed is logged `evicted` with its allocated size.
    @concurrent static func remove(_ urls: [URL], module: LocalizedStringResource = "Large & Old Files",
                                   policy: SafetyPolicy = .current,
                                   status: @escaping @Sendable (URL) -> ICloudStatus? = ICloudStatus.current,
                                   size: @escaping @Sendable (URL) -> Int64 = allocatedSize,
                                   evict: @escaping @Sendable (URL) throws -> Void = evict) async -> Report {
        var report = Report()
        for url in urls {
            guard policy.allowsICloudDownload(url) else { report.kept[url] = .some(nil); continue }
            let state = status(url)
            guard state?.allowsRemovingDownload == true else { report.kept[url] = .some(state); continue }
            let bytes = size(url)
            do {
                try evict(url)
            } catch {
                report.kept[url] = .some(state)
                continue
            }
            report.removed.append(url)
            report.freed += bytes
            ActivityLog.recordEvicted(module: module, item: url.path, size: bytes, home: policy.homeURL)
        }
        return report
    }
}
