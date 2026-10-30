import Foundation
import Testing
@testable import CleanMate

/// Unit tests for the small rules that decide what gets deleted: `Uninstaller.agentIsActive`,
/// `CleanerGroup.containerBundleID`, `CleanerGroup.skipsSandboxCache` and `CleanerGroup.skipsGroupCache`. Everything lives in a throwaway folder.
final class DeletionRulesTests {
    let root = TestTemp.url("CleanMateRules")
    deinit { try? FileManager.default.removeItem(at: root) }

    func write(_ plist: Any, to path: String) throws -> URL {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
        return url
    }

    // MARK: agentIsActive

    func agent(_ dict: [String: Any]) throws -> URL { try write(dict, to: "LaunchAgents/com.foo.agent.plist") }

    @Test func agentWithExistingProgramIsActive() throws {
        let program = root.appending(path: "bin/tool")
        try FileManager.default.createDirectory(at: program.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: program)
        #expect(Uninstaller.agentIsActive(try agent(["Label": "a", "Program": program.path])))
        #expect(Uninstaller.agentIsActive(try agent(["Label": "a", "ProgramArguments": [program.path, "--x"]])))
    }

    @Test func agentWithMissingProgramIsNotActive() throws {
        let gone = root.appending(path: "Gone.app/Contents/MacOS/Gone").path
        #expect(!Uninstaller.agentIsActive(try agent(["Label": "a", "Program": gone])))
        #expect(!Uninstaller.agentIsActive(try agent(["ProgramArguments": [gone]])))
        // `Program` wins over `ProgramArguments`.
        #expect(!Uninstaller.agentIsActive(try agent(["Program": gone, "ProgramArguments": ["/bin/sh"]])))
        #expect(!Uninstaller.agentIsActive(try agent(["Program": "~/CleanMate-no-such-\(UUID().uuidString)/tool"])))
        #expect(Uninstaller.agentIsActive(try agent(["Program": "~"])))
    }

    @Test func agentThatCannotBeJudgedCountsAsActive() throws {
        // Unreadable, missing or not a plist: never called a leftover.
        #expect(Uninstaller.agentIsActive(root.appending(path: "missing.plist")))
        let junk = root.appending(path: "junk.plist")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not a plist".utf8).write(to: junk)
        #expect(Uninstaller.agentIsActive(junk))
        #expect(Uninstaller.agentIsActive(try write(["/bin/sh"], to: "array.plist")))
        // No program key, empty arguments, wrong types, or a relative program resolved through PATH.
        #expect(Uninstaller.agentIsActive(try agent(["Label": "a"])))
        #expect(Uninstaller.agentIsActive(try agent(["ProgramArguments": [String]()])))
        #expect(Uninstaller.agentIsActive(try agent(["Program": 42])))
        #expect(Uninstaller.agentIsActive(try agent(["ProgramArguments": [1, "/gone"]])))
        #expect(Uninstaller.agentIsActive(try agent(["Program": "gone-tool"])))
        #expect(Uninstaller.agentIsActive(try agent(["Program": ""])))
    }

    // MARK: containerBundleID

    func containerEntry(_ folder: String, metadata: Any? = nil) throws -> URL {
        if let metadata { _ = try write(metadata, to: "Containers/\(folder)/.com.apple.containermanagerd.metadata.plist") }
        return root.appending(path: "Containers/\(folder)/Data/Library/Caches/entry")
    }

    @Test func containerIDComesFromMetadata() throws {
        let url = try containerEntry("8A1B-UUID", metadata: ["MCMMetadataIdentifier": "com.Foo.App"])
        #expect(CleanerGroup.containerBundleID(url) == "com.Foo.App") // case kept: compared with running bundle ids
    }

    @Test func containerIDFallsBackToFolderName() throws {
        #expect(CleanerGroup.containerBundleID(try containerEntry("com.foo.app")) == "com.foo.app")
        #expect(CleanerGroup.containerBundleID(try containerEntry("com.foo.app", metadata: ["Other": "x"])) == "com.foo.app")
        #expect(CleanerGroup.containerBundleID(try containerEntry("com.foo.app", metadata: ["MCMMetadataIdentifier": 7]))
            == "com.foo.app")
    }

    @Test func containerIDNeedsContainersLayout() {
        #expect(CleanerGroup.containerBundleID(root.appending(path: "Other/com.foo.app/Data/Library/Caches/entry")) == nil)
        #expect(CleanerGroup.containerBundleID(root.appending(path: "Containers/com.foo.app/Data/Library/Caches")) == nil)
        #expect(CleanerGroup.containerBundleID(root.appending(path: "Containers")) == nil)
    }

    @Test func sandboxCacheKeptWhileAppOrItsHelperOwnerRuns() throws {
        let helper = try containerEntry("com.foo.App.helper")
        #expect(CleanerGroup.skipsSandboxCache(helper, runningApps: ["com.foo.app"]))
        #expect(CleanerGroup.skipsSandboxCache(try containerEntry("com.foo.app.LoginItem"), runningApps: ["com.Foo.App"]))
        #expect(CleanerGroup.skipsSandboxCache(try containerEntry("com.foo.app"), runningApps: ["com.foo.app"]))
        #expect(!CleanerGroup.skipsSandboxCache(helper, runningApps: []))
        #expect(!CleanerGroup.skipsSandboxCache(try containerEntry("com.foo.appx"), runningApps: ["com.foo.app"]))
        #expect(!CleanerGroup.skipsSandboxCache(try containerEntry("com.foo"), runningApps: ["com.foo.app"]))
        #expect(CleanerGroup.skipsSandboxCache(try containerEntry("com.apple.Notes"), runningApps: []))
        #expect(CleanerGroup.skipsSandboxCache(root.appending(path: "Other/x/Data/Library/Caches/entry"), runningApps: []))
    }

    // MARK: skipsGroupCache

    func groupEntry(_ group: String, creator: Any?) throws -> URL {
        let metadata: [String: Any] = creator.map { ["MCMMetadataCreator": $0] } ?? ["MCMMetadataIdentifier": group]
        _ = try write(metadata, to: "Group Containers/\(group)/.com.apple.containermanagerd.metadata.plist")
        return root.appending(path: "Group Containers/\(group)/Library/Caches/entry")
    }

    @Test func groupCacheOfIdleVendorIsCleaned() throws {
        let url = try groupEntry("ABCDE12345.com.foo.shared", creator: "com.foo.app")
        #expect(!CleanerGroup.skipsGroupCache(url, runningApps: []))
        #expect(!CleanerGroup.skipsGroupCache(url, runningApps: ["com.bar.app", "com.foobar.app"]))
    }

    @Test func groupCacheKeptWhileSameVendorRuns() throws {
        // Office group: id has no vendor, the creator (Excel) gives `com.microsoft`; Word running keeps it.
        let office = try groupEntry("UBF8T346G9.Office", creator: "com.microsoft.Excel")
        #expect(CleanerGroup.skipsGroupCache(office, runningApps: ["com.microsoft.Word"]))
        #expect(CleanerGroup.skipsGroupCache(office, runningApps: ["COM.MICROSOFT.EXCEL"]))
        #expect(!CleanerGroup.skipsGroupCache(office, runningApps: ["com.apple.Safari"]))
        // Vendor from the group id when the creator is another vendor.
        let group = try groupEntry("group.com.foo.shared", creator: "com.bar.app")
        #expect(CleanerGroup.skipsGroupCache(group, runningApps: ["com.foo.helper"]))
        #expect(CleanerGroup.skipsGroupCache(group, runningApps: ["com.bar.other"]))
    }

    @Test func appleAndSharedGroupsAreKept() throws {
        #expect(CleanerGroup.skipsGroupCache(try groupEntry("group.com.apple.notes", creator: "com.apple.Notes"), runningApps: []))
        #expect(CleanerGroup.skipsGroupCache(try groupEntry("ABCDE12345.com.foo.x", creator: "com.apple.Foo"), runningApps: []))
        #expect(CleanerGroup.skipsGroupCache(try groupEntry("group.com.Apple.x", creator: "com.foo.app"), runningApps: []))
        #expect(CleanerGroup.skipsGroupCache(try groupEntry("group.is.workflow.shared", creator: "is.workflow.my"),
                                                 runningApps: []))
    }

    @Test func groupCacheWithUnknownOwnerIsKept() throws {
        // No metadata, no creator, empty or non-string creator, creator and group without any vendor.
        #expect(CleanerGroup.skipsGroupCache(root.appending(path: "Group Containers/g.com.foo/Library/Caches/e"),
                                                 runningApps: []))
        #expect(CleanerGroup.skipsGroupCache(try groupEntry("group.com.foo.a", creator: nil), runningApps: []))
        #expect(CleanerGroup.skipsGroupCache(try groupEntry("group.com.foo.b", creator: ""), runningApps: []))
        #expect(CleanerGroup.skipsGroupCache(try groupEntry("group.com.foo.c", creator: 3), runningApps: []))
        #expect(CleanerGroup.skipsGroupCache(try groupEntry("ABCDE12345.Office", creator: "Excel"), runningApps: []))
    }

    @Test func groupCacheNeedsGroupContainersLayout() throws {
        _ = try groupEntry("group.com.foo.d", creator: "com.foo.app")
        // Same metadata but the entry is not at `<group>/Library/Caches/<entry>`.
        #expect(CleanerGroup.skipsGroupCache(root.appending(path: "Group Containers/group.com.foo.d/Library/Caches"),
                                                 runningApps: []))
        #expect(CleanerGroup.skipsGroupCache(root.appending(path: "Group Containers/group.com.foo.d/Library/Caches/a/b"),
                                                 runningApps: []))
        #expect(CleanerGroup.skipsGroupCache(root.appending(path: "Containers/group.com.foo.d/Library/Caches/e"),
                                                 runningApps: []))
    }
}
