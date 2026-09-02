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
    /// Pay-as-you-go providers show a remaining balance (currency applies).
    /// Plan providers show usage percentages — no currency setting.
    let balanceBased: Bool
    /// Whether the Base URL field applies at all (fixed-endpoint providers
    /// never read it).
    let usesBaseURL: Bool
    /// The complete base URL this provider uses when the user leaves the
    /// field empty — shown as the field placeholder.
    let defaultBaseURL: String?

    /// Convenience for the common single-token providers.
    static func tokenOnly(
        _ type: String, _ displayName: String, _ tokenPrompt: String,
        balanceBased: Bool = false,
        usesBaseURL: Bool = false,
        defaultBaseURL: String? = nil
    ) -> UsageProviderKind {
        UsageProviderKind(
            type: type, displayName: displayName,
            prompts: [("token", tokenPrompt, true)],
            balanceBased: balanceBased,
            usesBaseURL: usesBaseURL,
            defaultBaseURL: defaultBaseURL
        )
    }
}

/// Registry for add/edit in both UIs. Keys mirror `UsageConfig.explicitProvider`.
enum UsageKinds {
    static let all: [UsageProviderKind] = [
        .tokenOnly("glm", "GLM Coding Plan", "API token", usesBaseURL: true, defaultBaseURL: "https://open.bigmodel.cn"),
        UsageProviderKind(type: "zhipu-team", displayName: "GLM Team Plan", prompts: [
            ("token", "API key", true),
            ("organization_id", "Organization ID", false),
            ("project_id", "Project ID", false),
        ], balanceBased: false, usesBaseURL: false, defaultBaseURL: nil),
        UsageProviderKind(type: "volcengine", displayName: "Volcengine Ark", prompts: [
            ("access_key_id", "AccessKey ID", true),
            ("secret_access_key", "Secret Access Key", true),
        ], balanceBased: false, usesBaseURL: false, defaultBaseURL: nil),
        .tokenOnly("kimi", "Kimi For Coding", "API token"),
        .tokenOnly("minimax", "MiniMax Coding Plan", "API token", usesBaseURL: true, defaultBaseURL: "https://api.minimaxi.com"),
        .tokenOnly("zenmux", "ZenMux", "API token", usesBaseURL: true, defaultBaseURL: "https://zenmux.ai/api/v1/management/subscription/detail"),
        .tokenOnly("opencode-go", "OpenCode Go", "API token"),
        .tokenOnly("deepseek", "DeepSeek", "API key (sk-...)", balanceBased: true),
        .tokenOnly("openrouter", "OpenRouter", "API key (sk-or-...)", balanceBased: true),
        .tokenOnly("siliconflow", "SiliconFlow", "API token", balanceBased: true, usesBaseURL: true, defaultBaseURL: "https://api.siliconflow.cn"),
        .tokenOnly("stepfun", "StepFun", "API token", balanceBased: true),
        UsageProviderKind(type: "anthropic", displayName: "Anthropic Usage", prompts: [
            ("token", "Admin API key (sk-ant-admin...; org admin required)", true),
        ], balanceBased: false, usesBaseURL: false, defaultBaseURL: nil),
        UsageProviderKind(type: "openai", displayName: "OpenAI Usage", prompts: [
            ("token", "Organization admin/owner key", true),
        ], balanceBased: false, usesBaseURL: false, defaultBaseURL: nil),
        UsageProviderKind(type: "new-api", displayName: "New API gateway", prompts: [
            ("token", "System access token", true),
            ("user_id", "User ID (new-api requires the New-Api-User header)", false),
        ], balanceBased: true, usesBaseURL: true, defaultBaseURL: nil),
    ]

    static func kind(forType type: String) -> UsageProviderKind? {
        all.first { $0.type == type.lowercased() }
    }
}
