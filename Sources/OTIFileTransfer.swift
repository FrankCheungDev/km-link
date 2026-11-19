// OTIFileTransfer.swift
// File-drag metadata and data transfer commands captured from the original GO! Bridge.
//
// NodeInfo layout (824 bytes):
//   0..255   ANSI path, NUL padded, backslash separated, prefixed with "/"
//   256..259 reserved (zero)
//   260..    UTF-16LE path, NUL padded
//   780      FILETIME creation (LE u64)
//   788      FILETIME modification (LE u64)
//   796      FILETIME access (LE u64)
//   808      UInt64 file size (LE u64)
//
// The surrounding XML is:
//   <OTIMSG><NodeInfoList><Line><NodeInfo>HEX</NodeInfo></Line></NodeInfoList></OTIMSG>

import Foundation

public struct OTIFileNode: Equatable {
    public var path: String
    /// Raw bytes of the ANSI (peer code page) path block, NUL terminated.
    public var rawANSIPath: Data?
    /// Raw bytes of the UTF-16 path block, exactly as the peer announced them.
    public var rawUTF16Path: Data?
    public var size: UInt64
    public var createdAt: Date?
    public var modifiedAt: Date?
    public var attributes: UInt32

    public var isDirectory: Bool { (attributes & 0x10) != 0 }

    public init(path: String,
                rawANSIPath: Data? = nil,
                rawUTF16Path: Data? = nil,
                size: UInt64,
                createdAt: Date? = nil,
                modifiedAt: Date? = nil,
                attributes: UInt32 = 0) {
        self.path = path
        self.rawANSIPath = rawANSIPath
        self.rawUTF16Path = rawUTF16Path
        self.size = size
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.attributes = attributes
    }
}

public enum OTIFileTransfer {
    public static let nodeInfoSize = 824

    public static func parseNodeInfoList(_ xml: Data) -> [OTIFileNode] {
        guard let text = String(data: xml, encoding: .utf8) else { return [] }
        var nodes: [OTIFileNode] = []
        var search = text.startIndex
        while let open = text.range(of: "<NodeInfo>", range: search..<text.endIndex),
              let close = text.range(of: "</NodeInfo>", range: open.upperBound..<text.endIndex) {
            let hex = String(text[open.upperBound..<close.lowerBound])
            if let node = parseNodeInfo(hex) { nodes.append(node) }
            search = close.upperBound
        }
        return nodes
    }

    public static func parseNodeInfo(_ hex: String) -> OTIFileNode? {
        guard let data = dataFromHex(hex), data.count >= nodeInfoSize else { return nil }
        let bytes = [UInt8](data)

        let ascii = String(decoding: bytes[0..<256].prefix { $0 != 0 }, as: UTF8.self)
        var path = normalizePeerPath(ascii)

        let utf16End = utf16Terminator(bytes, from: 260, to: 768)
        let utf16Data = Data(bytes[260..<utf16End])
        if let decoded = String(data: utf16Data, encoding: .utf16LittleEndian), !decoded.isEmpty {
            path = normalizePeerPath(decoded)
        }

        let ansiEnd = Int(bytes[0..<256].firstIndex(of: 0) ?? 0)
        let rawANSI = Data(bytes[0..<max(0, min(ansiEnd, bytes.count))])
        let size = readU64LE(bytes, 808) ?? 0
        let created = readU64LE(bytes, 780).flatMap(fileTime)
        let modified = readU64LE(bytes, 788).flatMap(fileTime)
        let attributes = u32le(bytes, 816) ?? 0
        return OTIFileNode(path: path, rawANSIPath: rawANSI,
                           rawUTF16Path: Data(bytes[260..<utf16End]),
                           size: size, createdAt: created, modifiedAt: modified,
                           attributes: attributes)
    }

    /// Build the 824-byte NodeInfo blob for one file.
    public static func encodeNodeInfo(path: String, size: UInt64,
                                      createdAt: Date = Date(), modifiedAt: Date = Date()) -> Data {
        var bytes = [UInt8](repeating: 0, count: nodeInfoSize)
        let normalized = path.hasPrefix("/") ? path : "/" + path
        let otiPath = "/" + normalized.replacingOccurrences(of: "/", with: "\\")
        let ascii = Array(otiPath.utf8.prefix(255))
        bytes.replaceSubrange(0..<ascii.count, with: ascii)

        let utf16 = Array(otiPath.utf16).flatMap { word -> [UInt8] in
            let v = UInt16(word).littleEndian
            return [UInt8(v & 0xff), UInt8(v >> 8)]
        }
        let utf16Count = min(utf16.count, 500)
        bytes.replaceSubrange(260..<(260 + utf16Count), with: utf16.prefix(utf16Count))

        writeU64LE(&bytes, 780, windowsFileTime(createdAt))
        writeU64LE(&bytes, 788, windowsFileTime(modifiedAt))
        writeU64LE(&bytes, 796, windowsFileTime(modifiedAt))
        writeU64LE(&bytes, 808, size)
        return Data(bytes)
    }

    public static func nodeInfoListXML(files: [(path: String, size: UInt64, createdAt: Date, modifiedAt: Date)]) -> String {
        let lines = files.map { file in
            let hex = encodeNodeInfo(
                path: file.path,
                size: file.size,
                createdAt: file.createdAt,
                modifiedAt: file.modifiedAt).map { String(format: "%02X", $0) }.joined()
            return "<Line><NodeInfo>\(hex)</NodeInfo></Line>"
        }.joined()
        return "<OTIMSG><NodeInfoList>\(lines)</NodeInfoList></OTIMSG>"
    }

    public static func nodeInfoListXML(path: String, size: UInt64) -> Data {
        let now = Date()
        return Data(nodeInfoListXML(files: [(path: path, size: size, createdAt: now, modifiedAt: now)]).utf8)
    }

    public struct DownloadFile: Equatable {
        public var fileID: UInt32
        public var path: String
    }

    public struct DownloadRequest: Equatable {
        public var multiSessionID: UInt32
        public var files: [DownloadFile]
    }

    /// DownloadMultipleFile (command 0x10), little-endian.
    /// u8 0x10, u32 multiSessionID, u16 count,
    /// then per file: u32 fileID, u16 pathLength, UTF-16LE path.
    public static func parseDownloadRequest(_ payload: Data) -> DownloadRequest? {
        let bytes = [UInt8](payload)
        guard bytes.count >= 7, bytes[0] == 0x10,
              let session = u32le(bytes, 1),
              let count = u16le(bytes, 5) else { return nil }
        var offset = 7
        var files: [DownloadFile] = []
        for _ in 0..<Int(count) {
            guard let fileID = u32le(bytes, offset),
                  let length = u16le(bytes, offset + 4) else { return nil }
            offset += 6
            guard offset + Int(length) <= bytes.count else { return nil }
            let body = [UInt8](bytes[offset..<(offset + Int(length))])
            let end = utf16Terminator(body, from: 0, to: body.count)
            let path = String(data: Data(body[0..<end]), encoding: .utf16LittleEndian) ?? ""
            files.append(DownloadFile(fileID: fileID, path: normalize(path)))
            offset += Int(length)
        }
        return DownloadRequest(multiSessionID: session, files: files)
    }

    /// DownloadMultipleFile (command 0x10) sent by Mac to request files announced
    /// by Windows in a `NodeInfoList`.
    ///
    /// Captured byte-for-byte from `GoBridgeDemon`:
    ///   10 | u32BE session | u16BE count | (u32BE fileID | u16BE srcLen | srcUTF16BE+0000 | [u16BE dstLen | dstUTF16BE+0000])*
    /// Both paths are UTF-16BE with a 2-byte NUL terminator (no leading 0x00 padding byte).
    public static func encodeDownloadRequest(
        multiSessionID: UInt32,
        files: [(fileID: UInt32, path: String, destinationPath: String?, rawPath: Data?)],
        useRawPath: Bool = false
    ) -> Data {
        var out = Data([0x10])
        appendU32BE(&out, multiSessionID)
        appendU16BE(&out, UInt16(files.count))
        for file in files {
            appendU32BE(&out, file.fileID)
            let srcBytes: Data
            if useRawPath, let raw = file.rawPath, !raw.isEmpty {
                srcBytes = raw
            } else {
                srcBytes = utf16BigEndianZ(file.path)
            }
            appendU16BE(&out, UInt16(srcBytes.count))
            out.append(srcBytes)
            if let dst = file.destinationPath {
                let dstBytes = utf16BigEndianZ(dst)
                appendU16BE(&out, UInt16(dstBytes.count))
                out.append(dstBytes)
            }
        }
        return out
    }

    public static func encodeDownloadRequest(
        multiSessionID: UInt32,
        files: [(fileID: UInt32, path: String, rawPath: Data?)],
        useRawPath: Bool = false
    ) -> Data {
        encodeDownloadRequest(
            multiSessionID: multiSessionID,
            files: files.map { ($0.fileID, $0.path, nil, $0.rawPath) },
            useRawPath: useRawPath
        )
    }

    private static func utf16BigEndianZ(_ text: String) -> Data {
        var out = text.data(using: .utf16BigEndian) ?? Data()
        if !text.hasSuffix("\0") {
            out.append(contentsOf: [0x00, 0x00])
        }
        return out
    }

    /// Inner FileDataCommand (0xa3) as it arrives inside a 0x3a packet when the
    /// *Mac is receiving*: the fields are little-endian in that direction (the
    /// Mac->Windows direction uses big-endian).
    public struct LittleEndianFileData: Equatable {
        public var fileID: UInt32
        public var totalCount: UInt32
        public var currentCountIndex: UInt32
        public var dataLength: UInt32
        public var data: Data
    }

    /// Inner ChangeFileAttribute (0x37) inside a 0x3a MultipleFilePackage.
    public struct FileAttributeInfo: Equatable {
        public var attributes: UInt32
        public var createdAt: Date?
        public var accessedAt: Date?
        public var modifiedAt: Date?
        public var path: String
    }

    public struct MultipleFilePackage: Equatable {
        public var dataPackets: [LittleEndianFileData]
        public var attributes: [FileAttributeInfo]
    }

    /// Parses all inner commands in a `0x3a` MultipleFilePackage (`0xa3` data
    /// chunks and `0x37` attribute records, all fields little-endian).
    public static func parseMultipleFilePackage(_ payload: Data) -> MultipleFilePackage? {
        let bytes = [UInt8](payload)
        guard bytes.count > 16, bytes[0] == 0x3a else { return nil }
        let count = Int(u32le(bytes, 1) ?? 0)
        var offset = 16
        if offset >= bytes.count || (bytes[offset] != 0xa3 && bytes[offset] != 0x37) {
            if let found = (13..<min(24, bytes.count - 17)).first(where: { bytes[$0] == 0xa3 || bytes[$0] == 0x37 }) {
                offset = found
            } else {
                return nil
            }
        }
        var dataPackets: [LittleEndianFileData] = []
        var attrs: [FileAttributeInfo] = []
        let limit = max(count, 1)
        for _ in 0..<limit {
            guard offset < bytes.count else { break }
            let cmd = bytes[offset]
            if cmd == 0xa3 {
                guard let fileID = u32le(bytes, offset + 1),
                      let total = u32le(bytes, offset + 5),
                      let index = u32le(bytes, offset + 9),
                      let length = u32le(bytes, offset + 13) else { break }
                let start = offset + 17
                guard start <= bytes.count else { break }
                let take = min(Int(length), bytes.count - start)
                dataPackets.append(LittleEndianFileData(
                    fileID: fileID, totalCount: total,
                    currentCountIndex: index, dataLength: length,
                    data: Data(bytes[start..<(start + take)])))
                offset = start + take
            } else if cmd == 0x37 {
                guard let parsed = parseFileAttribute(bytes: bytes, offset: offset) else { break }
                attrs.append(parsed.info)
                offset = parsed.nextOffset
            } else {
                break
            }
        }
        guard !dataPackets.isEmpty || !attrs.isEmpty else { return nil }
        return MultipleFilePackage(dataPackets: dataPackets, attributes: attrs)
    }

    /// Parses a standalone Windows little-endian `0x37` file attribute frame.
    public static func parseFileAttribute(_ payload: Data) -> FileAttributeInfo? {
        let bytes = [UInt8](payload)
        return parseFileAttribute(bytes: bytes, offset: 0)?.info
    }

    private static func parseFileAttribute(
        bytes: [UInt8], offset: Int
    ) -> (info: FileAttributeInfo, nextOffset: Int)? {
        guard offset + 33 <= bytes.count, bytes[offset] == 0x37,
              let fileAttrs = u32le(bytes, offset + 1),
              let pathLen = u32le(bytes, offset + 29) else { return nil }
        let created = readU64LE(bytes, offset + 5).flatMap(fileTime)
        let accessed = readU64LE(bytes, offset + 13).flatMap(fileTime)
        let modified = readU64LE(bytes, offset + 21).flatMap(fileTime)
        let pathStart = offset + 33
        let take = min(Int(pathLen), max(0, bytes.count - pathStart))
        let pathBody = [UInt8](bytes[pathStart..<(pathStart + take)])
        let end = utf16Terminator(pathBody, from: 0, to: pathBody.count)
        let path = String(data: Data(pathBody[0..<end]), encoding: .utf16LittleEndian) ?? ""
        return (FileAttributeInfo(attributes: fileAttrs, createdAt: created,
                                  accessedAt: accessed, modifiedAt: modified, path: path),
                pathStart + take)
    }

    /// Scans a 0x3a packet for the first embedded 0xa3 command and decodes it.
    public static func parseFileDataPacket(_ payload: Data) -> LittleEndianFileData? {
        parseMultipleFilePackage(payload)?.dataPackets.first
    }

    public struct ErrorResponse: Equatable {
        public var multiSessionID: UInt32
        public var errorCode: UInt32
        public var fileID: UInt32
        public var message: String
    }

    /// Decodes a `0xa9` file transfer error frame:
    /// `a9 | u32LE multiSessionID | u32LE errorCode | u32LE fileID | "ErrStr" | u32LE byteLen | UTF-16LE message`.
    public static func parseErrorResponse(_ payload: Data) -> ErrorResponse? {
        let bytes = [UInt8](payload)
        guard bytes.count >= 13, bytes[0] == 0xa9,
              let session = u32le(bytes, 1),
              let code = u32le(bytes, 5),
              let fileID = u32le(bytes, 9) else { return nil }
        var message = ""
        let sig = Array("ErrStr".utf8)
        if bytes.count >= 23, Array(bytes[13..<19]) == sig,
           let msgLen = u32le(bytes, 19) {
            let start = 23
            let take = min(Int(msgLen), max(0, bytes.count - start))
            let body = [UInt8](bytes[start..<(start + take)])
            let end = utf16Terminator(body, from: 0, to: body.count)
            message = String(data: Data(body[0..<end]), encoding: .utf16LittleEndian) ?? ""
        } else {
            message = String(decoding: bytes[13...], as: UTF8.self)
                .trimmingCharacters(in: .controlCharacters)
        }
        return ErrorResponse(multiSessionID: session, errorCode: code, fileID: fileID, message: message)
    }

    private static func appendU16BE(_ out: inout Data, _ value: UInt16) {
        out.append(UInt8((value >> 8) & 0xff))
        out.append(UInt8(value & 0xff))
    }

    public struct FileDataHeader: Equatable {
        public var sessionFileID: UInt32
        public var totalCount: UInt32
        public var currentCountIndex: UInt32
        public var dataLength: UInt32
        public var data: Data
        public var truncated: Bool
    }

    /// FileDataCommand (command 0xa3).
    /// Mac sends big-endian; Windows GO! Bridge sends little-endian for
    /// standalone 0xa3 frames (large files not wrapped in a 0x3a container).
    /// u8 0xa3, u32 sessionFileID, u32 totalCount,
    /// u32 currentCountIndex (1-based), u32 dataLength, data.
    public static func parseFileData(_ payload: Data) -> FileDataHeader? {
        let bytes = [UInt8](payload)
        guard bytes.count >= 17, bytes[0] == 0xa3,
              let sessionBE = u32be(bytes, 1),
              let totalBE = u32be(bytes, 5),
              let indexBE = u32be(bytes, 9),
              let lengthBE = u32be(bytes, 13),
              let sessionLE = u32le(bytes, 1),
              let totalLE = u32le(bytes, 5),
              let indexLE = u32le(bytes, 9),
              let lengthLE = u32le(bytes, 13) else { return nil }
        let available = bytes.count - 17
        let beExact = Int(lengthBE) == available
        let leExact = Int(lengthLE) == available
        let beCountsSane = totalBE >= 1 && indexBE >= 1 && indexBE <= totalBE && totalBE <= 0x0010_0000
        let leCountsSane = totalLE >= 1 && indexLE >= 1 && indexLE <= totalLE && totalLE <= 0x0010_0000
        let useLE: Bool
        if leExact && !beExact {
            useLE = true
        } else if beExact && !leExact {
            useLE = false
        } else if leCountsSane && !beCountsSane {
            useLE = true
        } else if beCountsSane && !leCountsSane {
            useLE = false
        } else {
            useLE = Int(lengthLE) <= available && Int(lengthBE) > available
        }
        let session = useLE ? sessionLE : sessionBE
        let total = useLE ? totalLE : totalBE
        let index = useLE ? indexLE : indexBE
        let length = useLE ? lengthLE : lengthBE
        let take = min(Int(length), available)
        return FileDataHeader(sessionFileID: session, totalCount: total,
                              currentCountIndex: index, dataLength: length,
                              data: Data(bytes[17..<(17 + take)]),
                              truncated: take < Int(length))
    }

    public static func encodeFileData(sessionFileID: UInt32, totalCount: UInt32,
                                      currentCountIndex: UInt32, data: Data) -> Data {
        var out = Data([0xa3])
        appendU32BE(&out, sessionFileID)
        appendU32BE(&out, totalCount)
        appendU32BE(&out, currentCountIndex)
        appendU32BE(&out, UInt32(data.count))
        out.append(data)
        return out
    }

    /// 34-byte download acknowledgement (command 0xA1):
    /// [0xA1, 0x10, 0x00] + multiSessionID (4B BE) + 27 zero bytes.
    public static func encodeDownloadAck(multiSessionID: UInt32) -> Data {
        var out = Data([0xA1, 0x10, 0x00])
        appendU32BE(&out, multiSessionID)
        out.append(Data(count: 27))
        return out
    }

    /// 33-byte file attributes command (command 0x37):
    /// [0x37, 0x00, 0x00, 0x00, 0x00] + 3 x 8B BE Windows FILETIME + 4 zero bytes.
    public static func encodeFileAttributes(createdAt: Date, modifiedAt: Date, accessedAt: Date) -> Data {
        var out = Data([0x37, 0x00, 0x00, 0x00, 0x00])
        appendU64BE(&out, windowsFileTime(createdAt))
        appendU64BE(&out, windowsFileTime(modifiedAt))
        appendU64BE(&out, windowsFileTime(accessedAt))
        out.append(Data(count: 4))
        return out
    }

    /// 5-byte download completion command (command 0xA7):
    /// [0xA7] + multiSessionID (4B BE).
    public static func encodeDownloadFinish(multiSessionID: UInt32) -> Data {
        var out = Data([0xA7])
        appendU32BE(&out, multiSessionID)
        return out
    }

    /// File data frame (type 0xa3): locate the ZIP/DOCX payload.
    public static func filePayload(_ frame: Data) -> Data? {
        guard let range = frame.range(of: Data([0x50, 0x4b, 0x03, 0x04])) else { return nil }
        return frame.subdata(in: range.lowerBound..<frame.count)
    }

    // MARK: - Helpers

    private static func dataFromHex(_ hex: String) -> Data? {
        let clean = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count % 2 == 0 else { return nil }
        var data = Data(capacity: clean.count / 2)
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    /// Windows resolves its own paths with backslashes; the original daemon
    /// sends them untouched. Turning them into "/" made ASCII names work by
    /// accident (Win32 tolerates it) but non-ASCII names fail.
    private static func normalizePeerPath(_ raw: String) -> String {
        if raw.count > 1, raw[raw.index(raw.startIndex, offsetBy: 1)] == ":" {
            // A Windows path: keep its own backslashes, that is what the peer
            // resolves (ASCII names work with "/" by accident, non-ASCII do not).
            return raw
        }
        return normalize(raw)
    }

    private static func normalize(_ raw: String) -> String {
        var value = raw.replacingOccurrences(of: "\\", with: "/")
        while value.hasPrefix("//") { value.removeFirst() }
        return value
    }

    private static func utf16Terminator(_ bytes: [UInt8], from: Int, to: Int) -> Int {
        var i = from
        while i + 1 < to {
            if bytes[i] == 0 && bytes[i + 1] == 0 { return i }
            i += 2
        }
        return to
    }

    private static func u16le(_ b: [UInt8], _ o: Int) -> UInt16? {
        guard o + 2 <= b.count else { return nil }
        return UInt16(b[o]) | (UInt16(b[o + 1]) << 8)
    }

    private static func u32le(_ b: [UInt8], _ o: Int) -> UInt32? {
        guard o + 4 <= b.count else { return nil }
        return UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }

    private static func u32be(_ b: [UInt8], _ o: Int) -> UInt32? {
        guard o + 4 <= b.count else { return nil }
        return (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16) | (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3])
    }

    private static func readU64LE(_ bytes: [UInt8], _ offset: Int) -> UInt64? {
        guard offset + 8 <= bytes.count else { return nil }
        return bytes[offset..<(offset + 8)].enumerated().reduce(0) { value, pair in
            value | (UInt64(pair.element) << (UInt64(pair.offset) * 8))
        }
    }

    private static func writeU64LE(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt64) {
        guard offset + 8 <= bytes.count else { return }
        for i in 0..<8 { bytes[offset + i] = UInt8((value >> (UInt64(i) * 8)) & 0xff) }
    }

    private static func appendU32LE(_ out: inout Data, _ value: UInt32) {
        out.append(UInt8(value & 0xFF))
        out.append(UInt8((value >> 8) & 0xFF))
        out.append(UInt8((value >> 16) & 0xFF))
        out.append(UInt8((value >> 24) & 0xFF))
    }

    private static func appendU16LE(_ out: inout Data, _ value: UInt16) {
        out.append(UInt8(value & 0xFF))
        out.append(UInt8((value >> 8) & 0xFF))
    }

    private static func appendU32BE(_ out: inout Data, _ value: UInt32) {
        out.append(UInt8((value >> 24) & 0xff))
        out.append(UInt8((value >> 16) & 0xff))
        out.append(UInt8((value >> 8) & 0xff))
        out.append(UInt8(value & 0xff))
    }

    private static func appendU64BE(_ out: inout Data, _ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            out.append(UInt8((value >> UInt64(shift)) & 0xff))
        }
    }

    private static func fileTime(_ value: UInt64) -> Date? {
        guard value > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(value) / 10_000_000 - 11_644_473_600)
    }

    private static func windowsFileTime(_ date: Date) -> UInt64 {
        UInt64(max(0, (date.timeIntervalSince1970 + 11_644_473_600) * 10_000_000))
    }
}
