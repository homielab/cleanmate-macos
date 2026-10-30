import Foundation
import Testing
@testable import CleanMate

/// Android system images in Smart Scan: each image no AVD uses is listed on its own, unticked, and deleted whole; an
/// image an AVD uses, the rest of the SDK and the AVDs are never touched, and an AVD that can't be read keeps them all.
/// Everything happens in a throwaway fake home.
struct AndroidSystemImagesTests {
    private struct Home {
        let root = TestTemp.url("CleanMateAndroidImages")
        var home: URL { root.appending(path: "home") }
        var policy: SafetyPolicy { SafetyPolicy(home: home, temp: root.appending(path: "tmp")) }
        static let sdk = "Library/Android/sdk"

        init() throws {
            for dir in ["home", "tmp"] {
                try FileManager.default.createDirectory(at: root.appending(path: dir), withIntermediateDirectories: true)
            }
        }

        @discardableResult
        func file(_ path: String, _ data: Data = Data(repeating: 1, count: 40_000)) throws -> URL {
            let url = home.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            return url
        }

        /// An installed image `<sdk>/system-images/<key>` with its disk image and the SDK Manager's metadata.
        @discardableResult
        func image(_ key: String, sdk: String = Home.sdk, api: String? = nil) throws -> URL {
            let folder = sdk + "/system-images/" + key
            try file(folder + "/system.img")
            try file(folder + "/package.xml", Data("<package/>".utf8))
            if let api { try file(folder + "/source.properties", Data("Pkg.Revision=5\nAndroidVersion.ApiLevel=\(api)\n".utf8)) }
            return home.appending(path: folder)
        }

        /// An AVD folder whose config.ini names `images` (or holds `config` as written), with its disks next to it.
        @discardableResult
        func avd(_ folder: String, images: [String] = [], config: String? = nil) throws -> URL {
            let text = config ?? images.enumerated().map { "image.sysdir.\($0.offset + 1)=system-images/\($0.element)/" }
                .joined(separator: "\n")
            try file(folder + "/config.ini", Data(("AvdId=Pixel\r\nhw.ramSize=2048\r\n" + text + "\r\n").utf8))
            try file(folder + "/userdata-qemu.img")
            return home.appending(path: folder)
        }

        func profile(_ text: String) throws { try file(".zprofile", Data(text.utf8)) }
        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private var item: CleanerItem {
        get throws { try #require(CleanerGroup.developer.items.first { $0.id == AndroidSystemImages.id }) }
    }

    private func listed(_ box: Home) async throws -> [String] {
        await Scanner.scan(try item, policy: box.policy).entries.map(\.url.standardizedFileURL.path).sorted()
    }

    @Test func catalogItem() throws {
        let item = try item
        #expect(!item.selectedByDefault && item.selectableEntries && item.mode == .delete && !item.showsWhenEmpty)
        #expect(item.command == nil && item.probe == nil && item.included == nil && item.minAge == nil)
        #expect(item.skipsOpenFiles && item.allowsEntry != nil && item.entryLabel != nil)
        #expect(item.paths == ["~/Library/Android/sdk/system-images/*/*"])
        #expect(item.shellFolders == ["ANDROID_HOME": ["system-images/*/*"], "ANDROID_SDK_ROOT": ["system-images/*/*"]])
        #expect(Set(item.shellFolders.keys).isSubset(of: ShellEnvironment.variables))
        #expect(AndroidSystemImages.avdVariables.allSatisfy { ShellEnvironment.variables.contains($0.name) })
        // Next to the emulator snapshots.
        let ids = CleanerGroup.developer.items.map(\.id)
        #expect(ids.firstIndex(of: AndroidSystemImages.id) == ids.firstIndex(of: "android-avd-snapshots").map { $0 + 1 })
    }

    /// Three images, one AVD using one of them: the two others are listed with `Android N · tag · abi`; cleaning one
    /// deletes only its folder. The used image, platforms, build-tools, ndk, emulator and the AVD stay.
    @Test func listsImagesNoAVDUsesAndDeletesOnlyThem() async throws {
        let box = try Home()
        defer { box.remove() }
        let used = try box.image("android-35/google_apis_playstore/arm64-v8a")
        let tablet = try box.image("android-34/google_apis/arm64-v8a", api: "34")
        let preview = try box.image("android-Baklava/google_apis/arm64-v8a")
        let avd = try box.avd(".android/avd/Pixel_9.avd", images: ["android-35/google_apis_playstore/arm64-v8a"])
        try box.file(".android/avd/Pixel_9.ini", Data("avd.ini.encoding=UTF-8\npath=\(avd.path)\npath.rel=avd/Pixel_9.avd\n".utf8))
        let kept = try ["platforms/android-35/android.jar", "build-tools/35.0.0/aapt2", "ndk/27.1.12297006/source.properties",
                        "emulator/emulator", "platform-tools/adb", "system-images/android-35/notes.txt"]
            .map { try box.file(Home.sdk + "/" + $0) }

        let item = try item
        let scan = await Scanner.scan(item, policy: box.policy)
        #expect(scan.entries.map(\.url.standardizedFileURL.path).sorted() == [tablet, preview].map(\.path).sorted())
        #expect(Set(scan.entries.compactMap { item.entryLabel?($0.url)?.title })
                == ["Android 34 · google_apis · arm64-v8a", "Android Baklava · google_apis · arm64-v8a"])
        #expect(scan.entries.allSatisfy { $0.size >= 40_000 && item.entryLabel?($0.url)?.date != nil })

        var onlyTablet = scan
        onlyTablet.entries = scan.entries.filter { $0.url.standardizedFileURL.path == tablet.path }
        let size = try #require(onlyTablet.entries.first?.size)
        let report = await Cleaner.clean(item, scan: onlyTablet, policy: box.policy)
        #expect(report.skipped == 0 && report.freed == size)
        #expect(!box.exists(tablet) && box.exists(tablet.deletingLastPathComponent()))
        #expect(([used, preview, avd, avd.appending(path: "config.ini")] + kept).allSatisfy(box.exists))
    }

    /// An AVD that can't be read keeps every image: a broken, missing or empty config.ini, an image named outside a
    /// system-images folder, or an AVD folder on a drive that isn't plugged in.
    @Test(arguments: ["broken", "missing", "no sysdir", "elsewhere", "unplugged", "unreadable variable"])
    func anUnreadableAVDListsNothing(_ kind: String) async throws {
        let box = try Home()
        defer { box.remove() }
        try box.image("android-34/google_apis/arm64-v8a")
        try box.image("android-33/default/x86_64")
        try box.avd(".android/avd/Fine.avd", images: ["android-35/default/arm64-v8a"])
        #expect(try await listed(box).count == 2)
        switch kind {
        case "broken": try box.file(".android/avd/Pixel.avd/config.ini", Data(repeating: 0, count: AndroidSystemImages.fileLimit + 1))
        case "missing": try box.file(".android/avd/Pixel.avd/userdata-qemu.img")
        case "no sysdir": try box.avd(".android/avd/Pixel.avd", config: "hw.lcd.density=420")
        case "elsewhere": try box.avd(".android/avd/Pixel.avd", config: "image.sysdir.1=/opt/images/arm64/")
        case "unplugged":
            try box.file(".android/avd/Pixel.ini", Data("path=/Volumes/CleanMateNoDrive-\(UUID().uuidString)/avd/Pixel.avd\n".utf8))
        default: try box.profile("export ANDROID_AVD_HOME=$(brew --prefix)/avd\n")
        }
        #expect(try await listed(box).isEmpty, "\(kind)")
    }

    /// A `<name>.ini` pointing to a folder deleted from a disk that is there is just a leftover: images stay listed.
    /// One pointing to an AVD elsewhere (`path=`, or `path.rel=` from ~/.android) keeps that AVD's images.
    @Test func followsAVDsKeptElsewhere() async throws {
        let box = try Home()
        defer { box.remove() }
        let a = try box.image("android-34/google_apis/arm64-v8a")
        let b = try box.image("android-33/default/x86_64")
        let c = try box.image("android-32/default/x86_64")
        try box.file(".android/avd/Gone.ini", Data("path=\(box.home.path)/old/avd/Gone.avd\n".utf8))
        #expect(try await listed(box) == [a, b, c].map(\.path).sorted())
        let moved = try box.avd("AVDs/Moved.avd", images: ["android-34/google_apis/arm64-v8a"])
        try box.file(".android/avd/Moved.ini", Data("path=\(moved.path)\n".utf8))
        try box.avd(".android/Relative.avd", images: ["android-33/default/x86_64"])
        try box.file(".android/avd/Relative.ini", Data("path.rel=Relative.avd\n".utf8))
        #expect(try await listed(box) == [c.path])
    }

    /// An SDK and an AVD folder set in the shell profile count too; an image an AVD uses is kept in every SDK.
    @Test func readsSDKAndAVDFoldersFromTheProfile() async throws {
        let box = try Home()
        defer { box.remove() }
        let mine = try box.image("android-34/google_apis/arm64-v8a", sdk: "Developer/android-sdk")
        let shared = try box.image("android-33/default/x86_64", sdk: "Developer/android-sdk")
        let sharedDefault = try box.image("android-33/default/x86_64")
        try box.avd("Developer/avds/Pixel.avd", images: ["android-33/default/x86_64"])
        try box.profile("export ANDROID_HOME=$HOME/Developer/android-sdk\nexport ANDROID_AVD_HOME=~/Developer/avds\n")
        #expect(try await listed(box) == [mine.path])
        #expect(box.exists(shared) && box.exists(sharedDefault))
    }

    /// An AVD made for an image after the scan keeps it at clean.
    @Test func anAVDCreatedSinceTheScanKeepsItsImage() async throws {
        let box = try Home()
        defer { box.remove() }
        let image = try box.image("android-34/google_apis/arm64-v8a")
        let item = try item
        let scan = await Scanner.scan(item, policy: box.policy)
        #expect(scan.entries.count == 1)
        try box.avd(".android/avd/New.avd", images: ["android-34/google_apis/arm64-v8a"])
        let report = await Cleaner.clean(item, scan: scan, policy: box.policy)
        #expect(report.skipped == 1 && report.freed == 0 && box.exists(image))
    }

    /// Symlinked SDK folders, a folder without the SDK Manager's metadata and hidden names are never listed.
    @Test func onlyRealImageFolders() async throws {
        let box = try Home()
        defer { box.remove() }
        let real = try box.image("android-34/google_apis/arm64-v8a")
        try box.file(Home.sdk + "/system-images/android-34/google_apis/x86_64/system.img")
        try box.file(Home.sdk + "/system-images/android-34/google_apis/.hidden/package.xml")
        try box.file(Home.sdk + "/system-images/android-34/google_apis/loose.zip")
        let target = try box.image("android-30/default/x86", sdk: "Documents/sdk")
        let link = box.home.appending(path: Home.sdk + "/system-images/android-30")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target.deletingLastPathComponent().deletingLastPathComponent())
        #expect(try await listed(box) == [real.path])
    }

    /// Locked while Android Studio, the emulator, sdkmanager or avdmanager (run as java) runs; other JVMs don't lock it.
    @MainActor @Test func lockedWhileStudioOrTheEmulatorRuns() throws {
        let item = try item
        func names(_ strings: [String]) -> Set<String> {
            let argc = Int32(strings.count - 1)
            return RunningProcesses.argumentNames(withUnsafeBytes(of: argc) { Array($0) } + strings.flatMap { Array($0.utf8) + [0] })
        }
        let model = SmartScanModel(module: .smartScan) { [] }
        model.runningApps = []
        model.runningProcesses = names(["/usr/bin/java", "java", "-cp", "/g/launcher.jar", "org.gradle.launcher.daemon.bootstrap.GradleDaemon"])
        #expect(!model.isLocked(item))
        for running in [["emulator"], ["qemu-system-aarch64"], ["qemu-system-x86_64-headless"],
                        names(["/jdk/bin/java", "java", "-cp", "/sdk/cmdline-tools/latest/lib/sdkmanager-classpath.jar",
                               "com.android.sdklib.tool.sdkmanager.SdkManagerCli", "--install", "emulator"]),
                        names(["/jdk/bin/java", "java", "-cp", "/sdk/lib/avdmanager-classpath.jar",
                               "com.android.sdklib.tool.AvdManagerCli", "create", "avd"])] {
            model.runningProcesses = Set(running)
            #expect(model.isLocked(item), "\(running)")
        }
        model.runningProcesses = []
        model.runningApps = ["com.google.android.studio"]
        #expect(model.isLocked(item))
    }

    @Test func readsImageSysdirsAndProfileAssignments() throws {
        let box = try Home()
        defer { box.remove() }
        let avd = try box.avd("x.avd", config: "image.sysdir.1 = system-images\\android-34\\google_apis\\arm64-v8a\\\nimage.sysdir.2=/Users/me/sdk/system-images/android-33/default/x86_64")
        #expect(AndroidSystemImages.images(of: avd) == ["android-34/google_apis/arm64-v8a", "android-33/default/x86_64"])
        let bad = try box.avd("y.avd", config: "image.sysdir.1=system-images/android-34/../x")
        #expect(AndroidSystemImages.images(of: bad) == nil)
        try box.profile("if true; then\n  export ANDROID_USER_HOME=/x\nfi\nexport ANDROID_HOME=~/sdk\n  # export ANDROID_AVD_HOME=$(x)\n")
        let assigned = ShellEnvironment.assigned(home: box.home)
        #expect(assigned.isSuperset(of: ["ANDROID_USER_HOME", "ANDROID_HOME"]) && !assigned.contains("ANDROID_AVD_HOME"))
        #expect(ShellEnvironment.read(home: box.home)["ANDROID_USER_HOME"] == nil)
    }
}
