import Foundation
import ServiceManagement

/// Registers KMLink as a login item so the bridge is picked up automatically
/// after a reboot — the original MacKMLink installs itself the same way, which
/// is why it "just connects" whenever the USB cable is attached.
///
/// `SMAppService` is the modern path, but macOS rejects apps that do not live in
/// `/Applications`, so a user LaunchAgent is used as the fallback. Both are
/// controlled by a single setting.
enum LaunchAtLogin {
    static let agentLabel = "com.local.kmlink.agent"

    static var agentPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    private static var bundlePath: String { Bundle.main.bundlePath }

    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            if SMAppService.mainApp.status == .enabled { return true }
        }
        return FileManager.default.fileExists(atPath: agentPlistURL.path)
    }

    /// Applies the requested state and returns a short description of the
    /// mechanism that ended up being used (written to the app log).
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            if enabled {
                if service.status == .enabled {
                    removeAgent()
                    return "SMAppService (already enabled)"
                }
                do {
                    try service.register()
                    removeAgent()
                    return "SMAppService"
                } catch {
                    // Typically "app is outside /Applications"; a LaunchAgent
                    // runs the bundle no matter where it lives.
                    if writeAgent() {
                        return "LaunchAgent at \(agentPlistURL.path)"
                    }
                    return "failed: \(error.localizedDescription)"
                }
            }
            try? service.unregister()
            removeAgent()
            return "disabled"
        }
        if enabled {
            return writeAgent() ? "LaunchAgent at \(agentPlistURL.path)" : "failed"
        }
        removeAgent()
        return "disabled"
    }

    // MARK: - LaunchAgent fallback

    private static func writeAgent() -> Bool {
        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": ["/usr/bin/open", "-g", "-a", bundlePath],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua"
        ]
        do {
            try FileManager.default.createDirectory(at: agentPlistURL.deletingLastPathComponent(),
                                                   withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                         format: .xml,
                                                         options: 0)
            try data.write(to: agentPlistURL, options: .atomic)
        } catch {
            return false
        }
        let uid = getuid()
        runLaunchctl(["bootout", "gui/\(uid)/\(agentLabel)"])
        runLaunchctl(["bootstrap", "gui/\(uid)", agentPlistURL.path])
        return true
    }

    private static func removeAgent() {
        guard FileManager.default.fileExists(atPath: agentPlistURL.path) else { return }
        runLaunchctl(["bootout", "gui/\(getuid())/\(agentLabel)"])
        try? FileManager.default.removeItem(at: agentPlistURL)
    }

    private static func runLaunchctl(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // ignored: the plist file itself is what matters on the next login
        }
    }
}
