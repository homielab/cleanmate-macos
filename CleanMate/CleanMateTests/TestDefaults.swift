import Foundation
@testable import CleanMate

/// Throwaway defaults domains for tests. A suite name that is an absolute path keeps its plist there instead of in
/// ~/Library/Preferences (`removePersistentDomain` empties a domain but leaves its file, so every run would add one
/// to the developer's Mac); `TestTemp` sweeps any a crashed run left behind.
enum TestDefaults {
    /// A new suite name such as `$TMPDIR/CleanMateMenuBarTests-<uuid>`; pass it to `UserDefaults(suiteName:)`.
    static func suite(_ prefix: String) -> String { TestTemp.url(prefix).path }

    static func remove(_ suite: String) {
        TestDefaults.remove(suite)
        CFPreferencesAppSynchronize(suite as CFString)
        try? FileManager.default.removeItem(atPath: suite + ".plist")
    }
}

extension SmartScanModel {
    /// A model that ignores the ticks remembered on this Mac (`Preferences.overrides`), so results don't depend on
    /// what was clicked in the app here. Tests use it instead of `init`.
    static func isolated(module: Module, catalog: (() -> [CleanerGroup])? = nil) -> SmartScanModel {
        let model = SmartScanModel(module: module, catalog: catalog)
        model.selectionOverrides = { [:] }
        return model
    }
}
