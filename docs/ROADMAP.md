# Roadmap

> 愿景记录（2026-08-10，2026-09-02 / 2026-09-04 更新；2026-09-04 收尾归档）。
> 细节待后续细化，先占位跟踪。

## 愿景

Glow 是 AI 编程助手的菜单栏环境状态面板，从"agent 状态灯"演进为 **provider 状态指示工具栏工具**——一个菜单栏工具，同时提供：

- **Glow 状态灯**（M1，已有）：agent 工作状态指示（灯语系统、Codex / Claude Code / omp / pi hooks 集成、多会话聚合）。
- **provider-usage**（M2，立项中）：provider 用量提示——token 用量、余额、配额等，让 AI 助手及其使用的模型服务的"状态"在菜单栏一屏可见。

## 里程碑

### M1 — 状态灯（已完成）

- 灯语体系与多会话聚合（`sessions.json` 契约、优先级聚合、flock 并发）。
- Codex / Claude Code JSON hook 集成，omp / pi TS 扩展模板集成。
- launchd 开机自启、`install-hooks` / `uninstall-hooks` CLI 与 GUI 安装向导、
  nightly pre-push 打包；GitHub Actions CI（push 跑 `swift test`）。

### M2 — provider-usage（实施中）

目标：在菜单栏同时展示"agent 在做什么"与"模型服务还剩多少"。组件化架构，
数据与展示分离：

- **组件协议**（已落地）：`GlowComponent` + `UsageProducer` + `MenuContributor`
  （`Kernel/GlowComponent.swift`），随 UsageMonitor 淬炼成文。
- **Producer**（已落地 11 个 provider）：GLM/Z.ai Coding Plan、Kimi For Coding、
  MiniMax、ZenMux、OpenCode Go（配额窗口）；DeepSeek、OpenRouter、SiliconFlow、
  StepFun（余额）；Anthropic、OpenAI 官方 usage API（需组织 admin key）。
  凭据三路自动发现（claude env 块 / opencode auth.json / 显式
  `~/.config/glow/usage.json`），详见 docs/PLUGINS.md。
- **契约**（已落地）：`usage.json`（`StatePaths.usageFile`，flock 互斥，
  `order` 定优先级），CLI `usage` 子命令打印快照。
- **Renderer**（已落地）：菜单栏 badge 文本（首个可用 provider 首条 item）、
  Usage 子菜单（逐条目渲染 5h/1w/1m/余额）；badge 外观可自定义——
  usage.json `badge` 对象（数值/标签字号、行距、数值/标签/竖线三色 hex），
  Provider Settings 窗口 Badge 区即时生效，未触碰的颜色保持系统动态色
  （深浅色自适应），Reset 一键还原。详情面板已移除。
- 后续批次（按优先级）：**badge 自动跟随 agent provider**（2026-09-05
  调研完备 + 计划，待拍板 3 点：
  `docs/plans/2026-09-05-badge-auto-follow-agent-provider-plan.md`）→
  本地会话日志 token 统计（Claude JSONL / Codex
  rollout / opencode，参照 cc-switch `session_usage_*.rs` 口径）→ Session Stats 面板。
- **设置页重构（2026-09-04 决议，取代原 popover 主面板案；计划完备，用户
  决定暂缓执行）**：设置窗口升级为 App 级——侧边栏四分区（App：开机自启/
  轮询间隔；外观：badge 外观；Provider：凭据配置；Hooks：agent 开关），
  入口从 Usage 子菜单提级为菜单顶层 Settings…。计划：
  `docs/plans/2026-09-04-app-settings-window-plan.md`，恢复执行时按其
  "执行顺序"开工即可。

## 待定项（后续细化）

- 用量数据与灯语体系的关系：当前独立（usage.json 与 sessions.json 分离，
  badge 只加文本不换灯色）；是否引入"配额耗尽 → 黄灯"类联动待定。
- 官方 API 的金额/成本口径（Anthropic cost report 端点是否纳入）。
- 插件化拆分：组件协议转 public、拆独立 target 的时机。
- 功能可配置化（总原则）：已有与后续功能均需在设置页提供开关与参数调整
  （悬浮球、token 记录等），不引入硬编码-only 行为；badge 外观自定义
  已于 2026-09-04 落地（首个案例）。

## M3+ 候选（2026-09-04 补充，待排期）

- 可选桌面悬浮球：状态灯 + 用量信息的桌面浮动展示，菜单栏之外的可选形态。
- 跨平台：其他操作系统支持；CPU 架构已解——v0.1.3 起正式 release 与
  nightly 均双架构（arm64 / x86_64 安装包）。
- agent 端 token 估算与记录：从本地会话日志估算各 agent 的 token 消耗并留存，
  承接 M2 的"本地会话日志 token 统计"批次。
- provider 端用量记录：将 provider 轮询快照按时序留存为历史数据。
- 折线图统计：agent 端与 provider 端 token 用量对比可视化（依赖上两条的数据积累）。

## 备注

- 实现遵循现有架构约定：单一 Swift 二进制、JSON 文件契约、launchd 自启。
- nightly 构建 hook 已就绪，代码变更 push 自动打包上传双架构
  （`Glow-arm64.pkg` / `Glow-x86_64.pkg` + sha256）。
