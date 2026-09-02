import Foundation

/// Manages a macOS launchd plist for auto-starting the app on login.
final class LaunchdManager {
    static let plistLabel = "com.qqlzfmn.glow.app"

    private static var plistPath: String {
        let home = NSHomeDirectory()
        return (home as NSString).appendingPathComponent(
            "Library/LaunchAgents/\(plistLabel).plist"
        )
    }

    static func install() throws {
        let execPath = Bundle.main.executablePath ?? ""

        let logPath = StatePaths.logFile

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
          "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(plistLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(execPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <false/>
            <key>StandardOutPath</key>
            <string>\(logPath)</string>
            <key>StandardErrorPath</key>
            <string>\(logPath)</string>
        </dict>
        </plist>
        """

        let dir = (plistPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        try plist.write(toFile: plistPath, atomically: true, encoding: .utf8)

        // Load the plist via launchctl.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = ["load", "-w", plistPath]
        try proc.run()
        proc.waitUntilExit()
    }

    static func uninstall() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = ["unload", plistPath]
        try? proc.run()
        proc.waitUntilExit()

        try? FileManager.default.removeItem(atPath: plistPath)
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }
}
