# Badge 自动跟随 Agent Provider 计划

> 状态：调研完备（2026-09-05，结论全部本机实证），方案待拍板 3 点后即可开工。
> 需求：agent 切换模型/provider 后，菜单栏 usage badge 自动切到对应 provider 的用量显示。

## 结论

不依赖任何 agent 的 "model changed" 专门事件：Glow 已在接收的四路状态事件流
（claude-code-hook / codex-hook / pi / omp 扩展）中，每个事件点都能读到"当前
模型"，切换后下一个事件自动带出新值（读当前值而非变更通知，丢事件可自愈）。
改动全部落在现有通道：hook/扩展捎带 model → 内置规则映射 provider → 会话记录
附带 → badge 显示优先级加一档"跟随"。

原则：凭据仍严格显式配置（usage.json），联动只在**已配置的 provider 之间**切换
显示；用户钉选（badge_provider）是显式意图，优先于自动跟随；映射不命中即回退
现状，绝不猜错。

## 调研证据（本机实证，2026-09-05）

| Agent | 读法 | 证据 |
| --- | --- | --- |
| pi | 任意事件 handler 内 `ctx.model.provider` / `ctx.model.id` | 官方 extensions.md：ctx.model is the active model |
| omp | 同 pi（同源 API，模板互通） | @oh-my-pi/pi-coding-agent CHANGELOG 含 model_select |
| Codex | 每个 hook 的 stdin JSON 自带 `model` 字段，且为 required | codex 0.153.2 二进制内嵌 JSON Schema（PreToolUse/PostToolUse/PermissionRequest/PostCompact 均含） |
| Claude Code | hook stdin 无 model，但有 `transcript_path` → 读日志尾部 assistant 消息的 `model` | 2.1.260 探针实测 stdin 字段；本机会话日志实测 `model: "glm-5.3-flash"` |

时序无盲区：PreToolUse/PostToolUse 触发前 assistant 消息已写日志，读到的是本
turn 的 model。statusline 通道（含 model 对象）实测 `-p` 模式不触发且需用户配
置，侵入性强，弃用。

**本机特殊约束**：Claude Code env 块是本地代理
（`ANTHROPIC_BASE_URL=http://127.0.0.1:15721`、`PROXY_MANAGED`、env 模型名全为
claude-* 伪装）——按 BASE_URL 域名识别 provider 此路不通；transcript 里的
model 反而是真实模型名（glm-5.3-flash）。因此映射以 hook 实测 model id 为主，
env 不参与。

## 方案

### 数据流

```
claude-code-hook → stdin.model（扩展/Codex 直供）或 transcript 尾部
codex-hook      → stdin.model（schema required）
pi/omp 模板     → forwardGlow stdin 统一加 model 字段
      ↓ HookAgent → ProviderMapping.map(modelId) → providerKey（nil=不跟随）
SessionEntry 加 model / provider_key（optional，旧文件解码兼容）
      ↓ SessionStore 聚合（与灯色同源：信号优先级 → updated_at 最新会话）
badge 目标 = 跟随开 && 活跃会话 provider 已配置 → badgeProvider ?? order.first
```

### 1. model → provider 映射（新 `Kernel/ProviderMapping.swift`，纯函数）

内置子串规则（大小写不敏感）映射到 Glow 的 provider key：
`glm→glm`、`kimi→kimi`、`minimax→minimax`、`deepseek→deepseek`、
`gpt-*/o系/codex→openai`、`claude→anthropic`；其余不命中返回 nil（不跟随）。
usage.json 顶层可选 `model_map`（如 `{"my-custom": "glm"}`）覆盖/扩展规则，
应对模型名漂移。规则表与覆盖都以"不命中= nil"兜底。

### 2. 会话记录附带 model（SessionState + HookAgent）

- `SessionEntry` 加 `model: String?`、`providerKey: String?`
  （CodingKeys `model` / `provider_key`），Codable optional 天然向后兼容。
- `HookAgent` 处理事件写 sessions.json 时附带：payload 有 `model` 直接过映射
  （覆盖 Codex 与 pi/omp 模板两条路）；没有则从 `transcript_path` 读尾部
  （最后 ~64KB，倒序找首条含 `message.model` 的 assistant 行），读不到保留
  旧值（新会话空日志，幂等无害）。

### 3. badge 目标优先级（UsageMonitor / UsageBadge / StatusBarController）

- usage.json 新开关 `follow_agent: Bool?`（nil = 默认开，见拍板点 2）。
- 显示目标：`follow_agent && 活跃会话 providerKey 已配置` → 该 provider；
  否则完全现状（`badgeProvider ?? order.first`）。
- 钉选仍为最高优先（显式意图压自动）：想启用联动请取消钉选；菜单行 ✓ 语义
  不变（仍表钉选），跟随只在 badge 实际生效目标上体现。

### 4. pi/omp 模板（Resources/glow-hook-template.ts）

`forwardGlow` 的 stdin 加一个字段：
`model: ctx.model ? ctx.model.provider + "/" + ctx.model.id : undefined`。
不新增 model_select 转发事件——模型切换后下一个 turn_start/PreToolUse 必然带
出新值（KISS；避免向适配器引入无信号语义的新事件名）。模板改动后需重装
hooks（uninstall + install）。

## 待拍板（3 点，含建议）

1. **多 agent 并发**各用不同 provider 时 badge 跟谁：建议与灯色聚合同源
   （信号优先级 → updated_at 最新会话）取其 provider。
2. **follow_agent 默认值**：建议默认开（用户主动要的联动；映射不命中自动
   回退，风险可控）。
3. **映射表形态**：建议内置规则 + usage.json `model_map` 覆盖，暂不做设置
   窗口 UI（YAGNI，等真实需要再进设置页）。

## 测试计划

- ProviderMapping 纯函数 fixture：命中/大小写/model_map 覆盖/不命中 nil。
- ClaudeCodeHookAdapter：stdin 带 model → SessionEntry.provider_key；stdin 无
  model + transcript fixture → 读尾部；空 transcript → 保留旧值。
- CodexHookAdapter：payload["model"] 解析入会话记录。
- badge 目标优先级：跟随开 + 活跃 → 活跃；钉选 → 钉选；无活跃/未配置 →
  order.first；跟随关 → 现状。
- 照抄 StateDirEnvLock + home: 注入模式，不碰真实配置。

## 风险与对策

- **claude-* 歧义**（直连 vs 代理伪装）：以 hook 实测 model 为准、env 不参与
  ——本机代理场景 transcript 是真名，天然正确；直连场景 claude-* → anthropic
  正确。
- **模型名漂移**：model_map 覆盖 + 不命中不猜。
- **transcript 大文件**：只读尾部 64KB。
- **pi ctx.model 未加载**：模板 `?.` 防护，空值不写字段。
- 不触碰 isGlowCommand 识别器与 orca 第三方 hook。

## 验收

1. `swift test` 全绿。
2. 真机走查：Claude Code（GLM 代理）跑会话 → badge 自动变 GLM；
   `echo '{"event":"PreToolUse","session_id":"demo","model":"gpt-5.6"}' | Glow codex-hook`
   → badge 变 openai（若已配置）；映射不命中 → 回退现状；钉选后不跟随。
3. 模板重装后 omp/pi 会话正常联动。

## 执行顺序

ProviderMapping + 测试 → SessionEntry 字段 + HookAgent 解析（stdin.model 路径）
→ transcript 尾部读取 → badge 目标优先级 + 开关 → 模板 model 字段 + 重装 hooks
→ 全量测试 → 真机走查 → ROADMAP/HANDOFF 更新 → 原子 commit + push。
