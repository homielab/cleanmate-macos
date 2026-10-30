import Foundation
import Testing
@testable import CleanMate

/// conda / mamba package archives and the Dart / Flutter pub cache in Developer Junk, in a throwaway fake home.
struct PackageCacheItemsTests {
    private struct Home {
        let root = FileManager.default.temporaryDirectory.appending(path: "CleanMatePkgCache-\(UUID().uuidString)")
        var home: URL { root.appending(path: "home") }
        var policy: SafetyPolicy { SafetyPolicy(home: home, temp: root.appending(path: "tmp")) }

        init() throws {
            for dir in ["home", "tmp"] { try FileManager.default.createDirectory(at: root.appending(path: dir), withIntermediateDirectories: true) }
        }

        @discardableResult
        func file(_ path: String, _ data: Data = Data(repeating: 1, count: 40_000)) throws -> URL {
            let url = home.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            return url
        }

        func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: home.appending(path: path).path) }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private func item(_ id: String) throws -> CleanerItem { try #require(CleanerGroup.developer.items.first { $0.id == id }) }

    @Test func catalogItems() throws {
        let conda = try item("conda-cache"), pub = try item("pub-cache")
        for item in [conda, pub] {
            #expect(!item.selectedByDefault && item.skipsOpenFiles && !item.showsWhenEmpty && item.mode == .delete)
            #expect(item.command == nil && item.probe == nil)
        }
        #expect(conda.runningProcessNames == ["conda", "mamba", "micromamba"] && conda.configFolders != nil)
        #expect(pub.runningProcessNames == ["dart", "flutter"] && pub.shellFolders == ["PUB_CACHE": ["hosted", "git/cache"]])
        #expect(pub.paths == ["~/.pub-cache/hosted", "~/.pub-cache/git/cache"])
    }

    /// Only archives and the index cache: unpacked packages, `envs/` and other files stay; `pkgs_dirs` adds a folder.
    @Test func condaListsArchivesAndIndexOnly() async throws {
        let box = try Home()
        defer { box.remove() }
        let item = try item("conda-cache")
        let listed = try [
            "miniforge3/pkgs/numpy-2.0-py312.conda", "miniforge3/pkgs/zlib-1.3.tar.bz2", "miniforge3/pkgs/cache/abc.json",
            "extra/pkgs/old-1.0.tar.bz2",
        ].map { try box.file($0) }
        let kept = ["miniforge3/pkgs/numpy-2.0-py312/lib/libnumpy.dylib", "miniforge3/pkgs/urls.txt", "miniforge3/envs/ml/bin/python",
                    "miniforge3/bin/conda", "miniconda3/pkgs/zlib-1.3/info/index.json"]
        for path in kept { try box.file(path) }
        try box.file(".condarc", Data("channels:\n  - defaults\npkgs_dirs:\n  - ~/extra/pkgs # mine\n  - /Volumes/x/pkgs\nenvs_dirs:\n  - ~/envs\n".utf8))

        let scan = await Scanner.scan(item, policy: box.policy)
        // The index cache is listed as its `cache` folder.
        let expected = listed.map { $0.lastPathComponent == "abc.json" ? $0.deletingLastPathComponent() : $0 }
        #expect(scan.entries.map(\.url.standardizedFileURL.path).sorted() == expected.map(\.standardizedFileURL.path).sorted())
        let report = await Cleaner.clean(item, scan: scan, policy: box.policy)
        #expect(report.skipped == 0)
        #expect(listed.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(kept.allSatisfy(box.exists) && box.exists(".condarc"))
    }

    @Test func condarcParsing() {
        let home = URL(fileURLWithPath: "/Users/u")
        #expect(CondaPackages.pkgsDirs(in: "pkgs_dirs: ['~/a', \"/b\"]\n", home: home) == ["/Users/u/a", "/b"])
        #expect(CondaPackages.pkgsDirs(in: "# pkgs_dirs:\n  pkgs_dirs:\n    - /nope\nother:\n  - /no\n", home: home).isEmpty)
        #expect(CondaPackages.pkgsDirs(in: "pkgs_dirs:\n  - /x\n\n  # c\n  - '/y'\nchannels:\n  - /z\n", home: home) == ["/x", "/y"])
    }

    /// `hosted` and `git/cache` only (also under `PUB_CACHE`); credentials, `bin/` and checked-out git packages stay.
    @Test func pubListsHostedAndGitCacheOnly() async throws {
        let box = try Home()
        defer { box.remove() }
        let item = try item("pub-cache")
        let listed = try ["hosted/pub.dev/http-1.2.0/lib/http.dart", "git/cache/pkg-abc/HEAD"].map { try box.file(".pub-cache/" + $0) }
        let kept = [".pub-cache/credentials.json", ".pub-cache/bin/melos", ".pub-cache/git/pkg-abc/lib/p.dart", ".pub-cache/hosted-hashes/x"]
        for path in kept { try box.file(path) }
        let scan = await Scanner.scan(item, policy: box.policy)
        let paths = scan.entries.map(\.url.standardizedFileURL.path)
        #expect(paths.count == 2 && paths.contains { $0.hasSuffix("/hosted/pub.dev") } && paths.contains { $0.hasSuffix("/git/cache/pkg-abc") })
        let report = await Cleaner.clean(item, scan: scan, policy: box.policy)
        #expect(report.skipped == 0)
        #expect(listed.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(kept.allSatisfy(box.exists))
    }

    /// Locked and not ticked while the tool runs.
    @MainActor @Test func lockedWhileToolRuns() throws {
        let model = SmartScanModel(module: .smartScan) { [] }
        model.runningProcesses = ["zsh"]
        #expect(try !model.isRunning(item("conda-cache")) && !model.isRunning(item("pub-cache")))
        model.runningProcesses = ["micromamba"]
        #expect(try model.isRunning(item("conda-cache")) && !model.isRunning(item("pub-cache")))
        model.runningProcesses = ["flutter"]
        #expect(try !model.isRunning(item("conda-cache")) && model.isRunning(item("pub-cache")))
    }
}
