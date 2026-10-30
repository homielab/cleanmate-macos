import Foundation

/// `node_modules` folders of JavaScript projects nobody worked on for `StaleProjects.days` days. `npm install` (or Bun,
/// pnpm, Yarn) brings one back, but needs the network: one entry per project, unticked, moved to the Trash.
/// A project is a folder holding `package.json` and `node_modules`, found by `StaleProjects`; it is stale when its
/// manifest, lockfiles, Git index and `node_modules` folder itself, and those of every folder above it in the home
/// folder (a package of a monorepo, a project inside a repository), are all older.
nonisolated enum StaleNodeModules {
    static let folderName = "node_modules"
    static let manifest = "package.json"
    /// Files that change when a project's dependencies change or work on it is committed (`.git/index`).
    static let markers = ["package.json", "package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml",
                          "bun.lock", "bun.lockb", ".git/index"]
    /// Tools whose processes keep a project in use while they run in it (pnpm, npm and Yarn run as `node`).
    static let tools: Set = ["node", "bun", "pnpm", "npm", "npx", "yarn", "deno"]

    /// The Smart Scan item. `home`, `hasFullDiskAccess`, `running` (`RunningProcesses.folders`) and `now` are injected
    /// by tests.
    static func item(home: URL = URL(fileURLWithPath: NSHomeDirectory()),
                     hasFullDiskAccess: @escaping @Sendable () -> Bool = { FullDiskAccess.isGranted },
                     running: @escaping @Sendable () -> [String] = { RunningProcesses.folders(ofProcessesNamed: isTool) },
                     now: @escaping @Sendable () -> Date = { .now }) -> CleanerItem {
        CleanerItem(id: "stale-node-modules", title: "Stale node_modules",
                    note: "Projects whose package.json, lockfile and Git index were not modified for 90 days. Moved to the Trash; npm install brings them back",
                    paths: StaleProjects.folders, mode: .trash, selectedByDefault: false, showsWhenEmpty: false,
                    skipsOpenFiles: true,
                    skipsEntry: StaleProjects.skipsEntry(running: running, now: now) { lastWorkedOn($0, home: home) },
                    entryLabel: { url in
                        (url.deletingLastPathComponent().lastPathComponent, lastWorkedOn(url, home: home))
                    },
                    selectableEntries: true,
                    findEntries: { roots, policy in
                        await StaleProjects.find(in: roots, policy: policy, hasFullDiskAccess: hasFullDiskAccess())
                            .filter { $0.lastPathComponent == folderName }
                    },
                    allowsEntry: { $0.allowsNodeModules($1) })
    }

    /// `node`, `node22`, `bun`, `pnpm`…
    static func isTool(_ name: String) -> Bool {
        tools.contains(name) || name.hasPrefix("node") && RunningProcesses.isInterpreter(name)
    }

    /// Newest modification date of `nodeModules`, of the `markers` of its project and of each folder above it below
    /// `home`; nil when `nodeModules` is gone.
    static func lastWorkedOn(_ nodeModules: URL, home: URL) -> Date? {
        StaleProjects.lastWorkedOn(nodeModules, markers: markers, home: home)
    }
}
