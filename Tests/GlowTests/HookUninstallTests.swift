import Testing
import Foundation
@testable import GlowCore

/// uninstall-hooks 全链路测试。套件串行执行：CLI 用例会重定向 stdout 并注入 GLOW_HOME。
@Suite(.serialized) final class HookUninstallTests {

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

    private func glowCommand(_ event: String) -> [String: Any] {
        ["type": "command", "command": "/usr/local/bin/Glow codex-hook \(event)", "timeout": 5]
    }

    /// Redirect stdout into a pipe for the duration of `block`.
    private func captureStdout(_ block: () -> Void) -> String {
        let pipe = Pipe()
        let original = dup(FileHandle.standardOutput.fileDescriptor)
        fflush(stdout)
        dup2(pipe.fileHandleForWriting.fileDescriptor, FileHandle.standardOutput.fileDescriptor)
        block()
        fflush(stdout)
        dup2(original, FileHandle.standardOutput.fileDescriptor)
        close(original)
        pipe.fileHandleForWriting.closeFile()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Inject the home used by HookInstaller's defaults (GLOW_HOME env seam;
    /// NSHomeDirectory() does not honour HOME, so setenv("HOME") is not enough).
    @discardableResult
    private func withInjectedHome<T>(_ block: () throws -> T) rethrows -> T {
        let old = getenv("GLOW_HOME").map { String(cString: $0) }
        setenv("GLOW_HOME", home, 1)
        defer {
            if let old {
                setenv("GLOW_HOME", old, 1)
            } else {
                unsetenv("GLOW_HOME")
            }
        }
        return try block()
    }

    private static let templateText =
        "// glow omp hook template\nexport const glow = true\n"

    // MARK: - JSON uninstall (codex / claude-code)

    @Test func codexUninstallRemovesGlowKeepsThirdPartyAndDropsEmptyGroups() throws {
        let configPath = HookInstaller.Agent.codex.configPath(inHome: home)
        writeJSON(
            [
                "hooks": [
                    "Stop": [
                        ["hooks": [["type": "command", "command": "echo thirdparty", "timeout": 5]]]
                    ],
                    "CustomEvent": [
                        ["hooks": [["type": "command", "command": "my-own-tool run", "timeout": 5]]]
                    ],
                ],
                "otherTopLevelKey": "must survive"
            ],
            to: configPath
        )

        try HookInstaller.installAgent(.codex, home: home)
        let status = HookInstaller.uninstallAgentAndReport(.codex, home: home)

        #expect(status.message == "uninstalled", "status: \(status.message)")
        #expect(!status.installed)

        let config = readJSON(at: configPath)
        let hooks = config["hooks"] as? [String: Any]
        #expect(hooks != nil, "top-level hooks key must be preserved even when emptied")

        let stopCommands = hookCommands(in: config, event: "Stop")
        #expect(stopCommands == ["echo thirdparty"], "third-party entry must survive: \(stopCommands)")

        #expect(hooks?["SessionStart"] == nil, "glow-only group removed, emptied event key must be dropped")

        // CustomEvent is not a codex event — uninstall only touches agent.events
        // keys, so the whole event (and its third-party hooks) must survive.
        #expect(hookCommands(in: config, event: "CustomEvent") == ["my-own-tool run"],
                "non-agent event must survive untouched")
        #expect(config["otherTopLevelKey"] as? String == "must survive")
    }

    @Test func codexUninstallIsIdempotentAndInspectReportsMissing() throws {
        try HookInstaller.installAgent(.codex, home: home)
        let first = HookInstaller.uninstallAgentAndReport(.codex, home: home)
        #expect(first.message == "uninstalled")

        let second = HookInstaller.uninstallAgentAndReport(.codex, home: home)
        #expect(second.message == "not installed", "second uninstall: \(second.message)")
        #expect(!second.installed)

        let inspect = HookInstaller.inspectAgent(.codex, home: home)
        #expect(inspect.configExists, "JSON uninstall rewrites the file, it does not delete it")
        #expect(!inspect.installed)
        #expect(inspect.message == "7 missing", "no glow entries remain: \(inspect.message)")
    }

    @Test func codexUninstallThrowsOnInvalidJSONWithoutWriting() throws {
        let configPath = HookInstaller.Agent.codex.configPath(inHome: home)
        try FileManager.default.createDirectory(
            atPath: (configPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        let broken = "{ this is not json"
        try broken.write(toFile: configPath, atomically: true, encoding: .utf8)

        #expect(throws: (any Error).self) {
            try HookInstaller.uninstallAgent(.codex, home: home)
        }
        #expect(try String(contentsOfFile: configPath, encoding: .utf8) == broken, "invalid JSON must not be touched")
    }

    @Test func claudeCodeUninstallKeepsMatcherScopedThirdPartyGroup() throws {
        try HookInstaller.installAgent(.claudeCode, home: home)
        // Add a third-party group with a non-empty matcher that must survive.
        let configPath = HookInstaller.Agent.claudeCode.configPath(inHome: home)
        var config = readJSON(at: configPath)
        var hooks = config["hooks"] as! [String: Any]
        var stopGroups = hooks["Stop"] as! [[String: Any]]
        stopGroups.append([
            "matcher": "Bash",
            "hooks": [["type": "command", "command": "matcher-tool run", "timeout": 5]],
        ])
        hooks["Stop"] = stopGroups
        config["hooks"] = hooks
        writeJSON(config, to: configPath)

        let status = HookInstaller.uninstallAgentAndReport(.claudeCode, home: home)
        #expect(status.message == "uninstalled")

        let after = readJSON(at: configPath)
        let matcherCommands = hookCommands(in: after, event: "Stop")
        #expect(matcherCommands == ["matcher-tool run"], "matcher-scoped third-party group must survive: \(matcherCommands)")
        #expect(after["hooks"] != nil)
    }

    @Test func codexUninstallCreatesBackupWithUninstallSuffix() throws {
        let configPath = HookInstaller.Agent.codex.configPath(inHome: home)
        try HookInstaller.installAgent(.codex, home: home)

        try HookInstaller.uninstallAgent(.codex, home: home)

        let dir = (configPath as NSString).deletingLastPathComponent
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir)
        let uninstallBackups = contents.filter { $0.contains(".bak-glow-uninstall-") }
        #expect(!uninstallBackups.isEmpty, "expected a .bak-glow-uninstall- backup, got \(contents)")
        #expect(contents.filter { $0.contains(".bak-glow-install-") }.isEmpty, "uninstall must not use the install backup suffix")
        guard let backupName = uninstallBackups.first else { return }
        let backup = readJSON(at: (dir as NSString).appendingPathComponent(backupName))
        #expect(hookCommands(in: backup, event: "Stop").count == 1, "backup must contain the pre-uninstall state")
    }

    // MARK: - Template uninstall (omp / pi)

    @Test func ompTemplateUninstallRemovesFileAndBacksUp() throws {
        let path = HookInstaller.Agent.omp.configPath(inHome: home)
        let installed = HookInstaller.installAgentAndReport(.omp, home: home, templateText: Self.templateText)
        #expect(installed.installed)

        let status = HookInstaller.uninstallAgentAndReport(.omp, home: home, templateText: Self.templateText)

        #expect(status.message == "uninstalled")
        #expect(!FileManager.default.fileExists(atPath: path), "template file must be removed")

        let dir = (path as NSString).deletingLastPathComponent
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.hasPrefix((path as NSString).lastPathComponent + ".bak-glow-uninstall-") }
        #expect(backups.count == 1, "expected one uninstall backup, got \(backups)")
        guard let backupName = backups.first else { return }
        let backupText = try String(
            contentsOfFile: (dir as NSString).appendingPathComponent(backupName), encoding: .utf8
        )
        #expect(backupText == Self.templateText)
    }

    @Test func piTemplateUninstallCleansLegacyResidueFile() throws {
        let path = HookInstaller.Agent.pi.configPath(inHome: home)
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let legacyPath = (dir as NSString).appendingPathComponent("observability-signal-light.ts")
        try "// legacy".write(toFile: legacyPath, atomically: true, encoding: .utf8)

        HookInstaller.installAgentAndReport(.pi, home: home, templateText: Self.templateText)
        let status = HookInstaller.uninstallAgentAndReport(.pi, home: home, templateText: Self.templateText)

        #expect(status.message == "uninstalled")
        #expect(!FileManager.default.fileExists(atPath: legacyPath), "legacy observability-signal-light.ts must be cleaned up")
        let legacyBackups = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.hasPrefix("observability-signal-light.ts.bak-glow-uninstall-") }
        #expect(legacyBackups.count == 1, "legacy residue must be backed up before deletion")
    }

    @Test func ompTemplateUninstallIsIdempotent() throws {
        let first = HookInstaller.uninstallAgentAndReport(.omp, home: home, templateText: Self.templateText)
        #expect(first.message == "not installed", "uninstall without install: \(first.message)")

        HookInstaller.installAgentAndReport(.omp, home: home, templateText: Self.templateText)
        HookInstaller.uninstallAgentAndReport(.omp, home: home, templateText: Self.templateText)
        let second = HookInstaller.uninstallAgentAndReport(.omp, home: home, templateText: Self.templateText)
        #expect(second.message == "not installed", "second uninstall: \(second.message)")
    }

    // MARK: - CLI

    @Test func cliUninstallDryRunDoesNotWrite() throws {
        try HookInstaller.installAgent(.codex, home: home)
        let configPath = HookInstaller.Agent.codex.configPath(inHome: home)
        let before = try String(contentsOfFile: configPath, encoding: .utf8)

        let output = withInjectedHome {
            captureStdout {
                _ = InstallHooksCLI.run(["uninstall-hooks", "--all", "-y", "--dry-run"], mode: .uninstall)
            }
        }

        let wouldLines = output.components(separatedBy: "\n").filter { $0.hasPrefix("Would uninstall ") }
        #expect(wouldLines.count == 4, "expected 4 Would uninstall lines, got: \(output)")
        let after = try String(contentsOfFile: configPath, encoding: .utf8)
        #expect(after == before, "--dry-run must not modify the config")
        #expect(hookCommands(in: readJSON(at: configPath), event: "Stop").count == 1)
    }

    @Test func cliUninstallAllReportsAllFourAgents() throws {
        try HookInstaller.installAgent(.codex, home: home)
        try HookInstaller.installAgent(.claudeCode, home: home)
        HookInstaller.installAgentAndReport(.omp, home: home, templateText: Self.templateText)

        let output = withInjectedHome {
            captureStdout {
                _ = InstallHooksCLI.run(["uninstall-hooks", "--all", "-y"], mode: .uninstall)
            }
        }

        #expect(output.contains("Uninstalled Codex: uninstalled"), "output: \(output)")
        #expect(output.contains("Uninstalled Claude Code: uninstalled"), "output: \(output)")
        // omp 模板内容在测试环境无法被 CLI 的 inspect 校验（bundle 模板缺失），
        // 按“卸载前 inspect 未 installed”语义报 not installed；模板型卸载语义
        // 已由 ompTemplateUninstall* 三个 API 级测试覆盖。
        #expect(output.contains("Uninstalled omp: not installed"), "output: \(output)")
        #expect(output.contains("Uninstalled pi: not installed"), "output: \(output)")
    }
}
