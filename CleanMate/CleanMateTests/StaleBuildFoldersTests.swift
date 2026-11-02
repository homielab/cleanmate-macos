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
        #expect(["cargo", "rustc", "uv", "pod", "ruby", "python", "python3", "python3.12", "java", "dart", "node",
                 "swift-build", "beam.smp", "zig", "ghc", "ghc-9.8.2"].allSatisfy(StaleBuildFolders.isTool))
        #expect(!StaleBuildFolders.isTool("python-helper") && !StaleBuildFolders.isTool("ghc-pkg") && !StaleBuildFolders.isTool("git"))
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
        try project("web", files: ["package.json"], folder: "dist", contents: ["app.js": 50_000]) // no marker for dist
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
        #expect(allows("Developer/mvn/target"))
        #expect(!allows("Developer/py/env") && !allows("Developer/bare/.venv"))
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

    /// uv clones a virtual environment's packages from its cache: an untouched clone counts 0 in `.venv`; Cargo's
    /// `target` is measured whole (no clone lookups), except hard links to files outside it.
    @Test func venvClonesCountOnlyTheirOwnBytes() async throws {
        defer { try? fm.removeItem(at: root) }
        let cache = home.appending(path: ".cache/uv/archive-v0/x/site-packages/numpy/core.so")
        try write(cache, bytes: 400_000)
        let venvOwn = try project("py", files: ["pyproject.toml", "uv.lock"], folder: ".venv",
                                  contents: ["pyvenv.cfg": 100, "lib/python3.12/site-packages/app.py": 20_000])
        let numpy = developer.appending(path: "py/.venv/lib/python3.12/site-packages/numpy/core.so")
        try fm.createDirectory(at: numpy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #require(clonefile(cache.path, numpy.path, 0) == 0)
        let rust = try cargo("rust-cli")
        let rustClone = developer.appending(path: "rust-cli/target/debug/copy")
        try #require(clonefile(cache.path, rustClone.path, 0) == 0)
        try fm.linkItem(at: cache, to: developer.appending(path: "rust-cli/target/debug/linked"))
        for folder in ["py/.venv", "rust-cli/target"] {
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: developer.appending(path: folder).path)
        }

        let item = StaleBuildFolders.item(home: home, hasFullDiskAccess: { true }, running: { [] }, sizes: FolderSizeCache(file: nil))
        let scan = await Scanner.scan(item, policy: policy(), openPaths: EndToEndCleanTests.ownOpenPaths)
        let sizes = Dictionary(uniqueKeysWithValues: scan.entries.map { ($0.url.lastPathComponent, $0.size) })
        #expect(sizes == [".venv": venvOwn, "target": rust + Scanner.fileSize(rustClone)])
    }

    /// Each build system's folders are found next to the file that makes them, and never without it, as a symlink or
    /// as a regular file of the same name.
    @Test func eachBuildSystemNeedsItsFile() throws {
        defer { try? fm.removeItem(at: root) }
        let cases: [(files: [String], folders: [String])] = [
            (["Cargo.toml"], ["target"]), (["pom.xml"], ["target"]), (["Podfile"], ["Pods"]),
            (["build.gradle"], ["build", ".gradle"]), (["build.gradle.kts"], ["build", ".gradle"]),
            (["settings.gradle"], ["build", ".gradle"]), (["settings.gradle.kts"], ["build", ".gradle"]),
            (["Package.swift"], [".build"]), (["pubspec.yaml"], [".dart_tool", "build"]),
            (["package.json", "next.config.mjs"], [".next"]), (["package.json", "nuxt.config.ts"], [".nuxt", ".output"]),
            (["package.json", "svelte.config.js"], [".svelte-kit"]), (["package.json", "angular.json"], [".angular/cache"]),
            (["package.json", "turbo.json"], [".turbo"]), (["stack.yaml"], [".stack-work"]),
            (["cabal.project"], ["dist-newstyle"]), (["app.cabal"], ["dist-newstyle"]),
            (["mix.exs"], ["_build", "deps"]), (["build.zig"], [".zig-cache", "zig-cache"]),
        ]
        func found(_ project: URL) -> Set<String> {
            Set(StaleProjects.buildFolders(in: project.path, children: StaleProjects.entries(of: project.path)))
        }
        for (index, (files, folders)) in cases.enumerated() {
            let project = developer.appending(path: "p\(index)")
            for folder in folders { try write(project.appending(path: folder + "/x")) }
            for file in files.dropLast() { try write(project.appending(path: file), bytes: 10) }
            #expect(found(project).isEmpty, "\(files) without \(files.last!)")
            try write(project.appending(path: files.last!), bytes: 10)
            #expect(found(project) == Set(folders), "\(files)")
            for folder in folders { #expect(StaleProjects.isProjectFolder(project.appending(path: folder).path)) }

            // The same names as a symlink to a real folder, or a regular file, are not build folders.
            let links = developer.appending(path: "links\(index)"), plain = developer.appending(path: "files\(index)")
            for file in files {
                try write(links.appending(path: file), bytes: 10)
                try write(plain.appending(path: file), bytes: 10)
            }
            for folder in folders {
                try fm.createDirectory(at: links.appending(path: folder).deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.createSymbolicLink(at: links.appending(path: folder), withDestinationURL: project.appending(path: folder))
                try write(plain.appending(path: folder))
            }
            #expect(found(links).isEmpty && found(plain).isEmpty, "\(files)")
        }
        // A framework's config without package.json, the marker as a folder, zig-out and names alone are not.
        let other = developer.appending(path: "other")
        for folder in [".next", "zig-out", "build", "dist", "out", "target", "_build"] { try write(other.appending(path: folder + "/x")) }
        try write(other.appending(path: "next.config.js"), bytes: 10)
        try fm.createDirectory(at: other.appending(path: "Cargo.toml"), withIntermediateDirectories: true)
        #expect(found(other).isEmpty)
        try write(other.appending(path: "build.zig"), bytes: 10)
        #expect(found(other).isEmpty) // no .zig-cache; zig-out is what the project installs
    }

    /// A Gradle module's `build` belongs to the project around it only when the module has its own build file.
    @Test func gradleModuleBuildNeedsItsBuildFile() throws {
        defer { try? fm.removeItem(at: root) }
        let android = developer.appending(path: "android")
        try write(android.appending(path: "settings.gradle.kts"), bytes: 10)
        try write(android.appending(path: "app/build.gradle.kts"), bytes: 10)
        try write(android.appending(path: "app/build/outputs/app.apk"))
        try write(android.appending(path: "lib/build/x")) // no build file
        try write(android.appending(path: ".hidden/build.gradle"), bytes: 10)
        try write(android.appending(path: ".hidden/build/x"))
        try write(android.appending(path: "core/build.gradle"), bytes: 10)
        try fm.createSymbolicLink(at: android.appending(path: "core/build"), withDestinationURL: android.appending(path: "app/build"))
        let found = StaleProjects.buildFolders(in: android.path, children: StaleProjects.entries(of: android.path))
        #expect(found == ["app/build"])
        let appBuild = android.appending(path: "app/build")
        #expect(StaleProjects.projectPath(of: appBuild.path) == android.path)
        #expect(StaleBuildFolders.label(appBuild, home: home) == "~/Developer/android — app/build/")
        #expect(StaleBuildFolders.label(android.appending(path: ".angular/cache"), home: home) == "~/Developer/android — .angular/cache/")
        // A Gradle module alone is its own project.
        try fm.removeItem(at: android.appending(path: "settings.gradle.kts"))
        #expect(StaleProjects.projectPath(of: appBuild.path) == android.appending(path: "app").path)
        #expect(StaleBuildFolders.label(appBuild, home: home) == "~/Developer/android/app — build/")
    }

    /// Old Android, Next.js, Angular, Elixir and Zig projects are listed, each folder once with its path in the project;
    /// a Gradle project changed 10 days ago, a project inside a build folder and Zig's `zig-out` are not, nor a project
    /// a tool runs in. Two-level folders go to the (fake) Trash and come back.
    @Test func listsNewBuildSystems() async throws {
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        try project("android", files: ["settings.gradle.kts", "build.gradle.kts", "app/build.gradle.kts"], folder: "app/build",
                    contents: ["outputs/app.apk": 80_000])
        try project("android", files: [], folder: ".gradle", contents: ["8.10/file-hashes.bin": 10_000])
        try project("android", files: [], folder: "build/sub", contents: ["Cargo.toml": 100, "target/x": 4096]) // not walked
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: developer.appending(path: "android/build").path)
        try project("site", files: ["package.json", "next.config.ts"], folder: ".next", contents: ["cache/x": 30_000])
        try project("ng", files: ["package.json", "angular.json"], folder: ".angular/cache", contents: ["x": 20_000])
        try project("ex", files: ["mix.exs", "mix.lock"], folder: "deps", contents: ["jason/lib/jason.ex": 9_000])
        try project("zig", files: ["build.zig"], folder: ".zig-cache", contents: ["o/x": 9_000])
        try project("zig", files: [], folder: "zig-out", contents: ["bin/app": 9_000])
        try project("busy", files: ["package.json", "turbo.json"], folder: ".turbo", contents: ["x": 4096])
        try project("recent", files: ["build.gradle"], folder: "build", contents: ["x": 4096])
        try write(developer.appending(path: "recent/build.gradle"), bytes: 10, date: .now.addingTimeInterval(-10 * 86_400))

        let item = item(running: [developer.appending(path: "busy").path])
        let scan = await Scanner.scan(item, policy: policy(), openPaths: EndToEndCleanTests.ownOpenPaths)
        let titles = scan.entries.compactMap(\.title).sorted()
        #expect(titles == ["~/Developer/android — .gradle/", "~/Developer/android — app/build/", "~/Developer/android — build/",
                           "~/Developer/ex — deps/",
                           "~/Developer/ng — .angular/cache/", "~/Developer/site — .next/", "~/Developer/zig — .zig-cache/"])
        // The module's own build.gradle.kts changed today: its project was worked on.
        try write(developer.appending(path: "android/app/build.gradle.kts"), bytes: 10, date: .now)
        #expect(try #require(StaleBuildFolders.lastWorkedOn(developer.appending(path: "android/app/build"), home: home)) > .now.addingTimeInterval(-60))
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: developer.appending(path: "android/app/build.gradle.kts").path)
        // The framework's config counts as one of the project's files.
        try write(developer.appending(path: "site/next.config.ts"), bytes: 10, date: .now)
        #expect(try #require(StaleBuildFolders.lastWorkedOn(developer.appending(path: "site/.next"), home: home)) > .now.addingTimeInterval(-60))

        let twoLevel = scan.entries.filter { $0.url.path.hasSuffix("/app/build") || $0.url.path.hasSuffix("/.angular/cache") }
        var cleaned = scan
        cleaned.entries = twoLevel
        let report = await Cleaner.clean(item, scan: cleaned, policy: policy(), trash: moveToFakeTrash,
                                         openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(report.skipped == 0 && report.trashed.count == 2)
        #expect(!fm.fileExists(atPath: developer.appending(path: "android/app/build").path))
        #expect(!fm.fileExists(atPath: developer.appending(path: "ng/.angular/cache").path))
        #expect(fm.fileExists(atPath: developer.appending(path: "android/app/build.gradle.kts").path))
        #expect(fm.fileExists(atPath: developer.appending(path: "ng/.angular").path))
        let undo = await TrashUndo.restore(report.trashed, module: "Smart Scan", home: home)
        #expect(undo == TrashUndo.Result(restored: 2, skipped: 0))
        #expect(fm.fileExists(atPath: developer.appending(path: "android/app/build/outputs/app.apk").path))
    }

    /// The policy allows a module's `build` and `.angular/cache` next to their files, nothing inside a build folder,
    /// and no `build` without a build file.
    @Test func policyAllowsTwoLevelBuildFolders() throws {
        defer { try? fm.removeItem(at: root) }
        let policy = policy()
        func allows(_ path: String) -> Bool { policy.allowsBuildFolder(developer.appending(path: path)) }
        try write(developer.appending(path: "and/settings.gradle"), bytes: 10)
        try write(developer.appending(path: "and/app/build.gradle"), bytes: 10)
        try write(developer.appending(path: "and/app/build/x"))
        try write(developer.appending(path: "and/lib/build/x"))
        try write(developer.appending(path: "and/build/sub/build.gradle"), bytes: 10) // inside a build folder
        try write(developer.appending(path: "and/build/sub/build/x"))
        try write(developer.appending(path: "ng/package.json"), bytes: 10)
        try write(developer.appending(path: "ng/angular.json"), bytes: 10)
        try write(developer.appending(path: "ng/.angular/cache/x"))
        try write(developer.appending(path: "plain/build/x"))
        try write(developer.appending(path: "ex/mix.exs"), bytes: 10)
        try write(developer.appending(path: "ex/deps/x"))
        #expect(allows("and/app/build") && allows("and/build") && allows("ng/.angular/cache") && allows("ex/deps"))
        #expect(!allows("and/lib/build") && !allows("and/build/sub/build") && !allows("plain/build") && !allows("ng/.angular"))
        #expect(!policy.allowsNodeModules(developer.appending(path: "and/build")))
        #expect(!policy.allowsTerraformFolder(developer.appending(path: "ng/.angular/cache")))
    }
}
