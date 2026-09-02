import Foundation

/// One supported usage-provider type and the credential fields it needs.
/// Shared by the `usage-config` CLI and the Provider Settings window so both
/// render identical field sets.
struct UsageProviderKind {
    /// Config "type" value == `UsageProviderConfig.providerKey`.
    let type: String
    let displayName: String
    /// Fields prompted in order. The first is always stored as `token`;
    /// the rest land in `UsageProviderConfig.extra`. `secret` fields render
    /// as secure text in the GUI.
    let prompts: [(key: String, prompt: String, secret: Bool)]

    /// Convenience for the common single-token providers.
    static func tokenOnly(_ type: String, _ displayName: String, _ tokenPrompt: String) -> UsageProviderKind {
        UsageProviderKind(type: type, displayName: displayName, prompts: [
            ("token", tokenPrompt, true),
        ])
    }
}

/// Registry for add/edit in both UIs. Keys mirror `UsageConfig.explicitProvider`.
enum UsageKinds {
    static let all: [UsageProviderKind] = [
        .tokenOnly("glm", "GLM Coding Plan", "API token"),
        UsageProviderKind(type: "zhipu-team", displayName: "GLM Team Plan", prompts: [
            ("token", "API key", true),
            ("organization_id", "Organization ID", false),
            ("project_id", "Project ID", false),
        ]),
        UsageProviderKind(type: "volcengine", displayName: "Volcengine Ark", prompts: [
            ("access_key_id", "AccessKey ID", true),
            ("secret_access_key", "Secret Access Key", true),
        ]),
        .tokenOnly("kimi", "Kimi For Coding", "API token"),
        .tokenOnly("minimax", "MiniMax Coding Plan", "API token"),
        .tokenOnly("zenmux", "ZenMux", "API token"),
        .tokenOnly("opencode-go", "OpenCode Go", "API token"),
        .tokenOnly("deepseek", "DeepSeek", "API key (sk-...)"),
        .tokenOnly("openrouter", "OpenRouter", "API key (sk-or-...)"),
        .tokenOnly("siliconflow", "SiliconFlow", "API token"),
        .tokenOnly("stepfun", "StepFun", "API token"),
        UsageProviderKind(type: "anthropic", displayName: "Anthropic Usage", prompts: [
            ("token", "Admin API key (sk-ant-admin...; org admin required)", true),
        ]),
        UsageProviderKind(type: "openai", displayName: "OpenAI Usage", prompts: [
            ("token", "Organization admin/owner key", true),
        ]),
        UsageProviderKind(type: "new-api", displayName: "New API gateway", prompts: [
            ("token", "System access token", true),
            ("user_id", "User ID (new-api requires the New-Api-User header)", false),
        ]),
    ]

    static func kind(forType type: String) -> UsageProviderKind? {
        all.first { $0.type == type.lowercased() }
    }
}
