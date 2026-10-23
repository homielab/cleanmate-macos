import CryptoKit
import Foundation
import Synchronization

extension CleanerGroup {
    /// Developer junk: one item per tool, shown only when that tool left something behind.
    /// Official commands are used when the tool is installed; otherwise the cache folder is emptied.
    nonisolated static let developer = CleanerGroup(id: "developer", title: "Developer Junk", systemImage: "hammer", items: [
        // Xcode
        dev("xcode-derived-data", "Xcode DerivedData", note: "Build products and indexes, rebuilt on the next build",
            ["~/Library/Developer/Xcode/DerivedData"], apps: ["com.apple.dt.Xcode"], processes: ["xcodebuild"],
            entryLabel: XcodeData.derivedDataLabel(of:), selectableEntries: true), // a build in progress writes here
        dev("xcode-device-support", "Xcode device support files",
            note: "Debug symbols copied from connected devices, copied again when a device reconnects",
            ["iOS", "watchOS", "tvOS", "visionOS"].map { "~/Library/Developer/Xcode/\($0) DeviceSupport" },
            entryLabel: XcodeData.deviceSupportLabel(of:), selectableEntries: true),
        // No CoreDevice item: ~/Library/Developer/CoreDevice/DeviceFS is a filesystem of the connected devices
        // (devicefs mount), not a cache on this disk; its backing store is CoreDeviceService's container.
        // Archives are not regenerable (needed to symbolicate crashes of those builds): Trash, unticked.
        dev("xcode-archives", "Old Xcode archives",
            note: "Not modified for 90 days. Moved to the Trash; needed to symbolicate crash reports of those builds",
            ["~/Library/Developer/Xcode/Archives"], minAge: 90 * 86_400, mode: .trash, selected: false, selectableEntries: true),
        dev("unavailable-simulators", "Unavailable simulators", note: "Simulators whose runtime is no longer installed",
            [simulatorDevices],
            command: ShellCommand(executable: "/usr/bin/xcrun", arguments: ["simctl", "delete", "unavailable"],
                                  timeout: .seconds(300)),
            probe: simulators(available: false)),
        // Runtimes live in /Library (secure storage), outside home: only `simctl runtime delete` removes them.
        // Chosen by "a newer runtime of the same platform is installed" rather than by Xcode's SDK version: an
        // Xcode runs older runtimes, and its SDK is often a point release ahead of the newest runtime (27.1 vs 27.0).
        dev("old-simulator-runtimes", "Old simulator runtimes",
            note: "Replaced by a newer runtime of the same platform and unused for 30 days; downloadable again in Xcode Settings › Components",
            [], command: ShellCommand(executable: "/bin/sh", timeout: .seconds(600), leadingArguments: {
                // Exactly the runtimes the last scan showed; `simctl runtime delete` takes one identifier.
                let ids = staleRuntimeIDs.withLock { $0 }
                return ids.isEmpty ? nil : ["-c", "for id; do /usr/bin/xcrun simctl runtime delete \"$id\" || s=1; done; exit ${s:-0}", "sh"] + ids
            }),
            probe: SizeProbe(command: ShellCommand(executable: "/usr/bin/xcrun", arguments: ["simctl", "runtime", "list", "-j"],
                                                   timeout: .seconds(30)),
                             // Without Xcode, xcrun may prompt to install the command line tools.
                             precondition: { FileManager.default.fileExists(atPath: "/Library/Developer/CoreSimulator") },
                             parse: { output in
                                 let stale = DeveloperTools.staleRuntimes(in: output)
                                 staleRuntimeIDs.withLock { $0 = stale?.ids ?? [] }
                                 return stale.map { SizeProbe.Result.bytes($0.bytes) }
                             }),
            selected: false, apps: ["com.apple.dt.Xcode", "com.apple.iphonesimulator"]),
        dev("simulator-data", "Simulator content",
            note: "Erases every app and its data in all simulators (simctl erase all)",
            [simulatorDevices],
            command: ShellCommand(executable: "/bin/sh",
                                  arguments: ["-c", "xcrun simctl shutdown all; xcrun simctl erase all"],
                                  timeout: .seconds(300)),
            probe: simulators(available: true), selected: false, apps: ["com.apple.iphonesimulator"]),
        // Simulators SwiftUI Previews creates on its own; Xcode makes them again on the next preview.
        dev("xcode-previews", "Xcode Previews simulators", note: "Created again the next time a preview runs",
            ["~/Library/Developer/Xcode/UserData/Previews"],
            command: ShellCommand(executable: "/usr/bin/xcrun", arguments: ["simctl", "--set", "previews", "delete", "all"],
                                  timeout: .seconds(300)),
            apps: ["com.apple.dt.Xcode"]),
        // dyld shared caches of the simulator runtimes, rebuilt by the next simulator boot (takes a few minutes once).
        dev("simulator-caches", "Simulator caches", note: "Rebuilt when a simulator starts; that first start is slower",
            ["~/Library/Developer/CoreSimulator/Caches"], apps: ["com.apple.dt.Xcode", "com.apple.iphonesimulator"]),
        dev("swiftpm-cache", "Swift Package Manager cache", ["~/Library/Caches/org.swift.swiftpm"]),
        dev("cocoapods-cache", "CocoaPods cache", ["~/Library/Caches/CocoaPods"]),

        // Package managers
        dev("npm-cache", "npm cache", ["~/.npm/_cacache"],
            command: ShellCommand(executable: "npm", arguments: ["cache", "clean", "--force"]),
            locate: lookup("npm", ["config", "get", "cache"], subpath: "_cacache")),
        // Packages `npx` fetched to run once; a running npx (e.g. an MCP server started with npx) still uses its folder.
        dev("npx-cache", "npx cache", note: "Packages run with npx, downloaded again on the next run", ["~/.npm/_npx"],
            locate: lookup("npm", ["config", "get", "cache"], subpath: "_npx"), processes: ["npx"]),
        // Only the downloaded Node tarballs; ~/.nvm/versions (the installed Node versions) is never touched.
        dev("nvm-cache", "nvm download cache", note: "Downloaded Node.js archives, downloaded again by nvm install",
            ["~/.nvm/.cache"], shell: ["NVM_DIR": [".cache"]]),
        dev("yarn-cache", "Yarn cache", ["~/Library/Caches/Yarn"], processes: ["yarn"]),
        // Unticked: Yarn 2+ (Berry) keeps packages in this global cache by default, and Plug'n'Play projects
        // read their zips straight from it, so they stop running until `yarn install` downloads them again.
        dev("yarn-berry-cache", "Yarn Berry cache", note: "Projects using Yarn Plug'n'Play need yarn install again",
            ["~/.yarn/berry/cache"], selected: false, processes: ["yarn"]),
        dev("pnpm-store", "pnpm store",
            note: "Size of the whole store; only packages no project uses are removed (pnpm store prune)",
            ["~/Library/pnpm/store"], command: ShellCommand(executable: "pnpm", arguments: ["store", "prune"],
                                                            timeout: .seconds(300)),
            locate: lookup("pnpm", ["store", "path"]),
            upperBound: true), // pnpm has no dry run telling what prune would remove
        // bun (clonefile) and uv (link-mode clone) install by cloning from their cache on APFS: blocks a project still
        // uses are counted in the cache's size but not freed by removing it. No cheap API gives a clone's private size.
        dev("bun-cache", "Bun cache", note: clonedNote, ["~/.bun/install/cache"], processes: ["bun"], upperBound: true),
        dev("pip-cache", "pip cache", ["~/Library/Caches/pip"], processes: ["pip", "pip3"]),
        dev("uv-cache", "uv cache", note: clonedNote, ["~/.cache/uv"],
            command: ShellCommand(executable: "uv", arguments: ["cache", "clean"], timeout: .seconds(120)),
            locate: lookup("uv", ["cache", "dir"]), upperBound: true),
        dev("go-build-cache", "Go build cache", ["~/Library/Caches/go-build"],
            command: ShellCommand(executable: "go", arguments: ["clean", "-cache"]),
            locate: lookup("go", ["env", "GOCACHE"])),
        // Module files are read-only, so `go clean` is the reliable way to remove them.
        dev("go-mod-cache", "Go module cache", note: "Downloaded modules, downloaded again on the next build",
            ["~/go/pkg/mod"], command: ShellCommand(executable: "go", arguments: ["clean", "-modcache"],
                                                    timeout: .seconds(300)),
            locate: lookup("go", ["env", "GOMODCACHE"])),
        dev("cargo-registry", "Cargo registry cache", note: "Downloaded crates, downloaded again on the next build",
            ["~/.cargo/registry", "~/.cargo/git"], shell: ["CARGO_HOME": ["registry", "git"]], processes: ["cargo"]),
        // Partial and finished downloads of rustup; ~/.rustup/toolchains is never touched. A `cargo`/`rustc` proxy
        // may install a pinned toolchain (rust-toolchain.toml) into these folders, so those count as running too.
        dev("rustup-downloads", "rustup downloads", note: "Toolchain downloads, downloaded again by rustup when needed",
            ["~/.rustup/downloads", "~/.rustup/tmp"], shell: ["RUSTUP_HOME": ["downloads", "tmp"]], processes: ["rustup", "cargo", "rustc"]),
        // Unticked: models can be many GB to download again. One entry per `models--org--name` folder (blobs plus
        // snapshot symlinks into them): always removed whole, never inside. ~/.cache/huggingface/token and
        // stored_tokens sit next to these folders and are never listed. Only hub repo folders (`included`, checked at
        // scan and clean): HF_HUB_CACHE is scanned itself, so a mistaken value (`~/Developer`) lists nothing.
        // The `datasets` library cache is not scanned: its folders (`org___set`, `downloads`) have no tool-specific name.
        dev("huggingface-cache", "Hugging Face cache",
            note: "Downloaded models and datasets, downloaded again when a program loads them",
            ["~/.cache/huggingface/hub"], included: ["models--*", "datasets--*", "spaces--*"],
            shell: ["HF_HOME": ["hub"], "HF_HUB_CACHE": [""]], selected: false, selectableEntries: true),
        dev("prisma-engines", "Prisma engines", note: "Engine binaries of Prisma versions, downloaded again when needed",
            ["~/.cache/prisma"]),
        dev("gradle-caches", "Gradle caches", note: "Dependency and build caches, downloaded again on the next build",
            ["~/.gradle/caches"], shell: ["GRADLE_USER_HOME": ["caches"]], processes: ["GradleDaemon", "KotlinCompileDaemon"]),
        // Unticked: every Gradle version a wrapper used; the next build downloads its version again (needs network).
        dev("gradle-wrapper", "Gradle wrapper", note: "Downloaded Gradle versions, downloaded again by the next build",
            ["~/.gradle/wrapper/dists"], shell: ["GRADLE_USER_HOME": ["wrapper/dists"]], selected: false, processes: ["GradleDaemon", "KotlinCompileDaemon"]),
        // Unticked: quick-boot snapshots (GBs each) only make the next boot fast and keep the running state.
        // Deleted, not trashed: regenerable, and the Trash would free nothing. One entry per snapshot folder; the
        // AVD's own data (userdata-qemu.img, sdcard.img, *.ini) sits next to `snapshots` and is never listed.
        // Skipped while an emulator runs (`emulator` launcher, `qemu-system-<arch>[-headless]` engine).
        dev("android-avd-snapshots", "Android emulator snapshots",
            note: "Quick-boot snapshots; the next boot is slower and the emulator's running state is lost",
            ["~/.android/avd/*.avd/snapshots"],
            shell: ["ANDROID_AVD_HOME": ["*.avd/snapshots"], "ANDROID_EMULATOR_HOME": ["avd/*.avd/snapshots"]], selected: false,
            processes: ["emulator", "qemu-system-aarch64", "qemu-system-aarch64-headless",
                        "qemu-system-x86_64", "qemu-system-x86_64-headless"],
            selectableEntries: true),
        // Unticked, to the Trash: each JetBrains IDE / Android Studio version keeps its own settings, plugins,
        // caches and logs folder (`GoLand2025.3`, `AndroidStudio2026.1.1`), left behind by upgrades. Only versions older
        // than the newest of the same product found in these folders are listed (their settings were migrated);
        // never the newest nor folders without a version (`IntelliJServer`, `Daemon`). Android Studio's logs are left
        // to "Old logs" (they sit in ~/Library/Logs/Google with other apps'). User caches skips all of these.
        CleanerItem(id: oldIDEVersions, title: "Old IDE versions",
                    note: "Settings, caches and logs of JetBrains IDE and Android Studio versions replaced by a newer one. Moved to the Trash",
                    paths: ["~/Library/Application Support/JetBrains", "~/Library/Caches/JetBrains", "~/Library/Logs/JetBrains",
                            "~/Library/Application Support/Google", "~/Library/Caches/Google"],
                    mode: .trash, selectedByDefault: false, showsWhenEmpty: false,
                    runningAppBundleIDs: ["com.jetbrains.*", "com.google.android.studio*"],
                    skipsEntry: { { !DeveloperTools.isStaleIDEFolder($0) } }, selectableEntries: true),
        dev("maven-repository", "Maven repository",
            note: "May hold artifacts installed locally with mvn install, which cannot be downloaded again",
            ["~/.m2/repository"], selected: false),
        // Measured with the dry run: brew keeps part of its cache (api, bootsnap) and also removes old versions.
        dev("homebrew-cache", "Homebrew cache", note: "Downloads and old versions (brew cleanup -s)",
            ["~/Library/Caches/Homebrew"],
            command: ShellCommand(executable: "brew", arguments: ["cleanup", "-s"], timeout: .seconds(300)),
            probe: SizeProbe(command: ShellCommand(executable: "brew", arguments: ["cleanup", "-s", "--dry-run"]),
                             parse: { DeveloperTools.brewReclaimable(in: $0).map(SizeProbe.Result.bytes) },
                             fingerprint: { DeveloperTools.brewFingerprint() })),
        dev("composer-cache", "Composer cache", ["~/Library/Caches/composer", "~/.composer/cache", "~/.cache/composer"]),
        // Unticked like Playwright: since Puppeteer 19 this is where its browsers are installed; an existing
        // node_modules does not download them again, so launch() fails until `npx puppeteer browsers install`.
        dev("puppeteer-browsers", "Puppeteer browsers", note: "Downloaded again with npx puppeteer browsers install",
            ["~/.cache/puppeteer"], selected: false),
        // Unticked like Puppeteer: the Cypress binary; `cypress run` fails until `cypress install`.
        // Its own item also keeps it out of "User caches" (`ownedCachePaths`).
        dev("cypress-binary", "Cypress app", note: "Downloaded again with npx cypress install",
            ["~/Library/Caches/Cypress"], selected: false),
        // Unticked: not downloaded again by itself; tests fail until `playwright install` is run.
        dev("playwright-browsers", "Playwright browsers", note: "Downloaded again with playwright install",
            ["~/Library/Caches/ms-playwright"], selected: false),

        // Docker: measured with `docker system df`, only when a daemon is already running.
        // Unticked: `--all` also removes images built locally, which no registry can give back.
        docker("docker-images", "Docker: unused images", note: "Images no container uses. Images built on this Mac must be built again; others are pulled again when needed",
               type: "Images", ["image", "prune", "--all", "--force"], selected: false,
               details: DeveloperTools.dockerUnusedImages),
        docker("docker-build-cache", "Docker: build cache", note: "The next build is slower once",
               type: "Build Cache", ["builder", "prune", "--all", "--force"],
               details: DeveloperTools.dockerPrunableBuildCache),
        // Unticked: a stopped container's own filesystem (outside volumes) is lost with it.
        docker("docker-containers", "Docker: stopped containers",
               note: "Files written inside these containers (outside volumes) are lost",
               type: "Containers", ["container", "prune", "--force"], selected: false,
               details: DeveloperTools.dockerStoppedContainers),
        docker("docker-volumes", "Docker: unused volumes",
               note: "Volumes no container uses; they may hold databases or other data",
               type: "Local Volumes", ["volume", "prune", "--all", "--force"], selected: false,
               details: DeveloperTools.dockerUnusedVolumes),
    ])

    nonisolated static let oldIDEVersions = "old-ide-versions"
    nonisolated private static let clonedNote: LocalizedStringResource =
        "Files projects share with this cache (APFS clones) count in the size but free no space"
    nonisolated private static let simulatorDevices = "~/Library/Developer/CoreSimulator/Devices"
    /// Runtime identifiers the last scan of "old-simulator-runtimes" found.
    nonisolated private static let staleRuntimeIDs = Mutex<[String]>([])

    nonisolated private static func simulators(available: Bool) -> SizeProbe {
        SizeProbe(command: ShellCommand(executable: "/usr/bin/xcrun",
                                        arguments: ["simctl", "list", "devices", available ? "available" : "unavailable", "-j"],
                                        timeout: .seconds(30)),
                  parse: { DeveloperTools.simulatorIDs(in: $0, available: available).map(SizeProbe.Result.only) })
    }

    /// Asks the installed tool where its cache is (config files it reads, e.g. `go env -w`, `~/.npmrc`).
    /// Folder variables set only in a shell profile are read by `ShellEnvironment` instead (`shell:`).
    nonisolated private static func lookup(_ tool: String, _ arguments: [String], subpath: String = "") -> PathLookup {
        PathLookup(command: ShellCommand(executable: tool, arguments: arguments, timeout: .seconds(10)), subpath: subpath)
    }

    nonisolated private static func dev(
        _ id: String, _ title: LocalizedStringResource, note: LocalizedStringResource? = nil, _ paths: [String],
        minAge: TimeInterval? = nil, included: [String]? = nil, mode: RemovalMode = .delete, command: ShellCommand? = nil,
        probe: SizeProbe? = nil, locate: PathLookup? = nil, shell: [String: [String]] = [:], selected: Bool = true, apps: [String] = [],
        processes: [String] = [], upperBound: Bool = false,
        entryLabel: CleanerItem.EntryLabel? = nil, selectableEntries: Bool = false
    ) -> CleanerItem {
        CleanerItem(id: id, title: title, note: note, paths: paths, minAge: minAge, included: included, mode: mode,
                    selectedByDefault: selected, command: command, probe: probe, locate: locate, shellFolders: shell,
                    sizeIsUpperBound: upperBound,
                    showsWhenEmpty: false,
                    runningAppBundleIDs: apps, runningProcessNames: processes, entryLabel: entryLabel, selectableEntries: selectableEntries)
    }

    nonisolated private static func docker(
        _ id: String, _ title: LocalizedStringResource, note: LocalizedStringResource, type: String,
        _ cleanArguments: [String], selected: Bool = true,
        details: (@Sendable (String) -> [ScanEntry])? = nil // parses `docker system df -v`, one entry each
    ) -> CleanerItem {
        // `--host` beats DOCKER_HOST/DOCKER_CONTEXT and the current context, so a remote context is never pruned.
        let host: @Sendable () -> [String]? = { DeveloperTools.localDockerHostArguments() }
        return dev(id, title, note: note, [],
            command: ShellCommand(executable: "docker", arguments: cleanArguments, timeout: .seconds(300),
                                  leadingArguments: host),
            probe: SizeProbe(command: ShellCommand(executable: "docker",
                                                   arguments: ["system", "df", "--format", "{{json .}}"],
                                                   timeout: .seconds(20), leadingArguments: host),
                             precondition: DeveloperTools.dockerDaemonIsRunning,
                             parse: { DeveloperTools.dockerReclaimable(type, in: $0).map(SizeProbe.Result.bytes) },
                             details: details.map { (ShellCommand(executable: "docker", arguments: ["system", "df", "-v", "--format", "{{json .}}"],
                                                                  timeout: .seconds(20), leadingArguments: host), $0) }),
            selected: selected)
    }
}

/// Parsers for developer tool output, kept pure so they can be unit-tested.
nonisolated enum DeveloperTools {
    /// UDIDs from `xcrun simctl list devices [available|unavailable] -j`.
    static func simulatorIDs(in json: String, available: Bool) -> Set<String>? {
        struct Device: Decodable { let udid: String; let isAvailable: Bool? }
        struct List: Decodable { let devices: [String: [Device]] }
        guard let list = try? JSONDecoder().decode(List.self, from: Data(json.utf8)) else { return nil }
        return Set(list.devices.values.joined().filter { ($0.isAvailable ?? true) == available }.map(\.udid))
    }

    /// Runtimes in `xcrun simctl runtime list -j` that simctl may delete, that a newer installed runtime of the same
    /// platform replaces (so never the only or newest one) and that were not used for `unusedDays`; nil = none.
    static func staleRuntimes(in json: String, now: Date = .now, unusedDays: Double = 30) -> (ids: [String], bytes: Int64)? {
        struct Runtime: Decodable {
            let identifier: String, platformIdentifier: String, version: String
            let deletable: Bool?, sizeBytes: Int64?, lastUsedAt: Date?
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let runtimes = try? decoder.decode([String: Runtime].self, from: Data(json.utf8)).values else { return nil }
        let cutoff = now.addingTimeInterval(-unusedDays * 86_400)
        let stale = runtimes.filter { old in
            old.deletable == true && (old.lastUsedAt ?? .distantPast) < cutoff && runtimes.contains {
                $0.platformIdentifier == old.platformIdentifier
                    && old.version.compare($0.version, options: .numeric) == .orderedAscending
            }
        }.sorted { $0.identifier < $1.identifier }
        return stale.isEmpty ? nil : (stale.map(\.identifier), stale.reduce(0) { $0 + ($1.sizeBytes ?? 0) })
    }

    /// IDE folders (`GoLand2025.3`, `AndroidStudio2026.1.1`) that a newer version of the same product replaces; never
    /// the newest one nor a name without a `<year>.<n>` version (`IntelliJServer`, `Daemon`, `consentOptions`).
    static func staleIDEFolders(_ names: some Sequence<String>) -> Set<String> {
        let versioned = names.compactMap { name -> (name: String, product: Substring, version: Substring)? in
            guard let match = name.wholeMatch(of: #/([A-Za-z]+)(\d{4}(?:\.\d+)+)/#) else { return nil }
            return (name, match.1, match.2)
        }
        return Set(versioned.filter { old in
            versioned.contains { $0.product == old.product && old.version.compare($0.version, options: .numeric) == .orderedAscending }
        }.map(\.name))
    }

    /// Whether `<Library>/{Application Support,Caches,Logs}/{JetBrains,Google}/<name>` is an old IDE version: the newest
    /// of each product is found across those three folders together. In Google only `AndroidStudio…` counts.
    static func isStaleIDEFolder(_ url: URL) -> Bool {
        let vendor = url.deletingLastPathComponent()
        let library = vendor.deletingLastPathComponent().deletingLastPathComponent()
        let names = ["Application Support", "Caches", "Logs"].flatMap { folder in
            (try? FileManager.default.contentsOfDirectory(atPath: library.appending(path: folder)
                .appending(path: vendor.lastPathComponent).path)) ?? []
        }.filter { vendor.lastPathComponent == "JetBrains" || $0.hasPrefix("AndroidStudio") }
        return names.contains(url.lastPathComponent) && staleIDEFolders(names).contains(url.lastPathComponent)
    }

    /// `~/Library/Caches/JetBrains` and `~/Library/Caches/Google/AndroidStudio…`: left to "Old IDE versions",
    /// so "User caches" never removes the current IDE's caches (indexes), even while it runs (folders not named by bundle id).
    static func isIDECache(_ components: ArraySlice<String>) -> Bool {
        components.first == "JetBrains"
            || components.first == "Google" && components.dropFirst().first?.hasPrefix("AndroidStudio") == true
    }

    /// Reclaimable bytes of one `Type` ("Images", "Containers", "Local Volumes", "Build Cache")
    /// from `docker system df --format '{{json .}}'` (one JSON object per line, e.g. "Reclaimable":"1.9GB (77%)").
    static func dockerReclaimable(_ type: String, in output: String) -> Int64? {
        for line in output.split(whereSeparator: \.isNewline) {
            guard let row = try? JSONDecoder().decode([String: String].self, from: Data(line.utf8)),
                  row["Type"] == type, let value = row["Reclaimable"] else { continue }
            return bytes(fromDockerSize: String(value.split(separator: " ").first ?? ""))
        }
        return nil
    }

    /// Images `docker image prune --all` removes, from `docker system df -v --format '{{json .}}'`: those no
    /// container uses, stopped ones included ("Containers":"0", counted by image ID like prune does). One entry per
    /// tag; `Size` counts layers shared with other images, so entries can add up to more than the item's size.
    /// shortcut: untagged intermediate build images are not in this list though prune removes them; they are small.
    static func dockerUnusedImages(in output: String) -> [ScanEntry] {
        struct Image: Decodable {
            let Containers: String, CreatedAt: String, ID: String, Repository: String, Size: String, Tag: String
        }
        struct Report: Decodable { let Images: [Lenient<Image>]? }
        guard let report = try? JSONDecoder().decode(Report.self, from: Data(output.utf8)) else { return [] }
        return readable(report.Images, scheme: "docker-image") { index, image in
            guard image.Containers == "0", let url = URL(string: "docker-image:\(index)") else { return nil }
            let shortID = String(image.ID.replacingOccurrences(of: "sha256:", with: "").prefix(12))
            let named = image.Repository != "<none>" && !image.Repository.isEmpty
            let title = named ? image.Repository + (image.Tag == "<none>" ? "" : ":" + image.Tag) : shortID
            return ScanEntry(url: url, size: bytes(fromDockerSize: image.Size) ?? 0, title: title,
                             date: dockerDate(image.CreatedAt))
        }
    }

    /// Containers `docker container prune` removes, from `docker system df -v --format '{{json .}}'`: every one
    /// that is not running (prune keeps running, paused and restarting ones). Title "name · image · status".
    static func dockerStoppedContainers(in output: String) -> [ScanEntry] {
        struct Container: Decodable {
            let CreatedAt: String, Image: String, Names: String, Size: String, State: String, Status: String
        }
        struct Report: Decodable { let Containers: [Lenient<Container>]? }
        guard let report = try? JSONDecoder().decode(Report.self, from: Data(output.utf8)) else { return [] }
        return readable(report.Containers, scheme: "docker-container") { index, container in
            guard !["running", "paused", "restarting"].contains(container.State),
                  let url = URL(string: "docker-container:\(index)") else { return nil }
            return ScanEntry(url: url, size: bytes(fromDockerSize: container.Size) ?? 0,
                             title: [container.Names, container.Image, container.Status].joined(separator: " · "),
                             date: dockerDate(container.CreatedAt))
        }
    }

    /// Volumes `docker volume prune --all` removes (the item passes `--all`, so named volumes too, not only
    /// anonymous ones): those no container uses, stopped ones included ("Links":"0"). Title "name · driver";
    /// an anonymous volume (64-hex name or the anonymous label) shows its short ID and is marked as such.
    static func dockerUnusedVolumes(in output: String) -> [ScanEntry] {
        struct Volume: Decodable { let Driver: String, Labels: String, Links: String, Name: String, Size: String }
        struct Report: Decodable { let Volumes: [Lenient<Volume>]? }
        guard let report = try? JSONDecoder().decode(Report.self, from: Data(output.utf8)) else { return [] }
        return readable(report.Volumes, scheme: "docker-volume") { index, volume in
            guard volume.Links == "0", let url = URL(string: "docker-volume:\(index)") else { return nil }
            let anonymous = volume.Labels.contains("com.docker.volume.anonymous")
                || volume.Name.count == 64 && volume.Name.allSatisfy(\.isHexDigit)
            let name = anonymous ? String(volume.Name.prefix(12)) + " · " + String(localized: "anonymous") : volume.Name
            return ScanEntry(url: url, size: bytes(fromDockerSize: volume.Size) ?? 0, title: name + " · " + volume.Driver)
        }
    }

    /// Build cache records `docker builder prune --all` removes, from `docker system df -v --format '{{json .}}'`:
    /// every record not in use ("InUse":"false"; `--all` also takes internal/frontend ones, not only dangling).
    /// Title "short id · type · description", date = last use. A "Shared" record's data also belongs to an image,
    /// so removing it frees nothing: size 0 and marked, matching docker's Reclaimable (InUse and Shared both false).
    static func dockerPrunableBuildCache(in output: String) -> [ScanEntry] {
        struct Record: Decodable {
            let CacheType: String, Description: String, ID: String, InUse: String, LastUsedAt: String?, Shared: String, Size: String
        }
        struct Report: Decodable { let BuildCache: [Lenient<Record>]? }
        guard let report = try? JSONDecoder().decode(Report.self, from: Data(output.utf8)) else { return [] }
        return readable(report.BuildCache, scheme: "docker-build-cache") { index, record in
            guard record.InUse == "false", let url = URL(string: "docker-build-cache:\(index)") else { return nil }
            let shared = record.Shared == "true"
            let description = record.Description.count > 60 ? record.Description.prefix(59) + "…" : record.Description
            var title = [String(record.ID.prefix(12)), record.CacheType, description].joined(separator: " · ")
            if shared { title += " · " + String(localized: "shared with an image, frees no space") }
            return ScanEntry(url: url, size: shared ? 0 : bytes(fromDockerSize: record.Size) ?? 0, title: title,
                             date: record.LastUsedAt.flatMap(dockerDate))
        }
    }

    /// A record of `docker system df -v` decoded on its own: one missing field skips that record, not the list.
    struct Lenient<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) { value = try? T(from: decoder) }
    }

    /// `entry` of each readable record (with its index), then one size-0 row counting the unreadable ones: whether
    /// prune removes those can't be told, so they are counted rather than silently dropped (display only).
    static func readable<T>(_ records: [Lenient<T>]?, scheme: String, _ entry: (Int, T) -> ScanEntry?) -> [ScanEntry] {
        let records = records ?? []
        var entries = records.enumerated().compactMap { index, record in record.value.flatMap { entry(index, $0) } }
        let unreadable = records.count(where: { $0.value == nil })
        if unreadable > 0, let url = URL(string: "\(scheme):unreadable") {
            entries.append(ScanEntry(url: url, size: 0,
                                     title: String(localized: "Unreadable entries: \(unreadable) (prune may still remove them)")))
        }
        return entries
    }

    /// "2026-10-22 03:48:02 +0700 +07" or "2026-10-21 20:48:07.187 +0000 UTC" from `docker system df -v`:
    /// fractional seconds and the trailing zone name are dropped.
    static func dockerDate(_ text: String) -> Date? {
        let dates = DateFormatter()
        dates.locale = Locale(identifier: "en_US_POSIX")
        dates.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return dates.date(from: String(text.replacing(/\.\d+/, with: "").prefix(25)))
    }

    /// What `brew cleanup -s --dry-run` lists (it takes 2–4 s): the cache and logs folders, and the installed
    /// versions in Cellar/Caskroom of the prefix brew runs from (`/opt/homebrew/bin/brew` → `/opt/homebrew`).
    /// `Caches/Homebrew/api` changes with each `brew update` (newer versions make cached downloads outdated).
    static func brewFingerprint() -> String {
        let prefix = ShellCommand(executable: "brew").resolvedPath.map {
            URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent()
        }
        return SizeProbe.folderDates(["~/Library/Caches/Homebrew", "~/Library/Caches/Homebrew/api", "~/Library/Logs/Homebrew"]
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            + (prefix.map { [$0.appending(path: "Cellar"), $0.appending(path: "Caskroom")] } ?? []))
    }

    /// Bytes from the last line of `brew cleanup --dry-run`: "==> This operation would free approximately 54.5MB
    /// of disk space." (decimal units). nil when brew has nothing to remove (the line is then absent).
    static func brewReclaimable(in output: String) -> Int64? {
        guard let range = output.range(of: "would free approximately ") else { return nil }
        return bytes(fromDockerSize: String(output[range.upperBound...].prefix { !$0.isWhitespace }))
    }

    /// "1.995GB", "72.24MB", "512kB", "0B" (Docker uses decimal units) → bytes.
    static func bytes(fromDockerSize text: String) -> Int64? {
        let units: [String: Double] = [
            "B": 1, "kB": 1e3, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12, "PB": 1e15,
            "KiB": 1024, "MiB": 1_048_576, "GiB": 1_073_741_824, "TiB": 1_099_511_627_776,
        ]
        let number = text.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(number), let unit = units[String(text.dropFirst(number.count))] else { return nil }
        return Int64(value * unit)
    }

    /// Unix sockets of Docker Desktop, OrbStack, Colima, Rancher Desktop and the default path.
    static let dockerSockets = [
        "~/.docker/run/docker.sock", "~/.orbstack/run/docker.sock", "~/.colima/default/docker.sock",
        "~/.rd/docker.sock", "/var/run/docker.sock",
    ].map { ($0 as NSString).expandingTildeInPath }

    /// True when a Docker daemon accepts connections. Checked before running the CLI, because some CLIs
    /// (e.g. OrbStack's) launch the engine when it is stopped; CleanMate must never start Docker.
    @Sendable static func dockerDaemonIsRunning() -> Bool {
        localDockerHostArguments() != nil
    }

    /// Socket of the current Docker context (`~/.docker/config.json` `currentContext`, endpoint in
    /// `contexts/meta/<sha256 of name>/meta.json`) when it is a local `unix://` endpoint; [] for tcp/ssh
    /// (remote, never used) or unreadable config. No config/`currentContext` means the "default" context.
    static func currentContextSockets(dockerDir: String = ("~/.docker" as NSString).expandingTildeInPath) -> [String] {
        struct Config: Decodable { let currentContext: String? }
        struct Meta: Decodable {
            struct Endpoint: Decodable { let Host: String? }
            let Endpoints: [String: Endpoint]
        }
        let config = (try? Data(contentsOf: URL(fileURLWithPath: dockerDir + "/config.json")))
            .flatMap { try? JSONDecoder().decode(Config.self, from: $0) }
        let name = config?.currentContext ?? ""
        let host: String?
        if name.isEmpty || name == "default" {
            host = "unix:///var/run/docker.sock"
        } else {
            let hash = SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
            host = (try? Data(contentsOf: URL(fileURLWithPath: dockerDir + "/contexts/meta/\(hash)/meta.json")))
                .flatMap { try? JSONDecoder().decode(Meta.self, from: $0) }?.Endpoints["docker"]?.Host
        }
        guard let host, host.hasPrefix("unix://") else { return [] }
        return [String(host.dropFirst("unix://".count))]
    }

    /// `--host unix://<first local socket accepting connections>`, trying the current context's local socket
    /// first; nil when none does (Docker then counts as stopped). Every docker command passes it so the
    /// CLI never follows a remote context or DOCKER_HOST.
    static func localDockerHostArguments(sockets: [String] = currentContextSockets() + dockerSockets) -> [String]? {
        sockets.first(where: canConnect(toSocket:)).map { ["--host", "unix://" + $0] }
    }

    static func canConnect(toSocket path: String) -> Bool {
        var address = sockaddr_un()
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) == 0 }
        }
    }
}
