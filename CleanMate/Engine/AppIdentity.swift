import Foundation

/// Who is running the Engine: CleanMate.app (and its tests) or the `cleanmate` command line tool inside it, whose own
/// bundle id is the app's plus `.cli`. Settings, caches and "CleanMate's own folder" rules always use the app's id.
nonisolated enum AppIdentity {
    static let commandLineSuffix = ".cli"

    static let isCommandLineTool = Bundle.main.bundleIdentifier?.hasSuffix(commandLineSuffix) == true

    /// CleanMate.app's bundle id, also in the command line tool.
    static let bundleID: String = {
        let id = Bundle.main.bundleIdentifier ?? "com.homielab.CleanMate"
        return id.hasSuffix(commandLineSuffix) ? String(id.dropLast(commandLineSuffix.count)) : id
    }()
}
