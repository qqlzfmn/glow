import Foundation

// MARK: - Shared hook adapter pieces

/// Parsed hook invocation: resolved event name plus the raw JSON payload.
/// Shared by all hook adapters (previously duplicated per adapter).
struct HookInput {
    let eventName: String
    let payload: [String: Any]
}

/// Valid signal names — derived from the single registry in SignalDefinition.swift
/// instead of a hand-maintained whitelist.
let SIGNAL_NAMES: Set<String> = Set(SIGNAL_DEFINITIONS.keys)

/// Extract event name from command-line arguments (shared by all hook adapters).
func eventFromArgs(_ argv: [String]) -> String? {
    for (index, value) in argv.enumerated() {
        if (value == "--event" || value == "-e") && index + 1 < argv.count {
            return argv[index + 1]
        }
        if value.hasPrefix("--event=") {
            return String(value.dropFirst("--event=".count))
        }
    }
    // Positional: second argument that doesn't start with '-'.
    if argv.count >= 2 && !argv[1].hasPrefix("-") {
        return argv[1]
    }
    return nil
}

// MARK: - Shared run skeleton

enum HookSupport {
    /// Read all of stdin as UTF-8 text (empty string when unavailable).
    static func readStdinText() -> String {
        String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    /// Shared tail of every hook adapter: persist the signal and print the result.
    /// Persist errors are reported on stderr and yield exit code 1 — never silent.
    @discardableResult
    static func applyAndReport(sessionKey: String, signal: String) -> Int32 {
        do {
            let aggregate = try SessionStore.applySessionSignal(sessionKey: sessionKey, signalName: signal)
            print("Session \(sessionKey): \(signal); aggregate=\(aggregate)")
            return 0
        } catch {
            fputs("glow: \(error)\n", stderr)
            return 1
        }
    }
}
