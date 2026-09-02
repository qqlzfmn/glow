# omp Hook 安装菜单实施计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 把 omp hook 的安装能力整合进 Glow 的 `install-hooks`（CLI 与 GUI 菜单），并将 GUI 的 "Install Hooks" 改为按 coding agent 分组的二级菜单（Codex / Claude Code / omp）。

**Architecture:** 沿用现有 `HookInstaller.Agent` 枚举模型（`CaseIterable`，CLI 的 `--agent` 解析与 GUI 的 `allCases` 遍历自动覆盖新 agent）。omp 与现有两个 agent 的安装模型不同——Codex/Claude Code 是写 JSON 配置，omp 是**复制 TS hook 模板**到 `~/.omp/agent/extensions/`。因此 `Agent.omp` 在 `installAgent`/`inspectAgent` 里走文件复制分支。hook 模板以资源文件形式打进 app bundle（`Resources/glow-hook-template.ts`），安装时从 `Bundle.main` 读取。

**Tech Stack:** Swift（现有 AppKit 项目，`swiftc` 直接编译，无 Xcode 工程）、bash 构建脚本、零新依赖。

---

## 0. 现状（已确认）

- `HookInstaller.Agent`：`case codex` / `case claudeCode = "claude-code"`，`CaseIterable`；`configPath` 指向 JSON 配置文件；`installAgent` 合并写 JSON；`inspectAgent` 检查事件完整性。CLI（`main.swift` `runInstallHooks`）与 GUI（`StatusBarController.installHooks`）都遍历 `allCases`——**加枚举 case 后 CLI 自动支持 `--agent omp`，GUI 自动出现在列表中**。
- GUI 菜单：单个 "Install Hooks" 菜单项 → `installHooks()` 遍历全部 agent + 弹结果 alert + launchd 提示。
- build.sh：手写 `swiftc` 编译 SOURCES 数组，只拷贝 Info.plist 进 bundle——需加模板资源拷贝。
- Python 包（`glow/`）：**源码已不在仓库**（仅 egg-info 残留，gui-daemon 失败印证）。本计划不动 Python，README 里已失效的 `uv run` 命令一并更新。

## 1. 决策记录

- **D1 — omp 的 hook 源码迁入信号灯仓库为唯一真源**：`Resources/glow-hook-template.ts` 即模板文件；`/tmp/omp-observability-hook/src/index.ts` 停止作为维护副本。将来改 hook 直接在仓库改模板，重装即生效。
- **D2 — 安装动作 = 复制模板**：目标 `~/.omp/agent/extensions/observability-glow.ts`；目录不存在则创建；目标内容与模板一致时跳过（幂等）；不一致时先备份（复用 `backupConfig` 时间戳备份）再覆盖。
- **D3 — inspect 语义**：omp 无 events/JSON，`installed` = 目标存在且内容与模板一致；不一致 → "outdated"，缺失 → "missing"。
- **D4 — GUI 二级菜单**："Install Hooks" 变为子菜单，每 agent 一项（点击只装该 agent）+ 分隔线 + "Install All"（保留现有全装 + launchd 提示）。菜单项带勾选标记（启动时快照，安装后重开菜单刷新——不做动态刷新，YAGNI）。
- **D5 — 显示名与别名**：`displayName = "omp"`；CLI 别名接受 `omp`（rawValue）。Codex/Claude Code 的现有别名逻辑不动。
- **D6 — 模板缺失时 fail-fast**：bundle 读不到模板 → install 抛错、alert/CLI 显示明确错误（不静默）。
- **D7 — pi 与 omp 并行支持**：两者是同一扩展 API 的同源实现（orca 扩展注释已印证），hook 模板完全相同，仅安装路径不同——`~/.omp/agent/extensions/` 与 `~/.pi/agent/extensions/`（本机已确认后者存在且与前者结构一致）。`Agent` 新增 `case omp` 与 `case pi`（displayName/rawValue `pi`，CLI 别名 `pi`），模板复制逻辑参数化为按 agent 取目标路径。

## 2. 交付物

```
glow/
├── Glow/
│   ├── Resources/glow-hook-template.ts          ← 新增：hook 模板（唯一真源）
│   ├── build.sh                                ← 改：拷贝模板进 bundle
│   └── Sources/Glow/
│       ├── Core/HookInstaller.swift            ← 改：Agent.omp + install/inspect 分支
│       ├── Views/StatusBarController.swift     ← 改：二级菜单
│       └── (App/main.swift 无需改动)
├── README.zh.md / README.en.md                 ← 改：install-hooks 支持 omp + 二级菜单说明
└── docs/plans/2026-08-10-omp-install-hooks-menu.md  ← 本计划
```

---

### Task 1: 迁移 hook 模板进仓库

**Files:**
- Create: `Resources/glow-hook-template.ts`
- Modify: `build.sh`

**Step 1:** 复制当前 hook 源码为模板（内容与 `/tmp/omp-observability-hook/src/index.ts` 一致，二进制自动定位逻辑已就位）。

```bash
cp /tmp/omp-observability-hook/src/index.ts \
   Resources/glow-hook-template.ts
```

**Step 2:** build.sh 在拷贝 Info.plist 旁追加模板拷贝：

```bash
# Copy Info.plist
cp "$RESOURCES_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
# Copy omp hook template
cp "$RESOURCES_DIR/glow-hook-template.ts" "$APP_BUNDLE/Contents/Resources/"
```

**Step 3:** 构建验证模板进 bundle。

Run: `cd Glow && ./build.sh`
Expected: 编译成功；`ls .build/Glow.app/Contents/Resources/glow-hook-template.ts` 存在。

### Task 2: HookInstaller 增加 Agent.omp

**Files:**
- Modify: `Sources/Glow/Core/HookInstaller.swift`

**Step 1: 枚举扩展**

```swift
enum Agent: String, CaseIterable {
    case codex
    case claudeCode = "claude-code"
    case omp

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claudeCode: return "Claude Code"
        case .omp: return "omp"
        }
    }

    var configPath: String {
        let home = NSHomeDirectory()
        switch self {
        case .codex:
            return (home as NSString).appendingPathComponent(".codex/hooks.json")
        case .claudeCode:
            return (home as NSString).appendingPathComponent(".claude/settings.json")
        case .omp:
            return (home as NSString)
                .appendingPathComponent(".omp/agent/extensions/observability-glow.ts")
        }
    }
}
```

注意：`events`/`hookScript`/`passesEventArg`/`usesMatcher` 对 `.omp` 返回空/默认（`[]`、`""`、`false`、`false`）——现有 install/inspect 通用路径对 omp 不适用，由下面分支接管，这些属性不参与 omp 逻辑。

**Step 2: installAgent 加 omp 分支**（函数开头）：

```swift
static func installAgent(_ agent: Agent) throws {
    if agent == .omp {
        try installOmpHook()
        return
    }
    // …现有 JSON 合并逻辑不变
}

private static func installOmpHook() throws {
    guard let templateURL = Bundle.main.url(
        forResource: "glow-hook-template", withExtension: "ts"
    ) else {
        throw InstallError.templateMissing
    }
    let template = try String(contentsOf: templateURL, encoding: .utf8)
    let target = Agent.omp.configPath

    // 幂等：内容一致则跳过
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
```

**Step 3: inspectAgent 加 omp 分支**（函数开头）：

```swift
static func inspectAgent(_ agent: Agent) -> AgentStatus {
    if agent == .omp {
        let path = agent.configPath
        let exists = FileManager.default.fileExists(atPath: path)
        let matches = (try? String(contentsOfFile: path, encoding: .utf8))
            .flatMap { $0 == ompTemplateText } ?? false
        return AgentStatus(
            agent: agent,
            installed: exists && matches,
            configExists: exists,
            validJson: true,
            missingEvents: [],
            brokenEvents: [],
            message: !exists ? "missing" : (matches ? "installed" : "outdated")
        )
    }
    // …现有 JSON 检查逻辑不变
}
```

其中 `ompTemplateText` 为懒加载模板内容（`Bundle.main` 读不到时返回 `nil`，`matches` 即 false）。

**Step 4: InstallError 加 case**

```swift
enum InstallError: Error {
    case encodingFailed
    case templateMissing
}
```

### Task 3: GUI 二级菜单

**Files:**
- Modify: `Sources/Glow/Views/StatusBarController.swift`

**Step 1: setupMenu 改造**（替换单个 Install Hooks 菜单项）：

```swift
// Install Hooks → 二级菜单（per agent）
let installMenu = NSMenu()
for agent in HookInstaller.Agent.allCases {
    let item = NSMenuItem(
        title: agent.displayName,
        action: #selector(installHooksForAgent(_:)),
        keyEquivalent: ""
    )
    item.target = self
    item.representedObject = agent.rawValue
    item.state = HookInstaller.inspectAgent(agent).installed ? .on : .off
    installMenu.addItem(item)
}
installMenu.addItem(NSMenuItem.separator())
let allItem = NSMenuItem(title: "Install All", action: #selector(installHooks), keyEquivalent: "")
allItem.target = self
installMenu.addItem(allItem)

let installItem = NSMenuItem(title: "Install Hooks", action: nil, keyEquivalent: "")
installItem.submenu = installMenu
menu.addItem(installItem)
```

**Step 2: 新增单 agent 动作**：

```swift
@objc private func installHooksForAgent(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String,
          let agent = HookInstaller.Agent(rawValue: raw) else { return }
    let result = HookInstaller.installAgentAndReport(agent)
    let alert = NSAlert()
    alert.messageText = "\(agent.displayName) Hooks"
    alert.informativeText = result.message
    alert.alertStyle = .informational
    alert.addButton(withTitle: "OK")
    alert.runModal()
}
```

**Step 3:** 现有 `installHooks()`（Install All）保留不动（含 launchd 提示）。

### Task 4: 构建 + CLI 验证

**Step 1:** `cd Glow && ./build.sh` — 编译通过、模板进 bundle。

**Step 2:** 全新安装（先删现有自动安装的 hook）：

```bash
rm -f ~/.omp/agent/extensions/observability-glow.ts
APP=Glow/.build/Glow.app/Contents/MacOS/Glow
$APP install-hooks --agent omp -y
```
Expected: 打印 `Installed omp: installed`；`~/.omp/agent/extensions/observability-glow.ts` 存在且与模板一致。

**Step 3:** 幂等重跑 + 状态列表：

```bash
$APP install-hooks --agent omp -y          # 二次运行：unchanged，仍 installed
$APP install-hooks                          # 列表显示 3 个 agent（Codex / Claude Code / omp）
```
Expected: 列表第 3 项 `3. omp: ok (installed; config found)`。

**Step 4:** 破坏恢复验证：往目标文件追加一行注释 → `$APP install-hooks --agent omp -y` → 内容恢复为模板（备份文件生成）。

### Task 5: 端到端冒烟（零参数灯联动）

**Step 1:** 干净环境跑 omp（不带任何 env/参数），工作期检查默认状态目录：

```bash
unset GLOW_STATE_DIR GLOW_BIN OMP_OBSERVABILITY_DIR
rm -f /private/tmp/glow/sessions.json
/Users/lzf/.bun/bin/omp -p "用 glob 列出 /tmp 下的 jsonl 文件" &
sleep 12 && cat /private/tmp/glow/sessions.json   # 期望有 signal: thinking/working/tool_done
```
Expected: 工作期 sessions.json 有工作态信号（证明 install-hooks 装的 hook 端到端生效）。

### Task 6: README 更新

**Files:**
- Modify: `README.zh.md`、`README.en.md`

**Step 1:** Hook 安装章节更新：
- 支持 agent 列表：Codex、Claude Code、**omp**（新增）
- GUI：Install Hooks 二级菜单说明（per agent + Install All）
- CLI：`install-hooks --agent omp`、`--agent codex --agent claude-code`
- omp 条目说明：安装 = 把内置 hook 模板写入 `~/.omp/agent/extensions/`，零参数联动

**Step 2:** 删除/标注已失效的 `uv run glow ...` Python CLI 引用（Python 包源码不在仓库）。

---

## 验收标准

1. `./build.sh` 编译通过，模板文件在 bundle 内。
2. `install-hooks --agent omp -y` 生成目标文件且内容与模板一致；幂等；破坏后重装恢复 + 备份。
3. `install-hooks` 列表显示 3 个 agent。
4. 端到端：install-hooks 安装的 hook 在零参数 omp 会话中驱动 sessions.json 工作态。
5. GUI 菜单构建正确（二级菜单结构、勾选状态、Install All 行为不变）——编译通过 + 用户手测确认。
