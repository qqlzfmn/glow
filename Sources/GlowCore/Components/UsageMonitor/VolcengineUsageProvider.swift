import Foundation
import CryptoKit

/// Volcengine Ark Agent/Coding Plan quota via the control-plane OpenAPI
/// (`open.volcengineapi.com`, AK/SK signed — the inference Bearer key is
/// rejected by the gateway). Mirrors cc-switch `coding_plan.rs`, including
/// the two deviations from standard AWS SigV4 that make signing fail if
/// copied naively:
///   1. canonical headers / SignedHeaders use a FIXED order
///      `host;x-date;x-content-sha256;content-type` (not alphabetical);
///   2. algorithm string `HMAC-SHA256` (no `AWS4` prefix), credential scope
///      ends in `request`, and the signing key derives as
///      kDate = HMAC(SK, date) (SK without `AWS4` prefix).
final class VolcengineUsageProvider: UsageProducer {
    let providerKey = "volcengine"
    let displayName = "Volcengine Ark"
    private let config: UsageProviderConfig

    private static let host = "open.volcengineapi.com"
    private static let apiVersion = "2024-01-01"
    private static let service = "ark"
    private static let contentType = "application/json; charset=utf-8"
    private static let signedHeaders = "host;x-date;x-content-sha256;content-type"
    private static let akskHint =
        "Check the AccessKey ID / Secret are correct and the account has Ark usage-query (OpenAPI) permission."

    init(config: UsageProviderConfig) {
        self.config = config
    }

    // MARK: - UsageProducer

    func fetch() async throws -> [UsageItem] {
        // CLI/GUI store the first prompt in the `token` slot; for this
        // provider that is the AccessKey ID. `extra` remains the explicit
        // two-key shape for hand-written configs.
        let accessKey = config.extra["access_key_id"] ?? config.token
        let secretKey = config.extra["secret_access_key"]
        guard !accessKey.isEmpty, let secretKey, !secretKey.isEmpty else {
            throw UsageParseError.unexpectedShape(
                "volcengine: needs access_key_id and secret_access_key in the config"
            )
        }
        let region = Self.region(fromBaseURL: config.baseURL)

        // 1) Agent Plan first (absolute Quota/Used values)…
        let afp = try await Self.call(
            region: region, accessKeyID: accessKey, secretAccessKey: secretKey, action: "GetAFPUsage"
        )
        if case .body(let envelope) = afp {
            let items = Self.parseAFP(envelope.result)
            if !items.isEmpty { return items }
        }
        // …2) then Coding Plan (percentage-only windows). Auth failures stop
        // both probes; soft failures fall through to the second call.
        let coding = try await Self.call(
            region: region, accessKeyID: accessKey, secretAccessKey: secretKey, action: "GetCodingPlanUsage"
        )
        if case .body(let envelope) = coding {
            let items = Self.parseCodingPlan(envelope.result)
            if !items.isEmpty { return items }
        }

        let details = [afp.detail, coding.detail].compactMap { $0 }.joined(separator: "; ")
        throw UsageParseError.unexpectedShape(
            details.isEmpty
                ? "volcengine: no active Agent Plan or Coding Plan subscription found"
                : "volcengine: \(details)"
        )
    }

    // MARK: - Region

    /// Control-plane calls ignore the data-plane host except for the region
    /// (`ark.cn-beijing.volces.com` → `cn-beijing`); defaults to cn-beijing.
    static func region(fromBaseURL url: String?) -> String {
        guard let url, let match = url.range(of: #"ark\.([a-z-]+)\.volces\.com"#, options: .regularExpression) else {
            return "cn-beijing"
        }
        let segment = url[match]  // "ark.cn-beijing.volces.com"
        let parts = segment.split(separator: ".")
        return parts.count > 1 ? String(parts[1]) : "cn-beijing"
    }

    // MARK: - SigV4 (Volcengine variant)

    struct SignedRequest {
        let authorization: String
        let xDate: String
        let xContentSha256: String
    }

    /// Deterministic signer; `now` is injectable for fixture tests.
    static func sign(
        accessKeyID: String,
        secretAccessKey: String,
        region: String,
        canonicalQuery: String,
        body: Data,
        now: Date
    ) -> SignedRequest {
        func hmac(_ key: Data, _ data: Data) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
        }
        func hex(_ data: Data) -> String {
            data.map { String(format: "%02x", $0) }.joined()
        }

        let xDate = Self.format("%Y%m%dT%H%M%SZ", now)
        let shortDate = Self.format("%Y%m%d", now)
        let contentSha = hex(Data(SHA256.hash(data: body)))

        // Fixed-order canonical headers (Volcengine-specific, NOT sorted).
        let canonicalHeaders =
            "host:\(host)\nx-date:\(xDate)\nx-content-sha256:\(contentSha)\ncontent-type:\(contentType)\n"
        let canonicalRequest =
            "POST\n/\n\(canonicalQuery)\n\(canonicalHeaders)\n\(signedHeaders)\n\(contentSha)"

        let credentialScope = "\(shortDate)/\(region)/\(service)/request"
        let stringToSign =
            "HMAC-SHA256\n\(xDate)\n\(credentialScope)\n\(hex(Data(SHA256.hash(data: Data(canonicalRequest.utf8)))))"

        // Key derivation: kDate = HMAC(SK, date) — SK WITHOUT an AWS4 prefix.
        let kDate = hmac(Data(secretAccessKey.utf8), Data(shortDate.utf8))
        let kRegion = hmac(kDate, Data(region.utf8))
        let kService = hmac(kRegion, Data(service.utf8))
        let kSigning = hmac(kService, Data("request".utf8))
        let signature = hex(hmac(kSigning, Data(stringToSign.utf8)))

        return SignedRequest(
            authorization:
                "HMAC-SHA256 Credential=\(accessKeyID)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
            xDate: xDate,
            xContentSha256: contentSha
        )
    }

    /// UTC basic-format formatter (`%Y%m%dT%H%M%SZ` / `%Y%m%d`).
    private static func format(_ pattern: String, _ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = pattern == "%Y%m%d" ? "yyyyMMdd" : "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// RFC3986 encode: unreserved characters pass through, everything else
    /// becomes `%XX`. Used for the canonical query string.
    static func uriEncode(_ input: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return input.addingPercentEncoding(withAllowedCharacters: allowed) ?? input
    }

    static func canonicalQuery(action: String, region: String) -> String {
        [("Action", action), ("Region", region), ("Version", apiVersion)]
            .sorted { $0.0 < $1.0 }
            .map { "\(uriEncode($0.0))=\(uriEncode($0.1))" }
            .joined(separator: "&")
    }

    // MARK: - OpenAPI call

    enum Call {
        /// 2xx envelope without an error; carries the parsed JSON.
        case body(Envelope)
        /// Credential problem — stop probing further actions.
        case auth(String)
        /// Business-level failure — record and keep going.
        case soft(String)

        var detail: String? {
            switch self {
            case .body: return nil
            case .auth(let detail), .soft(let detail): return detail
            }
        }
    }

    struct Envelope {
        let result: [String: Any]
    }

    static func call(
        region: String, accessKeyID: String, secretAccessKey: String, action: String
    ) async throws -> Call {
        let query = canonicalQuery(action: action, region: region)
        let signed = sign(
            accessKeyID: accessKeyID, secretAccessKey: secretAccessKey,
            region: region, canonicalQuery: query, body: Data(), now: Date()
        )
        let response = try await UsageHTTP.post(
            "https://\(host)/?\(query)",
            headers: [
                "X-Date": signed.xDate,
                "X-Content-Sha256": signed.xContentSha256,
                "Content-Type": contentType,
                "Authorization": signed.authorization,
            ],
            body: Data()
        )

        guard let envelope = response.body as? [String: Any] else {
            return .soft("\(action): response is not a JSON object")
        }
        if let error = responseError(envelope) {
            let (code, message) = error
            if isAuthErrorCode(code) {
                return .auth("Authentication failed (\(code)): \(message). \(akskHint)")
            }
            return .soft("API error (\(code)): \(message)")
        }
        if !(200...299).contains(response.status) {
            return .auth("Authentication failed (HTTP \(response.status)). \(akskHint)")
        }
        let result = envelope["Result"] as? [String: Any] ?? envelope
        return .body(Envelope(result: result))
    }

    /// Extract `(code, message)` from the OpenAPI error envelope.
    static func responseError(_ envelope: [String: Any]) -> (String, String)? {
        let metadata = envelope["ResponseMetadata"] as? [String: Any] ?? envelope
        guard let error = metadata["Error"] as? [String: Any] else { return nil }
        guard let code = error["Code"] as? String else { return nil }
        let message = error["Message"] as? String ?? ""
        return (code, message)
    }

    static func isAuthErrorCode(_ code: String) -> Bool {
        let lowered = code.lowercased()
        return lowered.contains("auth") || lowered.contains("signature")
            || lowered.contains("credential") || lowered.contains("securitytoken")
    }

    // MARK: - Parsers

    /// Agent Plan windows carry absolute Quota/Used AFP values; Quota<=0
    /// means the window is not subscribed and is skipped (an empty result
    /// also triggers the Coding-Plan fallback in `fetch`).
    static func parseAFP(_ result: [String: Any]) -> [UsageItem] {
        [( "AFPFiveHour", "5 Hours"), ("AFPWeekly", "1 Week"), ("AFPMonthly", "1 Month")].compactMap { key, label in
            guard let window = result[key] as? [String: Any],
                  let quota = asDouble(window["Quota"]), quota > 0 else { return nil }
            let used = asDouble(window["Used"]) ?? 0.0
            return UsageItem(
                label: label,
                usedPercent: used / quota * 100.0,
                remaining: nil,
                total: nil,
                unit: nil,
                resetsAt: resetString(window["ResetTime"])
            )
        }
    }

    /// Coding Plan windows are percentage-only, loosely matching
    /// `QuotaUsage`/`Usages`/`Details` arrays and several field-name variants
    /// (official docs do not specify the response shape).
    static func parseCodingPlan(_ result: [String: Any]) -> [UsageItem] {
        let array = (result["QuotaUsage"] as? [[String: Any]])
            ?? (result["Usages"] as? [[String: Any]])
            ?? (result["Details"] as? [[String: Any]])
            ?? []
        return array.compactMap { item in
            let raw = (item["Level"] as? String)
                ?? (item["Type"] as? String)
                ?? (item["Period"] as? String)
                ?? (item["Label"] as? String)
                ?? (item["Window"] as? String)
                ?? ""
            guard let label = Self.codingWindow(raw) else { return nil }
            let percent = asDouble(item["Percent"])
                ?? asDouble(item["UsedPercent"])
                ?? asDouble(item["UsagePercent"])
                ?? 0.0
            return UsageItem(
                label: label,
                usedPercent: percent,
                remaining: nil,
                total: nil,
                unit: nil,
                resetsAt: resetString(item["ResetTime"]) ?? resetString(item["ResetTimestamp"])
            )
        }
    }

    private static func codingWindow(_ label: String) -> String? {
        switch label.lowercased() {
        case "session", "5h", "fivehour", "five_hour", "rolling_5h": return "5 Hours"
        case "weekly", "week", "7d": return "1 Week"
        case "monthly", "month": return "1 Month"
        default: return nil
        }
    }

    // MARK: - Small helpers

    private static func asDouble(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    /// Seconds/milliseconds epoch → ISO 8601 (strings pass through as-is).
    private static func resetString(_ value: Any?) -> String? {
        if let text = value as? String, !text.isEmpty { return text }
        guard let number = asDouble(value), number > 0 else { return nil }
        let seconds = number > 1_000_000_000_000 ? number / 1000.0 : number
        let date = Date(timeIntervalSince1970: seconds)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
