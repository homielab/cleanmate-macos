import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CleanMate

/// Similar Photos in a throwaway fake home with generated photos: an original, its resized and recompressed copies and
/// unrelated scenes. Nothing is ever moved to the real Trash and the real feature print cache is never touched.
@MainActor final class SimilarPhotosTests {
    let root = TestTemp.url("CleanMateSimilarPhotos")
    var home: URL { root.appending(path: "home") }
    var trashFolder: URL { root.appending(path: "Trash") }
    var policy: SafetyPolicy { SafetyPolicy(home: home, temp: root.appending(path: "tmp")) }

    init() throws {
        for folder in [home, trashFolder, root.appending(path: "tmp")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    // MARK: - Generated photos

    /// A reproducible "photo": a gradient, overlapping shapes and grain, all drawn from `seed`.
    static func scene(seed: UInt64, width: Int = 1200, height: Int = 900) -> CGImage {
        var random = SplitMix(seed)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        func color() -> CGColor { CGColor(srgbRed: random.unit(), green: random.unit(), blue: random.unit(), alpha: 1) }
        let gradient = CGGradient(colorsSpace: nil, colors: [color(), color()] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        for index in 0..<40 {
            context.setFillColor(color())
            let rect = CGRect(x: random.unit() * Double(width), y: random.unit() * Double(height),
                              width: 80 + random.unit() * Double(width) / 3, height: 80 + random.unit() * Double(height) / 3)
            if index % 2 == 0 { context.fillEllipse(in: rect) } else { context.fill(rect) }
        }
        // Coarse grain (8 px cells), so the files are photo-sized, yet survives resizing and recompression like detail.
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        let cell = 8
        for cellY in stride(from: 0, to: height, by: cell) {
            for cellX in stride(from: 0, to: width, by: cell) {
                let grain = Int(random.next() % 41) - 20
                for y in cellY..<min(cellY + cell, height) {
                    for x in cellX..<min(cellX + cell, width) {
                        let offset = (y * width + x) * 4
                        for channel in 0..<3 { pixels[offset + channel] = UInt8(clamping: Int(pixels[offset + channel]) + grain) }
                    }
                }
            }
        }
        return context.makeImage()!
    }

    static func resized(_ image: CGImage, by factor: Double) -> CGImage {
        let (width, height) = (Int(Double(image.width) * factor), Int(Double(image.height) * factor))
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    @discardableResult
    func write(_ image: CGImage, to path: String, type: UTType = .jpeg, quality: Double = 0.9, in folder: URL? = nil) throws -> URL {
        let url = (folder ?? home).appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return url
    }

    /// The original, a copy at half size (PNG), a recompressed copy and two unrelated scenes.
    func writeSet() throws -> (original: URL, resized: URL, recompressed: URL, others: [URL]) {
        let scene = Self.scene(seed: 1)
        let original = try write(scene, to: "Pictures/IMG_0001.jpg")
        let resized = try write(Self.resized(scene, by: 0.5), to: "Desktop/IMG_0001 small.png", type: .png)
        let recompressed = try write(scene, to: "Downloads/IMG_0001 (1).jpg", quality: 0.4)
        let others = [try write(Self.scene(seed: 2), to: "Pictures/IMG_0002.jpg"),
                      try write(Self.scene(seed: 3), to: "Pictures/IMG_0003.heic", type: .heic)]
        return (original, resized, recompressed, others)
    }

    func groups() async throws -> [SimilarPhotos.Group] {
        let photos = try await SimilarPhotos.photos(in: home, policy: policy)
        return try await SimilarPhotos.find(photos).groups
    }

    // MARK: - Grouping

    @Test func groupsAnOriginalWithItsEditsAndLeavesOtherPhotosOut() async throws {
        let set = try writeSet()
        let groups = try await groups()
        try #require(groups.count == 1)
        #expect(Set(groups[0].photos.map(\.url.lastPathComponent))
                == Set([set.original, set.resized, set.recompressed].map(\.lastPathComponent)))
        // Most pixels first: a full-size copy is suggested, never the half-size one.
        #expect(groups[0].suggested.pixels == 1200 * 900)
        #expect(groups[0].photos.last?.url.lastPathComponent == set.resized.lastPathComponent)
        #expect(groups[0].extraSize == groups[0].photos.dropFirst().reduce(0) { $0 + $1.size })
    }

    @Test func reusesCachedPrintsAndMakesNoneForUnchangedFiles() async throws {
        _ = try writeSet()
        let photos = try await SimilarPhotos.photos(in: home, policy: policy)
        let first = try await SimilarPhotos.find(photos)
        #expect(first.analyzedCount == 5 && first.prints.count == 5)
        let again = try await SimilarPhotos.find(photos, cache: first.prints)
        #expect(again.analyzedCount == 0 && again.groups == first.groups)

        // Saved and loaded back; a changed file's print is dropped on save.
        let cacheURL = root.appending(path: "cache/feature-prints.plist")
        await SimilarPhotos.Cache.save(first.prints, to: cacheURL)
        #expect(await SimilarPhotos.Cache.load(from: cacheURL) == first.prints)
        try write(Self.scene(seed: 9), to: "Pictures/IMG_0002.jpg")
        await SimilarPhotos.Cache.save([:], to: cacheURL)
        #expect(await SimilarPhotos.Cache.load(from: cacheURL).count == 4)
    }

    @Test func aCancelledSearchKeepsThePrintsItFinished() async throws {
        _ = try writeSet()
        let photos = try await SimilarPhotos.photos(in: home, policy: policy)
        let task = Task { try await SimilarPhotos.find(photos) }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected Cancelled")
        } catch let cancelled as SimilarPhotos.Cancelled {
            #expect(cancelled.prints.count <= photos.count)
        }
    }

    /// Stop while Vision is slow (fakes that block until the test lets them go): the search ends at once instead of
    /// waiting for the photos being analyzed, their requests are told to stop and no other photo is started. Waits on
    /// what the fakes signal, never on the clock; a search that waited for them would hang (the time limit fails it).
    @Test(.timeLimit(.minutes(1))) func stoppingDoesNotWaitForPhotosBeingAnalyzed() async throws {
        for index in 0..<20 {
            let url = home.appending(path: "Pictures/IMG_\(index).jpg")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: UInt8(index), count: 30_000).write(to: url)
        }
        let photos = try await SimilarPhotos.photos(in: home, policy: policy)
        try #require(photos.count == 20)
        // The photos `find` analyzes at once (its own rule); all of them are blocked in the fake before the stop.
        let inFlight = max(2, min(ProcessInfo.processInfo.activeProcessorCount, 8))

        func stop(_ make: @escaping SimilarPhotos.PrintMaker, started: SignalCount) async {
            let task = Task { try await SimilarPhotos.find(photos, makePrint: make) }
            await started.reach(inFlight)
            task.cancel()
            do {
                _ = try await task.value
                Issue.record("expected Cancelled")
            } catch {
                #expect(error is SimilarPhotos.Cancelled, "\(error)")
            }
        }

        // A fake that stops when told, like a cancelled Vision request.
        let (started, told, released) = (SignalCount(), SignalCount(), ThreadGate())
        defer { released.open() }
        await stop({ _, _, stop in
            started.add()
            while !stop.isStopped && !released.isOpen { usleep(1_000) }
            if stop.isStopped { told.add() }
            return nil
        }, started: started)
        await told.reach(inFlight)
        // None of them returned, so no other photo started (without the stop, each one returning starts the next).
        #expect(started.value == inFlight && told.value == inFlight)

        // A fake that never looks at the stop: the search still ended while every one of them was blocked.
        let (ignoring, finished, gate) = (SignalCount(), SignalCount(), ThreadGate())
        defer { gate.open() }
        await stop({ _, _, _ in
            ignoring.add()
            gate.wait()
            finished.add()
            return nil
        }, started: ignoring)
        #expect(finished.value == 0 && ignoring.value == inFlight)
        gate.open()
        await finished.reach(inFlight) // their threads are done before the test ends

        // A stopped photo is never decoded nor sent to Vision.
        let stop = SimilarPhotos.Stop()
        stop.stop()
        #expect(SimilarPhotos.featurePrint(of: photos[0].url, revision: SimilarPhotos.revision, stop: stop) == nil)
    }

    /// Complete linkage: a chain of close pairs whose ends are far apart is not one group.
    @Test func clustersNeedEveryTwoMembersClose() {
        func unit(_ angle: Float) -> [Float] { [cos(angle), sin(angle)] }
        // 0.3 rad apart ≈ distance 0.30 (under 0.35); 0.6 rad ≈ 0.60.
        let chain = [unit(0), unit(0.3), unit(0.6), unit(2), unit(2.05)]
        let groups = SimilarPhotos.clusters(chain, threshold: 0.35)
        #expect(groups.count == 2)
        #expect(groups.contains([3, 4]))
        #expect(groups.contains([0, 1]) || groups.contains([1, 2]))
        #expect(SimilarPhotos.clusters([unit(0)], threshold: 0.35).isEmpty)
        #expect(SimilarPhotos.clusters([unit(0), unit(1)], threshold: 0.35).isEmpty)
    }

    /// Prints compared 256 at a time: a group spread over several blocks is still one group, and the column matrix
    /// `find` builds gives the same groups as the vectors.
    @Test func clustersAcrossBlocks() {
        var random = SplitMix(7)
        func noise(_ scale: Float) -> [Float] { (0..<32).map { _ in (Float(random.unit()) - 0.5) * scale } }
        func unit(_ values: [Float]) -> [Float] { SimilarPhotos.normalized(values)! }
        var vectors = (0..<600).map { _ in unit(noise(2)) }
        let base = vectors[10]
        for index in [300, 590] { vectors[index] = unit(zip(base, noise(0.05)).map { $0 + $1 }) }
        #expect(SimilarPhotos.clusters(vectors, threshold: 0.35) == [[10, 300, 590]])

        var columns = [Float](repeating: 0, count: 600 * 32)
        for (column, vector) in vectors.enumerated() {
            for (row, value) in vector.enumerated() { columns[row * 600 + column] = value }
        }
        #expect(SimilarPhotos.clusters(columns: columns, count: 600, threshold: 0.35) == [[10, 300, 590]])
        #expect(SimilarPhotos.clusters(columns: columns, count: 0, threshold: 0.35).isEmpty)
    }

    /// Past `maxPairs` close pairs the rest are not compared: the result says so instead of looking complete.
    @Test(.timeLimit(.minutes(1))) func moreClosePairsThanTheLimitAreReportedAsIncomplete() async throws {
        func unit(_ angle: Float) -> [Float] { [cos(angle), sin(angle)] }
        let burst = [unit(0), unit(0.01), unit(0.02), unit(2)] // 3 close pairs
        #expect(SimilarPhotos.clustering(columns: columns(burst), count: 4, threshold: 0.35, maxPairs: 3).truncated == false)
        let cut = SimilarPhotos.clustering(columns: columns(burst), count: 4, threshold: 0.35, maxPairs: 1)
        #expect(cut.truncated && cut.groups.count <= 1)

        _ = try writeSet() // 3 photos alike: 3 close pairs
        let photos = try await SimilarPhotos.photos(in: home, policy: policy)
        let whole = try await SimilarPhotos.find(photos)
        #expect(!whole.truncated && whole.groups.count == 1)
        let limited = try await SimilarPhotos.find(photos, cache: whole.prints, maxPairs: 1)
        #expect(limited.truncated)

        // The model keeps the flag for the view's "Results may be incomplete" until the next search or a reset.
        let model = model()
        let flagged = Locked(true)
        model.findSimilar = { _, _, _ in SimilarPhotos.Result(truncated: flagged.withLock { $0 }) }
        model.find(in: home, policy: policy, skipping: [])
        await results(model)
        #expect(model.truncated)
        flagged.withLock { $0 = false }
        model.findAgain()
        await until(model) { if case .results = $0.phase { !$0.truncated } else { false } }
        model.reset()
        #expect(!model.truncated)
    }

    func columns(_ vectors: [[Float]]) -> [Float] {
        var columns = [Float](repeating: 0, count: vectors.count * (vectors.first?.count ?? 0))
        for (column, vector) in vectors.enumerated() {
            for (row, value) in vector.enumerated() { columns[row * vectors.count + column] = value }
        }
        return columns
    }

    @Test func packedPrintsKeepTheirDirection() throws {
        let values: [Float] = [3, 4, 0, -12]
        let packed = try #require(SimilarPhotos.pack(SimilarPhotos.normalized(values)))
        let unpacked = try #require(SimilarPhotos.unpack(packed))
        let expected: [Float] = [3 / 13, 4 / 13, 0, -12 / 13]
        #expect(zip(unpacked, expected).allSatisfy { abs($0 - $1) < 0.001 })
        #expect(SimilarPhotos.normalized([0, 0]) == nil && SimilarPhotos.unpack(Data([1])) == nil)
    }

    @Test func ranksMostPixelsThenLargestThenNewest() {
        func photo(_ name: String, _ width: Int, _ size: Int64, _ days: Double) -> SimilarPhotos.Photo {
            SimilarPhotos.Photo(url: URL(filePath: "/x/\(name)"), size: size, modified: Date(timeIntervalSince1970: days * 86_400),
                                width: width, height: 100, name: name, location: "~")
        }
        let ranked = SimilarPhotos.ranked([photo("small", 50, 9_000, 9), photo("old", 100, 5_000, 1),
                                           photo("new", 100, 5_000, 2), photo("big", 100, 8_000, 0)])
        #expect(ranked.map(\.name) == ["big", "new", "old", "small"])
    }

    @Test func sortsGroupsBySpaceDateOrCount() {
        func group(_ name: String, sizes: [Int64], day: Double) -> SimilarPhotos.Group {
            SimilarPhotos.Group(photos: sizes.enumerated().map { index, size in
                SimilarPhotos.Photo(url: URL(filePath: "/x/\(name)\(index)"), size: size,
                                    modified: Date(timeIntervalSince1970: (day + Double(index)) * 86_400),
                                    width: 100, height: 100, name: "\(name)\(index)", location: "~")
            })
        }
        let groups = [group("small", sizes: [9, 1, 1, 1], day: 1), group("big", sizes: [9, 50], day: 2),
                      group("new", sizes: [9, 5], day: 30)]
        #expect(SimilarPhotos.GroupOrder.space.sorted(groups).map(\.suggested.name) == ["big0", "new0", "small0"])
        #expect(SimilarPhotos.GroupOrder.date.sorted(groups).map(\.suggested.name) == ["new0", "small0", "big0"])
        #expect(SimilarPhotos.GroupOrder.count.sorted(groups).map(\.suggested.name) == ["small0", "big0", "new0"])
        #expect(groups[0].newest == Date(timeIntervalSince1970: 4 * 86_400))
    }

    // MARK: - Never inside a library or an app

    @Test func neverListsPhotosInsideAPhotosLibraryOrAnApp() async throws {
        let scene = Self.scene(seed: 1)
        try write(scene, to: "Pictures/kept.jpg")
        try write(scene, to: "Pictures/Photos Library.photoslibrary/originals/A/IMG_0001.jpg")
        try write(scene, to: "Pictures/Old.migratedphotolibrary/Masters/IMG_0001.jpg")
        try write(scene, to: "Applications/Viewer.app/Contents/Resources/sample.jpg")
        try write(scene, to: "Documents/Tool.APP/sample.jpg")
        try write(scene, to: "Pictures/icon.png", type: .png, quality: 1) // a 20 KB+ PNG too: only the size rule decides
        let photos = try await SimilarPhotos.photos(in: home, policy: policy)
        #expect(Set(photos.map(\.url.lastPathComponent)) == ["kept.jpg", "icon.png"])
        // Started inside one, it still lists nothing from it.
        let inside = try await SimilarPhotos.photos(in: home.appending(path: "Pictures/Photos Library.photoslibrary"), policy: policy)
        #expect(inside.isEmpty)
        for path in ["Pictures/Photos Library.photoslibrary/originals/A/IMG_0001.jpg", "Applications/Viewer.app/Contents/Resources/sample.jpg"] {
            #expect(SimilarPhotos.isInLibraryOrApp(home.appending(path: path)), "\(path)")
        }
        #expect(!SimilarPhotos.isInLibraryOrApp(home.appending(path: "Pictures/app/x.jpg")))
    }

    @Test func listsOnlyImageFilesOfAtLeastTheMinimumSize() async throws {
        try write(Self.scene(seed: 1), to: "Pictures/a.JPG")
        try write(Self.scene(seed: 1, width: 40, height: 30), to: "Pictures/tiny.jpg")
        try Data(repeating: 1, count: 200_000).write(to: home.appending(path: "Pictures/movie.mov"))
        let photos = try await SimilarPhotos.photos(in: home, policy: policy)
        #expect(photos.map(\.url.lastPathComponent) == ["a.JPG"])
    }

    @Test func aFolderMacOSProtectsIsNotReadWithoutFullDiskAccess() async throws {
        try write(Self.scene(seed: 1), to: "Pictures/a.jpg")
        try write(Self.scene(seed: 1), to: "Desktop/a.jpg")
        let skipping = ProtectedFolders.skipped(home: home, hasFullDiskAccess: false)
        let photos = try await SimilarPhotos.photos(in: home, policy: policy, skipping: skipping)
        #expect(photos.map(\.url.path).allSatisfy { path in !skipping.contains { path.hasPrefix($0 + "/") } })
        #expect(!skipping.isEmpty && photos.count < 2)
    }

    // MARK: - Model: Trash, Undo, restore

    func model() -> SimilarPhotosModel {
        let model = SimilarPhotosModel()
        let (trash, home) = (trashFolder, home)
        model.trashPhotos = { photos, policy in
            await SimilarPhotos.trash(photos, policy: policy) { url in
                let target = trash.appending(path: url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: target)
                return target
            }
        }
        model.restore = { await TrashUndo.restore($0, module: SimilarPhotos.module, home: home) }
        return model
    }

    func results(_ model: SimilarPhotosModel) async {
        await until(model) { if case .results = $0.phase { true } else { false } }
    }

    @Test(.timeLimit(.minutes(1))) func modelTicksNothingWarnsForAWholeGroupAndTrashesWithUndo() async throws {
        let set = try writeSet()
        let model = model()
        #expect(model.cacheURL == nil) // never the real cache under a test host
        model.find(in: home, policy: policy, skipping: [])
        await results(model)
        try #require(model.groups.count == 1)
        #expect(model.checked.isEmpty && model.groupsLosingEveryPhoto.isEmpty)

        model.checked = Set(model.groups[0].photos.map(\.url))
        #expect(model.groupsLosingEveryPhoto == [model.groups[0].suggested.name])
        model.checkAllButSuggested()
        #expect(model.checkedPhotos.count == 2 && model.groupsLosingEveryPhoto.isEmpty)
        let suggested = model.groups[0].suggested.url
        let size = model.checkedSize

        var dropped: [URL] = []
        model.onTrashed = { dropped = $0 }
        await model.trash()
        guard case .done(let report) = model.phase else { Issue.record("not done"); return }
        #expect(report.freed == size && report.trashed.count == 2 && Set(dropped).count == 2)
        #expect(FileManager.default.fileExists(atPath: suggested.path))
        #expect(model.groups.isEmpty && model.checked.isEmpty)
        // Recorded for `cleanmate restore --list`.
        let records = TrashRecords.inTrash(home: home)
        #expect(records.count == 2 && records.allSatisfy { $0.source == "Similar Photos" })

        await model.undoTrash()
        guard case .done(let after) = model.phase else { Issue.record("not done"); return }
        #expect(after.undo == TrashUndo.Result(restored: 2, skipped: 0))
        for url in [set.original, set.resized, set.recompressed] { #expect(FileManager.default.fileExists(atPath: url.path)) }
    }

    @Test(.timeLimit(.minutes(1))) func modelStopsMidSearchAndFindsAgain() async throws {
        _ = try writeSet()
        let model = model()
        model.find(in: home, policy: policy, skipping: [])
        #expect(model.isSearching)
        model.stop()
        guard case .idle = model.phase else { Issue.record("not idle"); return }
        model.findAgain()
        await results(model)
        #expect(model.groups.count == 1)
    }

    /// The Duplicates menu: Similar Photos replaces the file list and searches the scanned scope (with the files'
    /// FDA skips); going back to the file list drops the photo results and ticks.
    @Test(.timeLimit(.minutes(1))) func largeFilesListingSwitchesToSimilarPhotos() async throws {
        let set = try writeSet()
        let model = LargeFilesModel()
        model.home = home
        model.hasFullDiskAccess = { true }
        model.scanFiles = { _, _, _, _ in [] }
        model.scan()
        await until(model) { if case .results = $0.phase { true } else { false } }
        model.listing = .duplicates
        #expect(model.duplicatesShown && !model.similarPhotosShown)
        model.listing = .similarPhotos
        #expect(!model.duplicatesShown && model.similarPhotosShown && model.listing == .similarPhotos)
        await results(model.similarPhotos)
        #expect(model.similarPhotos.photoCount == 3)
        #expect(Set(model.similarPhotos.groups.flatMap(\.photos).map(\.url.lastPathComponent))
                == Set([set.original, set.resized, set.recompressed].map(\.lastPathComponent)))
        model.similarPhotos.checked = [set.recompressed]
        model.listing = .allFiles
        guard case .idle = model.similarPhotos.phase else { Issue.record("not reset"); return }
        #expect(!model.similarPhotosShown && !model.duplicatesShown && model.similarPhotos.checked.isEmpty)
    }

    /// `cleanmate similar --json` groups what the app groups (Settings › Exclusions left out, nothing chosen), and the
    /// photos the user picks go to the Trash with `cleanmate trash` and come back with `cleanmate restore`.
    @Test func commandLineFindsSimilarPhotosAndTrashedOnesComeBack() async throws {
        let fixture = try CommandLineToolTests.FilesFixture()
        let scene = Self.scene(seed: 1)
        try write(scene, to: "Pictures/IMG_0001.jpg", in: fixture.home)
        try write(Self.resized(scene, by: 0.5), to: "Pictures/IMG_0001 small.png", type: .png, in: fixture.home)
        try write(scene, to: "Media/IMG_0001 (1).jpg", quality: 0.4, in: fixture.home)
        try write(Self.scene(seed: 2), to: "Pictures/IMG_0002.jpg", in: fixture.home)
        try write(scene, to: "Media/Excluded/IMG_0001 copy.jpg", in: fixture.home) // in Settings › Exclusions
        let sources = fixture.sources(fullDiskAccess: true)

        let (code, printed) = await CommandLineToolTests.run(["similar", "--json", fixture.home.appending(path: "Pictures").path,
                                                              "~/Media"], sources)
        try #require(code == 0, "\(printed.stderr)")
        let report = try JSONDecoder().decode(HeadlessFiles.SimilarReport.self, from: Data(printed.stdout.utf8))
        #expect(report.version == "9.9" && report.fullDiskAccess && report.skipped.isEmpty)
        #expect(report.roots == [fixture.real + "/Pictures", fixture.real + "/Media"])
        #expect(report.photos == 4 && report.analyzed == 4 && report.count == 1 && report.moreGroups == 0)
        let group = try #require(report.groups.first)
        #expect(Set(group.photos.map { URL(filePath: $0.path).lastPathComponent })
                == ["IMG_0001.jpg", "IMG_0001 small.png", "IMG_0001 (1).jpg"])
        #expect(group.count == 3 && group.photos.map(\.suggested) == [true, false, false])
        #expect(group.photos[0].width == 1200 && group.photos[0].height == 900 && group.photos.last?.width == 600)
        #expect(group.freeable == group.photos.dropFirst().reduce(0) { $0 + $1.size } && report.freeable == group.freeable)
        // The same kinds of fields as the other commands: version a string, durationMs a whole number.
        let object = try #require(try JSONSerialization.jsonObject(with: Data(printed.stdout.utf8)) as? [String: Any])
        #expect(object["version"] is String && object["durationMs"] is Int && object["scannedAt"] is String)

        // Nothing moved by `similar`; the user's pick goes with `trash` and comes back with `restore`.
        let picked = group.photos.filter { !$0.suggested }.map(\.path)
        #expect(picked.allSatisfy { FileManager.default.fileExists(atPath: $0) })
        let trashed = try await CommandLineToolTests.trashReport(picked, sources)
        #expect(trashed.count == 2 && trashed.items.allSatisfy { !$0.skipped })
        #expect(picked.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
        #expect(FileManager.default.fileExists(atPath: group.photos[0].path))
        let restored = try await CommandLineToolTests.restoreReport(trashed.items.compactMap(\.trashed), sources)
        #expect(restored.count == 2 && picked.allSatisfy { FileManager.default.fileExists(atPath: $0) })

        let (textCode, text) = await CommandLineToolTests.run(["similar", "~/Pictures", "--in", "~/Media"], sources)
        #expect(textCode == 0 && text.stdout.contains("(suggested to keep)") && text.stdout.contains("1200×900"))
        #expect(text.stdout.contains("1 group, ") && text.stdout.contains("Nothing was moved."))
    }

    /// What Similar Photos moves is listed by `cleanmate restore --list` and put back by `cleanmate restore`.
    @Test func commandLineListsAndRestoresWhatItMoved() async throws {
        let fixture = try CommandLineToolTests.FilesFixture()
        let scene = Self.scene(seed: 4)
        let copy = fixture.home.appending(path: "Media/copy.jpg")
        let destination = try #require(CGImageDestinationCreateWithURL(copy as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, scene, nil)
        try #require(CGImageDestinationFinalize(destination))
        let size = try #require(try copy.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize)
        let photo = SimilarPhotos.Photo(url: copy, size: Int64(size), modified: .now, width: 1200, height: 900,
                                        name: "copy.jpg", location: "~/Media")
        let sources = fixture.sources(fullDiskAccess: true)
        let report = await SimilarPhotos.trash([photo], policy: sources.policy(), trash: sources.trash)
        try #require(report.trashed.count == 1)

        let list = try await CommandLineToolTests.restoreList([], sources)
        #expect(list.items.map(\.source) == ["Similar Photos"])
        let trashed = try #require(list.items.first?.trashed)
        let restored = try await CommandLineToolTests.restoreReport([trashed], sources)
        #expect(restored.count == 1 && FileManager.default.fileExists(atPath: copy.path))
    }
}

/// Small seeded generator, so a generated photo is the same on every run.
private struct SplitMix {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
