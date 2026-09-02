import Foundation

/// Claude Code hook adapter — maps Claude Code lifecycle events to signal names.
enum ClaudeCodeHookAdapter {

    // MARK: - Event → Signal mapping

    private static let eventToSignal: [String: String] = [
        "SessionStart": "session_start",
        "UserPromptSubmit": "thinking",
        "PreToolUse": "working",
        "PostToolUse": "tool_done",
        "PostToolUseFailure": "blocked",
        "PreCompact": "working",
        "SubagentStart": "working",
        "SubagentStop": "tool_done",
        "Stop": "turn_end",
        "Notification": "attention",
        "PermissionRequest": "permission",
        "SessionEnd": "session_end",
    ]

    private static let stopReasonSignal: [String: String] = [
        "max_tokens": "blocked",
        "error": "blocked",
    ]

    /// Parse hook input from argv + stdin JSON.
    static func readHookInput(argv: [String], stdinText: String) -> HookInput {
        var eventName: String? = eventFromArgs(argv)
        var payload: [String: Any] = [:]

        let trimmed = stdinText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            if let data = trimmed.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                payload = parsed
                if eventName == nil {
                    eventName = (parsed["event"] as? String) ?? (parsed["hook_event_name"] as? String)
                }
            } else {
                payload = ["raw": trimmed]
            }
        }

        let resolvedEventName = eventName ?? "Stop"
        return HookInput(eventName: resolvedEventName, payload: payload)
    }

    /// Determine signal from hook input.
    static func chooseSignal(eventName: String, payload: [String: Any]) -> String {
        // 1. Explicit signal name in payload.
        if let explicit = (payload["signal"] ?? payload["signal_name"]) as? String {
            let normalized = explicit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if SIGNAL_NAMES.contains(normalized) {
                return normalized
            }
        }

        // 2. Stop event with stop_reason.
        if eventName == "Stop",
           let stopReason = payload["stop_reason"] as? String,
           let mapped = stopReasonSignal[stopReason] {
            return mapped
        }

        // 3. Event name mapping.
        return eventToSignal[eventName] ?? "attention"
    }

    /// Extract session key from payload and environment.
    static func sessionKey(payload: [String: Any], environ: [String: String]) -> String {
        // 1. Explicit session_id in payload.
        if let sid = payload["session_id"] as? String,
           !sid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return sid.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 2. Environment variables.
        for key in ["CLAUDE_CODE_SESSION_ID", "CLAUDE_SESSION_ID"] {
            if let value = environ[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }

        // 3. cwd fallback.
        if let cwd = payload["cwd"] as? String,
           !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "cwd:\(cwd.trimmingCharacters(in: .whitespacesAndNewlines))"
        }

        return "global"
    }

    // MARK: - Runner

    static func run(argv: [String]) -> Int32 {
        let environ = ProcessInfo.processInfo.environment
        let input = readHookInput(argv: argv, stdinText: HookSupport.readStdinText())
        let signal = chooseSignal(eventName: input.eventName, payload: input.payload)
        let key = sessionKey(payload: input.payload, environ: environ)
        return HookSupport.applyAndReport(sessionKey: key, signal: signal)
    }

}

