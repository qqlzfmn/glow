# Roadmap

> 愿景记录（2026-08-10，2026-09-02 更新）。细节待后续细化，先占位跟踪。

## 愿景

Glow 是 AI 编程助手的菜单栏环境状态面板，从"agent 状态灯"演进为 **provider 状态指示工具栏工具**——一个菜单栏工具，同时提供：

- **Glow 状态灯**（M1，已有）：agent 工作状态指示（灯语系统、Codex / Claude Code / omp / pi hooks 集成、多会话聚合）。
- **provider-usage**（M2，立项中）：provider 用量提示——token 用量、余额、配额等，让 AI 助手及其使用的模型服务的"状态"在菜单栏一屏可见。

## 里程碑

### M1 — 状态灯（已完成）

- 灯语体系与多会话聚合（`sessions.json` 契约、优先级聚合、flock 并发）。
- Codex / Claude Code JSON hook 集成，omp / pi TS 扩展模板集成。
- launchd 开机自启、`install-hooks` CLI 与 GUI 安装向导、nightly pre-push 打包。

计划占位（待排期）：

- CI：push 时跑 `swift test`，保证主干可构建可测试。
- `uninstall-hooks` 子命令：对称地移除/回滚已安装的 hook 与扩展模板。

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
  Usage 子菜单（逐条目渲染 5h/1w/1m/余额）。详情面板已移除。
- 后续批次（按优先级）：new-api / one-api 网关统计 → 火山方舟（AK/SK 签名）→
  智谱团队版（`?type=2`）→ 本地会话日志 token 统计（Claude JSONL / Codex
  rollout / opencode，参照 cc-switch `session_usage_*.rs` 口径）→ Session Stats 面板。

## 待定项（后续细化）

- 用量数据与灯语体系的关系：当前独立（usage.json 与 sessions.json 分离，
  badge 只加文本不换灯色）；是否引入"配额耗尽 → 黄灯"类联动待定。
- 官方 API 的金额/成本口径（Anthropic cost report 端点是否纳入）。
- 菜单栏 badge 外观自定义：设置页（Usage Providers 窗口）支持调整字体大小、
  行间距、颜色（数值/小标签/竖线）等渲染参数，替代硬编码。
- 插件化拆分：组件协议转 public、拆独立 target 的时机。

## 备注

- 实现遵循现有架构约定：单一 Swift 二进制、JSON 文件契约、launchd 自启。
- nightly 构建 hook 已就绪，代码变更 push 自动打包上传。
