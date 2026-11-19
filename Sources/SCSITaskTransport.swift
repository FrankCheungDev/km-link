// SCSITaskTransport.swift
// Native arm64 user-space OTITransport backed by Apple's SCSITaskLib.plugin
// via SCSITaskShim.c. Requires no DriverKit entitlement and no Rosetta.

import Foundation

public struct OTIBlockAssembler {
    private struct Partial {
        let total: Int
        var chunks: [Int: Data]
    }

    private var partials: [UInt32: Partial] = [:]
    private var order: [UInt32] = []

    public init() {}

    public var hasPending: Bool { !partials.isEmpty }

    public mutating func reset() {
        partials.removeAll()
        order.removeAll()
    }

    public mutating func feed(_ block: [UInt8]) -> Data? {
        guard block.count >= OTIFrame.frameSize else { return nil }
        let seq = u32le(block, 4)
        let fragIndex = Int(u32le(block, 8))
        let totalFrags = Int(u32le(block, 12))
        let fragLen = Int(u32le(block, 16))
        guard totalFrags >= 1, fragIndex >= 0, fragIndex < totalFrags else { return nil }
        if fragIndex == 0 && block[0x14] == 0 { return nil }
        if totalFrags == 1 {
            guard fragLen >= 1, fragLen <= OTIFrame.frameSize - 0x14 else { return nil }
            return Data(block)
        }
        guard fragLen >= 1, fragLen <= OTIFrame.maxBlockPayload else { return nil }
        let slice = Data(block[0x14..<(0x14 + fragLen)])
        if partials[seq] == nil {
            if order.count >= 8 {
                let stale = order.removeFirst()
                partials.removeValue(forKey: stale)
            }
            order.append(seq)
            partials[seq] = Partial(total: totalFrags, chunks: [:])
        }
        guard var entry = partials[seq], entry.total == totalFrags else { return nil }
        entry.chunks[fragIndex] = slice
        if entry.chunks.count < entry.total {
            partials[seq] = entry
            return nil
        }
        partials.removeValue(forKey: seq)
        order.removeAll { $0 == seq }

        var payload = Data()
        payload.reserveCapacity(entry.total * OTIFrame.maxBlockPayload)
        for idx in 0..<entry.total {
            guard let part = entry.chunks[idx] else { return nil }
            payload.append(part)
        }
        guard let first = payload.first, first != 0 else { return nil }

        var reassembled = Data(count: 0x14)
        reassembled.withUnsafeMutableBytes { raw in
            let w = raw.bindMemory(to: UInt32.self)
            w[0] = 1
            w[1] = seq
            w[2] = 0
            w[3] = 1
            w[4] = UInt32(payload.count)
        }
        reassembled.append(payload)
        return reassembled
    }

    private func u32le(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }
}

public final class SCSITaskTransport: OTIHIDTransport, OTIMultiBlockTransport {
    public enum TransportError: Error, CustomStringConvertible {
        case notConnected
        case openFailed(Int32)
        case handshakeFailed(Int32, UInt8, [UInt8])
        case pollFailed(Int32, UInt8, [UInt8])
        case readFailed(Int32, UInt8, [UInt8])
        case writeFailed(Int32, UInt8, [UInt8])
        case invalidFrameSize(Int)

        public var description: String {
            switch self {
            case .notConnected:
                return "SCSITaskTransport is not open"
            case .openFailed(let code):
                return String(format: "oti_usb_open failed: 0x%x (%d)", UInt32(bitPattern: code), code)
            case .handshakeFailed(let code, let status, let sense):
                return "handshake failed: code=\(code) status=\(status) sense=\(Self.hex(sense))"
            case .pollFailed(let code, let status, let sense):
                return "poll failed: code=\(code) status=\(status) sense=\(Self.hex(sense))"
            case .readFailed(let code, let status, let sense):
                return "read failed: code=\(code) status=\(status) sense=\(Self.hex(sense))"
            case .writeFailed(let code, let status, let sense):
                return "write failed: code=\(code) status=\(status) sense=\(Self.hex(sense))"
            case .invalidFrameSize(let size):
                return "invalid OTi frame size: \(size) (expected <= 65536)"
            }
        }

        private static func hex(_ bytes: [UInt8]) -> String {
            bytes.map { String(format: "%02x", $0) }.joined()
        }
    }

    private let lock = NSLock()
    private var handle: OpaquePointer?
    private var rxQueue: [Data] = []
    private var rxAssembler = OTIBlockAssembler()
    public private(set) var lastStatusBytes: [UInt8] = []
    public private(set) var functionType: UInt8 = 0

    /// Raw `functionType` byte from `F0 00 00` offset 0x20 (this bridge: 0x88).
    ///
    /// Original `GoBridgeDemon` decoding (SKMBridge `getFunctionType`):
    /// `relative = (functionType & 0x88) == 0x88`; `functionType & 0x01` means
    /// "multimedia keyboard supported", it is NOT a HID report id.
    public var hidMouseUsesRelativeReports: Bool { (functionType & 0x88) == 0x88 }
    public var supportsMultimediaKeyboard: Bool { (functionType & 0x01) != 0 }

    public var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return handle != nil
    }

    public var lastPollStatusByte: UInt8? {
        lock.lock()
        defer { lock.unlock() }
        return lastStatusBytes.first
    }

    public static func isPeerOfflineError(_ error: Error) -> Bool {
        switch error {
        case TransportError.notConnected:
            return true
        case TransportError.writeFailed(let code, _, _) where code == -3:
            return true
        default:
            return false
        }
    }

    public init() {}

    deinit {
        close()
    }

    public func open() throws {
        lock.lock()
        defer { lock.unlock() }

        if handle != nil { return }

        var err: Int32 = 0
        guard let h = oti_usb_open(&err) else {
            throw TransportError.openFailed(err)
        }

        let hs = oti_usb_handshake(h)
        if hs != 0 {
            let errInfo = readLastError(h)
            oti_usb_close(h)
            throw TransportError.handshakeFailed(hs, errInfo.status, errInfo.sense)
        }

        handle = h
        functionType = oti_usb_function_type(h)
        rxQueue.removeAll()
        rxAssembler.reset()
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        if let h = handle {
            oti_usb_close(h)
            handle = nil
        }
        functionType = 0
        rxQueue.removeAll()
        rxAssembler.reset()
        lastStatusBytes.removeAll()
    }

    /// Injects one 12-byte HID report through the bridge.
    ///
    /// Same constraint as the 64 KB frame path: a pending RX block makes the
    /// vendor command abort, and the bridge silently drops the report. Drain
    /// first and retry, otherwise pointer input to the other machine is lost
    /// without any visible error.
    public func sendHID(kind: UInt8, data12: [UInt8]) throws {
        var buf = [UInt8](repeating: 0, count: 12)
        for i in 0..<min(data12.count, 12) { buf[i] = data12[i] }

        var lastError: Error = TransportError.notConnected
        for attempt in 1...3 {
            lock.lock()
            let result: Error? = {
                guard let h = handle else { return TransportError.notConnected }
                _ = try? drainPendingRxLocked(h)
                let rc = buf.withUnsafeBufferPointer { ptr -> Int32 in
                    guard let base = ptr.baseAddress else { return -1 }
                    return oti_usb_send_hid(h, kind, base)
                }
                if rc != 0 {
                    let errInfo = readLastError(h)
                    return TransportError.writeFailed(rc, errInfo.status, errInfo.sense)
                }
                return nil
            }()
            lock.unlock()

            guard let error = result else { return }
            lastError = error
            if attempt < 3 { usleep(80_000) }
        }
        throw lastError
    }

    @discardableResult
    public func pollStatus() throws -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        guard let h = handle else { throw TransportError.notConnected }
        return try pollLocked(h)
    }

    /// Sends one 64 KB frame (payload block + zero companion block).
    ///
    /// The bridge intermittently aborts a `D9 2A` data-out with CHECK CONDITION
    /// (SCSI status 2, sense key NO SENSE, ~1.28 s) even though the identical
    /// frame succeeds a moment later; the original daemon shows the same
    /// behaviour and simply re-sends. Retry with a short back-off instead of
    /// dropping the command, otherwise a KM switch or clipboard update is lost.
    public func send(frame: Data) throws {
        try sendBlocks([frame])
    }

    /// Sends one or more 64 KB fragment blocks followed by a 64 KB zero
    /// companion block.
    public func sendBlocks(_ blocks: [Data]) throws {
        guard !blocks.isEmpty else { return }
        var paddedBlocks: [Data] = []
        paddedBlocks.reserveCapacity(blocks.count)
        for block in blocks {
            guard block.count <= OTIFrame.frameSize else {
                throw TransportError.invalidFrameSize(block.count)
            }
            var padded = block
            if padded.count < OTIFrame.frameSize {
                padded.append(Data(count: OTIFrame.frameSize - padded.count))
            }
            paddedBlocks.append(padded)
        }

        // Measured on the real bridge: writing while an RX block is still
        // pending makes the data-out abort 1.28 s later with CHECK CONDITION
        // (NO SENSE). Draining RX until the poll reports idle first, and
        // retrying with a short delay, turned 2/8 successes into 8/8.
        let attempts = 4
        var lastError: Error = TransportError.notConnected
        for attempt in 1...attempts {
            lock.lock()
            let result: Error? = {
                do {
                    guard let h = handle else { throw TransportError.notConnected }
                    // Drain anything the peer queued before pushing our frame.
                    _ = try? drainPendingRxLocked(h)
                    let totalTx = UInt8(min(255, paddedBlocks.count + 1))
                    let status = try waitForTxReadyLocked(h, txBlocks: totalTx)
                    for (idx, padded) in paddedBlocks.enumerated() {
                        if idx > 0 && status == 0x06 {
                            let rem = UInt8(min(255, paddedBlocks.count - idx + 1))
                            _ = try waitForTxReadyLocked(h, txBlocks: rem)
                        }
                        try sendRawBlockLocked(h, bytes: padded)
                    }
                    if status == 0x06 {
                        _ = try waitForTxReadyLocked(h, txBlocks: 1)
                    }
                    try sendRawBlockLocked(h, bytes: Data(count: OTIFrame.frameSize))
                    return nil
                } catch {
                    return error
                }
            }()
            lock.unlock()

            guard let error = result else { return }
            lastError = error
            if attempt < attempts {
                usleep(200_000)
            }
        }
        throw lastError
    }

    /// Reads and queues any pending RX blocks without waiting for new data.
    private func drainPendingRxLocked(_ h: OpaquePointer) throws -> Int {
        var drained = 0
        for _ in 0..<128 {
            let st = try pollLocked(h, txBlocks: 0)
            guard st.count >= 3, st[0] == 0x05 else { break }
            let count = (Int(st[1]) << 8) | Int(st[2])
            guard count > 0 else { break }
            try drainRxBlocksLocked(h, count: count)
            drained += count
        }
        return drained
    }

    public func readFrame() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let h = handle else { throw TransportError.notConnected }

        if !rxQueue.isEmpty {
            return rxQueue.removeFirst()
        }

        let maxPolls = 80
        for pollIdx in 0..<maxPolls {
            let st = try pollLocked(h, txBlocks: 0)
            if st.count >= 3, st[0] == 0x05 {
                let blockCount = (Int(st[1]) << 8) | Int(st[2])
                if blockCount > 0 {
                    try drainRxBlocksLocked(h, count: blockCount)
                }
            }
            if !rxQueue.isEmpty {
                return rxQueue.removeFirst()
            }
            if st.first == 0x01 {
                rxAssembler.reset()
                break
            }
            // Only keep polling inside readFrame() when a multi-block message is
            // actively mid-flight; idle polls return nil immediately.
            guard rxAssembler.hasPending else { break }
            if pollIdx > 0 && st.first != 0x05 {
                usleep(2000)
            }
        }

        return rxQueue.isEmpty ? nil : rxQueue.removeFirst()
    }

    private func waitForTxReadyLocked(_ h: OpaquePointer, txBlocks: UInt8) throws -> UInt8 {
        var lastState: UInt8 = 0
        for _ in 0..<40 {
            let st: [UInt8]
            do {
                st = try pollLocked(h, txBlocks: txBlocks)
            } catch TransportError.pollFailed(let code, _, _) where code == 4 || code == -101 {
                usleep(5000)
                continue
            }
            guard !st.isEmpty else {
                usleep(5000)
                continue
            }
            lastState = st[0]
            if lastState == 0x07 || lastState == 0x06 {
                return lastState
            }
            if lastState == 0x01 {
                // Remote host (Windows GO! Bridge) is offline: no amount of
                // waiting makes the data-out acceptable, fail fast.
                throw TransportError.writeFailed(-3, 0x01, [])
            }
            if lastState == 0x05, st.count >= 3 {
                let rxCount = (Int(st[1]) << 8) | Int(st[2])
                if rxCount > 0 {
                    try drainRxBlocksLocked(h, count: rxCount)
                }
                continue
            }
            usleep(5000)
        }
        throw TransportError.writeFailed(-2, lastState, [])
    }

    private func sendRawBlockLocked(_ h: OpaquePointer, bytes: Data) throws {
        let rc = bytes.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return oti_usb_send_raw_block64k(h, base)
        }
        if rc != 0 {
            let errInfo = readLastError(h)
            throw TransportError.writeFailed(rc, errInfo.status, errInfo.sense)
        }
    }

    private func drainRxBlocksLocked(_ h: OpaquePointer, count: Int) throws {
        var block = [UInt8](repeating: 0, count: OTIFrame.frameSize)
        for _ in 0..<count {
            let rc = block.withUnsafeMutableBufferPointer { buf -> Int32 in
                guard let base = buf.baseAddress else { return -1 }
                return oti_usb_read_block64k(h, base)
            }
            if rc != 0 {
                let errInfo = readLastError(h)
                throw TransportError.readFailed(rc, errInfo.status, errInfo.sense)
            }
            if let assembled = rxAssembler.feed(block) {
                rxQueue.append(assembled)
            }
        }
    }

    private func pollLocked(_ h: OpaquePointer, txBlocks: UInt8 = 0) throws -> [UInt8] {
        var st = [UInt8](repeating: 0, count: 16)
        let rc = st.withUnsafeMutableBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return -1 }
            return oti_usb_poll_status(h, txBlocks, base)
        }
        if rc != 0 {
            let errInfo = readLastError(h)
            throw TransportError.pollFailed(rc, errInfo.status, errInfo.sense)
        }
        lastStatusBytes = st
        return st
    }

    private func readLastError(_ h: OpaquePointer) -> (kr: Int32, status: UInt8, sense: [UInt8]) {
        var kr: Int32 = 0
        var status: UInt8 = 0
        var sense = [UInt8](repeating: 0, count: 18)
        sense.withUnsafeMutableBufferPointer { buf in
            oti_usb_last_error(h, &kr, &status, buf.baseAddress)
        }
        return (kr, status, sense)
    }
}
