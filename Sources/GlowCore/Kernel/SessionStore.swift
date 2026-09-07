import Foundation

/// Errors thrown when session state cannot be persisted or the file lock
/// cannot be acquired. Replaces the previous silent `try?` failures.
enum SessionStoreError: Error {
    case lockUnavailable(String)
    case writeFailed(String)
}

/// Session state management — read/write/aggregate sessions.json with flock-based locking.
enum SessionStore {
    // MARK: - Paths

    static var stateDir: String { StatePaths.stateDir }

    static var sessionFile: String { StatePaths.sessionFile }

    static var lockFile: String { StatePaths.lockFile }

    static var sessionTTL: TimeInterval {
        if let raw = ProcessInfo.processInfo.environment["GLOW_SESSION_TTL_SECONDS"],
           let value = TimeInterval(raw) {
            return value
        }
        return 86400.0
    }

    // MARK: - Public API

    /// Update one session's signal. Returns the new aggregate signal name.
    /// Throws `SessionStoreError` when the state file cannot be written.
    @discardableResult
    static func applySessionSignal(sessionKey: String, signalName: String) throws -> String {
        return try withLock {
            var state = readSessionFile()
            let now = Date().timeIntervalSince1970
            pruneSessions(&state.sessions, now: now)

            if SignalSemantics.sessionEnd.contains(signalName)
                || SignalSemantics.sessionClear.contains(signalName) {
                state.sessions.removeValue(forKey: sessionKey)
            } else if SignalSemantics.turnEnd.contains(signalName) {
                if let current = state.sessions[sessionKey],
                   SignalSemantics.turnEndKeep.contains(current.signal) {
                    // keep the session — don't remove
                } else {
                    state.sessions.removeValue(forKey: sessionKey)
                }
            } else {
                state.sessions[sessionKey] = SessionEntry(signal: signalName, updatedAt: now)
            }

            let aggregate = aggregateSignal(from: state.sessions)
            try writeSessionFile(state)
            return aggregate
        }
    }

    /// Clear all tracked session states.
    /// Throws `SessionStoreError` when the state file cannot be written.
    static func clearSessionState() throws {
        try withLock {
            try writeSessionFile(SessionFile(sessions: [:]))
        }
    }

    /// Read the current snapshot (aggregate + sessions) without modifying.
    /// `sessions` holds typed `SessionEntry` values. Read failures are tolerated
    /// and yield an idle/empty snapshot.
    static func readSessionSnapshot() -> [String: Any] {
        do {
            return try withLock {
                var state = readSessionFile()
                pruneSessions(&state.sessions, now: Date().timeIntervalSince1970)
                return [
                    "aggregate": aggregateSignal(from: state.sessions),
                    "sessions": state.sessions,
                ]
            }
        } catch {
            return ["aggregate": "idle", "sessions": [String: SessionEntry]()]
        }
    }

    /// Missing file and malformed JSON yield an empty state, but a malformed
    /// (non-empty) file is traced to stderr — silent data loss hides bugs.
    private static func readSessionFile() -> SessionFile {
        JSONFileIO.read(at: sessionFile, name: "sessions.json")
            ?? SessionFile(sessions: [:])
    }
    private static func writeSessionFile(_ state: SessionFile) throws {
        do {
            try JSONFileIO.write(state, to: sessionFile, stateDir: stateDir)
        } catch {
            throw SessionStoreError.writeFailed("cannot write \(sessionFile): \(error)")
        }
    }

    private static func pruneSessions(_ sessions: inout [String: SessionEntry], now: TimeInterval) {
        sessions = sessions.filter { _, entry in
            now - entry.updatedAt <= sessionTTL
        }
    }

    private static func withLock<T>(_ body: () throws -> T) throws -> T {
        do {
            return try StateFileLock.withLock(stateDir: stateDir, lockFile: lockFile, body)
        } catch let error as StateLockError {
            switch error {
            case .lockUnavailable(let message):
                throw SessionStoreError.lockUnavailable(message)
            }
        }
    }
}

