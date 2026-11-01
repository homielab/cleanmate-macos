import Foundation
import Testing
@testable import CleanMate

/// Privacy › System: Gatekeeper's download history and the Recent Items lists, in a fake home; the real
/// ~/Library is never read and no real app counts as running.
final class PrivacySystemTests {
    let fm = FileManager.default
    let root = TestTemp.url("CleanMatePrivacySystem")
    var home: URL { root.appending(path: "home") }
    var policy: SafetyPolicy { SafetyPolicy(home: home, temp: root.appending(path: "tmp")) }
    var lists: URL { home.appending(path: "Library/Application Support/com.apple.sharedfilelist") }
    var appLists: URL { lists.appending(path: RecentItems.appFolderName) }
    var quarantine: URL { home.appending(path: "Library/Preferences/" + CleanerGroup.quarantineEvents) }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func write(_ url: URL) throws -> URL {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 2048).write(to: url)
        return url
    }

    func system() throws -> [CleanerItem] {
        try #require(CleanerGroup.privacy(runningApps: { [] }).first { $0.id == "privacy-system" }).items
    }

    /// Both items sit in System, unticked, deleted permanently, hidden when empty.
    @Test func systemGroupHasBothItemsUnticked() throws {
        let items = try system()
        for id in [RecentItems.id, "quarantine-history"] {
            let item = try #require(items.first { $0.id == id }, "\(id)")
            #expect(!item.selectedByDefault && item.mode == .delete && !item.showsWhenEmpty, "\(id)")
        }
        #expect(items.filter { $0.id == RecentItems.id }.count == 1)
    }

    /// Only the LSQuarantineEvent records go: the database stays, other preferences are not listed, and a database
    /// a process has open is kept at scan and at clean.
    @Test func quarantineHistoryErasesRecordsKeepsDatabase() async throws {
        let insert = (1...3).map { "INSERT INTO LSQuarantineEvent VALUES('id\($0)', 'https://site.example/f\($0).zip');" }.joined()
        _ = try await sqlite(quarantine, """
            CREATE TABLE LSQuarantineEvent (LSQuarantineEventIdentifier TEXT PRIMARY KEY NOT NULL, LSQuarantineDataURLString TEXT);
            CREATE TABLE other(id); INSERT INTO other VALUES(1);
            """ + insert)
        let plist = try write(home.appending(path: "Library/Preferences/com.apple.finder.plist"))
        let item = try #require(try system().first { $0.id == "quarantine-history" })
        #expect(item.skipsOpenFiles)

        let scan = await Scanner.scan(item, policy: policy, openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(scan.entries.map(\.url.lastPathComponent) == [CleanerGroup.quarantineEvents])
        #expect(scan.records == 3 && scan.size == 0 && scan.hasData)

        // Opened since the scan (LaunchServices recording a download): kept.
        let handle = try FileHandle(forReadingFrom: quarantine)
        #expect(await Scanner.scan(item, policy: policy, openPaths: EndToEndCleanTests.ownOpenPaths).entries.isEmpty)
        #expect(await Cleaner.clean(item, scan: scan, policy: policy, openPaths: EndToEndCleanTests.ownOpenPaths).skipped == 1)
        #expect(try await sqlite(quarantine, "SELECT count(*) FROM LSQuarantineEvent;") == "3")
        try handle.close()

        #expect(await Cleaner.clean(item, scan: scan, policy: policy, openPaths: EndToEndCleanTests.ownOpenPaths).skipped == 0)
        #expect(try await sqlite(quarantine, "SELECT (SELECT count(*) FROM LSQuarantineEvent) || ',' || (SELECT count(*) FROM other);") == "0,1")
        #expect(fm.fileExists(atPath: quarantine.path) && fm.fileExists(atPath: plist.path))
        #expect(await Scanner.scan(item, policy: policy, openPaths: EndToEndCleanTests.ownOpenPaths).hasData == false)
    }

    /// The Apple menu's Recent* lists and every app's Open Recent list are listed (one row each); the Finder sidebar
    /// lists, other files, folders and the list of an open app are not. An app opened after the scan keeps its list.
    @Test func recentItemsListsOnlyRecentLists() async throws {
        let listed = [
            lists.appending(path: "com.apple.LSSharedFileList.RecentApplications.sfl2"),
            lists.appending(path: "com.apple.LSSharedFileList.RecentDocuments.sfl3"),
            lists.appending(path: "com.apple.LSSharedFileList.RecentServers.sfl4"),
            appLists.appending(path: "com.apple.textedit.sfl3"),
            appLists.appending(path: "org.example.editor.sfl4"),
        ]
        let kept = [
            lists.appending(path: "com.apple.LSSharedFileList.FavoriteItems.sfl2"),
            lists.appending(path: "com.apple.LSSharedFileList.FavoriteVolumes.sfl3"),
            lists.appending(path: "com.apple.LSSharedFileList.iCloudItems.sfl3"),
            lists.appending(path: "com.apple.LSSharedFileList.ProjectsItems.sfl4"),
            lists.appending(path: "com.apple.LSSharedFileList.NetworkBrowser.sfl4"),
            lists.appending(path: "com.apple.LSSharedFileList.RecentDocuments.plist"),
            lists.appending(path: "notes.sfl3"),
            appLists.appending(path: "com.example.running.sfl3"), // open app
            appLists.appending(path: "com.example.running.helper.sfl3"), // its helper
            appLists.appending(path: "readme.txt"),
            appLists.appending(path: "folder.sfl3/inside.sfl3"),
        ]
        for url in listed + kept { try write(url) }
        try fm.createSymbolicLink(at: appLists.appending(path: "link.sfl3"), withDestinationURL: kept[0])

        let item = RecentItems.item(runningApps: { ["com.Example.Running"] }, appURL: { _ in nil })
        #expect(item.selectableEntries && !item.selectedByDefault && item.mode == .delete)
        let scan = await Scanner.scan(item, policy: policy)
        let found = Set(scan.entries.map { $0.url.resolvingSymlinksInPath().path })
        #expect(found == Set(listed.map { $0.resolvingSymlinksInPath().path }))
        let titles = Dictionary(uniqueKeysWithValues: scan.entries.map { ($0.url.lastPathComponent, $0.title) })
        #expect(titles["org.example.editor.sfl4"] == "org.example.editor")
        #expect(titles.values.allSatisfy { $0 != nil })

        // Excluded in Settings: the app lists are not listed, the Apple menu's still are.
        let excluding = SafetyPolicy(home: home, temp: root.appending(path: "tmp"), excluded: [appLists.path])
        let allowed = await Scanner.scan(item, policy: excluding).entries.map(\.url.lastPathComponent)
        #expect(Set(allowed) == Set(listed.prefix(3).map(\.lastPathComponent)))

        // TextEdit opened since the scan: its list stays, the rest go.
        let later = RecentItems.item(runningApps: { ["com.apple.TextEdit"] }, appURL: { _ in nil })
        #expect(await Cleaner.clean(later, scan: scan, policy: policy).skipped == 1)
        for url in listed { #expect(fm.fileExists(atPath: url.path) == (url.lastPathComponent == "com.apple.textedit.sfl3"), "\(url.lastPathComponent)") }
        for url in kept { #expect(fm.fileExists(atPath: url.path), "\(url.lastPathComponent)") }
        #expect(fm.fileExists(atPath: appLists.path))
    }

    /// The app's name when installed, else its bundle id; the Apple menu lists by what they hold.
    @Test func recentItemsLabels() throws {
        let app = appLists.appending(path: "com.apple.textedit.sfl3")
        let named = RecentItems.label(of: app) { _ in URL(fileURLWithPath: "/Applications/TextEdit.app") }
        #expect(named?.title == "TextEdit")
        #expect(RecentItems.label(of: app) { _ in nil }?.title == "com.apple.textedit")
        #expect(RecentItems.label(of: lists.appending(path: "com.apple.LSSharedFileList.RecentServers.sfl4")) { _ in nil }?.title != nil)
        #expect(RecentItems.label(of: lists.appending(path: "com.apple.LSSharedFileList.RecentOther.sfl4")) { _ in nil } == nil)
    }

    /// A list's path is checked against its folder: a Recent* name elsewhere, or an app list outside the shared file
    /// list folder, is not one.
    @Test func recentListOnlyInItsFolders() throws {
        let stray = try write(home.appending(path: "Library/com.apple.LSSharedFileList.RecentDocuments.sfl3"))
        let nested = try write(home.appending(path: "x/\(RecentItems.appFolderName)/com.example.app.sfl3"))
        let real = try write(appLists.appending(path: "com.example.app.sfl3"))
        #expect(!RecentItems.isRecentList(stray) && !RecentItems.isRecentList(nested) && RecentItems.isRecentList(real))
    }
}
