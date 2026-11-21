import CoreServices
import Foundation

/// Moves items to the Trash through Finder (its `delete` Apple Event), which asks for the administrator password for
/// items the user can't move (root's files in /Library, a root-owned app): `NSWorkspace.recycle` only fails on them.
/// macOS asks once to let CleanMate control Finder (`NSAppleEventsUsageDescription`). Put Back in Finder works after.
nonisolated enum FinderTrash {
    enum Failure: Error, Equatable, LocalizedError {
        /// The user turned down Finder control (System Settings › Privacy & Security › Automation).
        case notAllowed
        /// Finder or the Apple Event failed: its error number.
        case failed(Int)

        var errorDescription: String? {
            switch self {
            case .notAllowed: String(localized: "CleanMate may not control Finder (System Settings › Privacy & Security › Automation)")
            case .failed(let code): String(localized: "Finder couldn’t move it to the Trash (error \(code))")
            }
        }
    }

    /// How long Finder may wait for the password before the event gives up.
    static let timeout: TimeInterval = 600

    /// Sends one Finder `delete` of every item in `urls` (one password prompt for all), then finds each moved item in
    /// `trash` by its volume and inode (the name may change there: `x 2.plist`). A cancelled prompt is
    /// `CocoaError.userCancelled`; refused Finder control `Failure.notAllowed`.
    static func move(_ urls: [URL], trash: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash"),
                     send: (NSAppleEventDescriptor) throws -> NSAppleEventDescriptor = sendToFinder)
        -> (moved: [URL: URL], error: Error?) {
        let ids = urls.compactMap { url in SafeRemoval.FileID(url).map { (url, $0) } }
        guard !ids.isEmpty else { return ([:], nil) }
        var failure: Error?
        do {
            let reply = try send(deleteEvent(ids.map(\.0)))
            let code = Int(reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value ?? 0)
            if code != 0 { failure = error(code) }
        } catch {
            failure = Self.error((error as NSError).code)
        }
        let inTrash = Dictionary(((try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? []).compactMap { name in
            let url = trash.appending(path: name)
            return SafeRemoval.FileID(url).map { ($0, url) }
        }, uniquingKeysWith: { first, _ in first })
        var moved: [URL: URL] = [:]
        for (url, id) in ids where SafeRemoval.FileID(url) != id {
            if let found = inTrash[id] { moved[url] = found }
        }
        return (moved, failure)
    }

    /// Finder's `delete` (core/delo) with the items as file URLs.
    static func deleteEvent(_ urls: [URL]) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEDelete),
                                           targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder"),
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        let list = NSAppleEventDescriptor.list()
        for (index, url) in urls.enumerated() { list.insert(NSAppleEventDescriptor(fileURL: url), at: index + 1) }
        event.setParam(list, forKeyword: keyDirectObject)
        return event
    }

    static let sendToFinder: (NSAppleEventDescriptor) throws -> NSAppleEventDescriptor = { event in
        try event.sendEvent(options: [.waitForReply, .canInteract], timeout: timeout)
    }

    /// `userCanceledErr` (-128) → `CocoaError.userCancelled`; `errAEEventNotPermitted` (-1743) → `notAllowed`.
    static func error(_ code: Int) -> Error {
        switch code {
        case -128: CocoaError(.userCancelled)
        case -1743, -1744: Failure.notAllowed
        default: Failure.failed(code)
        }
    }
}
