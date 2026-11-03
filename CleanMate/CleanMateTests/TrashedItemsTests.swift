import Foundation
import Testing
@testable import CleanMate

/// Moved to the Trash (`TrashedItemsModel`): what any module moved, listed after a relaunch from the records alone, put
/// back under Undo's rules and logged "restored" under the module that moved it; in a fake home with a fake Trash.
@MainActor
struct TrashedItemsTests {
    typealias Fixture = CommandLineToolTests.FilesFixture

    /// Moves `paths` (in the fake home) to the fake Trash as `module` does in the app: logged and recorded.
    private static func move(_ paths: [String], module: LocalizedStringResource, _ fixture: Fixture) -> CleanReport {
        let sources = fixture.sources(fullDiskAccess: true)
        let policy = sources.policy()
        let items = paths.map { path in
            let url = URL(fileURLWithPath: SafetyPolicy.normalize(fixture.home.appending(path: path)))
            return (url, (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize).map(Int64.init) ?? 0)
        }
        return CleanReport.trashing(items, module: module, home: fixture.home, allows: { policy.allowsSpaceLensItem($0) },
                                    trash: sources.trash)
    }

    private static func log(_ fixture: Fixture) -> [ActivityLog.Entry] {
        ActivityLog.read(home: fixture.home).split(separator: "\n").map { ActivityLog.entry($0, locale: Locale(identifier: "en")) }
    }

    @Test func listsWhatAModuleMovedAfterARelaunchAndPutsItBack() async throws {
        let fixture = try Fixture()
        let moved = Self.move(["Media/movie.mov", "Projects/app"], module: "Large & Old Files", fixture)
        try #require(moved.trashed.count == 2)
        let cli = try await CommandLineToolTests.trashReport(["~/Media/old.zip"], fixture.sources(fullDiskAccess: true))
        try #require(cli.count == 1)

        // A new model reads only the records: as after quitting and opening CleanMate again.
        let model = TrashedItemsModel(home: fixture.home)
        await model.load()
        #expect(model.loaded && model.rows.count == 3)
        #expect(model.rows.map(\.name) == ["old.zip", "app", "movie.mov"])
        #expect(Set(model.rows.map(\.source)) == ["Large & Old Files", "Command Line"])
        #expect(model.rows.allSatisfy { $0.date != nil })
        #expect(model.rows.first { $0.name == "app" }?.isFolder == true && model.rows.first { $0.name == "movie.mov" }?.isFolder == false)
        #expect(model.sources == ["Large & Old Files", "Command Line"])

        let movie = try #require(model.rows.first { $0.name == "movie.mov" })
        await model.restore([movie])
        #expect(model.restoredCount == 1 && model.failures.isEmpty && !model.rows.contains(movie))
        #expect(FileManager.default.fileExists(atPath: fixture.home.appending(path: "Media/movie.mov").path))
        let last = try #require(Self.log(fixture).last)
        #expect(last.kind == "restored" && last.moduleKey == "Large & Old Files")
        // The Trash total no longer counts it.
        let app = try #require(moved.trashed.first { $0.original.lastPathComponent == "app" })
        #expect(ActivityLog.freed(home: fixture.home).trashed == app.size + (cli.items.first?.size ?? 0))
        // The record left: a new read lists the two others, and the command line agrees.
        await model.load()
        #expect(model.rows.count == 2 && !model.rows.contains { $0.name == "movie.mov" })
        let list = try await CommandLineToolTests.restoreList([], fixture.sources(fullDiskAccess: true))
        #expect(list.count == 2)
    }

    @Test func neverOverwritesAndKeepsTheRowWithItsReason() async throws {
        let fixture = try Fixture()
        let fm = FileManager.default
        let moved = Self.move(["Media/movie.mov", "Projects/app/data.bin", "Media/old.zip", "Media/small.bin"],
                              module: "Space Lens", fixture)
        try #require(moved.trashed.count == 4)
        // A new file at the old place stays as it is.
        let newer = fixture.home.appending(path: "Media/movie.mov")
        try Data("new".utf8).write(to: newer)
        // The old folder moved away, and another one replaced by a symlink.
        try fm.moveItem(at: fixture.home.appending(path: "Projects/app"), to: fixture.home.appending(path: "Projects/moved"))
        // Emptied from the Trash before the list was read: not listed.
        try fm.removeItem(at: try #require(moved.trashed.first { $0.original.lastPathComponent == "old.zip" }).inTrash)

        let model = TrashedItemsModel(home: fixture.home)
        await model.load()
        #expect(Set(model.rows.map(\.name)) == ["movie.mov", "data.bin", "small.bin"])
        #expect(model.rows.allSatisfy { $0.source == "Space Lens" })
        // Emptied after the list was read: the row goes, nothing is moved.
        let small = try #require(model.rows.first { $0.name == "small.bin" })
        try fm.removeItem(at: small.inTrash)

        await model.restore(model.rows)
        #expect(model.restoredCount == 0)
        #expect(try Data(contentsOf: newer) == Data("new".utf8))
        #expect(!fm.fileExists(atPath: fixture.home.appending(path: "Projects/app/data.bin").path))
        #expect(!fm.fileExists(atPath: fixture.home.appending(path: "Projects/moved/data.bin").path))
        #expect(Set(model.rows.map(\.name)) == ["movie.mov", "data.bin"])
        let reasons = Dictionary(uniqueKeysWithValues: model.rows.map { ($0.name, model.failures[$0.id]) })
        #expect(reasons["movie.mov"] == .occupied && reasons["data.bin"] == .folderChanged)
        #expect(!Self.log(fixture).contains { $0.kind == "restored" })

        // Its place free again: put back on the next try.
        try fm.removeItem(at: newer)
        let movie = try #require(model.rows.first { $0.name == "movie.mov" })
        await model.restore([movie])
        #expect(model.restoredCount == 1 && model.failures[movie.id] == nil)
        #expect(try Data(contentsOf: newer).count == 2_002_944)
    }

    @Test func refusesAnOldFolderThatIsNowASymlink() async throws {
        let fixture = try Fixture()
        let fm = FileManager.default
        let moved = Self.move(["Projects/app/data.bin"], module: "Uninstaller", fixture)
        try #require(moved.trashed.count == 1)
        try fm.moveItem(at: fixture.home.appending(path: "Projects/app"), to: fixture.home.appending(path: "Projects/moved"))
        try fm.createSymbolicLink(at: fixture.home.appending(path: "Projects/app"),
                                  withDestinationURL: fixture.home.appending(path: "Projects/moved"))
        let model = TrashedItemsModel(home: fixture.home)
        await model.load()
        let row = try #require(model.rows.first)
        await model.restore([row])
        #expect(model.failures[row.id] == .folderIsSymlink && model.rows.count == 1)
        #expect(!fm.fileExists(atPath: fixture.home.appending(path: "Projects/moved/data.bin").path))
    }

    @Test func noRecordsListsNothingAndMakesNoFile() async throws {
        let fixture = try Fixture()
        let model = TrashedItemsModel(home: fixture.home)
        await model.load()
        #expect(model.loaded && model.rows.isEmpty && model.sources.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: TrashRecords.url(home: fixture.home).path))
        #expect(TrashRecords.restore(["/nowhere"], home: fixture.home) == ["/nowhere": .notInTrash])
    }

    @Test func sortsNewestFirstFiltersBySourceAndSearch() {
        func record(_ name: String, _ module: String?, _ date: String?) -> TrashRecords.Record {
            var record = TrashRecords.Record(TrashedItem(original: URL(fileURLWithPath: "/Users/u/Docs/" + name),
                                                         inTrash: URL(fileURLWithPath: "/Users/u/.Trash/" + name), size: 1,
                                                         folder: "/Users/u/Docs", volume: 1),
                                             id: SafeRemoval.FileID(device: 1, inode: 1), module: module)
            record.date = date
            return record
        }
        // Oldest first in the file, as written.
        let rows = TrashedItemsModel.rows([
            record("a.mov", "Large & Old Files", "2026-11-01T10:00:00+07:00"),
            record("old.txt", nil, nil),
            record("Photo.heic", "Similar Photos", "2026-11-03T09:00:00+07:00"),
            record("b.zip", "Command Line", "2026-11-02T08:00:00Z"),
            record("Tool.app", "Uninstaller", "2026-11-03T09:00:00+07:00"),
        ])
        #expect(rows.map(\.name) == ["Tool.app", "Photo.heic", "b.zip", "a.mov", "old.txt"])
        #expect(TrashedItemsModel.sources(rows) == ["Large & Old Files", "Similar Photos", "Uninstaller", "Command Line", ""])
        #expect(TrashedItemsModel.filter(rows, source: "Uninstaller", search: "").map(\.name) == ["Tool.app"])
        #expect(TrashedItemsModel.filter(rows, source: "", search: "").map(\.name) == ["old.txt"])
        #expect(TrashedItemsModel.filter(rows, source: nil, search: " photo ").map(\.name) == ["Photo.heic"])
        // Search covers the old folder too.
        #expect(TrashedItemsModel.filter(rows, source: nil, search: "docs").count == 5)
        #expect(TrashedItemsModel.filter(rows, source: "Command Line", search: "a.mov").isEmpty)
    }

    @Test func putBackAllShownPutsBackOnlyTheFilteredRows() async throws {
        let fixture = try Fixture()
        _ = Self.move(["Media/movie.mov"], module: "Large & Old Files", fixture)
        _ = Self.move(["Media/old.zip", "Media/small.bin"], module: "Space Lens", fixture)
        let model = TrashedItemsModel(home: fixture.home)
        await model.load()
        model.source = "Space Lens"
        model.search = "small"
        #expect(model.shown.map(\.name) == ["small.bin"])
        await model.restore(model.shown)
        #expect(model.restoredCount == 1 && model.rows.count == 2)
        #expect(FileManager.default.fileExists(atPath: fixture.home.appending(path: "Media/small.bin").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.home.appending(path: "Media/old.zip").path))
        model.search = ""
        await model.restore(model.shown)
        #expect(model.rows.map(\.name) == ["movie.mov"])
        // The filter's source is gone from a fresh read: back to every source.
        await model.load()
        #expect(model.source == nil && model.shown.map(\.name) == ["movie.mov"])
    }

    @Test func sourceNamesAreTranslated() {
        let vi = Locale(identifier: "vi")
        #expect(TrashedItemsView.sourceTitle("", locale: vi) == "Không rõ")
        #expect(TrashedItemsView.sourceTitle("Command Line", locale: Locale(identifier: "en")) == "Command Line")
        #expect(TrashedItemsView.sourceTitle("Large & Old Files", locale: vi) != "Large & Old Files")
    }
}
