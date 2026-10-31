import Foundation

/// Counts what removing one folder entry really frees (`CleanerItem.freeableSize`), for package installs that share
/// their files with a store elsewhere: pnpm hard-links or clones files from its store, Bun and uv clone them from their
/// caches. One counter per entry, shared by its parallel walks (`Scanner.tree`, `undatedTree`).
/// - A file with several hard links counts only when every link is inside the entry, and then once (`linkedBytes`):
///   a link into a store outside frees nothing.
/// - With `clones`, a file sharing blocks with APFS clones counts only its private bytes (`ATTR_CMNEXT_PRIVATESIZE`):
///   0 for an untouched clone. `walk` reads the clone flags with each folder listing, so only a file sharing some but
///   not all of its blocks costs a `getattrlist` of its own; `FolderSizeCache` keeps the result.
nonisolated final class FreeableBytes: Sendable {
    let clones: Bool
    /// (st_dev, st_ino) of each file with several links met so far → links met, its link count and bytes.
    private let linked = Locked([[UInt64]: (seen: Int, links: Int, bytes: Int64)]())

    init(clones: Bool) {
        self.clones = clones
    }

    /// Bytes to add now for the non-folder `info` at `path`; a hard-linked file adds 0 here and counts in `linkedBytes`.
    func count(_ info: stat, path: UnsafePointer<CChar>) -> Int64 {
        count(bytes: Int64(info.st_blocks) * 512, regular: info.st_mode & S_IFMT == S_IFREG, links: Int(info.st_nlink),
              device: UInt64(info.st_dev), inode: info.st_ino) { DuplicateFinder.privateSize(path: path) }
    }

    /// `count` from values read another way (`walk`); `privateSize` is `DuplicateFinder.privateSize` of the file.
    func count(bytes: Int64, regular: Bool, links: Int, device: UInt64, inode: UInt64,
               privateSize: () -> Int64?) -> Int64 {
        var bytes = bytes
        if clones, bytes > 0, regular, let own = privateSize() {
            bytes = min(bytes, own)
        }
        guard links > 1 else { return bytes }
        linked.withLock { linked in
            let key = [device, inode]
            if var known = linked[key] {
                known.seen += 1
                linked[key] = known
            } else {
                linked[key] = (1, links, bytes)
            }
        }
        return 0
    }

    /// Files with several hard links whose links were all met in the entry, once each.
    var linkedBytes: Int64 {
        linked.withLock { $0.values.reduce(0) { $1.seen >= $1.links ? $0 + $1.bytes : $0 } }
    }

    /// `Scanner.tree(dates: false)` of the folder `path` with this counter: the same bytes (and unreadable flag, but for a
    /// folder that can be listed and not entered, flagged here and not by fts), read with one `getattrlistbulk` per
    /// folder (`list`) instead of an `lstat` and a `getattrlist` per file. nil when cancelled.
    func walk(_ path: String, device: dev_t) -> (Int64, Date, Bool)? {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize, alignment: 8)
        defer { buffer.deallocate() }
        var size: Int64 = 0
        var unreadable = false
        var folders = [path]
        while let folder = folders.popLast() {
            guard let listed = list(folder, device: device, buffer: buffer) else { return nil }
            size += listed.bytes
            unreadable = unreadable || listed.unreadable
            folders += listed.folders
        }
        return (size, .distantPast, unreadable)
    }

    /// `walk`, with the folders `depth` levels down walked in parallel (`Scanner.undatedTree`'s split: pnpm keeps
    /// every package under one `.pnpm` folder).
    func walk(_ path: String, device: dev_t, depth: Int) async -> (Int64, Date, Bool)? {
        guard depth > 0 else { return walk(path, device: device) }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize, alignment: 8)
        let listed = list(path, device: device, buffer: buffer)
        buffer.deallocate()
        guard let listed else { return nil }
        return await withTaskGroup(of: (Int64, Date, Bool)?.self) { group in
            for folder in listed.folders { group.addTask { await self.walk(folder, device: device, depth: depth - 1) } }
            var size = listed.bytes, unreadable = listed.unreadable
            for await sub in group {
                guard let sub else { group.cancelAll(); return nil }
                size += sub.0
                unreadable = unreadable || sub.2
            }
            return (size, .distantPast, unreadable)
        }
    }

    private static let bufferSize = 64 * 1024

    /// One folder read with `getattrlistbulk` (name, device, type, inode, link count, allocated size, clone flags): the
    /// bytes its files add through `count`, its subfolders on `device`, and whether it could not be read (`FTS_DNR`).
    /// `ATTR_FILE_ALLOCSIZE` is `st_blocks` × 512 (checked on 2 M files, compressed app bundles included). A file
    /// sharing all of its blocks (`EF_SHARES_ALL_BLOCKS`) has a private size of 0 without asking; one that may share
    /// some is asked (`getattrlistat` in the folder). A folder on another volume is neither counted nor entered, like
    /// `FTS_XDEV`. ~3× faster than fts on 1.2 M node_modules files, most of them clones. nil when cancelled.
    private func list(_ folder: String, device: dev_t, buffer: UnsafeMutableRawPointer)
        -> (bytes: Int64, folders: [String], unreadable: Bool)? {
        var attributes = attrlist()
        attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        let common = attrgroup_t(ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_FILEID)
        attributes.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | common
        attributes.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE)
        let cloneAttributes = attrgroup_t(ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_EXT_FLAGS)
        attributes.forkattr = cloneAttributes
        var size: Int64 = 0
        var folders: [String] = []
        let fd = open(folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        // Gone since it was listed: skipped.
        guard fd >= 0 else { return (0, [], errno == EACCES || errno == EPERM) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_dev == device else { return (0, [], false) } // a volume mounted here
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        while true {
            let count = getattrlistbulk(fd, &attributes, buffer, Self.bufferSize, UInt64(FSOPT_ATTR_CMN_EXTENDED))
            if count < 0 { return (size, folders, true) }
            guard count > 0 else { break }
            if Task.isCancelled { return nil }
            var entry = buffer
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                defer { entry += length }
                let returned = entry.loadUnaligned(fromByteOffset: 4, as: attribute_set_t.self)
                var field = entry + 4 + MemoryLayout<attribute_set_t>.size
                guard returned.commonattr & common == common else { continue } // like FTS_NS: skipped
                let nameField = field
                let name = field.loadUnaligned(as: attrreference_t.self)
                field += MemoryLayout<attrreference_t>.size
                let entryDevice = field.loadUnaligned(as: dev_t.self)
                field += MemoryLayout<dev_t>.size
                let type = field.loadUnaligned(as: fsobj_type_t.self)
                field += MemoryLayout<fsobj_type_t>.size
                let inode = field.loadUnaligned(as: UInt64.self)
                field += 8
                let namePointer = (nameField + Int(name.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
                if type == VDIR.rawValue {
                    if entryDevice == device { folders.append(prefix + String(cString: namePointer)) }
                    continue
                }
                let file = attrgroup_t(ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE)
                guard entryDevice == device, returned.fileattr & file == file else { continue }
                let links = field.loadUnaligned(as: UInt32.self)
                field += 4
                let allocated = field.loadUnaligned(as: off_t.self)
                field += 8
                var flags: UInt64? = nil
                if returned.forkattr & cloneAttributes == cloneAttributes {
                    flags = (field + 8).loadUnaligned(as: UInt64.self) // after the clone ID
                }
                size += self.count(bytes: Int64(allocated), regular: type == VREG.rawValue, links: Int(links),
                                   device: UInt64(entryDevice), inode: inode) {
                    // `DuplicateFinder.privateSize`: nil when the volume gives no flags or the file shares nothing.
                    guard let flags, flags & UInt64(EF_MAY_SHARE_BLOCKS | EF_SHARES_ALL_BLOCKS) != 0 else { return nil }
                    if flags & UInt64(EF_SHARES_ALL_BLOCKS) != 0 { return 0 }
                    return DuplicateFinder.privateSize(path: namePointer, in: fd)
                }
            }
        }
        return (size, folders, false)
    }
}
