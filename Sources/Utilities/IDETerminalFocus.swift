import AppKit
import Foundation

/// Shared utility for focusing the terminal running a Claude Code session.
/// Attempts IDE extension URI first (exact tab), falls back to AppleScript app activation.
enum IDETerminalFocus {

    /// Focus the terminal for a given session.
    static func focusSession(_ session: ClaudeSession) {
        focus(terminalPid: session.terminalPid, shellPid: session.shellPid)
    }

    /// Focus a terminal by PID.
    /// 1. If shellPid + IDE extension available → open URI to focus exact terminal tab
    /// 2. If terminalPid available → activate the IDE/terminal app (brings to foreground)
    /// 3. Fallback → activate first running terminal-like app
    static func focus(terminalPid: Int? = nil, shellPid: Int? = nil) {
        // Resolve bundle ID from terminalPid
        var bundleId: String?
        if let pid = terminalPid,
           let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
            bundleId = app.bundleIdentifier
        }

        // Try IDE extension URI for exact terminal tab focus
        if let shellPid,
           let bundleId,
           let scheme = ExtensionInstaller.uriScheme(forBundleId: bundleId),
           UserDefaults.standard.bool(forKey: "ideExtensionEnabled") {
            let urlString = "\(scheme)://masko.masko-terminal-focus/focus?pid=\(shellPid)"
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
                return
            }
        }

        // Fallback: bring IDE/terminal to foreground
        if let bundleId {
            activateApp(bundleId: bundleId)
            return
        }

        // Last resort: find any running terminal app
        let bundleIDs = [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "com.github.wez.wezterm",
            "net.kovidgoyal.kitty",
            "com.todesktop.230313mzl4w4u92",
            "com.microsoft.VSCode",
            "com.microsoft.VSCodeInsiders",
            "com.exafunction.windsurf",
            "dev.zed.Zed",
            "com.mitchellh.ghostty",
            "org.alacritty",
            "dev.warp.Warp-Stable",
        ]
        for id in bundleIDs {
            if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == id }) {
                activateApp(bundleId: id)
                return
            }
        }
    }

    /// AppleScript `tell application id` — most reliable cross-Space activation on macOS 14+.
    private static func activateApp(bundleId: String) {
        let src = "tell application id \"\(bundleId)\" to activate"
        if let script = NSAppleScript(source: src) {
            var error: NSDictionary?
            script.executeAndReturnError(&error)
        }
    }
}
