// USBLink.swift
// Pure-USB link: native arm64 SCSITask transport + OTi session + app-level events.
// No Bonjour, no TLS, no DriverKit, no Rosetta.

import AppKit
import CoreGraphics
import Foundation

public final class USBLink {
    public enum State: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    public private(set) var state: State = .idle
    public private(set) var peerOnline = true
    public var onState: ((State) -> Void)?
    public var onPeerOnlineChanged: ((Bool) -> Void)?
    public var onClipboard: ((String) -> Void)?
    public var onKMSwitch: ((String) -> Void)?
    public var onKMSwitchToLocal: ((KMSwitchMoveOutInfo) -> Void)?
    public var onKMRemoteEnded: ((KMSwitchMoveInInfo?) -> Void)?
    public var onRemoteScreenInfo: ((Int, Int) -> Void)?
    public var onFileSent: ((String, UInt64) -> Void)?
    public var onFileError: ((String) -> Void)?
    public var onDragHandoffCompleted: (() -> Void)?
    public var onLog: ((String) -> Void)?

    public var stagedFiles: [URL] = []
    private var dragFiles: [URL] = []
    private var allowedDownloadPaths: Set<String> = []
    /// Called on the main queue once a file arriving from the peer is complete.
    public var onFileReceived: ((URL) -> Void)?
    public var onFileReceiveFailed: ((String) -> Void)?
    /// Files arriving from the peer are written here (set from the UI).
    public var downloadsDirectory: URL = FileManager.default
        .urls(for: .downloadsDirectory, in: .userDomainMask).first?
        .appendingPathComponent("KMLink", isDirectory: true)
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/KMLink")

    private struct IncomingFile {
        let handle: FileHandle
        let temporaryURL: URL
        let finalURL: URL
        let expectedSize: UInt64
        let totalChunks: UInt32
        var received: UInt64
        var receivedData: Bool
        var createdAt: Date?
        var modifiedAt: Date?
    }

    private var incomingFiles: [UInt32: IncomingFile] = [:]
    private var requestedNodes: [UInt32: OTIFileNode] = [:]
    private var failedFileIDs: Set<UInt32> = []
    /// The original daemon numbers the files it asks for with small sequential
    /// ids (0x65, 0x66, …) and echoes the same value as the session; the peer
    /// answers "No such process" for anything else.
    private var downloadSessionSeed: UInt32 = 0x64

    private let scsiTransport: SCSITaskTransport?
    private let hidTransport: OTIHIDTransport?
    private let session: OTISession
    private var sentLogin = false
    private var remoteIsMac = false
    private var hidMouseButtons: UInt8 = 0
    private var hidModifiers: UInt8 = 0
    private var hidPressedKeys: [UInt8] = []
    /// Remote screen size used to map the local cursor onto 11-bit absolute HID
    /// coordinates when the bridge asks for absolute reports (functionType
    /// without the 0x88 relative flag). Declared by `Cmd_Post_Remote_Screen_Info`.
    /// Last pointer position the peer reported when it handed control to us, in
    /// the peer's own pixels. Logged next to our hand-back so the coordinate
    /// mapping can be checked from one crossing.
    private(set) var peerLastMoveOutY = -1
    private(set) var peerLastMoveOutHeight = 0
    private(set) var remoteScreenWidth = 1920
    private(set) var remoteScreenHeight = 1080
    private var virtualCursorX = 0
    private var virtualCursorY = 0
    private let switchLock = NSLock()
    private var pendingSwitchCommand: (direction: Int, x: Int, y: Int, width: Int, height: Int)?
    private var switchGeneration: UInt64 = 0
    private var peerHandlesSwitchAck = false
    private var handshakeNextStep = 8
    private var handshakeRetryRemaining = 0
    private var nextHandshakeRetryAt = Date.distantPast
    private var sentPostLoginAnnouncements = false
    private var loggedOutByPeer = false
    private var consecutiveOfflinePolls = 0
    /// "left" / "right" / "up" / "down": where the other machine sits relative to this screen.
    /// Announced to the peer in `Cmd_Post_Remote_KM_Setting_Info`.
    var localPeerPosition = "left"
    private let localHostName: String

    // Carbon virtual keyCode -> USB HID Usage ID (from KMKeyMouse __ZL10USBScanKey).
    private static let usbScanKey: [UInt8] = [
        4, 22, 7, 9, 11, 10, 29, 27, 6, 25, 100, 5, 20, 26, 8, 21,
        28, 23, 30, 31, 32, 33, 35, 34, 46, 38, 36, 45, 37, 39, 48, 18,
        24, 47, 12, 19, 40, 15, 13, 52, 14, 51, 49, 54, 56, 17, 16, 55,
        43, 44, 53, 42, 57, 41, 0, 0, 225, 57, 226, 224, 229, 230, 228, 0,
        102, 99, 0, 85, 0, 87, 0, 83, 0, 0, 0, 84, 88, 0, 86, 109,
        110, 0, 98, 89, 90, 91, 92, 93, 94, 95, 111, 96, 97, 137, 135, 99,
        62, 63, 64, 60, 65, 66, 145, 68, 144, 104, 107, 105, 0, 67, 0, 69,
        0, 106, 117, 74, 75, 76, 61, 77, 59, 78, 58, 80, 79, 81, 82, 0
    ]

    public convenience init() {
        self.init(transport: SCSITaskTransport())
    }

    public init(transport: OTITransport) {
        self.scsiTransport = transport as? SCSITaskTransport
        self.hidTransport = transport as? OTIHIDTransport
        self.session = OTISession(transport: transport)
        let rawHost = ProcessInfo.processInfo.hostName
        let trimmed = rawHost.hasSuffix(".local") ? String(rawHost.dropLast(6)) : rawHost
        self.localHostName = trimmed.isEmpty ? "Mac" : trimmed
    }

    public func start() throws {
        setState(.connecting)
        sentLogin = false
        remoteIsMac = false
        peerOnline = true
        loggedOutByPeer = false
        consecutiveOfflinePolls = 0
        peerHandlesSwitchAck = false
        handshakeNextStep = 8
        handshakeRetryRemaining = 0
        nextHandshakeRetryAt = .distantPast
        sentPostLoginAnnouncements = false
        clearPendingSwitch()
        hidMouseButtons = 0
        hidModifiers = 0
        hidPressedKeys.removeAll()
        do {
            if let scsiTransport {
                try scsiTransport.open()
                _ = try scsiTransport.pollStatus()
                let rel = scsiTransport.hidMouseUsesRelativeReports
                onLog?("USB bridge functionType=0x\(String(format: "%02x", scsiTransport.functionType)) hidMouse=\(rel ? "relative" : "absolute") multimedia=\(scsiTransport.supportsMultimediaKeyboard)")
            }
            setState(.connected)
            // The bridge may refuse writes while it reports a transient state
            // (observed: poll state 0x01 after a KM hand-off). That is not a
            // reason to tear the link down — polls still work, so announce
            // best-effort and keep the session.
            do {
                try session.sendLoginCommand(name: localHostName)
                sentLogin = true
                onLog?("USB TX: LoginCommand name=\(localHostName) flags=0x10")
            } catch {
                onLog?("USB login announce deferred (\(error)); link stays up")
            }
            do {
                try pump()
            } catch {
                onLog?("USB pump after login failed (\(error)); link stays up")
            }
        } catch {
            // Only open/handshake failures are fatal.
            scsiTransport?.close()
            setState(.failed(String(describing: error)))
            throw error
        }
    }

    public func stop() {
        clearPendingSwitch()
        peerHandlesSwitchAck = false
        handshakeNextStep = 8
        handshakeRetryRemaining = 0
        sentPostLoginAnnouncements = false
        loggedOutByPeer = false
        consecutiveOfflinePolls = 0
        peerOnline = false
        sentLogin = false
        remoteIsMac = false
        hidMouseButtons = 0
        hidModifiers = 0
        hidPressedKeys.removeAll()
        scsiTransport?.close()
        setState(.idle)
    }

    public func sendClipboard(_ text: String) throws {
        guard state == .connected else { return }
        try session.sendClipboard(text)
    }

    public func sendSwitchAcknowledge() throws {
        guard state == .connected else { return }
        try session.sendSwitchAcknowledge()
    }

    public func sendForceRemoteSwitchLocal(x: Int, y: Int, direction: Int) throws {
        guard state == .connected else { return }
        clearPendingSwitch()
        // `Cmd_Force_Remote_To_Switch_Local` carries only `Param_Move_In_X/Y`
        // (no width/height), and the peer takes them as pixels on its own
        // screen. Sending our local coordinates therefore landed the pointer
        // too high on a 2160 px tall screen — the return trip had to be scaled
        // into the peer's pixel space, exactly like the outbound switch point.
        let union = KMEngine.cgScreenUnion()
        let srcW = max(1, Int(union.width.rounded()))
        let srcH = max(1, Int(union.height.rounded()))
        let dstW = max(1, remoteScreenWidth)
        let dstH = max(1, remoteScreenHeight)
        let px = union.isNull ? x : Int((Double(x) * Double(dstW) / Double(srcW)).rounded())
        let py = union.isNull ? y : Int((Double(y) * Double(dstH) / Double(srcH)).rounded())
        // Seed the mirrored peer cursor at the entry edge we just handed back
        // to so a subsequent master session does not inherit a stale position.
        peerCursorX = direction == 1 ? dstW : (direction == 2 ? 0 : max(0, min(dstW, px)))
        peerCursorY = max(0, min(dstH, py))
        virtualCursorX = peerCursorX
        virtualCursorY = peerCursorY
        try session.sendForceRemoteSwitchLocal(x: px, y: py, direction: direction)
        onLog?("USB TX: Cmd_Force_Remote_To_Switch_Local (x=\(px), y=\(py), dir=\(direction) — local \(x),\(y) of \(srcW)x\(srcH); peer last reported y=\(peerLastMoveOutY) of \(peerLastMoveOutHeight))")
    }

    /// Hand control back to the peer using the coordinates it already has: the
    /// peer's pointer sits on its exit edge at `peerCursorY`, and rescaling that
    /// value would move it (that was the height mismatch).
    @discardableResult
    public func sendForceRemoteSwitchLocalPeerSpace(direction: Int) throws -> Int {
        guard state == .connected else { return peerCursorY }
        clearPendingSwitch()
        let x = direction == 1 ? remoteScreenWidth : 0
        peerCursorX = x
        try session.sendForceRemoteSwitchLocal(x: x, y: peerCursorY, direction: direction)
        onLog?("USB TX: Cmd_Force_Remote_To_Switch_Local (peer space x=\(x), y=\(peerCursorY), dir=\(direction))")
        return peerCursorY
    }

    public func sendSwitchToRemote(direction: Int, x: Int, y: Int, width: Int, height: Int,
                                   initialMouseButtons: UInt8 = 0) throws {
        guard state == .connected else {
            throw SCSITaskTransport.TransportError.notConnected
        }
        guard peerOnline else {
            throw SCSITaskTransport.TransportError.writeFailed(-3, 0x01, [])
        }
        clearPendingSwitch()
        hidMouseButtons = 0
        hidModifiers = 0
        hidPressedKeys.removeAll()
        virtualCursorX = x
        virtualCursorY = y
        peerCursorX = x
        // The Windows GO! Bridge places its pointer at the x/y we send *in its
        // own pixels* — it does not rescale by the w/h fields. Sending our local
        // coordinates (982 px tall) into a 2160 px tall screen made every round
        // trip land higher, because the return trip is mapped proportionally
        // (982/2160) while the outbound one was not.
        //
        // Express the exit point in the peer's pixel space and declare the
        // peer's size, so the payload is correct whether the peer rescales by
        // w/h or takes x/y literally.
        let srcW = max(1, width), srcH = max(1, height)
        let dstW = max(1, remoteScreenWidth), dstH = max(1, remoteScreenHeight)
        let px = Int((Double(x) * Double(dstW) / Double(srcW)).rounded())
        let py = Int((Double(y) * Double(dstH) / Double(srcH)).rounded())
        do {
            try session.sendSwitchToRemote(direction: direction, x: px, y: py, width: dstW, height: dstH)
            onLog?("USB TX: Cmd_Notify_KM_Switch_To_Remote (dir=\(direction), x=\(px), y=\(py), w=\(dstW), h=\(dstH) — local \(x),\(y) of \(srcW)x\(srcH))")
            // The peer is supposed to warp its pointer to the entry edge itself,
            // but the Windows GO! Bridge never answers the switch command, so
            // nudge the pointer there with relative reports unless it has
            // acknowledged a switch in this session.
            if !peerHandlesSwitchAck {
                slamPointerToEntryEdge(direction: direction)
            }
            if initialMouseButtons != 0 {
                hidMouseButtons = initialMouseButtons
                try? sendHIDMousePacket(buttons: hidMouseButtons, dx: 0, dy: 0, wheel: 0)
            }
            // Exiting our left edge (1) enters the peer at its *right* edge and
            // vice versa; the slam above parked the peer pointer exactly there.
            peerCursorX = direction == 1 ? remoteScreenWidth : 0
            peerCursorY = py
        } catch {
            if SCSITaskTransport.isPeerOfflineError(error) {
                if case SCSITaskTransport.TransportError.writeFailed(-3, _, _) = error {
                    setPeerOnline(false)
                }
                throw error
            }
            // A rejected write is common on this bridge; keep the command alive
            // in the resend queue instead of dropping the switch attempt.
            onLog?("USB TX: Cmd_Notify_KM_Switch_To_Remote rejected (\(error)); queued for resend")
        }
        scheduleSwitchResend(direction: direction, x: px, y: py, width: dstW, height: dstH)
        if remoteIsMac {
            try sendHIDMousePacket(buttons: hidMouseButtons, dx: 0, dy: 1, wheel: 0)
        }
    }

    /// The bridge/peer can swallow a single switch command; the original daemon
    /// re-sends `Cmd_Notify_KM_Switch_To_Remote` when the peer has not answered.
    /// Resend once shortly after the first frame unless the ACK already arrived
    /// or control already returned to the peer.
    private func scheduleSwitchResend(direction: Int, x: Int, y: Int, width: Int, height: Int) {
        switchLock.lock()
        switchGeneration &+= 1
        let gen = switchGeneration
        pendingSwitchCommand = (direction, x, y, width, height)
        switchLock.unlock()

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            for attempt in 1...4 {
                self.switchLock.lock()
                let stillValid = (self.switchGeneration == gen)
                let command = stillValid ? self.pendingSwitchCommand : nil
                self.switchLock.unlock()
                guard let command, self.state == .connected else { return }
                do {
                    try self.session.sendSwitchToRemote(direction: command.direction, x: command.x,
                                                        y: command.y, width: command.width,
                                                        height: command.height)
                    self.onLog?("USB TX: Cmd_Notify_KM_Switch_To_Remote (resend \(attempt) accepted)")
                    return
                } catch {
                    self.onLog?("USB switch-to-remote resend \(attempt) rejected: \(error)")
                    if attempt < 4 {
                        usleep(250_000)
                        self.switchLock.lock()
                        let cancelled = (self.switchGeneration != gen || self.pendingSwitchCommand == nil)
                        self.switchLock.unlock()
                        if cancelled { return }
                    }
                }
            }
        }
    }

    /// Called when the peer acknowledges a switch, control returns, or the link resets.
    @discardableResult
    func clearPendingSwitch() -> Bool {
        switchLock.lock()
        let wasPending = pendingSwitchCommand != nil
        pendingSwitchCommand = nil
        switchGeneration &+= 1
        switchLock.unlock()
        return wasPending
    }

    /// Set to false by tests that count injected reports.
    var pointerPrePositionEnabled = true

    /// Drives the peer pointer to the edge it should enter from.
    ///
    /// Relative HID cannot position the pointer, so push it hard against the
    /// entry edge with a burst of maximum-size reports (the peer clamps at its
    /// own screen border).
    func slamPointerToEntryEdge(direction: Int) {
        guard state == .connected, pointerPrePositionEnabled else { return }
        let step: Int8 = direction == 1 ? 127 : -127
        var sent = 0
        for _ in 0..<80 {
            do {
                try sendHIDMousePacket(buttons: hidMouseButtons, dx: step, dy: 0, wheel: 0)
                sent += 1
            } catch {
                onLog?("USB pointer pre-position stopped after \(sent) reports: \(error)")
                break
            }
        }
        onLog?("USB pointer pre-positioned to the peer's entry edge (\(sent) reports)")
    }

    private func peerDirectionCode() -> Int {
        switch localPeerPosition {
        case "left":  return 1
        case "right": return 2
        case "up":    return 3
        case "down":  return 4
        default:      return 1
        }
    }

    public func sendKMSettingAnnouncement() throws {
        guard state == .connected else { return }
        let peerDirection = peerDirectionCode()
        // Option 3 means bidirectional edge switching; never cycle to 1 or 2,
        // because option 2 disables peer -> Mac edge switching on Windows.
        try session.sendPostRemoteKMSetting(direction: peerDirection, option: 3)
        onLog?("USB TX: Cmd_Post_Remote_KM_Setting_Info (dir=\(peerDirection), option=3)")
    }

    private func runPendingHandshakeSteps() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask).first?.path ?? "\(home)/Desktop"
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "\(home)/Documents"
        let music = fm.urls(for: .musicDirectory, in: .userDomainMask).first?.path ?? "\(home)/Music"
        let pictures = fm.urls(for: .picturesDirectory, in: .userDomainMask).first?.path ?? "\(home)/Pictures"

        while handshakeNextStep < 8 {
            do {
                switch handshakeNextStep {
                case 0:
                    try session.sendLoginResponse(requestCommand: 0x01, osVersion: 0x28)
                    onLog?("USB TX: ResponseResult (0xA1 cmd=0x01 os=0x28)")
                case 1:
                    try session.sendLoginCommand(name: localHostName)
                    sentLogin = true
                    onLog?("USB TX: LoginCommand name=\(localHostName) flags=0x10")
                case 2:
                    try session.sendDomainFolders(desktop: desktop, documents: documents, music: music, pictures: pictures)
                    onLog?("USB TX: DomainFolders (0xAD)")
                case 3:
                    let rootName = fm.displayName(atPath: "/")
                    try session.sendDriveInfo(volumes: [(name: rootName, path: "/", type: 0x14)])
                    onLog?("USB TX: DriveInfo (0xA4 root=\(rootName))")
                case 4:
                    try session.sendLoginSubCommand()
                    onLog?("USB TX: ResponseResult (0xA1 cmd=0x04)")
                case 5:
                    let union = KMEngine.cgScreenUnion()
                    let screenBounds = union.isNull ? CGDisplayBounds(CGMainDisplayID()) : union
                    if screenBounds.width > 0, screenBounds.height > 0 {
                        try session.sendRemoteScreenInfo(
                            width: Int(screenBounds.width.rounded()),
                            height: Int(screenBounds.height.rounded()),
                            virtualX: Int(screenBounds.origin.x.rounded()),
                            virtualY: Int(screenBounds.origin.y.rounded()))
                        onLog?("USB TX: Cmd_Post_Remote_Screen_Info (\(Int(screenBounds.width))x\(Int(screenBounds.height)))")
                    }
                case 6:
                    try sendKMSettingAnnouncement()
                case 7:
                    try session.sendSwitchAcknowledge()
                    onLog?("USB TX: Cmd_Get_KM_Switch_Acknowlege (capability announce)")
                default:
                    break
                }
                handshakeNextStep += 1
            } catch {
                if handshakeRetryRemaining > 0 {
                    handshakeRetryRemaining -= 1
                }
                if handshakeRetryRemaining > 0 {
                    nextHandshakeRetryAt = Date().addingTimeInterval(0.35)
                    onLog?("USB handshake step \(handshakeNextStep) deferred (\(error)); will retry")
                } else {
                    onLog?("USB handshake step \(handshakeNextStep) failed: \(error)")
                    handshakeNextStep = 8
                }
                return
            }
        }
        handshakeRetryRemaining = 0
    }

    public func sendSwitchToLocal() throws {
        guard state == .connected else { return }
        clearPendingSwitch()
        try releaseAllHID()
        try session.sendSwitchToLocal()
        onLog?("USB TX: Cmd_Notify_KM_Switch_To_Local")
    }

    /// Peer pointer position in the peer's pixel space, mirrored from the
    /// deltas we forward. Seeded at the switch entry edge.
    private(set) var peerCursorX = 0
    private(set) var peerCursorY = 0
    var peerScreenWidth: Int { remoteScreenWidth }
    var peerScreenHeight: Int { remoteScreenHeight }

    /// True when the forwarded motion pushed the peer pointer out of the given
    /// edge by more than `margin` pixels — i.e. the user is trying to come back.
    func peerCursorExited(edge: Int, margin: Int) -> Bool {
        switch edge {
        case 1: return peerCursorX <= -margin
        case 2: return peerCursorX >= remoteScreenWidth + margin
        default: return false
        }
    }

    func resetPeerCursor(toX x: Int) {
        peerCursorX = x
    }

    func sendHID(event: KMEvent) throws {
        guard state == .connected else {
            throw SCSITaskTransport.TransportError.notConnected
        }
        guard peerOnline else {
            throw SCSITaskTransport.TransportError.writeFailed(-3, 0x01, [])
        }
        guard let hid = hidTransport else { return }
        do {
            try performHID(event: event, hid: hid)
        } catch {
            if case SCSITaskTransport.TransportError.writeFailed(-3, _, _) = error {
                setPeerOnline(false)
            }
            throw error
        }
    }

    private func performHID(event: KMEvent, hid: OTIHIDTransport) throws {
        switch event.kind {
        case "mouseMoved", "mouseDragged":
            let dx = Int(event.dx?.rounded() ?? 0)
            let dy = Int(event.dy?.rounded() ?? 0)
            if dx != 0 || dy != 0 {
                if hid.hidMouseUsesRelativeReports {
                    peerCursorX += dx
                    peerCursorY += dy
                    try sendHIDMouseDelta(dx: dx, dy: dy, wheel: 0)
                } else {
                    try sendHIDMouseAbsolute(dx: dx, dy: dy)
                }
            }
        case "mouseDown":
            hidMouseButtons |= mouseButtonMask(event.button ?? 0)
            try sendHIDMousePacket(buttons: hidMouseButtons, dx: 0, dy: 0, wheel: 0)
        case "mouseUp":
            hidMouseButtons &= ~mouseButtonMask(event.button ?? 0)
            try sendHIDMousePacket(buttons: hidMouseButtons, dx: 0, dy: 0, wheel: 0)
        case "scroll":
            let wheel = max(-127, min(127, Int(event.scrollY ?? 0)))
            if wheel != 0 {
                try sendHIDMousePacket(buttons: hidMouseButtons, dx: 0, dy: 0, wheel: Int8(wheel))
            }
        case "keyDown":
            if let flags = event.flags {
                hidModifiers = usbModifierMask(from: flags)
            }
            if let keyCode = event.keyCode {
                let usage = usbUsage(for: keyCode)
                if usage != 0 && !hidPressedKeys.contains(usage) && hidPressedKeys.count < 6 {
                    hidPressedKeys.append(usage)
                }
            }
            try sendHIDKeyboardPacket()
        case "keyUp":
            if let flags = event.flags {
                hidModifiers = usbModifierMask(from: flags)
            }
            if let keyCode = event.keyCode {
                let usage = usbUsage(for: keyCode)
                if usage != 0 {
                    hidPressedKeys.removeAll { $0 == usage }
                }
            }
            try sendHIDKeyboardPacket()
        case "flags":
            if let flags = event.flags {
                hidModifiers = usbModifierMask(from: flags)
            }
            try sendHIDKeyboardPacket()
        default:
            break
        }
    }

    public func releaseAllHID() throws {
        guard state == .connected, hidTransport != nil else {
            hidMouseButtons = 0
            hidModifiers = 0
            hidPressedKeys.removeAll()
            return
        }
        if hidMouseButtons != 0 {
            hidMouseButtons = 0
            try sendHIDMousePacket(buttons: 0, dx: 0, dy: 0, wheel: 0)
        }
        if hidModifiers != 0 || !hidPressedKeys.isEmpty {
            hidModifiers = 0
            hidPressedKeys.removeAll()
            try sendHIDKeyboardPacket()
        }
    }

    private func mouseButtonMask(_ button: Int) -> UInt8 {
        switch button {
        case 0: return 0x01
        case 1: return 0x02
        case 2: return 0x04
        default: return 0
        }
    }

    private func usbUsage(for keyCode: UInt16) -> UInt8 {
        let idx = Int(keyCode)
        guard idx >= 0 && idx < Self.usbScanKey.count else { return 0 }
        return Self.usbScanKey[idx]
    }

    private func usbModifierMask(from rawFlags: UInt64) -> UInt8 {
        let flags = CGEventFlags(rawValue: rawFlags)
        var mask: UInt8 = 0
        if flags.contains(.maskControl) { mask |= 0x01 }
        if flags.contains(.maskShift) { mask |= 0x02 }
        if flags.contains(.maskAlternate) { mask |= 0x04 }
        if flags.contains(.maskCommand) { mask |= 0x08 }
        return mask
    }

    /// Original `CKMEvent::SendMouseEvent` damping: deltas above 20 px are
    /// halved so a single fast flick cannot make the remote pointer overshoot,
    /// then clamped to the int8 range of the relative HID report.
    static func dampedRelativeDelta(_ value: Int) -> Int {
        var v = value
        if abs(v) > 20 { v /= 2 }
        return max(-127, min(127, v))
    }

    private func sendHIDMouseDelta(dx: Int, dy: Int, wheel: Int) throws {
        var rx = dx
        var ry = dy
        var rw = wheel
        repeat {
            let sx = Self.dampedRelativeDelta(rx)
            let sy = Self.dampedRelativeDelta(ry)
            let sw = max(-127, min(127, rw))
            try sendHIDMousePacket(
                buttons: hidMouseButtons,
                dx: Int8(sx),
                dy: Int8(sy),
                wheel: Int8(sw)
            )
            rx -= sx
            ry -= sy
            rw -= sw
        } while rx != 0 || ry != 0 || rw != 0
    }

    /// Absolute mode: map the accumulated virtual cursor onto the bridge's
    /// 11-bit (0...2047) absolute X/Y fields, exactly like
    /// `CKMEvent::SendMouseEvent` does for `functionType` without 0x88.
    private func sendHIDMouseAbsolute(dx: Int, dy: Int) throws {
        virtualCursorX = max(0, virtualCursorX + dx)
        virtualCursorY = max(0, virtualCursorY + dy)
        let width = max(1, remoteScreenWidth)
        let height = max(1, remoteScreenHeight)
        var hx = width > 0 ? (virtualCursorX << 11) / width : 0
        var hy = height > 0 ? (virtualCursorY << 11) / height : 0
        hx = max(0, min(0x7FF, hx))
        hy = max(0, min(0x7FF, hy))
        var pkt = [UInt8](repeating: 0, count: 12)
        pkt[0] = hidMouseButtons
        pkt[2] = UInt8(hx & 0xFF)
        pkt[3] = UInt8((hx >> 8) & 0xFF)
        pkt[4] = UInt8(hy & 0xFF)
        pkt[5] = UInt8((hy >> 8) & 0xFF)
        try hidTransport?.sendHID(kind: 0x33, data12: pkt)
    }

    /// Report layout matches the bridge's own HID mouse report descriptor
    /// (4 bytes, no report id): `[buttons(5 bits + 3 pad), dx, dy, wheel]`,
    /// X/Y/Wheel are int8 relative. Verified from the live IORegistry
    /// `ReportDescriptor` of VID 0x0EA0 / PID 0x2213.
    private func sendHIDMousePacket(buttons: UInt8, dx: Int8, dy: Int8, wheel: Int8) throws {
        guard let hid = hidTransport else { return }
        var pkt = [UInt8](repeating: 0, count: 12)
        pkt[0] = buttons
        pkt[1] = UInt8(bitPattern: dx)
        pkt[2] = UInt8(bitPattern: dy)
        pkt[3] = UInt8(bitPattern: wheel)
        try hid.sendHID(kind: 0x33, data12: pkt)
    }

    /// Bridge keyboard HID report descriptor is the 8-byte boot keyboard:
    /// `[modifiers, reserved, key1...key6]` (no report id).
    private func sendHIDKeyboardPacket() throws {
        guard let hid = hidTransport else { return }
        var pkt = [UInt8](repeating: 0, count: 12)
        pkt[0] = hidModifiers
        pkt[1] = 0x00
        for (i, usage) in hidPressedKeys.prefix(6).enumerated() {
            pkt[2 + i] = usage
        }
        try hid.sendHID(kind: 0x34, data12: pkt)
    }

    public func stageFiles(_ urls: [URL]) {
        let filtered = urls.filter { $0.isFileURL }
        stagedFiles = filtered
        dragFiles = filtered
        for url in filtered {
            allowedDownloadPaths.insert(url.standardizedFileURL.path)
        }
    }

    public func stageDragFiles(_ urls: [URL]) {
        let filtered = urls.filter { $0.isFileURL }
        dragFiles = filtered
        for url in filtered {
            allowedDownloadPaths.insert(url.standardizedFileURL.path)
        }
    }

    public func sendClipboardFiles(_ urls: [URL]) throws {
        guard state == .connected else { return }
        let entries = Self.collectFileEntries(from: urls)
        guard !entries.isEmpty else { return }
        for entry in entries {
            allowedDownloadPaths.insert(URL(fileURLWithPath: entry.path).standardizedFileURL.path)
        }
        try session.sendClipboardFiles(entries)
        onLog?("USB TX: clipboard files (\(entries.count) file(s))")
    }

    /// Drain pending frames. Call from a timer or a background loop.
    public func pump() throws {
        guard state == .connected else { return }
        var sawFrame = false
        while let frame = try session.read() {
            sawFrame = true
            consecutiveOfflinePolls = 0
            if frame.payloadType == 0x01 {
                clearPendingSwitch()
                peerHandlesSwitchAck = false
                loggedOutByPeer = false
                setPeerOnline(true)
                if let info = OTIXML.decodeLoginCommand(frame.payload) {
                    remoteIsMac = (info.osVersion & 0xF0) == 0x20
                    let hexOS = String(format: "%02x", info.osVersion)
                    onLog?("USB RX: LoginCommand name=\(info.name) os=0x\(hexOS) cp=\(info.codePage)")
                } else {
                    onLog?("USB RX: LoginCommand (\(frame.payload.count)B)")
                }
                // The original daemon re-announces itself on every incoming
                // LoginCommand; the Windows GO! Bridge polls roughly every 10 s
                // until it sees a full handshake, so answer the whole handshake
                // every time instead of only on the first frame.
                handshakeNextStep = 0
                handshakeRetryRemaining = 4
                nextHandshakeRetryAt = .distantPast
                sentPostLoginAnnouncements = true
                runPendingHandshakeSteps()
                continue
            }
            if frame.payloadType == 0x02 {
                clearPendingSwitch()
                peerHandlesSwitchAck = false
                loggedOutByPeer = true
                sentPostLoginAnnouncements = false
                handshakeNextStep = 8
                handshakeRetryRemaining = 0
                try? releaseAllHID()
                onLog?("USB RX: LogoutCommand")
                setPeerOnline(false)
                onKMRemoteEnded?(nil)
                continue
            }
            if frame.payloadType == 0xA1 {
                if let res = OTIXML.decodeResponseResult(frame.payload) {
                    if let osVer = res.remoteOSVersion {
                        remoteIsMac = (osVer & 0xF0) == 0x20
                    }
                    let osHex = res.remoteOSVersion.map { String(format: "0x%02x", $0) } ?? "none"
                    onLog?("USB RX: ResponseResult cmd=0x\(String(format: "%02x", res.requestCommand)) result=\(res.requestResult) os=\(osHex)")
                    if res.requestCommand == 0x01 && res.requestResult == 0 {
                        loggedOutByPeer = false
                        setPeerOnline(true)
                        // On a quick USB reopen, Windows may reply with 0xA1(cmd=0x01)
                        // without re-sending 0x01 LoginCommand; still send steps 4..7 so
                        // Windows gets our screen/KM setting announcement immediately.
                        if !sentPostLoginAnnouncements && handshakeNextStep >= 8 {
                            sentPostLoginAnnouncements = true
                            handshakeNextStep = 4
                            handshakeRetryRemaining = 4
                            nextHandshakeRetryAt = .distantPast
                            runPendingHandshakeSteps()
                        }
                    }
                } else {
                    onLog?("USB RX: ResponseResult (0xA1, \(frame.payload.count)B)")
                }
                continue
            }
            if frame.payloadType == 0x10,
               let request = OTIFileTransfer.parseDownloadRequest(frame.payload) {
                var allowedPaths = allowedDownloadPaths
                for url in stagedFiles { allowedPaths.insert(url.standardizedFileURL.path) }
                try session.fulfillDownloadRequest(
                    request,
                    validatePath: { path in
                        let std = URL(fileURLWithPath: path).standardizedFileURL.path
                        return path.hasPrefix("/Users/") || allowedPaths.contains(std)
                    },
                    onSent: onFileSent,
                    onError: onFileError)
                continue
            }

            if frame.payloadType == 0x3a,
               let package = OTIFileTransfer.parseMultipleFilePackage(frame.payload) {
                for packet in package.dataPackets {
                    let attr = package.attributes.first { attr in
                        let rxName = URL(fileURLWithPath: attr.path).lastPathComponent
                        return incomingFiles[packet.fileID]?.finalURL.lastPathComponent == rxName
                    } ?? (package.dataPackets.count == 1 ? package.attributes.first : nil)
                    if let attr, var state = incomingFiles[packet.fileID] {
                        state.createdAt = attr.createdAt
                        state.modifiedAt = attr.modifiedAt
                        incomingFiles[packet.fileID] = state
                    }
                    handleIncomingFileBytes(fileID: packet.fileID, data: packet.data,
                                            index: packet.currentCountIndex, total: packet.totalCount)
                }
                continue
            }
            if frame.payloadType == 0xa9,
               let err = OTIFileTransfer.parseErrorResponse(frame.payload) {
                handleRequestError(err)
                continue
            }
            if frame.payloadType == 0xa7, frame.payload.count >= 5 {
                // End-of-file marker for a receive session: close it even if the
                // peer sent fewer bytes than the NodeInfo announced.
                let bytes = [UInt8](frame.payload.prefix(5))
                let fileIDLE = UInt32(bytes[1]) | UInt32(bytes[2]) << 8 | UInt32(bytes[3]) << 16 | UInt32(bytes[4]) << 24
                let fileID = (incomingFiles[fileIDLE] != nil || requestedNodes[fileIDLE] != nil || failedFileIDs.contains(fileIDLE))
                    ? fileIDLE : fileIDLE.byteSwapped
                let failed = failedFileIDs.remove(fileID) != nil
                requestedNodes.removeValue(forKey: fileID)
                if let state = incomingFiles[fileID] {
                    let hasValidPayload = state.received > 0 || (state.expectedSize == 0 && state.receivedData)
                    if failed || !hasValidPayload {
                        // Drop the placeholder when the peer errored or sent no data.
                        try? state.handle.close()
                        try? FileManager.default.removeItem(at: state.temporaryURL)
                        try? FileManager.default.removeItem(at: state.finalURL)
                        incomingFiles[fileID] = nil
                        let reason = failed ? "peer error" : "no data"
                        onLog?("File RX failed: \(state.finalURL.lastPathComponent) (\(reason))")
                        onFileReceiveFailed?(state.finalURL.lastPathComponent)
                    } else {
                        finishIncomingFile(id: fileID, state: state)
                    }
                }
                continue
            }
            if frame.payloadType == 0xa3,
               let header = OTIFileTransfer.parseFileData(frame.payload) {
                handleIncomingFileData(header)
                continue
            }
            if frame.payloadType == 0x37,
               let attr = OTIFileTransfer.parseFileAttribute(frame.payload) {
                applyStandaloneFileAttribute(attr)
                continue
            }

            guard frame.payloadType == 0x39 else {
                let hexType = String(format: "%02x", frame.payloadType)
                // File-transfer replies we do not decode yet: dump the bytes and
                // any text they carry so the layout can be worked out from real
                // traffic instead of guesswork.
                let hex = frame.payload.prefix(64).map { String(format: "%02x", $0) }.joined(separator: " ")
                let ascii = String(decoding: frame.payload, as: UTF8.self)
                    .filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0.isPunctuation || $0 == " ") }
                onLog?("USB RX: frame type=0x\(hexType) len=\(frame.payload.count) hex=[\(hex)] text=\(ascii.prefix(120))")
                continue
            }
            guard let cmd = OTIBridge.command(from: frame.payload) else {
                let preview = String(decoding: frame.payload.prefix(160), as: UTF8.self)
                onLog?("USB RX: 0x39 without NP_Cmd: \(preview)")
                continue
            }

            if cmd == OTIBridge.clipboardCommand,
               let text = OTIBridge.clipboardText(from: frame.payload) {
                onClipboard?(text)
            } else if cmd == OTIBridge.clipboardCommand,
                      !OTIFileTransfer.parseNodeInfoList(frame.payload).isEmpty {
                // The peer announced files (clipboard copy / drag). Dump the raw
                // announcement first: the peer rejects IDs we invent ("No such
                // process"), so the session/fileID it assigned has to be read out
                // of this frame.
                let xml = String(decoding: frame.payload, as: UTF8.self)
                onLog?("File RX announce: len=\(frame.payload.count) head=\(xml.prefix(320)) tail=\(xml.suffix(360))")
                requestFiles(OTIFileTransfer.parseNodeInfoList(frame.payload))
            } else if cmd == OTIBridge.clipboardCommand {
                // Windows sent a clipboard frame we could not decode — dump what
                // actually arrived so the parser can be fixed instead of guessed.
                let xml = String(decoding: frame.payload, as: UTF8.self)
                let bodyStart = xml.range(of: "<OTIMSG>")
                let preview = bodyStart.map { String(xml[$0.lowerBound...].prefix(400)) } ?? String(xml.prefix(400))
                let hasContent = xml.contains("CP_Content") ? "yes" : "no"
                let formats = xml.contains("CB_Format_Text") ? "Text"
                    : (xml.contains("CB_Format_UnicodeText") ? "UnicodeText" : "other")
                onLog?("Clipboard RX undecoded: len=\(frame.payload.count) CP_Content=\(hasContent) format=\(formats) body=\(preview)")
            } else if cmd == OTIBridge.switchToRemote {
                loggedOutByPeer = false
                setPeerOnline(true)
                clearPendingSwitch()
                try session.sendSwitchAcknowledge()
                // Entering slave mode must not depend on the optional move-out
                // geometry: if it cannot be parsed we still take the slave role
                // with an unknown direction (the return edge then falls back to
                // the configured "other PC" side). Leaving the app in "local"
                // state while the peer is master is what made both machines
                // fight over control.
                let info = OTIBridge.parseMoveOutInfo(from: frame.payload)
                    ?? KMSwitchMoveOutInfo(moveOutX: 0, moveOutY: 0, remoteWidth: 0,
                                           remoteHeight: 0, direction: 0)
                if info.direction != 0 {
                    peerLastMoveOutY = info.moveOutY
                    peerLastMoveOutHeight = info.remoteHeight
                    // The peer reports its own screen size with every move-out,
                    // which is the only place it arrives when it never answers
                    // `Cmd_Post_Remote_Screen_Info`. Without it the hand-back
                    // coordinates were scaled by the 1080 default instead of the
                    // real 2160, so the pointer landed at half the right height.
                    if info.remoteWidth > 0, info.remoteHeight > 0 {
                        if remoteScreenWidth != info.remoteWidth || remoteScreenHeight != info.remoteHeight {
                            onLog?("Peer screen size: \(info.remoteWidth)x\(info.remoteHeight) (from move-out)")
                        }
                        remoteScreenWidth = info.remoteWidth
                        remoteScreenHeight = info.remoteHeight
                    }
                    onLog?("USB moveOut: dir=\(info.direction) x=\(info.moveOutX) y=\(info.moveOutY) w=\(info.remoteWidth) h=\(info.remoteHeight)")
                } else {
                    let raw = String(decoding: frame.payload, as: UTF8.self)
                    onLog?("USB moveOut: geometry unparsed, taking slave role anyway raw=\(raw.prefix(200))")
                }
                onKMSwitchToLocal?(info)
                onKMSwitch?(cmd)
            } else if cmd == OTIBridge.forceSwitchLocal {
                clearPendingSwitch()
                try? releaseAllHID()
                let info = OTIBridge.parseMoveInInfo(from: frame.payload)
                onLog?("USB RX: Cmd_Force_Remote_To_Switch_Local dir=\(info?.direction ?? -1) x=\(info?.moveInX ?? -1) y=\(info?.moveInY ?? -1)")
                onKMRemoteEnded?(info)
                onKMSwitch?(cmd)
            } else if cmd == OTIBridge.switchToLocal || cmd == OTIBridge.notifySwitchBack {
                clearPendingSwitch()
                try? releaseAllHID()
                onLog?("USB RX: \(cmd)")
                onKMRemoteEnded?(nil)
                onKMSwitch?(cmd)
            } else if cmd == OTIBridge.switchAcknowledge {
                onLog?("USB RX: Cmd_Get_KM_Switch_Acknowlege")
                if clearPendingSwitch() {
                    peerHandlesSwitchAck = true
                }
                onKMSwitch?(cmd)
            } else if cmd == OTIBridge.postRemoteScreenInfo {
                if let sz = OTIBridge.parseScreenInfo(from: frame.payload) {
                    remoteScreenWidth = sz.width
                    remoteScreenHeight = sz.height
                    onLog?("USB RX: Remote screen \(sz.width)x\(sz.height)")
                    onRemoteScreenInfo?(sz.width, sz.height)
                } else {
                    let raw = String(decoding: frame.payload, as: UTF8.self)
                    onLog?("USB RX cmd=\(cmd): \(raw.prefix(240))")
                }
            } else if cmd == OTIBridge.getRemoteDraggingInfo {
                try sendStagedDragInfoIfAvailable()
            } else if cmd == OTIBridge.postRemoteKMPreference {
                if let pref = OTIBridge.parsePeerKMPreference(from: frame.payload) {
                    let clipText = pref.clipOption.map(String.init) ?? "?"
                    let blockText = pref.blocking.map(String.init) ?? "?"
                    onLog?("USB RX: Peer KM preference switchMode=\(pref.switchMode) clip=\(clipText) blocking=\(blockText)")
                } else {
                    let raw = String(decoding: frame.payload, as: UTF8.self)
                    onLog?("USB RX cmd=\(cmd): \(raw.prefix(240))")
                }
            } else {
                let raw = String(decoding: frame.payload, as: UTF8.self)
                onLog?("USB RX cmd=\(cmd): \(raw.prefix(240))")
                if cmd.contains("KM_Switch") { onKMSwitch?(cmd) }
            }
        }
        if !sawFrame, let st = scsiTransport?.lastPollStatusByte {
            if st == 0x01 {
                consecutiveOfflinePolls += 1
                if consecutiveOfflinePolls >= 10 {
                    setPeerOnline(false)
                }
            } else {
                consecutiveOfflinePolls = 0
                if !loggedOutByPeer {
                    setPeerOnline(true)
                }
            }
        }
        if handshakeNextStep < 8 && handshakeRetryRemaining > 0 && Date() >= nextHandshakeRetryAt {
            runPendingHandshakeSteps()
        }
    }

    private func setPeerOnline(_ online: Bool) {
        guard peerOnline != online else { return }
        peerOnline = online
        if !online {
            clearPendingSwitch()
        }
        onPeerOnlineChanged?(online)
    }

    // MARK: - Receiving files

    private func nextDownloadID() -> UInt32 {
        downloadSessionSeed += 1
        if downloadSessionSeed > 9999 || downloadSessionSeed < 0x65 {
            downloadSessionSeed = 0x65
        }
        return downloadSessionSeed
    }

    private func requestFiles(_ nodes: [OTIFileNode]) {
        guard !nodes.isEmpty else { return }
        try? FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        for node in nodes {
            if node.isDirectory {
                let dirName = node.path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? node.path
                onLog?("File RX skipped directory (folders not yet supported over USB): \(dirName)")
                onFileReceiveFailed?("\(dirName) (folder not supported)")
                continue
            }
            let id = nextDownloadID()
            // Windows paths arrive as C:\dir\name.ext; keep only the file name.
            let name = node.path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init)
            let finalName = (name?.isEmpty == false ? name! : "file-\(id)")
            let finalURL = uniqueDestination(for: finalName)
            let tempURL = finalURL.appendingPathExtension("part")
            FileManager.default.createFile(atPath: tempURL.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: tempURL) else {
                onFileReceiveFailed?("cannot create \(tempURL.path)")
                continue
            }
            incomingFiles[id] = IncomingFile(handle: handle, temporaryURL: tempURL,
                                             finalURL: finalURL, expectedSize: node.size,
                                             totalChunks: 0, received: 0,
                                             receivedData: false,
                                             createdAt: node.createdAt,
                                             modifiedAt: node.modifiedAt)
            requestedNodes[id] = node
            let request = OTIFileTransfer.encodeDownloadRequest(
                multiSessionID: id,
                files: [(fileID: id, path: node.path, destinationPath: finalURL.path, rawPath: nil)])
            do {
                try sessionSendDownloadRequest(request)
                onLog?("File RX: requested \(finalName) (\(node.size)B, id=\(id))")
            } catch {
                try? handle.close()
                try? FileManager.default.removeItem(at: tempURL)
                incomingFiles[id] = nil
                requestedNodes[id] = nil
                onFileReceiveFailed?("download request failed: \(error)")
            }
        }
    }

    private func sessionSendDownloadRequest(_ payload: Data) throws {
        try session.sendFrame(payloadType: 0x10, payload: payload)
    }

    private func handleRequestError(_ err: OTIFileTransfer.ErrorResponse) {
        let fileID = err.fileID
        failedFileIDs.insert(fileID)
        let path = requestedNodes[fileID]?.path ?? "fileID=\(fileID)"
        onLog?("File RX: peer error for \(path) (code=0x\(String(format: "%x", err.errorCode)): \(err.message))")
    }

    private func handleIncomingFileData(_ header: OTIFileTransfer.FileDataHeader) {
        handleIncomingFileBytes(fileID: header.sessionFileID, data: header.data,
                                index: header.currentCountIndex, total: header.totalCount)
    }

    private func handleIncomingFileBytes(fileID: UInt32, data: Data, index: UInt32, total: UInt32) {
        guard var state = incomingFiles[fileID] else {
            onLog?("File RX: data for unknown fileID \(fileID) (\(data.count)B)")
            return
        }
        if !data.isEmpty {
            state.handle.write(data)
            state.received += UInt64(data.count)
        }
        state.receivedData = true
        let lastChunk = total > 0 && index >= total
        let sizeReached = state.expectedSize > 0 && state.received >= state.expectedSize
        incomingFiles[fileID] = state
        onLog?("File RX chunk: fileID=\(fileID) index=\(index)/\(total) +\(data.count)B total=\(state.received)/\(state.expectedSize)")
        guard lastChunk || sizeReached else { return }
        finishIncomingFile(id: fileID, state: state)
    }

    private func finishIncomingFile(id: UInt32, state: IncomingFile) {
        try? state.handle.close()
        incomingFiles[id] = nil
        requestedNodes.removeValue(forKey: id)
        failedFileIDs.remove(id)
        do {
            try FileManager.default.moveItem(at: state.temporaryURL, to: state.finalURL)
            applyFileTimestamps(created: state.createdAt, modified: state.modifiedAt, toPath: state.finalURL.path)
            onLog?("File RX complete: \(state.finalURL.lastPathComponent) (\(state.received)B)")
            onFileReceived?(state.finalURL)
        } catch {
            onFileReceiveFailed?("move failed: \(error)")
        }
    }

    private func applyFileTimestamps(created: Date?, modified: Date?, toPath path: String) {
        var attrs: [FileAttributeKey: Any] = [:]
        if let created { attrs[.creationDate] = created }
        if let modified { attrs[.modificationDate] = modified }
        if !attrs.isEmpty {
            try? FileManager.default.setAttributes(attrs, ofItemAtPath: path)
        }
    }

    private func applyStandaloneFileAttribute(_ attr: OTIFileTransfer.FileAttributeInfo) {
        let rxName = URL(fileURLWithPath: attr.path).lastPathComponent
        if let matchID = incomingFiles.first(where: { $0.value.finalURL.lastPathComponent == rxName })?.key
            ?? (incomingFiles.count == 1 ? incomingFiles.keys.first : nil),
           var state = incomingFiles[matchID] {
            state.createdAt = attr.createdAt
            state.modifiedAt = attr.modifiedAt
            incomingFiles[matchID] = state
            return
        }
        guard !attr.path.isEmpty else { return }
        let targetURL = URL(fileURLWithPath: attr.path).standardizedFileURL
        let rootPath = downloadsDirectory.standardizedFileURL.path
        guard targetURL.path.hasPrefix(rootPath),
              FileManager.default.fileExists(atPath: targetURL.path) else { return }
        applyFileTimestamps(created: attr.createdAt, modified: attr.modifiedAt, toPath: targetURL.path)
    }

    private func uniqueDestination(for name: String) -> URL {
        var url = downloadsDirectory.appendingPathComponent(name)
        var counter = 1
        while FileManager.default.fileExists(atPath: url.path) {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            let candidate = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            url = downloadsDirectory.appendingPathComponent(candidate)
            counter += 1
        }
        return url
    }

    private func sendStagedDragInfoIfAvailable() throws {
        var urls = dragFiles
        if urls.isEmpty {
            urls = Self.readDragPasteboardFileURLs()
        }
        let entries = Self.collectFileEntries(from: urls)
        guard !entries.isEmpty else { return }
        for entry in entries {
            allowedDownloadPaths.insert(URL(fileURLWithPath: entry.path).standardizedFileURL.path)
        }
        dragFiles = []

        let xml = OTIFileTransfer.nodeInfoListXML(files: entries)
        try session.sendDragFileIsBeginning()
        try session.sendLateDropData(nodeInfoListXML: xml)
        onLog?("USB drag metadata sent for \(entries.count) file(s)")
        onDragHandoffCompleted?()
    }

    private static func collectFileEntries(
        from urls: [URL]
    ) -> [(path: String, size: UInt64, createdAt: Date, modifiedAt: Date)] {
        var entries: [(path: String, size: UInt64, createdAt: Date, modifiedAt: Date)] = []
        for url in urls where url.isFileURL {
            let path = url.path
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
                continue
            }
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
            let created = (attrs?[.creationDate] as? Date) ?? Date()
            let modified = (attrs?[.modificationDate] as? Date) ?? created
            entries.append((path: path, size: size, createdAt: created, modifiedAt: modified))
        }
        return entries
    }

    public static func readFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        guard let types = pasteboard.types, types.contains(.fileURL) else { return [] }
        if let items = pasteboard.pasteboardItems {
            var direct: [URL] = []
            for item in items {
                guard let raw = item.string(forType: .fileURL),
                      let parsed = URL(string: raw) else { continue }
                let resolved = (parsed as NSURL).filePathURL ?? parsed
                if resolved.isFileURL { direct.append(resolved) }
            }
            if !direct.isEmpty { return direct }
        }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
    }

    public static func readDragPasteboardFileURLs() -> [URL] {
        readFileURLs(from: NSPasteboard(name: .drag))
    }

    private func setState(_ next: State) {
        state = next
        onState?(next)
    }
}
