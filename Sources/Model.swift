import Foundation

// MARK: - Internal message types

enum MessageType: String, Codable {
    case clipboard
    case km
    case switchRemote, switchLocal
}

struct KMEvent: Codable {
    var kind: String          // keyDown, keyUp, flags, mouseDown, mouseUp, mouseMoved, mouseDragged, scroll, otherDown, otherUp
    var keyCode: UInt16?
    var flags: UInt64?
    var down: Bool?
    var dx: Double?
    var dy: Double?
    var nx: Double? = nil
    var ny: Double? = nil
    var button: Int?
    var scrollX: Int32?
    var scrollY: Int32?
}

struct WireMessage: Codable {
    var type: String
    var deviceID: String?
    var deviceName: String?
    var text: String?
    var rtf: Data?
    var html: Data?
    var png: Data?
    var tiff: Data?
    var filePaths: [String]? = nil
    var clipboardChange: Int?
    var km: KMEvent?
}

// MARK: - Peer

struct Peer: Identifiable, Hashable {
    let id: String
    let name: String
    var endpoint: String?
    var isConnected: Bool = false
}

// MARK: - Settings

final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    var deviceID: String {
        if let value = defaults.string(forKey: "deviceID") { return value }
        let value = UUID().uuidString
        defaults.set(value, forKey: "deviceID")
        return value
    }

    var displayName: String {
        get { defaults.string(forKey: "displayName") ?? Host.current().localizedName ?? "Mac" }
        set { defaults.set(newValue, forKey: "displayName") }
    }

    var kmEnabled: Bool {
        get { defaults.object(forKey: "kmEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "kmEnabled") }
    }

    var clipboardEnabled: Bool {
        get { defaults.object(forKey: "clipboardEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "clipboardEnabled") }
    }

    /// Where the other computer sits relative to this one: left, right, up, down.
    var peerPosition: String {
        get { defaults.string(forKey: "peerPosition") ?? "left" }
        set { defaults.set(newValue, forKey: "peerPosition") }
    }

    var edgeSwitchingEnabled: Bool {
        get { defaults.object(forKey: "edgeSwitchingEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "edgeSwitchingEnabled") }
    }

    var middleButtonSwitch: Bool {
        get { defaults.object(forKey: "middleButtonSwitch") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "middleButtonSwitch") }
    }

    var hotCornerSwitch: Bool {
        get { defaults.object(forKey: "hotCornerSwitch") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "hotCornerSwitch") }
    }

    var edgeTolerance: Double {
        get { defaults.object(forKey: "edgeTolerance") as? Double ?? 1.0 }
        set { defaults.set(newValue, forKey: "edgeTolerance") }
    }

    /// Pointer speed multiplier applied to the KM pointer.
    ///
    /// 1.0 keeps macOS defaults (no HID override at all). Values below 1.0 make
    /// the bridge's virtual mouse slower, which is the knob to use when the
    /// pointer feels far too fast after the other PC takes control. Lower
    /// `HIDPointerAcceleration`/`HIDMouseAcceleration` values would make this
    /// bridge faster, so the C shim divides the system defaults by this value.
    var mouseSensitivity: Double {
        get { defaults.object(forKey: "mouseSensitivity") as? Double ?? 1.0 }
        set { defaults.set(newValue, forKey: "mouseSensitivity") }
    }

    var clipboardSendEnabled: Bool {
        get { defaults.object(forKey: "clipboardSendEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "clipboardSendEnabled") }
    }

    var clipboardReceiveEnabled: Bool {
        get { defaults.object(forKey: "clipboardReceiveEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "clipboardReceiveEnabled") }
    }

    var blockFileSending: Bool {
        get { defaults.object(forKey: "blockFileSending") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "blockFileSending") }
    }

    /// Host mode: forward this Mac's input to the peer when the pointer leaves
    /// the screen. Off keeps this Mac passive and lets the peer drive.
    var forwardLocalInput: Bool {
        get { defaults.object(forKey: "forwardLocalInput") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "forwardLocalInput") }
    }

    /// Keep retrying the bridge in the background so a re-plug connects on its
    /// own, like the original app's device polling.
    var autoConnectUSB: Bool {
        get { defaults.object(forKey: "autoConnectUSB") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoConnectUSB") }
    }

    /// Start KMLink when the user logs in.
    var launchAtLogin: Bool {
        get { defaults.object(forKey: "launchAtLogin") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "launchAtLogin") }
    }

    var downloadsDirectory: URL {
        let base = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("KMLink", isDirectory: true)
    }
}
