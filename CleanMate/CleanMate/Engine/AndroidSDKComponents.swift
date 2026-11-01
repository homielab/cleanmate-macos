import Foundation

/// Old versions of Android SDK components. Each Android Studio update downloads a new NDK (1–4 GB), build-tools,
/// platform or CMake next to the old ones, which stay: often 5–15 GB in `~/Library/Android/sdk` (or the SDK named by
/// `ANDROID_HOME` / `ANDROID_SDK_ROOT` in the shell profile, inside home, no symlink).
/// Components: `ndk/<version>` and the old-style `ndk-bundle` (one kind), `build-tools/<version>`, `platforms/android-N`
/// and `cmake/<version>`, each a real folder holding `source.properties` (a platform: or `package.xml`). Its version is
/// `Pkg.Revision` (a platform: `AndroidVersion.ApiLevel`), else the folder name; one CleanMate can't read is kept.
/// Kept, never listed (asked at scan and again right before removal): the newest version of each kind in each SDK,
/// and every version a project pins in a `build.gradle(.kts)` (`ndkVersion`, `buildToolsVersion`, `compileSdk`,
/// `compileSdkVersion`) or `local.properties` (`ndk.dir`). Projects are looked for in `StaleProjects.folders`, up to
/// `StaleProjects.depth` levels down, without running Gradle; a project elsewhere may need a listed version, which
/// the SDK Manager downloads again. One entry per component, unticked, deleted whole. `platform-tools`, `emulator`,
/// `system-images`, `licenses`, `.knownPackages` and everything else in the SDK are never listed.
nonisolated enum AndroidSDKComponents {
    static let id = "android-sdk-old-components"
    static let paths = ["~/Library/Android/sdk"]
    static let shellFolders = ["ANDROID_HOME": [""], "ANDROID_SDK_ROOT": [""]]
    /// Android Studio, a Gradle build (the `gradle` client or its daemon) and the emulator (`emulator` starts
    /// `qemu-system-<arch>[-headless]`).
    static let bundleIDs = ["com.google.android.studio*"]
    static let processNames = ["studio", "gradle", "GradleDaemon", "emulator", "qemu-system-*"]
    /// Largest `source.properties`, `build.gradle(.kts)` or `local.properties` read: real ones are a few KB.
    static let fileLimit = 1 << 20
    /// Pins found by a walk are reused for this long: one walk for a scan's entries, a fresh one for a later clean.
    static let reuseTime = Duration.seconds(10)

    /// A kind of component: the SDK folder holding its versions.
    enum Kind: String, CaseIterable, Sendable {
        case ndk, buildTools = "build-tools", platforms, cmake

        var name: String {
            switch self {
            case .ndk: "NDK"
            case .buildTools: "Build-Tools"
            case .platforms: "Android SDK Platform"
            case .cmake: "CMake"
            }
        }
    }

    /// `26.1.10909125`, `35.0.0-rc3`: numbers, then anything after them (a preview sorts below its release).
    struct Version: Comparable, Sendable {
        let numbers: [Int]
        let suffix: String

        init?(_ text: String) {
            let text = text.trimmingCharacters(in: .whitespaces)
            guard let match = text.prefixMatch(of: /(\d{1,9}(?:\.\d{1,9})*)/) else { return nil }
            numbers = match.1.split(separator: ".").compactMap { Int($0) }
            suffix = String(text[match.range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " -_."))
        }

        /// Both number lists padded with zeros: `34` is `34.0.0`.
        private static func padded(_ a: Version, _ b: Version) -> ([Int], [Int]) {
            let count = max(a.numbers.count, b.numbers.count)
            return (a.numbers + Array(repeating: 0, count: count - a.numbers.count),
                    b.numbers + Array(repeating: 0, count: count - b.numbers.count))
        }

        static func == (a: Version, b: Version) -> Bool {
            let (x, y) = padded(a, b)
            return x == y && a.suffix.lowercased() == b.suffix.lowercased()
        }

        static func < (a: Version, b: Version) -> Bool {
            let (x, y) = padded(a, b)
            if x != y { return x.lexicographicallyPrecedes(y) }
            if a.suffix.isEmpty != b.suffix.isEmpty { return !a.suffix.isEmpty }
            return a.suffix.lowercased() < b.suffix.lowercased()
        }

        /// `pin` names this version: the same, or a release pin this version starts with (`26.1` pins `26.1.10909125`,
        /// `36` pins platform `36.1`).
        func isPinned(by pin: Version) -> Bool {
            self == pin || pin.suffix.isEmpty && numbers.count > pin.numbers.count
                && Array(numbers.prefix(pin.numbers.count)) == pin.numbers
        }
    }

    /// One installed component.
    struct Component: Sendable {
        let url: URL
        let kind: Kind
        /// What the label shows: `Pkg.Revision`, the API level or the folder name.
        let versionText: String
        /// nil when it can't be read: the component is kept.
        let version: Version?
    }

    /// What the projects pin.
    struct Pins: Equatable, Sendable {
        var ndk: Set<String> = []
        var buildTools: Set<String> = []
        var compileSdk: Set<String> = []
        /// `ndk.dir` paths, standardized with symlinks resolved.
        var ndkFolders: Set<String> = []

        func pins(_ component: Component) -> Bool {
            if component.kind == .ndk, ndkFolders.contains(Self.resolved(component.url.path)) { return true }
            let texts: Set<String> = switch component.kind {
            case .ndk: ndk
            case .buildTools: buildTools
            case .platforms: compileSdk
            case .cmake: []
            }
            guard let version = component.version else { return true }
            return texts.contains { text in
                text == component.url.lastPathComponent || Version(text).map { version.isPinned(by: $0) } == true
            }
        }

        static func resolved(_ path: String) -> String {
            URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        }
    }

    // MARK: - Components

    /// The component `url` is (its SDK, kind and version), or nil: not one of the kinds' version folders, hidden, a
    /// symlink, or missing its `source.properties` (a platform: or `package.xml`).
    static func component(_ url: URL) -> Component? {
        let url = url.standardizedFileURL
        let name = url.lastPathComponent
        let kind: Kind
        if name == "ndk-bundle" {
            kind = .ndk
        } else if let parent = Kind(rawValue: url.deletingLastPathComponent().lastPathComponent) {
            kind = parent
        } else { return nil }
        var info = stat()
        guard !name.hasPrefix("."), lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        let properties = lines(of: url.appending(path: "source.properties"))
        guard properties != nil || kind == .platforms && isFile(url.appending(path: "package.xml")) else { return nil }
        let values = properties ?? []
        func value(_ key: String) -> String? {
            values.compactMap { AndroidSystemImages.value(of: key, in: $0) }.last.flatMap { $0.isEmpty ? nil : $0 }
        }
        if kind == .platforms {
            // A preview (`android-Baklava`, `CodeName=Baklava`) has the API level of the release before it: kept.
            if value("AndroidVersion.CodeName") != nil { return Component(url: url, kind: kind, versionText: name, version: nil) }
            let level = value("AndroidVersion.ApiLevel") ?? (name.hasPrefix("android-") ? String(name.dropFirst(8)) : name)
            let version = level.allSatisfy({ $0.isNumber || $0 == "." }) ? Version(level) : nil
            return Component(url: url, kind: kind, versionText: level, version: version)
        }
        let text = value("Pkg.Revision") ?? name
        return Component(url: url, kind: kind, versionText: text, version: name == "ndk-bundle" && value("Pkg.Revision") == nil ? nil : Version(text))
    }

    /// The components of `kind` in `sdk`, by path (`ndk-bundle` with the NDKs).
    static func components(of kind: Kind, in sdk: URL) -> [Component] {
        let folder = sdk.appending(path: kind.rawValue)
        var urls = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
            .map { folder.appending(path: $0) }
        if kind == .ndk { urls.append(sdk.appending(path: "ndk-bundle")) }
        return urls.compactMap(component)
    }

    /// Components older than the newest readable version of their kind in `sdk`, before pins are checked.
    static func older(in sdk: URL) -> [Component] {
        Kind.allCases.flatMap { kind -> [Component] in
            let found = components(of: kind, in: sdk)
            guard let newest = found.compactMap(\.version).max() else { return [] }
            return found.filter { $0.version.map { $0 < newest } == true }
        }
    }

    /// The SDK folder holding `component`.
    static func sdk(of component: Component) -> URL {
        component.url.lastPathComponent == "ndk-bundle" ? component.url.deletingLastPathComponent()
            : component.url.deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The SDK folders CleanMate scans: `~/Library/Android/sdk` and the checked `ANDROID_HOME` / `ANDROID_SDK_ROOT`.
    static func sdks(policy: SafetyPolicy) -> Set<String> {
        var found: Set = [policy.expand(paths[0]).standardizedFileURL.path]
        for name in shellFolders.keys {
            if let folder = ShellEnvironment.folder(name, policy: policy) { found.insert(folder.standardizedFileURL.path) }
        }
        return found
    }

    // MARK: - Pins

    /// What the build files and `local.properties` in the project folders pin (`StaleProjects.folders` below
    /// `policy`'s home, without what macOS guards when there is no Full Disk Access).
    static func pins(policy: SafetyPolicy, hasFullDiskAccess: Bool) -> Pins {
        let skipped = ProtectedFolders.skipped(home: policy.homeURL, hasFullDiskAccess: hasFullDiskAccess)
        let roots = StaleProjects.folders.map(policy.expand).filter { !ProtectedFolders.contains(skipped, $0) }
        return pins(in: roots, skipping: skipped)
    }

    /// `pins(policy:hasFullDiskAccess:)` from `roots`, walked like `StaleProjects.find`: up to `depth` levels, never
    /// a symlink, a hidden folder, one of `StaleProjects.unwalked`, a bundle, a folder of `skipping` or another
    /// volume, at most `folderLimit` folders in all.
    static func pins(in roots: [URL], skipping: Set<String> = [], depth: Int = StaleProjects.depth,
                     folderLimit: Int = StaleProjects.folderLimit) -> Pins {
        var pins = Pins(), budget = folderLimit
        for root in roots {
            let rootPath = root.standardizedFileURL.path
            var info = stat()
            guard lstat(rootPath, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
            let device = info.st_dev
            var level = [rootPath]
            for current in 0...depth where !level.isEmpty {
                var next: [String] = []
                for folder in level {
                    guard budget > 0 else { return pins }
                    budget -= 1
                    let children = StaleProjects.entries(of: folder)
                    read(folder, children: children, into: &pins)
                    guard current < depth else { continue }
                    for (name, type) in children where type == UInt8(DT_DIR) && !name.hasPrefix(".")
                        && !StaleProjects.unwalked.contains(name)
                        && !StaleProjects.bundleExtensions.contains((name as NSString).pathExtension.lowercased()) {
                        let path = folder + "/" + name
                        guard !skipping.contains(path), lstat(path, &info) == 0, info.st_dev == device else { continue }
                        next.append(path)
                    }
                }
                level = next.sorted()
            }
        }
        return pins
    }

    static let buildFiles = ["build.gradle", "build.gradle.kts"]
    static let settingsFiles = ["settings.gradle", "settings.gradle.kts"]

    /// Adds what `folder`'s build files and `local.properties` pin (from its `readdir` names and types).
    static func read(_ folder: String, children: [String: UInt8], into pins: inout Pins) {
        let file = UInt8(DT_REG)
        let builds = buildFiles.filter { children[$0] == file }
        for name in builds {
            guard let text = lines(of: URL(fileURLWithPath: folder + "/" + name))?.joined(separator: "\n") else { continue }
            let found = gradlePins(in: text)
            pins.ndk.formUnion(found.ndk)
            pins.buildTools.formUnion(found.buildTools)
            pins.compileSdk.formUnion(found.compileSdk)
        }
        guard !builds.isEmpty || settingsFiles.contains(where: { children[$0] == file }), children["local.properties"] == file,
              let lines = lines(of: URL(fileURLWithPath: folder + "/local.properties")) else { return }
        for line in lines {
            guard var value = AndroidSystemImages.value(of: "ndk.dir", in: line) else { continue }
            // Properties escaping: `\:` is `:`, `\\` is `\`.
            value = value.replacingOccurrences(of: "\\:", with: ":").replacingOccurrences(of: "\\\\", with: "\\")
            if value.hasPrefix("/") { pins.ndkFolders.insert(Pins.resolved(value)) }
        }
    }

    /// `ndkVersion`, `buildToolsVersion` and `compileSdk` / `compileSdkVersion` set to a literal in a Groovy or Kotlin
    /// build file (`ndkVersion "26.1.10909125"`, `ndkVersion = "…"`, `ext.ndkVersion = '…'`, `compileSdk 34`,
    /// `compileSdkVersion "android-34"`, `compileSdk { version = release(36) }`). A value CleanMate can't read
    /// (`flutter.ndkVersion`, a version catalog) pins nothing.
    static func gradlePins(in text: String) -> Pins {
        var pins = Pins()
        for match in text.matches(of: /\b(ndkVersion|buildToolsVersion)\b[ \t]*[=:(]?[ \t]*["']([0-9][^"'\s]*)["']/) {
            if match.1 == "ndkVersion" { pins.ndk.insert(String(match.2)) } else { pins.buildTools.insert(String(match.2)) }
        }
        let sdk = /\bcompileSdk(?:Version)?\b[ \t]*[=:(]?[ \t]*(?:\{[^}]*?release\([ \t]*)?["']?(?:android-)?(\d+(?:\.\d+)?)/
        for match in text.matches(of: sdk) { pins.compileSdk.insert(String(match.1)) }
        return pins
    }

    // MARK: - Item

    /// The components in `roots` (the SDK folders) that are neither the newest of their kind nor pinned; `pins` is
    /// only read when there is an older one.
    static func find(in roots: [URL], policy: SafetyPolicy, pins: () -> Pins) -> [URL] {
        let sdks = sdks(policy: policy)
        var seen = Set<String>()
        let older = roots.map(\.standardizedFileURL).filter { sdks.contains($0.path) && seen.insert($0.path).inserted }
            .flatMap(older(in:))
        guard !older.isEmpty else { return [] }
        let pins = pins()
        return older.filter { !pins.pins($0) && policy.allows($0.url) }.map(\.url).sorted { $0.path < $1.path }
    }

    /// `url` is a component of a scanned SDK, older than the newest of its kind there and pinned by no project.
    static func allows(_ url: URL, policy: SafetyPolicy, pins: () -> Pins) -> Bool {
        guard policy.allows(url), let component = component(url), let version = component.version,
              sdks(policy: policy).contains(sdk(of: component).path),
              let newest = components(of: component.kind, in: sdk(of: component)).compactMap(\.version).max(),
              version < newest else { return false }
        return !pins().pins(component)
    }

    /// `NDK 26.1.10909125`, `Build-Tools 34.0.0`, `Android SDK Platform 33`, `CMake 3.22.1`; dated when it was
    /// installed (its folder last changed).
    static func label(of url: URL) -> (title: String, date: Date?)? {
        guard let component = component(url) else { return nil }
        var title = component.kind.name + " " + component.versionText
        if url.lastPathComponent == "ndk-bundle" { title += " (ndk-bundle)" }
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return (title, date)
    }

    /// The Smart Scan item. `hasFullDiskAccess` and `sizes` are injected by tests.
    static func item(hasFullDiskAccess: @escaping @Sendable () -> Bool = { FullDiskAccess.isGranted },
                     sizes: FolderSizeCache = .shared) -> CleanerItem {
        let cache = Locked<(key: String, started: ContinuousClock.Instant, pins: Pins)?>(nil)
        @Sendable func cachedPins(_ policy: SafetyPolicy) -> Pins {
            let key = policy.homeURL.standardizedFileURL.path + "\n\(hasFullDiskAccess())"
            if let hit = cache.withLock({ $0 }), hit.key == key, hit.started.duration(to: .now) < reuseTime { return hit.pins }
            let started = ContinuousClock.now
            let pins = pins(policy: policy, hasFullDiskAccess: hasFullDiskAccess())
            cache.withLock { $0 = (key, started, pins) }
            return pins
        }
        return CleanerItem(id: id, title: "Old Android SDK components",
                    note: "Old NDK, build-tools, platform and CMake versions no project in your project folders pins. A project elsewhere may need one; Android Studio's SDK Manager downloads it again",
                    paths: paths, selectedByDefault: false, shellFolders: shellFolders, showsWhenEmpty: false,
                    runningAppBundleIDs: bundleIDs, runningProcessNames: processNames, skipsOpenFiles: true,
                    entryLabel: label(of:), selectableEntries: true,
                    findEntries: { roots, policy in find(in: roots, policy: policy) { cachedPins(policy) } },
                    allowsEntry: { policy, url in allows(url, policy: policy) { cachedPins(policy) } },
                    entrySizes: sizes)
    }

    // MARK: - Files

    private static func isFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }

    /// The lines of a regular file of at most `fileLimit` (not through a symlink); nil when it can't be read.
    static func lines(of file: URL) -> [String]? {
        var info = stat()
        guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= fileLimit,
              let data = FileManager.default.contents(atPath: file.path) else { return nil }
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
    }
}
