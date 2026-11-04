import Foundation

/// Duplicate Files in Large & Old Files and `cleanmate dupes`: files with the same content anywhere in the scope, found
/// by their own walk (not the Large Files list) down to `minSize`. Same skips as Large Files (`LargeFileScanner.scan`:
/// ~/Library, hidden files and folders such as `.git`, packages such as apps and the Photos library, `node_modules`,
/// Settings › Exclusions, other volumes, protected folders without Full Disk Access); a file iCloud keeps only in the
/// cloud takes no space and is never read. Three steps (`DuplicateFinder`): files grouped by size, then a hash of
/// their first and last 64 KB, then a full hash only for those still alike. Hard links to one file count once.
/// File contents are hashed in 1 MB chunks and never kept. Nothing is moved: the user ticks what goes.
nonisolated enum DuplicateScanner {
    /// The Size menu's default and the `dupes` default: small enough for photos, documents and downloads.
    static let defaultMinSize: Int64 = 1_000_000
    static let sizeOptions: [Int64] = [100_000, 1_000_000, 10_000_000, 50_000_000]

    /// Files with the same content, the copy suggested to keep first (`suggestedOrder`).
    struct Group: Identifiable, Hashable, Sendable {
        let files: [LargeFile]
        /// Grouped files sharing blocks with another file (APFS clones) → the bytes only they hold.
        let privateSizes: [URL: Int64]

        var id: URL { files[0].url }
        var suggested: LargeFile { files[0] }

        /// Bytes trashing `file` frees: nothing for a file with another hard link left, only its own blocks for an
        /// APFS clone, else its size.
        func freed(_ file: LargeFile) -> Int64 {
            file.hardLinked ? 0 : min(privateSizes[file.url] ?? file.size, file.size)
        }

        /// What trashing every copy but the suggested one frees.
        var extraSize: Int64 { files.dropFirst().reduce(0) { $0 + freed($1) } }

        /// The group without `gone`; nil when fewer than two copies are left.
        func removing(_ gone: Set<URL>) -> Group? {
            let left = files.filter { !gone.contains($0.url) }
            return left.count >= 2 ? Group(files: left, privateSizes: privateSizes) : nil
        }
    }

    /// Where a search is: listing files (entries checked so far), then comparing them (bytes settled).
    enum Progress: Sendable, Equatable {
        case listing(Int)
        case comparing(DuplicateFinder.Progress)
    }

    struct Result: Sendable {
        /// Most space to free first.
        var groups: [Group] = []
        /// Every full hash known after this run, to pass to the next one.
        var hashes: [DuplicateFinder.Key: Data] = [:]
        /// Stopped while comparing: `groups` holds those found before the stop (the largest sizes come first).
        var stopped = false
    }

    /// The duplicates under `root` (the home folder, a folder in it or an external drive) of at least `minSize`
    /// bytes each. Throws `CancellationError` when cancelled while listing; cancelled while comparing, returns the
    /// groups found so far with `stopped` set.
    @concurrent static func scan(root: URL, minSize: Int64 = defaultMinSize, policy: SafetyPolicy = .current,
                                 skipping: Set<String> = [], cache: [DuplicateFinder.Key: Data] = [:],
                                 icloudStatus: @escaping @Sendable (URL) -> ICloudStatus? = ICloudStatus.current,
                                 progress: (@Sendable (Progress) -> Void)? = nil) async throws -> Result {
        let files = try await LargeFileScanner.scan(root: root, minSize: minSize, policy: policy, skipping: skipping,
                                                    lean: true, progress: progress.map { report in { @Sendable count in report(.listing(count)) } })
        try Task.checkCancellation()
        let found: (groups: [[URL]], privateSizes: [URL: Int64], hashes: [DuplicateFinder.Key: Data], stopped: Bool)
        do {
            let result = try await DuplicateFinder.find(files.map(\.url), cache: cache,
                                                        progress: progress.map { report in { @Sendable step in report(.comparing(step)) } })
            found = (result.groups, result.privateSizes, result.hashes, false)
        } catch let cancelled as DuplicateFinder.Cancelled {
            found = (cancelled.groups, cancelled.privateSizes, cancelled.hashes, true)
        }
        let byURL = Dictionary(files.map { ($0.url, $0) }) { first, _ in first }
        let downloads = policy.homeURL.appending(path: "Downloads").standardizedFileURL.path + "/"
        let groups = found.groups.compactMap { urls -> Group? in
            let copies = urls.compactMap { byURL[$0].map { describe($0, icloudStatus: icloudStatus, home: policy.homeURL) } }
            guard copies.count >= 2 else { return nil }
            return Group(files: suggestedOrder(copies, downloads: downloads),
                         privateSizes: found.privateSizes.filter { url, _ in urls.contains(url) })
        }
        return Result(groups: sorted(groups), hashes: found.hashes, stopped: found.stopped)
    }

    /// Most space to free first, then larger copies, then by path: the same order every time.
    static func sorted(_ groups: [Group]) -> [Group] {
        groups.sorted { ($0.extraSize, $0.suggested.size, $1.suggested.url.path) > ($1.extraSize, $1.suggested.size, $0.suggested.url.path) }
    }

    /// The copy to keep first: one outside Downloads before one in it (a download is the copy most often made
    /// again), then the oldest (the original), then the shortest path; the others in the same order.
    static func suggestedOrder(_ files: [LargeFile], downloads: String) -> [LargeFile] {
        files.sorted { a, b in
            let (inA, inB) = (a.url.standardizedFileURL.path.hasPrefix(downloads), b.url.standardizedFileURL.path.hasPrefix(downloads))
            if inA != inB { return !inA }
            return (a.modified, a.url.path.count, a.url.path) < (b.modified, b.url.path.count, b.url.path)
        }
    }

    /// A grouped file with what the lean walk left out: its kind, whether it has other hard links, its iCloud state.
    private static func describe(_ file: LargeFile, icloudStatus: @Sendable (URL) -> ICloudStatus?, home: URL) -> LargeFile {
        var info = stat()
        return LargeFile(url: file.url, size: file.size, lastUsed: file.lastUsed, kind: FileKind(fileExtension: file.url.pathExtension),
                         modified: file.modified, hardLinked: lstat(file.url.path, &info) == 0 && info.st_nlink > 1,
                         icloud: icloudStatus(file.url), home: home)
    }
}
