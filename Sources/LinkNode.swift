// LinkNode.swift
// USB-only replacement for the former Bonjour/TLS LinkNode.
// Keeps the same callback surface used by Clipboard/FileTransfer/UI,
// backed by native arm64 SCSITaskTransport.

import AppKit
import Foundation

final class LinkNode {
    let deviceID: String
    let deviceName: String

    private(set) var peers: [Peer] = []
    private(set) var connectedPeer: Peer?
    private(set) var isListening = false
    private let peerStateLock = NSLock()
    private var _hasConnectedPeer = false
    var hasConnectedPeer: Bool {
        peerStateLock.lock()
        defer { peerStateLock.unlock() }
        return _hasConnectedPeer
    }

    var onPeersChanged: (([Peer]) -> Void)?
    var onConnected: ((Peer) -> Void)?
    var onDisconnected: (() -> Void)?
    var onMessage: ((WireMessage) -> Void)?
    var onLog: ((String) -> Void)?
    var onUSBKMSwitchToLocal: ((KMSwitchMoveOutInfo) -> Void)?
    var onUSBKMSwitchAck: (() -> Void)?
    /// Called whenever the peer sends us a KM command: it drives the KM state
    /// machine itself, so our local edge fallback must stay out of the way.
    var onPeerKMCommand: (() -> Void)?
    var onUSBKMRemoteEnded: ((KMSwitchMoveInInfo?) -> Void)?
    var onUSBRemoteScreenInfo: ((Int, Int) -> Void)?
    var onDragHandoffCompleted: (() -> Void)?
    var onPeerOnlineChanged: ((Bool) -> Void)?
    var onUSBControlLost: (() -> Void)?

    private let usb = USBLink()
    private let usbQueue = DispatchQueue(label: "kmlink.usb")
    private let hidLock = NSLock()
    private var pendingMouseDX: Double = 0
    private var pendingMouseDY: Double = 0
    private var mouseFlushScheduled = false
    private var running = false
    private var timer: DispatchSourceTimer?
    private var consecutivePollErrors = 0
    private var consecutiveHIDFailures = 0
    /// While a KM switch is in flight the bridge must not be polled between the
    /// readiness poll and the 64 KB data-out: background polls measurably make
    /// the data-out abort (standalone probe: 8/8 success with no polling, 2/8
    /// with the 50 ms pump running). The pump only slows down, it keeps reading
    /// so the peer's ACK still arrives.
    private var switchInFlight = false
    private var reportedPeerOffline = false

    init(deviceID: String, name: String) {
        self.deviceID = deviceID
        self.deviceName = name
    }

    func start() {
        guard !running else { return }
        running = true
        isListening = true

        let peer = Peer(id: "usb-bridge", name: "USB bridge", endpoint: "USB", isConnected: false)
        peers = [peer]
        onPeersChanged?(peers)

        usb.onState = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                switch state {
                case .connecting:
                    self.onLog?("USB connecting…")
                case .connected:
                    var connected = peer
                    connected.isConnected = true
                    self.peerStateLock.lock()
                    self._hasConnectedPeer = true
                    self.peerStateLock.unlock()
                    self.connectedPeer = connected
                    self.peers = [connected]
                    self.onPeersChanged?(self.peers)
                    self.onConnected?(connected)
                case .failed(let message):
                    self.isListening = false
                    self.peerStateLock.lock()
                    self._hasConnectedPeer = false
                    self.peerStateLock.unlock()
                    if self.connectedPeer != nil {
                        self.connectedPeer = nil
                        self.peers = [peer]
                        self.onPeersChanged?(self.peers)
                        self.onDisconnected?()
                    }
                    self.onLog?("USB unavailable: \(message)")
                case .idle:
                    self.peerStateLock.lock()
                    self._hasConnectedPeer = false
                    self.peerStateLock.unlock()
                    if self.connectedPeer != nil {
                        self.connectedPeer = nil
                        self.peers = [peer]
                        self.onPeersChanged?(self.peers)
                        self.onDisconnected?()
                    }
                }
            }
        }
        usb.onPeerOnlineChanged = { [weak self] online in
            DispatchQueue.main.async {
                guard let self else { return }
                if !online {
                    self.reportedPeerOffline = true
                    self.onLog?("Other PC offline or logged out — pausing edge switch")
                } else if self.reportedPeerOffline {
                    self.reportedPeerOffline = false
                    self.onLog?("Other PC back online — edge switch re-enabled")
                }
                self.onPeerOnlineChanged?(online)
            }
        }
        usb.onClipboard = { [weak self] text in
            let message = WireMessage(type: MessageType.clipboard.rawValue, text: text)
            DispatchQueue.main.async { self?.onMessage?(message) }
        }
        usb.onKMSwitch = { [weak self] command in
            DispatchQueue.main.async {
                self?.onLog?("USB KM event: \(command)")
                self?.onPeerKMCommand?()
                if command == OTIBridge.switchAcknowledge {
                    self?.setSwitchInFlight(false)
                    self?.onUSBKMSwitchAck?()
                }
            }
        }
        usb.onKMSwitchToLocal = { [weak self] info in
            DispatchQueue.main.async { self?.onUSBKMSwitchToLocal?(info) }
        }
        usb.onKMRemoteEnded = { [weak self] info in
            DispatchQueue.main.async { self?.onUSBKMRemoteEnded?(info) }
        }
        usb.onRemoteScreenInfo = { [weak self] w, h in
            DispatchQueue.main.async { self?.onUSBRemoteScreenInfo?(w, h) }
        }
        usb.onFileSent = { [weak self] path, size in
            let name = URL(fileURLWithPath: path).lastPathComponent
            DispatchQueue.main.async { self?.onLog?("USB sent \(name) (\(size) bytes)") }
        }
        usb.onFileError = { [weak self] message in
            DispatchQueue.main.async { self?.onLog?("USB file error: \(message)") }
        }
        usb.onLog = { [weak self] message in
            DispatchQueue.main.async { self?.onLog?(message) }
        }
        usb.onDragHandoffCompleted = { [weak self] in
            DispatchQueue.main.async { self?.onDragHandoffCompleted?() }
        }

        usbQueue.async { [weak self] in
            guard let self else { return }
            do {
                self.consecutivePollErrors = 0
                self.consecutiveHIDFailures = 0
                self.reportedPeerOffline = false
                try self.usb.start()
            } catch {
                DispatchQueue.main.async { self.onLog?("USB start failed: \(error)") }
            }
        }

        let timer = DispatchSource.makeTimerSource(queue: usbQueue)
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50),
                       leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            guard let self, self.usb.state == .connected else { return }
            do {
                try self.usb.pump()
                self.consecutivePollErrors = 0
            } catch {
                // A rejected write (transient bridge state) must not drop the
                // session; only read/poll failures count towards the limit.
                let text = String(describing: error)
                if text.contains("code=-3") {
                    if !self.reportedPeerOffline {
                        self.reportedPeerOffline = true
                        DispatchQueue.main.async {
                            self.onLog?("Other PC offline: the bridge reports remote host status 0x01 — "
                                + "start GO! Bridge on the Windows machine")
                            self.onPeerOnlineChanged?(false)
                        }
                    } else {
                        DispatchQueue.main.async { self.onUSBControlLost?() }
                    }
                    return
                }
                if text.contains("write failed") {
                    if self.consecutivePollErrors == 0 {
                        DispatchQueue.main.async { self.onLog?("USB write skipped (bridge busy)") }
                    }
                    return
                }
                self.consecutivePollErrors += 1
                if self.consecutivePollErrors == 1 {
                    DispatchQueue.main.async { self.onLog?("USB transient poll error: \(error)") }
                }
                if self.consecutivePollErrors >= 5 {
                    self.usb.stop()
                    DispatchQueue.main.async { self.onLog?("USB read failed: \(error)") }
                }
            }
        }
        timer.resume()
        self.timer = timer
    }

    /// Slows the bridge poll loop down while a KM switch command is in flight.
    func setSwitchInFlight(_ active: Bool) {
        usbQueue.async { [weak self] in
            guard let self, self.switchInFlight != active else { return }
            self.switchInFlight = active
            let interval = active ? 500 : 50
            self.timer?.schedule(deadline: .now() + .milliseconds(interval),
                                 repeating: .milliseconds(interval),
                                 leeway: .milliseconds(5))
            self.onLog?("USB poll interval -> \(interval) ms")
        }
    }

    /// Keeps the announced KM arrangement in sync with the user's setting.
    func setPeerPosition(_ name: String) {
        usbQueue.async { [weak self] in
            guard let usb = self?.usb else { return }
            let changed = usb.localPeerPosition != name
            usb.localPeerPosition = name
            if changed, usb.state == .connected {
                try? usb.sendKMSettingAnnouncement()
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        usbQueue.sync {
            usb.stop()
        }
        running = false
        isListening = false
        connectedPeer = nil
        peers = []
        onPeersChanged?([])
    }

    func connect(to peer: Peer) {
        _ = peer
        usbQueue.async { [weak self] in
            guard let self, self.usb.state != .connected else { return }
            do {
                try self.usb.start()
            } catch {
                DispatchQueue.main.async { self.onLog?("USB connect failed: \(error)") }
            }
        }
    }

    /// Background retry used by auto-connect: logs only when the failure reason
    /// changes, so a missing bridge does not spam the log every 2 s.
    private var lastAutoConnectError: String?

    func autoConnect() {
        usbQueue.async { [weak self] in
            guard let self, self.usb.state != .connected else { return }
            do {
                try self.usb.start()
                self.lastAutoConnectError = nil
            } catch {
                let text = "\(error)"
                guard text != self.lastAutoConnectError else { return }
                self.lastAutoConnectError = text
                DispatchQueue.main.async {
                    self.onLog?("Auto-connect waiting: \(text)")
                }
            }
        }
    }

    func disconnect() {
        usbQueue.async { [weak self] in
            self?.usb.stop()
        }
        isListening = false
    }

    /// Files arriving from the peer land in the user's downloads directory.
    func setDownloadsDirectory(_ url: URL) {
        usbQueue.async { [weak self] in
            self?.usb.downloadsDirectory = url
        }
    }

    var onFileReceived: ((URL) -> Void)? {
        didSet {
            usbQueue.async { [weak self] in
                guard let self else { return }
                let handler = self.onFileReceived
                self.usb.onFileReceived = { url in
                    DispatchQueue.main.async { handler?(url) }
                }
                self.usb.onFileReceiveFailed = { message in
                    DispatchQueue.main.async { self.onLog?("File RX failed: \(message)") }
                }
            }
        }
    }

    func stageFiles(_ urls: [URL]) {
        let fileURLs = urls.filter { $0.isFileURL }
        usbQueue.async { [weak self] in
            self?.usb.stageFiles(fileURLs)
        }
        if !fileURLs.isEmpty {
            onLog?("Staged \(fileURLs.count) file(s) for USB drag/transfer")
        }
    }

    func sendFilesViaClipboard(_ urls: [URL]) {
        let fileURLs = urls.filter { $0.isFileURL }
        guard !fileURLs.isEmpty else { return }
        usbQueue.async { [weak self] in
            do {
                try self?.usb.sendClipboardFiles(fileURLs)
                DispatchQueue.main.async {
                    self?.onLog?("Copied \(fileURLs.count) file(s) to USB clipboard (Ctrl+V on Windows)")
                }
            } catch {
                DispatchQueue.main.async { self?.onLog?("USB clipboard files send failed: \(error)") }
            }
        }
    }

    func startUSBRemoteControl(direction: Int, x: Int, y: Int, width: Int, height: Int,
                               mouseButtons: UInt8 = 0) {
        hidLock.lock()
        pendingMouseDX = 0
        pendingMouseDY = 0
        mouseFlushScheduled = false
        hidLock.unlock()
        usbQueue.async { [weak self] in
            guard let self else { return }
            if (mouseButtons & 0x01) != 0 {
                let draggedFiles = USBLink.readDragPasteboardFileURLs()
                if !draggedFiles.isEmpty {
                    self.usb.stageDragFiles(draggedFiles)
                }
            }
            do {
                try self.usb.sendSwitchToRemote(direction: direction, x: x, y: y,
                                                width: width, height: height,
                                                initialMouseButtons: mouseButtons)
                self.consecutiveHIDFailures = 0
            } catch {
                DispatchQueue.main.async {
                    self.onLog?("USB switch-to-remote failed: \(error)")
                    self.onUSBControlLost?()
                }
            }
        }
    }

    func handleUSBReturnEdge(at point: CGPoint, direction: Int) {
        let leftButtonDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
        usbQueue.async { [weak self] in
            guard let self else { return }
            if leftButtonDown {
                let dragged = USBLink.readDragPasteboardFileURLs()
                if !dragged.isEmpty {
                    self.usb.stageDragFiles(dragged)
                }
            }
            do {
                try self.usb.sendForceRemoteSwitchLocal(
                    x: Int(point.x.rounded()),
                    y: Int(point.y.rounded()),
                    direction: direction)
            } catch {
                DispatchQueue.main.async { self.onLog?("USB return-edge switch failed: \(error)") }
            }
        }
    }

    func send(_ message: WireMessage) {
        if message.type == MessageType.clipboard.rawValue {
            if let filePaths = message.filePaths, !filePaths.isEmpty {
                sendFilesViaClipboard(filePaths.map { URL(fileURLWithPath: $0) })
                return
            }
            if let text = message.text {
                usbQueue.async { [weak self] in
                    do { try self?.usb.sendClipboard(text) } catch {
                        DispatchQueue.main.async { self?.onLog?("USB clipboard send failed: \(error)") }
                    }
                }
                return
            }
        }
        if message.type == MessageType.km.rawValue, let km = message.km {
            if km.kind == "mouseMoved" || km.kind == "mouseDragged" {
                hidLock.lock()
                pendingMouseDX += km.dx ?? 0
                pendingMouseDY += km.dy ?? 0
                let needSchedule = !mouseFlushScheduled
                mouseFlushScheduled = true
                hidLock.unlock()
                if needSchedule {
                    usbQueue.async { [weak self] in self?.flushPendingMouseMoves() }
                }
            } else {
                usbQueue.async { [weak self] in
                    guard let self else { return }
                    self.flushPendingMouseMoves()
                    do {
                        try self.usb.sendHID(event: km)
                        self.consecutiveHIDFailures = 0
                    } catch {
                        self.handleHIDFailure(error, context: "USB HID send failed")
                    }
                }
            }
            return
        }
        if message.type == MessageType.switchLocal.rawValue {
            hidLock.lock()
            pendingMouseDX = 0
            pendingMouseDY = 0
            mouseFlushScheduled = false
            hidLock.unlock()
            usbQueue.async { [weak self] in
                do { try self?.usb.sendSwitchToLocal() } catch {
                    DispatchQueue.main.async { self?.onLog?("USB switch-to-local failed: \(error)") }
                }
            }
            return
        }
        onLog?("USB: unsupported message \(message.type) (not implemented yet)")
    }

    /// Hands control back while we are the master, echoing the peer's own cursor
    /// position so it does not move. Returns the equivalent local height for the
    /// pointer we leave behind.
    func handBackFromPeerCursor() -> CGFloat {
        let union = KMEngine.cgScreenUnion()
        let peerY = usb.peerCursorY
        let peerH = max(1, usb.peerScreenHeight)
        let localH = union.isNull ? 982 : union.height
        let localY = union.minY + CGFloat(peerY) / CGFloat(peerH) * localH
        let direction = usb.localPeerPosition == "left" ? 1 : 2
        usbQueue.async { [weak self] in
            do {
                try self?.usb.sendForceRemoteSwitchLocalPeerSpace(direction: direction)
            } catch {
                DispatchQueue.main.async { self?.onLog?("USB hand-back failed: \(error)") }
            }
        }
        return min(max(localY, union.isNull ? 0 : union.minY), union.isNull ? localH : union.maxY)
    }

    /// Called after each forwarded batch: while we drive the other machine, the
    /// mirrored peer pointer is the only way to detect "the user pushed back out
    /// of that machine", because our own cursor is pinned on the exit edge.
    var onPeerCursorMaybeExited: (() -> Void)?

    private func flushPendingMouseMoves() {
        hidLock.lock()
        let dx = pendingMouseDX
        let dy = pendingMouseDY
        pendingMouseDX = 0
        pendingMouseDY = 0
        mouseFlushScheduled = false
        hidLock.unlock()
        guard dx.rounded() != 0 || dy.rounded() != 0 else { return }
        do {
            try usb.sendHID(event: KMEvent(kind: "mouseMoved", dx: dx, dy: dy))
            consecutiveHIDFailures = 0
            if usb.localPeerPosition == "left" || usb.localPeerPosition == "right" {
                let exitEdge = usb.localPeerPosition == "left" ? 2 : 1
                if usb.peerCursorExited(edge: exitEdge, margin: 40) {
                    DispatchQueue.main.async { self.onPeerCursorMaybeExited?() }
                }
            }
        } catch {
            handleHIDFailure(error, context: "USB HID move failed")
        }
    }

    private func handleHIDFailure(_ error: Error, context: String) {
        consecutiveHIDFailures += 1
        let immediateAbort = SCSITaskTransport.isPeerOfflineError(error) || consecutiveHIDFailures >= 3
        DispatchQueue.main.async {
            self.onLog?("\(context): \(error)")
            if immediateAbort {
                self.onUSBControlLost?()
            }
        }
    }
}
