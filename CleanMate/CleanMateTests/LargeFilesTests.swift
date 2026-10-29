import Combine
import CryptoKit
import Foundation
import Testing
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
        ("Setup.dmg", .installer), ("x.pkg", .installer), ("x.pdf", .other), ("noext", .other),
    ])
    func classifiesByExtension(name: String, kind: FileKind) {
        #expect(FileKind(fileExtension: (name as NSString).pathExtension) == kind)
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
        let suite = "CleanMateTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = LargeFilesModel()
        #expect(model.lastCountDefaults == nil) // test host: never the real preferences
        model.lastCountDefaults = defaults
        model.home = home
        var access = true
        model.hasFullDiskAccess = { access }
        let roots = Roots()
        model.scanFiles = { root, _, _, _ in await roots.add(root); return [] }
        func scanned() async throws {
            for _ in 0..<3000 { if case .results = model.phase { return }; try await Task.sleep(for: .milliseconds(10)) }
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

    /// Under a test host a finished scan keeps its count in memory only: the real preferences stay untouched.
    @MainActor @Test func finishedScanNeverWritesTheRealPreferencesInTests() async throws {
        let before = UserDefaults.standard.dictionary(forKey: Preferences.largeFilesLastCount) as? [String: Int]
        let model = LargeFilesModel()
        model.home = home
        model.hasFullDiskAccess = { true }
        model.scanFiles = { _, _, _, progress in
            progress(700)
            try await Task.sleep(for: .milliseconds(100)) // the count reaches the model on the main actor
            return []
        }
        model.scan()
        for _ in 0..<3000 { if case .results = model.phase { break }; try await Task.sleep(for: .milliseconds(10)) }
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
            try await Task.sleep(for: LargeFilesModel.progressInterval * 2)
            progress(500_500) // the next interval: shown again
            try await Task.sleep(for: .milliseconds(100)) // the count reaches the model on the main actor
            return []
        }
        var shown: [Int] = []
        let subscription = model.$scannedCount.dropFirst().sink { shown.append($0) }
        defer { subscription.cancel() }
        model.scan()
        for _ in 0..<3000 { if case .results = model.phase { break }; try await Task.sleep(for: .milliseconds(10)) }
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
            for _ in 0..<3000 { if case .results = model.phase { return }; try await Task.sleep(for: .milliseconds(10)) }
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
            if root.lastPathComponent != "Projects" { try await Task.sleep(for: .seconds(60)) } // until stopped
            return []
        }
        func settled() async throws {
            for _ in 0..<3000 { if case .results = model.phase { return }; try await Task.sleep(for: .milliseconds(10)) }
        }
        model.setScope(projects)
        try await settled()
        model.setScope(home) // whole home: blocks
        #expect(model.scope == nil)
        model.cancel()
        try await settled()
        #expect(model.scope == projects && model.scopeName == "~/Projects")
        model.scanFiles = { _, _, _, _ in try await Task.sleep(for: .seconds(60)); return [] }
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
        #expect(result.hashedCount == 3) // a, b, c; the hard link and the unique size are never read
        // Second run answers from the cache, and a changed file is read again.
        #expect(try await DuplicateFinder.find([a, b, c], cache: result.hashes).hashedCount == 0)
        try other.write(to: b)
        let changed = try await DuplicateFinder.find([a, b, c], cache: result.hashes)
        #expect(changed.groups == [[b, c]] && changed.hashedCount == 1) // only b is read again
    }

    @Test func onlyHardLinksAreNotDuplicates() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try file("a.zip", Data(repeating: 7, count: 1_000))
        let link = root.appending(path: "b.zip")
        try FileManager.default.linkItem(at: a, to: link)
        let result = try await DuplicateFinder.find([a, link])
        #expect(result.groups.isEmpty && result.hashedCount == 0)
    }

    /// Whole-file APFS clones share their blocks, so trashing one frees nothing; a plain copy or a changed clone does.
    @Test func apfsClonesAreNotDuplicates() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try file("a.mov", Data(repeating: 7, count: 100_000))
        let clone = root.appending(path: "b.mov"), changed = root.appending(path: "d.mov")
        #expect(clonefile(a.path, clone.path, 0) == 0)
        let copy = try file("c.mov", Data(contentsOf: a)) // plain write: own blocks
        #expect(DuplicateFinder.cloneID(of: a) != nil && DuplicateFinder.cloneID(of: a) == DuplicateFinder.cloneID(of: clone))
        #expect(DuplicateFinder.cloneID(of: copy) == nil)
        #expect(try await DuplicateFinder.find([a, clone, copy]).groups == [[a, copy]])
        // A clone written to after cloning only may share blocks: still a duplicate.
        #expect(clonefile(a.path, changed.path, 0) == 0)
        let handle = try FileHandle(forWritingTo: changed)
        try handle.seek(toOffset: 50); try handle.write(contentsOf: Data([7])); try handle.close()
        #expect(DuplicateFinder.cloneID(of: changed) == nil)
        #expect(try await DuplicateFinder.find([a, changed]).groups == [[a, changed]])
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
        let result = try await DuplicateFinder.find([a, b, c, d, e, locked]) { f in fractions.withLock { $0.append(f) } }
        #expect(result.groups == [[a, b]])
        #expect(result.hashedCount == 2) // a and b; c, d, e ruled out by their head, f unreadable
        let seen = fractions.withLock { $0 }
        #expect(seen.last == 1 && seen == seen.sorted())
    }

    /// Cancelling while a big file is being hashed stops at the next 1 MB chunk, and no result (no hash) comes back.
    @Test func cancelledMidFileStopsAtTheNextChunk() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let content = Data(repeating: 9, count: 8_000_000)
        let urls = [try file("a.mov", content), try file("b.mov", content)]
        let reports = Locked(0)
        let task = Task {
            try await DuplicateFinder.find(urls) { _ in
                reports.withLock { $0 += 1 }
                withUnsafeCurrentTask { $0?.cancel() } // first report: 1 MB of a.mov read
            }
        }
        await #expect(throws: DuplicateFinder.Cancelled.self) { try await task.value }
        #expect(reports.withLock { $0 } == 1)
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
            try await DuplicateFinder.find(urls) { fraction in
                if fraction > 0.7 { withUnsafeCurrentTask { $0?.cancel() } } // 5/6: first chunk of c.mov read
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

/// The duplicates filter shows only grouped files, keeps groups together and works with Select All.
@MainActor @Test func duplicatesFilterShowsGroupsTogether() async throws {
    let model = LargeFilesModel()
    let f = { (path: String, size: Int64) in LargeFile(url: URL(fileURLWithPath: path), size: size, lastUsed: .now, kind: .other) }
    let (a1, a2, b1, b2, lone) = (f("/a1", 300_000_000), f("/z/a2", 300_000_000), f("/b1", 200_000_000), f("/b2", 200_000_000), f("/lone", 999_000_000))
    model.files = [lone, a1, a2, b1, b2]
    model.phase = .results
    model.findDuplicateFiles = { urls, _, _ in
        #expect(urls.count == 5)
        return DuplicateFinder.Result(groups: [[a1.url, a2.url], [b1.url, b2.url]])
    }
    model.duplicatesOnly = true
    while model.duplicateGroups == nil { await Task.yield() }
    #expect(model.duplicateProgress == nil)
    #expect(Set(model.visibleFiles.map(\.url)) == [a1.url, a2.url, b1.url, b2.url])
    #expect(model.duplicateCount(of: a1.url) == 2 && model.duplicateCount(of: lone.url) == nil)
    let byName = [a1, b1, b2, a2].sorted { $0.url.path < $1.url.path } // /a1 /b1 /b2 /z/a2: a group split by sorting
    #expect(model.groupedByDuplicates(byName).map(\.url) == [a1.url, a2.url, b1.url, b2.url])
    #expect(model.checked.isEmpty) // nothing ticked for the user
    model.setVisibleChecked(true)
    #expect(model.checked.count == 4)
    model.duplicatesOnly = false
    #expect(model.visibleFiles.count == 5)
}

/// Select Extra Copies keeps one copy per group: oldest modified, tie → shortest path, counted over hidden copies too;
/// trashing every copy of a group is flagged for the confirmation.
@Test func selectExtraCopiesKeepsTheOldestCopyOfEachGroup() {
    let model = LargeFilesModel()
    let day: TimeInterval = 86_400
    let f = { (path: String, age: Double, kind: FileKind) in
        LargeFile(url: URL(fileURLWithPath: path), size: 100_000_000, lastUsed: .now, kind: kind, modified: .now.addingTimeInterval(-age * day))
    }
    // a: /x/a-old is the oldest. b: same date, /b shortest path. c: the oldest copy is a zip, hidden by the kind filter.
    let (aNew, aOld, b, bLong, cOld, cNew) = (f("/a-new", 1, .other), f("/x/a-old", 9, .other), f("/b", 5, .other),
                                             f("/long/b", 5, .other), f("/c.zip", 9, .archive), f("/c2", 1, .other))
    model.files = [aNew, aOld, b, bLong, cOld, cNew]
    model.duplicateGroups = [[aNew.url, aOld.url], [bLong.url, b.url], [cNew.url, cOld.url]]
    model.duplicatesOnly = true
    model.phase = .results
    #expect(model.keptCopies == [aOld.url, b.url, cOld.url])
    model.kind = .other
    model.checkExtraCopies()
    #expect(model.checked == [aNew.url, bLong.url, cNew.url]) // c's kept copy is hidden, so its shown copy goes
    #expect(model.groupsLosingEveryCopy.isEmpty)
    model.checked.insert(aOld.url)
    #expect(model.groupsLosingEveryCopy == ["a-old"])
    model.setVisibleChecked(false)
    #expect(model.checked.isEmpty)
}

/// Select Extra Copies leaves exactly one copy per group even when the kept copy was ticked while a filter hid it;
/// with the Duplicates filter off, Select All on every copy still gets the warning.
@Test func extraCopiesUntickKeptCopyAndLosingEveryCopyWarnsWithFilterOff() {
    let model = LargeFilesModel()
    let f = { (path: String, age: Double) in
        LargeFile(url: URL(fileURLWithPath: path), size: 100_000_000, lastUsed: .now, kind: .other, modified: .now.addingTimeInterval(-age))
    }
    let (old, new) = (f("/keep-old", 9), f("/new", 1))
    model.files = [old, new]
    model.duplicateGroups = [[new.url, old.url]]
    model.phase = .results
    model.setVisibleChecked(true) // filter off: every copy ticked
    #expect(model.groupsLosingEveryCopy == ["keep-old"])
    model.duplicatesOnly = true
    model.search = "keep" // kept copy shown and ticked; then hidden by the search
    model.search = "new"
    model.setVisibleChecked(false)
    #expect(model.checked == [old.url])
    model.checkExtraCopies()
    model.search = ""
    #expect(model.checked == [new.url])
    #expect(model.groupsLosingEveryCopy.isEmpty)
}

@Test func largeFilesProgressFractionNeedsAnEstimateAndStopsAt99Percent() {
    #expect(LargeFilesModel.fraction(checked: 500, estimate: 0) == nil)
    #expect(LargeFilesModel.fraction(checked: 250, estimate: 1_000) == 0.25)
    #expect(LargeFilesModel.fraction(checked: 1_000, estimate: 1_000) == 0.99)
    #expect(LargeFilesModel.fraction(checked: 5_000, estimate: 1_000) == 0.99)
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
        let model = LargeFilesModel()
        model.hashCacheURL = cacheURL
        model.files = [a, b].map { LargeFile(url: $0, size: 2_000, lastUsed: .now, kind: .other) }
        model.phase = .results
        let read = Counter()
        model.findDuplicateFiles = { urls, cache, progress in
            let result = try await DuplicateFinder.find(urls, cache: cache, progress: progress)
            await read.add(result.hashedCount)
            return result
        }
        model.duplicatesOnly = true
        while model.duplicateGroups == nil { await Task.yield() }
        #expect(model.duplicateGroups == [[a, b]])
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
    let model = LargeFilesModel()
    model.hashCacheURL = cacheURL
    model.files = [a, b].map { LargeFile(url: $0, size: 2_000, lastUsed: .now, kind: .other) }
    model.phase = .results
    let started = Counter()
    model.findDuplicateFiles = { _, cache, _ in
        await started.add(1)
        while !Task.isCancelled { await Task.yield() }
        // a.mov finished before the stop; b.mov's value is a partial (non-SHA-256) one that must not be saved.
        throw DuplicateFinder.Cancelled(hashes: cache.merging([hashKey(a): Data(repeating: 1, count: 32), hashKey(b): Data([9])]) { $1 })
    }
    model.duplicatesOnly = true
    while await started.value == 0 { await Task.yield() }
    model.duplicatesOnly = false
    #expect(model.duplicateProgress == nil && model.duplicateGroups == nil)
    // The stopped task saves on its own; wait for the file to change, bounded so a regression fails instead of hanging.
    var saved: [DuplicateFinder.Key: Data] = [:]
    for _ in 0..<1_000 {
        saved = await DuplicateFinder.HashCache.load(from: cacheURL)
        if saved[hashKey(a)] != nil { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(Set(saved.keys) == [hashKey(old), hashKey(a)])
}
