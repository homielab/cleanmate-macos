import Foundation
import Testing
@testable import CleanMate

/// Abandoned downloads: a fake home in a throwaway folder and a fake Trash; the real ~/Downloads is never read.
final class AbandonedDownloadsTests {
    let fm = FileManager.default
    let root = TestTemp.url("CleanMateAbandoned")
    var home: URL { root.appending(path: "home") }
    var downloads: URL { home.appending(path: "Downloads") }
    var trash: URL { root.appending(path: "Trash") }
    let old = Date.now.addingTimeInterval(-30 * 86_400)
    let recent = Date.now.addingTimeInterval(-2 * 86_400)
    let ancient = Date.now.addingTimeInterval(-120 * 86_400)

    deinit { try? FileManager.default.removeItem(at: root) }

    func policy(excluded: [String] = []) -> SafetyPolicy {
        SafetyPolicy(home: home, temp: root.appending(path: "tmp"), excluded: excluded)
    }

    static func items(fda: Bool = true) -> [CleanerItem] {
        CleanerGroup.smartScan(ages: .default, hasFullDiskAccess: fda).flatMap(\.items)
    }

    static func item(_ id: String = AbandonedDownloads.id) -> CleanerItem? { items().first { $0.id == id } }

    /// A file in Downloads of `bytes` bytes, every date old unless given.
    @discardableResult
    func write(_ path: String, modified: Date? = nil, read: Date? = nil, bytes: Int = 4096) throws -> URL {
        let url = downloads.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
        try OldDownloadsTests.stamp(url, modified: modified ?? old, read: read ?? old, created: old, added: old)
        return url
    }

    func listed(_ id: String = AbandonedDownloads.id, excluded: [String] = []) async throws -> Set<String> {
        let scan = await Scanner.scan(try #require(Self.item(id)), policy: policy(excluded: excluded),
                                      openPaths: EndToEndCleanTests.ownOpenPaths)
        return Set(scan.entries.map(\.url.lastPathComponent))
    }

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
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        try write("disk.dmg.crdownload") // Chrome, Edge, Brave
        try write("VIDEO.MOV.CRDOWNLOAD") // any case
        try write("film.mkv.part") // Firefox, with the empty file of the real name it creates
        try write("film.mkv", bytes: 0)
        try write("song.mp3.part") // a full file of the same name is a download of its own: not moved along
        try write("song.mp3")
        try write("page.zip.download/page.zip") // Safari: a folder
        try write("page.zip.download/Info.plist")
        try OldDownloadsTests.stamp(downloads.appending(path: "page.zip.download"), modified: old, read: old, created: old, added: old)
        try write("linux.iso.aria2", bytes: 512) // aria2: the data is in the file of the real name
        try write("linux.iso", bytes: 16_384)
        try write("show.mkv.!qB") // qBittorrent
        try write("fresh.crdownload", modified: recent) // still downloading
        try write("opened.part", read: recent)
        try write("busy.iso.aria2") // aria2 still writing the data
        try write("busy.iso", modified: recent)
        let notes = try write("notes.txt") // a finished download: Old downloads, at its age
        try OldDownloadsTests.stamp(notes, modified: ancient, read: ancient, created: ancient, added: ancient)
        try write("folder.crdownload/a.bin") // not a file
        try OldDownloadsTests.stamp(downloads.appending(path: "folder.crdownload"), modified: old, read: old, created: old, added: old)
        try write("plain.download") // Safari's is a folder
        try write(".hidden.part")
        try write(".part")
        try write("Sub/inner.crdownload") // not at the top level
        let elsewhere = root.appending(path: "elsewhere.crdownload")
        try Data(repeating: 1, count: 4096).write(to: elsewhere)
        try fm.createSymbolicLink(at: downloads.appending(path: "link.crdownload"), withDestinationURL: elsewhere)
        return ["disk.dmg.crdownload", "VIDEO.MOV.CRDOWNLOAD", "film.mkv.part", "song.mp3.part", "page.zip.download",
                "linux.iso.aria2", "show.mkv.!qB"]
    }

    @Test func onlyWithFullDiskAccessUntickedToTheTrash() throws {
        #expect(!Self.items(fda: false).contains { $0.id == AbandonedDownloads.id }) // reading ~/Downloads makes macOS ask
        let item = try #require(Self.item())
        #expect(item.paths == ["~/Downloads"] && item.mode == .trash && !item.selectedByDefault && item.selectableEntries)
        #expect(item.skipsOpenFiles && !item.showsWhenEmpty && item.minAge == 7 * 86_400 && item.entryLabel != nil)
        let ids = Self.items().map(\.id)
        #expect(ids.firstIndex(of: AbandonedDownloads.id) == ids.firstIndex(of: OldScreenshots.id).map { $0 + 1 })
    }

    /// The five kinds, untouched for 7 days, each with its name and date; the file of the real name Firefox and aria2
    /// keep goes along. Old installers and Old downloads list none of them.
    @Test func listsEveryKindWithItsMate() async throws {
        let expected = try makeDownloads()
        let item = try #require(Self.item())
        let scan = await Scanner.scan(item, policy: policy(), openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(Set(scan.entries.map(\.url.lastPathComponent)) == expected)
        for entry in scan.entries {
            #expect(entry.title == entry.url.lastPathComponent)
            #expect(entry.date.map { abs($0.timeIntervalSince(old)) < 1 } == true, "\(entry.url.lastPathComponent)")
        }
        let mates = Dictionary(uniqueKeysWithValues: scan.entries.map {
            ($0.url.lastPathComponent, AbandonedDownloads.files(of: $0.url).own.map(\.lastPathComponent))
        })
        #expect(mates["film.mkv.part"] == ["film.mkv"] && mates["linux.iso.aria2"] == ["linux.iso"])
        #expect(mates["song.mp3.part"] == [] && mates["disk.dmg.crdownload"] == [])
        let aria = try #require(scan.entries.first { $0.url.lastPathComponent == "linux.iso.aria2" })
        #expect(aria.filesSize >= 16_384 && aria.size > aria.filesSize)
        let others = try await listed("old-downloads"), installers = try await listed("old-installers")
        #expect(others == ["notes.txt"] && installers.isEmpty)
    }

    /// A download still running holds its file open: kept, also when only aria2's data file is open.
    @Test func openFilesAreKept() async throws {
        try write("open.crdownload")
        try write("data.iso.aria2")
        let data = try write("data.iso")
        try write("closed.part")
        let first = try FileHandle(forReadingFrom: downloads.appending(path: "open.crdownload"))
        defer { try? first.close() }
        let second = try FileHandle(forReadingFrom: data)
        defer { try? second.close() }
        #expect(try await listed() == ["closed.part"])
    }

    @Test func exclusionsAreRespected() async throws {
        _ = try makeDownloads()
        let all = try await listed()
        let disk = downloads.appending(path: "disk.dmg.crdownload").path
        let film = downloads.appending(path: "film.mkv").path // the mate in Exclusions keeps its download too
        #expect(try await listed(excluded: [disk, film]) == all.subtracting(["disk.dmg.crdownload", "film.mkv.part"]))
    }

    /// Each download goes to the Trash with its mate, and Undo puts both back.
    @Test func cleanMovesThePairAndUndoPutsItBack() async throws {
        let expected = try makeDownloads()
        let item = try #require(Self.item())
        let policy = policy()
        let scan = await Scanner.scan(item, policy: policy, openPaths: EndToEndCleanTests.ownOpenPaths)
        let before = try Set(fm.contentsOfDirectory(atPath: downloads.path))
        let report = await Cleaner.clean(item, scan: scan, policy: policy, trash: moveToFakeTrash,
                                         openPaths: EndToEndCleanTests.ownOpenPaths)
        let moved = expected.union(["film.mkv", "linux.iso"])
        #expect(Set(report.trashed.map(\.original.lastPathComponent)) == moved && report.skipped == 0)
        #expect(report.freed == scan.size)
        #expect(try Set(fm.contentsOfDirectory(atPath: downloads.path)) == before.subtracting(moved))
        let undo = await TrashUndo.restore(report.trashed, module: "Smart Scan", home: home)
        #expect(undo == TrashUndo.Result(restored: moved.count, skipped: 0))
        #expect(try Set(fm.contentsOfDirectory(atPath: downloads.path)) == before)
    }

    /// Resumed after the scan (the download written to, or aria2's data file): kept at clean.
    @Test func resumedAfterTheScanIsKept() async throws {
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let part = try write("a.crdownload")
        try write("b.iso.aria2")
        let data = try write("b.iso")
        let item = try #require(Self.item())
        let found = await Scanner.scan(item, policy: policy(), openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(found.entries.count == 2)
        try OldDownloadsTests.stamp(part, modified: .now, read: .now, created: old, added: old)
        try OldDownloadsTests.stamp(data, modified: .now, read: .now, created: old, added: old)
        let report = await Cleaner.clean(item, scan: found, policy: policy(), trash: moveToFakeTrash,
                                         openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(report.skipped == 2 && report.trashed.isEmpty)
    }
}
