import Foundation
import Testing
@testable import CleanMate

/// Large & Old Files › Remove Download, against a throwaway fake home: iCloud states are injected and nothing is
/// ever evicted for real.
final class ICloudDownloadsTests {
    let root = TestTemp.url("CleanMateICloud")
    var home: URL { root.appending(path: "home") }
    var policy: SafetyPolicy { SafetyPolicy(home: home, temp: root.appending(path: "tmp")) }
    var drive: URL { home.appending(path: "Library/Mobile Documents") }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func file(_ path: String, bytes: Int = 20_000) throws -> URL {
        let url = home.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
        return url
    }

    @Test(arguments: [
        // ubiquitous, uploaded, uploading, downloading, conflicts, excluded → state
        (false, true, false, false, false, false, ICloudStatus?.none),
        (true, true, false, false, false, false, .uploaded),
        (true, false, false, false, false, false, .notUploaded),
        (true, true, false, false, false, true, .notUploaded),
        (true, false, true, false, false, false, .syncing),
        (true, true, false, true, false, false, .syncing),
        (true, true, false, false, true, false, .conflict),
        (true, false, true, true, true, false, .conflict),
    ])
    func statusComesFromTheICloudKeys(ubiquitous: Bool, uploaded: Bool, uploading: Bool, downloading: Bool,
                                      conflicts: Bool, excluded: Bool, expected: ICloudStatus?) {
        let status = ICloudStatus(isUbiquitous: ubiquitous, isUploaded: uploaded, isUploading: uploading,
                                  isDownloading: downloading, hasConflicts: conflicts, excludedFromSync: excluded)
        #expect(status == expected)
        #expect(status?.allowsRemovingDownload ?? false == (expected == .uploaded))
    }

    /// iCloud Drive as Finder shows it (CloudDocs, an app's Documents) takes Remove Download; an app's private data,
    /// hidden items, symlinks and the rest of ~/Library don't, and nothing in iCloud Drive may go to the Trash.
    @Test func policyAllowsRemovingDownloadsOnlyInICloudDriveAndUserFolders() throws {
        for path in ["Library/Mobile Documents/com~apple~CloudDocs/a.mov", "Library/Mobile Documents/com~apple~CloudDocs/F/b.zip",
                     "Library/Mobile Documents/iCloud~md~obsidian/Documents/c.pdf", "Desktop/d.mov", "Documents/e.iso"] {
            #expect(policy.allowsICloudDownload(try file(path)), "\(path)")
        }
        for path in ["Library/Mobile Documents/iCloud~md~obsidian/Data/db.sqlite", "Library/Mobile Documents/x.mov",
                     "Library/Mobile Documents/com~apple~CloudDocs/.hidden/x.mov",
                     "Library/Mobile Documents/com~apple~CloudDocs/.x.mov",
                     "Library/Mobile Documents/com~apple~CloudDocs/A.app/Contents/x.mov",
                     "Library/CloudStorage/Dropbox/x.mov", "Library/Caches/x.mov", ".ssh/x"] {
            #expect(!policy.allowsICloudDownload(try file(path)), "\(path)")
        }
        let link = drive.appending(path: "com~apple~CloudDocs/link.mov")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: drive.appending(path: "com~apple~CloudDocs/a.mov"))
        #expect(!policy.allowsICloudDownload(link))
        #expect(!policy.allowsICloudDownload(drive.appending(path: "com~apple~CloudDocs/F")))
        #expect(!policy.allowsICloudDownload(URL(fileURLWithPath: "/etc/hosts")))
        // Never the Trash, never Smart Scan.
        let inDrive = drive.appending(path: "com~apple~CloudDocs/a.mov")
        #expect(!policy.allowsUserFile(inDrive) && !policy.allows(inDrive) && !policy.allowsSpaceLensItem(inDrive))
        // An exclusion wins.
        let excluding = SafetyPolicy(home: home, temp: root.appending(path: "tmp"),
                                     excluded: [drive.appending(path: "com~apple~CloudDocs/F").path])
        #expect(!excluding.allowsICloudDownload(drive.appending(path: "com~apple~CloudDocs/F/b.zip")))
        #expect(excluding.allowsICloudDownload(inDrive))
    }

    /// The home scan takes in iCloud Drive's downloaded files (not trashable, with their state) only when it may
    /// read it (Full Disk Access); a folder scope never does.
    @Test func homeScanListsICloudDriveOnlyWithFullDiskAccess() async throws {
        let movie = try file("Library/Mobile Documents/com~apple~CloudDocs/Trip/movie.mov")
        let pending = try file("Library/Mobile Documents/com~apple~CloudDocs/new.zip")
        let appDoc = try file("Library/Mobile Documents/iCloud~com~app/Documents/book.pdf")
        try file("Library/Mobile Documents/iCloud~com~app/Data/store.db")
        try file("Library/Mobile Documents/com~apple~CloudDocs/local-only.bin") // not an iCloud item: left out
        let desktop = try file("Desktop/clip.mov")
        let plain = try file("Downloads/setup.dmg")
        let states: [String: ICloudStatus] = [
            movie.lastPathComponent: .uploaded, pending.lastPathComponent: .syncing, appDoc.lastPathComponent: .uploaded,
            "store.db": .uploaded, desktop.lastPathComponent: .uploaded,
        ]
        let status: @Sendable (URL) -> ICloudStatus? = { states[$0.lastPathComponent] }
        let found = try await LargeFileScanner.scan(root: home, minSize: 10_000, policy: policy, icloudStatus: status)
        let byName = Dictionary(found.map { ($0.name, $0) }) { a, _ in a }
        #expect(Set(byName.keys) == ["movie.mov", "new.zip", "book.pdf", "clip.mov", "setup.dmg"])
        #expect(byName["movie.mov"]?.icloud == .uploaded && byName["movie.mov"]?.trashable == false)
        #expect(byName["new.zip"]?.icloud == .syncing && byName["new.zip"]?.trashable == false)
        #expect(byName["book.pdf"]?.trashable == false)
        #expect(byName["clip.mov"]?.icloud == .uploaded && byName["clip.mov"]?.trashable == true)
        #expect(byName["setup.dmg"]?.icloud == nil && byName["setup.dmg"]?.trashable == true)
        _ = plain

        let limited = try await LargeFileScanner.scan(
            root: home, minSize: 10_000, policy: policy,
            skipping: ProtectedFolders.skipped(home: home, hasFullDiskAccess: false), icloudStatus: status)
        #expect(limited.isEmpty) // Desktop, Downloads and iCloud Drive all need Full Disk Access
        let folder = try await LargeFileScanner.scan(root: home.appending(path: "Desktop"), minSize: 10_000,
                                                     policy: policy, icloudStatus: status)
        #expect(folder.map(\.name) == ["clip.mov"])
    }

    /// Only a file iCloud says is fully uploaded, read again right before, loses its download; the others are kept
    /// with their state, and each removal is logged with the size measured right before.
    @MainActor @Test func removeEvictsOnlyUploadedFilesAndLogsThem() async throws {
        let uploaded = try file("Library/Mobile Documents/com~apple~CloudDocs/a.mov")
        let syncing = try file("Library/Mobile Documents/com~apple~CloudDocs/b.mov")
        let conflict = try file("Library/Mobile Documents/com~apple~CloudDocs/c.mov")
        let notUploaded = try file("Desktop/d.mov")
        let refusing = try file("Documents/e.mov")
        let outside = try file("Library/Caches/f.mov")
        let states: [String: ICloudStatus] = ["a.mov": .uploaded, "b.mov": .syncing, "c.mov": .conflict,
                                              "d.mov": .notUploaded, "e.mov": .uploaded, "f.mov": .uploaded]
        let evicted = Locked([String]())
        let report = await ICloudDownloads.remove(
            [uploaded, syncing, conflict, notUploaded, refusing, outside], policy: policy,
            status: { states[$0.lastPathComponent] }, size: { _ in 4_096_000 },
            evict: { url in
                if url.lastPathComponent == "e.mov" { throw CocoaError(.fileWriteUnknown) }
                evicted.withLock { $0.append(url.lastPathComponent) }
            })
        #expect(evicted.withLock { $0 } == ["a.mov"]) // never asked for the others
        #expect(report.removed == [uploaded] && report.freed == 4_096_000)
        #expect(report.kept[syncing] == .some(.syncing) && report.kept[conflict] == .some(.conflict))
        #expect(report.kept[notUploaded] == .some(.notUploaded) && report.kept[refusing] == .some(.uploaded))
        #expect(report.kept[outside] == .some(nil))
        // Nothing deleted nor moved.
        for url in [uploaded, syncing, conflict, notUploaded, refusing, outside] {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        let lines = ActivityLog.read(home: home).split(separator: "\n")
        #expect(lines.count == 1 && lines[0].contains("\tevicted\t") && lines[0].contains(uploaded.path))
        #expect(ActivityLog.freed(home: home).deleted == 4_096_000)
        #expect(ActivityLog.cleanups(home: home).total == 4_096_000)
        let evictedLabel = ActivitySettings.kindLabel("evicted", locale: Locale(identifier: "vi"))
        #expect(evictedLabel.title == "Đã bỏ bản tải về (vẫn trên iCloud)")
    }

    /// The model only removes downloads with Full Disk Access and of uploaded files; removed rows leave the list,
    /// kept ones show the state read right before. iCloud Drive rows are never ticked for the Trash.
    @MainActor @Test func modelRemovesDownloadsAndNeverTicksICloudDriveFiles() async throws {
        let model = LargeFilesModel()
        let f = { (path: String, icloud: ICloudStatus?, trashable: Bool) in
            LargeFile(url: URL(fileURLWithPath: path), size: 500_000_000, lastUsed: .now, kind: .video,
                      icloud: icloud, trashable: trashable)
        }
        let (a, b, c, d) = (f("/drive/a.mov", .uploaded, false), f("/drive/b.mov", .uploaded, false),
                            f("/drive/c.mov", .syncing, false), f("/Desktop/d.mov", .uploaded, true))
        model.files = [a, b, c, d]
        model.phase = .results
        model.setVisibleChecked(true)
        #expect(model.checked == [d.url] && model.allVisibleChecked)
        model.checked.insert(a.url) // even if a tick got there, the Trash never takes it
        #expect(model.checkedFiles.map(\.url) == [d.url])
        #expect(Set(model.removableDownloads([a.url, c.url, d.url]).map(\.url)) == [a.url, d.url])

        let asked = Locked([URL]())
        model.removeDownloadFiles = { urls in
            asked.withLock { $0 = urls }
            return ICloudDownloads.Report(removed: [a.url, d.url], freed: 1_000_000_000, kept: [b.url: .some(.syncing)])
        }
        model.hasFullDiskAccess = { false }
        await model.removeDownloads(of: [a, b, c, d])
        #expect(asked.withLock { $0 }.isEmpty && model.files.count == 4 && model.downloadsRemoved == nil)

        model.hasFullDiskAccess = { true }
        await model.removeDownloads(of: [a, b, c, d])
        #expect(asked.withLock { $0 } == [a.url, b.url, d.url]) // never the syncing one
        #expect(model.files.map(\.url) == [b.url, c.url])
        #expect(model.files.first?.icloud == .syncing)
        #expect(!model.checked.contains(d.url) && !model.checked.contains(a.url))
        #expect(model.downloadsRemoved?.freed == 1_000_000_000 && model.downloadRemovals == 1)
    }
}
