import Foundation

/// User-tunable rendering parameters of the menu bar usage badge
/// (`badge` object in usage.json). Every field is optional: nil means
/// "built-in default" — in particular unset colors keep the dynamic
/// system label color, which adapts to light/dark menu bars.
struct BadgeAppearance: Codable, Equatable {
    /// Top-line value font size (default 11).
    var valueFontSize: Double?
    /// Bottom-line label font size (default 7.5).
    var labelFontSize: Double?
    /// Extra vertical spread between the two lines, split above/below
    /// the badge center (default 0).
    var lineSpacing: Double?
    /// `#RRGGBB` overrides; nil keeps the dynamic label color.
    var valueColor: String?
    var labelColor: String?
    var separatorColor: String?

    /// All-defaults instance (an all-nil `badge` object).
    static let standard = BadgeAppearance()

    static let defaultValueFontSize: Double = 11
    static let defaultLabelFontSize: Double = 7.5

    enum CodingKeys: String, CodingKey {
        case valueFontSize = "value_font_size"
        case labelFontSize = "label_font_size"
        case lineSpacing = "line_spacing"
        case valueColor = "value_color"
        case labelColor = "label_color"
        case separatorColor = "separator_color"
    }

    /// Clamp hand-edited values into a renderable range and drop color
    /// strings that do not parse as `#RRGGBB`. Defends usage.json
    /// against manual edits; valid values pass through unchanged.
    var sanitized: BadgeAppearance {
        BadgeAppearance(
            valueFontSize: valueFontSize.map { min(max($0, 5), 20) },
            labelFontSize: labelFontSize.map { min(max($0, 4), 16) },
            lineSpacing: lineSpacing.map { min(max($0, 0), 8) },
            valueColor: valueColor.flatMap(Self.validHex),
            labelColor: labelColor.flatMap(Self.validHex),
            separatorColor: separatorColor.flatMap(Self.validHex)
        )
    }

    static func validHex(_ text: String) -> String? {
        parseHex(text) == nil ? nil : text
    }

    /// Parse `#RRGGBB` / `RRGGBB` (case-insensitive) into 0–1 components.
    static func parseHex(_ text: String) -> BadgeRGB? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("#") { t.removeFirst() }
        guard t.count == 6, let value = UInt64(t, radix: 16) else { return nil }
        return BadgeRGB(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// Format 0–1 components back to canonical uppercase `#RRGGBB`.
    static func hexString(_ rgb: BadgeRGB) -> String {
        String(
            format: "#%02X%02X%02X",
            Int((rgb.red * 255).rounded()),
            Int((rgb.green * 255).rounded()),
            Int((rgb.blue * 255).rounded())
        )
    }
}

/// Plain RGB triple (0–1 each), independent of AppKit so the model stays
/// unit-testable.
struct BadgeRGB: Equatable {
    var red: Double
    var green: Double
    var blue: Double
}
