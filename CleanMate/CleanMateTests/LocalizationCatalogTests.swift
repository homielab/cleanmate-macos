import Foundation
import Testing

/// Every translatable key in Localizable.xcstrings has a translated `vi` entry.
struct LocalizationCatalogTests {
    static let catalogURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("CleanMate/Localizable.xcstrings")

    /// Problems in one localization node: every stringUnit must be `translated`;
    /// plural variations need at least `other` (the only plural category Vietnamese has).
    static func problems(_ node: [String: Any]) -> [String] {
        var out: [String] = []
        if let unit = node["stringUnit"] as? [String: Any] {
            let state = unit["state"] as? String ?? "nil"
            if state != "translated" { out.append("state=\(state)") }
        }
        if let variations = node["variations"] as? [String: [String: [String: Any]]] {
            if let plural = variations["plural"], plural["other"] == nil { out.append("plural thiếu 'other'") }
            for (kind, cases) in variations {
                for (name, sub) in cases { out += problems(sub).map { "\(kind).\(name): \($0)" } }
            }
        }
        if node["stringUnit"] == nil && node["variations"] == nil { out.append("rỗng") }
        return out
    }

    @Test func everyKeyHasTranslatedVietnamese() throws {
        let data = try Data(contentsOf: Self.catalogURL)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: [String: Any]])
        #expect(!strings.isEmpty)

        var missing: [String] = []
        for (key, entry) in strings where entry["shouldTranslate"] as? Bool != false {
            let localizations = entry["localizations"] as? [String: [String: Any]]
            guard let vi = localizations?["vi"] else { missing.append("\(key): không có vi"); continue }
            missing += Self.problems(vi).map { "\(key): \($0)" }
        }
        #expect(missing.isEmpty, "Thiếu bản vi (\(missing.count)):\n\(missing.sorted().joined(separator: "\n"))")
    }
}
