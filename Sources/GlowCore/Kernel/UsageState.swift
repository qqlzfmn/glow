import Foundation

/// Root JSON document of the usage state file, written by `UsageMonitor`.
/// Same file-contract style as `sessions.json`: one writer per process,
/// flock-serialized, tolerant reads.
struct UsageFile: Codable {
    /// Provider keys in display/badge priority order (discovery order).
    /// Optional so hand-written or older files still decode.
    var order: [String]?
    /// Provider key the user pinned for the menu bar badge; nil means
    /// "first available in order". Persisted via the Usage menu.
    var badgeProvider: String?
    /// Keyed by stable provider key (e.g. `glm`, `deepseek`).
    var providers: [String: ProviderUsage]

    enum CodingKeys: String, CodingKey {
        case order
        case badgeProvider = "badge_provider"
        case providers
    }
}

/// Latest snapshot for one provider. `status == "error"` carries `error`
/// and keeps the last known `items` so menus can still show stale data.
struct ProviderUsage: Codable {
    var displayName: String
    var updatedAt: TimeInterval
    /// `ok` | `error`.
    var status: String
    var error: String?
    var items: [UsageItem]

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case updatedAt = "updated_at"
        case status
        case error
        case items
    }
}

/// One displayable usage number: a quota window (`usedPercent`) or a
/// balance (`remaining`). Order in `items` is display order; index 0 is
/// the badge candidate.
struct UsageItem: Codable {
    /// Short label, e.g. `5h`, `Balance`, `Tokens`.
    var label: String
    /// 0-100, already used share of a quota window.
    var usedPercent: Double?
    /// Remaining balance/quota in `unit`.
    var remaining: Double?
    /// Total quota/balance when the provider reports it.
    var total: Double?
    /// `USD`, `CNY`, `tokens`, ...
    var unit: String?
    /// ISO 8601 reset timestamp when the provider reports one.
    var resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case label
        case usedPercent = "used_percent"
        case remaining
        case total
        case unit
        case resetsAt = "resets_at"
    }
}

