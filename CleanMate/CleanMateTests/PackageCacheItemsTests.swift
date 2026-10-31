import Foundation
import Testing
@testable import CleanMate

/// conda / mamba package archives, the Dart / Flutter pub cache and build tool caches (Deno, Zig, Bazel, ccache,
/// sccache, NuGet, Poetry, pre-commit, pipx) in Developer Junk, in a throwaway fake home.
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

    static let buildTools: [(id: String, paths: [String], shell: [String: [String]], processes: [String])] = [
        ("deno-cache", ["~/Library/Caches/deno"], ["DENO_DIR": ["remote", "npm", "gen", "registries", "dl", "deps"]], ["deno"]),
        ("poetry-cache", ["~/Library/Caches/pypoetry/cache", "~/Library/Caches/pypoetry/artifacts"],
         ["POETRY_CACHE_DIR": ["cache", "artifacts"]], ["poetry"]),
        ("pipx-cache", ["~/Library/Caches/pipx", "~/.local/pipx/.cache", "~/.cache/pipx"],
         ["PIPX_HOME": [".cache"], "XDG_CACHE_HOME": ["pipx"]], ["pipx"]),
        ("pre-commit-cache", ["~/.cache/pre-commit"], ["PRE_COMMIT_HOME": [""], "XDG_CACHE_HOME": ["pre-commit"]], ["pre-commit"]),
        ("zig-cache", ["~/.cache/zig"], ["ZIG_GLOBAL_CACHE_DIR": ["o", "h", "z", "p", "tmp"], "XDG_CACHE_HOME": ["zig"]], ["zig", "zls"]),
        ("bazel-cache", ["~/.cache/bazel/_bazel_*/cache", "~/.cache/bazel/_bazel_*/install"], [:], ["bazel*", "bazelisk"]),
        ("ccache-cache", ["~/Library/Caches/ccache", "~/.ccache", "~/.cache/ccache"],
         ["CCACHE_DIR": [""], "XDG_CACHE_HOME": ["ccache"]], ["ccache"]),
        ("sccache-cache", ["~/Library/Caches/Mozilla.sccache"], ["SCCACHE_DIR": [""]], ["sccache"]),
        ("nuget-cache", ["~/.local/share/NuGet/v3-cache", "~/.local/share/NuGet/http-cache", "~/.nuget/v3-cache"],
         [:], ["dotnet", "nuget"]),
    ]

    /// Each build tool cache: its folders and shell variables only, unticked, deleted, skipped while the tool runs.
    /// Installed packages, virtualenvs, pipx apps and project outputs are never among its folders.
    @Test func buildToolCacheItems() throws {
        for tool in Self.buildTools {
            let item = try item(tool.id)
            #expect(item.paths == tool.paths && item.shellFolders == tool.shell, "\(tool.id)")
            #expect(item.runningProcessNames == tool.processes, "\(tool.id)")
            #expect(!item.selectedByDefault && item.skipsOpenFiles && !item.showsWhenEmpty && item.mode == .delete, "\(tool.id)")
            #expect(item.command == nil && item.probe == nil && item.note != nil, "\(tool.id)")
            for variable in tool.shell.keys { #expect(ShellEnvironment.variables.contains(variable), "\(variable)") }
            let folders = item.paths + item.shellFolders.values.flatMap { $0 }
            #expect(!folders.contains { $0.contains("packages") || $0.contains("virtualenvs") || $0.contains("venvs") }, "\(tool.id)")
        }
        #expect(try item("deno-cache").excluded == ["location_data"])
        #expect(try item("ccache-cache").included?.contains("ccache.conf") == false)
        #expect(try item("sccache-cache").included?.count == 16 && item("pre-commit-cache").included?.contains("db.db") == true)
        // Poetry's download caches now have their own item: "User caches" lists the rest of pypoetry only.
        #expect(CleanerGroup.ownedCachePaths.isSuperset(of: ["deno", "ccache", "Mozilla.sccache", "pipx", "pypoetry/cache",
                                                              "pypoetry/artifacts"]))
    }

    /// Only the caches go: Deno's origin storage, ccache's settings, Bazel's workspace output bases, NuGet's packages
    /// and Poetry's virtualenvs stay.
    @Test func buildToolCachesLeaveToolData() async throws {
        let box = try Home()
        defer { box.remove() }
        let junk = ["Library/Caches/deno/remote/https/deno.land/abc", "Library/Caches/deno/v8_code_cache_v2",
                    ".ccache/a/b/result", "Library/Caches/ccache/0/1/c", ".cache/bazel/_bazel_me/cache/repos/v1/content_addressable/x",
                    ".cache/bazel/_bazel_me/install/8f3a/A-server.jar", ".nuget/v3-cache/abc/list.dat",
                    ".local/share/NuGet/http-cache/abc/list.dat", "Library/Caches/pypoetry/cache/repositories/PyPI/x",
                    "Library/Caches/pypoetry/artifacts/ab/cd/pkg.whl", "Library/Caches/pipx/8b7a/bin/tool"]
        let kept = ["Library/Caches/deno/location_data/abc/local_storage", ".ccache/ccache.conf",
                    ".cache/bazel/_bazel_me/8f3a/execroot/app/bazel-out/x", ".cache/bazel/_bazel_me/8f3a/server/server.pid.txt",
                    ".nuget/packages/newtonsoft.json/13.0.3/lib.dll", "Library/Caches/pypoetry/virtualenvs/app-py3.12/bin/python",
                    ".local/pipx/venvs/black/bin/black", ".local/pipx/py/cpython/bin/python3"]
        for path in junk + kept { try box.file(path) }
        for tool in Self.buildTools {
            let item = try item(tool.id)
            let scan = await Scanner.scan(item, policy: box.policy, openPaths: EndToEndCleanTests.ownOpenPaths)
            #expect(await Cleaner.clean(item, scan: scan, policy: box.policy, openPaths: EndToEndCleanTests.ownOpenPaths).skipped == 0,
                    "\(tool.id)")
        }
        for path in junk { #expect(!box.exists(path), "\(path)") }
        for path in kept { #expect(box.exists(path), "\(path)") }
    }

    @MainActor @Test func buildToolCachesLockedWhileToolRuns() throws {
        let model = SmartScanModel(module: .smartScan) { [] }
        model.runningProcesses = ["bazel(app)"]
        #expect(try model.isRunning(item("bazel-cache")) && !model.isRunning(item("zig-cache")))
        model.runningProcesses = ["dotnet"]
        #expect(try model.isRunning(item("nuget-cache")) && !model.isRunning(item("deno-cache")))
    }
}
