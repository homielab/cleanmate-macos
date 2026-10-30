import Foundation
import Testing
@testable import CleanMate

/// Final Cut Pro and iMovie render files: one entry per library, only the events' `Render Files` folders measured and
/// deleted, never the library, its media or databases. Everything happens in a throwaway fake home.
final class VideoRenderFilesTests {
    private let fm = FileManager.default
    private let root = TestTemp.url("CleanMateVideoRender")
    private var home: URL { root.appending(path: "home") }
    private var temp: URL { root.appending(path: "tmp") }
    private var policy: SafetyPolicy { SafetyPolicy(home: home, temp: temp) }

    init() throws {
        for dir in ["home", "tmp"] { try fm.createDirectory(at: root.appending(path: dir), withIntermediateDirectories: true) }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    private func file(_ path: String, bytes: Int = 20_000) throws -> URL {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
        return url
    }

    private func exists(_ path: String) -> Bool { fm.fileExists(atPath: home.appending(path: path).path) }

    /// Media and databases of a library: never listed, measured nor removed.
    private let kept = [
        "Movies/Wedding.fcpbundle/CurrentVersion.flexolibrary/db",
        "Movies/Wedding.fcpbundle/Settings.plist",
        "Movies/Wedding.fcpbundle/Day 1/CurrentVersion.fcpevent",
        "Movies/Wedding.fcpbundle/Day 1/Original Media/clip.mov",
        "Movies/Wedding.fcpbundle/Day 1/Transcoded Media/High Quality Media/clip.mov",
        "Movies/Wedding.fcpbundle/Day 1/Analysis Files/a.dat",
        "Movies/Trips/Iceland.imovielibrary/Event/Original Media/clip.mov",
        "Movies/Trips/Iceland.imovielibrary/Event/Render Files.txt",
        "Movies/Too/Deep/Old.fcpbundle/Event/Render Files/r.mov",        // three levels down: not scanned
        "Movies/Wedding.fcpbundle/Day 1/Sub/Render Files/r.mov",         // not an event's own folder
        "Movies/Render Files/r.mov",                                     // not in a library
        "Pictures/Photo.fcpbundle/Event/Render Files/r.mov",             // not a scanned folder
    ]
    private let render = [
        "Movies/Wedding.fcpbundle/Day 1/Render Files/High Quality Media/r1.mov",
        "Movies/Wedding.fcpbundle/Day 2/Render Files/Peaks Data/p.dat",
        "Movies/Trips/Iceland.imovielibrary/Event/Render Files/r.mov",
        "Documents/Edits/Short.fcpbundle/Event/Render Files/r.mov",
        "Desktop/Draft.fcpbundle/Event/Render Files/r.mov",
    ]

    @Test func itemIsUntickedDeletedAndHiddenWhenEmpty() async throws {
        let items = CleanerGroup.applications(hasFullDiskAccess: true).items
        let index = try #require(items.firstIndex { $0.id == VideoRenderFiles.id })
        #expect(items[index - 1].id == "adobe-media-cache")
        let item = items[index]
        #expect(!item.selectedByDefault && item.mode == .delete && !item.showsWhenEmpty && item.note != nil)
        #expect(item.skipsOpenFiles && item.selectableEntries && item.command == nil && item.entryParts != nil)
        let scan = await Scanner.scan(VideoRenderFiles.item(hasFullDiskAccess: { true }), policy: policy,
                                      openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(scan.entries.isEmpty)
    }

    @Test func onlyRenderFilesAreMeasuredAndDeletedOneEntryPerLibrary() async throws {
        for path in kept { try file(path) }
        for path in render { try file(path, bytes: 100_000) }
        let item = VideoRenderFiles.item(hasFullDiskAccess: { true })
        let scan = await Scanner.scan(item, policy: policy, openPaths: EndToEndCleanTests.ownOpenPaths)
        let names = scan.entries.map(\.url.lastPathComponent).sorted()
        #expect(names == ["Draft.fcpbundle", "Iceland.imovielibrary", "Short.fcpbundle", "Wedding.fcpbundle"])
        let wedding = try #require(scan.entries.first { $0.url.lastPathComponent == "Wedding.fcpbundle" })
        var expected: Int64 = 0 // two events' render files, nothing else
        for event in ["Day 1", "Day 2"] {
            let folder = home.appending(path: "Movies/Wedding.fcpbundle/\(event)/Render Files")
            expected += try #require(await Scanner.entry(at: folder, olderThan: nil)).size
        }
        #expect(wedding.size == expected && expected >= 200_000)
        #expect(wedding.title == "Wedding — Final Cut Pro" && wedding.date != nil)
        #expect(scan.entries.first { $0.url.lastPathComponent == "Iceland.imovielibrary" }?.title == "Iceland — iMovie")

        // Only one library ticked: the others keep their render files.
        var picked = scan
        picked.entries = scan.entries.filter { $0.url.lastPathComponent != "Draft.fcpbundle" }
        let report = await Cleaner.clean(item, scan: picked, policy: policy, openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(report.skipped == 0 && report.freed == picked.entries.reduce(0) { $0 + $1.size })
        for path in render where !path.hasPrefix("Desktop/") {
            let folder = path.components(separatedBy: "/Render Files/")[0]
            #expect(!exists(folder + "/Render Files"), "\(path)")
            #expect(exists(folder), "event folder removed: \(folder)")
        }
        #expect(exists(render[4]))
        for path in kept { #expect(exists(path), "\(path)") }
    }

    @Test func excludedLibrariesAndOtherVolumesAreSkipped() async throws {
        for path in render { try file(path) }
        let wedding = home.appending(path: "Movies/Wedding.fcpbundle").path
        let excluded = SafetyPolicy(home: home, temp: temp, excluded: [wedding])
        let item = VideoRenderFiles.item(hasFullDiskAccess: { true })
        var scan = await Scanner.scan(item, policy: excluded, openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(scan.entries.count == 3 && !scan.entries.contains { $0.url.lastPathComponent == "Wedding.fcpbundle" })
        // One excluded event folder keeps its library whole.
        let event = SafetyPolicy(home: home, temp: temp, excluded: [wedding + "/Day 2/Render Files"])
        #expect(!event.allowsVideoLibrary(URL(fileURLWithPath: wedding)))
        // Excluded after the scan: nothing removed.
        scan = await Scanner.scan(item, policy: policy, openPaths: EndToEndCleanTests.ownOpenPaths)
        let report = await Cleaner.clean(item, scan: scan, policy: excluded, openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(report.skipped == 1)
        #expect(exists(render[0]) && exists(render[1]) && !exists(render[2]))

        // A library on another drive (or holding one) is never listed.
        let other = SafetyPolicy(home: home, temp: temp, device: { path in
            path.contains("Draft.fcpbundle") ? 4242 : SafetyPolicy.deviceID(path)
        })
        let library = home.appending(path: "Desktop/Draft.fcpbundle")
        #expect(!other.allowsVideoLibrary(library))
        #expect(!other.allowsRenderFiles(library.appending(path: "Event/Render Files")))
        #expect(other.allowsRenderFiles(URL(fileURLWithPath: wedding + "/Day 1/Render Files")))
    }

    @Test func policyAllowsOnlyAnEventsRenderFilesFolder() throws {
        try file("Movies/A.fcpbundle/Event/Render Files/r.mov")
        try file("Movies/A.fcpbundle/Event/Original Media/clip.mov")
        try file("Movies/A.fcpbundle/.hidden/Render Files/r.mov")
        try file("Movies/.Hidden/B.fcpbundle/Event/Render Files/r.mov")
        try file("Movies/Kit.app/C.fcpbundle/Event/Render Files/r.mov")
        try file("Library/D.fcpbundle/Event/Render Files/r.mov")
        try file("Movies/E.fcpbundle/F.fcpbundle/Render Files/r.mov")
        try file("Elsewhere/Render Files/r.mov")
        try fm.createDirectory(at: home.appending(path: "Movies/Linked.fcpbundle/Event"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: home.appending(path: "Movies/Linked.fcpbundle/Event/Render Files"),
                                  withDestinationURL: home.appending(path: "Elsewhere/Render Files"))
        try fm.createSymbolicLink(at: home.appending(path: "Movies/Alias.fcpbundle"),
                                  withDestinationURL: home.appending(path: "Movies/A.fcpbundle"))
        let url = { (path: String) in self.home.appending(path: path) }
        #expect(policy.allowsRenderFiles(url("Movies/A.fcpbundle/Event/Render Files")))
        #expect(policy.allowsVideoLibrary(url("Movies/A.fcpbundle")))
        for path in ["Movies/A.fcpbundle/Event/Original Media", "Movies/A.fcpbundle/Event", "Movies/A.fcpbundle",
                     "Movies/A.fcpbundle/Event/Render Files/r.mov", "Movies/A.fcpbundle/.hidden/Render Files",
                     "Movies/.Hidden/B.fcpbundle/Event/Render Files", "Movies/Kit.app/C.fcpbundle/Event/Render Files",
                     "Library/D.fcpbundle/Event/Render Files", "Movies/E.fcpbundle/F.fcpbundle/Render Files",
                     "Movies/Linked.fcpbundle/Event/Render Files", "Elsewhere/Render Files"] {
            #expect(!policy.allowsRenderFiles(url(path)), "\(path)")
        }
        #expect(!policy.allowsVideoLibrary(url("Movies/Alias.fcpbundle")))
        #expect(!policy.allowsVideoLibrary(url("Library/D.fcpbundle")))
        #expect(VideoRenderFiles.libraries(in: [url("Movies")], home: home, hasFullDiskAccess: true)
            .map(\.lastPathComponent).sorted() == ["A.fcpbundle", "E.fcpbundle", "Linked.fcpbundle"])
    }

    @Test func nothingIsListedWithoutFullDiskAccess() async throws {
        for path in render { try file(path) }
        let scan = await Scanner.scan(VideoRenderFiles.item(hasFullDiskAccess: { false }), policy: policy,
                                      openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(scan.entries.isEmpty)
    }

    @MainActor @Test func lockedWhileFinalCutProOrIMovieRuns() throws {
        let item = VideoRenderFiles.item(hasFullDiskAccess: { true })
        let model = SmartScanModel(module: .smartScan) { [] }
        model.runningApps = ["com.apple.Photos", "com.apple.QuickTimePlayerX"]
        model.runningProcesses = ["Photos", "QuickTime Player", "Compressor"]
        #expect(!model.isLocked(item))
        for id in ["com.apple.FinalCut", "com.apple.FinalCutTrial", "com.apple.iMovieApp"] {
            model.runningApps = [id]
            #expect(model.isLocked(item), "\(id)")
        }
        model.runningApps = []
        for name in ["Final Cut Pro", "Final Cut Pro Trial", "iMovie"] {
            model.runningProcesses = [name]
            #expect(model.isLocked(item), "\(name)")
        }
    }
}
