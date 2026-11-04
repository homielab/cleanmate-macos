import AppKit
import Foundation
import Testing
@testable import CleanMate

/// Overlapping scans, cleans and loads in the models. Slow work is simulated by injected hooks
/// that ignore cancellation, like a real file walk; nothing touches real files.
@MainActor
struct RaceTests {
    /// Call counter plus gates the injected hooks wait on (gate n opens call n).
    final class Gates: Sendable {
        let state = Locked((calls: 0, open: Set<Int>(), left: 0))
        /// Counts the call and waits for its gate when `gated` holds; returns the call number.
        func enter(gated: (Int) -> Bool = { _ in true }) async -> Int {
            let call = state.withLock { $0.calls += 1; return $0.calls }
            let deadline = ContinuousClock.now + .seconds(60) // a gate the test never opens fails its checks, not the run
            while gated(call) && !state.withLock({ $0.open.contains(call) }) && ContinuousClock.now < deadline {
                // A detached sleep: a cancelled caller's own sleep throws at once and would busy-spin.
                await Task.detached { try? await Task.sleep(for: .milliseconds(5)) }.value
            }
            state.withLock { $0.left += 1 }
            return call
        }
        var calls: Int { state.withLock { $0.calls } }
        /// Calls that got past their gate (returned).
        var left: Int { state.withLock { $0.left } }
        func open(_ call: Int) { _ = state.withLock { $0.open.insert(call) } }
    }

    func until(_ condition: () -> Bool) async throws {
        for _ in 0..<3000 where !condition() { try await Task.sleep(for: .milliseconds(10)) } // ≥ 30 s: busy machines
    }

    func smartScan(_ gates: Gates, gated: @escaping @Sendable (Int) -> Bool) -> SmartScanModel {
        let item = CleanerItem(id: "x", title: "X", paths: [])
        let model = SmartScanModel.isolated(module: .smartScan) { [CleanerGroup(id: "g", title: "G", systemImage: "x", items: [item])] }
        model.processNames = { [] }
        model.scanItem = { _, _ in ItemScan(measuredSize: Int64(await gates.enter(gated: gated)) * 100) }
        return model
    }

    @Test func olderScanNeverOverwritesANewerOne() async throws {
        let gates = Gates()
        let model = smartScan(gates) { $0 == 1 }
        model.startScan()
        try await until { gates.calls == 1 }
        model.startScan()
        try await until { model.scans["x"]?.size == 200 }
        gates.open(1) // the first scan finishes after the second
        try await until { gates.left == 2 }
        try await Task.sleep(for: .milliseconds(200))
        guard case .results = model.phase else { Issue.record("phase \(model.phase)"); return }
        #expect(model.scans["x"]?.size == 200 && model.selected == ["x"])
    }

    @Test func cancellingBackToBackScansRestoresWhatWasShownBefore() async throws {
        let gates = Gates()
        let model = smartScan(gates) { _ in true }
        model.startScan()
        try await until { gates.calls == 1 }
        model.startScan()
        try await until { gates.calls == 2 }
        model.cancelScan()
        gates.open(2)
        gates.open(1)
        try await until { if case .idle = model.phase { true } else { false } } // a fixed 200 ms flaked under a loaded full run
        guard case .idle = model.phase else { Issue.record("phase \(model.phase)"); return }
        #expect(model.scans.isEmpty)
    }

    @Test func cleanOnlyRunsFromResultsAndScanNotWhileCleaning() async {
        let model = smartScan(Gates()) { _ in false }
        model.phase = .scanning // ⌘R started a scan behind the Clean dialog
        model.selected = ["x"]
        await model.clean()
        guard case .scanning = model.phase else { Issue.record("phase \(model.phase)"); return }
        model.phase = .cleaning
        await model.scan()
        model.startScan()
        guard case .cleaning = model.phase else { Issue.record("phase \(model.phase)"); return }
        #expect(model.selected == ["x"])
    }

    @Test func largeFilesTrashOnlyFromResultsAndNoScanWhileTrashing() async {
        let model = LargeFilesModel()
        let file = LargeFile(url: URL(fileURLWithPath: "/nonexistent/a"), size: 100_000_000, lastUsed: .now, kind: .other)
        model.files = [file]
        model.checked = [file.url]
        model.phase = .scanning
        await model.trash()
        guard case .scanning = model.phase else { Issue.record("phase \(model.phase)"); return }
        #expect(model.files == [file])
        model.phase = .trashing
        model.scan()
        guard case .trashing = model.phase else { Issue.record("phase \(model.phase)"); return }
    }

    /// Scan call n finds one file of n × 100 MB and reports n × 1000 entries checked.
    func largeFiles(_ gates: Gates, gated: @escaping @Sendable (Int) -> Bool) -> LargeFilesModel {
        let model = LargeFilesModel()
        model.hasFullDiskAccess = { true }
        model.scanFiles = { _, _, _, progress in
            let call = await gates.enter(gated: gated)
            progress(call * 1000)
            return [LargeFile(url: URL(fileURLWithPath: "/nonexistent/\(call)"), size: Int64(call) * 100_000_000,
                              lastUsed: .now, kind: .other)]
        }
        return model
    }

    @Test func olderLargeFilesScanNeverOverwritesANewerOne() async throws {
        let gates = Gates()
        let model = largeFiles(gates) { $0 == 1 }
        model.scan()
        try await until { gates.calls == 1 }
        model.scan()
        try await until { if case .results = model.phase { true } else { false } }
        gates.open(1) // the first scan finishes after the second
        try await until { gates.left == 2 }
        try await Task.sleep(for: .milliseconds(200))
        guard case .results = model.phase else { Issue.record("phase \(model.phase)"); return }
        #expect(model.files.map(\.size) == [200_000_000] && model.scannedCount == 2000)
    }

    @Test func cancellingBackToBackLargeFilesScansRestoresWhatWasShownBefore() async throws {
        let gates = Gates()
        let model = largeFiles(gates) { _ in true }
        model.scan()
        try await until { gates.calls == 1 }
        model.scan()
        try await until { gates.calls == 2 }
        model.cancel()
        gates.open(2)
        gates.open(1)
        try await until { if case .idle = model.phase { true } else { false } }
        guard case .idle = model.phase else { Issue.record("phase \(model.phase)"); return }
        #expect(model.files.isEmpty)
    }

    @Test func olderLoginItemsListingNeverReplacesANewerOne() async throws {
        let gates = Gates()
        func agent(_ label: String) -> LaunchAgent {
            LaunchAgent(url: URL(fileURLWithPath: "/x/\(label).plist"), label: label, scope: .user,
                        program: nil, programMissing: false, owner: nil, state: .loaded)
        }
        let old = agent("old"), new = agent("new")
        let model = LaunchAgentsModel()
        model.scan = { await gates.enter { $0 == 1 } == 1 ? [old] : [new] }
        let first = Task { await model.load() }
        try await until { gates.calls == 1 }
        await model.load()
        gates.open(1)
        await first.value
        #expect(model.agents == [new] && !model.loading)
    }

    @Test func loginItemsRunOneActionAtATime() async throws {
        let gates = Gates()
        let agent = LaunchAgent(url: URL(fileURLWithPath: "/x/a.plist"), label: "a", scope: .user,
                                program: nil, programMissing: false, owner: nil, state: .loaded)
        let model = LaunchAgentsModel()
        model.scan = { [agent] }
        model.run = { _, _ in _ = await gates.enter(); return .done } // never the real launchctl
        let disabling = Task { await model.disable(agent) }
        try await until { gates.calls == 1 }
        await model.remove(agent) // overlaps the running Disable: refused
        #expect(gates.calls == 1 && model.working)
        gates.open(1)
        await disabling.value
        #expect(!model.working && model.problem == nil)
    }

    @Test func previousAppLoadNeverEndsTheCurrentOne() async throws {
        let gates = Gates()
        func app(_ name: String) -> InstalledApp {
            InstalledApp(url: URL(fileURLWithPath: "/nonexistent/\(name).app"), name: name, bundleID: "com.test.\(name)",
                         version: nil, lastUsed: nil)
        }
        let a = app("A"), b = app("B")
        let model = UninstallerModel()
        model.apps = [a, b]
        model.appData = { app, _, _ in
            _ = await gates.enter()
            return [AppDataEntry(url: app.url.appending(path: "data"), size: 1)]
        }
        model.selection = .app(a.url)
        let first = Task { await model.loadEntries() }
        try await until { gates.calls == 1 }
        first.cancel() // the view's .task(id: selection) restarts on a new selection
        model.selection = .app(b.url)
        let second = Task { await model.loadEntries() }
        try await until { gates.calls == 2 }
        gates.open(1)
        await first.value
        #expect(model.loadingEntries && model.entries.isEmpty) // still loading B: Remove stays disabled
        gates.open(2)
        await second.value
        #expect(!model.loadingEntries && model.entries.map(\.url) == [b.url.appending(path: "data")])
    }

    @Test func leavingWhileAppSizesLoadKeepsNoZeroAndReloadMeasures() async throws {
        let gates = Gates()
        let a = InstalledApp(url: URL(fileURLWithPath: "/nonexistent/A.app"), name: "A", bundleID: "com.test.A",
                             version: nil, lastUsed: nil)
        let model = UninstallerModel()
        model.installedApps = { [a] }
        // Like Scanner.entry: a cancelled walk ends with 0.
        model.appSize = { _ in _ = await gates.enter { $0 == 1 }; return Task.isCancelled ? 0 : 42 }
        let first = Task { await model.loadApps() }
        try await until { gates.calls == 1 }
        first.cancel() // leaving the module cancels the view's .task
        gates.open(1)
        await first.value
        #expect(model.appSizes[a.url] == nil)
        await model.loadApps() // coming back / Refresh
        #expect(model.appSizes[a.url] == 42)
    }

    @Test func selectingAnotherAppWhileRemovingKeepsIt() async throws {
        let gates = Gates()
        func app(_ name: String) -> InstalledApp {
            InstalledApp(url: URL(fileURLWithPath: "/nonexistent/\(name).app"), name: name, bundleID: "com.test.\(name)",
                         version: nil, lastUsed: nil)
        }
        let a = app("A"), b = app("B")
        let model = UninstallerModel()
        model.apps = [a, b]
        model.appData = { app, _, _ in [AppDataEntry(url: app.url.appending(path: "data"), size: 1)] }
        model.trash = { _, _ in _ = await gates.enter(); return CleanReport() }
        model.selection = .app(a.url)
        await model.loadEntries()
        let removal = Task { await model.remove() }
        try await until { gates.calls == 1 }
        model.selection = .app(b.url) // what the view's .task(id: selection) does on a new selection
        await model.loadEntries()
        gates.open(1)
        await removal.value
        #expect(model.selection == .app(b.url) && model.apps.map(\.url) == [b.url])
        #expect(model.entries.map(\.url) == [b.url.appending(path: "data")] && model.checked == [b.url.appending(path: "data")])
    }

    @Test func spaceLensTrashesOnceWhenAskedTwice() async throws {
        let gates = Gates()
        let folder = FileManager.default.temporaryDirectory.appending(path: "CleanMateRace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = SpaceLensModel()
        model.hasFullDiskAccess = { true }
        model.trashItems = { _ in _ = await gates.enter(); return CleanReport(freed: 7) }
        model.start(at: folder) // empty folder: the reload after trashing measures nothing real
        try await until { !model.measuring } // trash does nothing while measuring
        let item = SpaceItem(url: folder.appending(path: "x"), isFolder: false, size: 7)
        let first = Task { await model.trash([item]) }
        try await until { gates.calls == 1 }
        #expect(model.trashing)
        await model.trash([item]) // context menu clicked again while trashing: returns at once
        gates.open(1)
        await first.value
        #expect(gates.calls == 1 && !model.trashing && model.report?.freed == 7)
    }

    func tempFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "CleanMateRace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func spaceLensTrashReportStaysWithItsFolder() async throws {
        let gates = Gates()
        let a = try tempFolder(), b = try tempFolder()
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let model = SpaceLensModel()
        model.hasFullDiskAccess = { true }
        model.trashItems = { _ in _ = await gates.enter(); return CleanReport(freed: 7) }
        model.start(at: a)
        try await until { !model.measuring }
        let trashing = Task { await model.trash([SpaceItem(url: a.appending(path: "x"), isFolder: false, size: 7)]) }
        try await until { gates.calls == 1 }
        model.start(at: b) // "Choose Folder…" while trashing
        gates.open(1)
        await trashing.value
        #expect(model.current == b && model.report == nil)
    }

    @Test func spaceLensRevealOfAnUnlistedItemSelectsNothingLater() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = SpaceLensModel()
        model.hasFullDiskAccess = { true }
        model.reveal(folder.appending(path: "gone.mov"))
        try await until { !model.measuring }
        #expect(model.current.standardizedFileURL.path == folder.standardizedFileURL.path)
        #expect(model.revealed == nil)
    }

    /// The duplicate search running when the file list moves files to the Trash is stopped: its groups would bring
    /// them back. Files Duplicate Files moves leave the file list.
    @Test func largeFilesTrashStopsFindingDuplicates() async throws {
        let gates = Gates()
        let a = LargeFile(url: URL(fileURLWithPath: "/nonexistent/a"), size: 1, lastUsed: .now, kind: .other)
        let b = LargeFile(url: URL(fileURLWithPath: "/nonexistent/b"), size: 1, lastUsed: .now, kind: .other)
        let c = LargeFile(url: URL(fileURLWithPath: "/nonexistent/c"), size: 1, lastUsed: .now, kind: .other)
        let model = LargeFilesModel()
        model.hasFullDiskAccess = { true }
        model.duplicates.findDuplicates = { _, _, _, _, _, _ in
            _ = await gates.enter()
            return DuplicateScanner.Result(groups: [DuplicateScanner.Group(files: [a, b, c], privateSizes: [:])])
        }
        model.trashFiles = { _ in CleanReport(freed: 1, trashed: [TrashedItem(original: a.url, inTrash: a.url, size: 1)]) }
        model.files = [a, b, c]
        model.checked = [a.url]
        model.phase = .results
        model.duplicatesShown = true
        try await until { gates.calls == 1 }
        await model.trash()
        #expect(model.files.map(\.url) == [b.url, c.url])
        gates.open(1)
        try await until { gates.left == 1 }
        await Task.yield()
        guard case .idle = model.duplicates.phase else { Issue.record("not stopped"); return }
        #expect(model.duplicates.groups.isEmpty) // a's group never back

        model.duplicates.trashFiles = { _, _ in CleanReport(freed: 1, trashed: [TrashedItem(original: b.url, inTrash: b.url, size: 1)]) }
        model.duplicates.findAgain()
        gates.open(2)
        try await until { if case .results = model.duplicates.phase { true } else { false } }
        model.duplicates.checked = [b.url]
        await model.duplicates.trash()
        #expect(model.files.map(\.url) == [c.url])
    }

    @Test func largeFilesNoScanWhileUndoing() async throws {
        let gates = Gates()
        let model = largeFiles(Gates()) { _ in false }
        model.restore = { items in _ = await gates.enter(); return TrashUndo.Result(restored: items.count, skipped: 0) }
        let item = TrashedItem(original: URL(fileURLWithPath: "/nonexistent/x"), inTrash: URL(fileURLWithPath: "/nonexistent/y"), size: 1)
        model.phase = .results
        model.lastTrash = CleanReport(freed: 1, trashed: [item])
        let undo = Task { await model.undoTrash() }
        try await until { gates.calls == 1 }
        model.scan() // "Scan Again" / ⌘R while putting files back: ignored
        guard case .results = model.phase else { Issue.record("phase \(model.phase)"); gates.open(1); return }
        gates.open(1)
        await undo.value
        #expect(!model.undoing && model.lastTrash?.undo == TrashUndo.Result(restored: 1, skipped: 0))
    }

    /// Smart Scan's Undo: Scan Again / ⌘R while files come back is ignored, and quitting asks first.
    @Test func smartScanNoScanWhileUndoing() async throws {
        let gates = Gates()
        let junk = CleanerItem(id: "race.junk", title: "Junk", paths: ["~/nonexistent"])
        let model = SmartScanModel.isolated(module: .smartScan) { [CleanerGroup(id: "g", title: "G", systemImage: "x", items: [junk])] }
        model.scanItem = { _, _ in ItemScan() }
        model.blockedByExclusion = { _ in false }
        model.processNames = { [] }
        model.restore = { items, _ in _ = await gates.enter(); return TrashUndo.Result(restored: items.count, skipped: 0) }
        let item = TrashedItem(original: URL(fileURLWithPath: "/nonexistent/x"), inTrash: URL(fileURLWithPath: "/nonexistent/y"), size: 1)
        model.phase = .done(CleanReport(freed: 1, trashed: [item]))
        let undo = Task { await model.undoTrash() }
        try await until { gates.calls == 1 }
        #expect(AppModels.isChanging(model, nil, nil, nil, nil, nil))
        await model.scan()
        guard case .done = model.phase else { Issue.record("phase \(model.phase)"); gates.open(1); return }
        gates.open(1)
        await undo.value
        guard case .done(let report) = model.phase else { Issue.record("phase \(model.phase)"); return }
        #expect(!model.undoing && report.undo == TrashUndo.Result(restored: 1, skipped: 0) && report.trashed.isEmpty)
        #expect(!AppModels.isChanging(model, nil, nil, nil, nil, nil))
    }

    /// Quit asks first while something is being changed: a clean, a move/put back, a launchctl change.
    @Test func quitAsksWhileChanging() async throws {
        let smartScan = SmartScanModel.isolated(module: .smartScan), privacy = SmartScanModel.isolated(module: .privacy)
        let largeFiles = largeFiles(Gates()) { _ in false }
        let uninstaller = UninstallerModel(), spaceLens = SpaceLensModel(), loginItems = LaunchAgentsModel()
        func changing() -> Bool { AppModels.isChanging(smartScan, privacy, largeFiles, uninstaller, spaceLens, loginItems) }
        #expect(!changing())
        smartScan.phase = .scanning
        #expect(!changing()) // a scan only reads: quitting loses nothing
        privacy.phase = .cleaning
        #expect(changing())
        privacy.phase = .idle
        uninstaller.working = true
        #expect(changing())
        uninstaller.working = false
        let gates = Gates()
        loginItems.scan = { [] }
        loginItems.run = { _, _ in _ = await gates.enter(); return .done }
        let agent = LaunchAgent(url: URL(fileURLWithPath: "/nonexistent/com.example.a.plist"), label: "com.example.a",
                                scope: .user, program: nil, programMissing: false, owner: nil, state: .loaded)
        let remove = Task { await loginItems.remove(agent) }
        try await until { gates.calls == 1 }
        #expect(changing())
        gates.open(1)
        await remove.value
        #expect(!changing())
    }

    /// The app owns the models: a window built again gets the same ones, so a clean still running after the window
    /// closed keeps Quit asking until it ends, and a Maintenance task counts too.
    @Test func busyFollowsAppModelsNotWindow() {
        let privacy = SmartScanModel.isolated(module: .privacy)
        let models = AppModels(smartScan: SmartScanModel.isolated(module: .smartScan), privacy: privacy,
                               largeFiles: largeFiles(Gates()) { _ in false })
        #expect(ContentView(models: models).models === models)
        privacy.phase = .cleaning
        #expect(models.isChanging && models.isBusy)
        privacy.phase = .idle
        #expect(!models.isBusy)
        #expect(ContentView().models === AppModels.shared && AppModels.shared === AppModels.shared)
    }

    /// Closing the window (⌘W, menu bar only) drops ContentView, not the models: a scan under way keeps going and the
    /// window built again shows the same model with its results.
    @Test func closingTheWindowKeepsAScanGoingAndItsResults() async throws {
        let gates = Gates()
        let smartScan = smartScan(gates) { $0 == 1 }
        let models = AppModels(smartScan: smartScan, privacy: SmartScanModel.isolated(module: .privacy),
                               largeFiles: largeFiles(Gates()) { _ in false })
        do { // the window, closed mid-scan: the view is gone, its models are not
            let window = ContentView(models: models)
            smartScan.startScan()
            try await until { gates.calls == 1 }
            #expect(window.models.smartScan === smartScan)
        }
        guard case .scanning = smartScan.phase else { Issue.record("phase \(smartScan.phase)"); gates.open(1); return }
        gates.open(1)
        try await until { if case .results = smartScan.phase { true } else { false } }
        let reopened = ContentView(models: models)
        #expect(reopened.models.smartScan === smartScan && smartScan.scans["x"]?.size == 100 && smartScan.selected == ["x"])
    }

    /// Stop while cleaning: the item under way finishes, the items after it are never handed to the cleaner, and the
    /// done screen's report says how many were left.
    @Test func stopWhileCleaningLeavesTheRestUntouched() async throws {
        let gates = Gates()
        let items = (1...4).map { CleanerItem(id: "stop.\($0)", title: "Item \($0)", paths: []) }
        let model = SmartScanModel.isolated(module: .smartScan) { [CleanerGroup(id: "g", title: "G", systemImage: "x", items: items)] }
        model.processNames = { [] }
        model.appBundleIDs = { [] }
        model.freeSpace = { nil }
        model.logHome = URL(fileURLWithPath: "/nonexistent/stop-clean")
        let cleaned = Locked<[String]>([])
        model.cleanItem = { item, _, _ in
            _ = await gates.enter { $0 == 2 } // the second item takes long
            cleaned.withLock { $0.append(item.id) }
            return CleanReport(freed: 10)
        }
        model.scans = Dictionary(uniqueKeysWithValues: items.map { ($0.id, ItemScan(measuredSize: 10)) })
        model.selected = Set(items.map(\.id))
        model.phase = .results
        let clean = Task { await model.clean() }
        try await until { gates.calls == 2 }
        model.stopClean()
        #expect(model.stoppingClean)
        gates.open(2)
        await clean.value
        guard case .done(let report) = model.phase else { Issue.record("phase \(model.phase)"); return }
        #expect(cleaned.withLock { $0 } == ["stop.1", "stop.2"])
        #expect(report.stopped == 2 && report.freed == 20 && report.notCleaned == 0 && !model.stoppingClean)
        model.stopClean() // not cleaning: nothing to stop
        #expect(!model.stoppingClean)
    }

    /// The quit-while-busy alert: Cancel answers Return (Esc is caught while it runs), Quit Anyway has no key.
    @Test func quitAlertKeys() {
        let buttons = AppDelegate.quitAlert().buttons
        #expect(buttons.map(\.title) == [String(localized: "Cancel"), String(localized: "Quit Anyway")])
        #expect(buttons.map(\.keyEquivalent) == ["\r", ""])
    }

    /// The menu bar's freed line reads the log once until a removal is recorded or an hour passes.
    @Test func freedCacheRefreshesOnRecord() {
        let center = NotificationCenter()
        var reads = 0
        let cache = FreedCache(center: center) { reads += 1; return Int64(reads) }
        let now = Date.now
        #expect(cache.bytes(now: now) == 1 && cache.bytes(now: now) == 1)
        center.post(name: ActivityLog.didRecord, object: "Smart Scan")
        #expect(cache.bytes(now: now) == 2)
        #expect(cache.bytes(now: now.addingTimeInterval(3601)) == 3)
    }
}

/// A scan finished in the background bounces the Dock once; not when active, not when cancelled.
@MainActor
struct AttentionTests {
    @MainActor final class Bounces { var count = 0 }

    func scan(active: Bool, cancel: Bool) async throws -> Int {
        let bounces = Bounces()
        let gates = RaceTests.Gates()
        let race = RaceTests()
        try await Attention.$isActive.withValue({ active }) {
            try await Attention.$bounce.withValue({ bounces.count += 1 }) {
                let model = race.smartScan(gates) { _ in true }
                model.startScan()
                try await race.until { gates.calls == 1 }
                if cancel { model.cancelScan() }
                gates.open(1)
                try await race.until { if case .scanning = model.phase { false } else { true } }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        return bounces.count
    }

    @Test func bouncesOnlyWhenFinishedInTheBackground() async throws {
        #expect(try await scan(active: false, cancel: false) == 1)
        #expect(try await scan(active: true, cancel: false) == 0)
        #expect(try await scan(active: false, cancel: true) == 0)
    }
}
