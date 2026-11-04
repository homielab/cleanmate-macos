import Foundation
import Testing
@testable import CleanMate

/// Stop during a move to the Trash, the records kept per clean run, an unreadable records file and Empty Trash; in a
/// fake home with a fake Trash, never the real ones.
@MainActor
struct TrashStopTests {
    typealias Fixture = CommandLineToolTests.FilesFixture

    /// `count` one-byte files `Many/<n>.bin` in the fixture's home.
    private static func files(_ count: Int, in fixture: Fixture) throws -> [(url: URL, size: Int64)] {
        let folder = fixture.home.appending(path: "Many")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try (0..<count).map { number in
            let url = folder.appending(path: "\(number).bin")
            try Data([1]).write(to: url)
            return (URL(fileURLWithPath: SafetyPolicy.normalize(url)), 1)
        }
    }

    /// Moves `items` to the fixture's Trash as a module does, under `run`.
    private static func move(_ items: [(url: URL, size: Int64)], _ fixture: Fixture, run: TrashRun = TrashRun(),
                             afterEach: @escaping (Int) -> Void = { _ in }) -> CleanReport {
        let sources = fixture.sources(fullDiskAccess: true)
        let policy = sources.policy()
        let moved = Locked(0)
        return TrashRun.$current.withValue(run) {
            CleanReport.trashing(items, module: "Large & Old Files", home: fixture.home,
                                 allows: { policy.allowsSpaceLensItem($0) }, trash: { url in
                defer { afterEach(moved.withLock { $0 += 1; return $0 }) }
                return try sources.trash(url)
            })
        }
    }

    // MARK: - Stop

    @Test(.timeLimit(.minutes(1))) func stopAfterTheTenthOfAThousandLeavesTheRest() throws {
        let fixture = try Fixture()
        let items = try Self.files(1_000, in: fixture)
        let run = TrashRun()
        let report = Self.move(items, fixture, run: run) { moved in if moved == 10 { run.stop() } }
        #expect(report.trashed.count == 10)
        #expect(report.stopped == 990 && report.notCleaned == 0)
        #expect(items.prefix(10).allSatisfy { !FileManager.default.fileExists(atPath: $0.url.path) })
        #expect(items.dropFirst(10).allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
        // Recorded as one run: Moved to the Trash lists exactly what moved.
        let records = TrashRecords.inTrash(home: fixture.home)
        #expect(records.count == 10 && Set(records.map(\.run)) == [run.id])
    }

    @Test func aStoppedUninstallMovesNothing() async throws {
        let run = TrashRun()
        run.stop()
        let entry = AppDataEntry(url: URL(filePath: "/nonexistent/home/Library/Caches/com.test.stop"), size: 10)
        let report = try await TrashRun.$current.withValue(run) {
            try await Uninstaller.trash(app: URL(filePath: "/nonexistent/Stop.app"), data: [entry],
                                        moveToTrash: { _ in Issue.record("moved"); return nil })
        }
        #expect(report.stopped == 2 && report.trashed.isEmpty && report.freed == 0)
        #expect(UninstallerModel.stoppedBeforeApp(report, data: [entry]))
    }

    // MARK: - Records kept per run

    @Test(.timeLimit(.minutes(2))) func aRunOf1500IsKeptWholeAndPutBackAllReturnsEveryItem() async throws {
        let fixture = try Fixture()
        let items = try Self.files(1_500, in: fixture)
        let report = Self.move(items, fixture)
        try #require(report.trashed.count == 1_500)
        #expect(TrashRecords.inTrash(home: fixture.home).count == 1_500)

        let model = TrashedItemsModel(home: fixture.home)
        await model.load()
        #expect(model.rows.count == 1_500)
        await model.restore(model.shown)
        #expect(model.restoredCount == 1_500 && model.rows.isEmpty && model.failures.isEmpty)
        #expect(items.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
        #expect(TrashRecords.inTrash(home: fixture.home).isEmpty)
    }

    @Test func keepsWholeRunsUpToTheRunAndRecordLimits() {
        func record(_ name: String, run: String?, date: String? = nil) -> TrashRecords.Record {
            let item = TrashedItem(original: URL(filePath: "/nonexistent/\(name)"), inTrash: URL(filePath: "/nonexistent/.Trash/\(name)"),
                                   size: 1, folder: "/nonexistent", volume: 1)
            var record = TrashRecords.Record(item, id: SafeRemoval.FileID(device: 1, inode: 1), run: run)
            record.date = date
            return record
        }
        // Oldest first: run a (3), legacy records of one date (2), run b (4), run c (1).
        let records = (0..<3).map { record("a\($0)", run: "a") } + (0..<2).map { record("l\($0)", run: nil, date: "2026-01-01") }
            + (0..<4).map { record("b\($0)", run: "b") } + [record("c0", run: "c")]
        #expect(TrashRecords.kept(records) == records)
        // Two runs at most: b and c, whole and in order.
        #expect(TrashRecords.kept(records, runLimit: 2).map(\.runKey) == ["b", "b", "b", "b", "c"])
        // 6 records at most: c (1) and b (4) fit, the legacy run (2) would pass the limit, so it and a go.
        #expect(TrashRecords.kept(records, recordLimit: 6).map(\.runKey) == ["b", "b", "b", "b", "c"])
        #expect(TrashRecords.kept(records, recordLimit: 7).map(\.runKey) == ["2026-01-01", "2026-01-01", "b", "b", "b", "b", "c"])
        // The newest run is kept whole even over the limit.
        #expect(TrashRecords.kept(records, recordLimit: 0).map(\.runKey) == ["c"])
        let big = (0..<5).map { record("d\($0)", run: "d") }
        #expect(TrashRecords.kept(records + big, recordLimit: 3).count == 5)
    }

    // MARK: - Unreadable records file

    @Test func anUnreadableRecordsFileIsSetAsideAndANewOneStarts() async throws {
        let fixture = try Fixture()
        let url = TrashRecords.url(home: fixture.home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[{\"original\": broken".utf8).write(to: url)

        // Reading it (the window, `restore --list`) sets it aside, kept as it was.
        let model = TrashedItemsModel(home: fixture.home)
        await model.load()
        #expect(model.rows.isEmpty)
        let broken = try #require(TrashRecords.broken(home: fixture.home).first)
        #expect(broken.lastPathComponent.hasPrefix(TrashRecords.brokenPrefix))
        #expect(try String(contentsOf: broken, encoding: .utf8) == "[{\"original\": broken")
        #expect(model.brokenFile == broken)
        #expect(!FileManager.default.fileExists(atPath: url.path))

        // A new history starts with the next move.
        let items = try Self.files(2, in: fixture)
        #expect(Self.move(items, fixture).trashed.count == 2)
        await model.load()
        #expect(model.rows.count == 2 && model.brokenFile == broken)

        // Unreadable again on a write: set aside next to the first, never overwritten.
        try Data("{".utf8).write(to: url)
        let another = URL(fileURLWithPath: SafetyPolicy.normalize(fixture.home.appending(path: "Media/small.bin")))
        #expect(Self.move([(another, 1)], fixture).trashed.count == 1)
        #expect(TrashRecords.broken(home: fixture.home).count == 2)
        #expect(TrashRecords.inTrash(home: fixture.home).count == 1)

        // Older than the notice: the window no longer mentions it.
        let later = Date.now.addingTimeInterval(Double(TrashedItemsModel.brokenNoticeDays + 1) * 86_400)
        #expect(TrashedItemsModel.recentlyBroken(home: fixture.home, now: later) == nil)
    }

    @Test func restoreListSaysOnStderrWhenItSetTheFileAside() async throws {
        let fixture = try Fixture()
        let url = TrashRecords.url(home: fixture.home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let (code, printed) = await CommandLineToolTests.run(["restore", "--list", "--json"], fixture.sources(fullDiskAccess: true))
        #expect(code == 0)
        #expect(printed.stderr.contains("couldn’t be read"))
        let list = try JSONDecoder().decode(HeadlessTrash.ListReport.self, from: Data(printed.stdout.utf8))
        #expect(list.count == 0)
        // Once set aside, nothing more to say.
        let (_, again) = await CommandLineToolTests.run(["restore", "--list", "--json"], fixture.sources(fullDiskAccess: true))
        #expect(again.stderr.isEmpty)
    }

    // MARK: - Empty Trash

    @Test func emptyTrashButtonShowsWhileTheTrashHoldsSomething() async {
        let center = NotificationCenter()
        let bin = TrashBin(center: center)
        let contents = Locked((count: 2, size: Int64(4_096)))
        bin.read = { contents.withLock { $0 } }
        bin.emptyTrash = {
            contents.withLock { $0 = (0, 0) }
            return CleanReport(freed: 4_096)
        }
        #expect(bin.hasItems) // not read yet: shown until a read says empty
        await bin.refreshIfStale()
        #expect(bin.hasItems && bin.contents?.size == 4_096 && !bin.stale)

        await bin.empty()
        #expect(!bin.hasItems && bin.emptiedCount == 1 && bin.lastEmptied?.freed == 4_096)

        // A move to the Trash (an activity log line) makes it read again.
        contents.withLock { $0 = (1, 10) }
        center.post(name: ActivityLog.didRecord, object: nil)
        await until(bin) { $0.stale }
        #expect(bin.hasItems)
        await bin.refreshIfStale()
        #expect(bin.contents?.count == 1)
    }
}

/// A fake move to the Trash for the module tests: the first item moves, then it waits until `resume` (the test clicks
/// Stop meanwhile); every item after that is left once Stop is seen, as `CleanReport.trashing` does.
nonisolated func fakeMoveWithStop(_ urls: [URL], started: SignalCount, resume: SignalCount) async -> CleanReport {
    var report = CleanReport()
    for (index, url) in urls.enumerated() {
        if TrashRun.current?.isStopped == true {
            report.stopped = urls.count - index
            break
        }
        report.freed += 1
        report.trashed.append(TrashedItem(original: url, inTrash: url, size: 1, folder: "/nonexistent", volume: 1))
        if index == 0 {
            started.add()
            await resume.reach(1)
        }
    }
    return report
}

// MARK: - Stop in each module

extension LargeFilesTests {
    /// Large & Old Files (and its Duplicates listing, the same move): Stop while moving 4 files leaves 3, still ticked.
    @MainActor @Test(.timeLimit(.minutes(1))) func stopWhileMovingToTheTrash() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try (1...4).map { try file("Movies/\($0).mov") }
        let model = LargeFilesModel()
        model.home = home
        model.hasFullDiskAccess = { true }
        model.scanFiles = { _, _, _, _ in urls.map { LargeFile(url: $0, size: 100_000_000, lastUsed: .distantPast, kind: .video, home: self.home) } }
        let (started, resume) = (SignalCount(), SignalCount())
        model.trashFiles = { await fakeMoveWithStop($0.map(\.url), started: started, resume: resume) }
        model.scan()
        await until(model) { if case .results = $0.phase { true } else { false } }
        try #require(model.files.count == 4)
        model.checked = Set(urls)
        let moving = Task { await model.trash() }
        await started.reach(1)
        guard case .trashing = model.phase else { Issue.record("phase \(model.phase)"); return }
        model.stopTrash()
        #expect(model.stoppingTrash)
        resume.add()
        await moving.value
        #expect(model.lastTrash?.stopped == 3 && model.lastTrash?.trashed.count == 1 && !model.stoppingTrash)
        #expect(model.files.count == 3 && model.checked.count == 3)
    }
}

extension SpaceLensTests {
    /// Space Lens: Stop while moving 3 items; the report counts the 2 left.
    @MainActor @Test func stopWhileMovingToTheTrash() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a", "b", "c"] { try file("A/\(name).bin") }
        let model = SpaceLensModel()
        model.hasFullDiskAccess = { true }
        let (started, resume) = (SignalCount(), SignalCount())
        model.trashItems = { await fakeMoveWithStop($0.map(\.url), started: started, resume: resume) }
        model.start(at: home.appending(path: "A"))
        while model.measuring { try await Task.sleep(for: .milliseconds(5)) }
        try #require(model.items.count == 3)
        let moving = Task { await model.trash(model.items) }
        await started.reach(1)
        #expect(model.trashing)
        model.stopTrash()
        #expect(model.stoppingTrash)
        resume.add()
        await moving.value
        #expect(model.report?.stopped == 2 && model.report?.trashed.count == 1 && !model.trashing && !model.stoppingTrash)
    }
}

extension SimilarPhotosTests {
    /// Similar Photos: Stop while moving 2 photos; the done screen counts the one left.
    @Test(.timeLimit(.minutes(1))) func stopWhileMovingToTheTrash() async throws {
        _ = try writeSet()
        let model = model()
        let (started, resume) = (SignalCount(), SignalCount())
        model.trashPhotos = { photos, _ in await fakeMoveWithStop(photos.map(\.url), started: started, resume: resume) }
        model.find(in: home, policy: policy, skipping: [])
        await results(model)
        try #require(model.groups.count == 1)
        model.checkAllButSuggested()
        try #require(model.checkedPhotos.count == 2)
        let moving = Task { await model.trash() }
        await started.reach(1)
        guard case .trashing = model.phase else { Issue.record("phase \(model.phase)"); return }
        model.stopTrash()
        #expect(model.stoppingTrash)
        resume.add()
        await moving.value
        guard case .done(let report) = model.phase else { Issue.record("not done"); return }
        #expect(report.stopped == 1 && report.trashed.count == 1 && !model.stoppingTrash)
    }
}

extension UninstallerBatchTests {
    /// Uninstaller: Stop during a batch finishes the app under way; the apps not started stay, each said stopped.
    @Test(.timeLimit(.minutes(1))) func stopDuringABatchLeavesTheAppsNotStarted() async {
        let (a, b, c) = (Self.app("Alpha"), Self.app("Bravo"), Self.app("Charlie"))
        let fake = Fake()
        let model = fake.model([a, b, c])
        let (started, resume) = (SignalCount(), SignalCount())
        model.trash = { app, data throws(Uninstaller.AppTrashError) in
            fake.calls.append((app, data.map(\.url)))
            started.add()
            await resume.reach(1)
            return CleanReport(freed: 100)
        }
        model.appTicks = [a.url, b.url, c.url]
        await model.loadBatch()
        let moving = Task { await model.removeBatch() }
        await started.reach(1)
        #expect(model.movingToTrash)
        model.stopTrash()
        #expect(model.stoppingTrash)
        resume.add()
        await moving.value
        #expect(fake.calls.map(\.0) == [a.url] && !model.movingToTrash && !model.stoppingTrash)
        guard case .batch(let result)? = model.outcome else { Issue.record("no batch outcome"); return }
        #expect(result.removed.map(\.url) == [a.url])
        #expect(result.skipped.map(\.reason) == [.stopped, .stopped])
        #expect(model.apps.map(\.url) == [b.url, c.url])
        #expect(UninstallerView.batchMessage(result).contains("Bravo"))
    }

    /// Uninstaller: Stop before the app moved (one app) keeps it listed; the alert says nothing went.
    @Test func stopBeforeTheAppMovedKeepsItListed() async {
        let a = Self.app("Alpha")
        let model = Fake().model([a])
        model.trash = { _, data throws(Uninstaller.AppTrashError) in
            var report = CleanReport()
            report.stopped = 1 + data.count
            return report
        }
        model.selection = .app(a.url)
        await model.loadEntries()
        await model.remove()
        guard case .removed(let report)? = model.outcome else { Issue.record("no outcome"); return }
        #expect(report.stopped > 0 && model.apps == [a] && model.selection == .app(a.url))
        #expect(UninstallerView.stoppedLine(report) != nil)
    }
}
