import Foundation
import Testing
@testable import CleanMate

/// Space Lens on an external drive: fake drives in a temporary `volumesFolder`, with injected mount points and mount
/// flags; moves go to a fake drive Trash in the same folder, so no real drive or Trash is touched.
@Suite(.timeLimit(.minutes(2)))
struct SpaceLensExternalTests {
    let fm = FileManager.default
    let root = FileManager.default.temporaryDirectory.appending(path: "CleanMateSpaceLensExternal-\(UUID().uuidString)")
    var home: URL { root.appending(path: "home") }
    var volumes: URL { root.appending(path: "Volumes") }
    var ext: URL { volumes.appending(path: "Ext") }
    static let local = UInt32(MNT_LOCAL)

    @discardableResult func put(_ path: String, in base: URL? = nil, bytes: Int = 20_000) throws -> URL {
        let url = (base ?? ext).appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
        return url
    }

    /// `mounted`: folders of `volumesFolder` (or below it) reported as mount points.
    func policy(mounted names: [String] = ["Ext"], flags: [String: UInt32] = [:], excluded: [String] = []) -> SafetyPolicy {
        let mounts = names.map { SafetyPolicy.normalize(volumes.appending(path: $0)) }
        let byPath = Dictionary(uniqueKeysWithValues: flags.map { (SafetyPolicy.normalize(volumes.appending(path: $0.key)), $0.value) })
        return SafetyPolicy(home: home, temp: root.appending(path: "tmp"), excluded: excluded, mounts: { ["/"] + mounts },
                            volumesFolder: volumes.path, flags: { byPath[$0] ?? Self.local })
    }

    /// `du -s` in bytes (512-byte blocks).
    func du(_ url: URL) throws -> Int64 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-s", "-x", url.path]
        process.environment = ["BLOCKSIZE": "512"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return Int64(output.split(separator: "\t").first ?? "")! * 512
    }

    /// Regular files and folders holding only such files (Finder's `.DS_Store` / `._name` along) may go to the drive's
    /// Trash; hidden items, `.Trashes`, packages, links, other volumes, exclusions, the drive itself and drives that are
    /// read-only, network, Time Machine or not mounted stay view-only.
    @Test func policyOnAnExternalDrive() throws {
        defer { try? fm.removeItem(at: root) }
        try put("top.mov"); try put("Movies/big.mov"); try put("Movies/Sub/clip.mov")
        try put("Movies/.DS_Store", bytes: 10); try put("Movies/._big.mov", bytes: 10)
        try put(".hidden.mov"); try put(".Trashes/\(getuid())/old.mov")
        try put("Project/.git/HEAD"); try put("Project/main.swift")
        try put("Apps/Foo.app/Contents/x")
        try put("Holder/mnt/inner.mov"); try put("Outer/Excluded/x.mov"); try put("Links/a.mov")
        try fm.createSymbolicLink(at: ext.appending(path: "Links/link"), withDestinationURL: home)
        for name in ["ReadOnly", "Network", "TimeMachine", "Unmounted"] { try put("Movies/a.mov", in: volumes.appending(path: name)) }
        try fm.createDirectory(at: volumes.appending(path: "TimeMachine/Backups.backupdb"), withIntermediateDirectories: true)
        let policy = policy(mounted: ["Ext", "Ext/Holder/mnt", "ReadOnly", "Network", "TimeMachine"],
                            flags: ["ReadOnly": Self.local | UInt32(MNT_RDONLY), "Network": 0],
                            excluded: [ext.appending(path: "Outer/Excluded").path])

        for path in ["top.mov", "Movies", "Movies/big.mov", "Movies/Sub", "Movies/Sub/clip.mov", "Project/main.swift", "Links/a.mov"] {
            #expect(policy.allowsSpaceLensItem(ext.appending(path: path)), "\(path)")
        }
        for path in ["", ".hidden.mov", "Movies/.DS_Store", "Movies/._big.mov", ".Trashes", ".Trashes/\(getuid())/old.mov",
                     "Project", "Project/.git", "Apps", "Apps/Foo.app", "Apps/Foo.app/Contents/x", "Holder", "Holder/mnt",
                     "Holder/mnt/inner.mov", "Outer", "Outer/Excluded", "Outer/Excluded/x.mov", "Links", "Links/link"] {
            #expect(!policy.allowsSpaceLensItem(ext.appending(path: path)), "\(path)")
        }
        for name in ["ReadOnly", "Network", "TimeMachine", "Unmounted"] {
            for path in ["Movies", "Movies/a.mov"] {
                #expect(!policy.allowsSpaceLensItem(volumes.appending(path: "\(name)/\(path)")), "\(name)/\(path)")
            }
        }
        // The menu's cheap check doesn't walk the folder; the move checks it fully.
        #expect(policy.allowsSpaceLensItem(ext.appending(path: "Project"), deep: false))
        #expect(!policy.allowsSpaceLensItem(ext.appending(path: "Apps/Foo.app"), deep: false))
    }

    /// Folders on the drive measure like `du -x`, and open with the breadcrumb from the drive.
    @MainActor @Test func measuresAndOpensWithTheBreadcrumbFromTheDrive() async throws {
        defer { try? fm.removeItem(at: root) }
        try put("Movies/big.mov", bytes: 300_000); try put("Movies/Sub/clip.mov", bytes: 50_000); try put("Docs/a.pdf")
        let policy = policy()
        let model = SpaceLensModel(center: NotificationCenter())
        model.home = home
        model.hasFullDiskAccess = { true }
        model.externalVolume = { url in policy.externalVolume(SafetyPolicy.normalize(url)).map { URL(fileURLWithPath: $0) } }
        func settle() async throws { while model.measuring { try await Task.sleep(for: .milliseconds(5)) } }
        model.start(at: ext.appending(path: "Movies/Sub"))
        try await settle()
        #expect(model.breadcrumb.map(\.lastPathComponent) == ["Ext", "Movies", "Sub"])
        model.go(to: 0)
        try await settle()
        #expect(model.current.lastPathComponent == "Ext")
        for name in ["Movies", "Docs"] {
            let item = try #require(model.items.first { $0.name == name })
            #expect(item.size == (try du(ext.appending(path: name))), "\(name)")
        }
        model.start(at: home)
        try await settle()
        #expect(model.breadcrumb.map(\.lastPathComponent) == ["home"])
    }

    /// Allowed items go to the drive's own Trash, refused ones stay; Undo puts them back where they were.
    @Test func trashGoesToTheDrivesTrashAndUndoPutsItBack() async throws {
        defer { try? fm.removeItem(at: root) }
        let file = try put("Movies/big.mov")
        let folder = ext.appending(path: "Old")
        let inner = try put("Old/a.zip")
        try put("Old/.DS_Store", bytes: 10)
        let hidden = try put(".hidden.mov")
        let inTrashes = try put(".Trashes/\(getuid())/old.mov")
        let driveTrash = ext.appending(path: ".Trashes/\(getuid())")
        let policy = policy()
        let report = await SpaceLens.trash([file, folder, hidden, inTrashes].map { SpaceItem(url: $0, isFolder: false, size: 10) },
                                           policy: policy, trash: { url in
            let target = driveTrash.appending(path: url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        })
        #expect(report.trashed.map(\.original) == [file, folder] && report.skipped == 2 && report.freed == 20)
        #expect(!fm.fileExists(atPath: file.path) && !fm.fileExists(atPath: folder.path))
        #expect(fm.fileExists(atPath: driveTrash.appending(path: "Old/a.zip").path))
        #expect(fm.fileExists(atPath: hidden.path) && fm.fileExists(atPath: inTrashes.path))

        let result = await TrashUndo.restore(report.trashed, module: "Space Lens", home: home)
        #expect(result == TrashUndo.Result(restored: 2, skipped: 0))
        #expect(fm.fileExists(atPath: file.path) && fm.fileExists(atPath: inner.path))
        #expect(try fm.contentsOfDirectory(atPath: driveTrash.path) == ["old.mov"])
    }
}
