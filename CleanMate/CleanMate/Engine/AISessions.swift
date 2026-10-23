import Foundation
import os

/// Entry labels for old AI sessions. Claude Code names each `~/.claude/projects` folder after the project
/// path with every character other than a letter or digit turned into "-" (`/Users/me/my-app` →
/// `-Users-me-my-app`), so a real "-" (or "." / "_") can't be told from a "/" by the name alone.
nonisolated enum AISessions {
    /// Claude Code's folder name for `path`: JavaScript's `replace(/[^a-zA-Z0-9]/g, "-")`, which works on UTF-16
    /// units, so an emoji (2 units) gives "--" and a decomposed "ự" "u--".
    static func claudeFolderName(_ path: String) -> String {
        String(decoding: path.utf16.map { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) ? $0 : 0x2D },
               as: UTF16.self)
    }

    /// The project path whose folder name is `encoded`, found by walking existing folders from "/":
    /// at each level, a child whose own encoded name matches the next part. nil when no existing path matches.
    /// `children` lists the folder names inside a path.
    static func claudeProjectPath(encoded: String, children: (String) -> [String]) -> String? {
        guard encoded.hasPrefix("-") else { return nil }
        func walk(_ path: String, _ rest: Substring) -> String? {
            if rest.isEmpty { return path }
            guard rest.first == "-" else { return nil }
            let rest = rest.dropFirst()
            // Longest match first: "my-app" beats "my" when both exist.
            let matches = children(path).filter {
                let name = claudeFolderName($0)
                return !name.isEmpty && rest.hasPrefix(name) && (rest.count == name.count || rest.dropFirst(name.count).first == "-")
            }.sorted { $0.count > $1.count }
            for child in matches {
                if let found = walk(path == "/" ? "/" + child : path + "/" + child, rest.dropFirst(claudeFolderName(child).count)) {
                    return found
                }
            }
            return nil
        }
        return walk("/", Substring(encoded))
    }

    /// Folder name → (label, when resolved). An entry older than `labelLifetime` is resolved again, so a project
    /// moved or deleted between scans gets a fresh label while one scan still does one lookup per project.
    /// shortcut: a time window stands in for "this scan" (the label closure has no scan id); 30 s is far longer
    /// than labelling one scan's entries.
    private static let resolved = OSAllocatedUnfairLock(initialState: [String: (title: String, at: Date)]())
    static let labelLifetime: TimeInterval = 30

    /// Entries in `~/.claude/projects/<folder>/`: the project path with ~ (the folder name when the project
    /// no longer exists) and the entry's last change. nil for entries of the other Claude Code folders.
    static func claudeLabel(of url: URL) -> (title: String, date: Date?)? { claudeLabel(of: url, now: Date()) }

    static func claudeLabel(of url: URL, now: Date) -> (title: String, date: Date?)? {
        let folder = url.deletingLastPathComponent()
        guard folder.deletingLastPathComponent().lastPathComponent == "projects",
              folder.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == ".claude"
        else { return nil }
        return projectLabel(encoded: folder.lastPathComponent, shown: folder.lastPathComponent, of: url, now: now)
    }

    /// Entries in `~/.cursor/projects/<folder>/{agent-transcripts,agent-tools}/`: like Claude Code's, Cursor names
    /// `<folder>` after the project path, but without the leading "-" (`/Users/me/my_app` → `Users-me-my-app`).
    static func cursorLabel(of url: URL) -> (title: String, date: Date?)? { cursorLabel(of: url, now: Date()) }

    static func cursorLabel(of url: URL, now: Date) -> (title: String, date: Date?)? {
        let project = url.deletingLastPathComponent().deletingLastPathComponent()
        guard project.deletingLastPathComponent().lastPathComponent == "projects",
              project.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == ".cursor"
        else { return nil }
        return projectLabel(encoded: "-" + project.lastPathComponent, shown: project.lastPathComponent, of: url, now: now)
    }

    /// The project path of `encoded` with ~ (`shown` when the project no longer exists) and the entry's last change.
    private static func projectLabel(encoded: String, shown: String, of url: URL, now: Date) -> (title: String, date: Date?) {
        // One lookup per project, not per session file.
        let title = resolved.withLock { $0[encoded].flatMap { now.timeIntervalSince($0.at) < labelLifetime ? $0.title : nil } } ?? {
            let found = claudeProjectPath(encoded: encoded) { path in
                (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            }.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? shown
            resolved.withLock { $0[encoded] = (found, now) }
            return found
        }()
        return (title, (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)
    }
}
