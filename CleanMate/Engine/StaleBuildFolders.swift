import Foundation

/// Build folders of projects nobody worked on for `StaleProjects.days` days, each only next to the file that makes it
/// (`StaleProjects.buildFolders`): Cargo and Maven `target`, Gradle and Android `build`, `.gradle` and `<module>/build`,
/// SwiftPM `.build`, Flutter `.dart_tool` and `build`, Next.js, Nuxt, SvelteKit, Angular and Turborepo caches, Haskell
/// `.stack-work` and `dist-newstyle`, Elixir `_build` and `deps`, Zig caches, a Python virtual environment and
/// CocoaPods' `Pods`. The project's build tool makes them again, slowly: one entry per folder labelled with its
/// project's path and its path in the project, unticked, moved to the Trash.
/// Stale like `StaleNodeModules`: the project's files and lockfiles, its Git index and the folder itself, and those of
/// every folder above it in the home folder, are all older.
nonisolated enum StaleBuildFolders {
    /// Last path components of the folders `StaleProjects.buildFolders` finds (`cache` of `.angular/cache`).
    static let folderNames: Set = ["target", ".venv", "venv", "Pods", "build", ".gradle", ".build", ".dart_tool", ".next",
                                   ".nuxt", ".output", ".svelte-kit", "cache", ".turbo", ".stack-work", "dist-newstyle",
                                   "_build", "deps", ".zig-cache", "zig-cache"]
    /// Files that change when a project's build or dependencies change or work on it is committed (`.git/index`, with
    /// JavaScript's manifest and lockfiles); the project's `requirements*.txt`, `*.cabal` and framework configs too (`isProjectFile`).
    static let markers = ["Cargo.toml", "Cargo.lock", "pyproject.toml", "setup.py", "setup.cfg", "Pipfile", "Pipfile.lock",
                          "poetry.lock", "uv.lock", "pdm.lock", "Podfile", "Podfile.lock",
                          "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts", "gradle.properties",
                          "gradle/libs.versions.toml", "pom.xml", "Package.swift", "Package.resolved",
                          "pubspec.yaml", "pubspec.lock", "angular.json", "turbo.json",
                          "stack.yaml", "stack.yaml.lock", "cabal.project", "cabal.project.freeze",
                          "mix.exs", "mix.lock", "build.zig", "build.zig.zon"] + StaleNodeModules.markers
    /// Tools whose processes keep a project in use while they run in it (`pod` runs as `ruby`, Gradle and Maven as
    /// `java`, `mix` as `beam.smp`, Flutter as `dart`, the JavaScript frameworks as `node`).
    static let tools: Set = ["cargo", "rustc", "uv", "pod", "ruby", "java", "gradle", "mvn", "swift", "swift-build",
                             "swift-frontend", "swift-package", "dart", "flutter", "node", "bun", "deno", "stack", "cabal",
                             "ghc", "beam.smp", "mix", "elixir", "zig"]

    /// The Smart Scan item. `home`, `hasFullDiskAccess`, `running` (`RunningProcesses.folders`), `now` and `sizes`
    /// (sizes kept between scans) are injected by tests.
    static func item(home: URL = URL(fileURLWithPath: NSHomeDirectory()),
                     hasFullDiskAccess: @escaping @Sendable () -> Bool = { FullDiskAccess.isGranted },
                     running: @escaping @Sendable () -> [String] = { RunningProcesses.folders(ofProcessesNamed: isTool) },
                     now: @escaping @Sendable () -> Date = { .now }, sizes: FolderSizeCache = .shared) -> CleanerItem {
        CleanerItem(id: "stale-build-dirs", title: "Stale build folders",
                    note: "Build folders of projects whose files and Git index were not modified for 90 days: Cargo, Gradle and Android, Maven, SwiftPM, Flutter, Next.js, Nuxt, SvelteKit, Angular, Turborepo, Haskell, Elixir and Zig, Python virtual environments and CocoaPods Pods. Moved to the Trash; the project's build tool makes them again",
                    paths: StaleProjects.folders, mode: .trash, selectedByDefault: false, showsWhenEmpty: false,
                    skipsOpenFiles: true,
                    skipsEntry: StaleProjects.skipsEntry(running: running, now: now) { lastWorkedOn($0, home: home) },
                    entryLabel: { url in (label(url, home: home), lastWorkedOn(url, home: home)) },
                    selectableEntries: true,
                    findEntries: { roots, policy in
                        await StaleProjects.find(in: roots, policy: policy, hasFullDiskAccess: hasFullDiskAccess())
                            .filter(isBuildFolder)
                    },
                    allowsEntry: { $0.allowsBuildFolder($1) },
                    entrySizes: sizes,
                    // uv clones a virtual environment's packages from its cache; the other tools write their own files.
                    freeableSize: { FreeableBytes(clones: [".venv", "venv"].contains($0.lastPathComponent)) })
    }

    /// A folder of the shared walk that is this item's: not `node_modules` nor Terraform's downloads.
    static func isBuildFolder(_ url: URL) -> Bool {
        folderNames.contains(url.lastPathComponent) && url.deletingLastPathComponent().lastPathComponent != ".terraform"
    }

    /// `cargo`, `rustc`, `uv`, `pod`, `python3.12`, `ghc-9.8.2`…
    static func isTool(_ name: String) -> Bool {
        tools.contains(name) || name.hasPrefix("python") && RunningProcesses.isInterpreter(name)
            || name.hasPrefix("ghc-") && name.dropFirst(4).first?.isNumber == true
    }

    /// `~/Developer/api — target/`, `~/Developer/android — app/build/`: the project's path from the home folder, as
    /// project names repeat (`app`, `ios`), and the folder's path in it.
    static func label(_ folder: URL, home: URL) -> String { StaleProjects.label(folder, home: home) }

    /// `requirements*.txt`, `*.cabal`, `next.config.mjs`, `nuxt.config.ts`, `svelte.config.js`.
    static func isProjectFile(_ name: String) -> Bool {
        StaleProjects.isRequirements(name) || StaleProjects.isCabalFile(name)
            || ["next", "nuxt", "svelte"].contains { name.hasPrefix($0 + ".config.") }
    }

    /// Newest modification date of `folder`, of the `markers` of its project and of each folder above it below `home`,
    /// and of the project's own files (`isProjectFile`); nil when `folder` is gone.
    static func lastWorkedOn(_ folder: URL, home: URL) -> Date? {
        StaleProjects.lastWorkedOn(folder, markers: markers, projectFile: isProjectFile, home: home)
    }
}
