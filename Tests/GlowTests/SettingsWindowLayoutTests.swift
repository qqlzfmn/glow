import Testing
import Foundation
import AppKit
@testable import GlowCore

/// Layout contract of the app-level Settings window: four sidebar sections
/// switch panes, pane controls stay inside the window, and the Provider
/// poll-seconds field reads the real store value. Holds
/// GLOW_STATE_DIR/GLOW_HOME like the store suites.
@Suite(.serialized)
final class SettingsWindowLayoutTests {

    private let tmpDir: String

    init() {
        StateDirEnvLock.lock.lock()
        let dir = NSTemporaryDirectory() + "/glow-settings-\(UUID().uuidString)"
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

    // MARK: - Helpers

    private func makeController() throws -> (windowController: SettingsWindowController, content: NSView) {
        let windowController = SettingsWindowController(onRefresh: {}, onBadgeChange: {})
        let window = try #require(windowController.window)
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()
        return (windowController, content)
    }

    private func sidebarButton(titled title: String, in content: NSView) throws -> NSButton {
        try #require(
            content.findAllSubviews()
                .compactMap { $0 as? NSButton }
                .first { $0.title == title },
            "sidebar button \(title) missing"
        )
    }

    private func pane<T: NSView>(_ type: T.Type, in content: NSView) -> T? {
        content.findAllSubviews().compactMap { $0 as? T }.first
    }

    @Test @MainActor func fourSidebarSectionsSwitchPanes() throws {
        // Hold the whole tuple: `_` bindings don't keep the
        // NSWindowController alive, and a released controller detaches
        // every target-action in its window.
        let made = try makeController()
        let content = made.content

        for title in ["App", "Appearance", "Providers", "Hooks"] {
            _ = try sidebarButton(titled: title, in: content)
        }

        // App is selected first; its pane is visible, Providers is not.
        #expect(pane(AppSettingsPane.self, in: content)?.isHidden == false)
        #expect(pane(ProviderSettingsPane.self, in: content)?.isHidden == true)

        // Clicking Providers flips visibility (state-preserving isHidden).
        try sidebarButton(titled: "Providers", in: content).performClick(nil)
        #expect(pane(ProviderSettingsPane.self, in: content)?.isHidden == false)
        #expect(pane(AppSettingsPane.self, in: content)?.isHidden == true)
    }

    @Test @MainActor func providerPollFieldReadsStoreAndStaysInWindow() throws {
        // Seed a custom poll interval.
        try UsageStore.writeUsage(UsageFile(
            pollSeconds: 60,
            badge: nil,
            providers: [:]
        ))
        let made = try makeController()
        let content = made.content

        try sidebarButton(titled: "Providers", in: content).performClick(nil)
        let providerPane = try #require(pane(ProviderSettingsPane.self, in: content))
        content.layoutSubtreeIfNeeded()

        let pollField = try #require(
            providerPane.findAllSubviews()
                .compactMap { $0 as? NSTextField }
                .first { $0.placeholderString == "300" },
            "poll-seconds field missing from Providers pane"
        )
        #expect(pollField.stringValue == "60")

        // Frames live in different superview coordinate systems — convert
        // into content coordinates before comparing.
        let frame = pollField.convert(pollField.bounds, to: content)
        let bounds = content.bounds
        #expect(frame.width > 0, "poll field collapsed")
        #expect(frame.minY >= bounds.minY - 0.5, "poll field pushed out: \(frame)")
        #expect(frame.maxY <= bounds.maxY + 0.5, "poll field pushed out: \(frame)")
    }

    @Test @MainActor func appearanceBadgeControlsStayInWindow() throws {
        let made = try makeController()
        let content = made.content

        try sidebarButton(titled: "Appearance", in: content).performClick(nil)
        let badge = try #require(
            pane(AppearanceSettingsPane.self, in: content)?
                .findAllSubviews()
                .compactMap { $0 as? BadgeAppearanceControls }
                .first,
            "badge controls missing from Appearance pane"
        )
        content.layoutSubtreeIfNeeded()

        let frame = badge.convert(badge.bounds, to: content)
        let bounds = content.bounds
        #expect(frame.width > 0, "badge controls collapsed")
        #expect(frame.minX >= bounds.minX - 0.5, "badge controls overlap sidebar: \(frame)")
        #expect(frame.maxX <= bounds.maxX + 0.5, "badge controls pushed out: \(frame)")
    }
}
