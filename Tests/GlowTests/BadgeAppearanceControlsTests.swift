import Testing
import Foundation
import AppKit
@testable import GlowCore

/// BadgeAppearanceControls mutates usage.json (GLOW_STATE_DIR), so these
/// tests hold the cross-suite state-dir lock like UsageStoreTests.
@Suite(.serialized)
final class BadgeAppearanceControlsTests {

    private let tmpDir: String
    private let controls: BadgeAppearanceControls

    init() {
        StateDirEnvLock.lock.lock()
        let dir = NSTemporaryDirectory() + "/glow-badge-ui-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        self.tmpDir = dir
        setenv("GLOW_STATE_DIR", dir, 1)
        controls = BadgeAppearanceControls(frame: NSRect(x: 0, y: 0, width: 536, height: 44))
    }

    deinit {
        unsetenv("GLOW_STATE_DIR")
        try? FileManager.default.removeItem(atPath: tmpDir)
        StateDirEnvLock.lock.unlock()
    }

    private func writeFixture(_ badge: BadgeAppearance?) throws {
        var file = UsageStore.readUsage()
        file.badge = badge
        try UsageStore.writeUsage(file)
    }

    // MARK: - Seeding

    @Test func reloadSeedsFieldsFromStoredAppearance() throws {
        try writeFixture(BadgeAppearance(
            valueFontSize: 13, labelFontSize: 9, lineSpacing: 2,
            valueColor: "#FF0000", separatorColor: "#00FF00"
        ))
        controls.reloadFromStore()
        #expect(controls.valueSizeField?.stringValue == "13")
        #expect(controls.labelSizeField?.stringValue == "9")
        #expect(controls.spacingField?.stringValue == "2")
        #expect(controls.valueWell?.color == NSColor(hexRGBA: "#FF0000"))
    }

    @Test func reloadSeedsDefaultsWhenNothingStored() {
        controls.reloadFromStore()
        #expect(controls.valueSizeField?.stringValue == "11")
        #expect(controls.labelSizeField?.stringValue == "7.5")
        #expect(controls.spacingField?.stringValue == "0")
    }

    // MARK: - Actions persist

    @Test func sizeChangePersistsSanitizedValue() throws {
        controls.reloadFromStore()

        controls.valueSizeField?.stringValue = "99"
        controls.valueSizeChanged()
        #expect(UsageStore.readUsage().badge?.valueFontSize == 20)

        controls.valueSizeField?.stringValue = "12.5"
        controls.valueSizeChanged()
        #expect(UsageStore.readUsage().badge?.valueFontSize == 12.5)
    }

    @Test func invalidSizeSnapsBackAndKeepsStoredValue() throws {
        try writeFixture(BadgeAppearance(valueFontSize: 12))
        controls.reloadFromStore()

        controls.valueSizeField?.stringValue = "abc"
        controls.valueSizeChanged()
        #expect(UsageStore.readUsage().badge?.valueFontSize == 12)
        #expect(controls.valueSizeField?.stringValue == "12")
    }

    @Test func colorChangePersistsHex() throws {
        controls.reloadFromStore()
        controls.valueWell?.color = NSColor(red: 0, green: 0.5, blue: 1, alpha: 1)
        controls.valueColorChanged()
        #expect(UsageStore.readUsage().badge?.valueColor == "#0080FF")
    }

    @Test func resetClearsBadgeObject() throws {
        try writeFixture(BadgeAppearance(valueFontSize: 14, valueColor: "#FF0000"))
        controls.reloadFromStore()

        controls.resetClicked()
        #expect(UsageStore.readUsage().badge == nil)
        #expect(controls.valueSizeField?.stringValue == "11")
    }

    // MARK: - Untouched controls leave stored fields alone

    @Test func unrelatedSizeChangeKeepsStoredColors() throws {
        try writeFixture(BadgeAppearance(valueColor: "#123456"))
        controls.reloadFromStore()

        controls.spacingField?.stringValue = "3"
        controls.spacingChanged()
        let badge = UsageStore.readUsage().badge
        #expect(badge?.lineSpacing == 3)
        #expect(badge?.valueColor == "#123456")
    }
}
