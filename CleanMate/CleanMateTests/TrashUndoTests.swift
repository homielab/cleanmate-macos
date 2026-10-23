import Foundation
import Testing
@testable import CleanMate

/// "Undo" of the last move to the Trash. A fake Trash folder inside a throwaway folder: the real Trash is never touched.
struct TrashUndoTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "CleanMateUndo-\(UUID().uuidString)")
    var trash: URL { root.appending(path: "FakeTrash") }
    let fm = FileManager.default

    /// Moves into the fake Trash like `trashItem`, returning the new place.
    func fakeTrash(_ url: URL) throws -> URL? {
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let target = trash.appending(path: UUID().uuidString + "-" + url.lastPathComponent)
        try fm.moveItem(at: url, to: target)
        return target
    }

    func file(_ path: String, _ text: String = "data") throws -> URL {
        let url = root.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    func trashed(_ urls: [URL]) -> CleanReport {
        CleanReport.trashing(urls.map { ($0, 10) }, module: "Large & Old Files", home: root, allows: { _ in true },
                             trash: fakeTrash)
    }

    /// Unlocks everything under `root` so the throwaway folder can be removed.
    func unlockAll() {
        for case let url as URL in fm.enumerator(at: root, includingPropertiesForKeys: nil) ?? .init() { chflags(url.path, 0) }
    }

    /// Finder-locked items: the locked file or folder itself is not moved and is counted as `locked`, apart
    /// from `skipped`; a folder that only contains a locked file still moves. Throwaway folder and fake Trash only.
    @Test func lockedItemsAreCountedNotMoved() throws {
        defer { unlockAll(); try? fm.removeItem(at: root) }
        let file = try file("Movies/locked.mov")
        let folder = root.appending(path: "Projects/locked")
        let inner = try self.file("Projects/locked/inner.txt")
        let parent = root.appending(path: "Projects/holder")
        let held = try self.file("Projects/holder/locked.txt")
        for url in [file, folder, held] { #expect(chflags(url.path, UInt32(UF_IMMUTABLE)) == 0) }
        let report = trashed([file, folder, parent])
        #expect(report.locked == 2 && report.skipped == 0 && report.freed == 10)
        #expect(report.trashed.map(\.original) == [parent])
        #expect(fm.fileExists(atPath: file.path) && fm.fileExists(atPath: inner.path) && !fm.fileExists(atPath: parent.path))
    }

    @Test func undoPutsItemsBackAndLogsThem() async throws {
        defer { try? fm.removeItem(at: root) }
        let a = try file("Movies/a.mov", "A")
        let folder = root.appending(path: "Projects/old")
        _ = try file("Projects/old/inner.txt")
        let report = trashed([a, folder])
        #expect(report.trashed.count == 2 && report.freed == 20)
        #expect(!fm.fileExists(atPath: a.path) && !fm.fileExists(atPath: folder.path))
        #expect(ActivityLog.freed(home: root).trashed == 20)

        let result = await TrashUndo.restore(report.trashed, module: "Large & Old Files", home: root)
        #expect(result == TrashUndo.Result(restored: 2, skipped: 0))
        #expect(try String(contentsOf: a, encoding: .utf8) == "A")
        #expect(fm.fileExists(atPath: folder.appending(path: "inner.txt").path))
        #expect(try fm.contentsOfDirectory(atPath: trash.path).isEmpty)
        // Put back = not freed any more.
        #expect(ActivityLog.freed(home: root).trashed == 0)
    }

    /// The old folder swapped for a symlink since the move: "Undo" would write elsewhere, so it skips.
    @Test func undoSkipsFolderNowASymlink() async throws {
        defer { try? fm.removeItem(at: root) }
        let a = try file("Movies/a.mov", "A")
        let report = trashed([a])
        let elsewhere = root.appending(path: "Elsewhere")
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try fm.removeItem(at: a.deletingLastPathComponent())
        try fm.createSymbolicLink(at: a.deletingLastPathComponent(), withDestinationURL: elsewhere)
        let result = await TrashUndo.restore(report.trashed, module: "Large & Old Files", home: root)
        #expect(result == TrashUndo.Result(restored: 0, skipped: 1))
        #expect(try fm.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }

    @Test func undoNeverOverwrites() async throws {
        defer { try? fm.removeItem(at: root) }
        let a = try file("Movies/a.mov", "old")
        let report = trashed([a])
        _ = try file("Movies/a.mov", "new")
        let result = await TrashUndo.restore(report.trashed, module: "Large & Old Files", home: root)
        #expect(result == TrashUndo.Result(restored: 0, skipped: 1))
        #expect(try String(contentsOf: a, encoding: .utf8) == "new")
        #expect(try String(contentsOf: report.trashed[0].inTrash, encoding: .utf8) == "old")
    }

    @Test func undoSkipsItemsGoneFromTheTrashOrWithoutTheirFolder() async throws {
        defer { try? fm.removeItem(at: root) }
        let a = try file("Movies/a.mov")
        let b = try file("Gone/b.mov")
        let c = try file("Movies/c.mov")
        let report = trashed([a, b, c])
        try fm.removeItem(at: report.trashed[0].inTrash) // emptied from the Trash
        try fm.removeItem(at: root.appending(path: "Gone")) // old folder removed
        let result = await TrashUndo.restore(report.trashed, module: "Large & Old Files", home: root)
        #expect(result == TrashUndo.Result(restored: 1, skipped: 2))
        #expect(!fm.fileExists(atPath: a.path) && !fm.fileExists(atPath: b.path) && fm.fileExists(atPath: c.path))
        #expect(fm.fileExists(atPath: report.trashed[1].inTrash.path)) // left in the Trash
    }

    /// A drive mounted on the old folder (or above it) since the move: the path is the same but leads onto
    /// another volume, so "Undo" skips.
    @Test func undoSkipsFolderNowOnAnotherVolume() async throws {
        defer { try? fm.removeItem(at: root) }
        let a = try file("Movies/a.mov", "A")
        let report = trashed([a])
        let result = await TrashUndo.restore(report.trashed, module: "Large & Old Files", home: root,
                                             device: { _ in 12345 })
        #expect(result == TrashUndo.Result(restored: 0, skipped: 1))
        #expect(!fm.fileExists(atPath: a.path) && fm.fileExists(atPath: report.trashed[0].inTrash.path))
    }

    @MainActor @Test func largeFilesUndoRunsOnce() async {
        let model = LargeFilesModel()
        var calls = 0
        model.restore = { items in calls += 1; return TrashUndo.Result(restored: items.count, skipped: 0) }
        let item = TrashedItem(original: URL(fileURLWithPath: "/tmp/x"), inTrash: URL(fileURLWithPath: "/tmp/y"), size: 1)
        model.phase = .done(CleanReport(freed: 1, trashed: [item]))
        await model.undoTrash()
        await model.undoTrash()
        guard case .done(let report) = model.phase else { Issue.record("phase \(model.phase)"); return }
        #expect(calls == 1 && report.trashed.isEmpty && report.undo == TrashUndo.Result(restored: 1, skipped: 0))
    }

    // ⌘Z / Edit › Undo: a throwaway UndoManager and fake Trash hooks; nothing real is moved.
    static let item = TrashedItem(original: URL(fileURLWithPath: "/nonexistent/x"), inTrash: URL(fileURLWithPath: "/nonexistent/y"), size: 1)

    /// A window's UndoManager opens a group for an event once something registers; the test opens one around
    /// the calls that register (removal-only calls stay outside, as an empty group would still count as an undo).
    @MainActor func manager() -> UndoManager {
        let undo = UndoManager()
        undo.groupsByEvent = false
        return undo
    }

    @MainActor func event(_ undo: UndoManager, _ body: () async -> Void) async {
        undo.beginUndoGrouping()
        await body()
        undo.endUndoGrouping()
    }

    /// Waits for the Task the undo handler starts.
    @MainActor func settle(_ done: () -> Bool) async {
        for _ in 0..<5000 where !done() { try? await Task.sleep(for: .milliseconds(2)) } // ≥ 10 s: busy machines
    }

    @MainActor @Test func largeFilesRegistersUndoAndCmdZRestores() async {
        let model = LargeFilesModel(), undo = manager()
        model.undoManager = undo
        var calls = 0
        model.restore = { items in calls += 1; return TrashUndo.Result(restored: items.count, skipped: 0) }
        model.trashFiles = { _ in CleanReport(freed: 1, trashed: [Self.item]) }
        model.scanFiles = { _, _, _, _ in [] }
        model.phase = .results
        await event(undo) { await model.trash() }
        #expect(undo.canUndo && undo.undoActionName == String(localized: "Move to Trash"))
        undo.undo() // ⌘Z
        await settle { calls == 1 }
        guard case .done(let report) = model.phase else { Issue.record("phase \(model.phase)"); return }
        #expect(calls == 1 && report.undo != nil && !undo.canUndo && !undo.canRedo) // button gone, no redo
        // The button instead: ⌘Z is gone too.
        model.phase = .results
        await event(undo) { await model.trash() }
        await model.undoTrash()
        #expect(calls == 2 && !undo.canUndo)
        // A new scan drops it.
        model.phase = .results
        await event(undo) { await model.trash() }
        #expect(undo.canUndo)
        model.scan()
        #expect(!undo.canUndo && calls == 2)
        model.cancel()
    }

    @MainActor @Test func spaceLensUndoClearedWithReport() async {
        let model = SpaceLensModel(), undo = manager()
        model.undoManager = undo
        model.hasFullDiskAccess = { true }
        model.measure = { _, _, _ in (0, [:]) }
        var calls = 0
        model.restore = { items in calls += 1; return TrashUndo.Result(restored: items.count, skipped: 0) }
        model.trashItems = { _ in CleanReport(freed: 1, trashed: [Self.item]) }
        let thing = SpaceItem(url: URL(fileURLWithPath: "/nonexistent/x"), isFolder: false, size: 1)
        await event(undo) { await model.trash([thing]) }
        #expect(undo.canUndo && undo.undoActionName == String(localized: "Move to Trash"))
        undo.undo()
        await settle { calls == 1 && !model.trashing && !model.measuring } // trash does nothing while measuring
        #expect(calls == 1 && model.report?.undo != nil && !undo.canUndo)
        await event(undo) { await model.trash([thing]) }
        #expect(undo.canUndo)
        model.open(URL(fileURLWithPath: "/nonexistent/folder")) // another folder: report and ⌘Z go
        #expect(model.report == nil && !undo.canUndo)
        model.cancel()
    }

    /// Leaving the folder while items go to the Trash drops the report but not ⌘Z: they are in the Trash.
    @MainActor @Test func spaceLensUndoAfterLeavingTheFolder() async {
        let model = SpaceLensModel(), undo = manager()
        model.undoManager = undo
        model.hasFullDiskAccess = { true }
        model.measure = { _, _, _ in (0, [:]) }
        var restored: [TrashedItem] = []
        model.restore = { items in restored += items; return TrashUndo.Result(restored: items.count, skipped: 0) }
        model.trashItems = { _ in
            model.open(URL(fileURLWithPath: "/nonexistent/folder")) // the user moves on meanwhile
            return CleanReport(freed: 1, trashed: [Self.item])
        }
        let thing = SpaceItem(url: URL(fileURLWithPath: "/nonexistent/x"), isFolder: false, size: 1)
        await event(undo) { await model.trash([thing]) }
        #expect(model.report == nil && undo.canUndo && undo.undoActionName == String(localized: "Move to Trash"))
        undo.undo()
        await settle { !restored.isEmpty && !model.trashing }
        #expect(restored == [Self.item] && model.report == nil && !undo.canUndo)
        model.cancel()
    }

    /// "Never Clean This" in Space Lens goes through an injectable closure, like Smart Scan and Large Files.
    @MainActor @Test func spaceLensNeverCleanUsesInjectedExclude() {
        let model = SpaceLensModel()
        var saved: [URL] = []
        model.exclude = { saved += $0; return $0 }
        let url = URL(fileURLWithPath: "/nonexistent/keep")
        #expect(model.neverClean([url]) && saved == [url])
        model.exclude = { _ in [] } // e.g. already excluded
        #expect(!model.neverClean([url]))
        model.cancel()
    }

    @MainActor @Test func uninstallerNamesUndoUninstallOrReset() async {
        let app = InstalledApp(url: URL(filePath: "/nonexistent/Undoable.app"), name: "Undoable",
                               bundleID: "com.test.qqx.undoable", version: nil, lastUsed: nil)
        let model = UninstallerModel(), undo = manager()
        model.undoManager = undo
        model.installedApps = { [app] }
        model.appSize = { _ in 0 }
        model.appData = { _, _, _ in [AppDataEntry(url: URL(filePath: "/nonexistent/Library/Caches/qqx"), size: 3)] }
        model.trash = { _, _ in CleanReport(freed: 3, trashed: [Self.item]) }
        var calls = 0
        model.restore = { items in calls += 1; return TrashUndo.Result(restored: items.count, skipped: 0) }
        model.apps = [app]
        model.selection = .app(app.url)
        await model.loadEntries()
        model.trashApp = false
        await event(undo) { await model.remove() }
        #expect(undo.undoActionName == String(localized: "Reset"))
        guard case .removed(let report) = model.outcome else { Issue.record("outcome"); return }
        await model.undo(report) // the alert's button
        #expect(calls == 1 && !undo.canUndo)
        model.trashApp = true
        await event(undo) { await model.remove() }
        #expect(undo.undoActionName == String(localized: "Uninstall"))
        undo.undo()
        await settle { if case .restored = model.outcome { true } else { false } }
        #expect(calls == 2 && !undo.canUndo)
    }
}
