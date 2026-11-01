import Foundation

/// Whether macOS's own protections are on: Gatekeeper, the firewall, System Integrity Protection, FileVault and the
/// XProtect version. Read-only: runs the status commands a user could run in Terminal, without admin rights, and
/// changes nothing.
nonisolated struct SecurityStatus: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case on, off
        /// The command failed, timed out or printed something unexpected.
        case unknown
    }

    struct XProtect: Equatable, Sendable {
        var version: String
        /// When the definitions were installed: the modification date of the bundle's Info.plist.
        var date: Date?
    }

    enum Kind: CaseIterable, Sendable {
        case gatekeeper, firewall, sip, fileVault, xprotect

        var title: LocalizedStringResource {
            switch self {
            case .gatekeeper: "Gatekeeper"
            case .firewall: "Firewall"
            case .sip: "System Integrity Protection"
            case .fileVault: "FileVault"
            case .xprotect: "XProtect"
            }
        }

        var help: LocalizedStringResource {
            switch self {
            case .gatekeeper: "Checks that apps you open come from the App Store or identified developers."
            case .firewall: "Blocks unwanted incoming connections to apps on this Mac."
            case .sip: "Stops any app, even with admin rights, from changing macOS system files."
            case .fileVault: "Encrypts the startup disk so it can't be read without your password."
            case .xprotect: "The malware definitions macOS checks apps against, updated automatically."
            }
        }

        /// Shown under the row when the protection is off.
        var reminder: LocalizedStringResource? {
            switch self {
            case .gatekeeper: "Apps from anywhere open without a check. Turn Gatekeeper back on in Privacy & Security."
            case .firewall: "Incoming connections to apps on this Mac are not filtered. Turn the firewall on in Network settings."
            case .sip: "Apps with admin rights can change macOS system files. Turn it back on from macOS Recovery with “csrutil enable”."
            case .fileVault: "Anyone with your Mac can read its disk without your password. Turn FileVault on in Privacy & Security."
            case .xprotect: nil
            }
        }

        /// The System Settings pane where it is turned on; nil for SIP, which only macOS Recovery changes.
        var settingsURL: URL? {
            switch self {
            case .gatekeeper: URL(string: "x-apple.systempreferences:com.apple.preference.security?Security")
            case .firewall: URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall")
            case .fileVault: URL(string: "x-apple.systempreferences:com.apple.preference.security?FileVault")
            case .sip, .xprotect: nil
            }
        }
    }

    /// One row of the Overview's "System protection" group.
    struct Check: Identifiable, Equatable, Sendable {
        let kind: Kind
        let state: State
        var id: Kind { kind }
        /// Only when the protection is off.
        var reminder: LocalizedStringResource? { state == .off ? kind.reminder : nil }
        var settingsURL: URL? { state == .off ? kind.settingsURL : nil }
    }

    var gatekeeper = State.unknown
    var firewall = State.unknown
    var sip = State.unknown
    var fileVault = State.unknown
    /// nil when no XProtect bundle could be read.
    var xprotect: XProtect?

    var checks: [Check] {
        [Check(kind: .gatekeeper, state: gatekeeper), Check(kind: .firewall, state: firewall),
         Check(kind: .sip, state: sip), Check(kind: .fileVault, state: fileVault),
         Check(kind: .xprotect, state: xprotect == nil ? .unknown : .on)]
    }

    // MARK: Parsers (the commands print English whatever the system language)

    /// `spctl --status`: "assessments enabled" / "assessments disabled".
    static func gatekeeper(_ output: String?) -> State {
        guard let output = output?.lowercased() else { return .unknown }
        if output.contains("assessments enabled") { return .on }
        if output.contains("assessments disabled") { return .off }
        return .unknown
    }

    /// `socketfilterfw --getglobalstate`: "Firewall is enabled. (State = 1)", "Firewall is blocking all non-essential
    /// incoming connections. (State = 2)" or "Firewall is disabled. (State = 0)".
    static func firewall(_ output: String?) -> State {
        guard let output else { return .unknown }
        if let match = output.range(of: #"State = (\d+)"#, options: .regularExpression) {
            return output[match].hasSuffix(" 0") ? .off : .on
        }
        let lower = output.lowercased()
        if lower.contains("is disabled") { return .off }
        if lower.contains("is enabled") || lower.contains("is blocking") { return .on }
        return .unknown
    }

    /// `csrutil status`: "System Integrity Protection status: enabled." / "disabled."; a custom configuration
    /// ("unknown (Custom Configuration)" or "enabled (Custom Configuration)") has parts turned off, so counts as off.
    static func sip(_ output: String?) -> State {
        guard let line = output?.split(separator: "\n").first(where: { $0.contains("status:") })?.lowercased()
        else { return .unknown }
        if line.contains("custom configuration") || line.contains("status: disabled") { return .off }
        if line.contains("status: enabled") { return .on }
        return .unknown
    }

    /// `fdesetup status`: "FileVault is On." / "FileVault is Off.", or "Encryption in progress: …" (being turned
    /// on) / "Decryption in progress: …" (being turned off).
    static func fileVault(_ output: String?) -> State {
        guard let output = output?.lowercased() else { return .unknown }
        if output.contains("filevault is on") || output.contains("encryption in progress") { return .on }
        if output.contains("filevault is off") || output.contains("decryption in progress") { return .off }
        return .unknown
    }

    /// The version in an XProtect bundle's Info.plist; nil when unreadable or without a version.
    static func xprotect(plist data: Data?, modified: Date?) -> XProtect? {
        guard let data,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = plist["CFBundleShortVersionString"] as? String, !version.isEmpty else { return nil }
        return XProtect(version: version, date: modified)
    }

    /// Where macOS keeps XProtect: the copy macOS ships, the one updates land in from macOS 15, and the location
    /// before macOS 10.15.
    static let xprotectBundles = [
        "/Library/Apple/System/Library/CoreServices/XProtect.bundle",
        "/private/var/protected/xprotect/XProtect.bundle",
        "/System/Library/CoreServices/XProtect.bundle",
    ]

    /// The newest readable XProtect: highest version, then latest date.
    static func newestXProtect(bundles: [String] = xprotectBundles) -> XProtect? {
        bundles.compactMap { bundle -> XProtect? in
            let path = bundle + "/Contents/Info.plist"
            let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            return xprotect(plist: FileManager.default.contents(atPath: path), modified: modified)
        }.max { lhs, rhs in
            switch lhs.version.compare(rhs.version, options: .numeric) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: (lhs.date ?? .distantPast) < (rhs.date ?? .distantPast)
            }
        }
    }

    /// How long each status command may take.
    static let timeout: Duration = .seconds(5)

    /// Runs the four status commands at once and reads XProtect. Never asks for a password: none needs admin rights.
    @concurrent static func read() async -> SecurityStatus {
        @Sendable func output(_ path: String, _ arguments: [String]) async -> String? {
            await ShellCommand(executable: path, arguments: arguments, timeout: timeout, requiresSuccess: false).output()
        }
        async let gatekeeper = output("/usr/sbin/spctl", ["--status"])
        async let firewall = output("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"])
        async let sip = output("/usr/bin/csrutil", ["status"])
        async let fileVault = output("/usr/bin/fdesetup", ["status"])
        let xprotect = newestXProtect()
        return SecurityStatus(gatekeeper: Self.gatekeeper(await gatekeeper), firewall: Self.firewall(await firewall),
                              sip: Self.sip(await sip), fileVault: Self.fileVault(await fileVault), xprotect: xprotect)
    }
}
