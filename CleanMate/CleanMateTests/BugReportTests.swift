import Foundation
import Testing
@testable import CleanMate

/// Help › Report a Bug…: the report text never holds the user name or a personal path, and the link carries it intact.
struct BugReportTests {
    static let home = "/Users/jdoe"

    /// One activity log line as `ActivityLog` writes it.
    static func line(_ date: String, _ module: String, _ item: String, bytes: Int64, kind: String) -> String {
        [date, module, item, "1", "\(bytes) bytes", kind, String(bytes)].joined(separator: "\t")
    }

    static var report: BugReport {
        BugReport(version: "1.4", build: "5", macOS: "27.2 (26C100)", chip: "Apple M2 Pro", appleSilicon: true,
                  fullDiskAccess: true, language: "vi", languageChoice: .vietnamese, homebrewCask: false,
                  home: home, userNames: ["jdoe", "Jane Doe", "Jane", "Doe"])
    }

    @Test func bodyListsTheMacAndApp() {
        let body = Self.report.body
        #expect(body.contains("CleanMate: 1.4 (5)"))
        #expect(body.contains("macOS: 27.2 (26C100)"))
        #expect(body.contains("Mac: Apple M2 Pro, Apple Silicon"))
        #expect(body.contains("Full Disk Access: granted"))
        #expect(body.contains("App language: vi (chosen in Settings)"))
        #expect(body.contains("Installed with: not Homebrew (DMG or other)"))
        #expect(body.contains("Recent activity: none"))

        var intel = Self.report
        intel.chip = ""
        intel.appleSilicon = false
        intel.fullDiskAccess = false
        intel.homebrewCask = nil
        intel.languageChoice = .system
        #expect(intel.body.contains("Mac: Intel"))
        #expect(intel.body.contains("Full Disk Access: not granted"))
        #expect(intel.body.contains("Installed with: unknown"))
        #expect(intel.body.contains("(follows the Mac)"))
    }

    @Test func activityKeepsNamesAndSizesButNoPersonalPaths() {
        let log = [
            Self.line("2026-10-30T09:00:00+07:00", "Smart Scan", "User caches", bytes: 1_200_000_000, kind: "deleted"),
            Self.line("2026-10-30T09:01:00+07:00", "Large Files", "/Users/jdoe/Documents/tax 2025.pdf", bytes: 5_000_000, kind: "trashed"),
            Self.line("2026-10-30T09:02:00+07:00", "Uninstaller", "/Applications/Foo Bar.app", bytes: 80_000_000, kind: "trashed"),
            Self.line("2026-10-30T09:03:00+07:00", "Smart Scan", "~/Library/Application Support/CleanMate/cache.db", bytes: 10, kind: "deleted"),
            Self.line("2026-10-30T09:04:00+07:00", "Maintenance", "Rebuild Spotlight", bytes: 0, kind: "ran"),
            "not a log line",
        ].joined(separator: "\n")
        let lines = BugReport.activity(log, home: Self.home)
        #expect(lines.count == 5)
        #expect(lines[0].contains("Smart Scan  User caches  1.2 GB  deleted"))
        #expect(lines[1].contains("Large Files  (file or folder)"))
        #expect(!lines[1].contains("tax"))
        #expect(lines[2].contains("Foo Bar.app"))
        #expect(!lines[2].contains("/Applications"))
        #expect(lines[3].contains("~/Library/Application Support/CleanMate/cache.db"))
        #expect(lines[4].hasSuffix("Maintenance  Rebuild Spotlight  ran"))
    }

    @Test func activityKeepsOnlyTheLastLines() {
        let log = (0..<9).map { Self.line("2026-10-30T09:0\($0):00Z", "Smart Scan", "Item \($0)", bytes: 1, kind: "deleted") }
            .joined(separator: "\n")
        let lines = BugReport.activity(log, home: Self.home)
        #expect(lines.count == BugReport.activityLines)
        #expect(lines.first?.contains("Item 4") == true)
        #expect(lines.last?.contains("Item 8") == true)
    }

    @Test func bodyHidesTheUserNameAndHome() {
        var report = Self.report
        report.activity = [
            "2026-10-30 09:00  Uninstaller  Jane's Notes  1 MB  trashed",
            "2026-10-30 09:01  Smart Scan  Cache of /Users/jdoe/Projects and /Users/someone/x  1 MB  deleted",
            "2026-10-30 09:02  Smart Scan  JDOE backups, Doe-Lab, Doughnut  1 MB  deleted",
        ]
        let body = report.body
        #expect(!body.contains("/Users/jdoe"))
        #expect(!body.contains("/Users/someone"))
        #expect(!body.lowercased().contains("jdoe"))
        #expect(!body.contains("Jane"))
        #expect(body.contains("<user>'s Notes"))
        #expect(body.contains("Cache of ~/Projects and /Users/<user>/x"))
        #expect(body.contains("<user> backups, <user>-Lab, Doughnut"))
    }

    @Test func shortUserNamesDoNotRewriteTheFixedLines() {
        var report = Self.report
        report.userNames = ["mac", "Intel", "app"]
        report.activity = ["2026-10-30 09:00  Smart Scan  App caches of mac  1 MB  deleted"]
        let body = report.body
        #expect(body.contains("Mac: Apple M2 Pro"))
        #expect(body.contains("App language: vi"))
        #expect(body.contains("<user> caches of <user>"))
    }

    @Test func linkCarriesTheWholeReport() throws {
        var report = Self.report
        report.activity = ["2026-10-30 09:00  Smart Scan  C++ & Rust: caches = 100% #1  1 MB  deleted"]
        let url = report.issueURL
        #expect(url.absoluteString.hasPrefix("https://github.com/homielab/cleanmate-macos/issues/new?template=bug_report.yml&system="))
        #expect(!url.absoluteString.contains("+"))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.map(\.name) == ["template", "system"])
        #expect(items.last?.value == report.body)
    }

    @Test func tooLongReportLeavesTheLinkBare() {
        var report = Self.report
        // 1 000 characters that encode to 6 000: the link is what must stay short.
        report.activity = [String(repeating: "é", count: 1_000)]
        #expect(report.body.count < BugReport.maxLinkLength)
        #expect(!report.fitsLink)
        #expect(report.issueURL.absoluteString == "https://github.com/homielab/cleanmate-macos/issues/new?template=bug_report.yml")
        #expect(Self.report.fitsLink)
    }

    @Test func currentReportDescribesThisMacWithoutItsUser() {
        let report = BugReport.current()
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #expect(report.macOS.hasPrefix("\(os.majorVersion).\(os.minorVersion)"))
        #expect(!report.version.isEmpty && !report.build.isEmpty)
        let body = report.body
        #expect(!body.contains(NSHomeDirectory()))
        let words = body.lowercased().split { !$0.isLetter && !$0.isNumber }
        if NSUserName().count >= 3 { #expect(!words.contains(Substring(NSUserName().lowercased()))) }
        #expect(report.activity.count <= BugReport.activityLines)
    }

    @Test func featureLinkUsesItsTemplate() {
        #expect(ProjectLinks.newIssue(template: BugReport.featureTemplate).absoluteString
            == "https://github.com/homielab/cleanmate-macos/issues/new?template=feature_request.yml")
    }
}
