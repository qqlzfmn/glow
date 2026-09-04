import Testing
import Foundation
import AppKit
@testable import GlowCore

/// Contract of the Hooks settings pane: checkmarks derive from on-disk
/// state (inspectAgent), and toggling runs the idempotent install /
/// uninstall against the GLOW_HOME-isolated home. Holds the global env
/// lock like the other GLOW_HOME suites.
@Suite(.serialized)
final class HookSettingsPaneTests {

    private let tmpDir: String

    init() {
        StateDirEnvLock.lock.lock()
        let dir = NSTemporaryDirectory() + "/glow-hooks-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        self.tmpDir = dir
        setenv("GLOW_HOME", dir, 1)
    }

    deinit {
        unsetenv("GLOW_HOME")
        try? FileManager.default.removeItem(atPath: tmpDir)
        StateDirEnvLock.lock.unlock()
    }

    // MARK: - Helpers

    private func codexToggle(in pane: HookSettingsPane) throws -> NSButton {
        try #require(
            pane.findAllSubviews()
                .compactMap { $0 as? NSButton }
                .first { $0.title == "Codex" },
            "Codex toggle missing"
        )
    }

    @Test @MainActor func togglesReflectInspectStateOnEmptyHome() throws {
        let pane = HookSettingsPane(frame: .zero)
        let toggle = try codexToggle(in: pane)

        #expect(toggle.state == .off)
        #expect(
            !FileManager.default.fileExists(
                atPath: HookInstaller.Agent.codex.configPath
            )
        )
    }

    @Test @MainActor func toggleInstallsThenUninstallsIdempotently() throws {
        let pane = HookSettingsPane(frame: .zero)
        let toggle = try codexToggle(in: pane)

        // On → install: config file appears, checkmark follows disk.
        toggle.performClick(nil)
        let configPath = HookInstaller.Agent.codex.configPath
        #expect(FileManager.default.fileExists(atPath: configPath))
        #expect(toggle.state == .on)
        #expect(HookInstaller.inspectAgent(.codex).installed)

        // Off → uninstall: Glow entries removed, checkmark follows disk.
        toggle.performClick(nil)
        #expect(!HookInstaller.inspectAgent(.codex).installed)
        #expect(toggle.state == .off)
    }
}
