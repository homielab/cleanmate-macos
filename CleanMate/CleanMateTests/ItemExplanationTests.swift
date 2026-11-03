import Foundation
import Testing
@testable import CleanMate

/// Every cleaner item explains itself ("Why is this safe?") in English and Vietnamese, and the explanation follows
/// the item's own rules.
struct ItemExplanationTests {
    static var allItems: [CleanerItem] {
        CleanerGroup.smartScan(ages: .default, hasFullDiskAccess: true).flatMap(\.items)
            + CleanerGroup.privacy().flatMap(\.items)
    }

    static func vietnamese() throws -> [String: String] {
        let data = try Data(contentsOf: LocalizationCatalogTests.catalogURL)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: [String: Any]])
        var out: [String: String] = [:]
        for (key, entry) in strings {
            let vi = (entry["localizations"] as? [String: Any])?["vi"] as? [String: Any]
            if let value = (vi?["stringUnit"] as? [String: Any])?["value"] as? String {
                out[key] = value
            } else if vi?["variations"] != nil {
                out[key] = key
            }
        }
        return out
    }

    @Test func everyItemSaysWhatItIsInBothLanguages() throws {
        let vi = try Self.vietnamese()
        var missing: [String] = []
        for item in Self.allItems {
            let explanation = ItemExplanation(item) { $0 }
            guard let what = explanation.what, !String(localized: what).isEmpty else {
                missing.append("\(item.id): no description"); continue
            }
            let keys = [what] + explanation.afterClean + explanation.skippedWhen + [explanation.locationNote].compactMap { $0 }
            for key in keys.map(\.key) where vi[key]?.isEmpty != false {
                missing.append("\(item.id): no Vietnamese for \"\(key)\"")
            }
            #expect(!explanation.paths.isEmpty || explanation.locationNote != nil, "\(item.id): no location")
            #expect(!explanation.afterClean.isEmpty && !explanation.skippedWhen.isEmpty)
        }
        #expect(missing.isEmpty, "\(missing.count):\n\(missing.joined(separator: "\n"))")
    }

    /// A custom per-entry skip rule must be described in "Skipped when".
    @Test func everySkipRuleIsExplained() {
        let missing = Self.allItems.filter { $0.skipsEntry != nil && $0.skipNote == nil }.map(\.id)
        #expect(missing.isEmpty, "skipsEntry without skipNote: \(missing)")
    }

    @Test func followsTheItemsRules() throws {
        let items = Dictionary(uniqueKeysWithValues: Self.allItems.map { ($0.id, $0) })
        let backups = ItemExplanation(try #require(items["device-backups"])) { $0 }
        #expect(backups.afterClean.map(\.key).contains("Moved to the Trash: you can put it back until you empty the Trash"))
        #expect(backups.afterClean.map(\.key).contains("Not ticked by default: it is cleaned only if you tick it"))
        let derived = ItemExplanation(try #require(items["xcode-derived-data"])) { _ in "Xcode" }
        #expect(derived.paths == ["~/Library/Developer/Xcode/DerivedData"])
        let skipped = derived.skippedWhen.map { String(localized: $0) }
        #expect(skipped.contains("While Xcode is open") && skipped.contains("While xcodebuild runs"))
        let temp = ItemExplanation(try #require(items["temp-files"])) { $0 }
        #expect(temp.skippedWhen.map { String(localized: $0) }.contains("Anything changed in the last 3 days"))
        #expect(temp.skippedWhen.map(\.key).contains("Files a program has open"))
    }
}
