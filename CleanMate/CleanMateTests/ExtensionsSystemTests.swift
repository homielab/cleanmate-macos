import Foundation
import Testing
@testable import CleanMate

/// Extensions of the system Library and audio plug-ins, against a throwaway home and fake `/Library`: nothing real is
/// moved and no password is asked (Finder is faked).
final class ExtensionsSystemTests {
    let root = TestTemp.url("CleanMateSystemExtensions")
    deinit { try? FileManager.default.removeItem(at: root) }
    var home: URL { root.appending(path: "home") }
    var library: URL { root.appending(path: "Library") }
    var userLibrary: URL { home.appending(path: "Library") }
    var policy: SafetyPolicy { SafetyPolicy(home: home, temp: root.appending(path: "tmp"), systemLibrary: library) }
    var trash: URL { root.appending(path: "Trash") }
    typealias FakeFinder = LaunchAgentsSystemTests.FakeFinder

    /// A bundle folder under `base`, with `Contents/Info.plist` holding `id` when given.
    @discardableResult
    func bundle(_ path: String, id: String? = nil, in base: URL? = nil, bytes: Int = 0) throws -> URL {
        let url = (base ?? library).appending(path: path)
        try FileManager.default.createDirectory(at: url.appending(path: "Contents"), withIntermediateDirectories: true)
        if let id {
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
                .write(to: url.appending(path: "Contents/Info.plist"))
        }
        if bytes > 0 { try Data(repeating: 1, count: bytes).write(to: url.appending(path: "Contents/payload")) }
        return url
    }

    @Test func listsSystemAndAudioKindsWithoutAppleOrCleanMate() async throws {
        try bundle("Audio/Plug-Ins/HAL/Loop.driver", id: "com.loopco.driver")
        try bundle("Audio/Plug-Ins/Components/Synth.component", id: "com.synthco.au")
        try bundle("Audio/Plug-Ins/VST3/Synth.vst3", id: "com.synthco.vst3")
        try bundle("Audio/Plug-Ins/VST/VendorFolder")                                    // not a plug-in: not listed
        try bundle("QuickLook/Mine.qlgenerator", id: "com.qlco.ql")
        try bundle("QuickLook/Apple.qlgenerator", id: "com.apple.qlgen")                  // Apple's by bundle id
        try bundle("Spotlight/com.apple.thing.mdimporter")                                // Apple's by name
        try bundle("PreferencePanes/Helper.prefPane", id: "com.homielab.CleanMate.pane") // CleanMate's
        try bundle("Audio/Plug-Ins/Components/User.component", id: "com.userco.au", in: userLibrary)

        let items = await Extensions.list(policy: policy)
        let byName = Dictionary(items.map { ($0.name, $0) }) { first, _ in first }
        #expect(Set(byName.keys) == ["Loop", "Synth", "Mine", "User"])
        #expect(items.filter { $0.name == "Synth" }.map(\.kind) == [.audio, .audio] && items.count == 5)
        #expect(items.allSatisfy { $0.trashable })
        #expect(byName["Loop"]?.kind == .audio && byName["Loop"]?.system == true && byName["Loop"]?.appRemoved == true)
        #expect(byName["Mine"]?.kind == .quickLook && byName["Mine"]?.system == true)
        #expect(byName["User"]?.kind == .audio && byName["User"]?.system == false)
        // No system Library in the policy: only ~/Library.
        let userOnly = await Extensions.list(policy: SafetyPolicy(home: home, temp: root.appending(path: "tmp")))
        #expect(userOnly.map(\.name) == ["User"])
    }

    @Test func policyAllowsOnlyThirdPartyExtensionsOfTheSystemFolders() throws {
        let allowed = ["Audio/Plug-Ins/HAL/A.driver", "Audio/Plug-Ins/Components/B.component", "Audio/Plug-Ins/VST/C.vst",
                       "Audio/Plug-Ins/VST3/D.vst3", "QuickLook/Q.qlgenerator", "Spotlight/S.mdimporter",
                       "PreferencePanes/P.prefPane", "Internet Plug-Ins/I.plugin", "Screen Savers/X.saver",
                       "Input Methods/IM.app", "Services/W.workflow"]
        let refused = ["Audio/Plug-Ins/HAL/Wrong.component", "Audio/Plug-Ins/VST/VendorFolder", "Audio/Plug-Ins/X.vst3",
                       "QuickLook/.Hidden.qlgenerator", "QuickLook/com.apple.x.qlgenerator", "Caches/C.qlgenerator",
                       "QuickLook/Q.qlgenerator/Contents/Nested.qlgenerator"]
        for path in allowed + refused { try bundle(path, id: "com.vendor.x") }
        try bundle("QuickLook/AppleID.qlgenerator", id: "com.apple.quicklook.x")
        try bundle("QuickLook/Own.qlgenerator", id: "com.homielab.cleanmate.ql")
        for path in allowed { #expect(policy.allowsSystemExtension(library.appending(path: path)), "\(path)") }
        for path in refused + ["QuickLook/AppleID.qlgenerator", "QuickLook/Own.qlgenerator", "QuickLook"] {
            #expect(!policy.allowsSystemExtension(library.appending(path: path)), "\(path)")
        }
        // A symlink, the user's own Library, no system Library, excluded.
        let link = library.appending(path: "QuickLook/Link.qlgenerator")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: library.appending(path: "QuickLook/Q.qlgenerator"))
        #expect(!policy.allowsSystemExtension(link))
        let user = try bundle("QuickLook/U.qlgenerator", id: "com.vendor.u", in: userLibrary)
        #expect(!policy.allowsSystemExtension(user) && policy.allowsUserExtension(user))
        #expect(!policy.allowsUserExtension(library.appending(path: "QuickLook/Q.qlgenerator")))
        let q = library.appending(path: "QuickLook/Q.qlgenerator")
        #expect(!SafetyPolicy(home: home, temp: root.appending(path: "tmp")).allowsSystemExtension(q))
        #expect(!SafetyPolicy(home: home, temp: root.appending(path: "tmp"), excluded: [q.path], systemLibrary: library)
            .allowsSystemExtension(q))
        // User audio plug-ins follow the user rule.
        #expect(policy.allowsUserExtension(try bundle("Audio/Plug-Ins/Components/U.component", id: "com.vendor.u", in: userLibrary)))
    }

    /// ~/Library items go one by one (kept for Undo), /Library ones in one Finder move (one password), not kept.
    @Test func trashMovesUserItemsThenSystemItemsInOneBatch() async throws {
        let user = try bundle("QuickLook/U.qlgenerator", id: "com.vendor.u", in: userLibrary, bytes: 10)
        let system1 = try bundle("Audio/Plug-Ins/HAL/A.driver", id: "com.vendor.a")
        let system2 = try bundle("PreferencePanes/P.prefPane", id: "com.vendor.p")
        let apple = try bundle("QuickLook/X.qlgenerator", id: "com.apple.x")
        let finder = FakeFinder(trash: trash)
        let userTrash = root.appending(path: "UserTrash")
        try FileManager.default.createDirectory(at: userTrash, withIntermediateDirectories: true)
        let entries = [AppDataEntry(url: user, size: 10), AppDataEntry(url: system1, size: 20, system: true),
                       AppDataEntry(url: system2, size: 30, system: true), AppDataEntry(url: apple, size: 5, system: true)]
        let report = await Extensions.trash(entries, policy: policy, inUse: { $0 == system2 }, trash: { url in
            let target = userTrash.appending(path: url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }, recycleAll: { finder.move($0) })
        #expect(finder.calls.count == 1 && finder.calls[0].map(\.lastPathComponent) == [system1.lastPathComponent]) // the pane in use and Apple's never go
        #expect(report.freed == 30 && report.trashed.map(\.original) == [user] && report.skipped == 2)
        #expect(!FileManager.default.fileExists(atPath: system1.path) && FileManager.default.fileExists(atPath: system2.path))
        #expect(TrashRecords.inTrash(home: home).map(\.original) == [user.path])
        #expect(ActivityLog.read(home: home).contains(system1.path))
    }

    @Test func cancelledPasswordKeepsSystemItemsAndSaysSo() async throws {
        let system = try bundle("Audio/Plug-Ins/HAL/A.driver", id: "com.vendor.a")
        let finder = FakeFinder(trash: trash, error: CocoaError(.userCancelled))
        let report = await Extensions.trash([AppDataEntry(url: system, size: 20, system: true)], policy: policy,
                                            recycleAll: { finder.move($0) })
        #expect(finder.calls.count == 1 && report.freed == 0 && report.skipped == 1)
        #expect(FileManager.default.fileExists(atPath: system.path))
        guard case .kept? = report.failures.first?.reason else { Issue.record("not kept: \(report.failures)"); return }
    }

    /// The app's own plug-ins (its bundle id or under it) join its data; another vendor's never do.
    @Test func uninstallScanGathersTheAppsPlugins() async throws {
        let app = InstalledApp(url: root.appending(path: "Applications/Synth.app"), name: "Synth", bundleID: "com.synthco.Synth",
                               version: nil, lastUsed: nil)
        let ql = try bundle("QuickLook/Synth.qlgenerator", id: "com.synthco.synth.quicklook", in: userLibrary)
        let au = try bundle("Audio/Plug-Ins/Components/Synth.component", id: "com.synthco.Synth")
        try bundle("Audio/Plug-Ins/Components/Other.component", id: "com.synthco.other")    // same vendor, another product
        try bundle("Spotlight/Synth.mdimporter", id: "com.otherco.synth", in: userLibrary)
        let entries = await Uninstaller.data(of: app, otherBundleIDs: [], tools: [:], policy: policy)
        let plugins = entries.filter { $0.url.path.contains("QuickLook") || $0.url.path.contains("Audio") || $0.url.path.contains("Spotlight") }
        #expect(Set(plugins.map(\.url.lastPathComponent)) == [ql.lastPathComponent, au.lastPathComponent])
        #expect(plugins.allSatisfy { $0.kind == .data })
        #expect(plugins.first { $0.url.lastPathComponent == "Synth.component" }?.system == true)
        #expect(plugins.first { $0.url.lastPathComponent == "Synth.component" }?.location == "/Library/Audio/Plug-Ins/Components")
        // An Apple-shaped or vague id gathers nothing.
        #expect(Extensions.owned(by: "com.apple.Safari", policy: policy).isEmpty && Extensions.owned(by: "Synth", policy: policy).isEmpty)

        // Uninstall moves them: the user one by one, the system one through Finder.
        let finder = FakeFinder(trash: trash)
        let report = try await Uninstaller.trash(app: nil, data: plugins, policy: policy, moveToTrash: { url in
            let target = self.root.appending(path: "UserTrash-\(url.lastPathComponent)")
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }, recycleAll: { finder.move($0) })
        #expect(report.skipped == 0 && finder.calls.count == 1)
        #expect(!FileManager.default.fileExists(atPath: ql.path) && !FileManager.default.fileExists(atPath: au.path))
    }

    @Test func commandLineListsExtensions() async throws {
        #expect(try CommandLineTool.parse(["uninstall", "--extensions", "--json"]) == .extensionsList(json: true))
        for arguments in [["uninstall", "--extensions", "Synth"], ["uninstall", "--extensions", "--yes"],
                          ["uninstall", "--extensions", "--leftovers"]] {
            #expect(throws: CommandLineTool.UsageError.self, "\(arguments)") { try CommandLineTool.parse(arguments) }
        }
        try bundle("Audio/Plug-Ins/HAL/Loop.driver", id: "com.loopco.driver", bytes: 4096)
        try bundle("Services/Resize.workflow", in: userLibrary)
        var sources = HeadlessScan.Sources()
        let policy = policy
        sources.policy = { policy }
        sources.runningApps = { [:] }
        sources.version = { "9.9" }
        let (code, printed) = await CommandLineModulesTests.run(["uninstall", "--extensions", "--json"], sources)
        #expect(code == 0)
        let report = try CommandLineModulesTests.decode(HeadlessApps.ExtensionsReport.self, printed)
        #expect(report.count == 2 && report.version == "9.9")
        let loop = try #require(report.items.first { $0.name == "Loop" })
        #expect(loop.kind == "audio" && loop.system && loop.appRemoved && loop.removable && loop.size >= 4096)
        #expect(loop.bundleId == "com.loopco.driver" && loop.owner == nil)
        let service = try #require(report.items.first { $0.name == "Resize" })
        #expect(service.kind == "service" && !service.system && service.bundleId == nil && service.path == "~/Library/Services/Resize.workflow")
        #expect(printed.stdout.contains("\"bundleId\" : null") || printed.stdout.contains("\"bundleId\":null"))
        let (_, text) = await CommandLineModulesTests.run(["uninstall", "--extensions"], sources)
        #expect(text.stdout.contains("Loop") && text.stdout.contains("app removed"))
    }
}
