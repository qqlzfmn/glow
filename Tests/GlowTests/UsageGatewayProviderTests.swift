import Testing
import Foundation
@testable import GlowCore

/// Fixture tests for the New API / one-api gateway provider. `parse` is a
/// pure function over JSONSerialization output, so every test builds its body
/// in-memory — no network involved.
final class UsageGatewayProviderTests {

    // MARK: - Helpers

    private func json(_ object: Any) throws -> Any {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONSerialization.jsonObject(with: data)
    }

    /// Parsers must throw `unexpectedShape` on malformed bodies instead of
    /// returning an empty array masquerading as success.
    private func expectUnexpectedShape(_ body: Any) {
        #expect(throws: UsageParseError.self) {
            _ = try NewApiUsageProvider.parse(body)
        }
    }

    // MARK: - Normal shape

    @Test func parsesQuotaAndUsedQuotaIntoUSDBalance() throws {
        // 1_000_000 remaining + 500_000 used = 3.0 total, 2.0 left, 1/3 spent.
        let body = try json([
            "success": true,
            "message": "",
            "data": ["id": 1, "username": "tester", "quota": 1_000_000, "used_quota": 500_000],
        ])
        let items = try NewApiUsageProvider.parse(body)
        #expect(items.count == 1)
        #expect(items[0].label == "Balance")
        #expect(items[0].remaining == 2.0)
        #expect(items[0].total == 3.0)
        #expect(items[0].unit == "USD")
        #expect(items[0].used == nil)
        #expect(items[0].resetsAt == nil)
        #expect(abs(items[0].usedPercent! - 100.0 / 3.0) < 1e-9)
    }

    @Test func zeroQuotaYieldsNilUsedPercent() throws {
        // Fresh account: no quota, no usage — usedPercent is not computable.
        let body = try json(["success": true, "data": ["quota": 0, "used_quota": 0]])
        let items = try NewApiUsageProvider.parse(body)
        #expect(items[0].remaining == 0)
        #expect(items[0].total == 0)
        #expect(items[0].usedPercent == nil)
    }

    // MARK: - Tolerance

    @Test func toleratesStringNumbersAndMissingUsedQuota() throws {
        // Some deployments serialize quota fields as strings.
        let stringNumbers = try json([
            "success": true,
            "data": ["quota": "123456", "used_quota": "50000"],
        ])
        let items = try NewApiUsageProvider.parse(stringNumbers)
        #expect(items[0].remaining == 123456.0 / 500_000)
        #expect(items[0].total == 173456.0 / 500_000)
        #expect(items[0].usedPercent! == 50000.0 / 173456.0 * 100)

        // Fresh accounts may omit `used_quota` entirely.
        let noUsedQuota = try json(["success": true, "data": ["quota": 250_000]])
        let fresh = try NewApiUsageProvider.parse(noUsedQuota)
        #expect(fresh[0].remaining == 0.5)
        #expect(fresh[0].total == 0.5)
        #expect(fresh[0].usedPercent == 0)
    }

    // MARK: - Rejected shapes

    @Test func gatewayFailureEnvelopeThrows() throws {
        // Gateways return `success: false` envelopes (often with HTTP 200).
        expectUnexpectedShape(try json([
            "success": false,
            "message": "无权进行此操作，access token 无效",
        ]))
    }

    @Test func missingFieldsThrow() throws {
        expectUnexpectedShape(try json([1, 2, 3])) // array root
        expectUnexpectedShape(try json(["success": true])) // no data
        expectUnexpectedShape(try json(["success": true, "data": ["username": "tester"]])) // no quota
    }
}

