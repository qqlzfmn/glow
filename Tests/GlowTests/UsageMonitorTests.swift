import Testing
import Foundation
@testable import GlowCore

/// UsageMonitor merges producer results into usage.json; failures are
/// recorded per provider, never silent.
@Suite(.serialized)
final class UsageMonitorTests {

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


    // MARK: - Mocks

    private final class MockProducer: UsageProducer {
        let providerKey: String
        let displayName: String
        var result: Result<[UsageItem], Error>

        init(key: String, name: String, result: Result<[UsageItem], Error>) {
            self.providerKey = key
            self.displayName = name
            self.result = result
        }

        func fetch() async throws -> [UsageItem] {
            try result.get()
        }
    }

    // MARK: - pollOnce

    @Test func pollOnceWritesOkAndErrorStates() async throws {
        let ok = MockProducer(key: "glm", name: "GLM", result: .success([
            UsageItem(label: "5h", usedPercent: 12),
        ]))
        let failing = MockProducer(key: "deepseek", name: "DeepSeek", result: .failure(
            UsageHTTPError.httpStatus(401, "auth error")
        ))

        let monitor = UsageMonitor(producers: [ok, failing], pollInterval: 9999)
        await monitor.pollOnce()

        let usage = UsageStore.readUsage()
        #expect(usage.order == ["glm", "deepseek"])
        #expect(usage.providers["glm"]?.status == "ok")
        #expect(usage.providers["glm"]?.items.first?.usedPercent == 12)
        #expect(usage.providers["deepseek"]?.status == "error")
        #expect(usage.providers["deepseek"]?.error == "HTTP 401: auth error")
        #expect(UsageMonitor.describe(UsageHTTPError.badURL("x")) == "bad URL: x")
    }

    @Test func errorKeepsStaleItemsFromPreviousSuccess() async throws {
        let ok = MockProducer(key: "glm", name: "GLM", result: .success([
            UsageItem(label: "5h", usedPercent: 30),
        ]))
        let monitor = UsageMonitor(producers: [ok], pollInterval: 9999)
        await monitor.pollOnce()

        ok.result = .failure(UsageHTTPError.httpStatus(500, "boom"))
        await monitor.pollOnce()

        let glm = UsageStore.readUsage().providers["glm"]
        #expect(glm?.status == "error")
        #expect(glm?.items.first?.usedPercent == 30)
    }

    @Test func menuItemsListProvidersAndRefresh() async throws {
        let ok = MockProducer(key: "glm", name: "GLM Coding Plan", result: .success([
            UsageItem(label: "5h", usedPercent: 42),
        ]))
        let monitor = UsageMonitor(producers: [ok], pollInterval: 9999)
        await monitor.pollOnce()

        let items = monitor.menuItems()
        let titles = items.compactMap { $0.title.isEmpty ? nil : $0.title }
        #expect(titles == ["GLM Coding Plan", "5h 42%", "Refresh Usage"])
        #expect(items.first?.isEnabled == false)
        #expect(items[1].indentationLevel == 1)
    }

    @Test func menuItemsRenderEveryItemOfAProvider() async throws {
        let ok = MockProducer(key: "glm", name: "GLM Coding Plan", result: .success([
            UsageItem(label: "5h", usedPercent: 42),
            UsageItem(label: "1w", usedPercent: 7),
            UsageItem(label: "1m", usedPercent: 0),
        ]))
        let monitor = UsageMonitor(producers: [ok], pollInterval: 9999)
        await monitor.pollOnce()

        let titles = monitor.menuItems().compactMap { $0.title.isEmpty ? nil : $0.title }
        #expect(titles == ["GLM Coding Plan", "5h 42%", "1w 7%", "1m 0%", "Refresh Usage"])
    }

    @Test func emptyProducerListStillWritesEmptySnapshot() async throws {
        // Zero producers is a valid steady state (nothing configured): the
        // loop must keep running so late configuration takes effect, and
        // stale usage.json entries get cleared.
        let monitor = UsageMonitor(producers: [], pollInterval: 9999)
        monitor.start()
        monitor.stop()
        await monitor.pollOnce()
        #expect(UsageStore.readUsage().providers.isEmpty)
        #expect(UsageStore.readUsage().order == [])
    }
}
