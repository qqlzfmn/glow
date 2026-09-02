# Glow 交接文档（HANDOFF）

> 最后更新：2026-09-02。本文档面向接手 Glow 开发的 AI agent / 开发者。
> 先读本文，再读 `AGENTS.md`（技术规范）与 `CLAUDE.md`（构建与架构）。

## 项目是什么

Glow 是 macOS 菜单栏的 AI 编程助手环境状态面板：Agent（Codex / Claude Code / omp / pi）通过 hook 上报工作状态，菜单栏灯色实时反映（绿=空闲/工作中，黄=需关注，红=阻塞）。仓库：https://github.com/qqlzfmn/glow

**血统说明**：衍生自 starlight36/vibecoding-signal-light（MIT），代码已 100% 重写（Swift，上游现为 Rust 硬件方向），但灯语体系、hook 契约、LAMP_LANGUAGE 文档源自上游。MIT 合规已处理：LICENSE 双版权 + README attribution。**不要删除这些 attribution**。

## 当前状态快照

- 测试：134 个 Swift Testing 测试 / 13 套件，全绿（`StateDirEnvLock` 见下方陷阱）
- 结构：仓库根 SPM 包（`Sources/GlowCore/{Kernel,Components}` + `Sources/Glow` 薄入口 + `Tests/GlowTests`）
- M2a 已完成：provider-usage（详见下方 M2 节与 docs/PLUGINS.md）
- 已发布：nightly release（pre-push hook 自动构建上传）；本机 `/Applications/Glow.app` 运行中，launchd `com.qqlzfmn.glow.app` 自启
- 本机 hooks 已切换到 Glow（`~/.codex/hooks.json` 7 事件 + `~/.claude/settings.json` 12 事件 + omp/pi 模板），**orca 第三方 hook 必须永远保留**（`~/.orca/agent-hooks/` 调用）
- 旧仓库 qqlzfmn/vibecoding-signal-light 已 Archived，只读，勿动

## 关键命令（本机陷阱！）

```bash
# 测试——本机只有 CommandLineTools（无 Xcode），XCTest 不可用，用 Swift Testing；
# 且必须带以下 flags（SwiftPM 无法自动发现 CLT 的 Testing.framework）：
swift test --enable-swift-testing \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing \
  -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib

# CI（GitHub macos-15 runner 有完整 Xcode）：直接 swift test --enable-swift-testing，无需 flags
# 构建：./build.sh → .build/Glow.app；打包：bash package.sh → .build/Glow.pkg
# push 触发 pre-push hook 自动打包上传 nightly（gh CLI 已认证为 qqlzfmn）
```

**测试隔离陷阱（血泪教训）**：`NSHomeDirectory()` 不读 HOME 环境变量。涉及 home 的测试用 `home:` 参数注入（API 级）或 `GLOW_HOME` env（CLI 级，HookInstaller.defaultHome 支持）。曾因 setenv("HOME") 无效导致测试误卸真实 hooks（已恢复，备份链在）。

## 架构地图

三层插件模型（详见 `docs/PLUGINS.md`）：

```
Producer（AgentMonitor 等，产生事件，禁碰 UI）
  → Kernel（事件总线、SignalSemantics 聚合仲裁、StatePaths 文件契约、生命周期）
    → Renderer（BuiltInRenderer 菜单栏/面板，消费事件，禁产生事件）
```

**跨套件测试陷阱**：`SessionStoreTests`/`UsageStoreTests`/`UsageMonitorTests` 都改
进程全局 `GLOW_STATE_DIR`，`.serialized` 只管套件内——跨套件必须持有
`StateDirEnvLock`（`Tests/GlowTests/TestSupport.swift`，init 加锁 deinit 释放）。
新套件再碰该 env 时照抄此模式。

- **AgentMonitor**：4 个 agent 子适配器、事件→信号映射、深度失败探测、sessions.json 契约（flock + TTL）、多会话聚合（blocked > permission > attention/done > working > idle）、install-hooks/uninstall-hooks 双向幂等
- **BuiltInRenderer**：菜单栏灯色（闪烁语义）、详情面板交通灯动画、菜单
- **UsageMonitor**：11 个 provider Producer（配额/余额/官方 usage）、凭据三路自动发现、usage.json 契约、菜单栏 badge、Usage 菜单/详情面板区块、`usage` CLI（详见 PLUGINS.md 第 4 节与 HANDOFF M2 节）
- 协议（GlowComponent/UsageProducer/MenuContributor）已随 M2a 落地于 `Kernel/GlowComponent.swift`；UsageMonitor 为首个实现组件。新增 Usage 架构说明见 `docs/PLUGINS.md` 第 4 节

**兼容性红线**：`isGlowCommand` 识别器中的历史子串（`signal-light codex-hook`、`SignalLightApp codex-hook` 等）用于识别并升级旧版安装，不能删；token 级识别是**精确匹配**（`parts.contains`），orca 的 `codex-hook.sh` 路径不会被误伤——改识别逻辑时保持这两个性质。

## 里程碑历史（main 分支）

| Commit | 内容 |
| c33a534 | M0：bootstrap——从 vibecoding-signal-light 基线导入，全局改名 SignalLightApp→Glow，pi-coding-agent→pi，根 SPM 结构，LICENSE/README，64 测试 |
| f2dff07 | fix: pre-push hook 转义修复 |
| ac2c415 | CI：GitHub Actions（macos-15，test + release build） |
| c82482d | M1：Kernel/Components 骨架 + uninstall-hooks（幂等可还原）+ PLUGINS.md 骨架版，74 测试 |
| 84c4222 | docs: HANDOFF 交接文档 |
| f1035cb | M2a：**Usage Monitor**——组件协议落地（GlowComponent/UsageProducer/MenuContributor）+ usage.json 契约（flock 共享 StateFileLock）+ 11 个 provider Producer（GLM/Kimi/MiniMax/ZenMux/OpenCodeGo 配额，DeepSeek/OpenRouter/SiliconFlow/StepFun 余额，Anthropic/OpenAI 官方 usage）+ 凭据三路自动发现 + 菜单栏 badge + Usage 菜单/详情面板区块 + `usage` CLI，134 测试。端点口径源自 cc-switch `coding_plan.rs`/`balance.rs`（用户指定参考）与官方文档实证 |

重构方法论（沿用即可）：每阶段 subagent 实现 → 主会话独立验收（swift test + smoke + grep 残留）→ 原子 commit → push。

## M2 — Usage Monitor（M2a 已完成）

M2a 交付（数据源：用户选定 API usage 端点路线；展示：灯图标旁 badge 文本）：

1. **组件协议**：`Kernel/GlowComponent.swift`（GlowComponent/UsageProducer/
   MenuContributor）；SignalProducer/PanelContributor 仍为草案。
2. **usage.json 契约**：`StatePaths.usageFile`，`StateFileLock`（与 sessions.json
   共用 `state.lock`），snake_case 编码，`order` 定 badge 优先级。
3. **UsageMonitor 组件**：轮询（`GLOW_USAGE_POLL_SECONDS`，默认 300s）→ 逐
   producer fetch → 错误逐 provider 记录（禁静默）→ 落盘 → `onUsageUpdated` 回调。
4. **11 个 provider**：实现文件 `Components/UsageMonitor/{CodingPlan,Balance,
   OfficialUsage}Providers.swift`，parse 为纯函数（fixture 测试，变形 shape 必
   throw 不许空数组伪装成功）。凭据发现 `UsageConfig`：claude env 块按域名识别
   平台 / opencode auth.json / 显式 `~/.config/glow/usage.json`（type+token）。
5. **渲染**：StatusBarController badge 文本（UsageBadge 格式化）+ Usage 子菜单
   （NSMenuDelegate 每次打开重建）+ 详情面板 Usage 区块；CLI `usage` 子命令。

### M2b 候选（按优先级，详见 docs/ROADMAP.md）

new-api/one-api 网关统计 → 火山方舟（AK/SK 自定义 SigV4，参考 coding_plan.rs）→
智谱团队版（`?type=2` + organization/project 头）→ 本地会话日志 token 统计
（Claude JSONL / Codex rollout / opencode，参考 cc-switch `session_usage_*.rs`）→
SignalProducer/PanelContributor 协议落地（随 CI Monitor 等组件）。
### M3+ 组件候选（按优先级，详见 docs/PLUGINS.md 与仓库讨论）

CI Monitor（GitHub Actions 状态→红灯）→ Alert Center（黄/红灯超时升级为本地通知）→ Session Stats（会话统计面板）→ Hardware Lamp Renderer（MCP2221A 实体灯，致敬上游）→ Web Dashboard / Shortcuts Bridge。

## 工作约定

- 遵循 AGENTS.md：简体中文回复、金字塔原理、DRY/KISS/YAGNI、精准修改、禁止硬编码密钥、禁止静默失败、Conventional Commits、GitHub Flow（当前直接推 main 是用户明确授权的例外）
- 用户偏好：完全无人值守、每完成一部分就 push、善用 subagent（实现派 subagent，主会话负责验收 + commit + push，验收绝不轻信 subagent 报告）
- 每个里程碑完成后更新本文档
