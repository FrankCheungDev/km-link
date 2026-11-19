import Foundation

/// Temporarily disables macOS pointer acceleration while this Mac drives the
/// other machine.
///
/// The original daemon writes `com.apple.mouse.scaling = -1` on
/// `SwitchToRemote` and restores the saved value on `SwitchFromRemote`
/// (`MouseInterface`, via `/usr/bin/defaults -g`). The previous value is stored
/// in our preferences so a crash cannot leave the user's acceleration disabled:
/// `restoreIfNeeded()` runs at every launch.
enum MouseScaling {
    private static let savedKey = "SavedMouseScaling"
    private static let defaultsPath = "/usr/bin/defaults"
    private static let key = "com.apple.mouse.scaling"

    private static func run(_ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: defaultsPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `true` while the acceleration override is active.
    static var isOverridden: Bool {
        UserDefaults.standard.object(forKey: savedKey) != nil
    }

    static func disable() {
        guard UserDefaults.standard.object(forKey: savedKey) == nil else { return }
        let current = run(["read", "-g", key]) ?? ""
        if let value = Double(current), value > 0 {
            UserDefaults.standard.set(value, forKey: savedKey)
        } else if let value = Double(current), value <= 0 {
            // Already disabled (by us in an earlier run, or by the original
            // app). Remember the macOS default so restore() can put it back.
            UserDefaults.standard.set(1.0, forKey: savedKey)
        } else {
            UserDefaults.standard.set(1.0, forKey: savedKey)
        }
        _ = run(["write", "-g", key, "-float", "-1"])
    }

    static func restore() {
        // `object(forKey:) as? Double` silently failed for a value stored as an
        // integer, leaving the saved entry behind and the system-wide mouse
        // acceleration stuck at -1 (hard to notice but very unpleasant).
        guard UserDefaults.standard.object(forKey: savedKey) != nil else { return }
        var value = UserDefaults.standard.double(forKey: savedKey)
        if value <= 0 { value = 1.0 }
        UserDefaults.standard.removeObject(forKey: savedKey)
        _ = run(["write", "-g", key, "-float", String(format: "%.6f", value)])
    }

    /// Repairs the setting if a previous run stopped while controlling.
    static func restoreIfNeeded() {
        if UserDefaults.standard.object(forKey: savedKey) != nil {
            restore()
            return
        }
        // Safety net: an unclean shutdown may leave `com.apple.mouse.scaling`
        // at -1 with no saved value (we are the only writer of that value).
        if (run(["read", "-g", key])?.trimmingCharacters(in: .whitespacesAndNewlines)) == "-1" {
            _ = run(["write", "-g", key, "-float", "1.000000"])
        }
    }
}
