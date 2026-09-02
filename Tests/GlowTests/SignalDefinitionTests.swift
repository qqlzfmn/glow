import Testing
import Foundation
@testable import GlowCore

@Suite struct SignalDefinitionTests {

    // MARK: - Registry completeness

    @Test func allElevenSignalsDefined() {
        let expected: Set<String> = [
            "idle", "thinking", "working", "tool_done",
            "attention", "permission", "blocked", "done",
            "session_start", "session_end", "off",
        ]
        #expect(Set(SIGNAL_DEFINITIONS.keys) == expected)
    }

    // MARK: - SignalColor.colorKey

    @Test func signalColorKeys() {
        #expect(SignalColor.green.colorKey == "green")
        #expect(SignalColor.yellow.colorKey == "yellow")
        #expect(SignalColor.red.colorKey == "red")
        #expect(SignalColor.grey.colorKey == "grey")
    }

    // MARK: - SIGNAL_NAMES consistency

    @Test func signalNamesDerivedFromRegistry() {
        #expect(SIGNAL_NAMES == Set(SIGNAL_DEFINITIONS.keys))
    }

    // MARK: - aggregateSignal (typed) priority

    private func entry(_ signal: String) -> SessionEntry {
        SessionEntry(signal: signal, updatedAt: 0)
    }

    @Test func aggregateBlockedHighest() {
        let sessions = [
            "a": entry("working"),
            "b": entry("permission"),
            "c": entry("blocked"),
        ]
        #expect(aggregateSignal(from: sessions) == "blocked")
    }

    @Test func aggregatePermission() {
        let sessions = [
            "a": entry("working"),
            "b": entry("permission"),
        ]
        #expect(aggregateSignal(from: sessions) == "permission")
    }

    @Test func aggregateAttentionSet() {
        for signal in ["attention", "done"] {
            let sessions = [
                "a": entry(signal),
                "b": entry("working"),
            ]
            #expect(aggregateSignal(from: sessions) == "attention", "\(signal)")
        }
    }

    @Test func aggregateWorkingSet() {
        for signal in ["thinking", "working", "tool_done"] {
            let sessions = ["a": entry(signal)]
            #expect(aggregateSignal(from: sessions) == "working", "\(signal)")
        }
    }

    @Test func aggregateEmptyIsIdle() {
        #expect(aggregateSignal(from: [:]) == "idle")
    }
}
