import Foundation
import AppKit

/// Host component for provider usage polling: discovers producers, fetches
/// their snapshots on a fixed interval, persists the aggregate to
/// usage.json, and contributes the Usage section to the menu bar menu.
final class UsageMonitor: GlowComponent, MenuContributor {
    let id = "usage-monitor"

    private let producers: [any UsageProducer]
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
    ///   - producers: explicit producer set; defaults to discovery.
    ///   - pollInterval: override for tests.
    init(producers: [any UsageProducer]? = nil, pollInterval: TimeInterval? = nil) {
        if let producers {
            self.producers = producers
        } else {
            self.producers = UsageConfig.discoverProviders()
                .compactMap { UsageProducerFactory.make($0) }
        }
        self.pollInterval = pollInterval ?? Self.defaultPollInterval
    }

    func start() {
        guard pollTask == nil, !producers.isEmpty else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                let interval = self?.pollInterval ?? Self.defaultPollInterval
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
            let item = NSMenuItem(
                title: Self.menuTitle(for: provider),
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            items.append(item)
        }
        if !items.isEmpty {
            items.append(NSMenuItem.separator())
        }
        let refresh = NSMenuItem(
            title: "Refresh Usage",
            action: #selector(refreshNow),
            keyEquivalent: ""
        )
        refresh.target = self
        items.append(refresh)
        return items
    }

    @objc private func refreshNow() {
        Task { await pollOnce() }
    }

    // MARK: - Presentation helpers

    /// Menu line for one provider: "GLM Coding Plan — 5h window 42%" or the
    /// error text. Kept beside `UsageBadge` so both stay in sync.
    static func menuTitle(for provider: ProviderUsage) -> String {
        if provider.status == "error", let error = provider.error {
            return "\(provider.displayName) — \(error)"
        }
        guard let item = provider.items.first else {
            return "\(provider.displayName) — no data"
        }
        return "\(provider.displayName) — \(UsageBadge.itemText(item))"
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
        default:
            fputs("glow: unknown usage provider type \(config.providerKey)\n", stderr)
            return nil
        }
    }
}
