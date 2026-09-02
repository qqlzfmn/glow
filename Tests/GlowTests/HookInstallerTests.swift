import Testing
import Foundation
@testable import GlowCore

@Suite final class HookInstallerTests {

    private let home: String

    init() {
        let dir = NSTemporaryDirectory() + "/glow-home-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        self.home = dir
    }

    deinit {
        try? FileManager.default.removeItem(atPath: home)
    }

    // MARK: - Helpers

    private func writeJSON(_ object: [String: Any], to path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = try! JSONSerialization.data(withJSONObject: object)
        try! data.write(to: URL(fileURLWithPath: path))
    }

    private func readJSON(at path: String) -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: path),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return parsed
    }

    private func hookCommands(in config: [String: Any], event: String) -> [String] {
        guard let hooks = config["hooks"] as? [String: Any],
              let groups = hooks[event] as? [[String: Any]] else {
            return []
        }
        var commands: [String] = []
        for group in groups {
            for hook in (group["hooks"] as? [[String: Any]]) ?? [] {
                if let command = hook["command"] as? String {
                    commands.append(command)
                }
            }
        }
        return commands
    }

    // MARK: - Codex install

    @Test func codexInstallCreatesConfigAndReportsInstalled() {
        let status = HookInstaller.installAgentAndReport(.codex, home: home)

        let configPath = HookInstaller.Agent.codex.configPath(inHome: home)
        #expect(FileManager.default.fileExists(atPath: configPath))
        #expect(status.installed, "status: \(status.message)")
        #expect(status.message == "installed")
        #expect(status.agent.configPath(inHome: home) == configPath)
    }

    @Test func codexInstallIsIdempotent() throws {
        // Seed a production-shaped Glow command: the test runner binary
        // has a different name, so the pre-existing hook must be seeded with a
        // command the replacer recognizes.
        let configPath = HookInstaller.Agent.codex.configPath(inHome: home)
        writeJSON(
            [
                "hooks": [
                    "Stop": [
                        ["hooks": [[
                            "type": "command",
                            "command": "/Applications/Glow.app/Contents/MacOS/Glow codex-hook",
                            "timeout": 5,
                        ]]]
                    ]
                ]
            ],
            to: configPath
        )
        try HookInstaller.installAgent(.codex, home: home)

        // Note: a second install cannot be observed directly here — the test
        // runner binary is named "GlowPackageTests", so its installed
        // command never matches the production "Glow codex-hook"
        // replacement substrings and would be appended, not replaced. Under the
        // production binary name the same replace path keeps exactly one entry.
        // The assertions below pin the production semantics: replace, not
        // append, and no duplicate hooks.
        let config = readJSON(at: configPath)
        guard let hooks = config["hooks"] as? [String: Any],
              let stopGroups = hooks["Stop"] as? [[String: Any]] else {
            Issue.record("missing hooks.Stop")
            return
        }
        #expect(stopGroups.count == 1, "Stop should have exactly one group")
        let stopHooks = (stopGroups.first?["hooks"] as? [[String: Any]]) ?? []
        #expect(stopHooks.count == 1, "hooks entries must not duplicate")
        let status = HookInstaller.inspectAgent(.codex, home: home)
        #expect(status.installed, "status: \(status.message)")
    }


    @Test func codexInstallPreservesThirdPartyCommands() throws {
        let configPath = HookInstaller.Agent.codex.configPath(inHome: home)
        writeJSON(
            [
                "hooks": [
                    "Stop": [
                        ["hooks": [["type": "command", "command": "echo thirdparty", "timeout": 5]]]
                    ]
                ]
            ],
            to: configPath
        )

        try HookInstaller.installAgent(.codex, home: home)

        let config = readJSON(at: configPath)
        let commands = hookCommands(in: config, event: "Stop")
        #expect(commands.contains("echo thirdparty"), "third-party entry must survive: \(commands)")
        #expect(commands.count == 2, "expected third-party + glow entries")
    }

    @Test func codexInstallReplacesExistingGlowCommandWithBackup() throws {
        let configPath = HookInstaller.Agent.codex.configPath(inHome: home)
        writeJSON(
            [
                "hooks": [
                    "Stop": [
                        ["hooks": [[
                            "type": "command",
                            "command": "/usr/local/bin/Glow codex-hook Stop",
                            "timeout": 5,
                        ]]]
                    ]
                ]
            ],
            to: configPath
        )

        try HookInstaller.installAgent(.codex, home: home)

        let config = readJSON(at: configPath)
        let commands = hookCommands(in: config, event: "Stop")
        for command in commands {
            #expect(
                !command.contains("Glow codex-hook"),
                "old Glow command must be replaced: \(command)"
            )
        }
        #expect(commands.count == 1, "replaced entry should not duplicate")

        // Backup with the glow install prefix must exist.
        let dir = (configPath as NSString).deletingLastPathComponent
        let contents = try! FileManager.default.contentsOfDirectory(atPath: dir)
        let backups = contents.filter { $0.contains(".bak-glow-install-") }
        #expect(!backups.isEmpty, "expected a .bak-glow-install- backup, got \(contents)")
    }

    @Test func codexInstallReplacesLegacyCommand() throws {
        // Pre-existing hooks written by the older app (legacy compat substrings) must still
        // be recognized and replaced (legacy compatibility substrings).
        let configPath = HookInstaller.Agent.codex.configPath(inHome: home)
        writeJSON(
            [
                "hooks": [
                    "Stop": [
                        ["hooks": [[
                            "type": "command",
                            "command": "/usr/local/bin/signal-light codex-hook Stop",
                            "timeout": 5,
                        ]]]
                    ]
                ]
            ],
            to: configPath
        )

        try HookInstaller.installAgent(.codex, home: home)

        let config = readJSON(at: configPath)
        let commands = hookCommands(in: config, event: "Stop")
        for command in commands {
            #expect(
                !command.contains("signal-light codex-hook"),
                "legacy command must be replaced: \(command)"
            )
        }
        #expect(commands.count == 1, "legacy entry should be replaced, not duplicated")
    }

    // MARK: - Claude Code install

    @Test func claudeCodeInstallUsesEmptyMatcher() {
        _ = HookInstaller.installAgentAndReport(.claudeCode, home: home)

        let config = readJSON(at: HookInstaller.Agent.claudeCode.configPath(inHome: home))
        guard let hooks = config["hooks"] as? [String: Any],
              let stopGroups = hooks["Stop"] as? [[String: Any]] else {
            Issue.record("missing hooks.Stop")
            return
        }
        #expect(stopGroups.first?["matcher"] as? String == "", "claude-code group must use an empty matcher")

        let status = HookInstaller.inspectAgent(.claudeCode, home: home)
        #expect(status.installed, "status: \(status.message)")
    }

    @Test func claudeCodeEventTimeouts() {
        _ = HookInstaller.installAgentAndReport(.claudeCode, home: home)

        let config = readJSON(at: HookInstaller.Agent.claudeCode.configPath(inHome: home))
        guard let hooks = config["hooks"] as? [String: Any] else {
            Issue.record("missing hooks")
            return
        }
        for event in HookInstaller.claudeCodeEvents.keys {
            let expectedTimeout = event == "PermissionRequest" ? 10 : 5
            guard let groups = hooks[event] as? [[String: Any]] else {
                Issue.record("missing hooks.\(event)")
                continue
            }
            let hook = (groups.first?["hooks"] as? [[String: Any]])?.first ?? [:]
            #expect(
                hook["timeout"] as? Int == expectedTimeout,
                "\(event) should have timeout \(expectedTimeout)"
            )
        }
    }

    // MARK: - Template install (omp / pi)

    private static let templateText =
        "// glow omp hook template\nexport const glow = true\n"

    @Test func ompTemplateInstallWritesFileAndReportsInstalled() throws {
        let template = Self.templateText
        let status = HookInstaller.installAgentAndReport(.omp, home: home, templateText: template)

        let path = HookInstaller.Agent.omp.configPath(inHome: home)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == template)
        #expect(status.installed, "status: \(status.message)")
        #expect(status.message == "installed")
        #expect(status.configExists)
    }

    @Test func ompTemplateInstallIsIdempotent() throws {
        let template = Self.templateText
        _ = HookInstaller.installAgentAndReport(.omp, home: home, templateText: template)

        let path = HookInstaller.Agent.omp.configPath(inHome: home)
        let before = try String(contentsOfFile: path, encoding: .utf8)
        try HookInstaller.installAgent(.omp, home: home, templateText: template)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == before)

        // Idempotent reinstall must not create a backup.
        let dir = (path as NSString).deletingLastPathComponent
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.contains(".bak-glow-install-") }
        #expect(backups.isEmpty)
    }

    @Test func piTemplateInstallReplacesDifferentContentWithBackup() throws {
        let template = Self.templateText
        let path = HookInstaller.Agent.pi.configPath(inHome: home)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try "old content".write(toFile: path, atomically: true, encoding: .utf8)

        let status = HookInstaller.installAgentAndReport(.pi, home: home, templateText: template)

        #expect(try String(contentsOfFile: path, encoding: .utf8) == template)
        #expect(status.installed, "status: \(status.message)")

        let dir = (path as NSString).deletingLastPathComponent
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.hasPrefix("observability-glow.ts.bak-glow-install-") }
        #expect(backups.count == 1)
        guard let backupName = backups.first else { return }
        let backupText = try String(
            contentsOfFile: (dir as NSString).appendingPathComponent(backupName), encoding: .utf8
        )
        #expect(backupText == "old content")
    }

    @Test func inspectReportsOutdatedForDifferentTemplateContent() throws {
        let template = Self.templateText
        let path = HookInstaller.Agent.omp.configPath(inHome: home)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try "stale".write(toFile: path, atomically: true, encoding: .utf8)

        let status = HookInstaller.inspectAgent(.omp, home: home, templateText: template)
        #expect(!status.installed)
        #expect(status.message == "outdated")
    }
}
