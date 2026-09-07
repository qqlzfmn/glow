import Foundation

/// Usage state management — read/write usage.json with flock-based locking.
/// Read failures are tolerated (empty state); write failures throw.
enum UsageStore {
    static var usageFile: String { StatePaths.usageFile }

    /// Persist a full provider usage snapshot. Throws `StateLockError` /
    /// encoding / IO errors wrapped as `UsageStoreError` on failure.
    static func writeUsage(_ file: UsageFile) throws {
        try StateFileLock.withLock {
            try writeUsageFile(file)
        }
    }

    /// Read the current snapshot. Missing and malformed files yield an
    /// empty state; a malformed (non-empty) file is traced to stderr.
    static func readUsage() -> UsageFile {
        do {
            return try StateFileLock.withLock {
                readUsageFile()
            }
        } catch {
            return UsageFile(providers: [:])
        }
    }

    /// Clear all usage state.
    static func clearUsage() throws {
        try StateFileLock.withLock {
            try writeUsageFile(UsageFile(providers: [:]))
        }
    }

    // MARK: - File IO

    private static func readUsageFile() -> UsageFile {
        JSONFileIO.read(at: usageFile, name: "usage.json")
            ?? UsageFile(providers: [:])
    }

    private static func writeUsageFile(_ file: UsageFile) throws {
        do {
            try JSONFileIO.write(file, to: usageFile, stateDir: StatePaths.stateDir)
        } catch {
            throw UsageStoreError.writeFailed("cannot write \(usageFile): \(error)")
        }
    }
}

/// Errors thrown when usage state cannot be persisted.
enum UsageStoreError: Error {
    case writeFailed(String)
}
