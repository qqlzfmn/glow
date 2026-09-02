import Testing
@testable import GlowCore

@Suite struct ClaudeCodeHookAdapterTests {

    // MARK: - eventToSignal mapping (all 12 events)

    @Test func eventToSignalMapping() {
        let expected: [(String, String)] = [
            ("SessionStart", "session_start"),
            ("UserPromptSubmit", "thinking"),
            ("PreToolUse", "working"),
            ("PostToolUse", "tool_done"),
            ("PostToolUseFailure", "blocked"),
            ("PreCompact", "working"),
            ("SubagentStart", "working"),
            ("SubagentStop", "tool_done"),
            ("Stop", "turn_end"),
            ("Notification", "attention"),
            ("PermissionRequest", "permission"),
            ("SessionEnd", "session_end"),
        ]
        for (event, signal) in expected {
            #expect(
                ClaudeCodeHookAdapter.chooseSignal(eventName: event, payload: [:]) == signal,
                "\(event) should map to \(signal)"
            )
        }
    }

    // MARK: - Stop reason → blocked

    @Test func stopReasonMaxTokensMapsToBlocked() {
        #expect(
            ClaudeCodeHookAdapter.chooseSignal(
                eventName: "Stop", payload: ["stop_reason": "max_tokens"]
            ) == "blocked"
        )
    }

    @Test func stopReasonErrorMapsToBlocked() {
        #expect(
            ClaudeCodeHookAdapter.chooseSignal(
                eventName: "Stop", payload: ["stop_reason": "error"]
            ) == "blocked"
        )
    }

    @Test func notificationMapsToAttention() {
        #expect(ClaudeCodeHookAdapter.chooseSignal(eventName: "Notification", payload: [:]) == "attention")
    }

    @Test func chooseSignalExplicitSignalWins() {
        #expect(
            ClaudeCodeHookAdapter.chooseSignal(
                eventName: "Stop", payload: ["signal": "working"]
            ) == "working"
        )
    }

    @Test func chooseSignalUnknownEventFallsBackToAttention() {
        #expect(ClaudeCodeHookAdapter.chooseSignal(eventName: "Whatever", payload: [:]) == "attention")
    }

    // MARK: - sessionKey priority

    @Test func sessionKeyPayloadSessionID() {
        #expect(ClaudeCodeHookAdapter.sessionKey(payload: ["session_id": "cc-1"], environ: [:]) == "cc-1")
    }

    @Test func sessionKeyEnvironmentVariables() {
        #expect(
            ClaudeCodeHookAdapter.sessionKey(
                payload: [:], environ: ["CLAUDE_CODE_SESSION_ID": "env-1"]
            ) == "env-1"
        )
        #expect(
            ClaudeCodeHookAdapter.sessionKey(
                payload: [:], environ: ["CLAUDE_SESSION_ID": "env-2"]
            ) == "env-2"
        )
    }

    @Test func sessionKeyCwdFallback() {
        #expect(ClaudeCodeHookAdapter.sessionKey(payload: ["cwd": "/tmp/x"], environ: [:]) == "cwd:/tmp/x")
    }

    @Test func sessionKeyGlobalFallback() {
        #expect(ClaudeCodeHookAdapter.sessionKey(payload: [:], environ: [:]) == "global")
    }

    @Test func sessionKeyPayloadBeatsEnvironment() {
        #expect(
            ClaudeCodeHookAdapter.sessionKey(
                payload: ["session_id": "explicit"],
                environ: ["CLAUDE_CODE_SESSION_ID": "env"]
            ) == "explicit"
        )
    }

    // MARK: - readHookInput

    @Test func readHookInputEventField() {
        let input = ClaudeCodeHookAdapter.readHookInput(
            argv: ["prog"], stdinText: #"{"event": "Stop"}"#
        )
        #expect(input.eventName == "Stop")
    }

    @Test func readHookInputHookEventNameField() {
        let input = ClaudeCodeHookAdapter.readHookInput(
            argv: ["prog"], stdinText: #"{"hook_event_name": "Notification"}"#
        )
        #expect(input.eventName == "Notification")
    }

    @Test func readHookInputArgsBeatStdin() {
        let input = ClaudeCodeHookAdapter.readHookInput(
            argv: ["prog", "--event", "Stop"],
            stdinText: #"{"hook_event_name": "Notification"}"#
        )
        #expect(input.eventName == "Stop")
    }
}
