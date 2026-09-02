import Foundation

/// Root JSON document of the sessions state file, written by the hook CLI.
struct SessionFile: Codable {
    var sessions: [String: SessionEntry]
}

struct SessionEntry: Codable {
    var signal: String
    var updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case signal
        case updatedAt = "updated_at"
    }
}

/// Serializable view of the current aggregate + sessions, as printed by `status`.
struct SessionSnapshot: Codable {
    var aggregate: String
    var sessions: [String: SessionEntry]
}
