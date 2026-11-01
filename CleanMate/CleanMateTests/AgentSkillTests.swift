import Foundation
import Testing
@testable import CleanMate

/// The Agent Skill in `skills/cleanmate/` stays in step with the command: valid frontmatter, every example command
/// parses with options `cleanmate --help` lists and item ids from the catalog, and its JSON samples decode as the
/// reports the command prints.
struct AgentSkillTests {
    static let folder = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "skills/cleanmate")

    static func text(_ name: String) throws -> String {
        try String(contentsOf: folder.appending(path: name), encoding: .utf8)
    }

    /// `cleanmate …` commands in code blocks and inline code, without the program name and any `# comment`.
    static func commands(in text: String) -> [[String]] {
        var snippets: [String] = []
        var inCode = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") { inCode.toggle(); continue }
            if inCode { snippets.append(String(line)); continue }
            snippets += line.split(separator: "`", omittingEmptySubsequences: false).enumerated()
                .filter { $0.offset % 2 == 1 }.map { String($0.element) }
        }
        return snippets.compactMap { snippet in
            let code = snippet.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
            let words = code.split(whereSeparator: \.isWhitespace).map(String.init)
            return words.first == "cleanmate" && words.count > 1 ? Array(words.dropFirst()) : nil
        }
    }

    @Test func skillHasValidFrontmatter() throws {
        let text = try Self.text("SKILL.md")
        let parts = text.components(separatedBy: "---\n")
        try #require(text.hasPrefix("---\n") && parts.count >= 3)
        var fields: [String: String] = [:]
        for line in parts[1].split(separator: "\n") {
            let pair = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2 { fields[pair[0]] = pair[1] }
        }
        // agentskills.io: `name` matches the folder, lowercase letters, digits and hyphens, ≤ 64; `description` ≤ 1024.
        #expect(fields["name"] == Self.folder.lastPathComponent)
        #expect(fields["name"]?.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" } == true)
        let description = try #require(fields["description"])
        #expect(!description.isEmpty && description.count <= 1024)
        #expect(description.contains("free up disk space") && description.contains("disk is full"))
        #expect(text.contains("](reference.md)"))
    }

    @Test func exampleCommandsMatchTheCommandLineTool() throws {
        var ids = Set(CleanerGroup.smartScan(ages: .default, hasFullDiskAccess: true).flatMap(\.items).map(\.id))
        ids.formUnion(CleanerGroup.privacy().flatMap(\.items).map(\.id))
        var count = 0
        for name in ["SKILL.md", "reference.md"] {
            for arguments in Self.commands(in: try Self.text(name)) {
                count += 1
                let parsed = try? CommandLineTool.parse(arguments)
                #expect(parsed != nil, "\(name): cleanmate \(arguments.joined(separator: " ")) does not parse")
                for flag in arguments where flag.hasPrefix("-") {
                    #expect(CommandLineTool.help.contains(flag), "\(name): \(flag) is not in --help")
                }
                for (flag, value) in zip(arguments, arguments.dropFirst()) {
                    let values = value.split(separator: ",").map(String.init)
                    if flag == "--only" && value != "ID,ID" {
                        for id in values { #expect(ids.contains(id), "\(name): unknown item \(id)") }
                    }
                    if flag == "--group" {
                        for group in values { #expect(HeadlessScan.groupNames.contains(group), "\(name): unknown group \(group)") }
                    }
                }
            }
        }
        #expect(count >= 10)
        // The rules the skill exists for.
        let skill = try Self.text("SKILL.md")
        for rule in ["Never install anything yourself", "Always scan first", "--privacy", "selectedByDefault",
                     "clean --yes", "Contents/Helpers/cleanmate", "~/Library/Logs/CleanMate/activity.log"] {
            #expect(skill.contains(rule), "\(rule)")
        }
    }

    @Test func jsonSamplesDecodeAsReports() throws {
        let text = try Self.text("reference.md")
        let blocks = text.components(separatedBy: "```json\n").dropFirst().map { $0.components(separatedBy: "```").first ?? "" }
        try #require(blocks.count == 2)
        let scan = try JSONDecoder().decode(HeadlessScan.Report.self, from: Data(blocks[0].utf8))
        #expect(scan.items.contains { $0.locked })
        let clean = try JSONDecoder().decode(HeadlessClean.Report.self, from: Data(blocks[1].utf8))
        #expect(!clean.dryRun && clean.log == "~/Library/Logs/CleanMate/activity.log")
    }
}
