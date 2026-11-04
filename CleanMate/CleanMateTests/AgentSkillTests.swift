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
                     "clean --yes", "Contents/Helpers/cleanmate", "~/Library/Logs/CleanMate/activity.log",
                     "cleanmate space --json", "cleanmate large --json", "cleanmate dupes --json", "cleanmate similar --json", "Never delete or move these files yourself",
                     "cleanmate trash --yes", "only with the exact paths they confirmed", "cleanmate restore",
                     "cleanmate restore --list --json", "cleanmate uninstall --json", "cleanmate privacy --json",
                     "cleanmate login-items --json", "never asks for a password", "Never kill it yourself"] {
            #expect(skill.contains(rule), "\(rule)")
        }
    }

    /// Options as `--name`, outside longer words.
    static func options(in text: String) -> Set<String> {
        Set(text.matches(of: /(?:^|[^\w-])(--[a-z][a-z-]*)/).map { String($0.output.1) })
    }

    @Test func referenceListsEveryOptionOfHelp() throws {
        let reference = Self.options(in: try Self.text("reference.md"))
        let help = Self.options(in: CommandLineTool.help)
        #expect(help.count >= 15)
        #expect(help.subtracting(reference).isEmpty, "in --help but not in reference.md: \(help.subtracting(reference).sorted())")
        #expect(reference.subtracting(help).isEmpty, "in reference.md but not in --help: \(reference.subtracting(help).sorted())")
    }

    @Test func jsonSamplesDecodeAsReports() throws {
        let text = try Self.text("reference.md")
        let blocks = text.components(separatedBy: "```json\n").dropFirst().map { $0.components(separatedBy: "```").first ?? "" }
        try #require(blocks.count == 12)
        let scan = try JSONDecoder().decode(HeadlessScan.Report.self, from: Data(blocks[0].utf8))
        #expect(scan.items.contains { $0.locked })
        let clean = try JSONDecoder().decode(HeadlessClean.Report.self, from: Data(blocks[1].utf8))
        #expect(!clean.dryRun && clean.log == "~/Library/Logs/CleanMate/activity.log")
        let space = try JSONDecoder().decode(HeadlessFiles.SpaceReport.self, from: Data(blocks[2].utf8))
        #expect(space.items.contains { $0.skipped && $0.size == nil } && space.skipped.count == 1)
        let large = try JSONDecoder().decode(HeadlessFiles.LargeReport.self, from: Data(blocks[3].utf8))
        #expect(large.files.count == large.count && large.files.contains { $0.lastUsed == nil })
        let dupes = try JSONDecoder().decode(HeadlessFiles.DupesReport.self, from: Data(blocks[4].utf8))
        #expect(dupes.groups.count == dupes.count && dupes.wasted == dupes.groups.reduce(0) { $0 + $1.wasted })
        let similar = try JSONDecoder().decode(HeadlessFiles.SimilarReport.self, from: Data(blocks[5].utf8))
        #expect(similar.groups.count == similar.count && similar.freeable == similar.groups.reduce(0) { $0 + $1.freeable })
        #expect(similar.groups.allSatisfy { group in
            group.count == group.photos.count && group.photos.map(\.suggested) == [true] + Array(repeating: false, count: group.count - 1)
                && group.freeable == group.photos.dropFirst().reduce(0) { $0 + $1.size }
        })
        let trash = try JSONDecoder().decode(HeadlessTrash.TrashReport.self, from: Data(blocks[6].utf8))
        let moved = trash.items.filter { !$0.skipped }
        #expect(moved.count == trash.count && trash.size == moved.compactMap(\.size).reduce(0, +))
        #expect(moved.allSatisfy { $0.trashed != nil } && trash.items.filter(\.skipped).allSatisfy { $0.reason != nil && $0.trashed == nil })
        let restore = try JSONDecoder().decode(HeadlessTrash.RestoreReport.self, from: Data(blocks[7].utf8))
        #expect(restore.items.filter { !$0.skipped }.count == restore.count && restore.items.contains { $0.path == nil })
        // The trashed path trash prints is what restore takes.
        #expect(restore.items.first?.trashed == moved.first?.trashed)
        let list = try JSONDecoder().decode(HeadlessTrash.ListReport.self, from: Data(blocks[8].utf8))
        #expect(list.version == trash.version && list.count == list.items.count && list.items.first?.trashed == moved.first?.trashed)
        #expect(list.items.allSatisfy { $0.date != nil } && list.items.map(\.date) == list.items.map(\.date).sorted(by: { ($0 ?? "") > ($1 ?? "") }))
        let apps = try JSONDecoder().decode(HeadlessApps.ListReport.self, from: Data(blocks[9].utf8))
        #expect(apps.apps.contains { $0.running } && apps.apps.contains { $0.lastUsed == nil })
        #expect(apps.leftoversSize == apps.leftovers.reduce(0) { $0 + $1.size })
        let sources = Set(InstalledApp.Source.allCases.map(\.rawValue))
        #expect(apps.apps.allSatisfy { sources.contains($0.source) })
        let privacy = try JSONDecoder().decode(HeadlessPrivacy.Report.self, from: Data(blocks[10].utf8))
        #expect(privacy.items.contains { $0.skipped && $0.reason != nil } && privacy.items.contains { $0.signsOut })
        #expect(privacy.total == privacy.items.filter { $0.selectedByDefault && !$0.skipped }.reduce(0) { $0 + $1.size })
        #expect(privacy.items.allSatisfy { $0.signsOut == HeadlessPrivacy.signsOut($0.id) })
        let login = try JSONDecoder().decode(HeadlessLoginItems.ListReport.self, from: Data(blocks[11].utf8))
        #expect(login.count == login.items.count && login.items.contains { $0.removable } && login.items.contains { !$0.removable })
        for json in [blocks[9], blocks[10], blocks[11]] { #expect(json.contains("\"durationMs\"")) }
    }
}
