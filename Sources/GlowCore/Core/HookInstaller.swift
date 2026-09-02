import Foundation

/// Install and repair local agent hook configuration.
enum HookInstaller {

    // MARK: - Constants

    /// The hook command that agents will invoke. Points back at this binary.
    /// When compiled into the app bundle, the executable is at Contents/MacOS/Glow.
    private static var executablePath: String {
        Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments[0]
    }

    static func codexHookCommand() -> String {
        return "\(executablePath) codex-hook"
    }

    static func claudeCodeHookCommand() -> String {
        return "\(executablePath) claude-code-hook"
    }

    // MARK: - Inspection

    /// `templateText` 为注入值（测试用）；默认 nil 时从 bundle 读取模板文本。
    static func inspectAgent(
        _ agent: Agent, home: String = NSHomeDirectory(), templateText: String? = nil
    ) -> AgentStatus {
        if agent.isTemplateInstall {
            let path = agent.configPath(inHome: home)
            let exists = FileManager.default.fileExists(atPath: path)
            let expected = templateText ?? loadTemplateText()
            let matches = exists
                && (try? String(contentsOfFile: path, encoding: .utf8)) == expected
            return AgentStatus(
                agent: agent,
                installed: matches,
                configExists: exists,
                validJson: true,
                missingEvents: [],
                brokenEvents: [],
                message: !exists ? "missing" : (matches ? "installed" : "outdated")
            )
        }
        let configExists = FileManager.default.fileExists(atPath: agent.configPath(inHome: home))

        let (config, validJson) = loadJSONConfig(at: agent.configPath(inHome: home))

        guard configExists else {
            return AgentStatus(
                agent: agent,
                installed: false,
                configExists: false,
                validJson: true,
                missingEvents: Array(agent.events.keys),
                brokenEvents: [],
                message: "config missing"
            )
        }

        guard validJson else {
            return AgentStatus(
                agent: agent,
                installed: false,
                configExists: true,
                validJson: false,
                missingEvents: Array(agent.events.keys),
                brokenEvents: [],
                message: "invalid JSON"
            )
        }

        guard let hooks = config["hooks"] as? [String: Any] else {
            return AgentStatus(
                agent: agent,
                installed: false,
                configExists: true,
                validJson: true,
                missingEvents: Array(agent.events.keys),
                brokenEvents: [],
                message: "hooks missing"
            )
        }

        var missing: [String] = []
        var broken: [String] = []
        for event in agent.events.keys {
            let entries: Any? = hooks[event]
            if entries == nil {
                missing.append(event)
            } else if !eventHasExpectedHook(entries: entries!, agent: agent, event: event) {
                broken.append(event)
            }
        }

        let installed = missing.isEmpty && broken.isEmpty
        let message: String
        if installed {
            message = "installed"
        } else if !missing.isEmpty && !broken.isEmpty {
            message = "\(missing.count) missing, \(broken.count) broken"
        } else if !missing.isEmpty {
            message = "\(missing.count) missing"
        } else {
            message = "\(broken.count) broken"
        }

        return AgentStatus(
            agent: agent,
            installed: installed,
            configExists: configExists,
            validJson: true,
            missingEvents: missing,
            brokenEvents: broken,
            message: message
        )
    }

    // MARK: - Install

    /// `templateText` 为注入值（测试用）；默认 nil 时从 bundle 读取模板文本。
    static func installAgent(
        _ agent: Agent, home: String = NSHomeDirectory(), templateText: String? = nil
    ) throws {
        if agent.isTemplateInstall {
            try installTemplateHook(agent: agent, home: home, templateText: templateText)
            return
        }
        var (config, validJson) = loadJSONConfig(at: agent.configPath(inHome: home))
        if !validJson {
            config = [:]
        }

        let originalText = try? String(contentsOfFile: agent.configPath(inHome: home), encoding: .utf8)

        // Ensure hooks dict exists.
        var hooks = (config["hooks"] as? [String: Any]) ?? [:]
        for (event, timeout) in agent.events {
            hooks[event] = mergeEventGroups(
                existingEntries: hooks[event],
                agent: agent,
                event: event,
                timeout: timeout
            )
        }
        config["hooks"] = hooks

        let newData = try JSONSerialization.data(
            withJSONObject: config, options: [.prettyPrinted, .withoutEscapingSlashes]
        )
        guard let newText = String(data: newData, encoding: .utf8) else {
            throw InstallError.encodingFailed
        }
        let newTextNL = newText + "\n"

        if originalText == newTextNL {
            return // unchanged
        }

        // Backup existing config.
        if FileManager.default.fileExists(atPath: agent.configPath(inHome: home)) {
            backupConfig(at: agent.configPath(inHome: home))
        }

        // Write.
        let dir = (agent.configPath(inHome: home) as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try newTextNL.write(toFile: agent.configPath(inHome: home), atomically: true, encoding: .utf8)
    }

    /// Install hooks for the given agent. Returns the status after install.
    /// A failed install is reported via `message` ("install failed: …") instead
    /// of being silently swallowed.
    @discardableResult
    static func installAgentAndReport(
        _ agent: Agent, home: String = NSHomeDirectory(), templateText: String? = nil
    ) -> AgentStatus {
        do {
            try installAgent(agent, home: home, templateText: templateText)
        } catch {
            var status = inspectAgent(agent, home: home, templateText: templateText)
            status.message = "install failed: \(error)"
            return status
        }
        return inspectAgent(agent, home: home, templateText: templateText)
    }

    // MARK: - Internal helpers

    private static func loadJSONConfig(at path: String) -> ([String: Any], Bool) {
        guard let data = FileManager.default.contents(atPath: path) else {
            return ([:], true)
        }
        do {
            let parsed = try JSONSerialization.jsonObject(with: data)
            guard let dict = parsed as? [String: Any] else {
                return ([:], false)
            }
            return (dict, true)
        } catch {
            return ([:], false)
        }
    }

    private static func backupConfig(at path: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let backupPath = path + ".bak-glow-install-\(stamp)"
        try? FileManager.default.copyItem(atPath: path, toPath: backupPath)
    }

    // MARK: - Template install (omp / pi)

    /// 模板文本（安装与 inspect 对比用）；bundle 读不到时为 nil。
    static func loadTemplateText() -> String? {
        guard let url = Bundle.main.url(
            forResource: "glow-hook-template", withExtension: "ts"
        ) else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// omp/pi 的 hook 是 TS 扩展模板（bundle 内 `glow-hook-template.ts`），
    /// 安装 = 复制到 agent 的用户级扩展目录，内容一致时幂等跳过。
    private static func installTemplateHook(
        agent: Agent, home: String, templateText: String? = nil
    ) throws {
        guard let template = templateText ?? loadTemplateText() else {
            throw InstallError.templateMissing
        }
        let target = agent.configPath(inHome: home)

        if let existing = try? String(contentsOfFile: target, encoding: .utf8),
           existing == template {
            return
        }

        if FileManager.default.fileExists(atPath: target) {
            backupConfig(at: target)
        }
        let dir = (target as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try template.write(toFile: target, atomically: true, encoding: .utf8)
    }

    enum InstallError: Error {
        case encodingFailed
        case templateMissing
    }
}
