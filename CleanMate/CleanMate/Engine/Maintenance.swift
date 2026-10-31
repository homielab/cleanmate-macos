import Foundation

/// Maintenance tasks: macOS tools run as the user, no administrator password, nothing removed from the user's files.
/// Tasks that need root (purge, mdutil, dscacheutil) are deliberately left out.
nonisolated enum MaintenanceTask: String, CaseIterable, Identifiable, Sendable {
    case launchServices
    case quickLook
    case finderAndDock
    case fontCache
    case iconCache

    var id: Self { self }

    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    /// The user's own cache folder (`getconf DARWIN_USER_CACHE_DIR`, `/var/folders/…/C/`), where the Dock and Icon
    /// Services keep their icon caches. Empty when it can't be read; the icon task then does nothing but fail.
    static let userCacheDir: String = {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count) > 0 else { return "" }
        return String(cString: buffer)
    }()

    /// Run in order; the first one that fails stops the task.
    var commands: [ShellCommand] {
        switch self {
        // `-kill` and `-domain` were removed from lsregister: garbage-collect the database, then register the
        // apps of every domain again, so stale copies drop out of "Open With".
        case .launchServices: [
            ShellCommand(executable: Self.lsregister, arguments: ["-gc"]),
            ShellCommand(executable: Self.lsregister, arguments: ["-r", "-f", "-apps", "local,system,user"]),
        ]
        case .quickLook: [
            ShellCommand(executable: "/usr/bin/qlmanage", arguments: ["-r"]),
            ShellCommand(executable: "/usr/bin/qlmanage", arguments: ["-r", "cache"]),
        ]
        // launchd starts both again right away.
        case .finderAndDock: [
            ShellCommand(executable: "/usr/bin/killall", arguments: ["Finder"]),
            ShellCommand(executable: "/usr/bin/killall", arguments: ["Dock"]),
        ]
        // The user's font registry only (the system one needs root); fontd builds it again. `server` does nothing on
        // macOS 14 and later (it only prints that ATS is gone) and restarts the font server on macOS 13.
        case .fontCache: [
            ShellCommand(executable: "/usr/bin/atsutil", arguments: ["databases", "-removeUser"]),
            ShellCommand(executable: "/usr/bin/atsutil", arguments: ["server", "-shutdown"]),
            ShellCommand(executable: "/usr/bin/atsutil", arguments: ["server", "-ping"]),
        ]
        // Only the user's caches (never /Library/Caches/com.apple.iconservices.store, which needs root); the Dock
        // and Icon Services draw the icons again after the Dock restarts.
        case .iconCache: Self.userCacheDir.hasPrefix("/") ? [
            ShellCommand(executable: "/bin/rm", arguments: ["-rf"] + Self.iconCachePaths(in: Self.userCacheDir)),
            ShellCommand(executable: "/usr/bin/killall", arguments: ["Dock"]),
        ] : [ShellCommand(executable: "/usr/bin/false")]
        }
    }

    static func iconCachePaths(in cacheDir: String) -> [String] {
        ["com.apple.dock.iconcache", "com.apple.iconservices", "com.apple.iconservices.store"]
            .map { (cacheDir as NSString).appendingPathComponent($0) }
    }

    var title: LocalizedStringResource {
        switch self {
        case .launchServices: "Rebuild Launch Services"
        case .quickLook: "Reset Quick Look"
        case .finderAndDock: "Restart Finder and Dock"
        case .fontCache: "Reset Font Cache"
        case .iconCache: "Clear Icon Cache"
        }
    }

    var summary: LocalizedStringResource {
        switch self {
        case .launchServices: "Removes duplicate and outdated apps from “Open With” menus by registering the apps on this Mac again."
        case .quickLook: "Restarts Quick Look and clears its thumbnail cache, for previews that are blank, wrong or slow."
        case .finderAndDock: "Fixes a Finder or Dock that hangs or shows old icons. Finder windows close and open again."
        case .fontCache: "Fixes text drawn in the wrong font or as boxes by clearing your font cache. Open apps may need a restart."
        case .iconCache: "Fixes wrong or blank app icons in the Dock and Finder by clearing your icon cache, then restarts the Dock."
        }
    }

    var systemImage: String {
        switch self {
        case .launchServices: "arrow.up.forward.app"
        case .quickLook: "eye"
        case .finderAndDock: "dock.rectangle"
        case .fontCache: "textformat"
        case .iconCache: "app.dashed"
        }
    }

    /// Asks before running: these restart the Dock (and Finder, where a copy in progress stops).
    var asksFirst: Bool { self == .finderAndDock || self == .iconCache }
}
