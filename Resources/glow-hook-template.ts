import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";
import { appendFileSync, existsSync, mkdirSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { homedir } from "node:os";
import { basename, join } from "node:path";

// ---------------------------------------------------------------------------
// 配置（环境变量可覆盖）
// ---------------------------------------------------------------------------
const OBS_DIR =
  process.env.OMP_OBSERVABILITY_DIR ?? join(homedir(), ".omp", "observability");
const REDACT = process.env.OMP_OBSERVABILITY_REDACT !== "0";

// glow 二进制：env 优先，其次探测常见安装位置。
// 找不到时跳过信号灯转发，仅保留 JSONL 观测。
const GLOW_CANDIDATES = [
  process.env.GLOW_BIN,
  "/Applications/Glow.app/Contents/MacOS/Glow",
  join(
    homedir(),
    "Downloads",
    "Glow.app",
    "Contents",
    "MacOS",
    "Glow",
  ),
].filter((p): p is string => Boolean(p));

function resolveGlowBin(): string | undefined {
  return GLOW_CANDIDATES.find((p) => existsSync(p));
}
const GLOW_BIN = resolveGlowBin();
let warnedMissingBin = false;

// D3: 脱敏模式（与 omp 官方 redactor 示例一致 + 通用 secret 形状）
const SECRET_PATTERNS: RegExp[] = [
  /\b(sk|pk)-[a-zA-Z0-9]{20,}\b/g,
  /\bAKIA[A-Z0-9]{16}\b/g,
  /\bghp_[a-zA-Z0-9]{36}\b/g,
  /\b[a-zA-Z0-9]{16,}\.[a-zA-Z0-9]{16,}\b/g,
  /\b[a-zA-Z0-9_-]{20,}\s*=\s*["']?[a-zA-Z0-9._/+=-]{20,}["']?/g,
];

function redactText(text: string): string {
  if (!REDACT) return text;
  let out = text;
  for (const re of SECRET_PATTERNS) out = out.replace(re, "[REDACTED]");
  return out;
}

function redactValue(value: unknown): unknown {
  if (typeof value === "string") return redactText(value);
  if (Array.isArray(value)) return value.map(redactValue);
  if (value !== null && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value)) out[k] = redactValue(v);
    return out;
  }
  return value;
}

function safe<T>(fn: () => T): T | undefined {
  try {
    return fn();
  } catch {
    return undefined;
  }
}

// sessionId = 会话文件 basename 去扩展名；拿不到时回退时间戳
function resolveSessionId(ctx: ExtensionContext): string {
  const sessionFile = safe(() => ctx.sessionManager.getSessionFile());
  return sessionFile
    ? basename(sessionFile).replace(/\.(jsonl|json)$/i, "")
    : `unnamed-${Date.now()}`;
}

// ---------------------------------------------------------------------------
// JSONL 写入（D2: 同步追加；D5: 每会话一文件；D7: 永不抛出）
// ---------------------------------------------------------------------------
function emit(
  event: string,
  ctx: ExtensionContext | undefined,
  extra: Record<string, unknown>,
): void {
  try {
    if (!ctx) return;
    const rec: Record<string, unknown> = {
      ts: Date.now(),
      event,
      sessionId: resolveSessionId(ctx),
      cwd: ctx.cwd,
      ...(ctx.model ? { model: `${ctx.model.provider}/${ctx.model.id}` } : {}),
      ...extra,
    };
    mkdirSync(OBS_DIR, { recursive: true });
    appendFileSync(join(OBS_DIR, `${rec.sessionId}.jsonl`), JSON.stringify(rec) + "\n");
  } catch (err) {
    console.error("[omp-obs-hook] write failed:", err);
  }
}

// ---------------------------------------------------------------------------
// Glow bridge（glow 状态灯）
// 复用其 claude-code-hook 适配器：spawn binary，argv 传 Claude Code 事件名，
// stdin 传 { session_id, cwd }。fire-and-forget，失败只记录不阻塞。
// ---------------------------------------------------------------------------
function forwardGlow(
  eventName: string,
  ctx: ExtensionContext | undefined,
): void {
  if (!GLOW_BIN || !ctx) {
    if (!warnedMissingBin) {
      warnedMissingBin = true;
      console.error(
        "[omp-obs-hook] glow binary not found; skipping status lamp (JSONL only)",
      );
    }
    return;
  }
  // 同步执行：等待 binary 写完状态再返回，避免 omp 退出（print 模式）
  // 连带杀掉未完成的子进程导致状态丢失。单次开销 ~50ms，事件频率低，可接受。
  try {
    execFileSync(
      GLOW_BIN,
      ["claude-code-hook", "--event", eventName],
      {
        input: JSON.stringify({
          session_id: resolveSessionId(ctx),
          cwd: ctx.cwd,
        }),
        stdio: ["pipe", "ignore", "pipe"],
        timeout: 5000,
      },
    );
  } catch (err) {
    console.error(
      "[omp-obs-hook] glow forward failed:",
      (err as Error).message,
    );
  }
}

// ---------------------------------------------------------------------------
// Hook 工厂（D1: ExtensionAPI）
// ---------------------------------------------------------------------------
export default function ompObservabilityHook(pi: ExtensionAPI): void {
  // —— 会话生命周期（Claude Code: SessionStart/End、PreCompact/PostCompact）——
  pi.on("session_start", (e, ctx) => {
    emit("session_start", ctx, {});
    forwardGlow("SessionStart", ctx);
  });
  pi.on("session_switch", (e, ctx) =>
    emit("session_switch", ctx, {
      reason: e.reason,
      previousSessionFile: e.previousSessionFile,
    }),
  );
  pi.on("session_branch", (e, ctx) =>
    emit("session_branch", ctx, { previousSessionFile: e.previousSessionFile }),
  );
  pi.on("session_before_compact", (e, ctx) => {
    emit("session_before_compact", ctx, {});
    forwardGlow("PreCompact", ctx);
  });
  pi.on("session_compact", (e, ctx) =>
    emit("session_compact", ctx, {
      fromExtension: e.fromExtension,
      entryId: (e.compactionEntry as { id?: string } | undefined)?.id,
    }),
  );
  pi.on("session_shutdown", (e, ctx) => {
    emit("session_shutdown", ctx, {});
    forwardGlow("SessionEnd", ctx);
  });

  // —— 每轮对话（Claude Code: UserPromptSubmit、Stop）——
  pi.on("input", (e, ctx) => {
    emit("input", ctx, {
      text: redactText(e.text),
      images: e.images?.length ?? 0,
      source: e.source,
    });
    forwardGlow("UserPromptSubmit", ctx);
  });
  pi.on("turn_start", (e, ctx) =>
    emit("turn_start", ctx, { turnIndex: e.turnIndex, timestamp: e.timestamp }),
  );
  pi.on("turn_end", (e, ctx) =>
    emit("turn_end", ctx, {
      turnIndex: e.turnIndex,
      toolResults: e.toolResults.length,
    }),
  );
  // print/headless 模式无 input 事件，用 agent_start 替补工作态起始信号
  pi.on("agent_start", (e, ctx) => {
    emit("agent_start", ctx, {});
    forwardGlow("UserPromptSubmit", ctx);
  });
  pi.on("agent_end", (e, ctx) =>
    emit("agent_end", ctx, {
      messages: e.messages.length,
      willContinue: e.willContinue,
    }),
  );
  pi.on("session_stop", (e, ctx) => {
    emit("session_stop", ctx, {
      turnId: e.turn_id,
      sessionId: e.session_id,
      sessionFile: e.session_file,
    });
    forwardGlow("Stop", ctx);
  });

  // —— 工具调用（Claude Code: PreToolUse、PostToolUse、PostToolUseFailure）——
  // D6: toolCallId → 执行起始时间；耗时在 tool_execution_end 落盘
  //     （omp 事件顺序: tool_call → execution_start → tool_result → execution_end）
  const execStart = new Map<string, number>();

  pi.on("tool_call", (e, ctx) => {
    emit("tool_call", ctx, {
      toolName: e.toolName,
      toolCallId: e.toolCallId,
      input: redactValue(e.input),
    });
    forwardGlow("PreToolUse", ctx);
  });
  pi.on("tool_execution_start", (e) => {
    execStart.set(e.toolCallId, Date.now());
  });
  pi.on("tool_execution_end", (e, ctx) => {
    const start = execStart.get(e.toolCallId);
    execStart.delete(e.toolCallId);
    emit("tool_execution", ctx, {
      toolName: e.toolName,
      toolCallId: e.toolCallId,
      durationMs: start !== undefined ? Date.now() - start : undefined,
      isError: e.isError,
    });
  });
  pi.on("tool_result", (e, ctx) => {
    const textChars = e.content.reduce(
      (n, c) => n + (c.type === "text" ? c.text.length : 0),
      0,
    );
    emit("tool_result", ctx, {
      toolName: e.toolName,
      toolCallId: e.toolCallId,
      isError: e.isError,
      textChars,
    });
    forwardGlow(e.isError ? "PostToolUseFailure" : "PostToolUse", ctx);
  });

  // —— 权限与通知（Claude Code: PermissionRequest、Notification）——
  pi.on("tool_approval_requested", (e, ctx) => {
    emit("tool_approval_requested", ctx, {
      toolName: e.toolName,
      toolCallId: e.toolCallId,
      approvalMode: e.approvalMode,
      reason: e.reason,
    });
    forwardGlow("PermissionRequest", ctx);
  });
  pi.on("tool_approval_resolved", (e, ctx) => {
    emit("tool_approval_resolved", ctx, {
      toolName: e.toolName,
      toolCallId: e.toolCallId,
      approved: e.approved,
      reason: e.reason,
    });
    // 批准后恢复工作态，避免黄灯滞留到 Stop
    if (e.approved) forwardGlow("PostToolUse", ctx);
  });
  pi.on("mcp_notification", (e, ctx) => {
    emit("mcp_notification", ctx, { server: e.server, method: e.method });
    forwardGlow("Notification", ctx);
  });

  // —— 可靠性事件（omp 特有，Claude Code 无直接对应）——
  pi.on("auto_compaction_start", (e, ctx) =>
    emit("auto_compaction_start", ctx, { reason: e.reason, action: e.action }),
  );
  pi.on("auto_compaction_end", (e, ctx) =>
    emit("auto_compaction_end", ctx, {
      action: e.action,
      aborted: e.aborted,
      willRetry: e.willRetry,
      skipped: e.skipped,
      errorMessage: e.errorMessage,
    }),
  );
  pi.on("auto_retry_start", (e, ctx) =>
    emit("auto_retry_start", ctx, {
      attempt: e.attempt,
      maxAttempts: e.maxAttempts,
      delayMs: e.delayMs,
      errorMessage: e.errorMessage,
    }),
  );
  pi.on("auto_retry_end", (e, ctx) =>
    emit("auto_retry_end", ctx, {
      success: e.success,
      attempt: e.attempt,
      finalError: e.finalError,
    }),
  );
  pi.on("ttsr_triggered", (e, ctx) =>
    emit("ttsr_triggered", ctx, { rules: e.rules.length }),
  );
  pi.on("credential_disabled", (e, ctx) => {
    emit("credential_disabled", ctx, {
      provider: e.provider,
      disabledCause: e.disabledCause,
    });
    forwardGlow("PostToolUseFailure", ctx);
  });
}
