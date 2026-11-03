import Foundation

/// One entry or item a clean, delete, uninstall or reset left in place, and why: shown on the done screens
/// ("N items couldn't be cleaned") and written to the activity log as a "failed" line with the reason.
nonisolated struct CleanFailure: Sendable, Equatable {
    /// What was left; nil for a whole item run by a tool (`docker image prune`), named by `title`.
    var url: URL?
    /// The catalog item it belongs to, when known (`Cleaner.clean` fills it in).
    var title: LocalizedStringResource?
    var reason: Reason

    init(_ url: URL?, _ reason: Reason, title: LocalizedStringResource? = nil) {
        self.url = url
        self.reason = reason
        self.title = title
    }

    enum Reason: Sendable, Equatable {
        /// EPERM / EACCES: macOS refused (no Full Disk Access, System Integrity Protection, not the user's file).
        case notPermitted
        /// An app holds it open or runs from it.
        case inUse
        /// Locked in Finder (`Scanner.isLocked`).
        case locked
        /// Its volume has no Trash (a network share, some external drives).
        case noTrash
        /// An iCloud Drive file whose content is not downloaded.
        case notDownloaded
        /// Its volume is read-only.
        case readOnly
        /// Replaced since it was checked: a symlink or another item in its place (`SafeRemoval.Failure.changed`).
        case changed
        /// Written to since the scan (an item's `minAge`), so kept.
        case modified
        /// What reached the Trash is not the item checked (`SafeRemoval.Failure.movedOther`).
        case movedOther
        /// The safety policy or Settings › Exclusions keeps it.
        case refused
        /// Kept by the item's own rule, said by this text (a running app's data, a version still in use).
        case kept(String)
        /// The tool the item needs is not installed any more, or not running (Docker stopped since the scan).
        case toolMissing(String)
        case notRunning(String)
        /// The tool's command failed: exit code and the last line it printed to standard error.
        case command(ShellCommand.Failure)
        /// Any other error: the system's description.
        case other(String)

        /// From an errno of a failed system call.
        static func errno(_ code: Int32) -> Reason {
            switch code {
            case EPERM, EACCES: .notPermitted
            case EBUSY, ETXTBSY: .inUse
            case EROFS: .readOnly
            default: .other(String(cString: strerror(code)))
            }
        }

        /// From what a removal or move threw (`SafeRemoval.Failure`, a Cocoa or POSIX error of `FileManager`).
        /// `url`: an error that doesn't say why is read as "not downloaded" for an iCloud file not on disk.
        static func from(_ error: Error, at url: URL? = nil) -> Reason {
            if let failure = error as? SafeRemoval.Failure {
                switch failure {
                case .changed: return .changed
                case .refused: return .refused
                case .locked: return .locked
                case .movedOther: return .movedOther
                case .failed(let code): return errno(code)
                }
            }
            if let failure = error as? ShellCommand.Failure { return .command(failure) }
            let error = error as NSError
            if error.domain == NSPOSIXErrorDomain { return errno(Int32(error.code)) }
            if error.domain == NSCocoaErrorDomain {
                switch error.code {
                case NSFileWriteNoPermissionError, NSFileReadNoPermissionError: return .notPermitted
                case NSFileWriteVolumeReadOnlyError: return .readOnly
                case NSFileLockingError: return .inUse
                // FileManager.trashItem on a volume without a Trash.
                case NSFeatureUnsupportedError: return .noTrash
                case NSUbiquitousFileUnavailableError, NSUbiquitousFileNotUploadedDueToQuotaError: return .notDownloaded
                default:
                    if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
                        let reason = errno(Int32(underlying.code))
                        if case .other = reason {} else { return reason }
                    }
                }
            }
            if let url, isNotDownloaded(url) { return .notDownloaded }
            return .other(error.localizedDescription)
        }

        /// An iCloud Drive item whose content is not on this Mac.
        static func isNotDownloaded(_ url: URL) -> Bool {
            guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
                  values.isUbiquitousItem == true else { return false }
            return values.ubiquitousItemDownloadingStatus != .current
        }

        /// Why, for the user.
        var text: LocalizedStringResource {
            switch self {
            case .notPermitted: "Not permitted: macOS blocked access"
            case .inUse: "In use by an app"
            case .locked: "Locked in Finder"
            case .noTrash: "This drive has no Trash"
            case .notDownloaded: "In iCloud, not downloaded to this Mac"
            case .readOnly: "The drive is read-only"
            case .changed: "Replaced since it was checked"
            case .modified: "Changed since the scan"
            case .movedOther: "Something else went to the Trash in its place"
            case .refused: "Kept by CleanMate’s safety rules or your exclusions"
            case .kept(let rule): "Kept: \(rule)"
            case .toolMissing(let tool): "“\(tool)” is not installed"
            case .notRunning(let tool): "“\(tool)” is not running"
            case .command(let failure):
                switch failure.kind {
                case .notInstalled: "“\(failure.tool)” is not installed"
                case .notReady: "“\(failure.tool)” is not running"
                case .timedOut: "“\(failure.tool)” took too long and was stopped"
                case .cancelled: "“\(failure.tool)” was cancelled"
                case .notStarted(let code): "“\(failure.tool)” couldn’t start: \(String(cString: strerror(code)))"
                case .killed(let signal): "“\(failure.tool)” was stopped by signal \(Int(signal))"
                case .exited(let code):
                    if let line = failure.lastLine {
                        "“\(failure.tool)” exited with code \(Int(code)): \(line)"
                    } else {
                        "“\(failure.tool)” exited with code \(Int(code))"
                    }
                }
            case .other(let message): "\(message)"
            }
        }

        /// What the user can do about it.
        var hint: LocalizedStringResource {
            switch self {
            case .notPermitted: "Grant CleanMate Full Disk Access in System Settings, then try again."
            case .inUse: "Quit the app using it, then try again."
            case .locked: "Turn off Locked in Finder › Get Info, then try again."
            case .noTrash: "Delete it in Finder instead."
            case .notDownloaded: "Download it in Finder first, or remove it there."
            case .readOnly: "Nothing can be removed from this drive."
            case .changed, .modified: "Scan again, then try again."
            case .movedOther: "Check the Trash: the item there is not the one that was checked."
            case .refused: "Check Settings › Exclusions."
            case .kept: "It stays while this is true; try again later."
            case .toolMissing: "Install it again, or scan again."
            case .notRunning: "Start it, then try again."
            case .command(let failure):
                switch failure.kind {
                case .notInstalled: "Install it again, or scan again."
                case .notReady: "Start it, then try again."
                default: "Try again in a moment; if it keeps failing, run the tool in Terminal to see why."
                }
            case .other: "Try again."
            }
        }

        /// Asks for Full Disk Access: the list offers its settings.
        var needsFullDiskAccess: Bool { self == .notPermitted }

        /// Kept as "skipped" in the activity log, not "failed": nothing went wrong, it changed since the scan.
        var isSkip: Bool { self == .changed || self == .modified }
    }
}

extension CleanFailure.Reason {
    /// `text` as a sentence, then `hint`, in the app's language: one line for an alert.
    nonisolated var explanation: String {
        let text = String(localized: text)
        let end = text.last.map { ".!?…".contains($0) } == true ? "" : "."
        return text + end + " " + String(localized: hint)
    }

    /// `text` in English for the activity log's reason column (`ActivityLog.english`: shown translated again).
    nonisolated var logText: String { ActivityLog.english(text) }

    /// `text` in English, for `cleanmate clean --json`.
    nonisolated var english: String {
        var english = text
        english.locale = Locale(identifier: "en")
        return String(localized: english)
    }
}
