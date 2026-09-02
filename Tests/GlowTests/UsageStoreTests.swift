import Testing
import Foundation
@testable import GlowCore

/// UsageStore reads its state dir from the process environment, which is
/// process-global — so these tests must not run concurrently.
@Suite(.serialized)
final class UsageStoreTests {

    private let tmpDir: String

    init() {
        StateDirEnvLock.lock.lock()
        let dir = NSTemporaryDirectory() + "/glow-tests-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        self.tmpDir = dir
        setenv("GLOW_STATE_DIR", dir, 1)
    }

    deinit {
        unsetenv("GLOW_STATE_DIR")
        try? FileManager.default.removeItem(atPath: tmpDir)
        StateDirEnvLock.lock.unlock()
    }


    // MARK: - Roundtrip

    @Test func writeReadRoundtripPreservesOrderAndItems() throws {
        let file = UsageFile(
            order: ["glm", "deepseek"],
            providers: [
                "glm": ProviderUsage(
                    displayName: "GLM Coding Plan",
                    updatedAt: 1730000000,
                    status: "ok",
                    error: nil,
                    items: [UsageItem(label: "5h", usedPercent: 42.5)]
                ),
                "deepseek": ProviderUsage(
                    displayName: "DeepSeek",
                    updatedAt: 1730000001,
                    status: "error",
                    error: "HTTP 401: bad key",
                    items: []
                ),
            ]
        )

        try UsageStore.writeUsage(file)
        let read = UsageStore.readUsage()

        #expect(read.order == ["glm", "deepseek"])
        #expect(read.providers["glm"]?.items.first?.usedPercent == 42.5)
        #expect(read.providers["deepseek"]?.error == "HTTP 401: bad key")
    }

    @Test func jsonContractUsesSnakeCase() throws {
        let file = UsageFile(
            order: ["glm"],
            providers: [
                "glm": ProviderUsage(
                    displayName: "GLM Coding Plan",
                    updatedAt: 42,
                    status: "ok",
                    error: nil,
                    items: [UsageItem(
                        label: "5h",
                        usedPercent: 1,
                        remaining: nil,
                        total: nil,
                        unit: nil,
                        resetsAt: "2026-09-02T10:00:00Z"
                    )]
                )
            ]
        )
        try UsageStore.writeUsage(file)

        let raw = String(
            data: FileManager.default.contents(atPath: UsageStore.usageFile) ?? Data(),
            encoding: .utf8
        ) ?? ""
        #expect(raw.contains("\"updated_at\""))
        #expect(raw.contains("\"resets_at\""))
        #expect(raw.contains("\"used_percent\""))
        #expect(!raw.contains("\"updatedAt\""))
    }

    // MARK: - Tolerant reads

    @Test func missingFileYieldsEmptyState() {
        #expect(UsageStore.readUsage().providers.isEmpty)
    }

    @Test func corruptFileYieldsEmptyStateWithoutThrowing() throws {
        try Data("not json".utf8).write(to: URL(fileURLWithPath: UsageStore.usageFile))
        #expect(UsageStore.readUsage().providers.isEmpty)
    }

    // MARK: - clearUsage

    @Test func clearUsageEmptiesStore() throws {
        try UsageStore.writeUsage(UsageFile(
            order: ["glm"],
            providers: ["glm": ProviderUsage(
                displayName: "GLM", updatedAt: 0, status: "ok", error: nil, items: []
            )]
        ))

        try UsageStore.clearUsage()

        #expect(UsageStore.readUsage().providers.isEmpty)
    }
}
