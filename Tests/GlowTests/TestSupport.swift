import Foundation
import AppKit

/// Several suites mutate the process-global `GLOW_STATE_DIR` env var.
/// `.serialized` only orders tests *within* one suite, so suites that touch
/// the env must additionally hold this shared lock for their whole test
/// lifetime (init → deinit) to keep state-dir swaps exclusive.
enum StateDirEnvLock {
    static let lock = NSLock()
}

/// Flattens a view tree (layout tests locate controls inside panes).
extension NSView {
    func findAllSubviews() -> [NSView] {
        subviews + subviews.flatMap { $0.findAllSubviews() }
    }
}
