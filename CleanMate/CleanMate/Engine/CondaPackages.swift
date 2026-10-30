import Foundation

/// conda / mamba package caches: the downloaded archives (`*.tar.bz2`, `*.conda`) and the index cache (`cache/`) in a
/// `pkgs` folder. The unpacked package folders next to them are never listed: environments hard-link into them.
/// `envs/` is not scanned. Besides the usual install folders, `pkgs_dirs` of `~/.condarc` names more `pkgs` folders.
nonisolated enum CondaPackages {
    static let paths = [
        "~/miniconda3/pkgs", "~/anaconda3/pkgs", "~/miniforge3/pkgs", "~/mambaforge/pkgs", "~/micromamba/pkgs", "~/.conda/pkgs",
    ]
    static let included = ["*.tar.bz2", "*.conda", "cache"]
    static let processNames = ["conda", "mamba", "micromamba"]
    /// Largest `.condarc` read: real ones are a few lines.
    static let settingsLimit = 1 << 20

    /// The `pkgs_dirs` entries of `~/.condarc`, as written apart from a leading `~/` (checked by the scan like a
    /// `shellFolders` folder). Only the plain forms are read (a block list, or `[a, b]`); conda is never run.
    @Sendable static func configuredFolders(home: URL) -> [String] {
        let path = home.appending(path: ".condarc").path
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= settingsLimit,
              let data = FileManager.default.contents(atPath: path) else { return [] }
        return pkgsDirs(in: String(decoding: data, as: UTF8.self), home: home)
    }

    static func pkgsDirs(in text: String, home: URL) -> [String] {
        var values: [String] = []
        var inList = false
        for line in text.split(whereSeparator: \.isNewline) {
            let raw = line
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if raw.first?.isWhitespace == false {
                inList = false
                guard trimmed.hasPrefix("pkgs_dirs:") else { continue }
                let rest = trimmed.dropFirst("pkgs_dirs:".count).trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix("["), let end = rest.firstIndex(of: "]") {
                    values += rest[rest.index(after: rest.startIndex)..<end].split(separator: ",").map(String.init)
                } else if rest.isEmpty || rest.hasPrefix("#") {
                    inList = true
                }
            } else if inList, trimmed.hasPrefix("-") {
                values.append(String(trimmed.dropFirst()))
            }
        }
        return values.compactMap { value in
            var text = value.trimmingCharacters(in: .whitespaces)
            if let hash = text.range(of: " #") { text = String(text[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces) }
            if text.count >= 2, let quote = text.first, quote == "\"" || quote == "'", text.last == quote { text = String(text.dropFirst().dropLast()) }
            if text == "~" || text.hasPrefix("~/") { text = home.path + text.dropFirst() }
            return text.isEmpty ? nil : text
        }
    }
}
