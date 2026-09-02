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

    /// Home 注入点：默认 NSHomeDirectory()；测试/验收通过 `GLOW_HOME` 环境变量
    /// 重定向（NSHomeDirectory 不读 HOME env，故用独立变量名）。
    static var defaultHome: String {
        ProcessInfo.processInfo.environment["GLOW_HOME"] ?? NSHomeDirectory()
    }

    /// `templateText` 为注入值（测试用）；默认 nil 时从 bundle 读取模板文本。
    static func inspectAgent(
        _ agent: Agent, home: String = defaultHome, templateText: String? = nil
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
        _ agent: Agent, home: String = defaultHome, templateText: String? = nil
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
        _ agent: Agent, home: String = defaultHome, templateText: String? = nil
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

    // MARK: - Uninstall

    /// install 的对称逆操作。
    /// - 模板型（omp/pi）：删除目标扩展文件（存在时先备份）；顺带清理同目录
    ///   旧名残留 `observability-signal-light.ts`。文件不存在时静默返回（幂等）。
    /// - JSON 型（codex/claude-code）：从 `hooks` 中移除所有 Glow 识别器匹配的
    ///   条目（含历史兼容子串），组空删组、事件空删键；顶层 `hooks` 键保留
    ///   （即使为空字典）。无效 JSON 直接 throw，绝不半改。
    static func uninstallAgent(
        _ agent: Agent, home: String = defaultHome, templateText: String? = nil
    ) throws {
        if agent.isTemplateInstall {
            let target = agent.configPath(inHome: home)
            let dir = (target as NSString).deletingLastPathComponent
            let legacy = (dir as NSString).appendingPathComponent("observability-signal-light.ts")
            for path in [target, legacy] where FileManager.default.fileExists(atPath: path) {
                backupConfig(at: path, flavor: "uninstall")
                try FileManager.default.removeItem(atPath: path)
            }
            return
        }

        let path = agent.configPath(inHome: home)
        guard FileManager.default.fileExists(atPath: path) else { return } // 幂等 no-op
        var (config, validJson) = loadJSONConfig(at: path)
        guard validJson else {
            throw InstallError.invalidJSON
        }
        guard var hooks = config["hooks"] as? [String: Any] else { return } // 无 hooks 键 → 无可卸载

        var changed = false
        for event in agent.events.keys {
            guard let groups = hooks[event] as? [Any] else { continue }
            var newGroups: [Any] = []
            for group in groups {
                guard let groupDict = group as? [String: Any],
                      let groupHooks = groupDict["hooks"] as? [Any] else {
                    newGroups.append(group)
                    continue
                }
                let kept = groupHooks.filter { entry in
                    guard let hook = entry as? [String: Any],
                          hook["type"] as? String == "command",
                          isGlowCommand(hook["command"] as? String, agent: agent) else {
                        return true
                    }
                    changed = true
                    return false
                }
                if kept.isEmpty {
                    changed = true // 组内 hooks 为空 → 删该组
                    continue
                }
                if kept.count != groupHooks.count {
                    var newGroup = groupDict
                    newGroup["hooks"] = kept
                    newGroups.append(newGroup)
                } else {
                    newGroups.append(group)
                }
            }
            if newGroups.isEmpty {
                hooks.removeValue(forKey: event) // 事件数组为空 → 删该事件键
            } else if changed {
                hooks[event] = newGroups
            }
        }

        guard changed else { return } // 无变更 → 幂等 no-op
        config["hooks"] = hooks // 顶层 hooks 键保留（即使为空字典）

        backupConfig(at: path, flavor: "uninstall")
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: config, options: [.prettyPrinted, .withoutEscapingSlashes]
        )
        guard var text = String(data: data, encoding: .utf8) else {
            throw InstallError.encodingFailed
        }
        text += "\n"
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Uninstall hooks for the given agent. Returns the status after uninstall.
    /// `message` 语义：卸载前已安装（配置文件存在）→ "uninstalled"；
    /// 本来就没装 → "not installed"。失败通过 "uninstall failed: …" 上报。
    @discardableResult
    static func uninstallAgentAndReport(
        _ agent: Agent, home: String = defaultHome, templateText: String? = nil
    ) -> AgentStatus {
        let before = inspectAgent(agent, home: home, templateText: templateText)
        do {
            try uninstallAgent(agent, home: home, templateText: templateText)
        } catch {
            var status = inspectAgent(agent, home: home, templateText: templateText)
            status.message = "uninstall failed: \(error)"
            return status
        }
        var status = inspectAgent(agent, home: home, templateText: templateText)
        status.message = before.installed ? "uninstalled" : "not installed"
        return status
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

    /// `flavor`：install 写 `.bak-glow-install-<stamp>`，uninstall 写 `.bak-glow-uninstall-<stamp>`。
    private static func backupConfig(at path: String, flavor: String = "install") {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let backupPath = path + ".bak-glow-\(flavor)-\(stamp)"
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
        case invalidJSON
    }
}
