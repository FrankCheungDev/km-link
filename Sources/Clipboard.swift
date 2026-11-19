import Foundation
import AppKit

/// Watches the local pasteboard and mirrors it to the connected peer.
final class ClipboardSync {
    private let node: LinkNode
    private let queue = DispatchQueue(label: "com.local.kmlink.clipboard")
    private let stateLock = NSLock()
    private var timer: DispatchSourceTimer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var applyingRemote = false
    private var running = false
    private var _enabled = true
    private var _sendEnabled = true
    private var _receiveEnabled = true

    /// Master switch for the feature.
    var enabled: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _enabled }
        set {
            stateLock.lock()
            _enabled = newValue
            stateLock.unlock()
            if newValue {
                queue.async { [weak self] in
                    guard let self else { return }
                    let count = NSPasteboard.general.changeCount
                    self.stateLock.lock()
                    self.lastChangeCount = count
                    self.stateLock.unlock()
                }
            }
        }
    }
    var sendEnabled: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _sendEnabled }
        set { stateLock.lock(); _sendEnabled = newValue; stateLock.unlock() }
    }
    var receiveEnabled: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _receiveEnabled }
        set { stateLock.lock(); _receiveEnabled = newValue; stateLock.unlock() }
    }
    var onLog: ((String) -> Void)?

    init(node: LinkNode) {
        self.node = node
    }

    func start() {
        stateLock.lock()
        guard !running else {
            stateLock.unlock()
            return
        }
        running = true
        lastChangeCount = NSPasteboard.general.changeCount
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.4, repeating: 0.4)
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer
        stateLock.unlock()
        timer.resume()
    }

    func stop() {
        stateLock.lock()
        running = false
        let t = timer
        timer = nil
        stateLock.unlock()
        t?.cancel()
    }

    private func poll() {
        stateLock.lock()
        let isEnabled = _enabled && _sendEnabled
        let busyApplying = applyingRemote
        let prevChange = lastChangeCount
        stateLock.unlock()
        guard isEnabled, !busyApplying, node.hasConnectedPeer else { return }

        let pasteboard = NSPasteboard.general
        #if compiler(>=6.1)
        if #available(macOS 15.4, *), pasteboard.accessBehavior == .alwaysDeny {
            return
        }
        #endif
        let change = pasteboard.changeCount
        guard change != prevChange else { return }
        stateLock.lock()
        lastChangeCount = change
        stateLock.unlock()

        guard let message = Self.capture(from: pasteboard) else { return }
        node.send(message)
        onLog?("Clipboard sent")
    }

    static func capture(from pasteboard: NSPasteboard) -> WireMessage? {
        let fileURLs = USBLink.readFileURLs(from: pasteboard)
        if !fileURLs.isEmpty {
            return capture(fileURLs: fileURLs, changeCount: pasteboard.changeCount)
        }
        guard let types = pasteboard.types, !types.isEmpty else { return nil }
        let png = types.contains(.png)
            ? pasteboard.data(forType: .png).flatMap { $0.count < 8_000_000 ? $0 : nil }
            : nil
        let tiff = (png == nil && types.contains(.tiff))
            ? pasteboard.data(forType: .tiff).flatMap { $0.count < 8_000_000 ? $0 : nil }
            : nil
        let rtf = types.contains(.rtf)
            ? pasteboard.data(forType: .rtf).flatMap { $0.count < 2_000_000 ? $0 : nil }
            : nil
        let html = types.contains(.html)
            ? pasteboard.data(forType: .html).flatMap { $0.count < 2_000_000 ? $0 : nil }
            : nil
        let text = types.contains(.string) ? pasteboard.string(forType: .string) : nil
        return capture(fileURLs: [], png: png, tiff: tiff, rtf: rtf, html: html, text: text,
                       changeCount: pasteboard.changeCount)
    }

    static func capture(fileURLs: [URL], png: Data? = nil, tiff: Data? = nil,
                        rtf: Data? = nil, html: Data? = nil, text: String? = nil,
                        changeCount: Int = 0) -> WireMessage? {
        var message = WireMessage(type: MessageType.clipboard.rawValue,
                                  deviceID: AppSettings.shared.deviceID,
                                  deviceName: AppSettings.shared.displayName,
                                  clipboardChange: changeCount)

        if !fileURLs.isEmpty {
            let files = fileURLs.filter { url in
                guard url.isFileURL else { return false }
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                return !isDir
            }
            guard !files.isEmpty else { return nil }
            message.filePaths = files.map(\.path)
            return message
        }

        message.png = png
        if png == nil { message.tiff = tiff }
        message.rtf = rtf
        message.html = html
        message.text = text
        if message.png == nil, message.tiff == nil, message.rtf == nil, message.html == nil, message.text == nil {
            return nil
        }
        return message
    }

    private func performRemoteWrite(_ work: @escaping (NSPasteboard) -> Bool, onSuccess: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let canReceive = self._enabled && self._receiveEnabled
            if canReceive { self.applyingRemote = true }
            self.stateLock.unlock()
            guard canReceive else { return }
            defer {
                self.stateLock.lock()
                self.applyingRemote = false
                self.stateLock.unlock()
            }

            let pasteboard = NSPasteboard.general
            guard work(pasteboard) else { return }
            let updatedCount = pasteboard.changeCount
            self.stateLock.lock()
            self.lastChangeCount = updatedCount
            self.stateLock.unlock()
            onSuccess?()
        }
    }

    func applyRemote(_ message: WireMessage) {
        performRemoteWrite({ pasteboard in
            pasteboard.clearContents()
            var wrote = false
            if let png = message.png, let image = NSImage(data: png) {
                pasteboard.writeObjects([image])
                wrote = true
            } else if let tiff = message.tiff, let image = NSImage(data: tiff) {
                pasteboard.writeObjects([image])
                wrote = true
            }
            if let rtf = message.rtf {
                pasteboard.setData(rtf, forType: .rtf)
                wrote = true
            }
            if let html = message.html {
                pasteboard.setData(html, forType: .html)
                wrote = true
            }
            if let text = message.text {
                pasteboard.setString(text, forType: .string)
                wrote = true
            }
            return wrote
        }, onSuccess: { [weak self] in
            self?.onLog?("Clipboard received")
        })
    }

    func applyRemoteFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        performRemoteWrite { pasteboard in
            pasteboard.clearContents()
            pasteboard.writeObjects(urls as [NSURL])
            return true
        }
    }
}
