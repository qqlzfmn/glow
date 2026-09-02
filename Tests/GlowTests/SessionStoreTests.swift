import Testing
import Foundation
@testable import GlowCore

/// SessionStore reads its state dir from the process environment, and the
/// environment is process-global — so these tests must not run concurrently.
@Suite(.serialized)
final class SessionStoreTests {

    private let tmpDir: String

    init() {
        StateDirEnvLock.lock.lock()
        let dir = NSTemporaryDirectory() + "/glow-tests-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        self.tmpDir = dir
        setenv("GLOW_STATE_DIR", dir, 1)
    }

    deinit {
        unsetenv("GLOW_STATE_DIR")
        try? FileManager.default.removeItem(atPath: tmpDir)
        StateDirEnvLock.lock.unlock()
    }


    // MARK: - Helpers

    private func writeSessionsFile(_ sessions: [String: [String: Any]]) {
        let state: [String: Any] = ["sessions": sessions]
        let data = try! JSONSerialization.data(withJSONObject: state)
        try! data.write(to: URL(fileURLWithPath: SessionStore.sessionFile))
    }

    private func readSessionsFile() -> [String: SessionEntry] {
        guard let data = FileManager.default.contents(atPath: SessionStore.sessionFile) else {
            return [:]
        }
        return (try? JSONDecoder().decode(SessionFile.self, from: data))?.sessions ?? [:]
    }

    // MARK: - Aggregate priority (unified implementation)

    private func entry(_ signal: String) -> SessionEntry {
        SessionEntry(signal: signal, updatedAt: 0)
    }

    @Test func aggregatePriorityBlockedHighest() {
        let sessions = [
            "a": entry("working"),
            "b": entry("permission"),
            "c": entry("blocked"),
        ]
        #expect(aggregateSignal(from: sessions) == "blocked")
    }

    @Test func aggregatePriorityPermission() {
        let sessions = [
            "a": entry("working"),
            "b": entry("permission"),
        ]
        #expect(aggregateSignal(from: sessions) == "permission")
    }

    @Test func aggregatePriorityAttentionSet() {
        for signal in ["attention", "done"] {
            let sessions = [
                "a": entry(signal),
                "b": entry("working"),
            ]
            #expect(aggregateSignal(from: sessions) == "attention", "\(signal)")
        }
    }

    @Test func aggregatePriorityWorkingSet() {
        for signal in ["thinking", "working", "tool_done"] {
            let sessions = [
                "a": entry(signal),
            ]
            #expect(aggregateSignal(from: sessions) == "working")
        }
    }

    @Test func aggregateEmptyIsIdle() {
        #expect(aggregateSignal(from: [:]) == "idle")
    }

    // MARK: - applySessionSignal

    @Test func applyWorkingSignalPersistsAndAggregates() throws {
        let aggregate = try SessionStore.applySessionSignal(sessionKey: "s1", signalName: "working")
        #expect(aggregate == "working")

        let sessions = readSessionsFile()
        #expect(sessions["s1"]?.signal == "working")
    }

    @Test func applySessionEndRemovesSession() throws {
        try SessionStore.applySessionSignal(sessionKey: "s1", signalName: "working")
        try SessionStore.applySessionSignal(sessionKey: "s1", signalName: "session_end")

        let sessions = readSessionsFile()
        #expect(sessions["s1"] == nil)
        #expect(SessionStore.readSessionSnapshot()["aggregate"] as? String == "idle")
    }

    @Test func applyOffRemovesSession() throws {
        try SessionStore.applySessionSignal(sessionKey: "s1", signalName: "working")
        try SessionStore.applySessionSignal(sessionKey: "s1", signalName: "off")

        let sessions = readSessionsFile()
        #expect(sessions["s1"] == nil)
    }

    @Test func turnEndRemovesNonProtectedSession() throws {
        try SessionStore.applySessionSignal(sessionKey: "s1", signalName: "working")
        try SessionStore.applySessionSignal(sessionKey: "s1", signalName: "turn_end")

        let sessions = readSessionsFile()
        #expect(sessions["s1"] == nil)
    }

    @Test func turnEndKeepsPermissionSession() throws {
        try SessionStore.applySessionSignal(sessionKey: "s1", signalName: "permission")
        try SessionStore.applySessionSignal(sessionKey: "s1", signalName: "turn_end")

        let sessions = readSessionsFile()
        #expect(sessions["s1"]?.signal == "permission")
    }

    @Test func turnEndKeepsBlockedSession() throws {
        try SessionStore.applySessionSignal(sessionKey: "s1", signalName: "blocked")
        try SessionStore.applySessionSignal(sessionKey: "s1", signalName: "turn_end")

        let sessions = readSessionsFile()
        #expect(sessions["s1"]?.signal == "blocked")
    }

    // MARK: - TTL pruning

    @Test func expiredSessionPrunedOnRead() {
        let expiredAt = Date().timeIntervalSince1970 - SessionStore.sessionTTL - 60
        writeSessionsFile([
            "expired": ["signal": "working", "updated_at": expiredAt],
            "fresh": ["signal": "blocked", "updated_at": Date().timeIntervalSince1970],
        ])

        let snapshot = SessionStore.readSessionSnapshot()
        let sessions = snapshot["sessions"] as? [String: SessionEntry] ?? [:]
        #expect(sessions["expired"] == nil)
        #expect(sessions["fresh"] != nil)
        #expect(snapshot["aggregate"] as? String == "blocked")
    }

    // MARK: - clearSessionState

    @Test func clearSessionStateEmptiesStore() throws {
        try SessionStore.applySessionSignal(sessionKey: "s1", signalName: "working")
        try SessionStore.applySessionSignal(sessionKey: "s2", signalName: "blocked")

        try SessionStore.clearSessionState()

        #expect(readSessionsFile().isEmpty)
        #expect(SessionStore.readSessionSnapshot()["aggregate"] as? String == "idle")
    }
}
