import Foundation
import Testing
@testable import CleanMate

@Suite struct AppLanguageTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let name = TestDefaults.suite("CleanMateAppLanguageTests")
        return (UserDefaults(suiteName: name)!, name)
    }

    /// Vietnamese CleanMate on an English Mac: text in Vietnamese, the Mac's region kept; the Mac's own locale (and its
    /// format settings) whenever the languages match or none is known.
    @Test func localeIsInCleanMatesLanguage() {
        let mac = Locale(identifier: "en_US")
        #expect(AppLanguage.locale(language: "vi", current: mac).identifier == "vi_US")
        #expect(AppLanguage.locale(language: "en", current: mac) == mac)
        #expect(AppLanguage.locale(language: nil, current: mac) == mac)
        #expect(AppLanguage.locale(language: "en", current: Locale(identifier: "vi_VN")).identifier == "en_VN")
        #expect(AppLanguage.locale(language: "vi", current: Locale(identifier: "vi_VN")).identifier == "vi_VN")
    }

    @Test func noChoiceFollowsTheMac() {
        let (defaults, name) = makeDefaults()
        defer { TestDefaults.remove(name) }
        #expect(AppLanguage.current(defaults: defaults, domain: name) == .system)
    }

    @Test func storesAndReadsEachLanguage() {
        let (defaults, name) = makeDefaults()
        defer { TestDefaults.remove(name) }
        for language in [AppLanguage.vietnamese, .english] {
            AppLanguage.set(language, defaults: defaults)
            #expect(defaults.stringArray(forKey: AppLanguage.key) == [language.rawValue])
            #expect(AppLanguage.current(defaults: defaults, domain: name) == language)
        }
    }

    @Test func systemRemovesTheKey() {
        let (defaults, name) = makeDefaults()
        defer { TestDefaults.remove(name) }
        AppLanguage.set(.vietnamese, defaults: defaults)
        AppLanguage.set(.system, defaults: defaults)
        #expect(defaults.persistentDomain(forName: name)?[AppLanguage.key] == nil)
        #expect(AppLanguage.current(defaults: defaults, domain: name) == .system)
    }

    @Test func regionalOrUnknownCodes() {
        let (defaults, name) = makeDefaults()
        defer { TestDefaults.remove(name) }
        defaults.set(["vi-VN"], forKey: AppLanguage.key)
        #expect(AppLanguage.current(defaults: defaults, domain: name) == .vietnamese)
        defaults.set(["fr"], forKey: AppLanguage.key)
        #expect(AppLanguage.current(defaults: defaults, domain: name) == .system)
    }
}
