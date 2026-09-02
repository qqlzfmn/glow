import Foundation

/// Codex hook adapter — maps Codex lifecycle events to signal names.
enum CodexHookAdapter {

    // MARK: - Event → Signal mapping

    private static let eventToSignal: [String: String] = [
        "SessionStart": "session_start",
        "UserPromptSubmit": "thinking",
        "PreToolUse": "working",
        "PostToolUse": "tool_done",
        "PermissionRequest": "permission",
        "Stop": "turn_end",
        "SessionEnd": "session_end",
    ]

    private static let failureSignals: [String: String] = [
        "error": "blocked",
        "failed": "blocked",
        "failure": "blocked",
        "exception": "blocked",
    ]

    // MARK: - Public API

    /// Parse hook input from argv + stdin JSON.
    static func readHookInput(argv: [String], stdinText: String, environ: [String: String]) -> HookInput {
        var eventName: String? = eventFromArgs(argv)
        var payload: [String: Any] = [:]

        let trimmed = stdinText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            if let data = trimmed.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                payload = parsed
                // event name from payload if not already known from args
                if eventName == nil {
                    eventName = eventFromPayload(payload)
                }
            } else {
                payload = ["raw": trimmed]
            }
        }

        let resolvedEventName = eventName
            ?? environ["CODEX_HOOK_EVENT"]
            ?? environ["HOOK_EVENT"]
            ?? "Stop"

        return HookInput(eventName: resolvedEventName, payload: payload)
    }

    /// Determine signal from hook input.
    static func chooseSignal(eventName: String, payload: [String: Any]) -> String {
        // 1. Explicit signal name in payload.
        if let explicit = firstString(payload, keys: ["signal", "signal_name", "lamp_signal"]) {
            let normalized = explicit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if SIGNAL_NAMES.contains(normalized) {
                return normalized
            }
        }

        // 2. Status/state field.
        if let status = firstString(payload, keys: ["status", "state"]) {
            let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if SIGNAL_NAMES.contains(normalized) {
                return normalized
            }
            if let mapped = failureSignals[normalized] {
                return mapped
            }
        }

        // 3. Deep failure marker search.
        if let marker = structuredFailureMarker(payload) {
            return failureSignals[marker] ?? "blocked"
        }

        // 4. Event name mapping.
        let key = eventName.trimmingCharacters(in: .whitespacesAndNewlines)
        return eventToSignal[key] ?? "attention"
    }

    /// Extract session key from payload and environment.
    static func sessionKey(payload: [String: Any], environ: [String: String]) -> String {
        // 1. Explicit session ID fields.
        if let explicit = firstString(payload, keys: [
            "session_id", "conversation_id", "thread_id", "chat_id", "codex_session_id",
        ]) {
            return explicit.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 2. Nested search.
        if let nested = findNestedString(payload, keys: [
            "session_id", "conversation_id", "thread_id", "codex_session_id",
        ]) {
            return nested
        }

        // 3. Environment variables.
        for key in ["CODEX_SESSION_ID", "CODEX_CONVERSATION_ID", "CODEX_THREAD_ID"] {
            if let value = environ[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }

        // 4. cwd fallback.
        if let cwd = firstString(payload, keys: ["cwd", "workspace", "workspace_dir", "project_dir"]) {
            return "cwd:\(cwd.trimmingCharacters(in: .whitespacesAndNewlines))"
        }

        return "global"
    }

    // MARK: - Runner

    static func run(argv: [String]) -> Int32 {
        let environ = ProcessInfo.processInfo.environment
        let input = readHookInput(argv: argv, stdinText: HookSupport.readStdinText(), environ: environ)
        let signal = chooseSignal(eventName: input.eventName, payload: input.payload)
        let key = sessionKey(payload: input.payload, environ: environ)
        return HookSupport.applyAndReport(sessionKey: key, signal: signal)
    }

    // MARK: - Internal helpers

    /// Extract event name from payload fields.
    private static func eventFromPayload(_ payload: [String: Any]) -> String? {
        return firstString(payload, keys: [
            "hook_event_name", "event_name", "event", "hook", "type",
        ])
    }

    /// Get first non-empty string value for a set of keys.
    private static func firstString(_ dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    /// Recursively search for a string value by key names.
    private static func findNestedString(_ value: Any, keys: [String]) -> String? {
        if let dict = value as? [String: Any] {
            if let direct = firstString(dict, keys: keys) {
                return direct.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            for child in dict.values {
                if let found = findNestedString(child, keys: keys) {
                    return found
                }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = findNestedString(child, keys: keys) {
                    return found
                }
            }
        }
        return nil
    }

    /// Deep search for failure markers.
    private static func structuredFailureMarker(_ payload: [String: Any]) -> String? {
        return findFailureMarker(
            payload,
            keys: [
                "error", "failure", "exception", "error_type",
                "error_message", "failure_reason", "exit_status", "tool_error",
            ]
        )
    }

    private static func findFailureMarker(_ value: Any, keys: [String]) -> String? {
        if let dict = value as? [String: Any] {
            for (key, child) in dict {
                let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if failureSignals[normalizedKey] != nil || keys.contains(normalizedKey) {
                    if let marker = failureMarkerFromValue(child) {
                        return marker
                    }
                }
                if let found = findFailureMarker(child, keys: keys) {
                    return found
                }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = findFailureMarker(child, keys: keys) {
                    return found
                }
            }
        }
        return nil
    }

    private static func failureMarkerFromValue(_ value: Any) -> String? {
        if let bool = value as? Bool {
            return bool ? "error" : nil
        }
        if value is NSNull {
            return nil
        }
        if let number = value as? NSNumber {
            return number.doubleValue != 0 ? "failed" : nil
        }
        if let string = value as? String {
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized.isEmpty
                || ["0", "false", "no", "none", "null", "success", "ok"].contains(normalized) {
                return nil
            }
            for marker in failureSignals.keys {
                if normalized.contains(marker) {
                    return marker
                }
            }
            return "error"
        }
        return "error"
    }
}


