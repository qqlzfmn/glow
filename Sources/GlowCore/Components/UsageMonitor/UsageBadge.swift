import Foundation

/// Formats usage numbers for the menu bar badge and menus.
enum UsageBadge {
    /// Structured badge segments (value/label pairs) for the custom-drawn
    /// status item: the pinned provider's items, else the first provider
    /// with data. Empty when nothing is usable.
    static func badgeSegments(for file: UsageFile) -> [(value: String, label: String)] {
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
            return provider.items.map { item in
                (value: itemValue(item), label: item.label)
            }
        }
        return []
    }

    /// Single-line plain-text badge (`5h 62%│1w 84%`), used by tests and the
    /// `usage` CLI output consumers.
    static func badgeText(for file: UsageFile) -> String {
        badgeSegments(for: file)
            .map { "\($0.label) \($0.value)" }
            .joined(separator: "│")
    }

    private static func itemValue(_ item: UsageItem) -> String {
        if let percent = item.usedPercent {
            return String(format: "%.0f%%", percent)
        }
        if let remaining = item.remaining {
            return currency(remaining, unit: item.unit)
        }
        return item.label
    }
    static func itemText(_ item: UsageItem) -> String {
        var parts: [String] = [item.label]
        if let percent = item.usedPercent {
            parts.append(String(format: "%.0f%%", percent))
        } else if let remaining = item.remaining {
            parts.append(currency(remaining, unit: item.unit))
        }
        return parts.joined(separator: " ")
    }

    /// Currency rendering as free-form `{unit}{value}` concat — the unit
    /// may be a symbol ("$", "€", "¥") or an ISO code ("CNY" → "¥"); any
    /// other text is used verbatim as a prefix.
    static func currency(_ value: Double, unit: String?) -> String {
        var u = unit ?? ""
        switch u.uppercased() {
        case "USD": u = "$"
        case "CNY", "RMB": u = "¥"
        case "EUR": u = "€"
        default: break
        }
        return u + amount(value)
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
