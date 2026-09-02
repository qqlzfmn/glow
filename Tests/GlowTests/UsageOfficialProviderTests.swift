import Testing
import Foundation
@testable import GlowCore

/// Fixture tests for the Anthropic and OpenAI official usage parsers.
/// Fixtures are built in-test with JSONSerialization so payloads round-trip
/// exactly like real API responses (numbers arrive as NSNumber).
final class UsageOfficialProviderTests {

    // MARK: - Helpers

    /// Serialize and re-parse so the parser sees real JSON types.
    private func roundTrip(_ object: [String: Any]) throws -> Any {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONSerialization.jsonObject(with: data)
    }

    private func anthropicResult(
        uncached: Any, output: Any, cacheRead: Any,
        cache5m: Any? = 0, cache1h: Any? = 0
    ) -> [String: Any] {
        var result: [String: Any] = [
            "uncached_input_tokens": uncached,
            "output_tokens": output,
            "cache_read_input_tokens": cacheRead,
            "model": NSNull(),
        ]
        if let cache5m, let cache1h {
            result["cache_creation"] = [
                "ephemeral_5m_input_tokens": cache5m,
                "ephemeral_1h_input_tokens": cache1h,
            ]
        }
        return result
    }

    // MARK: - Anthropic

    @Test func anthropicSumsTokensAcrossBuckets() throws {
        let body = try roundTrip([
            "data": [
                [
                    "starting_at": "2026-09-01T00:00:00Z",
                    "ending_at": "2026-09-02T00:00:00Z",
                    "results": [
                        anthropicResult(uncached: 1500, output: 500, cacheRead: 200, cache5m: 500, cache1h: 1000),
                        anthropicResult(uncached: "100", output: "50", cacheRead: 0, cache5m: 0, cache1h: 0),
                    ],
                ],
                [
                    "starting_at": "2026-08-31T00:00:00Z",
                    "ending_at": "2026-09-01T00:00:00Z",
                    "results": [
                        anthropicResult(uncached: 400, output: 250, cacheRead: 60, cache5m: 40, cache1h: 0),
                    ],
                ],
            ],
            "has_more": false,
            "next_page": NSNull(),
        ])

        let items = try AnthropicUsageProvider.parse(body)
        #expect(items.count == 1)
        let item = items[0]
        #expect(item.label == "1d")
        #expect(item.unit == "tokens")
        #expect(item.usedPercent == nil)
        #expect(item.resetsAt == nil)
        // Output: 500 + 50 + 250.
        #expect(item.remaining == 800)
        // Input+cache: (1500+200+500+1000) + (100+0) + (400+60+40+0).
        #expect(item.total == 3800)
    }

    @Test func anthropicSkipsEntriesMissingCoreCounts() throws {
        let body = try roundTrip([
            "data": [
                [
                    "starting_at": "2026-09-01T00:00:00Z",
                    "ending_at": "2026-09-02T00:00:00Z",
                    "results": [
                        ["model": "claude-opus-5"], // no token counts: skipped
                        anthropicResult(uncached: 10, output: 20, cacheRead: 5),
                        // No cache_creation block at all: treated as zero cache creation.
                    ],
                ],
            ],
        ])

        let items = try AnthropicUsageProvider.parse(body)
        #expect(items.count == 1)
        #expect(items[0].remaining == 20)
        #expect(items[0].total == 15)
    }

    @Test func anthropicThrowsOnUnexpectedShape() {
        #expect(throws: UsageParseError.self) {
            try AnthropicUsageProvider.parse(["error": ["type": "not_found_error", "message": "nope"]])
        }
        #expect(throws: UsageParseError.self) {
            try AnthropicUsageProvider.parse(["data": "not-an-array"])
        }
    }

    // MARK: - OpenAI

    @Test func openAISumsTokensAcrossBuckets() throws {
        let body = try roundTrip([
            "object": "page",
            "data": [
                [
                    "object": "bucket",
                    "start_time": 1788300000,
                    "end_time": 1788386400,
                    "results": [
                        [
                            "input_tokens": 1000, // includes cached + cache-write per spec
                            "input_cached_tokens": 400,
                            "output_tokens": 500,
                            "num_model_requests": 2,
                            "model": NSNull(),
                        ],
                        [
                            "input_tokens": "300",
                            "input_cached_tokens": 0,
                            "output_tokens": "150",
                            "num_model_requests": 1,
                            "model": "gpt-4o",
                        ],
                    ],
                ],
                [
                    "object": "bucket",
                    "start_time": 1788386400,
                    "end_time": 1788472800,
                    "results": [
                        [
                            "input_tokens": 700,
                            "output_tokens": 350,
                            "num_model_requests": 1,
                            "model": NSNull(),
                        ],
                    ],
                ],
            ],
            "has_more": false,
            "next_page": NSNull(),
        ])

        let items = try OpenAIUsageProvider.parse(body)
        #expect(items.count == 1)
        let item = items[0]
        #expect(item.label == "1d")
        #expect(item.unit == "tokens")
        #expect(item.usedPercent == nil)
        #expect(item.resetsAt == nil)
        // Output: 500 + 150 + 350.
        #expect(item.remaining == 1000)
        // Input (cached included): 1000 + 300 + 700.
        #expect(item.total == 2000)
    }

    @Test func openAISkipsEntriesMissingCoreCounts() throws {
        let body = try roundTrip([
            "object": "page",
            "data": [
                [
                    "object": "bucket",
                    "start_time": 1788300000,
                    "end_time": 1788386400,
                    "results": [
                        ["num_model_requests": 3], // no token counts: skipped
                        ["input_tokens": 10, "output_tokens": 30],
                    ],
                ],
            ],
        ])

        let items = try OpenAIUsageProvider.parse(body)
        #expect(items.count == 1)
        #expect(items[0].remaining == 30)
        #expect(items[0].total == 10)
    }

    @Test func openAIThrowsOnUnexpectedShape() {
        #expect(throws: UsageParseError.self) {
            try OpenAIUsageProvider.parse(["detail": "Invalid endpoint or API key."])
        }
        #expect(throws: UsageParseError.self) {
            try OpenAIUsageProvider.parse(["data": "not-an-array"])
        }
    }
}
