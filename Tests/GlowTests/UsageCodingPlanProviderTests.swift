import Testing
import Foundation
@testable import GlowCore

/// Fixture tests for the coding-plan usage providers (GLM / Kimi / MiniMax /
/// ZenMux / OpenCode Go). Response shapes mirror cc-switch's `coding_plan.rs`,
/// the single source of truth for endpoints and fields.
final class UsageCodingPlanProviderTests {

    /// Feed fixtures through JSONSerialization exactly like production bodies.
    private func json(_ text: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    // MARK: - GLM (Zhipu)

    @Test func glmNewPlanClassifiesWindowsByUnitField() throws {
        // Issue #3036 shape: near the end of a weekly period the weekly
        // bucket can reset sooner than the 5h bucket, so the `unit` field
        // must win over reset-time ordering.
        let body = try json("""
        {"success": true, "data": {"level": "max", "limits": [
            {"type": "TIME_LIMIT", "percentage": 7.0},
            {"type": "TOKENS_LIMIT", "unit": 6, "number": 7, "percentage": 42.0, "nextResetTime": 1000003600000},
            {"type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 1.0, "nextResetTime": 1000018000000}
        ]}}
        """)
        let items = try GLMUsageProvider.parse(body)
        #expect(items.count == 2)
        #expect(items[0].label == "5h")
        #expect(items[0].usedPercent == 1.0)
        #expect(items[0].resetsAt == "2001-09-09T06:46:40Z")
        #expect(items[1].label == "1w")
        #expect(items[1].usedPercent == 42.0)
        #expect(items[1].resetsAt == "2001-09-09T02:46:40Z")
    }

    @Test func glmOldPlanSingleTierAndTimeLimitSkipped() throws {
        let body = try json("""
        {"success": true, "data": {"limits": [
            {"type": "TOKENS_LIMIT", "percentage": 2.0, "nextResetTime": 1774967594803},
            {"type": "TIME_LIMIT", "percentage": 0.0}
        ]}}
        """)
        let items = try GLMUsageProvider.parse(body)
        #expect(items.count == 1)
        #expect(items[0].label == "5h")
        #expect(items[0].usedPercent == 2.0)
        #expect(items[0].resetsAt != nil)
    }

    @Test func glmLitePlanIncludesMonthlyToolQuota() throws {
        // Live lite-tier shape: one 5h token window plus the monthly
        // MCP-tool TIME_LIMIT (unit 5); lite has no weekly token window.
        let body = try json("""
        {"code":200,"msg":"ok","success":true,"data":{"level":"lite","limits":[
            {"type":"TIME_LIMIT","unit":5,"number":1,"usage":100,"currentValue":0,"remaining":100,"percentage":0,"nextResetTime":1789107785999},
            {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":0}
        ]}}
        """)
        let items = try GLMUsageProvider.parse(body)
        #expect(items.count == 2)
        #expect(items[0].label == "5h")
        #expect(items[0].usedPercent == 0)
        #expect(items[1].label == "1m")
        #expect(items[1].usedPercent == 0)
        #expect(items[1].resetsAt == "2026-09-11T06:23:05Z")
    }

    @Test func glmResetLessEntryFillsFiveHourSlot() throws {
        // A 0% 5h bucket may lack nextResetTime; it must claim the 5h slot
        // while the reset-bearing entry fills the weekly slot.
        let body = try json("""
        {"success": true, "data": {"limits": [
            {"type": "TOKENS_LIMIT", "percentage": 25.0, "nextResetTime": 2000000000000},
            {"type": "TOKENS_LIMIT", "percentage": 0.0}
        ]}}
        """)
        let items = try GLMUsageProvider.parse(body)
        #expect(items.count == 2)
        #expect(items[0].usedPercent == 0.0)
        #expect(items[0].resetsAt == nil)
        #expect(items[1].usedPercent == 25.0)
        #expect(items[1].resetsAt != nil)
    }

    @Test func glmBusinessErrorThrows() {
        let body = try! json("""
        {"success": false, "msg": "invalid token"}
        """)
        #expect(throws: UsageParseError.self) {
            try GLMUsageProvider.parse(body)
        }
    }

    @Test func glmLimitsWithoutTokenEntriesThrows() {
        let body = try! json("""
        {"success": true, "data": {"limits": [{"type": "TIME_LIMIT", "percentage": 5.0}]}}
        """)
        #expect(throws: UsageParseError.self) {
            try GLMUsageProvider.parse(body)
        }
    }

    @Test func glmQuotaURLRouting() {
        #expect(
            GLMUsageProvider.quotaURL(baseURL: "https://open.bigmodel.cn/api/paas/v4")
                == "https://open.bigmodel.cn/api/monitor/usage/quota/limit"
        )
        #expect(
            GLMUsageProvider.quotaURL(baseURL: "https://api.z.ai/api/coding/paas/v4")
                == "https://api.z.ai/api/monitor/usage/quota/limit"
        )
        #expect(
            GLMUsageProvider.quotaURL(baseURL: nil)
                == "https://open.bigmodel.cn/api/monitor/usage/quota/limit"
        )
    }

    // MARK: - Kimi For Coding

    @Test func kimiParsesFiveHourAndWeekly() throws {
        let body = try json("""
        {"limits": [
            {"detail": {"limit": 30, "remaining": 12, "resetTime": "2026-08-26T14:12:03Z"}}
        ], "usage": {"limit": 150, "remaining": 90, "resetTime": 1000003600000}}
        """)
        let items = try KimiUsageProvider.parse(body)
        #expect(items.count == 2)
        #expect(items[0].label == "5h")
        #expect(items[0].usedPercent == 60.0)
        #expect(items[0].resetsAt == "2026-08-26T14:12:03Z")
        #expect(items[1].label == "1w")
        #expect(items[1].usedPercent == 40.0)
        // Numeric reset time in milliseconds converts to ISO 8601.
        #expect(items[1].resetsAt == "2001-09-09T02:46:40Z")
    }

    @Test func kimiUnknownShapeThrows() {
        #expect(throws: UsageParseError.self) {
            try KimiUsageProvider.parse(try json("{}"))
        }
    }

    // MARK: - MiniMax

    @Test func minimaxParsesGeneralEntryFlippingRemainingPercent() throws {
        let body = try json("""
        {"base_resp": {"status_code": 0, "status_msg": "success"},
         "model_remains": [
            {"model_name": "video", "current_interval_remaining_percent": 50.0},
            {"model_name": "general",
             "current_interval_remaining_percent": 70.0, "end_time": 1000003600000,
             "current_weekly_status": 1,
             "current_weekly_remaining_percent": 25.0, "weekly_end_time": 2000000000000}
         ]}
        """)
        let items = try MiniMaxUsageProvider.parse(body)
        #expect(items.count == 2)
        #expect(items[0].label == "5h")
        #expect(items[0].usedPercent == 30.0)
        #expect(items[0].resetsAt == "2001-09-09T02:46:40Z")
        #expect(items[1].label == "1w")
        #expect(items[1].usedPercent == 75.0)
        #expect(items[1].resetsAt == "2033-05-18T03:33:20Z")
    }

    @Test func minimaxPlanWithoutWeeklyCapSkipsWeeklyItem() throws {
        let body = try json("""
        {"model_remains": [
            {"model_name": "general", "current_interval_remaining_percent": 40.0,
             "current_weekly_status": 3, "current_weekly_remaining_percent": 100.0}
        ]}
        """)
        let items = try MiniMaxUsageProvider.parse(body)
        #expect(items.count == 1)
        #expect(items[0].label == "5h")
        #expect(items[0].usedPercent == 60.0)
    }

    @Test func minimaxBusinessErrorThrows() {
        let body = try! json("""
        {"base_resp": {"status_code": 1004, "status_msg": "invalid api key"},
         "model_remains": []}
        """)
        #expect(throws: UsageParseError.self) {
            try MiniMaxUsageProvider.parse(body)
        }
    }

    @Test func minimaxMissingGeneralEntryThrows() {
        let body = try! json("""
        {"model_remains": [{"model_name": "video", "current_interval_remaining_percent": 50.0}]}
        """)
        #expect(throws: UsageParseError.self) {
            try MiniMaxUsageProvider.parse(body)
        }
    }

    @Test func minimaxRemainsURLRouting() {
        #expect(
            MiniMaxUsageProvider.remainsURL(baseURL: "https://api.minimaxi.com/v1")
                == "https://api.minimaxi.com/v1/api/openplatform/coding_plan/remains"
        )
        #expect(
            MiniMaxUsageProvider.remainsURL(baseURL: "https://api.minimax.io/v1")
                == "https://api.minimax.io/v1/api/openplatform/coding_plan/remains"
        )
        #expect(
            MiniMaxUsageProvider.remainsURL(baseURL: nil)
                == "https://api.minimaxi.com/v1/api/openplatform/coding_plan/remains"
        )
    }

    // MARK: - ZenMux

    @Test func zenmuxParsesBothWindowsScalingFraction() throws {
        let body = try json("""
        {"success": true, "data": {"plan": {"tier": "pro"}, "account_status": "healthy",
            "quota_5_hour": {"usage_percentage": 0.25, "resets_at": "2026-07-21T10:00:00Z",
                             "used_value_usd": 3.0, "max_value_usd": 12.0},
            "quota_7_day": {"usage_percentage": "0.1", "resets_at": "2026-07-28T00:00:00Z",
                            "used_value_usd": 3.0, "max_value_usd": 30.0}}}
        """)
        let items = try ZenMuxUsageProvider.parse(body)
        #expect(items.count == 2)
        #expect(items[0].label == "5h")
        #expect(items[0].usedPercent == 25.0)
        #expect(items[0].total == 12.0)
        #expect(items[0].unit == "USD")
        #expect(items[0].resetsAt == "2026-07-21T10:00:00Z")
        #expect(items[1].label == "1w")
        #expect(items[1].usedPercent == 10.0)
    }

    @Test func zenmuxFailureEnvelopeThrows() {
        let body = try! json("""
        {"success": false, "message": "unauthorized"}
        """)
        #expect(throws: UsageParseError.self) {
            try ZenMuxUsageProvider.parse(body)
        }
    }

    @Test func zenmuxMissingDataThrows() {
        let body = try! json("""
        {"success": true}
        """)
        #expect(throws: UsageParseError.self) {
            try ZenMuxUsageProvider.parse(body)
        }
    }

    @Test func zenmuxQuotaURLUsesConfiguredEndpointVerbatim() {
        #expect(
            ZenMuxUsageProvider.quotaURL(baseURL: "https://api.zenmux.com/v1/usage/")
                == "https://api.zenmux.com/v1/usage"
        )
        #expect(
            ZenMuxUsageProvider.quotaURL(baseURL: nil)
                == "https://zenmux.ai/api/v1/management/subscription/detail"
        )
    }

    // MARK: - OpenCode Go

    @Test func opencodeGoParsesThreeWindows() throws {
        let body = try json("""
        {"usage": {
            "rolling": {"status": "ok", "percent": 37, "resetsAt": "2026-08-26T14:12:03.000Z"},
            "weekly": {"status": "ok", "percent": 62, "resetsAt": "2026-08-31T00:00:00.000Z"},
            "monthly": {"status": "rate-limited", "percent": 100, "resetsAt": "2026-09-11T00:00:00.000Z"}
        }}
        """)
        let items = try OpenCodeGoUsageProvider.parse(body)
        #expect(items.count == 3)
        #expect(items[0].label == "5h")
        #expect(items[0].usedPercent == 37.0)
        #expect(items[0].resetsAt == "2026-08-26T14:12:03.000Z")
        #expect(items[1].label == "1w")
        #expect(items[1].usedPercent == 62.0)
        #expect(items[2].label == "1m")
        #expect(items[2].usedPercent == 100.0)
    }

    @Test func opencodeGoZeroPercentDropsPlaceholderReset() throws {
        let body = try json("""
        {"usage": {"rolling": {"status": "ok", "percent": 0, "resetsAt": "2026-08-26T15:00:00.000Z"}}}
        """)
        let items = try OpenCodeGoUsageProvider.parse(body)
        #expect(items.count == 1)
        #expect(items[0].usedPercent == 0.0)
        #expect(items[0].resetsAt == nil)
    }

    @Test func opencodeGoPartialWindowsSkipMalformed() throws {
        // Bad windows skip, good windows survive; string percents tolerated.
        let body = try json("""
        {"usage": {
            "rolling": {"status": "ok"},
            "weekly": {"status": "ok", "percent": "12"},
            "monthly": null
        }}
        """)
        let items = try OpenCodeGoUsageProvider.parse(body)
        #expect(items.count == 1)
        #expect(items[0].label == "1w")
        #expect(items[0].usedPercent == 12.0)
    }

    @Test func opencodeGoLegacyFlatShapeThrows() {
        // The old flat shape (live for 53 minutes on 2026-08-11) must not
        // parse into a fake zero-usage menu.
        let body = try! json("""
        {"useBalance": false, "rollingUsage": {"status": "ok", "usagePercent": 37, "resetInSec": 3600}}
        """)
        #expect(throws: UsageParseError.self) {
            try OpenCodeGoUsageProvider.parse(body)
        }
    }
}
