import AppKit
import CryptoKit
import Foundation
import Testing
@testable import CleanMate

/// A throwaway fake home + temp folder so tests never touch the real account.
private struct Sandbox {
    let root: URL
    let home: URL
    let temp: URL
    let policy: SafetyPolicy

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "CleanMateTests-\(UUID().uuidString)")
        home = root.appending(path: "home")
        temp = root.appending(path: "tmp")
        for dir in [home, temp] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        policy = SafetyPolicy(home: home, temp: temp)
    }

    @discardableResult
    func file(_ path: String, bytes: Int = 10_000, age: TimeInterval = 0) throws -> URL {
        let url = home.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

struct SafetyPolicyTests {
    let policy = SafetyPolicy(home: URL(fileURLWithPath: "/Users/test"), temp: URL(fileURLWithPath: "/var/folders/xx/T"))

    @Test(arguments: [
        "/", "/System", "/System/Library/Caches/x", "/usr", "/usr/bin/ls", "/Applications/Safari.app",
        "/Library/Caches/x", "/private/etc/hosts", "/Users", "/Users/other/Library/Caches/x",
        "/Users/test", "/Users/test/Library", "/Users/test/Library/Caches", "/Users/test/Library/Logs",
        "/Users/test/.Trash", "/Users/test/Downloads", "/var/folders/xx/T",
        "/Users/test/Documents", "/Users/test/Documents/report.pdf", "/Users/test/Desktop/a.txt",
        "/Users/test/.ssh", "/Users/test/.ssh/id_ed25519", "/Users/test/.gnupg/pubring.kbx",
        "/Users/test/Library/Keychains/login.keychain-db", "/Users/test/Library/Mobile Documents/x",
        "/Users/test/Library/Caches/../Keychains/login.keychain-db",
        // APFS is case-insensitive: these are the protected folders themselves.
        "/Users/test/documents", "/Users/test/DESKTOP/a.txt", "/Users/test/.SSH", "/Users/test/.SSH/id_rsa",
        "/Users/test/library/caches", "/Users/test/Library/caches", "/Users/test/library/keychains/login.keychain-db",
    ])
    func blocks(_ path: String) {
        #expect(!policy.allows(URL(fileURLWithPath: path)))
    }

    @Test(arguments: [
        "/Users/test/Library/Caches/com.example.app", "/Users/test/Library/Logs/old.log",
        "/Users/test/Library/Logs/DiagnosticReports/a.ips", "/Users/test/.Trash/old.zip",
        "/var/folders/xx/T/junk.tmp",
    ])
    func allows(_ path: String) {
        #expect(policy.allows(URL(fileURLWithPath: path)))
    }

    @Test func symlinkedParentIsResolved() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let key = try box.file(".ssh/id_rsa")
        try FileManager.default.createDirectory(at: box.home.appending(path: "Library/Caches"), withIntermediateDirectories: true)
        let link = box.home.appending(path: "Library/Caches/sneaky")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: key.deletingLastPathComponent())
        #expect(!box.policy.allows(link.appending(path: "id_rsa")))
        #expect(box.policy.allows(link)) // removing the link itself is harmless
    }

    @Test func userExclusionIsCaseInsensitive() {
        let policy = SafetyPolicy(home: URL(fileURLWithPath: "/Users/test"), temp: URL(fileURLWithPath: "/var/folders/xx/T"),
                                  excluded: ["/Users/test/Library/Caches/Keep"])
        #expect(!policy.allows(URL(fileURLWithPath: "/Users/test/Library/Caches/keep")))
        #expect(!policy.allows(URL(fileURLWithPath: "/Users/test/Library/Caches/KEEP/x")))
    }

    /// `link/..` and `link/.` lead through the link's target: never cut lexically (removeItem would follow `link/.`).
    @Test func dotComponentsThroughSymlinkAreResolved() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let doc = try box.file("Documents/sub/doc.txt")
        let caches = box.home.appending(path: "Library/Caches")
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        let link = caches.appending(path: "deep")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: doc.deletingLastPathComponent())
        for path in ["deep/.", "deep/..", "deep/../sub", "deep/./doc.txt", "missing/../x"] {
            #expect(!box.policy.allows(URL(fileURLWithPath: caches.path + "/" + path)), "\(path)")
        }
        #expect(box.policy.allows(URL(fileURLWithPath: caches.path + "/./deep"))) // the link itself
        let forged = ItemScan(entries: [ScanEntry(url: URL(fileURLWithPath: link.path + "/."), size: 1)])
        _ = await Cleaner.clean(CleanerItem(id: "x", title: "x", paths: []), scan: forged, policy: box.policy)
        #expect(FileManager.default.fileExists(atPath: doc.path))
    }
}

struct ScannerCleanerTests {
    @Test func cancelledScanStopsEarlyWithoutCrashing() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        for i in 0..<50 { try box.file("Library/Caches/a/\(i).bin") }
        let item = CleanerItem(id: "c", title: "c", paths: ["~/Library/Caches"])
        let policy = box.policy
        let folder = box.home.appending(path: "Library/Caches/a")
        let (scan, entry) = await Task {
            withUnsafeCurrentTask { $0?.cancel() } // cancelled before the walk starts, no timing race
            return (await Scanner.scan(item, policy: policy), await Scanner.entry(at: folder, olderThan: nil))
        }.value
        #expect(scan.entries.isEmpty)
        #expect(entry == nil)
    }

    @Test func otherVolumeIsNeverScannedNorRemoved() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.file("Library/Caches/a/1.bin")
        let mounted = try box.file("Library/Caches/mounted/device.bin")
        // Tests can't mount: "mounted" and everything under it is reported on another device.
        let policy = SafetyPolicy(home: box.home, temp: box.temp) { path in
            path.contains("/mounted") ? 99 : SafetyPolicy.deviceID(path)
        }
        #expect(!policy.allows(mounted.deletingLastPathComponent()) && !policy.allows(mounted))
        let item = CleanerItem(id: "c", title: "c", paths: ["~/Library/Caches"])
        let scan = await Scanner.scan(item, policy: policy)
        #expect(scan.entries.map(\.url.lastPathComponent) == ["a"])

        // Re-checked right before removal, even for an entry the scan listed (e.g. mounted since the scan).
        let stale = ItemScan(entries: [ScanEntry(url: mounted.deletingLastPathComponent(), size: 1)])
        let report = await Cleaner.clean(item, scan: stale, policy: policy)
        #expect(report.skipped == 1 && report.freed == 0)
        #expect(FileManager.default.fileExists(atPath: mounted.path))
    }

    @Test func lockedEntryIsNeverListed() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.file("Library/Caches/a/1.bin")
        let locked = try box.file("Library/Caches/locked.bin")
        #expect(chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(locked.path, 0) }
        let scan = await Scanner.scan(CleanerItem(id: "c", title: "c", paths: ["~/Library/Caches"]), policy: box.policy)
        #expect(scan.entries.map(\.url.lastPathComponent) == ["a"])
    }

    @Test func scansSizesSkipsExcludedAndCleansContentsOnly() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.file("Library/Caches/a/1.bin", bytes: 50_000)
        try box.file("Library/Caches/a/sub/2.bin", bytes: 50_000)
        try box.file("Library/Caches/keep/3.bin")
        let item = CleanerItem(id: "c", title: "c", paths: ["~/Library/Caches", "~/missing"], excluded: ["keep"])

        let scan = await Scanner.scan(item, policy: box.policy)
        #expect(scan.entries.map(\.url.lastPathComponent) == ["a"])
        #expect(scan.size >= 100_000)

        let report = await Cleaner.clean(item, scan: scan, policy: box.policy)
        #expect(report.freed == scan.size && report.skipped == 0)
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: box.home.appending(path: "Library/Caches/a").path))
        #expect(fm.fileExists(atPath: box.home.appending(path: "Library/Caches/keep/3.bin").path))
        #expect(fm.fileExists(atPath: box.home.appending(path: "Library/Caches").path))
    }

    @Test func nestedExclusionListsSiblingsAndKeepsParent() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.file("Library/Caches/Google/Chrome/1.bin")
        try box.file("Library/Caches/Google/OtherApp/2.bin")
        try box.file("Library/Caches/Google/top.bin")
        try box.file("Library/Caches/plain/3.bin")
        let item = CleanerItem(id: "c", title: "c", paths: ["~/Library/Caches"], excluded: ["Google/Chrome"])

        let scan = await Scanner.scan(item, policy: box.policy)
        #expect(Set(scan.entries.map(\.url.lastPathComponent)) == ["OtherApp", "top.bin", "plain"])

        _ = await Cleaner.clean(item, scan: scan, policy: box.policy)
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: box.home.appending(path: "Library/Caches/Google/Chrome/1.bin").path))
        #expect(!fm.fileExists(atPath: box.home.appending(path: "Library/Caches/Google/OtherApp").path))
        #expect(!fm.fileExists(atPath: box.home.appending(path: "Library/Caches/plain").path))
    }

    @Test func rootInsideAnotherRootCountsOnce() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.file("App/GPUPersistentCache/GPUCache/x/1.bin")
        // `App/*/GPUCache` with `*` = `GPUPersistentCache` sits inside `App/GPUPersistentCache`.
        let item = CleanerItem(id: "c", title: "c", paths: ["~/App/*/GPUCache", "~/App/GPUPersistentCache"])

        let scan = await Scanner.scan(item, policy: box.policy)
        #expect(scan.entries.map(\.url.lastPathComponent) == ["GPUCache"])
        #expect(scan.entries.first?.url.deletingLastPathComponent().lastPathComponent == "GPUPersistentCache")
    }

    @Test func rootSharingANamePrefixIsNotNested() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.file("App/Cache/a.bin")
        try box.file("App/CacheX/b.bin")
        // `App/CacheX` starts with `App/Cache` but is not inside it: both are listed (ancestor lookup).
        let item = CleanerItem(id: "c", title: "c", paths: ["~/App/Cache", "~/App/CacheX"])

        let scan = await Scanner.scan(item, policy: box.policy)
        #expect(Set(scan.entries.map(\.url.lastPathComponent)) == ["a.bin", "b.bin"])
    }

    @Test func minAgeKeepsRecentFiles() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.file("Library/Logs/active/old.log", age: 10 * 86_400)
        try box.file("Library/Logs/active/new.log", age: 60)
        try box.file("Library/Logs/stale/old.log", age: 10 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast],
                                              ofItemAtPath: box.home.appending(path: "Library/Logs/stale").path)
        try box.file("Library/Logs/top-old.log", age: 10 * 86_400)
        let item = CleanerItem(id: "l", title: "l", paths: ["~/Library/Logs"], minAge: 7 * 86_400)

        let scan = await Scanner.scan(item, policy: box.policy)
        // "active" has a recent file, so it is kept whole (no half-deleted folders).
        #expect(Set(scan.entries.map(\.url.lastPathComponent)) == ["stale", "top-old.log"])
    }

    /// A folder changed after the cutoff is dropped before the other checks, but not one holding a nested
    /// exclusion: its own date says nothing about its old children, listed instead.
    @Test func minAgeStillListsOldChildrenOfANewFolderHoldingAnExclusion() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.file("Library/Logs/Group/Keep/k.log", age: 10 * 86_400)
        try box.file("Library/Logs/Group/Old/o.log", age: 10 * 86_400)
        try box.file("Library/Logs/New/n.log", age: 10 * 86_400) // the folder itself is new
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast],
                                              ofItemAtPath: box.home.appending(path: "Library/Logs/Group/Old").path)
        let item = CleanerItem(id: "l", title: "l", paths: ["~/Library/Logs"], minAge: 7 * 86_400, excluded: ["Group/Keep"])

        let scan = await Scanner.scan(item, policy: box.policy)
        #expect(scan.entries.map(\.url.lastPathComponent) == ["Old"])
    }

    @Test func minAgeIsRecheckedRightBeforeRemoval() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.file("Library/Logs/busy/old.log", age: 10 * 86_400)
        try box.file("Library/Logs/idle/old.log", age: 10 * 86_400)
        for name in ["busy", "idle"] {
            try FileManager.default.setAttributes([.modificationDate: Date.distantPast],
                                                  ofItemAtPath: box.home.appending(path: "Library/Logs/" + name).path)
        }
        let item = CleanerItem(id: "l", title: "l", paths: ["~/Library/Logs"], minAge: 7 * 86_400)
        let scan = await Scanner.scan(item, policy: box.policy)
        #expect(scan.entries.count == 2)
        // Written after the scan: "busy" is no longer old and must survive.
        try box.file("Library/Logs/busy/new.log")

        let report = await Cleaner.clean(item, scan: scan, policy: box.policy)
        #expect(report.skipped == 1)
        #expect(FileManager.default.fileExists(atPath: box.home.appending(path: "Library/Logs/busy/new.log").path))
        #expect(FileManager.default.fileExists(atPath: box.home.appending(path: "Library/Logs/busy/old.log").path))
        #expect(!FileManager.default.fileExists(atPath: box.home.appending(path: "Library/Logs/idle").path))
    }

    @Test func rootThroughSymlinkIsNeitherScannedNorCleaned() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let fm = FileManager.default
        let target = try box.file("Developer/project/src/main.swift", bytes: 50_000).deletingLastPathComponent()
            .deletingLastPathComponent()
        try fm.createDirectory(at: box.home.appending(path: "Library"), withIntermediateDirectories: true)
        try fm.createDirectory(at: box.home.appending(path: ".claude/projects"), withIntermediateDirectories: true)
        // The root itself, a folder between, and one `*` match are symlinks into the project.
        try fm.createSymbolicLink(at: box.home.appending(path: "Library/Caches"), withDestinationURL: target)
        try fm.createSymbolicLink(at: box.home.appending(path: ".tool"), withDestinationURL: box.home.appending(path: "Developer"))
        try fm.createSymbolicLink(at: box.home.appending(path: ".claude/projects/linked"), withDestinationURL: target)
        try box.file(".claude/projects/real/session.jsonl")
        let item = CleanerItem(id: "c", title: "c", paths: ["~/Library/Caches", "~/.tool/project", "~/.claude/projects/*"])

        let scan = await Scanner.scan(item, policy: box.policy)
        #expect(scan.entries.map(\.url.lastPathComponent) == ["session.jsonl"])
        _ = await Cleaner.clean(item, scan: scan, policy: box.policy)
        #expect(fm.fileExists(atPath: target.appending(path: "src/main.swift").path))
        #expect(!box.policy.rootThroughSymlink(box.temp.appending(path: "x"))) // the temp folder's own /var link is fine
    }

    @Test func doesNotFollowSymlinks() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let outside = try box.file("Documents/big.bin", bytes: 500_000)
        try FileManager.default.createDirectory(at: box.home.appending(path: "Library/Caches"), withIntermediateDirectories: true)
        let link = box.home.appending(path: "Library/Caches/link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.deletingLastPathComponent())
        let item = CleanerItem(id: "c", title: "c", paths: ["~/Library/Caches"])

        let scan = await Scanner.scan(item, policy: box.policy)
        #expect(scan.size < 500_000)
        _ = await Cleaner.clean(item, scan: scan, policy: box.policy)
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    /// A folder replaced by a symlink between scan and clean (its scanned URL ends in `/`), or holding one:
    /// only the links are removed, never their targets.
    @Test func cleanRemovesLinksNotTargetsAfterSwap() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let doc = try box.file("Documents/keep.txt")
        try box.file("Library/Caches/app/data.bin")
        try box.file("Library/Caches/other/data.bin")
        let fm = FileManager.default
        try fm.createSymbolicLink(at: box.home.appending(path: "Library/Caches/other/inner"), withDestinationURL: doc.deletingLastPathComponent())
        let item = CleanerItem(id: "c", title: "c", paths: ["~/Library/Caches"])
        let scan = await Scanner.scan(item, policy: box.policy)
        #expect(scan.entries.count == 2)
        let app = box.home.appending(path: "Library/Caches/app")
        try fm.removeItem(at: app)
        try fm.createSymbolicLink(at: app, withDestinationURL: doc.deletingLastPathComponent())
        let report = await Cleaner.clean(item, scan: scan, policy: box.policy)
        #expect(report.skipped == 0)
        #expect(fm.fileExists(atPath: doc.path))
        #expect(try fm.contentsOfDirectory(atPath: box.home.appending(path: "Library/Caches").path).isEmpty)
    }

    @Test func refusesBlockedEntriesAtCleanTime() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let key = try box.file(".ssh/id_rsa")
        let forged = ItemScan(entries: [ScanEntry(url: key, size: 1)])
        let report = await Cleaner.clean(CleanerItem(id: "x", title: "x", paths: []), scan: forged, policy: box.policy)
        #expect(report.skipped == 1 && report.freed == 0)
        #expect(FileManager.default.fileExists(atPath: key.path))
    }

    /// Docker's listed images, containers, volumes are display-only: even with the
    /// tool gone, the cleaner never removes an entry.
    @Test(arguments: ["docker-images", "docker-containers", "docker-volumes"])
    func dockerEntriesAreNeverRemoved(id: String) async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let file = try box.file("Library/Caches/x/a")
        let images = try #require(CleanerGroup.developer.items.first { $0.id == id })
        #expect(images.paths.isEmpty && images.command != nil && !images.selectableEntries && images.probe?.details != nil)
        var item = images
        item.command = ShellCommand(executable: "cleanmate-no-such-tool")
        item.probe?.precondition = { true }
        let scan = ItemScan(entries: [ScanEntry(url: file, size: 1), ScanEntry(url: URL(string: "docker-image:0")!, size: 1)],
                            measuredSize: 2)
        let report = await Cleaner.clean(item, scan: scan, policy: box.policy)
        #expect(report.freed == 0 && report.skipped == 1)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func dockerDanglingImages() throws {
        let output = """
        {"CreatedAt":"2026-09-18 05:11:30 +0000 UTC","ID":"6fecacab9f88","Repository":"<none>","Size":"97.9MB","Tag":"<none>"}
        not json
        {"CreatedAt":"2026-10-22 03:48:02 +0700 +07","ID":"8b1bc650def0","Repository":"<none>","Size":"1.82GB","Tag":"<none>"}
        {"CreatedAt":"2026-10-22 03:48:02 +0700 +07","ID":"../../etc","Repository":"<none>","Size":"1GB","Tag":"<none>"}
        """
        let entries = DeveloperTools.dockerDanglingImages(in: output)
        #expect(entries.map(\.title) == ["6fecacab9f88", "8b1bc650def0"])
        #expect(entries.map(\.size) == [97_900_000, 1_820_000_000] && entries.allSatisfy { $0.date != nil })
        #expect(DeveloperTools.dockerDanglingImages(in: "").isEmpty)
        #expect(DeveloperTools.dockerImageID(of: entries[0].url) == "6fecacab9f88")
        #expect(DeveloperTools.dockerImageID(of: URL(string: "docker-dangling:--force")!) == nil)
        #expect(DeveloperTools.dockerImageID(of: URL(string: "docker-image:6fecacab9f88")!) == nil)
        let item = try #require(CleanerGroup.developer.items.first { $0.id == "docker-dangling" })
        #expect(item.selectedByDefault && item.selectableEntries && item.paths.isEmpty)
        guard case .bytes(let total)? = item.probe?.parse(output) else { Issue.record("no size"); return }
        #expect(total == 1_917_900_000)
        #expect(item.probe?.parse("") == nil) // none: hidden
    }

    /// Only the ticked entries reach `docker rmi`, each by its own ID; an unrecognised one is skipped.
    @Test func danglingImagesAreRemovedPerEntry() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let log = box.root.appending(path: "calls.txt")
        let script = try box.file("fake-docker.sh")
        try "#!/bin/sh\necho \"$@\" >> '\(log.path)'\n[ \"$2\" != 6fecacab9f88 ]\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        var item = try #require(CleanerGroup.developer.items.first { $0.id == "docker-dangling" })
        item.command = ShellCommand(executable: script.path)
        item.entryCommand = { url in
            DeveloperTools.dockerImageID(of: url).map { ShellCommand(executable: script.path, arguments: ["rmi", $0]) }
        }
        item.probe?.precondition = { true }
        let scan = ItemScan(entries: [
            ScanEntry(url: URL(string: "docker-dangling:8b1bc650def0")!, size: 10),
            ScanEntry(url: URL(string: "docker-dangling:6fecacab9f88")!, size: 5),
            ScanEntry(url: URL(string: "docker-dangling:nope")!, size: 1),
        ], measuredSize: 16)
        let report = await Cleaner.clean(item, scan: scan, policy: box.policy)
        #expect(report.freed == 10 && report.skipped == 2)
        #expect(SmartScanModel.removedCount(item, scan, report) == 1)
        #expect(try String(contentsOf: log, encoding: .utf8) == "rmi 8b1bc650def0\nrmi 6fecacab9f88\n")
    }

    @Test func commandTimeout() async {
        #expect(await ShellCommand(executable: "/usr/bin/true").run())
        #expect(await !ShellCommand(executable: "/bin/sleep", arguments: ["30"], timeout: .milliseconds(300)).run()) // 30 s: a starved poll can't see it exit 0 first
        #expect(await !ShellCommand(executable: "/nonexistent/tool").run())
    }

    /// A background child holding the output pipe doesn't hang the read; a timeout kills the whole group.
    @Test func backgroundChildDoesNotHangAndTimeoutKillsGroup() async throws {
        let start = ContinuousClock.now
        let output = await ShellCommand(executable: "/bin/sh", arguments: ["-c", "sleep 30 & echo x"]).output()
        #expect(output == "x\n")
        #expect(ContinuousClock.now - start < .seconds(25)) // not the 30 s child; 10 s failed under -test-iterations load

        let pidFile = FileManager.default.temporaryDirectory.appending(path: "cleanmate-108-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        // Both ignore SIGTERM, so they must be SIGKILLed after the grace.
        let stopStart = ContinuousClock.now
        #expect(await !ShellCommand(executable: "/bin/sh",
                                    arguments: ["-c", "trap '' TERM; sleep 30 & echo $! > '\(pidFile.path)'; wait"],
                                    timeout: .milliseconds(500)).run())
        #expect(ContinuousClock.now - stopStart >= .milliseconds(500) + ShellCommand.termGrace)
        #expect(ContinuousClock.now - stopStart < .seconds(25)) // under the 30 s child, room for a busy machine
        // A tool that honours SIGTERM stops right away.
        // A full-grace wait always takes ≥ 300 ms + termGrace, so the fastest of 3 tries tells it from a busy machine.
        var fastest = Duration.seconds(3600)
        for _ in 0..<3 where fastest >= .milliseconds(300) + ShellCommand.termGrace {
            let termStart = ContinuousClock.now
            #expect(await !ShellCommand(executable: "/bin/sleep", arguments: ["30"], timeout: .milliseconds(300)).run())
            fastest = min(fastest, ContinuousClock.now - termStart)
        }
        #expect(fastest < .milliseconds(300) + ShellCommand.termGrace) // no SIGKILL wait (not a fixed 1.5 s)
        let grandchild = try #require(pid_t(String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        for _ in 0..<3000 where kill(grandchild, 0) == 0 { try await Task.sleep(for: .milliseconds(10)) } // reaping can lag under load
        #expect(kill(grandchild, 0) == -1 && errno == ESRCH)
    }
}

/// The fts walk must give exactly what the old per-URL resource-value walk gave.
struct TreeMeasureTests {
    /// The old walk, kept as the reference: FileManager enumerator + `totalFileAllocatedSize` /
    /// `contentModificationDate`, sockets and pipes never old, other volumes skipped.
    func reference(_ url: URL) -> (Int64, Date) {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .contentModificationDateKey, .isVolumeKey, .fileResourceTypeKey]
        func modified(_ v: URLResourceValues) -> Date {
            v.fileResourceType == .socket || v.fileResourceType == .namedPipe ? .distantFuture : v.contentModificationDate ?? .distantFuture
        }
        let root = try! url.resourceValues(forKeys: Set(keys))
        var size = Int64(root.totalFileAllocatedSize ?? 0), newest = modified(root)
        let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })!
        while let file = files.nextObject() as? URL {
            guard let v = try? file.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isVolume == true { files.skipDescendants(); continue }
            size += Int64(v.totalFileAllocatedSize ?? 0)
            newest = max(newest, modified(v))
        }
        return (size, newest)
    }

    func measure(_ url: URL) -> (Int64, Date)? {
        guard let device = SafetyPolicy.deviceID(url.path) else { return nil }
        return Scanner.tree(url, dates: true, device: device).map { ($0.0, $0.1) }
    }

    @Test func treeMatchesResourceValues() async throws {
        // Short path: a Unix socket path must fit in 104 bytes.
        let root = URL(fileURLWithPath: NSTemporaryDirectory() + "cm-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let plain = root.appending(path: "plain"), deep = plain.appending(path: "a/b/c")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        for (i, bytes) in [0, 1, 4_095, 4_097, 300_000, 2_000_000].enumerated() {
            try Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ i) }).write(to: (i % 2 == 0 ? plain : deep).appending(path: "f\(i)"))
        }
        try FileManager.default.copyItem(at: plain.appending(path: "f4"), to: plain.appending(path: "clone")) // APFS clone
        try FileManager.default.linkItem(at: plain.appending(path: "f4"), to: deep.appending(path: "hard"))
        try FileManager.default.createSymbolicLink(atPath: plain.appending(path: "link").path, withDestinationPath: deep.path)
        try FileManager.default.createSymbolicLink(atPath: plain.appending(path: "dangling").path, withDestinationPath: "/nonexistent")
        let text = plain.appending(path: "text")
        try Data(repeating: 65, count: 1_000_000).write(to: text)
        let ditto = try Process.run(URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["--hfsCompression", text.path, plain.appending(path: "compressed").path])
        ditto.waitUntilExit() // a file compressed by APFS: allocated size well under its length
        // Sizes and dates: the whole plain tree (dates kept as the files have them, sub-microsecond parts included).
        let (size, date) = try #require(measure(plain))
        // The hard link `hard` to f4 counts once; resource values count it per link.
        let linked = Int64(try plain.appending(path: "f4").resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize!)
        #expect(size == reference(plain).0 - linked && size > 3_000_000)
        #expect(date == reference(plain).1)
        // A pipe or socket anywhere inside: never old.
        let piped = root.appending(path: "piped"), socketed = root.appending(path: "socketed")
        try FileManager.default.createDirectory(at: piped, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: socketed, withIntermediateDirectories: true)
        #expect(mkfifo(piped.appending(path: "fifo").path, 0o600) == 0)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(socketed.appending(path: "s").path.utf8CString).map { UInt8(bitPattern: $0) }) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(bound == 0)
        for folder in [piped, socketed] {
            #expect(measure(folder)?.1 == .distantFuture && reference(folder).1 == .distantFuture)
            #expect(measure(folder)?.0 == reference(folder).0)
        }
        // A symlink measured on its own counts the link, not its target.
        #expect(measure(plain.appending(path: "link"))?.0 == reference(plain.appending(path: "link")).0)
        // Without dates: same size, no date.
        let device = try #require(SafetyPolicy.deviceID(plain.path))
        #expect(Scanner.tree(plain, dates: false, device: device)! == (size, .distantPast, false))
        // Another device's tree counts nothing (as a volume mounted inside would).
        #expect(Scanner.tree(plain, dates: true, device: device &+ 1)! == (0, .distantPast, false))
        // Folders read in parallel: exactly the serial walk, hard link once, unreadable folder flagged.
        let locked = deep.appending(path: "locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data(count: 50_000).write(to: locked.appending(path: "hidden"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let serial = try #require(Scanner.tree(plain, dates: false, device: device))
        #expect(serial.0 == size && serial.2)
        for depth in [0, 1, 2, 3, 6] {
            let parallel = try #require(await Scanner.undatedTree(plain.path, device: device, links: .init(), depth: depth))
            #expect(parallel == serial, "depth \(depth)")
        }
    }

    /// A file hard-linked twice inside one entry counts once, like `du -s` (npm's `_npx` links its binaries);
    /// each entry holding a link still counts it, as `du -s` of that entry would.
    @Test func hardLinkCountsOncePerEntry() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CleanMateLinks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appending(path: "a"), b = root.appending(path: "b")
        try FileManager.default.createDirectory(at: a.appending(path: "bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let big = a.appending(path: "big")
        try Data(repeating: 7, count: 3_000_000).write(to: big)
        try FileManager.default.linkItem(at: big, to: a.appending(path: "bin/big"))
        try FileManager.default.linkItem(at: big, to: b.appending(path: "big"))
        let one = Int64(try big.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize!)
        #expect(await Scanner.entry(at: a, olderThan: nil)?.size == one)
        #expect(await Scanner.entry(at: b, olderThan: nil)?.size == one)
        #expect(await Scanner.entry(at: a, olderThan: nil)?.size == (try SpaceLens.measure(a)).size)
    }

    /// A folder that can't be read inside an entry counts 0 and marks the entry (and its item) as partly unreadable.
    @Test func unreadableFolderMarksEntry() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CleanMateUnreadable-\(UUID().uuidString)")
        let locked = root.appending(path: "entry/locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 100_000).write(to: locked.appending(path: "f"))
        try Data(repeating: 7, count: 100_000).write(to: root.appending(path: "entry/g"))
        defer {
            chmod(locked.path, 0o755)
            try? FileManager.default.removeItem(at: root)
        }
        let readable = try #require(await Scanner.entry(at: root.appending(path: "entry"), olderThan: nil))
        #expect(!readable.partlyUnreadable && !ItemScan(entries: [readable]).partlyUnreadable)
        #expect(chmod(locked.path, 0) == 0)
        let entry = try #require(await Scanner.entry(at: root.appending(path: "entry"), olderThan: nil))
        #expect(entry.partlyUnreadable && entry.size < readable.size)
        #expect(ItemScan(entries: [readable, entry]).partlyUnreadable)
        // The entry folder itself unreadable.
        #expect(await Scanner.entry(at: locked, olderThan: nil)?.partlyUnreadable == true)
    }

    /// One new file deep inside keeps the entry (the walk stops there); an old folder keeps its full size.
    @Test func ageStopsAtFirstNewFile() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory() + "cm-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let old = Date.now.addingTimeInterval(-30 * 86_400), cutoff = Date.now.addingTimeInterval(-7 * 86_400)
        func make(_ name: String, newDeep: Bool) throws -> URL {
            let folder = root.appending(path: name), deep = folder.appending(path: "a/b/c")
            try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
            for i in 0..<20 { try Data(count: 5_000 * (i + 1)).write(to: (i % 2 == 0 ? folder : deep).appending(path: "f\(i)")) }
            if newDeep { try Data(count: 10).write(to: deep.appending(path: "new")) }
            let all = FileManager.default.enumerator(atPath: folder.path)!.allObjects as! [String]
            for path in all.reversed() + [""] where !path.hasSuffix("new") {
                try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: folder.appending(path: path).path)
            }
            return folder
        }
        let kept = try make("kept", newDeep: true), aged = try make("aged", newDeep: false)
        #expect(await Scanner.entry(at: kept, olderThan: cutoff) == nil)
        #expect(await Scanner.entry(at: aged, olderThan: cutoff)?.size == reference(aged).0)
        #expect(await Scanner.entry(at: kept, olderThan: nil)?.size == reference(kept).0)
        let device = try #require(SafetyPolicy.deviceID(kept.path))
        #expect(Scanner.tree(kept, dates: true, device: device, stopAt: cutoff)?.1 == .distantFuture)
        #expect(Scanner.tree(aged, dates: true, device: device, stopAt: cutoff).map { ($0.0, $0.1) }! == reference(aged))
    }
}

struct ProbeAndCommandTests {
    @Test func probeOnlyLimitsEntriesToReportedNames() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.file("Library/Developer/CoreSimulator/Devices/AAA/data/x.bin")
        try box.file("Library/Developer/CoreSimulator/Devices/BBB/data/x.bin")
        // Deeper than `Scanner.splitDepth`: these entries are walked split, same size as one walk.
        for (i, dir) in ["a", "a/b", "a/b/c", "a/b/c/d", "a/b/c/d/e"].enumerated() {
            try box.file("Library/Developer/CoreSimulator/Devices/AAA/data/\(dir)/f.bin", bytes: 5_000 * (i + 1))
        }
        let probe = SizeProbe(command: ShellCommand(executable: "/bin/echo", arguments: ["AAA"]),
                              parse: { .only(Set($0.split(whereSeparator: \.isWhitespace).map(String.init))) })
        let item = CleanerItem(id: "s", title: "s", paths: ["~/Library/Developer/CoreSimulator/Devices"], probe: probe)
        let scan = await Scanner.scan(item, policy: box.policy)
        #expect(scan.entries.map(\.url.lastPathComponent) == ["AAA"])
        let whole = await Scanner.entry(at: try #require(scan.entries.first).url, olderThan: nil)
        #expect(scan.entries.first?.size == whole?.size && (whole?.size ?? 0) > 75_000)
    }

    /// A `.only` probe is asked again when cleaning: a name it stopped reporting since the scan is kept.
    @Test func probeOnlyNamesRecheckedWhenCleaning() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let a = try box.file("Sims/AAA/x.bin")
        let b = try box.file("Sims/BBB/x.bin")
        func item(_ reported: String) -> CleanerItem {
            CleanerItem(id: "s", title: "s", paths: ["~/Sims"], probe: SizeProbe(
                command: ShellCommand(executable: "/bin/echo", arguments: [reported]),
                parse: { .only(Set($0.split(whereSeparator: \.isWhitespace).map(String.init))) }))
        }
        let scan = await Scanner.scan(item("AAA BBB"), policy: box.policy)
        #expect(scan.entries.count == 2)
        let report = await Cleaner.clean(item("BBB"), scan: scan, policy: box.policy)
        #expect(report.skipped == 1)
        #expect(FileManager.default.fileExists(atPath: a.path) && !FileManager.default.fileExists(atPath: b.path))
    }

    /// `minAge` is checked before a database erase: a database written to recently is left alone.
    @Test func databaseEraseHonoursMinAge() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let db = box.home.appending(path: "db.sqlite")
        #expect(await ShellCommand(executable: DatabaseErase.sqlite,
                                   arguments: [db.path, "CREATE TABLE t(a); INSERT INTO t VALUES(1);"]).run())
        let item = CleanerItem(id: "d", title: "d", paths: ["~"], minAge: 3600,
                               database: DatabaseErase(count: "SELECT count(*) FROM t;", erase: "DELETE FROM t;"))
        let report = await Cleaner.clean(item, scan: ItemScan(entries: [ScanEntry(url: db, size: 0, isDatabase: true)]),
                                         policy: box.policy)
        #expect(report.skipped == 1)
        #expect(await ShellCommand(executable: DatabaseErase.sqlite, arguments: [db.path, "SELECT count(*) FROM t;"])
                    .output()?.trimmingCharacters(in: .whitespacesAndNewlines) == "1")
    }

    @Test func probeBytesAndFailures() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let bytes = SizeProbe(command: ShellCommand(executable: "/bin/echo", arguments: ["1.5kB"]),
                              parse: { DeveloperTools.bytes(fromDockerSize: $0.trimmingCharacters(in: .whitespacesAndNewlines)).map(SizeProbe.Result.bytes) })
        #expect(await Scanner.scan(CleanerItem(id: "b", title: "b", paths: [], probe: bytes), policy: box.policy).size == 1_500)

        var failing = bytes
        failing.command = ShellCommand(executable: "/usr/bin/false")
        #expect(await Scanner.scan(CleanerItem(id: "f", title: "f", paths: [], probe: failing), policy: box.policy).size == 0)

        var blocked = bytes
        blocked.precondition = { false }
        #expect(await Scanner.scan(CleanerItem(id: "p", title: "p", paths: [], probe: blocked), policy: box.policy).size == 0)

        // Probe is not run when none of the item's folders exist.
        #expect(await Scanner.scan(CleanerItem(id: "m", title: "m", paths: ["~/missing"], probe: bytes), policy: box.policy).size == 0)
    }

    /// A cache moved by the tool's config is found; never counted twice, never outside home.
    @Test func locatedCacheFolder() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.file("go/pkg/mod/a/x.bin")
        try box.file("custom/gomod/b/x.bin")
        try box.file("custom/npm/_cacache/c/x.bin")
        try box.file("Library/Caches/d/x.bin")
        func item(_ printed: String, subpath: String = "") -> CleanerItem {
            CleanerItem(id: "l", title: "l", paths: ["~/go/pkg/mod"], locate: PathLookup(
                command: ShellCommand(executable: "/bin/echo", arguments: [printed]), subpath: subpath))
        }
        func names(_ printed: String, subpath: String = "") async -> [String] {
            await Scanner.scan(item(printed, subpath: subpath), policy: box.policy).entries.map(\.url.lastPathComponent).sorted()
        }
        let home = box.home.path
        #expect(await names(home + "/custom/gomod") == ["a", "b"])
        #expect(await names(home + "/custom/npm", subpath: "_cacache") == ["a", "c"])
        // Same folder as the default, or inside it: counted once.
        #expect(await names(home + "/go/pkg/mod") == ["a"])
        #expect(await names(home + "/go/pkg/mod/a") == ["a"])
        #expect(await names(home + "/go/pkg/../pkg/mod/") == ["a"])
        #expect(await names(home + "/go/pkg") == ["mod"]) // the default folder is inside it
        // Refused: outside home, home itself, a protected folder, a relative path, `..` escaping home.
        for refused in [box.temp.path, "/", "/usr/lib", home, home + "/Library/Caches", "custom/gomod",
                        home + "/../tmp", home + "/Documents"] {
            #expect(await names(refused) == ["a"], "\(refused)")
        }
        // Reached through a symlink: refused.
        try FileManager.default.createSymbolicLink(at: box.home.appending(path: "link"), withDestinationURL: box.home.appending(path: "custom"))
        #expect(await names(home + "/link/gomod") == ["a"])
        // Tool missing or failing: the default folder only.
        let missing = CleanerItem(id: "m", title: "m", paths: ["~/go/pkg/mod"], locate: PathLookup(
            command: ShellCommand(executable: "no-such-tool-92")))
        #expect(await Scanner.scan(missing, policy: box.policy).entries.count == 1)
    }

    /// Folder variables are read from the profile text, never run; only literal values (and known variables).
    @Test func shellProfileParser() {
        let home = "/Users/me"
        let text = """
        export CARGO_HOME=/opt/cargo
        export CARGO_HOME="$HOME/dev/cargo"  # moved
        RUSTUP_HOME=~/dev/rustup
        export NVM_DIR='/Users/me/.nvm2'
        export GRADLE_USER_HOME="${HOME}/g"
        export HF_HOME=$(brew --prefix)/hf
        export HF_HUB_CACHE=`pwd`/hub
        export RUSTUP_HOME=$XDG_DATA_HOME/rustup
        export ANDROID_AVD_HOME="~/avd"
        export ANDROID_EMULATOR_HOME=$HOMEBREW/x
        export SECRET_TOKEN=abc
        if [ -d /x ]; then
        export HF_HOME=/in/if
        fi
          export HF_HOME=/indented
        if true; then export HF_HOME=/oneline; fi
        export HF_HOME=/a; rm -rf /
        export HF_HOME=/after/if
        """
        #expect(ShellEnvironment.parse(text, home: home) == [
            "CARGO_HOME": "/Users/me/dev/cargo", "RUSTUP_HOME": "/Users/me/.local/share/rustup", "NVM_DIR": "/Users/me/.nvm2",
            "GRADLE_USER_HOME": "/Users/me/g", "ANDROID_AVD_HOME": "~/avd", "HF_HOME": "/after/if",
        ])
        #expect(ShellEnvironment.value("'$HOME/x'", home: home) == nil)
        #expect(ShellEnvironment.value("/a/*", home: home) == nil)
        // XDG folders (spec defaults or set earlier) and listed variables set earlier, in load order.
        let xdg = """
        export NVM_DIR="$XDG_DATA_HOME/nvm"
        export HF_HOME=${XDG_CACHE_HOME}/hf
        export XDG_DATA_HOME=~/data
        export CARGO_HOME="$XDG_DATA_HOME/cargo"
        export RUSTUP_HOME=${CARGO_HOME}/../rustup
        export GRADLE_USER_HOME=$UNKNOWN/gradle
        export ANDROID_AVD_HOME=${XDG_DATA_HOME:-/x}/avd
        export HF_HUB_CACHE='$XDG_DATA_HOME/hub'
        """
        #expect(ShellEnvironment.parse(xdg, home: home) == [
            "NVM_DIR": "/Users/me/.local/share/nvm", "HF_HOME": "/Users/me/.cache/hf", "XDG_DATA_HOME": "/Users/me/data",
            "CARGO_HOME": "/Users/me/data/cargo", "RUSTUP_HOME": "/Users/me/data/cargo/../rustup",
        ])
        // A later line that can't be read makes the name unknown: no fallback to the default or an older value.
        let unknown = """
        export XDG_DATA_HOME=$(brew --prefix)/share
        export NVM_DIR=$XDG_DATA_HOME/nvm
        export CARGO_HOME=/c
          export CARGO_HOME=/indented
        export RUSTUP_HOME=$CARGO_HOME/r
        export GRADLE_USER_HOME=$XDG_CONFIG_HOME/gradle
        """
        #expect(ShellEnvironment.parse(unknown, home: home) == ["CARGO_HOME": "/c", "GRADLE_USER_HOME": "/Users/me/.config/gradle"])
        // Across files: a later file builds on an earlier one's values.
        #expect(ShellEnvironment.parse("export NVM_DIR=$XDG_DATA_HOME/nvm\n", home: home, known: ["XDG_DATA_HOME": "/d"])
                == ["NVM_DIR": "/d/nvm"])
    }

    /// `PATH` lines: several parts, `$PATH` anywhere (the folders found so far, empty at first), `~`/`$HOME`; a line that
    /// needs a shell or sits in a block is skipped without dropping what earlier lines added. Across files too.
    @Test func shellProfilePath() {
        let home = "/Users/me"
        let text = """
        export PATH="$HOME/.cargo/bin:$PATH"
        PATH=~/dev/bin:$PATH:/opt/x/bin
        export PATH="$(brew --prefix)/bin:$PATH"
        if [ -d ~/y ]; then export PATH=~/y:$PATH; fi
        export PATH=$PNPM_HOME:$PATH
        export PATH="${PATH}:$XDG_DATA_HOME/pnpm"
        """
        #expect(ShellEnvironment.parse(text, home: home)["PATH"]
                == "/Users/me/dev/bin:/Users/me/.cargo/bin::/opt/x/bin:/Users/me/.local/share/pnpm")
        #expect(ShellEnvironment.parse("export PATH=$PATH\n", home: home)["PATH"] == nil)
        #expect(ShellEnvironment.parse("export PATH=/b:$PATH\n", home: home, known: ["PATH": "/a"])["PATH"] == "/b:/a")
    }

    /// An item cleaned by a command never shows profile folders the command (without that env) wouldn't clean.
    @Test func shellFoldersOnlyOnFileRemovalItems() {
        let items = [CleanerGroup.developer].flatMap(\.items)
        #expect(items.contains { !$0.shellFolders.isEmpty })
        for item in items where !item.shellFolders.isEmpty {
            #expect(item.command == nil, "\(item.id)")
            #expect(Set(item.shellFolders.keys).isSubset(of: ShellEnvironment.variables), "\(item.id)")
        }
    }

    /// A folder set in the shell profile is scanned besides the default; outside home or nested counts once.
    @Test func shellProfileFolders() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.file(".cargo/registry/a/x.bin")
        try box.file("dev/cargo/registry/b/x.bin")
        try box.file("dev/cargo/git/c/x.bin")
        try box.file("dev/avd/p.avd/snapshots/s1/x.bin")
        let item = CleanerItem(id: "c", title: "c", paths: ["~/.cargo/registry"], shellFolders: ["CARGO_HOME": ["registry", "git"]])
        func names(_ item: CleanerItem) async -> [String] {
            await Scanner.scan(item, policy: box.policy).entries.map(\.url.lastPathComponent).sorted()
        }
        let profile = box.home.appending(path: ".zshrc")
        #expect(await names(item) == ["a"]) // no profile
        try "export CARGO_HOME=$HOME/dev/cargo\nexport ANDROID_AVD_HOME=~/dev/avd\n".write(to: profile, atomically: true, encoding: .utf8)
        #expect(await names(item) == ["a", "b", "c"])
        let avd = CleanerItem(id: "v", title: "v", paths: ["~/.android/avd/*.avd/snapshots"],
                              shellFolders: ["ANDROID_AVD_HOME": ["*.avd/snapshots"]])
        #expect(await names(avd) == ["s1"])
        // zsh wins over bash; the bash file only fills a variable zsh leaves unset.
        try "export CARGO_HOME=/nowhere\n".write(to: box.home.appending(path: ".bash_profile"), atomically: true, encoding: .utf8)
        #expect(await names(item) == ["a", "b", "c"])
        // Default folder itself, outside home, a protected folder, missing: default only.
        for refused in ["$HOME/.cargo", box.temp.path, "$HOME/Library/Caches", "$HOME/missing", "$HOME"] {
            try "export CARGO_HOME=\(refused)\n".write(to: profile, atomically: true, encoding: .utf8)
            #expect(await names(item) == ["a"], "\(refused)")
        }
        // Through a symlink: refused.
        try FileManager.default.createSymbolicLink(at: box.home.appending(path: "link"), withDestinationURL: box.home.appending(path: "dev"))
        try "export CARGO_HOME=$HOME/link/cargo # x\n".write(to: profile, atomically: true, encoding: .utf8)
        #expect(await names(item) == ["a"])
    }

    /// Hostile or mistaken profile values never add a folder: root, home, protected trees, `..`, symlinks out,
    /// quoting tricks. HF_HUB_CACHE is the worst case (the folder itself is the root, every child an entry).
    @Test func shellProfileBadValuesRefused() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.file(".cache/huggingface/hub/models--a/x.bin")
        for path in ["Documents/sub/registry/d", ".ssh/registry/k", "Library/registry/l", "Library/Caches/registry/c",
                     "Downloads/registry/x", "dev/x/y"] { try box.file(path) }
        try FileManager.default.createDirectory(at: box.temp.appending(path: "registry/t"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: box.home.appending(path: "out"), withDestinationURL: box.temp)
        let item = CleanerItem(id: "h", title: "h", paths: ["~/.cache/huggingface/hub"],
                               shellFolders: ["HF_HUB_CACHE": [""], "CARGO_HOME": ["registry", "git"]])
        let profile = box.home.appending(path: ".zshrc")
        for bad in ["/", "~", "~/", "$HOME", "${HOME}", "$HOME/", "$HOME/.", "$HOME/..", "$HOME/dev/../..", "$HOME/dev/x/../../..",
                    "~/Documents", "~/documents", "$HOME/Documents/sub", "$HOME/dev/../Documents", "~/.ssh", "~/.SSH/",
                    "~/Library", "~/Library/Caches", "~/Downloads", box.temp.path, "$HOME/out", "$HOME/out/registry",
                    "\"$HOME/Documents \"", "\"$HOME\"/Documents", "'$HOME/Documents'", "\"~/Documents\"", "~user/Documents",
                    " $HOME/Documents", "$HOME/Documents;", "$HOME/Documents && true", "$HOME/Doc\\ uments", "$TMPDIR",
                    "$HOMEX/Documents", "$HOME/.cache/huggingface/hub", "/private$HOME/Documents"] {
            try "export HF_HUB_CACHE=\(bad)\nexport CARGO_HOME=\(bad)\n".write(to: profile, atomically: true, encoding: .utf8)
            let names = await Scanner.scan(item, policy: box.policy).entries.map(\.url.lastPathComponent).sorted()
            #expect(names == ["models--a"], "\(bad)")
            // The same values reached through an XDG folder or another variable.
            try """
            export XDG_DATA_HOME=\(bad)
            export XDG_CACHE_HOME=\(bad)
            export NVM_DIR=\(bad)
            export HF_HUB_CACHE="$XDG_DATA_HOME"
            export CARGO_HOME=${XDG_CACHE_HOME}
            export HF_HOME=$NVM_DIR
            """.write(to: profile, atomically: true, encoding: .utf8)
            let chained = await Scanner.scan(item, policy: box.policy).entries.map(\.url.lastPathComponent).sorted()
            #expect(chained == ["models--a"], "chain \(bad)")
        }
        // Defaults lead to the default folder itself or nowhere; chains into forbidden places stay refused.
        for bad in ["export HF_HUB_CACHE=$XDG_CACHE_HOME/huggingface/hub", "export XDG_DATA_HOME=~\nexport HF_HUB_CACHE=$XDG_DATA_HOME/Documents",
                    "export NVM_DIR=$HOME/Library\nexport HF_HUB_CACHE=$NVM_DIR/Caches", "export CARGO_HOME=$XDG_CONFIG_HOME/../Documents/sub",
                    "export NVM_DIR=$HOME/out\nexport CARGO_HOME=$NVM_DIR", "export XDG_CACHE_HOME=$(pwd)\nexport HF_HUB_CACHE=$XDG_CACHE_HOME/huggingface/hub"] {
            try "\(bad)\n".write(to: profile, atomically: true, encoding: .utf8)
            let names = await Scanner.scan(item, policy: box.policy).entries.map(\.url.lastPathComponent).sorted()
            #expect(names == ["models--a"], "\(bad)")
        }
    }

    @Test func missingToolFallsBackToDeletingFolders() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.file(".npm/_cacache/content/a.bin")
        let item = CleanerItem(id: "n", title: "n", paths: ["~/.npm/_cacache"],
                               command: ShellCommand(executable: "cleanmate-no-such-tool"))
        let scan = await Scanner.scan(item, policy: box.policy)
        let report = await Cleaner.clean(item, scan: scan, policy: box.policy)
        #expect(report.skipped == 0 && report.freed == scan.size && scan.size > 0)
        #expect(!FileManager.default.fileExists(atPath: box.home.appending(path: ".npm/_cacache/content").path))
    }

    @Test func installedToolRunsInsteadOfDeleting() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let file = try box.file(".cache/uv/a.bin")
        let item = CleanerItem(id: "u", title: "u", paths: ["~/.cache/uv"], command: ShellCommand(executable: "true"))
        let report = await Cleaner.clean(item, scan: await Scanner.scan(item, policy: box.policy), policy: box.policy)
        #expect(report.skipped == 0 && report.freed == 0)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    /// A cleanup command removes what it likes in its folder: a user exclusion there, around it, or at the folder the
    /// tool prints (`locate`) keeps the command from running.
    @Test(arguments: [".cache/uv/keep", ".cache", "custom/keep"])
    func commandNeverRunsOverAUserExclusion(excluded: String) async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let kept = [try box.file(".cache/uv/keep/a.bin"), try box.file("custom/keep/b.bin")]
        let policy = SafetyPolicy(home: box.home, temp: box.temp, excluded: [box.home.appending(path: excluded).path])
        let wipe = ShellCommand(executable: "/bin/rm", arguments: ["-rf", box.home.appending(path: ".cache/uv").path,
                                                                 box.home.appending(path: "custom").path])
        let item = CleanerItem(id: "u", title: "u", paths: ["~/.cache/uv"], command: wipe,
                               locate: PathLookup(command: ShellCommand(executable: "/bin/echo",
                                                                        arguments: [box.home.appending(path: "custom").path])))
        let report = await Cleaner.clean(item, scan: await Scanner.scan(item, policy: policy), policy: policy)
        #expect(report.skipped == 1 && report.freed == 0)
        for file in kept { #expect(FileManager.default.fileExists(atPath: file.path)) }
    }

    /// A probe-measured scan (`.bytes`) lists no files of the item, whatever entries it carries: with the tool gone,
    /// nothing is removed even when the item has paths.
    @Test func measuredScanEntriesAreNeverRemoved() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let file = try box.file(".cache/tool/a.bin")
        let item = CleanerItem(id: "t", title: "t", paths: ["~/.cache/tool"],
                               command: ShellCommand(executable: "cleanmate-no-such-tool"))
        let report = await Cleaner.clean(item, scan: ItemScan(entries: [ScanEntry(url: file, size: 1)], measuredSize: 1),
                                         policy: box.policy)
        #expect(report.skipped == 1 && report.freed == 0)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func bareToolNamesResolveAndCaptureOutput() async {
        #expect(ShellCommand(executable: "sh").resolvedPath != nil)
        #expect(ShellCommand(executable: "cleanmate-no-such-tool").resolvedPath == nil)
        #expect(await ShellCommand(executable: "/bin/echo", arguments: ["hi"]).output() == "hi\n")
        #expect(await ShellCommand(executable: "/bin/sh", arguments: ["-c", "echo x; exit 3"]).output() == nil)
    }
}

struct DeveloperToolsTests {
    @Test func dockerSystemDf() {
        let output = """
        {"Active":"2","Reclaimable":"1.995GB (77%)","Size":"2.573GB","TotalCount":"3","Type":"Images"}
        {"Active":"2","Reclaimable":"0B (0%)","Size":"72.24MB","TotalCount":"2","Type":"Containers"}
        {"Active":"1","Reclaimable":"14.21GB (98%)","Size":"14.45GB","TotalCount":"28","Type":"Local Volumes"}
        {"Active":"0","Reclaimable":"512kB","Size":"0B","TotalCount":"0","Type":"Build Cache"}
        """
        #expect(DeveloperTools.dockerReclaimable("Images", in: output) == 1_995_000_000)
        #expect(DeveloperTools.dockerReclaimable("Containers", in: output) == 0)
        #expect(DeveloperTools.dockerReclaimable("Local Volumes", in: output) == 14_210_000_000)
        #expect(DeveloperTools.dockerReclaimable("Build Cache", in: output) == 512_000)
        #expect(DeveloperTools.dockerReclaimable("Images", in: "Cannot connect to the Docker daemon") == nil)
        #expect(DeveloperTools.bytes(fromDockerSize: "1.5GiB") == 1_610_612_736)
        #expect(DeveloperTools.bytes(fromDockerSize: "12XB") == nil)
    }

    @Test func dockerUnusedImages() {
        let output = """
        {"Images":[\
        {"Containers":"0","CreatedAt":"2026-10-22 03:48:02 +0700 +07","ID":"sha256:8b1bc650def028e2a1","Repository":"app-dev","Size":"1.82GB","Tag":"latest"},\
        {"Containers":"1","CreatedAt":"2026-10-06 08:36:10 +0700 +07","ID":"sha256:a470461db3d4079fb4","Repository":"postgres","Size":"477MB","Tag":"17"},\
        {"Containers":"0","CreatedAt":"2026-09-18 05:11:30 +0000 UTC","ID":"sha256:6fecacab9f884dc313","Repository":"<none>","Size":"97.9MB","Tag":"<none>"}\
        ],"Containers":[],"Volumes":[],"BuildCache":[]}
        """
        let images = DeveloperTools.dockerUnusedImages(in: output)
        #expect(images.map(\.title) == ["app-dev:latest", "6fecacab9f88"]) // postgres:17 has a (stopped) container
        #expect(images.map(\.size) == [1_820_000_000, 97_900_000])
        #expect(images[0].date == Date(timeIntervalSince1970: 1_792_615_682))
        #expect(Set(images.map(\.url)).count == 2 && images.allSatisfy { !$0.url.isFileURL })
        #expect(DeveloperTools.dockerUnusedImages(in: "Cannot connect to the Docker daemon").isEmpty)
    }

    /// Stopped containers / unused volumes listed exactly as `container prune` / `volume prune --all` remove them.
    @Test func dockerStoppedContainersAndUnusedVolumes() throws {
        let hex = String(repeating: "ed5c3850", count: 8)
        let output = """
        {"Images":[],"Containers":[\
        {"CreatedAt":"2026-10-22 13:05:02 +0700 +07","Image":"app-dev","Names":"web","Size":"2.75MB","State":"running","Status":"Up 8 minutes"},\
        {"CreatedAt":"2026-10-22 03:16:13 +0700 +07","Image":"alpine:3","Names":"lint","Size":"0B","State":"created","Status":"Created"},\
        {"CreatedAt":"2026-10-19 11:43:56 +0700 +07","Image":"postgres:17","Names":"db-1","Size":"16kB","State":"exited","Status":"Exited (0) 2 days ago"},\
        {"CreatedAt":"2026-10-19 11:43:56 +0700 +07","Image":"redis","Names":"cache","Size":"1kB","State":"paused","Status":"Up 1 hour (Paused)"},\
        {"CreatedAt":"2026-10-19 11:43:56 +0700 +07","Image":"redis","Names":"flaky","Size":"1kB","State":"restarting","Status":"Restarting"},\
        {"CreatedAt":"2026-10-19 11:43:56 +0700 +07","Image":"redis","Names":"gone","Size":"1kB","State":"dead","Status":"Dead"}\
        ],"Volumes":[\
        {"Driver":"local","Labels":"com.docker.volume.anonymous=","Links":"0","Name":"\(hex)","Size":"314.7MB"},\
        {"Driver":"local","Labels":"","Links":"0","Name":"limcare_pgdata","Size":"48MB"},\
        {"Driver":"local","Labels":"","Links":"1","Name":"in-use","Size":"3.7GB"},\
        {"Driver":"local","Labels":"","Links":"0","Name":"\(hex.dropLast(2))zz","Size":"N/A"}\
        ],"BuildCache":[]}
        """
        let containers = DeveloperTools.dockerStoppedContainers(in: output)
        #expect(containers.map(\.title) == ["lint · alpine:3 · Created", "db-1 · postgres:17 · Exited (0) 2 days ago",
                                            "gone · redis · Dead"]) // running, paused, restarting are kept by prune
        #expect(containers.map(\.size) == [0, 16_000, 1_000])
        #expect(containers[1].date == DeveloperTools.dockerDate("2026-10-19 11:43:56 +0700 +07") && containers[1].date != nil)
        let volumes = DeveloperTools.dockerUnusedVolumes(in: output)
        #expect(volumes.count == 3) // `--all`: named unused volumes too; "in-use" has a container
        #expect(volumes[0].title?.hasPrefix(String(hex.prefix(12)) + " · ") == true && volumes[0].title?.hasSuffix(" · local") == true)
        #expect(volumes[0].title != String(hex.prefix(12)) + " · local") // marked anonymous
        #expect(volumes[1].title == "limcare_pgdata · local" && volumes[1].size == 48_000_000)
        #expect(volumes[2].title == "\(hex.dropLast(2))zz · local" && volumes[2].size == 0) // not hex: named
        let urls = (containers + volumes).map(\.url)
        #expect(Set(urls).count == urls.count && urls.allSatisfy { !$0.isFileURL })
        #expect(DeveloperTools.dockerStoppedContainers(in: "Cannot connect").isEmpty)
        #expect(DeveloperTools.dockerUnusedVolumes(in: "Cannot connect").isEmpty)
        // The prune commands these lists mirror (never made more aggressive).
        let items = CleanerGroup.developer.items
        let containerItem = try #require(items.first { $0.id == "docker-containers" })
        let volumeItem = try #require(items.first { $0.id == "docker-volumes" })
        #expect(containerItem.command?.arguments == ["container", "prune", "--force"])
        #expect(volumeItem.command?.arguments == ["volume", "prune", "--all", "--force"])
    }

    /// Build cache: every record not in use, one entry each by its ID; an in-use record is never listed.
    @Test func dockerPrunableBuildCache() throws {
        let long = String(repeating: "x", count: 80)
        let output = """
        {"Images":[],"Containers":[],"Volumes":[],"BuildCache":[\
        {"CacheType":"regular","CreatedAt":"2026-10-21 20:47:48.935345187 +0000 UTC","Description":"mount / from exec /bin/sh -c apt-get update","ID":"bq3itzl10tm8j1gn19o4ej3pi","InUse":"false","LastUsedAt":"2026-10-21 20:48:07.189503195 +0000 UTC","Parent":"","Shared":"false","Size":"1.16GB","UsageCount":"1"},\
        {"CacheType":"regular","CreatedAt":"2026-10-21 20:45:10.262416741 +0000 UTC","Description":"pulled from docker.io/library/ubuntu:24.04","ID":"bzbo560astpltinpb8pdz91mu","InUse":"false","LastUsedAt":"2026-10-21 20:48:07.18723845 +0000 UTC","Parent":"","Shared":"true","Size":"564MB","UsageCount":"1"},\
        {"CacheType":"exec.cachemount","CreatedAt":"2026-10-21 20:45:10 +0000 UTC","Description":"\(long)","ID":"inuse0000000000","InUse":"true","Parent":"","Shared":"false","Size":"2GB","UsageCount":"3"},\
        {"CacheType":"source.local","CreatedAt":"2026-10-21 20:45:10 +0000 UTC","Description":"\(long)","ID":"local0000000000","InUse":"false","Parent":"","Shared":"false","Size":"235kB","UsageCount":"1"}\
        ]}
        """
        let cache = DeveloperTools.dockerPrunableBuildCache(in: output)
        #expect(cache.count == 3) // the in-use record is kept by prune
        #expect(cache[0].title == "bq3itzl10tm8 · regular · mount / from exec /bin/sh -c apt-get update")
        #expect(cache.map(\.size) == [1_160_000_000, 0, 235_000]) // shared: frees nothing, like docker's Reclaimable
        #expect(cache[1].title?.hasPrefix("bzbo560astpl · regular · pulled from") == true && cache[1].title!.count > 60)
        #expect(cache[2].title == "local0000000 · source.local · " + String(repeating: "x", count: 59) + "…")
        #expect(cache[0].date == Date(timeIntervalSince1970: 1_792_615_687) && cache[2].date == nil)
        #expect(cache.map(\.url.absoluteString) == ["docker-build-cache:bq3itzl10tm8j1gn19o4ej3pi",
                                                     "docker-build-cache:bzbo560astpltinpb8pdz91mu",
                                                     "docker-build-cache:local0000000000"])
        #expect(!cache.contains { $0.url.absoluteString.contains("inuse") })
        #expect(DeveloperTools.dockerPrunableBuildCache(in: "Cannot connect").isEmpty)
        let item = try #require(CleanerGroup.developer.items.first { $0.id == "docker-build-cache" })
        #expect(!item.selectedByDefault && item.selectableEntries && item.paths.isEmpty && item.entryCommand != nil)
        guard case .bytes(let total)? = item.probe?.parse(output) else { Issue.record("no size"); return }
        #expect(total == 1_160_235_000)
        let empty = #"{"Images":[],"BuildCache":[]}"#
        #expect(item.probe?.parse(empty) == nil) // none: hidden
        let command = try #require(item.entryCommand?(cache[0].url))
        #expect(command.arguments == ["builder", "prune", "--all", "--force", "--filter", "id=bq3itzl10tm8j1gn19o4ej3pi"])
        // An internal/frontend record (source.local) is listed, so its command needs --all to remove it.
        let local = try #require(item.entryCommand?(cache[2].url))
        #expect(local.arguments == ["builder", "prune", "--all", "--force", "--filter", "id=local0000000000"])
        for bad in ["docker-build-cache:--all", "docker-build-cache:abc", "docker-build-cache:ABCDEFGHIJKLMN",
                    "docker-build-cache:bq3itzl10tm8,id=x", "docker-build-cache:unreadable", "docker-dangling:bq3itzl10tm8j1g"] {
            #expect(item.entryCommand?(URL(string: bad)!) == nil, "\(bad)")
        }
    }

    /// Only the ticked records reach `docker builder prune`, each by its own ID; freed = their sizes.
    @Test func buildCacheIsRemovedPerEntry() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let log = box.root.appending(path: "calls.txt")
        let script = try box.file("fake-docker.sh")
        try "#!/bin/sh\necho \"$@\" >> '\(log.path)'\n[ \"$5\" != id=local0000000000 ]\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        var item = try #require(CleanerGroup.developer.items.first { $0.id == "docker-build-cache" })
        item.command = ShellCommand(executable: script.path)
        item.entryCommand = { url in
            DeveloperTools.dockerBuildCacheID(of: url).map {
                ShellCommand(executable: script.path, arguments: ["builder", "prune", "--force", "--filter", "id=\($0)"])
            }
        }
        item.probe?.precondition = { true }
        let scan = ItemScan(entries: [
            ScanEntry(url: URL(string: "docker-build-cache:bq3itzl10tm8j1gn19o4ej3pi")!, size: 10),
            ScanEntry(url: URL(string: "docker-build-cache:local0000000000")!, size: 5),
            ScanEntry(url: URL(string: "docker-build-cache:unreadable")!, size: 0),
        ], measuredSize: 15)
        let report = await Cleaner.clean(item, scan: scan, policy: box.policy)
        #expect(report.freed == 10 && report.skipped == 2)
        #expect(try String(contentsOf: log, encoding: .utf8)
                == "builder prune --force --filter id=bq3itzl10tm8j1gn19o4ej3pi\nbuilder prune --force --filter id=local0000000000\n")
    }

    /// A record missing a field drops only itself; the rest still shows, plus a row counting the unreadable.
    @Test func dockerRecordMissingFieldKeepsTheList() {
        let output = """
        {"Images":[],"Containers":[\
        {"CreatedAt":"2026-10-19 11:43:56 +0700 +07","Image":"redis","Names":"gone","Size":"1kB","State":"exited","Status":"Exited"},\
        {"CreatedAt":"2026-10-19 11:43:56 +0700 +07","Image":"redis","Names":"odd","Size":"1kB","Status":"Exited"}\
        ],"Volumes":[{"Driver":"local","Labels":"","Links":"0","Name":"data","Size":"1kB"},{"Name":"broken"}],\
        "BuildCache":[{"ID":"x"}]}
        """
        let containers = DeveloperTools.dockerStoppedContainers(in: output)
        #expect(containers.count == 2 && containers[0].title == "gone · redis · Exited")
        #expect(containers[1].size == 0 && containers[1].title?.contains("1") == true && containers[1].url.absoluteString == "docker-container:unreadable")
        let volumes = DeveloperTools.dockerUnusedVolumes(in: output)
        #expect(volumes.map(\.url.absoluteString) == ["docker-volume:0", "docker-volume:unreadable"])
        #expect(DeveloperTools.dockerPrunableBuildCache(in: output).map(\.url.absoluteString) == ["docker-build-cache:unreadable"])
    }

    @Test func staleSimulatorRuntimes() throws {
        func runtime(_ id: String, _ platform: String, _ version: String, used: String?, deletable: Bool = true) -> String {
            """
            "\(id)": {"identifier": "\(id)", "platformIdentifier": "com.apple.platform.\(platform)", "version": "\(version)",
              "deletable": \(deletable), "sizeBytes": 1000, "state": "Ready"\(used.map { ", \"lastUsedAt\": \"\($0)\"" } ?? "")}
            """
        }
        let now = try Date("2026-10-22T00:00:00Z", strategy: .iso8601)
        let json = "{" + [
            runtime("ios-27", "iphonesimulator", "27.0", used: "2026-10-21T23:34:28Z"), // current: never chosen
            runtime("ios-17", "iphonesimulator", "17.5", used: "2026-01-01T00:00:00Z"), // older, unused: chosen
            runtime("ios-18", "iphonesimulator", "18.10", used: nil),                   // never used: chosen
            runtime("ios-26", "iphonesimulator", "26.4", used: "2026-10-10T00:00:00Z"), // used 12 days ago: kept
            runtime("ios-16", "iphonesimulator", "16.0", used: nil, deletable: false),  // simctl can't delete it
            runtime("watch-11", "watchsimulator", "11.0", used: "2025-01-01T00:00:00Z"), // only one of its platform
        ].joined(separator: ",") + "}"
        let stale = try #require(DeveloperTools.staleRuntimes(in: json, now: now))
        #expect(stale.ids == ["ios-17", "ios-18"] && stale.bytes == 2000)
        // This Mac's real output: the only iOS runtime is never chosen.
        #expect(DeveloperTools.staleRuntimes(in: "{" + runtime("a", "iphonesimulator", "27.0", used: nil) + "}", now: now) == nil)
        #expect(DeveloperTools.staleRuntimes(in: "{}") == nil)
        #expect(DeveloperTools.staleRuntimes(in: "xcrun: error: unable to find utility") == nil)
        let item = try #require(CleanerGroup.developer.items.first { $0.id == "old-simulator-runtimes" })
        #expect(!item.selectedByDefault && item.paths.isEmpty && item.runningAppBundleIDs.contains("com.apple.dt.Xcode"))
    }

    @Test func brewCleanupDryRun() {
        let output = """
        Would remove: /Users/me/Library/Caches/Homebrew/Cask/gcloud-cli--589.0.0.tar.gz (54.2MB)
        ==> This operation would free approximately 54.5MB of disk space.
        """
        #expect(DeveloperTools.brewReclaimable(in: output) == 54_500_000)
        #expect(DeveloperTools.brewReclaimable(in: "==> This operation would free approximately 2GB of disk space.")
            == 2_000_000_000)
        #expect(DeveloperTools.brewReclaimable(in: "") == nil) // nothing to clean: brew prints no total
    }

    /// `brew autoremove --dry-run`: listed formulae measured in the Cellar (a tap formula by its name; unknown or odd
    /// names left out), shown as display-only entries with their total; nothing to remove → no size, item hidden.
    @Test func brewAutoremoveDryRun() async throws {
        let item = try #require(CleanerGroup.developer.items.first { $0.id == "brew-autoremove" })
        #expect(!item.selectedByDefault && item.paths.isEmpty && !item.showsWhenEmpty && !item.selectableEntries)
        #expect(item.command?.arguments == ["autoremove"] && item.runningProcessNames == ["brew"])
        #expect(item.probe?.command.arguments == ["autoremove", "--dry-run"] && item.probe?.fingerprint != nil)

        let root = FileManager.default.temporaryDirectory.appending(path: "CleanMateBrew-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cellar = root.appending(path: "Cellar")
        for (path, bytes) in [("libyaml/0.2.5/lib/libyaml.dylib", 8192), ("oniguruma/6.9.9/lib/a.dylib", 4096), ("etc", 4096)] {
            let url = cellar.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: bytes).write(to: url)
        }
        let output = """
        ==> Would autoremove 4 unneeded formulae:
        libyaml
        user/tap/oniguruma
        missing
        ../etc
        libyaml
        """
        let entries = DeveloperTools.brewAutoremovable(in: output, cellar: cellar)
        #expect(entries.map(\.title) == ["libyaml", "oniguruma"])
        #expect(entries.map(\.size) == [8192, 4096] && entries.allSatisfy { !$0.url.isFileURL })
        #expect(DeveloperTools.brewAutoremovable(in: "", cellar: cellar).isEmpty)
        #expect(DeveloperTools.brewAutoremovable(in: output, cellar: nil).isEmpty)

        // Through the scanner with a stand-in for brew: the dry run's output gives the total and the listed formulae.
        func scan(_ text: String) async -> ItemScan {
            let probe = DeveloperTools.brewAutoremoveProbe(dryRun: ShellCommand(executable: "/usr/bin/printf", arguments: ["%s", text]),
                                                           cellar: { cellar })
            return await Scanner.scan(CleanerItem(id: "brew-test", title: "Brew", paths: [], probe: probe))
        }
        let found = await scan(output)
        #expect(found.measuredSize == 12_288 && found.entries.map(\.title) == ["libyaml", "oniguruma"])
        let empty = await scan("")
        #expect(empty.measuredSize == nil && empty.entries.isEmpty && !empty.hasData)
    }

    /// The brew dry run is reused while its folders are unchanged and less than `reuseLimit` old.
    @Test func probeOutputReuse() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let saved: [String: Any] = ["fingerprint": "a", "output": "out", "date": now]
        #expect(SizeProbe.reusable(saved, fingerprint: "a", now: now.addingTimeInterval(60)) == "out")
        #expect(SizeProbe.reusable(saved, fingerprint: "b", now: now) == nil)
        #expect(SizeProbe.reusable(saved, fingerprint: "a", now: now.addingTimeInterval(SizeProbe.reuseLimit)) == nil)
        #expect(SizeProbe.reusable(saved, fingerprint: "a", now: now.addingTimeInterval(-60)) == nil) // clock moved back
        #expect(SizeProbe.reusable(nil, fingerprint: "a", now: now) == nil)

        // uuidgen prints something new on each run: same output = reused.
        let suite = "probeOutputReuse-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        func probe(_ fingerprint: String) -> SizeProbe {
            SizeProbe(command: ShellCommand(executable: "/usr/bin/uuidgen"), parse: { _ in nil }, fingerprint: { fingerprint })
        }
        let first = try #require(await probe("1").output(defaults: defaults, now: now))
        #expect(await probe("1").output(defaults: defaults, now: now.addingTimeInterval(60)) == first)
        let second = try #require(await probe("2").output(defaults: defaults, now: now.addingTimeInterval(60)))
        #expect(second != first)
        #expect(await probe("2").output(defaults: defaults, now: now.addingTimeInterval(60 + SizeProbe.reuseLimit)) != second)

        // After the item's own command ran (brew cleanup), the saved output is dropped: the next run is real.
        let third = try #require(await probe("3").output(defaults: defaults, now: now))
        probe("3").forgetOutput(defaults: defaults)
        #expect(await probe("3").output(defaults: defaults, now: now) != third)

        // Without a fingerprint the command always runs.
        let plain = SizeProbe(command: ShellCommand(executable: "/usr/bin/uuidgen"), parse: { _ in nil })
        #expect(await plain.output(defaults: defaults) != plain.output(defaults: defaults))
    }

    /// A file added inside a child folder (a new version in `Cellar/<name>`) changes the fingerprint.
    @Test func folderDatesFingerprint() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "folderDates-\(UUID())")
        let child = root.appending(path: "wget")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appending(path: "missing")
        let before = SizeProbe.folderDates([root, missing])
        #expect(before == SizeProbe.folderDates([root, missing]))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: child.path)
        let older = SizeProbe.folderDates([root, missing])
        #expect(older != before)
        try FileManager.default.createDirectory(at: child.appending(path: "1.25"), withIntermediateDirectories: false)
        #expect(SizeProbe.folderDates([root, missing]) != older)
        let item = try #require(CleanerGroup.developer.items.first { $0.id == "homebrew-cache" })
        #expect(item.probe?.fingerprint != nil)
    }

    /// npx, nvm and rustup download caches: their own folders only, ticked, skipped while the tool runs.
    @Test func toolDownloadCacheItems() {
        let items = Dictionary(uniqueKeysWithValues: CleanerGroup.developer.items.map { ($0.id, $0) })
        let npx = items["npx-cache"], nvm = items["nvm-cache"], rustup = items["rustup-downloads"]
        #expect(npx?.paths == ["~/.npm/_npx"] && npx?.locate?.subpath == "_npx" && npx?.runningProcessNames == ["npx"])
        #expect(nvm?.paths == ["~/.nvm/.cache"] && nvm?.runningProcessNames == [])
        #expect(rustup?.paths == ["~/.rustup/downloads", "~/.rustup/tmp"])
        #expect(rustup?.runningProcessNames == ["rustup"] && rustup?.skipsOpenFiles == true)
        #expect([npx, nvm, rustup].allSatisfy { $0?.selectedByDefault == true && $0?.showsWhenEmpty == false })
        let mine = Set([npx, nvm, rustup].flatMap { $0?.paths ?? [] })
        let others = CleanerGroup.developer.items.filter { !["npx-cache", "nvm-cache", "rustup-downloads"].contains($0.id) }
        #expect(!others.flatMap(\.paths).contains { path in mine.contains { $0.hasPrefix(path + "/") || path.hasPrefix($0) } })
    }

    /// rustup downloads stay while `cargo`/`rustc` build, and are locked only while `rustup` itself runs.
    @MainActor @Test func rustupDownloadsLockedOnlyByRustup() throws {
        let rustup = try #require(CleanerGroup.developer.items.first { $0.id == "rustup-downloads" })
        let model = SmartScanModel(module: .smartScan) { [] }
        model.runningProcesses = ["cargo", "rustc"]
        #expect(!model.isRunning(rustup))
        model.runningProcesses = ["rustup"]
        #expect(model.isRunning(rustup))
    }

    /// A running Firebase emulator (a JVM or binary run from ~/.cache/firebase/emulators) locks the emulators item.
    @MainActor @Test func firebaseEmulatorsLockedWhileOneRuns() throws {
        let item = try #require(CleanerGroup.developer.items.first { $0.id == "firebase-emulators" })
        func names(_ strings: [String]) -> Set<String> {
            let argc = Int32(strings.count - 1)
            return RunningProcesses.argumentNames(withUnsafeBytes(of: argc) { Array($0) } + strings.flatMap { Array($0.utf8) + [0] })
        }
        let model = SmartScanModel(module: .smartScan) { [] }
        model.runningProcesses = names(["/usr/bin/java", "java", "-jar",
                                        "/Users/u/.cache/firebase/emulators/cloud-firestore-emulator-v1.19.jar"])
        #expect(model.isRunning(item) && model.isLocked(item))
        model.runningProcesses = names(["/usr/bin/java", "java", "-jar", "/Users/u/app.jar"])
            .union(names(["/opt/bin/node", "node", "/opt/bin/firebase", "login"]))
        #expect(!model.isLocked(item))
    }

    /// DerivedData skipped while Xcode builds; Yarn Berry and Cypress unticked; package caches skipped while their tool runs.
    @Test func catalogAuditItems393() {
        let items = Dictionary(uniqueKeysWithValues: CleanerGroup.developer.items.map { ($0.id, $0) })
        let derived = items["xcode-derived-data"]
        #expect(derived?.runningAppBundleIDs == ["com.apple.dt.Xcode"] && derived?.runningProcessNames == ["xcodebuild"])
        #expect(derived?.selectedByDefault == true)
        #expect(items["yarn-cache"]?.paths == ["~/Library/Caches/Yarn"] && items["yarn-cache"]?.selectedByDefault == true)
        #expect(items["yarn-berry-cache"]?.paths == ["~/.yarn/berry/cache"])
        #expect(items["cypress-binary"]?.paths == ["~/Library/Caches/Cypress"])
        #expect(CleanerGroup.ownedCachePaths.contains("Cypress"))
        #expect(items["cargo-registry"]?.runningProcessNames == ["cargo"])
        #expect(items["yarn-cache"]?.runningProcessNames == ["yarn"] && items["yarn-berry-cache"]?.runningProcessNames == ["yarn"])
        #expect(items["bun-cache"]?.runningProcessNames == ["bun"])
        #expect(items["pip-cache"]?.runningProcessNames == ["pip", "pip3"])
        func buffer(_ argc: Int32, _ strings: [String]) -> [UInt8] {
            withUnsafeBytes(of: argc) { Array($0) } + strings.flatMap { Array($0.utf8) + [0] }
        }
        // `yarn` run by node through its shim, a project's pinned Berry release, or the npm package's yarn.js.
        #expect(RunningProcesses.argumentNames(buffer(3, ["/opt/bin/node", "node", "/opt/bin/yarn", "install"])).contains("yarn"))
        #expect(RunningProcesses.argumentNames(buffer(2, ["/opt/bin/node", "node", "/p/.yarn/releases/yarn-4.5.0.cjs"])).contains("yarn"))
        #expect(RunningProcesses.argumentNames(buffer(2, ["/opt/bin/node", "node", "/l/node_modules/yarn/bin/yarn.js"])).contains("yarn"))
        #expect(RunningProcesses.argumentNames(buffer(4, ["/usr/bin/python3", "python3", "-m", "pip", "install"])).contains("pip"))
        #expect(RunningProcesses.argumentNames(buffer(3, ["/v/bin/python3.12", "python3.12", "/v/bin/pip3", "list"])).contains("pip3"))
        #expect(RunningProcesses.argumentNames(buffer(2, ["/u/.cargo/bin/cargo", "cargo", "build"])).contains("cargo"))
        // brew: `bash …/brew.sh` and then `ruby … …/brew.rb`.
        #expect(RunningProcesses.argumentNames(buffer(3, ["/bin/bash", "/bin/bash", "-p", "/opt/homebrew/Library/Homebrew/brew.sh"])).contains("brew"))
        #expect(RunningProcesses.argumentNames(buffer(4, ["/r/bin/ruby", "ruby", "-W1", "--", "/usr/local/Homebrew/Library/Homebrew/brew.rb"])).contains("brew"))
        #expect(RunningProcesses.argumentNames(buffer(2, ["/u/.bun/bin/bun", "bun", "install"])).contains("bun"))
    }

    /// Hugging Face and Prisma caches: one entry per repo folder, removed whole; the token is never listed.
    @Test func huggingFaceRepoEntriesNeverTheToken() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let items = Dictionary(uniqueKeysWithValues: CleanerGroup.developer.items.map { ($0.id, $0) })
        let hf = try #require(items["huggingface-cache"]), prisma = try #require(items["prisma-engines"])
        #expect(hf.paths == ["~/.cache/huggingface/hub"])
        #expect(!hf.selectedByDefault && hf.selectableEntries && hf.command == nil && hf.probe == nil)
        #expect(prisma.paths == ["~/.cache/prisma"] && prisma.selectedByDefault)
        let blob = try box.file(".cache/huggingface/hub/models--org--name/blobs/abc")
        let snapshot = box.home.appending(path: ".cache/huggingface/hub/models--org--name/snapshots/rev")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: snapshot.appending(path: "model.bin"), withDestinationURL: blob)
        try box.file(".cache/huggingface/datasets/org___set/data.arrow")
        let tokens = [try box.file(".cache/huggingface/token"), try box.file(".cache/huggingface/stored_tokens")]
        let listed = await Scanner.scan(hf, policy: box.policy).entries.map(\.url.lastPathComponent)
        #expect(Set(listed) == ["models--org--name"])
        #expect(tokens.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    /// HF_HUB_CACHE pointed at an ordinary folder lists only hub repo folders, never its other children,
    /// and the clean re-checks the names (a forged scan entry is kept).
    @Test func huggingFaceHubCacheOnlyRepoFolders() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let hf = try #require(CleanerGroup.developer.items.first { $0.id == "huggingface-cache" })
        let project = try box.file("Developer/app/main.swift")
        try box.file("Developer/notes.txt")
        try "export HF_HUB_CACHE=~/Developer\n".write(to: box.home.appending(path: ".zshrc"), atomically: true, encoding: .utf8)
        #expect(await Scanner.scan(hf, policy: box.policy).entries.isEmpty)
        try box.file("Developer/models--a--b/blobs/x")
        let scan = await Scanner.scan(hf, policy: box.policy)
        #expect(scan.entries.map(\.url.lastPathComponent) == ["models--a--b"])
        var forged = scan
        forged.entries.append(ScanEntry(url: project.deletingLastPathComponent(), size: 1))
        let report = await Cleaner.clean(hf, scan: forged, policy: box.policy)
        #expect(report.skipped == 1 && FileManager.default.fileExists(atPath: project.path))
        #expect(!FileManager.default.fileExists(atPath: box.home.appending(path: "Developer/models--a--b").path))
    }

    /// The clean re-checks `excluded` by path under the root: a forged entry that is excluded, inside an
    /// excluded folder or holding one is kept; a sibling the scan would list still goes.
    @Test func cleanRechecksExcluded() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let item = CleanerItem(id: "c", title: "c", paths: ["~/Library/Caches"], excluded: ["keep", "Google/Chrome"])
        let keep = try box.file("Library/Caches/keep/a").deletingLastPathComponent()
        let chrome = try box.file("Library/Caches/Google/Chrome/b").deletingLastPathComponent()
        let other = try box.file("Library/Caches/Google/Other/c").deletingLastPathComponent()
        let google = other.deletingLastPathComponent()
        let scan = await Scanner.scan(item, policy: box.policy)
        #expect(scan.entries.map(\.url.standardizedFileURL) == [other.standardizedFileURL])
        var forged = scan
        forged.entries += [keep, chrome, chrome.appending(path: "b"), google].map { ScanEntry(url: $0, size: 1) }
        let report = await Cleaner.clean(item, scan: forged, policy: box.policy)
        #expect(report.skipped == 4)
        #expect([keep, chrome].allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(!FileManager.default.fileExists(atPath: other.path))
        #expect(!Cleaner.isExcluded(URL(fileURLWithPath: "/elsewhere/Chrome"), excluded: ["Google/Chrome"], roots: []))
        #expect(Cleaner.isExcluded(URL(fileURLWithPath: "/elsewhere/keep"), excluded: ["keep"], roots: []))
    }

    /// The cleaner's open-file and `excluded` checks cover the same roots as the scan, a `shellFolders` folder too.
    @Test func cleanChecksOpenFilesAndExcludedUnderShellFolders() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let held = try box.file("dev/cargo/registry/a/x.bin")
        try box.file("dev/cargo/registry/b/x.bin")
        let keep = try box.file("dev/cargo/registry/b2/keep/x.bin").deletingLastPathComponent()
        try "export CARGO_HOME=$HOME/dev/cargo\n".write(to: box.home.appending(path: ".zshrc"), atomically: true, encoding: .utf8)
        let item = CleanerItem(id: "c", title: "c", paths: ["~/.cargo/registry"], excluded: ["b2/keep"],
                               shellFolders: ["CARGO_HOME": ["registry"]], skipsOpenFiles: true)
        var scan = await Scanner.scan(item, policy: box.policy)
        #expect(scan.entries.map(\.url.lastPathComponent).sorted() == ["a", "b"])
        scan.entries.append(ScanEntry(url: keep, size: 1))
        let report = await Cleaner.clean(item, scan: scan, policy: box.policy, openPaths: { root in
            root.hasSuffix("dev/cargo/registry") ? [RunningProcesses.withoutPrivate(held.standardizedFileURL.path)] : []
        })
        #expect(report.skipped == 2)
        #expect(FileManager.default.fileExists(atPath: held.path) && FileManager.default.fileExists(atPath: keep.path))
        #expect(!FileManager.default.fileExists(atPath: box.home.appending(path: "dev/cargo/registry/b").path))
    }

    /// A profile variable's folder itself is a scan root only when the item filters names (`included`);
    /// otherwise roots are tool-specific subfolders (`registry`, `.cache`, `*.avd/snapshots`).
    @Test func shellFolderValueIsRootOnlyWithNameFilter() {
        for item in CleanerGroup.developer.items where item.shellFolders.values.contains(where: { $0.contains("") }) {
            #expect(item.included != nil, "\(item.id)")
        }
    }

    /// Android emulator snapshots: one entry per snapshot, unticked, skipped while an emulator runs;
    /// the AVD's disks and settings are never listed.
    @Test func androidSnapshotEntriesNeverTheAvdData() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let item = try #require(CleanerGroup.developer.items.first { $0.id == "android-avd-snapshots" })
        #expect(item.paths == ["~/.android/avd/*.avd/snapshots"] && item.mode == .delete)
        #expect(!item.selectedByDefault && item.selectableEntries && item.command == nil && item.probe == nil)
        #expect(item.runningProcessNames.contains("qemu-system-aarch64-headless") && item.runningProcessNames.contains("emulator"))
        try box.file(".android/avd/Pixel.avd/snapshots/default_boot/ram.bin")
        try box.file(".android/avd/Tablet.avd/snapshots/snap_1/ram.bin")
        let data = try ["userdata-qemu.img", "sdcard.img", "config.ini", "hardware-qemu.ini"]
            .map { try box.file(".android/avd/Pixel.avd/\($0)") } + [try box.file(".android/avd/Pixel.ini")]
        let listed = await Scanner.scan(item, policy: box.policy).entries.map(\.url.path)
        #expect(Set(listed.map { URL(fileURLWithPath: $0).lastPathComponent }) == ["default_boot", "snap_1"])
        #expect(!listed.contains { path in data.contains { $0.path == path } })
    }

    /// Firebase CLI: only its debug logs in ~/.cache/firebase go (ticked); the emulators are their own unticked row.
    /// The login token, the other downloaded tools and a project's own firebase-debug.log are never listed;
    /// a log a process still has open (a running `firebase mcp`) is kept at scan and clean.
    @Test func firebaseOnlyDebugLogsAndEmulators() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let items = CleanerGroup.developer.items
        let logs = try #require(items.first { $0.id == "firebase-logs" })
        let emulators = try #require(items.first { $0.id == "firebase-emulators" })
        #expect(logs.paths == ["~/.cache/firebase"] && logs.included == ["firebase-debug.log", "firebase-debug.*.log"])
        #expect(logs.selectedByDefault && logs.mode == .delete && logs.skipsOpenFiles && logs.runningProcessNames.isEmpty)
        #expect(emulators.paths == ["~/.cache/firebase/emulators"] && !emulators.selectedByDefault)
        #expect(emulators.mode == .delete && emulators.skipsOpenFiles && emulators.runningProcessNames == ["firebase-emulators"])
        #expect(logs.shellFolders.isEmpty && logs.configFolders != nil)
        #expect(emulators.shellFolders == ["FIREBASE_EMULATORS_PATH": [""]] && emulators.configFolders == nil)
        for item in [logs, emulators] { #expect(item.command == nil && item.probe == nil) }

        let held = try box.file(".cache/firebase/firebase-debug.log")
        let rotated = try box.file(".cache/firebase/firebase-debug.1.log")
        let jar = try box.file(".cache/firebase/emulators/cloud-firestore-emulator-v1.19.8.jar")
        let ui = try box.file(".cache/firebase/emulators/ui-v1.14.0/index.html")
        let kept = try [".config/configstore/firebase-tools.json", ".cache/firebase/crashlytics/buildtools/b.jar",
                        ".cache/firebase/universal-maker/universal-maker", ".cache/firebase/extensions/a/1.0.0/extension.yaml",
                        ".cache/firebase/other.log", "Developer/app/firebase-debug.log", "Developer/app/firebase.json"]
            .map { try box.file($0) }
        let handle = try FileHandle(forWritingTo: held)
        defer { try? handle.close() }
        let own: @Sendable (String) -> Set<String> = { RunningProcesses.openPaths(under: $0, only: [getpid()]) }

        let logScan = await Scanner.scan(logs, policy: box.policy, openPaths: own)
        #expect(logScan.entries.map(\.url.lastPathComponent) == ["firebase-debug.1.log"])
        let emulatorScan = await Scanner.scan(emulators, policy: box.policy, openPaths: own)
        #expect(Set(emulatorScan.entries.map(\.url.lastPathComponent)) == ["cloud-firestore-emulator-v1.19.8.jar", "ui-v1.14.0"])
        // Opened between scan and clean: kept too.
        var forged = logScan
        forged.entries.append(ScanEntry(url: held, size: 1))
        #expect(await Cleaner.clean(logs, scan: forged, policy: box.policy, openPaths: own).skipped == 1)
        #expect(await Cleaner.clean(emulators, scan: emulatorScan, policy: box.policy, openPaths: own).skipped == 0)
        let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
        #expect(exists(held) && !exists(rotated) && !exists(jar) && !exists(ui.deletingLastPathComponent()))
        #expect(kept.allSatisfy(exists))
        try handle.close()
        #expect(await Scanner.scan(logs, policy: box.policy, openPaths: own).entries.map(\.url.lastPathComponent) == ["firebase-debug.log"])
    }

    /// FIREBASE_EMULATORS_PATH / FIREBASE_DEBUG_PATH from the shell profile add their folder, only inside home,
    /// never through a symlink, only the CLI's own names; a debug path naming another file adds nothing.
    @Test func firebaseFoldersFromShellProfile() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let items = CleanerGroup.developer.items
        let logs = try #require(items.first { $0.id == "firebase-logs" })
        let emulators = try #require(items.first { $0.id == "firebase-emulators" })
        #expect(ShellEnvironment.variables.isSuperset(of: ["FIREBASE_EMULATORS_PATH", "FIREBASE_DEBUG_PATH"]))
        let profile = box.home.appending(path: ".zshrc")
        func set(_ text: String) throws { try text.write(to: profile, atomically: true, encoding: .utf8) }
        func names(_ item: CleanerItem) async -> Set<String> {
            Set(await Scanner.scan(item, policy: box.policy, openPaths: { _ in [] }).entries.map(\.url.lastPathComponent))
        }
        try box.file(".cache/firebase/emulators/cloud-firestore-emulator-v1.22.0.jar")
        try box.file(".local/firebase-emulators/firebase-database-emulator-v4.11.2.jar")
        try box.file(".local/firebase-emulators/ui-v1.15.0/server/server.mjs")
        try box.file(".local/firebase-emulators/notes.txt")
        try box.file("logs/firebase-debug.log")
        try box.file("logs/firebase-debug.2.log")
        try box.file("logs/app.log")

        try set("export FIREBASE_EMULATORS_PATH=~/.local/firebase-emulators\nexport FIREBASE_DEBUG_PATH=$HOME/logs\n")
        #expect(await names(emulators) == ["cloud-firestore-emulator-v1.22.0.jar", "firebase-database-emulator-v4.11.2.jar", "ui-v1.15.0"])
        #expect(await names(logs) == ["firebase-debug.log", "firebase-debug.2.log"])
        let lock = RunningProcesses.shellInstallPaths(policy: box.policy)
        #expect(lock.map(\.name) == ["firebase-emulators"])
        let java: [UInt8] = withUnsafeBytes(of: Int32(3)) { Array($0) }
            + ["/usr/bin/java", "java", "-jar", lock.first.map { $0.path + "x.jar" } ?? ""].flatMap { Array($0.utf8) + [0] }
        #expect(RunningProcesses.argumentNames(java, extra: lock).contains("firebase-emulators"))

        // A log file: its folder, still only the log names; another file name: nothing.
        try set("export FIREBASE_DEBUG_PATH=~/logs/firebase-debug.log\n")
        #expect(await names(logs) == ["firebase-debug.log", "firebase-debug.2.log"])
        try set("export FIREBASE_DEBUG_PATH=~/logs/app.log\n")
        #expect(await names(logs).isEmpty)

        // Outside home or through a symlink: ignored.
        let outside = try box.file("../outside/firebase-database-emulator-v1.jar").deletingLastPathComponent().standardizedFileURL
        try FileManager.default.createSymbolicLink(at: box.home.appending(path: "linked"), withDestinationURL: box.home.appending(path: ".local/firebase-emulators"))
        for value in [outside.path, "~/linked"] {
            try set("export FIREBASE_EMULATORS_PATH=\(value)\nexport FIREBASE_DEBUG_PATH=\(value)\n")
            #expect(await names(emulators) == ["cloud-firestore-emulator-v1.22.0.jar"], "\(value)")
            #expect(await names(logs).isEmpty && RunningProcesses.shellInstallPaths(policy: box.policy).isEmpty, "\(value)")
        }
    }

    /// pnpm prune may remove far less than the store; bun and uv caches share APFS clones with projects:
    /// never counted as sure bytes.
    @Test func upperBoundDeveloperItems() {
        let flagged = CleanerGroup.developer.items.filter(\.sizeIsUpperBound).map(\.id)
        #expect(flagged == ["pnpm-store", "bun-cache", "uv-cache"])
    }

    /// Removing a clone frees nothing while the original stays: "freed" is still the removed size (never the
    /// volume's noisy free-space change), flagged as an upper bound so the done screen says less may be freed.
    @Test func upperBoundItemReportsRemovedSizeAsUpTo() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let original = try box.file("project/lib.bin", bytes: 64_000_000)
        let cache = box.home.appending(path: "Library/Caches/tool/lib.bin")
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #require(clonefile(original.path, cache.path, 0) == 0)
        let item = CleanerItem(id: "c", title: "c", paths: ["~/Library/Caches/tool"], sizeIsUpperBound: true)

        let scan = await Scanner.scan(item, policy: box.policy)
        #expect(scan.size >= 64_000_000) // allocated size counts the shared blocks
        let report = await Cleaner.clean(item, scan: scan, policy: box.policy)
        #expect(!FileManager.default.fileExists(atPath: cache.path))
        #expect(report.freed == scan.size && report.upTo == scan.size)

        let plain = CleanerItem(id: "p", title: "p", paths: ["~/project"])
        let plainScan = await Scanner.scan(plain, policy: box.policy)
        var total = await Cleaner.clean(plain, scan: plainScan, policy: box.policy)
        #expect(total.freed == plainScan.size && total.upTo == 0)
        total += report
        #expect(total.freed == scan.size + plainScan.size && total.upTo == scan.size)
    }

    @Test func simctlDevices() {
        let json = """
        {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-17-0":[
          {"udid":"OLD-1","isAvailable":false,"name":"iPhone 15"}],
         "com.apple.CoreSimulator.SimRuntime.iOS-27-0":[
          {"udid":"NEW-1","isAvailable":true,"name":"iPhone 18"}]}}
        """
        #expect(DeveloperTools.simulatorIDs(in: json, available: false) == ["OLD-1"])
        #expect(DeveloperTools.simulatorIDs(in: json, available: true) == ["NEW-1"])
        #expect(DeveloperTools.simulatorIDs(in: "xcrun: error", available: true) == nil)
    }

    @Test func dockerSocketCheck() throws {
        #expect(!DeveloperTools.canConnect(toSocket: "/nonexistent/docker.sock"))
        let path = NSTemporaryDirectory() + "cm-\(UUID().uuidString.prefix(8)).sock"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd); unlink(path) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8CString).map { UInt8(bitPattern: $0) }) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(bound == 0 && listen(fd, 8) == 0)
        #expect(DeveloperTools.canConnect(toSocket: path))
        // Docker commands target the first listening local socket; none listening → not run.
        #expect(DeveloperTools.localDockerHostArguments(sockets: ["/nonexistent/docker.sock", path])
                == ["--host", "unix://" + path])
        #expect(DeveloperTools.localDockerHostArguments(sockets: ["/nonexistent/docker.sock"]) == nil)
        // The current context's local socket goes first; a remote context is skipped.
        let dir = NSTemporaryDirectory() + "cm-docker-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        func use(_ name: String, host: String) throws {
            let hash = SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
            let meta = dir + "/contexts/meta/\(hash)"
            try FileManager.default.createDirectory(atPath: meta, withIntermediateDirectories: true)
            try #"{"currentContext":"\#(name)"}"#.write(toFile: dir + "/config.json", atomically: true, encoding: .utf8)
            try #"{"Name":"\#(name)","Endpoints":{"docker":{"Host":"\#(host)"}}}"#
                .write(toFile: meta + "/meta.json", atomically: true, encoding: .utf8)
        }
        #expect(DeveloperTools.currentContextSockets(dockerDir: dir) == ["/var/run/docker.sock"])
        try use("orbstack", host: "unix://" + path)
        let context = DeveloperTools.currentContextSockets(dockerDir: dir)
        #expect(context == [path])
        #expect(DeveloperTools.localDockerHostArguments(sockets: context + ["/nonexistent/docker.sock"])
                == ["--host", "unix://" + path])
        try use("remote", host: "ssh://me@server")
        #expect(DeveloperTools.currentContextSockets(dockerDir: dir).isEmpty)
        try use("tcp", host: "tcp://10.0.0.1:2376")
        #expect(DeveloperTools.currentContextSockets(dockerDir: dir).isEmpty)
        try #"{"currentContext":"missing"}"#.write(toFile: dir + "/config.json", atomically: true, encoding: .utf8)
        #expect(DeveloperTools.currentContextSockets(dockerDir: dir).isEmpty)
    }

    @Test func dockerCommandsAlwaysTargetLocalSocket() async throws {
        let items = CleanerGroup.smartScan(ages: .default).flatMap(\.items).filter { $0.id.hasPrefix("docker-") }
        try #require(items.count == 5)
        let expected = DeveloperTools.localDockerHostArguments()
        for item in items {
            #expect(item.command?.leadingArguments() == expected)
            #expect(item.probe?.command.leadingArguments() == expected)
        }
        // No local socket → the command is refused before the tool is even started.
        #expect(await ShellCommand(executable: "/bin/echo", arguments: ["x"], leadingArguments: { nil }).output() == nil)
        #expect(await ShellCommand(executable: "/bin/echo", arguments: ["x"], leadingArguments: { ["a"] }).output() == "a x\n")
    }
}

struct CatalogTests {
    private var items: [CleanerItem] { CleanerGroup.smartScan(ages: .default).flatMap(\.items) }

    @Test func developerCachesAreNotCountedTwice() throws {
        let userCaches = try #require(items.first { $0.id == "user-caches" })
        for name in ["org.swift.swiftpm", "CocoaPods", "Homebrew", "ms-playwright", "go-build", "pip", "Yarn", "composer",
                     "Google/Chrome", "BraveSoftware/Brave-Browser", "Firefox", "com.apple.Safari", "claude-cli-nodejs", "com.microsoft.VSCode", "Zed"] {
            #expect(userCaches.excluded.contains(name), "\(name)")
        }
        #expect(!userCaches.excluded.contains("Google")) // the rest of Google/ is still listed
        for name in ["Google/Chrome Beta", "Microsoft Edge Canary", "BraveSoftware/Brave-Browser-Nightly"] {
            #expect(userCaches.excluded.contains(name), "\(name)")
        }
    }

    @Test func browserChannelsHaveTheirOwnBundleAndFolders() throws {
        let channels = [
            ("chrome-beta", "com.google.Chrome.beta", "Google/Chrome Beta"),
            ("chrome-dev", "com.google.Chrome.dev", "Google/Chrome Dev"),
            ("chrome-canary", "com.google.Chrome.canary", "Google/Chrome Canary"),
            ("edge-beta", "com.microsoft.edgemac.Beta", "Microsoft Edge Beta"),
            ("edge-dev", "com.microsoft.edgemac.Dev", "Microsoft Edge Dev"),
            ("edge-canary", "com.microsoft.edgemac.Canary", "Microsoft Edge Canary"),
            ("brave-beta", "com.brave.Browser.beta", "BraveSoftware/Brave-Browser-Beta"),
            ("brave-nightly", "com.brave.Browser.nightly", "BraveSoftware/Brave-Browser-Nightly"),
        ]
        for (id, bundle, folder) in channels {
            let item = try #require(items.first { $0.id == id }, "\(id)")
            #expect(item.runningAppBundleIDs == [bundle] && !item.showsWhenEmpty, "\(id)")
            #expect(item.paths.contains("~/Library/Caches/" + folder), "\(id)")
            #expect(item.paths.contains("~/Library/Application Support/\(folder)/*/Code Cache"), "\(id)")
        }
    }

    /// Only folders of an IDE version older than the newest of the same product, across Application Support,
    /// Caches and Logs; never the newest, unversioned folders, nor other Google folders. User caches leaves them all.
    @Test func oldIDEVersions() throws {
        let names = ["GoLand2025.3", "GoLand2026.2", "GoLand2026.1.4", "IntelliJIdea2025.3", "IntelliJServer", "Daemon",
                     "consentOptions", "AndroidStudio2026.1.1", "AndroidStudio2026.1.10", "AndroidStudio2026.2.1",
                     "AndroidStudio2026.2", "PyCharmCE2024.1", "PyCharm2025.1", "Rider2025.3-EAP"]
        #expect(DeveloperTools.staleIDEFolders(names) == ["GoLand2025.3", "GoLand2026.1.4", "AndroidStudio2026.1.1",
                                                           "AndroidStudio2026.1.10", "AndroidStudio2026.2"])
        #expect(DeveloperTools.staleIDEFolders(["GoLand2026.2", "IntelliJServer"]).isEmpty)

        let root = FileManager.default.temporaryDirectory.appending(path: "CleanMateIDE-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appending(path: "Library")
        for path in ["Application Support/JetBrains/GoLand2025.3", "Application Support/JetBrains/IntelliJServer",
                     "Caches/JetBrains/GoLand2025.3", "Logs/JetBrains/GoLand2026.2", // newest only in Logs
                     "Application Support/Google/AndroidStudio2026.1.1", "Application Support/Google/Chrome",
                     "Caches/Google/AndroidStudio2026.1.1", "Caches/Google/AndroidStudio2026.2.1"] {
            try FileManager.default.createDirectory(at: library.appending(path: path), withIntermediateDirectories: true)
        }
        let stale = { (path: String) in DeveloperTools.isStaleIDEFolder(library.appending(path: path)) }
        #expect(stale("Application Support/JetBrains/GoLand2025.3") && stale("Caches/JetBrains/GoLand2025.3"))
        #expect(stale("Application Support/Google/AndroidStudio2026.1.1") && stale("Caches/Google/AndroidStudio2026.1.1"))
        #expect(!stale("Logs/JetBrains/GoLand2026.2") && !stale("Caches/Google/AndroidStudio2026.2.1"))
        #expect(!stale("Application Support/JetBrains/IntelliJServer") && !stale("Application Support/Google/Chrome"))
        #expect(!stale("Caches/JetBrains/GoLand2024.1")) // not there

        let item = try #require(items.first { $0.id == "old-ide-versions" })
        #expect(!item.selectedByDefault && item.mode == .trash && item.selectableEntries && !item.showsWhenEmpty)
        #expect(item.runningAppBundleIDs == ["com.jetbrains.*", "com.google.android.studio*"])
        #expect(SmartScanModel.bundleID("com.jetbrains.goland", matches: "com.jetbrains.*"))
        #expect(SmartScanModel.bundleID("com.google.android.studio-EAP", matches: "com.google.android.studio*"))
        #expect(!SmartScanModel.bundleID("com.google.Chrome", matches: "com.google.android.studio*"))
        #expect(SmartScanModel.bundleID("com.apple.mail", matches: "com.apple.mail")
                && !SmartScanModel.bundleID("com.apple.mail2", matches: "com.apple.mail"))

        let userCaches = try #require(items.first { $0.id == "user-caches" })
        #expect(!userCaches.excluded.contains("Google"))
        let caches = URL(fileURLWithPath: "/Users/x/Library/Caches")
        for path in ["JetBrains", "Google/AndroidStudio2026.2.1"] {
            #expect(CleanerGroup.skipsUserCache(caches.appending(path: path), runningApps: []), "\(path)")
        }
        #expect(!CleanerGroup.skipsUserCache(caches.appending(path: "Google/GoogleUpdater"), runningApps: []))
        #expect(try #require(items.first { $0.id == "old-logs" }).excluded.contains("JetBrains"))
    }

    /// Chrome's on-device AI model per channel (unticked, deleted, skipped while that channel runs) and
    /// Google Updater's downloaded packages (ticked, skipped while GoogleUpdater runs); nothing else of the updater.
    @Test func chromeAIModelAndGoogleUpdaterCache() throws {
        for (id, bundle, folder) in [("chrome", "com.google.Chrome", "Google/Chrome"),
                                     ("chrome-beta", "com.google.Chrome.beta", "Google/Chrome Beta"),
                                     ("chrome-dev", "com.google.Chrome.dev", "Google/Chrome Dev"),
                                     ("chrome-canary", "com.google.Chrome.canary", "Google/Chrome Canary")] {
            let item = try #require(items.first { $0.id == id + "-ai-model" }, "\(id)")
            #expect(item.paths == ["~/Library/Application Support/\(folder)/OptGuideOnDeviceModel"], "\(id)")
            #expect(!item.selectedByDefault && item.mode == .delete && item.note != nil && !item.showsWhenEmpty, "\(id)")
            #expect(item.runningAppBundleIDs == [bundle], "\(id)")
        }
        for (id, bundle, folder) in [("edge", "com.microsoft.edgemac", "Microsoft Edge"),
                                     ("edge-beta", "com.microsoft.edgemac.Beta", "Microsoft Edge Beta"),
                                     ("edge-dev", "com.microsoft.edgemac.Dev", "Microsoft Edge Dev"),
                                     ("edge-canary", "com.microsoft.edgemac.Canary", "Microsoft Edge Canary")] {
            let item = try #require(items.first { $0.id == id + "-ai-model" }, "\(id)")
            #expect(item.paths == ["~/Library/Application Support/\(folder)/EdgeLLMOnDeviceModel"], "\(id)")
            #expect(!item.selectedByDefault && item.mode == .delete && item.note != nil && !item.showsWhenEmpty, "\(id)")
            #expect(item.runningAppBundleIDs == [bundle], "\(id)")
        }
        let updater = try #require(items.first { $0.id == "google-updater-cache" })
        #expect(updater.paths == ["~/Library/Application Support/Google/GoogleUpdater/crx_cache"])
        #expect(updater.selectedByDefault && updater.mode == .delete && !updater.showsWhenEmpty)
        #expect(updater.runningProcessNames == ["GoogleUpdater"])
        #expect(!items.flatMap(\.paths).contains { $0.hasPrefix("~/Library/Application Support/Google/GoogleUpdater")
            && $0 != updater.paths[0] })
    }

    @Test func dataLossItemsAreUntickedAndDescribed() {
        for id in ["claude-code-sessions", "codex-sessions", "claude-desktop-sessions"] {
            let item = items.first { $0.id == id }
            #expect(item?.selectedByDefault == false && item?.mode == .trash && item?.minAge == TimeInterval(30 * 86_400), "\(id)")
        }
        for id in ["simulator-data", "docker-volumes", "docker-containers", "maven-repository", "xcode-archives",
                   "docker-images", "playwright-browsers", "puppeteer-browsers", "cypress-binary", "yarn-berry-cache"] {
            let item = items.first { $0.id == id }
            #expect(item?.selectedByDefault == false && item?.note != nil, "\(id)")
        }
        #expect(items.first { $0.id == "xcode-archives" }?.mode == .trash)
        // Regenerable Xcode/simulator data, skipped while the app using it runs.
        let previews = items.first { $0.id == "xcode-previews" }
        #expect(previews?.paths == ["~/Library/Developer/Xcode/UserData/Previews"] && previews?.selectedByDefault == true)
        #expect(previews?.runningAppBundleIDs == ["com.apple.dt.Xcode"])
        #expect(previews?.command?.arguments == ["simctl", "--set", "previews", "delete", "all"])
        let caches = items.first { $0.id == "simulator-caches" }
        #expect(caches?.paths == ["~/Library/Developer/CoreSimulator/Caches"] && caches?.selectedByDefault == true)
        #expect(caches?.runningAppBundleIDs == ["com.apple.dt.Xcode", "com.apple.iphonesimulator"] && caches?.command == nil)
        // Downloaded Gradle versions, unticked, skipped while a Gradle/Kotlin daemon runs.
        let wrapper = items.first { $0.id == "gradle-wrapper" }
        #expect(wrapper?.paths == ["~/.gradle/wrapper/dists"] && wrapper?.selectedByDefault == false && wrapper?.note != nil)
        #expect(wrapper?.runningProcessNames == ["GradleDaemon", "KotlinCompileDaemon"] && wrapper?.showsWhenEmpty == false)
    }

    @Test func developerItemsAreUniqueHiddenWhenEmptyAndCleanable() {
        #expect(Set(items.map(\.id)).count == items.count)
        let policy = SafetyPolicy(home: URL(fileURLWithPath: "/Users/test"), temp: URL(fileURLWithPath: "/var/folders/xx/T"))
        for item in [CleanerGroup.developer, .aiTools(), .applications(hasFullDiskAccess: true)].flatMap(\.items) {
            #expect(!item.showsWhenEmpty, "\(item.id)")
            #expect(!item.paths.isEmpty || item.probe != nil, "\(item.id)")
            // An item finding its entries itself has its own rule (`allowsEntry`), tested with the item.
            for path in item.paths where item.allowsEntry == nil {
                // Contents must pass the safety policy, otherwise the item could never clean anything.
                let path = path.replacingOccurrences(of: "*", with: "x")
                #expect(policy.allows(policy.expand(path).appending(path: "entry")), "\(path)")
            }
        }
    }
}

struct AppCatalogTests {
    @Test func globMatchesNonHiddenFolders() throws {
        let box = try Sandbox()
        defer { box.remove() }
        for path in ["a/Default/GPUCache/x", "a/Profile 1/GPUCache/x", "a/.hidden/GPUCache/x", "a/Other/y"] { try box.file(path) }
        let roots = box.policy.roots("~/a/*/GPUCache").filter { FileManager.default.fileExists(atPath: $0.path) }
        #expect(roots.map { $0.deletingLastPathComponent().lastPathComponent } == ["Default", "Profile 1"])
        #expect(box.policy.roots("~/missing/*/x").isEmpty)
        #expect(box.policy.roots("~/plain") == [box.home.appending(path: "plain")])
    }

    /// Logins, settings, memory, models and profiles of AI tools and apps, even very old, are never listed.
    /// ZCode: ticked caches and logs, skipped while the app or one of its `zcode-cli` agents runs (today's log is
    /// still being written then); no session history (`cli/rollout`) in this item.
    @Test func zcodeCachesAndLogsSkippedWhileRunning() throws {
        let item = try #require(CleanerGroup.aiTools().items.first { $0.id == "zcode-cache" })
        #expect(item.selectedByDefault && item.mode == .delete && item.minAge == nil && item.command == nil)
        #expect(item.runningAppBundleIDs == ["dev.zcode.app"] && item.runningProcessNames == ["zcode-cli"])
        #expect(item.paths.contains("~/.zcode/v2/logs") && item.paths.contains("~/.zcode/cli/log"))
        #expect(item.paths.contains("~/Library/Application Support/ZCode/session/Partitions/*/Cache"))
        #expect(!item.paths.contains { $0.contains("rollout") || $0.hasSuffix("/ZCode") || $0.contains("remote-assets") })
    }

    /// ZCode's remote server files: unticked, skipped while ZCode runs, and listed as one entry (the cache folder)
    /// so the files `releases` hard-links from `components` count once; nothing else of ZCode is listed.
    @Test func zcodeRemoteServerFilesAreOneUntickedEntry() async throws {
        let item = try #require(CleanerGroup.aiTools().items.first { $0.id == "zcode-remote-assets" })
        #expect(!item.selectedByDefault && item.mode == .delete && !item.showsWhenEmpty && item.note != nil)
        #expect(item.runningAppBundleIDs == ["dev.zcode.app"] && item.runningProcessNames == ["zcode-cli"])
        #expect(item.included == ["remote-assets-cache"] && item.command == nil && item.probe == nil)
        let box = try Sandbox()
        defer { box.remove() }
        let cache = "Library/Application Support/ZCode/remote-assets-cache"
        let node = try box.file(cache + "/components/node-runtime/linux-x64/v22.0.0/bin/node", bytes: 200_000)
        let linked = box.home.appending(path: cache + "/releases/3.15.3/linux-x64/node/linux-x64/bin/node")
        try FileManager.default.createDirectory(at: linked.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: node, to: linked)
        try box.file(cache + "/staging/remote-component-glm-1/component.tar.gz")
        try box.file("Library/Application Support/ZCode/session/Cookies")
        try box.file("Library/Application Support/ZCode/Preferences")
        let entries = await Scanner.scan(item, policy: box.policy).entries
        #expect(entries.map { $0.url.resolvingSymlinksInPath().lastPathComponent } == ["remote-assets-cache"])
        #expect((entries.first?.size ?? 0) >= 200_000 && (entries.first?.size ?? 0) < 400_000)
    }

    /// Adobe media cache: only Media Cache Files, Media Cache and Peak Files are counted and deleted; the rest of
    /// Adobe/Common, Adobe preferences, profiles and projects stay, and so does Adobe/Common itself.
    @Test func adobeMediaCacheCleansOnlyTheCacheFolders() async throws {
        let item = try #require(CleanerGroup.applications().items.first { $0.id == "adobe-media-cache" })
        #expect(!item.selectedByDefault && item.mode == .delete && !item.showsWhenEmpty && item.note != nil)
        #expect(item.skipsOpenFiles && item.command == nil && item.probe == nil)
        let box = try Sandbox()
        defer { box.remove() }
        let common = "Library/Application Support/Adobe/Common"
        try box.file(common + "/Media Cache Files/clip 48000.cfa", bytes: 300_000)
        try box.file(common + "/Media Cache Files/clip.pek", bytes: 20_000)
        try box.file(common + "/Media Cache/media_cache_db.mcdb", bytes: 50_000)
        try box.file(common + "/Peak Files/voice.pkf", bytes: 30_000)
        let kept = [
            common + "/Team Projects Cache/t.dat", common + "/Plug-ins/7.0/MediaCore/p.bundle",
            "Library/Application Support/Adobe/Adobe Premiere Pro/25.0/Profile-me/Adobe Premiere Pro Prefs",
            "Library/Preferences/Adobe/After Effects/25.0/prefs.txt", "Movies/Film/Film.prproj",
        ]
        for path in kept { try box.file(path) }
        let scan = await Scanner.scan(item, policy: box.policy, openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(Set(scan.entries.map { $0.url.lastPathComponent }) == ["Media Cache Files", "Media Cache", "Peak Files"])
        #expect(scan.size >= 400_000 && scan.size < 600_000)
        let report = await Cleaner.clean(item, scan: scan, policy: box.policy, openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(report.freed >= 400_000)
        let fm = FileManager.default
        for name in ["Media Cache Files", "Media Cache", "Peak Files"] {
            #expect(!fm.fileExists(atPath: box.home.appending(path: common + "/" + name).path), "\(name)")
        }
        #expect(fm.fileExists(atPath: box.home.appending(path: common).path))
        for path in kept { #expect(fm.fileExists(atPath: box.home.appending(path: path).path), "\(path)") }
    }

    /// Without Adobe there is nothing to list, and the hidden item shows no row.
    @Test func adobeMediaCacheHiddenWithoutAdobe() async throws {
        let item = try #require(CleanerGroup.applications().items.first { $0.id == "adobe-media-cache" })
        let box = try Sandbox()
        defer { box.remove() }
        try box.file("Library/Application Support/Adobe/Common/Team Projects Cache/t.dat")
        #expect(await Scanner.scan(item, policy: box.policy, openPaths: EndToEndCleanTests.ownOpenPaths).entries.isEmpty)
        #expect(!item.showsWhenEmpty)
    }

    /// Locked while Premiere, After Effects or Media Encoder (any version) runs; Creative Cloud and its helpers,
    /// always running, do not lock it.
    @MainActor @Test func adobeMediaCacheLockedWhileAnAdobeMediaAppRuns() throws {
        let item = try #require(CleanerGroup.applications().items.first { $0.id == "adobe-media-cache" })
        let model = SmartScanModel(module: .smartScan) { [] }
        model.runningApps = ["com.adobe.acc.AdobeCreativeCloud", "com.adobe.CCXProcess"]
        model.runningProcesses = ["Creative Cloud", "AdobeIPCBroker", "CCXProcess", "Core Sync", "Adobe Desktop Service"]
        #expect(!model.isLocked(item))
        for name in ["Adobe Premiere Pro 2025", "Adobe Premiere Pro (Beta)", "After Effects", "Adobe Media Encoder 2025",
                     "Adobe Audition 2025", "aerender"] {
            model.runningProcesses = ["AdobeIPCBroker", name]
            #expect(model.isLocked(item), "\(name)")
        }
        model.runningProcesses = []
        model.runningApps = ["com.adobe.PremierePro.25"]
        #expect(model.isLocked(item))
    }

    @Test func credentialsSettingsAndMemoryAreNeverListed() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let old: TimeInterval = 400 * 86_400
        let protected = [
            ".claude/.credentials.json", ".claude/settings.json", ".claude/settings.local.json", ".claude/CLAUDE.md",
            ".claude/history.jsonl", ".claude/plugins/p/plugin.json", ".claude/skills/s/SKILL.md", ".claude/agents/a.md",
            ".claude/projects/-Users-me-app/memory/MEMORY.md", ".claude/projects/-Users-me-app/memory/note.md",
            ".claude.json", ".codex/auth.json", ".codex/config.toml", ".codex/AGENTS.md", ".codex/memories/m.md",
            ".codex/memories_1.sqlite", ".gemini/settings.json", ".gemini/oauth_creds.json",
            ".gemini/jetski-standalone-oauth-token", ".gemini/antigravity/settings.json",
            ".config/github-copilot/apps.json", ".copilot/config.json", ".continue/config.yaml",
            ".ollama/models/blobs/sha256-1", ".ollama/id_ed25519", ".lmstudio/models/m.gguf", ".cache/lm-studio/models/m.gguf",
            ".cursor/mcp.json", ".codeium/windsurf/memories/m.pb",
            ".cursor/extensions/ext/package.json", ".cursor/ai-tracking/ai-code-tracking.db", ".cursor/hooks.json",
            ".cursor/projects/Users-me-app/terminals/1.txt", ".cursor/skills-cursor/s/SKILL.md",
            ".codeium/windsurf/cascade/c.pb", ".codeium/windsurf/user_settings.pb", ".codeium/windsurf/skills/s/SKILL.md",
            ".codeium/windsurf/ws-browser-profile/Default/Cookies", ".codeium/windsurf/ws-browser-profile/Default/History",
            ".codeium/windsurf/ws-browser-profile/Default/Login Data", ".codeium/installation_id",
            ".local/share/opencode/auth.json", ".local/share/opencode/opencode.db", ".local/share/opencode/snapshot/a/HEAD",
            ".local/share/opencode/tool-output/t.txt", ".cline/data/secrets.json", ".cline/data/globalState.json",
            ".cline/data/cache/user_input_history.jsonl", ".cline/data/db/sessions.db",
            ".cline/data/sessions/session_1/s.messages.json", ".cline/data/settings/providers.json",
            ".cline/data/workspaces/1/state.json", ".factory/settings.json",
            ".local/share/kilo/kilo.db", ".local/share/kilo/kilo.db-wal", ".local/share/kilo/kilo.db-shm",
            ".local/share/kilo/repos/r/HEAD", ".local/share/kilo/auth.json", ".config/kilo/kilo.jsonc",
            ".local/state/kilo/locks/l", ".local/share/mimocode/mimocode.db", ".local/share/mimocode/auth.json",
            ".local/share/mimocode/snapshot/a/HEAD", ".local/share/mimocode/builtin_skills/b/skills/s/SKILL.md",
            ".local/share/mimocode/compose/0.1.14/c.js", ".local/share/mimocode/storage/session_diff/d.json",
            ".local/share/mimocode/tool-output/t.txt", ".local/share/mimocode/installation_id",
            ".config/mimocode/mimocode.jsonc", ".local/state/mimocode/model.json",
            "Library/Application Support/Claude/claude_desktop_config.json", "Library/Application Support/Claude/Cookies",
            "Library/Application Support/Claude/Local Storage/leveldb/1.ldb",
            "Library/Application Support/Code/User/settings.json", "Library/Application Support/Cursor/User/settings.json",
            "Library/Application Support/Code/User/globalStorage/state.vscdb",
            "Library/Application Support/Code/User/History/1a/entries.json",
            "Library/Application Support/Google/Chrome/Default/Cookies", "Library/Application Support/Google/Chrome/Default/History",
            "Library/Application Support/Google/Chrome/Default/Login Data",
            "Library/Application Support/Google/Chrome/Default/Local Storage/leveldb/1.ldb",
            "Library/Application Support/Google/Chrome Beta/Default/Cookies",
            "Library/Application Support/Google/Chrome Beta/Profile 1/History",
            "Library/Application Support/Google/Chrome Beta/Default/IndexedDB/x/1.ldb",
            "Library/Application Support/Google/Chrome Beta/Local State",
            "Library/Application Support/Microsoft Edge Dev/Default/Login Data",
            "Library/Application Support/BraveSoftware/Brave-Browser-Nightly/Default/Preferences",
            "Library/Application Support/Firefox/Profiles/x.default/cookies.sqlite",
            "Library/Application Support/Telegram Desktop/tdata/key_datas",
            ".zcode/v2/credentials.json", ".zcode/v2/provider_config.json", ".zcode/v2/setting.json",
            ".zcode/v2/certs/ca.pem", ".zcode/v2/runtime/r/bin", ".zcode/v2/tasks-index.sqlite",
            ".zcode/v2/tasks-index.sqlite-wal", ".zcode/v2/visualizations/v.html", ".zcode/cli/config.json",
            ".zcode/cli/db/state.db", ".zcode/cli/memories/m.md", ".zcode/cli/agents/a/agent.json",
            ".zcode/cli/plugins/p/plugin.json", ".zcode/cli/rollout/model-io-session_1.jsonl",
            ".zcode/cli/artifacts/a.txt", ".zcode/cli/exec/e.log", ".zcode/skills/s/SKILL.md",
            ".zcode/workspace/w/file.txt", ".zcode/plugin-workspace/p.txt", ".zcode/backup/b.json",
            ".zcode/computer-use/c.json", "Library/Application Support/ZCode/session/Cookies",
            "Library/Application Support/ZCode/session/Local Storage/leveldb/1.ldb",
            "Library/Application Support/ZCode/session/IndexedDB/x/1.ldb",
            "Library/Application Support/ZCode/session/Partitions/p/Cookies",
            "Library/Application Support/ZCode/Preferences", "Library/Application Support/ZCode/Local Storage/leveldb/1.ldb",
        ]
        let junk = [
            ".claude/debug/log.txt", ".claude/projects/-Users-me-app/old.jsonl", ".codex/log/codex.log",
            ".codex/sessions/2025/01/01/rollout.jsonl", ".ollama/logs/server.log",
            "Library/Application Support/Claude/Cache/Cache_Data/f", "Library/Application Support/Google/Chrome/Default/GPUCache/f",
            "Library/Application Support/Google/Chrome/Profile 2/Service Worker/CacheStorage/f",
            "Library/Application Support/Google/Chrome Beta/Profile 1/Code Cache/js/f",
            "Library/Application Support/Microsoft Edge Canary/Default/Cache/Cache_Data/f",
            "Library/Caches/BraveSoftware/Brave-Browser-Beta/Default/Cache/f",
            "Library/Caches/Google/Chrome/Default/Cache/f", "Library/Application Support/Telegram Desktop/tdata/user_data/cache/f",
            ".cursor/projects/Users-me-app/agent-transcripts/1/t.jsonl", ".cursor/projects/Users-me-app/agent-tools/1.txt",
            ".codeium/windsurf/database/abc/3/MODEL_EMBED_1/x", ".codeium/database/abc/3/x",
            ".codeium/windsurf/ws-browser/chromium-1169/c", ".codeium/windsurf/ws-browser-profile/Default/Cache/f",
            ".codeium/windsurf/ws-browser-profile/GrShaderCache/f", ".cache/opencode/models.json",
            ".cache/opencode/bin/rg", ".local/share/opencode/log/opencode.log", ".cline/data/logs/cline.log",
            ".cache/kilo/models.json", ".local/share/kilo/log/2026-09-09T031513.log", ".cache/mimocode/models.json",
            ".cache/mimocode/version", ".local/share/mimocode/log/2026-10-08T141239618Z-main-1-a.log",
            ".zcode/v2/logs/2026-10-20.log", ".zcode/cli/log/zcode-2026-10-20.jsonl",
            "Library/Application Support/ZCode/session/Cache/Cache_Data/f",
            "Library/Application Support/ZCode/session/Partitions/p/Code Cache/js/f",
            "Library/Application Support/ZCode/remote-assets-cache/components/ripgrep/linux-x64/v14.1.1-1/rg",
            "Library/Application Support/ZCode/remote-assets-cache/releases/3.15.3/linux-x64/manifest-linux-x64.json",
        ]
        for path in protected + junk { try box.file(path, age: old) }
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-old)],
                                              ofItemAtPath: box.home.appending(path: ".codex/sessions/2025/01/01").path)
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-old)],
                                              ofItemAtPath: box.home.appending(path: ".cursor/projects/Users-me-app/agent-transcripts/1").path)
        var listed: [URL] = []
        for item in [CleanerGroup.aiTools(), .applications(hasFullDiskAccess: true)].flatMap(\.items) {
            listed += await Scanner.scan(item, policy: box.policy).entries.map { $0.url.resolvingSymlinksInPath() }
        }
        for path in protected {
            let file = box.home.appending(path: path).resolvingSymlinksInPath().path
            #expect(!listed.contains { file == $0.path || file.hasPrefix($0.path + "/") }, "\(path)")
        }
        for path in junk {
            let file = box.home.appending(path: path).resolvingSymlinksInPath().path
            #expect(listed.contains { file == $0.path || file.hasPrefix($0.path + "/") }, "\(path)")
        }
    }

    /// A command item whose tool folder overlaps an exclusion is skipped by `Cleaner`; the scan shows it at once:
    /// not ticked, locked, left out of the totals, through the same check.
    @MainActor @Test func modelLocksItemsBlockedByAnExclusion() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        _ = try box.file(".cache/uv/a.bin")
        _ = try box.file(".cache/plain/b.bin")
        let policy = SafetyPolicy(home: box.home, temp: box.temp, excluded: [box.home.appending(path: ".cache/uv/keep").path])
        let tool = CleanerItem(id: "blocked-381", title: "uv", paths: ["~/.cache/uv"], command: ShellCommand(executable: "/bin/echo"))
        let plain = CleanerItem(id: "plain-381", title: "plain", paths: ["~/.cache/plain"])
        let group = CleanerGroup(id: "g", title: "G", systemImage: "x", items: [tool, plain])
        let model = SmartScanModel(module: .smartScan) { [group] }
        model.processNames = { [] }
        model.appBundleIDs = { [] }
        model.scanItem = { await Scanner.scan($0, policy: policy, openPaths: $1) }
        model.blockedByExclusion = { await Cleaner.blockedByExclusion($0, policy: policy) }
        await model.scan()
        #expect(model.scans[tool.id]?.hasData == true)
        #expect(model.blocked == [tool.id] && model.isLocked(tool))
        #expect(model.selected == [plain.id])
        #expect(model.selectableItems(in: group).map(\.id) == [plain.id])
        model.selected.insert(tool.id) // even ticked (e.g. remembered), it is never counted
        #expect(model.selectedSize == model.scans[plain.id]?.size)
        model.selected = [tool.id]
        #expect(!model.hasSelection)
        #expect(await Cleaner.clean(tool, scan: model.scans[tool.id]!, policy: policy).skipped == 1)
    }

    @MainActor @Test func cancelledModelScanKeepsThePreviousState() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try FileManager.default.createDirectory(at: box.temp.appending(path: "c"), withIntermediateDirectories: true)
        try Data(count: 5000).write(to: box.temp.appending(path: "c/f"))
        let item = CleanerItem(id: "x", title: "X", paths: [box.temp.appending(path: "c").path])
        let model = SmartScanModel(module: .smartScan) { [CleanerGroup(id: "g", title: "G", systemImage: "x", items: [item])] }
        let policy = box.policy // not this Mac's Settings › Exclusions
        model.scanItem = { await Scanner.scan($0, policy: policy, openPaths: $1) }
        await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await model.scan()
        }.value
        guard case .idle = model.phase else { Issue.record("phase \(model.phase)"); return }
        #expect(model.scans.isEmpty && model.selected.isEmpty)
        await model.scan()
        #expect((model.scans["x"]?.size ?? 0) > 0)
    }

    @MainActor @Test func modelSortsItemsBySizeOnlyAfterTheScan() async throws {
        let ids = ["small", "records", "big", "upTo", "few", "tie"]
        let items = ids.map { CleanerItem(id: $0, title: "\($0)", paths: ["/nonexistent"], sizeIsUpperBound: $0 == "upTo") }
        let results: [String: ItemScan] = [
            "small": ItemScan(measuredSize: 10), "tie": ItemScan(measuredSize: 10), "big": ItemScan(measuredSize: 900),
            "upTo": ItemScan(measuredSize: 500),
            "records": ItemScan(entries: [ScanEntry(url: URL(filePath: "/r"), size: 0, isDatabase: true, records: 40)]),
            "few": ItemScan(entries: [ScanEntry(url: URL(filePath: "/f"), size: 0, isDatabase: true, records: 3)]),
        ]
        let model = SmartScanModel(module: .smartScan) { [CleanerGroup(id: "g", title: "G", systemImage: "x", items: items)] }
        model.processNames = { [] }
        let (gate, open) = AsyncStream<Void>.makeStream()
        model.scanItem = { item, _ in
            if item.id == "tie" { for await _ in gate { break } }
            return results[item.id]!
        }
        let scan = Task { await model.scan() }
        for _ in 0..<3000 where model.scannedItems < 5 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.visibleGroups.first?.items.map(\.id) == ids) // catalog order while scanning
        open.yield()
        await scan.value
        // biggest first, the "up to" item at its maximum, records-only after, ties in catalog order
        #expect(model.visibleGroups.first?.items.map(\.id) == ["big", "upTo", "small", "tie", "records", "few"])
    }

    @MainActor @Test func modelShowsEachItemAsSoonAsItIsScanned() async throws {
        let fast = CleanerItem(id: "fast", title: "Fast", paths: ["/nonexistent"])
        let slow = CleanerItem(id: "slow", title: "Slow", paths: ["/nonexistent"])
        let (gate, open) = AsyncStream<Void>.makeStream()
        let model = SmartScanModel(module: .smartScan) {
            [CleanerGroup(id: "g", title: "G", systemImage: "x", items: [fast, slow])]
        }
        model.processNames = { [] }
        model.scanItem = { item, _ in
            if item.id == "slow" { for await _ in gate { break } }
            return ItemScan(measuredSize: 1000)
        }
        let scan = Task { await model.scan() }
        for _ in 0..<3000 where model.scans["fast"] == nil { try await Task.sleep(for: .milliseconds(10)) }
        guard case .scanning = model.phase else { Issue.record("phase \(model.phase)"); return }
        #expect(model.scans["fast"]?.size == 1000 && model.scans["slow"] == nil)
        #expect(model.selected == ["fast"] && model.scannedItems == 1 && model.totalItems == 2)
        #expect(model.visibleGroups.first?.items.count == 2) // the unscanned item stays listed
        open.yield()
        await scan.value
        guard case .results = model.phase else { Issue.record("phase \(model.phase)"); return }
        #expect(model.selected == ["fast", "slow"])
    }

    @Test func scanProgressIsWeightedByLastScanTimes() {
        let all = ["a", "b", "c"]
        // First scan: no estimates → nil, the model falls back to items done / items.
        #expect(SmartScanModel.fraction(done: ["a"], all: all, estimates: [:]) == nil)
        #expect(SmartScanModel.fraction(done: ["a"], all: all, estimates: ["gone": 5]) == nil)
        // a took 8 s, b 1 s, c 1 s: finishing a is 80%.
        #expect(SmartScanModel.fraction(done: ["a"], all: all, estimates: ["a": 8, "b": 1, "c": 1]) == 0.8)
        // c is new: counts as the average (2 s) → a = 2 / 6.
        #expect(SmartScanModel.fraction(done: ["a"], all: all, estimates: ["a": 2, "b": 2]) == 2.0 / 6)
        // Capped at 99% until the scan finishes, even with every item done.
        #expect(SmartScanModel.fraction(done: Set(all), all: all, estimates: ["a": 1]) == 0.99)
        #expect(SmartScanModel.fraction(done: [], all: all, estimates: ["a": 0, "b": 0, "c": 0]) == nil)
    }

    @MainActor @Test func finishedScanStoresEachItemsTimeOnlyWithAKey() async {
        let item = CleanerItem(id: "timed", title: "Timed", paths: [])
        let model = SmartScanModel(module: .smartScan) { [CleanerGroup(id: "g", title: "G", systemImage: "x", items: [item])] }
        #expect(model.durationsKey == nil) // custom catalog: never touches the real key
        #expect(SmartScanModel(module: .privacy).durationsKey == Preferences.smartScanLastDurations)
        let key = "test.smartScanLastDurations.\(UUID())"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.set(["other": 3.0], forKey: key)
        model.durationsKey = key
        model.processNames = { [] }
        model.scanItem = { _, _ in try? await Task.sleep(for: .milliseconds(50)); return ItemScan(measuredSize: 1) }
        await model.scan()
        let saved = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        #expect(saved["other"] == 3 && (saved["timed"] ?? 0) >= 0.04)
        #expect(model.scanFraction == 1) // no estimate for "timed" yet: items done / items
        await model.scan()
        #expect(model.scanFraction == 0.99) // now weighted (capped); the bar is hidden once phase is .results
    }

    @MainActor @Test func upperBoundSizeIsKeptOutOfTheSelectedTotal() async {
        let sure = CleanerItem(id: "sure", title: "Sure", paths: [])
        let upTo = CleanerItem(id: "upto", title: "Up to", paths: [], sizeIsUpperBound: true)
        let model = SmartScanModel(module: .smartScan) {
            [CleanerGroup(id: "g", title: "G", systemImage: "x", items: [sure, upTo])]
        }
        model.processNames = { [] }
        model.scanItem = { item, _ in ItemScan(measuredSize: item.id == "sure" ? 1000 : 5000) }
        await model.scan()
        #expect(model.selected == ["sure", "upto"])
        #expect(model.selectedSize == 1000 && model.selectedUpToSize == 5000)
    }

    @MainActor @Test func groupSelectAllSkipsLockedItemsAndGroupTotalAddsUp() {
        let a = CleanerItem(id: "t161.a", title: "A", paths: [])
        let b = CleanerItem(id: "t161.b", title: "B", paths: [], sizeIsUpperBound: true)
        let empty = CleanerItem(id: "t161.empty", title: "Empty", paths: [])
        let locked = CleanerItem(id: "t161.locked", title: "Locked", paths: [], runningAppBundleIDs: ["test.161.app"])
        let db = CleanerItem(id: "t161.db", title: "DB", paths: [])
        let group = CleanerGroup(id: "g", title: "G", systemImage: "x", items: [a, b, empty, locked, db])
        let model = SmartScanModel(module: .smartScan) { [group] }
        model.runningApps = ["test.161.app"]
        model.scans = ["t161.a": ItemScan(measuredSize: 1000), "t161.b": ItemScan(measuredSize: 5000), "t161.empty": ItemScan(),
                       "t161.locked": ItemScan(measuredSize: 300),
                       "t161.db": ItemScan(entries: [ScanEntry(url: URL(fileURLWithPath: "/tmp/h.db"), size: 0, isDatabase: true, records: 7)])]
        #expect(model.total(of: group.items) == .init(size: 1300, upTo: 5000, records: 7))
        #expect(model.selectableItems(in: group).map(\.id) == ["t161.a", "t161.b", "t161.db"])
        #expect(!model.isAllSelected(group) && !model.isAnySelected(group)) // group checkbox off
        model.setSelected(a, true)
        #expect(model.isAnySelected(group) && !model.isAllSelected(group)) // mixed
        model.setSelected(group, true)
        #expect(model.selected == ["t161.a", "t161.b", "t161.db"] && model.isAllSelected(group))
        model.setSelected(group, false)
        #expect(model.selected.isEmpty && !model.isAllSelected(group) && !model.isAnySelected(group))
        #expect(Preferences.overrides["t161.a"] == false) // remembered like a tick by hand
        model.setSelected(group, true) // back to the default, so the override is forgotten
        #expect(Preferences.overrides["t161.a"] == nil)
    }

    @MainActor @Test func spaceTogglesHighlightedRowsLikeFinderAndSkipsLockedOnes() {
        let a = CleanerItem(id: "t177.a", title: "A", paths: [])
        let b = CleanerItem(id: "t177.b", title: "B", paths: [])
        let empty = CleanerItem(id: "t177.empty", title: "Empty", paths: [])
        let locked = CleanerItem(id: "t177.locked", title: "Locked", paths: [], runningAppBundleIDs: ["test.177.app"])
        let group = CleanerGroup(id: "g", title: "G", systemImage: "x", items: [a, b, empty, locked])
        let model = SmartScanModel(module: .smartScan) { [group] }
        model.runningApps = ["test.177.app"]
        model.scans = ["t177.a": ItemScan(measuredSize: 10), "t177.b": ItemScan(measuredSize: 20), "t177.empty": ItemScan(),
                       "t177.locked": ItemScan(measuredSize: 30)]
        model.selected = ["t177.a", "t177.locked"]
        let all: Set<String> = ["t177.a", "t177.b", "t177.empty", "t177.locked"]
        model.toggle(ids: all) // b is off → tick every selectable one; locked/empty untouched
        #expect(model.selected == ["t177.a", "t177.b", "t177.locked"])
        model.toggle(ids: all) // all selectable on → untick them
        #expect(model.selected == ["t177.locked"])
        model.toggle(ids: ["t177.empty"]) // only a locked row highlighted: nothing changes
        #expect(model.selected == ["t177.locked"])
        model.toggle(ids: ["t177.b"])
        #expect(model.selected == ["t177.locked", "t177.b"])
        model.toggle(ids: ["t177.a", "t177.b"]) // a off → both on, the default, so no override is left behind
        #expect(model.selected == ["t177.a", "t177.b", "t177.locked"] && Preferences.overrides["t177.a"] == nil)
    }

    /// Quit App never ticks a row that can't be ticked by hand, Deselect All also unticks a locked row still
    /// ticked, and a ticked item with nothing to clean never reaches the cleaner (a command item would run anyway).
    @MainActor @Test func lockedOrEmptyRowsNeverReachTheCleaner() async {
        let cmd = CleanerItem(id: "t397.cmd", title: "Cmd", paths: [], command: ShellCommand(executable: "/nonexistent/tool"),
                              runningAppBundleIDs: ["test.397.cmd"])
        let blockedItem = CleanerItem(id: "t397.blocked", title: "Blocked", paths: [], runningAppBundleIDs: ["test.397.blocked"])
        let open = CleanerItem(id: "t397.open", title: "Open", paths: [], runningAppBundleIDs: ["test.397.open"])
        let group = CleanerGroup(id: "g", title: "G", systemImage: "x", items: [cmd, blockedItem, open])
        let model = SmartScanModel(module: .smartScan) { [group] }
        model.appBundleIDs = { [] }
        model.processNames = { [] }
        model.runningApps = ["test.397.cmd", "test.397.blocked", "test.397.open"]
        model.scans = ["t397.cmd": ItemScan(), "t397.blocked": ItemScan(measuredSize: 10), "t397.open": ItemScan(measuredSize: 20)]
        model.blocked = ["t397.blocked"]
        for item in group.items { model.quitApps(of: item) }
        #expect(model.selected == ["t397.open"]) // no data, blocked: not ticked
        model.setSelected(group, false) // the only ticked row is locked (still running): Deselect All unticks it
        #expect(model.selected.isEmpty)
        #expect(Preferences.overrides["t397.open"] == false) // remembered like a tick by hand
        Preferences.remember(open, selected: true) // back to the default: no override left behind

        let cleaned = Locked<[String]>([])
        model.cleanItem = { item, _, _ in cleaned.withLock { $0.append(item.id) }; return CleanReport() }
        model.phase = .results
        model.selected = ["t397.cmd", "t397.open"] // e.g. ticked before its result came in empty
        await model.clean()
        #expect(cleaned.withLock { $0 } == ["t397.open"])
    }

    /// One entry of a selectable item left out → only the other goes to the (fake) Trash; other items unchanged.
    @MainActor @Test func selectableEntriesCleanOnlyTickedEntries() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let a = try box.file("Backups/a/data", bytes: 10_000), b = try box.file("Backups/b/data", bytes: 30_000)
        let x = try box.file("Other/x", bytes: 5_000)
        let trash = box.root.appending(path: "Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let backups = CleanerItem(id: "t219.backups", title: "Backups", paths: ["~/Backups"], mode: .trash, selectableEntries: true)
        let other = CleanerItem(id: "t219.other", title: "Other", paths: ["~/Other"], mode: .trash)
        let model = SmartScanModel(module: .smartScan) { [CleanerGroup(id: "g", title: "G", systemImage: "x", items: [backups, other])] }
        let policy = box.policy
        model.logHome = box.home // not the real ~/Library/Logs/CleanMate/activity.log
        model.scanItem = { await Scanner.scan($0, policy: policy, openPaths: $1) }
        model.cleanItem = { item, scan, _ in
            await Cleaner.clean(item, scan: scan, policy: policy) {
                let target = trash.appending(path: $0.lastPathComponent)
                try FileManager.default.moveItem(at: $0, to: target)
                return target
            }
        }
        await model.scan()
        let entries = try #require(model.scans["t219.backups"]?.entries) // largest first: B, then A
        try #require(entries.map(\.url.lastPathComponent) == ["b", "a"])
        let (urlB, sizeB, urlA, sizeA) = (entries[0].url, entries[0].size, entries[1].url, entries[1].size)
        let sizeX = try #require(model.scans["t219.other"]?.size)
        let full = model.selectedSize
        #expect(model.isFullySelected(backups) && model.selected.contains("t219.other"))

        model.setEntry(backups, urlA, false) // mixed: item ticked, A left out
        #expect(model.selected.contains("t219.backups") && !model.isFullySelected(backups))
        #expect(!model.isEntrySelected(backups, urlA) && model.isEntrySelected(backups, urlB))
        #expect(model.selectedSize == full - sizeA && model.hasSelection)
        #expect(model.partialSelectedSize(backups) == sizeB && model.partialSelectedSize(CleanerItem(id: "t219.other", title: "", paths: [])) == nil)
        model.toggle(ids: ["t219.backups"]) // Space on a mixed row ticks every entry
        #expect(model.isFullySelected(backups) && model.selectedSize == full)
        #expect(model.partialSelectedSize(backups) == nil)
        model.setEntry(backups, urlA, false)
        model.setEntry(backups, urlB, false) // last entry off → item off
        #expect(!model.selected.contains("t219.backups") && model.excludedEntries.isEmpty)
        model.setEntry(backups, urlB, true) // one entry on → item on with only that entry
        #expect(model.isEntrySelected(backups, urlB) && !model.isEntrySelected(backups, urlA))
        #expect(Preferences.overrides["t219.backups"] == nil) // entry ticks are not remembered

        await model.clean()
        guard case .done(let report) = model.phase else { Issue.record("not done"); return }
        #expect(report.freed == sizeB + sizeX && report.skipped == 0)
        #expect(FileManager.default.fileExists(atPath: a.path))
        #expect(!FileManager.default.fileExists(atPath: b.path) && !FileManager.default.fileExists(atPath: x.path))
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: trash.path)) == ["b", "x"])
        #expect(model.excludedEntries.isEmpty)
        #expect(CleanerGroup.developer.items.first { $0.id == "xcode-archives" }?.selectableEntries == true)
        let label = CleanerItemRow.accessibilityLabel(entry: ScanEntry(url: urlA, size: 2_000_000, title: "Meo’s iPhone"),
                                                      locale: Locale(identifier: "en"))
        #expect(label == "Meo’s iPhone, 2 MB")
    }

    /// A Docker-images-like command item: its entries are display-only and a failed command skips the whole item,
    /// so the activity log must not say "n − 1 entries removed". Logged into a throwaway home.
    @MainActor @Test func commandItemLogsWholeItemCount() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "CleanMateLog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let item = CleanerItem(id: "t268.docker", title: "Docker: unused images", paths: [],
                               command: ShellCommand(executable: "/nonexistent/docker"))
        let images = (0..<3).map { ScanEntry(url: URL(string: "docker-image:\($0)")!, size: 1_000) }
        let model = SmartScanModel(module: .smartScan) { [CleanerGroup(id: "g", title: "G", systemImage: "x", items: [item])] }
        model.logHome = home
        model.appBundleIDs = { [] }
        model.processNames = { [] }
        func run(_ entries: [ScanEntry], _ report: CleanReport) async -> [String] {
            model.scanItem = { _, _ in ItemScan(entries: entries, measuredSize: 3_000) }
            model.cleanItem = { _, _, _ in report }
            await model.scan()
            await model.clean()
            return ActivityLog.read(home: home).split(separator: "\n").map { String($0.split(separator: "\t")[3]) }
        }
        #expect(await run(images, CleanReport(skipped: 1)).isEmpty) // prune failed: nothing logged
        #expect(await run(images, CleanReport(freed: 3_000)) == ["3"])
        #expect(await run([], CleanReport(freed: 3_000)) == ["3", "1"]) // image list failed: the item itself
        // Plain file items still count entries minus skipped ones.
        let files = CleanerItem(id: "f", title: "f", paths: ["~/x"])
        #expect(SmartScanModel.removedCount(files, ItemScan(entries: images), CleanReport(freed: 2_000, skipped: 1)) == 2)
    }

    /// Entry ticks only work when cleaning removes the scanned entries: a command, a database erase or a probe
    /// acts on the whole item, so an unticked entry would be cleaned anyway (unless `entryCommand` removes each).
    @Test func selectableEntriesOnlyOnPlainFileItems() {
        let items = (CleanerGroup.smartScan(ages: .default, hasFullDiskAccess: true) + CleanerGroup.privacy).flatMap(\.items).filter(\.selectableEntries)
        #expect(!items.isEmpty)
        for item in items {
            #expect(item.entryCommand != nil || item.command == nil && item.database == nil && item.probe == nil, "\(item.id)")
        }
    }

    /// Clean checks `included` by the entry's own name, so an entry listed below a nested exclusion would not match
    /// it: the two are never used together.
    @Test func includedNeverWithExcluded() {
        for item in (CleanerGroup.smartScan(ages: .default, hasFullDiskAccess: true) + CleanerGroup.privacy).flatMap(\.items) {
            #expect(item.included == nil || item.excluded.isEmpty, "\(item.id)")
        }
    }

    @MainActor @Test func runningAppItemIsNotSelectedNorCounted() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try FileManager.default.createDirectory(at: box.temp.appending(path: "c"), withIntermediateDirectories: true)
        try Data(count: 5000).write(to: box.temp.appending(path: "c/f"))
        let path = box.temp.appending(path: "c").path
        let policy = box.policy // not this Mac's Settings › Exclusions
        let item = CleanerItem(id: "app", title: "App", paths: [path], runningAppBundleIDs: ["test.running.app"])
        let model = SmartScanModel(module: .smartScan) { [CleanerGroup(id: "g", title: "G", systemImage: "x", items: [item])] }
        model.appBundleIDs = { ["test.running.app"] }
        model.runningApps = ["test.running.app"]
        // An app launching on the Mac mid-scan refreshes the list; it used to bring back the real one.
        model.scanItem = { item, _ in
            await MainActor.run { NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil) }
            return await Scanner.scan(item, policy: policy)
        }
        await model.scan()
        #expect(model.isRunning(item))
        #expect((model.scans["app"]?.size ?? 0) > 0)
        #expect(model.selected.isEmpty && model.selectedSize == 0)
        model.runningApps = []
        #expect(!model.isRunning(item))
    }

    @MainActor @Test func runningToolItemIsSkipped() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try FileManager.default.createDirectory(at: box.temp.appending(path: "s"), withIntermediateDirectories: true)
        try Data(count: 5000).write(to: box.temp.appending(path: "s/f"))
        let item = CleanerItem(id: "cli", title: "CLI", paths: [box.temp.appending(path: "s").path],
                               runningProcessNames: ["claude"])
        let model = SmartScanModel(module: .smartScan) { [CleanerGroup(id: "g", title: "G", systemImage: "x", items: [item])] }
        model.processNames = { ["claude", "zsh"] }
        let policy = box.policy // not this Mac's Exclusions, Trash or activity log
        model.logHome = box.home
        model.scanItem = { await Scanner.scan($0, policy: policy, openPaths: $1) }
        model.cleanItem = { await Cleaner.clean($0, scan: $1, policy: policy, openPaths: $2) }
        await model.scan()
        #expect(model.isRunning(item) && model.selected.isEmpty)
        model.selected = ["cli"]
        await model.clean()
        #expect(model.totalItems == 1 && model.scannedItems == 1 && model.cleaningItem?.key == "CLI")
        guard case .done(let report) = model.phase else { Issue.record("not done"); return }
        #expect(report.skipped == 1 && FileManager.default.fileExists(atPath: box.temp.appending(path: "s/f").path))
        model.processNames = { ["claude-helper", "node"] }
        await model.scan()
        #expect(!model.isRunning(item))
        #expect(CleanerGroup.aiTools().items.first { $0.id == "claude-code-sessions" }?.runningProcessNames == ["claude"])
    }

    /// Old AI sessions: one tickable entry each, Claude Code ones named after the project path.
    @Test func aiSessionEntries() throws {
        let sessions = CleanerGroup.aiTools().items.filter { $0.id.hasSuffix("-sessions") }
        #expect(sessions.count >= 5)
        for item in sessions {
            #expect(item.selectableEntries && !item.selectedByDefault && item.mode == .trash, "\(item.id)")
            #expect(item.command == nil && item.probe == nil && item.database == nil, "\(item.id)")
        }
        let claude = try #require(sessions.first { $0.id == "claude-code-sessions" })
        #expect(claude.excluded == ["memory"] && claude.entryLabel != nil)

        let tree: [String: [String]] = ["/": ["Users"], "/Users": ["me"], "/Users/me": ["Developer", "my-app", "my"],
                                        "/Users/me/my": ["web"], "/Users/me/Developer": ["app", "site.io", "a_b"]]
        func decode(_ name: String) -> String? { AISessions.claudeProjectPath(encoded: name) { tree[$0] ?? [] } }
        #expect(decode("-Users-me-Developer-app") == "/Users/me/Developer/app")
        #expect(decode("-Users-me-Developer-site-io") == "/Users/me/Developer/site.io")
        #expect(decode("-Users-me-Developer-a-b") == "/Users/me/Developer/a_b")
        #expect(decode("-Users-me-my-app") == "/Users/me/my-app")
        #expect(decode("-Users-me-my-web") == "/Users/me/my/web") // "my-app" tried first, then backtracks
        #expect(decode("-Users-me") == "/Users/me")
        #expect(decode("-Users-me-gone-project") == nil)
        #expect(decode("Users") == nil)
        #expect(AISessions.claudeFolderName("/Users/me/my-app.v2") == "-Users-me-my-app-v2")
        // UTF-16 units like Claude Code's JavaScript: an emoji is 2, a decomposed "ự" 3.
        #expect(AISessions.claudeFolderName("/Users/me/🚀app") == "-Users-me---app")
        #expect(AISessions.claudeFolderName("/a/D\u{0075}\u{031B}\u{0323}") == "-a-Du--")

        // The label reads the real disk: the temp folder resolves, a missing project keeps its folder name.
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "CleanMate332-\(UUID().uuidString)/my-app")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let projects = URL(fileURLWithPath: "/x/.claude/projects")
        let label = AISessions.claudeLabel(of: projects.appending(path: AISessions.claudeFolderName(root.path) + "/s.jsonl"))
        #expect(label?.title == (root.path as NSString).abbreviatingWithTildeInPath)
        #expect(AISessions.claudeLabel(of: projects.appending(path: "-nope-gone/s.jsonl"))?.title == "-nope-gone")
        #expect(AISessions.claudeLabel(of: URL(fileURLWithPath: "/x/.claude/file-history/abc")) == nil)

        // Cursor: the same encoding without the leading "-", one level deeper (agent-transcripts/<id>).
        let cursor = URL(fileURLWithPath: "/x/.cursor/projects")
        let encoded = String(AISessions.claudeFolderName(root.path).dropFirst())
        #expect(AISessions.cursorLabel(of: cursor.appending(path: encoded + "/agent-transcripts/1"))?.title
                == (root.path as NSString).abbreviatingWithTildeInPath)
        #expect(AISessions.cursorLabel(of: cursor.appending(path: "Users-nope-gone/agent-tools/1.txt"))?.title == "Users-nope-gone")
        #expect(AISessions.cursorLabel(of: URL(fileURLWithPath: "/x/.cursor/extensions/a/b")) == nil)
        let cursorSessions = try #require(sessions.first { $0.id == "cursor-sessions" })
        #expect(cursorSessions.runningAppBundleIDs == ["com.todesktop.230313mzl4w4u92"] && cursorSessions.entryLabel != nil)
    }

    /// A cached label lasts one scan; a later scan sees the project moved away.
    @Test func claudeLabelRefreshesBetweenScans() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "CleanMate342-\(UUID().uuidString)/app")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let folder = AISessions.claudeFolderName(root.path)
        let session = URL(fileURLWithPath: "/x/.claude/projects/\(folder)/s.jsonl")
        let now = Date()
        let path = (root.path as NSString).abbreviatingWithTildeInPath
        #expect(AISessions.claudeLabel(of: session, now: now)?.title == path)
        try FileManager.default.removeItem(at: root)
        #expect(AISessions.claudeLabel(of: session, now: now + 1)?.title == path) // same scan: cached
        #expect(AISessions.claudeLabel(of: session, now: now + AISessions.labelLifetime)?.title == folder) // next scan
    }

    @Test func processArgumentNames() {
        func buffer(_ argc: Int32, _ strings: [String]) -> [UInt8] {
            withUnsafeBytes(of: argc) { Array($0) } + strings.flatMap { Array($0.utf8) + [0] }
        }
        // Native Claude Code: the executable is named after its version, argv[0] is `claude`.
        let native = buffer(2, ["/Users/u/.local/share/claude/versions/2.1.304", "", "", "claude", "--resume", "X=1"])
        #expect(RunningProcesses.argumentNames(native) == ["2.1.304", "claude"])
        // Node-based CLI: the script name after the interpreter counts too.
        let node = buffer(3, ["/opt/bin/node", "node", "/opt/bin/gemini", "chat"])
        #expect(RunningProcesses.argumentNames(node) == ["node", "gemini"])
        // npm install / wrapper script: the script is `cli.js`, the package path names the tool.
        let npm = buffer(3, ["/opt/bin/node", "node", "--no-warnings",
                             "/Users/u/.claude/local/node_modules/@anthropic-ai/claude-code/cli.js"])
        #expect(RunningProcesses.argumentNames(npm).contains("claude"))
        let codex = buffer(2, ["/usr/local/bin/node22", "node22", "/usr/local/lib/node_modules/@openai/codex/bin/codex.js"])
        #expect(RunningProcesses.argumentNames(codex) == ["node22", "codex.js", "codex"])
        let renamed = buffer(1, ["/Users/u/.local/share/claude/versions/2.1.304", "", "cc"])
        #expect(RunningProcesses.argumentNames(renamed).contains("claude"))
        // An unrelated tool whose arguments merely mention a CLI name is not counted.
        #expect(!RunningProcesses.argumentNames(buffer(2, ["/bin/vim", "vim", "/tmp/claude.txt"])).contains("claude"))
        // Gradle daemon: the main class comes after many JVM options.
        let gradle = buffer(6, ["/jdk/bin/java", "", "/jdk/bin/java", "-Xmx512m", "-Dx=1", "-cp", "/g/launcher.jar",
                                "org.gradle.launcher.daemon.bootstrap.GradleDaemon"])
        #expect(RunningProcesses.argumentNames(gradle).contains("GradleDaemon"))
        let kotlin = buffer(6, ["/jdk/bin/java", "", "/jdk/bin/java", "-Xmx2g", "-cp", "/k/kotlin-daemon.jar",
                                "org.jetbrains.kotlin.daemon.KotlinCompileDaemon", "--daemon-runFilesPath"])
        #expect(RunningProcesses.argumentNames(kotlin).contains("KotlinCompileDaemon"))
        #expect(!RunningProcesses.argumentNames(kotlin).contains("GradleDaemon"))
        #expect(RunningProcesses.argumentNames([]).isEmpty)
        #expect(CleanerGroup.developer.items.first { $0.id == "gradle-caches" }?.runningProcessNames == ["GradleDaemon", "KotlinCompileDaemon"])
        #expect(!RunningProcesses.names().isEmpty) // reads the real process list without `ps`
    }

    // MARK: - Privacy

    @Test func includedPicksSingleFilesButNeverHomeOrProtectedTrees() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        for path in [".zsh_history", ".bash_history", ".ssh/known_hosts", "Documents/notes.txt", ".zshrc"] { try box.file(path) }
        let item = CleanerItem(id: "h", title: "h", paths: ["~"], included: [".zsh_history", "*_history", ".ssh", "Documents"])
        let scan = await Scanner.scan(item, policy: box.policy)
        #expect(Set(scan.entries.map(\.url.lastPathComponent)) == [".zsh_history", ".bash_history"])
        let report = await Cleaner.clean(item, scan: scan, policy: box.policy)
        #expect(report.skipped == 0)
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: box.home.appending(path: ".zsh_history").path))
        for kept in [".zshrc", ".ssh/known_hosts", "Documents/notes.txt"] {
            #expect(fm.fileExists(atPath: box.home.appending(path: kept).path), "\(kept)")
        }
    }

    /// Passwords, bookmarks, extensions, saved cards and settings are never listed by any Privacy item;
    /// databases shared with them (Web Data, History) are only listed for record erasing.
    @Test func privacyNeverTouchesCredentialsBookmarksExtensions() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let chrome = "Library/Application Support/Google/Chrome"
        let firefox = "Library/Application Support/Firefox/Profiles/ab12.default-release"
        let beta = "Library/Application Support/Google/Chrome Beta", canary = "Library/Application Support/Microsoft Edge Canary"
        let nightly = "Library/Application Support/BraveSoftware/Brave-Browser-Nightly"
        let protected = [
            "\(chrome)/Default/Login Data", "\(chrome)/Default/Login Data-journal", "\(chrome)/Default/Bookmarks",
            "\(chrome)/Default/Bookmarks.bak", "\(chrome)/Default/Extensions/abc/1.0/manifest.json",
            "\(chrome)/Default/Local Extension Settings/abc/1.ldb", "\(chrome)/Default/Preferences", "\(chrome)/Local State",
            "\(chrome)/Profile 1/Login Data For Account", "\(chrome)/Default/History-journal", "Library/Application Support/com.operasoftware.Opera/Bookmarks",
            "\(beta)/Default/Login Data", "\(beta)/Default/Bookmarks", "\(beta)/Default/Extensions/abc/1.0/manifest.json",
            "\(beta)/Default/Preferences", "\(beta)/Local State", "\(canary)/Default/Login Data", "\(canary)/Default/Bookmarks",
            "\(nightly)/Profile 1/Login Data", "\(nightly)/Profile 1/Local Extension Settings/abc/1.ldb",
            "\(firefox)/logins.json", "\(firefox)/key4.db", "\(firefox)/places.sqlite-wal",
            "\(firefox)/extensions/x@y.xpi", "\(firefox)/prefs.js", "\(firefox)/favicons.sqlite",
            "Library/Safari/Bookmarks.plist", "Library/Safari/PasswordBreachStore.plist", "Library/Safari/TopSites.plist",
            "Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.FavoriteItems.sfl4",
            ".ssh/known_hosts", ".zshrc", ".vimrc", "Library/Keychains/login.keychain-db",
        ]
        let erased = [
            "\(chrome)/Default/Visited Links", "\(chrome)/Default/Cookies",
            "\(chrome)/Profile 1/Network/Cookies", "Library/Application Support/com.operasoftware.Opera/Cookies",
            "\(beta)/Default/Cookies", "\(beta)/Default/Visited Links", "\(canary)/Profile 1/Network/Cookies",
            "\(nightly)/Default/Top Sites",
            "\(firefox)/cookies.sqlite", "\(firefox)/cookies.sqlite-wal", "\(firefox)/formhistory.sqlite",
            "Library/Safari/History.db", "Library/Safari/History.db-wal", "Library/Safari/Downloads.plist",
            "Library/Safari/Form Values", "Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies",
            "Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.RecentDocuments.sfl4",
            "Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/a.sfl3",
            ".zsh_history", ".zsh_sessions/x.session", ".local/share/fish/fish_history", ".python_history", ".viminfo",
        ]
        let history = box.home.appending(path: "\(chrome)/Default/History")
        let webData = box.home.appending(path: "\(chrome)/Default/Web Data")
        _ = try await sqlite(history, "CREATE TABLE downloads(id); CREATE TABLE downloads_url_chains(id); CREATE TABLE urls(id); INSERT INTO downloads VALUES(1);")
        _ = try await sqlite(webData, "CREATE TABLE autofill(name); CREATE TABLE credit_cards(id); INSERT INTO autofill VALUES('q');")
        let places = box.home.appending(path: "\(firefox)/places.sqlite")
        _ = try await sqlite(places, EndToEndCleanTests.firefoxPlaces)
        for path in protected + erased { try box.file(path) } // after sqlite3, which deletes stray journals

        var removed: [URL] = [], databases: [URL] = []
        for item in CleanerGroup.privacy.flatMap(\.items).map(EndToEndCleanTests.ownOpenFiles) {
            #expect(!item.selectedByDefault, "\(item.id)")
            #expect(item.mode == .delete, "\(item.id)")
            for entry in await Scanner.scan(item, policy: box.policy).entries {
                #expect(entry.isDatabase == (item.database?.applies(to: entry.url) == true))
                let url = entry.url.resolvingSymlinksInPath()
                if entry.isDatabase { databases.append(url) } else { removed.append(url) }
            }
        }
        #expect(Set(databases.map(\.path)) == Set([history, webData, places].map { $0.resolvingSymlinksInPath().path }))
        for path in protected + [chrome + "/Default/Web Data", firefox + "/places.sqlite"] {
            let file = box.home.appending(path: path).resolvingSymlinksInPath().path
            #expect(!removed.contains { file == $0.path || file.hasPrefix($0.path + "/") }, "\(path)")
        }
        for path in erased {
            let file = box.home.appending(path: path).resolvingSymlinksInPath().path
            #expect(removed.contains { file == $0.path || file.hasPrefix($0.path + "/") }, "\(path)")
        }
    }

    /// One Privacy group per Beta/Dev/Canary/Nightly channel, its own folder and bundle id, nothing ticked.
    @Test func privacyBrowserChannelsHaveTheirOwnGroup() throws {
        #expect(CleanerGroup.browserChannels.count == 8)
        for channel in CleanerGroup.browserChannels {
            let group = try #require(CleanerGroup.privacy.first { $0.id == "privacy-" + channel.id }, "\(channel.id)")
            #expect(group.items.map(\.id) == ["history", "downloads", "cookies", "autofill"].map { channel.id + "-" + $0 })
            let root = "~/Library/Application Support/" + channel.folder
            for item in group.items {
                #expect(item.runningAppBundleIDs == [channel.bundle] && !item.selectedByDefault && !item.showsWhenEmpty, "\(item.id)")
                #expect(item.mode == .delete && item.paths.starts(with: [root, root + "/*"]), "\(item.id)")
            }
        }
    }

    /// Chromium on a recent schema (Web Data v153, History v70 as in Brave 2026): form entries live in
    /// `autocomplete` (and the old `autofill`), download slices go with the download list, a WAL next to a deleted
    /// Cookies goes too (a stale -wal could be replayed into the new database).
    @Test func chromiumRecentSchemaErasesAutocompleteSlicesAndWal() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let profile = "Library/Application Support/Google/Chrome/Default"
        let webData = box.home.appending(path: profile + "/Web Data")
        _ = try await sqlite(webData, """
            CREATE TABLE autofill(name, value); CREATE TABLE autocomplete(name, label, value);
            CREATE TABLE addresses(id); CREATE TABLE credit_cards(id); CREATE TABLE keywords(id); CREATE TABLE autofill_ai_entities(id);
            INSERT INTO autocomplete VALUES('q','','x'),('email','','a@b.c'); INSERT INTO autofill VALUES('old','y');
            INSERT INTO addresses VALUES(1); INSERT INTO credit_cards VALUES(1); INSERT INTO keywords VALUES(1);
            INSERT INTO autofill_ai_entities VALUES(1);
            """)
        let items = CleanerGroup.privacy.flatMap(\.items)
        let autofill = try #require(items.first { $0.id == "chrome-autofill" })
        let scan = await Scanner.scan(autofill, policy: box.policy)
        #expect(scan.records == 3)
        #expect(await Cleaner.clean(autofill, scan: scan, policy: box.policy).skipped == 0)
        #expect(try await sqlite(webData, """
            SELECT (SELECT count(*) FROM autofill) + (SELECT count(*) FROM autocomplete), (SELECT count(*) FROM addresses)
              + (SELECT count(*) FROM credit_cards) + (SELECT count(*) FROM keywords) + (SELECT count(*) FROM autofill_ai_entities);
            """) == "0|4")
        #expect(await Scanner.scan(autofill, policy: box.policy).hasData == false)

        let history = box.home.appending(path: profile + "/History")
        _ = try await sqlite(history, """
            CREATE TABLE downloads(id INTEGER PRIMARY KEY); CREATE TABLE downloads_url_chains(id, chain_index, url);
            CREATE TABLE downloads_slices(download_id, offset, received_bytes); CREATE TABLE urls(id); CREATE TABLE visits(id);
            INSERT INTO downloads VALUES(1); INSERT INTO downloads_url_chains VALUES(1,0,'u'); INSERT INTO downloads_slices VALUES(1,0,5);
            INSERT INTO urls VALUES(1); INSERT INTO visits VALUES(1);
            """)
        let downloads = try #require(items.first { $0.id == "chrome-downloads" })
        #expect(await Cleaner.clean(downloads, scan: await Scanner.scan(downloads, policy: box.policy), policy: box.policy).skipped == 0)
        #expect(try await sqlite(history, """
            SELECT (SELECT count(*) FROM downloads) + (SELECT count(*) FROM downloads_url_chains) + (SELECT count(*) FROM downloads_slices),
              (SELECT count(*) FROM urls) + (SELECT count(*) FROM visits);
            """) == "0|2")

        let cookies = try #require(items.first { $0.id == "chrome-cookies" })
        for name in ["Cookies", "Cookies-wal", "Cookies-shm"] { try box.file(profile + "/Network/" + name) }
        #expect(await Cleaner.clean(cookies, scan: await Scanner.scan(cookies, policy: box.policy), policy: box.policy).skipped == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.home.appending(path: profile + "/Network").path).isEmpty)
    }

    /// Table names come from the database itself: one with a quote, a semicolon or a newline is matched and quoted
    /// exactly, never split into other names or run as SQL.
    @Test func databaseEraseQuotesOddTableNamesExactly() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let db = box.home.appending(path: "odd.sqlite")
        _ = try await sqlite(db, """
            CREATE TABLE "visits""; DROP TABLE keep; --
            urls"(a); CREATE TABLE keep(a); CREATE TABLE urls(a);
            INSERT INTO "visits""; DROP TABLE keep; --
            urls" VALUES(1),(2); INSERT INTO keep VALUES(1); INSERT INTO urls VALUES(1);
            """)
        let item = CleanerItem(id: "d", title: "d", paths: ["~"], included: ["odd.sqlite"],
                               database: DatabaseErase(count: "", tables: ["visits*"]))
        let scan = await Scanner.scan(item, policy: box.policy)
        #expect(scan.records == 2)
        #expect(await Cleaner.clean(item, scan: scan, policy: box.policy).skipped == 0)
        #expect(try await sqlite(db, """
            SELECT (SELECT count(*) FROM "visits""; DROP TABLE keep; --
            urls"), (SELECT count(*) FROM keep), (SELECT count(*) FROM urls);
            """) == "0|1|1")
    }

    @Test func databaseEraseKeepsOtherTablesAndNeverCreatesFiles() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let profile = "Library/Application Support/Google/Chrome/Default"
        let webData = box.home.appending(path: profile + "/Web Data")
        _ = try await sqlite(webData, """
            CREATE TABLE autofill(name, value); CREATE TABLE credit_cards(id); CREATE TABLE keywords(id);
            INSERT INTO autofill VALUES('email','a@b.c'); INSERT INTO autofill VALUES('q','x');
            INSERT INTO credit_cards VALUES(1); INSERT INTO keywords VALUES(1);
            """)
        let items = CleanerGroup.privacy.flatMap(\.items)
        let autofill = try #require(items.first { $0.id == "chrome-autofill" })
        let scan = await Scanner.scan(autofill, policy: box.policy)
        #expect(scan.records == 2 && scan.hasData && scan.size == 0)
        let report = await Cleaner.clean(autofill, scan: scan, policy: box.policy)
        #expect(report.skipped == 0)
        #expect(try await sqlite(webData, "SELECT (SELECT count(*) FROM autofill) || ',' || (SELECT count(*) FROM credit_cards) || ',' || (SELECT count(*) FROM keywords);") == "0,1,1")
        #expect(await Scanner.scan(autofill, policy: box.policy).hasData == false)

        // A database removed after the scan is not recreated by sqlite3.
        let downloads = try #require(items.first { $0.id == "chrome-downloads" })
        let history = box.home.appending(path: profile + "/History")
        let forged = ItemScan(entries: [ScanEntry(url: history, size: 0, isDatabase: true, records: 1)])
        _ = await Cleaner.clean(downloads, scan: forged, policy: box.policy)
        #expect(!FileManager.default.fileExists(atPath: history.path))

        // An empty database file is not listed, and a forged entry for it is left at 0 bytes.
        FileManager.default.createFile(atPath: history.path, contents: Data())
        #expect(await Scanner.scan(downloads, policy: box.policy).hasData == false)
        #expect(await Cleaner.clean(downloads, scan: forged, policy: box.policy).skipped == 0)
        #expect(try FileManager.default.attributesOfItem(atPath: history.path)[.size] as? Int == 0)
    }

    /// VACUUM runs apart from the erase: when it fails (e.g. disk full) the records are still erased, the item
    /// is not skipped and nothing is reported as freed; when it works the file really shrinks.
    @Test func databaseEraseReportsTruthfullyWhenVacuumFails() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let webData = box.home.appending(path: "Library/Application Support/Google/Chrome/Default/Web Data")
        let fill = """
            CREATE TABLE IF NOT EXISTS autofill(name, value); DELETE FROM autofill;
            WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 2000)
            INSERT INTO autofill SELECT 'k', randomblob(1000) FROM n;
            """
        var item = try #require(CleanerGroup.privacy.flatMap(\.items).first { $0.id == "chrome-autofill" })
        item.database?.vacuum = "SELECT no_such_function();" // fails like a VACUUM without free space
        for vacuumWorks in [false, true] {
            if vacuumWorks { item.database?.vacuum = "VACUUM;" }
            _ = try await sqlite(webData, fill)
            let scan = await Scanner.scan(item, policy: box.policy)
            let report = await Cleaner.clean(item, scan: scan, policy: box.policy)
            #expect(report.skipped == 0)
            #expect(try await sqlite(webData, "SELECT count(*) FROM autofill;") == "0")
            #expect(vacuumWorks ? report.freed > 1_000_000 : report.freed == 0)
        }
    }

    /// A database replaced by a symlink (or a hard link) to another database after the scan: sqlite3 would write
    /// through it, so nothing is erased.
    @Test func databaseEraseNeverWritesThroughLinks() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let target = box.home.appending(path: "Documents/notes.sqlite")
        _ = try await sqlite(target, "CREATE TABLE autofill(name); INSERT INTO autofill VALUES('mine');")
        let item = try #require(CleanerGroup.privacy.flatMap(\.items).first { $0.id == "chrome-autofill" })
        let webData = box.home.appending(path: "Library/Application Support/Google/Chrome/Default/Web Data")
        try FileManager.default.createDirectory(at: webData.deletingLastPathComponent(), withIntermediateDirectories: true)
        let forged = ItemScan(entries: [ScanEntry(url: webData, size: 0, isDatabase: true, records: 1)])
        let fm = FileManager.default
        let links: [() throws -> Void] = [{ try fm.createSymbolicLink(at: webData, withDestinationURL: target) },
                                          { try fm.linkItem(at: target, to: webData) }]
        for link in links {
            try? fm.removeItem(at: webData)
            try link()
            let report = await Cleaner.clean(item, scan: forged, policy: box.policy)
            #expect(report.skipped == 1)
            #expect(try await sqlite(target, "SELECT count(*) FROM autofill;") == "1")
        }
    }

    /// Chromium history: browsing tables of a real-schema History are emptied (missing ones skipped), the download
    /// list and the file itself are kept; the item's other files are removed.
    @Test func chromiumHistoryEraseKeepsDownloads() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let profile = "Library/Application Support/Google/Chrome/Default"
        let history = box.home.appending(path: profile + "/History")
        _ = try await sqlite(history, """
            CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
            CREATE TABLE urls(id INTEGER PRIMARY KEY AUTOINCREMENT, url LONGVARCHAR, title LONGVARCHAR, visit_count INTEGER DEFAULT 0 NOT NULL,
              typed_count INTEGER DEFAULT 0 NOT NULL, last_visit_time INTEGER NOT NULL, hidden INTEGER DEFAULT 0 NOT NULL);
            CREATE TABLE visits(id INTEGER PRIMARY KEY AUTOINCREMENT, url INTEGER NOT NULL, visit_time INTEGER NOT NULL,
              from_visit INTEGER, transition INTEGER DEFAULT 0 NOT NULL, segment_id INTEGER, visit_duration INTEGER DEFAULT 0 NOT NULL);
            CREATE TABLE visit_source(id INTEGER PRIMARY KEY, source INTEGER NOT NULL);
            CREATE TABLE keyword_search_terms(keyword_id INTEGER NOT NULL, url_id INTEGER NOT NULL, term LONGVARCHAR NOT NULL,
              normalized_term LONGVARCHAR NOT NULL);
            CREATE TABLE segments(id INTEGER PRIMARY KEY, name VARCHAR, url_id INTEGER NON NULL);
            CREATE TABLE segment_usage(id INTEGER PRIMARY KEY, segment_id INTEGER NOT NULL, time_slot INTEGER NOT NULL,
              visit_count INTEGER DEFAULT 0 NOT NULL);
            CREATE TABLE content_annotations(visit_id INTEGER PRIMARY KEY, visibility_score NUMERIC, page_topics_model_version INTEGER);
            CREATE TABLE clusters(cluster_id INTEGER PRIMARY KEY AUTOINCREMENT, should_show_on_prominent_ui_surfaces BOOLEAN NOT NULL);
            CREATE TABLE clusters_and_visits(cluster_id INTEGER NOT NULL, visit_id INTEGER NOT NULL, score NUMERIC DEFAULT 0 NOT NULL,
              PRIMARY KEY(cluster_id, visit_id)) WITHOUT ROWID;
            CREATE INDEX clusters_for_visit ON clusters_and_visits(visit_id);
            CREATE TABLE cluster_keywords(cluster_id INTEGER NOT NULL, keyword VARCHAR NOT NULL, type INTEGER NOT NULL, score NUMERIC NOT NULL,
              collections VARCHAR NOT NULL);
            CREATE TABLE cluster_visit_duplicates(visit_id INTEGER NOT NULL, duplicate_visit_id INTEGER NOT NULL,
              PRIMARY KEY(visit_id, duplicate_visit_id)) WITHOUT ROWID;
            CREATE TABLE journeys(journey_id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, emoji TEXT, overview TEXT, short_overview TEXT,
              creation_time_micros INTEGER NOT NULL);
            CREATE INDEX journeys_creation_time_idx ON journeys(creation_time_micros);
            CREATE TABLE journey_history_entries(journey_id TEXT NOT NULL, visit_timestamp_micros INTEGER NOT NULL,
              PRIMARY KEY(journey_id, visit_timestamp_micros)) WITHOUT ROWID;
            CREATE TABLE journey_continuation_queries(id INTEGER PRIMARY KEY, journey_id TEXT NOT NULL, title TEXT NOT NULL, prompt TEXT NOT NULL);
            CREATE TABLE journey_sync_metadata(storage_key TEXT PRIMARY KEY NOT NULL, value BLOB NOT NULL);
            CREATE TABLE downloads(id INTEGER PRIMARY KEY, guid VARCHAR NOT NULL, current_path LONGVARCHAR NOT NULL,
              target_path LONGVARCHAR NOT NULL, start_time INTEGER NOT NULL, received_bytes INTEGER NOT NULL, total_bytes INTEGER NOT NULL,
              state INTEGER NOT NULL, tab_url VARCHAR NOT NULL DEFAULT '');
            CREATE TABLE downloads_url_chains(id INTEGER NOT NULL, chain_index INTEGER NOT NULL, url LONGVARCHAR NOT NULL,
              PRIMARY KEY (id, chain_index));
            INSERT INTO meta VALUES('version','67');
            INSERT INTO urls VALUES(1,'https://a.example/','A',2,1,1,0),(2,'https://b.example/?q=x','B',1,0,1,0);
            INSERT INTO visits VALUES(1,1,1,0,1,1,0),(2,1,2,1,0,1,0),(3,2,3,0,1,0,0);
            INSERT INTO visit_source VALUES(1,0); INSERT INTO keyword_search_terms VALUES(1,2,'X','x');
            INSERT INTO segments VALUES(1,'http://a.example/',1); INSERT INTO segment_usage VALUES(1,1,1,2);
            INSERT INTO content_annotations VALUES(1,0.5,1); INSERT INTO clusters VALUES(1,1); INSERT INTO clusters_and_visits VALUES(1,1,1);
            INSERT INTO cluster_keywords VALUES(1,'k',0,1,''); INSERT INTO cluster_visit_duplicates VALUES(1,2);
            INSERT INTO journeys VALUES('j','Trip','x','o','s',1); INSERT INTO journey_history_entries VALUES('j',1);
            INSERT INTO journey_continuation_queries VALUES(1,'j','T','p'); INSERT INTO journey_sync_metadata VALUES('j',x'00');
            INSERT INTO downloads VALUES(1,'g','/Users/x/Downloads/f.zip','/Users/x/Downloads/f.zip',1,10,10,1,'https://a.example/');
            INSERT INTO downloads_url_chains VALUES(1,0,'https://a.example/f.zip');
            """)
        try box.file(profile + "/Visited Links")
        let item = try #require(CleanerGroup.privacy.flatMap(\.items).first { $0.id == "chrome-history" })
        let scan = await Scanner.scan(item, policy: box.policy)
        #expect(scan.records == 3)
        #expect(Set(scan.entries.map(\.url.lastPathComponent)) == ["History", "Visited Links"])
        #expect(await Cleaner.clean(item, scan: scan, policy: box.policy).skipped == 0)
        #expect(try await sqlite(history, """
            SELECT (SELECT count(*) FROM urls) + (SELECT count(*) FROM visits) + (SELECT count(*) FROM visit_source)
              + (SELECT count(*) FROM keyword_search_terms) + (SELECT count(*) FROM segments) + (SELECT count(*) FROM segment_usage)
              + (SELECT count(*) FROM content_annotations) + (SELECT count(*) FROM clusters) + (SELECT count(*) FROM clusters_and_visits)
              + (SELECT count(*) FROM cluster_keywords) + (SELECT count(*) FROM cluster_visit_duplicates) + (SELECT count(*) FROM journeys)
              + (SELECT count(*) FROM journey_history_entries) + (SELECT count(*) FROM journey_continuation_queries);
            SELECT count(*) FROM downloads; SELECT url FROM downloads_url_chains; SELECT value FROM meta;
            SELECT count(*) FROM journey_sync_metadata;
            """) == "0\n1\nhttps://a.example/f.zip\n67\n1")
        #expect(!FileManager.default.fileExists(atPath: box.home.appending(path: profile + "/Visited Links").path))
        #expect(await Scanner.scan(item, policy: box.policy).entries.isEmpty)
    }

    /// A History.db* file held open (by a macOS history service after Safari quits) keeps all of History.db, -wal
    /// and -shm, at scan and at clean; RecentlyClosedTabs.plist still goes. Real open file, temp home.
    @Test func safariHistoryKeptWhileHistoryDatabaseOpen() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let db = try box.file("Library/Safari/History.db")
        try box.file("Library/Safari/History.db-wal")
        try box.file("Library/Safari/History.db-shm")
        let tabs = try box.file("Library/Safari/RecentlyClosedTabs.plist")
        let item = EndToEndCleanTests.ownOpenFiles(try #require(CleanerGroup.privacy.flatMap(\.items).first { $0.id == "safari-history" }))
        let full = await Scanner.scan(item, policy: box.policy)
        #expect(full.entries.count == 4)
        let handle = try FileHandle(forReadingFrom: box.home.appending(path: "Library/Safari/History.db-wal"))
        #expect(await Scanner.scan(item, policy: box.policy).entries.map(\.url.lastPathComponent) == ["RecentlyClosedTabs.plist"])
        let report = await Cleaner.clean(item, scan: full, policy: box.policy) // scanned before it was opened
        #expect(report.skipped == 3)
        #expect(FileManager.default.fileExists(atPath: db.path) && !FileManager.default.fileExists(atPath: tabs.path))
        try handle.close()
        #expect(await Scanner.scan(item, policy: box.policy).entries.count == 3)
    }

    /// Developer Edition and Nightly share Firefox/Profiles (and Caches/Firefox): any of them running skips every
    /// Firefox item, in Privacy and in the app caches.
    @Test func firefoxItemsSkipWhileAnyFirefoxEditionRuns() throws {
        let privacy = try #require(CleanerGroup.privacy.first { $0.id == "privacy-firefox" }).items
        let cache = try #require(CleanerGroup.applications().items.first { $0.id == "firefox" })
        #expect(privacy.count == 3)
        for item in privacy + [cache] {
            #expect(Set(item.runningAppBundleIDs) == ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
                                                       "org.mozilla.nightly"], "\(item.id)")
        }
    }

    /// Firefox history + downloads: visits, typed input, metadata and download annotations go; bookmarks (and
    /// their URL), folders, keywords and other annotations stay. Works once Firefox removed the -shm file.
    @Test func firefoxHistoryEraseKeepsBookmarks() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let places = box.home.appending(path: "Library/Application Support/Firefox/Profiles/ab.default/places.sqlite")
        _ = try await sqlite(places, EndToEndCleanTests.firefoxPlaces + "PRAGMA wal_checkpoint(TRUNCATE);")
        for suffix in ["-shm", "-wal"] { try? FileManager.default.removeItem(atPath: places.path + suffix) }
        let item = try #require(CleanerGroup.privacy.flatMap(\.items).first { $0.id == "firefox-history" })
        #expect(!item.selectedByDefault && item.runningAppBundleIDs == CleanerGroup.firefoxBundleIDs)
        let scan = await Scanner.scan(item, policy: box.policy)
        #expect(scan.records == 6) // 4 visits + 2 download annotations
        #expect(await Cleaner.clean(item, scan: scan, policy: box.policy).skipped == 0)
        #expect(try await sqlite(places, """
            SELECT (SELECT count(*) FROM moz_historyvisits) || ',' || (SELECT count(*) FROM moz_inputhistory) || ','
              || (SELECT count(*) FROM moz_places_metadata) || ',' || (SELECT count(*) FROM moz_places_metadata_search_queries);
            SELECT group_concat(id || ':' || url || ':' || visit_count || ':' || ifnull(last_visit_date, '-'), ' ') FROM moz_places;
            SELECT group_concat(id || ':' || ifnull(fk, '-') || ':' || parent || ':' || title, ' ') FROM moz_bookmarks;
            SELECT keyword || ':' || place_id FROM moz_keywords;
            SELECT group_concat(place_id || ':' || content, ' ') FROM moz_annos;
            SELECT group_concat(host, ' ') FROM (SELECT host FROM moz_origins ORDER BY id);
            """) == """
            0,0,0,0
            1:https://bank.example/:0:- 3:https://search.example/?q=%s:0:- 5:https://note.example/:0:-
            1:-:0: 2:-:1:Work 3:1:2:Bank
            s:3
            5:keep
            bank.example search.example note.example
            """)
        #expect(await Scanner.scan(item, policy: box.policy).hasData == false)
    }
}

/// Runs `sql` on the SQLite file at `url` (created with its folder if missing) and returns the trimmed output.
func sqlite(_ url: URL, _ sql: String) async throws -> String {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let output = await ShellCommand(executable: DatabaseErase.sqlite, arguments: [url.path, sql]).output()
    return try #require(output).trimmingCharacters(in: .whitespacesAndNewlines)
}
