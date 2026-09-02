import AppKit
import GlowCore

if let code = CLIDispatch.run(CommandLine.arguments) {
    exit(code)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
