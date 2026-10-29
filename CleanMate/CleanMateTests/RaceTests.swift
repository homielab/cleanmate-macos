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
            while gated(call) && !state.withLock({ $0.open.contains(call) }) {
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
        let model = SmartScanModel(module: .smartScan) { [CleanerGroup(id: "g", title: "G", systemImage: "x", items: [item])] }
        model.processNames = { [] }
        model.scanItem = { _ in ItemScan(measuredSize: Int64(await gates.enter(gated: gated)) * 100) }
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
        model.run = { _, _ in _ = await gates.enter(); return true } // never the real launchctl
        let disabling = Task { await model.disable(agent) }
        try await until { gates.calls == 1 }
        await model.remove(agent) // overlaps the running Disable: refused
        #expect(gates.calls == 1 && model.working)
        gates.open(1)
        await disabling.value
        #expect(!model.working && model.failed == nil)
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

    @Test func largeFilesTrashStopsFindingDuplicates() async throws {
        let gates = Gates()
        let a = LargeFile(url: URL(fileURLWithPath: "/nonexistent/a"), size: 1, lastUsed: .now, kind: .other)
        let b = LargeFile(url: URL(fileURLWithPath: "/nonexistent/b"), size: 1, lastUsed: .now, kind: .other)
        let model = LargeFilesModel()
        model.findDuplicateFiles = { _, _, _ in _ = await gates.enter(); return DuplicateFinder.Result(groups: [[a.url, b.url]]) }
        model.trashFiles = { _ in CleanReport(freed: 1) }
        model.files = [a, b]
        model.checked = [a.url]
        model.phase = .results
        model.duplicatesOnly = true
        try await until { gates.calls == 1 }
        await model.trash()
        gates.open(1)
        try await until { gates.left == 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.duplicateGroups == nil && model.duplicateProgress == nil)
    }

    @Test func largeFilesNoScanWhileUndoing() async throws {
        let gates = Gates()
        let model = largeFiles(Gates()) { _ in false }
        model.restore = { items in _ = await gates.enter(); return TrashUndo.Result(restored: items.count, skipped: 0) }
        let item = TrashedItem(original: URL(fileURLWithPath: "/nonexistent/x"), inTrash: URL(fileURLWithPath: "/nonexistent/y"), size: 1)
        model.phase = .done(CleanReport(freed: 1, trashed: [item]))
        let undo = Task { await model.undoTrash() }
        try await until { gates.calls == 1 }
        model.scan() // "Scan Again" / ⌘R while putting files back: ignored
        guard case .done = model.phase else { Issue.record("phase \(model.phase)"); gates.open(1); return }
        gates.open(1)
        await undo.value
        guard case .done(let report) = model.phase else { Issue.record("phase \(model.phase)"); return }
        #expect(!model.undoing && report.undo == TrashUndo.Result(restored: 1, skipped: 0))
    }

    /// Quit asks first while something is being changed: a clean, a move/put back, a launchctl change.
    @Test func quitAsksWhileChanging() async throws {
        let smartScan = SmartScanModel(module: .smartScan), privacy = SmartScanModel(module: .privacy)
        let largeFiles = largeFiles(Gates()) { _ in false }
        let uninstaller = UninstallerModel(), spaceLens = SpaceLensModel(), loginItems = LaunchAgentsModel()
        func changing() -> Bool { ContentView.isChanging(smartScan, privacy, largeFiles, uninstaller, spaceLens, loginItems) }
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
        loginItems.run = { _, _ in _ = await gates.enter(); return true }
        let agent = LaunchAgent(url: URL(fileURLWithPath: "/nonexistent/com.example.a.plist"), label: "com.example.a",
                                scope: .user, program: nil, programMissing: false, owner: nil, state: .loaded)
        let remove = Task { await loginItems.remove(agent) }
        try await until { gates.calls == 1 }
        #expect(changing())
        gates.open(1)
        await remove.value
        #expect(!changing())
    }

    /// Quit reads the models, not a flag the window mirrored: a model still cleaning after its window
    /// closed counts until it finishes; models gone with the window never do.
    @Test func busyFollowsModelsNotWindow() {
        var smartScan: SmartScanModel? = SmartScanModel(module: .smartScan)
        let privacy = SmartScanModel(module: .privacy)
        let busy = ContentView.busyCheck(smartScan!, privacy, largeFiles(Gates()) { _ in false }, UninstallerModel(),
                                         SpaceLensModel(), LaunchAgentsModel())
        privacy.phase = .cleaning // the window closed; a running clean keeps `privacy` alive
        smartScan = nil
        #expect(busy() == true)
        privacy.phase = .idle
        #expect(busy() == false)
    }

    /// Reopening the window replaces its quit check instead of chaining one more; a set of models that
    /// outlived its window (still cleaning) keeps asking, and drops out once all of it is gone.
    @Test func busyChecksDoNotPileUp() {
        func models() -> (SmartScanModel, () -> Bool?) {
            let smartScan = SmartScanModel(module: .smartScan)
            return (smartScan, ContentView.busyCheck(smartScan, SmartScanModel(module: .privacy), largeFiles(Gates()) { _ in false },
                                                     UninstallerModel(), SpaceLensModel(), LaunchAgentsModel()))
        }
        let (live, check) = models()
        // The first registration also drops checks left by an earlier run of this test (-test-iterations).
        AppDelegate.registerBusyCheck(ObjectIdentifier(live), check)
        let registered = AppDelegate.busyChecks.count
        for _ in 0..<4 { AppDelegate.registerBusyCheck(ObjectIdentifier(live), check) } // the same window appearing again
        #expect(AppDelegate.busyChecks.count == registered)
        live.phase = .cleaning
        #expect(AppDelegate.isBusy)
        live.phase = .idle
        for _ in 0..<5 {
            let (smartScan, check) = models()
            AppDelegate.registerBusyCheck(ObjectIdentifier(smartScan), check)
        } // a closed window's models, freed right after; the next registration drops them
        #expect(AppDelegate.busyChecks.count <= registered + 1)
        #expect(!AppDelegate.isBusy)
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
