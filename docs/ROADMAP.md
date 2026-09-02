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

### M2 — provider-usage（立项中）

目标：在菜单栏同时展示"agent 在做什么"与"模型服务还剩多少"。初步设想采用组件化架构，沿用状态灯侧已验证的"数据与展示分离"思路：

- **Producer** 插件：负责从各类来源采集原始用量数据（API usage 端点、本地网关/代理统计、hook 侧 token 计数汇总等），输出统一的用量事件流。
- **Processor** 插件：对事件流做归一化、聚合与配额计算（token/金额/重置周期口径），产出可渲染的用量快照。
- **Renderer** 插件：把快照渲染到菜单栏（图标分区、子菜单、详情面板），与状态灯渲染共存。

插件间通过定义良好的数据契约交互，新增 provider 只需实现 Producer；展示形态演进只动 Renderer。

## 待定项（后续细化）

- provider 用量数据来源：API 余额端点（如 Anthropic/OpenAI usage API）、本地网关/代理统计、hook 侧 token 计数汇总？
- 展示形态：现有菜单栏图标扩展（分区域/子菜单）、详情面板扩展，还是独立状态项？
- 支持的 provider 范围与用量口径（token、金额、配额、重置周期）。
- 与现有 `sessions.json` 聚合/灯语体系的关系（独立信号还是并入聚合优先级）。

## 备注

- 实现遵循现有架构约定：单一 Swift 二进制、JSON 文件契约、launchd 自启。
- nightly 构建 hook 已就绪，代码变更 push 自动打包上传。
