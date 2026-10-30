import Foundation

/// Screenshots and screen recordings left where macOS saves them (Desktop unless changed in the Screenshot app's
/// Options › Save to) that nothing touched for the downloads age: a Retina screenshot is 5–10 MB, a recording hundreds.
/// Top-level regular files only, each one an entry, moved to the Trash.
nonisolated enum OldScreenshots {
    static let id = "old-screenshots"
    static let defaultFolder = "~/Desktop"
    /// Set on every file the Screenshot app (and `screencapture`) saves; read straight from the file, no Spotlight.
    static let screenCaptureAttribute = "com.apple.metadata:kMDItemIsScreenCapture"
    /// Names of screenshots without that attribute (copied, synced, made by CleanShot), English and Vietnamese macOS,
    /// followed by a space.
    static let namePrefixes = ["Screenshot", "Screen Shot", "Screen Recording", "CleanShot",
                               "Ảnh chụp màn hình", "Ảnh màn hình", "Ghi màn hình", "Bản ghi màn hình"]
    static let extensions: Set<String> = ["png", "jpg", "jpeg", "heic", "mov", "mp4"]

    /// Where screenshots are saved, as `~/…`: the Screenshot app's `location` (`com.apple.screencapture`), Desktop when
    /// unset. nil when it is the home folder itself or outside it: nothing is listed then.
    static func folder(location: String? = systemLocation(), home: String = NSHomeDirectory()) -> String? {
        guard var path = location?.trimmingCharacters(in: .whitespaces), !path.isEmpty else { return defaultFolder }
        if path == "~" || path.hasPrefix("~/") { path = home + path.dropFirst() }
        let base = URL(fileURLWithPath: home).standardizedFileURL.path
        let standard = URL(fileURLWithPath: path).standardizedFileURL.path
        guard standard.hasPrefix(base + "/") else { return nil }
        return "~" + standard.dropFirst(base.count)
    }

    /// The Screenshot app's save folder setting, nil when unset.
    static func systemLocation() -> String? {
        CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String
    }

    /// A screenshot or screen recording: the Screenshot app's attribute, or a screenshot name with an image or movie
    /// extension.
    static func isScreenshot(_ url: URL) -> Bool {
        hasScreenCaptureAttribute(url) || hasScreenshotName(url.lastPathComponent)
    }

    static func hasScreenshotName(_ name: String) -> Bool {
        let name = name.precomposedStringWithCanonicalMapping.lowercased() // APFS may hand in decomposed Vietnamese
        guard extensions.contains((name as NSString).pathExtension) else { return false }
        return namePrefixes.contains { name.hasPrefix($0.precomposedStringWithCanonicalMapping.lowercased() + " ") }
    }

    /// The attribute holds a binary plist `true` (`xattr -p` shows `bplist00…`).
    static func hasScreenCaptureAttribute(_ url: URL) -> Bool {
        let size = getxattr(url.path, screenCaptureAttribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0, size <= 1024 else { return false }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, screenCaptureAttribute, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        guard read == size, let value = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return false }
        return (value as? Bool) == true || (value as? NSNumber)?.boolValue == true
    }

    /// A screenshot under `SafetyPolicy.allowsUserFile` (a regular file in the home folder, not a symlink, not excluded,
    /// not under Library or a hidden folder), not hidden. A save folder reached through a symlink is never scanned
    /// (`Scanner.roots`).
    static func allows(_ url: URL, policy: SafetyPolicy) -> Bool {
        !url.lastPathComponent.hasPrefix(".") && policy.allowsUserFile(url) && isScreenshot(url)
    }

    /// The per-entry check of one scan or one removal: true keeps a file touched (`OldDownloads.lastTouched`: modified,
    /// created, added, opened, read) within `days`, or of unknown age.
    static func skips(olderThan days: Int, now: Date = .now) -> @Sendable (URL) -> Bool {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return { url in OldDownloads.lastTouched(url).map { $0 >= cutoff } ?? true }
    }

    /// The Smart Scan item, or nil when screenshots are saved nowhere CleanMate may look.
    static func item(days: Int, folder: String?) -> CleanerItem? {
        guard let folder else { return nil }
        return CleanerItem(id: id, title: "Old screenshots",
                           note: "Screenshots and screen recordings not modified or opened for \(days) days. Moved to the Trash",
                           paths: [folder], minAge: Double(days) * 86_400, mode: .trash, selectedByDefault: false,
                           showsWhenEmpty: false, skipsOpenFiles: true, skipsEntry: { skips(olderThan: days) },
                           entryLabel: OldDownloads.label(of:), selectableEntries: true,
                           allowsEntry: { allows($1, policy: $0) })
    }
}
