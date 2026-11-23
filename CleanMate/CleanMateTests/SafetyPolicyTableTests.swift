import Foundation
import Testing
@testable import CleanMate

/// The rules of `SafetyPolicy` case by case, on a throwaway home with a fake external volume: symlinks leading out,
/// other letter case, `..`, `~`, protected folders and trees, other volumes mounted inside, exclusions.
struct SafetyPolicyTableTests {
    let fm = FileManager.default
    let root: URL
    /// `root` with its symlinks resolved (`/var` → `/private/var`): the form `normalize` gives.
    let real: String

    init() throws {
        root = TestTemp.url("CleanMateSafetyTable")
        let files = [
            "home/Library/Caches/com.example/cache.db", "home/Downloads/old.zip", "home/Documents/report.pdf",
            "home/.ssh/id_ed25519", "home/.gnupg/key", "home/Library/Keychains/login.keychain-db",
            "home/Projects/app/build/out.o", "home/Projects/kept/notes.txt", "home/Mounted/file",
            "outside/secret", "tmp/scratch", "Volumes/Ext/Movies/film.mov", "Volumes/Ext/.Spotlight-V100/store",
        ]
        for file in files {
            let url = root.appending(path: file)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        try fm.createSymbolicLink(at: root.appending(path: "home/Projects/escape"),
                                  withDestinationURL: root.appending(path: "outside"))
        real = (root.path as NSString).resolvingSymlinksInPath
    }

    /// Ext is an external volume (device 99); ~/Mounted is a share mounted in the home (97).
    func policy(excluded: [String] = []) -> SafetyPolicy {
        let ext = real + "/Volumes/Ext", mounted = real + "/home/Mounted"
        @Sendable func under(_ path: String, _ folder: String) -> Bool { path == folder || path.hasPrefix(folder + "/") }
        return SafetyPolicy(
            home: root.appending(path: "home"), temp: root.appending(path: "tmp"),
            excluded: excluded.map { real + "/" + $0 },
            device: { path in
                if under(path, ext) { return 99 }
                if under(path, mounted) { return 97 }
                return SafetyPolicy.deviceID(path)
            },
            mounts: { ["/", ext, mounted] }, volumesFolder: real + "/Volumes")
    }

    func url(_ path: String) -> URL { root.appending(path: path) }

    @Test func allowsOnlyWhatIsInsideHomeOrTempAndUnprotected() {
        defer { try? fm.removeItem(at: root) }
        let policy = policy()
        let cases: [(String, Bool)] = [
            ("home/Library/Caches/com.example/cache.db", true),
            ("home/Library/Caches/com.example", true),
            ("home/Downloads/old.zip", true),
            ("tmp/scratch", true),
            ("home/Projects/escape", true), // the link itself: removing it removes only the link
            // The home and temp folders themselves, and the protected folders (contents allowed, never the folder).
            ("home", false), ("tmp", false), ("home/Library", false), ("home/Library/Caches", false),
            ("home/Downloads", false), ("home/.Trash", false),
            // A parent of a protected folder.
            ("home/Library/Caches/..", false),
            // Never-touch trees and what they hold, in any letter case.
            ("home/.ssh/id_ed25519", false), ("home/.SSH/id_ed25519", false), ("home/.ssh", false),
            ("home/.gnupg/key", false), ("home/Library/Keychains/login.keychain-db", false),
            ("home/library/keychains/login.keychain-db", false),
            ("home/Documents/report.pdf", false), ("home/DOCUMENTS/report.pdf", false),
            ("home/Library/CACHES", false),
            // Symlinks and `..` that lead out of the home.
            ("home/Projects/escape/secret", false), ("home/Projects/../../outside/secret", false),
            ("home/Library/Caches/../../.ssh/id_ed25519", false), ("home/Projects/escape/../home/Downloads", false),
            ("outside/secret", false),
            // Another volume: mounted inside the home, or an external drive.
            ("home/Mounted/file", false), ("home/Mounted", false), ("Volumes/Ext/Movies/film.mov", false),
        ]
        for (path, allowed) in cases {
            #expect(policy.allows(url(path)) == allowed, "\(path)")
        }
        #expect(!policy.allows(URL(fileURLWithPath: "/etc/hosts")) && !policy.allows(URL(fileURLWithPath: "/")))
        // A folder holding another volume's mount point is never removed with it.
        #expect(!policy.allows(url("home")) && !policy.allows(url("home/Mounted/..")))
    }

    @Test func homeRelativePathsAreNormalizedFirst() {
        defer { try? fm.removeItem(at: root) }
        let policy = policy()
        #expect(policy.expand("~").path == url("home").path)
        #expect(policy.expand("~/Downloads/old.zip").path == url("home/Downloads/old.zip").path)
        #expect(policy.expand("$TMPDIR/scratch").path == url("tmp/scratch").path)
        let cases: [(String, String)] = [
            ("home/./Library//Caches/", "/home/Library/Caches"),
            ("home/Projects/../Downloads/old.zip", "/home/Downloads/old.zip"),
            ("home/Projects/escape/secret", "/outside/secret"), // a symlinked parent is followed…
            ("home/Projects/escape", "/home/Projects/escape"), // …the last component never is
        ]
        for (path, expected) in cases {
            #expect(SafetyPolicy.normalize(url(path)) == real + expected, "\(path)")
        }
        #expect(SafetyPolicy.normalize(url("missing/../..")) == "/") // `..` through what doesn't exist: refused
        #expect(policy.allows(policy.expand("~/Library/Caches/com.example/cache.db")))
        #expect(!policy.allows(policy.expand("~/.ssh/id_ed25519")))
    }

    @Test func excludedFoldersAndTheirParentsAreNeverTouched() {
        defer { try? fm.removeItem(at: root) }
        let policy = policy(excluded: ["home/Projects/app"])
        let cases: [(String, Bool)] = [
            ("home/Projects/app/build/out.o", false), ("home/projects/APP/build", false), ("home/Projects/app", false),
            ("home/Projects", false), // holds the exclusion
            ("home/Projects/kept/notes.txt", true),
        ]
        for (path, allowed) in cases {
            #expect(policy.allows(url(path)) == allowed, "\(path)")
        }
        #expect(policy.overlapsExclusion(url("home/Projects")) && !policy.overlapsExclusion(url("home/Downloads")))
    }

    /// Large & Old Files: a regular file the user picked, in the home or on an external drive, never hidden, in
    /// ~/Library, behind a symlink or on another volume mounted inside.
    @Test func userFilesInHomeAndOnExternalDrives() {
        defer { try? fm.removeItem(at: root) }
        let policy = policy()
        let cases: [(String, Bool)] = [
            ("home/Documents/report.pdf", true), ("home/Downloads/old.zip", true),
            ("Volumes/Ext/Movies/film.mov", true),
            ("home/Documents", false), // not a regular file
            ("home/.ssh/id_ed25519", false), ("home/Library/Caches/com.example/cache.db", false),
            ("home/Projects/escape/secret", false), ("home/Projects/escape", false), ("home/Mounted/file", false),
            ("Volumes/Ext/.Spotlight-V100/store", false), ("tmp/scratch", false),
            ("outside/secret", false),
        ]
        for (path, allowed) in cases {
            #expect(policy.allowsUserFile(url(path)) == allowed, "\(path)")
        }
    }

    @Test func externalScanRootsStayOnTheirVolume() {
        defer { try? fm.removeItem(at: root) }
        let policy = policy()
        let cases: [(String, Bool)] = [
            ("Volumes/Ext", true), ("Volumes/Ext/Movies", true),
            ("Volumes", false), ("Volumes/Ext/.Spotlight-V100", false),
            ("Volumes/Missing", false), ("outside", false), ("home/Downloads", false),
        ]
        for (path, allowed) in cases {
            #expect(policy.allowsExternalRoot(url(path)) == allowed, "\(path)")
        }
        #expect(policy.externalVolume(real + "/Volumes/Ext/Movies/film.mov") == real + "/Volumes/Ext")
        // An excluded folder on the drive is not a scan root either.
        #expect(!SafetyPolicy(home: url("home"), temp: url("tmp"), excluded: [real + "/Volumes/Ext/Movies"],
                              device: { _ in 99 }, mounts: { [real + "/Volumes/Ext"] }, volumesFolder: real + "/Volumes")
            .allowsExternalRoot(url("Volumes/Ext/Movies")))
    }
}
