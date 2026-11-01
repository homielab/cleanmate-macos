import Foundation
import Testing
@testable import CleanMate

/// Old Android SDK components in Smart Scan: each NDK, build-tools, platform or CMake version older than the newest of
/// its kind is listed on its own, unticked, and deleted whole, unless a project in the project folders pins it.
/// Everything happens in a throwaway fake home.
struct AndroidSDKComponentsTests {
    private struct Home {
        let root = TestTemp.url("CleanMateAndroidSDK")
        var home: URL { root.appending(path: "home") }
        var policy: SafetyPolicy { SafetyPolicy(home: home, temp: root.appending(path: "tmp")) }
        static let sdk = "Library/Android/sdk"

        init() throws {
            for dir in ["home", "tmp"] {
                try FileManager.default.createDirectory(at: root.appending(path: dir), withIntermediateDirectories: true)
            }
        }

        @discardableResult
        func file(_ path: String, _ text: String? = nil) throws -> URL {
            let url = home.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (text.map { Data($0.utf8) } ?? Data(repeating: 1, count: 40_000)).write(to: url)
            return url
        }

        /// An installed component `<sdk>/<path>` with a payload and the SDK Manager's `source.properties`.
        @discardableResult
        func component(_ path: String, revision: String? = nil, api: String? = nil, sdk: String = Home.sdk) throws -> URL {
            let folder = sdk + "/" + path
            try file(folder + "/payload.bin")
            var properties = "Pkg.Desc=Component\n"
            if let revision { properties += "Pkg.Revision=\(revision)\n" }
            if let api { properties += "AndroidVersion.ApiLevel=\(api)\n" }
            try file(folder + "/source.properties", properties)
            return home.appending(path: folder)
        }

        /// The SDK of the acceptance criteria: three NDKs, build-tools and platforms, two CMakes.
        func standardSDK() throws -> [String: URL] {
            var found: [String: URL] = [:]
            for (key, path, revision) in [("ndk26", "ndk/26.1.10909125", "26.1.10909125"), ("ndk27", "ndk/27.1.12297006", "27.1.12297006"),
                                          ("ndk28", "ndk/28.0.13004108", "28.0.13004108"),
                                          ("bt34", "build-tools/34.0.0", "34.0.0"), ("bt35", "build-tools/35.0.0", "35.0.0"),
                                          ("bt36", "build-tools/36.0.0", "36.0.0"),
                                          ("cmake322", "cmake/3.22.1", "3.22.1.9987284"), ("cmake330", "cmake/3.30.5", "3.30.5")] {
                found[key] = try component(path, revision: revision)
            }
            for api in ["33", "34", "35"] { found["p\(api)"] = try component("platforms/android-\(api)", revision: "3", api: api) }
            return found
        }

        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private func item() -> CleanerItem {
        AndroidSDKComponents.item(hasFullDiskAccess: { true }, sizes: FolderSizeCache(file: nil))
    }

    private func listed(_ box: Home, _ item: CleanerItem) async -> [String] {
        await Scanner.scan(item, policy: box.policy).entries.map(\.url.standardizedFileURL.path).sorted()
    }

    @Test func catalogItem() throws {
        let item = try #require(CleanerGroup.developer.items.first { $0.id == AndroidSDKComponents.id })
        #expect(!item.selectedByDefault && item.selectableEntries && item.mode == .delete && !item.showsWhenEmpty)
        #expect(item.command == nil && item.probe == nil && item.included == nil && item.minAge == nil)
        #expect(item.skipsOpenFiles && item.allowsEntry != nil && item.entryLabel != nil && item.findEntries != nil)
        #expect(item.entrySizes != nil && item.note != nil)
        #expect(item.paths == ["~/Library/Android/sdk"])
        #expect(item.shellFolders == ["ANDROID_HOME": [""], "ANDROID_SDK_ROOT": [""]])
        #expect(Set(item.shellFolders.keys).isSubset(of: ShellEnvironment.variables))
        // Right after the system images.
        let ids = CleanerGroup.developer.items.map(\.id)
        #expect(ids.firstIndex(of: AndroidSDKComponents.id) == ids.firstIndex(of: AndroidSystemImages.id).map { $0 + 1 })
    }

    /// The acceptance SDK: every version but the newest of each kind is listed with `<kind> <version>`; a project
    /// pinning NDK 26.1 and compileSdk 33 takes those two off the list, and `allowsEntry` refuses them.
    @Test func listsOlderVersionsAndKeepsPinnedOnes() async throws {
        let box = try Home()
        defer { box.remove() }
        let sdk = try box.standardSDK()
        let item = item()
        let older = ["ndk26", "ndk27", "bt34", "bt35", "p33", "p34", "cmake322"]
        #expect(await listed(box, item) == older.map { sdk[$0]!.path }.sorted())
        let scan = await Scanner.scan(item, policy: box.policy)
        #expect(Set(scan.entries.compactMap { item.entryLabel?($0.url)?.title }) == [
            "NDK 26.1.10909125", "NDK 27.1.12297006", "Build-Tools 34.0.0", "Build-Tools 35.0.0",
            "Android SDK Platform 33", "Android SDK Platform 34", "CMake 3.22.1.9987284"])
        #expect(scan.entries.allSatisfy { $0.size >= 40_000 && item.entryLabel?($0.url)?.date != nil })

        try box.file("Developer/client/app/android/app/build.gradle", """
            android {
                compileSdk 33
                ndkVersion "26.1.10909125"
            }
            """)
        let pinned = AndroidSDKComponents.item(hasFullDiskAccess: { true }, sizes: FolderSizeCache(file: nil))
        #expect(await listed(box, pinned) == ["ndk27", "bt34", "bt35", "p34", "cmake322"].map { sdk[$0]!.path }.sorted())
        for key in ["ndk26", "p33"] { #expect(pinned.allowsEntry?(box.policy, sdk[key]!) == false, "\(key)") }
        // The newest of a kind is never allowed either.
        for key in ["ndk28", "bt36", "p35", "cmake330"] { #expect(pinned.allowsEntry?(box.policy, sdk[key]!) == false, "\(key)") }
        #expect(pinned.allowsEntry?(box.policy, sdk["ndk27"]!) == true)
    }

    /// Cleaning deletes the ticked version's folder only; the newest and the other versions stay.
    @Test func cleaningDeletesOnlyTheTickedVersion() async throws {
        let box = try Home()
        defer { box.remove() }
        let sdk = try box.standardSDK()
        let item = item()
        let scan = await Scanner.scan(item, policy: box.policy)
        var one = scan
        one.entries = scan.entries.filter { $0.url.standardizedFileURL.path == sdk["ndk26"]!.path }
        let size = try #require(one.entries.first?.size)
        let report = await Cleaner.clean(item, scan: one, policy: box.policy)
        #expect(report.skipped == 0 && report.freed == size)
        #expect(!box.exists(sdk["ndk26"]!))
        #expect(sdk.filter { $0.key != "ndk26" }.values.allSatisfy(box.exists))
        #expect(box.exists(box.home.appending(path: Home.sdk + "/ndk")))
    }

    /// A project pinned after the scan keeps its version: asked again right before removal.
    @Test func aPinAddedAfterTheScanKeepsTheVersion() async throws {
        let box = try Home()
        defer { box.remove() }
        let sdk = try box.standardSDK()
        let scan = await Scanner.scan(item(), policy: box.policy)
        #expect(scan.entries.contains { $0.url.standardizedFileURL.path == sdk["bt34"]!.path })
        try box.file("Projects/app/build.gradle.kts", #"android { buildToolsVersion = "34.0.0" }"#)
        let report = await Cleaner.clean(item(), scan: scan.filtered { $0.url.standardizedFileURL.path == sdk["bt34"]!.path },
                                         policy: box.policy)
        #expect(report.skipped == 1 && box.exists(sdk["bt34"]!))
    }

    /// `ndk.dir` in a project's `local.properties` (escaped as Android Studio writes it) keeps that NDK.
    @Test func ndkDirInLocalPropertiesKeepsThatNDK() async throws {
        let box = try Home()
        defer { box.remove() }
        let sdk = try box.standardSDK()
        let path = sdk["ndk27"]!.path.replacingOccurrences(of: ":", with: "\\:")
        try box.file("Code/game/settings.gradle", "include ':app'\n")
        try box.file("Code/game/local.properties", "sdk.dir=\(box.home.path)/\(Home.sdk)\nndk.dir=\(path)\n")
        let listed = await listed(box, item())
        #expect(!listed.contains(sdk["ndk27"]!.path) && listed.contains(sdk["ndk26"]!.path))
    }

    /// Only the component folders are ever listed: not `platform-tools`, `emulator`, `system-images`, `licenses`,
    /// `.knownPackages`, other SDK files, a version folder without `source.properties`, a hidden one or a symlink.
    @Test func neverListsAnythingElse() async throws {
        let box = try Home()
        defer { box.remove() }
        let sdk = try box.standardSDK()
        for path in ["platform-tools/adb", "emulator/emulator", "emulator/source.properties", "licenses/android-sdk-license",
                     ".knownPackages", "system-images/android-33/default/arm64-v8a/source.properties", "tools/bin/sdkmanager",
                     "build-tools/30.0.3/aapt2", "ndk/99.0.0/README", "cmake/.3.10.2/source.properties"] {
            try box.file(Home.sdk + "/" + path)
        }
        // A version folder without source.properties neither is listed nor counts as the newest.
        let link = box.home.appending(path: Home.sdk + "/build-tools/20.0.0")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sdk["bt34"]!)
        let listed = await listed(box, item())
        #expect(listed == ["ndk26", "ndk27", "bt34", "bt35", "p33", "p34", "cmake322"].map { sdk[$0]!.path }.sorted())
        #expect(AndroidSDKComponents.component(link) == nil)
        #expect(AndroidSDKComponents.component(box.home.appending(path: Home.sdk + "/build-tools/30.0.3")) == nil)
    }

    /// The old-style `ndk-bundle` is an NDK like the others: listed when older than the newest `ndk/<version>`.
    @Test func ndkBundleIsAnOldNDK() async throws {
        let box = try Home()
        defer { box.remove() }
        let bundle = try box.component("ndk-bundle", revision: "21.4.7075529")
        let newest = try box.component("ndk/27.1.12297006", revision: "27.1.12297006")
        let item = item()
        #expect(await listed(box, item) == [bundle.path])
        #expect(item.entryLabel?(bundle)?.title == "NDK 21.4.7075529 (ndk-bundle)")
        #expect(box.exists(newest))
        // Alone, it is the newest.
        try FileManager.default.removeItem(at: newest)
        #expect(await listed(box, AndroidSDKComponents.item(hasFullDiskAccess: { true })).isEmpty)
    }

    /// A platform preview (`CodeName`) or a version that can't be read is kept; the newest is chosen by version, not
    /// by name (`build-tools/9.0.0` is older than `10.0.0`), a release candidate below its release.
    @Test func versionsAreComparedAsNumbers() async throws {
        let box = try Home()
        defer { box.remove() }
        let nine = try box.component("build-tools/9.0.0", revision: "9.0.0")
        let rc = try box.component("build-tools/10.0.0-rc1", revision: "10.0.0 rc1")
        try box.component("build-tools/10.0.0", revision: "10.0.0")
        try box.component("build-tools/latest", revision: "unknown")
        try box.component("platforms/android-34", revision: "3", api: "34")
        let preview = try box.component("platforms/android-Baklava", revision: "1", api: "35")
        try box.file(Home.sdk + "/platforms/android-Baklava/source.properties", "AndroidVersion.ApiLevel=35\nAndroidVersion.CodeName=Baklava\n")
        try box.component("platforms/android-35", revision: "1", api: "35")
        let listed = await listed(box, item())
        #expect(listed == [nine, rc, box.home.appending(path: Home.sdk + "/platforms/android-34")].map(\.path).sorted())
        #expect(!listed.contains(preview.path))
        typealias V = AndroidSDKComponents.Version
        #expect(V("9.0.0")! < V("10.0.0")! && V("10.0.0 rc1")! < V("10.0.0")! && V("34")! == V("34.0.0")!)
        #expect(V("26.1.10909125")!.isPinned(by: V("26.1")!) && !V("26.10.1")!.isPinned(by: V("26.1")!))
        #expect(V("36.1")!.isPinned(by: V("36")!) && !V("35.0.0")!.isPinned(by: V("36")!) && V("unknown") == nil)
    }

    /// The pins read from Groovy and Kotlin build files, a root `ext` block included; values CleanMate can't read
    /// pin nothing.
    @Test func readsPinsFromGradleFiles() {
        let groovy = AndroidSDKComponents.gradlePins(in: """
            buildscript { ext { ndkVersion = "27.1.12297006"; compileSdkVersion = 35; buildToolsVersion = '35.0.0' } }
            android {
                compileSdkVersion "android-34"
                ndkVersion '26.1.10909125'
                buildToolsVersion "34.0.0"
            }
            """)
        #expect(groovy.ndk == ["27.1.12297006", "26.1.10909125"] && groovy.buildTools == ["35.0.0", "34.0.0"])
        #expect(groovy.compileSdk == ["35", "34"])
        let kotlin = AndroidSDKComponents.gradlePins(in: """
            android {
                compileSdk {
                    version = release(36)
                }
                compileSdk = 33
                ndkVersion = "28.0.13004108"
            }
            """)
        #expect(kotlin.compileSdk == ["36", "33"] && kotlin.ndk == ["28.0.13004108"] && kotlin.buildTools.isEmpty)
        let unread = AndroidSDKComponents.gradlePins(in: """
            android {
                compileSdk = flutter.compileSdkVersion
                ndkVersion = flutter.ndkVersion
                compileSdk = libs.versions.compileSdk.get().toInt()
                ndkVersion rootProject.ext.ndkVersion
            }
            """)
        #expect(unread == AndroidSDKComponents.Pins())
    }

    /// Projects are looked for up to four levels into the project folders, never inside `node_modules`, hidden folders
    /// or deeper.
    @Test func looksForProjectsFourLevelsDown() throws {
        let box = try Home()
        defer { box.remove() }
        try box.file("Developer/a/b/c/d/build.gradle", "ndkVersion \"1.0.0\"")
        try box.file("Developer/a/b/c/d/e/build.gradle", "ndkVersion \"2.0.0\"")
        try box.file("Developer/app/node_modules/lib/android/build.gradle", "ndkVersion \"3.0.0\"")
        try box.file("Developer/.hidden/build.gradle", "ndkVersion \"4.0.0\"")
        try box.file("Desktop/app/build.gradle.kts", "ndkVersion = \"5.0.0\"")
        try box.file("Downloads/app/build.gradle", "ndkVersion \"6.0.0\"")
        #expect(AndroidSDKComponents.pins(policy: box.policy, hasFullDiskAccess: true).ndk == ["1.0.0", "5.0.0"])
        // Without Full Disk Access, Desktop and Documents are not read (macOS would ask).
        #expect(AndroidSDKComponents.pins(policy: box.policy, hasFullDiskAccess: false).ndk == ["1.0.0"])
    }

    /// An SDK set with `ANDROID_HOME` in the shell profile is scanned like the default one; its own newest is kept.
    @Test func scansTheSDKInTheProfile() async throws {
        let box = try Home()
        defer { box.remove() }
        let old = try box.component("ndk/25.2.9519653", revision: "25.2.9519653", sdk: "sdks/android")
        try box.component("ndk/26.1.10909125", revision: "26.1.10909125", sdk: "sdks/android")
        try box.file(".zprofile", "export ANDROID_HOME=$HOME/sdks/android\n")
        #expect(await listed(box, item()) == [old.path])
        // A folder outside a scanned SDK is never allowed.
        try box.component("other/ndk/1.0.0", revision: "1.0.0")
        try box.component("other/ndk/2.0.0", revision: "2.0.0")
        #expect(item().allowsEntry?(box.policy, box.home.appending(path: Home.sdk + "/other/ndk/1.0.0")) == false)
    }

    @MainActor @Test func lockedWhileAndroidStudioGradleOrTheEmulatorRuns() throws {
        let model = SmartScanModel(module: .smartScan) { [] }
        model.runningApps = []
        model.runningProcesses = []
        let item = try #require(CleanerGroup.developer.items.first { $0.id == AndroidSDKComponents.id })
        #expect(!model.isRunning(item))
        model.runningApps = ["com.google.android.studio"]
        #expect(model.isRunning(item))
        model.runningApps = []
        for name in ["studio", "gradle", "GradleDaemon", "emulator", "qemu-system-aarch64-headless"] {
            model.runningProcesses = [name]
            #expect(model.isRunning(item), "\(name)")
        }
        model.runningProcesses = ["adb", "java", "sdkmanager"]
        #expect(!model.isRunning(item))
    }
}

private extension ItemScan {
    func filtered(_ keep: (ScanEntry) -> Bool) -> ItemScan {
        var copy = self
        copy.entries = entries.filter(keep)
        return copy
    }
}
