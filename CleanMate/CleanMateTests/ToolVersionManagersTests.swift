import Foundation
import Testing
@testable import CleanMate

/// Old asdf and mise versions in Smart Scan: every version but the newest of each tool and the pinned ones is listed on
/// its own, unticked, and deleted whole; alias links, shims, plugins and settings stay. Everything happens in a
/// throwaway fake home.
struct ToolVersionManagersTests {
    private struct Home {
        let root = TestTemp.url("CleanMateToolVersions")
        var home: URL { root.appending(path: "home") }
        var policy: SafetyPolicy { SafetyPolicy(home: home, temp: root.appending(path: "tmp")) }
        static let asdf = ".asdf/installs"
        static let mise = ".local/share/mise/installs"

        init() throws {
            for dir in ["home", "tmp"] {
                try FileManager.default.createDirectory(at: root.appending(path: dir), withIntermediateDirectories: true)
            }
        }

        @discardableResult
        func file(_ path: String, _ text: String? = nil) throws -> URL {
            let url = home.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (text.map { Data($0.utf8) } ?? Data(repeating: 1, count: 40_000)).write(to: url)
            return url
        }

        /// `<installs>/<tool>/<version>` with a binary.
        @discardableResult
        func version(_ tool: String, _ version: String, in installs: String) throws -> URL {
            try file("\(installs)/\(tool)/\(version)/bin/\(tool)")
            return home.appending(path: "\(installs)/\(tool)/\(version)")
        }

        func link(_ path: String, to target: String) throws {
            try FileManager.default.createSymbolicLink(atPath: home.appending(path: path).path, withDestinationPath: target)
        }

        /// The fixture of the acceptance criteria: three tools of each manager, a global and a project pin per manager,
        /// mise's alias links.
        func standard() throws {
            for version in ["18.19.0", "20.11.1", "22.11.0"] { try self.version("nodejs", version, in: Home.asdf) }
            for version in ["3.10.13", "3.11.9", "3.12.4"] { try self.version("python", version, in: Home.asdf) }
            for version in ["3.2.0", "3.3.0"] { try self.version("ruby", version, in: Home.asdf) }
            for version in ["18.20.4", "20.18.0", "22.11.0", "23.1.0"] { try self.version("node", version, in: Home.mise) }
            for version in ["3.11.9", "3.12.4", "3.13.0"] { try self.version("python", version, in: Home.mise) }
            for version in ["temurin-17.0.9+9", "temurin-21.0.2+13.0.LTS", "zulu-21.30.15"] {
                try self.version("java", version, in: Home.mise)
            }
            try link(Home.mise + "/node/lts", to: "22.11.0")
            try link(Home.mise + "/node/latest", to: "23.1.0")
            try link(Home.mise + "/node/20", to: "20.18.0")
            // Global: asdf's `nodejs 20` keeps 20.11.1 (and mise's newest 20, the same tool); mise's `lts` keeps 22.11.0.
            try file(".tool-versions", "nodejs 20 # the team's line\n")
            try file(".config/mise/config.toml", "[settings]\nexperimental = true\n\n[tools]\nnode = \"lts\"\n")
            // Projects: python 3.10.13 (asdf) and 3.12 (mise) are pinned.
            try file("Developer/api/.tool-versions", "python 3.10.13\nruby 3.3.0\n")
            try file("Developer/client/web/mise.toml", "[tools]\npython = [\"3.12\"]\n")
        }

        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private func asdf(running: [String] = []) -> CleanerItem {
        ToolVersionManagers.asdfItem(hasFullDiskAccess: { true }, running: { running }, pins: .init(), sizes: FolderSizeCache(file: nil))
    }

    private func mise(running: [String] = []) -> CleanerItem {
        ToolVersionManagers.miseItem(hasFullDiskAccess: { true }, running: { running }, pins: .init(), sizes: FolderSizeCache(file: nil))
    }

    /// Entries as `<tool>/<version>`.
    private func listed(_ item: CleanerItem, _ box: Home) async -> [String] {
        await Scanner.scan(item, policy: box.policy).entries.map {
            $0.url.deletingLastPathComponent().lastPathComponent + "/" + $0.url.lastPathComponent
        }.sorted()
    }

    @Test func catalogItems() throws {
        let ids = CleanerGroup.developer.items.map(\.id)
        let go = try #require(ids.firstIndex(of: OldRuntimes.goID))
        #expect(Array(ids[(go + 1)...(go + 2)]) == [ToolVersionManagers.asdfID, ToolVersionManagers.miseID])
        for (id, process) in [(ToolVersionManagers.asdfID, "asdf"), (ToolVersionManagers.miseID, "mise")] {
            let item = try #require(CleanerGroup.developer.items.first { $0.id == id })
            #expect(!item.selectedByDefault && item.selectableEntries && item.mode == .delete && !item.showsWhenEmpty)
            #expect(item.skipsOpenFiles && item.allowsEntry != nil && item.locksEntry != nil && item.findEntries != nil)
            #expect(item.command == nil && item.probe == nil && item.minAge == nil && item.runningProcessNames == [process])
            #expect(Set(item.shellFolders.keys).isSubset(of: ShellEnvironment.variables))
        }
    }

    /// Only versions neither newest nor pinned are listed, labelled `<tool> <version>`; alias links never; `20` keeps
    /// the newest 20, `lts` the version mise's `lts` link names; Java flavors each keep their newest.
    @Test func listsOnlyVersionsNeitherNewestNorPinned() async throws {
        let box = try Home()
        defer { box.remove() }
        try box.standard()
        #expect(await listed(asdf(), box) == ["nodejs/18.19.0", "python/3.11.9", "ruby/3.2.0"])
        #expect(await listed(mise(), box) == ["java/temurin-17.0.9+9", "node/18.20.4", "python/3.11.9"])
        let scan = await Scanner.scan(mise(), policy: box.policy)
        let labels = scan.entries.compactMap { mise().entryLabel?($0.url)?.title }.sorted()
        #expect(labels == ["java temurin-17.0.9+9", "node 18.20.4", "python 3.11.9"])
        #expect(scan.entries.allSatisfy { $0.lockReason == nil && $0.size >= 40_000 })
    }

    /// Cleaning deletes only the ticked version, never the newest, a pinned one, an alias link or the settings.
    @Test func cleaningDeletesOnlyTheListedVersions() async throws {
        let box = try Home()
        defer { box.remove() }
        try box.standard()
        let item = mise()
        let scan = await Scanner.scan(item, policy: box.policy)
        let report = await Cleaner.clean(item, scan: scan, policy: box.policy)
        #expect(report.skipped == 0 && report.freed == scan.size)
        for gone in ["node/18.20.4", "python/3.11.9", "java/temurin-17.0.9+9"] {
            #expect(!box.exists(box.home.appending(path: Home.mise + "/" + gone)), "\(gone)")
        }
        for kept in ["node/20.18.0", "node/22.11.0", "node/23.1.0", "node/lts", "node/latest", "python/3.12.4",
                     "python/3.13.0", "java/temurin-21.0.2+13.0.LTS", "java/zulu-21.30.15"] {
            #expect(box.exists(box.home.appending(path: Home.mise + "/" + kept)), "\(kept)")
        }
        #expect(box.exists(box.home.appending(path: ".config/mise/config.toml")) && box.exists(box.home.appending(path: ".tool-versions")))
        #expect(await listed(item, box).isEmpty)
    }

    /// A pin written after the scan keeps its version when cleaned (asked again right before removal).
    @Test func aPinAddedAfterTheScanKeepsTheVersion() async throws {
        let box = try Home()
        defer { box.remove() }
        try box.standard()
        let scan = await Scanner.scan(asdf(), policy: box.policy)
        try box.file("Projects/legacy/.tool-versions", "ruby 3.2.0\n")
        let item = asdf() // a fresh pin cache, as a clean more than a few seconds later gets
        let report = await Cleaner.clean(item, scan: scan, policy: box.policy)
        #expect(report.skipped == 1)
        #expect(box.exists(box.home.appending(path: Home.asdf + "/ruby/3.2.0")))
        #expect(!box.exists(box.home.appending(path: Home.asdf + "/nodejs/18.19.0")))
    }

    /// Without the `lts` link, Node's `lts` keeps the newest of the two newest even majors; `latest` the newest.
    @Test func ltsWithoutALinkKeepsTheNewestEvenMajors() async throws {
        let box = try Home()
        defer { box.remove() }
        for version in ["16.20.2", "18.20.4", "20.18.0", "22.10.0", "22.11.0", "23.1.0"] {
            try box.version("node", version, in: Home.mise)
        }
        try box.file(".mise.toml", "[tools.node]\nversion = 'lts'\n")
        #expect(await listed(mise(), box) == ["node/16.20.2", "node/18.20.4", "node/22.10.0"])
        try box.file(".mise.toml", "[tools]\nnode = { version = \"latest\" }\n")
        #expect(await listed(mise(), box) == ["node/16.20.2", "node/18.20.4", "node/20.18.0", "node/22.10.0", "node/22.11.0"])
    }

    /// Nothing installed: nothing listed and the items stay hidden.
    @Test func hiddenWhenNotInstalled() async throws {
        let box = try Home()
        defer { box.remove() }
        try box.file(".tool-versions", "nodejs 20.11.1\n")
        for item in [asdf(), mise()] {
            let scan = await Scanner.scan(item, policy: box.policy)
            #expect(scan.entries.isEmpty && scan.size == 0)
        }
        try box.version("nodejs", "20.11.1", in: Home.asdf) // one version: the newest, never listed
        #expect(await listed(asdf(), box).isEmpty)
    }

    /// Skipped while asdf or mise runs (an install, a `mise exec`); other tools don't skip it.
    @MainActor @Test func skippedWhileTheToolRuns() throws {
        let model = SmartScanModel.isolated(module: .smartScan) { [] }
        model.runningApps = []
        for (id, name) in [(ToolVersionManagers.asdfID, "asdf"), (ToolVersionManagers.miseID, "mise")] {
            let item = try #require(CleanerGroup.developer.items.first { $0.id == id })
            model.runningProcesses = ["node", "python3"]
            #expect(!model.isRunning(item))
            model.runningProcesses = [name]
            #expect(model.isRunning(item), "\(name)")
        }
        // Legacy asdf is a bash script: `bash …/bin/asdf install` goes by `asdf` too.
        let buffer = Self.procArgs(["/bin/bash", "/Users/me/.asdf/bin/asdf", "install"])
        #expect(RunningProcesses.argumentNames(buffer).contains("asdf"))
    }

    /// A `KERN_PROCARGS2` buffer: argc, the executable path, then the arguments.
    static func procArgs(_ arguments: [String]) -> [UInt8] {
        var argc = Int32(arguments.count)
        var buffer = withUnsafeBytes(of: &argc) { Array($0) }
        buffer += Array(arguments[0].utf8) + [0, 0]
        for argument in arguments { buffer += Array(argument.utf8) + [0] }
        return buffer
    }

    /// A version a program runs from (its binary, a global CLI installed in it) is listed locked and kept when cleaned.
    @Test func versionsInUseAreLocked() async throws {
        let box = try Home()
        defer { box.remove() }
        try box.standard()
        let busy = box.home.appending(path: Home.asdf + "/nodejs/18.19.0")
        let item = asdf(running: [busy.path + "/bin/nodejs", "/usr/bin/login"])
        let scan = await Scanner.scan(item, policy: box.policy)
        let locked = scan.entries.filter { $0.lockReason != nil }.map(\.url.lastPathComponent)
        #expect(locked == ["18.19.0"] && scan.entries.count == 3)
        let report = await Cleaner.clean(item, scan: scan, policy: box.policy)
        #expect(box.exists(busy) && report.skipped == 1)
        #expect(!box.exists(box.home.appending(path: Home.asdf + "/ruby/3.2.0")))
    }

    /// The install and settings folders set in the profile are read.
    @Test func readsFoldersFromTheProfile() async throws {
        let box = try Home()
        defer { box.remove() }
        for version in ["1.0.0", "2.0.0"] {
            try box.version("deno", version, in: "tools/asdf/installs")
            try box.version("deno", version, in: "tools/mise/installs")
            try box.version("bun", version, in: "data/mise/installs")
        }
        try box.version("bun", "0.9.0", in: "data/mise/installs")
        try box.file("conf/mise/config.toml", "[tools]\nbun = \"0.9\"\n")
        try box.file(".zshrc", """
            export ASDF_DATA_DIR="$HOME/tools/asdf"
            export MISE_DATA_DIR=$HOME/tools/mise
            export XDG_DATA_HOME=~/data
            export XDG_CONFIG_HOME=~/conf
            """)
        #expect(await listed(asdf(), box) == ["deno/1.0.0"])
        #expect(await listed(mise(), box) == ["bun/1.0.0", "deno/1.0.0"])
        // Settings moved in a way the profile reader can't follow: nothing is listed.
        try box.file(".zshrc", "export MISE_DATA_DIR=$HOME/tools/mise\nexport MISE_CONFIG_DIR=$(mise_dir)\n")
        #expect(await listed(mise(), box).isEmpty)
    }

    /// Version names: flavors, prereleases, names without a version.
    @Test func comparesVersionsPerFlavor() {
        #expect(ToolVersionManagers.newest(["3.12.4", "3.13.0rc1", "3.9.19", "pypy3.10-7.3.15", "pypy3.10-7.3.12", "ref-main"])
                == ["3.12.4", "3.13.0rc1", "pypy3.10-7.3.15", "ref-main"])
        #expect(ToolVersionManagers.newest(["20.9.0", "20.11.1", "v20.10.0"]) == ["20.11.1"])
        #expect(ToolVersionManagers.parse("lts") == nil && ToolVersionManagers.parse("miniconda3-latest") == nil)
        #expect(ToolVersionManagers.parse("corretto-21.0.2.13.1")?.flavor == "corretto-")
        let folder = URL(fileURLWithPath: "/nonexistent/node")
        let names = ["18.20.4", "20.11.1", "20.18.0", "22.11.0"]
        #expect(ToolVersionManagers.kept(by: "20", folder: folder, names: names) == ["20.18.0"])
        #expect(ToolVersionManagers.kept(by: "20.11.1", folder: folder, names: names) == ["20.11.1"])
        #expect(ToolVersionManagers.kept(by: "prefix:18", folder: folder, names: names) == ["18.20.4"])
        #expect(ToolVersionManagers.kept(by: "19", folder: folder, names: names) == [])
        #expect(ToolVersionManagers.kept(by: "system", folder: folder, names: names) == [])
        #expect(ToolVersionManagers.kept(by: "{{ env.NODE }}", folder: folder, names: names) == nil)
        #expect(ToolVersionManagers.kept(by: "sub-1:latest", folder: folder, names: names) == nil)
    }

    /// A pin CleanMate can't read keeps every version of that tool only.
    @Test func anUnreadablePinKeepsThatTool() async throws {
        let box = try Home()
        defer { box.remove() }
        try box.standard()
        try box.file(".config/mise/config.toml", "[tools]\njava = \"{{ env.JAVA_VERSION }}\"\n")
        // `lts` is gone with the old file: node 22.11.0 is listed now; java keeps all three.
        #expect(await listed(mise(), box) == ["node/18.20.4", "node/22.11.0", "python/3.11.9"])
    }

    /// The settings formats: `.tool-versions` lines and mise's `[tools]` in its TOML shapes.
    @Test func readsPins() {
        let tool = ToolVersionManagers.toolVersionsPins("# global\nnodejs 20.11.1 18.19.0\npython 3.12.4 # main\n\nruby\n")
        #expect(tool.map(\.tool) == ["nodejs", "python"] && tool.map(\.specs) == [["20.11.1", "18.19.0"], ["3.12.4"]])
        let mise = ToolVersionManagers.misePins("""
            [env]
            NODE_ENV = "production"
            [tools]
            node = "22" # current
            python = ["3.11", '3.12']
            ruby = [
              "3.3",
              "3.2",
            ]
            java = { version = "temurin-21", os = ["macos"] }
            "npm:prettier" = "latest"
            go = 1.22
            [tools.terraform]
            version = "1.9"
            [tasks.build]
            run = "make"
            """)
        #expect(mise.map(\.tool) == ["node", "python", "ruby", "java", "npm:prettier", "go", "terraform"])
        #expect(mise.map(\.specs) == [["22"], ["3.11", "3.12"], ["3.3", "3.2"], ["temurin-21"], ["latest"], ["1.22"], ["1.9"]])
        #expect(ToolVersionManagers.toolKey("nodejs") == "node" && ToolVersionManagers.toolKey("core:node") == "node")
        #expect(ToolVersionManagers.toolKey("npm:@antfu/ni") == ToolVersionManagers.toolKey("npm-antfu-ni"))
    }
}
