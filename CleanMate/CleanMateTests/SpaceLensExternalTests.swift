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
        func settle() async { await until(model) { !$0.measuring } }
        model.start(at: ext.appending(path: "Movies/Sub"))
        await settle()
        #expect(model.breadcrumb.map(\.lastPathComponent) == ["Ext", "Movies", "Sub"])
        model.go(to: 0)
        await settle()
        #expect(model.current.lastPathComponent == "Ext")
        for name in ["Movies", "Docs"] {
            let item = try #require(model.items.first { $0.name == name })
            #expect(item.size == (try du(ext.appending(path: name))), "\(name)")
        }
        model.start(at: home)
        await settle()
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

    // MARK: Startup disk

    /// A fake startup disk: `Disk` with Users (this user's home `me`, `bob`, `Shared`), Library, Applications, opt and
    /// System holding a mounted data volume; `mountPoints` injected.
    var disk: URL { root.appending(path: "Disk") }
    var diskHome: URL { disk.appending(path: "Users/me") }
    var dataVolume: URL { disk.appending(path: "System/Volumes/Data") }

    @MainActor func diskModel(fullDiskAccess: Bool = true) throws -> SpaceLensModel {
        try put("Users/me/Docs/a.txt", in: disk, bytes: 40_000); try put("Users/me/Desktop/big.mov", in: disk, bytes: 400_000)
        try put("Users/bob/notes.txt", in: disk); try put("Users/Shared/x.bin", in: disk)
        try put("Library/Caches/c.bin", in: disk); try put("Applications/Foo.app/Contents/Foo", in: disk)
        try put("opt/tool/bin/run", in: disk); try put("System/Library/k.bin", in: disk)
        try put("System/Volumes/Data/whole.bin", in: disk, bytes: 300_000); try put(".hidden.bin", in: disk, bytes: 60_000)
        let model = SpaceLensModel(center: NotificationCenter())
        model.home = diskHome
        model.disk = disk
        model.hasFullDiskAccess = { fullDiskAccess }
        model.externalVolume = { _ in nil }
        let mounted = dataVolume.path
        model.mountPoints = { [mounted] }
        return model
    }

    @MainActor func settle(_ model: SpaceLensModel) async {
        await until(model) { !$0.measuring }
    }

    /// Startup Disk lists the disk's top level measured like `du -x` but never inside the data volume mounted in
    /// /System; each item outside home has its lock reason; a folder outside home opens with the breadcrumb from the
    /// disk, which goes back up to it.
    @MainActor @Test func startupDiskListsItsTopLevelWithReasons() async throws {
        defer { try? fm.removeItem(at: root) }
        let model = try diskModel()
        model.start(at: model.disk)
        await settle(model)
        #expect(model.breadcrumb == [disk.standardizedFileURL])
        func item(_ name: String) throws -> SpaceItem { try #require(model.items.first { $0.name == name }, "\(name)") }
        for name in ["Users", "Library", "Applications", "opt"] {
            #expect(try item(name).size == (try du(disk.appending(path: name))), "\(name)")
        }
        var data = stat()
        #expect(lstat(dataVolume.path, &data) == 0)
        let system = try du(disk.appending(path: "System")) - (try du(dataVolume)) + Int64(data.st_blocks) * 512
        #expect(try item("System").size == system)
        #expect(try item("Users").viewOnly == .holdsHome)
        #expect(try item("Library").viewOnly == .systemLibrary)
        #expect(try item("Applications").viewOnly == .app)
        #expect(try item("opt").viewOnly == .outsideHome)
        #expect(try item(".hidden.bin").isHidden)

        model.open(disk.appending(path: "Users"))
        await settle(model)
        #expect(try item("me").viewOnly == .holdsHome)
        #expect(try item("bob").viewOnly == .otherUser)
        #expect(try item("Shared").viewOnly == .outsideHome)
        model.open(diskHome)
        await settle(model)
        #expect(model.items.allSatisfy { $0.viewOnly == nil })

        model.start(at: dataVolume.deletingLastPathComponent())
        await settle(model)
        #expect(model.breadcrumb.map(\.lastPathComponent) == ["Disk", "System", "Volumes"])
        let volume = try item("Data")
        #expect(volume.isMountPoint && volume.size == nil && volume.viewOnly == .otherVolume && !model.canOpen(volume))
        model.go(to: 0)
        await settle(model)
        #expect(model.current == disk.standardizedFileURL && model.items.contains { $0.name == "opt" })

        model.start(at: disk.appending(path: "opt/tool"))
        await settle(model)
        #expect(model.breadcrumb.map(\.lastPathComponent) == ["Disk", "opt", "tool"])
        model.start(at: diskHome.appending(path: "Docs"))
        await settle(model)
        #expect(model.breadcrumb.map(\.lastPathComponent) == ["me", "Docs"]) // home keeps its own breadcrumb
    }

    /// Without Full Disk Access, measuring the disk's Users never enters this user's protected folders.
    @MainActor @Test func startupDiskSkipsProtectedFoldersWithoutFullDiskAccess() async throws {
        defer { try? fm.removeItem(at: root) }
        let model = try diskModel(fullDiskAccess: false)
        model.start(at: model.disk)
        await settle(model)
        #expect(model.skippedProtected)
        let users = try #require(model.items.first { $0.name == "Users" }?.size)
        #expect(users <= (try du(disk.appending(path: "Users"))) - 400_000)
    }

    /// Items of the home folder reached from the startup disk go to the Trash as in the home view; Undo puts them back.
    @MainActor @Test func homeItemsReachedFromTheDiskStillGoToTheTrash() async throws {
        defer { try? fm.removeItem(at: root) }
        let model = try diskModel()
        model.start(at: model.disk)
        await settle(model)
        model.open(disk.appending(path: "Users"))
        model.open(diskHome)
        model.open(diskHome.appending(path: "Docs"))
        await settle(model)
        #expect(model.breadcrumb.map(\.lastPathComponent) == ["Disk", "Users", "me", "Docs"])
        let file = try #require(model.items.first { $0.name == "a.txt" })
        #expect(file.viewOnly == nil)
        let policy = SafetyPolicy(home: diskHome, temp: root.appending(path: "tmp"), mounts: { ["/"] }, volumesFolder: volumes.path)
        #expect(policy.allowsSpaceLensItem(file.url))
        for refused in ["Library/Caches/c.bin", "Users/bob/notes.txt", "opt/tool/bin/run", "Users/me"] {
            #expect(!policy.allowsSpaceLensItem(disk.appending(path: refused)), "\(refused)")
        }
        let trash = root.appending(path: "Trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let report = await SpaceLens.trash([file], policy: policy, trash: { url in
            let target = trash.appending(path: url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        })
        #expect(report.trashed.map(\.original) == [file.url] && !fm.fileExists(atPath: file.url.path))
        let result = await TrashUndo.restore(report.trashed, module: "Space Lens", home: diskHome)
        #expect(result == TrashUndo.Result(restored: 1, skipped: 0) && fm.fileExists(atPath: file.url.path))
    }

    /// The real /System is flagged by System Integrity Protection (when SIP is on), read from the listing's lstat.
    @Test func restrictedItemsAreSystemIntegrityProtected() async throws {
        var info = stat()
        #expect(lstat("/System", &info) == 0)
        let system = try #require(await SpaceLens.list(URL(fileURLWithPath: "/")).first { $0.name == "System" })
        #expect(system.isRestricted == (info.st_flags & UInt32(SF_RESTRICTED) != 0))
        var flagged = SpaceItem(url: URL(fileURLWithPath: "/usr/bin"), isFolder: true)
        flagged.isRestricted = true
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(SpaceLens.viewOnly(flagged, home: home, disk: URL(fileURLWithPath: "/")) == .systemIntegrity)
        #expect(SpaceLens.viewOnly(SpaceItem(url: URL(fileURLWithPath: "/Users"), isFolder: true), home: home, disk: URL(fileURLWithPath: "/")) == .holdsHome)
        #expect(SpaceLens.viewOnly(SpaceItem(url: home.appending(path: "x"), isFolder: true), home: home, disk: URL(fileURLWithPath: "/")) == nil)
    }

    /// Show Hidden Files off: hidden items leave the table and get no slice of their own, but stay in the total.
    @MainActor @Test func hiddenItemsStayInTheTotalWhenHidden() async throws {
        defer { try? fm.removeItem(at: root) }
        let model = try diskModel()
        model.start(at: model.disk)
        await settle(model)
        let total = model.total
        model.showsHidden = false
        #expect(!model.shown.contains { $0.isHidden } && model.shown.count < model.items.count && model.total == total)
        let slices = SpaceLens.slices(model.items, showsHidden: false)
        #expect(slices.allSatisfy { $0.item?.isHidden != true })
        #expect(slices.reduce(0) { $0 + $1.size } == model.items.reduce(0) { $0 + ($1.size ?? 0) })
        model.showsHidden = true
        #expect(model.shown.contains { $0.name == ".hidden.bin" })
    }
}

