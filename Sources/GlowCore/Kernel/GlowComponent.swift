import AppKit

/// Base protocol for all Glow components. The host (`AppDelegate`) assembles
/// components and drives their lifecycle; components never call each other
/// directly — they interact through on-disk contracts and host-injected hooks.
protocol GlowComponent: AnyObject {
    /// Unique component id (used for logs and menu wiring).
    var id: String { get }
    /// Called once after assembly; start polling/listening here.
    func start()
    /// Called before teardown; release resources here.
    func stop()
}

/// A component that produces provider usage snapshots. Producers must not
/// touch UI and must not write state files themselves — they fetch data and
/// report it back; the owning component persists it via `UsageStore`.
protocol UsageProducer: AnyObject {
    /// Stable provider key, also the `usage.json` dictionary key (e.g. `glm`).
    var providerKey: String { get }
    /// Human-readable provider name for menus and panels.
    var displayName: String { get }
    /// Fetch current usage items. Throw on network/credential/shape failure;
    /// the caller records the error message in `usage.json`.
    func fetch() async throws -> [UsageItem]
}

/// A component that contributes items to the menu bar's context menu.
protocol MenuContributor: AnyObject {
    /// Items appended to the menu; the host inserts separators around them.
    func menuItems() -> [NSMenuItem]
}
