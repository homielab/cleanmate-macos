import Foundation

/// Full Disk Access of this process: the app's own, or for the command line tool the one of the app that runs it
/// (Terminal, an AI agent's app), since macOS checks the process responsible for the tool.
enum FullDiskAccess {
    /// ~/.Trash is only readable with Full Disk Access on recent macOS.
    nonisolated static var isGranted: Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/.Trash")) != nil
    }
}
