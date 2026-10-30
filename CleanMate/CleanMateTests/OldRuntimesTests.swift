import Foundation
import Testing
@testable import CleanMate

/// Old Node versions (nvm) and Flutter SDKs (fvm) in Smart Scan: every version but the default one is listed on its
/// own, unticked, and deleted whole; a version a program runs from is listed locked; aliases, the default link and
/// project files stay. Everything happens in a throwaway fake home.
struct OldRuntimesTests {
    private struct Home {
        let root = TestTemp.url("CleanMateOldRuntimes")
        var home: URL { root.appending(path: "home") }
        var policy: SafetyPolicy { SafetyPolicy(home: home, temp: root.appending(path: "tmp")) }

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

        /// `<nvm>/versions/node/<version>` with its `node` binary.
        @discardableResult
        func node(_ version: String, nvm: String = ".nvm") throws -> URL {
            try file("\(nvm)/versions/node/\(version)/bin/node").deletingLastPathComponent().deletingLastPathComponent()
        }

        /// `<fvm>/versions/<version>` with its Dart VM.
        @discardableResult
        func flutter(_ version: String, fvm: String = "fvm") throws -> URL {
            try file("\(fvm)/versions/\(version)/bin/cache/dart-sdk/bin/dart")
            return home.appending(path: "\(fvm)/versions/\(version)")
        }

        func alias(_ name: String, _ target: String, nvm: String = ".nvm") throws { try file("\(nvm)/alias/\(name)", target + "\n") }

        func link(_ path: String, to target: String) throws {
            try FileManager.default.createSymbolicLink(atPath: home.appending(path: path).path, withDestinationPath: target)
        }

        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private func listed(_ item: CleanerItem, _ box: Home) async -> [String] {
        await Scanner.scan(item, policy: box.policy).entries.map(\.url.lastPathComponent).sorted()
    }

    @Test func catalogItems() throws {
        let ids = CleanerGroup.developer.items.map(\.id)
        let rustup = try #require(ids.firstIndex(of: "rustup-downloads"))
        #expect(Array(ids[(rustup + 1)...(rustup + 2)]) == [OldRuntimes.nodeID, OldRuntimes.flutterID])
        for id in [OldRuntimes.nodeID, OldRuntimes.flutterID] {
            let item = try #require(CleanerGroup.developer.items.first { $0.id == id })
            #expect(!item.selectedByDefault && item.selectableEntries && item.mode == .delete && !item.showsWhenEmpty)
            #expect(item.skipsOpenFiles && item.allowsEntry != nil && item.locksEntry != nil && item.entryLabel != nil)
            #expect(item.command == nil && item.probe == nil && item.minAge == nil)
            #expect(Set(item.shellFolders.keys).isSubset(of: ShellEnvironment.variables))
        }
    }

    /// Three Node versions, default `lts/iron` (→ `alias/lts/iron` → v20.18.0): the two others are listed as
    /// `Node vX.Y.Z`; cleaning one deletes only it, never `alias/`, nvm itself or a project's `.nvmrc`.
    @Test func listsNodeVersionsButTheDefault() async throws {
        let box = try Home()
        defer { box.remove() }
        let old = try box.node("v18.20.4")
        let current = try box.node("v20.18.0")
        let newer = try box.node("v22.11.0")
        try box.alias("default", "lts/iron")
        try box.alias("lts/iron", "v20.18.0")
        try box.alias("lts/*", "lts/jod")
        let kept = try [box.file(".nvm/nvm.sh", "# nvm"), box.file("Developer/app/.nvmrc", "18\n"),
                        box.file(".nvm/alias/default", "lts/iron\n")]

        let item = OldRuntimes.nodeItem(running: { [] })
        let scan = await Scanner.scan(item, policy: box.policy)
        #expect(scan.entries.map(\.url.lastPathComponent).sorted() == ["v18.20.4", "v22.11.0"])
        #expect(Set(scan.entries.compactMap { item.entryLabel?($0.url)?.title }) == ["Node v18.20.4", "Node v22.11.0"])
        #expect(scan.entries.allSatisfy { $0.lockReason == nil && $0.size >= 40_000 })

        var onlyOld = scan
        onlyOld.entries = scan.entries.filter { $0.url.lastPathComponent == "v18.20.4" }
        let report = await Cleaner.clean(item, scan: onlyOld, policy: box.policy)
        #expect(report.skipped == 0 && report.freed == onlyOld.entries.first?.size)
        #expect(!box.exists(old) && box.exists(current) && box.exists(newer))
        #expect(kept.allSatisfy(box.exists) && box.exists(box.home.appending(path: ".nvm/alias/lts/iron")))
    }

    @Test func resolvesNvmDefaultLikeNvm() throws {
        let box = try Home()
        defer { box.remove() }
        let nvm = box.home.appending(path: ".nvm")
        let installed = ["v18.20.4", "v20.9.0", "v20.11.1", "v22.11.0"]
        func resolve(_ value: String?) throws -> String?? {
            try? FileManager.default.removeItem(at: nvm.appending(path: "alias/default"))
            if let value { try box.alias("default", value) }
            return OldRuntimes.nodeDefault(nvmDir: nvm, installed: installed)
        }
        try box.alias("lts/*", "lts/jod")
        try box.alias("lts/jod", "v22.11.0")
        try box.alias("loop", "loop")
        #expect(try resolve("v20.9.0") == .some("v20.9.0"))
        #expect(try resolve("20") == .some("v20.11.1"))
        #expect(try resolve("v20.9") == .some("v20.9.0"))
        #expect(try resolve("node") == .some("v22.11.0"))
        #expect(try resolve("stable") == .some("v22.11.0"))
        #expect(try resolve("lts/*") == .some("v22.11.0"))
        #expect(try resolve("system") == .some(nil)) // no nvm version is the default: every one is listed
        // Can't tell: nothing is listed.
        #expect(try resolve(nil) == nil)
        #expect(try resolve("16") == nil)
        #expect(try resolve("lts/hydrogen") == nil)
        #expect(try resolve("loop") == nil)
        #expect(try resolve("../../etc") == nil)
    }

    @Test func keepsTheVersionsThePathRunsAndListsNothingWithoutADefault() async throws {
        let box = try Home()
        defer { box.remove() }
        try box.node("v18.20.4")
        try box.node("v20.18.0")
        try box.node("v22.11.0")
        let item = OldRuntimes.nodeItem(running: { [] })
        #expect(await listed(item, box).isEmpty) // no `nvm alias default`
        try box.alias("default", "22")
        try box.file(".zprofile", "export PATH=\"$HOME/.nvm/versions/node/v18.20.4/bin:$PATH\"\n")
        #expect(await listed(item, box) == ["v20.18.0"])
    }

    @Test func readsNvmDirFromTheProfile() async throws {
        let box = try Home()
        defer { box.remove() }
        try box.node("v18.20.4", nvm: ".local/share/nvm")
        try box.node("v20.18.0", nvm: ".local/share/nvm")
        try box.alias("default", "v20.18.0", nvm: ".local/share/nvm")
        try box.file(".zshrc", "export NVM_DIR=\"$XDG_DATA_HOME/nvm\"\n")
        #expect(await listed(OldRuntimes.nodeItem(running: { [] }), box) == ["v18.20.4"])
    }

    /// Two Flutter SDKs, `default` pointing to one: the other is listed as `Flutter <version>`. No `default` (no fvm
    /// global): both. A `default` that is not a symlink into `versions/`: none.
    @Test func listsFlutterSDKsButTheGlobalOne() async throws {
        let box = try Home()
        defer { box.remove() }
        let global = try box.flutter("3.24.5")
        let old = try box.flutter("3.19.6")
        let item = OldRuntimes.flutterItem(running: { [] })
        #expect(await listed(item, box) == ["3.19.6", "3.24.5"])
        try box.link("fvm/default", to: global.path)
        let scan = await Scanner.scan(item, policy: box.policy)
        #expect(scan.entries.map(\.url.lastPathComponent) == ["3.19.6"])
        #expect(scan.entries.first.flatMap { item.entryLabel?($0.url)?.title } == "Flutter 3.19.6")
        let report = await Cleaner.clean(item, scan: scan, policy: box.policy)
        #expect(report.skipped == 0 && !box.exists(old) && box.exists(global))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: box.home.appending(path: "fvm/default").path)) == global.path)

        try box.flutter("3.19.6")
        try FileManager.default.removeItem(at: box.home.appending(path: "fvm/default"))
        try box.link("fvm/default", to: "versions/3.19.6") // relative link
        #expect(await listed(item, box) == ["3.24.5"])
        try FileManager.default.removeItem(at: box.home.appending(path: "fvm/default"))
        try box.link("fvm/default", to: box.home.appending(path: "Developer/flutter").path)
        #expect(await listed(item, box).isEmpty)
        try FileManager.default.removeItem(at: box.home.appending(path: "fvm/default"))
        try box.file("fvm/default", "3.24.5")
        #expect(await listed(item, box).isEmpty)
    }

    @Test func readsFvmCachePathFromTheProfile() async throws {
        let box = try Home()
        defer { box.remove() }
        let global = try box.flutter("3.24.5", fvm: "dev/fvm")
        try box.flutter("3.19.6", fvm: "dev/fvm")
        try box.link("dev/fvm/default", to: global.path)
        try box.file(".zprofile", "export FVM_CACHE_PATH=~/dev/fvm\n")
        #expect(await listed(OldRuntimes.flutterItem(running: { [] }), box) == ["3.19.6"])
    }

    /// A version a program runs from (node itself, a global CLI's script, the Dart VM) is listed locked with the reason,
    /// and kept when cleaned even if the scan handed it in.
    @Test func versionsInUseAreLocked() async throws {
        let box = try Home()
        defer { box.remove() }
        let busy = try box.node("v18.20.4")
        let idle = try box.node("v22.11.0")
        try box.node("v20.18.0")
        try box.alias("default", "v20.18.0")
        let running = [busy.path + "/bin/node", "/usr/bin/login", box.home.appending(path: ".nvm/versions/node/v22").path]
        let item = OldRuntimes.nodeItem(running: { running })
        let scan = await Scanner.scan(item, policy: box.policy)
        let reasons = Dictionary(uniqueKeysWithValues: scan.entries.map { ($0.url.lastPathComponent, $0.lockReason) })
        #expect(reasons.count == 2 && reasons["v18.20.4"] != nil && reasons["v22.11.0"] == .some(nil))
        let report = await Cleaner.clean(item, scan: scan, policy: box.policy)
        #expect(report.skipped == 1 && box.exists(busy) && !box.exists(idle))

        let fvmBusy = try box.flutter("3.19.6")
        let flutter = OldRuntimes.flutterItem(running: { [fvmBusy.path + "/bin/cache/dart-sdk/bin/dart"] })
        let flutterScan = await Scanner.scan(flutter, policy: box.policy)
        #expect(flutterScan.entries.count == 1 && flutterScan.entries.first?.lockReason != nil)
    }

    /// The kernel reports a running program by its resolved path: a version reached through a symlinked nvm folder is
    /// still locked.
    @Test func versionsBehindASymlinkAreLocked() throws {
        let box = try Home()
        defer { box.remove() }
        let real = try box.node("v18.20.4", nvm: "Volumes/nvm")
        try box.link(".nvm", to: box.home.appending(path: "Volumes/nvm").path)
        let linked = box.home.appending(path: ".nvm/versions/node/v18.20.4")
        let check = OldRuntimes.locks(reason: "busy", running: { [real.resolvingSymlinksInPath().path + "/bin/node"] })()
        #expect(check(linked) == "busy" && check(real) == "busy")
        #expect(check(box.home.appending(path: ".nvm/versions/node/v18")) == nil)
    }

    /// Smart Scan never ticks, counts or cleans a locked entry: ticking the item takes only the others, and an item
    /// whose every entry is locked is locked itself.
    @MainActor @Test func smartScanLeavesLockedEntriesOut() async throws {
        let box = try Home()
        defer { box.remove() }
        let busy = try box.node("v18.20.4")
        let idle = try box.node("v22.11.0")
        try box.node("v20.18.0")
        try box.alias("default", "v20.18.0")
        let item = OldRuntimes.nodeItem(running: { [busy.path + "/bin/node"] })
        let model = SmartScanModel(module: .smartScan) { [CleanerGroup(id: "g", title: "G", systemImage: "x", items: [item])] }
        // Ticking the item by hand is remembered in the real defaults: forget it.
        defer { Preferences.update(Preferences.selectionOverrides) { (all: inout [String: Bool]) in all[item.id] = nil } }
        let policy = box.policy
        model.logHome = box.home
        model.scanItem = { await Scanner.scan($0, policy: policy, openPaths: $1) }
        model.cleanItem = { item, scan, _ in await Cleaner.clean(item, scan: scan, policy: policy) }
        await model.scan()
        let entries = try #require(model.scans[item.id]?.entries)
        let idleSize = try #require(entries.first { $0.url.lastPathComponent == "v22.11.0" }?.size)
        let busyURL = try #require(entries.first { $0.lockReason != nil }?.url)
        #expect(!model.selected.contains(item.id) && !model.isLocked(item))

        model.setSelected(item, true)
        #expect(model.lockedEntries(item) == [busyURL] && !model.isEntrySelected(item, busyURL))
        #expect(model.selectedSize == idleSize && model.partialSelectedSize(item) == idleSize)
        model.setEntry(item, entries.first { $0.lockReason == nil }!.url, false) // the only tickable one off → item off
        #expect(!model.selected.contains(item.id))
        model.setSelected(item, true)
        await model.clean()
        #expect(box.exists(busy) && !box.exists(idle))

        let allBusy = ItemScan(entries: [ScanEntry(url: busy, size: 1, lockReason: "busy")])
        #expect(SmartScanModel.allEntriesLocked(allBusy) && !SmartScanModel.allEntriesLocked(ItemScan()))
    }
}
