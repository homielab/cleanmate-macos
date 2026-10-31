import AppKit
import Security

/// The signing Team ID of an app bundle, read from its code signature on disk. Group containers are named
/// `<TEAMID>.<group>` and only apps of that team can use them, so the team tells whose a container is better than a
/// vendor name. Static check only: the signature is not validated, nothing goes over the network.
nonisolated enum CodeSignature {
    /// Path → (bundle modification date, team ID): an app updated in place gets a new date and is read again.
    private static let cache = Locked<[String: (modified: Date?, team: String?)]>([:])

    /// The bundle's Team ID, nil when unsigned, ad-hoc signed, Apple's own (no team) or unreadable.
    static func teamID(of bundle: URL) -> String? {
        let path = bundle.standardizedFileURL.path
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if let hit = cache.withLock({ $0[path] }), hit.modified == modified { return hit.team }
        let team = read(bundle)
        cache.withLock { $0[path] = (modified, team) }
        return team
    }

    private static func read(_ bundle: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any],
              let team = info[kSecCodeInfoTeamIdentifier as String] as? String, isTeamID(team) else { return nil }
        return team
    }

    /// Ten upper-case letters or digits, as Apple assigns them.
    static func isTeamID(_ text: some StringProtocol) -> Bool {
        text.count == 10 && text.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
    }

    /// The `<TEAMID>` of a group container named `<TEAMID>.<group>`; nil for `group.<id>` and other names.
    static func teamPrefix(ofGroup name: String) -> String? {
        let parts = name.split(separator: ".", maxSplits: 1)
        guard parts.count == 2, isTeamID(parts[0]) else { return nil }
        return String(parts[0])
    }

    /// Team ID of each running app with a readable signature, by bundle id. Reads only running apps (cached), never
    /// every installed app.
    static func runningAppTeams() -> [String: String] {
        var teams: [String: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, let url = app.bundleURL, let team = teamID(of: url) else { continue }
            teams[id] = team
        }
        return teams
    }
}
