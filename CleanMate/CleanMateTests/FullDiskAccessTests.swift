import AppKit
import Foundation
import Testing
@testable import CleanMate

/// The Full Disk Access check: one `opendir` of the folder, never a listing; views read a cached answer refreshed
/// off the main thread when the app becomes active.
@Suite(.timeLimit(.minutes(1)))
final class FullDiskAccessTests {
    let root = TestTemp.url("CleanMateFullDiskAccess")

    deinit {
        chmod(root.appending(path: "locked").path, 0o755)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func probeReadsTheFolderWithoutListingIt() throws {
        let empty = root.appending(path: "empty"), full = root.appending(path: "full"), locked = root.appending(path: "locked")
        for folder in [empty, full, locked] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        for index in 0..<50 { try Data().write(to: full.appending(path: "\(index)")) }
        chmod(locked.path, 0)
        #expect(FullDiskAccess.probe(trash: empty.path)) // "." at least
        #expect(FullDiskAccess.probe(trash: full.path))
        #expect(!FullDiskAccess.probe(trash: locked.path)) // what macOS does to ~/.Trash without access
        #expect(!FullDiskAccess.probe(trash: root.appending(path: "missing").path))
    }

    /// Becoming active probes again, off the main thread, and publishes the new answer; the view never probes.
    @MainActor @Test func statusRefreshesOffTheMainThreadWhenTheAppBecomesActive() async {
        let center = NotificationCenter()
        let answer = Locked(false), onMain = Locked<Bool?>(nil)
        let status = FullDiskAccessStatus(granted: false, probe: {
            onMain.withLock { $0 = Thread.isMainThread }
            return answer.withLock { $0 }
        }, center: center)
        #expect(!status.granted)
        answer.withLock { $0 = true }
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await until(status) { $0.granted }
        #expect(onMain.withLock { $0 } == false)
        answer.withLock { $0 = false }
        status.refresh()
        await status.refreshTask?.value
        #expect(!status.granted)
    }
}
