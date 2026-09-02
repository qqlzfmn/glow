import Foundation

/// Credentials for one usage provider, resolved from auto-discovery or the
/// explicit config file.
struct UsageProviderConfig {
    /// Stable provider key == `usage.json` key == producer `providerKey`.
    var providerKey: String
    var displayName: String
    /// Override for providers whose endpoint host derives from the account's
    /// coding endpoint (e.g. GLM quota host follows the configured base URL).
    var baseURL: String?
    /// Bearer/Authorization token.
    var token: String
}

/// Resolves which usage providers to poll and with which credentials.
///
/// Sources, later wins on duplicate provider key:
/// 1. `~/.claude/settings.json` `env` block — `ANTHROPIC_BASE_URL` /
///    `ANTHROPIC_AUTH_TOKEN` identify the coding-plan host the user already
///    runs agents against (GLM, Kimi, MiniMax, ZenMux, OpenCode Go, Anthropic).
/// 2. `~/.local/share/opencode/auth.json` — per-provider credential entries.
/// 3. `~/.config/glow/usage.json` — explicit Glow config, always wins:
///    `{"providers": [{"type": "glm", "token": "...", "base_url": "..."}]}`.
///
/// Tokens never leave this process except in Authorization headers; config
/// files are read-only here. Missing sources are skipped silently — absence
/// of a provider is not an error.
enum UsageConfig {
    static func discoverProviders(home: String = NSHomeDirectory()) -> [UsageProviderConfig] {
        var byKey: [String: UsageProviderConfig] = [:]
        var order: [String] = []

        func merge(_ config: UsageProviderConfig) {
            if byKey[config.providerKey] == nil {
                order.append(config.providerKey)
            }
            byKey[config.providerKey] = config
        }

        if let claude = discoverClaudeEnv(home: home) {
            merge(claude)
        }
        for config in discoverOpenCode(home: home) {
            merge(config)
        }
        for config in discoverExplicitConfig(home: home) {
            merge(config)
        }

        return order.compactMap { byKey[$0] }
    }

    // MARK: - Source 1: ~/.claude/settings.json env block

    static func discoverClaudeEnv(home: String) -> UsageProviderConfig? {
        let path = (home as NSString).appendingPathComponent(".claude/settings.json")
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = json["env"] as? [String: Any] else {
            return nil
        }
        guard let base = env["ANTHROPIC_BASE_URL"] as? String, !base.isEmpty,
              let token = env["ANTHROPIC_AUTH_TOKEN"] as? String, !token.isEmpty else {
            return nil
        }
        guard let plan = planProvider(forBaseURL: base) else {
            // Unknown relay host: no quota API we can talk to; not an error.
            return nil
        }
        return UsageProviderConfig(
            providerKey: plan.key,
            displayName: plan.name,
            baseURL: base,
            token: token
        )
    }

    // MARK: - Source 2: ~/.local/share/opencode/auth.json

    static func discoverOpenCode(home: String) -> [UsageProviderConfig] {
        let path = (home as NSString)
            .appendingPathComponent(".local/share/opencode/auth.json")
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        var configs: [UsageProviderConfig] = []
        // Only provider ids with a known usage API are recognized.
        if let entry = json["zhipuai-coding-plan"] as? [String: Any],
           let key = entry["key"] as? String, !key.isEmpty {
            configs.append(UsageProviderConfig(
                providerKey: "glm",
                displayName: "GLM Coding Plan",
                baseURL: "https://open.bigmodel.cn",
                token: key
            ))
        }
        return configs
    }

    // MARK: - Source 3: ~/.config/glow/usage.json

    static func discoverExplicitConfig(home: String) -> [UsageProviderConfig] {
        let path = (home as NSString).appendingPathComponent(".config/glow/usage.json")
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = json["providers"] as? [[String: Any]] else {
            return []
        }
        var configs: [UsageProviderConfig] = []
        for entry in providers {
            guard let type = entry["type"] as? String,
                  let token = entry["token"] as? String, !token.isEmpty,
                  let (key, name) = explicitProvider(forType: type) else {
                let raw = String(data: data, encoding: .utf8) ?? ""
                fputs(
                    "glow: usage.json entry skipped (needs known \"type\" and non-empty \"token\")"
                        + " in: \(raw.prefix(120))\n",
                    stderr
                )
                continue
            }
            configs.append(UsageProviderConfig(
                providerKey: key,
                displayName: name,
                baseURL: entry["base_url"] as? String,
                token: token
            ))
        }
        return configs
    }

    // MARK: - Provider identification

    /// Map a coding endpoint base URL to its plan quota provider, mirroring
    /// cc-switch's `detect_provider` (same host families, same caveats).
    static func planProvider(forBaseURL url: String) -> (key: String, name: String)? {
        let lowered = url.lowercased()
        if lowered.contains("api.kimi.com/coding") {
            return ("kimi", "Kimi For Coding")
        }
        if lowered.contains("bigmodel.cn") {
            return ("glm", "GLM Coding Plan")
        }
        if lowered.contains("api.z.ai") {
            return ("glm", "GLM Coding Plan")
        }
        if lowered.contains("api.minimaxi.com") || lowered.contains("api.minimax.io") {
            return ("minimax", "MiniMax Coding Plan")
        }
        if lowered.contains("zenmux") {
            return ("zenmux", "ZenMux")
        }
        if lowered.contains("opencode.ai/zen/go") {
            // Zen pay-as-you-go (`/zen/v1`) deliberately does not match: it
            // has no usage API (verified 404 upstream).
            return ("opencode-go", "OpenCode Go")
        }
        if lowered.contains("api.anthropic.com") {
            return ("anthropic", "Anthropic Usage")
        }
        return nil
    }

    static func explicitProvider(forType type: String) -> (key: String, name: String)? {
        switch type.lowercased() {
        case "glm": return ("glm", "GLM Coding Plan")
        case "kimi": return ("kimi", "Kimi For Coding")
        case "minimax": return ("minimax", "MiniMax Coding Plan")
        case "zenmux": return ("zenmux", "ZenMux")
        case "opencode-go", "opencodego": return ("opencode-go", "OpenCode Go")
        case "deepseek": return ("deepseek", "DeepSeek")
        case "openrouter": return ("openrouter", "OpenRouter")
        case "siliconflow": return ("siliconflow", "SiliconFlow")
        case "stepfun": return ("stepfun", "StepFun")
        case "anthropic": return ("anthropic", "Anthropic Usage")
        case "openai": return ("openai", "OpenAI Usage")
        default: return nil
        }
    }
}
