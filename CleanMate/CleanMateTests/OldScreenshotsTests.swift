import Foundation
import Testing
@testable import CleanMate

/// Old screenshots: a fake home in a throwaway folder and a fake Trash; the real Desktop is never read.
final class OldScreenshotsTests {
    let fm = FileManager.default
    let root = TestTemp.url("CleanMateScreenshots")
    var home: URL { root.appending(path: "home") }
    var desktop: URL { home.appending(path: "Desktop") }
    var trash: URL { root.appending(path: "Trash") }
    let old = Date.now.addingTimeInterval(-100 * 86_400)
    let recent = Date.now.addingTimeInterval(-5 * 86_400)

    deinit { try? FileManager.default.removeItem(at: root) }

    func policy(excluded: [String] = []) -> SafetyPolicy {
        SafetyPolicy(home: home, temp: root.appending(path: "tmp"), excluded: excluded)
    }

    static func items(fda: Bool = true, folder: String? = OldScreenshots.defaultFolder) -> [CleanerItem] {
        CleanerGroup.smartScan(ages: .default, hasFullDiskAccess: fda, screenshotFolder: folder).flatMap(\.items)
    }

    static func item(_ id: String = OldScreenshots.id, folder: String? = OldScreenshots.defaultFolder) -> CleanerItem? {
        items(folder: folder).first { $0.id == id }
    }

    /// A file in `folder` (Desktop by default), every date `date` (old by default), with the Screenshot app's attribute
    /// when `captured`.
    @discardableResult
    func write(_ name: String, in folder: URL? = nil, date: Date? = nil, captured: Bool = false, bytes: Int = 4096) throws -> URL {
        let url = (folder ?? desktop).appending(path: name)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
        if captured {
            let value = try PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
            let result = value.withUnsafeBytes {
                setxattr(url.path, OldScreenshots.screenCaptureAttribute, $0.baseAddress, value.count, 0, XATTR_NOFOLLOW)
            }
            try #require(result == 0)
        }
        let date = date ?? old
        try OldDownloadsTests.stamp(url, modified: date, read: date, created: date, added: date)
        return url
    }

    func listed(_ item: CleanerItem, excluded: [String] = []) async -> Set<String> {
        Set(await Scanner.scan(item, policy: policy(excluded: excluded), openPaths: EndToEndCleanTests.ownOpenPaths)
            .entries.map(\.url.lastPathComponent))
    }

    /// Lays out every case on the Desktop; returns the names that must be listed.
    func makeDesktop() throws -> Set<String> {
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        try write("IMG_0001.png", captured: true) // renamed, but the attribute says screenshot
        try write("fresh.png", date: recent, captured: true)
        try write("Screenshot 2024-01-01 at 10.00.00.png") // no attribute (copied from another Mac)
        try write("Screen Recording 2024-01-02 at 09.00.00.mov")
        try write("Ảnh màn hình 2024-01-03 lúc 08.00.00.png".decomposedStringWithCanonicalMapping) // as APFS may store it
        try write("CleanShot 2024-01-04 at 07.00.00@2x.png")
        try write("report.png") // old, but not a screenshot
        try write("Screenshot notes.txt") // a screenshot name, not an image or movie
        try write(".Screenshot hidden.png", captured: true)
        let opened = try write("Screenshot opened.png") // opened lately
        try OldDownloadsTests.stamp(opened, modified: old, read: recent, created: old, added: old)
        try write("Shots/Screenshot inside a folder.png") // not at the top level
        try fm.createDirectory(at: desktop.appending(path: "Screenshot folder.png"), withIntermediateDirectories: true)
        let elsewhere = try write("Screenshot elsewhere.png", in: root)
        try fm.createSymbolicLink(at: desktop.appending(path: "Screenshot link.png"), withDestinationURL: elsewhere)
        return ["IMG_0001.png", "Screenshot 2024-01-01 at 10.00.00.png", "Screen Recording 2024-01-02 at 09.00.00.mov",
                "Ảnh màn hình 2024-01-03 lúc 08.00.00.png".decomposedStringWithCanonicalMapping,
                "CleanShot 2024-01-04 at 07.00.00@2x.png"]
    }

    @Test func onlyWithFullDiskAccessUntickedToTheTrash() throws {
        #expect(!Self.items(fda: false).contains { $0.id == OldScreenshots.id }) // reading Desktop makes macOS ask
        let item = try #require(Self.item())
        #expect(item.paths == ["~/Desktop"] && item.mode == .trash && !item.selectedByDefault && item.selectableEntries)
        #expect(item.skipsOpenFiles && !item.showsWhenEmpty && item.minAge == 90 * 86_400 && item.entryLabel != nil)
        let ids = Self.items().map(\.id)
        #expect(ids.firstIndex(of: OldScreenshots.id) == ids.firstIndex(of: "old-downloads").map { $0 + 1 })
        #expect(Self.item(folder: nil) == nil)
    }

    @Test func readsTheSaveFolder() {
        let home = "/Users/ann"
        #expect(OldScreenshots.folder(location: nil, home: home) == "~/Desktop")
        #expect(OldScreenshots.folder(location: " ", home: home) == "~/Desktop")
        #expect(OldScreenshots.folder(location: "/Users/ann/Pictures/Screenshots/", home: home) == "~/Pictures/Screenshots")
        #expect(OldScreenshots.folder(location: "~/Downloads", home: home) == "~/Downloads")
        #expect(OldScreenshots.folder(location: "/Users/ann", home: home) == nil)
        #expect(OldScreenshots.folder(location: "/Volumes/Shots", home: home) == nil)
        #expect(OldScreenshots.folder(location: "/Users/ann/../bob/Desktop", home: home) == nil)
    }

    /// Screenshots by attribute or by name, old all through, at the top level: each listed with its name and date.
    @Test func listsOnlyOldScreenshots() async throws {
        let expected = try makeDesktop()
        let item = try #require(Self.item())
        let scan = await Scanner.scan(item, policy: policy(), openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(Set(scan.entries.map(\.url.lastPathComponent)) == expected)
        #expect(scan.entries.allSatisfy { $0.title == $0.url.lastPathComponent && $0.date.map { $0 < recent } == true })
        // A file in Exclusions is left out.
        let excluded = desktop.appending(path: "IMG_0001.png").path
        #expect(await listed(item, excluded: [excluded]) == expected.subtracting(["IMG_0001.png"]))
    }

    @Test func savedElsewhere() async throws {
        let shots = home.appending(path: "Pictures/Screenshots")
        try write("Screenshot 1.png", in: shots)
        try write("Screenshot 2.png") // Desktop: not where screenshots go now
        let item = try #require(Self.item(folder: "~/Pictures/Screenshots"))
        #expect(await listed(item) == ["Screenshot 1.png"])
        // A save folder reached through a symlink lists nothing.
        try fm.moveItem(at: shots, to: root.appending(path: "Shots"))
        try fm.createSymbolicLink(at: shots, withDestinationURL: root.appending(path: "Shots"))
        #expect(await listed(item).isEmpty)
    }

    /// Screenshots saved in Downloads are listed here only, and a Downloads folder holding the save folder stays there.
    @Test func neverCountedTwiceWithOldDownloads() async throws {
        let downloads = home.appending(path: "Downloads")
        try write("Screenshot 1.png", in: downloads)
        try write("notes.txt", in: downloads)
        let shots = try #require(Self.item(folder: "~/Downloads"))
        let others = try #require(Self.item("old-downloads", folder: "~/Downloads"))
        #expect(await listed(shots) == ["Screenshot 1.png"])
        #expect(await listed(others) == ["notes.txt"])
        // Saved desktop-side: Downloads lists it again, as any old download.
        #expect(await listed(try #require(Self.item("old-downloads"))) == ["Screenshot 1.png", "notes.txt"])

        let inner = downloads.appending(path: "Captures")
        try write("Screenshot 2.png", in: inner)
        try OldDownloadsTests.stamp(inner, modified: old, read: old, created: old, added: old)
        #expect(await listed(try #require(Self.item("old-downloads", folder: "~/Downloads/Captures/2024"))) == ["notes.txt", "Screenshot 1.png"])
        #expect(await listed(try #require(Self.item("old-downloads"))).contains("Captures"))
    }

    /// Smart Scan: never ticked; once ticked, to the Trash, and ⌘Z puts it all back.
    @MainActor @Test func cleanMovesToTheTrashAndUndoPutsBack() async throws {
        let expected = try makeDesktop()
        let item = try #require(Self.item())
        let policy = policy(), home = home, trash = trash
        let moveToFakeTrash: @Sendable (URL) throws -> URL? = { url in
            let target = trash.appending(path: UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }
        let model = SmartScanModel(module: .smartScan) { [CleanerGroup(id: "g", title: "G", systemImage: "x", items: [item])] }
        model.processNames = { [] }
        model.appBundleIDs = { [] }
        model.blockedByExclusion = { _ in false }
        model.readOpenFiles = EndToEndCleanTests.ownOpenPaths
        model.scanItem = { await Scanner.scan($0, policy: policy, openPaths: $1) }
        model.cleanItem = { item, scan, openPaths in
            await Cleaner.clean(item, scan: scan, policy: policy, trash: moveToFakeTrash, openPaths: openPaths)
        }
        model.restore = { items, logName in await TrashUndo.restore(items, module: "Smart Scan", home: home, logName: logName) }
        model.logHome = home
        model.freeSpace = { nil }
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo

        await model.scan()
        #expect(model.selected.isEmpty) // never ticked by default
        let before = try Set(fm.contentsOfDirectory(atPath: desktop.path))
        model.selected = [item.id]
        undo.beginUndoGrouping()
        await model.clean()
        undo.endUndoGrouping()
        guard case .done(let report) = model.phase else { Issue.record("phase \(model.phase)"); return }
        #expect(Set(report.trashed.map(\.original.lastPathComponent)) == expected && report.skipped == 0)
        #expect(try Set(fm.contentsOfDirectory(atPath: desktop.path)) == before.subtracting(expected))

        undo.undo() // ⌘Z
        func restored() -> Bool {
            guard case .done(let report) = model.phase else { return false }
            return report.undo != nil && !model.undoing
        }
        for _ in 0..<5000 where !restored() { try? await Task.sleep(for: .milliseconds(2)) }
        guard case .done(let after) = model.phase else { Issue.record("phase \(model.phase)"); return }
        #expect(after.undo == TrashUndo.Result(restored: expected.count, skipped: 0))
        #expect(try Set(fm.contentsOfDirectory(atPath: desktop.path)) == before)
    }

    /// Opened after the scan: kept at clean.
    @Test func openedAfterTheScanIsKept() async throws {
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let file = try write("Screenshot 1.png")
        let item = try #require(Self.item())
        let found = await Scanner.scan(item, policy: policy(), openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(found.entries.count == 1)
        try OldDownloadsTests.stamp(file, modified: old, read: .now, created: old, added: old)
        let trash = trash
        let report = await Cleaner.clean(item, scan: found, policy: policy(), trash: { url in
            let target = trash.appending(path: url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }, openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(report.skipped == 1 && report.trashed.isEmpty)
    }
}
