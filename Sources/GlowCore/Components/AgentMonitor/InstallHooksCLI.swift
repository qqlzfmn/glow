import Foundation

/// `install-hooks` / `uninstall-hooks` CLI — argument parsing, agent selection
/// and the interactive prompt. Split out of CLIDispatch.swift; the two commands
/// share one argument parser and one selection/execution flow.
enum InstallHooksCLI {

    enum Mode {
        case install
        case uninstall

        var header: String {
            switch self {
            case .install: return "Glow hook installer"
            case .uninstall: return "Glow hook uninstaller"
            }
        }
    }

    /// Shared argument parsing for install-hooks / uninstall-hooks
    /// (`--all`, `--dry-run`, `-y/--yes`, `--agent X` / `-a X` / `--agent=X`).
    struct Options {
        let allAgents: Bool
        let dryRun: Bool
        let yes: Bool
        let selectedAgents: [String]
    }

    static func parseOptions(_ args: [String]) -> Options {
        // Parse arguments manually (simple subset of argparse behavior).
        let allAgents = args.contains("--all")
        let dryRun = args.contains("--dry-run")
        let yes = args.contains("-y") || args.contains("--yes")

        var selectedAgents: [String] = []
        for (i, arg) in args.enumerated() {
            if arg == "--agent" || arg == "-a", i + 1 < args.count {
                selectedAgents.append(args[i + 1])
            }
            if arg.hasPrefix("--agent=") {
                selectedAgents.append(String(arg.dropFirst("--agent=".count)))
            }
        }
        return Options(allAgents: allAgents, dryRun: dryRun, yes: yes, selectedAgents: selectedAgents)
    }

    static func run(_ args: [String]) -> Int32 {
        run(args, mode: .install)
    }

    static func run(_ args: [String], mode: Mode) -> Int32 {
        let options = parseOptions(args)

        let agents = HookInstaller.Agent.allCases
        let statuses = agents.map { HookInstaller.inspectAgent($0) }

        print(mode.header)
        print("")
        for (index, status) in statuses.enumerated() {
            let marker = status.installed ? "ok" : "needs repair"
            let exists = status.configExists ? "found" : "missing"
            print("\(index + 1). \(status.agent.displayName): \(marker) (\(status.message); config \(exists))")
            print("   \(status.agent.configPath)")
        }

        var keys: [HookInstaller.Agent]
        if !options.selectedAgents.isEmpty {
            keys = options.selectedAgents.compactMap(resolveAgentName)
            if keys.isEmpty {
                if let data = "Unsupported agent: \(options.selectedAgents.joined(separator: ", "))\n".data(using: .utf8) {
                    FileHandle.standardError.write(data)
                }
                return 2
            }
        } else if options.allAgents {
            keys = agents
        } else if options.yes {
            // install: repair what is broken; uninstall: remove what is installed.
            let wanted: (HookInstaller.AgentStatus) -> Bool = mode == .install
                ? { !$0.installed }
                : { $0.installed }
            keys = statuses.filter { wanted($0) }.map { $0.agent }
            if keys.isEmpty { keys = agents }
        } else {
            // Interactive prompt.
            print("")
            let wanted: (HookInstaller.AgentStatus) -> Bool = mode == .install
                ? { !$0.installed }
                : { $0.installed }
            let defaults = statuses.enumerated()
                .filter { wanted($0.element) }
                .map { "\($0.offset + 1)" }
                .joined(separator: ",")
            let defaultPrompt = defaults.isEmpty ? "1-\(statuses.count)" : defaults
            let verb = mode == .install ? "install/repair" : "uninstall"
            print("Select agents to \(verb) [\(defaultPrompt)] (comma separated, or 'all'): ", terminator: "")
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
                    if let intVal = Int(c), intVal >= 1, intVal <= agents.count {
                        return agents[intVal - 1]
                    }
                    return resolveAgentName(c)
                }
            }
        }

        print("")
        for agent in keys {
            if options.dryRun {
                switch mode {
                case .install:
                    print("Would install/repair \(agent.displayName): \(agent.configPath)")
                case .uninstall:
                    print("Would uninstall \(agent.displayName): \(agent.configPath)")
                }
            } else {
                switch mode {
                case .install:
                    let result = HookInstaller.installAgentAndReport(agent)
                    print("Installed \(agent.displayName): \(result.message)")
                case .uninstall:
                    let result = HookInstaller.uninstallAgentAndReport(agent)
                    print("Uninstalled \(agent.displayName): \(result.message)")
                }
            }
        }

        return 0
    }

    private static func resolveAgentName(_ name: String) -> HookInstaller.Agent? {
        let normalized = name.lowercased().trimmingCharacters(in: .whitespaces)
        if normalized == "claude" || normalized == "claudecode" {
            return .claudeCode
        }
        if normalized == "picodingagent" {
            return .pi
        }
        return HookInstaller.Agent(rawValue: normalized)
    }
}

// MARK: - Helpers

extension FileHandle: @retroactive TextOutputStream {
    public func write(_ string: String) {
        if let data = string.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}
