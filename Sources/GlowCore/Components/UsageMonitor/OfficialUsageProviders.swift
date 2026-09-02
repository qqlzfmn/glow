import Foundation

// Official provider usage parsers: Anthropic Usage/Cost Admin API and the
// OpenAI Usage API. Both report org-level token counts per time bucket, so
// both produce the same single "1d" item:
//   - `remaining` carries output tokens (the "remaining" quota slot is not
//     meaningful for these endpoints; kept simple by contract).
//   - `total` carries input+cache tokens.
// Parsing is pure and fixture-testable; shape failures must throw rather
// than fake an empty success.

/// Shared defensive helpers for the official provider parsers below.
private enum OfficialUsage {
    /// Coerce a JSONSerialization value into a number. Tolerates NSNumber
    /// (Int/Double payloads) and numeric strings; anything else is missing.
    static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber:
            return n.doubleValue
        case let s as String:
            return Double(s)
        default:
            return nil
        }
    }

    /// Build the single display item from window token totals.
    static func tokenItem(output: Double, input: Double) -> [UsageItem] {
        [UsageItem(
            label: "1d",
            usedPercent: nil,
            remaining: output,
            total: input,
            unit: "tokens",
            resetsAt: nil
        )]
    }

    /// Window end snapped to the current UTC hour, start exactly 24h earlier.
    static func last24Hours() -> (start: Date, end: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let end = calendar.dateInterval(of: .hour, for: Date())!.start
        return (end.addingTimeInterval(-24 * 3600), end)
    }
}

/// Anthropic Usage Admin API. Requires an admin API key (`sk-ant-admin01-...`);
/// ordinary workspace keys get a 401, which is surfaced as-is by `UsageHTTP`.
final class AnthropicUsageProvider: UsageProducer {
    let providerKey = "anthropic"
    var displayName: String { config.displayName }

    /// Current recommended API version per platform.claude.com docs.
    private static let apiVersion = "2023-06-01"

    private let config: UsageProviderConfig

    init(config: UsageProviderConfig) {
        self.config = config
    }

    func fetch() async throws -> [UsageItem] {
        let window = OfficialUsage.last24Hours()
        var components = URLComponents(string: "https://api.anthropic.com/v1/organizations/usage_report/messages")!
        components.queryItems = [
            URLQueryItem(name: "starting_at", value: AnthropicUsageProvider.iso8601(window.start)),
            URLQueryItem(name: "ending_at", value: AnthropicUsageProvider.iso8601(window.end)),
            URLQueryItem(name: "bucket_width", value: "1d"),
        ]
        let response = try await UsageHTTP.getJSON(
            components.url!.absoluteString,
            headers: [
                "x-api-key": config.token,
                "anthropic-version": Self.apiVersion,
            ]
        )
        return try Self.parse(response.body)
    }

    /// Sum token counts across all buckets/results of a usage report.
    /// Response shape (admin docs): `{data: [{starting_at, ending_at,
    /// results: [{uncached_input_tokens, output_tokens, cache_read_input_tokens,
    /// cache_creation: {ephemeral_5m_input_tokens, ephemeral_1h_input_tokens}}]}]}`.
    /// Results missing the core counts are skipped; an unrecognizable document
    /// throws instead of faking zero usage.
    static func parse(_ body: Any) throws -> [UsageItem] {
        guard let document = body as? [String: Any], let buckets = document["data"] as? [Any] else {
            throw UsageParseError.unexpectedShape("anthropic usage report: expected {data: [...]}")
        }
        var output = 0.0
        var input = 0.0
        for bucket in buckets {
            guard let bucket = bucket as? [String: Any], let results = bucket["results"] as? [Any] else {
                continue
            }
            for result in results {
                guard let result = result as? [String: Any],
                      let out = number(result["output_tokens"]),
                      let uncached = number(result["uncached_input_tokens"]) else {
                    continue
                }
                output += out
                input += uncached
                    + (number(result["cache_read_input_tokens"]) ?? 0)
                    + cacheCreationTokens(result["cache_creation"])
            }
        }
        return OfficialUsage.tokenItem(output: output, input: input)
    }

    private static func number(_ value: Any?) -> Double? {
        OfficialUsage.number(value)
    }

    /// Cache-creation block contributes 5m + 1h ephemeral token counts.
    private static func cacheCreationTokens(_ value: Any?) -> Double {
        guard let creation = value as? [String: Any] else { return 0 }
        return (number(creation["ephemeral_5m_input_tokens"]) ?? 0)
            + (number(creation["ephemeral_1h_input_tokens"]) ?? 0)
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: date)
    }
}

/// OpenAI Usage API (`/v1/organization/usage/completions`). Requires an
/// organization admin/owner key; non-admin keys get a 403, surfaced as-is.
final class OpenAIUsageProvider: UsageProducer {
    let providerKey = "openai"
    var displayName: String { config.displayName }

    private let config: UsageProviderConfig

    init(config: UsageProviderConfig) {
        self.config = config
    }

    func fetch() async throws -> [UsageItem] {
        let window = OfficialUsage.last24Hours()
        var components = URLComponents(string: "https://api.openai.com/v1/organization/usage/completions")!
        components.queryItems = [
            URLQueryItem(name: "start_time", value: String(Int(window.start.timeIntervalSince1970))),
            URLQueryItem(name: "end_time", value: String(Int(window.end.timeIntervalSince1970))),
            URLQueryItem(name: "bucket_width", value: "1d"),
        ]
        let response = try await UsageHTTP.getJSON(
            components.url!.absoluteString,
            headers: ["Authorization": "Bearer \(config.token)"]
        )
        return try Self.parse(response.body)
    }

    /// Sum token counts across all buckets/results of a usage report.
    /// Response shape (cookbook + openai-node): `{data: [{start_time, end_time,
    /// results: [{input_tokens, output_tokens, input_cached_tokens, ...}]}]}`.
    /// Note `input_tokens` already includes cached and cache-write tokens, so
    /// it maps straight onto the item's `total`. Results missing either count
    /// are skipped; an unrecognizable document throws.
    static func parse(_ body: Any) throws -> [UsageItem] {
        guard let document = body as? [String: Any], let buckets = document["data"] as? [Any] else {
            throw UsageParseError.unexpectedShape("openai usage report: expected {data: [...]}")
        }
        var output = 0.0
        var input = 0.0
        for bucket in buckets {
            guard let bucket = bucket as? [String: Any], let results = bucket["results"] as? [Any] else {
                continue
            }
            for result in results {
                guard let result = result as? [String: Any],
                      let inTokens = number(result["input_tokens"]),
                      let out = number(result["output_tokens"]) else {
                    continue
                }
                input += inTokens
                output += out
            }
        }
        return OfficialUsage.tokenItem(output: output, input: input)
    }

    private static func number(_ value: Any?) -> Double? {
        OfficialUsage.number(value)
    }
}
