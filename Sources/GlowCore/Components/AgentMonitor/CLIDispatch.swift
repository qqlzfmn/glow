import Foundation

/// CLI dispatch — the same binary serves both as a macOS menu bar app and as
/// the hook CLI. Executable entry (thin main.swift) calls `CLIDispatch.run`
/// first; a nil result means "no subcommand, launch the GUI".
public enum CLIDispatch {

    /// 执行 CLI 子命令。返回 exit code；返回 nil 表示无子命令、应启动 GUI。
    public static func run(_ args: [String]) -> Int32? {
        guard args.count >= 2 else { return nil }
        let subcommand = args[1]

        switch subcommand {
        case "codex-hook":
            // Drop the subcommand from argv so event parsers see the real arguments.
            var hookArgs = args
            hookArgs.remove(at: 1) // remove "codex-hook"
            return CodexHookAdapter.run(argv: hookArgs)

        case "claude-code-hook":
            var hookArgs = args
            hookArgs.remove(at: 1) // remove "claude-code-hook"
            return ClaudeCodeHookAdapter.run(argv: hookArgs)

        case "status":
            let snapshot = SessionStore.readSessionSnapshot()
            let output = SessionSnapshot(
                aggregate: snapshot["aggregate"] as? String ?? "idle",
                sessions: snapshot["sessions"] as? [String: SessionEntry] ?? [:]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            let data: Data
            do {
                data = try encoder.encode(output)
            } catch {
                fputs("glow: cannot encode status output: \(error)\n", stderr)
                return 1
            }
            if let json = String(data: data, encoding: .utf8) {
                print(json)
            }
            return 0

        case "usage-config":
            return UsageConfigCLI.run(Array(args.dropFirst()))

        case "install-hooks":
            return InstallHooksCLI.run(args)

        case "uninstall-hooks":
            return InstallHooksCLI.run(args, mode: .uninstall)

        case "clear-state":
            do {
                try SessionStore.clearSessionState()
            } catch {
                fputs("glow: \(error)\n", stderr)
                return 1
            }
            print("Session state cleared.")
            return 0

        default:
            return nil
        }
    }
}

