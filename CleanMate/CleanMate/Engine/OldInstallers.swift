import Foundation

/// Installers left in ~/Downloads after the app was installed: disk images, packages, ISO images, Xcode archives and
/// zip files holding an app. Only regular files at the top level of the folder; never a download still in progress.
nonisolated enum OldInstallers {
    static let folder = "~/Downloads"
    static let extensions = ["dmg", "pkg", "iso", "xip", "zip"]
    /// `CleanerItem.included` patterns (fnmatch is case-sensitive): `Setup.dmg` and `SETUP.DMG`.
    static let patterns = extensions.flatMap { ["*.\($0)", "*.\($0.uppercased())"] }
    /// Names browsers download to: Safari `<name>.download` (a folder), Chrome `<name>.crdownload`, Firefox
    /// `<name>.part` (Firefox also creates `<name>` itself, empty, until the download ends).
    static let partialSuffixes = ["download", "crdownload", "part"]
    /// A central directory larger than this (millions of entries) is not read: the zip is kept.
    static let centralDirectoryLimit: UInt64 = 64 << 20

    /// Whether `url` is kept: not an installer name, not a regular file (a symlink, a folder, a bundle-style package),
    /// a download in progress next to it, or a zip without an app at its top level.
    static func skips(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard extensions.contains(ext) else { return true }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return true }
        let folder = url.deletingLastPathComponent()
        for suffix in partialSuffixes {
            var other = stat()
            if lstat(folder.appending(path: url.lastPathComponent + "." + suffix).path, &other) == 0 { return true }
        }
        return ext == "zip" && !zipHoldsApp(url)
    }

    /// Whether the zip archive at `url` has an app at its top level (`Name.app/…`). Reads only the names in its
    /// central directory (zip64 included); an unreadable or malformed archive counts as no app.
    static func zipHoldsApp(_ url: URL) -> Bool {
        zipEntryNames(url)?.contains(where: isTopLevelApp) ?? false
    }

    /// `Name.app/` or `Name.app/Contents/…`; not a file named `Name.app`, not `Folder/Name.app/…`.
    static func isTopLevelApp(_ name: String) -> Bool {
        guard let slash = name.firstIndex(of: "/") else { return false }
        let first = name[..<slash]
        return first.count > 4 && first.lowercased().hasSuffix(".app")
    }

    /// Entry names from the central directory of the zip at `url`; nil when it is not a readable zip.
    static func zipEntryNames(_ url: URL) -> [String]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        func read(_ offset: UInt64, _ count: UInt64) -> [UInt8]? {
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let data = try? handle.read(upToCount: Int(count)), data.count == Int(count) else { return nil }
            return [UInt8](data)
        }
        // End of central directory record: 22 bytes plus a comment of up to 64 KB, preceded by a 20-byte zip64 locator.
        guard let size = try? handle.seekToEnd(), size >= 22 else { return nil }
        let tailLength = min(size, 20 + 22 + 0xFFFF)
        guard let tail = read(size - tailLength, tailLength),
              let end = stride(from: tail.count - 22, through: 0, by: -1).first(where: { le(tail, $0, 4) == 0x0605_4b50 })
        else { return nil }
        var count = le(tail, end + 10, 2), length = le(tail, end + 12, 4), start = le(tail, end + 16, 4)
        if count == 0xFFFF || length == 0xFFFF_FFFF || start == 0xFFFF_FFFF {
            guard end >= 20, le(tail, end - 20, 4) == 0x0706_4b50,
                  let record = read(le(tail, end - 20 + 8, 8), 56), le(record, 0, 4) == 0x0606_4b50 else { return nil }
            (count, length, start) = (le(record, 32, 8), le(record, 40, 8), le(record, 48, 8))
        }
        guard length <= centralDirectoryLimit, start <= size, length <= size - start else { return nil }
        if length == 0 { return [] }
        guard let directory = read(start, length) else { return nil }
        var names: [String] = []
        var i = 0
        while UInt64(names.count) < count, i + 46 <= directory.count, le(directory, i, 4) == 0x0201_4b50 {
            let nameLength = Int(le(directory, i + 28, 2))
            let next = i + 46 + nameLength + Int(le(directory, i + 30, 2)) + Int(le(directory, i + 32, 2))
            guard next <= directory.count else { return nil }
            names.append(String(decoding: directory[(i + 46)..<(i + 46 + nameLength)], as: UTF8.self))
            i = next
        }
        return names
    }

    /// Little-endian unsigned integer of `width` bytes at `offset`.
    private static func le(_ bytes: [UInt8], _ offset: Int, _ width: Int) -> UInt64 {
        (0..<width).reduce(0) { $0 | UInt64(bytes[offset + $1]) << (8 * $1) }
    }
}
