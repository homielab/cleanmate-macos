import Foundation
import Testing
@testable import CleanMate

/// CocoaPods spec repo clones and Xcode's documentation cache and device logs in Developer Junk, in a throwaway fake home.
final class XcodeCocoaPodsJunkTests {
    private let root = TestTemp.url("CleanMateXcodePods")
    private var home: URL { root.appending(path: "home") }
    private var policy: SafetyPolicy { SafetyPolicy(home: home, temp: root.appending(path: "tmp")) }

    init() throws {
        for dir in ["home", "tmp"] { try FileManager.default.createDirectory(at: root.appending(path: dir), withIntermediateDirectories: true) }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    private func file(_ path: String) throws -> URL {
        let url = home.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 40_000).write(to: url)
        return url
    }

    private func item(_ id: String) throws -> CleanerItem { try #require(CleanerGroup.developer.items.first { $0.id == id }) }

    @Test func catalogItems() throws {
        for id in ["cocoapods-spec-repos", "xcode-documentation-cache", "xcode-device-logs"] {
            let item = try item(id)
            #expect(!item.selectedByDefault && item.mode == .delete && item.command == nil && !item.showsWhenEmpty, "\(id)")
        }
        #expect(try item("cocoapods-spec-repos").runningProcessNames == ["pod"])
        #expect(try item("xcode-device-logs").runningAppBundleIDs == ["com.apple.dt.Xcode"])
        #expect(try item("xcode-documentation-cache").runningAppBundleIDs == ["com.apple.dt.Xcode"])
    }

    /// Only git clones are listed: `trunk` (the CDN index) stays.
    @Test func specReposListsGitClonesOnly() async throws {
        let item = try item("cocoapods-spec-repos")
        try file(".cocoapods/repos/master/.git/HEAD")
        try file(".cocoapods/repos/master/Specs/0/0/0/A/1.0/A.podspec.json")
        try file(".cocoapods/repos/trunk/Specs/0/0/0/A/1.0/A.podspec.json")
        let scan = await Scanner.scan(item, policy: policy)
        #expect(scan.entries.map(\.url.lastPathComponent) == ["master"])
        let report = await Cleaner.clean(item, scan: scan, policy: policy)
        #expect(report.skipped == 0)
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: ".cocoapods/repos/master").path))
        #expect(FileManager.default.fileExists(atPath: home.appending(path: ".cocoapods/repos/trunk/Specs").path))
    }

    @Test func xcodeFoldersListed() async throws {
        try file("Library/Developer/Xcode/DocumentationCache/v1/index.db")
        try file("Library/Developer/Xcode/iOS Device Logs/iPhone.logarchive")
        try file("Library/Developer/Xcode/watchOS Device Logs/Watch.log")
        try file("Library/Developer/Xcode/DerivedData/App-abc/x")
        let docs = await Scanner.scan(try item("xcode-documentation-cache"), policy: policy)
        #expect(docs.entries.map(\.url.lastPathComponent) == ["v1"])
        let logs = await Scanner.scan(try item("xcode-device-logs"), policy: policy)
        #expect(Set(logs.entries.map(\.url.lastPathComponent)) == ["iPhone.logarchive", "Watch.log"])
    }

    @MainActor @Test func lockedWhileToolRuns() throws {
        let model = SmartScanModel(module: .smartScan) { [] }
        model.runningProcesses = ["pod"]
        #expect(try model.isRunning(item("cocoapods-spec-repos")) && !model.isRunning(item("xcode-device-logs")))
        model.runningProcesses = []
        model.runningApps = ["com.apple.dt.Xcode"]
        #expect(try !model.isRunning(item("cocoapods-spec-repos")) && model.isRunning(item("xcode-documentation-cache"))
            && model.isRunning(item("xcode-device-logs")))
    }
}
