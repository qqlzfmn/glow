import Foundation
import AppKit

/// Host component for provider usage polling: discovers producers, fetches
/// their snapshots on a fixed interval, persists the aggregate to
/// usage.json, and contributes the Usage section to the menu bar menu.
final class UsageMonitor: GlowComponent, MenuContributor {
    let id = "usage-monitor"

    /// Explicit producer set for tests; nil means "discover every cycle".
    private let injectedProducers: [any UsageProducer]?
    /// Live producer set, refreshed from discovery on every poll.
    private var producers: [any UsageProducer] = []
    private let pollInterval: TimeInterval
    private var pollTask: Task<Void, Never>?

    /// Called on the main queue after usage.json has been (re)written.
    var onUsageUpdated: (() -> Void)?

    /// Default poll cadence. Quota windows move slowly; 300s is plenty and
    /// keeps well under provider rate limits.
    static var defaultPollInterval: TimeInterval {
        if let raw = ProcessInfo.processInfo.environment["GLOW_USAGE_POLL_SECONDS"],
           let value = TimeInterval(raw), value >= 10 {
            return value
        }
        return 300
    }

    /// - Parameters:
    ///   - producers: explicit producer set (tests); defaults to discovery.
    ///   - pollInterval: override for tests.
    init(producers: [any UsageProducer]? = nil, pollInterval: TimeInterval? = nil) {
        injectedProducers = producers
        self.producers = producers ?? Self.discover()
        self.pollInterval = pollInterval ?? Self.defaultPollInterval
    }

    /// Resolve the producer set: credential-backed providers from all
    /// discovery sources plus the always-available local session stats.
    /// (reads agent logs directly — no credentials needed).
    static func discover() -> [any UsageProducer] {
        var list = UsageConfig.discoverProviders().compactMap { UsageProducerFactory.make($0) }
        list.append(LocalSessionStatsProvider())
        return list
    }

    func start() {
        guard pollTask == nil else { return }
        guard !producers.isEmpty else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                // Re-discover every cycle so usage-config edits and agent
                // credential changes apply live, without an app restart.
                if injectedProducers == nil {
                    producers = Self.discover()
                }
                await pollOnce()
                let interval = pollInterval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Fetch every producer serially and persist one merged snapshot.
    /// Producer failures are recorded per provider (status=error) — never
    /// silent; stale items are kept so menus degrade gracefully.
    func pollOnce() async {
        var file = UsageStore.readUsage()
        var providers = file.providers
        for producer in producers {
            do {
                let items = try await producer.fetch()
                providers[producer.providerKey] = ProviderUsage(
                    displayName: producer.displayName,
                    updatedAt: Date().timeIntervalSince1970,
                    status: "ok",
                    error: nil,
                    items: items
                )
            } catch {
                let previous = providers[producer.providerKey]
                providers[producer.providerKey] = ProviderUsage(
                    displayName: producer.displayName,
                    updatedAt: Date().timeIntervalSince1970,
                    status: "error",
                    error: Self.describe(error),
                    items: previous?.items ?? []
                )
            }
        }
        file.providers = providers
        file.order = producers.map { $0.providerKey }
        do {
            try UsageStore.writeUsage(file)
        } catch {
            fputs("glow: cannot write usage.json: \(error)\n", stderr)
        }
        await MainActor.run { onUsageUpdated?() }
    }

    // MARK: - MenuContributor

    func menuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let usage = UsageStore.readUsage()
        for key in usage.order ?? usage.providers.keys.sorted() {
            guard let provider = usage.providers[key] else { continue }
            if provider.status == "error", let error = provider.error {
                items.append(Self.disabledItem("\(provider.displayName) — \(error)"))
                continue
            }
            // Section header, then one row per item (5h / 1w / 1m / balance).
            items.append(Self.disabledItem(provider.displayName))
            for item in provider.items {
                let row = Self.disabledItem(UsageBadge.itemText(item))
                row.indentationLevel = 1
                items.append(row)
            }
        }
        if !items.isEmpty {
            items.append(NSMenuItem.separator())
        }
        items.append(Self.actionItem("Refresh Usage", action: #selector(refreshNow), target: self))
        items.append(Self.actionItem("Configure Providers…", action: #selector(openConfiguration), target: self))
        return items
    }

    // MARK: - Actions

    @objc private func refreshNow() {
        Task { await pollOnce() }
    }

    /// Open (creating if needed) the explicit provider config file in the
    /// user's default editor. Changes apply on the next poll cycle.
    @objc private func openConfiguration() {
        NSWorkspace.shared.open(URL(fileURLWithPath: UsageConfigStore.ensureConfigFile()))
    }

    // MARK: - Helpers

    private static func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private static func actionItem(_ title: String, action: Selector, target: AnyObject?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        return item
    }

    static func describe(_ error: Error) -> String {
        if let httpError = error as? UsageHTTPError {
            switch httpError {
            case .badURL(let url):
                return "bad URL: \(url)"
            case .httpStatus(let status, let body):
                return "HTTP \(status): \(body)"
            }
        }
        return error.localizedDescription
    }
}

/// Builds concrete producers from resolved credentials. Unknown types are
/// traced (never silently dropped).
enum UsageProducerFactory {
    static func make(_ config: UsageProviderConfig) -> (any UsageProducer)? {
        switch config.providerKey {
        case "glm": return GLMUsageProvider(config: config)
        case "zhipu-team": return ZhipuTeamUsageProvider(config: config)
        case "volcengine": return VolcengineUsageProvider(config: config)
        case "kimi": return KimiUsageProvider(config: config)
        case "minimax": return MiniMaxUsageProvider(config: config)
        case "zenmux": return ZenMuxUsageProvider(config: config)
        case "opencode-go": return OpenCodeGoUsageProvider(config: config)
        case "deepseek": return DeepSeekUsageProvider(config: config)
        case "openrouter": return OpenRouterUsageProvider(config: config)
        case "siliconflow": return SiliconFlowUsageProvider(config: config)
        case "stepfun": return StepFunUsageProvider(config: config)
        case "anthropic": return AnthropicUsageProvider(config: config)
        case "openai": return OpenAIUsageProvider(config: config)
        case "new-api": return NewApiUsageProvider(config: config)
        default:
            fputs("glow: unknown usage provider type \(config.providerKey)\n", stderr)
            return nil
        }
    }
}
