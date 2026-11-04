import Foundation
import Testing
@testable import CleanMate

/// `docs/FEATURES.md` lists every Smart Scan and Privacy item by the id `cleanmate list` prints.
struct FeaturesDocTests {
    static let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "docs/FEATURES.md")

    @Test func everyCatalogItemIdIsDocumented() throws {
        let text = try String(contentsOf: Self.url, encoding: .utf8)
        var ids = CleanerGroup.smartScan(ages: .default, hasFullDiskAccess: true).flatMap(\.items).map(\.id)
        ids += CleanerGroup.privacy().flatMap(\.items).map(\.id)
        #expect(ids.count > 200)
        let missing = ids.filter { !text.contains("`\($0)`") }
        #expect(missing.isEmpty, "not in docs/FEATURES.md: \(missing)")
    }

    @Test func tableOfContentsLinksExist() throws {
        let text = try String(contentsOf: Self.url, encoding: .utf8)
        let anchors = Set(text.split(separator: "\n").filter { $0.hasPrefix("## ") || $0.hasPrefix("### ") }.map { line in
            line.drop(while: { $0 == "#" }).dropFirst().lowercased()
                .filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_" }
                .replacingOccurrences(of: " ", with: "-")
        })
        let links = text.matches(of: /\]\(#([a-z0-9_-]+)\)/).map { String($0.output.1) }
        #expect(links.count >= 15)
        for link in links { #expect(anchors.contains(link), "no heading for #\(link)") }
    }
}
