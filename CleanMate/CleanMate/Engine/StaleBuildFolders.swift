import Foundation

/// Build folders of projects nobody worked on for `StaleProjects.days` days: Cargo's `target`, a Python virtual
/// environment (`.venv` or `venv` holding `pyvenv.cfg`) and CocoaPods' `Pods`, each only next to the file that makes
/// it (`StaleProjects.projectFolders`). `cargo build`, `pip`/`uv` and `pod install` make them again, slowly: one entry
/// per folder labelled with its project's path, unticked, moved to the Trash.
/// Stale like `StaleNodeModules`: the project's files and lockfiles, its Git index and the folder itself, and those of
/// every folder above it in the home folder, are all older.
nonisolated enum StaleBuildFolders {
    static let folderNames: Set = ["target", ".venv", "venv", "Pods"]
    /// Files that change when a project's build or dependencies change or work on it is committed (`.git/index`);
    /// the project's `requirements*.txt` too.
    static let markers = ["Cargo.toml", "Cargo.lock", "pyproject.toml", "setup.py", "setup.cfg", "Pipfile", "Pipfile.lock",
                          "poetry.lock", "uv.lock", "pdm.lock", "Podfile", "Podfile.lock", ".git/index"]
    /// Tools whose processes keep a project in use while they run in it (`pod` runs as `ruby`).
    static let tools: Set = ["cargo", "rustc", "uv", "pod", "ruby"]

    /// The Smart Scan item. `home`, `hasFullDiskAccess`, `running` (`RunningProcesses.folders`), `now` and `sizes`
    /// (sizes kept between scans) are injected by tests.
    static func item(home: URL = URL(fileURLWithPath: NSHomeDirectory()),
                     hasFullDiskAccess: @escaping @Sendable () -> Bool = { FullDiskAccess.isGranted },
                     running: @escaping @Sendable () -> [String] = { RunningProcesses.folders(ofProcessesNamed: isTool) },
                     now: @escaping @Sendable () -> Date = { .now }, sizes: FolderSizeCache = .shared) -> CleanerItem {
        CleanerItem(id: "stale-build-dirs", title: "Stale build folders",
                    note: "Cargo target, Python virtual environment and CocoaPods Pods folders of projects whose files and Git index were not modified for 90 days. Moved to the Trash; cargo build, uv or pip, and pod install make them again",
                    paths: StaleProjects.folders, mode: .trash, selectedByDefault: false, showsWhenEmpty: false,
                    skipsOpenFiles: true,
                    skipsEntry: StaleProjects.skipsEntry(running: running, now: now) { lastWorkedOn($0, home: home) },
                    entryLabel: { url in (label(url, home: home), lastWorkedOn(url, home: home)) },
                    selectableEntries: true,
                    findEntries: { roots, policy in
                        await StaleProjects.find(in: roots, policy: policy, hasFullDiskAccess: hasFullDiskAccess())
                            .filter { folderNames.contains($0.lastPathComponent) }
                    },
                    allowsEntry: { $0.allowsBuildFolder($1) },
                    entrySizes: sizes,
                    // uv clones a virtual environment's packages from its cache; Cargo and CocoaPods write their own files.
                    freeableSize: { FreeableBytes(clones: [".venv", "venv"].contains($0.lastPathComponent)) })
    }

    /// `cargo`, `rustc`, `uv`, `pod`, `python3.12`…
    static func isTool(_ name: String) -> Bool {
        tools.contains(name) || name.hasPrefix("python") && RunningProcesses.isInterpreter(name)
    }

    /// `~/Developer/api — target/`: the project's path from the home folder, as project names repeat (`app`, `ios`).
    static func label(_ folder: URL, home: URL) -> String {
        let project = folder.deletingLastPathComponent().standardizedFileURL.path, homePath = home.standardizedFileURL.path
        let shown = project.hasPrefix(homePath + "/") ? "~" + project.dropFirst(homePath.count) : project
        return shown + " — " + folder.lastPathComponent + "/"
    }

    /// Newest modification date of `folder`, of the `markers` of its project and of each folder above it below `home`,
    /// and of the project's `requirements*.txt`; nil when `folder` is gone.
    static func lastWorkedOn(_ folder: URL, home: URL) -> Date? {
        StaleProjects.lastWorkedOn(folder, markers: markers, projectFile: StaleProjects.isRequirements, home: home)
    }
}
