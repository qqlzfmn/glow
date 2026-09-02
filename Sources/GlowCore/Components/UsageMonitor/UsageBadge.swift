import Foundation

/// Formats usage numbers for the menu bar badge and menus.
enum UsageBadge {
    /// Menu bar badge: the pinned provider's (`badge_provider`) items joined
    /// with a vertical bar (e.g. `5h 62%│1w 84%│1m 62%`), else the first
    /// provider (in `order`) with data. Empty when nothing is usable.
    static func badgeText(for file: UsageFile) -> String {
        let keys = file.order ?? file.providers.keys.sorted()
        var candidates = keys
        if let pinned = file.badgeProvider {
            candidates = [pinned] + keys.filter { $0 != pinned }
        }
        for key in candidates {
            guard let provider = file.providers[key],
                  provider.status == "ok",
                  !provider.items.isEmpty else {
                continue
            }
            return provider.items.map { itemText($0) }.joined(separator: "│")
        }
        return ""
    }
    /// One-line text for an item: `5h 42%`, `1w 12.3M`, or `Balance ¥123.45`.
    static func itemText(_ item: UsageItem) -> String {
        var parts: [String] = [item.label]
        if let percent = item.usedPercent {
            parts.append(String(format: "%.0f%%", percent))
        } else if let remaining = item.remaining {
            parts.append(currency(remaining, unit: item.unit))
        }
        return parts.joined(separator: " ")
    }

    /// Compact currency formatting: symbol form for CNY/USD, suffix form
    /// otherwise; large values keep integers, small ones one decimal.
    static func currency(_ value: Double, unit: String?) -> String {
        switch unit?.uppercased() {
        case "CNY": return "¥" + amount(value)
        case "USD": return "$" + amount(value)
        default:
            let u = unit ?? ""
            return u.isEmpty ? amount(value) : amount(value) + " " + u
        }
    }

    private static func amount(_ value: Double) -> String {
        if abs(value) >= 100 {
            return String(format: "%.0f", value)
        }
        // "%.1f" rounds half-to-even (8.25 → 8.2); round half-away instead.
        let rounded = (value * 10).rounded() / 10
        return String(format: "%.1f", rounded)
    }
}
