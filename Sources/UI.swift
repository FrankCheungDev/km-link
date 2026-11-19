import Foundation
import AppKit
import UniformTypeIdentifiers

// MARK: - Model

final class AppModel {
    let deviceName: String
    var peers: [Peer] = []
    var connected: Peer?
    var status: String = "Starting…"
    var logLines: [String] = []
    var accessibilityOK: Bool = KMEngine.hasAccessibility()
    var kmEnabled: Bool
    var clipboardEnabled: Bool
    var peerPosition: String

    /// Called on the main thread whenever observable state changes.
    var onChange: (() -> Void)?

    private let node: LinkNode
    private let clipboard: ClipboardSync
    private let km: KMEngine
    private let settings = AppSettings.shared
    private let previewMode: Bool
    private var permissionTimer: DispatchSourceTimer?
    private var autoConnectTimer: DispatchSourceTimer?
    private var usbSwitchAckTimer: DispatchSourceTimer?
    private var workspaceObserver: NSObjectProtocol?
    private var hidMouseTuned = false
    private var remoteScreenWidth = 0
    private var remoteScreenHeight = 0
    private var manualDisconnectActive = false
    private var peerOffline = false
    private var lastAutoConnectSetting = AppSettings.shared.autoConnectUSB

    init(previewMode: Bool = false) {
        self.previewMode = previewMode
        let settings = AppSettings.shared
        kmEnabled = settings.kmEnabled
        clipboardEnabled = settings.clipboardEnabled
        peerPosition = settings.peerPosition
        let env = ProcessInfo.processInfo.environment
        let deviceID = env["KMLINK_DEVICE_ID"] ?? settings.deviceID
        deviceName = env["KMLINK_NAME"] ?? settings.displayName
        node = LinkNode(deviceID: deviceID, name: deviceName)
        clipboard = ClipboardSync(node: node)
        km = KMEngine()
        if previewMode {
            peers = [Peer(id: "usb-bridge", name: "USB bridge", endpoint: "USB", isConnected: false)]
            status = "Waiting for USB bridge"
            accessibilityOK = true
            logLines = ["[10:00:00] KMLink ready — waiting for OTi USB bridge (0x0EA0:0x2213)"]
            return
        }
        wire()
        node.start()
        Notifications.request()
        status = "Waiting for USB bridge"
        clipboard.start()
        clipboard.enabled = clipboardEnabled
        km.usbMode = true
        km.enabled = kmEnabled
        // Heal any acceleration value written by an earlier KMLink run before we
        // start touching the bridge again.
        _ = oti_hid_restore_mouse_defaults(nil)
        MouseScaling.restoreIfNeeded()
        // Match the original app: be present at login and keep the bridge warm.
        if settings.launchAtLogin {
            let mechanism = LaunchAtLogin.setEnabled(true)
            appendLog("Launch at login: \(mechanism)")
        }
        km.peerPosition = peerPosition
        applySettings()
        appendLog("Accessibility trusted: \(accessibilityOK)")
        if kmEnabled { km.start() }
        refreshPermission()

        let pTimer = DispatchSource.makeTimerSource(queue: .main)
        pTimer.schedule(deadline: .now() + 1.5, repeating: 1.5)
        pTimer.setEventHandler { [weak self] in
            guard let self else { return }
            let trusted = KMEngine.hasAccessibility()
            if trusted != self.accessibilityOK {
                self.accessibilityOK = trusted
                self.appendLog("Accessibility trusted: \(trusted)")
                self.changed()
            }
            if trusted && self.kmEnabled && !self.km.isCaptureActive {
                self.km.start()
            }
        }
        pTimer.resume()
        permissionTimer = pTimer

        // Hot-plug handling: retry the bridge every 2 s until it answers, so
        // attaching the cable (or replugging it) connects without any UI action.
        let aTimer = DispatchSource.makeTimerSource(queue: .main)
        aTimer.schedule(deadline: .now() + 1.0, repeating: 2.0)
        aTimer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.settings.autoConnectUSB, !self.manualDisconnectActive else { return }
            guard self.connected == nil else { return }
            self.node.autoConnect()
        }
        aTimer.resume()
        autoConnectTimer = aTimer

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, self.km.controllingRemote else { return }
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bid = app?.bundleIdentifier ?? ""
            if bid == "com.apple.UserNotificationCenter"
                || bid == "com.apple.SecurityAgent"
                || bid == "com.apple.CoreServicesUIAgent" {
                self.km.endRemoteControl(notifyPeer: true)
                self.appendLog("System dialog (\(bid)) activated -> returned mouse control to Mac")
            }
        }
    }

    deinit {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
    }

    private func wire() {
        node.onPeersChanged = { [weak self] peers in
            DispatchQueue.main.async { self?.peers = peers; self?.changed() }
        }
        node.onConnected = { [weak self] peer in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.manualDisconnectActive {
                    self.node.disconnect()
                    return
                }
                self.connected = peer
                self.peerOffline = false
                self.km.canSwitch = true
                self.hidMouseTuned = false
                self.tuneOTIHIDMouse()
                self.status = "Connected to \(peer.name)"
                self.appendLog("Connected to \(peer.name)")
                Notifications.post(title: "KMLink", body: "Connected to \(peer.name)")
            }
        }
        node.onDisconnected = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                let shouldLog = (self.connected != nil || self.status != "Disconnected")
                self.connected = nil
                self.peerOffline = false
                self.km.canSwitch = false
                self.leaveRemoteModes(notifyPeer: false, restoreHID: true)
                self.status = "Disconnected"
                if shouldLog {
                    self.appendLog("Disconnected")
                }
                self.changed()
            }
        }
        node.onMessage = { [weak self] message in
            DispatchQueue.main.async { self?.handle(message) }
        }
        node.onLog = { [weak self] text in
            DispatchQueue.main.async { self?.appendLog(text) }
        }
        node.onUSBKMSwitchToLocal = { [weak self] info in
            DispatchQueue.main.async {
                guard let self else { return }
                self.cancelUSBSwitchAckTimer()
                self.node.setSwitchInFlight(false)
                if info.remoteWidth > 0 && info.remoteHeight > 0 {
                    self.remoteScreenWidth = info.remoteWidth
                    self.remoteScreenHeight = info.remoteHeight
                }
                if !self.hidMouseTuned {
                    self.tuneOTIHIDMouse()
                }
                self.km.beginUSBSlave(from: info)
                let syncedPos: String?
                switch info.direction {
                case 2: syncedPos = "left"
                case 1: syncedPos = "right"
                case 3: syncedPos = "down"
                case 4: syncedPos = "up"
                default: syncedPos = nil
                }
                if let syncedPos, syncedPos != self.peerPosition {
                    self.peerPosition = syncedPos
                    self.settings.peerPosition = syncedPos
                    self.changed()
                }
            }
        }
        node.onUSBKMSwitchAck = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.cancelUSBSwitchAckTimer()
                self.appendLog("USB KM switch ACK received")
            }
        }
        node.onUSBKMRemoteEnded = { [weak self] info in
            DispatchQueue.main.async {
                guard let self else { return }
                self.cancelUSBSwitchAckTimer()
                self.node.setSwitchInFlight(false)
                var warp: CGPoint?
                if let info {
                    let moveOut = KMSwitchMoveOutInfo(
                        moveOutX: info.moveInX,
                        moveOutY: info.moveInY,
                        remoteWidth: self.remoteScreenWidth,
                        remoteHeight: self.remoteScreenHeight,
                        direction: info.direction)
                    warp = KMEngine.entryPoint(from: moveOut)
                }
                if info == nil && self.km.usbSlaveActive {
                    self.km.endUSBSlave(at: .zero, direction: 1, notifyPeer: false, becomeMaster: false)
                }
                self.km.endRemoteControl(notifyPeer: false, warpTo: warp)
                self.changed()
            }
        }
        node.onUSBRemoteScreenInfo = { [weak self] w, h in
            DispatchQueue.main.async {
                self?.remoteScreenWidth = w
                self?.remoteScreenHeight = h
            }
        }
        clipboard.onLog = { [weak self] text in
            DispatchQueue.main.async { self?.appendLog(text) }
        }
        km.onEvent = { [weak self] event in
            self?.node.send(WireMessage(type: MessageType.km.rawValue, km: event))
        }
        km.onRequestSwitchRemote = { [weak self] in
            self?.node.send(WireMessage(type: MessageType.switchRemote.rawValue))
        }
        km.onRemoteActiveChanged = { [weak self] active in
            DispatchQueue.main.async {
                guard let self else { return }
                // Mirrors the original daemon: drop local pointer acceleration while
                // we drive the other machine, restore it the moment control ends.
                if active {
                    MouseScaling.disable()
                    self.appendLog("Pointer acceleration disabled for the takeover")
                } else {
                    MouseScaling.restore()
                    self.appendLog("Pointer acceleration restored")
                }
            }
        }
        node.setDownloadsDirectory(settings.downloadsDirectory)
        node.onFileReceived = { [weak self] url in
            guard let self else { return }
            self.appendLog("File received: \(url.lastPathComponent)")
            self.enqueueForClipboard(url)
        }
        node.onPeerKMCommand = { [weak km] in km?.notePeerKMCommand() }
        node.onPeerCursorMaybeExited = { [weak km, weak self] in
            guard let self, let km, km.controllingRemote else { return }
            self.cancelUSBSwitchAckTimer()
            self.node.setSwitchInFlight(false)
            let localY = self.node.handBackFromPeerCursor()
            self.appendLog("Peer cursor left its edge -> handing control back (local y=\(Int(localY)))")
            km.endMasterForHandBack(localY: localY)
        }
        km.onRequestUSBRemoteSwitch = { [weak self] point, dir, size, buttons in
            guard let self else { return }
            self.node.startUSBRemoteControl(
                direction: dir,
                x: Int(point.x.rounded()),
                y: Int(point.y.rounded()),
                width: Int(size.width.rounded()),
                height: Int(size.height.rounded()),
                mouseButtons: buttons)
            DispatchQueue.main.async { self.armUSBSwitchAckTimer() }
        }
        km.onRequestSwitchLocal = { [weak self] in
            self?.node.send(WireMessage(type: MessageType.switchLocal.rawValue))
        }
        km.onUSBReturnEdge = { [weak self] point, dir in
            self?.node.handleUSBReturnEdge(at: point, direction: dir)
        }
        node.onDragHandoffCompleted = { [weak self] in
            self?.km.finishLocalDragCleanly()
        }
        node.onPeerOnlineChanged = { [weak self] online in
            DispatchQueue.main.async {
                guard let self else { return }
                self.peerOffline = !online
                let isConnected = (self.connected != nil) && !self.manualDisconnectActive
                self.km.canSwitch = isConnected && online
                if !online {
                    self.leaveRemoteModes(notifyPeer: false, restoreHID: false)
                    if isConnected {
                        self.status = "USB connected — waiting for Windows GO! Bridge"
                    }
                } else if isConnected && !self.km.controllingRemote && !self.km.usbSlaveActive {
                    self.status = "Connected to \(self.connected?.name ?? "USB bridge")"
                }
                self.changed()
            }
        }
        node.onUSBControlLost = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.cancelUSBSwitchAckTimer()
                self.node.setSwitchInFlight(false)
                if self.km.controllingRemote {
                    self.km.endRemoteControl(notifyPeer: false)
                    self.appendLog("Returned mouse control to Mac (peer unavailable)")
                    self.changed()
                }
            }
        }
        km.onEdgeDiag = { [weak self] text in
            DispatchQueue.main.async { self?.appendLog("KM edge: " + text) }
        }
        km.onStatus = { [weak self] text in
            DispatchQueue.main.async {
                guard let self, self.connected != nil, !self.manualDisconnectActive, !self.peerOffline else { return }
                self.status = text
                self.changed()
            }
        }
        km.onControlled = { [weak self] in
            DispatchQueue.main.async { self?.status = "Controlled by the other PC"; self?.changed() }
        }
    }

    private func handle(_ message: WireMessage) {
        switch MessageType(rawValue: message.type) {
        case .clipboard:
            clipboard.applyRemote(message)
        case .km:
            if let event = message.km { km.applyRemote(event) }
        case .switchRemote:
            km.beginControlled()
        case .switchLocal:
            if km.controllingRemote {
                km.endRemoteControl(notifyPeer: false)
            } else {
                km.endControlled(notifyPeer: false)
            }
        default:
            break
        }
    }

    // MARK: Commands

    func connect(to peer: Peer) {
        manualDisconnectActive = false
        peerOffline = false
        status = "Connecting…"
        changed()
        node.connect(to: peer)
    }

    func disconnect() {
        manualDisconnectActive = true
        connected = nil
        peerOffline = false
        km.canSwitch = false
        leaveRemoteModes(notifyPeer: false, restoreHID: true)
        status = "Disconnected"
        appendLog("Disconnected")
        changed()
        node.disconnect()
    }

    private func leaveRemoteModes(notifyPeer: Bool, restoreHID: Bool) {
        cancelUSBSwitchAckTimer()
        node.setSwitchInFlight(false)
        km.endControlled(notifyPeer: notifyPeer)
        if km.usbSlaveActive {
            km.endUSBSlave(at: .zero, direction: 1, notifyPeer: notifyPeer, becomeMaster: false)
        }
        if km.controllingRemote {
            km.endRemoteControl(notifyPeer: notifyPeer)
        }
        if restoreHID {
            restoreOTIHIDMouse()
        }
    }

    func toggleKM(_ value: Bool) {
        kmEnabled = value
        settings.kmEnabled = value
        km.enabled = value
        if value {
            km.start()
            refreshPermission()
        } else {
            leaveRemoteModes(notifyPeer: true, restoreHID: false)
            km.stop()
        }
        changed()
    }

    func toggleClipboard(_ value: Bool) {
        clipboardEnabled = value
        settings.clipboardEnabled = value
        clipboard.enabled = value
        changed()
    }

    func setPosition(_ value: String) {
        peerPosition = value
        settings.peerPosition = value
        km.peerPosition = value
        node.setPeerPosition(value)
        changed()
    }

    func sendFiles(_ urls: [URL]) {
        guard !settings.blockFileSending else {
            appendLog("File sending is blocked in Settings")
            return
        }
        guard connected != nil else {
            appendLog("Connect to a USB bridge before sending files")
            return
        }
        node.sendFilesViaClipboard(urls)
    }

    func requestAccessibility() {
        KMEngine.requestAccessibility()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.refreshPermission() }
    }

    /// Files arrive asynchronously and usually in groups; collect them for a
    /// moment and then offer the whole set on the pasteboard, so ⌘V in Finder
    /// pastes the real files instead of whatever text was there before.
    private var pendingClipboardFiles: [URL] = []
    private var clipboardFileTimer: DispatchSourceTimer?

    private func enqueueForClipboard(_ url: URL) {
        pendingClipboardFiles.append(url)
        clipboardFileTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.8)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let files = self.pendingClipboardFiles
            self.pendingClipboardFiles = []
            guard !files.isEmpty else { return }
            self.clipboard.applyRemoteFiles(files)
            let names = files.map { $0.lastPathComponent }.joined(separator: ", ")
            self.appendLog("On clipboard: \(names) — press ⌘V to paste")
            Notifications.post(title: "File received",
                               body: files.count == 1 ? "\(names) — 按 ⌘V 粘贴" : "\(files.count) 个文件 — 按 ⌘V 粘贴")
        }
        timer.resume()
        clipboardFileTimer = timer
    }

    func applySettings() {
        let settings = AppSettings.shared
        if settings.autoConnectUSB && !lastAutoConnectSetting {
            manualDisconnectActive = false
        }
        lastAutoConnectSetting = settings.autoConnectUSB
        km.edgeEnabled = settings.edgeSwitchingEnabled
        km.middleButtonSwitch = settings.middleButtonSwitch
        km.hotCornerSwitch = settings.hotCornerSwitch
        km.edgeTolerance = CGFloat(settings.edgeTolerance)
        km.mouseSensitivity = settings.mouseSensitivity
        km.peerPosition = settings.peerPosition
        km.forwardLocalInput = settings.forwardLocalInput
        node.setPeerPosition(settings.peerPosition)
        clipboard.sendEnabled = settings.clipboardSendEnabled
        clipboard.receiveEnabled = settings.clipboardReceiveEnabled
        if connected != nil {
            tuneOTIHIDMouse()
        }
    }

    /// Applies the "pointer speed" setting to the bridge's virtual mouse only.
    ///
    /// 1.00x means "leave macOS alone". The old implementation always wrote a
    /// low acceleration value (6144), which on this hardware makes the OTi
    /// virtual mouse *much faster* — that was the "insanely fast / uncontrollable
    /// pointer after crossing from Windows" bug.
    private func tuneOTIHIDMouse() {
        var applied: Int32 = 0
        let speed = settings.mouseSensitivity
        let count = oti_hid_tune_mouse(true, speed, &applied)
        hidMouseTuned = count > 0
        if abs(speed - 1.0) < 0.005 {
            appendLog("Pointer speed 1.00x: OTi mouse keeps macOS defaults (services=\(count))")
        } else {
            appendLog(String(format: "Pointer speed %.2fx: OTi mouse accel=%d (services=%d)", speed, applied, count))
        }
    }

    private func restoreOTIHIDMouse() {
        // Always run: a previous KMLink run may have left a tuned value behind,
        // because the HID service properties survive the process exit.
        let count = oti_hid_restore_mouse_defaults(nil)
        hidMouseTuned = false
        if count > 0 {
            appendLog("Restored OTi mouse to macOS defaults (services=\(count))")
        }
    }

    /// Called after `Cmd_Notify_KM_Switch_To_Remote` was queued.
    ///
    /// The Windows GO! Bridge never answers with
    /// `Cmd_Get_KM_Switch_Acknowlege` in practice, yet the bridge happily
    /// injects our HID reports into the Windows host (verified on hardware:
    /// `--hidtest` moves the Windows pointer with no KM handshake at all).
    /// So the ACK is *not* treated as a precondition for taking control: after
    /// the timeout we keep forwarding input and only resume the fast poll loop.
    /// Control is given back with the hotkey, or by the peer's
    /// `Cmd_Force_Remote_To_Switch_Local`.
    private func armUSBSwitchAckTimer() {
        cancelUSBSwitchAckTimer()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(5000))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.usbSwitchAckTimer = nil
            self.node.setSwitchInFlight(false)
            guard self.km.controllingRemote else { return }
            self.status = "Controlling the other PC (mouse over USB HID)"
            self.appendLog("No switch ACK from Windows; continuing with direct HID injection "
                + "(press the KM hotkey to come back)")
            self.changed()
        }
        timer.resume()
        usbSwitchAckTimer = timer
    }

    private func cancelUSBSwitchAckTimer() {
        usbSwitchAckTimer?.cancel()
        usbSwitchAckTimer = nil
    }

    func refreshPermission() {
        accessibilityOK = KMEngine.hasAccessibility()
        if accessibilityOK && kmEnabled && !km.isCaptureActive {
            km.start()
        }
        changed()
    }

    func appendLog(_ text: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(stamp)] \(text)"
        logLines.append(line)
        if logLines.count > 400 { logLines.removeFirst(logLines.count - 400) }
        if !previewMode, let data = (line + "\n").data(using: .utf8) {
            let logURL = URL(fileURLWithPath: "/tmp/kmlink-runtime.log")
            let fm = FileManager.default
            if let attrs = try? fm.attributesOfItem(atPath: logURL.path),
               let size = (attrs[.size] as? NSNumber)?.uint64Value,
               size >= 2 * 1024 * 1024 {
                let backupURL = URL(fileURLWithPath: "/tmp/kmlink-runtime.log.1")
                try? fm.removeItem(at: backupURL)
                try? fm.moveItem(at: logURL, to: backupURL)
            }
            if let fh = try? FileHandle(forWritingTo: logURL) {
                _ = try? fh.seekToEnd()
                try? fh.write(contentsOf: data)
                try? fh.close()
            } else {
                try? data.write(to: logURL)
            }
        }
        changed()
    }

    private func changed() {
        if Thread.isMainThread {
            onChange?()
        } else {
            DispatchQueue.main.async { self.onChange?() }
        }
    }
}

// MARK: - Drop view

final class DropView: NSView {
    var onDrop: (([URL]) -> Void)?
    private let label = NSTextField(labelWithString: "Drop files to copy to Windows clipboard (Ctrl+V)")
    private let button = NSButton(title: "Choose Files…", target: nil, action: nil)
    private var highlighted = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true

        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        button.bezelStyle = .rounded
        button.target = self
        button.action = #selector(choose)

        let stack = NSStackView(views: [label, button])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        path.lineWidth = 1.5
        path.setLineDash([6, 4], count: 2, phase: 0)
        (highlighted ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setStroke()
        path.stroke()
    }

    @objc private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { onDrop?(panel.urls) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        highlighted = true
        needsDisplay = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlighted = false
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        needsDisplay = true
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else {
            return false
        }
        onDrop?(urls)
        return true
    }
}

// MARK: - Main view controller

final class MainViewController: NSViewController {
    private let model: AppModel
    private let statusLabel = NSTextField(labelWithString: "")
    private let dot = NSView()
    private let peersStack = NSStackView()
    private let logTextView = NSTextView()
    private let kmCheck = NSButton(checkboxWithTitle: "Keyboard & mouse sharing", target: nil, action: nil)
    private let clipCheck = NSButton(checkboxWithTitle: "Clipboard sync", target: nil, action: nil)
    private let positionControl = NSSegmentedControl(labels: ["Left", "Right", "Top", "Bottom"],
                                                     trackingMode: .selectOne, target: nil, action: nil)
    private var permissionRow: NSStackView!

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        model.onChange = { [weak self] in self?.refresh() }
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        root.translatesAutoresizingMaskIntoConstraints = false

        // Header
        let iconView = NSImageView()
        iconView.image = AppBrand.appIcon()
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 44).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 44).isActive = true
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        let title = NSTextField(labelWithString: "KMLink")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let subtitle = NSTextField(labelWithString: model.deviceName)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        let nameStack = NSStackView(views: [title, subtitle])
        nameStack.orientation = .vertical
        nameStack.alignment = .leading
        nameStack.spacing = 1

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4.5
        dot.layer?.backgroundColor = NSColor.systemGray.cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 9).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 9).isActive = true
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let spacer = NSView()
        let header = NSStackView(views: [iconView, nameStack, spacer, dot, statusLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Permission
        let permText = NSTextField(wrappingLabelWithString:
            "Accessibility permission is required to share keyboard and mouse input.")
        permText.font = .systemFont(ofSize: 11)
        permText.textColor = .secondaryLabelColor
        let openButton = NSButton(title: "Open Settings", target: self, action: #selector(openAccessibility))
        let checkButton = NSButton(title: "Check", target: self, action: #selector(checkAccessibility))
        openButton.bezelStyle = .rounded
        checkButton.bezelStyle = .rounded
        permissionRow = NSStackView(views: [permText, openButton, checkButton])
        permissionRow.orientation = .horizontal
        permissionRow.spacing = 8
        permissionRow.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        permissionRow.wantsLayer = true
        permissionRow.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.12).cgColor
        permissionRow.layer?.cornerRadius = 8

        // Peers
        let peersTitle = NSTextField(labelWithString: "DEVICES")
        peersTitle.font = .systemFont(ofSize: 10, weight: .semibold)
        peersTitle.textColor = .secondaryLabelColor
        peersStack.orientation = .vertical
        peersStack.alignment = .leading
        peersStack.spacing = 6

        // Controls
        kmCheck.target = self
        kmCheck.action = #selector(toggleKM)
        clipCheck.target = self
        clipCheck.action = #selector(toggleClipboard)
        positionControl.target = self
        positionControl.action = #selector(positionChanged)
        positionControl.selectedSegment = 1
        let positionRow = NSStackView(views: [NSTextField(labelWithString: "Other PC is on the"), positionControl])
        positionRow.orientation = .horizontal
        positionRow.spacing = 8
        let hint = NSTextField(wrappingLabelWithString:
            "Move the pointer off that screen edge, or press ⌃⌥S, to take control. ⌃⌥S returns.")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor

        // Drop
        let drop = DropView()
        drop.translatesAutoresizingMaskIntoConstraints = false
        drop.heightAnchor.constraint(equalToConstant: 92).isActive = true
        drop.onDrop = { [weak self] urls in self?.model.sendFiles(urls) }

        // Log
        let logTitle = NSTextField(labelWithString: "ACTIVITY")
        logTitle.font = .systemFont(ofSize: 10, weight: .semibold)
        logTitle.textColor = .secondaryLabelColor
        logTextView.frame = NSRect(x: 0, y: 0, width: 524, height: 120)
        logTextView.minSize = NSSize(width: 0, height: 120)
        logTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        logTextView.isVerticallyResizable = true
        logTextView.isHorizontallyResizable = false
        logTextView.autoresizingMask = [.width]
        logTextView.textContainerInset = NSSize(width: 4, height: 4)
        logTextView.textContainer?.containerSize = NSSize(width: 524, height: CGFloat.greatestFiniteMagnitude)
        logTextView.textContainer?.widthTracksTextView = true
        logTextView.isEditable = false
        logTextView.drawsBackground = true
        logTextView.backgroundColor = NSColor.black.withAlphaComponent(0.05)
        logTextView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        logTextView.textColor = .labelColor
        let scroll = NSScrollView()
        scroll.documentView = logTextView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
        let logBox = NSView()
        logBox.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: logBox.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: logBox.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: logBox.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: logBox.bottomAnchor)
        ])
        logBox.heightAnchor.constraint(equalToConstant: 120).isActive = true

        for view in [header, permissionRow!, peersTitle, peersStack, kmCheck, clipCheck,
                     positionRow, hint, drop, logTitle, logBox] {
            root.addArrangedSubview(view)
        }

        // Width constraints
        for view in [header, permissionRow!, peersStack, positionRow, hint, drop, logBox] {
            view.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -36).isActive = true
        }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 640))
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -18),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 560),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 620)
        ])
        view = container
        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    // MARK: Refresh

    func refresh() {
        statusLabel.stringValue = model.status
        dot.layer?.backgroundColor = (model.connected == nil ? NSColor.systemGray : NSColor.systemGreen).cgColor
        permissionRow.isHidden = model.accessibilityOK
        kmCheck.state = model.kmEnabled ? .on : .off
        clipCheck.state = model.clipboardEnabled ? .on : .off
        switch model.peerPosition {
        case "left": positionControl.selectedSegment = 0
        case "right": positionControl.selectedSegment = 1
        case "up": positionControl.selectedSegment = 2
        default: positionControl.selectedSegment = 3
        }

        rebuildPeers()
        logTextView.string = model.logLines.joined(separator: "\n")
        if !model.logLines.isEmpty {
            logTextView.scrollRangeToVisible(NSRange(location: logTextView.string.count, length: 0))
        }
    }

    private func rebuildPeers() {
        for view in peersStack.arrangedSubviews {
            peersStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if model.peers.isEmpty {
            let empty = NSTextField(wrappingLabelWithString:
                "No USB bridge detected. Connect the OTi bridge cable.")
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = .secondaryLabelColor
            peersStack.addArrangedSubview(empty)
            return
        }
        for (index, peer) in model.peers.enumerated() {
            let name = NSTextField(labelWithString: peer.name)
            name.font = .systemFont(ofSize: 12)
            let subtitle = NSTextField(labelWithString: String(peer.id.prefix(8)))
            subtitle.font = .systemFont(ofSize: 9)
            subtitle.textColor = .tertiaryLabelColor
            let text = NSStackView(views: [name, subtitle])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 0

            let button: NSButton
            if model.connected?.id == peer.id {
                button = NSButton(title: "Disconnect", target: self, action: #selector(disconnectPeer))
            } else {
                button = NSButton(title: "Connect", target: self, action: #selector(connectPeer))
                button.isEnabled = model.connected == nil
            }
            button.bezelStyle = .rounded
            button.tag = index

            let icon = NSImageView(image: NSImage(systemSymbolName: "desktopcomputer",
                                                  accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = .secondaryLabelColor
            let row = NSStackView(views: [icon, text, NSView(), button])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            row.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
            row.wantsLayer = true
            row.layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.08).cgColor
            row.layer?.cornerRadius = 7
            peersStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: peersStack.widthAnchor).isActive = true
        }
    }

    // MARK: Actions

    @objc private func connectPeer(_ sender: NSButton) {
        guard model.peers.indices.contains(sender.tag) else { return }
        model.connect(to: model.peers[sender.tag])
    }

    @objc private func disconnectPeer() {
        model.disconnect()
    }

    @objc private func toggleKM() {
        model.toggleKM(kmCheck.state == .on)
    }

    @objc private func toggleClipboard() {
        model.toggleClipboard(clipCheck.state == .on)
    }

    @objc private func positionChanged() {
        let values = ["left", "right", "up", "down"]
        let index = positionControl.selectedSegment
        guard values.indices.contains(index) else { return }
        model.setPosition(values[index])
    }

    @objc private func openAccessibility() { model.requestAccessibility() }
    @objc private func checkAccessibility() { model.refreshPermission() }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var model: AppModel!
    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private var settingsController: SettingsWindowController?
    private let kmMenuItem = NSMenuItem(title: "Keyboard & mouse sharing", action: nil, keyEquivalent: "")
    private let clipboardMenuItem = NSMenuItem(title: "Clipboard sync", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = AppBrand.appIcon()
        model = AppModel()

        let controller = MainViewController(model: model)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "KMLink"
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 560, height: 640))
        window.minSize = NSSize(width: 520, height: 600)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "arrow.left.arrow.right.circle",
                                   accessibilityDescription: "KMLink")
        }
        let menu = NSMenu()
        menu.delegate = self
        let show = NSMenuItem(title: "Show KMLink", action: #selector(showWindow), keyEquivalent: "o")
        let send = NSMenuItem(title: "Send Files…", action: #selector(sendFiles), keyEquivalent: "f")
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        for item in [show, send, settings, quit] { item.target = self }
        kmMenuItem.target = self
        kmMenuItem.action = #selector(toggleKMFromMenu)
        clipboardMenuItem.target = self
        clipboardMenuItem.action = #selector(toggleClipboardFromMenu)
        menu.addItem(show)
        menu.addItem(.separator())
        menu.addItem(kmMenuItem)
        menu.addItem(clipboardMenuItem)
        menu.addItem(.separator())
        menu.addItem(send)
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(quit)
        statusItem.menu = menu

        NSApp.activate(ignoringOtherApps: true)
    }

    func menuWillOpen(_ menu: NSMenu) {
        if let first = menu.items.first {
            first.title = model.connected == nil ? "Show KMLink" : "Show KMLink — \(model.connected!.name)"
        }
        kmMenuItem.state = model.kmEnabled ? .on : .off
        clipboardMenuItem.state = model.clipboardEnabled ? .on : .off
    }

    @objc private func toggleKMFromMenu() {
        model.toggleKM(!model.kmEnabled)
    }

    @objc private func toggleClipboardFromMenu() {
        model.toggleClipboard(!model.clipboardEnabled)
    }

    @objc private func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(model: model)
        }
        settingsController?.showWindow(nil)
        settingsController?.window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func sendFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { model.sendFiles(panel.urls) }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = oti_hid_restore_mouse_defaults(nil)
        MouseScaling.restore()
    }
}
