import Foundation
import Testing
@testable import CleanMate

/// Old installers in Downloads: a fake home in a throwaway folder and a fake Trash; the real ~/Downloads is never read.
struct OldInstallersTests {
    let fm = FileManager.default
    let root = FileManager.default.temporaryDirectory.appending(path: "CleanMateInstallers-\(UUID().uuidString)")
    var home: URL { root.appending(path: "home") }
    var downloads: URL { home.appending(path: "Downloads") }
    var trash: URL { root.appending(path: "Trash") }
    var policy: SafetyPolicy { SafetyPolicy(home: home, temp: root.appending(path: "tmp")) }
    let old = Date.now.addingTimeInterval(-40 * 86_400)

    static func item(fda: Bool = true, ages: CleanupAges = .default) -> CleanerItem? {
        CleanerGroup.smartScan(ages: ages, hasFullDiskAccess: fda).flatMap(\.items).first { $0.id == "old-installers" }
    }

    func write(_ path: String, date: Date? = nil, bytes: Int = 4096) throws {
        let url = downloads.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
        try fm.setAttributes([.modificationDate: date ?? old], ofItemAtPath: url.path)
    }

    /// A real zip made by `ditto` of `entries` (paths inside the archive), written to Downloads as `name`, old.
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
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: downloads.appending(path: name).path)
    }

    /// Moves into the fake Trash like `trashItem`, returning the new place.
    var moveToFakeTrash: @Sendable (URL) throws -> URL? {
        let trash = trash
        return { url in
            let target = trash.appending(path: UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }
    }

    /// Lays out every case next to each other; returns the names that must be listed.
    func makeDownloads() throws -> Set<String> {
        try #require(!(root.path as NSString).resolvingSymlinksInPath.hasPrefix((NSHomeDirectory() as NSString).resolvingSymlinksInPath + "/"))
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        try write("a.dmg")
        try write("b.pkg", date: .now) // downloaded today
        try write("I.DMG") // upper case
        try write("c.dmg.download/c.dmg") // Safari, still downloading
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: downloads.appending(path: "c.dmg.download").path)
        try write("g.dmg", bytes: 0) // Firefox, still downloading: the final name exists, empty, next to `.part`
        try write("g.dmg.part")
        try write("h.iso.crdownload") // Chrome
        try write("notes.txt")
        try write("Sub/inner.dmg") // not at the top level
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: downloads.appending(path: "Sub").path)
        try fm.createDirectory(at: downloads.appending(path: "Bundle.pkg"), withIntermediateDirectories: true) // a folder
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: downloads.appending(path: "Bundle.pkg").path)
        // A symlink to an old disk image elsewhere: neither followed nor trashed.
        try Data(repeating: 1, count: 4096).write(to: root.appending(path: "elsewhere.dmg"))
        try fm.createSymbolicLink(at: downloads.appending(path: "link.dmg"), withDestinationURL: root.appending(path: "elsewhere.dmg"))
        var times = [timeval(tv_sec: Int(old.timeIntervalSince1970), tv_usec: 0), timeval(tv_sec: Int(old.timeIntervalSince1970), tv_usec: 0)]
        try #require(lutimes(downloads.appending(path: "link.dmg").path, &times) == 0)
        try zip("d.zip", holding: ["X.app/Contents/Info.plist"])
        try zip("docs.zip", holding: ["Docs/readme.txt"])
        try zip("wrapped.zip", holding: ["Folder/Y.app/Contents/Info.plist"])
        try write("broken.zip") // not a zip
        return ["a.dmg", "I.DMG", "d.zip"]
    }

    @Test func onlyWithFullDiskAccessUntickedToTheTrash() throws {
        #expect(Self.item(fda: false) == nil) // reading ~/Downloads without it makes macOS ask
        let item = try #require(Self.item())
        #expect(item.paths == ["~/Downloads"] && item.mode == .trash && !item.selectedByDefault && item.selectableEntries)
        #expect(item.skipsOpenFiles && !item.showsWhenEmpty && item.minAge == 30 * 86_400)
        #expect(policy.allows(policy.expand(item.paths[0]).appending(path: "a.dmg")))
    }

    /// Its own age (default 30 days), not the logs one: a 10-day-old image shows only once the setting is 7 days.
    @Test func usesTheInstallersAge() async throws {
        defer { try? fm.removeItem(at: root) }
        try write("recent.dmg", date: .now.addingTimeInterval(-10 * 86_400))
        try write("old.dmg")
        func listed(_ ages: CleanupAges) async throws -> Set<String> {
            let item = try #require(Self.item(ages: ages))
            let scan = await Scanner.scan(item, policy: policy, openPaths: EndToEndCleanTests.ownOpenPaths)
            return Set(scan.entries.map(\.url.lastPathComponent))
        }
        #expect(CleanupAges.default.installers == 30)
        #expect(try await listed(.default) == ["old.dmg"])
        #expect(try await listed(CleanupAges(logs: 90, installers: 7)) == ["old.dmg", "recent.dmg"])
    }

    /// Old top-level installers only, each its own entry; to the (fake) Trash, and put back by Undo.
    @Test func listsOldInstallersAndUndoPutsThemBack() async throws {
        defer { try? fm.removeItem(at: root) }
        let expected = try makeDownloads()
        let item = try #require(Self.item())
        let scan = await Scanner.scan(item, policy: policy, openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(Set(scan.entries.map(\.url.lastPathComponent)) == expected)
        #expect(scan.entries.allSatisfy { $0.size > 0 })

        let before = try Set(fm.contentsOfDirectory(atPath: downloads.path))
        let report = await Cleaner.clean(item, scan: scan, policy: policy, trash: moveToFakeTrash,
                                         openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(report.skipped == 0 && report.freed == scan.size)
        #expect(Set(report.trashed.map(\.original.lastPathComponent)) == expected)
        #expect(try Set(fm.contentsOfDirectory(atPath: downloads.path)) == before.subtracting(expected))
        #expect(fm.fileExists(atPath: root.appending(path: "elsewhere.dmg").path))

        let undo = await TrashUndo.restore(report.trashed, module: "Smart Scan", home: home)
        #expect(undo == TrashUndo.Result(restored: 3, skipped: 0))
        #expect(try Set(fm.contentsOfDirectory(atPath: downloads.path)) == before)
    }

    /// An installer that is open (a mounted disk image) is not listed, nor removed when opened after the scan.
    @Test func openInstallerIsKept() async throws {
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        try write("open.dmg")
        try write("closed.pkg")
        let item = try #require(Self.item())
        let scan = await Scanner.scan(item, policy: policy, openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(scan.entries.count == 2)
        let handle = try FileHandle(forReadingFrom: downloads.appending(path: "open.dmg"))
        defer { try? handle.close() }
        #expect(await Scanner.scan(item, policy: policy, openPaths: EndToEndCleanTests.ownOpenPaths)
            .entries.map(\.url.lastPathComponent) == ["closed.pkg"])
        let report = await Cleaner.clean(item, scan: scan, policy: policy, trash: moveToFakeTrash,
                                         openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(report.skipped == 1 && report.trashed.map(\.original.lastPathComponent) == ["closed.pkg"])
        #expect(fm.fileExists(atPath: downloads.appending(path: "open.dmg").path))
    }

    /// Smart Scan's done screen: ⌘Z puts back what went to the Trash, and the activity log no longer counts it.
    @MainActor @Test func smartScanUndoRestoresAndLogs() async throws {
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        try write("a.dmg")
        try write("b.iso")
        let item = try #require(Self.item())
        let policy = policy, home = home, moveToFakeTrash = moveToFakeTrash
        let model = SmartScanModel(module: .smartScan) { [CleanerGroup(id: "g", title: "G", systemImage: "x", items: [item])] }
        model.processNames = { [] }
        model.appBundleIDs = { [] }
        model.blockedByExclusion = { _ in false }
        model.scanItem = { await Scanner.scan($0, policy: policy, openPaths: EndToEndCleanTests.ownOpenPaths) }
        model.cleanItem = { item, scan in
            await Cleaner.clean(item, scan: scan, policy: policy, trash: moveToFakeTrash, openPaths: EndToEndCleanTests.ownOpenPaths)
        }
        model.restore = { items, logName in await TrashUndo.restore(items, module: "Smart Scan", home: home, logName: logName) }
        model.logHome = home
        model.freeSpace = { nil }
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo

        await model.scan()
        #expect(model.selected.isEmpty) // never ticked by default
        model.selected = [item.id]
        undo.beginUndoGrouping()
        await model.clean()
        undo.endUndoGrouping()
        guard case .done(let report) = model.phase else { Issue.record("phase \(model.phase)"); return }
        #expect(report.trashed.count == 2 && ActivityLog.freed(home: home).trashed == report.freed)
        #expect(undo.canUndo && undo.undoActionName == String(localized: "Move to Trash"))
        #expect(try fm.contentsOfDirectory(atPath: downloads.path).isEmpty)

        undo.undo() // ⌘Z
        func restored() -> Bool {
            guard case .done(let report) = model.phase else { return false }
            return report.undo != nil && !model.undoing
        }
        for _ in 0..<5000 where !restored() { try? await Task.sleep(for: .milliseconds(2)) } // the Task ⌘Z starts
        guard case .done(let after) = model.phase else { Issue.record("phase \(model.phase)"); return }
        #expect(after.undo == TrashUndo.Result(restored: 2, skipped: 0) && after.trashed.isEmpty && !undo.canUndo)
        #expect(try Set(fm.contentsOfDirectory(atPath: downloads.path)) == ["a.dmg", "b.iso"])
        #expect(ActivityLog.freed(home: home).trashed == 0) // restored under the same item name it was trashed under
    }

    @Test func topLevelAppNames() {
        #expect(OldInstallers.isTopLevelApp("X.app/"))
        #expect(OldInstallers.isTopLevelApp("My App.APP/Contents/Info.plist"))
        #expect(!OldInstallers.isTopLevelApp("X.app")) // a file
        #expect(!OldInstallers.isTopLevelApp("Folder/X.app/"))
        #expect(!OldInstallers.isTopLevelApp("__MACOSX/._X.app"))
        #expect(!OldInstallers.isTopLevelApp(".app/"))
        #expect(!OldInstallers.isTopLevelApp("X.application/"))
    }

    /// Central directories written by hand: plain, zip64 (counts and offset in the zip64 record), with a comment,
    /// and broken ones (truncated, offset past the end), which count as no app.
    @Test func readsZipCentralDirectory() throws {
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        func check(_ data: Data, _ names: [String]?, _ file: String) throws {
            let url = root.appending(path: file)
            try data.write(to: url)
            #expect(OldInstallers.zipEntryNames(url) == names, "\(file)")
        }
        let names = ["readme.txt", "Tool.app/", "Tool.app/Contents/Info.plist"]
        try check(Self.zip(names), names, "plain.zip")
        try check(Self.zip(names, zip64: true), names, "zip64.zip")
        try check(Self.zip(names, comment: "PK made by a tool"), names, "comment.zip")
        try check(Self.zip([]), [], "empty.zip")
        try check(Self.zip(names).dropLast(30), nil, "truncated.zip")
        try check(Data(repeating: 0, count: 100), nil, "zeros.zip")
        var past = Self.zip(names)
        past[past.count - 3] = 0xFF // central directory offset far past the end
        try check(past, nil, "past.zip")
        #expect(OldInstallers.zipHoldsApp(root.appending(path: "zip64.zip")))
        #expect(!OldInstallers.zipHoldsApp(root.appending(path: "missing.zip")))
    }

    /// A zip holding only a central directory (no file data): enough for `zipEntryNames`, which reads nothing else.
    static func zip(_ names: [String], zip64: Bool = false, comment: String = "") -> Data {
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        for name in names {
            put(UInt32(0x0201_4b50))
            for _ in 0..<6 { put(UInt16(0)) } // versions, flags, method, time, date
            for _ in 0..<3 { put(UInt32(0)) } // crc, sizes
            put(UInt16(name.utf8.count)); put(UInt16(0)); put(UInt16(0)); put(UInt16(0)); put(UInt16(0))
            put(UInt32(0)); put(UInt32(0))
            data.append(contentsOf: name.utf8)
        }
        let length = data.count
        if zip64 {
            let record = data.count
            put(UInt32(0x0606_4b50)); put(UInt64(44)); put(UInt16(45)); put(UInt16(45)); put(UInt32(0)); put(UInt32(0))
            put(UInt64(names.count)); put(UInt64(names.count)); put(UInt64(length)); put(UInt64(0))
            put(UInt32(0x0706_4b50)); put(UInt32(0)); put(UInt64(record)); put(UInt32(1))
        }
        put(UInt32(0x0605_4b50)); put(UInt16(0)); put(UInt16(0))
        put(UInt16(zip64 ? 0xFFFF : names.count)); put(UInt16(zip64 ? 0xFFFF : names.count))
        put(UInt32(zip64 ? 0xFFFF_FFFF : length)); put(UInt32(zip64 ? 0xFFFF_FFFF : 0))
        put(UInt16(comment.utf8.count))
        data.append(contentsOf: comment.utf8)
        return data
    }
}
