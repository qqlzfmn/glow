import Testing
import Foundation
@testable import GlowCore

@Suite
final class UsageBadgeTests {

    private func file(
        _ providers: [(key: String, status: String, item: UsageItem?)],
        order: [String]? = nil
    ) -> UsageFile {
        var dict: [String: ProviderUsage] = [:]
        for entry in providers {
            dict[entry.key] = ProviderUsage(
                displayName: entry.key,
                updatedAt: 0,
                status: entry.status,
                error: entry.status == "error" ? "HTTP 500" : nil,
                items: entry.item.map { [$0] } ?? []
            )
        }
        return UsageFile(
            order: order ?? providers.map { $0.key },
            providers: dict
        )
    }

    // MARK: - badgeText

    @Test func badgeShowsFirstOkProviderInOrder() {
        let usage = file([
            ("deepseek", "error", UsageItem(label: "Balance", remaining: 99)),
            ("glm", "ok", UsageItem(label: "5h window", usedPercent: 42)),
        ])
        #expect(UsageBadge.badgeText(for: usage) == "5h window 42%")
    }

    @Test func badgeSkipsEmptyAndErrorProviders() {
        let usage = file([
            ("glm", "ok", nil),
            ("deepseek", "ok", UsageItem(label: "Balance", remaining: 5, unit: "USD")),
        ])
        #expect(UsageBadge.badgeText(for: usage) == "Balance $5.0")
    }

    @Test func badgeEmptyWhenNoData() {
        #expect(UsageBadge.badgeText(for: UsageFile(order: nil, providers: [:])) == "")
        #expect(UsageBadge.badgeText(for: file([
            ("glm", "error", nil),
        ])) == "")
    }

    @Test func badgeFallsBackToSortedKeysWithoutOrder() {
        var usage = file([
            ("zzz", "ok", UsageItem(label: "5h window", usedPercent: 7)),
            ("aaa", "ok", UsageItem(label: "5h window", usedPercent: 9)),
        ])
        usage.order = nil
        #expect(UsageBadge.badgeText(for: usage) == "5h window 9%")
    }

    // MARK: - itemText

    @Test func itemTextPercentAndBalance() {
        #expect(UsageBadge.itemText(UsageItem(label: "5h window", usedPercent: 42.4)) == "5h window 42%")
        #expect(UsageBadge.itemText(UsageItem(label: "Balance", remaining: 123.4, unit: "CNY")) == "Balance ¥123")
        #expect(UsageBadge.itemText(UsageItem(label: "Balance", remaining: 8.25, unit: "USD")) == "Balance $8.3")
        #expect(UsageBadge.itemText(UsageItem(label: "Tokens", remaining: 1200, unit: "tokens")) == "Tokens 1200 tokens")
        #expect(UsageBadge.itemText(UsageItem(label: "Mystery")) == "Mystery")
    }
}
