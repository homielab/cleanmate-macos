import Foundation
import Testing
@testable import CleanMate

/// Julia, Conan 2, Expo, Hex, PlatformIO and Arduino caches, old Godot export templates and the Pythons uv
/// installed: a fake home in a throwaway folder; the real home is never read.
struct MoreDeveloperCachesTests {
    let fm = FileManager.default
    let root = FileManager.default.temporaryDirectory.appending(path: "CleanMateMoreDeveloperCaches-\(UUID().uuidString)")
    var home: URL { root.appending(path: "home") }
    let caches = ["julia-compiled", "julia-artifacts", "conan-packages", "expo-cache", "hex-packages", "platformio-cache",
                  "arduino-downloads"]

    func policy() -> SafetyPolicy { SafetyPolicy(home: home, temp: root.appending(path: "tmp")) }
    func item(_ id: String) throws -> CleanerItem { try #require(CleanerGroup.developer.items.first { $0.id == id }) }
    func exists(_ path: String) -> Bool { fm.fileExists(atPath: home.appending(path: path).path) }

    func write(_ path: String, bytes: Int = 4096) throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
    }

    func listed(_ item: CleanerItem) async -> [String] {
        let scan = await Scanner.scan(item, policy: policy(), openPaths: { _ in [] })
        // `$TMPDIR` may be reached through /private: compare the part after the fake home.
        return scan.entries.compactMap { $0.url.path.components(separatedBy: "/home/").last }.sorted()
    }

    /// What can't come back on its own (precompiled and downloaded Julia files, Conan packages built locally, old
    /// templates, Pythons) is unticked.
    @Test func onlySelfHealingCachesAreTicked() throws {
        for id in caches + [GodotTemplates.id, OldRuntimes.uvPythonID] {
            let item = try item(id)
            #expect(item.mode == .delete && !item.showsWhenEmpty, "\(id)")
        }
        for id in ["julia-compiled", "julia-artifacts", "conan-packages", GodotTemplates.id, OldRuntimes.uvPythonID] {
            #expect(try !item(id).selectedByDefault, "\(id)")
        }
        for id in ["expo-cache", "hex-packages", "platformio-cache", "arduino-downloads"] {
            #expect(try item(id).selectedByDefault, "\(id)")
        }
    }

    /// Cleaning removes the cache folders only; packages, environments, sign-ins, settings and installed tools stay.
    @Test func cleansOnlyCacheFolders() async throws {
        defer { try? fm.removeItem(at: root) }
        let removed = [
            ".julia/compiled/v1.11/Plots/abc.ji", ".julia/artifacts/0a1b/lib/libx.dylib",
            ".conan2/p/cache.sqlite3", ".conan2/p/zlib1234/p/lib/libz.a",
            ".expo/ios-simulator-app-cache/Exponent-2.31.app/Exponent", ".expo/versions-cache/versions.json",
            ".hex/packages/hexpm/phoenix-1.7.0.tar",
            ".platformio/.cache/downloads/toolchain.tar.gz",
            "Library/Arduino15/staging/packages/avr-gcc.tar.bz2", ".arduino15/staging/libraries/Servo.zip",
        ]
        let kept = [
            ".julia/packages/Plots/abc/src/Plots.jl", ".julia/environments/v1.11/Manifest.toml", ".julia/registries/General.toml",
            ".julia/dev/Mine/src/Mine.jl", ".julia/config/startup.jl", ".julia/scratchspaces/uuid/data.bin",
            ".conan2/profiles/default", ".conan2/remotes.json", ".conan2/settings.yml",
            ".expo/state.json", ".expo/codesigning/key.pem",
            ".hex/hex.config", ".hex/cache.ets", ".mix/archives/hex-2.0.6/hex-2.0.6/ebin/hex.app", ".mix/rebar3",
            ".platformio/packages/toolchain-atmelavr/bin/avr-gcc", ".platformio/platforms/atmelavr/platform.json",
            ".platformio/penv/bin/pio", ".platformio/appstate.json",
            "Library/Arduino15/packages/arduino/hardware/avr/1.8.6/boards.txt", "Library/Arduino15/arduino-cli.yaml",
            "Library/Arduino15/library_index.json",
        ]
        for path in removed + kept { try write(path) }
        for id in caches {
            let item = try item(id)
            let scan = await Scanner.scan(item, policy: policy(), openPaths: { _ in [] })
            #expect(!scan.entries.isEmpty, "\(id)")
            #expect(await Cleaner.clean(item, scan: scan, policy: policy()).skipped == 0, "\(id)")
        }
        for path in removed { #expect(!exists(path), "\(path)") }
        for path in kept { #expect(exists(path), "\(path)") }
    }

    @Test func hiddenWhenAbsent() async throws {
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        for id in caches + [GodotTemplates.id, OldRuntimes.uvPythonID] {
            #expect(try await listed(item(id)).isEmpty, "\(id)")
        }
    }

    /// Folders moved with JULIA_DEPOT_PATH, CONAN_HOME, HEX_HOME, PLATFORMIO_CORE_DIR and ARDUINO_DIRECTORIES_DATA in the
    /// shell profile: only the cache folder below each.
    @Test func readsFoldersFromTheShellProfile() async throws {
        defer { try? fm.removeItem(at: root) }
        for path in ["jl/depot/compiled/v1.11/x.ji", "jl/depot/artifacts/ab/x", "jl/depot/packages/P/x.jl",
                     "cpp/conan/p/x", "cpp/conan/profiles/default", "ex/hex/packages/hexpm/x.tar", "ex/hex/hex.config",
                     "mcu/pio/.cache/x", "mcu/pio/packages/x", "mcu/arduino/staging/x", "mcu/arduino/packages/x"] {
            try write(path)
        }
        let profile = "export JULIA_DEPOT_PATH=$HOME/jl/depot\nexport CONAN_HOME=$HOME/cpp/conan\nexport HEX_HOME=$HOME/ex/hex\n"
            + "export PLATFORMIO_CORE_DIR=$HOME/mcu/pio\nexport ARDUINO_DIRECTORIES_DATA=$HOME/mcu/arduino\n"
        try profile.write(to: home.appending(path: ".zshrc"), atomically: true, encoding: .utf8)
        let expected = [("julia-compiled", "jl/depot/compiled"), ("julia-artifacts", "jl/depot/artifacts"),
                        ("conan-packages", "cpp/conan/p"), ("hex-packages", "ex/hex/packages"),
                        ("platformio-cache", "mcu/pio/.cache"), ("arduino-downloads", "mcu/arduino/staging")]
        for (id, folder) in expected {
            let entries = try await listed(item(id))
            #expect(!entries.isEmpty && entries.allSatisfy { $0 == folder || $0.hasPrefix(folder + "/") }, "\(id): \(entries)")
        }
    }

    /// A list of depots (`a:b`) is not one folder: nothing extra is listed.
    @Test func juliaDepotListIsNotFollowed() async throws {
        defer { try? fm.removeItem(at: root) }
        try write("jl/a/compiled/v1.11/x.ji")
        try "export JULIA_DEPOT_PATH=$HOME/jl/a:$HOME/jl/b\n".write(to: home.appending(path: ".zshrc"), atomically: true, encoding: .utf8)
        #expect(try await listed(item("julia-compiled")).isEmpty)
    }

    @Test func skippedWhileItsToolRuns() throws {
        for (id, tool) in [("julia-compiled", "julia"), ("julia-artifacts", "julia"), ("conan-packages", "conan"),
                           ("expo-cache", "expo"), ("hex-packages", "beam.smp"), ("platformio-cache", "pio"),
                           ("arduino-downloads", "arduino-cli"), (OldRuntimes.uvPythonID, "uv")] {
            #expect(try item(id).runningBlocker(apps: [], processes: ["zsh", tool]) == tool, "\(id)")
            #expect(try item(id).runningBlocker(apps: [], processes: ["zsh", "node"]) == nil, "\(id)")
        }
        #expect(try item("arduino-downloads").runningBlocker(apps: ["cc.arduino.IDE2"], processes: []) != nil)
        #expect(try item(GodotTemplates.id).runningBlocker(apps: ["org.godotengine.godot"], processes: []) != nil)
        #expect(try item(GodotTemplates.id).runningBlocker(apps: ["com.apple.Safari"], processes: []) == nil)
    }

    @Test func godotVersionsAreCompared() {
        #expect(GodotTemplates.stale(["4.2.1.stable", "4.3.stable", "4.3.beta2", "4.3.rc1", "3.5.3.stable", "4.10.dev1"])
                == ["4.2.1.stable", "4.3.stable", "4.3.beta2", "4.3.rc1", "3.5.3.stable"])
        #expect(GodotTemplates.stale(["4.3.stable", "4.3.rc2", "4.3.beta10"]) == ["4.3.rc2", "4.3.beta10"])
        // Each flavour keeps its own newest; other names are never stale.
        #expect(GodotTemplates.stale(["4.3.stable", "4.2.stable.mono", "4.1.stable.mono", "notes", "4.3", ".DS_Store"])
                == ["4.1.stable.mono"])
        #expect(GodotTemplates.stale(["4.3.stable"]).isEmpty)
    }

    /// Only older template versions are listed and removed; the newest, a link and other folders stay.
    @Test func godotKeepsTheNewestTemplates() async throws {
        defer { try? fm.removeItem(at: root) }
        let base = "Library/Application Support/Godot/"
        for path in ["export_templates/4.2.1.stable/macos.zip", "export_templates/4.3.stable/macos.zip",
                     "export_templates/4.3.stable.mono/macos.zip", "export_templates/custom/macos.zip",
                     "editor_settings-4.tres", "projects.cfg"] {
            try write(base + path)
        }
        try fm.createSymbolicLink(at: home.appending(path: base + "export_templates/4.1.stable"),
                                  withDestinationURL: home.appending(path: base + "export_templates/4.3.stable"))
        let item = try item(GodotTemplates.id)
        #expect(await listed(item) == [base + "export_templates/4.2.1.stable"])
        let scan = await Scanner.scan(item, policy: policy(), openPaths: { _ in [] })
        #expect(await Cleaner.clean(item, scan: scan, policy: policy()).skipped == 0)
        #expect(!exists(base + "export_templates/4.2.1.stable"))
        for path in ["export_templates/4.3.stable/macos.zip", "export_templates/4.3.stable.mono/macos.zip",
                     "export_templates/custom/macos.zip", "editor_settings-4.tres", "projects.cfg"] {
            #expect(exists(base + path), "\(path)")
        }
    }

    /// One entry per Python uv installed; links, hidden files and other names are not listed. Each is removed by
    /// uv itself, and one a program runs from is locked.
    @Test func uvPythonsAreListedOneByOne() async throws {
        defer { try? fm.removeItem(at: root) }
        let base = ".local/share/uv/python/"
        let names = ["cpython-3.12.4-macos-aarch64-none", "cpython-3.13.0+freethreaded-macos-aarch64-none",
                     "pypy-3.10.14-macos-x86_64-none"]
        for name in names { try write(base + name + "/bin/python3") }
        for path in [".lock", ".gitignore", ".temp/x", "notes/readme"] { try write(base + path) }
        try fm.createSymbolicLink(at: home.appending(path: base + "cpython-3.12-macos-aarch64-none"),
                                  withDestinationURL: home.appending(path: base + names[0]))
        let busy = home.appending(path: base + names[0] + "/bin/python3").path
        let item = OldRuntimes.uvPythonItem(running: { [busy] })
        #expect(!item.selectedByDefault && item.selectableEntries)
        let scan = await Scanner.scan(item, policy: policy(), openPaths: { _ in [] })
        #expect(scan.entries.map(\.url.lastPathComponent).sorted() == names.sorted())
        #expect(scan.entries.filter { $0.lockReason != nil }.map(\.url.lastPathComponent) == [names[0]])

        let command = try #require(item.entryCommand?(home.appending(path: base + names[2])))
        #expect(command.executable == "uv" && command.arguments == ["python", "uninstall", names[2]])
        for odd in ["--all", "cpython-3.12-macos-aarch64-none; rm", "notes", "3.12"] {
            #expect(item.entryCommand?(home.appending(path: base + odd)) == nil, "\(odd)")
        }
        #expect(!OldRuntimes.isUVPython("cpython-3.12.4-linux-x86_64-gnu") && !OldRuntimes.isUVPython("-3.12.4-macos-aarch64-none"))
    }
}
