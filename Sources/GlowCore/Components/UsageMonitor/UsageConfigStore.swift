import Foundation

/// Read/write access to the explicit usage-provider config file
/// (`~/.config/glow/usage.json`). Used by `usage-config` and the menu's
/// "Configure Providers…" action. File permissions are tightened to 0600
/// since tokens are stored in plain JSON.
enum UsageConfigStore {
    static var configDir: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".config/glow")
    }

    static var configFile: String {
        (configDir as NSString).appendingPathComponent("usage.json")
    }

    /// Load explicit provider entries (delegates to the discovery parser so
    /// both paths share one schema interpretation). Missing file → [].
    static func load() -> [UsageProviderConfig] {
        UsageConfig.discoverExplicitConfig(home: NSHomeDirectory())
    }

    /// Persist the full provider list atomically with 0600 permissions.
    static func save(_ configs: [UsageProviderConfig]) throws {
        try FileManager.default.createDirectory(
            atPath: configDir, withIntermediateDirectories: true
        )
        var providers: [[String: Any]] = []
        for config in configs {
            var entry: [String: Any] = [
                "type": config.providerKey,
                "token": config.token,
            ]
            if let baseURL = config.baseURL {
                entry["base_url"] = baseURL
            }
            for (key, value) in config.extra {
                entry[key] = value
            }
            providers.append(entry)
        }
        let data = try JSONSerialization.data(
            withJSONObject: ["providers": providers],
            options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        )
        try data.write(to: URL(fileURLWithPath: configFile), options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: configFile
        )
    }

    /// Insert or replace one provider (matched by provider key).
    static func upsert(_ config: UsageProviderConfig) throws {
        var configs = load().filter { $0.providerKey != config.providerKey }
        configs.append(config)
        try save(configs)
    }

    /// Remove one provider; returns false when it was not configured.
    static func remove(providerKey: String) throws -> Bool {
        let configs = load()
        guard configs.contains(where: { $0.providerKey == providerKey }) else {
            return false
        }
        try save(configs.filter { $0.providerKey != providerKey })
        return true
    }

    /// Ensure the config file exists so editors open something meaningful.
    static func ensureConfigFile() -> String {
        if !FileManager.default.fileExists(atPath: configFile) {
            try? save([])
        }
        return configFile
    }
}
