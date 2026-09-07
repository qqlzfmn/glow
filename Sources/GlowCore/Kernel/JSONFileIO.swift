import Foundation

/// Shared, generic JSON file IO used by the on-disk stores
/// (`SessionStore`, `UsageStore`) — decode-with-corruption-tolerance on
/// read, pretty-printed atomic write on save. Keeps the two stores from
/// duplicating the same encoding/decoding/atomicity plumbing.
enum JSONFileIO {

    /// Read and decode a JSON file. Missing files yield `nil`; a malformed
    /// (non-empty) file is traced to stderr and also yields `nil` — silent
    /// data loss would hide bugs.
    static func read<T: Decodable>(at path: String, name: String) -> T? {
        guard let data = FileManager.default.contents(atPath: path) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            fputs("glow: corrupt \(name) ignored (\(error.localizedDescription))\n", stderr)
            return nil
        }
    }

    /// Encode and atomically write a JSON file (temp file + rename, so a
    /// concurrent reader never sees a half-written file). Creates the state
    /// directory on demand. Throws on encode or write failure.
    static func write<T: Encodable>(_ value: T, to path: String, stateDir: String) throws {
        try FileManager.default.createDirectory(
            atPath: stateDir, withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}