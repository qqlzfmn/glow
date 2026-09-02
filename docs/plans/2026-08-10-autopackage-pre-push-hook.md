# 自动打包上传 Git Hook 实施计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 添加一个 git hook：当 `Glow/` 下的代码变更被 push 时，自动重新 package（`package.sh` 产出 `Glow.pkg`）并上传到 GitHub 的固定 `nightly` release（资产覆盖更新）。

**Architecture:** 仓库内 `.githooks/pre-push` 脚本 + 本机 `git config core.hooksPath .githooks`。pre-push 读取 stdin 的推送引用，用 `git diff --name-only <remote>...<local>` 检测变更；任一变更路径以 `Glow/` 开头（`.build` 被 gitignore，天然排除产物）即触发打包与上传。上传用已登录的 `gh` CLI 操作固定 `nightly` release（不存在则创建，存在则 `--clobber` 覆盖资产 + 更新 notes）。打包失败退出非 0，阻断 push。

**Tech Stack:** bash（`set -euo pipefail`）、`pkgbuild`/`productbuild`（现有 package.sh）、`gh` CLI（已登录 qqlzfmn）。

---

## 0. 现状（已确认）

- `package.sh`：build.sh → pkgroot → pkgbuild → productbuild → `Glow/.build/Glow.pkg`（版本 0.2.0，无上传步骤）。
- `gh` 已登录（`gh auth status` OK，账号 qqlzfmn），remote 为 `github.com/qqlzfmn/glow`（HTTPS，push 凭证可用）。
- 产物 `.build/` 在 .gitignore 的 `build/` 规则下，不会进入 git diff。

## 1. 决策记录

- **D1 — 触发点 pre-push**（用户选定）：推送即发布意图；打包失败阻断推送，避免"已 push 但包没跟上"。
- **D2 — 固定 nightly release**（用户选定）：不存在则 `gh release create nightly`，存在则 `gh release upload --clobber` 覆盖资产 + `gh release edit` 更新 notes；始终可下载最新包，不堆积版本。
- **D3 — 变更检测**（用户选定）：`git diff --name-only <remote_sha>...<local_sha>` 任一路径以 `Glow/` 开头才打包；README/docs/CLAUDE.md/.claude/ 变更跳过（exit 0 静默）。
- **D4 — hook 入库**：`.githooks/pre-push` 提交进仓库（团队可复用），本机 `git config core.hooksPath .githooks` 启用；README 附启用命令。
- **D5 — 推送引用解析**：从 stdin 逐行读 `<local ref> <local sha> <remote ref> <remote sha>`；remote sha 全 0（新分支）时退化为最近 1 次提交的变更集。
- **D6 — 失败即阻断**：`set -euo pipefail`，打包/上传任一步失败打印明确错误并退出非 0，push 被 git 中止。
- **D7 — 资产清单**（用户确认）：只传 `Glow.pkg` + `Glow.pkg.sha256`（shasum -a 256），不传 .app.zip。固定同名、覆盖更新。
- **D8 — release body**（用户确认）：模板 = Nightly 标题 + 构建时间/commit/版本 + Changes（git log 列表）+ Install + Requirements + Usage + Note（未签名说明）。版本从 `Resources/Info.plist` 的 `CFBundleShortVersionString` 动态读取。

## 2. 交付物

```
glow/
├── .githooks/
│   └── pre-push                      ← 新增：hook 脚本（可执行）
├── README.zh.md / README.en.md       ← 改：Nightly 构建说明 + hook 启用命令
└── docs/plans/2026-08-10-autopackage-pre-push-hook.md  ← 本计划
```

---

### Task 1: 编写 `.githooks/pre-push`

**Files:**
- Create: `.githooks/pre-push`（`chmod +x`）

**Step 1: 完整脚本**

```bash
#!/bin/bash
set -euo pipefail

# Pre-push hook: rebuild the .pkg and publish to the fixed `nightly` GitHub
# release when code under Glow/ changes. Skipped silently for
# docs-only pushes.

REPO_ROOT="$(git rev-parse --show-toplevel)"
PKG="$REPO_ROOT/Glow/.build/Glow.pkg"

# stdin: <local ref> <local sha> <remote ref> <remote sha> per pushed ref
changed=0
while read -r local_ref local_sha remote_ref remote_sha; do
    [ -z "$local_sha" ] && continue
    if [ "$remote_sha" = "0000000000000000000000000000000000000000" ]; then
        # New branch: diff against the empty tree (first commit)
        files="$(git diff --name-only "$(git hash-object -t tree /dev/null)" "$local_sha")"
    else
        files="$(git diff --name-only "$remote_sha" "$local_sha")"
    fi
    if echo "$files" | grep -q '^Glow/'; then
        changed=1
    fi
done

if [ "$changed" -eq 0 ]; then
    echo "pre-push: no code changes under Glow/, skipping package"
    exit 0
fi

echo "==> pre-push: rebuilding package..."
bash "$REPO_ROOT/package.sh"

# Collect commit summary for release notes
local_sha=""
while read -r _local_ref _local_sha _remote_ref _remote_sha; do
    local_sha="$_local_sha"
done
[ -z "$local_sha" ] && local_sha="$(git rev-parse HEAD)"
notes="$(git log --oneline --no-merges -10 "$local_sha" 2>/dev/null | head -20 || true)"

echo "==> pre-push: publishing to nightly release..."
if gh release view nightly >/dev/null 2>&1; then
    gh release upload nightly "$PKG" --clobber
    gh release edit nightly --notes "$notes"
else
    gh release create nightly "$PKG" --title "Nightly" --notes "$notes" --target "$local_sha"
fi

echo "==> pre-push: done"
```

注意：
- 第二个 stdin 循环会重新读取——pre-push 的 stdin 只能读一次，需要**一次性收集 refs 到数组**再处理（见 Step 2 修正）。
- `grep -q '^Glow/'` 需要 `set -e` 下 grep 无匹配返回 1 导致退出——用 `if echo ... | grep -q ...` 包裹规避。

**Step 2（修正）**：脚本改为先收集所有 refs 再处理（stdin 一次性读完）：

```bash
refs=()
while read -r local_ref local_sha remote_ref remote_sha; do
    [ -z "$local_sha" ] && continue
    refs+=("$local_ref" "$local_sha" "$remote_ref" "$remote_sha")
done

changed=0
for ((i = 0; i < ${#refs[@]}; i += 4)); do
    local_sha="${refs[i + 1]}"
    remote_sha="${refs[i + 3]}"
    if [ "$remote_sha" = "0000000000000000000000000000000000000000" ]; then
        files="$(git diff --name-only "$(git hash-object -t tree /dev/null)" "$local_sha")"
    else
        files="$(git diff --name-only "$remote_sha" "$local_sha")"
    fi
    if echo "$files" | grep -q '^Glow/'; then
        changed=1
        last_local_sha="$local_sha"
    fi
done
```

### Task 2: 启用 hook 并做变更检测单元验证

**Files:**
- Modify: 本机 git config（不入库）

**Step 1:** `chmod +x .githooks/pre-push && git config core.hooksPath .githooks`

**Step 2:** 验证各分支的检测逻辑（直接调用脚本逻辑，不真打包）：

```bash
# 模拟 stdin：推送只含 docs 变更（应跳过）
echo "refs/heads/main <sha> refs/heads/main <remote>" | \
  sed 's/<sha>/<remote>/'   # 用真实场景替代，见下
```

实际验证：用一个临时 commit 只改 README → push 到临时分支 → 观察 "skipping"（不真推 main）。更安全的做法：在脚本里加 `SKIP` 环境变量用于测试？不引入测试后门——改为：

1. 临时分支 `test-hook/docs-only` 提交一个 README 改动 → push（pre-push 触发，应跳过打包）→ 删除临时分支。
2. 临时分支 `test-hook/code` 提交一个 `Glow/` 改动（如 Resources 注释）→ push（应打包+上传 nightly）→ 删除临时分支。**此步会真实更新 nightly release**（用户选定的目标，可接受）。
3. 清理临时分支。

> 若用户不想用真实 push 触发验证，Task 4 提供替代：手动运行 hook 脚本 + 伪造 stdin（`echo "refs/heads/main $(git rev-parse HEAD) refs/heads/main 0000..." | .githooks/pre-push`），仅验证打包与上传链路，不产生 git 分支。

### Task 3: README 更新

**Files:**
- Modify: `README.zh.md`、`README.en.md`

**Step 1:** 在 Hook 安装/构建章节后追加 Nightly 构建小节：

zh：
```markdown
## Nightly 构建

推送 `Glow/` 下的代码变更时，`.githooks/pre-push` 会自动重新打包并上传到 GitHub 的 `nightly` release（固定名称，资产覆盖更新；仅文档变更的推送会跳过）。

启用（一次性）：

```bash
git config core.hooksPath .githooks
```

手动打包：`bash package.sh`
```

en 对应翻译。

### Task 4: 端到端验证

**Step 1:** docs-only push → 日志出现 `skipping package`，exit 0。

**Step 2:** code push → package.sh 完成、`gh release view nightly` 存在、资产 `Glow.pkg` 已更新（对比上传时间/大小）。

**Step 3:** 手动运行一次 hook 模拟 stdin 验证幂等（可选）。

---

## 验收标准

1. `.githooks/pre-push` 可执行、`core.hooksPath` 生效（`git config core.hooksPath` 输出 `.githooks`）。
2. docs-only push 跳过打包（日志确认，exit 0）。
3. 代码 push 触发完整链路：package.sh 成功 → nightly release 存在 → 资产为最新 pkg。
4. 打包失败场景阻断 push（手动制造：临时破坏 package.sh 或用 `gh` 无权限环境模拟——验证失败输出非 0，不真推）。

---

## 实现偏差记录（2026-08-10 执行期）

1. **`gh release create --target` 的 422 陷阱**：pre-push 时正在推送的 commit 尚不存在于远端，`--target <local_sha>` 报 `Release.target_commitish is invalid`。修复：首次创建 nightly 时 `--target` 取 `origin/main`（远端已存在）；nightly 已存在后走 `upload --clobber` + `edit` 分支，不再涉及 target。已用真 push 验证两条分支（首次创建 ✓、覆盖更新 ✓）。
2. 验证覆盖了两条分支 + 失败阻断（受限 PATH 使 `gh` 不可见 → hook 非 0 退出 → push 被拒，分支保留）。测试分支 `test-hook-code` 已删除，main 不受测试 commit 影响。
