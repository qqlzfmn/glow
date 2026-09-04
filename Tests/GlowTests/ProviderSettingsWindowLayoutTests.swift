import Testing
import Foundation
import AppKit
@testable import GlowCore

/// Layout contract of the Provider Settings window: the badge appearance
/// strip must not crowd the poll-seconds row (or anything else) out of
/// the window. Holds GLOW_STATE_DIR/GLOW_HOME like the store suites.
@Suite(.serialized)
final class ProviderSettingsWindowLayoutTests {

    private let tmpDir: String

    init() {
        StateDirEnvLock.lock.lock()
        let dir = NSTemporaryDirectory() + "/glow-win-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        self.tmpDir = dir
        setenv("GLOW_STATE_DIR", dir, 1)
        setenv("GLOW_HOME", dir, 1)
    }

    deinit {
        unsetenv("GLOW_STATE_DIR")
        unsetenv("GLOW_HOME")
        try? FileManager.default.removeItem(atPath: tmpDir)
        StateDirEnvLock.lock.unlock()
    }

    @Test @MainActor func pollRowRemainsVisibleWithBadgeStrip() throws {
        // Seed the user's scenario: a custom poll interval + badge overrides.
        try UsageStore.writeUsage(UsageFile(
            pollSeconds: 60,
            badge: BadgeAppearance(valueFontSize: 14, valueColor: "#FF0000"),
            providers: [:]
        ))

        let controller = ProviderSettingsWindowController(
            onRefresh: {}, onBadgeChange: {}
        )
        let window = try #require(controller.window)
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()

        // The poll-seconds field is identified by its placeholder.

        let pollFields = content.findAllSubviews()
            .compactMap { $0 as? NSTextField }
            .filter { $0.placeholderString == "300" }
        let pollField = try #require(pollFields.first, "poll-seconds field missing from window")
        #expect(pollField.stringValue == "60")

        // Frames live in different superview coordinate systems — convert
        // both into content coordinates before comparing.
        let pollFrameInContent = pollField.convert(pollField.bounds, to: content)
        let contentBounds = content.bounds
        #expect(pollFrameInContent.width > 0, "poll field collapsed")
        #expect(pollFrameInContent.minY >= contentBounds.minY - 0.5,
                "poll field pushed below the window: \(pollFrameInContent)")
        #expect(pollFrameInContent.maxY <= contentBounds.maxY + 0.5,
                "poll field pushed above the window: \(pollFrameInContent)")

        let badge = content.findAllSubviews()
            .compactMap { $0 as? BadgeAppearanceControls }
            .first
        let badgeFrame = try #require(badge).frame
        #expect(badgeFrame.minY >= pollFrameInContent.maxY - 0.5,
                "badge strip overlaps the poll row: badge=\(badgeFrame) poll=\(pollFrameInContent)")
    }
}

extension NSView {
    func findAllSubviews() -> [NSView] {
        subviews + subviews.flatMap { $0.findAllSubviews() }
    }

}
