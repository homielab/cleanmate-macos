import Foundation
import os
import Testing
@testable import CleanMate

/// Exclusions, age thresholds and the activity log, on a throwaway home folder.
struct SettingsTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "CleanMateSettingsTests-\(UUID().uuidString)")
    var home: URL { root.appending(path: "home") }

    private func file(_ path: String, age: TimeInterval = 0) throws -> URL {
        let url = home.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 10_000).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }

    private func policy(excluding paths: [String] = []) -> SafetyPolicy {
        SafetyPolicy(home: home, temp: root.appending(path: "tmp"), excluded: paths.map { home.appending(path: $0).path })
    }

    @Test func excludedFoldersAreNeverListedNorRemoved() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = try file("Library/Caches/Keep/data")
        let nested = try file("Library/Caches/Outer/Inner/data")
        let other = try file("Library/Caches/Other/data")
        let policy = policy(excluding: ["Library/Caches/Keep", "Library/Caches/Outer/Inner"])
        // Inside, the folder itself, and a parent holding an excluded folder are all refused.
        #expect(!policy.allows(kept))
        #expect(!policy.allows(kept.deletingLastPathComponent()))
        #expect(!policy.allows(home.appending(path: "Library/Caches/Outer")))
        #expect(!policy.allows(nested))
        #expect(policy.allows(other.deletingLastPathComponent()))

        let item = CleanerItem(id: "t", title: "t", paths: ["~/Library/Caches"])
        let scan = await Scanner.scan(item, policy: policy)
        #expect(scan.entries.map(\.url.lastPathComponent) == ["Other"])
        // Removal re-checks: an entry scanned before the folder was excluded is skipped.
        let before = await Scanner.scan(item, policy: self.policy())
        let report = await Cleaner.clean(item, scan: before, policy: policy)
        #expect(report.skipped == 2)
        #expect(FileManager.default.fileExists(atPath: kept.path) && FileManager.default.fileExists(atPath: nested.path))
        #expect(!FileManager.default.fileExists(atPath: other.path))
    }

    @Test func exclusionsApplyToUserPickedFiles() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let video = try file("Movies/Keep/clip.mov")
        let loose = try file("Movies/clip.mov")
        let policy = policy(excluding: ["Movies/Keep"])
        #expect(!policy.allowsUserFile(video))
        #expect(!policy.allowsSpaceLensItem(video.deletingLastPathComponent()))
        #expect(policy.allowsUserFile(loose))
        #expect(!policy.allowsApp(URL(fileURLWithPath: "/Applications/Safari.app")))
    }

    @Test func oldLogsKeepCleanMateActivityLog() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let old: TimeInterval = 400 * 86_400
        for path in ["Library/Logs/CleanMate/activity.log", "Library/Logs/SomeApp/app.log"] {
            let log = try file(path, age: old)
            try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-old)],
                                                  ofItemAtPath: log.deletingLastPathComponent().path)
        }
        let item = try #require(CleanerGroup.smartScan(ages: .default).flatMap(\.items).first { $0.id == "old-logs" })
        let scan = await Scanner.scan(item, policy: policy())
        #expect(scan.entries.map(\.url.lastPathComponent) == ["SomeApp"])
    }

    @Test func catalogsUseTheAgeSettings() {
        let ages = CleanupAges(logs: 14, temp: 5, sessions: 60)
        let items = CleanerGroup.smartScan(ages: ages).flatMap(\.items)
        func age(_ id: String) -> Int? { items.first { $0.id == id }?.minAge.map { Int($0) } }
        #expect(age("old-logs") == 14 * 86_400)
        #expect(age("temp-files") == 5 * 86_400)
        #expect(age("claude-code-sessions") == 60 * 86_400)
        #expect(age("codex-sessions") == 60 * 86_400)
    }

    /// 1-day thresholds: the age is used as is and the note is singular in English, plural from 2.
    @Test func oneDayThresholdIsSingular() throws {
        func note(_ days: Int, _ lang: String) throws -> String {
            let item = try #require(CleanerGroup.smartScan(ages: CleanupAges(logs: days, temp: days)).flatMap(\.items)
                .first { $0.id == "temp-files" })
            #expect(item.minAge == Double(days) * 86_400)
            var resource = try #require(item.note)
            resource.locale = Locale(identifier: lang)
            return String(localized: resource)
        }
        #expect(try note(1, "en") == "Not modified for 1 day")
        #expect(try note(2, "en") == "Not modified for 2 days")
        #expect(try note(1, "vi") == "Không thay đổi trong 1 ngày")
    }

    @Test func englishCountsAreSingularForOne() {
        func en(_ r: LocalizedStringResource) -> String {
            var r = r
            r.locale = Locale(identifier: "en")
            return String(localized: r)
        }
        #expect(en("\(1) records") == "1 record")
        #expect(en("\(2) records") == "2 records")
        #expect(en("Selected: \(1) items, \("5 MB")") == "Selected: 1 item, 5 MB")
        #expect(en("Move \(1) items (\("5 MB")) to the Trash?") == "Move 1 item (5 MB) to the Trash?")
        #expect(en("Move \("Foo") and \(1) related items (\("5 MB")) to the Trash?")
            == "Move Foo and 1 related item (5 MB) to the Trash?")
        #expect(en("Move \("Foo") and \(3) related items (\("5 MB")) to the Trash?")
            == "Move Foo and 3 related items (5 MB) to the Trash?")
    }

    /// Under a test host the real ~/Library/Logs/CleanMate/activity.log is off limits; the shipped app is unaffected.
    @Test func activityLogRefusesTheRealHomeInTests() {
        let real = URL(fileURLWithPath: NSHomeDirectory())
        #expect(ActivityLog.writesRealLogInTests(real))
        #expect(!ActivityLog.writesRealLogInTests(FileManager.default.temporaryDirectory))
        #expect(!ActivityLog.writesRealLogInTests(real, environment: [:]))
    }

    @Test func activityLogPostsDidRecordAfterWriting() {
        defer { try? FileManager.default.removeItem(at: root) }
        var lineCountAtPost = -1
        let observer = NotificationCenter.default.addObserver(forName: ActivityLog.didRecord, object: nil, queue: nil) { _ in
            lineCountAtPost = ActivityLog.read(home: home).split(separator: "\n").count
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        ActivityLog.record(module: "Smart Scan", item: "c", size: 1, mode: .delete, home: home)
        #expect(lineCountAtPost == 1)
    }

    @Test func activityLogAppendsLinesAndRotates() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        ActivityLog.record(module: "Smart Scan", item: "User caches", count: 3, size: 2_000_000, mode: .delete, home: home)
        ActivityLog.record(module: "Space Lens", item: "/x/y\tz", size: 10, mode: .trash, home: home)
        let lines = ActivityLog.read(home: home).split(separator: "\n")
        #expect(lines.count == 2)
        let first = lines[0].split(separator: "\t", omittingEmptySubsequences: false)
        #expect(first.count == 7)
        #expect(first[1] == "Smart Scan" && first[2] == "User caches" && first[3] == "3" && first[5] == "deleted" && first[6] == "2000000")
        #expect(lines[1].hasSuffix("trashed\t10") && lines[1].contains("/x/y z"))

        try Data(count: ActivityLog.maxSize + 1).write(to: ActivityLog.url(home: home))
        ActivityLog.record(module: "Uninstaller", item: "Foo.app", size: 1, mode: .trash, home: home)
        #expect(ActivityLog.read(home: home).split(separator: "\n").count == 1)
        let rotated = home.appending(path: "Library/Logs/CleanMate/activity.1.log")
        #expect(FileManager.default.fileExists(atPath: rotated.path))
    }

    /// Concurrent records crossing the rotation threshold. ~60 lines of ~70 bytes against a 2500-byte
    /// threshold rotate exactly once, so nothing is dropped: every line is in exactly one of the two files.
    @Test func activityLogKeepsEveryLineWhenRecordsRotateConcurrently() {
        defer { try? FileManager.default.removeItem(at: root) }
        let count = 60
        DispatchQueue.concurrentPerform(iterations: count) { index in
            ActivityLog.record(module: "Smart Scan", item: String(format: "item-%02d", index), size: 1, mode: .delete,
                               home: home, rotateAt: 2500)
        }
        let rotated = home.appending(path: "Library/Logs/CleanMate/activity.1.log")
        let text = ActivityLog.read(home: home) + ((try? String(contentsOf: rotated, encoding: .utf8)) ?? "")
        let items = text.split(separator: "\n").map { String($0.split(separator: "\t")[2]) }
        #expect(FileManager.default.fileExists(atPath: rotated.path))
        #expect(items.sorted() == (0..<count).map { String(format: "item-%02d", $0) })
    }

    /// Module and item are stored in English and translated when shown; old translated lines and paths stay as they are.
    @Test func activityLogShowsNamesInTheCurrentLanguage() {
        defer { try? FileManager.default.removeItem(at: root) }
        ActivityLog.record(module: "Smart Scan", item: ActivityLog.english("User caches"), size: 1, mode: .delete, home: home)
        ActivityLog.record(module: "Login Items", item: "/a/User caches%d.plist", size: 1, mode: .trash, home: home)
        let lines = ActivityLog.read(home: home).split(separator: "\n")
        #expect(lines[0].split(separator: "\t")[1] == "Smart Scan")
        let vi = Locale(identifier: "vi"), en = Locale(identifier: "en")
        let first = ActivityLog.entry(lines[0], locale: vi)
        #expect(first.module == "Quét thông minh" && first.moduleKey == "Smart Scan" && first.item == "Bộ nhớ đệm người dùng")
        #expect(ActivityLog.entry(lines[0], locale: en).module == "Smart Scan")
        #expect(first.bytes == 1 && first.kind == "deleted" && first.date != nil)
        #expect(ActivityLog.entry(lines[0], locale: en).item == "User caches")
        let second = ActivityLog.entry(lines[1], locale: vi)
        #expect(second.module == "Mục đăng nhập" && second.item == "/a/User caches%d.plist" && second.kind == "trashed")
        // Old 6-column line: no raw bytes, size text and names kept as written.
        let old = "2026-01-01T00:00:00+07:00\tQuét thông minh\tBộ nhớ đệm người dùng\t3\t2 MB\tdeleted"
        #expect(ActivityLog.entry(old[...], id: 4, locale: en) == ActivityLog.Entry(
            id: 4, date: try? Date("2026-01-01T00:00:00+07:00", strategy: .iso8601), dateText: "2026-01-01T00:00:00+07:00",
            module: "Quét thông minh", moduleKey: "Quét thông minh", item: "Bộ nhớ đệm người dùng", size: "2 MB", bytes: nil, kind: "deleted"))
        #expect(ActivityLog.entry("garbage", locale: vi) == ActivityLog.Entry(item: "garbage"))
        // Unknown module (edited log, older version): shown as written.
        let odd = ActivityLog.entry("2026-01-01T00:00:00Z\tMy Tool\tx\t1\t1 MB\tdeleted", locale: vi)
        #expect(odd.module == "My Tool" && odd.moduleKey == "My Tool")
    }

    /// Totals come from the raw byte column: both log files, old 6-column lines (EN or VI size text) skipped.
    @Test func activityLogTotalsFreedBytes() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = home.appending(path: "Library/Logs/CleanMate")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try ([
            "2026-01-01T00:00:00+07:00\tQuét thông minh\tBộ nhớ đệm người dùng\t3\t2,5 MB\tdeleted",
            "2026-01-02T00:00:00+07:00\tSmart Scan\tUser caches\t1\t1 KB\tdeleted\t1000",
            "2026-01-03T00:00:00Z\tUninstaller\t/A.app\t1\t5 KB\ttrashed\t5000",
        ].joined(separator: "\n") + "\n").write(to: dir.appending(path: "activity.1.log"), atomically: true, encoding: .utf8)
        ActivityLog.record(module: "Smart Scan", item: "c", size: 300, mode: .delete, home: home)
        ActivityLog.record(module: "Space Lens", item: "/x", size: 40, mode: .trash, home: home)
        let total = ActivityLog.freed(home: home)
        #expect(total.deleted == 1300 && total.trashed == 5040)
        #expect(total.since == (try Date("2026-01-02T00:00:00+07:00", strategy: .iso8601)))
        let recent = ActivityLog.freed(after: .now.addingTimeInterval(-30 * 86_400), home: home)
        #expect(recent.deleted == 300 && recent.trashed == 40)
        // The raw byte column becomes `bytes`.
        let line = ActivityLog.read(home: home).split(separator: "\n")[0]
        let entry = ActivityLog.entry(line, locale: Locale(identifier: "en"))
        #expect(entry.bytes == 300 && entry.kind == "deleted")
        let none = ActivityLog.freed(home: home.appending(path: "none"))
        #expect(none.deleted == 0 && none.trashed == 0 && none.since == nil)
    }

    /// "restored" takes back only bytes its own "trashed" line added in the window: never another item's,
    /// nor a total trashed before the cutoff. Settings › Activity lists the rotated file too.
    @Test func activityLogPairsRestoredWithItsTrashedLine() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = home.appending(path: "Library/Logs/CleanMate")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = "2020-01-01T00:00:00Z\tSpace Lens\t/old\t1\t9 KB\ttrashed\t9000\n"
        try old.write(to: dir.appending(path: "activity.1.log"), atomically: true, encoding: .utf8)
        ActivityLog.record(module: "Space Lens", item: "/a", size: 300, mode: .trash, home: home)
        ActivityLog.recordRestored(module: "Space Lens", item: "/old", size: 9000, home: home) // trashed long ago
        ActivityLog.recordRestored(module: "Space Lens", item: "/b", size: 300, home: home)   // never trashed
        let recent = ActivityLog.freed(after: .now.addingTimeInterval(-30 * 86_400), home: home)
        #expect(recent.trashed == 300)
        #expect(ActivityLog.freed(home: home).trashed == 300) // 9000 + 300 − 9000
        ActivityLog.recordRestored(module: "Space Lens", item: "/a", size: 300, home: home)
        #expect(ActivityLog.freed(home: home).trashed == 0)
        #expect(ActivityLog.readAll(home: home).split(separator: "\n").count == 5)
    }

    /// A damaged line whose key takes `%s`/`%d` keeps the stored English text: never formatted with C types.
    @Test func activityLogNeverFormatsDamagedKeysWithCTypes() {
        let s = ActivityLog.separator
        for key in ["%s: gone", "%d: gone", "%@ %s"] {
            let line = "2026-01-01T00:00:00Z\tSmart Scan\tShown\(s)\(key)\(s)Foo\t1\t1 KB\tdeleted"
            #expect(ActivityLog.entry(line[...], locale: Locale(identifier: "en")).item == "Shown")
        }
    }

    /// Excluding the startup disk "/" (folder picker) excludes everything, as the list says.
    @Test func excludingTheStartupDiskRefusesEverything() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try file("Library/Caches/a")
        let policy = SafetyPolicy(home: home, temp: root.appending(path: "tmp"), excluded: ["/"])
        #expect(!policy.allows(cache) && policy.overlapsExclusion(cache))
    }

    /// Menu bar extra + Smart Scan idle line: hidden at 0, otherwise mentions the 30 days.
    @Test func freedLineHiddenAtZero() {
        #expect(SmartScanView.freedLine(0) == nil)
        let line = SmartScanView.freedLine(3_400_000_000)
        #expect(line != nil && line != "")
    }

    /// Interpolated titles ("Chrome: cache & logs") are stored with key + arguments and translated when shown.
    @Test func activityLogTranslatesInterpolatedTitles() {
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "Chrome"
        let item = ActivityLog.english("\(name): cache & logs")
        #expect(item.hasPrefix("Chrome: cache & logs"))
        ActivityLog.record(module: "Smart Scan", item: item, size: 1, mode: .delete, home: home)
        let line = ActivityLog.read(home: home).split(separator: "\n")[0]
        let vi = Locale(identifier: "vi"), en = Locale(identifier: "en")
        #expect(ActivityLog.entry(line, locale: vi).item == "Chrome: bộ nhớ đệm & nhật ký")
        #expect(ActivityLog.entry(line, locale: en).item == "Chrome: cache & logs")
        // Put back by Undo: interpolated title + "restored" kind.
        ActivityLog.recordRestored(module: "Smart Scan", item: item, size: 2048, home: home)
        let restored = ActivityLog.entry(ActivityLog.read(home: home).split(separator: "\n")[1], locale: vi)
        #expect(restored.item == "Chrome: bộ nhớ đệm & nhật ký" && restored.kind == "restored" && restored.bytes == 2048)
        // Key no longer in the catalog / arguments don't fit: the stored English text.
        let s = ActivityLog.separator
        let gone = "2026-01-01T00:00:00+07:00\tSmart Scan\tFoo: gone\(s)%@: gone\(s)Foo\(s)Bar\t1\t1 KB\tdeleted"
        #expect(ActivityLog.entry(gone[...], locale: vi).item == "Foo: gone")
        // Written by an older version: plain English, shown as it is.
        let plain = "2026-01-01T00:00:00+07:00\tSmart Scan\tChrome: cache & logs\t1\t1 KB\tdeleted"
        #expect(ActivityLog.entry(plain[...], locale: vi).item == "Chrome: cache & logs")
    }

    /// Disk full or log folder unwritable: cleaning finishes and reports what it removed; the log line is lost.
    @Test func cleaningCompletesWhenTheActivityLogCannotBeWritten() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try file("Library/Logs/CleanMate") // a file where the log folder should be: every write fails
        _ = try file("Library/Caches/a")
        let item = CleanerItem(id: "c", title: "c", paths: ["~/Library/Caches"])
        let scan = await Scanner.scan(item, policy: policy())
        let report = await Cleaner.clean(item, scan: scan, policy: policy())
        ActivityLog.record(module: "Smart Scan", item: "c", count: 1, size: report.freed, mode: .delete, home: home)
        #expect(report.skipped == 0 && report.freed == scan.size && scan.size > 0)
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: "Library/Caches/a").path))
        #expect(ActivityLog.read(home: home).isEmpty)
    }

    @Test func sessionStepperSnapsToEvenSteps() {
        #expect(CleanupAges.sessionSteps.contains(CleanupAges.default.sessions))
        #expect(CleanupAges.sessionStep(from: 30, up: true) == 60)
        #expect(CleanupAges.sessionStep(from: 30, up: false) == 14)
        #expect(CleanupAges.sessionStep(from: 37, up: true) == 60)   // old value from step 7
        #expect(CleanupAges.sessionStep(from: 37, up: false) == 30)
        #expect(CleanupAges.sessionStep(from: 365, up: true) == 365)
        #expect(CleanupAges.sessionStep(from: 7, up: false) == 7)
    }

    /// The add button, drag & drop and "Never Clean This" share one path: folders and regular files,
    /// never packages, symlinks nor missing paths, never twice.
    @Test func addingExcludedKeepsFoldersAndFilesWithoutDuplicates() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = home.appending(path: "Projects")
        let package = home.appending(path: "Tool.app")
        for url in [folder, package] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let file = try file("notes.txt")
        let link = home.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        let existing = home.appending(path: "Old").path
        let added = Preferences.addingExcluded(
            [folder, file, package, link, folder, home.appending(path: "Missing"), home.appending(path: "Projects/")],
            to: [existing])
        #expect(added == [existing, folder.path, file.path])
        #expect(Preferences.addingExcluded([folder], to: added) == added)
    }

    /// Home, "/" and a parent of home are broad; Settings still adds them (after its confirmation row), the
    /// "Never Clean This" menu never does.
    @Test func broadPathsAreDetectedAndNeverExcludedFromTheMenu() {
        let home = URL(fileURLWithPath: "/Users/someone")
        for path in ["/", "/Users", "/Users/", "/Users/someone", "/Users/someone/"] {
            #expect(Preferences.isBroad(URL(fileURLWithPath: path), home: home), "\(path)")
        }
        for path in ["/Users/someone/Library", "/Users/some", "/Applications", "/Users/someoneelse"] {
            #expect(!Preferences.isBroad(URL(fileURLWithPath: path), home: home), "\(path)")
        }
        let realHome = URL(fileURLWithPath: NSHomeDirectory())
        #expect(!Preferences.canExclude(realHome))
        #expect(!Preferences.canExclude(URL(fileURLWithPath: "/")))
        #expect(Preferences.addingExcluded([realHome], to: []) == [realHome.standardizedFileURL.path])
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(Preferences.exclude([realHome], defaults: defaults).isEmpty)
        #expect(defaults.stringArray(forKey: Preferences.excludedFolders) == [])
    }

    /// A throwaway defaults domain: tests never touch the real exclusion list.
    private func scratchDefaults() -> (UserDefaults, String) {
        let name = "CleanMateTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    /// An excluded file is refused like an excluded folder, and so is its parent folder (never excluded itself).
    @Test func excludedFileIsNeverRemovedNorItsParent() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = try file("Library/Caches/App/keep.bin")
        let other = try file("Library/Caches/App/other.bin")
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(Preferences.exclude([kept, home.appending(path: "Tool.app")], defaults: defaults) == [kept])
        #expect(defaults.stringArray(forKey: Preferences.excludedFolders) == [kept.standardizedFileURL.path])
        let policy = SafetyPolicy(home: home, temp: root.appending(path: "tmp"),
                                  excluded: defaults.stringArray(forKey: Preferences.excludedFolders) ?? [])
        #expect(!policy.allows(kept))
        #expect(!policy.allows(kept.deletingLastPathComponent()))
        #expect(policy.allows(other))
        #expect(policy.allows(home.appending(path: "Library/Caches/App/keep.bin.old")))
    }

    /// Smart Scan: "Never Clean This" drops the entry from the item, its total and the selection, and the clean skips it.
    @MainActor @Test func neverCleanDropsSmartScanEntry() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        _ = (try file("Library/Caches/A/data"), try file("Library/Caches/B/data"))
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let item = CleanerItem(id: "c", title: "C", paths: ["~/Library/Caches"], selectableEntries: true)
        let model = SmartScanModel(module: .smartScan) { [CleanerGroup(id: "g", title: "G", systemImage: "x", items: [item])] }
        model.processNames = { [] }
        model.scanItem = { [policy = policy()] in await Scanner.scan($0, policy: policy) }
        model.exclude = { Preferences.exclude($0, defaults: defaults) }
        await model.scan()
        // The scanner's URLs (home resolved through /private), as the row passes them.
        let urls = model.scans["c"]?.entries.map(\.url) ?? []
        try #require(urls.map(\.lastPathComponent).sorted() == ["A", "B"])
        let folderA = try #require(urls.first { $0.lastPathComponent == "A" }), folderB = try #require(urls.first { $0.lastPathComponent == "B" })
        model.setSelected(item, true)
        model.setEntry(item, folderB, false) // left out by hand, then excluded: nothing left ticked
        #expect(model.neverClean(item, folderA))
        #expect(model.scans["c"]?.entries.map(\.url.lastPathComponent) == ["B"])
        #expect(model.total(of: [item]).size == model.scans["c"]?.size)
        #expect(!model.selected.contains("c") && model.excludedEntries["c"] == nil)
        let policy = SafetyPolicy(home: home, temp: root.appending(path: "tmp"),
                                  excluded: defaults.stringArray(forKey: Preferences.excludedFolders) ?? [])
        #expect(!policy.allows(folderA) && policy.allows(folderB))
        // A package can't be excluded: nothing changes.
        #expect(!model.neverClean(item, home.appending(path: "Missing.app")))
        #expect(model.scans["c"]?.entries.count == 1)
    }

    /// Large & Old Files: excluded files leave the list, the ticks and the duplicate groups.
    @MainActor @Test func neverCleanDropsLargeFile() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let big = try file("big.iso"), copy = try file("copy.iso")
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let model = LargeFilesModel()
        model.exclude = { Preferences.exclude($0, defaults: defaults) }
        model.files = [big, copy].map { LargeFile(url: $0, size: 10_000, lastUsed: .now, kind: .other) }
        model.checked = [big, copy]
        model.duplicateGroups = [[big, copy]]
        #expect(model.neverClean([big]))
        #expect(model.files.map(\.url) == [copy] && model.checked == [copy] && model.duplicateGroups == [])
        let policy = SafetyPolicy(home: home, temp: root.appending(path: "tmp"),
                                  excluded: defaults.stringArray(forKey: Preferences.excludedFolders) ?? [])
        #expect(!policy.allows(big) && policy.allows(copy))
    }

    /// Settings › Activity filter: module, search on name or path, and both together.
    @Test func activityFilterByModuleAndSearch() {
        let entries = [
            // Shown in Vietnamese, filtered by the English key.
            ActivityLog.Entry(id: 0, module: "Quét thông minh", moduleKey: "Smart Scan", item: "User caches"),
            ActivityLog.Entry(id: 1, module: "Gỡ ứng dụng", moduleKey: "Uninstaller", item: "/Applications/Sample.app"),
            ActivityLog.Entry(id: 2, module: "Tệp lớn & cũ", moduleKey: "Large & Old Files", item: "/Users/Shared/Trip 2019.mov"),
            ActivityLog.Entry(id: 3, module: "Gỡ ứng dụng", moduleKey: "Uninstaller", item: "/Applications/Other.app"),
        ]
        func ids(_ module: String, _ search: String) -> [Int] {
            ActivitySettings.filter(entries, module: module, search: search).map(\.id)
        }
        #expect(ids("", "") == [0, 1, 2, 3])
        #expect(ids("Uninstaller", "") == [1, 3])
        #expect(ids("", "sample") == [1])           // case-insensitive, matches the path
        #expect(ids("", " /users/shared ") == [2])  // trimmed, any part of the path
        #expect(ids("Uninstaller", "app") == [1, 3])
        #expect(ids("Smart Scan", "app") == [])
        #expect(ids("Gỡ ứng dụng", "") == [])
        #expect(ActivitySettings.modules(entries).map(\.key) == ["Uninstaller", "Smart Scan", "Large & Old Files"])
    }

    /// The broad-exclusion row and "Reset Choices" are also read aloud by VoiceOver, in the app's language.
    @Test func settingsAnnouncementsAreLocalized() {
        let en = Locale(identifier: "en"), vi = Locale(identifier: "vi"), root = URL(fileURLWithPath: "/")
        #expect(ExclusionSettings.broadWarning(root, locale: en) == "Excluding / means CleanMate cleans nothing inside it.")
        #expect(ExclusionSettings.broadWarning(root, locale: vi) == "Nếu loại trừ /, CleanMate sẽ không dọn gì bên trong.")
        #expect(GeneralSettings.resetDone(locale: en) == "Remembered choices reset")
        #expect(GeneralSettings.resetDone(locale: vi) == "Đã đặt lại lựa chọn đã nhớ")
    }
}

/// Smart Scan groups turned off in Settings are neither scanned nor shown; all off = no scan.
@MainActor struct DisabledScanGroupsTests {
    @Test func disabledGroupIsNotScannedNorShown() async {
        let name = "CleanMateTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("dev\nnope", forKey: Preferences.disabledScanGroups)
        let a = CleanerItem(id: "a", title: "A", paths: ["/nonexistent"])
        let b = CleanerItem(id: "b", title: "B", paths: ["/nonexistent"])
        let model = SmartScanModel(module: .smartScan) {
            [CleanerGroup(id: "junk", title: "J", systemImage: "x", items: [a]),
             CleanerGroup(id: "dev", title: "D", systemImage: "x", items: [b])]
        }
        model.disabledGroups = { Preferences.disabledGroups(defaults: defaults) }
        model.processNames = { [] }
        let scanned = OSAllocatedUnfairLock<[String]>(initialState: [])
        model.scanItem = { item in scanned.withLock { $0.append(item.id) }; return ItemScan(measuredSize: 10) }
        await model.scan()
        #expect(scanned.withLock { $0 } == ["a"])
        #expect(model.visibleGroups.map(\.id) == ["junk"] && model.totalItems == 1)
        #expect(model.disabledCount(Preferences.disabledGroups(defaults: defaults)) == 1)

        defaults.set("junk\ndev", forKey: Preferences.disabledScanGroups)
        scanned.withLock { $0 = [] }
        await model.scan()
        #expect(scanned.withLock { $0 }.isEmpty)
        #expect(model.disabledCount(Preferences.disabledGroups(defaults: defaults)) == 2)
        guard case .results = model.phase else { Issue.record("phase \(model.phase)"); return } // last results kept
    }

    /// A group turned off after the scan is hidden, out of the totals and not cleaned; back on, its results return.
    @Test func groupTurnedOffAfterScanIsHiddenAndNotCleaned() async {
        let name = "CleanMateTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let a = CleanerItem(id: "a", title: "A", paths: ["/nonexistent"])
        let b = CleanerItem(id: "b", title: "B", paths: ["/nonexistent"])
        let model = SmartScanModel(module: .smartScan) {
            [CleanerGroup(id: "junk", title: "J", systemImage: "x", items: [a]),
             CleanerGroup(id: "dev", title: "D", systemImage: "x", items: [b])]
        }
        model.disabledGroups = { Preferences.disabledGroups(defaults: defaults) }
        model.processNames = { [] }
        model.appBundleIDs = { [] }
        model.scanItem = { _ in ItemScan(measuredSize: 10) }
        await model.scan()
        #expect(model.visibleGroups.map(\.id) == ["junk", "dev"] && model.selectedSize == 20)

        defaults.set("dev", forKey: Preferences.disabledScanGroups)
        model.refreshDisabled()
        #expect(model.visibleGroups.map(\.id) == ["junk"] && model.selectedSize == 10)

        defaults.removeObject(forKey: Preferences.disabledScanGroups)
        model.refreshDisabled()
        #expect(model.visibleGroups.map(\.id) == ["junk", "dev"] && model.selectedSize == 20) // back, no rescan

        defaults.set("dev", forKey: Preferences.disabledScanGroups) // clean() re-reads the setting itself
        let cleaned = OSAllocatedUnfairLock<[String]>(initialState: [])
        model.cleanItem = { item, _ in cleaned.withLock { $0.append(item.id) }; return CleanReport() }
        await model.clean()
        #expect(cleaned.withLock { $0 } == ["a"])
    }
}
