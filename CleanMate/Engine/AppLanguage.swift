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

    /// The locale of CleanMate's own text: the language its strings are shown in (`language`, the bundle's pick from
    /// Settings › General or the Mac's languages) with the Mac's region; the Mac's own locale when the languages match.
    /// `Locale.current` keeps the Mac's language when only CleanMate's is set, so text looked up with it
    /// (`LocalizedStringResource.locale`) came out in English in a Vietnamese CleanMate.
    static func locale(language: String? = Bundle.main.preferredLocalizations.first,
                       current: Locale = .autoupdatingCurrent) -> Locale {
        guard let code = language.flatMap({ Locale.Language(identifier: $0).languageCode?.identifier }),
              code != current.language.languageCode?.identifier else { return current }
        return Locale(identifier: current.region.map { "\(code)_\($0.identifier)" } ?? code)
    }
}
