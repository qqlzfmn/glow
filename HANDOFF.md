# Glow 交接文档（HANDOFF）

> 最后更新：2026-09-02。本文档面向接手 Glow 开发的 AI agent / 开发者。
> 先读本文，再读 `AGENTS.md`（技术规范）与 `CLAUDE.md`（构建与架构）。

## 项目是什么

Glow 是 macOS 菜单栏的 AI 编程助手环境状态面板：Agent（Codex / Claude Code / omp / pi）通过 hook 上报工作状态，菜单栏灯色实时反映（绿=空闲/工作中，黄=需关注，红=阻塞）。仓库：https://github.com/qqlzfmn/glow

**血统说明**：衍生自 starlight36/vibecoding-signal-light（MIT），代码已 100% 重写（Swift，上游现为 Rust 硬件方向），但灯语体系、hook 契约、LAMP_LANGUAGE 文档源自上游。MIT 合规已处理：LICENSE 双版权 + README attribution。**不要删除这些 attribution**。

## 当前状态快照

- 测试：74 个 Swift Testing 测试 / 6 套件，全绿
- 结构：仓库根 SPM 包（`Sources/GlowCore/{Kernel,Components}` + `Sources/Glow` 薄入口 + `Tests/GlowTests`）
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

- **AgentMonitor**：4 个 agent 子适配器、事件→信号映射、深度失败探测、sessions.json 契约（flock + TTL）、多会话聚合（blocked > permission > attention/done > working > idle）、install-hooks/uninstall-hooks 双向幂等
- **BuiltInRenderer**：菜单栏灯色（闪烁语义）、详情面板交通灯动画、菜单
- 协议（GlowComponent/SignalProducer/MenuContributor/PanelContributor）目前是 PLUGINS.md 中的草案，M2 随第一个新组件落地

**兼容性红线**：`isGlowCommand` 识别器中的历史子串（`signal-light codex-hook`、`SignalLightApp codex-hook` 等）用于识别并升级旧版安装，不能删；token 级识别是**精确匹配**（`parts.contains`），orca 的 `codex-hook.sh` 路径不会被误伤——改识别逻辑时保持这两个性质。

## 里程碑历史（main 分支）

| Commit | 内容 |
|---|---|
| c33a534 | M0：bootstrap——从 vibecoding-signal-light 基线导入，全局改名 SignalLightApp→Glow，pi-coding-agent→pi，根 SPM 结构，LICENSE/README，64 测试 |
| f2dff07 | fix: pre-push hook 转义修复 |
| ac2c415 | CI：GitHub Actions（macos-15，test + release build） |
| c82482d | M1：Kernel/Components 骨架 + uninstall-hooks（幂等可还原）+ PLUGINS.md 骨架版，74 测试 |

重构方法论（沿用即可）：每阶段 subagent 实现 → 主会话独立验收（swift test + smoke + grep 残留）→ 原子 commit → push。

## 待办：M2 — Usage Monitor（下一个里程碑）

1. **数据源决策**（三选一，需与用户确认）：
   - API usage 端点（Anthropic/OpenAI usage API，需配置 key）
   - 本地网关统计（用户跑本地代理时从日志汇总）
   - hook 侧 token 计数（hook payload 常带 token 信息，扩展 sessions.json 字段上报）
2. **usage.json 契约**：仿 sessions.json（flock + TTL + StatePaths 收敛，如 `/private/tmp/glow/usage.json`）
3. **UsageMonitor 组件**：第一个真正实现 `SignalProducer`/`MenuContributor` 协议的组件——用它淬炼协议接口，然后把 PLUGINS.md 的协议节从"草案"改为"稳定"
4. **菜单栏展示**：Kernel 独占 StatusItem，UsageMonitor 贡献 badge 文本（如 `1.2M` tokens）——避免多个 StatusItem
5. **PLUGINS.md 完整版**：50 行示例插件教程 + AI prompt 模板（文首"把本指南喂给 AI"路径）+ 组件测试约定

### M3+ 组件候选（按优先级，详见 docs/PLUGINS.md 与仓库讨论）

CI Monitor（GitHub Actions 状态→红灯）→ Alert Center（黄/红灯超时升级为本地通知）→ Session Stats（会话统计面板）→ Hardware Lamp Renderer（MCP2221A 实体灯，致敬上游）→ Web Dashboard / Shortcuts Bridge。

## 工作约定

- 遵循 AGENTS.md：简体中文回复、金字塔原理、DRY/KISS/YAGNI、精准修改、禁止硬编码密钥、禁止静默失败、Conventional Commits、GitHub Flow（当前直接推 main 是用户明确授权的例外）
- 用户偏好：完全无人值守、每完成一部分就 push、善用 subagent（实现派 subagent，主会话负责验收 + commit + push，验收绝不轻信 subagent 报告）
- 每个里程碑完成后更新本文档
