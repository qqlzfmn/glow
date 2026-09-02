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
        guard let data = FileManager.default.contents(atPath: usageFile) else {
            return UsageFile(providers: [:])
        }
        do {
            return try JSONDecoder().decode(UsageFile.self, from: data)
        } catch {
            fputs("glow: corrupt usage.json ignored (\(error.localizedDescription))\n", stderr)
            return UsageFile(providers: [:])
        }
    }

    private static func writeUsageFile(_ file: UsageFile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(file)
        } catch {
            throw UsageStoreError.writeFailed("cannot encode usage state: \(error)")
        }
        do {
            try data.write(to: URL(fileURLWithPath: usageFile), options: .atomic)
        } catch {
            throw UsageStoreError.writeFailed("cannot write \(usageFile): \(error)")
        }
    }
}

/// Errors thrown when usage state cannot be persisted.
enum UsageStoreError: Error {
    case writeFailed(String)
}
