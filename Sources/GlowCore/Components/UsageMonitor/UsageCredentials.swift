import Foundation

/// Credentials for one usage provider, taken from the explicit config file.
struct UsageProviderConfig {
    /// Stable provider key == `usage.json` key == producer `providerKey`.
    var providerKey: String
    var displayName: String
    /// Override for providers whose endpoint host derives from the account's
    /// coding endpoint (e.g. GLM quota host follows the configured base URL).
    var baseURL: String?
    /// Bearer/Authorization token.
    var token: String
    /// Provider-specific additional credentials: `organization_id` /
    /// `project_id` (GLM team), `access_key_id` / `secret_access_key`
    /// (Volcengine), `user_id` (new-api), etc.
    var extra: [String: String]

    init(
        providerKey: String,
        displayName: String,
        baseURL: String? = nil,
        token: String,
        extra: [String: String] = [:]
    ) {
        self.providerKey = providerKey
        self.displayName = displayName
        self.baseURL = baseURL
        self.token = token
        self.extra = extra
    }
}

/// Resolves which usage providers to poll. Per user decision, **nothing is
/// auto-enabled**: the only source is the explicit config file
/// `~/.config/glow/usage.json`
/// (`{"providers": [{"type": "glm", "token": "...", "base_url": "..."}]}`),
/// edited via the Provider Settings window or `usage-config`.
///
/// Tokens never leave this process except in Authorization headers. Missing
/// file or entries are skipped with a stderr trace — absence of a provider
/// is not an error.
enum UsageConfig {
    /// Effective home: `GLOW_HOME` env override for tests/smoke, else the
    /// user's home. Mirrors `HookInstaller.defaultHome`.
    static var effectiveHome: String {
        ProcessInfo.processInfo.environment["GLOW_HOME"] ?? NSHomeDirectory()
    }

    static func discoverProviders(home: String = UsageConfig.effectiveHome) -> [UsageProviderConfig] {
        discoverExplicitConfig(home: home)
    }

    // MARK: - Explicit config parsing

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
            // Everything beyond the well-known keys is a provider-specific
            // credential (organization_id, project_id, access_key_id, ...);
            // "name" overrides the built-in display name (e.g. call
            // "New API" "DMXAPI").
            let extra = entry.filter { key, _ in
                !["type", "token", "base_url", "name"].contains(key)
            }.compactMapValues { $0 as? String }
            let displayName = (entry["name"] as? String).flatMap {
                $0.isEmpty ? nil : $0
            } ?? name
            configs.append(UsageProviderConfig(
                providerKey: key,
                displayName: displayName,
                baseURL: entry["base_url"] as? String,
                token: token,
                extra: extra
            ))
        }
        return configs
    }

    // MARK: - Provider identification

    static func explicitProvider(forType type: String) -> (key: String, name: String)? {
        switch type.lowercased() {
        case "glm": return ("glm", "GLM Coding Plan")
        case "kimi": return ("kimi", "Kimi For Coding")
        case "minimax": return ("minimax", "MiniMax Coding Plan")
        case "zenmux": return ("zenmux", "ZenMux")
        case "opencode-go", "opencodego": return ("opencode-go", "OpenCode Go")
        case "zhipu-team", "glm-team": return ("zhipu-team", "GLM Team Plan")
        case "volcengine", "ark": return ("volcengine", "Volcengine Ark")
        case "deepseek": return ("deepseek", "DeepSeek")
        case "openrouter": return ("openrouter", "OpenRouter")
        case "siliconflow": return ("siliconflow", "SiliconFlow")
        case "stepfun": return ("stepfun", "StepFun")
        case "new-api", "one-api": return ("new-api", "New API gateway")
        case "anthropic": return ("anthropic", "Anthropic Usage")
        case "openai": return ("openai", "OpenAI Usage")
        default: return nil
        }
    }
}
