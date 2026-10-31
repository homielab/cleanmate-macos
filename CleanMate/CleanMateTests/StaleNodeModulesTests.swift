import Foundation
import Testing
@testable import CleanMate

/// Stale node_modules: projects laid out in a fake home in a throwaway folder and a fake Trash; the real home is never read.
struct StaleNodeModulesTests {
    let fm = FileManager.default
    let root = FileManager.default.temporaryDirectory.appending(path: "CleanMateNodeModules-\(UUID().uuidString)")
    var home: URL { root.appending(path: "home") }
    var developer: URL { home.appending(path: "Developer") }
    var trash: URL { root.appending(path: "Trash") }
    func policy(excluded: [String] = []) -> SafetyPolicy {
        SafetyPolicy(home: home, temp: root.appending(path: "tmp"), excluded: excluded)
    }
    let old = Date.now.addingTimeInterval(-120 * 86_400)

    func item(fda: Bool = true, running: [String] = []) -> CleanerItem {
        StaleNodeModules.item(home: home, hasFullDiskAccess: { fda }, running: { running })
    }

    func write(_ url: URL, bytes: Int = 4096, date: Date? = nil) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
        if let date { try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }
    }

    /// Moves into the fake Trash like `trashItem`, returning the new place.
    var moveToFakeTrash: @Sendable (URL) throws -> URL? {
        let trash = trash
        return { url in
            let target = trash.appending(path: UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }
    }

    func touch(_ url: URL, _ date: Date) throws {
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    /// A project at `path` with `package.json` and two installed packages (one with its own nested `node_modules`), all
    /// old unless `fresh` names files to date today (`yarn.lock`, `.git/index`…). Returns the bytes its node_modules holds.
    @discardableResult
    func project(_ path: String, in base: URL? = nil, fresh: [String] = [], modules: Bool = true) throws -> Int64 {
        let folder = (base ?? developer).appending(path: path)
        try write(folder.appending(path: "package.json"), bytes: 100)
        try write(folder.appending(path: "package-lock.json"), bytes: 100)
        var bytes: Int64 = 0
        if modules {
            let modules = folder.appending(path: "node_modules")
            for (file, size) in [("left-pad/index.js", 4096), ("left-pad/package.json", 4096), ("react/cjs/react.js", 40_000),
                                 ("react/node_modules/loose/index.js", 8192), ("react/node_modules/loose/package.json", 4096)] {
                try write(modules.appending(path: file), bytes: size)
                bytes += Scanner.fileSize(modules.appending(path: file))
            }
            try touch(modules, old)
        }
        try touch(folder.appending(path: "package.json"), old)
        try touch(folder.appending(path: "package-lock.json"), old)
        for name in fresh { try write(folder.appending(path: name), bytes: 100, date: .now) }
        return bytes
    }

    @Test func uncheckedToTheTrashInDeveloperJunk() throws {
        let item = try #require(CleanerGroup.developer.items.first { $0.id == "stale-node-modules" })
        #expect(item.mode == .trash && !item.selectedByDefault && item.selectableEntries && item.skipsOpenFiles)
        #expect(!item.showsWhenEmpty && item.findEntries != nil && item.allowsEntry != nil && item.command == nil)
        #expect(item.paths == ["~/Developer", "~/Projects", "~/Code", "~/src", "~/Documents", "~/Desktop"])
        #expect(StaleNodeModules.isTool("node") && StaleNodeModules.isTool("node22") && StaleNodeModules.isTool("pnpm"))
        #expect(!StaleNodeModules.isTool("python3") && !StaleNodeModules.isTool("nodejs-helper"))
    }

    /// Old projects are listed with their node_modules' size; new ones, ones without package.json, nested node_modules,
    /// too deep, hidden or symlinked folders are not. Moved to the (fake) Trash and put back by Undo.
    @Test func listsStaleProjectsAndUndoPutsThemBack() async throws {
        defer { try? fm.removeItem(at: root) }
        try #require(!(root.path as NSString).resolvingSymlinksInPath.hasPrefix((NSHomeDirectory() as NSString).resolvingSymlinksInPath + "/"))
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let oldApp = try project("old-app")
        try project("new-manifest", fresh: ["package.json"])
        try project("new-yarn-lock", fresh: ["yarn.lock"])
        try project("new-git-index", fresh: [".git/index"])
        let monoRoot = try project("mono")
        let monoWeb = try project("mono/packages/web")
        try project("active-repo/packages/api") // its repository was committed to today
        try write(developer.appending(path: "active-repo/.git/index"), bytes: 100, date: .now)
        let deep = try project("a/b/c/d") // 4 levels down
        try project("a/b/c/d/e") // 5 levels down: not looked for
        try project(".hidden/app")
        try write(developer.appending(path: "no-manifest/node_modules/x/index.js"))
        try touch(developer.appending(path: "no-manifest/node_modules"), old)
        try project("app", in: home.appending(path: "Elsewhere"))
        try fm.createSymbolicLink(at: developer.appending(path: "link"), withDestinationURL: home.appending(path: "Elsewhere"))
        try write(developer.appending(path: "sym-modules/package.json"), bytes: 100, date: old)
        try fm.createSymbolicLink(at: developer.appending(path: "sym-modules/node_modules"),
                                  withDestinationURL: home.appending(path: "Elsewhere/app/node_modules"))
        let documents = try project("thesis", in: home.appending(path: "Documents"))

        let item = item()
        let scan = await Scanner.scan(item, policy: policy(), openPaths: EndToEndCleanTests.ownOpenPaths)
        let expected = ["Developer/old-app", "Developer/mono", "Developer/mono/packages/web", "Developer/a/b/c/d", "Documents/thesis"]
        #expect(Set(scan.entries.map(\.url.path)) == Set(expected.map { home.appending(path: $0 + "/node_modules").path }))
        let sizes = Dictionary(uniqueKeysWithValues: scan.entries.map { ($0.url.deletingLastPathComponent().lastPathComponent, $0.size) })
        #expect(sizes == ["old-app": oldApp, "mono": monoRoot, "web": monoWeb, "d": deep, "thesis": documents])
        let entry = try #require(scan.entries.first { $0.url.path.hasSuffix("old-app/node_modules") })
        #expect(entry.title == "old-app" && entry.date.map { abs($0.timeIntervalSince(old)) < 1 } == true)

        // Without Full Disk Access Documents and Desktop are not read (macOS would ask).
        let withoutAccess = await Scanner.scan(self.item(fda: false), policy: policy(), openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(withoutAccess.entries.count == 4 && !withoutAccess.entries.contains { $0.url.path.contains("/Documents/") })

        let report = await Cleaner.clean(item, scan: scan, policy: policy(), trash: moveToFakeTrash,
                                         openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(report.skipped == 0 && report.freed == scan.size && report.trashed.count == 5)
        #expect(!fm.fileExists(atPath: developer.appending(path: "old-app/node_modules").path))
        #expect(fm.fileExists(atPath: developer.appending(path: "old-app/package.json").path))
        #expect(fm.fileExists(atPath: developer.appending(path: "new-manifest/node_modules").path))

        let undo = await TrashUndo.restore(report.trashed, module: "Smart Scan", home: home)
        #expect(undo == TrashUndo.Result(restored: 5, skipped: 0))
        #expect(fm.fileExists(atPath: developer.appending(path: "old-app/node_modules/react/cjs/react.js").path))
        #expect(fm.fileExists(atPath: home.appending(path: "Documents/thesis/node_modules/left-pad/index.js").path))
    }

    /// pnpm and Bun install from a store: a file hard-linked to the store or an untouched APFS clone of it frees nothing,
    /// so the entry counts only its own files, a file linked twice inside node_modules once. Cleaning reports that size,
    /// and a later scan takes it from the size cache.
    @Test func countsOnlyWhatRemovingFrees() async throws {
        defer { try? fm.removeItem(at: root) }
        let modules = developer.appending(path: "pnpm-app/node_modules")
        let own = try project("pnpm-app")
        let store = home.appending(path: "Library/pnpm/store/v10/files")
        try write(store.appending(path: "00/linked"), bytes: 300_000)
        try write(store.appending(path: "01/cloned"), bytes: 500_000)
        try fm.createDirectory(at: modules.appending(path: ".pnpm/lodash/lib"), withIntermediateDirectories: true)
        try fm.linkItem(at: store.appending(path: "00/linked"), to: modules.appending(path: ".pnpm/lodash/lib/linked.js"))
        try #require(clonefile(store.appending(path: "01/cloned").path, modules.appending(path: ".pnpm/lodash/lib/cloned.js").path, 0) == 0)
        try write(modules.appending(path: ".pnpm/inner/a.js"), bytes: 70_000)
        try fm.linkItem(at: modules.appending(path: ".pnpm/inner/a.js"), to: modules.appending(path: ".pnpm/inner/b.js"))
        let inner = Scanner.fileSize(modules.appending(path: ".pnpm/inner/a.js"))
        try touch(modules, old)

        let sizes = FolderSizeCache(file: nil)
        let item = StaleNodeModules.item(home: home, hasFullDiskAccess: { true }, running: { [] }, sizes: sizes)
        let scan = await Scanner.scan(item, policy: policy(), openPaths: EndToEndCleanTests.ownOpenPaths)
        let entry = try #require(scan.entries.first)
        #expect(scan.entries.count == 1 && entry.size == own + inner)
        // Without the rule the same folder is the store's size too.
        let whole = try #require(await Scanner.entry(at: modules, olderThan: nil)).size
        #expect(whole >= own + inner + 800_000)
        #expect(sizes.count == 1)
        #expect(await Scanner.scan(item, policy: policy(), openPaths: EndToEndCleanTests.ownOpenPaths).entries.first?.size == entry.size)

        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let report = await Cleaner.clean(item, scan: scan, policy: policy(), trash: moveToFakeTrash,
                                         openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(report.freed == own + inner && report.trashed.count == 1)
        #expect(fm.fileExists(atPath: store.appending(path: "00/linked").path))
    }

    /// The counter alone: a clone changed in place counts its rewritten part only; a hard link counts once all its
    /// links are met, never when one is outside.
    @Test func freeableBytesRules() throws {
        defer { try? fm.removeItem(at: root) }
        try write(root.appending(path: "original"), bytes: 1_000_000)
        try #require(clonefile(root.appending(path: "original").path, root.appending(path: "clone").path, 0) == 0)
        let handle = try FileHandle(forWritingTo: root.appending(path: "clone"))
        try handle.write(contentsOf: Data(repeating: 2, count: 100_000))
        try handle.close()
        func count(_ counter: FreeableBytes, _ name: String) -> Int64 {
            var info = stat()
            let path = root.appending(path: name).path
            guard lstat(path, &info) == 0 else { return -1 }
            return path.withCString { counter.count(info, path: $0) }
        }
        let clones = FreeableBytes(clones: true)
        let changed = count(clones, "clone")
        #expect(changed >= 100_000 && changed < Scanner.fileSize(root.appending(path: "clone")))
        #expect(count(FreeableBytes(clones: false), "clone") == Scanner.fileSize(root.appending(path: "clone")))

        try fm.linkItem(at: root.appending(path: "original"), to: root.appending(path: "link"))
        let links = FreeableBytes(clones: false)
        #expect(count(links, "original") == 0 && links.linkedBytes == 0) // one of two links met
        #expect(count(links, "link") == 0 && links.linkedBytes == Scanner.fileSize(root.appending(path: "original")))
    }

    /// The folder walk with one listing per folder gives what fts gives with a `getattrlist` per file: hard links in and
    /// out of the folder, whole and changed clones, a clone of a file outside, symlinks, a pipe, an empty and an
    /// unreadable folder, and a folder of 3 000 files (several listings).
    @Test func freeableWalkMatchesFts() async throws {
        let tree = root.appending(path: "tree"), outside = root.appending(path: "outside")
        defer {
            chmod(tree.appending(path: "locked").path, 0o755)
            try? fm.removeItem(at: root)
        }
        try write(outside.appending(path: "store-file"), bytes: 200_000)
        try write(outside.appending(path: "store-clone"), bytes: 300_000)
        try write(tree.appending(path: "a/own.js"), bytes: 50_000)
        try write(tree.appending(path: "a/b/c/deep.js"), bytes: 9_000)
        try fm.linkItem(at: tree.appending(path: "a/own.js"), to: tree.appending(path: "a/b/own-link.js"))
        try fm.linkItem(at: outside.appending(path: "store-file"), to: tree.appending(path: "a/store-link.js"))
        try #require(clonefile(outside.appending(path: "store-clone").path, tree.appending(path: "a/clone.js").path, 0) == 0)
        try #require(clonefile(outside.appending(path: "store-clone").path, tree.appending(path: "a/changed.js").path, 0) == 0)
        let handle = try FileHandle(forWritingTo: tree.appending(path: "a/changed.js"))
        try handle.write(contentsOf: Data(repeating: 3, count: 100_000))
        try handle.close()
        try write(tree.appending(path: "a/twin.js"), bytes: 80_000)
        try #require(clonefile(tree.appending(path: "a/twin.js").path, tree.appending(path: "a/twin-clone.js").path, 0) == 0)
        try fm.createSymbolicLink(atPath: tree.appending(path: "a/link").path, withDestinationPath: outside.path)
        try fm.createSymbolicLink(atPath: tree.appending(path: "a/dangling").path, withDestinationPath: "/nonexistent")
        try #require(mkfifo(tree.appending(path: "a/pipe").path, 0o600) == 0)
        try fm.createDirectory(at: tree.appending(path: "empty"), withIntermediateDirectories: true)
        try write(tree.appending(path: "locked/secret"), bytes: 4096)
        let many = tree.appending(path: "many")
        try fm.createDirectory(at: many, withIntermediateDirectories: true)
        for index in 0..<3_000 {
            try Data(repeating: 1, count: index % 7 * 1_000).write(to: many.appending(path: "file-with-a-long-name-\(index).js"))
        }
        #expect(chmod(tree.appending(path: "locked").path, 0) == 0)
        let device = try #require(SafetyPolicy.deviceID(tree.path))
        for clones in [true, false] {
            let fts = FreeableBytes(clones: clones), bulk = FreeableBytes(clones: clones)
            let expected = try #require(Scanner.tree(tree, dates: true, device: device, freeable: fts))
            let walked = try #require(bulk.walk(tree.path, device: device))
            #expect(walked.0 + bulk.linkedBytes == expected.0 + fts.linkedBytes, "clones: \(clones)")
            #expect(walked.2 && expected.2, "unreadable folder flagged")
            #expect(bulk.linkedBytes == fts.linkedBytes && bulk.linkedBytes > 0)
            // Through `Scanner.tree` the walk is used whenever dates are not needed; split, it gives the same.
            let viaTree = FreeableBytes(clones: clones)
            #expect(Scanner.tree(tree, dates: false, device: device, freeable: viaTree)?.0 == walked.0)
            for depth in [1, 3] {
                let split = FreeableBytes(clones: clones)
                let parallel = try #require(await Scanner.undatedTree(tree.path, device: device, links: .init(),
                                                                      freeable: split, depth: depth))
                #expect(parallel.0 + split.linkedBytes == walked.0 + bulk.linkedBytes && parallel.2, "depth \(depth)")
            }
        }
    }

    /// A project something works on is kept: node or a package manager running in it, an exclusion, a file opened or
    /// a lockfile written after the scan.
    @Test func projectsInUseAreKept() async throws {
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        try project("served")
        try project("excluded")
        try project("opened")
        try project("installed")
        let running = [developer.appending(path: "served/src").path, "/usr/local/lib/node_modules/npm/bin/npm-cli.js"]
        let policy = policy(excluded: [developer.appending(path: "excluded").path])
        let scan = await Scanner.scan(item(running: running), policy: policy, openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(Set(scan.entries.map { $0.url.deletingLastPathComponent().lastPathComponent }) == ["opened", "installed"])

        let handle = try FileHandle(forReadingFrom: developer.appending(path: "opened/node_modules/left-pad/index.js"))
        defer { try? handle.close() }
        try write(developer.appending(path: "installed/pnpm-lock.yaml"), bytes: 100, date: .now)
        let report = await Cleaner.clean(item(running: running), scan: scan, policy: policy,
                                         trash: moveToFakeTrash, openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(report.skipped == 2 && report.trashed.isEmpty && report.freed == 0)
        #expect(fm.fileExists(atPath: developer.appending(path: "installed/node_modules").path))
    }

    @Test func policyAllowsOnlyProjectDependencies() throws {
        defer { try? fm.removeItem(at: root) }
        let policy = policy()
        func allows(_ path: String) -> Bool { policy.allowsNodeModules(home.appending(path: path)) }
        for path in ["Developer/p", "Documents/p", "Desktop/p", "Pictures/p", "Library/Application Support/p", ".npm/p",
                     "Developer/p/node_modules/dep", "Developer/Tool.app/Contents/Resources/p", "Developer/no-manifest"] {
            try write(home.appending(path: path + "/node_modules/x/index.js"))
            if !path.hasSuffix("no-manifest") { try write(home.appending(path: path + "/package.json"), bytes: 10) }
        }
        try fm.createDirectory(at: home.appending(path: "Developer/Tool.app/Contents"), withIntermediateDirectories: true)
        #expect(allows("Developer/p/node_modules") && allows("Documents/p/node_modules") && allows("Desktop/p/node_modules"))
        #expect(!policy.allows(home.appending(path: "Documents/p/node_modules"))) // the general rule is unchanged
        #expect(!allows("Pictures/p/node_modules") && !allows("Library/Application Support/p/node_modules"))
        #expect(!allows(".npm/p/node_modules") && !allows("Developer/p/node_modules/dep/node_modules"))
        #expect(!allows("Developer/no-manifest/node_modules") && !allows("Developer/p") && !allows("Developer/p/package.json"))
        #expect(!allows("Developer/Tool.app/Contents/Resources/p/node_modules"))
        try write(home.appending(path: "Developer/q/package.json"), bytes: 10)
        try fm.createSymbolicLink(at: home.appending(path: "Developer/q/node_modules"),
                                  withDestinationURL: home.appending(path: "Developer/p/node_modules"))
        #expect(!allows("Developer/q/node_modules"))
        try write(home.appending(path: "Developer/r/node_modules"), bytes: 10) // a file
        try write(home.appending(path: "Developer/r/package.json"), bytes: 10)
        #expect(!allows("Developer/r/node_modules"))
        let excluded = self.policy(excluded: [home.appending(path: "Developer/p").path])
        #expect(!excluded.allowsNodeModules(home.appending(path: "Developer/p/node_modules")))
    }

    /// The folder walk stops at its depth and its folder budget.
    @Test func findStopsAtDepthAndLimit() async throws {
        defer { try? fm.removeItem(at: root) }
        try project("x")
        try project("y/z")
        #expect(await StaleProjects.find(in: [developer], depth: 1).map(\.lastPathComponent) == ["node_modules"])
        #expect(await StaleProjects.find(in: [developer]).count == 2)
        #expect(await StaleProjects.find(in: [developer], folderLimit: 1).isEmpty) // only the root itself was read
        #expect(await StaleProjects.find(in: [developer], skipping: [developer.appending(path: "y").path]).count == 1)
    }

    /// A worktree's `.git` file leads to its own index in the main repository.
    @Test func worktreeIndexCounts() throws {
        defer { try? fm.removeItem(at: root) }
        try project("tree")
        try write(developer.appending(path: "main/.git/worktrees/tree/index"), bytes: 10, date: .now)
        try Data("gitdir: ../main/.git/worktrees/tree\n".utf8).write(to: developer.appending(path: "tree/.git"))
        try touch(developer.appending(path: "tree/.git"), old)
        #expect(StaleProjects.gitFolder(linkedFrom: developer.appending(path: "tree/.git").path)
            == developer.appending(path: "main/.git/worktrees/tree").path)
        let date = try #require(StaleNodeModules.lastWorkedOn(developer.appending(path: "tree/node_modules"), home: home))
        #expect(date > .now.addingTimeInterval(-60))
    }

    @Test func readsProcessWorkingFolder() {
        let own = (fm.currentDirectoryPath as NSString).resolvingSymlinksInPath
        #expect(RunningProcesses.workingFolder(of: getpid()).map { ($0 as NSString).resolvingSymlinksInPath } == own)
        let folders = RunningProcesses.folders(ofProcessesNamed: { _ in true })
        #expect(folders.contains(RunningProcesses.withoutPrivate(own)))
        #expect(StaleProjects.isUsed(URL(fileURLWithPath: "/Users/me/app"), by: ["/Users/me/app/src"]))
        #expect(!StaleProjects.isUsed(URL(fileURLWithPath: "/Users/me/app"), by: ["/Users/me/app-2", "/Users/me"]))
    }
}
