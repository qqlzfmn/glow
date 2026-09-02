import Foundation

enum UsageHTTPError: Error {
    case badURL(String)
    /// Non-2xx response. Carries status and a truncated body for diagnostics.
    case httpStatus(Int, String)
}

/// Thrown by provider parsers when the response shape is not recognized.
/// Never swallow: an empty result would render a fake zero-usage menu.
enum UsageParseError: Error {
    case unexpectedShape(String)
}
struct UsageHTTPResponse {
    let status: Int
    /// Parsed JSON object; empty object when the body is not valid JSON.
    let body: Any
}

/// Minimal JSON GET helper shared by all usage provider queries. Non-2xx
/// responses throw `UsageHTTPError.httpStatus` with a body excerpt so error
/// messages in usage.json stay actionable.
enum UsageHTTP {
    static func getJSON(
        _ urlString: String,
        headers: [String: String] = [:],
        timeout: TimeInterval = 15
    ) async throws -> UsageHTTPResponse {
        guard let url = URL(string: urlString) else {
            throw UsageHTTPError.badURL(urlString)
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body: Any = (try? JSONSerialization.jsonObject(with: data)) ?? [:]
        if !(200...299).contains(status) {
            throw UsageHTTPError.httpStatus(status, bodyExcerpt(data))
        }
        return UsageHTTPResponse(status: status, body: body)
    }

    static func bodyExcerpt(_ data: Data, limit: Int = 200) -> String {
        let text = String(data: data, encoding: .utf8) ?? "<binary body>"
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }
}
