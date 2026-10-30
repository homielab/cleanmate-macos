import Foundation
import Testing
@testable import CleanMate

/// Stale build folders: projects laid out in a fake home in a throwaway folder and a fake Trash; the real home is never read.
struct StaleBuildFoldersTests {
    let fm = FileManager.default
    let root = FileManager.default.temporaryDirectory.appending(path: "CleanMateBuildFolders-\(UUID().uuidString)")
    var home: URL { root.appending(path: "home") }
    var developer: URL { home.appending(path: "Developer") }
    var trash: URL { root.appending(path: "Trash") }
    func policy(excluded: [String] = []) -> SafetyPolicy {
        SafetyPolicy(home: home, temp: root.appending(path: "tmp"), excluded: excluded)
    }
    let old = Date.now.addingTimeInterval(-100 * 86_400)

    func item(fda: Bool = true, running: [String] = []) -> CleanerItem {
        StaleBuildFolders.item(home: home, hasFullDiskAccess: { fda }, running: { running })
    }

    func write(_ url: URL, bytes: Int = 4096, date: Date? = nil) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
        if let date { try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }
    }

    var moveToFakeTrash: @Sendable (URL) throws -> URL? {
        let trash = trash
        return { url in
            let target = trash.appending(path: UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }
    }

    /// A project at `path` (in `base`, else ~/Developer) with `files` (its project files and lockfiles) and a build
    /// folder `folder` holding `contents`, all dated 100 days ago. Returns the bytes the build folder holds.
    @discardableResult
    func project(_ path: String, in base: URL? = nil, files: [String], folder: String, contents: [String: Int]) throws -> Int64 {
        let project = (base ?? developer).appending(path: path)
        var bytes: Int64 = 0
        for (file, size) in contents {
            let url = project.appending(path: folder + "/" + file)
            try write(url, bytes: size, date: old)
            bytes += Scanner.fileSize(url)
        }
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: project.appending(path: folder).path)
        for file in files { try write(project.appending(path: file), bytes: 100, date: old) }
        return bytes
    }

    @discardableResult
    func cargo(_ path: String, in base: URL? = nil) throws -> Int64 {
        try project(path, in: base, files: ["Cargo.toml", "Cargo.lock"], folder: "target",
                    contents: ["debug/app": 90_000, "debug/deps/libx.rlib": 40_000, "CACHEDIR.TAG": 100])
    }

    @Test func uncheckedToTheTrashAfterNodeModules() throws {
        let items = CleanerGroup.developer.items
        let index = try #require(items.firstIndex { $0.id == "stale-build-dirs" })
        #expect(items[index - 1].id == "stale-node-modules")
        let item = items[index]
        #expect(item.mode == .trash && !item.selectedByDefault && item.selectableEntries && item.skipsOpenFiles)
        #expect(!item.showsWhenEmpty && item.findEntries != nil && item.allowsEntry != nil && item.command == nil)
        #expect(item.paths == StaleProjects.folders)
        #expect(["cargo", "rustc", "uv", "pod", "ruby", "python", "python3", "python3.12"].allSatisfy(StaleBuildFolders.isTool))
        #expect(!StaleBuildFolders.isTool("node") && !StaleBuildFolders.isTool("python-helper"))
    }

    /// Old Cargo, Python and CocoaPods projects are listed with their build folder's size, labelled with the project's
    /// path; a lockfile changed 10 days ago, a project inside a repository committed to today and a `target` with no
    /// `Cargo.toml` next to it are not. Moved to the (fake) Trash and put back by Undo.
    @Test func listsStaleBuildFoldersAndUndoPutsThemBack() async throws {
        defer { try? fm.removeItem(at: root) }
        try #require(!(root.path as NSString).resolvingSymlinksInPath.hasPrefix((NSHomeDirectory() as NSString).resolvingSymlinksInPath + "/"))
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let rust = try cargo("rust-cli")
        let python = try project("client/api", files: ["pyproject.toml", "uv.lock"], folder: ".venv",
                                 contents: ["pyvenv.cfg": 100, "lib/python3.12/site-packages/x/__init__.py": 20_000])
        let pods = try project("Documents/ios-app", in: home, files: ["Podfile", "Podfile.lock"], folder: "Pods",
                               contents: ["Alamofire/Source/Session.swift": 60_000, "Manifest.lock": 100])
        try cargo("recent-lock")
        try write(developer.appending(path: "recent-lock/Cargo.lock"), bytes: 100, date: .now.addingTimeInterval(-10 * 86_400))
        try cargo("active-repo/crates/core") // its repository was committed to today
        try write(developer.appending(path: "active-repo/.git/index"), bytes: 100, date: .now)
        try project("maven", files: ["pom.xml"], folder: "target", contents: ["app.jar": 50_000])
        try project("no-cfg", files: ["requirements.txt"], folder: "venv", contents: ["lib/x.py": 4096])

        let item = item()
        let scan = await Scanner.scan(item, policy: policy(), openPaths: EndToEndCleanTests.ownOpenPaths)
        let expected = ["Developer/rust-cli/target", "Developer/client/api/.venv", "Documents/ios-app/Pods"]
        #expect(Set(scan.entries.map(\.url.path)) == Set(expected.map { home.appending(path: $0).path }))
        let sizes = Dictionary(uniqueKeysWithValues: scan.entries.map { ($0.url.lastPathComponent, $0.size) })
        #expect(sizes == ["target": rust, ".venv": python, "Pods": pods])
        let titles = Set(scan.entries.compactMap(\.title))
        #expect(titles == ["~/Developer/rust-cli — target/", "~/Developer/client/api — .venv/", "~/Documents/ios-app — Pods/"])
        #expect(scan.entries.allSatisfy { $0.date.map { abs($0.timeIntervalSince(old)) < 1 } == true })

        // Without Full Disk Access Documents and Desktop are not read (macOS would ask).
        let withoutAccess = await Scanner.scan(self.item(fda: false), policy: policy(), openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(withoutAccess.entries.count == 2 && !withoutAccess.entries.contains { $0.url.path.contains("/Documents/") })

        let report = await Cleaner.clean(item, scan: scan, policy: policy(), trash: moveToFakeTrash,
                                         openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(report.skipped == 0 && report.freed == scan.size && report.trashed.count == 3)
        #expect(!fm.fileExists(atPath: developer.appending(path: "rust-cli/target").path))
        #expect(fm.fileExists(atPath: developer.appending(path: "rust-cli/Cargo.toml").path))
        #expect(fm.fileExists(atPath: developer.appending(path: "recent-lock/target").path))

        let undo = await TrashUndo.restore(report.trashed, module: "Smart Scan", home: home)
        #expect(undo == TrashUndo.Result(restored: 3, skipped: 0))
        #expect(fm.fileExists(atPath: developer.appending(path: "rust-cli/target/debug/app").path))
        #expect(fm.fileExists(atPath: developer.appending(path: "client/api/.venv/pyvenv.cfg").path))
    }

    /// A project where cargo or Python runs, or that is excluded, is kept.
    @Test func projectsInUseAreKept() async throws {
        defer { try? fm.removeItem(at: root) }
        try cargo("built")
        try cargo("excluded")
        try cargo("idle")
        let policy = policy(excluded: [developer.appending(path: "excluded").path])
        let scan = await Scanner.scan(item(running: [developer.appending(path: "built").path]), policy: policy,
                                      openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(scan.entries.map { $0.url.deletingLastPathComponent().lastPathComponent } == ["idle"])
    }

    /// Both items find their folders in one walk of the same folders, and each only its own.
    @Test func itemsShareOneWalk() async throws {
        defer { try? fm.removeItem(at: root) }
        try cargo("both")
        try write(developer.appending(path: "both/package.json"), bytes: 100, date: old)
        try write(developer.appending(path: "both/node_modules/x/index.js"), date: old)
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: developer.appending(path: "both/node_modules").path)
        let node = StaleNodeModules.item(home: home, hasFullDiskAccess: { true }, running: { [] })
        async let builds = Scanner.scan(item(), policy: policy(), openPaths: EndToEndCleanTests.ownOpenPaths)
        async let modules = Scanner.scan(node, policy: policy(), openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(await builds.entries.map(\.url.lastPathComponent) == ["target"])
        #expect(await modules.entries.map(\.url.lastPathComponent) == ["node_modules"])
        #expect(await StaleProjects.shared(in: [developer], skipping: []).map(\.lastPathComponent) == ["node_modules", "target"])
        // A second walk of the same folders right after reuses the first one's result.
        try fm.removeItem(at: developer.appending(path: "both/target"))
        #expect(await StaleProjects.shared(in: [developer], skipping: []).count == 2)
        #expect(await StaleProjects.find(in: [developer]).count == 1)
    }

    @Test func policyAllowsOnlyBuildFoldersNextToTheirProjectFile() throws {
        defer { try? fm.removeItem(at: root) }
        let policy = policy()
        func allows(_ path: String) -> Bool { policy.allowsBuildFolder(home.appending(path: path)) }
        try write(developer.appending(path: "rs/Cargo.toml"), bytes: 10)
        try write(developer.appending(path: "rs/target/x"))
        try write(developer.appending(path: "py/requirements-dev.txt"), bytes: 10)
        for name in [".venv", "venv"] { try write(developer.appending(path: "py/\(name)/pyvenv.cfg"), bytes: 10) }
        try write(developer.appending(path: "py/env/pyvenv.cfg"), bytes: 10)
        try write(developer.appending(path: "ios/Podfile"), bytes: 10)
        try write(developer.appending(path: "ios/Pods/x"))
        try write(developer.appending(path: "mvn/pom.xml"), bytes: 10)
        try write(developer.appending(path: "mvn/target/x"))
        try write(developer.appending(path: "bare/.venv/pyvenv.cfg"), bytes: 10) // no Python project file
        try write(developer.appending(path: "rs/target/sub/Cargo.toml"), bytes: 10) // inside a build folder
        try write(developer.appending(path: "rs/target/sub/target/x"))
        try write(home.appending(path: "Pictures/rs/Cargo.toml"), bytes: 10)
        try write(home.appending(path: "Pictures/rs/target/x"))
        #expect(allows("Developer/rs/target") && allows("Developer/py/.venv") && allows("Developer/py/venv"))
        #expect(allows("Developer/ios/Pods"))
        #expect(!allows("Developer/py/env") && !allows("Developer/mvn/target") && !allows("Developer/bare/.venv"))
        #expect(!allows("Developer/rs/target/sub/target") && !allows("Pictures/rs/target") && !allows("Developer/rs"))
        #expect(!policy.allowsNodeModules(developer.appending(path: "rs/target")))
        try fm.removeItem(at: developer.appending(path: "py/venv/pyvenv.cfg"))
        #expect(!allows("Developer/py/venv"))
        try write(developer.appending(path: "ln/Cargo.toml"), bytes: 10)
        try fm.createSymbolicLink(at: developer.appending(path: "ln/target"), withDestinationURL: developer.appending(path: "rs/target"))
        #expect(!allows("Developer/ln/target"))
        let excluded = self.policy(excluded: [developer.appending(path: "rs").path])
        #expect(!excluded.allowsBuildFolder(developer.appending(path: "rs/target")))
    }

    /// A project's `requirements*.txt` counts as one of its files.
    @Test func requirementsFileCounts() throws {
        defer { try? fm.removeItem(at: root) }
        try project("py", files: ["requirements.txt"], folder: "venv", contents: ["pyvenv.cfg": 100])
        let venv = developer.appending(path: "py/venv")
        #expect(try #require(StaleBuildFolders.lastWorkedOn(venv, home: home)) < .now.addingTimeInterval(-99 * 86_400))
        try write(developer.appending(path: "py/requirements-test.txt"), bytes: 10, date: .now)
        #expect(try #require(StaleBuildFolders.lastWorkedOn(venv, home: home)) > .now.addingTimeInterval(-60))
        #expect(StaleBuildFolders.label(venv, home: home) == "~/Developer/py — venv/")
    }
}
