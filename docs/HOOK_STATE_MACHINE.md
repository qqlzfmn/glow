# Glow Hook 状态转换表

> 用途：人工审查每一个 hook 事件 → 信号 → 灯效 → 会话动作的转换，按需修改。
> 修改源点：适配器映射（`Sources/GlowCore/Components/AgentMonitor/{ClaudeCodeHookAdapter,CodexHookAdapter}.swift`）、
> pi/omp 模板（`Resources/glow-hook-template.ts`，部署于 `~/.pi|~/.omp/agent/extensions/observability-glow.ts`）。
> 灯效与绿灯/黄灯/红灯语义见 `docs/LAMP_LANGUAGE.md` 与 `Sources/GlowCore/Kernel/SignalDefinition.swift`。

## 一、公共语义（所有 agent 共用）

**灯效（SIGNAL_DEFINITIONS）**

| 信号 | 灯效 |
| --- | --- |
| `idle` | 常亮绿 |
| `session_start` / `session_end` | 常亮绿 |
| `thinking` / `working` / `tool_done` | 闪烁绿 |
| `permission` / `attention` | 闪烁黄 |
| `blocked` | 闪烁红 |
| `off` | 全灭 |

**会话动作（SessionStore.applySessionSignal，按会话 key）**

| 信号类别 | 动作 |
| --- | --- |
| 普通信号（thinking/working/tool_done/attention/permission/blocked/session_start） | 写入/覆盖该 key，刷新 `updated_at` |
| `turn_end` | 该 key 当前为 `permission` / `blocked` 时**保留**（告警不被工作态清掉），否则**删除**该 key |
| `session_end` / `off` | 删除该 key |

**聚合优先级（多会话同时存在时）**

```
blocked > permission > attention > (working / thinking / tool_done) > idle
```

---

## 二、Claude Code（12 事件，`claude-code-hook`）

| 事件 | 信号 | 灯效 | 会话动作 | 触发时机 |
| --- | --- | --- | --- | --- |
| `SessionStart` | `session_start` | 常亮绿 | 写入 | 会话开始 |
| `UserPromptSubmit` | `thinking` | 闪烁绿 | 写入 | 用户提交提问 |
| `PreToolUse` | `working` | 闪烁绿 | 写入 | 工具即将执行 |
| `PostToolUse` | `tool_done` | 闪烁绿 | 写入 | 工具成功完成 |
| `PostToolUseFailure` | *(不改变状态)* | — | 保持 | 非终止失败：agent 通常会继续，红灯仅保留给失败导致停止；终止失败由 `Stop`+`stop_reason` 抛住 |
| `PreCompact` | `working` | 闪烁绿 | 写入 | 上下文压缩前 |
| `SubagentStart` | `working` | 闪烁绿 | 写入 | 子代理启动 |
| `SubagentStop` | `tool_done` | 闪烁绿 | 写入 | 子代理结束 |
| `PermissionRequest` | `permission` | 闪烁黄 ⚠️ | 写入 | 请求权限（文档称红，见备注 1） |
| `Notification` | `attention` | 闪烁黄 | 写入 | 需要你关注的通知 |
| `Stop` | `turn_end` | — | 删除（`permission`/`blocked` 保留） | 一轮回复完成 |
| `Stop` + `stop_reason` ∈ {`max_tokens`,`error`} | `blocked` | 闪烁红 | 写入 | 输出截断 / 出错 |
| `SessionEnd` | `session_end` | 常亮绿 | 删除 | 会话结束 |

---

## 三、Codex（7 事件 + 结构化失败探测，`codex-hook`）

| 事件 | 信号 | 灯效 | 会话动作 | 触发时机 |
| --- | --- | --- | --- | --- |
| `SessionStart` | `session_start` | 常亮绿 | 写入 | 会话开始 |
| `UserPromptSubmit` | `thinking` | 闪烁绿 | 写入 | 用户提交提问 |
| `PreToolUse` | `working` | 闪烁绿 | 写入 | 工具即将执行 |
| `PostToolUse` | `tool_done` | 闪烁绿 | 写入 | 工具调用完成 |
| `PermissionRequest` | `permission` | 闪烁黄 ⚠️ | 写入 | 请求权限（文档称红，见备注 1） |
| `Stop` | `turn_end` | — | 删除（`permission`/`blocked` 保留） | 一轮回复完成 |
| `SessionEnd` | `session_end` | 常亮绿 | 删除 | 会话结束 |
| 任意事件 + 失败字段 | `blocked` | 闪烁红 | 写入 | payload 含 `error`/`failed`/`failure`/`exception`/`error_type`/`error_message`/`failure_reason`/`exit_status`≠0/`status`≠ok 等（深度探测） |

> 会话 key 解析顺序：payload `session_id`/`conversation_id`/`thread_id`/`chat_id`/`codex_session_id` → 嵌套同名字段 → env `CODEX_SESSION_ID`/`CODEX_CONVERSATION_ID`/`CODEX_THREAD_ID` → `cwd:` 前缀 → `global`。

---

## 四、pi / omp（共用一个 TS 模板，经 `claude-code-hook --event <事件>` 转发）

| pi 事件 | 转发事件 | 信号 | 灯效 | 会话动作 | 触发时机 / 备注 |
| --- | --- | --- | --- | --- | --- |
| `session_start` | `SessionStart` | `session_start` | 常亮绿 | 写入 | 会话开始 |
| `input` | `UserPromptSubmit` | `thinking` | 闪烁绿 | 写入 | 交互式输入 |
| `agent_start` | `UserPromptSubmit` | `thinking` | 闪烁绿 | 写入 | headless/print 模式无 `input`，替补工作起始 |
| `tool_call` | `PreToolUse` | `working` | 闪烁绿 | 写入 | 工具即将执行 |
| `tool_result` | `PostToolUse`（含失败结果） | `tool_done` | 闪烁绿 | 写入 | 工具结果返回；`isError` 不切红——失败未停止，保持工作态 |
| `turn_end` | `Stop`（**本次修复新增**） | `turn_end` | — | 删除（`permission`/`blocked` 保留） | 一轮应答完成 |
| `session_stop` | `Stop` | `turn_end` | — | 删除（`permission`/`blocked` 保留） | 会话停止 |
| `tool_approval_requested` | `PermissionRequest` | `permission` | 闪烁黄 ⚠️ | 写入 | 请求工具权限（文档称红，见备注 1） |
| `tool_approval_resolved`（`approved=true`） | `PostToolUse` | `tool_done` | 闪烁绿 | 写入 | 批准后恢复工作态 |
| `mcp_notification` | `Notification` | `attention` | 闪烁黄 | 写入 | MCP 通知 |
| `session_before_compact` | `PreCompact` | `working` | 闪烁绿 | 写入 | 压缩前 |
| `session_shutdown` | `SessionEnd` | `session_end` | 常亮绿 | 删除 | 会话关闭 |
| `credential_disabled` | `PostToolUseFailure` + `signal: blocked` | `blocked` | 闪烁红 | 写入 | 凭据被禁用：实质失败（无法继续调用工具），显式红 |

**仅本地 JSONL 观测、不转发 Glow 的 pi 事件**（不影响灯）：`session_switch`、`session_branch`、`turn_start`、`agent_end`、`tool_execution_start/end`、`session_compact`、`auto_compaction_start/end`、`auto_retry_start/end`、`ttsr_triggered`、`tool_approval_resolved(approved=false)`。

> 会话 key 解析顺序（模板 `resolveSessionId`）：会话文件 basename 去扩展名（`<日期>T<时间>_<uuid>`）→ 拿不到时 `unnamed-<时间戳>`。

---

## 五、决策结果与已知例外（2026-09-07 第一性原理评审后对齐）

> 灯语第一性原理：**无任务 = 绿常亮；任务中 = 绿闪；需操作 = 黄闪；失败导致停止 = 红闪。**
> 已按此原则完成一轮校准：`done` 废弃、`permission` 明确为黄、非终止失败不红。

| # | 项 | 决策后状态 |
| --- | --- | --- |
| 1 | `permission` 灯色 | **已对齐为闪烁黄**（需操作=黄，含授权）；红仅保留给 `blocked`（阻塞/失败停止）。README/LAMP 已同步 |
| 2 | `done` 信号 | **已废弃**（从 `SignalDefinition` 与文档移除）。正常完成任务且 agent 等待 = `idle` 绿常亮；agent 明确要求你读/继续 = `attention` 黄；如需显式表达“完成任务待确认”，走显式 `signal` 字段直发 `attention` |
| 3 | 非终止工具失败 | **不改变状态**（保持工作态）——Claude `PostToolUseFailure` 返回 nil；pi `tool_result(isError)` 仍转 `PostToolUse`（绿）。终止失败由 `Stop`+`stop_reason`（error/max_tokens）→ `blocked` 红；pi `credential_disabled` 经显式 `signal: blocked` 红 |
| 4 | Codex 失败字段 | **保持字段级失败即红（唯一例外）**——Codex hook schema 无终止型失败信号（无 `stop_reason` 类字段），无法区分“工具失败将重试”与“致命错误”；保留红防漏报，代价是工具级失败闪红 |
| 5 | pi `agent_end` | 无转发（仅观测），`turn_end` 已覆盖同场景，保持 |
| 6 | dangling working 兜底 | 仅 24h TTL（`GLOW_SESSION_TTL_SECONDS` 可调，默认 86400s） |
| 7 | Codex key 漂移 | payload 缺会话标识时降级 `cwd:`/`global`，待实测（当前无不良证据） |