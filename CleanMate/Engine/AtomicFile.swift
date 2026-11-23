import Foundation
import os

/// Saves a file whole or not at all: the bytes go to a temporary file next to it, are flushed to disk, then the
/// temporary file is renamed over it. A full disk or an I/O error leaves the old file exactly as it was.
nonisolated enum AtomicFile {
    private static let logger = Logger(subsystem: "com.homielab.CleanMate", category: "save")

    /// Writes the bytes to the open temporary file; tests pass one that fails part way.
    typealias Writer = (FileHandle, Data) throws -> Void
    static let plainWrite: Writer = { try $0.write(contentsOf: $1) }

    /// Prefix of the temporary file next to `url` (hidden): `.<name>.tmp-<UUID>`.
    static func temporaryPrefix(_ url: URL) -> String { ".\(url.lastPathComponent).tmp-" }

    /// Replaces `url` with `data` (created with `permissions` when new; a symlink at `url` is replaced, never
    /// followed). Throws when any step fails; `url` is then untouched and the temporary file removed.
    static func write(_ data: Data, to url: URL, permissions: mode_t = 0o644, writer: Writer = plainWrite) throws {
        let temp = url.deletingLastPathComponent().appending(path: temporaryPrefix(url) + UUID().uuidString)
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, permissions)
        guard fd >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        do {
            try writer(handle, data)
            guard fsync(fd) == 0 else { throw posixError() }
        } catch {
            close(fd)
            unlink(temp.path)
            throw error
        }
        close(fd)
        guard rename(temp.path, url.path) == 0 else {
            let error = posixError()
            unlink(temp.path)
            throw error
        }
    }

    /// `write` for files whose loss costs only time (caches of sizes and hashes): makes the folder, logs a failure
    /// instead of throwing. nil `data` (it couldn't be encoded) counts as a failure. False when nothing was saved.
    @discardableResult
    static func save(_ data: Data?, to url: URL, permissions: mode_t = 0o644) -> Bool {
        do {
            guard let data else { throw CocoaError(.coderInvalidValue) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try write(data, to: url, permissions: permissions)
            return true
        } catch {
            logger.error("Could not save \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
