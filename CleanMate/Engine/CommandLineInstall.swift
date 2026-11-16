import Foundation

/// Settings › Integrations: links the `cleanmate` helper inside the app into ~/.local/bin. No root, never replaces
/// a file that is not a link to a CleanMate helper.
nonisolated enum CommandLineInstall {
    enum Status: Equatable {
        /// Nothing at the link path.
        case notInstalled
        /// A link to this app's helper, which exists.
        case installed
        /// A link to another CleanMate.app's helper that exists (its path).
        case otherCopy(String)
        /// A link to a CleanMate helper that no longer exists (its path).
        case broken(String)
        /// A regular file, a folder, or a link to anything else: never touched.
        case foreign
    }

    enum Failure: Error, Equatable {
        case foreignFile, helperMissing, translocated
        case failed(String)
    }

    static let pathLine = "export PATH=\"$HOME/.local/bin:$PATH\""
    static let skillCommand = "bunx skills add homielab/cleanmate-macos"
    private static let helperSuffix = ".app/Contents/Helpers/cleanmate"

    /// home/.local/bin/cleanmate
    static func link(home: URL = SafetyPolicy.current.homeURL) -> URL {
        folder(home: home).appending(path: "cleanmate")
    }

    private static func folder(home: URL) -> URL {
        home.appending(path: ".local/bin")
    }

    /// bundle/Contents/Helpers/cleanmate
    static func helper(bundle: URL = Bundle.main.bundleURL) -> URL {
        bundle.appending(path: "Contents/Helpers/cleanmate")
    }

    static func status(home: URL = SafetyPolicy.current.homeURL, helper: URL = helper()) -> Status {
        let path = link(home: home).path
        var info = stat()
        guard lstat(path, &info) == 0 else { return .notInstalled }
        guard info.st_mode & S_IFMT == S_IFLNK,
              let raw = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return .foreign }
        let base = URL(fileURLWithPath: path).deletingLastPathComponent()
        let target = URL(fileURLWithPath: raw, relativeTo: base).standardizedFileURL.path
        guard target.hasSuffix(helperSuffix) else { return .foreign }
        let exists = FileManager.default.fileExists(atPath: target)
        if target == helper.standardizedFileURL.path { return exists ? .installed : .broken(target) }
        return exists ? .otherCopy(target) : .broken(target)
    }

    /// Install and Repair: points the link at `helper`, creating ~/.local/bin when missing.
    static func install(home: URL = SafetyPolicy.current.homeURL, helper: URL = helper()) throws {
        guard !helper.path.contains("/AppTranslocation/") else { throw Failure.translocated }
        guard FileManager.default.fileExists(atPath: helper.path) else { throw Failure.helperMissing }
        guard status(home: home, helper: helper) != .foreign else { throw Failure.foreignFile }
        let directory = folder(home: home)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw Failure.failed(error.localizedDescription)
        }
        // A temporary link renamed onto the old one: the command never goes missing in between.
        let temporary = directory.appending(path: ".cleanmate.\(UUID().uuidString)").path
        guard symlink(helper.path, temporary) == 0 else { throw Failure.failed(String(cString: strerror(errno))) }
        guard rename(temporary, link(home: home).path) == 0 else {
            let message = String(cString: strerror(errno))
            unlink(temporary)
            throw Failure.failed(message)
        }
    }

    /// Removes the link only, never the folder.
    static func remove(home: URL = SafetyPolicy.current.homeURL) throws {
        switch status(home: home) {
        case .notInstalled: return
        case .foreign: throw Failure.foreignFile
        default:
            guard unlink(link(home: home).path) == 0 else { throw Failure.failed(String(cString: strerror(errno))) }
        }
    }

    /// Whether the shell finds `~/.local/bin`: in the profile's PATH or in `environment`'s. Reads shell profiles.
    static func onPath(home: URL = SafetyPolicy.current.homeURL,
                       environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        let wanted = folder(home: home).standardizedFileURL.path
        if ShellEnvironment.pathFolders(home: home).contains(wanted) { return true }
        return (environment["PATH"] ?? "").split(separator: ":").contains {
            URL(fileURLWithPath: String($0)).standardizedFileURL.path == wanted
        }
    }
}
