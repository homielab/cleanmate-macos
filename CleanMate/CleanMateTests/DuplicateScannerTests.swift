import Foundation
import Testing
@testable import CleanMate

/// Duplicate Files: its own search (`DuplicateScanner`), the app's model and `cleanmate dupes` on the same files.
@MainActor struct DuplicateScannerTests {
    /// A fake home with whole 4 KB blocks (allocated size = byte count):
    /// - three 2 MB copies (one in Downloads, the oldest), a hard link to one of them;
    /// - two 60 MB copies; a 500 KB pair;
    /// - copies the walk never opens: in an app, `node_modules`, `.git`, and a hidden file.
    final class Fixture {
        let root = TestTemp.url("CleanMateDupes")
        var home: URL { root.appending(path: "home") }
        var policy: SafetyPolicy { SafetyPolicy(home: home, temp: root.appending(path: "tmp")) }
        static let small = 2_002_944, big = 60_002_304, tiny = 503_808
        let day: TimeInterval = 86_400

        init() throws {
            let fm = FileManager.default
            let two = Data(repeating: 1, count: Self.small), sixty = Data(repeating: 2, count: Self.big)
            let half = Data(repeating: 3, count: Self.tiny)
            let files: [(String, Data, Double)] = [
                ("Documents/report.pdf", two, 20), ("Desktop/report copy.pdf", two, 10), ("Downloads/report.pdf", two, 90),
                ("Movies/clip.mov", sixty, 5), ("Movies/Old/clip.mov", sixty, 50),
                ("Pictures/a.jpg", half, 3), ("Pictures/b.jpg", half, 2),
                ("Applications/Tool.app/Contents/Resources/report.pdf", two, 1), ("Code/node_modules/x/report.pdf", two, 1),
                ("Code/.git/objects/report.pdf", two, 1), ("Documents/.report.pdf", two, 1),
            ]
            for (path, data, age) in files {
                let url = home.appending(path: path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
                try fm.setAttributes([.modificationDate: Date.now.addingTimeInterval(-age * day)], ofItemAtPath: url.path)
            }
            try fm.createDirectory(at: root.appending(path: "tmp"), withIntermediateDirectories: true)
            try fm.createDirectory(at: home.appending(path: "Music"), withIntermediateDirectories: true)
            try fm.linkItem(at: home.appending(path: "Documents/report.pdf"), to: home.appending(path: "Music/report-link.pdf"))
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        /// Group file names (paths under the home), largest group first.
        func names(_ groups: [DuplicateScanner.Group]) -> [[String]] {
            groups.map { $0.files.map { relative($0.url.path) } }
        }

        func relative(_ path: String) -> String {
            let real = HeadlessFiles.realPath(home.path) ?? home.path
            let resolved = HeadlessFiles.realPath(path) ?? path
            return String(resolved.dropFirst(real.count + 1))
        }
    }

    /// Default 1 MB: the 2 MB and 60 MB copies, a hard link counted once, nothing from apps, `node_modules`, `.git`
    /// or hidden files, the copy outside Downloads suggested (then the oldest), nothing ticked. 100 KB adds the pair.
    @Test func groupsAtTheDefaultSizeAndDownTo100KB() async throws {
        let fixture = try Fixture()
        let found = try await DuplicateScanner.scan(root: fixture.home, policy: fixture.policy)
        #expect(!found.stopped)
        let names = fixture.names(found.groups)
        #expect(names.count == 2, "\(names)")
        #expect(names.first == ["Movies/Old/clip.mov", "Movies/clip.mov"])
        let reports = try #require(names.last)
        // One of the two hard links (20 days old), the Desktop copy (10 days), then the oldest copy: it is in Downloads.
        #expect(reports.count == 3 && ["Documents/report.pdf", "Music/report-link.pdf"].contains(reports[0]), "\(reports)")
        #expect(reports.dropFirst() == ["Desktop/report copy.pdf", "Downloads/report.pdf"])
        #expect(Set(reports).isDisjoint(with: ["Applications/Tool.app/Contents/Resources/report.pdf", "Code/node_modules/x/report.pdf",
                                               "Code/.git/objects/report.pdf", "Documents/.report.pdf"]))
        #expect(found.groups.map(\.extraSize) == [Int64(Fixture.big), 2 * Int64(Fixture.small)])

        let small = try await DuplicateScanner.scan(root: fixture.home, minSize: 100_000, policy: fixture.policy)
        #expect(fixture.names(small.groups).count == 3 && fixture.names(small.groups).last == ["Pictures/a.jpg", "Pictures/b.jpg"])
    }

    /// A file with another hard link outside the group frees nothing: shown as such, never ticked by Select All but
    /// Suggested, and the selected size leaves it out.
    @Test func hardLinkedCopyFreesNothing() async throws {
        let fixture = try Fixture()
        let found = try await DuplicateScanner.scan(root: fixture.home, policy: fixture.policy)
        let group = try #require(found.groups.first { $0.files.count == 3 })
        let linked = try #require(group.files.first { $0.hardLinked })
        #expect(linked.url == group.suggested.url && group.freed(linked) == 0) // the oldest outside Downloads
        #expect(group.extraSize == 2 * Int64(Fixture.small))
    }

    /// Progress comes off the main thread: listing counts, then bytes compared out of the total, ending at the total.
    @Test func progressComesOffTheMainThreadAndReachesTheTotal() async throws {
        let fixture = try Fixture()
        let onMain = Locked(false)
        let steps = Locked<[DuplicateScanner.Progress]>([])
        _ = try await DuplicateScanner.scan(root: fixture.home, policy: fixture.policy, progress: { step in
            if Thread.isMainThread { onMain.withLock { $0 = true } }
            steps.withLock { $0.append(step) }
        })
        #expect(!onMain.withLock { $0 })
        let compared = steps.withLock { $0 }.compactMap { if case .comparing(let p) = $0 { p } else { nil } }
        let total = 3 * Int64(Fixture.small) + 2 * Int64(Fixture.big) // the hard link counts once
        #expect(compared.first == DuplicateFinder.Progress(done: 0, total: total))
        #expect(compared.last == DuplicateFinder.Progress(done: total, total: total))
        #expect(compared.map(\.done) == compared.map(\.done).sorted())
    }

    /// `cleanmate dupes` groups exactly what the app groups, at the default size and at 100 KB.
    @Test func commandLineGroupsWhatTheAppGroups() async throws {
        let fixture = try Fixture()
        var sources = HeadlessScan.Sources()
        let policy = fixture.policy
        sources.policy = { policy }
        sources.hasFullDiskAccess = { true }
        for size in [nil, "100KB"] {
            let model = DuplicatesModel()
            if size != nil { model.minSize = 100_000 }
            model.find(in: fixture.home, policy: policy, skipping: [])
            await until(model) { if case .results = $0.phase { true } else { false } }
            let app = Set(model.groups.map { Set($0.files.map { fixture.relative($0.url.path) }) })
            let (code, printed) = await CommandLineToolTests.run(["dupes", "--json"] + (size.map { ["--min-size", $0] } ?? []), sources)
            try #require(code == 0, "\(printed.stderr)")
            let report = try JSONDecoder().decode(HeadlessFiles.DupesReport.self, from: Data(printed.stdout.utf8))
            let cli = Set(report.groups.map { Set($0.files.map { fixture.relative($0.path) }) })
            #expect(app == cli && app.count == (size == nil ? 2 : 3), "\(app) vs \(cli)")
            #expect(report.minSize == (size == nil ? 1_000_000 : 100_000))
        }
    }

    // MARK: - The model

    private static func file(_ path: String, size: Int64 = 1_000_000, age: Double = 0, hardLinked: Bool = false) -> LargeFile {
        LargeFile(url: URL(fileURLWithPath: path), size: size, lastUsed: .now, kind: .other,
                  modified: Self.today.addingTimeInterval(-age * 86_400), hardLinked: hardLinked)
    }

    private static let today = Date(timeIntervalSince1970: 1_800_000_000)
    private static let policy = SafetyPolicy(home: URL(fileURLWithPath: "/Users/test"), temp: URL(fileURLWithPath: "/tmp/x"))

    /// Nothing ticked; Select All but Suggested skips the suggested copy and copies that free less than their size;
    /// ticking every copy is flagged; the selected size counts what each copy frees; the badge shows it.
    @Test func selectionKeepsTheSuggestedCopyAndCountsWhatIsFreed() async throws {
        let (a1, a2, a3) = (Self.file("/a1", age: 9), Self.file("/a2", age: 5), Self.file("/a3", age: 1, hardLinked: true))
        let (b1, clone) = (Self.file("/b1", size: 500_000), Self.file("/b2", size: 500_000))
        let model = DuplicatesModel()
        model.findDuplicates = { _, _, _, _, _, _ in
            DuplicateScanner.Result(groups: [DuplicateScanner.Group(files: [a1, a2, a3], privateSizes: [:]),
                                             DuplicateScanner.Group(files: [b1, clone], privateSizes: [b1.url: 0, clone.url: 4_096])])
        }
        model.find(in: URL(fileURLWithPath: "/Users/test"), policy: Self.policy, skipping: [])
        await until(model) { if case .results = $0.phase { true } else { false } }
        #expect(model.checked.isEmpty && model.fileCount == 5)
        model.checkAllButSuggested()
        #expect(model.checked == [a2.url]) // a3 frees nothing, b2 only 4 KB
        #expect(model.checkedSize == 1_000_000 && model.groupsLosingEveryCopy.isEmpty)
        model.checked = [a1.url, a2.url, a3.url, clone.url]
        #expect(model.checkedSize == 2_000_000 + 4_096 && model.groupsLosingEveryCopy == ["a1"])
        #expect(Module.largeFiles.badge(hasResults: true, size: model.checkedSize, files: model.fileCount) == .size(2_004_096))
        #expect(Module.largeFiles.badge(hasResults: true, size: 0, files: 5) == .files(5))
        model.search = "b2"
        #expect(model.shownGroups.map(\.suggested.url) == [b1.url]) // the whole group stays in view
        model.uncheckAll()
        #expect(model.checked == [a1.url, a2.url, a3.url])
    }

    /// The copy to keep: outside Downloads first, then the oldest, then the shortest path.
    @Test func suggestedCopyIsOutsideDownloadsThenTheOldest() {
        let downloads = "/Users/test/Downloads/"
        let files = [Self.file("/Users/test/Downloads/x", age: 99), Self.file("/Users/test/Documents/long/x", age: 5),
                     Self.file("/Users/test/Desktop/x", age: 5), Self.file("/Users/test/Pictures/x", age: 1)]
        #expect(DuplicateScanner.suggestedOrder(files, downloads: downloads).map(\.url.path)
                == ["/Users/test/Desktop/x", "/Users/test/Documents/long/x", "/Users/test/Pictures/x", "/Users/test/Downloads/x"])
    }

    /// Stop while comparing keeps the groups found so far (`stopped`); the progress shown follows the reports; the
    /// main thread stays free while the search runs.
    @Test(.timeLimit(.minutes(1))) func stopWhileComparingKeepsTheGroupsFound() async throws {
        let (a, b) = (Self.file("/a"), Self.file("/b"))
        let model = DuplicatesModel()
        let started = SignalCount()
        model.findDuplicates = { _, _, _, _, _, progress in
            progress(.listing(500))
            progress(.comparing(.init(done: 0, total: 10)))
            progress(.comparing(.init(done: 10, total: 10))) // shown at once: the last report always is
            started.add()
            while !Task.isCancelled { await Task.yield() }
            return DuplicateScanner.Result(groups: [DuplicateScanner.Group(files: [a, b], privateSizes: [:])], stopped: true)
        }
        model.find(in: URL(fileURLWithPath: "/Users/test"), policy: Self.policy, skipping: [])
        await started.reach(1)
        await until(model) { if case .comparing = $0.phase { $0.progress.done == 10 } else { false } }
        #expect(model.progress.total == 10 && model.isSearching)
        model.stop()
        #expect(model.stopping)
        await until(model) { if case .results = $0.phase { true } else { false } }
        #expect(model.stopped && !model.stopping && model.groups.count == 1 && model.checked.isEmpty)
        // Find Again searches the whole scope again.
        model.findDuplicates = { _, _, _, _, _, _ in DuplicateScanner.Result() }
        model.findAgain()
        await until(model) { if case .results = $0.phase { true } else { false } }
        #expect(!model.stopped && model.groups.isEmpty)
    }

    /// Stop while listing goes back to the start: nothing compared, nothing to show.
    @Test(.timeLimit(.minutes(1))) func stopWhileListingGoesBackToIdle() async throws {
        let model = DuplicatesModel()
        let started = SignalCount()
        model.findDuplicates = { _, _, _, _, _, _ in
            started.add()
            while !Task.isCancelled { await Task.yield() }
            throw CancellationError()
        }
        model.find(in: URL(fileURLWithPath: "/Users/test"), policy: Self.policy, skipping: [])
        await started.reach(1)
        model.stop()
        guard case .idle = model.phase else { Issue.record("not idle"); return }
        #expect(model.error == nil && model.groups.isEmpty)
    }

    /// Another size searches the same place again; a failure shows its reason and Try Again searches again.
    @Test(.timeLimit(.minutes(1))) func anotherSizeSearchesAgainAndAFailureCanBeRetried() async throws {
        let sizes = Locked<[Int64]>([])
        let model = DuplicatesModel()
        model.findDuplicates = { _, size, _, _, _, _ in
            sizes.withLock { $0.append(size) }
            if size == 100_000 { throw CocoaError(.fileReadNoPermission) }
            return DuplicateScanner.Result()
        }
        model.find(in: URL(fileURLWithPath: "/Users/test"), policy: Self.policy, skipping: [])
        await until(model) { if case .results = $0.phase { true } else { false } }
        model.minSize = 100_000
        await until(model) { $0.error != nil }
        model.minSize = 10_000_000
        await until(model) { if case .results = $0.phase { true } else { false } }
        #expect(sizes.withLock { $0 } == [1_000_000, 100_000, 10_000_000] && model.error == nil)
    }

    /// Moving ticked copies: they leave their groups (a group left with one copy goes), Large & Old Files hears of
    /// them, the done screen counts what they free, and Undo puts them back.
    @Test(.timeLimit(.minutes(1))) func trashDropsTheCopiesAndUndoPutsThemBack() async throws {
        let (a1, a2, b1, b2, b3) = (Self.file("/a1"), Self.file("/a2"), Self.file("/b1", hardLinked: true), Self.file("/b2"), Self.file("/b3"))
        let model = DuplicatesModel()
        model.findDuplicates = { _, _, _, _, _, _ in
            DuplicateScanner.Result(groups: [DuplicateScanner.Group(files: [a1, a2], privateSizes: [:]),
                                             DuplicateScanner.Group(files: [b2, b1, b3], privateSizes: [:])])
        }
        var told: [URL] = []
        model.onTrashed = { told += $0 }
        model.trashFiles = { files, _ in
            CleanReport(freed: files.reduce(0) { $0 + $1.size },
                        trashed: files.map { TrashedItem(original: $0.url, inTrash: URL(fileURLWithPath: "/T" + $0.url.path), size: $0.size) })
        }
        let restored = Locked(0)
        model.restore = { items in restored.withLock { $0 += items.count }; return TrashUndo.Result() }
        model.find(in: URL(fileURLWithPath: "/Users/test"), policy: Self.policy, skipping: [])
        await until(model) { if case .results = $0.phase { true } else { false } }
        model.checked = [a2.url, b1.url]
        await model.trash()
        guard case .done = model.phase else { Issue.record("not done"); return }
        #expect(model.groups.map(\.files) == [[b2, b3]] && Set(told) == [a2.url, b1.url])
        #expect(model.lastFreed == 1_000_000) // the hard link frees nothing
        await model.undoTrash()
        #expect(restored.withLock { $0 } == 2)
    }
}
