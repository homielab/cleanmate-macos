import Foundation

/// Maintenance tasks: macOS tools run as the user, no administrator password, nothing removed from the user's files.
/// Tasks that need root (purge, mdutil, dscacheutil) are deliberately left out.
nonisolated enum MaintenanceTask: String, CaseIterable, Identifiable, Sendable {
    case launchServices
    case quickLook
    case finderAndDock

    var id: Self { self }

    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

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
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .launchServices: "Rebuild Launch Services"
        case .quickLook: "Reset Quick Look"
        case .finderAndDock: "Restart Finder and Dock"
        }
    }

    var summary: LocalizedStringResource {
        switch self {
        case .launchServices: "Removes duplicate and outdated apps from “Open With” menus by registering the apps on this Mac again."
        case .quickLook: "Restarts Quick Look and clears its thumbnail cache, for previews that are blank, wrong or slow."
        case .finderAndDock: "Fixes a Finder or Dock that hangs or shows old icons. Finder windows close and open again."
        }
    }

    var systemImage: String {
        switch self {
        case .launchServices: "arrow.up.forward.app"
        case .quickLook: "eye"
        case .finderAndDock: "dock.rectangle"
        }
    }

    /// Asks before running: Finder windows close and a copy in progress stops.
    var asksFirst: Bool { self == .finderAndDock }
}
