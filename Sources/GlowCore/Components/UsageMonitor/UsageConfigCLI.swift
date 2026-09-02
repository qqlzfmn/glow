import Foundation

/// `usage-config` CLI — make every supported usage provider visible and
/// configurable without hand-writing JSON. Subcommands:
///
///     usage-config list            show supported types and current config
///     usage-config add [type]      interactive add (prompts for credentials)
///     usage-config remove <type>   remove one explicit entry
///
/// Auto-discovered providers (claude env block, opencode auth.json) are shown
/// in `list` but cannot be edited here — they come from the agent configs.
/// The provider-type registry is shared with the Provider Settings window
/// (`UsageKinds.all`).
enum UsageConfigCLI {

    static func run(_ args: [String]) -> Int32 {
        let sub = args.count >= 2 ? args[1] : ""
        switch sub {
        case "list", "":
            return list()
        case "add":
            return add(selected: args.count >= 3 ? args[2] : nil)
        case "remove", "rm":
            guard args.count >= 3 else {
                print("Usage: usage-config remove <type>")
                return 2
            }
            return remove(type: args[2])
        default:
            print("Usage: usage-config [list|add [type]|remove <type>]")
            return 2
        }
    }

    // MARK: - list

    private static func list() -> Int32 {
        let configuredKeys = Set(UsageConfigStore.load().map { $0.providerKey })
        let autoDetected = Set(
            UsageConfig.discoverProviders(home: NSHomeDirectory()).map { $0.providerKey }
        )

        print("Usage providers (configured in \(UsageConfigStore.configFile())):")
        print("")
        for kind in UsageKinds.all {
            let state: String
            if configuredKeys.contains(kind.type) {
                state = "configured"
            } else if autoDetected.contains(kind.type) {
                state = "auto-discovered (from agent config)"
            } else {
                state = "not configured"
            }
            print("  \(kind.displayName) [\(kind.type)]: \(state)")
        }
        print("")
        print("Add:    glow usage-config add [type]")
        print("Remove: glow usage-config remove <type>")
        return 0
    }

    // MARK: - add

    private static func add(selected type: String?) -> Int32 {
        let kind: UsageProviderKind
        if let type {
            guard let resolved = UsageKinds.kind(forType: type) else {
                fputs("glow: unknown provider type \(type)\n", stderr)
                return 2
            }
            kind = resolved
        } else {
            print("Select provider type:")
            for (index, candidate) in UsageKinds.all.enumerated() {
                print("  \(index + 1). \(candidate.displayName) [\(candidate.type)]")
            }
            guard let answer = prompt("Type number or key: "), !answer.isEmpty else {
                print("Aborted.")
                return 0
            }
            let resolved: UsageProviderKind?
            if let index = Int(answer), index >= 1, index <= UsageKinds.all.count {
                resolved = UsageKinds.all[index - 1]
            } else {
                resolved = UsageKinds.kind(forType: answer)
            }
            guard let chosen = resolved else {
                fputs("glow: unknown provider type \(answer)\n", stderr)
                return 2
            }
            kind = chosen
        }

        var extra: [String: String] = [:]
        var token = ""
        for (index, field) in kind.prompts.enumerated() {
            guard let value = prompt("\(field.prompt): "), !value.isEmpty else {
                print("Aborted.")
                return 0
            }
            if index == 0 {
                token = value  // first prompt is the primary token
            } else {
                extra[field.key] = value
            }
        }
        var baseURL: String?
        if let base = prompt("Base URL (optional, Enter to skip): "), !base.isEmpty {
            baseURL = base
        }

        let config = UsageProviderConfig(
            providerKey: kind.type,
            displayName: kind.displayName,
            baseURL: baseURL,
            token: token,
            extra: extra
        )
        do {
            try UsageConfigStore.upsert(config)
        } catch {
            fputs("glow: cannot write \(UsageConfigStore.configFile()): \(error)\n", stderr)
            return 1
        }
        print("Saved \(kind.displayName). It appears in the menu on the next poll.")
        return 0
    }

    // MARK: - remove

    private static func remove(type: String) -> Int32 {
        guard let kind = UsageKinds.kind(forType: type) else {
            fputs("glow: unknown provider type \(type)\n", stderr)
            return 2
        }
        do {
            if try UsageConfigStore.remove(providerKey: kind.type) {
                print("Removed \(kind.displayName).")
                return 0
            }
            print("\(kind.displayName) was not configured in the explicit config.")
            return 0
        } catch {
            fputs("glow: cannot update \(UsageConfigStore.configFile()): \(error)\n", stderr)
            return 1
        }
    }

    private static func prompt(_ text: String) -> String? {
        print(text, terminator: "")
        guard let answer = readLine() else { return nil }
        return answer.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
