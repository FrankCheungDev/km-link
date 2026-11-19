import Foundation
import AppKit
import CoreGraphics
import ApplicationServices
import Carbon

/// Captures local input through a CGEventTap and injects remote input with CGEvents.
final class KMEngine {
    private let stateLock = NSLock()
    private let tapLifecycleLock = NSLock()

    private var _enabled = true
    var enabled: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _enabled }
        set { stateLock.lock(); _enabled = newValue; stateLock.unlock() }
    }
    private var _canSwitch = false
    var canSwitch: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _canSwitch }
        set { stateLock.lock(); _canSwitch = newValue; stateLock.unlock() }
    }
    private var _usbMode = false
    var usbMode: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _usbMode }
        set { stateLock.lock(); _usbMode = newValue; stateLock.unlock() }
    }
    private var _peerPosition = "left"
    var peerPosition: String {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _peerPosition }
        set {
            stateLock.lock()
            _peerPosition = newValue
            usbReturnDirection = Self.returnDirection(from: 0, fallbackPeerPosition: newValue)
            stateLock.unlock()
        }
    }
    private var _edgeEnabled = true
    var edgeEnabled: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _edgeEnabled }
        set { stateLock.lock(); _edgeEnabled = newValue; stateLock.unlock() }
    }
    private var _middleButtonSwitch = false
    var middleButtonSwitch: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _middleButtonSwitch }
        set { stateLock.lock(); _middleButtonSwitch = newValue; stateLock.unlock() }
    }
    private var _hotCornerSwitch = false
    var hotCornerSwitch: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _hotCornerSwitch }
        set { stateLock.lock(); _hotCornerSwitch = newValue; stateLock.unlock() }
    }
    private var _edgeTolerance: CGFloat = 1
    var edgeTolerance: CGFloat {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _edgeTolerance }
        set { stateLock.lock(); _edgeTolerance = newValue; stateLock.unlock() }
    }
    /// Host mode: when the pointer leaves towards the peer, this Mac's software
    /// reads the local mouse and forwards it over the bridge. Off = only tell
    /// the peer "control is yours" and stay passive (useful when the physical
    /// mouse is attached to the peer / behind a hardware switch).
    private var _forwardLocalInput = true
    var forwardLocalInput: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _forwardLocalInput }
        set { stateLock.lock(); _forwardLocalInput = newValue; stateLock.unlock() }
    }
    private var _mouseSensitivity: Double = 1
    var mouseSensitivity: Double {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _mouseSensitivity }
        set { stateLock.lock(); _mouseSensitivity = newValue; stateLock.unlock() }
    }

    static let syntheticBypassUserData: Int64 = 0x4B4D4C4B

    var onEvent: ((KMEvent) -> Void)?
    var onRequestSwitchRemote: (() -> Void)?
    var onRequestUSBRemoteSwitch: ((CGPoint, Int, CGSize, UInt8) -> Void)?
    var onRequestSwitchLocal: (() -> Void)?
    var onUSBReturnEdge: ((CGPoint, Int) -> Void)?
    var onStatus: ((String) -> Void)?
    var onRemoteActiveChanged: ((Bool) -> Void)?
    var onControlled: (() -> Void)?
    /// Human readable notes about edge detection (throttled). Used to explain in
    /// the log why a mouse crossing did or did not fire.
    var onEdgeDiag: ((String) -> Void)?

    private var _controllingRemote = false
    private(set) var controllingRemote: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _controllingRemote }
        set { stateLock.lock(); _controllingRemote = newValue; stateLock.unlock() }
    }
    private var _beingControlled = false
    private(set) var beingControlled: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _beingControlled }
        set { stateLock.lock(); _beingControlled = newValue; stateLock.unlock() }
    }
    private var _usbSlaveActive = false
    private(set) var usbSlaveActive: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _usbSlaveActive }
        set { stateLock.lock(); _usbSlaveActive = newValue; stateLock.unlock() }
    }
    var isCaptureActive: Bool {
        tapLifecycleLock.lock()
        defer { tapLifecycleLock.unlock() }
        return tap != nil
    }
    var remoteActive: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _controllingRemote || _beingControlled || _usbSlaveActive
    }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?
    private var tapExitSemaphore: DispatchSemaphore?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var virtualCursor: CGPoint = .zero
    private var suppressSwitchUntil = Date.distantPast
    private var usbReturnDirection = 1
    private var hasLockedReturnDirection = false
    private var usbEdgeHitCount = 0
    private var edgeHitSince = Date.distantPast
    private var lastUSBReturnSentAt = Date.distantPast
    /// Last time the peer sent us a KM command. When the peer is an active KM
    /// partner it drives both directions itself; our own "walk back over the
    /// edge" fallback must stay quiet, otherwise the two state machines fight
    /// and the local pointer bounces to the screen centre.
    private var lastPeerKMCommandAt = Date.distantPast
    /// Accumulated outward travel while the pointer is clamped against the
    /// return edge. Reaching `returnPushThreshold` means the user is pushing
    /// through the border and wants control back.
    private var returnPush = 0
    /// Outward travel past the border, measured on the slave-mode virtual
    /// cursor, that gives control back. The real cursor cannot be used: while
    /// the peer is master it drives our pointer with absolute reports, so it
    /// teleports all over the screen (observed 664→19→1350 in one second).
    /// Edge based return: reaching the border and pushing through it is enough,
    /// no "move inside first" requirement. The teleport filter plus the dwell
    /// and push thresholds below already keep the entry position from counting
    /// as a return.
    static let returnPushThreshold = 30
    /// The pointer must travel inside the screen before "back at the edge" can
    /// mean "hand control back" — otherwise arriving on the entry point (which
    /// sits on the border) would immediately bounce back. This used to be
    /// 200 px, which made short trips near the edge impossible to return from;
    /// the teleport filter and the dwell/push thresholds already guard against
    /// the accidental trigger that the large value was protecting against.

    private var lastSlaveDiagAt = Date.distantPast
    private var lastOutwardAt = Date.distantPast
    /// Armed once the pointer has been well inside the screen during slave mode.
    private var edgeDwellSince = Date.distantPast
    /// Virtual cursor inside slave mode. The real cursor is unusable there: the
    /// peer positions it with absolute reports, so it teleports around the
    /// screen. Accumulating the relative deltas from the entry point gives the
    /// position the user actually means, and only then can "reached the edge"
    /// mean "take control back".
    private var slaveVirtualX: CGFloat = 0
    private var slaveVirtualY: CGFloat = 0
    private var lastEdgeDiagAt = Date.distantPast
    private var hidSendBlockedUntil = Date.distantPast
    /// While this Mac drives the other machine the local pointer must not roam:
    /// it is pinned to this point after every forwarded sample (the original
    /// daemon re-posts a stored warp event for the same reason).
    private var localPinPoint: CGPoint?
    private var lastHotKeyHandledAt = Date.distantPast
    private var dragSinkWindow: NSWindow?
    private var dragSinkHideWorkItem: DispatchWorkItem?

    deinit {
        stop()
    }

    // MARK: Permission

    static func hasAccessibility() -> Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: Lifecycle

    func start() {
        tapLifecycleLock.lock()
        if tap != nil || tapThread != nil {
            tapLifecycleLock.unlock()
            return
        }
        let eventTypes: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged, .mouseMoved,
            .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .scrollWheel
        ]
        let mask: CGEventMask = eventTypes.reduce(0) { $0 | (CGEventMask(1) << $1.rawValue) }

        let ready = DispatchSemaphore(value: 0)
        let exitSem = DispatchSemaphore(value: 0)
        var created = false
        let thread = Thread { [weak self] in
            guard let self else {
                ready.signal()
                exitSem.signal()
                return
            }
            let userInfo = Unmanaged.passUnretained(self).toOpaque()
            guard let createdTap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                                     place: .headInsertEventTap,
                                                     options: .defaultTap,
                                                     eventsOfInterest: mask,
                                                     callback: Self.tapCallback,
                                                     userInfo: userInfo) else {
                ready.signal()
                exitSem.signal()
                return
            }
            let rl = CFRunLoopGetCurrent()
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, createdTap, 0)
            self.tapLifecycleLock.lock()
            self.tap = createdTap
            self.runLoopSource = source
            self.tapRunLoop = rl
            self.tapExitSemaphore = exitSem
            self.tapLifecycleLock.unlock()

            CFRunLoopAddSource(rl, source, .commonModes)
            CGEvent.tapEnable(tap: createdTap, enable: true)
            created = true
            ready.signal()

            CFRunLoopRun()

            if let source { CFRunLoopRemoveSource(rl, source, .commonModes) }
            CFMachPortInvalidate(createdTap)
            self.tapLifecycleLock.lock()
            if self.tap === createdTap {
                self.tap = nil
                self.runLoopSource = nil
                self.tapRunLoop = nil
                self.tapThread = nil
                self.tapExitSemaphore = nil
            }
            self.tapLifecycleLock.unlock()
            exitSem.signal()
        }
        thread.name = "com.local.kmlink.eventtap"
        thread.qualityOfService = .userInteractive
        self.tapThread = thread
        tapLifecycleLock.unlock()

        thread.start()
        ready.wait()

        if !created {
            tapLifecycleLock.lock()
            self.tapThread = nil
            self.tapExitSemaphore = nil
            tapLifecycleLock.unlock()
            onStatus?("Accessibility permission is required for keyboard/mouse sharing")
            return
        }
        onStatus?("Keyboard/mouse capture active")
        if Thread.isMainThread {
            installHotKey()
        } else {
            DispatchQueue.main.async { [weak self] in self?.installHotKey() }
        }
    }

    func stop() {
        tapLifecycleLock.lock()
        let activeTap = tap
        let activeRL = tapRunLoop
        let exitSem = tapExitSemaphore
        tap = nil
        runLoopSource = nil
        tapRunLoop = nil
        tapThread = nil
        tapExitSemaphore = nil
        tapLifecycleLock.unlock()

        if let activeTap {
            CGEvent.tapEnable(tap: activeTap, enable: false)
        }
        if let activeRL {
            CFRunLoopStop(activeRL)
            _ = exitSem?.wait(timeout: .now() + 0.5)
        } else if let activeTap {
            CFMachPortInvalidate(activeTap)
        }

        let clearHotKey = {
            if let ref = self.hotKeyRef { UnregisterEventHotKey(ref) }
            self.hotKeyRef = nil
            if let handler = self.hotKeyHandler { RemoveEventHandler(handler) }
            self.hotKeyHandler = nil
        }
        if Thread.isMainThread {
            clearHotKey()
        } else {
            DispatchQueue.main.async(execute: clearHotKey)
        }
    }

    // MARK: Hotkey (Ctrl-Option-S)

    private func installHotKey() {
        guard hotKeyRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), Self.hotKeyCallback, 1, &eventType, userInfo, &hotKeyHandler)
        let hotKeyID = EventHotKeyID(signature: OSType(0x4B4D4C4B), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_S), UInt32(controlKey | optionKey), hotKeyID,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    private func hotKeyPressed() {
        stateLock.lock()
        let isSlave = _usbSlaveActive
        let retDir = usbReturnDirection
        let isControlling = _controllingRemote
        let isControlled = _beingControlled
        let allowedSwitch = _canSwitch
        stateLock.unlock()

        if isSlave {
            endUSBSlave(at: Self.currentCGMouseLocation(), direction: retDir, notifyPeer: true)
        } else if isControlling {
            endRemoteControl()
        } else if isControlled {
            endControlled()
        } else if allowedSwitch {
            beginRemoteControl()
        }
    }

    // MARK: Switching

    func beginRemoteControl(from edgePoint: CGPoint? = nil, isDragging: Bool = false) {
        let union = Self.cgScreenUnion()
        let fallbackCursor = edgePoint ?? Self.currentCGMouseLocation()

        stateLock.lock()
        guard _enabled, _canSwitch, !_controllingRemote else {
            stateLock.unlock()
            return
        }
        if _usbSlaveActive {
            _usbSlaveActive = false
        }
        let passiveHandover = _usbMode && !_forwardLocalInput
        if !passiveHandover {
            _controllingRemote = true
        }
        resetEdgeHitsLocked()
        suppressSwitchUntil = Date().addingTimeInterval(2.0)
        hidSendBlockedUntil = Date().addingTimeInterval(0.15)
        let cgCursor = fallbackCursor
        virtualCursor = cgCursor
        let dir = usbPeerDirectionLocked()
        let pin = Self.pinTargetPoint(at: cgCursor, direction: dir, union: union)
        let dragActive = isDragging || CGEventSource.buttonState(.combinedSessionState, button: .left)
        let initialButtons: UInt8 = dragActive ? 0x01 : 0
        let isUSB = _usbMode
        if isUSB && !passiveHandover {
            localPinPoint = pin
        }
        stateLock.unlock()

        if !passiveHandover { onRemoteActiveChanged?(true) }
        if isUSB {
            let relX = union.isNull ? Int(cgCursor.x.rounded()) : Int(max(0, min(union.width, cgCursor.x - union.minX)).rounded())
            let relY = union.isNull ? Int(cgCursor.y.rounded()) : Int(max(0, min(union.height, cgCursor.y - union.minY)).rounded())
            let mainBounds = CGDisplayBounds(CGMainDisplayID()).size
            let size = union.isNull ? (mainBounds.width > 0 ? mainBounds : CGSize(width: 1512, height: 982)) : union.size
            onRequestUSBRemoteSwitch?(CGPoint(x: relX, y: relY), dir, size, initialButtons)
            if passiveHandover {
                // Hand control to the peer and stay passive: no cursor pinning,
                // no event swallowing. The peer drives its own pointer.
                onRemoteActiveChanged?(false)
                onStatus?("Control handed to the other PC")
            } else {
                CGWarpMouseCursorPosition(pin)
                onStatus?("Controlling remote PC")
            }
        } else {
            onRequestSwitchRemote?()
            onStatus?("Controlling the other Mac")
        }
    }

    /// Terminates an active macOS Finder drag cleanly once the remote peer has
    /// acknowledged handoff, without releasing physical mouse tracking to the peer.
    func finishLocalDragCleanly() {
        DispatchQueue.main.async {
            guard CGEventSource.buttonState(.combinedSessionState, button: .left) else { return }
            let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
            guard mainHeight > 0 else { return }
            self.stateLock.lock()
            let pin = self.localPinPoint
            self.stateLock.unlock()
            let cgTarget = pin ?? Self.currentCGMouseLocation()
            let appKitCenter = NSPoint(x: cgTarget.x, y: mainHeight - cgTarget.y)
            let frame = NSRect(x: appKitCenter.x - 16, y: appKitCenter.y - 16, width: 32, height: 32)
            let sinkWindow: NSWindow
            if let existing = self.dragSinkWindow {
                sinkWindow = existing
                sinkWindow.setFrame(frame, display: false)
            } else {
                let win = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
                win.isOpaque = false
                win.backgroundColor = .clear
                win.alphaValue = 0.01
                win.level = .screenSaver
                win.hasShadow = false
                win.ignoresMouseEvents = false
                let sinkView = DragSinkView(frame: NSRect(origin: .zero, size: frame.size))
                win.contentView = sinkView
                self.dragSinkWindow = win
                sinkWindow = win
            }
            self.dragSinkHideWorkItem?.cancel()
            sinkWindow.orderFrontRegardless()

            if let dragEv = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged,
                                    mouseCursorPosition: cgTarget, mouseButton: .left) {
                dragEv.setIntegerValueField(.eventSourceUserData, value: Self.syntheticBypassUserData)
                dragEv.post(tap: .cghidEventTap)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) {
                if let upEv = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                      mouseCursorPosition: cgTarget, mouseButton: .left) {
                    upEv.setIntegerValueField(.eventSourceUserData, value: Self.syntheticBypassUserData)
                    upEv.post(tap: .cghidEventTap)
                }
            }
            let hideItem = DispatchWorkItem { [weak sinkWindow] in
                sinkWindow?.orderOut(nil)
            }
            self.dragSinkHideWorkItem = hideItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: hideItem)
        }
    }

    /// Records that the peer is an active KM partner (it sent us a KM command).
    func notePeerKMCommand() {
        stateLock.lock()
        lastPeerKMCommandAt = Date()
        stateLock.unlock()
    }

    func endRemoteControl(notifyPeer: Bool = true, warpTo warpPoint: CGPoint? = nil) {
        let union = Self.cgScreenUnion()
        stateLock.lock()
        guard _controllingRemote else {
            stateLock.unlock()
            return
        }
        _controllingRemote = false
        let pinBeforeClear = localPinPoint
        localPinPoint = nil
        usbEdgeHitCount = 0
        suppressSwitchUntil = Date().addingTimeInterval(0.8)
        let targetWarp: CGPoint?
        if let warpPoint {
            targetWarp = warpPoint
            virtualCursor = warpPoint
        } else if _usbMode {
            let fallback = fallbackEdgeReturnPointLocked(union: union, pin: pinBeforeClear)
            if fallback != .zero {
                targetWarp = fallback
                virtualCursor = fallback
            } else {
                targetWarp = nil
            }
        } else {
            targetWarp = nil
        }
        let isUSB = _usbMode
        stateLock.unlock()

        if let targetWarp { CGWarpMouseCursorPosition(targetWarp) }
        if notifyPeer { onRequestSwitchLocal?() }
        onRemoteActiveChanged?(false)
        onStatus?(isUSB ? "Connected to USB bridge" : "Back on this Mac")
    }

    func beginControlled() {
        let center = Self.cgScreenUnion().center
        stateLock.lock()
        guard !_beingControlled else {
            stateLock.unlock()
            return
        }
        _beingControlled = true
        virtualCursor = center
        stateLock.unlock()
        onRemoteActiveChanged?(true)
        onControlled?()
    }

    func endControlled(notifyPeer: Bool = true) {
        stateLock.lock()
        guard _beingControlled else {
            stateLock.unlock()
            return
        }
        _beingControlled = false
        stateLock.unlock()
        if notifyPeer { onRequestSwitchLocal?() }
        onRemoteActiveChanged?(false)
    }

    func beginUSBSlave(from info: KMSwitchMoveOutInfo) {
        let union = Self.cgScreenUnion()
        let entry = Self.entryPoint(from: info, in: union)
        stateLock.lock()
        lastPeerKMCommandAt = Date()
        if _controllingRemote {
            _controllingRemote = false
        }
        localPinPoint = nil
        virtualCursor = entry
        if (1...4).contains(info.direction) {
            hasLockedReturnDirection = true
        }
        usbReturnDirection = Self.returnDirection(from: info.direction, fallbackPeerPosition: _peerPosition)
        _usbSlaveActive = true
        returnPush = 0
        slaveVirtualX = entry.x
        slaveVirtualY = entry.y
        resetEdgeHitsLocked()
        edgeDwellSince = .distantPast
        lastSlaveDiagAt = .distantPast
        lastUSBReturnSentAt = Date.distantPast
        suppressSwitchUntil = Date().addingTimeInterval(1.5)
        stateLock.unlock()

        CGWarpMouseCursorPosition(entry)
        onRemoteActiveChanged?(true)
        onControlled?()
    }

    /// Hands control back to the peer while we are the master.
    func endMasterForHandBack(localY: CGFloat) {
        let union = Self.cgScreenUnion()
        stateLock.lock()
        guard _controllingRemote else {
            stateLock.unlock()
            return
        }
        _controllingRemote = false
        localPinPoint = nil
        usbEdgeHitCount = 0
        suppressSwitchUntil = Date().addingTimeInterval(0.8)
        let base = union.isNull ? CGPoint(x: 0, y: localY) : CGPoint(x: union.minX, y: localY)
        let pin = Self.pinTargetPoint(at: base, direction: usbPeerDirectionLocked(), union: union)
        virtualCursor = pin
        let isUSB = _usbMode
        stateLock.unlock()

        CGWarpMouseCursorPosition(pin)
        onRemoteActiveChanged?(false)
        onStatus?(isUSB ? "Connected to USB bridge" : "Back on this Mac")
    }

    func requestUSBHandBack() {
        let union = Self.cgScreenUnion()
        stateLock.lock()
        guard _controllingRemote else {
            stateLock.unlock()
            return
        }
        let pin = localPinPoint ?? fallbackEdgeReturnPointLocked(union: union)
        let dir = usbPeerDirectionLocked()
        stateLock.unlock()

        var point = pin
        if !union.isNull {
            point = CGPoint(x: min(max(pin.x, union.minX), union.maxX),
                            y: min(max(pin.y, union.minY), union.maxY))
        }
        endRemoteControl(notifyPeer: false)
        onUSBReturnEdge?(point, dir)
    }

    /// Leaves slave mode.
    func endUSBSlave(at point: CGPoint, direction: Int, notifyPeer: Bool = true,
                     becomeMaster: Bool = false) {
        let union = Self.cgScreenUnion()
        var exitPoint = point
        if !union.isNull {
            exitPoint = CGPoint(x: min(max(point.x, union.minX), union.maxX),
                                y: min(max(point.y, union.minY), union.maxY))
        }
        stateLock.lock()
        _usbSlaveActive = false
        resetEdgeHitsLocked()
        edgeDwellSince = .distantPast
        returnPush = 0
        lastUSBReturnSentAt = Date()
        suppressSwitchUntil = Date().addingTimeInterval(2.0)
        var masterPin: CGPoint?
        if becomeMaster {
            _controllingRemote = true
            hidSendBlockedUntil = Date().addingTimeInterval(0.15)
            let pin = Self.pinTargetPoint(at: exitPoint, direction: usbPeerDirectionLocked(), union: union)
            localPinPoint = pin
            virtualCursor = pin
            masterPin = pin
        }
        stateLock.unlock()

        if notifyPeer {
            onUSBReturnEdge?(exitPoint, direction)
        }
        if let masterPin {
            CGWarpMouseCursorPosition(masterPin)
            onRemoteActiveChanged?(true)
            onStatus?("Controlling remote PC")
            diag("return edge hit at virtual \(Int(exitPoint.x)),\(Int(exitPoint.y)) dir=\(direction) -> back to remote master")
        } else {
            onRemoteActiveChanged?(false)
            onStatus?("Connected to USB bridge")
        }
    }

    /// Point the local pointer is pinned to while the Mac controls the peer.
    ///
    /// It has to sit where the pointer left the Mac (the edge towards the other
    /// machine) so the cursor does not visibly jump to the middle of the screen;
    /// a 2 pt inset keeps it off hot corners and screen edges.
    static func pinTargetPoint(at exitPoint: CGPoint?, direction: Int, union: CGRect = cgScreenUnion()) -> CGPoint {
        let inset: CGFloat = 2
        if let exitPoint {
            let limit = union.isNull ? CGRect(x: 0, y: 0, width: 1512, height: 982) : union
            var x = exitPoint.x
            switch direction {
            case 1: x = limit.minX + inset          // left edge
            case 2: x = limit.maxX - inset          // right edge
            default: break
            }
            let y = min(max(exitPoint.y, limit.minY + inset), limit.maxY - inset)
            return CGPoint(x: x, y: y)
        }
        // No exit point: park on the edge towards the peer rather than in the
        // middle of the screen, which used to look like the pointer "jumping"
        // to the centre right after a takeover.
        guard !union.isNull else { return CGPoint(x: 700, y: 400) }
        switch direction {
        case 1: return CGPoint(x: union.minX + inset, y: union.midY)
        case 2: return CGPoint(x: union.maxX - inset, y: union.midY)
        case 3: return CGPoint(x: union.midX, y: union.minY + inset)
        case 4: return CGPoint(x: union.midX, y: union.maxY - inset)
        default: return union.center
        }
    }

    private func resetEdgeHitsLocked() {
        usbEdgeHitCount = 0
        edgeHitSince = .distantPast
    }

    private func diag(_ text: String) {
        // Keep the log readable: at most one diagnostic line per second.
        let now = Date()
        stateLock.lock()
        guard now.timeIntervalSince(lastEdgeDiagAt) >= 1.0 else {
            stateLock.unlock()
            return
        }
        lastEdgeDiagAt = now
        stateLock.unlock()
        onEdgeDiag?(text)
    }

    /// True when `point` sits on the screen edge facing the peer and the sample
    /// moved further outwards. Pure so the self-test can cover it.
    static func edgeIsOutward(peerPosition: String,
                              point: CGPoint,
                              dx: CGFloat,
                              dy: CGFloat,
                              union: CGRect,
                              tolerance: CGFloat) -> Bool {
        guard !union.isNull, union.width > 0, union.height > 0 else { return false }
        // The OTi bridge itself relays the physical mouse, so when the pointer
        // reaches the border macOS can sit a few pixels short of it and report a
        // zero delta. Require "at the edge and not moving away" instead of a
        // strictly negative delta, and give the border a wider tolerance.
        let margin = max(tolerance, 6)
        switch peerPosition {
        case "left":  return point.x <= union.minX + margin && dx <= 0
        case "right": return point.x >= union.maxX - margin && dx >= 0
        case "up":    return point.y <= union.minY + margin && dy <= 0
        case "down":  return point.y >= union.maxY - margin && dy >= 0
        default:      return false
        }
    }

    /// Counts outward edge samples. The original daemon cross-checks twice
    /// ("secondcheckswitch"/"Second check ok!"), so require two samples that are
    /// close in time instead of three strictly consecutive events; cursor
    /// jitter between two samples no longer swallows the crossing.
    private func accumulateEdgeHitLocked() -> Bool {
        let now = Date()
        if now.timeIntervalSince(edgeHitSince) > 0.4 {
            usbEdgeHitCount = 0
        }
        if usbEdgeHitCount == 0 { edgeHitSince = now }
        usbEdgeHitCount += 1
        return usbEdgeHitCount >= 2
    }

    static func entryPoint(from info: KMSwitchMoveOutInfo, in union: CGRect = cgScreenUnion()) -> CGPoint {
        guard !union.isNull, union.width > 0, union.height > 0 else { return .zero }
        let rx: CGFloat = info.remoteWidth > 0
            ? min(max(CGFloat(info.moveOutX) / CGFloat(info.remoteWidth), 0), 1)
            : 0.5
        let ry: CGFloat = info.remoteHeight > 0
            ? min(max(CGFloat(info.moveOutY) / CGFloat(info.remoteHeight), 0), 1)
            : 0.5
        let inset: CGFloat = 3
        switch info.direction {
        case 1: // Remote exited left -> enter Mac right edge
            return CGPoint(x: union.maxX - inset, y: union.minY + ry * union.height)
        case 2: // Remote exited right -> enter Mac left edge
            return CGPoint(x: union.minX + inset, y: union.minY + ry * union.height)
        case 3: // Remote exited top -> enter Mac bottom edge
            return CGPoint(x: union.minX + rx * union.width, y: union.maxY - inset)
        case 4: // Remote exited bottom -> enter Mac top edge
            return CGPoint(x: union.minX + rx * union.width, y: union.minY + inset)
        default:
            return union.center
        }
    }

    static func returnDirection(from moveOutDirection: Int, fallbackPeerPosition: String) -> Int {
        switch moveOutDirection {
        case 1: return 2
        case 2: return 1
        case 3: return 4
        case 4: return 3
        default:
            switch fallbackPeerPosition {
            case "left": return 1
            case "right": return 2
            case "up": return 3
            case "down": return 4
            default: return 1
            }
        }
    }

    // MARK: Local capture

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            tapLifecycleLock.lock()
            let activeTap = tap
            tapLifecycleLock.unlock()
            if let activeTap { CGEvent.tapEnable(tap: activeTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticBypassUserData {
            return Unmanaged.passUnretained(event)
        }

        stateLock.lock()
        let isEnabled = _enabled
        guard isEnabled else {
            stateLock.unlock()
            return Unmanaged.passUnretained(event)
        }

        // The Carbon hotkey never reaches the app while we are driving the other
        // machine (the session tap consumes keyboard events first and forwards
        // them), so recognise the same chord here and swallow it.
        if (type == .keyDown || type == .keyUp),
           event.getIntegerValueField(.keyboardEventKeycode) == 1,
           event.flags.contains(.maskControl),
           event.flags.contains(.maskAlternate) {
            var triggerHotkey = false
            if type == .keyDown, Date().timeIntervalSince(lastHotKeyHandledAt) > 0.3 {
                lastHotKeyHandledAt = Date()
                triggerHotkey = true
            }
            stateLock.unlock()
            if triggerHotkey {
                diag("hotkey ctrl+opt+S handled inside the tap")
                hotKeyPressed()
            }
            return nil
        }

        if _usbSlaveActive {
            let watchReturn = _edgeEnabled &&
                (type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged)
            let location = watchReturn ? event.location : .zero
            var returnResult: (triggerEnd: (point: CGPoint, direction: Int)?, diagText: String?) = (nil, nil)
            if watchReturn {
                stateLock.unlock()
                let union = Self.cgScreenUnion()
                stateLock.lock()
                if _usbSlaveActive {
                    returnResult = checkUSBReturnEdgeLocked(point: location, event: event, union: union)
                }
            }
            let becomeMaster = _forwardLocalInput && _canSwitch
            stateLock.unlock()
            if let text = returnResult.diagText { diag(text) }
            if let endInfo = returnResult.triggerEnd {
                endUSBSlave(at: endInfo.point, direction: endInfo.direction, notifyPeer: true, becomeMaster: becomeMaster)
            }
            return Unmanaged.passUnretained(event)
        }

        if _controllingRemote {
            let blockedUntil = hidSendBlockedUntil
            let sens = _mouseSensitivity
            let pin = localPinPoint
            stateLock.unlock()
            if var payload = Self.payload(type: type, event: event) {
                if payload.kind == "mouseMoved" || payload.kind == "mouseDragged" {
                    let dx = payload.dx ?? 0
                    let dy = payload.dy ?? 0
                    if dx == 0 && dy == 0 { return nil }
                    if Date() < blockedUntil { return nil }
                    payload.dx = dx * sens
                    payload.dy = dy * sens
                    if let pin {
                        CGWarpMouseCursorPosition(pin)
                    }
                }
                onEvent?(payload)
            }
            return nil
        }

        let allowedSwitch = _canSwitch
        let midBtn = _middleButtonSwitch
        let hotCorner = _hotCornerSwitch
        let edgeOn = _edgeEnabled
        let controlled = _beingControlled
        let isUSB = _usbMode
        stateLock.unlock()

        if allowedSwitch, midBtn, type == .otherMouseDown,
           event.getIntegerValueField(.mouseEventButtonNumber) == 2 {
            beginRemoteControl()
            return nil
        }

        if allowedSwitch, hotCorner, type == .leftMouseDown, isInHotCorner(event.location) {
            beginRemoteControl()
            return nil
        }

        if edgeOn, allowedSwitch, !controlled,
           type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged {
            let location = event.location
            let union = Self.cgScreenUnion()
            if isUSB {
                stateLock.lock()
                let enterRes = checkUSBEnterEdgeLocked(point: location, event: event, union: union)
                stateLock.unlock()
                if let text = enterRes.diagText { diag(text) }
                if enterRes.entered {
                    beginRemoteControl(from: location, isDragging: type == .leftMouseDragged)
                    return nil
                }
            } else {
                stateLock.lock()
                let should = shouldSwitchLocked(at: location, event: event, union: union)
                stateLock.unlock()
                if should {
                    beginRemoteControl()
                    return nil
                }
            }
        }

        return Unmanaged.passUnretained(event)
    }

    private func usbPeerDirectionLocked() -> Int {
        switch _peerPosition {
        case "left":  return 1
        case "right": return 2
        case "up":    return 3
        case "down":  return 4
        default:      return 1
        }
    }

    private func fallbackEdgeReturnPointLocked(union: CGRect, pin: CGPoint? = nil) -> CGPoint {
        guard !union.isNull else { return .zero }
        let clampedY = pin.map { min(max($0.y, union.minY + 12), union.maxY - 12) } ?? union.midY
        let clampedX = pin.map { min(max($0.x, union.minX + 12), union.maxX - 12) } ?? union.midX
        switch _peerPosition {
        case "left":  return CGPoint(x: union.minX + 12, y: clampedY)
        case "right": return CGPoint(x: union.maxX - 12, y: clampedY)
        case "up":    return CGPoint(x: clampedX, y: union.minY + 12)
        case "down":  return CGPoint(x: clampedX, y: union.maxY - 12)
        default:      return union.center
        }
    }

    private func checkUSBEnterEdgeLocked(point: CGPoint, event: CGEvent, union: CGRect) -> (entered: Bool, diagText: String?) {
        let now = Date()
        guard now > suppressSwitchUntil else {
            resetEdgeHitsLocked()
            return (false, nil)
        }
        guard !union.isNull else { return (false, nil) }
        let dx = event.getIntegerValueField(.mouseEventDeltaX)
        let dy = event.getIntegerValueField(.mouseEventDeltaY)
        let hit = Self.edgeIsOutward(peerPosition: _peerPosition, point: point,
                                     dx: CGFloat(dx), dy: CGFloat(dy),
                                     union: union, tolerance: _edgeTolerance)
        if hit {
            if accumulateEdgeHitLocked() {
                resetEdgeHitsLocked()
                return (true, "edge crossing to remote: peer=\(_peerPosition) at \(Int(point.x)),\(Int(point.y)) delta=\(dx),\(dy)")
            }
            return (false, nil)
        }
        var diagText: String?
        if abs(point.x - union.minX) < 2 || abs(point.x - union.maxX) < 2 ||
            abs(point.y - union.minY) < 2 || abs(point.y - union.maxY) < 2 {
            diagText = "at screen edge but delta \(dx),\(dy) is not outward for peer=\(_peerPosition)"
        }
        resetEdgeHitsLocked()
        return (false, diagText)
    }

    private func checkUSBReturnEdgeLocked(
        point: CGPoint, event: CGEvent, union: CGRect
    ) -> (triggerEnd: (point: CGPoint, direction: Int)?, diagText: String?) {
        let now = Date()
        guard now > suppressSwitchUntil,
              now.timeIntervalSince(lastUSBReturnSentAt) >= 0.6 else {
            resetEdgeHitsLocked()
            return (nil, nil)
        }
        guard !union.isNull else { return (nil, nil) }
        let margin = max(_edgeTolerance, 10)
        let rawDX = CGFloat(event.getIntegerValueField(.mouseEventDeltaX))
        let rawDY = CGFloat(event.getIntegerValueField(.mouseEventDeltaY))
        if abs(rawDX) > 100 || abs(rawDY) > 100 || (rawDX == 0 && rawDY == 0) {
            resetEdgeHitsLocked()
            return (nil, nil)
        }
        let dx = rawDX
        let dy = rawDY
        slaveVirtualX = min(max(slaveVirtualX + dx, union.minX - 200), union.maxX + 200)
        slaveVirtualY = min(max(slaveVirtualY + dy, union.minY - 200), union.maxY + 200)
        var outward: CGFloat = 0
        switch usbReturnDirection {
        case 1: outward = -dx
        case 2: outward = dx
        case 3: outward = -dy
        case 4: outward = dy
        default: outward = 0
        }
        let realDistance: CGFloat
        switch usbReturnDirection {
        case 1: realDistance = point.x - union.minX
        case 2: realDistance = union.maxX - point.x
        case 3: realDistance = point.y - union.minY
        case 4: realDistance = union.maxY - point.y
        default: realDistance = 0
        }
        let atEdge = realDistance <= margin
        if !atEdge {
            edgeDwellSince = Date.distantPast
        } else if edgeDwellSince == Date.distantPast {
            edgeDwellSince = now
        }
        let edgeDwell = atEdge ? now.timeIntervalSince(edgeDwellSince) : 0
        if !atEdge {
            returnPush = 0
            resetEdgeHitsLocked()
            return (nil, nil)
        }
        if edgeDwell < 0.15 {
            resetEdgeHitsLocked()
            return (nil, nil)
        }
        if outward > 0 {
            returnPush += Int(outward.rounded())
        } else {
            returnPush = max(0, returnPush + Int(outward.rounded()))
        }
        var diagText: String?
        if now.timeIntervalSince(lastSlaveDiagAt) > 0.25 {
            lastSlaveDiagAt = now
            diagText = "slave probe: v=\(Int(slaveVirtualX)),\(Int(slaveVirtualY)) d=\(Int(dx)),\(Int(dy)) edge=\(atEdge) dwell=\(String(format: "%.2f", edgeDwell)) push=\(returnPush)/\(Self.returnPushThreshold)"
        }
        guard returnPush >= Self.returnPushThreshold else {
            resetEdgeHitsLocked()
            return (nil, diagText)
        }
        if accumulateEdgeHitLocked() {
            returnPush = 0
            resetEdgeHitsLocked()
            return ((point: point, direction: usbReturnDirection),
                    "return edge: net outward travel reached \(Self.returnPushThreshold)px -> back to remote master")
        }
        return (nil, diagText)
    }

    private func shouldSwitchLocked(at point: CGPoint, event: CGEvent, union: CGRect) -> Bool {
        guard Date() > suppressSwitchUntil else { return false }
        guard !union.isNull else { return false }
        let dx = event.getIntegerValueField(.mouseEventDeltaX)
        let dy = event.getIntegerValueField(.mouseEventDeltaY)
        return Self.edgeIsOutward(peerPosition: _peerPosition, point: point,
                                  dx: CGFloat(dx), dy: CGFloat(dy),
                                  union: union, tolerance: _edgeTolerance)
    }

    // MARK: Remote injection

    func applyRemote(_ payload: KMEvent) {
        let union = Self.cgScreenUnion()
        stateLock.lock()
        guard _beingControlled else {
            stateLock.unlock()
            return
        }
        if virtualCursor == .zero {
            virtualCursor = Self.currentCGMouseLocation()
        }
        let curCursor = virtualCursor
        let peerPos = _peerPosition
        stateLock.unlock()

        let source = CGEventSource(stateID: .hidSystemState)
        switch payload.kind {
        case "keyDown", "keyUp":
            guard let keyCode = payload.keyCode else { return }
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode,
                                keyDown: payload.down ?? (payload.kind == "keyDown"))
            if let flags = payload.flags { event?.flags = CGEventFlags(rawValue: flags) }
            event?.post(tap: .cghidEventTap)
        case "flags":
            guard let keyCode = payload.keyCode else { return }
            let event = CGEvent(source: source)
            event?.type = .flagsChanged
            event?.setIntegerValueField(.keyboardEventKeycode, value: Int64(keyCode))
            if let flags = payload.flags { event?.flags = CGEventFlags(rawValue: flags) }
            event?.post(tap: .cghidEventTap)
        case "mouseMoved", "mouseDragged":
            var next = CGPoint(x: curCursor.x + (payload.dx ?? 0),
                               y: curCursor.y + (payload.dy ?? 0))
            next.x = min(max(next.x, union.minX + 1), union.maxX - 1)
            next.y = min(max(next.y, union.minY + 1), union.maxY - 1)
            stateLock.lock()
            virtualCursor = next
            stateLock.unlock()
            let dragging = payload.kind == "mouseDragged" || (payload.button ?? 0) >= 1
            let type: CGEventType = dragging ? .leftMouseDragged : .mouseMoved
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: next, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            CGWarpMouseCursorPosition(next)
            checkReturnEdge(point: next, union: union, peerPos: peerPos)
        case "mouseDown", "mouseUp":
            var cursor = curCursor
            if let nx = payload.nx, let ny = payload.ny, union.width > 0, union.height > 0 {
                cursor = CGPoint(x: union.minX + CGFloat(nx) * union.width,
                                 y: union.minY + CGFloat(ny) * union.height)
                stateLock.lock()
                virtualCursor = cursor
                stateLock.unlock()
            }
            let button = payload.button ?? 0
            let type: CGEventType
            if payload.kind == "mouseDown" {
                type = button == 1 ? .rightMouseDown : button == 0 ? .leftMouseDown : .otherMouseDown
            } else {
                type = button == 1 ? .rightMouseUp : button == 0 ? .leftMouseUp : .otherMouseUp
            }
            let cgButton: CGMouseButton = button == 1 ? .right : button == 0 ? .left : .center
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: cursor, mouseButton: cgButton)?
                .post(tap: .cghidEventTap)
        case "scroll":
            if let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                   wheel1: payload.scrollY ?? 0, wheel2: payload.scrollX ?? 0, wheel3: 0) {
                event.location = curCursor
                event.post(tap: .cghidEventTap)
            }
        default:
            break
        }
    }

    private func isInHotCorner(_ point: CGPoint) -> Bool {
        let union = Self.cgScreenUnion()
        guard !union.isNull else { return false }
        let size: CGFloat = 24
        return CGRect(x: union.minX, y: union.minY, width: size, height: size).contains(point)
    }

    private func checkReturnEdge(point: CGPoint, union: CGRect, peerPos: String) {
        let margin: CGFloat = 1.5
        let shouldReturn: Bool
        switch peerPos {
        case "left":  shouldReturn = point.x <= union.minX + margin
        case "right": shouldReturn = point.x >= union.maxX - margin
        case "up":    shouldReturn = point.y <= union.minY + margin
        case "down":  shouldReturn = point.y >= union.maxY - margin
        default:      shouldReturn = false
        }
        if shouldReturn {
            endControlled(notifyPeer: true)
            stateLock.lock()
            suppressSwitchUntil = Date().addingTimeInterval(0.6)
            stateLock.unlock()
        }
    }

    // MARK: Event conversion

    static func payload(type: CGEventType, event: CGEvent) -> KMEvent? {
        switch type {
        case .keyDown, .keyUp:
            return KMEvent(kind: type == .keyDown ? "keyDown" : "keyUp",
                           keyCode: UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode)),
                           flags: event.flags.rawValue,
                           down: type == .keyDown)
        case .flagsChanged:
            let keyCode = UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode))
            return KMEvent(kind: "flags", keyCode: keyCode, flags: event.flags.rawValue, down: nil)
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return KMEvent(kind: type == .mouseMoved ? "mouseMoved" : "mouseDragged",
                           dx: Double(event.getIntegerValueField(.mouseEventDeltaX)),
                           dy: Double(event.getIntegerValueField(.mouseEventDeltaY)),
                           button: type == .rightMouseDragged ? 1 : 0)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let button = type == .rightMouseDown ? 1
                : (type == .otherMouseDown ? Int(event.getIntegerValueField(.mouseEventButtonNumber)) : 0)
            let norm = normalized(event.location)
            return KMEvent(kind: "mouseDown", nx: norm.x, ny: norm.y, button: button)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            let button = type == .rightMouseUp ? 1
                : (type == .otherMouseUp ? Int(event.getIntegerValueField(.mouseEventButtonNumber)) : 0)
            let norm = normalized(event.location)
            return KMEvent(kind: "mouseUp", nx: norm.x, ny: norm.y, button: button)
        case .scrollWheel:
            return KMEvent(kind: "scroll",
                           scrollX: Int32(clamping: event.getIntegerValueField(.scrollWheelEventDeltaAxis2)),
                           scrollY: Int32(clamping: event.getIntegerValueField(.scrollWheelEventDeltaAxis1)))
        default:
            return nil
        }
    }

    static func normalized(_ point: CGPoint) -> (x: Double, y: Double) {
        let union = cgScreenUnion()
        guard union.width > 0, union.height > 0 else { return (0.5, 0.5) }
        return (Double((point.x - union.minX) / union.width),
                Double((point.y - union.minY) / union.height))
    }

    static func currentCGMouseLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    static func cgPoint(fromAppKit point: CGPoint) -> CGPoint {
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CGPoint(x: point.x, y: mainHeight - point.y)
    }

    static func cgScreenUnion() -> CGRect {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return .null }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return .null }
        var union = CGRect.null
        for id in ids.prefix(Int(count)) {
            union = union.union(CGDisplayBounds(id))
        }
        return union
    }

    // MARK: C callbacks

    private static let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let engine = Unmanaged<KMEngine>.fromOpaque(refcon).takeUnretainedValue()
        return engine.handle(type: type, event: event)
    }

    private static let hotKeyCallback: EventHandlerUPP = { _, _, userInfo in
        guard let userInfo else { return noErr }
        let engine = Unmanaged<KMEngine>.fromOpaque(userInfo).takeUnretainedValue()
        engine.hotKeyPressed()
        return noErr
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

private final class DragSinkView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        true
    }
}
