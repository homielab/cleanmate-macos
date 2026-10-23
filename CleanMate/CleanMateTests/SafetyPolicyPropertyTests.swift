import Foundation
import Testing
@testable import CleanMate

/// Deterministic RNG (SplitMix64) so a failing case reproduces from the seed.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Property test: random paths built from `.`/`..`/`//`, case flips, NFD, trailing spaces and symlinks in a
/// throwaway home + temp; whenever an `allows*` rule says yes, the real target (realpath of the parent + last
/// component) must be somewhere the rule may touch.
struct SafetyPolicyPropertyTests {
    let fm = FileManager.default

    private func real(_ path: String) -> String? {
        guard let p = realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    private func key(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }

    /// What a removal of `path` would hit: realpath of the parent + last component (`.`/`..` last → the whole path).
    /// nil when the parent does not exist (nothing to remove).
    private func target(_ path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let last = parts.last else { return "/" }
        if last == "." || last == ".." { return real(path) }
        guard let parent = real("/" + parts.dropLast().joined(separator: "/")) else { return nil }
        return (parent == "/" ? "" : parent) + "/" + last
    }

    private func isLink(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK
    }

    private func app(_ url: URL, id: String) throws {
        let contents = url.appending(path: "Contents")
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
    }

    @Test func allowsNeverReachesForbiddenPlaces() throws {
        let root = fm.temporaryDirectory.appending(path: "CleanMateProps-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let home = root.appending(path: "home"), temp = root.appending(path: "tmp"), outside = root.appending(path: "outside")
        let files = [
            "Documents/a.txt", "Desktop/b.txt", ".ssh/id_rsa", ".gnupg/key", "Library/Keychains/login.keychain-db",
            "Library/Mail/V10/m.emlx", "Library/Mobile Documents/com~apple~CloudDocs/c.txt", "Library/Caches/com.x.app/f",
            "Library/Application Support/App/f", "Library/LaunchAgents/com.x.agent.plist", "Library/Preferences/com.x.plist",
            "Downloads/d.bin", "Projects/p/file", "Projects/p/node_modules/m.js", "Café/f", "Excluded/f", "excl.txt",
            "Pictures/p.jpg",
        ]
        for f in files.map({ home.appending(path: $0) }) + [temp.appending(path: "t/f"), outside.appending(path: "o/f"),
                                                            outside.appending(path: "agent.plist")] {
            try fm.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: f)
        }
        try app(home.appending(path: "Applications/Foo.app"), id: "com.test.foo")
        try app(home.appending(path: "Applications/Vendor/Bar.app"), id: "com.test.bar")
        try app(home.appending(path: "Applications/Apple.app"), id: "com.apple.thing")
        try app(home.appending(path: "Documents/Inside.app"), id: "com.test.inside")
        try app(outside.appending(path: "Out.app"), id: "com.test.out")
        try app(home.appending(path: "Library/PreferencePanes/Pane.prefPane"), id: "com.test.pane")
        try app(home.appending(path: "Library/PreferencePanes/ApplePane.prefPane"), id: "com.apple.pane")
        try app(home.appending(path: "Library/Input Methods/IM.app"), id: "com.test.im")
        try app(home.appending(path: "Library/Screen Savers/Wrong.app"), id: "com.test.wrong")
        let links: [(String, String)] = [
            ("home/linkDocs", "home/Documents"), ("home/linkSSH", "home/.ssh"), ("home/linkOut", "outside"),
            ("home/Library/Caches/linkKeys", "home/Library/Keychains"), ("home/linkExcl", "home/Excluded"),
            ("home/Projects/linkHome", "home"), ("home/linkLib", "home/Library"), ("tmp/linkDocs", "home/Documents"),
            ("home/Library/Application Support/linkMail", "home/Library/Mail"), ("home/linkTmp", "tmp"),
            ("home/Library/LaunchAgents/link.plist", "outside/agent.plist"), ("home/Applications/linkApp.app", "home/Applications/Foo.app"),
            ("home/Applications/linkVendor", "home/Documents"), ("home/Applications/Out.app", "outside/Out.app"),
            ("home/linkExclFile", "home/excl.txt"), ("tmp/linkHome", "home"),
            ("home/Library/PreferencePanes/Link.prefPane", "outside/Out.app"), ("home/Library/Spotlight", "outside"),
        ]
        for (link, dest) in links {
            try fm.createSymbolicLink(atPath: root.appending(path: link).path, withDestinationPath: root.appending(path: dest).path)
        }
        // Excluded as the user would pick them: NFC name, a folder and a file.
        let excluded = ["Café", "Excluded", "excl.txt"].map { home.appending(path: $0).path }
        let policy = SafetyPolicy(home: home, temp: temp, excluded: excluded)

        let realRoot = try #require(real(root.path)), realHome = try #require(real(home.path)), realTemp = try #require(real(temp.path))
        let protectedFolders = [realHome, realTemp] + [
            "Library", "Library/Caches", "Library/Logs", "Library/Logs/DiagnosticReports", "Library/Application Support",
            "Library/Containers", "Library/Group Containers", "Library/Preferences", "Library/Developer", ".Trash",
            "Downloads", "Applications", ".config", ".local", ".local/share", ".cache",
        ].map { realHome + "/" + $0 }
        let trees = [
            ".ssh", ".gnupg", ".aws", ".kube", "Library/Keychains", "Documents", "Desktop", "Pictures", "Movies", "Music",
            "Library/Mobile Documents", "Library/CloudStorage", "Library/Mail", "Library/Messages",
        ].map { realHome + "/" + $0 }
        let realExcluded = excluded.map { real($0)! }
        let folderKeys = protectedFolders.map(key), treeKeys = trees.map(key), exclKeys = realExcluded.map(key)

        func isOrContains(_ t: String, _ list: [String]) -> Bool { list.contains { $0 == t || $0.hasPrefix(t + "/") } }
        func inside(_ t: String, _ list: [String]) -> Bool { list.contains { t.hasPrefix($0 + "/") } }
        /// Invariant of `allows` (and the Uninstaller rules built on it).
        func generalOK(_ t: String) -> Bool {
            let k = key(t)
            return (k.hasPrefix(key(realHome) + "/") || k.hasPrefix(key(realTemp) + "/"))
                && !isOrContains(k, folderKeys + treeKeys + exclKeys) && !inside(k, treeKeys + exclKeys)
        }
        /// Invariant of the hand-picked rules: in the home, not hidden, not ~/Library, not excluded, not a protected
        /// folder itself (or a parent), never a symlink.
        func userOK(_ t: String) -> Bool {
            let k = key(t), h = key(realHome)
            guard k.hasPrefix(h + "/") else { return false }
            let parts = k.dropFirst(h.count + 1).split(separator: "/")
            return parts.first != "library" && !parts.contains { $0.hasPrefix(".") }
                && !isOrContains(k, folderKeys + treeKeys + exclKeys) && !inside(k, exclKeys) && !isLink(t)
        }

        var rng = SplitMix64(state: 282)
        let tokens = [".", "..", "", "nope", "Documents", "documents", "Library", ".ssh", "Café", "Excluded", "excl.txt"]
        let starts = [home.path, temp.path, root.path + "/home/../home", root.path + "//home/./", home.path + "/Projects/linkHome"]
        var checked = 0, allowed = 0, extensionsAllowed = 0
        for _ in 0..<4000 {
            var path = starts.randomElement(using: &rng)!
            for _ in 0..<Int.random(in: 1...6, using: &rng) {
                var comp: String
                if Int.random(in: 0..<100, using: &rng) < 65,
                   let kids = try? fm.contentsOfDirectory(atPath: path), let kid = kids.sorted().randomElement(using: &rng) {
                    comp = kid
                } else {
                    comp = tokens.randomElement(using: &rng)!
                }
                switch Int.random(in: 0..<100, using: &rng) {
                case 0..<10: comp = comp.uppercased()
                case 10..<20: comp = String(comp.enumerated().map { $0.offset % 2 == 0 ? Character($0.element.uppercased()) : $0.element })
                case 20..<30: comp = comp.decomposedStringWithCanonicalMapping
                case 30..<34: comp += " "
                default: break
                }
                let next = path + "/" + comp
                if let r = real(next), r != realRoot, !r.hasPrefix(realRoot + "/") { continue }  // stay in the sandbox
                path = next
            }
            guard let t = target(path) else { continue }
            checked += 1
            let url = URL(fileURLWithPath: path)
            let parentKey = key((t as NSString).deletingLastPathComponent), name = (t as NSString).lastPathComponent
            if policy.allows(url) {
                allowed += 1
                #expect(generalOK(t), "allows \(path) → \(t)")
            }
            if policy.allowsUserFile(url) { #expect(userOK(t), "allowsUserFile \(path) → \(t)") }
            if policy.allowsSpaceLensItem(url) {
                #expect(userOK(t) && parentKey != key(realHome), "allowsSpaceLensItem \(path) → \(t)")
            }
            if policy.allowsApp(url) {
                let k = key(t)
                #expect(k.hasPrefix(key(realHome + "/Applications/")) && k.hasSuffix(".app") && !isLink(t)
                        && !isOrContains(k, exclKeys) && !inside(k, treeKeys + exclKeys), "allowsApp \(path) → \(t)")
            }
            if policy.allowsAppData(url) {
                #expect(generalOK(t) && SafetyPolicy.appDataFolders.map { key(realHome + "/Library/" + $0) }.contains(parentKey)
                        && !name.hasPrefix("."), "allowsAppData \(path) → \(t)")
            }
            for label in ["com.x.agent", "com.apple.x", "a/b", ""] where policy.allowsLaunchAgent(url, label: label) {
                #expect(generalOK(t) && parentKey == key(realHome + "/Library/LaunchAgents") && !isLink(t)
                        && label == "com.x.agent", "allowsLaunchAgent \(path) → \(t)")
            }
            if policy.allowsUserExtension(url) {
                extensionsAllowed += 1
                let kinds = ExtensionItem.Kind.allCases.filter { key(realHome + "/Library/" + $0.folder) == parentKey }
                #expect(generalOK(t) && kinds.count == 1 && kinds[0].fileExtensions.contains((name as NSString).pathExtension.lowercased())
                        && !name.hasPrefix(".") && !isLink(t) && !key(t).contains("applepane"), "allowsUserExtension \(path) → \(t)")
            }
        }
        // The generator must actually reach both sides of the rules.
        #expect(checked > 2000)
        #expect(allowed > 100)
        #expect(extensionsAllowed > 0)
    }
}
