import Foundation

/// Android emulator system images no virtual device (AVD) uses: 1–8 GB each, and they stay when their AVD is deleted.
/// An image is `<sdk>/system-images/<android-N>/<tag>/<abi>` holding `package.xml` or `source.properties`, in
/// `~/Library/Android/sdk` or the SDK named by `ANDROID_HOME` / `ANDROID_SDK_ROOT` in the shell profile (inside home,
/// no symlink). An AVD uses the images its `config.ini` names in `image.sysdir.N` (relative to the SDK, so an image used
/// in one SDK is kept in every SDK). AVDs are read from `~/.android/avd` and the folders the AVD variables name, both the
/// `<name>.avd` folders and those a `<name>.ini` points to elsewhere (`path=`, `path.rel=`).
/// Any AVD that can't be read (a broken or missing `config.ini`, a folder on a drive that isn't plugged in, a variable
/// the profile sets in a way CleanMate can't read) keeps every image: nothing is listed.
/// One entry per image, unticked, deleted whole (the SDK Manager downloads it again; removing the folder is also how
/// `sdkmanager --uninstall` does it). `platforms`, `build-tools`, `ndk`, `emulator` and the AVDs are never listed.
nonisolated enum AndroidSystemImages {
    static let id = "android-system-images"
    /// One level per API and tag; the entries are the ABI folders inside.
    static let paths = ["~/Library/Android/sdk/system-images/*/*"]
    static let shellFolders = ["ANDROID_HOME": ["system-images/*/*"], "ANDROID_SDK_ROOT": ["system-images/*/*"]]
    /// Files the SDK Manager writes in every installed package.
    static let markers = ["package.xml", "source.properties"]
    /// Android Studio, the emulator (`emulator` starts `qemu-system-<arch>[-headless]`), and the SDK tools that install
    /// or create images and AVDs (run as `java`, named by `RunningProcesses.argumentNames`).
    static let bundleIDs = ["com.google.android.studio*"]
    static let processNames = ["studio", "emulator", "qemu-system-*", "sdkmanager", "avdmanager"]
    /// Profile variables naming where AVDs are kept, with the folder below each value (as the emulator resolves them).
    static let avdVariables: [(name: String, subpath: String)] = [
        ("ANDROID_AVD_HOME", ""), ("ANDROID_EMULATOR_HOME", "avd"), ("ANDROID_USER_HOME", "avd"),
        ("ANDROID_SDK_HOME", ".android/avd"), ("ANDROID_PREFS_ROOT", ".android/avd"),
    ]
    /// Largest `config.ini`, `<name>.ini` or `source.properties` read: real ones are a few KB.
    static let fileLimit = 1 << 20

    /// The Smart Scan item. `volumesFolder` is where drives mount (tests use their own).
    static func item(volumesFolder: String = "/Volumes") -> CleanerItem {
        CleanerItem(id: id, title: "Android system images without a device",
                    note: "Emulator images no virtual device uses; downloaded again with Android Studio's SDK Manager",
                    paths: paths, selectedByDefault: false, shellFolders: shellFolders, showsWhenEmpty: false,
                    runningAppBundleIDs: bundleIDs, runningProcessNames: processNames, skipsOpenFiles: true,
                    entryLabel: label(of:), selectableEntries: true,
                    allowsEntry: { policy, url in allows(url, policy: policy, volumesFolder: volumesFolder) })
    }

    /// `url` is an image no AVD uses, allowed by `policy`. Asked at scan and again right before removal, so an AVD
    /// created since the scan keeps its image.
    static func allows(_ url: URL, policy: SafetyPolicy, volumesFolder: String = "/Volumes") -> Bool {
        guard policy.allows(url), isImage(url),
              let used = usedImages(home: policy.homeURL, volumesFolder: volumesFolder) else { return false }
        return !used.contains(key(of: url))
    }

    /// A real image folder: not hidden, not a symlink, holding one of `markers`.
    static func isImage(_ url: URL) -> Bool {
        var info = stat()
        guard !url.lastPathComponent.hasPrefix("."), lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR
        else { return false }
        return markers.contains { lstat(url.appending(path: $0).path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG }
    }

    /// `android-34/google_apis/arm64-v8a`: what an AVD's `image.sysdir.N` names after `system-images/`. Lowercased,
    /// like the case-insensitive disk.
    static func key(of image: URL) -> String {
        image.pathComponents.suffix(3).joined(separator: "/").lowercased()
    }

    /// Keys of the images every AVD uses; nil when one AVD (or where they are kept) can't be read.
    static func usedImages(home: URL, volumesFolder: String = "/Volumes") -> Set<String>? {
        let env = ShellEnvironment.cached(home: home)
        // Set in the profile in a way that can't be read (`$(…)`, inside an `if`): its AVDs are unknown.
        let names = avdVariables.map(\.name)
        guard ShellEnvironment.assigned(home: home).filter(names.contains).allSatisfy({ env[$0] != nil }) else { return nil }
        var folders = [home.appending(path: ".android/avd").path]
        for (name, subpath) in avdVariables {
            guard let value = env[name] else { continue }
            guard value.hasPrefix("/") else { return nil }
            folders.append(subpath.isEmpty ? value : value + "/" + subpath)
        }
        var used = Set<String>(), seen = Set<String>()
        for folder in folders.map({ URL(fileURLWithPath: $0).standardizedFileURL }) {
            guard exists(folder.path) else {
                if isGone(folder.path, volumesFolder: volumesFolder) { continue }
                return nil
            }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
            for name in names.sorted() where name.hasSuffix(".avd") {
                let avd = folder.appending(path: name).standardizedFileURL
                guard seen.insert(avd.path).inserted else { continue }
                guard let images = images(of: avd) else { return nil }
                used.formUnion(images)
            }
            for name in names.sorted() where name.hasSuffix(".ini") {
                guard let lines = lines(of: folder.appending(path: name)) else { return nil }
                var path: String?, relative: String?
                for line in lines {
                    if let value = value(of: "path", in: line) { path = value }
                    if let value = value(of: "path.rel", in: line) { relative = value }
                }
                // `path.rel` is relative to the folder above the AVD folder (`~/.android`).
                guard let target = path ?? relative.map({ folder.deletingLastPathComponent().path + "/" + $0 }),
                      !target.isEmpty else { continue }
                let avd = URL(fileURLWithPath: target).standardizedFileURL
                guard seen.insert(avd.path).inserted else { continue }
                if exists(avd.path) {
                    guard let images = images(of: avd) else { return nil }
                    used.formUnion(images)
                } else if !isGone(avd.path, volumesFolder: volumesFolder) {
                    return nil // on a drive that isn't plugged in, or can't be checked
                }
            }
        }
        return used
    }

    /// Keys of the images `avd`'s `config.ini` names; nil when it can't be read, names none, or names one somewhere
    /// else than a `system-images` folder.
    static func images(of avd: URL) -> Set<String>? {
        guard let lines = lines(of: avd.appending(path: "config.ini")) else { return nil }
        var found = Set<String>()
        for line in lines {
            guard let match = line.wholeMatch(of: /\s*image\.sysdir\.\d+\s*=\s*(.*?)\s*/) else { continue }
            var value = String(match.1).replacingOccurrences(of: "\\", with: "/").lowercased()
            while value.hasSuffix("/") { value.removeLast() }
            guard let range = value.range(of: "system-images/", options: .backwards) else { return nil }
            let key = value[range.upperBound...]
            let parts = key.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
            found.insert(String(key))
        }
        return found.isEmpty ? nil : found
    }

    /// `Android 34 · google_apis · arm64-v8a`: the API level from `source.properties` when it has one, else from the
    /// folder name. Dated when the image was installed (its folder last changed).
    static func label(of image: URL) -> (title: String, date: Date?)? {
        let parts = image.pathComponents.suffix(3)
        guard parts.count == 3 else { return nil }
        let folder = parts[parts.startIndex]
        let level = lines(of: image.appending(path: "source.properties"))?
            .compactMap { value(of: "AndroidVersion.ApiLevel", in: $0) }.last.flatMap { $0.isEmpty ? nil : $0 }
        let api = level ?? (folder.hasPrefix("android-") ? String(folder.dropFirst(8)) : folder)
        let date = (try? image.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return (["Android \(api)", parts[parts.startIndex + 1], parts[parts.startIndex + 2]].joined(separator: " · "), date)
    }

    /// The lines of a small regular file (followed through a symlink, as the emulator does); nil when it can't be read.
    static func lines(of file: URL) -> [String]? {
        var info = stat()
        guard stat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= fileLimit,
              let data = FileManager.default.contents(atPath: file.path) else { return nil }
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
    }

    /// The value of `key = value` in an ini line, trimmed; nil for another key.
    static func value(of key: String, in line: String) -> String? {
        let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == key else { return nil }
        return parts[1].trimmingCharacters(in: .whitespaces)
    }

    private static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    /// `path` is certainly missing: not on a drive that isn't plugged in, and its nearest existing folder can be searched.
    static func isGone(_ path: String, volumesFolder: String = "/Volumes") -> Bool {
        var info = stat()
        guard lstat(path, &info) != 0, errno == ENOENT else { return false }
        let volumes = volumesFolder.hasSuffix("/") ? volumesFolder : volumesFolder + "/"
        if path.hasPrefix(volumes) {
            guard let drive = path.dropFirst(volumes.count).split(separator: "/").first,
                  lstat(volumes + drive, &info) == 0 else { return false }
        }
        var parent = (path as NSString).deletingLastPathComponent
        while lstat(parent, &info) != 0 {
            guard errno == ENOENT, parent != "/" else { return false }
            parent = (parent as NSString).deletingLastPathComponent
        }
        return stat(parent, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && access(parent, X_OK) == 0
    }
}
