import Testing
import Foundation
@testable import GlowCore

@Suite
final class UsageKindsTests {

    @Test func registryCoversAllExplicitTypes() {
        let kindTypes = Set(UsageKinds.all.map { $0.type })
        // Every type the explicit-config parser accepts must have a kind
        // entry, otherwise a configured provider would render no form.
        let parserTypes = Set([
            "glm", "kimi", "minimax", "zenmux", "opencode-go", "zhipu-team",
            "volcengine", "deepseek", "openrouter", "siliconflow", "stepfun",
            "anthropic", "openai", "new-api",
        ])
        #expect(kindTypes == parserTypes)
    }

    @Test func everyKindHasACredentialPrompt() {
        for kind in UsageKinds.all {
            // Volcengine's first credential is the AccessKey ID (stored in
            // the token slot); every other kind starts with the token.
            let firstKey = kind.prompts.first?.key
            #expect(firstKey == "token" || (kind.type == "volcengine" && firstKey == "access_key_id"), "first prompt for \(kind.type)")
        }
    }

    @Test func kindLookupIsCaseInsensitive() {
        #expect(UsageKinds.kind(forType: "GLM")?.type == "glm")
        #expect(UsageKinds.kind(forType: "nope") == nil)
    }
}

@Suite
final class ProviderRowStateTests {

    private let kinds = UsageKinds.all

    private func config(_ key: String, token: String = "tok") -> UsageProviderConfig {
        UsageProviderConfig(providerKey: key, displayName: key, token: token)
    }

    private func snapshot(_ key: String, percent: Double) -> ProviderUsage {
        ProviderUsage(
            displayName: key,
            updatedAt: 0,
            status: "ok",
            error: nil,
            items: [UsageItem(label: "5h", usedPercent: percent)]
        )
    }

    @Test func resolveProducesTwoStates() {
        let rows = ProviderSettingsPane.RowState.resolve(
            kinds: kinds,
            explicit: [config("deepseek")],
            snapshots: ["glm": snapshot("glm", percent: 5)]
        )
        let stateOf = { key in rows.first { $0.kind.type == key }?.state }
        #expect(stateOf("deepseek") == .configured)
        #expect(stateOf("openrouter") == .notConfigured)
        // No provider is ever auto-configured.
        #expect(stateOf("glm") == .notConfigured)
    }

    @Test func configuredRowPrefillsExplicitValues() {
        let rows = ProviderSettingsPane.RowState.resolve(
            kinds: kinds,
            explicit: [config("glm", token: "explicit-tok")],
            snapshots: [:]
        )
        let glm = rows.first { $0.kind.type == "glm" }
        #expect(glm?.state == .configured)
        #expect(glm?.activeConfig?.token == "explicit-tok")
    }

    @Test func snapshotAttachesToMatchingKind() {
        let rows = ProviderSettingsPane.RowState.resolve(
            kinds: kinds,
            explicit: [],
            snapshots: ["glm": snapshot("glm", percent: 7)]
        )
        #expect(rows.first { $0.kind.type == "glm" }?.snapshot?.items.first?.usedPercent == 7)
        #expect(rows.first { $0.kind.type == "kimi" }?.snapshot == nil)
    }
}

@Suite
final class UsageConfigStoreTests {

    private var tmpHome: String {
        NSTemporaryDirectory() + "/glow-store-\(UUID().uuidString)"
    }

    @Test func saveLoadRoundtripPreservesExtraAndBaseURL() throws {
        let home = tmpHome
        let config = UsageProviderConfig(
            providerKey: "zhipu-team",
            displayName: "GLM Team Plan",
            baseURL: "https://open.bigmodel.cn",
            token: "tok",
            extra: ["organization_id": "org1", "project_id": "proj1"]
        )
        try UsageConfigStore.upsert(config, home: home)

        let loaded = UsageConfigStore.load(home: home)
        #expect(loaded.count == 1)
        #expect(loaded[0].providerKey == "zhipu-team")
        #expect(loaded[0].token == "tok")
        #expect(loaded[0].baseURL == "https://open.bigmodel.cn")
        #expect(loaded[0].extra["organization_id"] == "org1")
        #expect(loaded[0].extra["project_id"] == "proj1")
    }

    @Test func savedFileHasRestrictedPermissions() throws {
        let home = tmpHome
        try UsageConfigStore.upsert(
            UsageProviderConfig(providerKey: "glm", displayName: "GLM", token: "t"),
            home: home
        )
        let attrs = try FileManager.default.attributesOfItem(
            atPath: UsageConfigStore.configFile(home: home)
        )
        #expect((attrs[.posixPermissions] as? NSNumber) == 0o600)
    }

    @Test func upsertReplacesByKeyAndRemoveReportsMissing() throws {
        let home = tmpHome
        try UsageConfigStore.upsert(
            UsageProviderConfig(providerKey: "glm", displayName: "GLM", token: "old"),
            home: home
        )
        try UsageConfigStore.upsert(
            UsageProviderConfig(providerKey: "glm", displayName: "GLM", token: "new"),
            home: home
        )
        #expect(UsageConfigStore.load(home: home).first?.token == "new")

        #expect(try UsageConfigStore.remove(providerKey: "glm", home: home) == true)
        #expect(try UsageConfigStore.remove(providerKey: "glm", home: home) == false)
        #expect(UsageConfigStore.load(home: home).isEmpty)
    }

    @Test func ensureConfigFileCreatesEmptyDoc() throws {
        let home = tmpHome
        let path = UsageConfigStore.ensureConfigFile(home: home)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(UsageConfigStore.load(home: home).isEmpty)
    }
}
