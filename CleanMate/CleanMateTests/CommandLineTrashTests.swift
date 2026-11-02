import Foundation
import Testing
@testable import CleanMate

/// `cleanmate trash` and `cleanmate restore`, in a fake home with a fake Trash: only the paths named move, only
/// through the safety rules, never without --yes off a terminal, and restore puts back without overwriting. What the
/// app moves to the Trash is listed by `restore --list` and put back by `restore` too.
extension CommandLineToolTests {
    static func trashReport(_ arguments: [String], _ sources: HeadlessScan.Sources) async throws -> HeadlessTrash.TrashReport {
        let (code, printed) = await run(["trash", "--yes", "--json"] + arguments, sources)
        try #require(code == 0, "\(printed.stderr)")
        return try JSONDecoder().decode(HeadlessTrash.TrashReport.self, from: Data(printed.stdout.utf8))
    }

    static func restoreReport(_ arguments: [String], _ sources: HeadlessScan.Sources) async throws -> HeadlessTrash.RestoreReport {
        let (code, printed) = await run(["restore", "--json"] + arguments, sources)
        try #require(code == 0, "\(printed.stderr)")
        return try JSONDecoder().decode(HeadlessTrash.RestoreReport.self, from: Data(printed.stdout.utf8))
    }

    static func restoreList(_ arguments: [String], _ sources: HeadlessScan.Sources) async throws -> HeadlessTrash.ListReport {
        let (code, printed) = await run(["restore", "--list", "--json"] + arguments, sources)
        try #require(code == 0, "\(printed.stderr)")
        return try JSONDecoder().decode(HeadlessTrash.ListReport.self, from: Data(printed.stdout.utf8))
    }

    private static func inTrash(_ fixture: FilesFixture) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: fixture.trash.path)) ?? []).sorted()
    }

    private static func exists(_ fixture: FilesFixture, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: fixture.home.appending(path: path).path)
    }

    @Test func trashMovesExactlyThePathsNamedAndRestorePutsThemBack() async throws {
        let fixture = try FilesFixture()
        let sources = fixture.sources(fullDiskAccess: true)
        let movie = fixture.home.appending(path: "Media/movie.mov").path
        // `~/…`, a duplicate and a folder: each path once, a folder whole.
        let report = try await Self.trashReport([movie, "~/Media/movie.mov", "~/Projects/app"], sources)
        #expect(report.version == "9.9" && report.count == 2 && report.items.count == 2)
        #expect(report.items.map(\.path) == [movie, fixture.home.appending(path: "Projects/app").path])
        #expect(report.items.map(\.kind) == ["file", "folder"] && report.items.allSatisfy { !$0.skipped && $0.reason == nil })
        #expect(report.items[0].size == 2_002_944)
        #expect(report.size == report.items.compactMap(\.size).reduce(0, +) && report.size >= 2_002_944 + FilesFixture.projectFiles)
        #expect(report.log == "~/Library/Logs/CleanMate/activity.log")
        let trashed = report.items.compactMap(\.trashed)
        #expect(trashed.map { URL(fileURLWithPath: $0).lastPathComponent } == ["movie.mov", "app"])
        #expect(Self.inTrash(fixture) == ["app", "movie.mov"])
        #expect(!Self.exists(fixture, "Media/movie.mov") && !Self.exists(fixture, "Projects/app"))
        // Everything else stays, the hard link to build.bin included.
        #expect(Self.exists(fixture, "Media/old.zip") && Self.exists(fixture, "Media/build-link.bin"))
        #expect(TrashRecords.inTrash(home: fixture.home).count == 2)

        let entries = ActivityLog.read(home: fixture.home).split(separator: "\n")
            .map { ActivityLog.entry($0, locale: Locale(identifier: "en")) }
        #expect(entries.map(\.moduleKey) == ["Command Line", "Command Line"] && entries.map(\.kind) == ["trashed", "trashed"])
        #expect(ActivityLog.freed(home: fixture.home).trashed == report.size)

        let restored = try await Self.restoreReport(trashed, sources)
        #expect(restored.count == 2 && restored.items.allSatisfy { !$0.skipped && $0.reason == nil })
        #expect(restored.items.map(\.trashed) == trashed)
        let originals = [movie, fixture.home.appending(path: "Projects/app").path]
        #expect(restored.items.compactMap(\.path) == originals.map { SafetyPolicy.normalize(URL(fileURLWithPath: $0)) })
        #expect(Self.exists(fixture, "Media/movie.mov") && Self.exists(fixture, "Projects/app/build.bin"))
        #expect(Self.inTrash(fixture).isEmpty && TrashRecords.inTrash(home: fixture.home).isEmpty)
        let kinds = ActivityLog.read(home: fixture.home).split(separator: "\n").map { ActivityLog.entry($0).kind }
        #expect(kinds == ["trashed", "trashed", "restored", "restored"] && ActivityLog.freed(home: fixture.home).trashed == 0)

        // Put back once: a second restore finds no record.
        let again = try await Self.restoreReport([trashed[0]], sources)
        #expect(again.count == 0 && again.items.first?.skipped == true && again.items.first?.path == nil)
        #expect(again.items.first?.reason == HeadlessTrash.notRecorded)
    }

    @Test func trashSkipsWhatTheSafetyRulesRefuseAndMovesNothing() async throws {
        let fixture = try FilesFixture()
        let fm = FileManager.default
        let home = fixture.home
        let outside = fixture.root.appending(path: "tmp/outside.bin")
        try Data(repeating: 1, count: 4_096).write(to: outside)
        try fm.createDirectory(at: home.appending(path: ".ssh"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4_096).write(to: home.appending(path: ".ssh/id_ed25519"))
        try Data(repeating: 1, count: 4_096).write(to: home.appending(path: "Library/Caches/cache.bin"))
        try fm.createSymbolicLink(at: home.appending(path: "Media/link.zip"), withDestinationURL: home.appending(path: "Media/old.zip"))
        // A symlinked folder leading out of the home: the path through it is outside.
        try fm.createSymbolicLink(at: home.appending(path: "Outside"), withDestinationURL: fixture.root.appending(path: "tmp"))
        try Data(repeating: 1, count: 4_096).write(to: fixture.root.appending(path: "tmp/other.bin"))
        let cases: [(String, String)] = [
            (outside.path, HeadlessTrash.outsideHome),
            ("~/Outside/other.bin", HeadlessTrash.outsideHome),
            ("/etc/hosts", HeadlessTrash.outsideHome),
            ("~/Media/Excluded/kept.iso", HeadlessTrash.excludedReason),
            ("~/Media/Excluded", HeadlessTrash.excludedReason),
            ("~/.ssh/id_ed25519", HeadlessTrash.hiddenReason),
            ("~/.ssh", HeadlessTrash.hiddenReason),
            ("~/Library/Caches/cache.bin", HeadlessTrash.libraryReason),
            ("~/Library", HeadlessTrash.libraryReason),
            // A folder holding an exclusion is excluded too.
            ("~/Media", HeadlessTrash.excludedReason),
            ("~/Projects", HeadlessTrash.topFolderReason),
            ("~", HeadlessTrash.homeReason),
            ("~/Media/link.zip", HeadlessTrash.symlinkReason),
            ("~/Media/gone.bin", HeadlessTrash.notFound),
            ("~/Documents/secret.bin", HeadlessScan.needsAccess),
        ]
        let report = try await Self.trashReport(cases.map(\.0), fixture.sources(fullDiskAccess: false))
        #expect(report.count == 0 && report.size == 0)
        #expect(report.items.map(\.reason) == cases.map(\.1))
        #expect(report.items.allSatisfy { $0.skipped && $0.trashed == nil && $0.size == nil })
        #expect(Self.inTrash(fixture).isEmpty && TrashRecords.inTrash(home: home).isEmpty)
        #expect(fm.fileExists(atPath: outside.path) && Self.exists(fixture, ".ssh/id_ed25519") && Self.exists(fixture, "Media/old.zip"))
        #expect(Self.exists(fixture, "Library/Caches/cache.bin") && Self.exists(fixture, "Documents/secret.bin"))
        #expect((try? fm.destinationOfSymbolicLink(atPath: home.appending(path: "Media/link.zip").path)) != nil)
        #expect(!fm.fileExists(atPath: ActivityLog.url(home: home).path))
        // JSON writes the absent fields as null, like space.
        let (_, printed) = await Self.run(["trash", "--yes", "--json", "~/Media/gone.bin"], fixture.sources())
        #expect(printed.stdout.contains("\"trashed\" : null") && printed.stdout.contains("\"size\" : null"))
    }

    @Test func trashWithoutYesOffATerminalExitsWith4AndMovesNothing() async throws {
        let fixture = try FilesFixture()
        let (code, printed) = await Self.run(["trash", "--json", "~/Media/movie.mov"], fixture.sources(fullDiskAccess: true))
        #expect(code == CommandLineTool.Exit.notConfirmed.rawValue)
        #expect(printed.stdout.isEmpty && printed.stderr.contains("--yes"))
        #expect(Self.exists(fixture, "Media/movie.mov") && Self.inTrash(fixture).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: ActivityLog.url(home: fixture.home).path))
        // restore with nothing moved yet writes no record file.
        let restored = try await Self.restoreReport([fixture.trash.appending(path: "movie.mov").path], fixture.sources())
        #expect(restored.count == 0 && restored.items.first?.skipped == true)
        #expect(!FileManager.default.fileExists(atPath: TrashRecords.url(home: fixture.home).path))
    }

    @Test func trashAsksOnATerminal() async throws {
        let fixture = try FilesFixture()
        let sources = fixture.sources(fullDiskAccess: true)
        let (declined, no) = await Self.run(["trash", "~/Media/movie.mov", "~/Library"], sources, answer: "n")
        #expect(declined == 0 && no.stderr.contains("About to move 1 item") && no.stderr.contains("Proceed? [y/N]"))
        #expect(no.stderr.contains("skipped: " + HeadlessTrash.libraryReason) && no.stderr.contains("Nothing was moved"))
        #expect(no.stdout.isEmpty && Self.exists(fixture, "Media/movie.mov") && Self.inTrash(fixture).isEmpty)

        let (accepted, yes) = await Self.run(["trash", "~/Media/movie.mov"], sources, answer: "y")
        #expect(accepted == 0 && !Self.exists(fixture, "Media/movie.mov") && Self.inTrash(fixture) == ["movie.mov"])
        let undo = "Undo: cleanmate restore " + CommandLineTool.quoted(fixture.trash.appending(path: "movie.mov").path)
        #expect(yes.stdout.contains("Moved 1 item") && yes.stdout.contains(undo), "\(yes.stdout)")

        let (_, back) = await Self.run(["restore", fixture.trash.appending(path: "movie.mov").path], sources)
        #expect(back.stdout.contains("Put back 1 item") && Self.exists(fixture, "Media/movie.mov"))
    }

    @Test func restoreNeverOverwritesAndRefusesAFolderThatIsNowASymlink() async throws {
        let fixture = try FilesFixture()
        let fm = FileManager.default
        let sources = fixture.sources(fullDiskAccess: true)
        let report = try await Self.trashReport(["~/Media/movie.mov", "~/Projects/app/data.bin", "~/Media/old.zip"], sources)
        let trashed = report.items.compactMap(\.trashed)
        try #require(trashed.count == 3)

        // A new file at the old place stays as it is.
        let newer = fixture.home.appending(path: "Media/movie.mov")
        try Data("new".utf8).write(to: newer)
        // The old folder moved away and a symlink to it put in its place.
        try fm.moveItem(at: fixture.home.appending(path: "Projects/app"), to: fixture.home.appending(path: "Projects/moved"))
        try fm.createSymbolicLink(at: fixture.home.appending(path: "Projects/app"), withDestinationURL: fixture.home.appending(path: "Projects/moved"))
        // Emptied from the Trash meanwhile.
        try fm.removeItem(atPath: trashed[2])

        let restored = try await Self.restoreReport(trashed, sources)
        #expect(restored.count == 0 && restored.items.allSatisfy(\.skipped))
        #expect(restored.items.map { $0.reason?.prefix(14) } == ["Something is a", "Its folder is ", "Not in the Tra"])
        #expect(try Data(contentsOf: newer) == Data("new".utf8))
        #expect(!fm.fileExists(atPath: fixture.home.appending(path: "Projects/moved/data.bin").path))
        #expect(Self.inTrash(fixture) == ["data.bin", "movie.mov"])
        // The two still in the Trash keep their record: put back once their place is free again.
        #expect(TrashRecords.inTrash(home: fixture.home).count == 2)
        try fm.removeItem(at: newer)
        let second = try await Self.restoreReport([trashed[0]], sources)
        #expect(second.count == 1 && fm.fileExists(atPath: newer.path))
        #expect(try Data(contentsOf: newer).count == 2_002_944)
    }

    @Test func restoreListShowsWhatTheAppMovedNewestFirstAndRestorePutsItBack() async throws {
        let fixture = try FilesFixture()
        let sources = fixture.sources(fullDiskAccess: true)
        let policy = sources.policy()
        // No record yet: an empty list, and no file made.
        let none = try await Self.restoreList([], sources)
        #expect(none.version == sources.version() && none.count == 0 && none.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: TrashRecords.url(home: fixture.home).path))
        let (_, emptyText) = await Self.run(["restore", "--list"], sources)
        #expect(emptyText.stdout == "Nothing CleanMate moved to the Trash is still there.\n")

        // Large & Old Files and Space Lens in the app, then the command line.
        let movie = URL(fileURLWithPath: SafetyPolicy.normalize(fixture.home.appending(path: "Media/movie.mov")))
        let app = URL(fileURLWithPath: SafetyPolicy.normalize(fixture.home.appending(path: "Projects/app")))
        let large = CleanReport.trashing([(movie, 2_002_944)], module: "Large & Old Files", home: fixture.home,
                                         allows: policy.allowsUserFile, trash: sources.trash)
        let lens = CleanReport.trashing([(app, FilesFixture.projectFiles)], module: "Space Lens", home: fixture.home,
                                        allows: { policy.allowsSpaceLensItem($0) }, trash: sources.trash)
        try #require(large.trashed.count == 1 && lens.trashed.count == 1)
        let cli = try await Self.trashReport(["~/Media/old.zip"], sources)
        try #require(cli.count == 1)

        let list = try await Self.restoreList([], sources)
        #expect(list.version == sources.version() && list.count == 3)
        #expect(list.items.map(\.source) == ["Command Line", "Space Lens", "Large & Old Files"])
        #expect(list.items.map(\.trashed) == [cli.items[0].trashed, lens.trashed[0].inTrash.path, large.trashed[0].inTrash.path])
        #expect(list.items.map(\.path) == [SafetyPolicy.normalize(fixture.home.appending(path: "Media/old.zip")), app.path, movie.path])
        #expect(list.items.map(\.kind) == ["file", "folder", "file"])
        #expect(list.items.map(\.size) == [1_200_128, FilesFixture.projectFiles, 2_002_944])
        #expect(list.items.allSatisfy { $0.date.flatMap { try? Date($0, strategy: .iso8601) } != nil })
        // --limit keeps the newest; JSON writes every field.
        #expect(try await Self.restoreList(["--limit", "1"], sources).items.map(\.source) == ["Command Line"])
        let (_, json) = await Self.run(["restore", "--list", "--json"], sources)
        #expect(json.stdout.contains("\"version\" : \"\(sources.version())\"") && json.stdout.contains("\"source\" : \"Space Lens\""))
        let (_, text) = await Self.run(["restore", "--list"], sources)
        let lines = text.stdout.split(separator: "\n")
        #expect(lines.count == 4 && lines[0].contains("~/Media/old.zip") && lines[0].contains("Command Line"))
        #expect(lines[2].contains(CommandLineTool.size(2_002_944)) && lines[2].contains("~/Media/movie.mov"), "\(text.stdout)")
        #expect(lines[3].hasPrefix("Put back: cleanmate restore"))

        // Emptied from the Trash: no longer listed. Listing writes nothing.
        try FileManager.default.removeItem(atPath: lens.trashed[0].inTrash.path)
        let before = try Data(contentsOf: TrashRecords.url(home: fixture.home))
        #expect(try await Self.restoreList([], sources).items.map(\.source) == ["Command Line", "Large & Old Files"])
        #expect(try Data(contentsOf: TrashRecords.url(home: fixture.home)) == before)

        // The app's move is put back, logged under its own module so the Trash total drops.
        let restored = try await Self.restoreReport([large.trashed[0].inTrash.path], sources)
        #expect(restored.count == 1 && restored.items.first?.path == movie.path)
        #expect(FileManager.default.fileExists(atPath: movie.path))
        let entries = ActivityLog.read(home: fixture.home).split(separator: "\n")
            .map { ActivityLog.entry($0, locale: Locale(identifier: "en")) }
        #expect(entries.last?.moduleKey == "Large & Old Files" && entries.last?.kind == "restored")
        #expect(ActivityLog.freed(home: fixture.home).trashed == FilesFixture.projectFiles + 1_200_128)
        #expect(try await Self.restoreList([], sources).items.map(\.source) == ["Command Line"])
    }

    @Test func smartScanItemsMovedToTheTrashAreListedAndDeletedOnesAreNot() async throws {
        let fixture = try Fixture()
        let sources = fixture.sources()
        let cleaned = try await Self.cleanReport(["--yes", "--only", "cli-old,cli-caches"], sources)
        #expect(cleaned.inTrash == 16_384 && cleaned.freed == 16_384 + 49_152)
        let list = try await Self.restoreList([], sources)
        // Only what went to the Trash: the deleted caches can't come back.
        #expect(list.count == 1 && list.items.map(\.source) == ["Smart Scan"] && list.items.first?.size == 16_384)
        let item = try #require(list.items.first)
        #expect(item.trashed == fixture.trash.appending(path: "c.bin").path && item.path.hasSuffix("/Library/Caches/cli-old/c.bin"))

        let restored = try await Self.restoreReport([item.trashed], sources)
        #expect(restored.count == 1 && fixture.exists("Library/Caches/cli-old/c.bin") && fixture.inTrash.isEmpty)
        // Logged "restored" under the item's name, like the app's Undo, so it no longer counts as in the Trash.
        let last = try #require(ActivityLog.read(home: fixture.home).split(separator: "\n").last.map { ActivityLog.entry($0) })
        #expect(last.moduleKey == "Smart Scan" && last.kind == "restored")
        #expect(ActivityLog.freed(home: fixture.home).trashed == 0)
        #expect(try await Self.restoreList([], sources).items.isEmpty)
    }

    @Test func trashAndRestoreArguments() throws {
        #expect(try CommandLineTool.parse(["trash", "a", "--yes", "b"]) == .trash(paths: ["a", "b"], json: false, yes: true))
        #expect(try CommandLineTool.parse(["trash", "-y", "--json", "--", "-odd", "--yes"])
                == .trash(paths: ["-odd", "--yes"], json: true, yes: true))
        #expect(try CommandLineTool.parse(["restore", "--json", "x"]) == .restore(paths: ["x"], json: true))
        #expect(try CommandLineTool.parse(["restore", "--list"]) == .restoreList(limit: 200, json: false))
        #expect(try CommandLineTool.parse(["restore", "--json", "--limit", "5", "--list"]) == .restoreList(limit: 5, json: true))
        #expect(try CommandLineTool.parse(["restore", "--list", "--limit=3"]) == .restoreList(limit: 3, json: false))
        #expect(try CommandLineTool.parse(["trash", "--help"]) == .help)
        for bad in [["trash"], ["trash", "--yes"], ["restore"], ["restore", "--yes", "x"], ["trash", "--recursive", "x"],
                    ["trash", "--json=1", "x"], ["restore", "--list", "x"], ["restore", "--limit", "3", "x"],
                    ["restore", "--list", "--limit", "0"], ["restore", "--list", "--limit"], ["trash", "--list", "x"]] {
            #expect(throws: CommandLineTool.UsageError.self, "\(bad)") { try CommandLineTool.parse(bad) }
        }
        #expect(CommandLineTool.quoted("/Users/me/.Trash/a.mov") == "/Users/me/.Trash/a.mov")
        #expect(CommandLineTool.quoted("/Users/me/.Trash/it's 2.mov") == "'/Users/me/.Trash/it'\\''s 2.mov'")
    }
}
