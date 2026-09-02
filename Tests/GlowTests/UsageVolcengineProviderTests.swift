import Testing
import Foundation
@testable import GlowCore

@Suite
final class VolcengineUsageProviderTests {

    private let provider = VolcengineUsageProvider(config: UsageProviderConfig(
        providerKey: "volcengine",
        displayName: "Volcengine Ark",
        token: "unused",
        extra: ["access_key_id": "AKTEST", "secret_access_key": "SKTEST"]
    ))

    // MARK: - Credentials guard

    @Test func missingAKSKThrowsOnFetch() async {
        let bare = VolcengineUsageProvider(config: UsageProviderConfig(
            providerKey: "volcengine", displayName: "Volcengine Ark", token: "x"
        ))
        await #expect(throws: UsageParseError.self) {
            try await bare.fetch()
        }
    }

    // MARK: - Region extraction

    @Test func regionDerivedFromDataPlaneURL() {
        #expect(VolcengineUsageProvider.region(
            fromBaseURL: "https://ark.cn-beijing.volces.com/api/v3"
        ) == "cn-beijing")
        #expect(VolcengineUsageProvider.region(
            fromBaseURL: "https://ark.cn-guangzhou.volces.com/api/v3"
        ) == "cn-guangzhou")
        #expect(VolcengineUsageProvider.region(fromBaseURL: nil) == "cn-beijing")
        #expect(VolcengineUsageProvider.region(fromBaseURL: "https://example.com") == "cn-beijing")
    }

    // MARK: - Signing (deterministic)

    @Test func signProducesVolcengineVariantShape() {
        let signed = VolcengineUsageProvider.sign(
            accessKeyID: "AKTEST",
            secretAccessKey: "SKTEST",
            region: "cn-beijing",
            canonicalQuery: "Action=GetAFPUsage&Region=cn-beijing&Version=2024-01-01",
            body: Data(),
            now: Date(timeIntervalSince1970: 1_788_345_678)
        )
        // Volcengine variant: HMAC-SHA256 algorithm (no AWS4 prefix), scope
        // ending in `request`, fixed SignedHeaders order.
        #expect(signed.authorization.hasPrefix("HMAC-SHA256 Credential=AKTEST/"))
        #expect(signed.authorization.contains("/cn-beijing/ark/request"))
        #expect(signed.authorization.contains(
            "SignedHeaders=host;x-date;x-content-sha256;content-type, Signature="
        ))
        // Same input must produce the same signature (deterministic signing).
        let again = VolcengineUsageProvider.sign(
            accessKeyID: "AKTEST",
            secretAccessKey: "SKTEST",
            region: "cn-beijing",
            canonicalQuery: "Action=GetAFPUsage&Region=cn-beijing&Version=2024-01-01",
            body: Data(),
            now: Date(timeIntervalSince1970: 1_788_345_678)
        )
        #expect(signed.authorization == again.authorization)
        #expect(signed.xDate == "20260902T104118Z")
        #expect(signed.xContentSha256 == Self.emptySHA256Hex)
    }

    private static let emptySHA256Hex =
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    @Test func canonicalQueryIsSortedAndEncoded() {
        let query = VolcengineUsageProvider.canonicalQuery(action: "GetAFPUsage", region: "cn-beijing")
        #expect(query == "Action=GetAFPUsage&Region=cn-beijing&Version=2024-01-01")
    }

    // MARK: - AFP (Agent Plan) parsing

    @Test func parseAFPMapsAbsoluteQuotaWindows() {
        let result: [String: Any] = [
            "AFPFiveHour": ["Quota": 100, "Used": 25, "ResetTime": 1_789_107_785],
            "AFPWeekly": ["Quota": 0, "Used": 0],           // not subscribed → skip
            "AFPMonthly": ["Quota": 200, "Used": 50],
        ]
        let items = VolcengineUsageProvider.parseAFP(result)
        #expect(items.count == 2)
        #expect(items[0].label == "5h")
        #expect(items[0].usedPercent == 25.0)
        #expect(items[1].label == "1m")
        #expect(items[1].usedPercent == 25.0)
    }

    // MARK: - Coding Plan parsing

    @Test func parseCodingPlanMapsPercentageWindows() throws {
        let body = try JSONSerialization.jsonObject(with: Data("""
        {"Result": {"QuotaUsage": [
            {"Level": "session", "Percent": 12},
            {"Level": "weekly", "Percent": 34.5},
            {"Level": "monthly", "Percent": 56}
        ]}}
        """.utf8)) as? [String: Any] ?? [:]
        let result = body["Result"] as? [String: Any] ?? [:]
        let items = VolcengineUsageProvider.parseCodingPlan(result)
        #expect(items.map { $0.label } == ["5h", "1w", "1m"])
        #expect(items.map { $0.usedPercent } == [12.0, 34.5, 56.0])
    }

    // MARK: - Error envelope classification

    @Test func authErrorCodesDetected() {
        #expect(VolcengineUsageProvider.isAuthErrorCode("InvalidAuthorization"))
        #expect(VolcengineUsageProvider.isAuthErrorCode("SignatureDoesNotMatch"))
        #expect(!VolcengineUsageProvider.isAuthErrorCode("NotFound"))
    }

    @Test func responseErrorExtractedFromEnvelope() throws {
        let envelope = try JSONSerialization.jsonObject(with: Data("""
        {"ResponseMetadata": {"Error": {"Code": "InvalidAuthorization", "Message": "bad creds"}}}
        """.utf8)) as? [String: Any] ?? [:]
        #expect(VolcengineUsageProvider.responseError(envelope)?.0 == "InvalidAuthorization")
    }
}

@Suite
final class ZhipuTeamUsageProviderTests {

    @Test func missingOrgProjectThrowsOnFetch() async {
        let bare = ZhipuTeamUsageProvider(config: UsageProviderConfig(
            providerKey: "zhipu-team", displayName: "GLM Team Plan", token: "tok"
        ))
        await #expect(throws: UsageParseError.self) {
            try await bare.fetch()
        }
    }

    @Test func parseReusesPersonalPlanShape() throws {
        let body = try JSONSerialization.jsonObject(with: Data("""
        {"success": true, "data": {"limits": [
            {"type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 18.0, "nextResetTime": 1000018000000}
        ]}}
        """.utf8)) as? [String: Any] ?? [:]
        let items = try GLMUsageProvider.parse(body)
        #expect(items.count == 1)
        #expect(items[0].label == "5h")
        #expect(items[0].usedPercent == 18.0)
    }
}
