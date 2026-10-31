import Foundation
import Testing
@testable import CleanMate

/// Homebrew casks in the Uninstaller, against a fake Caskroom in a throwaway folder; brew never runs and nothing goes to
/// the real Trash.
final class HomebrewCaskTests {
    let root = TestTemp.url("CleanMateHomebrewCask")
    deinit { try? FileManager.default.removeItem(at: root) }
    var home: URL { root.appending(path: "home") }
    var prefix: URL { root.appending(path: "homebrew") }
    var applications: URL { home.appending(path: "Applications") }
    var policy: SafetyPolicy { SafetyPolicy(home: home, temp: root.appending(path: "tmp")) }

    @discardableResult
    func app(_ name: String, bundleID: String) throws -> URL {
        let url = applications.appending(path: name)
        try FileManager.default.createDirectory(at: url.appending(path: "Contents"), withIntermediateDirectories: true)
        let plist = ["CFBundleIdentifier": bundleID, "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: url.appending(path: "Contents/Info.plist"))
        return url
    }

    /// `Caskroom/<token>/<version>/` with `config.json` naming `appdir`; returns the version folder.
    @discardableResult
    func cask(_ token: String, version: String = "1.0", receipt: Any? = nil) throws -> URL {
        let folder = prefix.appending(path: "Caskroom/\(token)")
        let versionFolder = folder.appending(path: version)
        let metadata = folder.appending(path: ".metadata")
        try FileManager.default.createDirectory(at: versionFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["default": ["appdir": applications.path], "env": [:], "explicit": [:]])
            .write(to: metadata.appending(path: "config.json"))
        if let receipt {
            try JSONSerialization.data(withJSONObject: receipt).write(to: metadata.appending(path: "INSTALL_RECEIPT.json"))
        }
        return versionFolder
    }

    @Test func findsTheCaskOfAnAppBySymlinkReceiptOrSavedCask() throws {
        let linked = try app("Linked.app", bundleID: "com.foo.Linked")
        try FileManager.default.createSymbolicLink(at: try cask("linked").appending(path: "Linked.app"), withDestinationURL: linked)
        let renamed = try app("Renamed App.app", bundleID: "com.foo.Renamed")
        try cask("renamed", receipt: ["uninstall_artifacts": [["app": ["Source/Orig.app", ["target": "Renamed App.app"]]],
                                                              ["zap": [["trash": "~/Library/Preferences/x.plist"]]]]])
        let old = try app("Old.app", bundleID: "com.foo.Old")
        let saved = prefix.appending(path: "Caskroom/old/.metadata/1.0/20200101/Casks")
        try cask("old")
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
        try "cask \"old\" do\n  version \"1.0\"\n  app \"Old.app\"\nend\n".write(to: saved.appending(path: "old.rb"), atomically: true, encoding: .utf8)
        let plain = try app("Plain.app", bundleID: "com.foo.Plain")
        try Data("bin".utf8).write(to: try cask("ngrok").appending(path: "ngrok")) // a CLI cask: no app
        try FileManager.default.createDirectory(at: prefix.appending(path: "Caskroom/-bad"), withIntermediateDirectories: true)

        let casks = HomebrewCasks.installed(prefixes: [prefix.path])
        #expect(HomebrewCasks.cask(for: linked, in: casks) == HomebrewCask(token: "linked", prefix: prefix.path))
        #expect(HomebrewCasks.cask(for: renamed, in: casks)?.token == "renamed")
        #expect(HomebrewCasks.cask(for: old, in: casks)?.token == "old")
        #expect(HomebrewCasks.cask(for: plain, in: casks) == nil)
        #expect(Set(casks.values.map(\.token)) == ["linked", "renamed", "old"])
        #expect(HomebrewCasks.cask(for: linked, in: casks)?.brew == prefix.path + "/bin/brew")
    }

    @Test func uninstallCommandOnlyClearsTheRecord() {
        let command = HomebrewCasks.uninstallCommand(HomebrewCask(token: "zulu@17", prefix: "/opt/homebrew"))
        #expect(command.executable == "/opt/homebrew/bin/brew")
        #expect(command.arguments == ["uninstall", "--cask", "zulu@17"])
        #expect(command.environment["HOMEBREW_NO_AUTO_UPDATE"] == "1")
        #expect(HomebrewCasks.isToken("zulu@17") && HomebrewCasks.isToken("visual-studio-code"))
        #expect(!HomebrewCasks.isToken("--zap") && !HomebrewCasks.isToken("Foo") && !HomebrewCasks.isToken("a/b"))
    }

    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        func add(_ call: String) { lock.withLock { list.append(call) } }
        var all: [String] { lock.withLock { list } }
    }

    /// The app goes to the (fake) Trash first, then brew clears the record, then the data follows.
    @Test func trashesTheAppBeforeBrewClearsTheRecord() async throws {
        let appURL = try app("Linked.app", bundleID: "com.foo.Linked")
        let cache = home.appending(path: "Library/Caches/com.foo.Linked")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let calls = Calls()
        let report = try await Uninstaller.trash(
            app: appURL, data: [AppDataEntry(url: cache, size: 1)], policy: policy,
            cask: HomebrewCask(token: "linked", prefix: prefix.path), launchctl: { _ in true },
            moveToTrash: { calls.add("trash " + $0.lastPathComponent); return $0 }, isRunning: { _ in false },
            brewRunning: { false }, uninstallCask: { calls.add("brew uninstall --cask " + $0.token); return true })
        #expect(calls.all == ["trash Linked.app", "brew uninstall --cask linked", "trash com.foo.Linked"])
        #expect(report.casksLeft.isEmpty && report.trashed.count == 2)
        #expect(try String(contentsOf: ActivityLog.url(home: home), encoding: .utf8).contains("brew uninstall --cask linked\t1\t"))
    }

    /// brew fails: the app stays in the Trash (Undo puts it back), the token is reported, the log says "failed".
    @Test func brewFailureKeepsTheAppInTheTrashAndReportsTheCask() async throws {
        let appURL = try app("Linked.app", bundleID: "com.foo.Linked")
        let report = try await Uninstaller.trash(
            app: appURL, data: [], policy: policy, cask: HomebrewCask(token: "linked", prefix: prefix.path),
            launchctl: { _ in true }, moveToTrash: { $0 }, isRunning: { _ in false },
            brewRunning: { false }, uninstallCask: { _ in false })
        #expect(report.casksLeft == ["linked"] && report.trashed.map(\.original) == [appURL])
        let log = try String(contentsOf: ActivityLog.url(home: home), encoding: .utf8)
        #expect(log.split(separator: "\n").last?.hasSuffix("\tfailed\t0") == true)
    }

    /// While a brew command runs, a cask app is left alone; a plain app isn't affected.
    @Test func brewRunningLeavesTheCaskAppInPlace() async throws {
        let appURL = try app("Linked.app", bundleID: "com.foo.Linked")
        let calls = Calls()
        await #expect(throws: Uninstaller.AppTrashError.brewBusy) {
            try await Uninstaller.trash(app: appURL, data: [], policy: self.policy,
                                        cask: HomebrewCask(token: "linked", prefix: self.prefix.path), launchctl: { _ in true },
                                        moveToTrash: { calls.add("trash"); return $0 }, isRunning: { _ in false },
                                        brewRunning: { true }, uninstallCask: { _ in calls.add("brew"); return true })
        }
        #expect(calls.all.isEmpty)
        _ = try await Uninstaller.trash(app: appURL, data: [], policy: policy, launchctl: { _ in true },
                                        moveToTrash: { calls.add("trash"); return $0 }, isRunning: { _ in false },
                                        brewRunning: { true }, uninstallCask: { _ in calls.add("brew"); return true })
        #expect(calls.all == ["trash"])
    }

    @MainActor @Test func batchReportsBrewBusyAndUncleanedCasks() async throws {
        let first = InstalledApp(url: try app("A.app", bundleID: "com.foo.A"), name: "A", bundleID: "com.foo.A", version: nil, lastUsed: nil)
        let second = InstalledApp(url: try app("B.app", bundleID: "com.foo.B"), name: "B", bundleID: "com.foo.B", version: nil, lastUsed: nil)
        let model = UninstallerModel()
        model.appBundleIDs = { [] }
        model.runningApps = []
        model.apps = [first, second]
        model.appData = { _, _, _ in [] }
        model.trash = { app, _ throws(Uninstaller.AppTrashError) in
            if app == first.url { throw .brewBusy }
            var report = CleanReport()
            report.casksLeft = ["b"]
            return report
        }
        model.appTicks = [first.url, second.url]
        await model.removeBatch()
        guard case .batch(let result) = model.outcome else { Issue.record("\(String(describing: model.outcome))"); return }
        #expect(result.skipped.map(\.reason) == [.brewBusy] && result.removed == [second])
        let message = UninstallerView.batchMessage(result)
        #expect(message.contains("brew uninstall --cask b") && message.contains("A"))
    }
}
