import Accelerate
import Foundation
import ImageIO
import Vision

/// Near-identical photos (bursts, edits, resized or recompressed copies, repeated screenshots), found on this Mac
/// with Vision's image feature prints: never uploaded, no network.
nonisolated enum SimilarPhotos {
    /// Image files compared (lowercased extensions).
    static let extensions: Set = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "webp"]
    /// Smaller files (icons, web graphics) are not photos worth comparing.
    static let minSize: Int64 = 20_000
    /// Packages never read into: the Photos library (its own app manages it) and app bundles.
    static let neverEntered: Set = ["photoslibrary", "photolibrary", "migratedphotolibrary", "aplibrary", "app"]

    /// A path inside a Photos / Aperture library or an app bundle.
    static func isInLibraryOrApp(_ url: URL) -> Bool {
        url.pathComponents.dropLast().contains { neverEntered.contains(($0 as NSString).pathExtension.lowercased()) }
    }

    struct Photo: Identifiable, Hashable, Sendable {
        let url: URL
        /// Allocated bytes: what the Trash frees.
        let size: Int64
        let modified: Date
        /// Pixels as shown (orientation applied); 0 when the file does not say.
        let width: Int
        let height: Int
        let name: String
        let location: String
        var id: URL { url }
        var pixels: Int { width * height }
    }

    /// Photos that look alike; the first one is the one suggested to keep.
    struct Group: Identifiable, Hashable, Sendable {
        let photos: [Photo]
        var id: URL { photos[0].url }
        var suggested: Photo { photos[0] }
        /// What trashing every photo but the suggested one frees.
        var extraSize: Int64 { photos.dropFirst().reduce(0) { $0 + $1.size } }
        /// The newest photo's last change.
        var newest: Date { photos.lazy.map(\.modified).max() ?? .distantPast }
    }

    /// How the groups are listed: the most space to free, the newest photo, or the most photos first. Ties keep the
    /// most space to free first, then the suggested photo's path.
    enum GroupOrder: String, CaseIterable, Sendable {
        case space, date, count

        func sorted(_ groups: [Group]) -> [Group] {
            groups.sorted { a, b in
                switch self {
                case .date where a.newest != b.newest: return a.newest > b.newest
                case .count where a.photos.count != b.photos.count: return a.photos.count > b.photos.count
                default:
                    if a.extraSize != b.extraSize { return a.extraSize > b.extraSize }
                    return a.id.path < b.id.path
                }
            }
        }
    }

    /// One photo's feature print, L2-normalized and stored as Float16 (half the size of the cache, distances unchanged
    /// to 3 decimals), with the photo's pixel size.
    struct Print: Codable, Hashable, Sendable {
        let revision: Int
        let width: Int
        let height: Int
        let vector: Data
    }

    struct Result: Sendable {
        /// Groups of 2+ photos, the most space to free first.
        var groups: [Group] = []
        /// The cache passed in plus every print made this run, for the next run.
        var prints: [DuplicateFinder.Key: Print] = [:]
        /// Photos read and analyzed this run (not answered from the cache).
        var analyzedCount = 0
    }

    /// Thrown instead of `CancellationError` by `find`: the cache passed in plus every print finished before the stop.
    struct Cancelled: Error { let prints: [DuplicateFinder.Key: Print] }

    /// The newest feature print revision this macOS has: 2 (macOS 14+, 768 values) or 1 (2048 values).
    static var revision: Int { VNGenerateImageFeaturePrintRequest.supportedRevisions.contains(2) ? 2 : 1 }

    /// Largest distance between two normalized prints of one group. Measured on 3000 px photos: re-saved, resized to
    /// half, cropped 5% or brightened 10% stay under 0.30 (revision 2) and bursts under 0.16, while different scenes
    /// are over 0.8 (revision 1) and 1.1 (revision 2).
    static func threshold(revision: Int) -> Float { revision == 1 ? 0.32 : 0.35 }

    /// Image files of at least `minSize` under `root`, with the same rules and skips as Large & Old Files
    /// (`LargeFileScanner.scan`): never inside a library or app, never in iCloud Drive, and a file only in the cloud
    /// (no local blocks) is never listed, so it is never downloaded.
    @concurrent static func photos(in root: URL, policy: SafetyPolicy = .current, skipping: Set<String> = [],
                                   progress: (@Sendable (Int) -> Void)? = nil) async throws -> [LargeFile] {
        try await LargeFileScanner.scan(root: root, minSize: minSize, policy: policy, skipping: skipping, extensions: extensions,
                                        spotlightLastUsed: { _ in nil }, icloudStatus: { _ in nil }, progress: progress)
    }

    /// Makes one photo's print on a GCD thread; `Stop` is set when the search stops. `featurePrint`, or a fake in tests.
    typealias PrintMaker = @Sendable (_ url: URL, _ revision: Int, _ stop: Stop) -> Print?

    /// Groups the photos among `files` that look alike. Hard links to one file count once. Prints in `cache` for the
    /// same path, size, modification date and inode are reused; the others are made a few at a time. A file that
    /// can't be read or decoded is left out. `progress` gets (done, total). Throws `Cancelled` when cancelled, at once:
    /// photos being analyzed are given up (their Vision requests cancelled), not waited for.
    @concurrent static func find(_ files: [LargeFile], cache: [DuplicateFinder.Key: Print] = [:], revision: Int = revision,
                                 makePrint: @escaping PrintMaker = featurePrint,
                                 progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> Result {
        var result = Result(prints: cache)
        var seen = Set<[UInt64]>()
        var todo: [(file: LargeFile, key: DuplicateFinder.Key)] = []
        for file in files {
            var info = stat()
            guard lstat(file.url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  seen.insert([UInt64(UInt32(bitPattern: info.st_dev)), info.st_ino]).inserted else { continue }
            let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
            todo.append((file, DuplicateFinder.Key(path: file.url.path, size: info.st_size, modified: modified, inode: info.st_ino)))
        }
        var prints = [Print?](repeating: nil, count: todo.count)
        var missing: [Int] = []
        for (index, item) in todo.enumerated() {
            if let cached = cache[item.key], cached.revision == revision { prints[index] = cached } else { missing.append(index) }
        }
        var done = todo.count - missing.count
        progress?(done, todo.count)
        do {
            try await withThrowingTaskGroup(of: (Int, Print?).self) { group in
                var next = 0
                func add() {
                    let index = missing[next]
                    let url = todo[index].file.url
                    group.addTask { (index, await featurePrintOffPool(of: url, revision: revision, make: makePrint)) }
                    next += 1
                }
                // Vision runs on the GPU / Neural Engine: a few at a time keep it busy without decoding dozens of
                // 24 MP photos at once.
                for _ in 0..<min(missing.count, max(2, min(ProcessInfo.processInfo.activeProcessorCount, 8))) { add() }
                try Task.checkCancellation()
                while let (index, print) = try await group.next() {
                    try Task.checkCancellation()
                    prints[index] = print
                    if let print { result.prints[todo[index].key] = print }
                    result.analyzedCount += 1
                    done += 1
                    progress?(done, todo.count)
                    if next < missing.count { add() }
                }
            }
        } catch {
            throw Cancelled(prints: result.prints)
        }
        // Each print unpacked straight into its column of one matrix: no array per photo held at once.
        let made = zip(todo, prints).compactMap { item, print in print.map { (item, $0) } }
        let dimension = made.first.map { $0.1.vector.count / 2 } ?? 0
        let usable = made.filter { $0.1.vector.count == dimension * 2 }
        var photos: [Photo] = []
        photos.reserveCapacity(usable.count)
        var columns = [Float](repeating: 0, count: usable.count * dimension)
        columns.withUnsafeMutableBufferPointer { columns in
            for (item, print) in usable {
                guard let vector = unpack(print.vector) else { continue }
                // Column = index in `photos`; columns left over at the end stay zero and never match anything.
                for (row, value) in vector.enumerated() { columns[row * usable.count + photos.count] = value }
                photos.append(Photo(url: item.file.url, size: item.file.size, modified: item.key.modified, width: print.width,
                                    height: print.height, name: item.file.name, location: item.file.location))
            }
        }
        do {
            try Task.checkCancellation()
            result.groups = clusters(columns: columns, count: usable.count, threshold: threshold(revision: revision))
                .map { Group(photos: ranked($0.map { photos[$0] })) }
                .sorted { ($0.extraSize, $1.id.path) > ($1.extraSize, $0.id.path) }
        } catch {
            throw Cancelled(prints: result.prints)
        }
        return result
    }

    /// The photo to keep first: most pixels, then the largest file, then the newest; the others by the same order.
    static func ranked(_ photos: [Photo]) -> [Photo] {
        photos.sorted { a, b in
            if a.pixels != b.pixels { return a.pixels > b.pixels }
            if a.size != b.size { return a.size > b.size }
            if a.modified != b.modified { return a.modified > b.modified }
            return a.url.path < b.url.path
        }
    }

    /// Indexes of `vectors` (each L2-normalized) in groups of 2+ where every two members are within `threshold`
    /// (complete linkage: a burst drifting frame by frame does not chain unrelated ends together). Closest pairs merge
    /// first. Groups in order of their first index, indexes sorted.
    static func clusters(_ vectors: [[Float]], threshold: Float, maxPairs: Int = 2_000_000) -> [[Int]] {
        guard let dimension = vectors.first?.count, dimension > 0, vectors.allSatisfy({ $0.count == dimension }) else { return [] }
        var columns = [Float](repeating: 0, count: vectors.count * dimension)
        for (column, vector) in vectors.enumerated() {
            for (row, value) in vector.enumerated() { columns[row * vectors.count + column] = value }
        }
        return clusters(columns: columns, count: vectors.count, threshold: threshold, maxPairs: maxPairs)
    }

    /// `clusters(_:threshold:maxPairs:)` of the `count` vectors stored as the columns of `columns` (dimension × count,
    /// row-major): the only copy of the prints, besides 256 of them at a time.
    // shortcut: past `maxPairs` close pairs (tens of thousands of near-identical images) the rest are ignored, so
    // some photos end up in smaller groups or none; memory stays bounded.
    static func clusters(columns: [Float], count n: Int, threshold: Float, maxPairs: Int = 2_000_000) -> [[Int]] {
        guard n >= 2, !columns.isEmpty, columns.count % n == 0 else { return [] }
        let dimension = columns.count / n
        // |a - b|² = 2 - 2 a·b for unit vectors: distance ≤ threshold ⇔ a·b ≥ 1 - threshold² / 2.
        let minDot = 1 - threshold * threshold / 2
        var pairs: [(dot: Float, a: Int, b: Int)] = []
        let rows = 256
        var slice = [Float](repeating: 0, count: min(rows, n) * dimension)
        var block = [Float](repeating: 0, count: min(rows, n) * n)
        rowBlocks: for start in stride(from: 0, to: n, by: rows) {
            let count = min(rows, n - start)
            // Vectors start..<start + count as rows (count × dimension), times all of them as columns.
            columns.withUnsafeBufferPointer { columns in
                slice.withUnsafeMutableBufferPointer { slice in
                    for k in 0..<dimension {
                        for row in 0..<count { slice[row * dimension + k] = columns[k * n + start + row] }
                    }
                }
            }
            vDSP_mmul(slice, 1, columns, 1, &block, 1, vDSP_Length(count), vDSP_Length(n), vDSP_Length(dimension))
            for row in 0..<count {
                let a = start + row
                for b in (a + 1)..<n where block[row * n + b] >= minDot {
                    pairs.append((block[row * n + b], a, b))
                    if pairs.count >= maxPairs { break rowBlocks }
                }
            }
        }
        pairs.sort { ($0.dot, $1.a, $1.b) > ($1.dot, $0.a, $0.b) }
        let linked = Set(pairs.map { $0.a * n + $0.b })
        var cluster = Array(0..<n)
        var members = (0..<n).map { [$0] }
        for (_, a, b) in pairs {
            let (x, y) = (cluster[a], cluster[b])
            guard x != y, members[x].allSatisfy({ i in members[y].allSatisfy { j in linked.contains(min(i, j) * n + max(i, j)) } })
            else { continue }
            let (keep, gone) = members[x].count >= members[y].count ? (x, y) : (y, x)
            for i in members[gone] { cluster[i] = keep }
            members[keep] += members[gone]
            members[gone] = []
        }
        return members.filter { $0.count >= 2 }.map { $0.sorted() }.sorted { $0[0] < $1[0] }
    }

    /// Stops one photo's analysis: a print not started yet is never made, a running Vision request is cancelled.
    final class Stop: @unchecked Sendable {
        private let state = Locked((stopped: false, request: VNRequest?.none))

        var isStopped: Bool { state.withLock { $0.stopped } }

        func stop() {
            state.withLock { state -> VNRequest? in
                state.stopped = true
                return state.request
            }?.cancel()
        }

        /// Holds `request` so `stop` cancels it; false when already stopped (don't perform it).
        func running(_ request: VNRequest) -> Bool {
            state.withLock { state in
                guard !state.stopped else { return false }
                state.request = request
                return true
            }
        }
    }

    /// `make` on a GCD thread: Vision blocks the calling thread while it waits for its own workers, and with every
    /// thread of the Swift concurrency pool waiting there nothing is left to run them (a deadlock). Cancelling the
    /// task returns nil at once and stops `make` (its Vision request is cancelled); its thread is not waited for.
    static func featurePrintOffPool(of url: URL, revision: Int, make: @escaping PrintMaker = featurePrint) async -> Print? {
        let stop = Stop()
        let waiting = Locked(CheckedContinuation<Print?, Never>?.none)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Stored unless already cancelled; whoever takes it out (the result or the cancel) resumes it once.
                let cancelled = waiting.withLock { slot in
                    if stop.isStopped { return true }
                    slot = continuation
                    return false
                }
                guard !cancelled else { return continuation.resume(returning: nil) }
                DispatchQueue.global(qos: .userInitiated).async {
                    let print = stop.isStopped ? nil : make(url, revision, stop)
                    waiting.withLock { $0.take() }?.resume(returning: print)
                }
            }
        } onCancel: {
            stop.stop()
            waiting.withLock { $0.take() }?.resume(returning: nil)
        }
    }

    /// `featurePrint(of:revision:running:)` unless `stop` is set; `stop` cancels its Vision request.
    static func featurePrint(of url: URL, revision: Int, stop: Stop) -> Print? {
        guard !stop.isStopped else { return nil }
        return featurePrint(of: url, revision: revision, running: stop.running)
    }

    /// The feature print of the image at `url`, made from a 512 px rendition (the full image decoded at that size,
    /// orientation applied); nil when it can't be read or decoded, or `running` refuses the Vision request. The file's
    /// access date is put back.
    static func featurePrint(of url: URL, revision: Int, running: (VNRequest) -> Bool = { _ in true }) -> Print? {
        DuplicateFinder.keepingAccessDate(of: url) {
            autoreleasepool { () -> Print? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      CGImageSourceGetCount(source) > 0 else { return nil }
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
                var width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
                var height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
                if let orientation = properties?[kCGImagePropertyOrientation] as? Int, orientation >= 5 { swap(&width, &height) }
                // Always from the full image: an embedded thumbnail can predate an edit.
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                kCGImageSourceThumbnailMaxPixelSize: 512,
                                                kCGImageSourceCreateThumbnailWithTransform: true,
                                                kCGImageSourceShouldCacheImmediately: true]
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
                let request = VNGenerateImageFeaturePrintRequest()
                request.revision = revision
                guard running(request), (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil,
                      let observation = request.results?.first, observation.elementType == .float,
                      observation.data.count == observation.elementCount * MemoryLayout<Float>.size
                else { return nil }
                let values = observation.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                guard let vector = pack(normalized(values)) else { return nil }
                return Print(revision: revision, width: width, height: height, vector: vector)
            }
        }
    }

    /// `values` scaled to length 1; nil when they are all zero.
    static func normalized(_ values: [Float]) -> [Float]? {
        let length = sqrt(vDSP.sumOfSquares(values))
        guard length > 0, length.isFinite else { return nil }
        return vDSP.divide(values, length)
    }

    /// Float32 → Float16 bytes (vImage: Swift's Float16 is not on Intel Macs).
    static func pack(_ values: [Float]?) -> Data? {
        guard let values, !values.isEmpty else { return nil }
        var halves = Data(count: values.count * 2)
        let error = values.withUnsafeBufferPointer { source in
            halves.withUnsafeMutableBytes { target in
                var from = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source.baseAddress!), height: 1,
                                         width: vImagePixelCount(values.count), rowBytes: values.count * 4)
                var to = vImage_Buffer(data: target.baseAddress!, height: 1, width: vImagePixelCount(values.count),
                                       rowBytes: values.count * 2)
                return vImageConvert_PlanarFtoPlanar16F(&from, &to, vImage_Flags(kvImageNoFlags))
            }
        }
        return error == kvImageNoError ? halves : nil
    }

    /// Float16 bytes → Float32, renormalized; nil for bytes that are no vector.
    static func unpack(_ data: Data) -> [Float]? {
        let count = data.count / 2
        guard count > 0, data.count % 2 == 0 else { return nil }
        var values = [Float](repeating: 0, count: count)
        var data = data
        let error = data.withUnsafeMutableBytes { source in
            values.withUnsafeMutableBufferPointer { target in
                var from = vImage_Buffer(data: source.baseAddress!, height: 1, width: vImagePixelCount(count), rowBytes: count * 2)
                var to = vImage_Buffer(data: target.baseAddress!, height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
                return vImageConvert_Planar16FtoPlanarF(&from, &to, vImage_Flags(kvImageNoFlags))
            }
        }
        return error == kvImageNoError ? normalized(values) : nil
    }

    /// Feature prints kept across launches in `~/Library/Caches/<bundle id>/feature-prints.plist` (binary). Any read
    /// or write error = no cache. Smart Scan's "User caches" never cleans this folder (`keptCaches`).
    enum Cache {
        static let limit = 20_000
        static var defaultURL: URL {
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appending(path: "\(AppIdentity.bundleID)/feature-prints.plist")
        }

        private struct Entry: Codable {
            let key: DuplicateFinder.Key
            let print: Print
        }

        @concurrent static func load(from url: URL) async -> [DuplicateFinder.Key: Print] { read(url) }

        private static func read(_ url: URL) -> [DuplicateFinder.Key: Print] {
            let entries = (try? Data(contentsOf: url)).flatMap { try? PropertyListDecoder().decode([Entry].self, from: $0) } ?? []
            return Dictionary(entries.map { ($0.key, $0.print) }) { _, new in new }
        }

        /// Serializes read-merge-write, so two saves at once keep both sets.
        private static let lock = NSLock()

        /// Merges into what is on disk (new prints win), drops entries whose file is gone or changed, keeps the `limit`
        /// most recently modified, writes atomically.
        @concurrent static func save(_ prints: [DuplicateFinder.Key: Print], to url: URL, limit: Int = limit) async {
            lock.withLock {
                let live = read(url).merging(prints) { _, new in new }.filter { key, _ in
                    var info = stat()
                    return lstat(key.path, &info) == 0 && info.st_size == key.size && info.st_ino == key.inode
                        && Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9) == key.modified
                }
                let kept = live.sorted { $0.key.modified > $1.key.modified }.prefix(limit).map { Entry(key: $0.key, print: $0.value) }
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? encoder.encode(Array(kept)).write(to: url, options: .atomic)
            }
        }
    }

    static let module: LocalizedStringResource = "Similar Photos"

    /// Moves photos to the Trash (never deletes), re-checking the user-file policy (and never a library or app) right
    /// before each one; each move is logged and recorded for `cleanmate restore`.
    @concurrent static func trash(_ photos: [Photo], policy: SafetyPolicy = .current,
                                  trash: @escaping @Sendable (URL) throws -> URL? = CleanReport.moveToTrash) async -> CleanReport {
        CleanReport.trashing(photos.map { ($0.url, $0.size) }, module: module, home: policy.homeURL,
                             allows: { policy.allowsUserFile($0) && !isInLibraryOrApp($0) }, trash: trash)
    }
}
