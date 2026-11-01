import Foundation

/// The `cleanmate` command line tool inside CleanMate.app: `list` and a read-only `scan`, as text or JSON.
/// No stdin, no network; colours only on a terminal without `NO_COLOR`.
nonisolated enum CommandLineTool {
    enum Exit: Int32 {
        case ok = 0
        case failure = 1
        case usage = 2
        case noFullDiskAccess = 3
    }

    /// Where the tool writes; tests collect the text.
    struct Output: Sendable {
        var out: @Sendable (String) -> Void
        var err: @Sendable (String) -> Void
        /// ANSI colours in text output.
        var color: Bool
        /// A "Scanning…" line on stderr while a text scan runs.
        var progress: Bool

        static var standard: Output {
            let environment = ProcessInfo.processInfo.environment
            let plain = environment["NO_COLOR"].map { !$0.isEmpty } == true || environment["TERM"] == "dumb"
            return Output(out: { FileHandle.standardOutput.write(Data($0.utf8)) },
                          err: { FileHandle.standardError.write(Data($0.utf8)) },
                          color: !plain && isatty(STDOUT_FILENO) == 1, progress: isatty(STDERR_FILENO) == 1)
        }
    }

    enum Command: Equatable {
        case help
        case version
        case list(json: Bool, privacy: Bool)
        case scan(HeadlessScan.Options, json: Bool, requireFullDiskAccess: Bool)
    }

    struct UsageError: Error, Equatable { let message: String }

    static let usage = """
        Usage:
          cleanmate list [--json] [--privacy]
          cleanmate scan [--only ID,ID…] [--group G,G…] [--privacy] [--json] [--require-fda]
          cleanmate --version
          cleanmate --help

        """

    static let help = """
        cleanmate: what CleanMate's Smart Scan would clean on this Mac, for scripts and AI agents.
        Read-only: it deletes nothing, writes no activity log and never connects to the network.
        To clean, open CleanMate.

        \(usage)
        Commands:
          list            Every Smart Scan item: id, group, name, what it removes, ticked by default or not,
                          deleted or moved to the Trash.
          scan            Measures the items like Smart Scan in the app: the same items, safety rules,
                          Settings › Exclusions and Scan Groups. An item whose app or tool is running is
                          locked, with the reason; files in use are skipped.

        Options:
          --json          Print one JSON object instead of text.
          --only IDS      Scan only these items (ids from `cleanmate list`), comma-separated.
          --group GROUPS  Scan only these groups, comma-separated: system, user, dev, ai, apps, privacy.
                          A group turned off in Settings is scanned when named here.
          --privacy       Include the Privacy items (browser history, cookies, recent items).
          --require-fda   Exit with code 3 instead of scanning when Full Disk Access is missing.
          -h, --help      Show this help.
          --version       Show the version.

        Full Disk Access:
          macOS grants it to the app that runs cleanmate (Terminal, iTerm, your AI agent's app), not to
          CleanMate. Without it the scan skips the folders macOS protects (Desktop, Documents, Downloads,
          the Trash, Mail, other apps' data) and reports "fullDiskAccess": false. To grant it: System
          Settings › Privacy & Security › Full Disk Access, turn on that app, then quit and reopen it.

        Exit codes:
          0  OK
          1  Error
          2  Invalid arguments
          3  No Full Disk Access with --require-fda

        """

    /// Runs the tool on `arguments` (without the program name) and returns its exit code.
    static func run(_ arguments: [String], sources: HeadlessScan.Sources = HeadlessScan.Sources(),
                    output: Output = .standard) async -> Int32 {
        let command: Command
        do {
            command = try parse(arguments)
            if case .scan(let options, _, _) = command { try HeadlessScan.validate(options, sources: sources) }
        } catch let error as UsageError {
            output.err("cleanmate: \(error.message)\nRun `cleanmate --help` for usage.\n")
            return Exit.usage.rawValue
        } catch let error as HeadlessScan.OptionError {
            output.err("cleanmate: \(message(error))\nRun `cleanmate --help` for usage.\n")
            return Exit.usage.rawValue
        } catch {
            output.err("cleanmate: \(error.localizedDescription)\n")
            return Exit.failure.rawValue
        }
        switch command {
        case .help:
            output.out(help)
        case .version:
            output.out("cleanmate \(sources.version())\n")
        case .list(let json, let privacy):
            let report = HeadlessScan.list(privacy: privacy, sources: sources)
            guard let text = json ? encode(report) : listText(report, color: output.color) else { return Exit.failure.rawValue }
            output.out(text)
        case .scan(let options, let json, let requireAccess):
            if requireAccess && !sources.hasFullDiskAccess() {
                output.err("cleanmate: no Full Disk Access. Grant it to the app that runs cleanmate in System Settings › "
                           + "Privacy & Security › Full Disk Access, then reopen that app.\n")
                return Exit.noFullDiskAccess.rawValue
            }
            let showsProgress = output.progress && !json
            if showsProgress { output.err("Scanning…") }
            let report = await HeadlessScan.scan(options, sources: sources)
            if showsProgress { output.err("\r\u{1B}[K") }
            guard let text = json ? encode(report) : scanText(report, color: output.color) else { return Exit.failure.rawValue }
            output.out(text)
        }
        return Exit.ok.rawValue
    }

    static func parse(_ arguments: [String]) throws -> Command {
        guard let first = arguments.first else { throw UsageError(message: "missing command\n\n" + usage) }
        var rest = arguments.dropFirst()
        switch first {
        case "-h", "--help", "help":
            return .help
        case "--version", "version":
            guard rest.isEmpty else { throw UsageError(message: "unexpected argument `\(rest.first!)`") }
            return .version
        case "list", "scan":
            var json = false, privacy = false, requireAccess = false
            var options = HeadlessScan.Options()
            while let argument = rest.popFirst() {
                let (name, inline) = split(argument)
                func value() throws -> [String] {
                    guard let text = inline ?? rest.popFirst(), !text.isEmpty, !text.hasPrefix("-") else {
                        throw UsageError(message: "\(name) needs a value")
                    }
                    let values = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    guard !values.isEmpty else { throw UsageError(message: "\(name) needs a value") }
                    return values
                }
                switch (name, first) {
                case ("-h", _), ("--help", _): return .help
                case ("--json", _) where inline == nil: json = true
                case ("--privacy", _) where inline == nil: privacy = true
                case ("--only", "scan"): options.only = (options.only ?? []) + (try value())
                case ("--group", "scan"): options.groups = (options.groups ?? []) + (try value())
                case ("--require-fda", "scan") where inline == nil: requireAccess = true
                default:
                    throw UsageError(message: argument.hasPrefix("-") ? "unknown option `\(name)` for \(first)"
                                                                      : "unexpected argument `\(argument)`")
                }
            }
            options.privacy = privacy
            return first == "list" ? .list(json: json, privacy: privacy)
                                   : .scan(options, json: json, requireFullDiskAccess: requireAccess)
        default:
            throw UsageError(message: first.hasPrefix("-") ? "unknown option `\(first)`" : "unknown command `\(first)`")
        }
    }

    /// `--only=a,b` → ("--only", "a,b").
    private static func split(_ argument: String) -> (String, String?) {
        guard argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") else { return (argument, nil) }
        return (String(argument[..<equals]), String(argument[argument.index(after: equals)...]))
    }

    static func message(_ error: HeadlessScan.OptionError) -> String {
        switch error {
        case .unknownItem(let id): "unknown item `\(id)` (see `cleanmate list`)"
        case .unknownGroup(let group): "unknown group `\(group)` (groups: \(HeadlessScan.groupNames.joined(separator: ", ")))"
        case .needsPrivacy(let name):
            name == "privacy" ? "the privacy group needs --privacy" : "`\(name)` is a Privacy item: add --privacy"
        }
    }

    // MARK: - Output

    static func encode(_ value: some Encodable) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) + "\n" }
    }

    static let groupTitles = ["system": "System Junk", "user": "Trash", "dev": "Developer Junk", "ai": "AI Tools",
                              "apps": "Applications", "privacy": "Privacy"]

    private struct Style {
        let color: Bool
        func bold(_ text: String) -> String { color ? "\u{1B}[1m\(text)\u{1B}[0m" : text }
        func dim(_ text: String) -> String { color ? "\u{1B}[2m\(text)\u{1B}[0m" : text }
        func yellow(_ text: String) -> String { color ? "\u{1B}[33m\(text)\u{1B}[0m" : text }
    }

    static func size(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false // "0 bytes", not "Zero KB"
        return formatter.string(fromByteCount: bytes)
    }

    private static func padded(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    static func listText(_ report: HeadlessScan.ListReport, color: Bool) -> String {
        let style = Style(color: color)
        var text = ""
        var group: String?
        let width = min(36, report.items.map(\.id.count).max() ?? 0)
        for item in report.items {
            if item.group != group {
                text += (group == nil ? "" : "\n") + style.bold("\(groupTitles[item.group] ?? item.group) (\(item.group))") + "\n"
                group = item.group
            }
            let flags = [item.disposal == "trash" ? "moves to Trash" : nil, item.needsFullDiskAccess ? "needs Full Disk Access" : nil]
                .compactMap { $0 }
            text += "  \(item.selectedByDefault ? "[x]" : "[ ]") \(padded(item.id, width))  \(item.name)"
                + (flags.isEmpty ? "" : style.dim(" (\(flags.joined(separator: ", ")))")) + "\n"
            if !item.description.isEmpty { text += "      " + style.dim(item.description) + "\n" }
        }
        return text + "\n[x] = ticked by default\n"
    }

    static func scanText(_ report: HeadlessScan.Report, color: Bool) -> String {
        let style = Style(color: color)
        var text = ""
        var group: String?
        let width = min(40, report.items.map(\.name.count).max() ?? 0)
        for item in report.items {
            if item.group != group {
                text += (group == nil ? "" : "\n") + style.bold(groupTitles[item.group] ?? item.group) + "\n"
                group = item.group
            }
            let amount = item.size == 0 && item.records != nil ? "\(item.records!) records"
                : (item.sizeIsUpperBound ? "up to " : "") + size(item.size)
            let mark = item.locked ? "[-]" : item.selectedByDefault ? "[x]" : "[ ]"
            text += "  \(mark) \(padded(item.name, width))  \(String(repeating: " ", count: max(0, 12 - amount.count)) + amount)"
            if let reason = item.reason { text += "  " + style.yellow(reason) }
            text += "\n"
        }
        if report.items.isEmpty { text += "Nothing found.\n" }
        text += "\n" + style.bold("Ticked by default: \(size(report.total))")
            + (report.totalUpTo > 0 ? " (+ up to \(size(report.totalUpTo)))" : "") + "\n"
        text += style.dim("[x] ticked, [ ] not ticked, [-] locked. Nothing was deleted: clean in CleanMate.") + "\n"
        if !report.fullDiskAccess {
            text += style.yellow("Note: no Full Disk Access, so folders macOS protects were skipped (see `cleanmate --help`).") + "\n"
        }
        return text
    }
}
