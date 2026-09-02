# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Glow provides an ambient environment status panel for AI coding assistants (Codex, Claude Code, omp, pi). It is a **single Swift macOS app** that serves both as a menu bar GUI and as a hook CLI for agents.

The same binary operates in two modes:
- **GUI mode** (no arguments) — Menu bar app that reads session state and renders a colored icon (with usage badge).
- **CLI mode** (`codex-hook`, `claude-code-hook`, `install-hooks`, `status`) — Runs as a hook command invoked by agents, writing session state to a shared JSON file.

Communication between agents and the GUI is via a shared JSON file (`/private/tmp/glow/sessions.json`).

## Commands

```bash
# Build
./build.sh                           # Build the macOS app (SwiftPM release build + assemble .app)

# Test (Swift Testing suite; CLT-only machines need the Swift Testing framework paths,
# see Package.swift and Tests/ for details)
swift test --enable-swift-testing \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing \
  -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib

# Launch GUI
open .build/Glow.app                 # Launch menu bar app

# CLI (run the binary inside the app bundle)
APP=.build/Glow.app/Contents/MacOS/Glow

$APP status                     # Show aggregated session state
$APP usage                      # Print usage.json (provider usage snapshot)
$APP usage-config list          # List supported providers and their config state
$APP usage-config add [type]    # Interactive provider setup (writes 0600 config)
$APP usage-config remove <type> # Remove one explicit provider entry
$APP install-hooks --all --yes  # Install hooks for all agents
$APP uninstall-hooks --all --yes # Uninstall Glow hooks for all agents (symmetric to install)
$APP clear-state                # Clear all session state

# Hook adapters (normally called by agents, not manually)
echo '{"session_id":"abc"}' | $APP codex-hook Stop
echo '{"session_id":"abc"}' | $APP claude-code-hook Stop
```

There is no linter or formatter configured. No CI pipeline.

## Architecture

### Source layout (SwiftPM; package at repo root)

- **`GlowCore/`** (`Sources/GlowCore/`) — library target with all business logic (testable), organized as Kernel + Components:
  - `Kernel/` — host kernel (event bus, aggregation, state file contract, lifecycle):
    - `StatePaths.swift` — Single source of truth for on-disk state paths; honours `GLOW_STATE_DIR`.
    - `SessionState.swift` — Codable JSON model matching the `sessions.json` format.
    - `SignalDefinition.swift` — 11 signal definitions with color mapping, `SignalSemantics` classification sets, and `aggregateSignal()` computation.
    - `SessionStore.swift` — Reads/writes `sessions.json` with typed JSON (`SessionFile`/`SessionEntry`), `fcntl.flock` locking, TTL pruning, and priority-based aggregation. Write/lock failures throw `SessionStoreError` (`lockUnavailable`/`writeFailed`); reads tolerate missing or corrupt files (corrupt files traced to stderr).
    - `LaunchdManager.swift` — macOS launchd plist for auto-start on login.
    - `AppDelegate.swift` — PID file, poller init, menu bar setup.
  - `Components/AgentMonitor/` — Producer: agent state monitoring (hook adapters and hook management):
    - `CodexHookAdapter.swift` — Maps Codex lifecycle events to signal names. Deep payload introspection for failure detection (error status, exit_status, tool_error).
    - `ClaudeCodeHookAdapter.swift` — Maps Claude Code hook events to signal names. Supports `stop_reason` handling and `SubagentStart`/`SubagentStop`/`Notification`.
    - `HookSupport.swift` — Shared hook-adapter pieces: `HookInput`, `SIGNAL_NAMES`, event-name parsing, and the `applyAndReport` tail (persist + report; errors to stderr with exit code 1).
    - `HookAgent.swift` — `HookInstaller.Agent` enum and `AgentStatus`.
    - `HookConfigMerge.swift` — Pure merge/replace/removal helpers for JSON hook configs. `isGlowCommand` recognizes the current `Glow codex-hook` / `Glow claude-code-hook` command shapes plus legacy `signal-light` / `SignalLightApp` substrings and any command invoking this CLI's hook subcommands, so hooks installed by the older app are still replaced on upgrade.
    - `HookInstaller.swift` — Installs/uninstalls/inspects hooks: reads/writes `~/.codex/hooks.json` and `~/.claude/settings.json` for JSON agents; copies the bundled omp/pi hook template into `~/.omp/agent/extensions/` and `~/.pi/agent/extensions/` for template agents. Timestamped backups (`.bak-glow-install-` / `.bak-glow-uninstall-`), idempotent, third-party hooks preserved. `installAgent`/`uninstallAgent` throw; the `*AndReport` variants surface failures via `AgentStatus.message` (`uninstalled` / `not installed`).
    - `InstallHooksCLI.swift` — `install-hooks` / `uninstall-hooks` subcommands: shared argument parsing, agent selection, interactive prompt.
    - `CLIDispatch.swift` — CLI subcommand dispatch (codex-hook / claude-code-hook / status / usage / usage-config / install-hooks / uninstall-hooks / clear-state); returns exit code or nil for GUI mode.
    - `SessionPoller.swift` — 500ms Combine-based polling of `sessions.json`.
  - `Components/UsageMonitor/` — Producer: provider usage monitoring:
    - `UsageMonitor.swift` — Host component: polls providers, persists the merged snapshot to `usage.json`, contributes the Usage submenu (provider headers are clickable to pin the badge; persisted as `badge_provider`).
    - `UsageCredentials.swift` — Explicit-config-only credential discovery (`~/.config/glow/usage.json`, 0600); `GLOW_HOME` overrides the root. Nothing is auto-enabled.
    - `UsageKinds.swift` — Shared provider-type registry (fields, secret flags, balanceBased, default base URL) used by both the CLI and the Settings window.
    - `UsageConfigStore.swift` — Read/write/0600 persistence for the config file; parameterized by home for tests.
    - `UsageConfigCLI.swift` — `usage-config` subcommand (list/add/remove interactive wizard).
    - `UsageHTTP.swift` — JSON GET/POST helpers + `UsageParseError`.
    - `UsageBadge.swift` — Badge/menu text formatting; `badgeSegments` feeds the custom status view.
    - `CodingPlanProviders.swift` / `BalanceProviders.swift` / `GatewayProviders.swift` / `OfficialUsageProviders.swift` / `VolcengineUsageProvider.swift` — 14 provider producers; parsers are pure functions (throw on unknown shape).
  - `Components/BuiltInRenderer/` — Renderer: menu bar only:
    - `StatusBarController.swift` — NSStatusItem with the custom-drawn badge (`StatusItemBadgeView`), flash animation, and right-click menu (Usage submenu with badge pinning + auto-refresh input, Install Hooks per-agent toggles, Clear State, Quit).
    - `StatusItemBadgeView.swift` — iStat-style two-line drawing: lamp, hairline separators, value-over-label segments.

  See `docs/PLUGINS.md` for the component architecture and plugin guide.

- **`Glow/`** (`Sources/Glow/`) — executable target; thin `main.swift` that calls `CLIDispatch.run(CommandLine.arguments)` and launches NSApplication on nil.

- **`Tests/GlowTests/`** — Swift Testing suite (hook adapters, SessionStore, HookInstaller, signal definitions).

### Key patterns

- **Single binary, dual mode**: `CLIDispatch.run(CommandLine.arguments)` checks the arguments — if a subcommand is present, it runs the CLI handler and returns an exit code; on nil the thin `main.swift` launches NSApplication.
- **JSON files as contract**: Hook CLIs write `sessions.json`; `UsageMonitor` writes `usage.json` (provider snapshots, badge pin, poll cadence); the GUI reads both. No IPC needed.
- **Multi-session aggregation**: `SessionStore.aggregateSessions()` picks the highest-priority signal so urgent alerts (red/yellow) are never masked by normal activity.
- **File-lock concurrency**: `SessionStore.withLock()` uses `fcntl.flock(LOCK_EX)` for exclusive access across concurrent hook processes.
- **Errors are explicit**: No silent `try?` on failure paths that matter. Session writes/locks throw `SessionStoreError`; CLI callers print `glow: <error>` to stderr and exit 1; GUI callers show an alert. Read failures are tolerated (empty state) but corrupt `sessions.json` is traced to stderr.

### Entry points (subcommands of the single binary)

| Subcommand | Handler |
|---|---|
| `codex-hook` | `CodexHookAdapter.run()` |
| `claude-code-hook` | `ClaudeCodeHookAdapter.run()` |
| `install-hooks` | `InstallHooksCLI.run()` |
| `uninstall-hooks` | `InstallHooksCLI.run(_:mode:)` |
| `status` | `SessionStore.readSessionSnapshot()` |
| `clear-state` | `SessionStore.clearSessionState()` |
| `usage` | `UsageStore.readUsage()` (pretty JSON) |
| `usage-config` | `UsageConfigCLI.run()` |

### Environment variables

| Variable | Purpose | Default |
|---|---|---|
| `GLOW_STATE_DIR` | Session state directory | `/private/tmp/glow` |
| `GLOW_SESSION_TTL_SECONDS` | Session expiry | `86400` |
| `GLOW_GUI_POLL_MS` | GUI polling interval | `500` |
| `GLOW_USAGE_POLL_SECONDS` | Usage poll cadence (wins over `poll_seconds` in usage.json; min 10) | — |
| `GLOW_HOME` | Home root override for usage config paths (tests/smoke) | — |
