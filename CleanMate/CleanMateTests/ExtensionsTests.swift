import Foundation
import Testing
@testable import CleanMate

/// Extensions in ~/Library against a throwaway Library; read-only, nothing is ever removed.
struct ExtensionsTests {
    let library = FileManager.default.temporaryDirectory.appending(path: "CleanMateExtensions-\(UUID().uuidString)/Library")

    /// A bundle folder, with `Contents/Info.plist` holding `id` when given.
    func bundle(_ path: String, id: String? = nil) throws {
        let url = library.appending(path: path)
        try FileManager.default.createDirectory(at: url.appending(path: "Contents"), withIntermediateDirectories: true)
        if let id {
            let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
            try data.write(to: url.appending(path: "Contents/Info.plist"))
        }
    }

    @Test func listsKindsAndOwners() throws {
        defer { try? FileManager.default.removeItem(at: library.deletingLastPathComponent()) }
        try bundle("PreferencePanes/Gone.prefPane", id: "fr.goneco.gone.prefpane")
        try bundle("QuickLook/Markdown.qlgenerator", id: "com.vendor.markdown.ql")       // same vendor as an installed app
        try bundle("Services/Resize Images.workflow")                                   // no bundle id
        try bundle("Screen Savers/Exact.saver", id: "com.exact.saver")                  // exactly an installed app's id
        try bundle("Input Methods/Shared.app", id: "org.sparkle-project.thing")         // shared vendor: never "removed"
        try bundle("Internet Plug-Ins/Plug.plugin", id: "com.apple.plug")               // Apple: never "removed"
        try bundle("Spotlight/Sketch.mdimporter", id: "com.gone2.sketch.importer")
        try bundle("PreferencePanes/SelfContained.prefPane", id: "fr.solo.pane")
        try bundle("PreferencePanes/SelfContained.prefPane/Contents/PlugIns/Solo Control.app", id: "fr.solo.app")  // ships its own app
        try bundle("Spotlight/Assets")                                                  // not an importer
        try bundle("Spotlight/ExtensionsCache")
        try bundle("PreferencePanes/.Hidden.prefPane", id: "com.hidden.pane")

        let apps = ["com.vendor.editor": "Editor", "com.vendor.zeta": "Zeta", "com.exact.saver": "Exact Saver"]
        let items = Extensions.list(library: library, apps: apps)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        #expect(Set(byName.keys) == ["Gone", "Markdown", "Resize Images", "Exact", "Shared", "Plug", "Sketch", "SelfContained"])
        #expect(items.map(\.name) == ["Exact", "Gone", "Markdown", "Plug", "Resize Images", "SelfContained", "Shared", "Sketch"])

        #expect(byName["Gone"]?.kind == .preferencePane)
        #expect(byName["Gone"]?.owner == nil && byName["Gone"]?.appRemoved == true)
        #expect(byName["Markdown"]?.kind == .quickLook && byName["Markdown"]?.owner == "Editor")
        #expect(byName["Markdown"]?.appRemoved == false)
        #expect(byName["Resize Images"]?.kind == .service)
        #expect(byName["Resize Images"]?.bundleID == nil && byName["Resize Images"]?.appRemoved == false)
        #expect(byName["Exact"]?.kind == .screenSaver && byName["Exact"]?.owner == "Exact Saver")
        #expect(byName["Shared"]?.kind == .inputMethod && byName["Shared"]?.appRemoved == false)
        #expect(byName["Plug"]?.kind == .internetPlugin && byName["Plug"]?.appRemoved == false)
        #expect(byName["SelfContained"]?.owner == nil && byName["SelfContained"]?.appRemoved == false)
        #expect(byName["Sketch"]?.kind == .spotlight && byName["Sketch"]?.appRemoved == true)
    }

    /// A symlinked extension is listed but never read through: its target could be a TCC-protected folder.
    @Test func symlinkIsListedNotOpened() throws {
        defer { try? FileManager.default.removeItem(at: library.deletingLastPathComponent()) }
        try bundle("Elsewhere/Linked.qlgenerator", id: "fr.goneco.linked")
        try FileManager.default.createDirectory(at: library.appending(path: "QuickLook"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: library.appending(path: "QuickLook/Linked.qlgenerator"),
                                                   withDestinationURL: library.appending(path: "Elsewhere/Linked.qlgenerator"))
        let items = Extensions.list(library: library, apps: [:])
        #expect(items.map(\.name) == ["Linked"])
        #expect(items.first?.bundleID == nil && items.first?.appRemoved == false)
    }

    @Test func missingLibraryListsNothing() {
        #expect(Extensions.list(library: library, apps: [:]).isEmpty)
    }

    /// `allowsUserExtension`: only a right-named, non-Apple, non-symlink entry directly in one of the 7 folders.
    @Test func policyAllowsOnlyUserExtensions() throws {
        let root = library.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root, outside = root.appending(path: "outside")
        let policy = SafetyPolicy(home: home, temp: root.appending(path: "tmp"),
                                  excluded: [library.appending(path: "Screen Savers/Excluded.saver").path])
        let allowed = ["PreferencePanes/Good.prefPane", "QuickLook/Q.QLGenerator", "Services/S.workflow", "Screen Savers/X.saver",
                       "Input Methods/IM.app", "Input Methods/IM2.bundle", "Internet Plug-Ins/P.plugin",
                       "Internet Plug-Ins/W.webplugin", "Spotlight/I.mdimporter"]
        let refused = ["PreferencePanes/Wrong.app", "Spotlight/Assets", "Services/Thing.app", "Internet Plug-Ins/IM.bundle",
                       "PreferencePanes/.Hidden.prefPane", "PreferencePanes/Apple.prefPane", "Screen Savers/com.apple.x.saver",
                       "PreferencePanes/Good.prefPane/Contents/Nested.prefPane", "Screen Savers/Excluded.saver", "Caches/C.prefPane"]
        for path in allowed + refused { try bundle(path, id: path == "PreferencePanes/Apple.prefPane" ? "com.apple.pane" : "com.x.ext") }
        try FileManager.default.createDirectory(at: outside.appending(path: "Out.prefPane"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: library.appending(path: "PreferencePanes/Link.prefPane"),
                                                   withDestinationURL: outside.appending(path: "Out.prefPane"))
        // A symlinked kind folder: its entries really live elsewhere.
        try FileManager.default.createSymbolicLink(at: library.appending(path: "Spotlight2"), withDestinationURL: outside)
        for path in allowed { #expect(policy.allowsUserExtension(library.appending(path: path)), "\(path)") }
        for path in refused + ["PreferencePanes/Link.prefPane", "PreferencePanes", "Spotlight2/Out.prefPane"] {
            #expect(!policy.allowsUserExtension(library.appending(path: path)), "\(path)")
        }
        #expect(!policy.allowsUserExtension(URL(fileURLWithPath: "/Library/PreferencePanes/Good.prefPane")))
        #expect(!policy.allowsUserExtension(library.appending(path: "Input Methods/../PreferencePanes/../../Library")))
    }

    /// Trashing against a fake Trash, then "Undo" puts it back; a refused item is skipped and stays.
    @Test func trashAndUndo() async throws {
        let root = library.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = SafetyPolicy(home: root, temp: root.appending(path: "tmp"))
        try bundle("PreferencePanes/Gone.prefPane", id: "fr.gone.pane")
        try bundle("PreferencePanes/Apple.prefPane", id: "com.apple.pane")
        let fakeTrash = root.appending(path: "FakeTrash")
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
        let gone = library.appending(path: "PreferencePanes/Gone.prefPane"), apple = library.appending(path: "PreferencePanes/Apple.prefPane")
        let report = await Extensions.trash([AppDataEntry(url: gone, size: 7), AppDataEntry(url: apple, size: 3)], policy: policy, trash: { url in
            let dest = fakeTrash.appending(path: url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        })
        #expect(report.freed == 7 && report.skipped == 1 && report.trashed.map(\.original) == [gone])
        #expect(!FileManager.default.fileExists(atPath: gone.path) && FileManager.default.fileExists(atPath: apple.path))
        #expect(ActivityLog.read(home: root).contains("Gone.prefPane"))
        let result = await TrashUndo.restore(report.trashed, module: "Uninstaller", home: root)
        #expect(result.restored == 1 && FileManager.default.fileExists(atPath: gone.path))
    }

    /// Nothing is ticked for the user; only ticked, selectable items reach the trash hook; ⌘Z undoes it.
    @MainActor @Test func modelTrashesTickedExtensionsAndUndoes() async {
        let model = UninstallerModel(), undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        let pane = URL(fileURLWithPath: "/nonexistent/Library/PreferencePanes/X.prefPane")
        let apple = URL(fileURLWithPath: "/nonexistent/Library/PreferencePanes/A.prefPane")
        model.extensions = {
            [ExtensionItem(url: pane, kind: .preferencePane, modified: nil, bundleID: "com.x.pane", owner: nil, appRemoved: true),
             ExtensionItem(url: apple, kind: .preferencePane, modified: nil, bundleID: "com.apple.a", owner: nil, appRemoved: false)]
        }
        model.appSize = { _ in 9 }
        model.installedApps = { [] }
        model.runningApps = [] // System Settings open on this Mac would untick the pane
        model.appBundleIDs = { [] }
        var sent: [AppDataEntry] = []
        model.trashExtensions = { data, _ in sent = data; return CleanReport(freed: 9, trashed: [TrashedItem(original: pane, inTrash: pane, size: 9)]) }
        var restored = 0
        model.restore = { items in restored += items.count; return TrashUndo.Result(restored: items.count, skipped: 0) }
        await model.loadExtensions()
        model.selection = .extensions
        await model.loadEntries()
        #expect(model.checked.isEmpty && model.checkedEntries.isEmpty)
        await model.remove() // nothing ticked: nothing happens
        #expect(sent.isEmpty && model.outcome == nil)
        model.checked = [pane, apple] // Apple's has no checkbox; never sent even if ticked
        #expect(model.checkedEntries == [AppDataEntry(url: pane, size: 9)] && model.checkedSize == 9)
        undo.beginUndoGrouping()
        await model.remove()
        undo.endUndoGrouping()
        #expect(sent == [AppDataEntry(url: pane, size: 9)] && !model.checked.contains(pane))
        guard case .removed(let report) = model.outcome else { Issue.record("outcome"); return }
        #expect(report.freed == 9 && undo.canUndo)
        undo.undo()
        for _ in 0..<5000 where restored == 0 { try? await Task.sleep(for: .milliseconds(2)) } // ≥ 10 s: busy machines
        #expect(restored == 1 && !undo.canUndo)
    }

    /// System Settings open: a pane gets no checkbox and is never sent, other kinds are unaffected; a pane
    /// ticked before it opened is skipped by the check just before the move.
    @MainActor @Test func paneLockedWhileSystemSettingsRuns() async throws {
        let root = library.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = SafetyPolicy(home: root, temp: root.appending(path: "tmp"))
        try bundle("PreferencePanes/P.prefPane", id: "fr.p.pane")
        try bundle("QuickLook/Q.qlgenerator", id: "fr.q.ql")
        let pane = library.appending(path: "PreferencePanes/P.prefPane"), ql = library.appending(path: "QuickLook/Q.qlgenerator")
        let model = UninstallerModel()
        nonisolated(unsafe) var running: Set<String> = [UninstallerModel.systemSettingsID]
        model.appBundleIDs = { running }
        model.runningApps = running
        model.extensions = {
            [ExtensionItem(url: pane, kind: .preferencePane, modified: nil, bundleID: "fr.p.pane", owner: nil, appRemoved: true),
             ExtensionItem(url: ql, kind: .quickLook, modified: nil, bundleID: "fr.q.ql", owner: nil, appRemoved: true)]
        }
        model.appSize = { _ in 1 }
        model.installedApps = { [] }
        var sent: [AppDataEntry] = [], opensDuringMove = false
        model.trashExtensions = { data, inUse in
            sent = data
            if opensDuringMove { running = [UninstallerModel.systemSettingsID] }
            return await Extensions.trash(data, policy: policy, inUse: inUse) { _ in nil }
        }
        await model.loadExtensions()
        model.selection = .extensions
        let items = try #require(model.extensionItems)
        #expect(model.isInUse(items[0]) && !model.isInUse(items[1])) // only the pane
        model.checked = [pane, ql]
        #expect(model.checkedEntries.map(\.url) == [ql])
        await model.remove()
        #expect(sent.map(\.url) == [ql])
        // Ticked while Settings was closed, then it opens just before the move: the pane is skipped.
        running = []
        model.runningApps = []
        model.checked = [pane]
        opensDuringMove = true
        await model.remove()
        guard case .removed(let report) = model.outcome else { Issue.record("outcome"); return }
        #expect(sent.map(\.url) == [pane] && report.skipped == 1 && report.freed == 0)
    }

    /// The check just before the move knows a pane by its kind, like `isInUse`, not by its name extension.
    @MainActor @Test func paneCheckUsesKind() async throws {
        let pane = library.appending(path: "PreferencePanes/P.prefPane"), odd = library.appending(path: "Services/Odd.prefpane")
        let model = UninstallerModel()
        let running = Locked<Set<String>>([])
        model.appBundleIDs = { running.withLock { $0 } }
        model.extensions = {
            [ExtensionItem(url: pane, kind: .preferencePane, modified: nil, bundleID: nil, owner: nil, appRemoved: true),
             ExtensionItem(url: odd, kind: .service, modified: nil, bundleID: nil, owner: nil, appRemoved: true)]
        }
        model.installedApps = { [] }
        nonisolated(unsafe) var inUse: (@Sendable (URL) -> Bool)?
        model.trashExtensions = { _, check in inUse = check; return CleanReport(freed: 0, trashed: []) }
        await model.loadExtensions()
        model.selection = .extensions
        model.checked = [pane]
        await model.remove()
        let check = try #require(inUse)
        running.withLock { $0 = [UninstallerModel.systemSettingsID] } // Settings opens just before the move
        model.runningApps = running.withLock { $0 }
        #expect(check(pane) && !check(odd))
        #expect(model.isInUse(model.extensionItems![0]) == check(pane))
    }

    /// An app open from outside the application folders owns its extensions.
    @Test func runningAppsOwnExtensions() async throws {
        let root = library.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try bundle("Spotlight/Sketch.mdimporter", id: "com.qqxrunonly.sketch.importer")
        let policy = SafetyPolicy(home: root, temp: root.appending(path: "tmp"))
        let gone = await Extensions.list(policy: policy)
        #expect(gone.first?.appRemoved == true)
        let items = await Extensions.list(policy: policy, running: ["com.qqxrunonly.sketch": "Sketch Runner"])
        #expect(items.first?.owner == "Sketch Runner" && items.first?.appRemoved == false)
    }
}
