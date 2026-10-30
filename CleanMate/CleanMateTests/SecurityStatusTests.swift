import Foundation
import Testing
@testable import CleanMate

/// The Overview's "System protection" group: parsers on real command output, and the model with an injected reader.
/// No status command runs here.
@Suite(.timeLimit(.minutes(1)))
struct SecurityStatusTests {
    @Test func gatekeeperOutput() {
        #expect(SecurityStatus.gatekeeper("assessments enabled\n") == .on)
        #expect(SecurityStatus.gatekeeper("assessments disabled\n") == .off)
        #expect(SecurityStatus.gatekeeper("spctl: unexpected\n") == .unknown)
        #expect(SecurityStatus.gatekeeper(nil) == .unknown)
    }

    @Test func firewallOutput() {
        #expect(SecurityStatus.firewall("Firewall is enabled. (State = 1)\n") == .on)
        #expect(SecurityStatus.firewall("Firewall is blocking all non-essential incoming connections. (State = 2)\n") == .on)
        #expect(SecurityStatus.firewall("Firewall is disabled. (State = 0)\n") == .off)
        #expect(SecurityStatus.firewall("Firewall is enabled.\n") == .on)
        #expect(SecurityStatus.firewall("") == .unknown)
        #expect(SecurityStatus.firewall(nil) == .unknown)
    }

    @Test func sipOutput() {
        #expect(SecurityStatus.sip("System Integrity Protection status: enabled.\n") == .on)
        #expect(SecurityStatus.sip("System Integrity Protection status: disabled.\n") == .off)
        let custom = """
        System Integrity Protection status: unknown (Custom Configuration).

        Configuration:
        \tApple Internal: disabled
        \tKext Signing: disabled
        \tFilesystem Protections: enabled

        This is an unsupported configuration, likely to break in the future and leave your machine in an unknown state.
        """
        #expect(SecurityStatus.sip(custom) == .off)
        #expect(SecurityStatus.sip("csrutil: failed\n") == .unknown)
        #expect(SecurityStatus.sip(nil) == .unknown)
    }

    @Test func fileVaultOutput() {
        #expect(SecurityStatus.fileVault("FileVault is On.\n") == .on)
        #expect(SecurityStatus.fileVault("FileVault is Off.\n") == .off)
        #expect(SecurityStatus.fileVault("FileVault is Off, but will be enabled after the next restart.\n") == .off)
        #expect(SecurityStatus.fileVault("Encryption in progress: Percent completed = 34\n") == .on)
        #expect(SecurityStatus.fileVault("Decryption in progress: Percent completed = 80\n") == .off)
        #expect(SecurityStatus.fileVault("Error: unexpected\n") == .unknown)
        #expect(SecurityStatus.fileVault(nil) == .unknown)
    }

    static let xprotectPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
    \t<key>CFBundleIdentifier</key>
    \t<string>com.apple.XProtect</string>
    \t<key>CFBundleShortVersionString</key>
    \t<string>5368</string>
    \t<key>InstallationTime</key>
    \t<date>2026-10-22T15:46:52Z</date>
    </dict>
    </plist>
    """

    @Test func xprotectPlist() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(SecurityStatus.xprotect(plist: Data(Self.xprotectPlist.utf8), modified: date)
            == .init(version: "5368", date: date))
        #expect(SecurityStatus.xprotect(plist: Data("not a plist".utf8), modified: date) == nil)
        #expect(SecurityStatus.xprotect(plist: nil, modified: nil) == nil)
        let noVersion = Self.xprotectPlist.replacingOccurrences(of: "CFBundleShortVersionString", with: "Other")
        #expect(SecurityStatus.xprotect(plist: Data(noVersion.utf8), modified: date) == nil)
    }

    /// Highest version wins, then the newest file; unreadable bundles are skipped.
    @Test func newestXProtectBundle() throws {
        let root = TestTemp.url("CleanMateSecurity")
        defer { try? FileManager.default.removeItem(at: root) }
        func bundle(_ name: String, version: String, daysAgo: Double) throws -> String {
            let contents = root.appending(path: "\(name)/XProtect.bundle/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist = contents.appending(path: "Info.plist")
            try Data(Self.xprotectPlist.replacingOccurrences(of: "5368", with: version).utf8).write(to: plist)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -daysAgo * 86_400)],
                                                  ofItemAtPath: plist.path)
            return contents.deletingLastPathComponent().path
        }
        let shipped = try bundle("shipped", version: "5299", daysAgo: 30)
        let updated = try bundle("updated", version: "5368", daysAgo: 8)
        let copy = try bundle("copy", version: "5368", daysAgo: 2)
        let missing = root.appending(path: "missing/XProtect.bundle").path
        #expect(SecurityStatus.newestXProtect(bundles: [shipped, missing, updated])?.version == "5368")
        let newest = try #require(SecurityStatus.newestXProtect(bundles: [shipped, updated, copy]))
        #expect(abs(try #require(newest.date).timeIntervalSinceNow + 2 * 86_400) < 60)
        #expect(SecurityStatus.newestXProtect(bundles: [missing]) == nil)
    }

    /// The model shows each state from an injected reader; a reminder (and a Settings button except for SIP) only
    /// when off.
    @MainActor @Test func modelShowsOnOffAndUnknown() async throws {
        let status = SecurityStatus(gatekeeper: .on, firewall: .off, sip: .off, fileVault: .unknown,
                                    xprotect: .init(version: "5368", date: nil))
        let model = OverviewModel(center: NotificationCenter())
        model.home = TestTemp.url("CleanMateSecurityHome")
        model.readDisks = { [] }
        model.measure = { _, _, _ in (0, [:]) }
        model.readSecurity = { status }
        #expect(model.security == nil)
        model.refresh()
        while model.security == nil { try await Task.sleep(for: .milliseconds(5)) }
        model.cancel()

        let checks = try #require(model.security?.checks)
        #expect(checks.map(\.kind) == SecurityStatus.Kind.allCases)
        #expect(checks.map(\.state) == [.on, .off, .off, .unknown, .on])
        #expect(checks.map { $0.reminder != nil } == [false, true, true, false, false])
        #expect(checks.map { $0.settingsURL != nil } == [false, true, false, false, false])
        #expect(SecurityStatus.Kind.allCases.allSatisfy { $0 == .sip || $0 == .xprotect || $0.settingsURL != nil })

        // Every command failed: all unknown, no reminder.
        let unknown = SecurityStatus().checks
        #expect(unknown.allSatisfy { $0.state == .unknown && $0.reminder == nil && $0.settingsURL == nil })
    }

    /// Under tests the default reader runs nothing and reports every protection as unknown.
    @MainActor @Test func defaultReaderRunsNothingUnderTests() async {
        #expect(await OverviewModel().readSecurity() == SecurityStatus())
    }

    /// `spctl --status` exits 1 when assessments are disabled: its output must still be read.
    @Test func outputOfAFailingToolIsKeptWhenAsked() async {
        let script = ["-c", "echo assessments disabled; exit 1"]
        #expect(await ShellCommand(executable: "/bin/sh", arguments: script).output() == nil)
        #expect(await ShellCommand(executable: "/bin/sh", arguments: script, requiresSuccess: false).output()
            == "assessments disabled\n")
        #expect(await ShellCommand(executable: "/bin/sleep", arguments: ["30"], timeout: .milliseconds(300),
                                   requiresSuccess: false).output() == nil)
    }
}
