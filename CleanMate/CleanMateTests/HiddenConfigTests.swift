import Foundation
import Testing
@testable import CleanMate

/// Hidden config against a throwaway fake home; read-only, nothing is ever removed.
struct HiddenConfigTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "CleanMateHidden-\(UUID().uuidString)")
    var home: URL { root.appending(path: "home") }
    var policy: SafetyPolicy { SafetyPolicy(home: home, temp: root.appending(path: "tmp")) }

    @discardableResult
    func make(_ path: String, folder: Bool = false, contents: String = "x", age days: Double = 0) throws -> URL {
        let url = home.appending(path: path)
        if folder {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        if days > 0 {
            try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-days * 86_400)],
                                                  ofItemAtPath: url.path)
        }
        return url
    }

    @Test(arguments: [
        (".zshrc", true), (".zshrc.2026-04-04.bak", true), (".zcompdump-host-5.9", true), (".node_repl_history", true),
        (".ssh", true), (".gnupg", true), (".password-store", true), ("gh", true), (".claude.json", true), (".DS_Store", false), (".qqxstrange", false), ("qqx-tool", false),
    ])
    func known(name: String, expected: Bool) {
        #expect(HiddenConfig.isKnown(name, known: HiddenConfig.standard.union(["claude", "gh"])) == expected)
    }

    @Test func catalogPathsAreKnown() {
        let names = HiddenConfig.catalogNames()
        #expect(names.isSuperset(of: ["cargo", "ollama", "gradle", "claude"]))
    }

    @Test func listsOnlyStrangeItemsWithReasons() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        // Standard dotfiles, macOS' own entries, a fake installed CLI and its config.
        try make(".zshrc")
        try make(".gitconfig")
        try make(".ssh/id_ed25519")
        try make(".DS_Store")
        try make(".Trash/old.txt")
        try make(".local/bin/qqxtool", contents: "#!/bin/sh\n")
        try make(".qqxtool/config.toml")
        try make(".config/qqxtool/settings.json")
        try make(".config/git/ignore")
        // Strange: an old plain file, a recent folder, a folder with a script, a non-hidden file (never listed).
        try make(".qqxold", age: 30)
        try make(".qqxrecent/data.json")
        try make(".config/qqxscripts/run", contents: "#!/bin/sh\necho hi\n", age: 30)
        try make(".config/qqxscripts", folder: true, age: 30)
        try make("Notes.txt")

        let known = HiddenConfig.knownNames(policy: policy)
        #expect(known.contains("qqxtool"))
        let items = await HiddenConfig.strange(home: home, known: known)
        #expect(items.map(\.url.lastPathComponent) == [".qqxold", ".qqxrecent", "qqxscripts"])
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.url.lastPathComponent, $0) })
        #expect(byName[".qqxold"]?.isNotable == false)
        #expect(byName[".qqxrecent"]?.isRecent == true)
        #expect(byName[".qqxrecent"]?.hasExecutable == false)
        #expect(byName["qqxscripts"]?.hasExecutable == true)
        #expect(byName["qqxscripts"]?.isRecent == false)
    }

    @Test func executableBit() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try make(".qqxbin", contents: "binary")
        #expect(!HiddenConfig.isExecutable(file))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        #expect(HiddenConfig.isExecutable(file))
    }

    /// Nothing in this selection can be removed: `remove()` never reaches the trash hook and nothing is ticked.
    @MainActor @Test func hiddenConfigIsNeverRemoved() async throws {
        let model = UninstallerModel()
        let url = URL(fileURLWithPath: "/nonexistent/.qqxstrange")
        model.hiddenConfig = { [HiddenConfigItem(url: url, modified: nil, hasExecutable: true, isRecent: true)] }
        model.appSize = { _ in 7 }
        var trashed = 0
        model.trash = { _, _ in trashed += 1; return CleanReport() }
        await model.loadHiddenConfig()
        #expect(model.hiddenItems?.map(\.url) == [url])
        #expect(model.hiddenSizes[url] == 7)
        model.selection = .hiddenConfig
        await model.loadEntries()
        #expect(model.entries.isEmpty && model.checked.isEmpty && !model.loadingEntries)
        model.checked = [url] // even if something were ticked
        await model.remove()
        #expect(trashed == 0)
        #expect(model.outcome == nil && model.selection == .hiddenConfig)
    }

    /// ⌘R and the Refresh button share `refresh()`: hidden config and extensions load again, not only the apps.
    @MainActor @Test func refreshReloadsEverything() async throws {
        let model = UninstallerModel()
        var apps = 0, hidden = 0, extensions = 0
        model.installedApps = { apps += 1; return [] }
        model.hiddenConfig = { hidden += 1; return [] }
        model.extensions = { extensions += 1; return [] }
        model.appDataSizes = [URL(fileURLWithPath: "/x.app"): 1]
        model.refresh()
        #expect(model.appDataSizes.isEmpty)
        // Wait for the results, not the calls: they land after the hooks return (≥ 30 s on a busy machine).
        for _ in 0..<3000 where apps == 0 || model.hiddenItems == nil || model.extensionItems == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(apps == 1 && hidden == 1 && extensions == 1)
        #expect(model.hiddenItems != nil && model.extensionItems != nil)
    }
}
