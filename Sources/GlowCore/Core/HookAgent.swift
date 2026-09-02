import Foundation

extension HookInstaller {

    // MARK: - Constants

    static let codexEvents: [String: Int] = [
        "SessionStart": 5,
        "UserPromptSubmit": 5,
        "PreToolUse": 5,
        "PostToolUse": 5,
        "PermissionRequest": 10,
        "Stop": 5,
        "SessionEnd": 5,
    ]

    static let claudeCodeEvents: [String: Int] = [
        "SessionStart": 5,
        "UserPromptSubmit": 5,
        "PreToolUse": 5,
        "PostToolUse": 5,
        "PostToolUseFailure": 5,
        "PreCompact": 5,
        "SubagentStart": 5,
        "SubagentStop": 5,
        "PermissionRequest": 10,
        "Notification": 5,
        "Stop": 5,
        "SessionEnd": 5,
    ]

    // MARK: - Types

    enum Agent: String, CaseIterable {
        case codex
        case claudeCode = "claude-code"
        case omp
        case pi = "pi"

        var displayName: String {
            switch self {
            case .codex: return "Codex"
            case .claudeCode: return "Claude Code"
            case .omp: return "omp"
            case .pi: return "pi"
            }
        }

        func configPath(inHome home: String) -> String {
            switch self {
            case .codex:
                return (home as NSString).appendingPathComponent(".codex/hooks.json")
            case .claudeCode:
                return (home as NSString).appendingPathComponent(".claude/settings.json")
            case .omp:
                return (home as NSString)
                    .appendingPathComponent(".omp/agent/extensions/observability-glow.ts")
            case .pi:
                return (home as NSString)
                    .appendingPathComponent(".pi/agent/extensions/observability-glow.ts")
            }
        }

        var configPath: String {
            configPath(inHome: NSHomeDirectory())
        }

        var events: [String: Int] {
            switch self {
            case .codex: return codexEvents
            case .claudeCode: return claudeCodeEvents
            case .omp, .pi: return [:]
            }
        }

        var passesEventArg: Bool {
            switch self {
            case .codex: return true
            case .claudeCode, .omp, .pi: return false
            }
        }

        var usesMatcher: Bool {
            switch self {
            case .codex: return false
            case .claudeCode: return true
            case .omp, .pi: return false
            }
        }

        func hookCommand(for event: String) -> String {
            if passesEventArg {
                return "\(hookScript) \(event)"
            }
            return hookScript
        }

        var hookScript: String {
            switch self {
            case .codex: return codexHookCommand()
            case .claudeCode: return claudeCodeHookCommand()
            case .omp, .pi: return ""
            }
        }

        /// omp/pi 是文件复制型 agent：把 TS hook 模板装进扩展目录，无 JSON 配置。
        var isTemplateInstall: Bool {
            switch self {
            case .codex, .claudeCode: return false
            case .omp, .pi: return true
            }
        }
    }

    struct AgentStatus {
        let agent: Agent
        let installed: Bool
        let configExists: Bool
        let validJson: Bool
        let missingEvents: [String]
        let brokenEvents: [String]
        var message: String
    }
}
