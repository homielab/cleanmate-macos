import Foundation
import Testing
@testable import CleanMate

/// An app's files in the system Library (launch daemons, privileged helpers…), against a throwaway fake `/Library`;
/// nothing real is moved and no password is asked.
final class UninstallerSystemTests {
    let root = TestTemp.url("CleanMateUninstallerSystem")
    deinit { try? FileManager.default.removeItem(at: root) }
    var home: URL { root.appending(path: "home") }
    var library: URL { root.appending(path: "Library") }
    var policy: SafetyPolicy { SafetyPolicy(home: home, temp: root.appending(path: "tmp"), systemLibrary: library) }
    let app = InstalledApp(url: URL(filePath: "/nonexistent/AnyDesk.app"), name: "AnyDesk", bundleID: "com.philandro.anydesk",
                           version: nil, lastUsed: nil)

    @discardableResult
    func make(_ path: String, in base: URL? = nil, folder: Bool = false) throws -> URL {
        let url = (base ?? library).appending(path: path)
        if folder {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 4_000).write(to: url)
        }
        return url
    }

    /// Moves like `NSWorkspace.recycle` into a fake Trash (a rename keeps the inode), counting the calls.
    final class FakeRecycle: @unchecked Sendable {
        let trash: URL
        private let lock = NSLock()
        private(set) var calls: [[URL]] = []
        init(trash: URL) { self.trash = trash }

        func move(_ urls: [URL]) -> (moved: [URL: URL], error: Error?) {
            lock.withLock { calls.append(urls) }
            try? FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            var moved: [URL: URL] = [:]
            for url in urls {
                let target = trash.appending(path: url.lastPathComponent)
                if (try? FileManager.default.moveItem(at: url, to: target)) != nil { moved[url] = target }
            }
            return (moved, nil)
        }
    }

    @Test func policyAllowsOnlyBundleIDEntriesOfTheSystemFolders() throws {
        for path in ["LaunchDaemons/com.foo.bar.Helper.plist", "LaunchAgents/com.foo.bar.plist",
                     "PrivilegedHelperTools/com.foo.bar.Helper", "Preferences/com.foo.bar.plist"] {
            #expect(policy.allowsSystemAppData(try make(path)), "\(path)")
        }
        #expect(policy.allowsSystemAppData(try make("Application Support/com.foo.bar", folder: true)))
        // Vendor folders, hidden or Apple items, the folders themselves, deeper items, other folders, symlinks.
        let refused = [try make("Application Support/Microsoft", folder: true), try make("LaunchDaemons/.com.foo.bar.plist"),
                       try make("LaunchDaemons/com.apple.foo.plist"), library.appending(path: "LaunchDaemons"),
                       try make("Application Support/com.foo.bar/com.foo.bar.plist"), try make("Extensions/com.foo.bar.kext"),
                       try make("Logs/foo bar.log")]
        let link = library.appending(path: "PrivilegedHelperTools/com.foo.bar.link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home)
        for url in refused + [link] { #expect(!policy.allowsSystemAppData(url), "\(url.path)") }
        // Without a system Library (every test policy unless given one), nothing; an excluded entry neither.
        let plain = SafetyPolicy(home: home, temp: root.appending(path: "tmp"))
        #expect(!plain.allowsSystemAppData(library.appending(path: "LaunchDaemons/com.foo.bar.Helper.plist")))
        let excluded = SafetyPolicy(home: home, temp: root.appending(path: "tmp"),
                                    excluded: [library.appending(path: "LaunchDaemons").path], systemLibrary: library)
        #expect(!excluded.allowsSystemAppData(library.appending(path: "LaunchDaemons/com.foo.bar.Helper.plist")))
        // The home rules never allow them.
        #expect(!policy.allowsAppData(library.appending(path: "LaunchDaemons/com.foo.bar.Helper.plist")))
    }

    @Test func appListsItsSystemFilesByBundleIDOnly() async throws {
        let own = ["LaunchAgents/com.philandro.anydesk.Frontend.plist", "LaunchDaemons/com.philandro.anydesk.Helper.plist",
                   "LaunchDaemons/com.philandro.anydesk.service.plist", "PrivilegedHelperTools/com.philandro.anydesk.Helper"]
        for path in own { try make(path) }
        // Not its: a shared prefix, another app's id, a name folder, another release channel.
        for path in ["LaunchDaemons/com.philandro.anydeskpro.plist", "LaunchDaemons/com.carriez.RustDesk_service.plist",
                     "LaunchDaemons/com.philandro.anydesk.beta.plist"] { try make(path) }
        try make("Application Support/AnyDesk", folder: true)
        try make("Preferences/com.philandro.anydesk.plist", in: home.appending(path: "Library"))

        let entries = await Uninstaller.data(of: app, otherBundleIDs: [], tools: [:], policy: policy)
        let system = entries.filter(\.system)
        #expect(Set(system.map { "\($0.folder)/\($0.url.lastPathComponent)" }) == Set(own))
        #expect(system.allSatisfy { $0.kind == .data && $0.location.hasPrefix("/Library/") })
        #expect(system.first { $0.folder == "LaunchDaemons" }?.location == "/Library/LaunchDaemons")
        #expect(entries.contains { !$0.system && $0.url.lastPathComponent == "com.philandro.anydesk.plist" })
        // The app row counts them; Reset never offers them.
        let matches = await Uninstaller.dataMatches(of: [app], otherBundleIDs: [], tools: [:], policy: policy)
        #expect(Set(matches[app.url] ?? []) == Set(entries.map(\.url)))
        #expect(UninstallerModel.resetItems(entries).allSatisfy { !$0.system })
        // A longer installed bundle id claims its own.
        let claimed = await Uninstaller.data(of: app, otherBundleIDs: ["com.philandro.anydesk.Helper"], tools: [:], policy: policy)
        #expect(!claimed.contains { $0.url.lastPathComponent.hasPrefix("com.philandro.anydesk.Helper") })
        // An app without a real bundle id gets none.
        let vague = InstalledApp(url: URL(filePath: "/nonexistent/Phil.app"), name: "Phil", bundleID: "com.philandro",
                                 version: nil, lastUsed: nil)
        #expect(await Uninstaller.data(of: vague, otherBundleIDs: [], tools: [:], policy: policy).allSatisfy { !$0.system })
    }

    @Test func systemFilesMoveInOneRecycleWithoutUndo() async throws {
        let daemon = try make("LaunchDaemons/com.philandro.anydesk.Helper.plist")
        let helper = try make("PrivilegedHelperTools/com.philandro.anydesk.Helper")
        let prefs = try make("Preferences/com.philandro.anydesk.plist", in: home.appending(path: "Library"))
        let data = [AppDataEntry(url: daemon, size: 10, system: true), AppDataEntry(url: helper, size: 20, system: true),
                    AppDataEntry(url: prefs, size: 5)]
        let fake = FakeRecycle(trash: root.appending(path: "Trash"))
        let homeMoves = Locked<[URL]>([])
        let report = try await Uninstaller.trash(app: nil, data: data, policy: policy, launchctl: { _ in true },
                                                 moveToTrash: { url in homeMoves.withLock { $0.append(url) }; return nil },
                                                 recycleAll: { fake.move($0) }, isRunning: { _ in false })
        #expect(fake.calls.count == 1 && Set(fake.calls[0].map(\.lastPathComponent)) == [daemon.lastPathComponent, helper.lastPathComponent])
        #expect(homeMoves.withLock { $0 }.map(\.lastPathComponent) == [prefs.lastPathComponent])
        #expect(!FileManager.default.fileExists(atPath: daemon.path) && !FileManager.default.fileExists(atPath: helper.path))
        #expect(report.freed == 35 && report.skipped == 0)
        #expect(!report.trashed.contains { $0.original == daemon || $0.original == helper })
    }

    @Test func cancelledPasswordLeavesSystemFiles() async throws {
        let daemon = try make("LaunchDaemons/com.philandro.anydesk.Helper.plist")
        let outside = try make("com.philandro.anydesk.plist", in: home) // not in a system folder: never moved
        let report = try await Uninstaller.trash(
            app: nil, data: [AppDataEntry(url: daemon, size: 10, system: true), AppDataEntry(url: outside, size: 1, system: true)],
            policy: policy, launchctl: { _ in true }, moveToTrash: { _ in nil },
            recycleAll: { _ in ([:], CocoaError(.userCancelled)) }, isRunning: { _ in false })
        #expect(FileManager.default.fileExists(atPath: daemon.path) && report.freed == 0 && report.skipped == 2)
        #expect(report.failures.contains { $0.reason == .kept(String(localized: "the admin password was not given")) })
        #expect(report.failures.contains { $0.reason == .refused })
    }
}

/// `FinderTrash` with a fake Finder: no Apple Event is sent and the real Trash is never touched.
final class FinderTrashTests {
    let root = TestTemp.url("CleanMateFinderTrash")
    deinit { try? FileManager.default.removeItem(at: root) }
    var trash: URL { root.appending(path: "Trash") }

    func file(_ name: String) throws -> URL {
        let url = root.appending(path: "Library/LaunchDaemons/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: url)
        return url
    }

    /// The file URLs a Finder `delete` event carries.
    static func targets(_ event: NSAppleEventDescriptor) -> [URL] {
        guard let list = event.paramDescriptor(forKeyword: keyDirectObject) else { return [] }
        return (0..<list.numberOfItems).compactMap { list.atIndex($0 + 1)?.fileURLValue }
    }

    @Test func oneDeleteFindsEachItemInTheTrashByInode() throws {
        let a = try file("com.foo.bar.plist"), b = try file("com.foo.bar.helper.plist")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try Data([2]).write(to: trash.appending(path: "com.foo.bar.plist")) // same name already in the Trash
        var events = 0
        let result = FinderTrash.move([a, b], trash: trash) { event in
            events += 1
            #expect(event.eventClass == AEEventClass(kAECoreSuite) && event.eventID == AEEventID(kAEDelete))
            let urls = Self.targets(event)
            #expect(urls.map(\.lastPathComponent) == [a.lastPathComponent, b.lastPathComponent])
            for (index, url) in urls.enumerated() {
                try FileManager.default.moveItem(at: url, to: self.trash.appending(path: "moved \(index)"))
            }
            return NSAppleEventDescriptor.null()
        }
        #expect(events == 1 && result.error == nil)
        #expect(result.moved[a]?.lastPathComponent == "moved 0" && result.moved[b]?.lastPathComponent == "moved 1")
    }

    @Test func cancelledOrRefusedMovesNothing() throws {
        let a = try file("com.foo.bar.plist")
        let cancelled = FinderTrash.move([a], trash: trash) { _ in throw NSError(domain: NSOSStatusErrorDomain, code: -128) }
        #expect(cancelled.moved.isEmpty && (cancelled.error as? CocoaError)?.code == .userCancelled)
        let refused = FinderTrash.move([a], trash: trash) { _ in
            let reply = NSAppleEventDescriptor.record()
            reply.setParam(NSAppleEventDescriptor(int32: -1743), forKeyword: keyErrorNumber)
            return reply
        }
        #expect(refused.moved.isEmpty && refused.error as? FinderTrash.Failure == .notAllowed)
        #expect(FileManager.default.fileExists(atPath: a.path))
    }
}
