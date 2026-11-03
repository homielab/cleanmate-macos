import Foundation

/// The Overview's last measure of the home folder, kept in `~/Library/Application Support/CleanMate/home-folders.json`
/// so the next launch shows it at once while the folders are measured again. Holds only names and sizes, never file
/// contents; a missing, unreadable or foreign file (another home, another format) reads as nil.
nonisolated struct HomeFolderSizes: Codable, Equatable, Sendable {
    nonisolated struct Folder: Codable, Equatable, Sendable {
        /// Name in the home folder.
        var name: String
        var size: Int64
    }

    /// Bumped when the format changes: an older file is then ignored.
    static let currentVersion = 1

    var version = HomeFolderSizes.currentVersion
    /// The home folder measured (standardized path).
    var home: String
    /// When the measure finished.
    var date: Date
    /// Largest first, as the Overview lists them.
    var folders: [Folder]
    /// The folders measured plus the files directly in the home folder.
    var homeSize: Int64
    /// Folders macOS protects were left out (no Full Disk Access).
    var skippedProtected: Bool

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "CleanMate/home-folders.json")
    }

    /// The sizes saved in `file` for `home`; nil when there are none, the file is damaged or it is about another home.
    static func read(from file: URL, home: URL) -> HomeFolderSizes? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let sizes = try? decoder.decode(HomeFolderSizes.self, from: data), sizes.version == currentVersion,
              sizes.home == home.standardizedFileURL.path else { return nil }
        return sizes
    }

    /// Saves atomically; a write error only means the next launch measures without numbers to show first.
    func write(to file: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
