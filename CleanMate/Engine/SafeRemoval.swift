import Foundation

/// Removal that is checked and done through the same open folder, so a symlink swapped in after the check can't send it
/// anywhere else. The folder holding the item is opened without following a symlink there (`O_NOFOLLOW`); the safety
/// check is made on the path that open folder really has (`F_GETPATH`, every symlink above it resolved); the item is
/// looked at in it (`fstatat`, never followed) and must still be what the scan saw (`FileID`), then it is removed in it
/// (`unlinkat`). A folder is emptied the same way: each subfolder is opened from its parent without following a symlink
/// and only on the item's own volume, so a symlink inside is removed itself, never followed, and another volume
/// mounted inside is never entered.
nonisolated enum SafeRemoval {
    /// A file, folder or symlink on disk: its volume and inode, read without following a symlink.
    struct FileID: Hashable, Sendable {
        let device: dev_t
        let inode: ino_t

        init(device: dev_t, inode: ino_t) {
            self.device = device
            self.inode = inode
        }

        init(_ info: stat) { self.init(device: info.st_dev, inode: info.st_ino) }

        /// nil when nothing is at `url`.
        init?(_ url: URL) {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return nil }
            self.init(info)
        }
    }

    enum Failure: Error, Equatable {
        /// Not the item that was checked: its folder is a symlink or a file now, its real place is refused by the safety
        /// check, it is not what the scan saw, or a folder was swapped while being opened. Left as it is.
        case changed
        /// Not (wholly) removed: no permission, locked, gone, another volume mounted inside… (`errno`).
        case failed(Int32)
    }

    /// Volume of an open folder; injected by tests, which can't mount.
    typealias Device = @Sendable (Int32) -> dev_t?
    static let device: Device = { fd in
        var info = stat()
        return fstat(fd, &info) == 0 ? info.st_dev : nil
    }

    /// Checks `url` without removing it, for a removal that only takes a path (`FileManager.trashItem`): through its
    /// open folder, `allows` the real path, the item still `expected` (when known) and on its folder's volume.
    static func check(_ url: URL, expected: FileID? = nil, regularFileOnly: Bool = false,
                      allows: (URL) -> Bool) throws(Failure) {
        try inFolder(of: url, expected: expected, regularFileOnly: regularFileOnly, allows: allows) { _, _, _ in }
    }

    /// Removes `url` (a folder with everything inside) once it passes the checks of `check`.
    static func remove(_ url: URL, expected: FileID? = nil, regularFileOnly: Bool = false,
                       allows: (URL) -> Bool, device: Device = SafeRemoval.device) throws(Failure) {
        try inFolder(of: url, expected: expected, regularFileOnly: regularFileOnly, allows: allows) { folder, name, info throws(Failure) in
            guard info.st_mode & S_IFMT == S_IFDIR else {
                guard unlinkat(folder, name, 0) == 0 else { throw .failed(errno) }
                return
            }
            let fd = openat(folder, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw errno == ELOOP || errno == ENOTDIR ? .changed : .failed(errno) }
            var opened = stat()
            guard fstat(fd, &opened) == 0, FileID(opened) == FileID(info) else { close(fd); throw .changed }
            guard let volume = device(fd) else { close(fd); throw .failed(EIO) }
            try empty(fd, volume: volume, device: device)
            guard unlinkat(folder, name, AT_REMOVEDIR) == 0 else { throw .failed(errno) }
        }
    }

    /// Removes the folder `url` only when it is empty (`rmdir`), checked like `check`.
    static func removeEmptyFolder(_ url: URL, allows: (URL) -> Bool) throws(Failure) {
        try inFolder(of: url, expected: nil, regularFileOnly: false, allows: allows) { folder, name, info throws(Failure) in
            guard info.st_mode & S_IFMT == S_IFDIR else { throw .failed(ENOTDIR) }
            guard unlinkat(folder, name, AT_REMOVEDIR) == 0 else { throw .failed(errno) }
        }
    }

    /// Opens the folder holding `url` without following a symlink there, checks the item in it and runs `body` with
    /// that folder, the item's name and its `lstat`.
    private static func inFolder(of url: URL, expected: FileID?, regularFileOnly: Bool, allows: (URL) -> Bool,
                                 _ body: (Int32, String, stat) throws(Failure) -> Void) throws(Failure) {
        let name = url.lastPathComponent
        guard !name.isEmpty, name != "/", name != ".", name != "..", !name.contains("/") else { throw .failed(EINVAL) }
        let folder = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { throw errno == ELOOP || errno == ENOTDIR ? .changed : .failed(errno) }
        defer { close(folder) }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(folder, F_GETPATH, &buffer) == 0 else { throw .failed(errno) }
        let path = String(cString: buffer)
        guard allows(URL(fileURLWithPath: path == "/" ? "/" + name : path + "/" + name)) else { throw .changed }
        var info = stat(), folderInfo = stat()
        guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw .failed(errno) }
        // A volume mounted on the item itself: its root reports the other volume.
        guard fstat(folder, &folderInfo) == 0, info.st_dev == folderInfo.st_dev else { throw .changed }
        if let expected, FileID(info) != expected { throw .changed }
        if regularFileOnly, info.st_mode & S_IFMT != S_IFREG { throw .changed }
        try body(folder, name, info)
    }

    /// Removes everything in the open folder `fd` (closed on return), never leaving `volume`. Keeps going after a
    /// failure, so as much as possible goes; the first failure is thrown.
    private static func empty(_ fd: Int32, volume: dev_t, device: Device) throws(Failure) {
        guard let stream = fdopendir(fd) else { let error = errno; close(fd); throw .failed(error) }
        defer { closedir(stream) }
        // Read in full first: entries removed while reading could make `readdir` skip others.
        // Names as raw bytes, NUL-terminated: never re-encoded, so each one names exactly what was read.
        var children: [(name: [CChar], folder: Bool)] = []
        while let entry = readdir(stream) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                bytes.prefix(Int(entry.pointee.d_namlen)).map { CChar(bitPattern: $0) } + [0]
            }
            guard name != [46, 0], name != [46, 46, 0] else { continue } // "." and ".."
            children.append((name, entry.pointee.d_type == DT_DIR || entry.pointee.d_type == DT_UNKNOWN))
        }
        var first: Failure?
        for child in children {
            do throws(Failure) {
                try removeChild(child.name, maybeFolder: child.folder, in: fd, volume: volume, device: device)
            } catch {
                first = first ?? error
            }
        }
        if let first { throw first }
    }

    private static func removeChild(_ name: [CChar], maybeFolder: Bool, in folder: Int32, volume: dev_t,
                                    device: Device) throws(Failure) {
        if !maybeFolder {
            if unlinkat(folder, name, 0) == 0 || errno == ENOENT { return }
            // A folder swapped in since it was read is emptied below; anything else (locked, no permission) stays.
            guard errno == EPERM || errno == EISDIR else { throw .failed(errno) }
        }
        let fd = openat(folder, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            let error = errno
            if error == ENOENT { return }
            // Not a folder (any more): a symlink or file is removed itself, never followed.
            if (error == ELOOP || error == ENOTDIR), maybeFolder {
                if unlinkat(folder, name, 0) == 0 || errno == ENOENT { return }
                throw .failed(errno)
            }
            throw .failed(maybeFolder ? error : EPERM)
        }
        // Another volume mounted here (its root, entered by `openat`): never walked nor removed.
        guard device(fd) == volume else { close(fd); throw .failed(EXDEV) }
        try empty(fd, volume: volume, device: device)
        guard unlinkat(folder, name, AT_REMOVEDIR) == 0 || errno == ENOENT else { throw .failed(errno) }
    }
}
