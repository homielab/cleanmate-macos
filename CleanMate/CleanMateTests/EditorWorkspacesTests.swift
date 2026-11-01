import Foundation
import Testing
@testable import CleanMate

/// Workspace storage of VS Code and its forks whose project folder is gone: one unticked entry each, to the (fake)
/// Trash. Everything happens in a throwaway fake home; projects, drives and the Trash are folders next to it.
struct EditorWorkspacesTests {
    private struct Home {
        let fm = FileManager.default
        let root = FileManager.default.temporaryDirectory.appending(path: "CleanMateEditors-\(UUID().uuidString)")
        var home: URL { root.appending(path: "home") }
        var volumes: URL { root.appending(path: "Volumes") }
        var trash: URL { root.appending(path: "Trash") }
        var policy: SafetyPolicy { SafetyPolicy(home: home, temp: root.appending(path: "tmp")) }

        init() throws {
            for dir in ["home", "tmp", "Volumes/Plugged", "Trash"] {
                try fm.createDirectory(at: root.appending(path: dir), withIntermediateDirectories: true)
            }
        }

        func item(fda: Bool = true) -> CleanerItem {
            EditorWorkspaces.item(home: home, hasFullDiskAccess: { fda }, volumesFolder: volumes.path)
        }

        @discardableResult
        func file(_ path: String, _ data: Data = Data(repeating: 1, count: 30_000)) throws -> URL {
            let url = home.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            return url
        }

        /// `<editor>/User/workspaceStorage/<hash>` with a state database and, when given, a `workspace.json` holding it.
        @discardableResult
        func workspace(_ editor: String, _ hash: String, json: String?) throws -> URL {
            let folder = "Library/Application Support/\(editor)/User/workspaceStorage/\(hash)"
            try file(folder + "/state.vscdb")
            if let json { try file(folder + "/workspace.json", Data(json.utf8)) }
            return home.appending(path: folder)
        }

        func folder(_ path: String) -> String { URL(fileURLWithPath: path).absoluteString }

        var moveToFakeTrash: @Sendable (URL) throws -> URL? {
            let trash = trash
            return { url in
                let target = trash.appending(path: UUID().uuidString + "-" + url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: target)
                return target
            }
        }

        func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }
        func remove() { try? fm.removeItem(at: root) }
    }

    @Test func catalogItem() throws {
        let item = try #require(CleanerGroup.applications().items.first { $0.id == "vscode-stale-workspaces" })
        let ids = CleanerGroup.applications().items.map(\.id)
        #expect(ids.firstIndex(of: item.id) == ids.firstIndex(of: "vscode").map { $0 + 1 })
        #expect(!item.selectedByDefault && item.selectableEntries && item.mode == .trash && !item.showsWhenEmpty)
        #expect(item.skipsOpenFiles && item.skipsEntry != nil && item.entryLabel != nil && item.minAge == nil)
        #expect(item.command == nil && item.included == nil && item.findEntries == nil && item.entryFiles == nil)
        #expect(item.paths.count == 5 && item.paths.allSatisfy { $0.hasSuffix("/User/workspaceStorage") })
        #expect(Set(item.runningAppBundleIDs) == ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium",
                                                  "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf"])
        #expect(item.runningProcessNames.contains("Code Helper (Plugin)") && item.runningProcessNames.contains("Cursor Helper (Plugin)"))
    }

    /// Only folders whose project is gone are listed, labelled `<project> — <editor>` with their size; a living,
    /// remote, unreadable or unknown project, a drive not plugged in, and a protected folder without Full Disk Access
    /// keep theirs. Cleaning moves the ticked one to the Trash; globalStorage, History and settings stay.
    @Test func listsOnlyWorkspacesOfDeletedProjects() async throws {
        let box = try Home()
        defer { box.remove() }
        let alive = box.home.appending(path: "Developer/alive")
        try box.fm.createDirectory(at: alive, withIntermediateDirectories: true)
        let aliveWorkspace = try box.file("Developer/team.code-workspace", Data("{}".utf8))
        let goneFolder = box.home.appending(path: "Developer/old app")
        let goneWorkspace = box.home.appending(path: "Developer/legacy.code-workspace")
        let goneInDocuments = box.home.appending(path: "Documents/thesis")

        let kept = try [
            box.workspace("Code", "a1", json: #"{"folder":"\#(box.folder(alive.path))"}"#),
            box.workspace("Code", "a2", json: #"{"workspace":"\#(box.folder(aliveWorkspace.path))"}"#),
            box.workspace("Code", "remote", json: #"{"folder":"vscode-remote://ssh-remote%2Bserver/home/me/gone"}"#),
            box.workspace("Code", "vfs", json: #"{"folder":"vscode-vfs://github/me/repo"}"#),
            box.workspace("Code", "1700000000000", json: nil), // an empty window
            box.workspace("Code", "broken", json: "{"),
            box.workspace("Code", "relative", json: #"{"folder":"old app"}"#),
            box.workspace("Code", "unplugged", json: #"{"folder":"\#(box.folder(box.volumes.path + "/Away/proj"))"}"#),
            box.workspace("Code", "documents", json: #"{"folder":"\#(box.folder(goneInDocuments.path))"}"#),
        ]
        let orphans = try [
            box.workspace("Code", "b1", json: #"{"folder":"\#(box.folder(goneFolder.path))"}"#),
            box.workspace("Cursor", "b2", json: #"{"workspace":"\#(box.folder(goneWorkspace.path))"}"#),
            box.workspace("Windsurf", "b3", json: #"{"folder":"\#(box.folder(box.volumes.path + "/Plugged/gone"))"}"#),
            box.workspace("Code - Insiders", "b4", json: #"{"folder":"\#(box.folder(goneFolder.path))"}"#),
            box.workspace("VSCodium", "b5", json: #"{"folder":"\#(box.folder(goneFolder.path))"}"#),
        ]
        let protected = try [
            "Library/Application Support/Code/User/globalStorage/state.vscdb",
            "Library/Application Support/Code/User/History/1a/entries.json",
            "Library/Application Support/Code/User/settings.json",
            "Library/Application Support/Cursor/User/globalStorage/storage.json",
        ].map { try box.file($0) }

        let withoutAccess = await Scanner.scan(box.item(fda: false), policy: box.policy, openPaths: EndToEndCleanTests.ownOpenPaths)
        let paths = { (scan: ItemScan) in Set(scan.entries.map { $0.url.resolvingSymlinksInPath().path }) }
        #expect(paths(withoutAccess) == Set(orphans.map { $0.resolvingSymlinksInPath().path }))

        let item = box.item()
        let scan = await Scanner.scan(item, policy: box.policy, openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(paths(scan) == Set((orphans + [kept[8]]).map { $0.resolvingSymlinksInPath().path }))
        #expect(scan.entries.allSatisfy { $0.size >= 30_000 && item.entryLabel?($0.url)?.date != nil })
        #expect(Set(scan.entries.compactMap { item.entryLabel?($0.url)?.title }) == [
            "old app — VS Code", "legacy.code-workspace — Cursor", "gone — Windsurf", "old app — VS Code Insiders",
            "old app — VSCodium", "thesis — VS Code",
        ])

        var onlyCursor = scan
        onlyCursor.entries = scan.entries.filter { $0.url.lastPathComponent == "b2" }
        let report = await Cleaner.clean(item, scan: onlyCursor, policy: box.policy, trash: box.moveToFakeTrash,
                                         openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(report.skipped == 0 && report.freed == onlyCursor.size && report.trashed.count == 1)
        #expect(!box.exists(orphans[1]) && box.exists(orphans[1].deletingLastPathComponent()))
        #expect((kept + protected + [orphans[0], orphans[2], orphans[3], orphans[4]]).allSatisfy(box.exists))
    }

    /// A project folder that comes back between the scan and the clean keeps its workspace data.
    @Test func projectBackBeforeCleaningIsKept() async throws {
        let box = try Home()
        defer { box.remove() }
        let project = box.home.appending(path: "Developer/back")
        let entry = try box.workspace("Code", "c1", json: #"{"folder":"\#(box.folder(project.path))"}"#)
        let item = box.item()
        let scan = await Scanner.scan(item, policy: box.policy, openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(scan.entries.count == 1)
        try box.fm.createDirectory(at: project, withIntermediateDirectories: true)
        let report = await Cleaner.clean(item, scan: scan, policy: box.policy, trash: box.moveToFakeTrash,
                                         openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(report.trashed.isEmpty && box.exists(entry))
    }

    /// While an editor or its extension host runs, the row is locked, not ticked (not even when the user's remembered
    /// tick says so) and not cleaned. Once it quits, the row is unticked by default and ticked by a remembered tick.
    @MainActor @Test func lockedWhileAnEditorRuns() async throws {
        let box = try Home()
        defer { box.remove() }
        let item = box.item()
        let entry = try box.workspace("Cursor", "d1", json: #"{"folder":"\#(box.folder(box.home.path + "/gone"))"}"#)
        let smartScan = SmartScanModel(module: .smartScan) { [CleanerGroup(id: "g", title: "G", systemImage: "x", items: [item])] }
        smartScan.appBundleIDs = { [] }
        smartScan.runningApps = []
        smartScan.processNames = { ["Cursor Helper (Plugin)", "zsh"] }
        smartScan.selectionOverrides = { [item.id: true] } // not this Mac's remembered ticks
        let policy = box.policy // not this Mac's Exclusions, Trash or activity log
        let trash = box.moveToFakeTrash
        smartScan.logHome = box.home
        smartScan.readOpenFiles = EndToEndCleanTests.ownOpenPaths
        smartScan.scanItem = { await Scanner.scan($0, policy: policy, openPaths: $1) }
        smartScan.cleanItem = {
            await Cleaner.clean($0, scan: $1, policy: policy, trash: trash, openPaths: $2)
        }
        await smartScan.scan()
        #expect(smartScan.isRunning(item) && smartScan.selected.isEmpty)
        smartScan.selected = [item.id]
        await smartScan.clean()
        guard case .done(let report) = smartScan.phase else { Issue.record("not done"); return }
        #expect(report.skipped == 1 && box.exists(entry))
        smartScan.processNames = { ["zsh"] }
        smartScan.runningApps = ["com.microsoft.VSCode"]
        #expect(smartScan.isRunning(item))
        smartScan.runningApps = []
        await smartScan.scan()
        #expect(!smartScan.isRunning(item) && smartScan.selected == [item.id]) // the remembered tick
        smartScan.selectionOverrides = { [:] }
        await smartScan.scan()
        #expect(!smartScan.isRunning(item) && smartScan.selected.isEmpty) // unticked by default
    }
}
