import Foundation

/// Errors thrown when the shared state lock cannot be acquired.
/// Mirrors `SessionStoreError` semantics for the usage contract.
enum StateLockError: Error {
    case lockUnavailable(String)
}

/// Exclusive `flock` over `state.lock` in the state directory. All JSON
/// contract files (`sessions.json`, `usage.json`) share this one lock:
/// writers are short and rare, and a single lock keeps cross-file reads
/// consistent without lock-ordering concerns.
enum StateFileLock {
    static func withLock<T>(
        stateDir: String = StatePaths.stateDir,
        lockFile: String = StatePaths.lockFile,
        _ body: () throws -> T
    ) throws -> T {
        do {
            try FileManager.default.createDirectory(
                atPath: stateDir, withIntermediateDirectories: true
            )
        } catch {
            throw StateLockError.lockUnavailable(
                "cannot create state dir \(stateDir): \(error)"
            )
        }

        // Open or create the lock file.
        if !FileManager.default.fileExists(atPath: lockFile) {
            FileManager.default.createFile(atPath: lockFile, contents: nil)
        }

        guard let fd = fopen(lockFile, "a+") else {
            throw StateLockError.lockUnavailable(
                "cannot open lock file \(lockFile): \(String(cString: strerror(errno)))"
            )
        }
        defer { fclose(fd) }

        flock(fileno(fd), LOCK_EX)
        defer { flock(fileno(fd), LOCK_UN) }

        return try body()
    }
}

#if os(macOS)
import Darwin
#else
import Glibc
#endif

private let LOCK_EX: Int32 = 2
private let LOCK_UN: Int32 = 8
