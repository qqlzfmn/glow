import Foundation

// MARK: - Shared parsing helpers

/// Tolerant numeric field reader: accepts JSON numbers and numeric strings,
/// mirroring BalanceProviders' helper (file-private, so definitions do not
/// collide across files).
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

// MARK: - New API / one-api

/// GET `{base_url}/api/user/self` — user self-info endpoint shared by
/// new-api (QuantumNous/new-api) and one-api (songquanpeng/one-api) gateways;
/// the response shape is identical (`{ success, message, data: { id, quota,
/// used_quota, ... } }`), so one class covers both.
///
/// Auth needs the *system access token* from the web console (Personal
/// Settings → generate access token), not an `sk-` API key:
/// - one-api validates the `Authorization` header against the user's
///   `access_token` column, stripping a leading `Bearer ` — so
///   `Authorization: Bearer <token>` works.
/// - new-api additionally requires the numeric user id in the
///   `New-Api-User` header (missing/mismatched header is rejected); one-api
///   ignores it. Supply it as `extra["user_id"]`.
///
/// `quota` is the remaining balance and `used_quota` the lifetime spend in
/// internal units; both codebases use `QuotaPerUnit = 500 * 1000.0`
/// (`$0.002 / 1K tokens`), i.e. 500000 units = $1.
final class NewApiUsageProvider: UsageProducer {
    let providerKey = "new-api"
    let displayName = "New API"
    private let config: UsageProviderConfig

    init(config: UsageProviderConfig) {
        self.config = config
    }

    func fetch() async throws -> [UsageItem] {
        guard var base = config.baseURL, !base.isEmpty else {
            // Config error rather than a parse failure; `badURL` carries the
            // empty/missing host for a actionable message.
            throw UsageHTTPError.badURL(config.baseURL ?? "<missing base_url>")
        }
        while base.hasSuffix("/") {
            base.removeLast()
        }
        var headers = ["Authorization": "Bearer \(config.token)"]
        if let userId = config.extra["user_id"], !userId.isEmpty {
            // Required by new-api, ignored by one-api.
            headers["New-Api-User"] = userId
        }
        let response = try await UsageHTTP.getJSON("\(base)/api/user/self", headers: headers)
        return try Self.parse(response.body)
    }

    /// Pure parsing, fixture-testable. Unknown shape must throw rather than
    /// return an empty array masquerading as success.
    static func parse(_ body: Any) throws -> [UsageItem] {
        guard let root = asObject(body) else {
            throw UsageParseError.unexpectedShape("new-api: body is not a JSON object")
        }
        if root["success"] as? Bool == false {
            let message = root["message"] as? String ?? "gateway reported failure"
            throw UsageParseError.unexpectedShape("new-api: \(message)")
        }
        guard let data = asObject(root["data"]) else {
            throw UsageParseError.unexpectedShape("new-api: missing data object")
        }
        // Gateways report both fields as integers, but tolerate numeric
        // strings; `used_quota` may be absent on fresh accounts.
        guard let quota = parseF64(data, "quota") else {
            throw UsageParseError.unexpectedShape("new-api: missing data.quota")
        }
        let usedQuota = parseF64(data, "used_quota") ?? 0

        // Internal units → USD: QuotaPerUnit = 500000.
        let remaining = quota / 500_000
        let total = (quota + usedQuota) / 500_000
        // Used share is only computable once the account has a quota at all.
        let usedPercent = total > 0 ? (usedQuota / (quota + usedQuota)) * 100 : nil

        return [
            UsageItem(
                label: "Balance",
                usedPercent: usedPercent,
                remaining: remaining,
                total: total,
                unit: "USD",
                resetsAt: nil
            )
        ]
    }
}
