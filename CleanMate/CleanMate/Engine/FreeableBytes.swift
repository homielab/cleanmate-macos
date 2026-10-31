import Foundation

/// Counts what removing one folder entry really frees (`CleanerItem.freeableSize`), for package installs that share
/// their files with a store elsewhere: pnpm hard-links or clones files from its store, Bun and uv clone them from their
/// caches. One counter per entry, shared by its parallel walks (`Scanner.tree`, `undatedTree`).
/// - A file with several hard links counts only when every link is inside the entry, and then once (`linkedBytes`):
///   a link into a store outside frees nothing.
/// - With `clones`, a file sharing blocks with APFS clones counts only its private bytes (`ATTR_CMNEXT_PRIVATESIZE`):
///   0 for an untouched clone. One `getattrlist` per file, so the first measure is slower; `FolderSizeCache` keeps it.
nonisolated final class FreeableBytes: Sendable {
    let clones: Bool
    /// (st_dev, st_ino) of each file with several links met so far → links met, its link count and bytes.
    private let linked = Locked([[UInt64]: (seen: Int, links: Int, bytes: Int64)]())

    init(clones: Bool) {
        self.clones = clones
    }

    /// Bytes to add now for the non-folder `info` at `path`; a hard-linked file adds 0 here and counts in `linkedBytes`.
    func count(_ info: stat, path: UnsafePointer<CChar>) -> Int64 {
        var bytes = Int64(info.st_blocks) * 512
        if clones, bytes > 0, info.st_mode & S_IFMT == S_IFREG, let own = DuplicateFinder.privateSize(path: path) {
            bytes = min(bytes, own)
        }
        guard info.st_nlink > 1 else { return bytes }
        linked.withLock { linked in
            let key = [UInt64(info.st_dev), info.st_ino]
            if var known = linked[key] {
                known.seen += 1
                linked[key] = known
            } else {
                linked[key] = (1, Int(info.st_nlink), bytes)
            }
        }
        return 0
    }

    /// Files with several hard links whose links were all met in the entry, once each.
    var linkedBytes: Int64 {
        linked.withLock { $0.values.reduce(0) { $1.seen >= $1.links ? $0 + $1.bytes : $0 } }
    }
}
