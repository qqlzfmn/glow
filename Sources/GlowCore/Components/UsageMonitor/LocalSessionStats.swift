import Foundation
import SQLite3

/// Producer for local agent session token usage. Parses the on-disk session
/// logs of Claude Code (`~/.claude/projects`), opencode
/// (`~/.local/share/opencode/opencode.db`) and Codex (`~/.codex/sessions`)
/// and aggregates them into rolling 7-day / 30-day token totals — no network,
/// no credentials.
///
/// Token accounting mirrors cc-switch's `session_usage*.rs`:
/// - Claude Code (`session_usage.rs`): per `requestId`, tokens =
///   `input_tokens + output_tokens + cache_creation_input_tokens`.
///   `cache_read_input_tokens` is EXCLUDED — reading from the prompt cache is
///   not a new billing quantity (口径与成本侧一致：缓存命中不计新增)。
/// - opencode (`session_usage_opencode.rs`): per completed assistant message,
///   tokens = `input + output + reasoning + cache.write`; `cache.read` is
///   EXCLUDED for the same reason. In-progress messages (no `time.completed`)
///   only carry half-finalized counts and are skipped.
/// - Codex (`session_usage_codex.rs`): `total_token_usage` is session-
///   cumulative. `input_tokens` already contains `cached_input_tokens`
///   (codex's own `total_tokens == input_tokens + output_tokens`) and
///   `reasoning_output_tokens` is part of `output_tokens`, so a session's
///   tokens = `input_tokens + output_tokens`, taken as the maximum snapshot
///   in the rollout file (the cumulative counter is monotonic; duplicate
///   re-emissions under a new rate-limit `limit_id` never decrease it).
///
/// The result is reported as two `UsageItem`s — `1w` then `1m` — with
/// `used` in `unit: "tokens"`. If the machine has no readable session data
/// at all (the user simply never used an agent) `fetch` returns `[]`.
final class LocalSessionStatsProvider: UsageProducer {
    let providerKey = "sessions"
    let displayName = "Local Sessions"

    /// Injected home directory; tests build fixtures under a temp home.
    private let home: String

    init(home: String = NSHomeDirectory()) {
        self.home = home
    }

    // MARK: - Aggregation

    /// One counted usage event: `tokens` consumed at `timestamp`.
    struct SessionTokenRecord {
        let timestamp: Date
        let tokens: Double
    }

    func fetch() async throws -> [UsageItem] {
        let now = Date()
        var records: [SessionTokenRecord] = []
        records.append(contentsOf: claudeRecords(now: now))
        records.append(contentsOf: try openCodeRecords(now: now))
        records.append(contentsOf: codexRecords(now: now))

        guard !records.isEmpty else { return [] }
        let week = totalTokens(in: records, from: now.addingTimeInterval(-7 * 86400), to: now)
        let month = totalTokens(in: records, from: now.addingTimeInterval(-30 * 86400), to: now)
        return [item("1w", week), item("1m", month)]
    }

    private func totalTokens(in records: [SessionTokenRecord], from start: Date, to end: Date) -> Double {
        records.reduce(0.0) { total, record in
            record.timestamp >= start && record.timestamp <= end ? total + record.tokens : total
        }
    }

    private func item(_ label: String, _ tokens: Double) -> UsageItem {
        UsageItem(
            label: label,
            usedPercent: nil,
            used: tokens,
            remaining: nil,
            total: nil,
            unit: "tokens",
            resetsAt: nil
        )
    }

    // MARK: - Shared scanning / caching

    /// (path, mtime) → parsed records. The provider instance survives many
    /// polling rounds; unchanged files are never re-parsed.
    private struct FileCacheEntry {
        let mtime: TimeInterval
        let records: [SessionTokenRecord]
    }

    private var claudeCache: [String: FileCacheEntry] = [:]
    private var codexCache: [String: FileCacheEntry] = [:]

    /// Only scan files whose mtime is inside the last 35 days — anything
    /// older cannot contribute to the 30-day window.
    private func scanCutoff(now: Date) -> TimeInterval {
        now.addingTimeInterval(-35 * 86400).timeIntervalSince1970
    }

    private func modificationTime(_ url: URL) -> TimeInterval? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?
            .timeIntervalSince1970
    }

    private func jsonlChildren(of dir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: []
        ))?.filter { $0.pathExtension == "jsonl" } ?? []
    }

    // MARK: - Claude Code (~/.claude/projects)

    /// Fixed-depth scan, no recursion (mirrors cc-switch `collect_jsonl_files`):
    ///
    ///     ~/.claude/projects/<project>/*.jsonl                          (main session)
    ///     ~/.claude/projects/<project>/<session>/subagents/*.jsonl       (Task/Agent subagents)
    ///     ~/.claude/projects/<project>/<session>/subagents/workflows/wf_*/*.jsonl
    ///
    private func claudeRecords(now: Date) -> [SessionTokenRecord] {
        let cutoff = scanCutoff(now: now)
        var records: [SessionTokenRecord] = []
        for file in claudeJSONLFiles() {
            guard let mtime = modificationTime(file), mtime >= cutoff else { continue }
            let path = file.path
            if let cached = claudeCache[path], cached.mtime == mtime {
                records.append(contentsOf: cached.records)
                continue
            }
            let parsed = parseClaudeFile(at: file)
            claudeCache[path] = FileCacheEntry(mtime: mtime, records: parsed)
            records.append(contentsOf: parsed)
        }
        return records
    }

    private func claudeJSONLFiles() -> [URL] {
        let fm = FileManager.default
        let projectsDir = URL(fileURLWithPath: home)
            .appendingPathComponent(".claude/projects", isDirectory: true)
        guard let projects = try? fm.contentsOfDirectory(
            at: projectsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return [] }

        var files: [URL] = []
        for project in projects {
            guard (try? project.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            guard let children = try? fm.contentsOfDirectory(
                at: project,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            ) else { continue }
            for child in children {
                if child.pathExtension == "jsonl" {
                    files.append(child)
                } else if (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    let subagents = child.appendingPathComponent("subagents", isDirectory: true)
                    files.append(contentsOf: jsonlChildren(of: subagents))
                    let workflows = subagents.appendingPathComponent("workflows", isDirectory: true)
                    for workflowDir in jsonlChildrenParentDirs(of: workflows) {
                        files.append(contentsOf: jsonlChildren(of: workflowDir))
                    }
                }
            }
        }
        return files
    }

    /// Direct child directories of `dir` (the `wf_*` dirs under `workflows`).
    private func jsonlChildrenParentDirs(of dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )) ?? []).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }

    /// Per-line assistant usage, deduplicated by key (prefer a line with
    /// `stop_reason`, else the one with the larger `output_tokens` — the same
    /// tie-break as cc-switch's `sync_single_file`). Corrupted lines and lines
    /// without a timestamp are skipped.
    private struct ClaudeUsageEntry {
        let tokens: Double
        let output: Double
        let hasStopReason: Bool
        let timestamp: Date?
    }

    private func parseClaudeFile(at url: URL) -> [SessionTokenRecord] {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var best: [String: ClaudeUsageEntry] = [:]
        var keyless: [ClaudeUsageEntry] = []

        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            // Tolerate single corrupt lines: skip and keep going.
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any]
            else { continue }

            let input = Self.number(usage["input_tokens"]) ?? 0
            let output = Self.number(usage["output_tokens"]) ?? 0
            let cacheCreation = Self.number(usage["cache_creation_input_tokens"]) ?? 0
            // cache_read_input_tokens deliberately NOT counted (see header).
            let entry = ClaudeUsageEntry(
                tokens: input + output + cacheCreation,
                output: output,
                hasStopReason: message["stop_reason"] as? String != nil,
                timestamp: (object["timestamp"] as? String).flatMap(isoDate)
            )

            let key = (object["requestId"] as? String) ?? (message["id"] as? String)
            if let key {
                switch best[key] {
                case nil:
                    best[key] = entry
                case let existing?:
                    if entry.hasStopReason && !existing.hasStopReason {
                        best[key] = entry
                    } else if entry.hasStopReason == existing.hasStopReason,
                              entry.output > existing.output {
                        best[key] = entry
                    }
                }
            } else {
                keyless.append(entry)
            }
        }

        return (best.values + keyless).compactMap { entry in
            entry.timestamp.map { SessionTokenRecord(timestamp: $0, tokens: entry.tokens) }
        }
    }

    // MARK: - opencode (~/.local/share/opencode/opencode.db)

    private struct OpenCodeCache {
        let dbMtime: TimeInterval
        let walMtime: TimeInterval
        let records: [SessionTokenRecord]
    }

    private var openCodeCache: OpenCodeCache?

    private func openCodeRecords(now: Date) throws -> [SessionTokenRecord] {
        let dbPath = URL(fileURLWithPath: home)
            .appendingPathComponent(".local/share/opencode/opencode.db").path
        guard FileManager.default.fileExists(atPath: dbPath) else { return [] }

        // opencode runs SQLite in WAL mode: fresh commits live in `-wal`
        // until a checkpoint, so the cache key must include both mtimes.
        let dbMtime = modificationTime(URL(fileURLWithPath: dbPath)) ?? 0
        let walMtime = modificationTime(URL(fileURLWithPath: dbPath + "-wal")) ?? 0
        if let cached = openCodeCache, cached.dbMtime == dbMtime, cached.walMtime == walMtime {
            return cached.records
        }
        let records = try parseOpenCodeDB(at: URL(fileURLWithPath: dbPath))
        openCodeCache = OpenCodeCache(dbMtime: dbMtime, walMtime: walMtime, records: records)
        return records
    }

    private func parseOpenCodeDB(at url: URL) throws -> [SessionTokenRecord] {
        let path = url.path
        var dbHandle: OpaquePointer?
        guard sqlite3_open_v2(path, &dbHandle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = dbHandle
        else {
            sqlite3_close(dbHandle)
            throw UsageParseError.unexpectedShape("opencode: cannot open \(path)")
        }
        defer { sqlite3_close(db) }

        func scalar(_ sql: String) throws -> Int64 {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw UsageParseError.unexpectedShape("opencode: query failed on \(path)")
            }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                throw UsageParseError.unexpectedShape("opencode: query returned no row on \(path)")
            }
            return sqlite3_column_int64(stmt, 0)
        }

        // Schema drift guard: a file at this path without the `message`
        // table is an unrecognized shape, not "no usage".
        guard try scalar("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='message'") > 0
        else {
            throw UsageParseError.unexpectedShape("opencode: \(path) has no message table")
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT data FROM message", -1, &stmt, nil) == SQLITE_OK,
              let messageStmt = stmt
        else {
            throw UsageParseError.unexpectedShape("opencode: cannot query message table in \(path)")
        }
        defer { sqlite3_finalize(messageStmt) }

        var records: [SessionTokenRecord] = []
        while sqlite3_step(messageStmt) == SQLITE_ROW {
            let data: Data?
            if let blob = sqlite3_column_blob(messageStmt, 0) {
                data = Data(bytes: blob, count: Int(sqlite3_column_bytes(messageStmt, 0)))
            } else {
                data = nil
            }
            guard let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["role"] as? String == "assistant",
                  let tokens = object["tokens"] as? [String: Any],
                  let time = object["time"] as? [String: Any],
                  let completedMs = (time["completed"] as? NSNumber)?.doubleValue,
                  completedMs > 0
            else { continue }

            let input = Self.number(tokens["input"]) ?? 0
            let output = Self.number(tokens["output"]) ?? 0
            let reasoning = Self.number(tokens["reasoning"]) ?? 0
            let cache = tokens["cache"] as? [String: Any]
            let cacheWrite = Self.number(cache?["write"]) ?? 0
            // cache.read deliberately NOT counted (see header).
            let cacheRead = Self.number(cache?["read"]) ?? 0
            if input == 0 && output == 0 && reasoning == 0 && cacheRead == 0 && cacheWrite == 0 {
                continue
            }
            records.append(SessionTokenRecord(
                timestamp: Date(timeIntervalSince1970: completedMs / 1000),
                tokens: input + output + reasoning + cacheWrite
            ))
        }
        return records
    }

    // MARK: - Codex (~/.codex/sessions)

    private func codexRecords(now: Date) -> [SessionTokenRecord] {
        let cutoff = scanCutoff(now: now)
        var records: [SessionTokenRecord] = []
        var files: [URL] = []
        collectCodexJSONL(from: URL(fileURLWithPath: home)
            .appendingPathComponent(".codex/sessions", isDirectory: true),
            depth: 0, into: &files)
        for file in files {
            guard let mtime = modificationTime(file), mtime >= cutoff else { continue }
            let path = file.path
            if let cached = codexCache[path], cached.mtime == mtime {
                records.append(contentsOf: cached.records)
                continue
            }
            let parsed = parseCodexFile(at: file)
            codexCache[path] = FileCacheEntry(mtime: mtime, records: parsed)
            records.append(contentsOf: parsed)
        }
        return records
    }

    /// `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` — depth-bounded
    /// recursive scan (the date path is three levels; 6 is generous).
    private func collectCodexJSONL(from dir: URL, depth: Int, into files: inout [URL]) {
        guard depth <= 6 else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return }
        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDirectory {
                collectCodexJSONL(from: entry, depth: depth + 1, into: &files)
            } else if entry.pathExtension == "jsonl" {
                files.append(entry)
            }
        }
    }

    /// One record per rollout file: the maximum `total_token_usage` snapshot
    /// (input + output), stamped with that event's timestamp. `last_token_usage`
    /// per-event deltas are deliberately not replayed — the ticketed口径 is the
    /// per-session maximum of the cumulative counter, which is robust against
    /// duplicate re-emissions across rate-limit lanes.
    private func parseCodexFile(at url: URL) -> [SessionTokenRecord] {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var maxTokens = 0.0
        var maxTimestamp: Date?
        var lastTimestamp: Date?

        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            // Cheap prefilter: token_count events are rare among rollout lines.
            guard line.contains("\"token_count\"") else { continue }
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let totalUsage = info["total_token_usage"] as? [String: Any]
            else { continue }

            let timestamp = (object["timestamp"] as? String).flatMap(isoDate)
            if let timestamp { lastTimestamp = timestamp }
            let tokens = (Self.number(totalUsage["input_tokens"]) ?? 0)
                + (Self.number(totalUsage["output_tokens"]) ?? 0)
            if tokens > maxTokens {
                maxTokens = tokens
                maxTimestamp = timestamp
            }
        }

        guard maxTokens > 0, let timestamp = maxTimestamp ?? lastTimestamp else { return [] }
        return [SessionTokenRecord(timestamp: timestamp, tokens: maxTokens)]
    }

    // MARK: - Parsing helpers

    private let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let isoPlain = ISO8601DateFormatter()

    private func isoDate(_ string: String) -> Date? {
        isoFractional.date(from: string) ?? isoPlain.date(from: string)
    }

    /// Tolerant numeric reader: JSONSerialization numbers bridge to NSNumber.
    private static func number(_ any: Any?) -> Double? {
        guard let number = any as? NSNumber else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }
}
