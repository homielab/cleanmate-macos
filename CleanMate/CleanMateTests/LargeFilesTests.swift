import Combine
import CryptoKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import CleanMate

/// Large & Old Files run against a throwaway fake home; nothing is ever moved to the real Trash.
struct LargeFilesTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "CleanMateLargeFiles-\(UUID().uuidString)")
    var home: URL { root.appending(path: "home") }
    var policy: SafetyPolicy { SafetyPolicy(home: home, temp: root.appending(path: "tmp")) }

    @discardableResult
    func file(_ path: String, bytes: Int = 20_000) throws -> URL {
        let url = home.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
        return url
    }

    /// A file with another hard link is marked (trashing it frees nothing), and still listed.
    @Test func hardLinkedFileIsMarked() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let linked = try file("Documents/linked.mov")
        try file("Documents/single.mov")
        try FileManager.default.linkItem(at: linked, to: home.appending(path: "Documents/other.mov"))
        let found = try await LargeFileScanner.scan(root: home, minSize: 10_000, policy: policy)
        #expect(found.first { $0.url.lastPathComponent == "linked.mov" }?.hardLinked == true)
        #expect(found.first { $0.url.lastPathComponent == "single.mov" }?.hardLinked == false)
    }

    /// A virtual machine bundle is one row with the size of everything inside it, never opened, movable when the
    /// Space Lens rule takes the folder; the files inside are not listed.
    @Test func virtualMachineBundleIsOneRow() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = home.appending(path: "Parallels/Windows 11.pvm")
        try file("Parallels/Windows 11.pvm/disk.img", bytes: 60_000)
        try file("Parallels/Windows 11.pvm/config", bytes: 100)
        try file("Parallels/keep.txt", bytes: 20_000)
        let found = try await LargeFileScanner.scan(root: home, minSize: 10_000, policy: policy)
        let rows = found.filter { $0.url.lastPathComponent.hasPrefix("Windows 11") }
        #expect(rows.count == 1)
        #expect(rows.first?.url.standardizedFileURL.path == bundle.standardizedFileURL.path,
                "was: \(rows.first?.url.path ?? "nil")")
        #expect((rows.first?.size ?? 0) >= 60_000)
        #expect(rows.first?.trashable == true) // in the home folder, not under ~/Library
        #expect(found.contains { $0.url.lastPathComponent == "keep.txt" })
        #expect(!found.contains { $0.url.lastPathComponent == "disk.img" })
        #expect(LargeFileScanner.isVMBundle(bundle))
        // A bundle under ~/Library is never reached by the home walk; outside the home it is not a root.
        #expect(!LargeFileScanner.isVMBundle(home.appending(path: "Parallels/Windows 11")))
    }

    @Test func userFilePolicyAllowsDocumentsButNotLibraryHiddenPackagesOrOutsideHome() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["Documents/a.mov", "Desktop/b.zip", "Movies/c.mp4", "Downloads/d.dmg", "Music/e.iso", "f.pkg"] {
            #expect(policy.allowsUserFile(try file(path)), "\(path)")
        }
        for path in ["Library/Mobile Documents/x.mov", "Library/CloudStorage/x.zip", "library/Keychains/x", ".ssh/id_rsa",
                     ".gnupg/x", ".Trash/x.dmg", "Documents/.git/pack", "Documents/.hidden.mov",
                     "Applications/Foo.app/Contents/x.dmg", "Pictures/Photos Library.photoslibrary/x.jpg"] {
            #expect(!policy.allowsUserFile(try file(path)), "\(path)")
        }
        // Folders, symlinks, the home itself and anything outside it.
        let link = home.appending(path: "Documents/link.mov")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home.appending(path: "Documents/a.mov"))
        for url in [home.appending(path: "Documents"), link, home, root.appending(path: "tmp/x"),
                    URL(fileURLWithPath: "/etc/hosts"), URL(fileURLWithPath: "/Applications/Safari.app")] {
            #expect(!policy.allowsUserFile(url), "\(url.path)")
        }
        // Smart Scan's policy is unchanged: user documents stay blocked there.
        #expect(!policy.allows(home.appending(path: "Documents/a.mov")))
    }

    @Test(arguments: [
        ("Movie.MOV", FileKind.video), ("clip.mp4", .video), ("a.mkv", .video), ("x.zip", .archive), ("x.tar", .archive),
        ("x.7z", .archive), ("x.xip", .archive), ("Ubuntu.iso", .diskImage), ("vm.qcow2", .diskImage),
        ("Setup.dmg", .installer), ("x.pkg", .installer), ("song.mp3", .audio), ("take.WAV", .audio), ("x.flac", .audio),
        ("IMG_1.HEIC", .image), ("x.png", .image), ("x.psd", .image), ("x.dng", .image), ("logo.svg", .image),
        ("x.pdf", .document), ("x.docx", .document), ("x.xlsx", .document), ("x.pptx", .document),
        ("notes.txt", .document), ("x.md", .document), ("x.csv", .document), ("x.epub", .document),
        ("x.mobi", .document), ("x.swift", .code), ("x.py", .code), ("x.go", .code), ("x.rs", .code), ("x.json", .code),
        ("x.ipynb", .code), ("x.sql", .code), ("x.css", .code), ("noext", .other), ("model.gguf", .other), ("x.db", .other),
    ])
    func classifiesByExtension(name: String, kind: FileKind) {
        #expect(FileKind(fileExtension: (name as NSString).pathExtension) == kind)
    }

    /// Nine kinds in the filter; each kind's `UTType` family lands in it.
    @Test func classifiesByType() {
        #expect(FileKind.allCases.count == 9)
        #expect(FileKind(type: .mpeg4Movie) == .video && FileKind(type: .mp3) == .audio && FileKind(type: .jpeg) == .image)
        #expect(FileKind(type: .rtf) == .document && FileKind(type: .presentation) == .document)
        #expect(FileKind(type: .shellScript) == .code && FileKind(type: .yaml) == .code && FileKind(type: .data) == .other)
    }

    /// A file of no known kind inside a project (a Git repo, a package) is code; known kinds keep theirs; a home under
    /// Git does not make everything code.
    @Test func unknownFilesInAProjectAreCode() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: home.appending(path: "Developer/app/.git"), withIntermediateDirectories: true)
        try file("Developer/app/models/weights.gguf")
        try file("Developer/app/demo.mov")
        try file("Developer/tool/Cargo.toml", bytes: 10)
        try file("Developer/tool/target/debug/tool.rlib")
        try file("Downloads/backup.db")
        try FileManager.default.createDirectory(at: home.appending(path: ".git"), withIntermediateDirectories: true)
        let found = try await LargeFileScanner.scan(root: home, minSize: 10_000, policy: policy)
        let kinds = Dictionary(uniqueKeysWithValues: found.map { ($0.name, $0.kind) })
        #expect(kinds == ["weights.gguf": .code, "demo.mov": .video, "tool.rlib": .code, "backup.db": .other])
    }

    @Test func projectLookupStopsBelowHomeAndRemembersFolders() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = home.appending(path: "a/repo")
        try FileManager.default.createDirectory(at: repo.appending(path: "src/deep"), withIntermediateDirectories: true)
        try Data().write(to: repo.appending(path: "package.json"))
        let known = Locked([String: Bool]())
        #expect(FileKind.isInProject(repo.appending(path: "src/deep").path, home: home.path, known: known))
        #expect(known.withLock { $0[repo.appending(path: "src").path] } == true)
        #expect(!FileKind.isInProject(home.appending(path: "a").path, home: home.path, known: known))
        #expect(!FileKind.isInProject(home.path, home: home.path, known: known)) // never the home itself
    }

    @Test(arguments: [
        ("/Users/me/Downloads/a.zip", "~/Downloads"), ("/Users/me/a.zip", "~"),
        ("/Users/me/Movies/Old/2019/Trip/a.mov", "~/Movies/Old/2019/Trip"),
        ("/Users/meow/a.zip", "/Users/meow"), ("/Volumes/Data/a.zip", "/Volumes/Data"),
    ])
    func displayLocationAbbreviatesHome(path: String, expected: String) {
        #expect(LargeFile.displayLocation(of: URL(fileURLWithPath: path), home: URL(fileURLWithPath: "/Users/me")) == expected)
        let file = LargeFile(url: URL(fileURLWithPath: path), size: 1, lastUsed: .now, kind: .other, home: URL(fileURLWithPath: "/Users/me/"))
        #expect(file.location == expected)
    }

    @Test func filtersBySizeAndAge() {
        let year: TimeInterval = 365 * 86_400
        let old = LargeFile(url: URL(fileURLWithPath: "/a"), size: 100, lastUsed: .now.addingTimeInterval(-2 * year), kind: .other)
        let recent = LargeFile(url: URL(fileURLWithPath: "/b"), size: 100, lastUsed: .now, kind: .other)
        let cutoff = Date.now.addingTimeInterval(-year)
        #expect(old.matches(minSize: 100, unusedSince: cutoff))
        #expect(!recent.matches(minSize: 100, unusedSince: cutoff))
        #expect(recent.matches(minSize: 100, unusedSince: nil))
        #expect(!old.matches(minSize: 101, unusedSince: nil))
    }

    @Test func scanFindsLargeUserFilesOnly() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try file("Documents/big.mov")
        try file("Downloads/sub/setup.dmg")
        try file("Documents/small.mov", bytes: 100)
        for path in ["Library/Caches/big.zip", ".hidden/big.zip", "Documents/.big.zip", "code/node_modules/big.zip",
                     "Applications/Foo.app/Contents/big.zip"] {
            try file(path)
        }
        let found = try await LargeFileScanner.scan(root: home, minSize: 10_000, policy: policy)
        #expect(Set(found.map(\.name)) == ["big.mov", "setup.dmg"])
        #expect(found.allSatisfy { $0.size >= 20_000 })
        #expect(found.first { $0.name == "big.mov" }?.kind == .video)
    }

    @Test func lastUsedPrefersSpotlightOverAccessButNeverBeforeModification() {
        let (d1, d2, d3) = (Date(timeIntervalSince1970: 1), Date(timeIntervalSince1970: 2), Date(timeIntervalSince1970: 3))
        #expect(LargeFileScanner.lastUsed(spotlight: d1, accessed: d3, modified: nil) == d1) // stale atime ignored
        #expect(LargeFileScanner.lastUsed(spotlight: d3, accessed: d1, modified: d2) == d3)
        #expect(LargeFileScanner.lastUsed(spotlight: d1, accessed: d3, modified: d2) == d2) // modified after last open
        #expect(LargeFileScanner.lastUsed(spotlight: nil, accessed: d3, modified: d2) == d3) // fallback max(atime, mtime)
        #expect(LargeFileScanner.lastUsed(spotlight: nil, accessed: d1, modified: d2) == d2)
        #expect(LargeFileScanner.lastUsed(spotlight: nil, accessed: nil, modified: nil) == .distantPast)
    }

    @Test func scanUsesInjectedSpotlightDateOnlyForLargeFiles() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let big = try file("Documents/big.mov")
        try file("Documents/small.mov", bytes: 100)
        let opened = Date.now.addingTimeInterval(86_400) // later than mtime, so it must win
        let found = try await LargeFileScanner.scan(root: home, minSize: 10_000, policy: policy, spotlightLastUsed: { url in
            #expect(url.lastPathComponent == "big.mov") // never asked for files under the threshold
            return opened
        })
        #expect(found.map(\.url.lastPathComponent) == [big.lastPathComponent])
        #expect(found.first?.lastUsed == opened)
    }

    /// The folder levels read in parallel (`splitDepth`) and the enumerator below them skip the same things.
    @Test func parallelLevelsAndDeeperWalkSkipTheSameFolders() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        var kept: Set<String> = []
        for level in 0...LargeFileScanner.splitDepth + 1 {
            let dir = (0..<level).map { "d\($0)/" }.joined()
            kept.insert(try file(dir + "keep.mov").standardizedFileURL.path)
            for path in ["node_modules/x.mov", "Pods/x.mov", ".hidden/x.mov", ".x.mov", "Foo.app/Contents/x.mov", "small.mov"] {
                try file(dir + path, bytes: path == "small.mov" ? 10 : 20_000)
            }
        }
        try file("Library/x.mov")
        let found = try await LargeFileScanner.scan(root: home, minSize: 10_000, policy: policy)
        #expect(Set(found.map(\.url.standardizedFileURL.path)) == kept && found.count == kept.count)
    }

    @Test func scanCanBeCancelled() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try file("Documents/big.mov")
        let (home, policy) = (home, policy)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() } // cancelled before the walk starts, no timing race
            return try await LargeFileScanner.scan(root: home, minSize: 1, policy: policy)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func trashRefusesFilesOutsideThePolicy() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let blocked = try file("Library/Caches/big.zip")
        let report = await LargeFileScanner.trash(
            [LargeFile(url: blocked, size: 20_000, lastUsed: .now, kind: .archive)], policy: policy)
        #expect(report.skipped == 1 && report.freed == 0)
        #expect(FileManager.default.fileExists(atPath: blocked.path))
    }

    @Test func withoutFullDiskAccessProtectedFoldersAreNotEntered() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["Documents/big.mov", "Music/sub/big.zip", "Projects/big.zip"] { try file(path) }
        let without = ProtectedFolders.skipped(home: home, hasFullDiskAccess: false)
        #expect(without.contains(home.appending(path: "Library/Mobile Documents").path))
        #expect(ProtectedFolders.skipped(home: home, hasFullDiskAccess: true).isEmpty)
        let found = try await LargeFileScanner.scan(root: home, minSize: 10_000, policy: policy, skipping: without)
        #expect(found.map(\.name) == ["big.zip"] && found[0].url.path.contains("/Projects/"))
        let all = try await LargeFileScanner.scan(root: home, minSize: 10_000, policy: policy,
                                                  skipping: ProtectedFolders.skipped(home: home, hasFullDiskAccess: true))
        #expect(all.count == 3)
    }

    /// Scope: a folder inside home lists only its own files, the home rules still apply; others are refused.
    @Test func scanOfASubfolderListsOnlyItsFilesAndRootsOutsideHomeAreRefused() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["Projects/app/big.zip", "Projects/app/node_modules/x.zip", "Projects/app/.cache/x.zip",
                     "Movies/big.mov"] { try file(path) }
        let found = try await LargeFileScanner.scan(root: home.appending(path: "Projects"), minSize: 10_000, policy: policy)
        #expect(found.map(\.name) == ["big.zip"])
        #expect(found[0].location == "~/Projects/app")
        for bad in [root, root.appending(path: "tmp"), home.appending(path: "Library/Caches"), home.appending(path: ".ssh"),
                    URL(fileURLWithPath: "/Applications")] {
            #expect(!LargeFileScanner.allowsRoot(bad, policy: policy), "\(bad.path)")
            await #expect(throws: LargeFileScanner.OutsideHomeError.self) {
                try await LargeFileScanner.scan(root: bad, minSize: 1, policy: policy)
            }
        }
        #expect(LargeFileScanner.allowsRoot(home, policy: policy) && LargeFileScanner.allowsRoot(home.appending(path: "Projects/app"), policy: policy))
        // Without Full Disk Access a protected folder, or one inside it, needs access; its neighbours do not.
        let skipped = ProtectedFolders.skipped(home: home, hasFullDiskAccess: false)
        #expect(ProtectedFolders.contains(skipped, home.appending(path: "Downloads")))
        #expect(ProtectedFolders.contains(skipped, home.appending(path: "Documents/Work")))
        #expect(!ProtectedFolders.contains(skipped, home.appending(path: "Projects")) && !ProtectedFolders.contains(skipped, home))
    }

    /// An external volume (a folder standing in for /Volumes/Ext) or a folder on it can be scanned: its files are listed,
    /// never through a symlink, never hidden ones (.Trashes) or ones the policy blocks (excluded, another volume inside).
    @Test func scanOfAnExternalVolume() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let volumes = root.appending(path: "Volumes")
        let ext = volumes.appending(path: "Ext")
        try FileManager.default.createDirectory(at: ext, withIntermediateDirectories: true)
        @discardableResult func put(_ path: String) throws -> URL {
            let url = ext.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 20_000).write(to: url)
            return url
        }
        try put("Movies/big.mov"); try put(".Trashes/501/old.mov"); try put("Backups/keep.zip")
        try put("Nested/inner.zip"); try put("Excluded/x.zip")
        let outside = try file("Projects/home.zip")
        try FileManager.default.createSymbolicLink(at: ext.appending(path: "Movies/link.zip"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: ext.appending(path: "LinkedFolder"),
                                                   withDestinationURL: home.appending(path: "Projects"))
        let nested = ext.appending(path: "Nested").standardizedFileURL.path
        let realExt = SafetyPolicy.normalize(ext)
        let policy = SafetyPolicy(home: home, temp: root.appending(path: "tmp"),
                                  excluded: [ext.appending(path: "Excluded").path],
                                  device: { path in
                                      let real = (path as NSString).resolvingSymlinksInPath
                                      return real.hasPrefix((nested as NSString).resolvingSymlinksInPath) ? 99 : SafetyPolicy.deviceID(path)
                                  },
                                  mounts: { ["/", realExt] }, volumesFolder: volumes.path)
        let found = try await LargeFileScanner.scan(root: ext, minSize: 10_000, policy: policy)
        #expect(Set(found.map(\.name)) == ["big.mov", "keep.zip"])
        #expect(found.allSatisfy { SafetyPolicy.normalize($0.url).hasPrefix(realExt + "/") })
        let movies = try await LargeFileScanner.scan(root: ext.appending(path: "Movies"), minSize: 10_000, policy: policy)
        #expect(movies.map(\.name) == ["big.mov"])
        #expect(LargeFileScanner.allowsRoot(ext, policy: policy) && LargeFileScanner.allowsRoot(ext.appending(path: "Movies"), policy: policy))
        for bad in [volumes, ext.appending(path: ".Trashes"), ext.appending(path: "Excluded"), ext.appending(path: "Nested"),
                    root.appending(path: "Other")] {
            #expect(!LargeFileScanner.allowsRoot(bad, policy: policy), "\(bad.path)")
        }
        // Not mounted any more (or never was): the same folder is not a volume.
        let unmounted = SafetyPolicy(home: home, temp: root.appending(path: "tmp"), mounts: { ["/"] }, volumesFolder: volumes.path)
        #expect(!LargeFileScanner.allowsRoot(ext, policy: unmounted))
        #expect(!unmounted.allowsUserFile(ext.appending(path: "Movies/big.mov")))
    }

    /// One helper for the Large & Old Files and Space Lens recent folders: newest five, no repeats,
    /// folders that no longer exist dropped. Pure on the stored string, so no defaults are written.
    @Test func recentFoldersKeepTheNewestFiveExistingWithoutRepeats() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try ["a", "b", "c", "d", "e", "f"].map { name in
            let url = home.appending(path: name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url.path
        }
        var stored = ""
        for i in [0, 1, 2, 3, 4, 5, 2] { stored = Preferences.addingRecentFolder(paths[i], to: stored) }
        #expect(Preferences.recentFolders(stored) == [2, 5, 4, 3, 1].map { paths[$0] })
        try FileManager.default.removeItem(atPath: paths[5])
        #expect(Preferences.recentFolders(stored) == [2, 4, 3, 1].map { paths[$0] })
        stored = Preferences.addingRecentFolder(paths[0], to: stored)
        #expect(stored.split(separator: "\n").map(String.init) == [0, 2, 4, 3, 1].map { paths[$0] })
        #expect(Preferences.recentFolders(home.appending(path: "missing").path).isEmpty)
    }

    /// A saved scope comes back; one that is gone, outside home, hidden, excluded or protected without Full
    /// Disk Access falls back to the home folder.
    @MainActor @Test func savedScopeIsRestoredUnlessNoLongerValid() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Projects", "Projects/Old", ".hidden", "Downloads"] {
            try FileManager.default.createDirectory(at: home.appending(path: name), withIntermediateDirectories: true)
        }
        let model = LargeFilesModel()
        model.home = home
        var access = true
        model.hasFullDiskAccess = { access }
        let projects = home.appending(path: "Projects")
        model.restoreScope(projects.path, excluded: [])
        #expect(model.scope == LargeFilesModel.folder(projects.path) && model.scopeName == "~/Projects")
        for path in ["", home.path, home.appending(path: "Gone").path, home.appending(path: ".hidden").path, root.path] {
            model.restoreScope(projects.path, excluded: [])
            model.restoreScope(path, excluded: [])
            #expect(model.scope == nil, "\(path)")
        }
        model.restoreScope(home.appending(path: "Projects/Old").path, excluded: [projects.path.uppercased()])
        #expect(model.scope == nil)
        model.restoreScope(home.appending(path: "Downloads").path, excluded: [])
        #expect(model.scope != nil)
        access = false
        model.restoreScope(home.appending(path: "Downloads").path, excluded: [])
        #expect(model.scope == nil)
    }

    /// Each scope keeps its own entry count for the progress estimate; a protected scope without access is not scanned.
    @MainActor @Test func scopeChangesRescanWithItsOwnEstimateAndProtectedScopesNeedAccess() async throws {
        let suite = TestDefaults.suite("CleanMateTests")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { TestDefaults.remove(suite) }
        let model = LargeFilesModel()
        #expect(model.lastCountDefaults == nil) // test host: never the real preferences
        model.lastCountDefaults = defaults
        model.home = home
        var access = true
        model.hasFullDiskAccess = { access }
        let roots = Roots()
        model.scanFiles = { root, _, _, _ in await roots.add(root); return [] }
        func scanned() async throws {
            try await eventually("the scan reaches its results", timeout: .seconds(60)) {
                if case .results = model.phase { return true }
                return false
            }
        }
        let projects = home.appending(path: "Projects")
        #expect(!model.setScope(root)) // outside home: refused, nothing scanned
        Preferences.update(Preferences.largeFilesLastCount, defaults: defaults) { (counts: inout [String: Int]) in
            counts["\(projects.path)|full"] = 1500
            counts["\(home.path)|full"] = 3000
        }
        #expect(model.setScope(projects))
        #expect(model.estimatedCount == 1500 && model.scopeName == "~/Projects")
        try await scanned()
        #expect(model.lastCounts == ["\(projects.path)|full": 0, "\(home.path)|full": 3000]) // the finished scan's count
        model.setScope(home)
        #expect(model.scope == nil && model.estimatedCount == 3000)
        try await scanned()
        #expect(await roots.all.map(\.lastPathComponent) == ["Projects", home.lastPathComponent])
        access = false
        model.setScope(home.appending(path: "Downloads"))
        #expect(model.needsAccess && model.files.isEmpty)
        guard case .results = model.phase else { Issue.record("phase \(model.phase)"); return }
        #expect(await roots.all.count == 2)
    }

    /// The entry counts keep only scopes inside home (older versions also stored others), at most `lastCountLimit`.
    @Test func lastCountsKeepScopesInsideHomeUpToTheLimit() {
        let home = URL(fileURLWithPath: "/Users/me")
        let stale = ["/var/folders/x/T/CleanMateLargeFiles-1|full": 5, "/Users/meow|full": 6, "/Users/me/../other|full": 7,
                     "no-bar": 8, "/Users/me|limited": 9, "/Users/me/Downloads|full": 10]
        #expect(LargeFilesModel.recordingLastCount(1, for: "/Users/me|full", in: stale, home: home)
                == ["/Users/me|full": 1, "/Users/me|limited": 9, "/Users/me/Downloads|full": 10])
        let many = Dictionary(uniqueKeysWithValues: (10..<40).map { ("/Users/me/F\($0)|full", $0) })
        let kept = LargeFilesModel.recordingLastCount(2, for: "/Users/me/New|full", in: many, home: home, limit: 5)
        #expect(kept == ["/Users/me/New|full": 2, "/Users/me/F10|full": 10, "/Users/me/F11|full": 11,
                         "/Users/me/F12|full": 12, "/Users/me/F13|full": 13])
        #expect(LargeFilesModel.recordingLastCount(3, for: "/Users/me/F39|full", in: many, home: home, limit: 2)
                == ["/Users/me/F39|full": 3, "/Users/me/F10|full": 10])
    }

    /// Moving 2 of 5 files to the Trash keeps the list: 3 rows stay, the report shows above them, nothing is scanned
    /// again. "Undo" lists the 2 again once they are back.
    @MainActor @Test(.timeLimit(.minutes(1))) func trashKeepsTheOtherRowsWithoutScanningAgain() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try (1...5).map { try file("Movies/\($0).mov") }
        let trash = root.appending(path: "Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let model = LargeFilesModel()
        model.home = home
        model.hasFullDiskAccess = { true }
        let scans = Locked(0)
        model.scanFiles = { _, _, _, _ in
            scans.withLock { $0 += 1 }
            return urls.map { LargeFile(url: $0, size: 100_000_000, lastUsed: .distantPast, kind: .video, home: home) }
        }
        model.trashFiles = { files in
            var report = CleanReport()
            for file in files {
                let inTrash = trash.appending(path: file.url.lastPathComponent)
                guard (try? FileManager.default.moveItem(at: file.url, to: inTrash)) != nil else { continue }
                report.freed += file.size
                report.trashed.append(TrashedItem(original: file.url, inTrash: inTrash, size: file.size))
            }
            return report
        }
        model.restore = { items in
            for item in items { try? FileManager.default.moveItem(at: item.inTrash, to: item.original) }
            return TrashUndo.Result(restored: items.count, skipped: 0)
        }
        model.scan()
        await until(model) { if case .results = $0.phase { true } else { false } }
        #expect(model.files.count == 5)
        model.checked = [urls[1], urls[3]]
        await model.trash()
        guard case .results = model.phase else { Issue.record("phase \(model.phase)"); return }
        #expect(Set(model.files.map(\.url)) == Set([urls[0], urls[2], urls[4]]))
        #expect(model.checked.isEmpty && scans.withLock { $0 } == 1)
        #expect(model.lastTrash?.freed == 200_000_000 && model.lastTrash?.trashed.count == 2)
        await model.undoTrash()
        #expect(Set(model.files.map(\.url)) == Set(urls) && scans.withLock { $0 } == 1)
        #expect(model.lastTrash?.undo == TrashUndo.Result(restored: 2, skipped: 0))
        model.dismissTrashReport()
        #expect(model.lastTrash == nil)
    }

    /// Under a test host a finished scan keeps its count in memory only: the real preferences stay untouched.
    @MainActor @Test func finishedScanNeverWritesTheRealPreferencesInTests() async throws {
        let before = UserDefaults.standard.dictionary(forKey: Preferences.largeFilesLastCount) as? [String: Int]
        let model = LargeFilesModel()
        model.home = home
        model.hasFullDiskAccess = { true }
        model.scanFiles = { _, _, _, progress in
            progress(700)
            try await eventually("the count reaches the model") { await MainActor.run { model.scannedCount } == 700 }
            return []
        }
        model.scan()
        try await eventually("the scan reaches its results", timeout: .seconds(60)) {
            if case .results = model.phase { return true }
            return false
        }
        #expect(model.lastCounts == ["\(home.path)|full": 700])
        #expect(UserDefaults.standard.dictionary(forKey: Preferences.largeFilesLastCount) as? [String: Int] == before)
    }

    /// A burst of progress reports reaches the view as one update per `progressInterval`; the stored count is the highest.
    @MainActor @Test func scanProgressIsThrottledAndTheHighestCountIsStored() async throws {
        let model = LargeFilesModel()
        model.home = home
        model.hasFullDiskAccess = { true }
        model.scanFiles = { _, _, _, progress in
            for count in stride(from: 500, through: 500_000, by: 500) { progress(count) } // well under 100 ms
            // Kept: the throttler measures time, so the next report has to come one interval later.
            try await Task.sleep(for: LargeFilesModel.progressInterval * 2)
            progress(500_500) // the next interval: shown again
            try await eventually("the count reaches the model") { await MainActor.run { model.scannedCount } == 500_500 }
            return []
        }
        var shown: [Int] = []
        let subscription = model.$scannedCount.dropFirst().sink { shown.append($0) }
        defer { subscription.cancel() }
        model.scan()
        try await eventually("the scan reaches its results", timeout: .seconds(60)) {
            if case .results = model.phase { return true }
            return false
        }
        #expect(shown.filter { $0 > 0 } == [500, 500_500]) // `scan()` resets it to 0 first
        #expect(model.lastCounts == ["\(home.path)|full": 500_500])
    }

    /// A folder scope can go down to 1 MB (smaller → scans again, larger → filters only); the home stays ≥ 50 MB.
    @MainActor @Test func folderScopeScansDownToOneMegabyteHomeStaysAtFifty() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try file("Projects/small.bin", bytes: 2_000_000)
        try file("Projects/medium.bin", bytes: 12_000_000)
        let model = LargeFilesModel()
        model.home = home
        model.hasFullDiskAccess = { true }
        let thresholds = Roots() // each scan's threshold, as the last path component
        let policy = policy
        model.scanFiles = { root, minSize, _, _ in
            await thresholds.add(URL(filePath: "/\(minSize)"))
            return try await LargeFileScanner.scan(root: root, minSize: minSize, policy: policy, spotlightLastUsed: { _ in nil })
        }
        func scanned() async throws {
            try await eventually("the scan reaches its results", timeout: .seconds(60)) {
                if case .results = model.phase { return true }
                return false
            }
        }
        #expect(model.sizeChoices == LargeFilesModel.sizeOptions)
        model.setScope(home.appending(path: "Projects"))
        try await scanned()
        #expect(model.files.isEmpty && model.sizeChoices.first == 1_000_000)
        model.minSize = 1_000_000
        try await scanned()
        #expect(model.visibleFiles.map(\.name) == ["medium.bin", "small.bin"])
        model.minSize = 10_000_000 // filters what is already scanned
        #expect(model.visibleFiles.map(\.name) == ["medium.bin"])
        model.setScope(home)
        #expect(model.minSize == 50_000_000)
        try await scanned()
        #expect(model.files.isEmpty && model.scannedMinSize == 50_000_000)
        #expect(await thresholds.all.map(\.lastPathComponent) == ["50000000", "1000000", "50000000"])
    }

    /// A scope or size change whose scan is stopped puts back the scope and size of the files still shown.
    @MainActor @Test func stoppedScanKeepsTheScopeAndSizeOfTheShownFiles() async throws {
        let model = LargeFilesModel()
        model.home = home
        model.hasFullDiskAccess = { true }
        let projects = LargeFilesModel.folder(home.appending(path: "Projects").path)
        model.scanFiles = { root, _, _, _ in
            if root.lastPathComponent != "Projects" { try await untilCancelled() } // until stopped
            return []
        }
        func settled() async throws {
            try await eventually("the scan reaches its results", timeout: .seconds(60)) {
                if case .results = model.phase { return true }
                return false
            }
        }
        model.setScope(projects)
        try await settled()
        model.setScope(home) // whole home: blocks
        #expect(model.scope == nil)
        model.cancel()
        try await settled()
        #expect(model.scope == projects && model.scopeName == "~/Projects")
        model.scanFiles = { _, _, _, _ in try await untilCancelled(); return [] }
        model.minSize = 1_000_000 // below the 50 MB scanned: scans again, then stopped
        guard case .scanning = model.phase else { Issue.record("phase \(model.phase)"); return }
        model.cancel()
        try await settled()
        #expect(model.minSize == model.scannedMinSize && model.scannedMinSize == 50_000_000)
    }
}

actor Roots {
    var all: [URL] = []
    func add(_ url: URL) { all.append(url) }
}

/// Duplicates: only same-size files are read; same content → group, hard links and different content → not.
struct DuplicateFinderTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "CleanMateDuplicates-\(UUID().uuidString)")

    func file(_ name: String, _ data: Data) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: name)
        try data.write(to: url)
        return url
    }

    @Test func sameContentIsDuplicateSameSizeDifferentContentAndHardLinksAreNot() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let content = Data((0..<3_000_000).map { UInt8($0 % 251) }) // > 1 MB: several chunks
        var other = content
        other[other.count - 1] ^= 0xFF // same size, last byte differs
        let a = try file("a.mov", content), b = try file("b.mov", content)
        let c = try file("c.mov", other)
        let unique = try file("d.mov", Data(count: 10))
        let link = root.appending(path: "a-link.mov")
        try FileManager.default.linkItem(at: a, to: link)
        let result = try await DuplicateFinder.find([a, link, b, c, unique])
        #expect(result.groups == [[a, b]])
        // a and b; c is ruled out by its last 64 KB, the hard link and the unique size are never read.
        #expect(result.hashedCount == 2)
        // Second run answers from the cache, and a changed file is read again.
        #expect(try await DuplicateFinder.find([a, b, c], cache: result.hashes).hashedCount == 0)
        try other.write(to: b)
        let changed = try await DuplicateFinder.find([a, b, c], cache: result.hashes)
        #expect(changed.groups == [[b, c]])
        #expect(changed.hashedCount == 2) // b changed, c was never read in full; a is ruled out by its sample
    }

    @Test func onlyHardLinksAreNotDuplicates() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try file("a.zip", Data(repeating: 7, count: 1_000))
        let link = root.appending(path: "b.zip")
        try FileManager.default.linkItem(at: a, to: link)
        let result = try await DuplicateFinder.find([a, link])
        #expect(result.groups.isEmpty && result.hashedCount == 0)
    }

    /// APFS clones are duplicates, the clones of one file grouped without reading them; trashing one frees only the
    /// blocks it alone holds: 0 for a whole-file clone, the rewritten part for a clone changed in place. A plain
    /// copy frees its whole size (no private size). Skipped when the temporary folder is not on APFS.
    @Test func apfsClonesAreDuplicatesThatFreeOnlyTheirOwnBlocks() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try file("a.mov", Data((0..<1_048_576).map { UInt8($0 % 251) }))
        let clone = root.appending(path: "b.mov")
        guard clonefile(a.path, clone.path, 0) == 0, DuplicateFinder.cloneID(of: a) != nil else { return } // not APFS
        #expect(DuplicateFinder.cloneID(of: a) == DuplicateFinder.cloneID(of: clone))
        let pair = try await DuplicateFinder.find([a, clone])
        #expect(pair.groups == [[a, clone]] && pair.hashedCount == 0)
        #expect(pair.privateSizes == [a: 0, clone: 0])
        let copy = try file("c.mov", Data(contentsOf: a)) // plain write: own blocks
        #expect(DuplicateFinder.cloneID(of: copy) == nil && DuplicateFinder.privateSize(of: copy) == nil)
        let three = try await DuplicateFinder.find([a, clone, copy])
        #expect(three.groups == [[a, clone, copy]] && three.hashedCount == 2) // a and the copy; the clone is not read
        #expect(three.privateSizes == [a: 0, clone: 0])
        // The first 64 KB of a fresh clone rewritten with the same bytes: same content, those blocks are its own
        // now, and the original's old ones only the original's.
        let original = try file("d.mov", Data(contentsOf: a)), changed = root.appending(path: "e.mov")
        #expect(clonefile(original.path, changed.path, 0) == 0)
        let handle = try FileHandle(forWritingTo: changed)
        try handle.write(contentsOf: try Data(contentsOf: original).prefix(65_536)); try handle.close()
        #expect(DuplicateFinder.cloneID(of: changed) == nil)
        let partly = try await DuplicateFinder.find([original, changed])
        #expect(partly.groups == [[original, changed]])
        #expect(partly.privateSizes == [original: 65_536, changed: 65_536])
    }

    /// Chunks read in their own autorelease pool still hash the whole file: several chunks plus a partial one.
    @Test func hashingSpansChunks() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data((0..<(2_500_000)).map { UInt8($0 % 251) })
        let a = try file("a.mov", data)
        #expect(try DuplicateFinder.sha256(of: a) == Data(SHA256.hash(data: data)))
        #expect(try DuplicateFinder.sha256(of: try file("empty.mov", Data())) == Data(SHA256.hash(data: Data())))
    }

    @Test func hashingKeepsTheAccessDate() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try file("a.mov", Data(repeating: 1, count: 1_000))
        let old = Date(timeIntervalSince1970: 1_500_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: a.path) // atime ≤ mtime: a read would move it
        var times = [timeval(tv_sec: 1_400_000_000, tv_usec: 0), timeval(tv_sec: 1_500_000_000, tv_usec: 0)]
        #expect(utimes(a.path, &times) == 0)
        #expect(try DuplicateFinder.sha256(of: a) != nil)
        let accessed = try a.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate
        #expect(accessed == Date(timeIntervalSince1970: 1_400_000_000))
    }

    /// Same-size files whose first 64 KB differ are never read in full; progress still reaches 1, also past an
    /// unreadable file, and never goes back.
    @Test func differentHeadsAreNotReadInFullAndProgressCompletes() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let content = Data((0..<300_000).map { UInt8($0 % 251) })
        var other = content
        other[0] ^= 0xFF
        let a = try file("a.mov", content), b = try file("b.mov", content), c = try file("c.mov", other)
        let d = try file("d.mov", Data(repeating: 1, count: 200_000)), e = try file("e.mov", Data(repeating: 2, count: 200_000))
        let locked = try file("f.mov", Data(repeating: 1, count: 200_000))
        #expect(chmod(locked.path, 0) == 0)
        let fractions = Locked<[Double]>([])
        let result = try await DuplicateFinder.find([a, b, c, d, e, locked]) { p in fractions.withLock { $0.append(p.fraction) } }
        #expect(result.groups == [[a, b]])
        #expect(result.hashedCount == 2) // a and b; c, d, e ruled out by their head, f unreadable
        let seen = fractions.withLock { $0 }
        #expect(seen.first == 0 && seen.last == 1 && seen == seen.sorted())
    }

    /// Same-size files whose first 64 KB match but whose last 64 KB differ are not read in full either.
    @Test func differentTailsAreNotReadInFull() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let content = Data((0..<1_500_000).map { UInt8($0 % 251) })
        var other = content
        other[other.count - 1] ^= 0xFF
        let a = try file("a.mov", content), b = try file("b.mov", other)
        let result = try await DuplicateFinder.find([a, b])
        #expect(result.groups.isEmpty && result.hashedCount == 0)
        let same = try await DuplicateFinder.find([a, b, try file("c.mov", content)])
        #expect(same.groups == [[a, root.appending(path: "c.mov")]] && same.hashedCount == 2)
    }

    /// A stop keeps the groups of the sizes compared before it (the largest first), with what they free.
    @Test func cancelledKeepsTheGroupsFoundSoFar() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let big = Data(repeating: 4, count: 3_000_000), small = Data(repeating: 5, count: 2_000_000)
        let (a1, a2) = (try file("a1.mov", big), try file("a2.mov", big))
        let (b1, b2) = (try file("b1.mov", small), try file("b2.mov", small))
        let task = Task {
            try await DuplicateFinder.find([b1, a1, b2, a2]) { p in
                if p.done > 6_000_000 { withUnsafeCurrentTask { $0?.cancel() } } // a1 and a2 hashed, b1 started
            }
        }
        do { _ = try await task.value; Issue.record("not cancelled") } catch let cancelled as DuplicateFinder.Cancelled {
            #expect(cancelled.groups == [[a1, a2]] && cancelled.privateSizes.isEmpty)
        }
    }

    /// Cancelling while a big file is being hashed stops at the next 1 MB chunk, and no result (no hash) comes back.
    @Test func cancelledMidFileStopsAtTheNextChunk() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let content = Data(repeating: 9, count: 8_000_000)
        let urls = [try file("a.mov", content), try file("b.mov", content)]
        let reports = Locked(0)
        let task = Task {
            try await DuplicateFinder.find(urls) { p in
                reports.withLock { $0 += 1 }
                if p.done > 0 { withUnsafeCurrentTask { $0?.cancel() } } // 1 MB of a.mov read
            }
        }
        await #expect(throws: DuplicateFinder.Cancelled.self) { try await task.value }
        #expect(reports.withLock { $0 } == 2) // the start (nothing compared yet), then the first chunk
    }

    @Test func canBeCancelled() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let content = Data(repeating: 3, count: 1_000)
        let urls = [try file("a", content), try file("b", content)]
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DuplicateFinder.find(urls)
        }
        await #expect(throws: DuplicateFinder.Cancelled.self) { try await task.value }
    }

    /// Cancelling keeps full hashes finished before the stop (not the half-read file nor head hashes); the next
    /// run reads only the unfinished file.
    @Test func cancelledKeepsFinishedFullHashes() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let content = Data((0..<2_000_000).map { UInt8($0 % 251) }) // 2 chunks each, heads all equal
        let urls = try ["a.mov", "b.mov", "c.mov"].map { try file($0, content) }
        let task = Task {
            try await DuplicateFinder.find(urls) { p in
                if p.fraction > 0.7 { withUnsafeCurrentTask { $0?.cancel() } } // 5/6: first chunk of c.mov read
            }
        }
        var kept: [DuplicateFinder.Key: Data] = [:]
        do { _ = try await task.value; Issue.record("not cancelled") } catch let cancelled as DuplicateFinder.Cancelled {
            kept = cancelled.hashes
        }
        #expect(kept.keys.map(\.path).sorted() == urls.prefix(2).map(\.path))
        #expect(kept.values.allSatisfy { $0 == kept.values.first && $0.count == 32 })
        let rerun = try await DuplicateFinder.find(urls, cache: kept)
        #expect(rerun.hashedCount == 1)
        #expect(rerun.groups == [urls])
    }
}

@Test func largeFilesProgressFractionNeedsAnEstimateAndStopsAt99Percent() {
    #expect(LargeFilesModel.fraction(checked: 500, estimate: 0) == nil)
    #expect(LargeFilesModel.fraction(checked: 250, estimate: 1_000) == 0.25)
    #expect(LargeFilesModel.fraction(checked: 1_000, estimate: 1_000) == 0.99)
    #expect(LargeFilesModel.fraction(checked: 5_000, estimate: 1_000) == 0.99)
}

/// Last Used: whole months from the menu, or a typed number of days.
@Test func lastUsedFilterTakesMonthsOrDays() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let calendar = Calendar(identifier: .gregorian)
    #expect(LargeFilesModel.UnusedFor.anyTime.cutoff(from: now) == nil)
    #expect(LargeFilesModel.UnusedFor.days(10).cutoff(from: now, calendar: calendar) == now.addingTimeInterval(-10 * 86_400))
    #expect(LargeFilesModel.UnusedFor.months(1).cutoff(from: now, calendar: calendar)
            == calendar.date(byAdding: .month, value: -1, to: now))
    #expect(LargeFilesModel.ageOptions.first == 1)

    let model = LargeFilesModel()
    let day: TimeInterval = 86_400
    let files = [5, 20, 40].map { LargeFile(url: URL(fileURLWithPath: "/f\($0)"), size: 100_000_000,
                                           lastUsed: .now.addingTimeInterval(-Double($0) * day), kind: .other) }
    model.files = files
    model.unusedFor = .days(10)
    #expect(model.visibleFiles.map(\.name) == ["f20", "f40"])
    model.unusedFor = .months(1)
    #expect(model.visibleFiles.map(\.name) == ["f40"])
}

/// Select All/Deselect All touch only the files the filters show.
@Test func selectAllActsOnShownFilesOnly() {
    let model = LargeFilesModel()
    let video = LargeFile(url: URL(fileURLWithPath: "/v.mov"), size: 100_000_000, lastUsed: .now, kind: .video)
    let zip = LargeFile(url: URL(fileURLWithPath: "/a.zip"), size: 100_000_000, lastUsed: .now, kind: .archive)
    let hiddenTicked = LargeFile(url: URL(fileURLWithPath: "/b.zip"), size: 100_000_000, lastUsed: .now, kind: .archive)
    model.files = [video, zip, hiddenTicked]
    model.checked = [hiddenTicked.url]
    model.kind = .video
    #expect(!model.allVisibleChecked)
    model.setVisibleChecked(true)
    #expect(model.checked == [video.url, hiddenTicked.url] && model.allVisibleChecked) // the hidden zip is not ticked
    model.setVisibleChecked(false)
    #expect(model.checked == [hiddenTicked.url] && !model.allVisibleChecked) // a hidden tick stays, still never trashed
    #expect(model.checkedFiles.isEmpty)
    model.kind = .installer // nothing shown
    #expect(!model.allVisibleChecked)
}

/// The toolbar search matches name or location, case/diacritic-insensitively, with the other filters and Select All.
@Test func searchFiltersByNameOrLocation() {
    let home = URL(fileURLWithPath: "/Users/me")
    let model = LargeFilesModel()
    let movie = LargeFile(url: URL(fileURLWithPath: "/Users/me/Movies/Hè.mov"), size: 100_000_000, lastUsed: .now, kind: .video, home: home)
    let zip = LargeFile(url: URL(fileURLWithPath: "/Users/me/Downloads/he-backup.zip"), size: 100_000_000, lastUsed: .now, kind: .archive, home: home)
    let other = LargeFile(url: URL(fileURLWithPath: "/Users/me/Downloads/x.dmg"), size: 100_000_000, lastUsed: .now, kind: .diskImage, home: home)
    model.files = [movie, zip, other]
    model.search = "HE"
    #expect(Set(model.visibleFiles.map(\.url)) == [movie.url, zip.url])
    model.kind = .archive
    #expect(model.visibleFiles.map(\.url) == [zip.url])
    model.kind = nil
    model.search = " downloads "
    #expect(Set(model.visibleFiles.map(\.url)) == [zip.url, other.url])
    model.search = "x.dmg"
    model.setVisibleChecked(true)
    #expect(model.checked == [other.url] && model.checkedFiles.map(\.url) == [other.url])
    model.search = "zzz"
    #expect(model.visibleFiles.isEmpty && model.checkedFiles.isEmpty && !model.allVisibleChecked)
    model.search = ""
    #expect(model.visibleFiles.count == 3)
}

/// Rank-based sort gives exactly the order of `sorted(using:)` with `localizedStandardCompare`, ties included.
@Test func rankedSortMatchesLocalizedStandardOrder() {
    let names = ["file10.mov", "file2.mov", "File2.mov", "file1.mov", "Ảnh.jpg", "anh.jpg", "Anh 2.jpg", "đĩa.dmg", "dia.dmg",
                 "Zebra.zip", "zebra.zip", "éclair.iso", "eclair.iso", "１２.bin", "12.bin", "a b.mov", "a-b.mov", "_x.pkg", "Ô tô.mp4"]
    let folders = ["~/Tài liệu", "~/Tai lieu", "~/Downloads", "~/downloads", "~/Dự án 10", "~/Dự án 9", "~"]
    let model = LargeFilesModel()
    model.files = names.enumerated().flatMap { i, name in
        folders.enumerated().map { j, folder in
            LargeFile(url: URL(fileURLWithPath: "/h/\(folder.dropFirst())/\(name)"), size: Int64((i * 7 + j * 3) % 5), lastUsed: .now,
                      kind: .other, home: URL(fileURLWithPath: "/h"))
        }
    }
    let orders: [[KeyPathComparator<LargeFile>]] = [
        [KeyPathComparator(\.name)], [KeyPathComparator(\.name, order: .reverse)],
        [KeyPathComparator(\.location)], [KeyPathComparator(\.location, order: .reverse)],
        [KeyPathComparator(\.name), KeyPathComparator(\.size, order: .reverse)],
        [KeyPathComparator(\.size), KeyPathComparator(\.location, order: .reverse), KeyPathComparator(\.name)],
        [KeyPathComparator(\.size, order: .reverse)],
    ]
    for order in orders {
        #expect(model.sorted(model.files, using: order).map(\.url) == model.files.sorted(using: order).map(\.url))
        let subset = model.files.filter { $0.size > 1 } // filtered view keeps the same order
        #expect(model.sorted(subset, using: order).map(\.url) == subset.sorted(using: order).map(\.url))
    }
}

/// Hashes persist across launches: a new model reads nothing again; a changed date or a corrupt cache file → read again.
@MainActor @Test func duplicateHashesPersistAcrossModels() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "CleanMateHashCache-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let content = Data(repeating: 7, count: 2_000)
    let (a, b) = (root.appending(path: "a.mov"), root.appending(path: "b.mov"))
    try content.write(to: a); try content.write(to: b)
    let cacheURL = root.appending(path: "Caches/hashes.json") // folder created on save
    func run() async -> Int {
        let model = DuplicatesModel()
        model.cacheURL = cacheURL
        let read = Counter()
        model.findDuplicates = { _, _, _, _, cache, _ in
            let result = try await DuplicateFinder.find([a, b], cache: cache)
            await read.add(result.hashedCount)
            let files = [a, b].map { LargeFile(url: $0, size: 2_000, lastUsed: .now, kind: .other) }
            return DuplicateScanner.Result(groups: result.groups.map { _ in DuplicateScanner.Group(files: files, privateSizes: [:]) },
                                           hashes: result.hashes)
        }
        model.find(in: root, policy: SafetyPolicy(home: root, temp: root.appending(path: "tmp")), skipping: [])
        await until(model) { if case .results = $0.phase { true } else { false } }
        #expect(model.groups.map { $0.files.map(\.url) } == [[a, b]])
        return await read.value
    }
    #expect(await run() == 2)
    #expect(await run() == 0) // new model, same files: answered from hashes.json
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_500_000_000)], ofItemAtPath: a.path)
    #expect(await run() == 1)
    try Data("not json".utf8).write(to: cacheURL)
    #expect(await run() == 2)
    #expect(await run() == 0) // rewritten after the corrupt file was ignored
}

private actor Counter {
    var value = 0
    func add(_ n: Int) { value += n }
}

/// Saving drops gone files and keeps only the most recently modified past the limit.
@Test func hashCacheDropsGoneFilesAndOldest() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "CleanMateHashCache-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var hashes: [DuplicateFinder.Key: Data] = [:]
    for (i, name) in ["old", "new"].enumerated() {
        let url = root.appending(path: name)
        try Data(count: 10).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(1_000_000_000 + i))], ofItemAtPath: url.path)
        var info = stat()
        lstat(url.path, &info)
        hashes[.init(path: url.path, size: 10, modified: Date(timeIntervalSince1970: Double(1_000_000_000 + i)), inode: info.st_ino)] = Data(repeating: UInt8(i), count: 32)
    }
    hashes[.init(path: root.appending(path: "gone").path, size: 10, modified: .now, inode: 1)] = Data(repeating: 9, count: 32)
    let url = root.appending(path: "hashes.json")
    await DuplicateFinder.HashCache.save(hashes, to: url, limit: 1)
    #expect(await DuplicateFinder.HashCache.load(from: url).keys.map(\.path) == [root.appending(path: "new").path])
    // A value that is no SHA-256 (hand-edited or another format) is ignored on load, so it can't match another file.
    let newKey = try #require(hashes.keys.first { $0.path.hasSuffix("/new") })
    try JSONEncoder().encode([newKey: Data([1])]).write(to: url)
    #expect(await DuplicateFinder.HashCache.load(from: url).isEmpty)
}

private func hashKey(_ url: URL) -> DuplicateFinder.Key {
    var info = stat()
    lstat(url.path, &info)
    return .init(path: url.path, size: info.st_size,
                 modified: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9),
                 inode: info.st_ino)
}

/// Saves merge into the file instead of replacing it, also when two run at once; a non-SHA-256 value is never written.
@Test func hashCacheSavesMergeEvenWhenConcurrent() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "CleanMateHashCache-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let keys = try (0..<40).map { i in
        let url = root.appending(path: "f\(i)")
        try Data([UInt8(i)]).write(to: url)
        return hashKey(url)
    }
    let url = root.appending(path: "hashes.json")
    await DuplicateFinder.HashCache.save([keys[0]: Data(repeating: 0, count: 32)], to: url)
    await DuplicateFinder.HashCache.save([keys[1]: Data(repeating: 1, count: 32), keys[2]: Data([2])], to: url)
    #expect(Set(await DuplicateFinder.HashCache.load(from: url).keys) == [keys[0], keys[1]])
    // Each of 38 saves at once carries one key: every key must survive whatever order they run in.
    await withTaskGroup(of: Void.self) { group in
        for (i, key) in keys.enumerated().dropFirst(2) {
            group.addTask { await DuplicateFinder.HashCache.save([key: Data(repeating: UInt8(i), count: 32)], to: url) }
        }
    }
    #expect(Set(await DuplicateFinder.HashCache.load(from: url).keys) == Set(keys))
}

/// Stopping a search saves the full hashes it finished next to what the cache already held.
@MainActor @Test func stoppedDuplicateSearchSavesFinishedHashes() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "CleanMateHashCache-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let (a, b, old) = (root.appending(path: "a.mov"), root.appending(path: "b.mov"), root.appending(path: "old.mov"))
    for url in [a, b, old] { try Data(repeating: 7, count: 2_000).write(to: url) }
    let cacheURL = root.appending(path: "Caches/hashes.json")
    await DuplicateFinder.HashCache.save([hashKey(old): Data(repeating: 3, count: 32)], to: cacheURL)
    let model = DuplicatesModel()
    model.cacheURL = cacheURL
    let started = Counter()
    model.findDuplicates = { _, _, _, _, cache, progress in
        progress(.comparing(.init(done: 0, total: 4_000)))
        await started.add(1)
        while !Task.isCancelled { await Task.yield() }
        // a.mov finished before the stop; b.mov's value is a partial (non-SHA-256) one that must not be saved.
        return DuplicateScanner.Result(hashes: cache.merging([hashKey(a): Data(repeating: 1, count: 32), hashKey(b): Data([9])]) { $1 },
                                       stopped: true)
    }
    model.find(in: root, policy: SafetyPolicy(home: root, temp: root.appending(path: "tmp")), skipping: [])
    while await started.value == 0 { await Task.yield() }
    await until(model) { if case .comparing = $0.phase { true } else { false } }
    model.stop()
    await until(model) { if case .results = $0.phase { true } else { false } }
    #expect(model.stopped && model.groups.isEmpty)
    // The stopped task saves on its own; wait for the file to change, bounded so a regression fails instead of hanging.
    var saved: [DuplicateFinder.Key: Data] = [:]
    try await eventually("the stopped task saves its cache", timeout: .seconds(60)) {
        saved = await DuplicateFinder.HashCache.load(from: cacheURL)
        return saved[hashKey(a)] != nil
    }
    #expect(Set(saved.keys) == [hashKey(old), hashKey(a)])
}
