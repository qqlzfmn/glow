# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Glow provides an ambient environment status panel for AI coding assistants (Codex, Claude Code, omp, pi). It is a **single Swift macOS app** that serves both as a menu bar GUI and as a hook CLI for agents.

The same binary operates in two modes:
- **GUI mode** (no arguments) — Menu bar app that reads session state and renders a colored icon + floating detail panel.
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
$APP install-hooks --all --yes  # Install hooks for all agents
$APP clear-state                # Clear all session state

# Hook adapters (normally called by agents, not manually)
echo '{"session_id":"abc"}' | $APP codex-hook Stop
echo '{"session_id":"abc"}' | $APP claude-code-hook Stop
```

There is no linter or formatter configured. No CI pipeline.

## Architecture

### Source layout (SwiftPM; package at repo root)

- **`GlowCore/`** (`Sources/GlowCore/`) — library target with all business logic (testable):
  - `App/AppDelegate.swift` — PID file, poller init, menu bar setup.
  - `Core/` (hook adapters and session management)
    - `SessionStore.swift` — Reads/writes `sessions.json` with typed JSON (`SessionFile`/`SessionEntry`), `fcntl.flock` locking, TTL pruning, and priority-based aggregation. Write/lock failures throw `SessionStoreError` (`lockUnavailable`/`writeFailed`); reads tolerate missing or corrupt files (corrupt files traced to stderr).
    - `HookSupport.swift` — Shared hook-adapter pieces: `HookInput`, `SIGNAL_NAMES`, event-name parsing, and the `applyAndReport` tail (persist + report; errors to stderr with exit code 1).
    - `CodexHookAdapter.swift` — Maps Codex lifecycle events to signal names. Deep payload introspection for failure detection (error status, exit_status, tool_error).
    - `ClaudeCodeHookAdapter.swift` — Maps Claude Code hook events to signal names. Supports `stop_reason` handling and `SubagentStart`/`SubagentStop`/`Notification`.
    - `HookAgent.swift` — `HookInstaller.Agent` enum and `AgentStatus`.
    - `HookConfigMerge.swift` — Pure merge/replace helpers for JSON hook configs. `isGlowCommand` recognizes the current `Glow codex-hook` / `Glow claude-code-hook` command shapes plus legacy `signal-light` / `SignalLightApp` substrings, so hooks installed by the older app are still replaced on upgrade.
    - `HookInstaller.swift` — Reads/writes `~/.codex/hooks.json` and `~/.claude/settings.json` to register hook commands. Installs the bundled omp/pi hook template into `~/.omp/agent/extensions/` and `~/.pi/agent/extensions/`. Handles merge with existing hooks and creates backups. `installAgent` throws; `installAgentAndReport` surfaces failures via `AgentStatus.message`.
    - `InstallHooksCLI.swift` — `install-hooks` subcommand: argument parsing, agent selection, interactive prompt.
  - `Models/`
    - `StatePaths.swift` — Single source of truth for on-disk state paths; honours `GLOW_STATE_DIR`.
    - `SessionState.swift` — Codable JSON model matching the `sessions.json` format.
    - `SignalDefinition.swift` — 11 signal definitions with color mapping, `SignalSemantics` classification sets, and `aggregateSignal()` computation.
  - `Services/`
    - `SessionPoller.swift` — 500ms Combine-based polling of `sessions.json`.
    - `LaunchdManager.swift` — macOS launchd plist for auto-start on login.
  - `Views/`
    - `StatusBarController.swift` — NSStatusItem with flash animation and right-click menu (Show Details, Install Hooks, Quit).
    - `DetailPanelWindow.swift` — Floating NSPanel with traffic light animation.
    - `TrafficLightView.swift` — Custom NSView drawing three colored circles (red/yellow/green).
  - `CLI/CLIDispatch.swift` — CLI subcommand dispatch (codex-hook / claude-code-hook / status / install-hooks / clear-state); returns exit code or nil for GUI mode.

- **`Glow/`** (`Sources/Glow/`) — executable target; thin `main.swift` that calls `CLIDispatch.run(CommandLine.arguments)` and launches NSApplication on nil.

- **`Tests/GlowTests/`** — Swift Testing suite (hook adapters, SessionStore, HookInstaller, signal definitions).

### Key patterns

- **Single binary, dual mode**: `CLIDispatch.run(CommandLine.arguments)` checks the arguments — if a subcommand is present, it runs the CLI handler and returns an exit code; on nil the thin `main.swift` launches NSApplication.
- **JSON file as contract**: The CLI writes `sessions.json`; the GUI reads it. No IPC needed.
- **Multi-session aggregation**: `SessionStore.aggregateSessions()` picks the highest-priority signal so urgent alerts (red/yellow) are never masked by normal activity.
- **File-lock concurrency**: `SessionStore.withLock()` uses `fcntl.flock(LOCK_EX)` for exclusive access across concurrent hook processes.
- **Errors are explicit**: No silent `try?` on failure paths that matter. Session writes/locks throw `SessionStoreError`; CLI callers print `glow: <error>` to stderr and exit 1; GUI callers show an alert. Read failures are tolerated (empty state) but corrupt `sessions.json` is traced to stderr.

### Entry points (subcommands of the single binary)

| Subcommand | Handler |
|---|---|
| `codex-hook` | `CodexHookAdapter.run()` |
| `claude-code-hook` | `ClaudeCodeHookAdapter.run()` |
| `install-hooks` | `InstallHooksCLI.run()` |
| `status` | `SessionStore.readSessionSnapshot()` |
| `clear-state` | `SessionStore.clearSessionState()` |

### Environment variables

| Variable | Purpose | Default |
|---|---|---|
| `GLOW_STATE_DIR` | Session state directory | `/private/tmp/glow` |
| `GLOW_SESSION_TTL_SECONDS` | Session expiry | `86400` |
| `GLOW_GUI_POLL_MS` | GUI polling interval | `500` |
