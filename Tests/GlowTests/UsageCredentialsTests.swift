import Testing
import Foundation
@testable import GlowCore

/// Credentials discovery runs against a fake home directory (the `home:`
/// parameter is the only reliable injection point on macOS).
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

    // MARK: - Explicit config only (nothing is auto-enabled)

    @Test func missingConfigYieldsNoProviders() {
        #expect(UsageConfig.discoverProviders(home: makeHome()).isEmpty)
    }

    @Test func agentCredentialsAreNeverAutoDiscovered() {
        // Per user decision: agent config files (claude env block, opencode
        // auth.json) must NOT enable providers implicitly.
        let home = makeHome()
        write(
            home + "/.claude/settings.json",
            #"{"env":{"ANTHROPIC_BASE_URL":"https://open.bigmodel.cn/api/anthropic","ANTHROPIC_AUTH_TOKEN":"tok"}}"#
        )
        write(
            home + "/.local/share/opencode/auth.json",
            #"{"zhipuai-coding-plan":{"type":"api","key":"zkey"}}"#
        )
        #expect(UsageConfig.discoverProviders(home: home).isEmpty)
    }

    @Test func explicitConfigEntriesAreParsed() {
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
        #expect(UsageConfig.explicitProvider(forType: "one-api")?.key == "new-api")
    }
}
