import AppKit

// MARK: - Signal Color

enum SignalColor {
    case green, yellow, red, grey

    /// Stable string key for the color (used by the detail panel).
    var colorKey: String {
        switch self {
        case .green:  return "green"
        case .yellow: return "yellow"
        case .red:    return "red"
        case .grey:   return "grey"
        }
    }

    var nsColor: NSColor {
        switch self {
        case .green:  return NSColor(red: 76/255,  green: 175/255, blue: 80/255,  alpha: 1)
        case .yellow: return NSColor(red: 255/255, green: 193/255, blue: 7/255,   alpha: 1)
        case .red:    return NSColor(red: 244/255, green: 67/255,  blue: 54/255,  alpha: 1)
        case .grey:   return NSColor(red: 158/255, green: 158/255, blue: 158/255, alpha: 1)
        }
    }

    var dimColor: NSColor {
        switch self {
        case .green:  return NSColor(red: 76/255,  green: 175/255, blue: 80/255,  alpha: 0.3)
        case .yellow: return NSColor(red: 255/255, green: 193/255, blue: 7/255,   alpha: 0.3)
        case .red:    return NSColor(red: 244/255, green: 67/255,  blue: 54/255,  alpha: 0.3)
        case .grey:   return NSColor(red: 158/255, green: 158/255, blue: 158/255, alpha: 0.3)
        }
    }
}

// MARK: - Signal Definition

struct SignalDefinition {
    let name: String
    let summary: String
    let color: SignalColor
    let isRepeating: Bool
    /// For repeating signals: which color flashes.
    let flashColor: SignalColor
}

// MARK: - Signal Registry

let SIGNAL_DEFINITIONS: [String: SignalDefinition] = [
    "idle": SignalDefinition(
        name: "idle", summary: "Agent 空闲。",
        color: .green, isRepeating: false, flashColor: .green
    ),
    "thinking": SignalDefinition(
        name: "thinking", summary: "Agent 已收到任务，正在思考或工作。",
        color: .green, isRepeating: true, flashColor: .green
    ),
    "working": SignalDefinition(
        name: "working", summary: "Agent 正在执行工具、读写文件、跑命令或测试。",
        color: .green, isRepeating: true, flashColor: .green
    ),
    "tool_done": SignalDefinition(
        name: "tool_done", summary: "一次工具调用完成，Agent 仍处于工作流中。",
        color: .green, isRepeating: true, flashColor: .green
    ),
    "attention": SignalDefinition(
        name: "attention", summary: "Agent 停下来等你读结果或继续回复。",
        color: .yellow, isRepeating: true, flashColor: .yellow
    ),
    "permission": SignalDefinition(
        name: "permission", summary: "Codex 请求授权或需要你明确批准。",
        color: .yellow, isRepeating: true, flashColor: .yellow
    ),
    "blocked": SignalDefinition(
        name: "blocked", summary: "Agent 遇到阻塞、失败或无法继续。",
        color: .red, isRepeating: true, flashColor: .red
    ),
    "done": SignalDefinition(
        name: "done", summary: "任务已完成。",
        color: .yellow, isRepeating: true, flashColor: .yellow
    ),
    "session_start": SignalDefinition(
        name: "session_start", summary: "Codex 会话开始。",
        color: .green, isRepeating: false, flashColor: .green
    ),
    "session_end": SignalDefinition(
        name: "session_end", summary: "Codex 会话结束，回到当前聚合状态。",
        color: .green, isRepeating: false, flashColor: .green
    ),
    "off": SignalDefinition(
        name: "off", summary: "关闭所有灯。",
        color: .grey, isRepeating: false, flashColor: .grey
    ),
]

// MARK: - Signal Semantics

/// Signal-name classification used by aggregation and session lifecycle rules.
/// Single source of truth — both `aggregateSignal` and `SessionStore` read these sets.
enum SignalSemantics {
    static let red: Set<String> = ["blocked"]
    static let yellow: Set<String> = ["permission", "attention", "done"]
    static let working: Set<String> = ["thinking", "working", "tool_done"]
    static let sessionEnd: Set<String> = ["session_end"]
    static let sessionClear: Set<String> = ["off"]
    static let turnEnd: Set<String> = ["turn_end"]
    /// On `turn_end`, a session currently in one of these states is kept.
    static let turnEndKeep: Set<String> = ["permission", "blocked"]
}

// MARK: - Aggregate

/// Priority: blocked > permission > attention > working > idle
func aggregateSignal(from sessions: [String: SessionEntry]) -> String {
    let signals = sessions.values.map(\.signal)

    if signals.contains(where: { SignalSemantics.red.contains($0) }) {
        return "blocked"
    }
    if signals.contains("permission") {
        return "permission"
    }
    if signals.contains(where: { SignalSemantics.yellow.contains($0) }) {
        return "attention"
    }
    if signals.contains(where: { SignalSemantics.working.contains($0) }) {
        return "working"
    }
    return "idle"
}
