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
        /// `trash` only: the safety check refuses the item's real place. Left as it is.
        case refused
        /// `trash` only: locked in Finder or by SIP (`Scanner.isLocked`), so the move can only fail. Left as it is.
        case locked
        /// `trash` only: what reached the Trash, at this place, is not the item checked (swapped in during the move).
        case movedOther(URL)
    }

    /// Volume of an open folder; injected by tests, which can't mount.
    typealias Device = @Sendable (Int32) -> dev_t?
    static let device: Device = { fd in
        var info = stat()
        return fstat(fd, &info) == 0 ? info.st_dev : nil
    }

    /// Moves `url` to the Trash with `move` (`FileManager.trashItem`, which only takes a path), making sure the item
    /// moved is the one checked. In its open folder the item is looked at (`fstatat`, never followed; on the folder's
    /// volume, still `expected` when known), `allows` its real path (and the path handed in, when a symlink above it
    /// makes it differ), then it is opened itself (`O_NOFOLLOW`; a symlink item: the link) and held open, so its
    /// volume and inode stay its own (an item the user can't read: checked by them alone). Right before the move it
    /// must still be in that folder, and its real path (no symlink above it) and the path handed in must still lead
    /// to it; `move` gets the real path. Afterwards what landed in the Trash must be the same item (a move on one
    /// volume keeps the inode), else `movedOther`. `move` returning nil: not checked after. Errors of `move` itself
    /// are thrown as they are. `beforeMove`: tests swap the item between the check and the move.
    static func trash(_ url: URL, expected: FileID? = nil, regularFileOnly: Bool = false, allows: (URL) -> Bool,
                      beforeMove: () -> Void = {}, move: (URL) throws -> URL?) throws -> URL? {
        let held = try Held(url, expected: expected, regularFileOnly: regularFileOnly, allows: allows)
        beforeMove()
        try held.unchanged()
        return try held.landed(move(held.path))
    }

    /// `trash` with a move that waits (`NSWorkspace.recycle`, which may ask for an admin password).
    static func trash(_ url: URL, expected: FileID? = nil, allows: (URL) -> Bool,
                      moveAsync move: (URL) async throws -> URL?) async throws -> URL? {
        let held = try Held(url, expected: expected, regularFileOnly: false, allows: allows)
        try held.unchanged()
        return try await held.landed(move(held.path))
    }

    /// An item checked for a move to the Trash, held open with its folder until it is moved.
    private final class Held {
        let folder: Int32
        let item: Int32
        let name: String
        /// Real path: the open folder's (`F_GETPATH`) and the item's name.
        let path: URL
        /// The path handed in.
        let given: URL
        let id: FileID

        init(_ url: URL, expected: FileID?, regularFileOnly: Bool, allows: (URL) -> Bool) throws(Failure) {
            given = url
            let (folder, name, path) = try SafeRemoval.openFolder(of: url)
            var item: Int32 = -1
            var opened = stat()
            do throws(Failure) {
                var info = stat(), folderInfo = stat()
                guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw .failed(errno) }
                guard fstat(folder, &folderInfo) == 0, info.st_dev == folderInfo.st_dev else { throw .changed }
                if let expected, FileID(info) != expected { throw .changed }
                if regularFileOnly, info.st_mode & S_IFMT != S_IFREG { throw .changed }
                // Read before the safety check, compared after it: the check is about this very item. The path handed
                // in too when a symlink above it makes it differ: a caller's check may compare it with paths it knows.
                guard allows(path), url.standardizedFileURL.path == path.path || allows(url) else { throw .refused }
                let link = info.st_mode & S_IFMT == S_IFLNK
                // O_EVTONLY: no read access needed, never holds a drive from unmounting; O_NONBLOCK: a FIFO doesn't wait.
                item = openat(folder, name, O_EVTONLY | O_NONBLOCK | O_CLOEXEC | (link ? O_SYMLINK : O_NOFOLLOW))
                if item >= 0 {
                    guard fstat(item, &opened) == 0, FileID(opened) == FileID(info) else { throw .changed }
                } else if errno == EACCES || errno == EPERM {
                    // Not readable by the user (mode 000): it still moves (a rename needs only its folder), checked by
                    // the volume and inode read above.
                    opened = info
                } else {
                    throw errno == ELOOP ? .changed : .failed(errno)
                }
                if Scanner.isLocked(opened) { throw .locked }
            } catch {
                if item >= 0 { close(item) }
                close(folder)
                throw error
            }
            self.folder = folder
            self.item = item
            self.name = name
            self.path = path
            id = FileID(opened)
        }

        deinit {
            if item >= 0 { close(item) }
            close(folder)
        }

        /// Still in its folder, and its real path and the path handed in still lead to it (no folder above it moved or
        /// swapped since).
        func unchanged() throws(Failure) {
            var info = stat()
            guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0, FileID(info) == id,
                  FileID(path) == id, FileID(given) == id else { throw .changed }
        }

        /// `inTrash` when it is the item held; nil stays nil.
        func landed(_ inTrash: URL?) throws(Failure) -> URL? {
            guard let inTrash else { return nil }
            guard FileID(inTrash) == id else { throw .movedOther(inTrash) }
            return inTrash
        }
    }

    /// Removes `url` (a folder with everything inside) once it passes the checks of `inFolder`: its real path
    /// `allows` it, it is on its folder's volume and still `expected` (when known).
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

    /// Removes the folder `url` only when it is empty (`rmdir`), checked like `remove`.
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
        let (folder, name, path) = try openFolder(of: url)
        defer { close(folder) }
        guard allows(path) else { throw .changed }
        var info = stat(), folderInfo = stat()
        guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw .failed(errno) }
        // A volume mounted on the item itself: its root reports the other volume.
        guard fstat(folder, &folderInfo) == 0, info.st_dev == folderInfo.st_dev else { throw .changed }
        if let expected, FileID(info) != expected { throw .changed }
        if regularFileOnly, info.st_mode & S_IFMT != S_IFREG { throw .changed }
        try body(folder, name, info)
    }

    /// Opens the folder holding `url` without following a symlink there (the caller closes it): the folder, the item's
    /// name and its real path (the folder's `F_GETPATH`, every symlink above it resolved, and the name).
    private static func openFolder(of url: URL) throws(Failure) -> (Int32, String, URL) {
        let name = url.lastPathComponent
        guard !name.isEmpty, name != "/", name != ".", name != "..", !name.contains("/") else { throw .failed(EINVAL) }
        let folder = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { throw errno == ELOOP || errno == ENOTDIR ? .changed : .failed(errno) }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(folder, F_GETPATH, &buffer) == 0 else { let error = errno; close(folder); throw .failed(error) }
        let path = String(cString: buffer)
        return (folder, name, URL(fileURLWithPath: path == "/" ? "/" + name : path + "/" + name))
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
