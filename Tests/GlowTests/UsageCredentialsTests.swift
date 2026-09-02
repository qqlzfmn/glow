import Testing
import Foundation
@testable import GlowCore

/// Credentials discovery must run against a fake home: NSHomeDirectory()
/// ignores the HOME env var on macOS, so the `home:` parameter is the only
/// reliable injection point.
@Suite
final class UsageCredentialsTests {

    private func makeHome() -> String {
        let dir = NSTemporaryDirectory() + "/glow-home-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ path: String, _ json: String) {
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try? Data(json.utf8).write(to: URL(fileURLWithPath: path))
    }

    // MARK: - Claude settings.json env

    @Test func claudeEnvBigmodelMapsToGLM() {
        let home = makeHome()
        write(
            home + "/.claude/settings.json",
            #"{"env":{"ANTHROPIC_BASE_URL":"https://open.bigmodel.cn/api/anthropic","ANTHROPIC_AUTH_TOKEN":"tok"}}"#
        )
        let configs = UsageConfig.discoverProviders(home: home)
        #expect(configs.count == 1)
        #expect(configs[0].providerKey == "glm")
        #expect(configs[0].token == "tok")
    }

    @Test func claudeEnvZaiMapsToGLM() {
        let home = makeHome()
        write(
            home + "/.claude/settings.json",
            #"{"env":{"ANTHROPIC_BASE_URL":"https://api.z.ai/api/anthropic","ANTHROPIC_AUTH_TOKEN":"tok"}}"#
        )
        #expect(UsageConfig.discoverProviders(home: home).first?.providerKey == "glm")
    }

    @Test func claudeEnvUnknownRelayIgnored() {
        let home = makeHome()
        write(
            home + "/.claude/settings.json",
            #"{"env":{"ANTHROPIC_BASE_URL":"https://relay.example.com","ANTHROPIC_AUTH_TOKEN":"tok"}}"#
        )
        #expect(UsageConfig.discoverProviders(home: home).isEmpty)
    }

    @Test func claudeEnvWithoutTokenIgnored() {
        let home = makeHome()
        write(
            home + "/.claude/settings.json",
            #"{"env":{"ANTHROPIC_BASE_URL":"https://open.bigmodel.cn/api/anthropic"}}"#
        )
        #expect(UsageConfig.discoverProviders(home: home).isEmpty)
    }

    @Test func allKnownCodingPlanHostsDetected() {
        for (url, key) in [
            ("https://api.kimi.com/coding", "kimi"),
            ("https://api.minimaxi.com", "minimax"),
            ("https://api.minimax.io", "minimax"),
            ("https://zenmux.ai/api/anthropic", "zenmux"),
            ("https://opencode.ai/zen/go/v1", "opencode-go"),
            ("https://api.anthropic.com", "anthropic"),
        ] {
            #expect(UsageConfig.planProvider(forBaseURL: url)?.key == key, "detected key for \(url)")
        }
        // Zen pay-as-you-go deliberately does not match.
        #expect(UsageConfig.planProvider(forBaseURL: "https://opencode.ai/zen/v1") == nil)
    }

    // MARK: - opencode auth.json

    @Test func openCodeZhipuEntryMapsToGLM() {
        let home = makeHome()
        write(home + "/.local/share/opencode/auth.json", #""""#)
        write(
            home + "/.local/share/opencode/auth.json",
            #"{"zhipuai-coding-plan":{"type":"api","key":"zkey"}}"#
        )
        let configs = UsageConfig.discoverProviders(home: home)
        #expect(configs.count == 1)
        #expect(configs[0].providerKey == "glm")
        #expect(configs[0].token == "zkey")
        #expect(configs[0].baseURL == "https://open.bigmodel.cn")
    }

    // MARK: - explicit config

    @Test func explicitConfigWinsOverDiscovery() {
        let home = makeHome()
        write(
            home + "/.claude/settings.json",
            #"{"env":{"ANTHROPIC_BASE_URL":"https://open.bigmodel.cn/api/anthropic","ANTHROPIC_AUTH_TOKEN":"auto"}}"#
        )
        write(
            home + "/.config/glow/usage.json",
            #"{"providers":[{"type":"glm","token":"explicit"}]}"#
        )
        let configs = UsageConfig.discoverProviders(home: home)
        #expect(configs.count == 1)
        #expect(configs[0].token == "explicit")
    }

    @Test func explicitConfigAddsUnknownSources() {
        let home = makeHome()
        write(
            home + "/.config/glow/usage.json",
            #"{"providers":[{"type":"deepseek","token":"sk-1"},{"type":"openrouter","token":"sk-2"}]}"#
        )
        let configs = UsageConfig.discoverProviders(home: home)
        #expect(configs.map { $0.providerKey } == ["deepseek", "openrouter"])
    }

    @Test func explicitConfigEntryWithoutTokenSkipped() {
        let home = makeHome()
        write(
            home + "/.config/glow/usage.json",
            #"{"providers":[{"type":"deepseek"},{"type":"glm","token":"ok"}]}"#
        )
        let configs = UsageConfig.discoverProviders(home: home)
        #expect(configs.map { $0.providerKey } == ["glm"])
    }

    @Test func explicitConfigUnknownTypeSkipped() {
        let home = makeHome()
        write(
            home + "/.config/glow/usage.json",
            #"{"providers":[{"type":"nope","token":"x"}]}"#
        )
        #expect(UsageConfig.discoverProviders(home: home).isEmpty)
    }

    @Test func unknownExplicitTypeNotInFactory() {
        #expect(UsageConfig.explicitProvider(forType: "nope") == nil)
        #expect(UsageConfig.explicitProvider(forType: "OpenCode-Go")?.key == "opencode-go")
    }
}
