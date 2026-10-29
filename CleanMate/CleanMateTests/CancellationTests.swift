import Foundation
import Testing
@testable import CleanMate

/// Cancelling the parallel walks midway: Space Lens' `measure`, `Scanner.undatedTree`, Large Files'
/// walk and `Scanner.scan`. A cancelled walk stops (throws or returns nil), never hands back a partial size.
/// Fake temp trees only; assertions hold whatever the timing, so a busy machine cannot make them flaky.
struct CancellationTests {
    /// home/Tree/a0…a9/b0…b9/c0…c4/f0…f3: 2 000 small files in 610 folders, each leaf folder far under 1 000 entries.
    final class Tree: Sendable {
        let root: URL
        let home: URL
        let tree: URL
        let policy: SafetyPolicy

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "CleanMateCancel-\(UUID().uuidString)")
            home = root.appending(path: "home")
            tree = home.appending(path: "Tree")
            let temp = root.appending(path: "tmp")
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            for a in 0..<10 { for b in 0..<10 { for c in 0..<5 {
                let folder = tree.appending(path: "a\(a)/b\(b)/c\(c)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for f in 0..<4 { try Data(count: 20_000).write(to: folder.appending(path: "f\(f).bin")) }
            } } }
            policy = SafetyPolicy(home: home, temp: temp)
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    /// Runs `work` in a task cancelled after `delay` microseconds (0: at once), or by `cancel()` from inside it.
    final class Canceller: Sendable {
        private let task = Locked<Task<Void, Never>?>(nil)
        func cancel() { task.withLock { $0?.cancel() } }
        func run(after delay: Int? = nil, _ work: @escaping @Sendable () async -> Void) async {
            let ready = Locked(false)
            let handle = Task {
                while !ready.withLock({ $0 }) { await Task.yield() } // `cancel()` from `work` needs the handle stored
                await work()
            }
            task.withLock { $0 = handle }
            ready.withLock { $0 = true }
            if let delay {
                if delay > 0 { try? await Task.sleep(for: .microseconds(delay)) }
                handle.cancel()
            }
            await handle.value
        }
    }

    static let delays = [0, 50, 200, 500, 1_000, 2_000, 5_000, 10_000]

    /// Unsplit (`depth` 0): one small folder, a single walk of 25 entries; else the whole tree.
    static func folder(_ box: Tree, _ depth: Int) -> URL { depth == 0 ? box.tree.appending(path: "a0/b0") : box.tree }

    // MARK: Space Lens

    @Test(arguments: [0, 3])
    func measureCancelledBeforeItStartsThrows(splitDepth: Int) async throws {
        let box = try Tree()
        let thrown = Locked(false)
        await Canceller().run {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await SpaceLens.measure(Self.folder(box, splitDepth), splitDepth: splitDepth) } catch is CancellationError {
                thrown.withLock { $0 = true }
            } catch {}
        }
        #expect(thrown.withLock { $0 }) // a walk under 1 000 entries used to finish and return its size
    }

    @Test func measureCancelledMidwayThrowsOrReturnsTheFullSize() async throws {
        let box = try Tree()
        let full = try await SpaceLens.measure(box.tree, splitDepth: 3).size
        let outcomes = Locked<[Int64?]>([])
        for delay in Self.delays {
            await Canceller().run(after: delay) {
                let size = try? await SpaceLens.measure(box.tree, splitDepth: 3).size
                outcomes.withLock { $0.append(size) }
            }
        }
        for size in outcomes.withLock({ $0 }) { #expect(size == nil || size == full) }
    }

    // MARK: Scanner.undatedTree / entry (Uninstaller sizes)

    @Test(arguments: [0, 3])
    func undatedTreeCancelledBeforeItStartsReturnsNil(depth: Int) async throws {
        let box = try Tree()
        let device = try #require(SafetyPolicy.deviceID(box.tree.path))
        let result = Locked<(Int64, Date, Bool)??>(nil)
        await Canceller().run {
            withUnsafeCurrentTask { $0?.cancel() }
            let found = await Scanner.undatedTree(Self.folder(box, depth).path, device: device, links: .init(), depth: depth)
            result.withLock { $0 = .some(found) }
        }
        #expect(result.withLock { $0 } != nil)
        #expect(result.withLock { $0 }! == nil)
    }

    @Test func entryCancelledMidwayIsNilOrTheFullSize() async throws {
        let box = try Tree()
        let full = try #require(await Scanner.entry(at: box.tree, olderThan: nil, splitDepth: Scanner.splitDepth)?.size)
        let outcomes = Locked<[Int64?]>([])
        for delay in Self.delays {
            await Canceller().run(after: delay) {
                let size = await Scanner.entry(at: box.tree, olderThan: nil, splitDepth: Scanner.splitDepth)?.size
                outcomes.withLock { $0.append(size) }
            }
        }
        for size in outcomes.withLock({ $0 }) { #expect(size == nil || size == full) }
    }

    // MARK: Large & Old Files

    @Test func largeFilesCancelledMidwayThrows() async throws {
        let box = try Tree()
        let canceller = Canceller()
        let outcome = Locked<String>("")
        let checked = Locked(0)
        await canceller.run {
            do {
                let files = try await LargeFileScanner.scan(root: box.home, minSize: 1, policy: box.policy, spotlightLastUsed: { _ in nil },
                                                            progress: { count in
                    checked.withLock { $0 = max($0, count) }
                    if count == 500 { canceller.cancel() }
                })
                outcome.withLock { $0 = "returned \(files.count)" }
            } catch is CancellationError {
                outcome.withLock { $0 = "cancelled" }
            } catch {
                outcome.withLock { $0 = "\(error)" }
            }
        }
        #expect(outcome.withLock { $0 } == "cancelled")
        #expect(checked.withLock { $0 } < 2_610) // stopped before checking every entry
    }

    @Test func largeFilesCancelledMidwayThrowsOrReturnsEverything() async throws {
        let box = try Tree()
        let full = try await LargeFileScanner.scan(root: box.home, minSize: 1, policy: box.policy, spotlightLastUsed: { _ in nil })
        #expect(full.count == 2_000)
        let outcomes = Locked<[[URL]?]>([])
        for delay in Self.delays {
            await Canceller().run(after: delay) {
                let files = try? await LargeFileScanner.scan(root: box.home, minSize: 1, policy: box.policy, spotlightLastUsed: { _ in nil })
                outcomes.withLock { $0.append(files?.map(\.url)) }
            }
        }
        for urls in outcomes.withLock({ $0 }) { #expect(urls == nil || urls == full.map(\.url)) } // same order too
    }

    // MARK: Smart Scan

    /// Entries: the 10 `a*` folders of the tree, listed as a cache item's children.
    func item(_ box: Tree, skipsEntry: (@Sendable () -> @Sendable (URL) -> Bool)? = nil) -> CleanerItem {
        var item = CleanerItem(id: "t", title: "t", paths: ["~/Tree"])
        item.skipsEntry = skipsEntry
        return item
    }

    @Test func scanCancelledWhileListingReturnsNoEntry() async throws {
        let box = try Tree()
        let canceller = Canceller()
        let seen = Locked(0)
        let entries = Locked<[ScanEntry]?>(nil)
        await canceller.run {
            let scan = await Scanner.scan(self.item(box) {
                { _ in if seen.withLock({ $0 += 1; return $0 }) == 5 { canceller.cancel() }; return false }
            }, policy: box.policy)
            entries.withLock { $0 = scan.entries }
        }
        #expect(entries.withLock { $0 } == [])
    }

    @Test func scanCancelledMidwayNeverListsAPartlyMeasuredEntry() async throws {
        let box = try Tree()
        let full = await Scanner.scan(item(box), policy: box.policy)
        #expect(full.entries.count == 10)
        let sizes = Dictionary(uniqueKeysWithValues: full.entries.map { ($0.url, $0.size) })
        let outcomes = Locked<[[ScanEntry]]>([])
        for delay in Self.delays {
            await Canceller().run(after: delay) {
                let scan = await Scanner.scan(self.item(box), policy: box.policy)
                outcomes.withLock { $0.append(scan.entries) }
            }
        }
        // Entries measured before the cancel may stay (callers discard a cancelled scan), each one whole.
        for entries in outcomes.withLock({ $0 }) {
            for entry in entries { #expect(entry.size == sizes[entry.url]) }
        }
    }
}
