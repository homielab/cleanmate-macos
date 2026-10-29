import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import CleanMate

/// Space Lens runs against a throwaway fake home; nothing is ever moved to the real Trash.
/// The `settle()` waits are unbounded, so a hang fails the test after the limit instead of stalling the run.
@Suite(.timeLimit(.minutes(2)))
struct SpaceLensTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "CleanMateSpaceLens-\(UUID().uuidString)")
    var home: URL { root.appending(path: "home") }
    var policy: SafetyPolicy { SafetyPolicy(home: home, temp: root.appending(path: "tmp")) }

    @discardableResult
    func file(_ path: String, bytes: Int = 20_000) throws -> URL {
        let url = home.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
        return url
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

    @Test func measureMatchesDuWithoutFollowingSymlinksOrDoubleCountingHardLinks() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try file("Projects/a/big.bin", bytes: 3_000_000)
        try file("Projects/a/b/c.txt")
        try file("Projects/.hidden/x", bytes: 100_000)
        let outside = try file("Outside/huge.bin", bytes: 8_000_000)
        let fm = FileManager.default
        try fm.createSymbolicLink(at: home.appending(path: "Projects/link.bin"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: home.appending(path: "Projects/linkdir"), withDestinationURL: outside.deletingLastPathComponent())
        try fm.linkItem(at: home.appending(path: "Projects/a/big.bin"), to: home.appending(path: "Projects/hard.bin"))

        let projects = home.appending(path: "Projects")
        let result = try await SpaceLens.measure(projects)
        #expect(result.size == (try du(projects)))
        #expect(result.size > 3_000_000 && result.size < 4_000_000) // hard link once, symlinks not followed
        #expect(result.folders[projects.appending(path: "a").path] == nil) // holds a hard-linked file
        #expect(result.folders[projects.appending(path: "a/b").path] == nil) // too small to remember
        try file("Projects/c/plain.bin", bytes: 2_000_000)
        let plain = try await SpaceLens.measure(projects).folders[projects.appending(path: "c").path]
        #expect(plain == (try du(projects.appending(path: "c"))))
    }

    /// A/{x,y}/s share a hard-linked file: viewing A counts it under one of them only, but after drilling into x or
    /// y every child shows its own `du -s` (the link counts in each listing, never a size remembered from A's).
    @MainActor @Test func drillingIntoFoldersSharingAHardLinkMatchesDu() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let big = try file("A/x/s/big.bin", bytes: 3_000_000)
        try file("A/x/s/own.bin", bytes: 2_000_000)
        try file("A/y/s/own.bin", bytes: 2_000_000)
        try FileManager.default.linkItem(at: big, to: home.appending(path: "A/y/s/big.bin"))
        let model = SpaceLensModel()
        model.hasFullDiskAccess = { true }
        func settle() async throws { while model.measuring { try await Task.sleep(for: .milliseconds(5)) } }
        model.start(at: home.appending(path: "A"))
        try await settle()
        #expect(model.total > 7_000_000 && model.total < 8_000_000) // the link once in A's listing
        for name in ["x", "y"] {
            model.go(to: 0)
            model.open(home.appending(path: "A/\(name)"))
            try await settle()
            let s = try #require(model.items.first { $0.name == "s" })
            #expect(s.size == (try du(s.url)), "\(name)/s")
        }
    }

    /// Going back to a folder already listed reuses its children's sizes, hard-linked ones included, without measuring
    /// again; Refresh, a clean by another module and a change in access measure again.
    @MainActor @Test func goingBackReusesTheListingAndRefreshMeasuresAgain() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let big = try file("A/x/s/big.bin", bytes: 3_000_000)
        try file("A/y/s/own.bin", bytes: 2_000_000)
        try FileManager.default.linkItem(at: big, to: home.appending(path: "A/y/s/big.bin"))
        let calls = Counter()
        let model = SpaceLensModel(center: NotificationCenter())
        var access = true
        model.hasFullDiskAccess = { access }
        model.measure = { calls.add(); return try await SpaceLens.measure($0, links: $1, skipping: $2) }
        func settle() async throws { while model.measuring { try await Task.sleep(for: .milliseconds(5)) } }
        model.start(at: home.appending(path: "A"))
        try await settle()
        let before = model.items.map(\.size)
        #expect(calls.value == 2 && model.total > 5_000_000)
        model.open(home.appending(path: "A/x"))
        try await settle()
        model.go(to: 0)
        #expect(calls.value == 3)
        try await settle()
        #expect(calls.value == 3); #expect(model.items.map(\.size) == before) // no measuring: same sizes at once
        model.rescan()
        try await settle()
        #expect(calls.value == 5)
        model.invalidate()
        model.startIfNeeded()
        try await settle()
        #expect(calls.value == 7)
        access = false // the skipped set changes
        model.go(to: 0)
        try await settle()
        #expect(calls.value == 9)
    }

    /// Another module cleaning while a listing is still measuring: that listing's sizes are not remembered.
    @MainActor @Test func listingMeasuredBeforeAnotherModuleCleanedIsNotRemembered() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try file("A/x/big.bin", bytes: 2_000_000)
        try file("A/y/big.bin", bytes: 2_000_000)
        let calls = Counter(), gate = Counter()
        let model = SpaceLensModel(center: NotificationCenter())
        model.hasFullDiskAccess = { true }
        model.measure = {
            calls.add()
            while gate.value == 0 { try await Task.sleep(for: .milliseconds(5)) }
            return try await SpaceLens.measure($0, links: $1, skipping: $2)
        }
        func settle() async throws { while model.measuring { try await Task.sleep(for: .milliseconds(5)) } }
        model.start(at: home.appending(path: "A"))
        while calls.value < 2 { try await Task.sleep(for: .milliseconds(5)) }
        model.invalidate() // e.g. Large Files moved a file to the Trash meanwhile
        gate.add()
        try await settle()
        #expect(model.total > 4_000_000) // still shown
        model.go(to: 0)
        try await settle()
        #expect(calls.value == 4) // measured again, not answered from the old listing
    }

    /// A folder inside home opens with every parent in the breadcrumb, so it can go up; a locked parent (no Full Disk
    /// Access) keeps the old behaviour: the folder opens alone.
    @MainActor @Test func folderInsideHomeOpensWithTheFullBreadcrumb() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try file("a/b/c/f.bin")
        try file("a/other/g.bin")
        try file("Documents/x/y/h.bin")
        let measured = Names()
        let model = SpaceLensModel(center: NotificationCenter())
        model.home = home
        var access = true
        model.hasFullDiskAccess = { access }
        model.measure = { url, links, skipping in
            measured.add(url.lastPathComponent)
            return try await SpaceLens.measure(url, links: links, skipping: skipping)
        }
        func settle() async throws { while model.measuring { try await Task.sleep(for: .milliseconds(5)) } }
        model.start(at: home.appending(path: "a/b/c"))
        try await settle()
        #expect(model.breadcrumb.map(\.lastPathComponent) == ["home", "a", "b", "c"])
        #expect(model.current.standardizedFileURL.path == home.appending(path: "a/b/c").standardizedFileURL.path)
        model.go(to: 1)
        try await settle()
        #expect(model.current.lastPathComponent == "a" && model.breadcrumb.count == 2)
        #expect(measured.value.isSuperset(of: ["b", "other"]))
        access = false
        model.start(at: home.appending(path: "Documents/x/y"))
        #expect(model.path.isEmpty && model.root.lastPathComponent == "y")
        try await settle()
    }

    @MainActor @Test func revealOpensTheItemsFolderLikeChooseFolderAndReusesSizes() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let big = try file("A/x/big.bin", bytes: 1_000_000)
        try file("A/y/own.bin", bytes: 2_000)
        let calls = Counter()
        let model = SpaceLensModel(center: NotificationCenter())
        model.hasFullDiskAccess = { true }
        model.measure = { calls.add(); return try await SpaceLens.measure($0, links: $1, skipping: $2) }
        func settle() async throws { while model.measuring { try await Task.sleep(for: .milliseconds(5)) } }
        model.start(at: home.appending(path: "A"))
        try await settle()
        #expect(calls.value == 2)
        model.reveal(home.appending(path: "A/x")) // a folder: its parent A, listing remembered
        try await settle()
        #expect(model.current.path == home.appending(path: "A").path && model.path.isEmpty)
        #expect(calls.value == 2 && model.revealed?.lastPathComponent == "x")
        model.reveal(big)
        try await settle()
        #expect(model.current.path == home.appending(path: "A/x").path)
        #expect(model.revealed == big && model.items.contains { $0.url.standardizedFileURL == big.standardizedFileURL })
        model.open(home.appending(path: "A/x")) // navigating on drops the pending selection
        #expect(model.revealed == nil)
        model.invalidate() // another module cleaned: reveal measures afresh, showing the module does not measure twice
        model.reveal(home.appending(path: "A/y"))
        model.startIfNeeded()
        try await settle()
        #expect(calls.value == 4)
    }

    @Test func hardLinkSharedBySiblingsCountsOnce() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try file("Parent/a/big.bin", bytes: 2_000_000)
        try file("Parent/b/x.txt")
        try FileManager.default.linkItem(at: original, to: home.appending(path: "Parent/b/same.bin"))
        try FileManager.default.linkItem(at: original, to: home.appending(path: "Parent/same.bin"))

        let parent = home.appending(path: "Parent")
        let links = SpaceLens.HardLinks()
        let items = await SpaceLens.list(parent, links: links)
        var total = items.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        for item in items where item.isFolder {
            total += try await SpaceLens.measure(item.url, links: links).size
        }
        var info = stat()
        lstat(parent.path, &info) // the parent folder's own blocks are not one of its children
        #expect(total + Int64(info.st_blocks) * 512 == (try du(parent)))
        #expect(total > 2_000_000 && total < 3_000_000)
    }

    /// Reading folders in parallel gives exactly the serial `fts` result: total, remembered folders, hard links
    /// once (also across parallel subtrees), symlinks not followed, unreadable and skipped folders count their own entry.
    @Test func parallelMeasureMatchesTheSerialWalk() async throws {
        let tree = home.appending(path: "Tree")
        let locked = tree.appending(path: "a/locked")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: root)
        }
        for path in ["Tree/a/b/c/d/e/f/g/big.bin", "Tree/a/b/plain/big.bin", "Tree/x/w/v/big.bin", "Tree/a/b/y/z/w.txt", "Tree/top.bin"] {
            try file(path, bytes: 1_200_000)
        }
        let shared = try file("Tree/a/b/c/d/e/shared.bin", bytes: 1_500_000)
        try FileManager.default.linkItem(at: shared, to: home.appending(path: "Tree/x/shared.bin"))
        try FileManager.default.linkItem(at: shared, to: home.appending(path: "Tree/a/b/y/z/shared.bin"))
        for index in 0..<30 { try file("Tree/a/b/c/many/\(index).txt", bytes: 5_000) }
        try file("Tree/a/locked/hidden.bin", bytes: 2_000_000)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        try file("Tree/x/skipped/inside.bin", bytes: 2_000_000)
        try FileManager.default.createSymbolicLink(at: home.appending(path: "Tree/x/w/link"), withDestinationURL: home.appending(path: "Tree/a"))
        let skipping: Set = [tree.appending(path: "x/skipped").path]

        let serial = try await SpaceLens.measure(tree, skipping: skipping, splitDepth: 0)
        #expect(serial.size > 7_500_000 && serial.size < 8_500_000) // shared once; locked/skipped/link contents not counted
        #expect(serial.folders[tree.appending(path: "a/b/plain").path] != nil && serial.folders[tree.appending(path: "x").path] == nil)
        for depth in [1, 2, 3, 6] {
            let parallel = try await SpaceLens.measure(tree, skipping: skipping, splitDepth: depth)
            #expect(parallel.size == serial.size && parallel.folders == serial.folders, "splitDepth \(depth)")
        }
        #expect(try await SpaceLens.measure(tree, skipping: skipping).size == serial.size) // automatic: small tree → serial
    }

    @Test func listsChildrenWithFileSizesAndFoldersToMeasure() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try file("Folder/x.bin", bytes: 50_000)
        try file(".hidden", bytes: 10_000)
        try FileManager.default.createSymbolicLink(at: home.appending(path: "link"), withDestinationURL: home.appending(path: "Folder"))
        let items = await SpaceLens.list(home)
        #expect(Set(items.map(\.name)) == ["Folder", ".hidden", "link"])
        #expect(items.first { $0.name == "Folder" }?.isFolder == true && items.first { $0.name == "Folder" }?.size == nil)
        #expect(items.first { $0.name == "link" }?.isFolder == false) // symlink: not a folder to open
        #expect((items.first { $0.name == ".hidden" }?.size ?? 0) >= 10_000)
    }

    @Test func spaceLensPolicyAllowsUserItemsButNotTopLevelFoldersLibraryHiddenPackagesOrOutsideHome() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["Documents/Old/a.mov", "Developer/proj/x", "Downloads/d.dmg", "f.pkg", "Applications/Foo.app/Contents/x"] {
            try file(path)
        }
        for path in ["Documents/Old", "Developer/proj", "Downloads/d.dmg", "Documents/Old/a.mov", "f.pkg", "Applications/Foo.app"] {
            #expect(policy.allowsSpaceLensItem(home.appending(path: path)), "\(path)")
        }
        for path in [".ssh/id_rsa", "Library/Caches/x", "Documents/.git/pack", "Applications/Foo.app/Contents/x"] {
            try file(path)
        }
        let link = home.appending(path: "Documents/link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home.appending(path: "Documents/Old"))
        for url in ["Documents", "Developer", "Downloads", "Library", "Library/Caches/x", ".ssh", ".ssh/id_rsa",
                    "Documents/.git", "Applications/Foo.app/Contents", "Documents/link"].map({ home.appending(path: $0) })
            + [home, root.appending(path: "tmp/x"), URL(fileURLWithPath: "/Applications/Safari.app"), URL(fileURLWithPath: "/etc")] {
            #expect(!policy.allowsSpaceLensItem(url), "\(url.path)")
        }
    }

    @Test func allowedSpaceLensItemsKeepsOnlyWhatThePolicyAllows() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try file("Documents/a.mov")
        let ok = home.appending(path: "Documents/a.mov")
        #expect(policy.allowedSpaceLensItems([ok, home.appending(path: "Documents"), URL(fileURLWithPath: "/etc")]) == [ok])
    }

    @Test func trashRefusesItemsThePolicyBlocks() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = home.appending(path: "Documents")
        try file("Documents/a.txt")
        let report = await SpaceLens.trash([SpaceItem(url: documents, isFolder: true, size: 1)], policy: policy)
        #expect(report.skipped == 1 && report.freed == 0)
        #expect(FileManager.default.fileExists(atPath: documents.path))
    }

    @Test func itemsOnAnotherVolumeMountedInHomeAreNeverTrashed() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let inside = try file("Mounted/share/a.mov")
        let local = try file("Developer/b.mov")
        // Tests can't mount: "Mounted" and everything under it is reported on another device.
        let policy = SafetyPolicy(home: home, temp: root.appending(path: "tmp")) { path in
            path.contains("/Mounted") ? 99 : SafetyPolicy.deviceID(path)
        }
        for url in [home.appending(path: "Mounted"), home.appending(path: "Mounted/share"), inside] {
            #expect(!policy.allowsSpaceLensItem(url), "\(url.path)")
        }
        #expect(!policy.allowsUserFile(inside))
        #expect(policy.allowsSpaceLensItem(local) && policy.allowsUserFile(local))
        let report = await SpaceLens.trash([SpaceItem(url: inside, isFolder: false, size: 1)], policy: policy)
        #expect(report.skipped == 1 && report.freed == 0)
        #expect(FileManager.default.fileExists(atPath: inside.path))
    }

    @Test func foldersHoldingAMountPointAreNeverTrashed() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try file("Projects/parent/sub/note.txt")
        let other = try file("Projects/other/b.txt")
        // A real trashItem of `parent` moves the volume mounted on `sub/mnt` along with it.
        let mount = home.appending(path: "Projects/parent/sub/mnt").path
        let policy = SafetyPolicy(home: home, temp: root.appending(path: "tmp"), mounts: { ["/", mount.uppercased()] })
        for url in [home.appending(path: "Projects"), home.appending(path: "Projects/parent"), note.deletingLastPathComponent()] {
            #expect(!policy.allowsSpaceLensItem(url) && !policy.allows(url), "\(url.path)")
        }
        #expect(policy.allowsSpaceLensItem(note) && policy.allowsUserFile(note))
        #expect(policy.allowsSpaceLensItem(other.deletingLastPathComponent()))
        let report = await SpaceLens.trash([SpaceItem(url: home.appending(path: "Projects/parent"), isFolder: true, size: 1)],
                                           policy: policy)
        #expect(report.skipped == 1 && report.freed == 0)
        #expect(FileManager.default.fileExists(atPath: note.path))
    }

    @Test func withoutFullDiskAccessProtectedFoldersAreNotEntered() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try file("Library/Containers/com.example/big.bin", bytes: 3_000_000)
        try file("Library/Caches/x.bin", bytes: 50_000)
        let skipping = ProtectedFolders.skipped(home: home, hasFullDiskAccess: false)
        #expect(ProtectedFolders.skips(skipping, inside: home) && ProtectedFolders.skips(skipping, inside: home.appending(path: "Library")))
        #expect(!ProtectedFolders.skips(skipping, inside: home.appending(path: "Library/Caches")))
        #expect(!ProtectedFolders.skips(ProtectedFolders.skipped(home: home, hasFullDiskAccess: true), inside: home))
        let library = home.appending(path: "Library")
        let skipped = try await SpaceLens.measure(library, skipping: skipping).size
        #expect(skipped >= 50_000 && skipped < 1_000_000)
        #expect(try await SpaceLens.measure(library).size == (try du(library)))
    }

    @Test @MainActor func volumeLevelThresholds() {
        func level(_ free: Int64) -> SpaceLensModel.Volume.Level { SpaceLensModel.Volume(name: "", total: 100, available: free).level }
        #expect(level(50) == .normal)
        #expect(level(10) == .normal)
        #expect(level(9) == .low)
        #expect(level(5) == .low)
        #expect(level(4) == .critical)
        #expect(SpaceLensModel.Volume().level == .normal)
    }

    @Test func donutSlicesKeepTopEightAndGroupTheRest() {
        func item(_ name: String, _ size: Int64?) -> SpaceItem {
            SpaceItem(url: URL(fileURLWithPath: "/x/\(name)"), isFolder: true, size: size)
        }
        // 12 measured (sizes 1…12), one unmeasured, one empty.
        let items = (1...12).map { item("f\($0)", Int64($0)) } + [item("pending", nil), item("empty", 0)]
        let slices = SpaceLens.slices(items)
        #expect(slices.count == 9)
        #expect(slices.prefix(8).map(\.size) == [12, 11, 10, 9, 8, 7, 6, 5])
        #expect(slices.last?.item == nil && slices.last?.size == 1 + 2 + 3 + 4)
        #expect(slices.reduce(0) { $0 + $1.size } == (1...12).reduce(0, +))
        // Nine items: the ninth is shown itself, not as a one-item "Other".
        #expect(SpaceLens.slices(Array(items.prefix(9))).allSatisfy { $0.item != nil })
        #expect(SpaceLens.slices([item("pending", nil)]).isEmpty)
        // The hovered slice is kept by id: a size arriving later changes the slice, not its id.
        var grown = items
        grown[12].size = 3
        let later = SpaceLens.slices(grown)
        #expect(later.last != slices.last && later.last?.id == slices.last?.id)
        #expect(later.first?.id == slices.first?.id)
        // Every own slice (up to top + 1, when no "Other") gets a distinct color, or two neighbors would look alike.
        #expect(SpaceLensView.colors.count >= SpaceLens.top + 1)
        #expect(Set(SpaceLensView.colors).count == SpaceLensView.colors.count)
    }

    @Test func donutHitTestByAngleInsideRing() {
        func slice(_ name: String, _ size: Int64) -> SpaceLens.Slice {
            SpaceLens.Slice(item: SpaceItem(url: URL(fileURLWithPath: "/x/\(name)"), isFolder: true, size: size), size: size)
        }
        // Quarters clockwise from 12 o'clock: a (0–90°), b (90–180°), c+d (180–360°, c first half).
        let slices = [slice("a", 1), slice("b", 1), slice("c", 1), slice("d", 1)]
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100) // center (50,50), radius 50, ring 30…50
        func hit(_ x: Double, _ y: Double) -> String? { SpaceLens.slice(at: CGPoint(x: x, y: y), in: frame, of: slices)?.item?.name }
        #expect(hit(70, 10) == "a")  // upper right (y grows downward)
        #expect(hit(90, 70) == "b")  // lower right
        #expect(hit(30, 90) == "c")  // lower left
        #expect(hit(10, 30) == "d")  // upper left
        #expect(hit(50, 5) == "a")   // straight up: angle 0 is the start of the first slice
        #expect(hit(95, 50) == "a")  // exactly 90°: boundary belongs to the slice ending there
        #expect(hit(49.9, 5) == "d") // just left of 12 o'clock: the last slice
        #expect(hit(50, 50) == nil)  // center hole
        #expect(hit(50, 25) == nil)  // inside the hole, just short of the ring (radius 25 < 30)
        #expect(hit(50, 20) == "a")  // inner edge of the ring (radius 30)
        #expect(hit(50, 0) == "a")   // outer edge (radius 50)
        #expect(hit(2, 2) == nil)    // frame corner, outside the circle
        #expect(SpaceLens.slice(at: CGPoint(x: 50, y: 5), in: frame, of: []) == nil)
        // Uneven sizes: a is 3/4 of the ring.
        let uneven = [slice("a", 3), slice("b", 1)]
        #expect(SpaceLens.slice(at: CGPoint(x: 30, y: 90), in: frame, of: uneven)?.item?.name == "a")
        #expect(SpaceLens.slice(at: CGPoint(x: 10, y: 30), in: frame, of: uneven)?.item?.name == "b")
    }

    /// The stacked bar drawn instead of the donut on macOS 13: slices left to right by share.
    @Test func barHitTestByFraction() {
        func slice(_ name: String, _ size: Int64) -> SpaceLens.Slice {
            SpaceLens.Slice(item: SpaceItem(url: URL(fileURLWithPath: "/x/\(name)"), isFolder: true, size: size), size: size)
        }
        let slices = [slice("a", 3), slice("b", 1)]
        func hit(_ fraction: Double) -> String? { SpaceLens.slice(atFraction: fraction, of: slices)?.item?.name }
        #expect(hit(0) == "a")
        #expect(hit(0.75) == "a") // boundary belongs to the slice ending there
        #expect(hit(0.76) == "b")
        #expect(hit(1) == "b")
        #expect(hit(-0.01) == nil && hit(1.01) == nil)
        #expect(SpaceLens.slice(atFraction: 0.5, of: []) == nil)
    }

    /// After a trash the selection drops what is gone, and an empty pick keeps the real report.
    @MainActor @Test func trashPrunesSelectionAndEmptyPickKeepsReport() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try file("A/a.bin"), b = try file("A/b.bin")
        let model = SpaceLensModel()
        model.hasFullDiskAccess = { true }
        var calls = 0
        // Stands in for the Trash: removes the throwaway file only, never touches the real Trash.
        model.trashItems = { items in
            calls += 1
            for item in items { try? FileManager.default.removeItem(at: item.url) }
            return CleanReport(freed: 20_000)
        }
        func settle() async throws { while model.measuring { try await Task.sleep(for: .milliseconds(5)) } }
        model.start(at: home.appending(path: "A"))
        try await settle()
        let selection: Set<URL> = [a, b]
        #expect(model.pruned(selection) == selection)
        await model.trash(model.items.filter { $0.url == a })
        try await settle()
        #expect(model.pruned(selection) == [b])
        #expect(model.report?.freed == 20_000)
        await model.trash([])
        #expect(calls == 1 && model.report?.freed == 20_000)
    }

    /// ⌘R behind the confirmation: while the folder is measured again, a confirmed Trash moves nothing.
    @MainActor @Test func trashSkippedWhileMeasuring() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try file("A/a.bin")
        let model = SpaceLensModel()
        model.hasFullDiskAccess = { true }
        var calls = 0
        model.trashItems = { _ in calls += 1; return CleanReport(freed: 1) }
        func settle() async throws { while model.measuring { try await Task.sleep(for: .milliseconds(5)) } }
        model.start(at: home.appending(path: "A"))
        try await settle()
        let confirmed = model.items
        model.rescan()
        #expect(model.measuring)
        await model.trash(confirmed)
        #expect(calls == 0 && model.report == nil && !model.trashing)
        try await settle()
        await model.trash(model.items)
        #expect(calls == 1)
    }

    /// Search lists matching names only; a selected item hidden by the search is dropped and never trashed.
    @MainActor @Test func searchFiltersListingAndSelection() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try file("A/report.bin"), b = try file("A/photo.bin"), _ = try file("A/Sub/x.bin")
        let model = SpaceLensModel()
        model.hasFullDiskAccess = { true }
        var trashed: [URL] = []
        model.trashItems = { items in trashed += items.map(\.url); return CleanReport(freed: 0) }
        func settle() async throws { while model.measuring { try await Task.sleep(for: .milliseconds(5)) } }
        model.start(at: home.appending(path: "A"))
        try await settle()
        let total = model.total
        model.search = " REPORT "
        #expect(model.shown.map(\.url) == [a])
        #expect(model.total == total) // the donut/total keep the whole folder
        let selection = model.pruned([a, b])
        #expect(selection == [a])
        await model.trash(model.shown.filter { selection.contains($0.url) })
        #expect(trashed == [a])
        try await settle()
        model.search = "zzz"
        #expect(model.shown.isEmpty && !model.items.isEmpty)
        model.open(home.appending(path: "A/Sub"))
        #expect(model.search.isEmpty)
        try await settle()
        model.search = "x"
        model.go(to: 0)
        #expect(model.search.isEmpty)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}

private final class Names: @unchecked Sendable {
    private let lock = NSLock()
    private var names: Set<String> = []
    var value: Set<String> { lock.withLock { names } }
    func add(_ name: String) { lock.withLock { _ = names.insert(name) } }
}
