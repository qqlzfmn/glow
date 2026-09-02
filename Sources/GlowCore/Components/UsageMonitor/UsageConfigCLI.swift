import Foundation

/// `usage-config` CLI — make every supported usage provider visible and
/// configurable without hand-writing JSON. Subcommands:
///
///     usage-config list            show supported types and current config
///     usage-config add [type]      interactive add (prompts for credentials)
///     usage-config remove <type>   remove one explicit entry
///
/// Auto-discovered providers (claude env block, opencode auth.json) are shown
/// in `list` but cannot be edited here — they come from the agent configs.
enum UsageConfigCLI {

    /// One supported provider type and the credential fields it needs.
    struct Kind {
        let type: String
        let displayName: String
        /// Fields prompted in order; the first is always stored as `token`.
        let prompts: [(key: String, prompt: String)]
    }

    /// Registry for `add`. Keys mirror `UsageConfig.explicitProvider`.
    static let kinds: [Kind] = [
        Kind(type: "glm", displayName: "GLM Coding Plan", prompts: [("token", "API token")]),
        Kind(type: "zhipu-team", displayName: "GLM Team Plan", prompts: [
            ("token", "API key"), ("organization_id", "Organization ID"), ("project_id", "Project ID"),
        ]),
        Kind(type: "volcengine", displayName: "Volcengine Ark", prompts: [
            ("access_key_id", "AccessKey ID"), ("secret_access_key", "Secret Access Key"),
        ]),
        Kind(type: "kimi", displayName: "Kimi For Coding", prompts: [("token", "API token")]),
        Kind(type: "minimax", displayName: "MiniMax Coding Plan", prompts: [("token", "API token")]),
        Kind(type: "zenmux", displayName: "ZenMux", prompts: [("token", "API token")]),
        Kind(type: "opencode-go", displayName: "OpenCode Go", prompts: [("token", "API token")]),
        Kind(type: "deepseek", displayName: "DeepSeek", prompts: [("token", "API key (sk-...)")]),
        Kind(type: "openrouter", displayName: "OpenRouter", prompts: [("token", "API key (sk-or-...)")]),
        Kind(type: "siliconflow", displayName: "SiliconFlow", prompts: [("token", "API token")]),
        Kind(type: "stepfun", displayName: "StepFun", prompts: [("token", "API token")]),
        Kind(type: "anthropic", displayName: "Anthropic Usage", prompts: [
            ("token", "Admin API key (sk-ant-admin...; org admin required)"),
        ]),
        Kind(type: "openai", displayName: "OpenAI Usage", prompts: [
            ("token", "Organization admin/owner key"),
        ]),
        Kind(type: "new-api", displayName: "New API gateway", prompts: [
            ("token", "System access token"),
            ("user_id", "User ID (new-api requires the New-Api-User header)"),
        ]),
    ]

    static func run(_ args: [String]) -> Int32 {
        let sub = args.count >= 2 ? args[1] : ""
        switch sub {
        case "list", "":
            return list()
        case "add":
            return add(selected: args.count >= 3 ? args[2] : nil)
        case "remove", "rm":
            guard args.count >= 3 else {
                print("Usage: usage-config remove <type>")
                return 2
            }
            return remove(type: args[2])
        default:
            print("Usage: usage-config [list|add [type]|remove <type>]")
            return 2
        }
    }

    // MARK: - list

    private static func list() -> Int32 {
        let configured = UsageConfigStore.load()
        let configuredKeys = Set(configured.map { $0.providerKey })
        let autoDetected = Set(
            UsageConfig.discoverProviders(home: NSHomeDirectory()).map { $0.providerKey }
        )

        print("Usage providers (configured in \(UsageConfigStore.configFile)):")
        print("")
        for (index, kind) in kinds.enumerated() {
            let key = kind.type
            let state: String
            if configuredKeys.contains(key) {
                state = "configured"
            } else if autoDetected.contains(key) {
                state = "auto-discovered (from agent config)"
            } else {
                state = "not configured"
            }
            print("  \(kind.displayName) [\(kind.type)]: \(state)")
            _ = index
        }
        print("")
        print("Add:    glow usage-config add [type]")
        print("Remove: glow usage-config remove <type>")
        return 0
    }

    // MARK: - add

    private static func add(selected type: String?) -> Int32 {
        let kind: Kind
        if let type {
            guard let resolved = kinds.first(where: { $0.type == type.lowercased() }) else {
                fputs("glow: unknown provider type \(type)\n", stderr)
                return 2
            }
            kind = resolved
        } else {
            print("Select provider type:")
            for (index, candidate) in kinds.enumerated() {
                print("  \(index + 1). \(candidate.displayName) [\(candidate.type)]")
            }
            guard let answer = prompt("Type number or key: "), !answer.isEmpty else {
                print("Aborted.")
                return 0
            }
            let resolved: Kind?
            if let index = Int(answer), index >= 1, index <= kinds.count {
                resolved = kinds[index - 1]
            } else {
                resolved = kinds.first { $0.type == answer.lowercased() }
            }
            guard let chosen = resolved else {
                fputs("glow: unknown provider type \(answer)\n", stderr)
                return 2
            }
            kind = chosen
        }

        var extra: [String: String] = [:]
        var token = ""
        for (index, field) in kind.prompts.enumerated() {
            guard let value = prompt("\(field.prompt): "), !value.isEmpty else {
                print("Aborted.")
                return 0
            }
            if index == 0 {
                token = value  // first prompt is the primary token
            } else {
                extra[field.key] = value
            }
        }
        var baseURL: String?
        if let base = prompt("Base URL (optional, Enter to skip): "), !base.isEmpty {
            baseURL = base
        }

        let config = UsageProviderConfig(
            providerKey: kind.type,
            displayName: kind.displayName,
            baseURL: baseURL,
            token: token,
            extra: extra
        )
        do {
            try UsageConfigStore.upsert(config)
        } catch {
            fputs("glow: cannot write \(UsageConfigStore.configFile): \(error)\n", stderr)
            return 1
        }
        print("Saved \(kind.displayName). It appears in the menu on the next poll.")
        return 0
    }

    // MARK: - remove

    private static func remove(type: String) -> Int32 {
        guard let (key, name) = UsageConfig.explicitProvider(forType: type) else {
            fputs("glow: unknown provider type \(type)\n", stderr)
            return 2
        }
        do {
            if try UsageConfigStore.remove(providerKey: key) {
                print("Removed \(name).")
                return 0
            }
            print("\(name) was not configured in the explicit config.")
            return 0
        } catch {
            fputs("glow: cannot update \(UsageConfigStore.configFile): \(error)\n", stderr)
            return 1
        }
    }

    private static func prompt(_ text: String) -> String? {
        print(text, terminator: "")
        guard let answer = readLine() else { return nil }
        return answer.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
