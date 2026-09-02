import Foundation

/// `install-hooks` CLI — argument parsing, agent selection and the
/// interactive prompt. Split out of CLIDispatch.swift.
enum InstallHooksCLI {

    static func run(_ args: [String]) -> Int32 {
        // Parse arguments manually (simple subset of argparse behavior).
        let allAgents: Bool = args.contains("--all")
        let dryRun: Bool = args.contains("--dry-run")
        let yes: Bool = args.contains("-y") || args.contains("--yes")

        var selectedAgents: [String] = []
        for (i, arg) in args.enumerated() {
            if arg == "--agent" || arg == "-a", i + 1 < args.count {
                selectedAgents.append(args[i + 1])
            }
            if arg.hasPrefix("--agent=") {
                selectedAgents.append(String(arg.dropFirst("--agent=".count)))
            }
        }

        let agents = HookInstaller.Agent.allCases
        let statuses = agents.map { HookInstaller.inspectAgent($0) }

        print("Glow hook installer")
        print("")
        for (index, status) in statuses.enumerated() {
            let marker = status.installed ? "ok" : "needs repair"
            let exists = status.configExists ? "found" : "missing"
            print("\(index + 1). \(status.agent.displayName): \(marker) (\(status.message); config \(exists))")
            print("   \(status.agent.configPath)")
        }

        var keys: [HookInstaller.Agent]
        if !selectedAgents.isEmpty {
            keys = selectedAgents.compactMap { name in
                let normalized = name.lowercased().trimmingCharacters(in: .whitespaces)
                if normalized == "claude" || normalized == "claudecode" {
                    return .claudeCode
                }
                if normalized == "picodingagent" {
                    return .pi
                }
                return HookInstaller.Agent(rawValue: normalized)
            }
            if keys.isEmpty {
                if let data = "Unsupported agent: \(selectedAgents.joined(separator: ", "))\n".data(using: .utf8) {
                    FileHandle.standardError.write(data)
                }
                return 2
            }
        } else if allAgents {
            keys = agents
        } else if yes {
            keys = statuses.filter { !$0.installed }.map { $0.agent }
            if keys.isEmpty { keys = agents }
        } else {
            // Interactive prompt.
            print("")
            let defaults = statuses.enumerated()
                .filter { !$0.element.installed }
                .map { "\($0.offset + 1)" }
                .joined(separator: ",")
            let defaultPrompt = defaults.isEmpty ? "1-\(statuses.count)" : defaults
            print("Select agents to install/repair [\(defaultPrompt)] (comma separated, or 'all'): ", terminator: "")
            guard let answer = readLine() else {
                print("\nNo agents selected.")
                return 0
            }
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved = trimmed.isEmpty ? defaultPrompt : trimmed
            if resolved.lowercased() == "all" || resolved == "*" || resolved.lowercased() == "a" {
                keys = agents
            } else if ["none", "n", "skip", "q", "quit"].contains(resolved.lowercased()) {
                print("No agents selected.")
                return 0
            } else {
                keys = resolved.components(separatedBy: ",").compactMap { chunk in
                    let c = chunk.trimmingCharacters(in: .whitespaces)
                    if c.isEmpty { return nil }
                    if c == "claude" || c == "claudecode" { return .claudeCode }
                    if c == "picodingagent" { return .pi }
                    if let intVal = Int(c), intVal >= 1, intVal <= agents.count {
                        return agents[intVal - 1]
                    }
                    return HookInstaller.Agent(rawValue: c.lowercased())
                }
            }
        }

        print("")
        for agent in keys {
            if dryRun {
                print("Would install/repair \(agent.displayName): \(agent.configPath)")
            } else {
                let result = HookInstaller.installAgentAndReport(agent)
                print("Installed \(agent.displayName): \(result.message)")
            }
        }

        return 0
    }
}

// MARK: - Helpers

extension FileHandle: @retroactive TextOutputStream {
    public func write(_ string: String) {
        if let data = string.data(using: .utf8) {
            write(data)
        }
    }
}
