import Foundation

/// CleanMate's public pages: the GitHub repository and the website. Help menu links only; the app never calls them.
nonisolated enum ProjectLinks {
    static let repository = URL(string: "https://github.com/homielab/cleanmate-macos")!
    static let website = URL(string: "https://cleanmate.homielab.com")!

    /// A new issue from `.github/ISSUE_TEMPLATE/<template>`, its form fields filled from `fields` (field id → text).
    static func newIssue(template: String, fields: [(id: String, value: String)] = []) -> URL {
        let items = [("template", template)] + fields.map { ($0.id, $0.value) }
        let query = items.map { "\($0.0)=\(encode($0.1))" }.joined(separator: "&")
        return URL(string: repository.absoluteString + "/issues/new?" + query)!
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Percent-encodes everything but unreserved characters: `URLComponents` leaves `+`, `=` and `;` as they are,
    /// and GitHub reads a `+` in a query as a space.
    static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}

/// Help › Report a Bug…: the Mac and CleanMate facts a bug report needs, shown to the user before GitHub opens.
/// Never a file path outside CleanMate's own folders, the user name or the home folder: `body` hides them.
/// Nothing is sent from the app; the browser opens the prefilled issue and the user submits it there.
nonisolated struct BugReport: Equatable {
    var version = ""
    var build = ""
    var macOS = ""
    /// `machdep.cpu.brand_string`, e.g. "Apple M2 Pro".
    var chip = ""
    var appleSilicon = false
    /// The app runs translated on an Apple Silicon Mac.
    var rosetta = false
    var fullDiskAccess = false
    /// Language the app runs in ("en", "vi") and how it was chosen.
    var language = ""
    var languageChoice = AppLanguage.system
    /// Installed by a Homebrew cask (nil: not known).
    var homebrewCask: Bool?
    /// Last lines of the activity log, oldest first, already stripped of paths (`activity(_:home:)`).
    var activity: [String] = []
    /// Home folder and user names `body` hides, in case one slipped into an item name.
    var home = ""
    var userNames: [String] = []

    /// Issue template and form field the report fills (`.github/ISSUE_TEMPLATE/bug_report.yml`).
    static let template = "bug_report.yml"
    static let field = "system"
    static let featureTemplate = "feature_request.yml"
    /// A prefilled link longer than this doesn't open (GitHub answered 500 or 414 from about 7 300 characters in
    /// 2026-11), so the report is copied instead. Counted on the encoded link: the encoding can triple the text.
    static let maxLinkLength = 6_000
    static let activityLines = 5
    /// An item name is cut to this many characters, so the report stays short.
    static let maxItemLength = 100

    /// The text shown in the preview and put in the issue; English, whatever the app language.
    var body: String {
        let arch = appleSilicon ? "Apple Silicon" + (rosetta ? ", running under Rosetta" : "") : "Intel"
        let languageNote = switch languageChoice {
        case .system: "follows the Mac"
        case .english, .vietnamese: "chosen in Settings"
        }
        let install = switch homebrewCask {
        case true?: "Homebrew cask"
        case false?: "not Homebrew (DMG or other)"
        case nil: "unknown"
        }
        var lines = [
            "CleanMate: \(version) (\(build))",
            "macOS: \(macOS)",
            "Mac: \(chip.isEmpty ? arch : "\(chip), \(arch)")",
            "Full Disk Access: \(fullDiskAccess ? "granted" : "not granted")",
            "App language: \(language) (\(languageNote))",
            "Installed with: \(install)",
            "",
        ]
        if activity.isEmpty {
            lines.append("Recent activity: none")
        } else {
            lines.append("Recent activity (last \(activity.count), oldest first):")
            // Only the activity can hold names: the lines above are built from fixed words, which a short user
            // name such as "mac" must not replace.
            lines += activity.map { Self.redact($0, home: home, userNames: userNames) }
        }
        return Self.redact(lines.joined(separator: "\n"), home: home, userNames: [])
    }

    /// The prefilled new-issue page; too long → the bare template (`fitsLink` false: copy `body` instead).
    var issueURL: URL { fitsLink ? prefilledURL : ProjectLinks.newIssue(template: Self.template) }

    var fitsLink: Bool { prefilledURL.absoluteString.count <= Self.maxLinkLength }

    private var prefilledURL: URL { ProjectLinks.newIssue(template: Self.template, fields: [(Self.field, body)]) }

    /// Hides the home folder (→ `~`), any other `/Users/<name>` and the user's short and full names (whole words,
    /// 3 characters or more so a short name doesn't eat parts of other words).
    static func redact(_ text: String, home: String, userNames: [String]) -> String {
        var text = text
        if home.count > 1 {
            let trimmed = home.hasSuffix("/") ? String(home.dropLast()) : home
            text = text.replacingOccurrences(of: trimmed, with: "~")
        }
        text = text.replacing(/\/Users\/[^\/\s]+/, with: "/Users/<user>")
        for name in Set(userNames.map { $0.trimmingCharacters(in: .whitespaces) }) where name.count >= 3 {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: name) + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "<user>")
        }
        return text
    }

    /// The last `limit` lines of the activity log (`ActivityLog.readAll`) as "date  module  item  size  action", in English.
    /// An item that is a path shows only an app's name (`Foo.app`) or, inside CleanMate's own folders in ~/Library,
    /// its path from `~`; any other path becomes "(file or folder)". A line that doesn't parse is left out.
    static func activity(_ log: String, home: String, limit: Int = activityLines) -> [String] {
        let english = Locale(identifier: "en")
        let entries = log.split(separator: "\n").map { ActivityLog.entry($0, locale: english) }.filter { $0.date != nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return entries.suffix(limit).map { entry in
            var item = itemName(entry.item, home: home)
            if item.count > maxItemLength { item = String(item.prefix(maxItemLength - 1)) + "…" }
            let size = entry.bytes.map { $0.formatted(.fileSize.locale(english)) }
            let fields = [entry.date.map(formatter.string(from:)), entry.module, item,
                          entry.kind == "ran" || entry.kind == "failed" ? nil : size, entry.kind]
            return fields.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  ")
        }
    }

    /// `item` from the log without personal paths (see `activity`).
    static func itemName(_ item: String, home: String) -> String {
        let trimmed = home.hasSuffix("/") ? String(home.dropLast()) : home
        var path = item
        if path.hasPrefix("~/") { path = trimmed + path.dropFirst() }
        guard path.hasPrefix("/") else { return item }
        let url = URL(fileURLWithPath: path)
        if url.pathExtension == "app" { return url.lastPathComponent }
        if !trimmed.isEmpty, path.hasPrefix(trimmed + "/Library/"),
           url.pathComponents.contains(where: { $0.hasPrefix("CleanMate") }) {
            return "~" + path.dropFirst(trimmed.count)
        }
        return "(file or folder)"
    }

    /// The report for this Mac and this copy of CleanMate. Reads local state only: no network.
    static func current(bundle: Bundle = .main, home: URL = SafetyPolicy.current.homeURL) -> BugReport {
        let info = bundle.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var macOS = "\(os.majorVersion).\(os.minorVersion)" + (os.patchVersion > 0 ? ".\(os.patchVersion)" : "")
        if let build = sysctlString("kern.osversion") { macOS += " (\(build))" }
        return BugReport(
            version: info["CFBundleShortVersionString"] as? String ?? "?",
            build: info["CFBundleVersion"] as? String ?? "?",
            macOS: macOS,
            chip: sysctlString("machdep.cpu.brand_string") ?? "",
            appleSilicon: sysctlInt("hw.optional.arm64") == 1,
            rosetta: sysctlInt("sysctl.proc_translated") == 1,
            fullDiskAccess: FullDiskAccess.isGranted,
            language: bundle.preferredLocalizations.first ?? "en",
            languageChoice: AppLanguage.current(),
            homebrewCask: HomebrewCasks.cask(for: bundle.bundleURL) != nil,
            activity: activity(ActivityLog.readAll(home: home), home: home.path),
            home: home.path,
            userNames: [NSUserName(), NSFullUserName()] + NSFullUserName().split(separator: " ").map(String.init))
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    private static func sysctlInt(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }
}
