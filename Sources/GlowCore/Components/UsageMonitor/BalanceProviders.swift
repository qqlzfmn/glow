import Foundation

// MARK: - Shared parsing helpers

/// Balance parsers (DeepSeek / OpenRouter / SiliconFlow / StepFun). Each wraps
/// one `GET` endpoint that reports account balance only — no quota windows —
/// so every item is a `Balance` row with `usedPercent == nil`. Shapes mirror
/// cc-switch's `balance.rs`, the single source of truth for endpoints and
/// response fields.

/// Tolerant numeric field reader: accepts JSON numbers and numeric strings
/// (some providers serialize balances as `"1.23"`), mirroring cc-switch's
/// `parse_f64_field`.
private func parseF64(_ dict: [String: Any], _ field: String) -> Double? {
    switch dict[field] {
    case let n as Double: return n.isFinite ? n : nil
    case let n as Int: return Double(n)
    case let s as String: return Double(s)
    default: return nil
    }
}

/// Defense-cast of a JSONSerialization value to a string-keyed object.
private func asObject(_ any: Any?) -> [String: Any]? {
    any as? [String: Any]
}

// MARK: - DeepSeek

/// GET https://api.deepseek.com/user/balance
/// Response: `{ balance_infos: [{ currency, total_balance, ... }], is_available }`.
/// One item per `balance_infos` entry; `is_available == false` is informational
/// and still returns the reported numbers.
final class DeepSeekUsageProvider: UsageProducer {
    let providerKey = "deepseek"
    let displayName = "DeepSeek"
    private let config: UsageProviderConfig

    init(config: UsageProviderConfig) {
        self.config = config
    }

    func fetch() async throws -> [UsageItem] {
        let response = try await UsageHTTP.getJSON(
            "https://api.deepseek.com/user/balance",
            headers: ["Authorization": "Bearer \(config.token)"]
        )
        return try Self.parse(response.body)
    }

    /// Pure parsing, fixture-testable. Unknown shape must throw rather than
    /// return an empty array masquerading as success.
    static func parse(_ body: Any) throws -> [UsageItem] {
        guard let root = asObject(body),
              let infos = root["balance_infos"] as? [[String: Any]],
              !infos.isEmpty else {
            throw UsageParseError.unexpectedShape("deepseek: missing balance_infos array")
        }
        return try infos.map { info in
            let currency = info["currency"] as? String
            guard let total = parseF64(info, "total_balance") else {
                throw UsageParseError.unexpectedShape("deepseek: missing total_balance")
            }
            return UsageItem(
                label: currency ?? "Balance",
                usedPercent: nil,
                remaining: total,
                total: nil,
                unit: currency,
                resetsAt: nil
            )
        }
    }
}

// MARK: - OpenRouter

/// GET https://openrouter.ai/api/v1/credits
/// Response: `{ data: { total_credits, total_usage } }`. Prepaid credits minus
/// usage gives the remaining balance; unit is always USD.
final class OpenRouterUsageProvider: UsageProducer {
    let providerKey = "openrouter"
    let displayName = "OpenRouter"
    private let config: UsageProviderConfig

    init(config: UsageProviderConfig) {
        self.config = config
    }

    func fetch() async throws -> [UsageItem] {
        let response = try await UsageHTTP.getJSON(
            "https://openrouter.ai/api/v1/credits",
            headers: ["Authorization": "Bearer \(config.token)"]
        )
        return try Self.parse(response.body)
    }

    static func parse(_ body: Any) throws -> [UsageItem] {
        guard let root = asObject(body),
              let data = asObject(root["data"]),
              let credits = parseF64(data, "total_credits"),
              let usage = parseF64(data, "total_usage") else {
            throw UsageParseError.unexpectedShape("openrouter: missing data.total_credits/total_usage")
        }
        return [
            UsageItem(
                label: "Balance",
                usedPercent: nil,
                remaining: credits - usage,
                total: credits,
                unit: "USD",
                resetsAt: nil
            )
        ]
    }
}

// MARK: - SiliconFlow

/// GET https://api.siliconflow.{cn,com}/v1/user/info
/// Response: `{ code, data: { balance, chargeBalance, totalBalance, status } }`.
/// The `.com` endpoint is the international (EN) site and bills in USD; `.cn`
/// bills in CNY. The reported figure is `totalBalance`.
final class SiliconFlowUsageProvider: UsageProducer {
    let providerKey = "siliconflow"
    let displayName = "SiliconFlow"
    private let config: UsageProviderConfig

    init(config: UsageProviderConfig) {
        self.config = config
    }

    func fetch() async throws -> [UsageItem] {
        let domain = config.baseURL?.contains("siliconflow.com") == true
            ? "api.siliconflow.com"
            : "api.siliconflow.cn"
        let response = try await UsageHTTP.getJSON(
            "https://\(domain)/v1/user/info",
            headers: ["Authorization": "Bearer \(config.token)"]
        )
        return try Self.parse(response.body, unit: domain.contains(".com") ? "USD" : "CNY")
    }

    static func parse(_ body: Any) throws -> [UsageItem] {
        try parse(body, unit: "CNY")
    }

    /// The billing currency follows the endpoint (cn → CNY, en → USD), which
    /// only the caller knows — hence this unit-parameterized variant.
    static func parse(_ body: Any, unit: String) throws -> [UsageItem] {
        guard let root = asObject(body),
              let data = asObject(root["data"]),
              let totalBalance = parseF64(data, "totalBalance") else {
            throw UsageParseError.unexpectedShape("siliconflow: missing data.totalBalance")
        }
        return [
            UsageItem(
                label: "Balance",
                usedPercent: nil,
                remaining: totalBalance,
                total: nil,
                unit: unit,
                resetsAt: nil
            )
        ]
    }
}

// MARK: - StepFun

/// GET https://api.stepfun.com/v1/accounts
/// Response: `{ balance, total_cash_balance, total_voucher_balance }`.
/// `balance` is the spendable account balance, always in CNY.
final class StepFunUsageProvider: UsageProducer {
    let providerKey = "stepfun"
    let displayName = "StepFun"
    private let config: UsageProviderConfig

    init(config: UsageProviderConfig) {
        self.config = config
    }

    func fetch() async throws -> [UsageItem] {
        let response = try await UsageHTTP.getJSON(
            "https://api.stepfun.com/v1/accounts",
            headers: ["Authorization": "Bearer \(config.token)"]
        )
        return try Self.parse(response.body)
    }

    static func parse(_ body: Any) throws -> [UsageItem] {
        guard let root = asObject(body),
              let balance = parseF64(root, "balance") else {
            throw UsageParseError.unexpectedShape("stepfun: missing balance")
        }
        return [
            UsageItem(
                label: "Balance",
                usedPercent: nil,
                remaining: balance,
                total: nil,
                unit: "CNY",
                resetsAt: nil
            )
        ]
    }
}
