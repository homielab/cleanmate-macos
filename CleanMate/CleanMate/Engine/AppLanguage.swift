import Foundation

/// Language CleanMate uses, chosen in Settings › General. Stored as the app's own `AppleLanguages`
/// (read by Foundation at launch), so a change applies after a restart and the system language is never touched.
nonisolated enum AppLanguage: String, CaseIterable, Identifiable {
    case system, english = "en", vietnamese = "vi"

    var id: String { rawValue }

    static let key = "AppleLanguages"

    /// The choice stored in the app's own defaults (`domain`); `system` when none or an unsupported one is set.
    /// Reads that domain only: `UserDefaults` lookups also see the Mac's own list, which is not a choice.
    static func current(defaults: UserDefaults = .standard,
                        domain: String = Bundle.main.bundleIdentifier ?? "") -> AppLanguage {
        guard let codes = defaults.persistentDomain(forName: domain)?[key] as? [String],
              let code = codes.first else { return .system }
        return AppLanguage(rawValue: String(code.prefix(2))) ?? .system
    }

    /// Stores the choice; `system` removes the key so CleanMate follows the Mac again.
    static func set(_ language: AppLanguage, defaults: UserDefaults = .standard) {
        if language == .system {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set([language.rawValue], forKey: key)
        }
    }

    /// The choice CleanMate started with: the picker shows Restart once the stored one differs.
    @MainActor static let atLaunch = current()
}
