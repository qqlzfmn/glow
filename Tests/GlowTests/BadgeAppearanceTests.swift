import Testing
import Foundation
import AppKit
@testable import GlowCore

/// BadgeAppearance is pure (no state dir, no env) — plain unit tests.
@Suite
final class BadgeAppearanceTests {

    // MARK: - Hex parsing

    @Test func hexParseAcceptsHashBareAndLowercase() {
        let withHash = BadgeAppearance.parseHex("#FF8040")
        #expect(withHash == BadgeRGB(red: 1, green: 128 / 255, blue: 64 / 255))

        let bare = BadgeAppearance.parseHex("FF8040")
        #expect(bare == withHash)

        let lower = BadgeAppearance.parseHex("#ff8040")
        #expect(lower == withHash)

        let padded = BadgeAppearance.parseHex("  #FF8040 \n")
        #expect(padded == withHash)
    }

    @Test func hexParseRejectsMalformed() {
        for text in ["", "#", "#FFF", "#FFFFF", "#FFFFFFF", "#GG8040", "FF804", "0xFF8040", "#FF80 40"] {
            #expect(BadgeAppearance.parseHex(text) == nil, "expected rejection: \(text)")
        }
    }

    @Test func hexRoundTripKeepsComponents() {
        let rgb = BadgeRGB(red: 10 / 255, green: 200 / 255, blue: 30 / 255)
        #expect(BadgeAppearance.parseHex(BadgeAppearance.hexString(rgb)) == rgb)
    }

    @Test func nsColorHexInitMatchesComponents() throws {
        let color = try #require(NSColor(hexRGBA: "#3366CC"))
        #expect(abs(color.redComponent - 0x33 / 255) < 0.001)
        #expect(abs(color.greenComponent - 0x66 / 255) < 0.001)
        #expect(abs(color.blueComponent - 0xCC / 255) < 0.001)
        #expect(NSColor(hexRGBA: "nope") == nil)
    }

    // MARK: - Sanitization

    @Test func sanitizedClampsSizesAndSpacing() {
        let badgeAppearance = BadgeAppearance(
            valueFontSize: 99,
            labelFontSize: 0.5,
            lineSpacing: -3
        ).sanitized
        #expect(badgeAppearance.valueFontSize == 20)
        #expect(badgeAppearance.labelFontSize == 4)
        #expect(badgeAppearance.lineSpacing == 0)
    }

    @Test func sanitizedDropsInvalidColorsAndKeepsValid() {
        let badgeAppearance = BadgeAppearance(
            valueColor: "#FF0000",
            labelColor: "rainbow",
            separatorColor: "#12345"
        ).sanitized
        #expect(badgeAppearance.valueColor == "#FF0000")
        #expect(badgeAppearance.labelColor == nil)
        #expect(badgeAppearance.separatorColor == nil)
    }

    @Test func sanitizedKeepsValidValuesUnchanged() {
        let original = BadgeAppearance(
            valueFontSize: 12.5,
            labelFontSize: 8,
            lineSpacing: 2,
            valueColor: "#00AA55",
            labelColor: "#808080",
            separatorColor: "#404040"
        )
        #expect(original.sanitized == original)
    }

    // MARK: - usage.json contract

    @Test func decodesBadgeObjectFromSnakeCaseJSON() throws {
        let json = ##"{"order":["glm"],"badge":{"value_font_size":12.5,"label_font_size":8,"line_spacing":2,"value_color":"#FF0000","label_color":"#00FF00","separator_color":"#0000FF"},"providers":{}}"##
        let file = try JSONDecoder().decode(UsageFile.self, from: Data(json.utf8))
        let badge = try #require(file.badge)
        #expect(badge.valueFontSize == 12.5)
        #expect(badge.labelFontSize == 8)
        #expect(badge.lineSpacing == 2)
        #expect(badge.valueColor == "#FF0000")
        #expect(badge.labelColor == "#00FF00")
        #expect(badge.separatorColor == "#0000FF")
    }

    @Test func decodesWithoutBadgeField() throws {
        // Older files (and files written before this feature) have no
        // `badge` object — they must decode with a nil badge.
        let json = #"{"order":["glm"],"providers":{}}"#
        let file = try JSONDecoder().decode(UsageFile.self, from: Data(json.utf8))
        #expect(file.badge == nil)
    }

    @Test func encodesBadgeObjectInSnakeCase() throws {
        let file = UsageFile(badge: BadgeAppearance(valueFontSize: 14, lineSpacing: 3, valueColor: "#AB0012"), providers: [:])
        let data = try JSONEncoder().encode(file)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let badge = try #require(object["badge"] as? [String: Any])
        #expect(badge["value_font_size"] as? Double == 14)
        #expect(badge["line_spacing"] as? Double == 3)
        #expect(badge["value_color"] as? String == "#AB0012")
        #expect(badge["label_font_size"] == nil)
    }
}

/// Layout-level assertions on the custom badge view: font sizes drive the
/// intrinsic width, so a wrong appearance wiring shrinks or blows up the
/// status item. No window server needed — pure string metrics.
@Suite
final class StatusItemBadgeViewTests {

    private func makeView() -> StatusItemBadgeView {
        let view = StatusItemBadgeView(frame: NSRect(x: 0, y: 0, width: 30, height: 24))
        view.segments = [
            StatusItemBadgeView.Segment(value: "62%", label: "5 Hours"),
            StatusItemBadgeView.Segment(value: "$10", label: "Balance"),
        ]
        return view
    }

    @Test func largerFontsWidenBadge() {
        let view = makeView()
        let standard = view.intrinsicContentSize.width

        // Both lines scale up — cell width is max(value, label) per
        // segment, so shrinking only the value line can be masked by a
        // wider label.
        view.badgeAppearance = BadgeAppearance(valueFontSize: 14, labelFontSize: 12)
        #expect(view.intrinsicContentSize.width > standard)

        view.badgeAppearance = BadgeAppearance(valueFontSize: 8, labelFontSize: 6)
        #expect(view.intrinsicContentSize.width < standard)
    }

    @Test func lineSpacingDoesNotChangeWidth() {
        let view = makeView()
        let standard = view.intrinsicContentSize.width
        view.badgeAppearance = BadgeAppearance(lineSpacing: 4)
        #expect(view.intrinsicContentSize.width == standard)
    }
}
