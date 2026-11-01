import Foundation
import Testing
@testable import CleanMate

/// Old Unity Editor versions and Unity caches: a fake home in a throwaway folder, its ~/Applications searched instead
/// of the real /Applications (never read nor touched), injected owner and running paths, and a fake Trash.
final class UnityEditorsTests {
    typealias Version = UnityEditors.Version
    let fm = FileManager.default
    let root = TestTemp.url("CleanMateUnityEditors")
    var home: URL { root.appending(path: "home") }
    var editors: URL { home.appending(path: "Applications/Unity/Hub/Editor") }
    var hub: URL { home.appending(path: UnityEditors.hubSettings) }
    var trash: URL { root.appending(path: "Trash") }
    var policy: SafetyPolicy { SafetyPolicy(home: home, temp: root.appending(path: "tmp")) }

    deinit {
        chmod(home.appending(path: "Applications/Unity/Hub/Editor").path, 0o755)
        try? FileManager.default.removeItem(at: root)
    }

    /// A Unity Hub editor folder `name` in `folder` (~/Applications/Unity/Hub/Editor by default) with its `Unity.app`
    /// and a 64 KB file inside. `appVersion` nil: none in the plist.
    @discardableResult
    func editor(_ name: String, appVersion: String? = "same", id: String = "com.unity3d.UnityEditor5.x",
                in folder: URL? = nil) throws -> URL {
        let url = (folder ?? editors).appending(path: name)
        let contents = url.appending(path: "Unity.app/Contents")
        try fm.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        var info = ["CFBundleIdentifier": id]
        if let appVersion { info["CFBundleVersion"] = appVersion == "same" ? name : appVersion }
        try (info as NSDictionary).write(to: contents.appending(path: "Info.plist"))
        try Data(repeating: 1, count: 65_536).write(to: url.appending(path: "Unity.app/Contents/MacOS/Unity"))
        return url
    }

    /// A Unity project at `path` below the home folder pinning `version`.
    @discardableResult
    func project(_ path: String, _ version: String) throws -> URL {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.appending(path: "ProjectSettings"), withIntermediateDirectories: true)
        try "m_EditorVersion: \(version)\nm_EditorVersionWithRevision: \(version) (abc123)\n"
            .write(to: url.appending(path: UnityEditors.projectVersionFile), atomically: true, encoding: .utf8)
        return url
    }

    func hubFile(_ name: String, _ text: String) throws {
        try fm.createDirectory(at: hub, withIntermediateDirectories: true)
        try text.write(to: hub.appending(path: name), atomically: true, encoding: .utf8)
    }

    func item(running: [String] = [], owner: @escaping SafetyPolicy.OwnerID = SafetyPolicy.ownerID) -> CleanerItem {
        let applications = [home.appending(path: "Applications")]
        return UnityEditors.item(folders: { UnityEditors.editorFolders(applications: applications, home: $0.homeURL) },
                                 owner: owner, running: { running }, hasFullDiskAccess: { false }, pins: .init(),
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

    @Test func inDeveloperJunkAfterAndroidSDKComponents() throws {
        let items = CleanerGroup.developer.items
        let index = try #require(items.firstIndex { $0.id == UnityEditors.id })
        #expect(items[index - 1].id == AndroidSDKComponents.id && items[index + 1].id == UnityEditors.cachesID)
        let editors = items[index]
        #expect(editors.mode == .trash && !editors.selectedByDefault && editors.selectableEntries && !editors.showsWhenEmpty)
        #expect(editors.paths.isEmpty && editors.findEntries != nil && editors.allowsEntry != nil && editors.locksEntry != nil)
        // Not skipped whenever Unity runs: only a version a program runs from is locked.
        #expect(editors.runningAppBundleIDs.isEmpty && editors.runningProcessNames.isEmpty)
        let caches = items[index + 1]
        #expect(caches.mode == .delete && !caches.selectedByDefault && caches.selectableEntries && !caches.showsWhenEmpty)
        #expect(caches.runningAppBundleIDs == ["com.unity3d.UnityEditor*", "com.unity3d.unityhub"])
        #expect(caches.runningProcessNames == ["Unity", "Unity Hub"] && caches.skipsOpenFiles)
    }

    /// Three editors, a project pinning the oldest: only the middle one is listed, labelled and measured, unticked.
    @Test func listsOnlyVersionsNeitherNewestNorPinned() async throws {
        try editor("2021.3.30f1")
        try editor("2022.3.10f1")
        try editor("6000.0.23f1")
        try project("Developer/Games/Racer", "2021.3.30f1")
        let item = item()
        let result = await scan(item)
        #expect(result.entries.map(\.url.lastPathComponent) == ["2022.3.10f1"])
        #expect(result.entries.map(\.title) == ["Unity 2022.3.10f1"])
        #expect(result.entries.allSatisfy { $0.size >= 65_536 && $0.date != nil && $0.lockReason == nil })
        #expect(!item.selectedByDefault)
        // Without the project, the oldest is listed too; with only one editor, nothing.
        try fm.removeItem(at: home.appending(path: "Developer"))
        #expect(await listed(self.item()) == ["2021.3.30f1", "2022.3.10f1"])
        try fm.removeItem(at: editors.appending(path: "2021.3.30f1"))
        try fm.removeItem(at: editors.appending(path: "2022.3.10f1"))
        #expect(await listed(self.item()).isEmpty)
    }

    /// Hub's project list pins the versions it records and the ones its projects' ProjectVersion.txt name, wherever
    /// they are; a list that can't be read lists nothing.
    @Test func hubProjectListPins() async throws {
        try editor("2020.3.48f1")
        try editor("2021.3.30f1")
        try editor("2022.3.10f1")
        try editor("6000.0.23f1")
        let elsewhere = try project("Work/Client/App", "2022.3.10f1") // not in a project folder: only Hub knows it
        try hubFile(UnityEditors.projectsFile, """
            {"schema_version": "v1", "data": {
              "\(elsewhere.path)": {"title": "App", "path": "\(elsewhere.path)", "version": "2021.3.0f1"},
              "/Volumes/Gone/Old": {"title": "Old", "path": "/Volumes/Gone/Old", "version": "2021.3.30f1"}}}
            """)
        #expect(await listed(item()) == ["2020.3.48f1"])
        try hubFile(UnityEditors.projectsFile, "{\"data\": ")
        #expect(await listed(item()).isEmpty)
    }

    /// Editors in the install folder set in Hub are listed with the others and compared together.
    @Test func secondaryInstallFolder() async throws {
        let custom = root.appending(path: "home/Games/Unity Editors")
        try editor("2021.3.30f1", in: custom)
        try editor("2022.3.10f1")
        try editor("6000.0.23f1", in: custom)
        #expect(await listed(item()).isEmpty) // one editor in the default folder, the others not known yet
        try hubFile(UnityEditors.secondaryInstallFile, "\"\(custom.path)\"")
        #expect(UnityEditors.secondaryInstallFolder(home: home)?.path == custom.standardizedFileURL.path)
        #expect(await listed(item()) == ["2021.3.30f1", "2022.3.10f1"])
        try hubFile(UnityEditors.secondaryInstallFile, "\"\"")
        #expect(UnityEditors.secondaryInstallFolder(home: home) == nil)
        try hubFile(UnityEditors.secondaryInstallFile, "\"relative/path\"")
        #expect(UnityEditors.secondaryInstallFolder(home: home) == nil)
    }

    /// Only real version folders holding the Unity Editor's app; a folder whose app says another version is kept.
    @Test func recognisedByAppAndFolderName() async throws {
        try editor("6000.0.23f1")
        try editor("2022.3.10f1")
        try editor("2021.3.30f1", id: "com.example.other") // not Unity's bundle id
        try editor("2020.3.48f1", appVersion: "2020.3.47f1") // the app says another version: kept
        try editor("2019.4.40f1", appVersion: nil) // no version in the app: the folder's counts
        try editor("Custom Build") // not a version name: kept
        try fm.createDirectory(at: editors.appending(path: "2018.4.36f1"), withIntermediateDirectories: true) // no app
        let elsewhere = root.appending(path: "elsewhere")
        try editor("2017.4.40f1", in: elsewhere)
        try fm.createSymbolicLink(at: editors.appending(path: "2017.4.40f1"), withDestinationURL: elsewhere.appending(path: "2017.4.40f1"))
        try editor("2016.4.39f1", in: editors.appending(path: "Nested"))
        #expect(await listed(item()) == ["2019.4.40f1", "2022.3.10f1"])
        #expect(UnityEditors.install(at: editors.appending(path: "2017.4.40f1")) == nil) // a symlink
    }

    @Test func versionsAndKept() throws {
        #expect(Version("2022.3.9f1")! < Version("2022.3.10f1")!) // numbers, not text
        #expect(Version("2022.3.10f1")! < Version("6000.0.23f1")!)
        #expect(Version("2023.1.0a12")! < Version("2023.1.0b1")! && Version("2023.1.0b9")! < Version("2023.1.0f1")!)
        #expect(Version("2019.4.40f1")! < Version("2019.4.40f1c1")!)
        #expect(Version("2017.4.3f1")! < Version("2017.4.3p2")! && Version("2017.4.3p2")!.isRelease)
        #expect(Version("6000.1.0b2")!.isRelease == false)
        #expect(["6000", "2022.3", "2022.3.10", "2022.3.10f", "v2022.3.10f1", "2022.3.10f1 ", "latest"].map(Version.init)
            .filter { $0 != nil }.count == 1) // only the trailing space is trimmed
        #expect(UnityEditors.projectVersion("m_EditorVersion: 2022.3.10f1\nm_EditorVersionWithRevision: 2022.3.10f1 (x)\n")
            == Version("2022.3.10f1"))
        #expect(UnityEditors.projectVersion("m_EditorVersionWithRevision: 2022.3.10f1 (x)") == nil)

        func install(_ name: String) -> UnityEditors.Install {
            UnityEditors.Install(url: URL(fileURLWithPath: "/Applications/Unity/Hub/Editor/\(name)"), version: Version(name),
                                 appVersion: Version(name))
        }
        func kept(_ names: [String], pins: [String] = []) -> [String] {
            UnityEditors.kept(names.map(install), pins: Set(pins.compactMap(Version.init)))
                .map { ($0 as NSString).lastPathComponent }.sorted()
        }
        // A newer beta doesn't replace the newest release: both kept.
        #expect(kept(["2022.3.10f1", "2021.3.30f1", "6000.1.0b2"]) == ["2022.3.10f1", "6000.1.0b2"])
        #expect(kept(["2022.3.10f1", "2021.3.30f1", "6000.0.23f1"], pins: ["2021.3.30f1"]) == ["2021.3.30f1", "6000.0.23f1"])
        #expect(kept(["2022.3.10f1", "2022.3.9f1"]) == ["2022.3.10f1"])
        #expect(kept(["2022.3.10f1", "Custom"]) == ["2022.3.10f1", "Custom"])
    }

    /// Locked, matched by the path a program runs from: listed, not tickable, skipped at clean.
    @MainActor @Test func lockedWhileItsUnityRuns() async throws {
        try editor("6000.0.23f1")
        let old = try editor("2022.3.10f1")
        let reason = String(localized: "A program runs from this version, so it is kept")
        let running = item(running: [old.appending(path: "Unity.app/Contents/MacOS/Unity").path])
        let result = await scan(running)
        #expect(result.entries.map(\.lockReason) == [reason])
        // Another version's Unity, or a lookalike path, doesn't lock it.
        let other = item(running: [editors.path + "/6000.0.23f1/Unity.app/Contents/MacOS/Unity", old.path + "x/Unity.app"])
        #expect(await scan(other).entries.map(\.lockReason) == [nil])

        let model = SmartScanModel(module: .smartScan) { [CleanerGroup(id: "g", title: "G", systemImage: "x", items: [running])] }
        model.scans[running.id] = result
        #expect(model.lockedEntries(running).contains(old))
        let report = await Cleaner.clean(running, scan: result, policy: policy, trash: moveToFakeTrash,
                                         openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(report.skipped == 1 && report.trashed.isEmpty && fm.fileExists(atPath: old.path))
    }

    /// Root-owned or in a folder the user can't write to: a locked row with a reason, never a password prompt.
    @Test func lockedWhenOwnedByRoot() async throws {
        try editor("6000.0.23f1")
        let old = try editor("2022.3.10f1")
        let reason = String(localized: "Administrator privileges required — delete with Finder")
        let rootOwned = item(owner: { _ in 0 })
        let result = await scan(rootOwned)
        #expect(result.entries.map(\.lockReason) == [reason] && result.entries[0].size >= 65_536)
        let report = await Cleaner.clean(rootOwned, scan: result, policy: policy, trash: moveToFakeTrash,
                                         openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(report.skipped == 1 && report.trashed.isEmpty && fm.fileExists(atPath: old.path))

        try #require(chmod(editors.path, 0o555) == 0)
        defer { chmod(editors.path, 0o755) }
        #expect(await scan(item()).entries.map(\.lockReason) == [reason])
    }

    /// To the (fake) Trash, put back where it was by Undo; checked again right before: a version pinned since the
    /// scan stays.
    @Test func trashedAndPutBackByUndo() async throws {
        try editor("6000.0.23f1")
        try editor("2022.3.10f1")
        try editor("2021.3.30f1")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let result = await scan(item())
        #expect(result.entries.count == 2)

        try project("Projects/Puzzle", "2021.3.30f1")
        let report = await Cleaner.clean(item(), scan: result, policy: policy, trash: moveToFakeTrash,
                                         openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(report.skipped == 1 && report.trashed.count == 1)
        #expect(try Set(fm.contentsOfDirectory(atPath: editors.path)) == ["6000.0.23f1", "2021.3.30f1"])

        let undo = await TrashUndo.restore(report.trashed, module: "Smart Scan", home: home)
        #expect(undo == TrashUndo.Result(restored: 1, skipped: 0))
        #expect(try Set(fm.contentsOfDirectory(atPath: editors.path)) == ["6000.0.23f1", "2022.3.10f1", "2021.3.30f1"])
        #expect(fm.fileExists(atPath: editors.appending(path: "2022.3.10f1/Unity.app/Contents/MacOS/Unity").path))
    }

    @Test func policyRule() throws {
        let old = try editor("2022.3.10f1")
        #expect(policy.allowsUnityEditor(old, in: [editors]))
        #expect(!policy.allowsUnityEditor(old, in: [home.appending(path: "Applications")])) // not directly in the folder
        #expect(!policy.allowsUnityEditor(old, in: [editors], owner: { _ in 0 }))
        #expect(policy.allowsUnityEditor(old, in: [editors], writableOnly: false, owner: { _ in 0 }))
        #expect(!policy.allowsUnityEditor(try editor("2021.3.30f1", id: "com.example.other"), in: [editors]))
        #expect(!policy.allowsUnityEditor(try editor("Custom"), in: [editors]))
        #expect(!policy.allowsUnityEditor(editors.appending(path: "2020.3.48f1"), in: [editors])) // missing
        let excluded = SafetyPolicy(home: home, temp: root.appending(path: "tmp"), excluded: [old.path])
        #expect(!excluded.allowsUnityEditor(old, in: [editors]))
    }

    /// The cache and Asset Store downloads, one row each, deleted; Licenses and anything else never listed.
    @Test func cachesListOnlyCacheAndAssetStore() async throws {
        let unity = home.appending(path: "Library/Unity")
        for folder in ["cache/packages", "Asset Store-5.x/Publisher", "Licenses", "Other"] {
            try fm.createDirectory(at: unity.appending(path: folder), withIntermediateDirectories: true)
            try Data(repeating: 2, count: 4_096).write(to: unity.appending(path: folder + "/file"))
        }
        let item = UnityEditors.cachesItem()
        let result = await scan(item)
        #expect(result.entries.map(\.url.lastPathComponent).sorted() == ["Asset Store-5.x", "cache"])
        #expect(Set(result.entries.map(\.title)) == [String(localized: "Package and build cache"),
                                                     String(localized: "Downloaded Asset Store packages")])
        let report = await Cleaner.clean(item, scan: result, policy: policy, trash: moveToFakeTrash,
                                         openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(report.skipped == 0 && report.trashed.isEmpty)
        #expect(try Set(fm.contentsOfDirectory(atPath: unity.path)) == ["Licenses", "Other"])
        #expect(fm.fileExists(atPath: unity.appending(path: "Licenses/file").path))
    }
}
