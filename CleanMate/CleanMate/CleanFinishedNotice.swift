import AppKit
import Foundation

/// "Freed 1.2 GB": a notification when Smart Scan or Privacy finishes cleaning while CleanMate is in the background,
/// so a clean left running while the user works elsewhere is not missed. Only when notifications are already allowed
/// (by the scan reminder or the low-disk warning): it never asks for permission. No network.
enum CleanFinishedNotice {
    /// One request per module: a new clean replaces the last notice of the same module.
    static let smartScanID = "cleanFinished.smartScan"
    static let privacyID = "cleanFinished.privacy"

    /// The module a click on the notice opens; nil for any other notification.
    static func module(forRequestID id: String) -> Module? {
        switch id {
        case smartScanID: .smartScan
        case privacyID: .privacy
        default: nil
        }
    }

    /// nil for a module that cleans nothing (only Smart Scan and Privacy post it).
    static func request(_ report: CleanReport, module: Module, locale: Locale = AppLanguage.locale()) -> ScanReminder.Request? {
        let size = report.freed.formatted(.fileSize.locale(locale))
        func text(_ resource: LocalizedStringResource) -> String {
            var resource = resource
            resource.locale = locale
            return String(localized: resource)
        }
        switch module {
        case .smartScan:
            return ScanReminder.Request(id: smartScanID,
                                        title: report.freed > 0 ? text("Freed \(size)") : text("Cleaning finished"),
                                        body: text("Smart Scan has finished cleaning."), components: nil)
        case .privacy:
            // Browser history and other records have no byte size: the title says what was done instead.
            return ScanReminder.Request(id: privacyID,
                                        title: report.freed > 0 ? text("Freed \(size)") : text("Privacy items erased"),
                                        body: text("Privacy has finished erasing."), components: nil)
        case .overview, .largeFiles, .uninstaller, .spaceLens, .loginItems, .maintenance:
            return nil
        }
    }
}

/// Posts `CleanFinishedNotice` through the scan reminder's notification center.
final class CleanFinishedNotifier {
    /// No center under tests: they must never reach the real notification center.
    static let shared = CleanFinishedNotifier(
        center: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil ? SystemReminderCenter() : nil,
        isActive: { NSApp?.isActive ?? true })

    private let center: (any ReminderCenter)?
    private let isActive: () -> Bool

    init(center: (any ReminderCenter)?, isActive: @escaping () -> Bool) {
        self.center = center
        self.isActive = isActive
    }

    /// Posts the notice when CleanMate is not the active app and notifications are allowed; true when posted.
    /// Never shows the permission prompt.
    @discardableResult
    func post(_ report: CleanReport, module: Module) async -> Bool {
        guard let center, !isActive(), let request = CleanFinishedNotice.request(report, module: module),
              await center.authorization() == .allowed else { return false }
        await center.add(request)
        return true
    }
}
