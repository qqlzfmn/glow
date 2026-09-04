# App 级设置窗口重构计划

> 状态：待用户批准。批准后按"执行顺序"实施。
> 背景：设置页原为 provider 专属（Usage 子菜单下 "Configure Providers…"），
> 2026-09-04 决议升级为 App 级分区式窗口。取代本目录旧计划的 Phase 2 原案。

## 结论

一次重构交付四件事：**入口提级**（菜单顶层 Settings…）、**窗口分区**（侧边栏
App / Appearance / Providers / Hooks 四区切换，pane 状态保留）、**旧窗口退役**
（ProviderSettingsWindow 整体迁移删除）、**测试跟进**（布局契约改指向新窗口，
新增 Hook 分区契约）。

## 菜单与窗口结构

菜单（StatusBarController.setupMenu）：

```
Usage            （子菜单保留：provider 行 + Refresh Usage）
─────────
Settings…        （新增顶层项，原 "Configure Providers…" 移除）
─────────
Install Hooks    （子菜单保留作快速入口，与设置页共用 HookInstaller）
─────────
Clear State
Quit
```

窗口 "Glow Settings"（640×480，titled+closable）：

```
┌──────────┬──────────────────────────────────┐
│ App      │  所选分区的 pane（切换时保留状态）  │
│ Appearance│                                  │
│ Providers│                                  │
│ Hooks    │                                  │
└──────────┴──────────────────────────────────┘
```

## 四分区内容

1. **App**：开机自启开关（`LaunchdManager.isInstalled / install() /
   uninstall()`）；自动刷新间隔输入（`poll_seconds`，逻辑原样迁移：写
   usage.json、非法回弹、10s 下限、下一轮生效）。
2. **Appearance**：嵌入现有 `BadgeAppearanceControls`（自带落盘与
   `onApply` 回调），加一行说明文案。
3. **Providers**：现有双栏（类型列表 + 凭据表单）+ Save/Remove + 保存后
   2s 自动刷新 Current 行，原样迁移；Refresh Now 按钮移入本区（原窗口
   底部行随重构取消，窗口关闭走标题栏）。
4. **Hooks**：4 个 agent 行（名称 + 开关 + 状态文案），开关走
   `HookInstaller.installAgentAndReport / uninstallAgentAndReport`（幂等，
   失败弹窗），另设 Install All / Uninstall All；菜单 Install Hooks 子菜单
   保留，两入口共用同一 HookInstaller 逻辑，无双写风险。

## 文件布局（≤500 行红线）

```
Components/Settings/
  SettingsWindowController.swift   骨架+侧边栏+pane 切换（~150 行）
  AppSettingsPane.swift            （~110）
  AppearanceSettingsPane.swift     （~60）
  ProviderSettingsPane.swift       从旧窗口迁移（~330）
  HookSettingsPane.swift           （~130）
删除：Components/UsageMonitor/ProviderSettingsWindow.swift
不动：BadgeAppearanceControls.swift（留在 UsageMonitor，badge 渲染语义）
```

## 接线变更

- `AppDelegate.showProviderSettings` → `showSettings`，构造
  `SettingsWindowController(onRefresh:, onBadgeChange:)`（回调语义不变）。
- `StatusBarController.openProviderSettings` → `openSettings`。

## 测试计划

- `ProviderSettingsWindowLayoutTests` → 改造为 `SettingsWindowLayoutTests`：
  四分区按钮存在且可切换；App 分区 poll 字段可见且读出真实值；Appearance
  分区 badge 控件不出窗。沿用 @MainActor + StateDirEnvLock 模式。
- 新增 HookSettingsPane 契约测试（GLOW_HOME 隔离）：开关初值反映
  `inspectAgent`，切换走 install/uninstall 且幂等。
- 既有 RowState / UsageConfigStore / BadgeAppearanceControls 测试不动
  （迁移不改纯逻辑）。

## 风险与对策

- **侧边栏观感**：NSButton（texturedRounded + contentTintColor 选中态）
  非 NSTableView 左侧源列表；验收看真实窗口，不满意换 NSTableView。
- **宽度**：Provider 表单需 ≥442pt 内容宽（170 标签 + 240 字段 + 边距），
  侧边栏 150 → 窗口 640 若挤则升 660。
- **两入口一致性**：菜单勾选与设置页开关都读磁盘状态（inspectAgent），
  打开时各自刷新，无内存态漂移。

## 验收

1. `swift test` 全绿；
2. 装入 /Applications 真机走查：四区切换、App 区显示当前 poll 值（60）、
   Appearance 改色菜单栏即时变、Providers 保存后 Current 行刷新、
   Hooks 开关与菜单勾选一致；
3. `grep -r ProviderSettingsWindow` 无残留。

## 执行顺序

Provider pane 迁移 → 窗口骨架 + 侧边栏 → App / Hook / Appearance pane →
菜单 + AppDelegate 接线 → 删旧文件 → 测试改造与新增 → 全量测试 →
安装走查 → ROADMAP/HANDOFF 更新 → 原子 commit + push。
