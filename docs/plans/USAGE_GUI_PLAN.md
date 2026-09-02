# Usage Provider 配置 GUI 计划

> 状态：待用户批准。批准后按 Phase 1 → （可选）Phase 2 实施。

## 结论

两阶段交付，Phase 1 直接解决"配置 provider 必须用终端或手编 JSON"的痛点：

- **Phase 1（必做）**：Provider 配置窗口（AppKit），菜单 "Configure Providers…" 从"打开 JSON 文件"改为打开此窗口。
- **Phase 2（可选）**：主面板（popover/panel）承载状态 + 用量 + Provider 管理 + Hooks 开关，即"整个菜单变 GUI"。Phase 1 的列表/表单组件被 Phase 2 复用，因此 Phase 1 是两条路线的共同必经之路。

技术栈：**纯 AppKit**。理由：现有 UI（StatusBarController）全部 AppKit，一致性最好；本机仅 CommandLineTools 工具链，引 SwiftUI 增加工具链验证风险；AppKit 表单（NSTableView + 动态字段）代码可控。

## Phase 1：Provider 配置窗口

### 组件与文件

| 文件 | 内容 |
|---|---|
| `Components/UsageMonitor/UsageKinds.swift`（新） | `UsageProviderKind` 注册表从 `UsageConfigCLI` 提取共享：type、displayName、动态字段定义（key/prompt/是否 secret）。CLI 与 GUI 共用一份 |
| `Components/UsageMonitor/ProviderSettingsWindow.swift`（新） | 窗口控制器：列表 + 详情表单 + 保存/删除逻辑 |
| `StatusBarController.swift`（改） | "Configure Providers…" action 改为打开窗口（单例，重复点击 bring-to-front） |
| `AppDelegate.swift`（改） | 懒创建并持有窗口控制器 |
| `UsageMonitor.swift`（改） | `refreshNow()` 公开为 `refreshNowAsync()` 供窗口保存后立即触发重新发现 + 拉取（不等 300s 轮询） |

### 窗口布局（双栏，约 480×420）

```
┌──────────────────────────────────────────────┐
│ Usage Providers                              │
├──────────────────┬───────────────────────────┤
│ ● GLM Coding     │  GLM Coding Plan          │
│   Plan     [auto]│  状态: 自动发现            │
│ ○ DeepSeek [cfg] │        （来源: opencode    │
│ ○ Volcengine [–] │        auth.json）        │
│ …（14 类型全列） │  5h: 0%                   │
│                  │  ─────────────────────    │
│ [+ Add] [− Del]  │  [另存为手动配置]          │
├──────────────────┴───────────────────────────┤
│ [Refresh Now]                    [Close]     │
└──────────────────────────────────────────────┘
```

- 左列表：14 个 provider 类型全量展示（回答"我列的 provider 在哪"），行内状态徽章：`configured`（显式配置）/ `auto`（自动发现）/ `–`（未配置）。
- 选中行右侧三态详情：
  1. **auto**：显示凭据来源 + 当前用量快照；提供"另存为手动配置"（把发现的凭据写入显式配置，之后可改）。
  2. **configured**：可编辑表单。字段按 `Kind.prompts` 动态生成——secret 字段（token/AK/SK）用 `NSSecureTextField`；`base_url` 可选单独一行；团队版/火山等 extra 字段（organization_id/project_id/AK/SK/user_id）动态出现。含 [Delete]（带确认弹窗）。
  3. **not configured**：同一表单的空态，[Save] 后 upsert。
- 保存：`UsageConfigStore.upsert/remove`（已有，0600 权限）→ 自动触发 `refreshNow` → 新 provider 数秒内出现在菜单。

### 数据流（全部复用现有管线）

```
窗口表单 → UsageConfigStore.upsert/remove（写 0600 JSON）
        → UsageMonitor.refreshNow（重新 discover + pollOnce）
        → usage.json → 菜单/badge 更新（onUsageUpdated 回调，已有）
```

### 测试与验收

- 单测：三态判定（discover ∪ store 对比）、表单字段按 Kind 生成、save roundtrip（0600、schema 正确）。
- 人工验收（AppKit 无法无头自动化）：窗口打开/编辑/保存 → 菜单出现新 provider；删除 → 消失。

### 工作量估计

新增 ~450 行 + 改动 ~40 行；2 个单测文件。

## Phase 2（可选）：主面板替代菜单

- 状态栏**左键**点击 → 主面板（NSPopover，锚定图标）：
  - 顶部：聚合状态灯摘要（当前灯色 + 活跃会话数）
  - 中部：Usage 明细（复用 Phase 1 列表行组件，含 Refresh）
  - Hooks 区：4 个 agent toggle（逻辑复用现有 `installHooksForAgent` 语义）
  - 底部：Provider 设置（打开 Phase 1 窗口）、Clear State、Quit
- 右键保留现有 NSMenu（或精简为 Quit）——需最终拍板。
- 依赖 Phase 1 组件，新增 ~300 行。

## 风险

1. AppKit UI 无法无头自动化验收，需人工看一眼（计划内已列人工验收步骤）。
2. NSTableView + 动态表单是本项目首个复杂视图，注意保持单文件 <500 行（必要时拆 DataSource）。
3. secret 字段明文存 0600 JSON 不变（与 usage-config CLI 相同语义；Keychain 属后续独立里程碑）。

## 决策点（需用户确认）

1. Phase 1 是否按此开工？
2. Phase 2 做不做、何时做（建议 Phase 1 验收后再定）？
3. Phase 2 若做：右键 NSMenu 保留精简版，还是完全替代？
