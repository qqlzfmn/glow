import Testing
@testable import GlowCore

@Suite struct CodexHookAdapterTests {

    // MARK: - eventToSignal mapping (all 7 events)

    @Test func eventToSignalMapping() {
        let expected: [(String, String)] = [
            ("SessionStart", "session_start"),
            ("UserPromptSubmit", "thinking"),
            ("PreToolUse", "working"),
            ("PostToolUse", "tool_done"),
            ("PermissionRequest", "permission"),
            ("Stop", "turn_end"),
            ("SessionEnd", "session_end"),
        ]
        for (event, signal) in expected {
            #expect(
                CodexHookAdapter.chooseSignal(eventName: event, payload: [:]) == signal,
                "\(event) should map to \(signal)"
            )
        }
    }

    // MARK: - chooseSignal priority

    @Test func chooseSignalExplicitSignalWins() {
        #expect(CodexHookAdapter.chooseSignal(eventName: "Stop", payload: ["signal": "working"]) == "working")
    }

    @Test func chooseSignalInvalidExplicitSignalIgnored() {
        // Illegal signal names fall through to later rules.
        #expect(CodexHookAdapter.chooseSignal(eventName: "Stop", payload: ["signal": "bogus"]) == "turn_end")
    }

    @Test func chooseSignalStatusFieldMapped() {
        #expect(CodexHookAdapter.chooseSignal(eventName: "Stop", payload: ["status": "working"]) == "working")
        #expect(CodexHookAdapter.chooseSignal(eventName: "Stop", payload: ["state": "error"]) == "blocked")
        #expect(CodexHookAdapter.chooseSignal(eventName: "Stop", payload: ["status": "failed"]) == "blocked")
        #expect(CodexHookAdapter.chooseSignal(eventName: "Stop", payload: ["state": "exception"]) == "blocked")
    }

    @Test func chooseSignalInvalidStatusIgnored() {
        #expect(CodexHookAdapter.chooseSignal(eventName: "Stop", payload: ["status": "not-a-signal"]) == "turn_end")
    }

    @Test func chooseSignalDeepFailureMarker() {
        let payload: [String: Any] = [
            "result": ["output": ["error": "boom"]]
        ]
        #expect(CodexHookAdapter.chooseSignal(eventName: "Stop", payload: payload) == "blocked")
    }

    @Test func chooseSignalUnknownEventFallsBackToAttention() {
        #expect(CodexHookAdapter.chooseSignal(eventName: "TotallyUnknown", payload: [:]) == "attention")
    }

    // MARK: - sessionKey priority

    @Test func sessionKeyExplicitFields() {
        #expect(CodexHookAdapter.sessionKey(payload: ["session_id": "abc"], environ: [:]) == "abc")
        #expect(CodexHookAdapter.sessionKey(payload: ["conversation_id": "conv-1"], environ: [:]) == "conv-1")
        #expect(CodexHookAdapter.sessionKey(payload: ["thread_id": "t1"], environ: [:]) == "t1")
    }

    @Test func sessionKeyNestedLookup() {
        let payload: [String: Any] = ["context": ["session_id": "nested-1"]]
        #expect(CodexHookAdapter.sessionKey(payload: payload, environ: [:]) == "nested-1")
    }

    @Test func sessionKeyEnvironmentVariables() {
        #expect(CodexHookAdapter.sessionKey(payload: [:], environ: ["CODEX_SESSION_ID": "env-1"]) == "env-1")
        #expect(CodexHookAdapter.sessionKey(payload: [:], environ: ["CODEX_CONVERSATION_ID": "env-2"]) == "env-2")
        #expect(CodexHookAdapter.sessionKey(payload: [:], environ: ["CODEX_THREAD_ID": "env-3"]) == "env-3")
    }

    @Test func sessionKeyCwdFallback() {
        #expect(CodexHookAdapter.sessionKey(payload: ["cwd": "/tmp/project"], environ: [:]) == "cwd:/tmp/project")
    }

    @Test func sessionKeyGlobalFallback() {
        #expect(CodexHookAdapter.sessionKey(payload: [:], environ: [:]) == "global")
    }

    @Test func sessionKeyExplicitBeatsEnvironment() {
        #expect(
            CodexHookAdapter.sessionKey(
                payload: ["session_id": "explicit"], environ: ["CODEX_SESSION_ID": "env"]
            ) == "explicit"
        )
    }

    // MARK: - eventFromArgs (via readHookInput)

    @Test func eventFromArgsLongFlag() {
        let input = CodexHookAdapter.readHookInput(
            argv: ["prog", "--event", "UserPromptSubmit"], stdinText: "", environ: [:]
        )
        #expect(input.eventName == "UserPromptSubmit")
    }

    @Test func eventFromArgsShortFlag() {
        let input = CodexHookAdapter.readHookInput(
            argv: ["prog", "-e", "Stop"], stdinText: "", environ: [:]
        )
        #expect(input.eventName == "Stop")
    }

    @Test func eventFromArgsEqualsForm() {
        let input = CodexHookAdapter.readHookInput(
            argv: ["prog", "--event=PreToolUse"], stdinText: "", environ: [:]
        )
        #expect(input.eventName == "PreToolUse")
    }

    @Test func eventFromArgsPositional() {
        let input = CodexHookAdapter.readHookInput(
            argv: ["prog", "PostToolUse"], stdinText: "", environ: [:]
        )
        #expect(input.eventName == "PostToolUse")
    }

    @Test func readHookInputEventFromStdinJSON() {
        let input = CodexHookAdapter.readHookInput(
            argv: ["prog"],
            stdinText: #"{"hook_event_name": "Stop"}"#,
            environ: [:]
        )
        #expect(input.eventName == "Stop")
    }
}
