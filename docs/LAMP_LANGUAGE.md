# AI Agent Traffic Signal Status Language

This project uses a three-light traffic signal model as an ambient status display for Codex or other AI agents.

The language is deliberately small: the current light must always describe the current state. There are no important startup animations and no "blink first, meaning later" patterns. If Codex is working or needs you, the pattern keeps running until another Codex event changes the state. When a session ends, its record is cleared and the light returns to the current aggregate state.

## Status Semantics

| Light | Meaning | Human action |
| --- | --- | --- |
| steady green | Codex is idle | Nothing |
| flashing green | Codex is thinking, using tools, or otherwise working | Wait |
| flashing yellow | Codex explicitly needs you to read or continue | Look at Codex when convenient |
| flashing red | Codex needs permission, is blocked, or hit a failure | Look at Codex now |
| off | Manual clear | Nothing |

That is the whole language.

## Signal Names

The CLI still exposes named signals so hooks and other agents can use stable words:

| Signal | Light | Meaning |
| --- | --- | --- |
| `idle` | steady green | Agent is idle |
| `thinking` | flashing green | Agent has received the prompt and is thinking |
| `working` | flashing green | Agent is using tools, editing, running commands, or testing |
| `tool_done` | flashing green | A tool call finished, but the agent is still in an active workflow |
| `attention` | flashing yellow | Agent explicitly expects you to read or continue |
| `done` | flashing yellow | Task completed; read the final answer |
| `permission` | flashing red | Codex requests permission |
| `blocked` | flashing red | Agent cannot continue without intervention |
| `session_start` | steady green | Codex session started and is idle |
| `session_end` | current aggregate state after clearing the session | Codex session ended |
| `off` | off | Clear all lights |

## Codex Hook Mapping

| Codex event | Signal | Light |
| --- | --- | --- |
| `SessionStart` | `session_start` | steady green |
| `UserPromptSubmit` | `thinking` | flashing green |
| `PreToolUse` | `working` | flashing green |
| `PostToolUse` | `tool_done` | flashing green |
| `PermissionRequest` | `permission` | flashing red |
| `Stop` | `turn_end` | clears non-urgent session state |
| `SessionEnd` | `session_end` | clears the session, then aggregate state |

`turn_end` is a hook-only control state. It is not a public lamp pattern: it removes that session's non-urgent working state, while leaving any existing `permission` or `blocked` red alert intact.

If the hook payload reports failure through structured fields such as `status`, `state`, `error`, `failure`, `exception`, or a non-zero `exit_status`, the adapter uses `blocked`, which starts flashing the red light.

`Stop` is treated as the end of a normal turn, so it clears working state instead of flashing yellow after every response.

Codex hook state is session-aware. Each session stores its own latest signal, then the menu bar shows the highest-priority aggregate:

```text
flashing red > flashing yellow > flashing green (work) > steady green
```

For example, if one Codex session is waiting for permission and another session starts working, the light stays flashing red. If one session is waiting for you to read a result and another session is working, the light stays flashing yellow.

When a tracked session ends, the runtime removes its record and recomputes the aggregate: if other sessions are still working, the light shows the working cycle; if no sessions remain, the light settles on steady green. Red and yellow alerts stay higher priority, so an active permission, blocked, attention, or done state is not cleared by another session ending.

## Try It

```bash
# CLI binary (inside the app bundle)
APP=.build/Glow.app/Contents/MacOS/Glow

$APP status
```

## Claude Code Hook Mapping

| Claude Code event | Signal | Light |
| --- | --- | --- |
| `SessionStart` | `session_start` | steady green |
| `UserPromptSubmit` | `thinking` | flashing green |
| `PreToolUse` | `working` | flashing green |
| `PostToolUse` | `tool_done` | flashing green |
| `PostToolUseFailure` | `blocked` | flashing red |
| `PreCompact` | `working` | flashing green |
| `SubagentStart` | `working` | flashing green |
| `SubagentStop` | `tool_done` | flashing green |
| `PermissionRequest` | `permission` | flashing red |
| `Notification` | `attention` | flashing yellow |
| `Stop` | `turn_end` | clears non-urgent session state |
| `SessionEnd` | `session_end` | clears the session, then aggregate state |

If `Stop` carries a `stop_reason` of `max_tokens` or `error`, the adapter uses `blocked` instead of clearing state.

## Claude Code settings.json Example

Run `$APP install-hooks --agent claude-code` (or right-click the menu bar icon → "Install Hooks") to install automatically, or add hooks manually to `~/.claude/settings.json` (replace `<path-to>/Glow` with the actual binary path):

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "<path-to>/Glow claude-code-hook",
            "timeout": 5
          }
        ],
        "matcher": ""
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "<path-to>/Glow claude-code-hook",
            "timeout": 5
          }
        ],
        "matcher": ""
      }
    ],
    "PreToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "<path-to>/Glow claude-code-hook",
            "timeout": 5
          }
        ],
        "matcher": ""
      }
    ],
    "PostToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "<path-to>/Glow claude-code-hook",
            "timeout": 5
          }
        ],
        "matcher": ""
      }
    ],
    "PostToolUseFailure": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "<path-to>/Glow claude-code-hook",
            "timeout": 5
          }
        ],
        "matcher": ""
      }
    ],
    "PermissionRequest": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "<path-to>/Glow claude-code-hook",
            "timeout": 10
          }
        ],
        "matcher": ""
      }
    ],
    "Notification": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "<path-to>/Glow claude-code-hook",
            "timeout": 5
          }
        ],
        "matcher": ""
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "<path-to>/Glow claude-code-hook",
            "timeout": 5
          }
        ],
        "matcher": ""
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "<path-to>/Glow claude-code-hook",
            "timeout": 5
          }
        ],
        "matcher": ""
      }
    ]
  }
}
```

Note: Claude Code passes the event as JSON on stdin, so the hook command does not need an event argument.

## Codex hooks.json Example

Run `$APP install-hooks --agent codex` to install automatically, or add hooks manually to `~/.codex/hooks.json` (replace `<path-to>/Glow` with the actual binary path):

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "<path-to>/Glow codex-hook UserPromptSubmit",
            "timeout": 5
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "<path-to>/Glow codex-hook PreToolUse",
            "timeout": 5
          }
        ]
      }
    ],
    "PermissionRequest": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "<path-to>/Glow codex-hook PermissionRequest",
            "timeout": 10
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "<path-to>/Glow codex-hook Stop",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```
