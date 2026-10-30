import Foundation
import Testing
@testable import CleanMate

/// Old downloads: a fake home in a throwaway folder and a fake Trash; the real ~/Downloads is never read.
final class OldDownloadsTests {
    let fm = FileManager.default
    let root = TestTemp.url("CleanMateDownloads")
    var home: URL { root.appending(path: "home") }
    var downloads: URL { home.appending(path: "Downloads") }
    var trash: URL { root.appending(path: "Trash") }
    var policy: SafetyPolicy { SafetyPolicy(home: home, temp: root.appending(path: "tmp")) }
    let old = Date.now.addingTimeInterval(-120 * 86_400)
    let recent = Date.now.addingTimeInterval(-86_400)

    deinit { try? FileManager.default.removeItem(at: root) }

    static func item(fda: Bool = true, ages: CleanupAges = .default) -> CleanerItem? {
        CleanerGroup.smartScan(ages: ages, hasFullDiskAccess: fda).flatMap(\.items).first { $0.id == "old-downloads" }
    }

    /// Sets every date of `url` (not following a symlink) to `old` unless given: modified, read, created and added
    /// to its folder.
    func stamp(_ url: URL, modified: Date? = nil, read: Date? = nil, created: Date? = nil, added: Date? = nil) throws {
        try Self.stamp(url, modified: modified ?? old, read: read ?? old, created: created ?? old, added: added ?? old)
    }

    static func stamp(_ url: URL, modified: Date, read: Date, created: Date, added: Date) throws {
        func spec(_ date: Date) -> timespec { timespec(tv_sec: Int(date.timeIntervalSince1970), tv_nsec: 0) }
        var times = [spec(read), spec(modified)]
        try #require(utimensat(AT_FDCWD, url.path, &times, AT_SYMLINK_NOFOLLOW) == 0)
        for (attribute, date) in [(ATTR_CMN_CRTIME, created), (ATTR_CMN_ADDEDTIME, added)] {
            var list = attrlist(bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0, commonattr: attrgroup_t(attribute),
                                volattr: 0, dirattr: 0, fileattr: 0, forkattr: 0)
            var value = spec(date)
            try #require(setattrlist(url.path, &list, &value, MemoryLayout<timespec>.size, UInt32(FSOPT_NOFOLLOW)) == 0)
        }
    }

    /// A file in Downloads, every date old unless given.
    @discardableResult
    func write(_ path: String, modified: Date? = nil, read: Date? = nil, created: Date? = nil, added: Date? = nil,
               bytes: Int = 4096) throws -> URL {
        let url = downloads.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
        try stamp(url, modified: modified, read: read, created: created, added: added)
        return url
    }

    /// A folder in Downloads holding `files` (each with the dates given, else old), the folder itself old.
    func folder(_ name: String, _ files: [String: Date?] = ["a.txt": nil], read: Date? = nil) throws {
        for (file, date) in files { try write(name + "/" + file, modified: date, read: read) }
        try stamp(downloads.appending(path: name))
    }

    /// A real zip made by `ditto` of `entries`, written to Downloads as `name`; read before its last change, so a
    /// read sets its access date.
    func zip(_ name: String, holding entries: [String]) throws {
        let staging = root.appending(path: "staging-\(name)")
        for entry in entries {
            let url = staging.appending(path: entry)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", staging.path, downloads.appending(path: name).path]
        try ditto.run()
        ditto.waitUntilExit()
        try #require(ditto.terminationStatus == 0)
        try stamp(downloads.appending(path: name), read: old.addingTimeInterval(-86_400))
    }

    var moveToFakeTrash: @Sendable (URL) throws -> URL? {
        let trash = trash
        return { url in
            let target = trash.appending(path: UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }
    }

    func scan(_ item: CleanerItem) async -> ItemScan {
        await Scanner.scan(item, policy: policy, openPaths: EndToEndCleanTests.ownOpenPaths)
    }

    func listed(_ ages: CleanupAges = .default) async throws -> Set<String> {
        Set(await scan(try #require(Self.item(ages: ages))).entries.map(\.url.lastPathComponent))
    }

    /// Lays out every case next to each other; returns the names that must be listed.
    func makeDownloads() throws -> Set<String> {
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        try write("old.txt")
        try write("new.txt", modified: .now, read: .now, created: .now, added: .now)
        try write("opened.pdf", read: recent) // read lately
        try write("created.mov", created: recent)
        try write("moved-in.jpg", added: recent) // an old file moved into Downloads lately
        try folder("Old Folder", ["a.txt": nil, "Sub/b.txt": nil])
        try stamp(downloads.appending(path: "Old Folder/Sub"))
        try stamp(downloads.appending(path: "Old Folder")) // `Sub` was stamped after the folder's last change
        try folder("Fresh Inside", ["a.txt": nil, "b.txt": recent]) // an old folder with a new file in it
        try folder("Read Inside", ["a.txt": nil], read: recent)
        try write("old.dmg") // Old installers lists it
        try write("Setup.PKG")
        try zip("App.zip", holding: ["X.app/Contents/Info.plist"])
        try zip("docs.zip", holding: ["Docs/readme.txt"]) // no app: a plain download
        try write("film.mp4") // Firefox, still downloading: the final name next to `.part`
        try write("film.mp4.part")
        try write("song.mp3.crdownload") // Chrome
        try folder("page.html.download") // Safari
        try write(".hidden")
        try write(".DS_Store")
        try write(".localized")
        try Data(repeating: 1, count: 4096).write(to: root.appending(path: "elsewhere.txt"))
        try stamp(root.appending(path: "elsewhere.txt"))
        try fm.createSymbolicLink(at: downloads.appending(path: "link.txt"), withDestinationURL: root.appending(path: "elsewhere.txt"))
        try stamp(downloads.appending(path: "link.txt"))
        return ["old.txt", "Old Folder", "docs.zip"]
    }

    @Test func onlyWithFullDiskAccessUntickedToTheTrash() throws {
        #expect(Self.item(fda: false) == nil) // reading ~/Downloads without it makes macOS ask
        let item = try #require(Self.item())
        #expect(item.paths == ["~/Downloads"] && item.mode == .trash && !item.selectedByDefault && item.selectableEntries)
        #expect(item.skipsOpenFiles && !item.showsWhenEmpty && item.minAge == 90 * 86_400 && item.entryLabel != nil)
        let ids = CleanerGroup.smartScan(ages: .default, hasFullDiskAccess: true).flatMap(\.items).map(\.id)
        #expect(ids.firstIndex(of: "old-downloads") == ids.firstIndex(of: "old-installers").map { $0 + 1 })
    }

    /// Only old files and folders old all through are listed, each with its name and last-touched date; installers
    /// stay in Old installers, even after it read a zip.
    @Test func listsOnlyWhatNothingTouched() async throws {
        let expected = try makeDownloads()
        let installers = try #require(OldInstallersTests.item())
        #expect(Set(await scan(installers).entries.map(\.url.lastPathComponent)) == ["old.dmg", "Setup.PKG", "App.zip"])
        let found = await scan(try #require(Self.item()))
        #expect(Set(found.entries.map(\.url.lastPathComponent)) == expected)
        for entry in found.entries {
            #expect(entry.size > 0 && entry.title == entry.url.lastPathComponent)
            #expect(entry.date.map { abs($0.timeIntervalSince(old)) < 1 } == true, "\(entry.url.lastPathComponent)")
        }
    }

    /// Its own age, 90 days by default: a 40-day-old file shows once the setting is 30 days.
    @Test func usesTheDownloadsAge() async throws {
        let fortyDays = Date.now.addingTimeInterval(-40 * 86_400)
        try write("forty.txt", modified: fortyDays, read: fortyDays, created: fortyDays, added: fortyDays)
        try write("old.txt")
        #expect(CleanupAges.default.downloads == 90 && CleanupAges.steps.contains(90))
        #expect(try await listed() == ["old.txt"])
        #expect(try await listed(CleanupAges(downloads: 30)) == ["forty.txt", "old.txt"])
        #expect(try await listed(CleanupAges(downloads: 365)) == [])
    }

    /// A folder with more items than the walk limit, an open file, or a symlinked Downloads: nothing is listed.
    @Test func keepsWhatItCannotCheck() async throws {
        try folder("Many", ["a": nil, "b": nil, "c": nil])
        #expect(OldDownloads.lastTouched(downloads.appending(path: "Many"), limit: 4) != nil) // the folder + 3 files
        #expect(OldDownloads.lastTouched(downloads.appending(path: "Many"), limit: 3) == nil)
        let open = try write("open.txt")
        let handle = try FileHandle(forReadingFrom: open)
        defer { try? handle.close() }
        #expect(try await listed() == ["Many"])

        // ~/Downloads as a symlink to a folder elsewhere in the home: never followed.
        try fm.moveItem(at: downloads, to: home.appending(path: "Real"))
        try fm.createSymbolicLink(at: downloads, withDestinationURL: home.appending(path: "Real"))
        #expect(try await listed() == [])
        #expect(!policy.allowsOldDownload(downloads.appending(path: "Many")))
        #expect(policy.allowsOldDownload(home.appending(path: "Real/Many")) == false)
    }

    @Test func policyAllowsOnlyTopLevelDownloads() throws {
        try folder("Folder")
        try write("file.txt")
        try write(".hidden")
        try fm.createDirectory(at: home.appending(path: "Documents"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: home.appending(path: "Documents/file.txt"))
        #expect(policy.allowsOldDownload(downloads.appending(path: "Folder")))
        #expect(policy.allowsOldDownload(downloads.appending(path: "file.txt")))
        #expect(!policy.allowsOldDownload(downloads.appending(path: "Folder/a.txt"))) // not at the top level
        #expect(!policy.allowsOldDownload(downloads.appending(path: ".hidden")))
        #expect(!policy.allowsOldDownload(downloads))
        #expect(!policy.allowsOldDownload(home.appending(path: "Documents/file.txt")))
        #expect(!policy.allowsOldDownload(downloads.appending(path: "missing.txt")))
        let excluding = SafetyPolicy(home: home, temp: root.appending(path: "tmp"), excluded: [downloads.appending(path: "Folder").path])
        #expect(!excluding.allowsOldDownload(downloads.appending(path: "Folder"))) // Settings › Exclusions
    }

    /// Smart Scan: never ticked; once ticked, to the Trash, counted as moved to the Trash, and ⌘Z puts it all back.
    @MainActor @Test func cleanMovesToTheTrashAndUndoPutsBack() async throws {
        let expected = try makeDownloads()
        let item = try #require(Self.item())
        let policy = policy, home = home, moveToFakeTrash = moveToFakeTrash
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
        let before = try Set(fm.contentsOfDirectory(atPath: downloads.path))
        model.selected = [item.id]
        undo.beginUndoGrouping()
        await model.clean()
        undo.endUndoGrouping()
        guard case .done(let report) = model.phase else { Issue.record("phase \(model.phase)"); return }
        #expect(Set(report.trashed.map(\.original.lastPathComponent)) == expected && report.skipped == 0)
        #expect(report.freed > 0 && model.cleanedGroups.first?.trashed == report.freed)
        #expect(ActivityLog.freed(home: home).trashed == report.freed)
        #expect(try Set(fm.contentsOfDirectory(atPath: downloads.path)) == before.subtracting(expected))
        #expect(fm.fileExists(atPath: root.appending(path: "elsewhere.txt").path))

        undo.undo() // ⌘Z
        func restored() -> Bool {
            guard case .done(let report) = model.phase else { return false }
            return report.undo != nil && !model.undoing
        }
        for _ in 0..<5000 where !restored() { try? await Task.sleep(for: .milliseconds(2)) } // the Task ⌘Z starts
        guard case .done(let after) = model.phase else { Issue.record("phase \(model.phase)"); return }
        #expect(after.undo == TrashUndo.Result(restored: expected.count, skipped: 0))
        #expect(try Set(fm.contentsOfDirectory(atPath: downloads.path)) == before)
        #expect(ActivityLog.freed(home: home).trashed == 0)
    }

    /// Something written in a listed folder after the scan keeps it at clean; so does a read of a listed file.
    @Test func touchedAfterTheScanIsKept() async throws {
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        try folder("Folder")
        let file = try write("file.txt")
        let item = try #require(Self.item())
        let found = await scan(item)
        #expect(found.entries.count == 2)
        try stamp(downloads.appending(path: "Folder/a.txt"), created: .now)
        try stamp(file, read: .now)
        let report = await Cleaner.clean(item, scan: found, policy: policy, trash: moveToFakeTrash,
                                         openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(report.skipped == 2 && report.trashed.isEmpty)
    }
}
