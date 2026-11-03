import Foundation
import Testing
@testable import CleanMate

/// Old Xcode versions: a fake home in a throwaway folder, its ~/Applications searched instead of the real
/// /Applications (never read nor touched), an injected xcode-select folder and running paths, and a fake Trash.
final class XcodeVersionsTests {
    let fm = FileManager.default
    let root = TestTemp.url("CleanMateXcodeVersions")
    var home: URL { root.appending(path: "home") }
    var applications: URL { home.appending(path: "Applications") }
    var trash: URL { root.appending(path: "Trash") }
    var policy: SafetyPolicy { SafetyPolicy(home: home, temp: root.appending(path: "tmp")) }

    deinit {
        chmod(home.appending(path: "Applications").path, 0o755)
        try? FileManager.default.removeItem(at: root)
    }

    /// An Xcode-like bundle `name` in `folder` (~/Applications by default) with its Developer folder and a 64 KB file inside. `license` nil: no
    /// LicenseInfo.plist.
    @discardableResult
    func xcode(_ name: String, version: String?, build: String? = nil, license: String? = "GM",
               id: String = XcodeVersions.bundleID, in folder: URL? = nil) throws -> URL {
        let url = (folder ?? applications).appending(path: name)
        let contents = url.appending(path: "Contents")
        try fm.createDirectory(at: contents.appending(path: "Resources"), withIntermediateDirectories: true)
        try fm.createDirectory(at: contents.appending(path: "Developer"), withIntermediateDirectories: true)
        var info = ["CFBundleIdentifier": id]
        if let version { info["CFBundleShortVersionString"] = version }
        try (info as NSDictionary).write(to: contents.appending(path: "Info.plist"))
        if let build { try (["ProductBuildVersion": build] as NSDictionary).write(to: contents.appending(path: "version.plist")) }
        if let license {
            try (["licenseType": license] as NSDictionary).write(to: contents.appending(path: "Resources/LicenseInfo.plist"))
        }
        try Data(repeating: 1, count: 65_536).write(to: contents.appending(path: "Resources/Payload"))
        return url
    }

    /// The developer folder of `name` in ~/Applications, as xcode-select records it.
    func developer(_ name: String) -> [String] { [applications.appending(path: name + "/Contents/Developer").path] }

    func item(selected: [String] = [], running: [String] = [],
              owner: @escaping SafetyPolicy.OwnerID = SafetyPolicy.ownerID) -> CleanerItem {
        let folders = [applications]
        return XcodeVersions.item(folders: { _ in folders }, owner: owner, selected: { selected }, running: { running },
                                  sizes: FolderSizeCache(file: nil))
    }

    func scan(_ item: CleanerItem) async -> ItemScan {
        await Scanner.scan(item, policy: policy, openPaths: EndToEndCleanTests.ownOpenPaths)
    }

    func listed(_ item: CleanerItem) async -> [String] {
        await scan(item).entries.map(\.url.lastPathComponent).sorted()
    }

    var moveToFakeTrash: @Sendable (URL) throws -> URL? {
        let trash = trash
        return { url in
            let target = trash.appending(path: UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }
    }

    @Test func inDeveloperJunkRightAfterArchivesUntickedToTheTrash() throws {
        let items = CleanerGroup.developer.items
        let index = try #require(items.firstIndex { $0.id == XcodeVersions.id })
        #expect(items[index - 1].id == "xcode-archives")
        let item = items[index]
        #expect(item.mode == .trash && !item.selectedByDefault && item.selectableEntries && !item.showsWhenEmpty)
        #expect(item.paths.isEmpty && item.findEntries != nil && item.allowsEntry != nil && item.locksEntry != nil)
        // Not skipped whenever Xcode runs (the running one is kept): only versions a program runs from are locked.
        #expect(item.runningAppBundleIDs.isEmpty && item.runningProcessNames.isEmpty)
    }

    /// Recognised by bundle id, whatever the name; only real bundles directly in Applications.
    @Test func identifiedByBundleIDNotName() async throws {
        try xcode("Xcode.app", version: "16.0", build: "16A242d")
        try xcode("Xcode-15.4.app", version: "15.4", build: "15F31d")
        try xcode("Tools.app", version: "14.3.1", build: "14E300c") // Xcode's id under another name
        try xcode("Xcode-14.app", version: "14.0", id: "com.example.notxcode") // Xcode's name, another id
        try xcode("Xcode-13.app", version: "13.0", in: applications.appending(path: "Old")) // not at the top level
        let elsewhere = root.appending(path: "elsewhere")
        try xcode("Xcode-12.app", version: "12.0", in: elsewhere)
        try fm.createSymbolicLink(at: applications.appending(path: "Xcode-12.app"),
                                  withDestinationURL: elsewhere.appending(path: "Xcode-12.app"))
        #expect(await listed(item()) == ["Tools.app", "Xcode-15.4.app"])
        #expect(XcodeVersions.install(at: applications.appending(path: "Xcode-14.app")) == nil)
        #expect(XcodeVersions.install(at: applications.appending(path: "Xcode-12.app")) == nil) // a symlink
    }

    /// One row per version with version, build and size; nothing ticked.
    @Test func labelsSizesAndUnticked() async throws {
        try xcode("Xcode.app", version: "16.0", build: "16A242d")
        try xcode("Xcode-15.4.app", version: "15.4", build: "15F31d")
        try xcode("Xcode-beta.app", version: "16.1", build: "16B5001e", license: "Beta")
        try xcode("Xcode-16.2-Beta.app", version: "16.2", build: "16C5013f", license: nil) // beta by name
        let item = item()
        let result = await scan(item)
        let labels = Dictionary(uniqueKeysWithValues: result.entries.map { ($0.url.lastPathComponent, $0.title) })
        #expect(labels == ["Xcode-15.4.app": "Xcode 15.4 (15F31d)", "Xcode-beta.app": "Xcode 16.1 beta (16B5001e)",
                           "Xcode-16.2-Beta.app": "Xcode 16.2 beta (16C5013f)"])
        #expect(result.entries.allSatisfy { $0.size >= 65_536 && $0.date != nil && $0.lockReason == nil })
        #expect(!item.selectedByDefault)
    }

    /// Kept: the newest release (a newer beta doesn't count), the selected version, one an app-folder symlink points to.
    @Test func keepsTheSelectedAndTheNewestRelease() async throws {
        try xcode("Xcode-15.4.app", version: "15.4")
        try xcode("Xcode-16.0.app", version: "16.0")
        try xcode("Xcode-16.0.1.app", version: "16.0.1")
        try xcode("Xcode-beta.app", version: "17.0", license: "Beta")
        #expect(await listed(item()) == ["Xcode-15.4.app", "Xcode-16.0.app", "Xcode-beta.app"])
        // xcode-select points inside one: kept.
        #expect(await listed(item(selected: developer("Xcode-15.4.app"))) == ["Xcode-16.0.app", "Xcode-beta.app"])
        #expect(await listed(item(selected: developer("Xcode-beta.app"))) == ["Xcode-15.4.app", "Xcode-16.0.app"])
        // `Xcode.app` → `Xcode-16.0.app` (xcodes): the target is kept, the symlink never listed.
        try fm.createSymbolicLink(at: applications.appending(path: "Xcode.app"),
                                  withDestinationURL: applications.appending(path: "Xcode-16.0.app"))
        #expect(await listed(item()) == ["Xcode-15.4.app", "Xcode-beta.app"])
        // xcode-select through that symlink: resolved, so its target is kept.
        try fm.removeItem(at: applications.appending(path: "Xcode-16.0.app"))
        try xcode("Xcode-16.0.app", version: "16.0")
        try fm.removeItem(at: applications.appending(path: "Xcode.app"))
        let link = root.appending(path: "Xcode.app")
        try fm.createSymbolicLink(at: link, withDestinationURL: applications.appending(path: "Xcode-15.4.app"))
        let selected = [link.path + "/Contents/Developer", link.appending(path: "Contents/Developer").resolvingSymlinksInPath().path]
        #expect(await listed(item(selected: selected)) == ["Xcode-16.0.app", "Xcode-beta.app"])
    }

    @Test func keptVersions() throws {
        func install(_ name: String, _ version: String?, beta: Bool = false) -> XcodeVersions.Install {
            XcodeVersions.Install(url: URL(fileURLWithPath: "/Applications/\(name).app"), version: version, build: nil, isBeta: beta)
        }
        func kept(_ installs: [XcodeVersions.Install], selected: [String] = [], linked: Set<String> = []) -> [String] {
            XcodeVersions.kept(installs, selected: selected, linked: linked).map { ($0 as NSString).lastPathComponent }.sorted()
        }
        let release = install("Xcode", "16.4"), old = install("Xcode-15", "15.4"), beta = install("Xcode-beta", "26.0", beta: true)
        #expect(kept([release, old, beta]) == ["Xcode.app"]) // a newer beta is not "the newest"
        #expect(kept([old, beta]) == ["Xcode-15.app"])
        #expect(kept([beta, install("Xcode-beta-2", "26.1", beta: true)]) == ["Xcode-beta-2.app"]) // only betas: newest beta
        #expect(kept([release, install("Xcode-copy", "16.4.0"), old]) == ["Xcode-copy.app", "Xcode.app"]) // both copies
        #expect(kept([install("Xcode-10", "10.3"), install("Xcode-9", "9.4.1")]) == ["Xcode-10.app"]) // numbers, not text
        #expect(kept([release, install("Odd", nil), install("Odder", "unknown")]) == ["Odd.app", "Odder.app", "Xcode.app"])
        #expect(kept([release, old], selected: ["/Applications/Xcode-15.app/Contents/Developer"]) == ["Xcode-15.app", "Xcode.app"])
        #expect(kept([release, old], selected: ["/Applications/Xcode-15.app"]) == ["Xcode-15.app", "Xcode.app"])
        #expect(kept([release, old], selected: ["/Applications/Xcode-15.app2/Contents/Developer"]) == ["Xcode.app"])
        #expect(kept([release, old], selected: ["/Library/Developer/CommandLineTools"]) == ["Xcode.app"])
        #expect(kept([release, old], linked: ["/Applications/Xcode-15.app"]) == ["Xcode-15.app", "Xcode.app"])
    }

    @Test func onlyOneXcodeHidesTheItem() async throws {
        try xcode("Xcode-15.4.app", version: "15.4")
        #expect(await listed(item()).isEmpty)
        try xcode("Xcode-beta.app", version: "16.0", license: "Beta")
        // Two, but the release is the newest release and the beta is the one selected.
        #expect(await listed(item(selected: developer("Xcode-beta.app"))).isEmpty)
    }

    @Test func selectedFolderFromTheLink() throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let link = root.appending(path: "xcode_select_link")
        #expect(XcodeVersions.selectedFolders(link: link.path).first == XcodeVersions.defaultDeveloperFolder)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "/Applications/Xcode-15.4.app/Contents/Developer")
        #expect(XcodeVersions.selectedFolders(link: link.path).first == "/Applications/Xcode-15.4.app/Contents/Developer")
    }

    /// Locked, matched by the path a program runs from (not its name): listed, not tickable, skipped at clean.
    @MainActor @Test func lockedWhileAProgramRunsFromIt() async throws {
        try xcode("Xcode.app", version: "16.0")
        let old = try xcode("Xcode-15.4.app", version: "15.4")
        let reason = String(localized: "A program runs from this version, so it is kept")
        for path in ["Contents/MacOS/Xcode", "Contents/Developer/usr/bin/xcodebuild",
                     "Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator",
                     "Contents/Developer/usr/bin/ibtoold"] {
            let result = await scan(item(running: [old.appending(path: path).path]))
            #expect(result.entries.map(\.lockReason) == [reason], "\(path)")
        }
        // An `Xcode` or `xcodebuild` running from elsewhere (the kept version, a lookalike path) doesn't lock it.
        let other = item(running: [applications.path + "/Xcode.app/Contents/MacOS/Xcode", old.path + "2/Contents/MacOS/Xcode",
                                   "/usr/bin/xcodebuild"])
        #expect(await scan(other).entries.map(\.lockReason) == [nil])

        let running = item(running: [old.appending(path: "Contents/MacOS/Xcode").path])
        let result = await scan(running)
        let model = SmartScanModel.isolated(module: .smartScan) { [CleanerGroup(id: "g", title: "G", systemImage: "x", items: [running])] }
        model.scans[running.id] = result
        #expect(model.lockedEntries(running).contains(old))
        let report = await Cleaner.clean(running, scan: result, policy: policy, trash: moveToFakeTrash,
                                         openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(report.skipped == 1 && report.trashed.isEmpty && fm.fileExists(atPath: old.path))
    }

    /// Root-owned or in a folder the user can't write to: a locked row with a reason, never a password prompt.
    @Test func lockedWhenOwnedByRoot() async throws {
        try xcode("Xcode.app", version: "16.0")
        let old = try xcode("Xcode-15.4.app", version: "15.4")
        let reason = String(localized: "Administrator privileges required — delete with Finder")
        let rootOwned = item(owner: { _ in 0 })
        let result = await scan(rootOwned)
        #expect(result.entries.map(\.lockReason) == [reason] && result.entries[0].size >= 65_536)
        let report = await Cleaner.clean(rootOwned, scan: result, policy: policy, trash: moveToFakeTrash,
                                         openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(report.skipped == 1 && report.trashed.isEmpty && fm.fileExists(atPath: old.path))

        try #require(chmod(applications.path, 0o555) == 0)
        defer { chmod(applications.path, 0o755) }
        #expect(await scan(item()).entries.map(\.lockReason) == [reason])
    }

    /// To the (fake) Trash, put back by Undo; checked again right before: a version selected since the scan stays.
    @Test func trashedAndPutBackByUndo() async throws {
        try xcode("Xcode.app", version: "16.0")
        try xcode("Xcode-15.4.app", version: "15.4")
        try xcode("Xcode-14.3.app", version: "14.3")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let result = await scan(item())
        #expect(result.entries.count == 2)

        let report = await Cleaner.clean(item(selected: developer("Xcode-14.3.app")), scan: result, policy: policy,
                                         trash: moveToFakeTrash, openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(report.skipped == 1 && report.trashed.count == 1)
        #expect(try Set(fm.contentsOfDirectory(atPath: applications.path)) == ["Xcode.app", "Xcode-14.3.app"])

        let undo = await TrashUndo.restore(report.trashed, module: "Smart Scan", home: home)
        #expect(undo == TrashUndo.Result(restored: 1, skipped: 0))
        #expect(try Set(fm.contentsOfDirectory(atPath: applications.path)) == ["Xcode.app", "Xcode-14.3.app", "Xcode-15.4.app"])
    }

    @Test func policyRule() throws {
        let old = try xcode("Xcode-15.4.app", version: "15.4")
        #expect(policy.allowsXcodeApp(old))
        let rootOwned: SafetyPolicy.OwnerID = { _ in 0 } // owned by root; outside #expect, which wants a Sendable closure
        #expect(!policy.allowsXcodeApp(old, owner: rootOwned))
        #expect(policy.allowsXcodeApp(old, writableOnly: false, owner: rootOwned))
        #expect(!policy.allowsXcodeApp(try xcode("Other.app", version: "1.0", id: "com.apple.Safari")))
        #expect(!policy.allowsXcodeApp(try xcode("Xcode.app", version: "16.0", in: home.appending(path: "Downloads"))))
        #expect(!policy.allowsXcodeApp(try xcode("Xcode.app", version: "16.0", in: applications.appending(path: "Sub"))))
        let excluded = SafetyPolicy(home: home, temp: root.appending(path: "tmp"), excluded: [old.path])
        #expect(!excluded.allowsXcodeApp(old))
        // Never the real /Applications through this test, but the rule accepts its folder.
        #expect(policy.applicationFolders.first?.path == "/Applications")
    }
}
