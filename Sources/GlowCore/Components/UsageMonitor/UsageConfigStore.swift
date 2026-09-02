import Foundation

/// Read/write access to the explicit usage-provider config file
/// (`~/.config/glow/usage.json`). Used by `usage-config`, the Provider
/// Settings window, and the menu's "Configure Providers…" action. File
/// permissions are tightened to 0600 since tokens are stored in plain JSON.
enum UsageConfigStore {
    static func configDir(home: String = NSHomeDirectory()) -> String {
        (home as NSString).appendingPathComponent(".config/glow")
    }

    static func configFile(home: String = NSHomeDirectory()) -> String {
        (configDir(home: home) as NSString).appendingPathComponent("usage.json")
    }

    /// Load explicit provider entries (delegates to the discovery parser so
    /// both paths share one schema interpretation). Missing file → [].
    static func load(home: String = NSHomeDirectory()) -> [UsageProviderConfig] {
        UsageConfig.discoverExplicitConfig(home: home)
    }

    /// Persist the full provider list atomically with 0600 permissions.
    static func save(_ configs: [UsageProviderConfig], home: String = NSHomeDirectory()) throws {
        let dir = configDir(home: home)
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        var providers: [[String: Any]] = []
        for config in configs {
            var entry: [String: Any] = [
                "type": config.providerKey,
                "name": config.displayName,
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
        let path = configFile(home: home)
        let data = try JSONSerialization.data(
            withJSONObject: ["providers": providers],
            options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        )
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: path
        )
    }

    /// Insert or replace one provider (matched by provider key).
    static func upsert(_ config: UsageProviderConfig, home: String = NSHomeDirectory()) throws {
        var configs = load(home: home).filter { $0.providerKey != config.providerKey }
        configs.append(config)
        try save(configs, home: home)
    }

    /// Remove one provider; returns false when it was not configured.
    static func remove(providerKey: String, home: String = NSHomeDirectory()) throws -> Bool {
        let configs = load(home: home)
        guard configs.contains(where: { $0.providerKey == providerKey }) else {
            return false
        }
        try save(configs.filter { $0.providerKey != providerKey }, home: home)
        return true
    }

    /// Ensure the config file exists so editors open something meaningful.
    static func ensureConfigFile(home: String = NSHomeDirectory()) -> String {
        if !FileManager.default.fileExists(atPath: configFile(home: home)) {
            try? save([], home: home)
        }
        return configFile(home: home)
    }
}
