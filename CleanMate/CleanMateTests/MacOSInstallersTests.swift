import Foundation
import Testing
@testable import CleanMate

/// macOS installer apps: a fake home in a throwaway folder, its ~/Applications searched instead of the real
/// /Applications (never read nor touched), and a fake Trash.
final class MacOSInstallersTests {
    let fm = FileManager.default
    let root = TestTemp.url("CleanMateMacOSInstallers")
    var home: URL { root.appending(path: "home") }
    var applications: URL { home.appending(path: "Applications") }
    var trash: URL { root.appending(path: "Trash") }
    var policy: SafetyPolicy { SafetyPolicy(home: home, temp: root.appending(path: "tmp")) }

    deinit {
        chmod(home.appending(path: "Applications").path, 0o755)
        try? FileManager.default.removeItem(at: root)
    }

    /// The catalog's item, searching only `folders` (the fake ~/Applications unless given).
    func item(folders: [URL]? = nil, owner: @escaping SafetyPolicy.OwnerID = SafetyPolicy.ownerID) -> CleanerItem {
        let folders = folders ?? [applications]
        return MacOSInstallers.item(folders: { _ in folders }, owner: owner)
    }

    /// An app bundle at `url` with `info` as its Info.plist (none when nil) and a 64 KB disk image inside.
    func bundle(_ url: URL, info: [String: String]?, installInfo: String? = nil) throws {
        let contents = url.appending(path: "Contents")
        try fm.createDirectory(at: contents.appending(path: "SharedSupport"), withIntermediateDirectories: true)
        if let info { try (info as NSDictionary).write(to: contents.appending(path: "Info.plist")) }
        if let installInfo {
            try (["System Image Info": ["version": installInfo]] as NSDictionary)
                .write(to: contents.appending(path: "SharedSupport/InstallInfo.plist"))
        }
        try Data(repeating: 1, count: 65_536).write(to: contents.appending(path: "SharedSupport/SharedSupport.dmg"))
    }

    func installer(_ name: String, in folder: URL? = nil, id: String = "com.apple.InstallAssistant.macOSSequoia",
                   version: String = "20.1.01", installInfo: String? = nil) throws {
        try bundle((folder ?? applications).appending(path: name + ".app"),
                   info: ["CFBundleIdentifier": id, "CFBundleShortVersionString": version], installInfo: installInfo)
    }

    var moveToFakeTrash: @Sendable (URL) throws -> URL? {
        let trash = trash
        return { url in
            let target = trash.appending(path: UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }
    }

    func listed(_ item: CleanerItem, policy: SafetyPolicy? = nil) async -> [String] {
        await Scanner.scan(item, policy: policy ?? self.policy, openPaths: EndToEndCleanTests.ownOpenPaths)
            .entries.map(\.url.lastPathComponent).sorted()
    }

    @Test func inSystemJunkUntickedToTheTrash() throws {
        for fda in [false, true] { // /Applications is not a protected folder: no Full Disk Access needed
            let group = try #require(CleanerGroup.smartScan(ages: .default, hasFullDiskAccess: fda).first { $0.id == "system-junk" })
            let item = try #require(group.items.first { $0.id == MacOSInstallers.id })
            #expect(item.mode == .trash && !item.selectedByDefault && item.selectableEntries && !item.showsWhenEmpty)
            #expect(item.paths.isEmpty && item.findEntries != nil && item.allowsEntry != nil && item.entryLabel != nil)
            #expect(item.runningAppBundleIDs == ["com.apple.InstallAssistant*"])
            #expect(item.runningProcessNames.contains("startosinstall") && item.runningProcessNames.contains("createinstallmedia"))
        }
        #expect(policy.applicationFolders.map(\.path) == ["/Applications", (home.path as NSString).resolvingSymlinksInPath + "/Applications"])
    }

    /// Only real installer bundles directly in Applications, each one row named after it with its version and size.
    @Test func listsOnlyInstallerBundles() async throws {
        try installer("Install macOS Sequoia")
        try installer("Install OS X El Capitan", id: "com.apple.InstallAssistant.ElCapitan", installInfo: "10.11.6")
        try installer("install macos sonoma beta", id: "com.apple.InstallAssistant.macOSSonoma") // any case
        try installer("Install macOS Fake", id: "com.example.fake") // same name, not Apple's installer
        try installer("Install macOS Other", id: "com.apple.Safari") // Apple's, but not an installer
        try bundle(applications.appending(path: "Install macOS NoInfo.app"), info: nil)
        try installer("Sequoia Installer") // installer bundle id, other name
        try installer("Install macOS Deep", in: applications.appending(path: "Sub")) // not at the top level
        try fm.createDirectory(at: applications.appending(path: "Install macOS File.app.d"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: applications.appending(path: "Install macOS Plain.app")) // a file
        // A symlink to a real installer elsewhere: neither followed nor trashed.
        let elsewhere = root.appending(path: "elsewhere")
        try installer("Install macOS Ventura", in: elsewhere)
        try fm.createSymbolicLink(at: applications.appending(path: "Install macOS Link.app"),
                                  withDestinationURL: elsewhere.appending(path: "Install macOS Ventura.app"))
        // Downloads is never searched; even when handed one, the policy refuses it ("Old installers" lists Downloads).
        let downloads = home.appending(path: "Downloads")
        try installer("Install macOS Monterey", in: downloads)

        let scan = await Scanner.scan(item(folders: [applications, downloads]), policy: policy,
                                      openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(scan.entries.map(\.url.lastPathComponent).sorted()
                 == ["Install OS X El Capitan.app", "Install macOS Sequoia.app", "install macos sonoma beta.app"])
        #expect(scan.entries.allSatisfy { $0.size >= 65_536 })
        let labels = Dictionary(uniqueKeysWithValues: scan.entries.map { ($0.url.lastPathComponent, $0.title) })
        #expect(labels["Install macOS Sequoia.app"] == "Install macOS Sequoia · 20.1.01")
        #expect(labels["Install OS X El Capitan.app"] == "Install OS X El Capitan · 10.11.6") // the macOS version when recorded
    }

    @Test func installerNames() {
        #expect(MacOSInstallers.isInstallerName("Install macOS Sequoia.app"))
        #expect(MacOSInstallers.isInstallerName("Install OS X Yosemite.app"))
        #expect(MacOSInstallers.isInstallerName("INSTALL MACOS 15 BETA.APP"))
        #expect(!MacOSInstallers.isInstallerName("Install macOS .app"))
        #expect(!MacOSInstallers.isInstallerName("Install macOS Sequoia"))
        #expect(!MacOSInstallers.isInstallerName("Install Xcode.app"))
        #expect(!MacOSInstallers.isInstallerName("My Install macOS Sequoia.app"))
    }

    /// Never a password prompt: an installer owned by root, or one in a folder the user can't write to, is not listed,
    /// and one that became so after the scan is skipped at clean.
    @Test func onlyWhatTheUserCanMoveWithoutAPassword() async throws {
        try installer("Install macOS Sequoia")
        #expect(await listed(item(owner: { _ in 0 })).isEmpty)
        #expect(!policy.allowsMacOSInstaller(applications.appending(path: "Install macOS Sequoia.app"), owner: { _ in 0 }))

        let scan = await Scanner.scan(item(), policy: policy, openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(scan.entries.count == 1)
        let report = await Cleaner.clean(item(owner: { _ in 0 }), scan: scan, policy: policy, trash: moveToFakeTrash,
                                         openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(report.skipped == 1 && report.trashed.isEmpty)

        try #require(chmod(applications.path, 0o555) == 0)
        defer { chmod(applications.path, 0o755) }
        #expect(await listed(item()).isEmpty)
    }

    @Test func excludedInstallerIsKept() async throws {
        try installer("Install macOS Sequoia")
        try installer("Install macOS Sonoma", id: "com.apple.InstallAssistant.macOSSonoma")
        let excluded = SafetyPolicy(home: home, temp: root.appending(path: "tmp"),
                                    excluded: [applications.appending(path: "Install macOS Sonoma.app").path])
        #expect(await listed(item(), policy: excluded) == ["Install macOS Sequoia.app"])
    }

    /// To the (fake) Trash, and put back by Undo.
    @Test func trashedAndPutBackByUndo() async throws {
        try installer("Install macOS Sequoia")
        try installer("Install macOS Sonoma", id: "com.apple.InstallAssistant.macOSSonoma")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let item = item()
        let scan = await Scanner.scan(item, policy: policy, openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(scan.entries.count == 2)
        let report = await Cleaner.clean(item, scan: scan, policy: policy, trash: moveToFakeTrash,
                                         openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(report.skipped == 0 && report.freed == scan.size && report.trashed.count == 2)
        #expect(try fm.contentsOfDirectory(atPath: applications.path).isEmpty)

        let undo = await TrashUndo.restore(report.trashed, module: "Smart Scan", home: home)
        #expect(undo == TrashUndo.Result(restored: 2, skipped: 0))
        #expect(try Set(fm.contentsOfDirectory(atPath: applications.path)) == ["Install macOS Sequoia.app", "Install macOS Sonoma.app"])
    }

    /// While an installer or one of its tools runs, the item is locked: not ticked, counted nor cleaned.
    @MainActor @Test func skippedWhileAnInstallerRuns() {
        let item = item()
        let model = SmartScanModel(module: .smartScan) { [CleanerGroup(id: "g", title: "G", systemImage: "x", items: [item])] }
        model.runningApps = []
        for name in ["InstallAssistant", "InstallAssistant_springboard", "startosinstall", "createinstallmedia", "osinstallersetupd"] {
            model.runningProcesses = [name, "zsh"]
            #expect(model.isRunning(item), "\(name)")
        }
        model.runningProcesses = ["zsh"]
        #expect(!model.isRunning(item))
        model.runningApps = ["com.apple.InstallAssistant.macOSSequoia"]
        #expect(model.isRunning(item))
    }
}
