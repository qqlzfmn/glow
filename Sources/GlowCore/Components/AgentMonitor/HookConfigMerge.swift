import Foundation

/// Pure merge/replace helpers for JSON hook configs (codex / claude-code).
extension HookInstaller {

    static func eventHasExpectedHook(entries: Any, agent: Agent, event: String) -> Bool {
        guard let groups = entries as? [Any] else { return false }
        let expected = agent.hookCommand(for: event)
        let timeout = agent.events[event] ?? 5

        for group in groups {
            guard let groupDict = group as? [String: Any] else { continue }
            // For Claude Code, skip groups with non-empty matcher.
            if agent.usesMatcher,
               let matcher = groupDict["matcher"] as? String,
               !matcher.isEmpty {
                continue
            }
            guard let hooks = groupDict["hooks"] as? [[String: Any]] else { continue }
            for hook in hooks {
                if hook["type"] as? String == "command",
                   hook["command"] as? String == expected,
                   hook["timeout"] as? Int == timeout {
                    return true
                }
            }
        }
        return false
    }

    static func mergeEventGroups(
        existingEntries: Any?, agent: Agent, event: String, timeout: Int
    ) -> [Any] {
        let replacement = hookGroup(agent: agent, event: event, timeout: timeout)
        guard let groups = existingEntries as? [Any] else {
            return [replacement]
        }

        var merged: [Any] = []
        var replaced = false

        for group in groups {
            guard let groupDict = group as? [String: Any] else {
                merged.append(group)
                continue
            }
            let (replacementGroup, cleanedGroup, hadGlowHooks) = replaceGlowHooks(
                group: groupDict, agent: agent, replacement: replacement
            )
            if hadGlowHooks {
                if let rg = replacementGroup { merged.append(rg); replaced = true }
                if let cg = cleanedGroup { merged.append(cg) }
            } else {
                merged.append(group)
            }
        }

        if !replaced {
            merged.append(replacement)
        }

        return merged
    }

    private static func replaceGlowHooks(
        group: [String: Any], agent: Agent, replacement: [String: Any]
    ) -> (replacementGroup: [String: Any]?, cleanedGroup: [String: Any]?, hadGlowHooks: Bool) {
        guard let hooks = group["hooks"] as? [[String: Any]] else {
            return (nil, group, false)
        }

        let replacementHooks = replacement["hooks"] as? [[String: Any]] ?? []
        var updatedHooks: [[String: Any]] = []
        var keptHooks: [[String: Any]] = []
        var replaced = false

        for hook in hooks {
            if hook["type"] as? String == "command",
               isGlowCommand(hook["command"] as? String, agent: agent) {
                if !replaced {
                    updatedHooks.append(contentsOf: replacementHooks)
                    replaced = true
                }
                // Skip old signal light hook.
            } else {
                keptHooks.append(hook)
                updatedHooks.append(hook)
            }
        }

        guard replaced else { return (nil, group, false) }

        var replacementGroup = group
        replacementGroup["hooks"] = updatedHooks
        if let matcher = replacement["matcher"] {
            replacementGroup["matcher"] = matcher
        }

        if keptHooks.isEmpty {
            // All hooks replaced — just one group.
            var pureReplacement = group
            pureReplacement["hooks"] = replacementHooks
            if let matcher = replacement["matcher"] {
                pureReplacement["matcher"] = matcher
            }
            return (pureReplacement, nil, true)
        }

        var cleanedGroup = group
        cleanedGroup["hooks"] = keptHooks
        return (replacementGroup, cleanedGroup, true)
    }

    static func isGlowCommand(_ command: String?, agent: Agent) -> Bool {
        guard let command = command, !command.trimmingCharacters(in: .whitespaces).isEmpty else {
            return false
        }
        let parts = command.components(separatedBy: .whitespaces)
        let joined = parts.filter { !$0.isEmpty }.joined(separator: " ")
        // Current install shape first, then legacy substrings kept for
        // compatibility with hooks installed by the previous app. Finally,
        // token-level compat: any command invoking this CLI's hook subcommands
        // is a Glow entry regardless of the executable's name (covers renamed
        // binaries, e.g. the swiftpm testing helper).
        if joined.contains("Glow codex-hook")
            || joined.contains("Glow claude-code-hook")
            || joined.contains("signal-light codex-hook")
            || joined.contains("signal-light claude-code-hook")
            || joined.contains("SignalLightApp codex-hook")
            || joined.contains("SignalLightApp claude-code-hook") {
            return true
        }
        return parts.contains("codex-hook") || parts.contains("claude-code-hook")
    }

    private static func hookGroup(agent: Agent, event: String, timeout: Int) -> [String: Any] {
        var group: [String: Any] = [
            "hooks": [
                [
                    "type": "command",
                    "command": agent.hookCommand(for: event),
                    "timeout": timeout,
                ] as [String: Any]
            ]
        ]
        if agent.usesMatcher {
            group["matcher"] = ""
        }
        return group
    }
}
