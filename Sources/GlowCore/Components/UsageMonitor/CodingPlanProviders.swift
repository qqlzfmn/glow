import Foundation

// MARK: - Shared parsing helpers

/// Coding-plan quota parsers (GLM / Kimi / MiniMax / ZenMux / OpenCode Go).
/// Each wraps one `GET` quota endpoint and reports per-window percentage
/// items. Endpoints, request headers, and response shapes mirror cc-switch's
/// `coding_plan.rs`, the single source of truth — header details matter
/// (GLM sends a raw token without the `Bearer` prefix; everyone else uses
/// `Bearer`).

/// Tolerant numeric reader: accepts JSON numbers and numeric strings
/// (some providers serialize percentages as `"42"`), mirroring cc-switch's
/// `parse_f64`.
private func parseF64(_ any: Any?) -> Double? {
    switch any {
    case let n as Double: return n.isFinite ? n : nil
    case let n as Int: return Double(n)
    case let s as String: return Double(s)
    default: return nil
    }
}

/// Tolerant integer reader for timestamps and status enums.
private func asInt(_ any: Any?) -> Int? {
    switch any {
    case let n as Int: return n
    case let n as Double where n == n.rounded(): return Int(n)
    case let s as String: return Int(s)
    default: return nil
    }
}

/// Defense-cast of a JSONSerialization value to a string-keyed object.
private func asObject(_ any: Any?) -> [String: Any]? {
    any as? [String: Any]
}

private let iso8601Formatter = ISO8601DateFormatter()

private func iso8601(fromMillis ms: Int) -> String {
    iso8601Formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
}

/// Reset-time extraction tolerant of both shapes cc-switch's
/// `extract_reset_time` handles: a string passes through as-is (ISO 8601);
/// a number is auto-detected as seconds (< 1e12) or milliseconds and
/// converted. Non-positive timestamps mean "no reset".
private func extractResetTime(_ any: Any?) -> String? {
    if let text = any as? String, !text.isEmpty {
        return text
    }
    guard let timestamp = asInt(any), timestamp > 0 else { return nil }
    let millis = timestamp < 1_000_000_000_000 ? timestamp * 1000 : timestamp
    return iso8601(fromMillis: millis)
}

// MARK: - GLM (Zhipu)

final class GLMUsageProvider: UsageProducer {
    let providerKey = "glm"
    var displayName: String { config.displayName }
    private let config: UsageProviderConfig

    init(config: UsageProviderConfig) {
        self.config = config
    }

    func fetch() async throws -> [UsageItem] {
        let response = try await UsageHTTP.getJSON(
            Self.quotaURL(baseURL: config.baseURL),
            headers: [
                // Zhipu authenticates with the raw token — no Bearer prefix.
                "Authorization": config.token,
                "Content-Type": "application/json",
                "Accept-Language": "en-US,en",
            ]
        )
        return try Self.parse(response.body)
    }

    /// Quota host routing mirrors cc-switch's `zhipu_quota_base`: the quota
    /// endpoint lives on the same host family as the coding endpoint, so a
    /// `bigmodel.cn` base URL routes to the domestic site and any other
    /// configured host routes to the z.ai international site. Missing
    /// configuration falls back to the domestic site.
    static func quotaURL(baseURL: String?) -> String {
        let lowered = (baseURL ?? "").lowercased()
        let base = lowered.contains("bigmodel.cn") || lowered.isEmpty
            ? "https://open.bigmodel.cn"
            : "https://api.z.ai"
        return base + "/api/monitor/usage/quota/limit"
    }

    /// One classified `TOKENS_LIMIT` entry.
    private struct Entry {
        let resetMs: Int?
        let percentage: Double
        let resetsAt: String?

        init(_ limit: [String: Any]) {
            self.resetMs = asInt(limit["nextResetTime"])
            self.percentage = parseF64(limit["percentage"]) ?? 0.0
            self.resetsAt = resetMs.map(iso8601(fromMillis:))
        }
    }

    private enum Window {
        case fiveHour
        case weekly
        case unknown
    }

    /// Pure parsing, fixture-testable. Business-level failure (`success ==
    /// false`) and a missing `data.limits` array both throw rather than
    /// masquerade as an empty success.
    static func parse(_ body: Any) throws -> [UsageItem] {
        guard let root = asObject(body) else {
            throw UsageParseError.unexpectedShape("glm: body is not a JSON object")
        }
        if root["success"] as? Bool == false {
            let msg = root["msg"] as? String ?? "Unknown error"
            throw UsageParseError.unexpectedShape("glm: API error: \(msg)")
        }
        guard let data = asObject(root["data"]),
              let limits = data["limits"] as? [[String: Any]] else {
            throw UsageParseError.unexpectedShape("glm: missing data.limits array")
        }

        var fiveHour: Entry?
        var weekly: Entry?
        var unclassified: [Entry] = []
        for limit in limits {
            // Skip TIME_LIMIT (monthly MCP-tool quota, not token usage) and
            // unknown entry kinds — mirrors cc-switch's token-tier parsing.
            guard isTokenLimit(limit) else { continue }
            let entry = Entry(limit)
            switch windowClass(limit) {
            case .fiveHour where fiveHour == nil: fiveHour = entry
            case .weekly where weekly == nil: weekly = entry
            default: unclassified.append(entry)
            }
        }
        // Fallback heuristic for entries without a usable `unit` field:
        // reset-less entries fill 5h first (a 0% bucket may lack a reset),
        // the rest sort by reset time ascending into the free slot.
        unclassified.sort {
            ($0.resetMs != nil ? 1 : 0, $0.resetMs ?? Int.min)
                < ($1.resetMs != nil ? 1 : 0, $1.resetMs ?? Int.min)
        }
        for entry in unclassified {
            if fiveHour == nil {
                fiveHour = entry
            } else if weekly == nil {
                weekly = entry
            }
        }

        guard fiveHour != nil || weekly != nil else {
            throw UsageParseError.unexpectedShape("glm: no TOKENS_LIMIT entries in limits")
        }
        return [(fiveHour, "5 Hours"), (weekly, "1 Week")].compactMap { slot in
            slot.0.map { UsageItem(label: slot.1, usedPercent: $0.percentage, remaining: nil, total: nil, unit: nil, resetsAt: $0.resetsAt) }
        }
    }

    /// `unit: 3` is the 5-hour rolling window, `unit: 6` the weekly window
    /// (both observed with several `number` values, so only `unit` anchors).
    private static func windowClass(_ limit: [String: Any]) -> Window {
        switch asInt(limit["unit"]) {
        case 3: return .fiveHour
        case 6: return .weekly
        default: return .unknown
        }
    }

    /// Case-insensitive match so an upstream casing change keeps parsing.
    private static func isTokenLimit(_ limit: [String: Any]) -> Bool {
        let type = (limit["type"] as? String)?.uppercased() ?? ""
        return type == "TOKENS_LIMIT" || type == "CREDIT_LIMIT"
    }

}

// MARK: - GLM Team Plan (Zhipu organization)

/// Team-plan quota: same endpoint and response shape as the personal plan,
/// but fixed to the domestic host with `?type=2` plus organization/project
/// headers (all three credentials required — mirrors cc-switch
/// `query_zhipu_team`). Parsed by `GLMUsageProvider.parse`.
final class ZhipuTeamUsageProvider: UsageProducer {
    let providerKey = "zhipu-team"
    var displayName: String { config.displayName }
    private let config: UsageProviderConfig

    init(config: UsageProviderConfig) {
        self.config = config
    }

    func fetch() async throws -> [UsageItem] {
        guard let organization = config.extra["organization_id"], !organization.isEmpty,
              let project = config.extra["project_id"], !project.isEmpty else {
            throw UsageParseError.unexpectedShape(
                "zhipu-team: needs organization_id and project_id in the config"
            )
        }
        let response = try await UsageHTTP.getJSON(
            "https://open.bigmodel.cn/api/monitor/usage/quota/limit?type=2",
            headers: [
                "Authorization": config.token,  // raw token, no Bearer prefix
                "bigmodel-organization": organization,
                "bigmodel-project": project,
                "Content-Type": "application/json",
                "Accept-Language": "en-US,en",
            ]
        )
        return try GLMUsageProvider.parse(response.body)
    }
}

// MARK: - Kimi For Coding

final class KimiUsageProvider: UsageProducer {
    let providerKey = "kimi"
    var displayName: String { config.displayName }
    private let config: UsageProviderConfig

    init(config: UsageProviderConfig) {
        self.config = config
    }

    func fetch() async throws -> [UsageItem] {
        let response = try await UsageHTTP.getJSON(
            "https://api.kimi.com/coding/v1/usages",
            headers: ["Authorization": "Bearer \(config.token)"]
        )
        return try Self.parse(response.body)
    }

    /// Pure parsing, fixture-testable. The 5h window lives in `limits[].detail`,
    /// the weekly quota in `usage`; both report `limit`/`remaining` amounts
    /// that convert to a used percentage. A body with neither field throws.
    static func parse(_ body: Any) throws -> [UsageItem] {
        guard let root = asObject(body) else {
            throw UsageParseError.unexpectedShape("kimi: body is not a JSON object")
        }
        var items: [UsageItem] = []
        if let limits = root["limits"] as? [[String: Any]] {
            for limit in limits {
                guard let detail = asObject(limit["detail"]) else { continue }
                items.append(windowItem(label: "5 Hours", detail: detail))
            }
        }
        if let usage = asObject(root["usage"]) {
            items.append(windowItem(label: "1 Week", detail: usage))
        }
        guard !items.isEmpty else {
            throw UsageParseError.unexpectedShape("kimi: no limits or usage data")
        }
        return items
    }

    private static func windowItem(label: String, detail: [String: Any]) -> UsageItem {
        let limit = parseF64(detail["limit"]) ?? 1.0
        let remaining = parseF64(detail["remaining"]) ?? 0.0
        let used = max(limit - remaining, 0)
        let percent = limit > 0 ? used / limit * 100 : 0
        return UsageItem(
            label: label,
            usedPercent: percent,
            remaining: nil,
            total: nil,
            unit: nil,
            resetsAt: extractResetTime(detail["resetTime"])
        )
    }
}

// MARK: - MiniMax

final class MiniMaxUsageProvider: UsageProducer {
    let providerKey = "minimax"
    var displayName: String { config.displayName }
    private let config: UsageProviderConfig

    init(config: UsageProviderConfig) {
        self.config = config
    }

    func fetch() async throws -> [UsageItem] {
        let response = try await UsageHTTP.getJSON(
            Self.remainsURL(baseURL: config.baseURL),
            headers: [
                "Authorization": "Bearer \(config.token)",
                "Content-Type": "application/json",
            ]
        )
        return try Self.parse(response.body)
    }

    /// Site routing mirrors cc-switch's `query_minimax`: `api.minimaxi.com`
    /// is the cn site, `api.minimax.io` the en site; missing configuration
    /// falls back to the cn site.
    static func remainsURL(baseURL: String?) -> String {
        let lowered = (baseURL ?? "").lowercased()
        let host = lowered.contains("api.minimax.io")
            ? "https://api.minimax.io"
            : "https://api.minimaxi.com"
        return host + "/v1/api/openplatform/coding_plan/remains"
    }

    /// Pure parsing, fixture-testable. `current_*_remaining_percent` fields
    /// are remaining percentages and get flipped to used percentages here.
    /// Only the `general` (coding plan) entry counts; `video` and friends
    /// are skipped.
    static func parse(_ body: Any) throws -> [UsageItem] {
        guard let root = asObject(body) else {
            throw UsageParseError.unexpectedShape("minimax: body is not a JSON object")
        }
        if let baseResp = asObject(root["base_resp"]) {
            let code = asInt(baseResp["status_code"]) ?? -1
            if code != 0 {
                let msg = baseResp["status_msg"] as? String ?? "Unknown error"
                throw UsageParseError.unexpectedShape("minimax: API error (code \(code)): \(msg)")
            }
        }
        guard let remains = root["model_remains"] as? [[String: Any]],
              let item = remains.first(where: { ($0["model_name"] as? String) == "general" }) else {
            throw UsageParseError.unexpectedShape("minimax: missing general entry in model_remains")
        }

        var items: [UsageItem] = []
        if let remain = parseF64(item["current_interval_remaining_percent"]) {
            items.append(UsageItem(
                label: "5 Hours",
                usedPercent: 100 - remain,
                remaining: nil,
                total: nil,
                unit: nil,
                resetsAt: asInt(item["end_time"]).map(iso8601(fromMillis:))
            ))
        }
        // `current_weekly_status == 1` means the plan has a weekly cap;
        // other values (e.g. 3) mean no weekly quota — never display it.
        if asInt(item["current_weekly_status"]) == 1,
           let remain = parseF64(item["current_weekly_remaining_percent"]) {
            items.append(UsageItem(
                label: "1 Week",
                usedPercent: 100 - remain,
                remaining: nil,
                total: nil,
                unit: nil,
                resetsAt: asInt(item["weekly_end_time"]).map(iso8601(fromMillis:))
            ))
        }
        guard !items.isEmpty else {
            throw UsageParseError.unexpectedShape("minimax: no usage percentages in general entry")
        }
        return items
    }
}

// MARK: - ZenMux

final class ZenMuxUsageProvider: UsageProducer {
    let providerKey = "zenmux"
    var displayName: String { config.displayName }
    private let config: UsageProviderConfig

    init(config: UsageProviderConfig) {
        self.config = config
    }

    func fetch() async throws -> [UsageItem] {
        let response = try await UsageHTTP.getJSON(
            Self.quotaURL(baseURL: config.baseURL),
            headers: ["Authorization": "Bearer \(config.token)"]
        )
        return try Self.parse(response.body)
    }

    /// cc-switch passes the ZenMux quota endpoint in as `base_url` verbatim
    /// (the user-configured billing URL, trailing slashes trimmed), so the
    /// configured value is used as the complete quota URL. Unset
    /// configuration falls back to the documented management endpoint.
    static func quotaURL(baseURL: String?) -> String {
        guard var url = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !url.isEmpty else {
            return "https://zenmux.ai/api/v1/management/subscription/detail"
        }
        while url.hasSuffix("/") {
            url.removeLast()
        }
        return url
    }

    /// Pure parsing, fixture-testable. `usage_percentage` is a 0-1 fraction
    /// and gets scaled to a 0-100 used percentage. A `success != true`
    /// envelope or a missing `data` field throws.
    static func parse(_ body: Any) throws -> [UsageItem] {
        guard let root = asObject(body) else {
            throw UsageParseError.unexpectedShape("zenmux: body is not a JSON object")
        }
        guard root["success"] as? Bool == true else {
            let msg = root["message"] as? String ?? "Unknown error"
            throw UsageParseError.unexpectedShape("zenmux: API error: \(msg)")
        }
        guard let data = asObject(root["data"]) else {
            throw UsageParseError.unexpectedShape("zenmux: missing data field")
        }
        var items: [UsageItem] = []
        if let quota = asObject(data["quota_5_hour"]) {
            items.append(windowItem(label: "5 Hours", quota: quota))
        }
        if let quota = asObject(data["quota_7_day"]) {
            items.append(windowItem(label: "1 Week", quota: quota))
        }
        guard !items.isEmpty else {
            throw UsageParseError.unexpectedShape("zenmux: no quota windows in data")
        }
        return items
    }

    private static func windowItem(label: String, quota: [String: Any]) -> UsageItem {
        let fraction = parseF64(quota["usage_percentage"]) ?? 0.0
        let maxUSD = parseF64(quota["max_value_usd"])
        return UsageItem(
            label: label,
            usedPercent: fraction * 100,
            remaining: nil,
            total: maxUSD,
            unit: maxUSD == nil ? nil : "USD",
            resetsAt: quota["resets_at"] as? String
        )
    }
}

// MARK: - OpenCode Go

final class OpenCodeGoUsageProvider: UsageProducer {
    let providerKey = "opencode-go"
    var displayName: String { config.displayName }
    private let config: UsageProviderConfig

    init(config: UsageProviderConfig) {
        self.config = config
    }

    func fetch() async throws -> [UsageItem] {
        // The usage endpoint is fixed and first-party; it only accepts
        // `Authorization: Bearer` (the inverse of the inference side).
        let response = try await UsageHTTP.getJSON(
            "https://opencode.ai/zen/go/v1/usage",
            headers: ["Authorization": "Bearer \(config.token)"]
        )
        return try Self.parse(response.body)
    }

    /// Pure parsing, fixture-testable. This endpoint is first-party but
    /// undocumented and already changed shape once, so each window parses
    /// defensively: a missing entry or unparseable `percent` skips that
    /// window without failing the rest. Only when no window survives does
    /// the shape count as unrecognized.
    static func parse(_ body: Any) throws -> [UsageItem] {
        let windows: [(key: String, label: String)] = [
            ("rolling", "5 Hours"),
            ("weekly", "1 Week"),
            ("monthly", "1 Month"),
        ]
        guard let usage = asObject(body)?["usage"] as? [String: Any] else {
            throw UsageParseError.unexpectedShape("opencode-go: missing usage object")
        }
        var items: [UsageItem] = []
        for window in windows {
            guard let entry = asObject(usage[window.key]),
                  let percent = parseF64(entry["percent"]) else {
                continue
            }
            // At percent 0 the upstream `resetsAt` is a now+window placeholder,
            // not a real reset time — drop it.
            let resetsAt = percent > 0 ? extractResetTime(entry["resetsAt"]) : nil
            items.append(UsageItem(
                label: window.label,
                usedPercent: percent,
                remaining: nil,
                total: nil,
                unit: nil,
                resetsAt: resetsAt
            ))
        }
        guard !items.isEmpty else {
            throw UsageParseError.unexpectedShape("opencode-go: no parseable usage windows")
        }
        return items
    }
}
