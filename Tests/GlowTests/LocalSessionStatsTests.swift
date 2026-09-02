import Testing
import Foundation
import SQLite3
@testable import GlowCore

/// Fixture tests for `LocalSessionStatsProvider`. Each test builds agent
/// session logs under a temp home (injected via `init(home:)`) — no real
/// `~/.claude`, `~/.codex` or `~/.local/share/opencode` state is touched.
///
/// 口径 under test (see LocalSessionStats.swift header):
/// - Claude: tokens = input + output + cache_creation; cache_read EXCLUDED
///   (读缓存非新增计费量); same requestId counted once.
/// - opencode: completed assistant messages only; cache.read EXCLUDED.
/// - Codex: per rollout file the max cumulative total_token_usage
///   (input + output) counts once, stamped with that snapshot's timestamp.
@Suite(.serialized)
final class LocalSessionStatsTests {

    // MARK: - Fixture helpers

    private let fileManager = FileManager.default

    private final class TempHome {
        let url: URL

        init() {
            let base = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("glow-local-session-stats-\(UUID().uuidString)")
            try! FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            url = base
        }

        deinit {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func writeFile(_ relativePath: String, content: String, in home: TempHome) -> URL {
        let url = home.url.appendingPathComponent(relativePath)
        try! fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try! content.data(using: .utf8)!.write(to: url)
        return url
    }

    private let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private func iso(_ date: Date) -> String {
        isoFractional.string(from: date)
    }

    /// Claude assistant JSONL line. `cacheRead` exists to assert it is
    /// excluded from the sum; omitting `timestamp` exercises the skip rule.
    private func claudeLine(
        requestId: String,
        timestamp: Date? = nil,
        input: Int,
        output: Int,
        cacheCreation: Int = 0,
        cacheRead: Int = 0,
        stopReason: String? = nil
    ) -> String {
        let usage = """
            {"input_tokens": \(input), "output_tokens": \(output), \
            "cache_creation_input_tokens": \(cacheCreation), "cache_read_input_tokens": \(cacheRead)}
            """
        let stop = stopReason.map { ", \"stop_reason\": \"\($0)\"" } ?? ", \"stop_reason\": null"
        let ts = timestamp.map { ", \"timestamp\": \"\(iso($0))\"" } ?? ""
        return """
            {"type": "assistant", "requestId": "\(requestId)", "sessionId": "s1"\(ts), \
            "message": {"id": "msg_\(requestId)"\(stop), "usage": \(usage)}}
            """
    }

    /// Codex token_count event line. `totalTokenUsage` is session-cumulative.
    private func codexLine(
        timestamp: Date,
        totalInput: Int,
        totalCached: Int = 0,
        totalOutput: Int,
        lastInput: Int = 0,
        lastOutput: Int = 0
    ) -> String {
        """
        {"timestamp": "\(iso(timestamp))", "type": "event_msg", \
        "payload": {"type": "token_count", \
        "info": {"total_token_usage": {"input_tokens": \(totalInput), \
        "cached_input_tokens": \(totalCached), "reasoning_output_tokens": 0, \
        "output_tokens": \(totalOutput), "total_tokens": \(totalInput + totalOutput)}, \
        "last_token_usage": {"input_tokens": \(lastInput), \
        "cached_input_tokens": 0, "reasoning_output_tokens": 0, \
        "output_tokens": \(lastOutput), "total_tokens": \(lastInput + lastOutput)}}}}
        """
    }

    /// Creates a minimal opencode SQLite db. `message.data` is the JSON blob
    /// cc-switch's `session_usage_opencode.rs` parses (role / tokens / time).
    private func makeOpenCodeDB(at url: URL, dataRows: [String]) {
        try! fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let db
        else {
            fatalError("test fixture: cannot create \(url.path)")
        }
        defer { sqlite3_close(db) }
        var err: UnsafeMutablePointer<CChar>?
        let sql = """
            CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, data TEXT);
            \(dataRows.map { "INSERT INTO message (id, session_id, data) VALUES ('\($0)', 'sess', \(opencodeDataJSON($0)));" }
                .joined(separator: "\n"))
            """
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "unknown"
            fatalError("test fixture: sqlite exec failed: \(message)")
        }
    }

    /// opencode `message.data` JSON as a quoted SQL string literal.
    private func opencodeDataJSON(_ id: String) -> String {
        switch id {
        case "m_complete":
            return "'{\"role\": \"assistant\", \"tokens\": {\"input\": 100, \"output\": 20, \"reasoning\": 5, \"cache\": {\"read\": 999, \"write\": 10}}, \"time\": {\"created\": 1000, \"completed\": \(Int(Date().timeIntervalSince1970 * 1000))}}'"
        case "m_incomplete":
            return "'{\"role\": \"assistant\", \"tokens\": {\"input\": 500, \"output\": 5, \"reasoning\": 0, \"cache\": {\"read\": 0, \"write\": 0}}, \"time\": {\"created\": 1000}}'"
        case "m_user":
            return "'{\"role\": \"user\", \"tokens\": {\"input\": 100, \"output\": 0, \"reasoning\": 0, \"cache\": {\"read\": 0, \"write\": 0}}, \"time\": {\"created\": 1000, \"completed\": \(Int(Date().timeIntervalSince1970 * 1000))}}'"
        case "m_zero":
            return "'{\"role\": \"assistant\", \"tokens\": {\"input\": 0, \"output\": 0, \"reasoning\": 0, \"cache\": {\"read\": 0, \"write\": 0}}, \"time\": {\"created\": 1000, \"completed\": \(Int(Date().timeIntervalSince1970 * 1000))}}'"
        default:
            fatalError("test fixture: unknown opencode row \(id)")
        }
    }

    // MARK: - Claude Code

    /// requestId dedup, cache_read exclusion, expired/missing timestamps,
    /// corrupt lines, subagent files — and the rolling 1w/1m windows.
    @Test func claudeDedupExcludesCacheReadAndFiltersWindows() async throws {
        let home = TempHome()
        let now = Date()
        let mainLines = [
            // r1 counted once: dup line has smaller output → first wins.
            claudeLine(requestId: "r1", timestamp: now, input: 100, output: 50,
                       cacheCreation: 20, cacheRead: 999),
            claudeLine(requestId: "r1", timestamp: now, input: 100, output: 40),
            // Expired for 1w but inside 1m.
            claudeLine(requestId: "r2", timestamp: now.addingTimeInterval(-8 * 86400),
                       input: 500, output: 0),
            // Missing timestamp → skipped.
            claudeLine(requestId: "r3", input: 1000, output: 0),
            // Corrupt line → skipped.
            "{not json",
            // Non-assistant type → skipped.
            "{\"type\": \"user\", \"message\": {}}",
        ]
        writeFile(".claude/projects/-Users-lzf-Workspace-glow/session.jsonl",
                  content: mainLines.joined(separator: "\n") + "\n", in: home)
        // Subagent transcript: cache_read must be excluded here too.
        writeFile(".claude/projects/-Users-lzf-Workspace-glow/s1/subagents/task.jsonl",
                  content: claudeLine(requestId: "r4", timestamp: now, input: 30, output: 10,
                                      cacheRead: 5) + "\n", in: home)

        let provider = LocalSessionStatsProvider(home: home.url.path)
        let items = try await provider.fetch()

        #expect(items.count == 2)
        #expect(items[0].label == "1w")
        // r1: 100 + 50 + 20 (cache_read 999 excluded) + r4: 30 + 10 + 0.
        #expect(items[0].used == 210)
        #expect(items[1].label == "1m")
        // + expired-but-in-30d r2: 500.
        #expect(items[1].used == 710)
        for item in items {
            #expect(item.unit == "tokens")
            #expect(item.usedPercent == nil)
            #expect(item.remaining == nil)
            #expect(item.resetsAt == nil)
        }
    }

    /// Same requestId across tool-loop/streaming lines must count once even
    /// when the duplicate carries stop_reason and the first does not.
    @Test func claudePrefersStopReasonEntryOnDedup() async throws {
        let home = TempHome()
        let now = Date()
        let lines = [
            claudeLine(requestId: "r1", timestamp: now, input: 100, output: 10),
            claudeLine(requestId: "r1", timestamp: now, input: 100, output: 90,
                       stopReason: "end_turn"),
        ]
        writeFile(".claude/projects/p/session.jsonl",
                  content: lines.joined(separator: "\n") + "\n", in: home)

        let provider = LocalSessionStatsProvider(home: home.url.path)
        let items = try await provider.fetch()

        #expect(abs(items[0].used! - 190.0) < 0.5)
    }

    // MARK: - Codex

    /// Per rollout file the maximum cumulative snapshot counts once; a
    /// duplicate re-emission of the same total (new limit_id) must not
    /// double-count, and old sessions only land in the 30-day window.
    @Test func codexTakesMaxCumulativeSnapshotPerSession() async throws {
        let home = TempHome()
        let now = Date()
        let freshLines = [
            codexLine(timestamp: now.addingTimeInterval(-3600),
                      totalInput: 100, totalCached: 50, totalOutput: 10,
                      lastInput: 100, lastOutput: 10),
            codexLine(timestamp: now,
                      totalInput: 200, totalCached: 80, totalOutput: 30,
                      lastInput: 100, lastOutput: 20),
            // Duplicate re-emission: same cumulative total, another limit_id.
            codexLine(timestamp: now,
                      totalInput: 200, totalCached: 80, totalOutput: 30),
        ]
        writeFile(".codex/sessions/2026/09/01/rollout-fresh.jsonl",
                  content: freshLines.joined(separator: "\n") + "\n", in: home)
        writeFile(".codex/sessions/2026/08/20/rollout-old.jsonl",
                  content: codexLine(timestamp: now.addingTimeInterval(-10 * 86400),
                                     totalInput: 40, totalOutput: 0) + "\n", in: home)
        // No token_count events at all → no record.
        writeFile(".codex/sessions/2026/08/21/rollout-empty.jsonl",
                  content: "{\"type\": \"session_meta\", \"payload\": {}}\n", in: home)

        let provider = LocalSessionStatsProvider(home: home.url.path)
        let items = try await provider.fetch()

        // Max snapshot of the fresh session: 200 + 30 (cached_input is
        // already inside input_tokens; total_tokens == input + output).
        #expect(items[0].used == 230)
        // + old session max: 40 + 0.
        #expect(items[1].used == 270)
    }

    // MARK: - opencode

    @Test func openCodeCountsOnlyCompletedAssistantMessages() async throws {
        let home = TempHome()
        makeOpenCodeDB(at: home.url.appendingPathComponent(".local/share/opencode/opencode.db"),
                       dataRows: ["m_complete", "m_incomplete", "m_user", "m_zero"])

        let provider = LocalSessionStatsProvider(home: home.url.path)
        let items = try await provider.fetch()

        // Only m_complete: 100 + 20 + 5 + 10 (cache.read 999 excluded);
        // incomplete (no time.completed), user role and all-zero skipped.
        #expect(items.count == 2)
        #expect(items[0].used == 135)
        #expect(items[1].used == 135)
    }

    /// A file at the opencode.db path without the expected schema is an
    /// unrecognized shape — must surface as an error, not fake zero usage.
    @Test func openCodeMissingMessageTableThrowsUnexpectedShape() async throws {
        let home = TempHome()
        let dbPath = home.url.appendingPathComponent(".local/share/opencode/opencode.db")
        try! fileManager.createDirectory(at: dbPath.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
        try! Data("not a sqlite db".utf8).write(to: dbPath)

        let provider = LocalSessionStatsProvider(home: home.url.path)
        do {
            _ = try await provider.fetch()
            Issue.record("expected UsageParseError.unexpectedShape")
        } catch let error as UsageParseError {
            guard case .unexpectedShape = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
        }
    }

    // MARK: - Aggregation & caching

    /// No agent dirs at all is a normal state → empty items, not an error.
    @Test func emptyHomeReturnsNoItems() async throws {
        let home = TempHome()
        let provider = LocalSessionStatsProvider(home: home.url.path)
        let items = try await provider.fetch()
        #expect(items.isEmpty)
    }

    /// All three sources merge into one rolling total.
    @Test func sourcesMergeAcrossAgents() async throws {
        let home = TempHome()
        let now = Date()
        writeFile(".claude/projects/p/session.jsonl",
                  content: claudeLine(requestId: "r1", timestamp: now, input: 10, output: 5) + "\n",
                  in: home)
        writeFile(".codex/sessions/2026/09/01/rollout-a.jsonl",
                  content: codexLine(timestamp: now, totalInput: 7, totalOutput: 3) + "\n", in: home)
        makeOpenCodeDB(at: home.url.appendingPathComponent(".local/share/opencode/opencode.db"),
                       dataRows: ["m_complete"])

        let provider = LocalSessionStatsProvider(home: home.url.path)
        let items = try await provider.fetch()

        // 15 (Claude) + 10 (Codex) + 135 (opencode).
        #expect(items[0].used == 160)
    }

    /// The (path, mtime) cache must reuse parsed records: rewriting a file
    /// while keeping its mtime must not change the result, and a real mtime
    /// change must invalidate it.
    @Test func mtimeCacheReuseAndInvalidation() async throws {
        let home = TempHome()
        let now = Date()
        let fileURL = writeFile(".claude/projects/p/session.jsonl",
                                content: claudeLine(requestId: "r1", timestamp: now,
                                                    input: 100, output: 50) + "\n", in: home)
        // setAttributes round-trips mtime through Date→timespec and loses
        // sub-second precision, so pin a whole-second mtime the restore can
        // reproduce bit-exactly (real mtimes are only read, never rewritten,
        // so the provider's double-equality cache key is exact in practice).
        let fixedMtime = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        try fileManager.setAttributes([.modificationDate: fixedMtime], ofItemAtPath: fileURL.path)
        let provider = LocalSessionStatsProvider(home: home.url.path)

        let first = try await provider.fetch()
        #expect(first[0].used == 150)

        // Rewrite with different content but restore the original mtime:
        // the cache must hit and the new line must be invisible.
        let rewritten = claudeLine(requestId: "r1", timestamp: now, input: 100, output: 50) + "\n"
            + claudeLine(requestId: "r2", timestamp: now, input: 1000, output: 0) + "\n"
        try rewritten.data(using: .utf8)!.write(to: fileURL)
        try fileManager.setAttributes([.modificationDate: fixedMtime], ofItemAtPath: fileURL.path)
        let second = try await provider.fetch()
        #expect(second[0].used == 150)

        // Touch the mtime: the cache must invalidate and pick up the change.
        try fileManager.setAttributes(
            [.modificationDate: fixedMtime.addingTimeInterval(5)],
            ofItemAtPath: fileURL.path
        )
        let third = try await provider.fetch()
        #expect(abs(third[0].used! - 1150.0) < 0.5)
    }
}
