import Testing
import Foundation
@testable import GlowCore

/// Fixture tests for the balance-only providers (DeepSeek / OpenRouter /
/// SiliconFlow / StepFun). Parsers are pure functions over JSONSerialization
/// output, so each test builds its body in-memory — no network involved.
final class UsageBalanceProviderTests {

    // MARK: - Helpers

    private func json(_ object: Any) throws -> Any {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONSerialization.jsonObject(with: data)
    }

    /// Parsers must throw `unexpectedShape` on malformed bodies instead of
    /// returning an empty array masquerading as success.
    private func expectUnexpectedShape(_ body: Any, _ parse: (Any) throws -> [UsageItem]) {
        #expect(throws: UsageParseError.self) {
            _ = try parse(body)
        }
    }

    // MARK: - DeepSeek

    @Test func deepSeekParsesEachBalanceInfoEntry() throws {
        let body = try json([
            "is_available": true,
            "balance_infos": [
                ["currency": "CNY", "total_balance": "12.50", "granted_balance": "2.50", "topped_up_balance": "10.00"],
                ["currency": "USD", "total_balance": 3.25, "granted_balance": 0, "topped_up_balance": 3.25],
            ],
        ])
        let items = try DeepSeekUsageProvider.parse(body)
        #expect(items.count == 2)
        #expect(items[0].label == "CNY")
        #expect(items[0].remaining == 12.50)
        #expect(items[0].unit == "CNY")
        #expect(items[0].usedPercent == nil)
        #expect(items[1].label == "USD")
        #expect(items[1].remaining == 3.25)
        #expect(items[1].unit == "USD")
    }

    @Test func deepSeekMissingBalanceInfosThrows() throws {
        expectUnexpectedShape(try json(["is_available": true]), DeepSeekUsageProvider.parse)
        expectUnexpectedShape(
            try json(["balance_infos": [["currency": "CNY"]]]),
            DeepSeekUsageProvider.parse
        )
    }

    // MARK: - OpenRouter

    @Test func openRouterComputesRemainingFromCreditsAndUsage() throws {
        let body = try json(["data": ["total_credits": 10.0, "total_usage": 4.25]])
        let items = try OpenRouterUsageProvider.parse(body)
        #expect(items.count == 1)
        #expect(items[0].label == "Balance")
        #expect(items[0].remaining == 5.75)
        #expect(items[0].total == 10.0)
        #expect(items[0].unit == "USD")
        #expect(items[0].usedPercent == nil)
    }

    @Test func openRouterToleratesStringNumbersAndRejectsWrongShape() throws {
        let body = try json(["data": ["total_credits": "10.00", "total_usage": "4"]])
        let items = try OpenRouterUsageProvider.parse(body)
        #expect(items[0].remaining == 6.0)

        expectUnexpectedShape(try json(["data": ["total_credits": 10.0]]), OpenRouterUsageProvider.parse)
        expectUnexpectedShape(try json([1, 2, 3]), OpenRouterUsageProvider.parse)
    }

    // MARK: - SiliconFlow

    @Test func siliconFlowReadsTotalBalanceWithGivenUnit() throws {
        let body = try json([
            "code": 20000,
            "data": ["balance": "1.00", "chargeBalance": "8.00", "totalBalance": "9.00", "status": "NORMAL"],
        ])
        let cn = try SiliconFlowUsageProvider.parse(body, unit: "CNY")
        #expect(cn[0].label == "Balance")
        #expect(cn[0].remaining == 9.00)
        #expect(cn[0].unit == "CNY")

        let en = try SiliconFlowUsageProvider.parse(body, unit: "USD")
        #expect(en[0].remaining == 9.00)
        #expect(en[0].unit == "USD")
    }

    @Test func siliconFlowMissingDataThrows() throws {
        expectUnexpectedShape(try json(["code": 20000]), SiliconFlowUsageProvider.parse)
        expectUnexpectedShape(
            try json(["data": ["balance": "1.00", "chargeBalance": "8.00"]]),
            SiliconFlowUsageProvider.parse
        )
    }

    // MARK: - StepFun

    @Test func stepFunReadsBalance() throws {
        let body = try json([
            "object": "account",
            "type": "user",
            "balance": "42.75",
            "total_cash_balance": "40.00",
            "total_voucher_balance": "2.75",
        ])
        let items = try StepFunUsageProvider.parse(body)
        #expect(items.count == 1)
        #expect(items[0].label == "Balance")
        #expect(items[0].remaining == 42.75)
        #expect(items[0].unit == "CNY")
        #expect(items[0].total == nil)
        #expect(items[0].usedPercent == nil)
    }

    @Test func stepFunMissingBalanceThrows() throws {
        expectUnexpectedShape(
            try json(["object": "account", "total_cash_balance": "40.00"]),
            StepFunUsageProvider.parse
        )
        expectUnexpectedShape(try json([1, 2, 3]), StepFunUsageProvider.parse)
    }
}
