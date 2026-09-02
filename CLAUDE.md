# CLAUDE.md

Guidance for Claude Code (claude.ai/code) working in this repository.

## Project Overview

Glow is a single Swift macOS app serving as a menu-bar status panel for AI
coding assistants (Codex, Claude Code, omp, pi):

- **GUI mode** (no arguments) — menu bar item: signal lamp + iStat-style
  usage badge (custom-drawn `StatusItemBadgeView`) and a right-click menu
  (Usage with badge pinning, Install Hooks per-agent toggles, Clear State,
  Quit).
- **CLI mode** — subcommands: hooks (`codex-hook`, `claude-code-hook`),
  usage (`usage`, `usage-config`), management (`install-hooks`,
  `uninstall-hooks`, `clear-state`, `status`).

The two modes talk through JSON files (`sessions.json`, `usage.json`) in
`$GLOW_STATE_DIR` (default `/private/tmp/glow`) — no IPC.

Full architecture, component map, provider matrix and on-disk contracts:
**docs/PLUGINS.md**. Milestone history and machine-specific pitfalls:
**HANDOFF.md**.

## Commands

```bash
# Build (release, assembles .app)
./build.sh

# Test — CommandLineTools machines need these flags (no Xcode):
swift test --enable-swift-testing \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing \
  -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib

APP=.build/Glow.app/Contents/MacOS/Glow
$APP install-hooks --all -y      # hooks for all agents (idempotent)
$APP usage-config list           # provider config states
$APP status                      # session snapshot JSON
```

## Architecture principles

- **JSON files as contract**: hook CLIs write `sessions.json`; the usage
  monitor writes `usage.json` (provider snapshots, badge pin, poll
  cadence); the GUI reads both. Writes serialize through `StateFileLock`.
- **Errors are explicit**: write/lock failures throw; the CLI prints
  `glow: <error>` to stderr and exits 1, the GUI shows an alert. Read
  failures are tolerated (empty state) but traced to stderr.
- **No implicit provider enablement**: usage providers come only from the
  explicit 0600 config (`~/.config/glow/usage.json`).
- **Data-flow rules** (Producers never touch UI; Renderers never emit
  events; components never call each other directly) are defined in
  docs/PLUGINS.md §1.

## Testing pitfalls

- Suites touching `GLOW_STATE_DIR` must hold `StateDirEnvLock`
  (Tests/GlowTests/TestSupport.swift) — `.serialized` only orders tests
  within one suite.
- Home-dependent tests use the `home:` parameter (`NSHomeDirectory`
  ignores the HOME env var); usage-config paths honor `GLOW_HOME`.
- Swift Testing only (`import Testing`) — XCTest is unavailable on
  CommandLineTools machines.

## Docs

- docs/PLUGINS.md — architecture, component map, provider matrix,
  usage.json contract, environment variables
- docs/LAMP_LANGUAGE.md — signal language + hook config examples
- docs/ROADMAP.md — milestones
- HANDOFF.md — handoff notes, machine pitfalls, milestone history
