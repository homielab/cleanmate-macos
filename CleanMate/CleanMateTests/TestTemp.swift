import Foundation

/// Throwaway folders for tests: names start with `CleanMate` and a dash. The first use in a run
/// also removes such folders older than an hour that earlier (crashed or killed) runs left behind.
enum TestTemp {
    private static let swept: Void = {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-3600)
        let names = (try? fm.contentsOfDirectory(atPath: fm.temporaryDirectory.path)) ?? []
        for name in names where name.hasPrefix("CleanMate") && name.contains("-") {
            let url = fm.temporaryDirectory.appending(path: name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modified, modified < cutoff else { continue }
            // A test that locks something (UF_IMMUTABLE) and died leaves it undeletable until the flag is cleared.
            for case let item as URL in fm.enumerator(at: url, includingPropertiesForKeys: nil) ?? NSEnumerator() { lchflags(item.path, 0) }
            lchflags(url.path, 0)
            try? fm.removeItem(at: url)
        }
    }()

    /// A new unique path (not created) such as `$TMPDIR/CleanMateRules-<uuid>`.
    static func url(_ prefix: String) -> URL {
        _ = swept
        return FileManager.default.temporaryDirectory.appending(path: "\(prefix)-\(UUID().uuidString)")
    }
}
