import Foundation
import Testing
@testable import CleanMate

/// Settings › Integrations › Command Line Tool: the link in ~/.local/bin, in a fake home with fake apps.
final class CommandLineInstallTests {
    let fm = FileManager.default
    let root = TestTemp.url("CleanMateCLIInstall")
    var home: URL { root.appending(path: "home") }
    var link: URL { CommandLineInstall.link(home: home) }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// A fake `<name>.app` with its helper file; returns the helper's URL.
    @discardableResult
    func app(_ name: String, in folder: String = "Apps") throws -> URL {
        let helper = root.appending(path: "\(folder)/\(name).app/Contents/Helpers/cleanmate")
        try fm.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: helper)
        return helper
    }

    func status(_ helper: URL) -> CommandLineInstall.Status { CommandLineInstall.status(home: home, helper: helper) }

    @Test func installCreatesTheFolderAndTheLink() throws {
        let helper = try app("Fake")
        #expect(!fm.fileExists(atPath: home.appending(path: ".local/bin").path))
        #expect(status(helper) == .notInstalled)
        try CommandLineInstall.install(home: home, helper: helper)
        #expect(status(helper) == .installed)
        #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == helper.path)
    }

    @Test func installingTwiceKeepsOneLink() throws {
        let helper = try app("Fake")
        try CommandLineInstall.install(home: home, helper: helper)
        try CommandLineInstall.install(home: home, helper: helper)
        #expect(status(helper) == .installed)
        #expect(try fm.contentsOfDirectory(atPath: link.deletingLastPathComponent().path) == ["cleanmate"])
    }

    @Test func removeDeletesTheLinkOnly() throws {
        let helper = try app("Fake")
        try CommandLineInstall.install(home: home, helper: helper)
        try CommandLineInstall.remove(home: home)
        #expect(status(helper) == .notInstalled)
        #expect(fm.fileExists(atPath: home.appending(path: ".local/bin").path))
        #expect(fm.fileExists(atPath: helper.path))
        try CommandLineInstall.remove(home: home) // nothing there: no error
    }

    @Test func movedAppIsBrokenUntilRepaired() throws {
        let old = try app("Fake", in: "Old")
        try CommandLineInstall.install(home: home, helper: old)
        let new = try app("Fake", in: "New")
        try fm.removeItem(at: old)
        #expect(status(new) == .broken(old.standardizedFileURL.path))
        try CommandLineInstall.install(home: home, helper: new)
        #expect(status(new) == .installed)
    }

    @Test func anotherCopyIsReportedAndRepointed() throws {
        let other = try app("Other")
        let mine = try app("Mine")
        try CommandLineInstall.install(home: home, helper: other)
        #expect(status(mine) == .otherCopy(other.standardizedFileURL.path))
        try CommandLineInstall.install(home: home, helper: mine)
        #expect(status(mine) == .installed)
    }

    @Test func aRegularFileIsNeverTouched() throws {
        let helper = try app("Fake")
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: link)
        #expect(status(helper) == .foreign)
        #expect(throws: CommandLineInstall.Failure.foreignFile) { try CommandLineInstall.install(home: home, helper: helper) }
        #expect(throws: CommandLineInstall.Failure.foreignFile) { try CommandLineInstall.remove(home: home) }
        #expect(try String(contentsOf: link, encoding: .utf8) == "mine")
    }

    @Test func aLinkToAnotherToolIsNeverTouched() throws {
        let helper = try app("Fake")
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "/bin/ls")
        #expect(status(helper) == .foreign)
        #expect(throws: CommandLineInstall.Failure.foreignFile) { try CommandLineInstall.install(home: home, helper: helper) }
        #expect(throws: CommandLineInstall.Failure.foreignFile) { try CommandLineInstall.remove(home: home) }
        #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == "/bin/ls")
    }

    @Test func refusesATranslocatedOrIncompleteApp() throws {
        let moved = try app("Fake", in: "AppTranslocation/ABC")
        #expect(throws: CommandLineInstall.Failure.translocated) { try CommandLineInstall.install(home: home, helper: moved) }
        let missing = root.appending(path: "Gone.app/Contents/Helpers/cleanmate")
        #expect(throws: CommandLineInstall.Failure.helperMissing) { try CommandLineInstall.install(home: home, helper: missing) }
        #expect(!fm.fileExists(atPath: home.appending(path: ".local").path))
    }

    @Test func pathCheckReadsTheEnvironment() throws {
        let folder = home.appending(path: ".local/bin").path
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        #expect(CommandLineInstall.onPath(home: home, environment: ["PATH": "\(folder):/usr/bin"]))
        #expect(!CommandLineInstall.onPath(home: home, environment: ["PATH": "/usr/bin"]))
        #expect(!CommandLineInstall.onPath(home: home, environment: [:]))
    }
}
