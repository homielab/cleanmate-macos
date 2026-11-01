import Foundation
import Testing
@testable import CleanMate

/// Old versions of VS Code / Cursor / Windsurf / VSCodium extensions: one unticked entry per extension, measured as its
/// old versions and deleting only those; the version in use, `extensions.json`, `.obsolete` and folders not named like
/// an extension version stay. Everything happens in a throwaway fake home.
final class EditorExtensionsTests {
    private let fm = FileManager.default
    private let root = TestTemp.url("CleanMateEditorExtensions")
    private var home: URL { root.appending(path: "home") }
    private var policy: SafetyPolicy { SafetyPolicy(home: home, temp: root.appending(path: "tmp")) }
    private let noOpenFiles: @Sendable (String) -> Set<String> = { _ in [] }

    init() throws {
        for dir in ["home", "tmp", "elsewhere/ms-python.python-2023.1.0"] {
            try fm.createDirectory(at: root.appending(path: dir), withIntermediateDirectories: true)
        }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    private func file(_ path: String, _ data: Data = Data(repeating: 1, count: 40_000)) throws -> URL {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    /// An extension version folder with a manifest and some code.
    @discardableResult
    private func version(_ editor: String, _ name: String) throws -> URL {
        try file("\(editor)/extensions/\(name)/package.json", Data("{}".utf8))
        try file("\(editor)/extensions/\(name)/dist/extension.js")
        return home.appending(path: "\(editor)/extensions/\(name)")
    }

    private func exists(_ path: String) -> Bool { fm.fileExists(atPath: home.appending(path: path).path) }

    private let vscodeOld = ["ms-python.python-2024.1.0", "ms-python.python-2024.2.0",
                             "ms-vscode.cpptools-1.19.0-darwin-arm64"]
    private let vscodeKept = ["ms-python.python-2024.10.1", "ms-vscode.cpptools-1.20.5-darwin-arm64",
                              "esbenp.prettier-vscode-10.4.0", "redhat.java-1.0.0", "redhat.java-1.1.0",
                              "foo.bar-0.9.0", "foo.bar-1.0.0-beta", "random-folder"]

    /// VS Code: an extension with 3 versions (`.obsolete` empty), one with a single version, one platform-specific, one
    /// whose older version `extensions.json` names, folders not named like a version. Cursor: `.obsolete` names the
    /// higher version, so the lower one is the one in use.
    private func makeTree() throws {
        for name in vscodeOld + vscodeKept { try version(".vscode", name) }
        try file(".vscode/extensions/.obsolete", Data("{}".utf8))
        try file(".vscode/extensions/extensions.json", Data(#"""
            [{"identifier":{"id":"redhat.java"},"version":"1.0.0","location":{"$mid":1,"path":"/x/.vscode/extensions/redhat.java-1.0.0","scheme":"file"},"relativeLocation":"redhat.java-1.0.0"}]
            """#.utf8))
        // A symlinked version (an extension in development): never listed nor removed.
        try fm.createSymbolicLink(at: home.appending(path: ".vscode/extensions/ms-python.python-2023.1.0"),
                                  withDestinationURL: root.appending(path: "elsewhere/ms-python.python-2023.1.0"))
        for name in ["golang.go-0.41.0", "golang.go-0.42.0"] { try version(".cursor", name) }
        try file(".cursor/extensions/.obsolete", Data(#"{"golang.go-0.42.0":true,"golang.go-0.40.0":false}"#.utf8))
    }

    @Test func catalogItem() throws {
        let ids = CleanerGroup.developer.items.map(\.id)
        #expect(ids.firstIndex(of: EditorExtensions.id) == ids.firstIndex(of: OldRuntimes.goID).map { $0 + 1 })
        let item = try #require(CleanerGroup.developer.items.first { $0.id == EditorExtensions.id })
        #expect(!item.selectedByDefault && item.selectableEntries && item.mode == .delete && !item.showsWhenEmpty)
        #expect(item.skipsOpenFiles && item.findEntries != nil && item.allowsEntry != nil && item.entryParts != nil)
        #expect(item.entryLabel != nil && item.command == nil && item.probe == nil && item.minAge == nil)
        #expect(item.paths == ["~/.vscode/extensions", "~/.vscode-insiders/extensions", "~/.vscode-oss/extensions",
                               "~/.cursor/extensions", "~/.windsurf/extensions"])
        #expect(Set(item.runningAppBundleIDs) == ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium",
                                                  "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf"])
        #expect(item.runningProcessNames.contains("Code Helper (Plugin)") && item.runningProcessNames.contains("Cursor Helper (Plugin)"))
    }

    @Test func parsesVersionFolderNames() {
        #expect(EditorExtensions.parse("ms-python.python-2024.10.1") == .init(extensionID: "ms-python.python", numbers: [2024, 10, 1]))
        #expect(EditorExtensions.parse("ms-vscode.cpptools-1.20.5-darwin-arm64")?.numbers == [1, 20, 5])
        #expect(EditorExtensions.parse("GitHub.copilot-chat-0.22.4")?.key == "github.copilot-chat")
        #expect(EditorExtensions.parse("pub.name-2-1.0.0")?.extensionID == "pub.name-2")
        for name in ["extensions.json", ".obsolete", "random-folder", "foo.bar-1.0.0-beta", "foo.bar-1.0", "foo-1.0.0",
                     ".foo.bar-1.0.0", "foo.bar-1.0.0-darwin-arm64-x", "a.b.c-1.0.0", "foo.bar-v1.0.0"] {
            #expect(EditorExtensions.parse(name) == nil, "\(name)")
        }
    }

    /// One entry per extension with old versions, labelled and measured as their total; cleaning removes them and
    /// nothing else; a rescan finds nothing.
    @Test func listsAndDeletesOnlyOldVersions() async throws {
        try makeTree()
        let item = EditorExtensions.item()
        let scan = await Scanner.scan(item, policy: policy, openPaths: noOpenFiles)
        let names = scan.entries.map(\.url.lastPathComponent).sorted()
        #expect(names == ["golang.go-0.42.0", "ms-python.python-2024.2.0", "ms-vscode.cpptools-1.19.0-darwin-arm64"])
        let python = try #require(scan.entries.first { $0.url.lastPathComponent == "ms-python.python-2024.2.0" })
        var expected: Int64 = 0
        for name in vscodeOld.prefix(2) {
            expected += try #require(await Scanner.entry(at: home.appending(path: ".vscode/extensions/\(name)"), olderThan: nil)).size
        }
        #expect(python.size == expected && expected >= 80_000)
        #expect(python.title?.hasPrefix("ms-python.python — VS Code · ") == true && python.title?.contains("2") == true)
        #expect(python.date != nil)
        #expect(scan.entries.first { $0.url.lastPathComponent == "golang.go-0.42.0" }?.title?.hasPrefix("golang.go — Cursor · ") == true)

        let report = await Cleaner.clean(item, scan: scan, policy: policy, openPaths: noOpenFiles)
        #expect(report.skipped == 0 && report.freed == scan.size)
        for name in vscodeOld { #expect(!exists(".vscode/extensions/\(name)"), "\(name)") }
        for name in vscodeKept { #expect(exists(".vscode/extensions/\(name)/package.json"), "\(name)") }
        #expect(!exists(".cursor/extensions/golang.go-0.42.0") && exists(".cursor/extensions/golang.go-0.41.0/package.json"))
        for path in [".vscode/extensions/extensions.json", ".vscode/extensions/.obsolete", ".cursor/extensions/.obsolete"] {
            #expect(exists(path), "\(path)")
        }
        #expect(fm.fileExists(atPath: root.appending(path: "elsewhere/ms-python.python-2023.1.0").path))
        #expect(try fm.destinationOfSymbolicLink(atPath: home.appending(path: ".vscode/extensions/ms-python.python-2023.1.0").path) != "")
        #expect(await Scanner.scan(item, policy: policy, openPaths: noOpenFiles).entries.isEmpty)
    }

    /// The versions are read again before removal: the newest version still installed is never removed, even when it
    /// was old at scan.
    @Test func newestInstalledVersionIsKeptWhenItChangesAfterTheScan() async throws {
        try makeTree()
        let item = EditorExtensions.item()
        let scan = await Scanner.scan(item, policy: policy, openPaths: noOpenFiles)
        try fm.removeItem(at: home.appending(path: ".vscode/extensions/ms-python.python-2024.10.1"))
        _ = await Cleaner.clean(item, scan: scan, policy: policy, openPaths: noOpenFiles)
        #expect(!exists(".vscode/extensions/ms-python.python-2024.1.0"))
        #expect(exists(".vscode/extensions/ms-python.python-2024.2.0/package.json"))
    }

    /// An old version holding an open file is left out at scan and kept at clean.
    @Test func versionWithOpenFileIsKept() async throws {
        try makeTree()
        let open = home.appending(path: ".vscode/extensions/ms-python.python-2024.1.0/dist/extension.js").path
        let openPaths: @Sendable (String) -> Set<String> = { _ in [open] }
        let item = EditorExtensions.item()
        let all = await Scanner.scan(item, policy: policy, openPaths: noOpenFiles)
        let scan = await Scanner.scan(item, policy: policy, openPaths: openPaths)
        let python = { (scan: ItemScan) in scan.entries.first { $0.url.lastPathComponent == "ms-python.python-2024.2.0" }?.size ?? 0 }
        #expect(python(scan) > 0 && python(scan) < python(all))
        let report = await Cleaner.clean(item, scan: all, policy: policy, openPaths: openPaths)
        #expect(report.skipped == 1)
        #expect(exists(".vscode/extensions/ms-python.python-2024.1.0/package.json"))
        #expect(!exists(".vscode/extensions/ms-python.python-2024.2.0"))
    }

    /// An editor folder reached through a symlink, or excluded by the user, is not scanned.
    @Test func symlinkedOrExcludedFoldersAreSkipped() async throws {
        try makeTree()
        try fm.createDirectory(at: root.appending(path: "dotfiles"), withIntermediateDirectories: true)
        try fm.moveItem(at: home.appending(path: ".cursor"), to: root.appending(path: "dotfiles/.cursor"))
        try fm.createSymbolicLink(at: home.appending(path: ".cursor"), withDestinationURL: root.appending(path: "dotfiles/.cursor"))
        let item = EditorExtensions.item()
        var scan = await Scanner.scan(item, policy: policy, openPaths: noOpenFiles)
        #expect(!scan.entries.contains { $0.url.path.contains("/.cursor/") } && scan.entries.count == 2)
        let excluded = SafetyPolicy(home: home, temp: root.appending(path: "tmp"),
                                    excluded: [home.appending(path: ".vscode/extensions/ms-python.python-2024.1.0").path])
        scan = await Scanner.scan(item, policy: excluded, openPaths: noOpenFiles)
        #expect(EditorExtensions.parts(of: home.appending(path: ".vscode/extensions/ms-python.python-2024.2.0"), policy: excluded)
            .map(\.lastPathComponent) == ["ms-python.python-2024.2.0"])
        _ = await Cleaner.clean(item, scan: scan, policy: excluded, openPaths: noOpenFiles)
        #expect(exists(".vscode/extensions/ms-python.python-2024.1.0/package.json"))
        #expect(!exists(".vscode/extensions/ms-python.python-2024.2.0"))
    }

    /// Skipped while VS Code or Cursor (or its extension host) runs; unticked by default.
    @MainActor @Test func skippedWhileAnEditorRuns() async throws {
        try makeTree()
        let item = EditorExtensions.item()
        let smartScan = SmartScanModel(module: .smartScan) { [CleanerGroup(id: "g", title: "G", systemImage: "x", items: [item])] }
        smartScan.appBundleIDs = { [] }
        smartScan.runningApps = []
        smartScan.processNames = { ["Cursor Helper (Plugin)", "zsh"] }
        smartScan.selectionOverrides = { [:] } // not this Mac's remembered ticks
        let policy = policy
        smartScan.logHome = home
        smartScan.readOpenFiles = noOpenFiles
        smartScan.scanItem = { await Scanner.scan($0, policy: policy, openPaths: $1) }
        smartScan.cleanItem = { await Cleaner.clean($0, scan: $1, policy: policy, openPaths: $2) }
        await smartScan.scan()
        #expect(smartScan.isRunning(item) && smartScan.selected.isEmpty)
        smartScan.selected = [item.id]
        await smartScan.clean()
        #expect(exists(".vscode/extensions/ms-python.python-2024.1.0/package.json"))
        smartScan.processNames = { ["zsh"] }
        smartScan.runningApps = ["com.microsoft.VSCode"]
        #expect(smartScan.isRunning(item))
        smartScan.runningApps = []
        await smartScan.scan()
        #expect(!smartScan.isRunning(item) && smartScan.selected.isEmpty)
    }
}
