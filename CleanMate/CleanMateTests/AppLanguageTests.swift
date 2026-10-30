import Foundation
import Testing
@testable import CleanMate

@Suite struct AppLanguageTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let name = "AppLanguageTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func noChoiceFollowsTheMac() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(AppLanguage.current(defaults: defaults, domain: name) == .system)
    }

    @Test func storesAndReadsEachLanguage() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        for language in [AppLanguage.vietnamese, .english] {
            AppLanguage.set(language, defaults: defaults)
            #expect(defaults.stringArray(forKey: AppLanguage.key) == [language.rawValue])
            #expect(AppLanguage.current(defaults: defaults, domain: name) == language)
        }
    }

    @Test func systemRemovesTheKey() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        AppLanguage.set(.vietnamese, defaults: defaults)
        AppLanguage.set(.system, defaults: defaults)
        #expect(defaults.persistentDomain(forName: name)?[AppLanguage.key] == nil)
        #expect(AppLanguage.current(defaults: defaults, domain: name) == .system)
    }

    @Test func regionalOrUnknownCodes() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["vi-VN"], forKey: AppLanguage.key)
        #expect(AppLanguage.current(defaults: defaults, domain: name) == .vietnamese)
        defaults.set(["fr"], forKey: AppLanguage.key)
        #expect(AppLanguage.current(defaults: defaults, domain: name) == .system)
    }
}
