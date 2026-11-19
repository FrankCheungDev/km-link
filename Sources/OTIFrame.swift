// OTIFrame.swift
// OTi 64 KB frame + uPipe XML encoding/decoding.
//
// Frame layout (header words little-endian):
//   0x00 u32 sequence (matches sequence on TX; on RX may be rolling index)
//   0x04 u32 sequence
//   0x08 u32 0
//   0x0C u32 1
//   0x10 u32 payloadLength
//   0x14 u8  payloadType
// For payloadType == 0x39 (XML command):
//   0x15 u32 innerLen (BE on TX, LE or BE accepted on RX) == payloadLength - 5
//   0x19 ... XML/envelope bytes
// For other payloadTypes (0xA1, 0x10, 0xA3, 0x37, 0xA7, ...):
//   0x14 ... raw command payload starting with payloadType byte (no 4-byte innerLen)
//   0xFFEC   20-byte mirror of the header

import Foundation
import CoreGraphics

public struct OTIFrame {
    public static let frameSize = 0x10000
    public static let payloadOffset = 0x19
    public static let mirrorOffset = 0xFFEC
    public static let maxBlockPayload = mirrorOffset - 0x14

    public var sequence: UInt32
    public var payloadType: UInt8
    public var payload: Data

    public init(sequence: UInt32, payloadType: UInt8, payload: Data) {
        self.sequence = sequence
        self.payloadType = payloadType
        self.payload = payload
    }

    public var payloadLength: UInt32 {
        if payloadType == 0x39 { return UInt32(5 + payload.count) }
        if payload.first == payloadType { return UInt32(payload.count) }
        return UInt32(1 + payload.count)
    }

    private func serializedBody() -> Data {
        if payloadType == 0x39 {
            var body = Data([0x39])
            let len = UInt32(payload.count)
            body.append(UInt8((len >> 24) & 0xFF))
            body.append(UInt8((len >> 16) & 0xFF))
            body.append(UInt8((len >> 8) & 0xFF))
            body.append(UInt8(len & 0xFF))
            body.append(payload)
            return body
        }
        if payload.first == payloadType {
            return payload
        }
        var body = Data([payloadType])
        body.append(payload)
        return body
    }

    public func encoded() -> Data {
        encodedBlock(bodySlice: serializedBody().prefix(Self.maxBlockPayload),
                     fragmentIndex: 0,
                     totalFragments: 1)
    }

    public func encodedBlocks() -> [Data] {
        let body = serializedBody()
        if body.count <= Self.maxBlockPayload {
            return [encodedBlock(bodySlice: body[...], fragmentIndex: 0, totalFragments: 1)]
        }
        let total = (body.count + Self.maxBlockPayload - 1) / Self.maxBlockPayload
        var blocks: [Data] = []
        blocks.reserveCapacity(total)
        for index in 0..<total {
            let start = index * Self.maxBlockPayload
            let end = min(start + Self.maxBlockPayload, body.count)
            blocks.append(encodedBlock(
                bodySlice: body[start..<end],
                fragmentIndex: UInt32(index),
                totalFragments: UInt32(total)))
        }
        return blocks
    }

    private func encodedBlock(bodySlice: Data.SubSequence,
                              fragmentIndex: UInt32,
                              totalFragments: UInt32) -> Data {
        var out = Data(count: Self.frameSize)
        out.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            p.withMemoryRebound(to: UInt32.self) { w in
                w[0] = totalFragments > 1 ? 1 : sequence
                w[1] = sequence
                w[2] = fragmentIndex
                w[3] = totalFragments
                w[4] = UInt32(bodySlice.count)
            }
            let copyCount = min(bodySlice.count, Self.maxBlockPayload)
            if copyCount > 0 {
                bodySlice.prefix(copyCount).copyBytes(to: p.baseAddress!.advanced(by: 0x14), count: copyCount)
            }
            for i in 0..<20 { p[Self.mirrorOffset + i] = p[i] }
        }
        return out
    }

    public static func decode(_ data: Data) -> OTIFrame? {
        guard data.count >= 0x15 else { return nil }
        let p = [UInt8](data)
        guard p[12] == 1, p[0x14] != 0 else { return nil }
        let payloadLen = Int(p[16]) | (Int(p[17]) << 8) | (Int(p[18]) << 16) | (Int(p[19]) << 24)
        guard payloadLen >= 1, payloadLen <= data.count - 0x14 else { return nil }
        let type = p[0x14]
        let start: Int
        let length: Int
        if type == 0x39 {
            guard payloadLen >= 5, data.count >= 0x19 else { return nil }
            let innerLE = Int(p[0x15]) | (Int(p[0x16]) << 8) | (Int(p[0x17]) << 16) | (Int(p[0x18]) << 24)
            let innerBE = (Int(p[0x15]) << 24) | (Int(p[0x16]) << 16) | (Int(p[0x17]) << 8) | Int(p[0x18])
            guard innerLE == payloadLen - 5 || innerBE == payloadLen - 5 else { return nil }
            start = 0x19
            length = payloadLen - 5
        } else {
            start = 0x14
            length = payloadLen
        }
        let seq = UInt32(p[4]) | (UInt32(p[5]) << 8) | (UInt32(p[6]) << 16) | (UInt32(p[7]) << 24)
        let end = start + length
        guard end <= data.count else { return nil }
        return OTIFrame(sequence: seq, payloadType: type, payload: Data(p[start..<end]))
    }

    /// Return the full 64 KB frame matching `SCSI dir=1 len=65536`.
    public func transferData() -> Data {
        encoded()
    }
}

public enum OTIXML {
    public static let clipboardPipeName = "\\\\.\\pipe\\OTI_ClipboardAgent"

    public static func envelope(_ inner: String) -> Data {
        let xml = "<ExtraXmlCommand>HookAppService</ExtraXmlCommand><ExtraXmlParam>\(inner)</ExtraXmlParam>"
        return xml.data(using: .utf8)!
    }

    public struct LoginCommandInfo: Equatable {
        public let osVersion: UInt8
        public let codePage: UInt16
        public let name: String
    }

    /// Byte 1 of the Mac `LoginCommand`; the original daemon sends 0x10.
    public static var macPeerFlags: UInt8 = 0x10

    public static func loginCommandPayload(name: String, osVersion: UInt8 = 0x10, codePage: UInt16 = 0) -> Data {
        var nameBytes = Array(name.utf8)
        if nameBytes.count > 64 {
            nameBytes = Array(nameBytes.prefix(64))
        }
        // Original Mac daemon (captured 2026-11-18): `01 10 00 00 <len> <name>`
        // — byte 1 is 0x10, not an OS version, and there is no code page. The
        // Windows GO! Bridge appears to use this header to pick which peer
        // product („Mac KMLink" vs „GO Bridge") it brings up.
        var out = Data([
            0x01,
            macPeerFlags,
            0x00,
            0x00,
            UInt8(nameBytes.count)
        ])
        out.append(contentsOf: nameBytes)
        return out
    }

    public static func decodeLoginCommand(_ payload: Data) -> LoginCommandInfo? {
        let bytes = [UInt8](payload)
        guard bytes.count >= 5, bytes[0] == 0x01 else { return nil }
        let osVersion = bytes[1]
        let codePage = UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)
        let nameLen = Int(bytes[4])
        guard bytes.count >= 5 + nameLen else { return nil }
        let nameData = Data(bytes[5..<(5 + nameLen)])
        let name = String(data: nameData, encoding: .utf8) ?? String(decoding: nameData, as: UTF8.self)
        return LoginCommandInfo(osVersion: osVersion, codePage: codePage, name: name)
    }

    public struct ResponseResultInfo: Equatable {
        public let requestCommand: UInt8
        public let requestResult: UInt8
        public let remoteOSVersion: UInt8?
    }

    /// 44-byte `ResponseResult` (`0xA1`) matching `GoBridgeDemon` `[ResponseResult encodeData]`
    /// with `setExtraInfoWithOSVersion:`.
    public static func loginResponsePayload(requestCommand: UInt8 = 0x01,
                                            requestResult: UInt8 = 0x00,
                                            osVersion: UInt8 = 0x28) -> Data {
        var out = Data(count: 44)
        out[0] = 0xA1
        out[1] = requestCommand
        out[2] = requestResult
        // TLV header: [19] = 0x03 (value kind), [20...] = block length.
        // The Windows GO! Bridge sends 0x0a here (9 ASCII chars + one value
        // byte) and looks the block up by that length; leaving it zero made the
        // peer ignore our OSVERSION block entirely.
        // Layout verified against both the Windows GO! Bridge and the original
        // Mac daemon (2026-11-18 capture): the TLV block starts at payload
        // offset 20 — `a1 cmd 00` + 17 zero bytes, then 0x03, then the length
        // byte, then the tag at offset 25 and the value at 34. We used to write
        // this one byte early, so the peer could not find OSVERSION at all and
        // classified us as a plain bridge instead of a Mac KMLink peer.
        out[20] = 0x03
        out[21] = 0x0a
        let tag = Array("OSVERSION".utf8)
        for (i, b) in tag.enumerated() {
            out[25 + i] = b
        }
        out[34] = osVersion
        return out
    }

    /// Decode an incoming `0xA1` (`ResponseResult`) frame (34B Windows or 44B Mac format).
    public static func decodeResponseResult(_ payload: Data) -> ResponseResultInfo? {
        let bytes = [UInt8](payload)
        guard bytes.count >= 19, bytes[0] == 0xA1 else { return nil }
        let reqCmd = bytes[1]
        let reqRes = bytes[2]
        var osVer: UInt8?
        let sig = Array("OSVERSION".utf8)
        if bytes.count >= 35, bytes[20] == 0x03, Array(bytes[25..<34]) == sig {
            osVer = bytes[34]
        } else if bytes.count >= 34, bytes[19] == 0x03, Array(bytes[24..<33]) == sig {
            osVer = bytes[33]
        }
        return ResponseResultInfo(requestCommand: reqCmd, requestResult: reqRes, remoteOSVersion: osVer)
    }

    /// A1 login response payload (44 bytes, OSVERSION=0x28).
    public static func loginPayload() -> Data {
        loginResponsePayload(requestCommand: 0x01, requestResult: 0x00, osVersion: 0x28)
    }

    /// `0xA1` login sub-command frame (34 bytes).
    ///
    /// The original daemon sends a second `0xA1` right after the folder/drive
    /// announcement; its request command is 0x04 and the payload carries the
    /// same `OSVERSION` TLV as the login response. Windows' own 34-byte `0xA1`
    /// uses exactly this layout (`… 03 0a 00 00 00 "OSVERSION" 07`), so this is
    /// a byte-compatible short form of the login response.
    public static func loginSubCommandPayload(requestCommand: UInt8 = 0x04,
                                              osVersion: UInt8 = 0x28) -> Data {
        var out = loginResponsePayload(requestCommand: requestCommand,
                                       requestResult: 0x00,
                                       osVersion: osVersion)
        out = out.prefix(34)
        return out
    }

    /// `Cmd_Post_Remote_Screen_Info` — announces our screen geometry matching
    /// the `<Param_Screen_Info><OTIMSG>` structure sent by Windows GO! Bridge.
    public static func postRemoteScreenInfoPayload(width: Int, height: Int,
                                                   virtualX: Int = 0, virtualY: Int = 0) -> Data {
        let screenInfo = [
            "<OTIMSG>",
            "<Param_Virtual_Screen_Width>\(width)</Param_Virtual_Screen_Width>",
            "<Param_Virtual_Screen_Height>\(height)</Param_Virtual_Screen_Height>",
            "<Param_Left_Side_Virtual_Screen_Coordinate>\(virtualX)</Param_Left_Side_Virtual_Screen_Coordinate>",
            "<Param_Top_Side_Virtual_Screen_Coordinate>\(virtualY)</Param_Top_Side_Virtual_Screen_Coordinate>",
            "<Param_Remote_Screen_Width>\(width)</Param_Remote_Screen_Width>",
            "<Param_Remote_Screen_Height>\(height)</Param_Remote_Screen_Height>",
            "</OTIMSG>"
        ].joined()
        let inner = [
            "<OTIMSG><NP_Cmd>Cmd_Post_Remote_Screen_Info</NP_Cmd>",
            "<NP_Up_Notice_NamePipe_Name>\(clipboardPipeName)</NP_Up_Notice_NamePipe_Name>",
            "<Param_Screen_Info>\(screenInfo)</Param_Screen_Info>",
            "</OTIMSG>"
        ].joined()
        return envelope(inner)
    }

    private static func kmSettingXML(direction: Int, option: Int, hotkeyOnly: Int) -> String {
        return "<OTIMSG>"
            + "<Param_Move_Out_Direction>\(direction)</Param_Move_Out_Direction>"
            + "<Param_Move_Out_KM_Switch_Option>\(option)</Param_Move_Out_KM_Switch_Option>"
            + "<Param_Move_Out_Use_Hotkey_Switch_Only>\(hotkeyOnly)</Param_Move_Out_Use_Hotkey_Switch_Only>"
            + "</OTIMSG>"
    }

    private static func escapedKMSettingXML(direction: Int, option: Int, hotkeyOnly: Int) -> String {
        return kmSettingXML(direction: direction, option: option, hotkeyOnly: hotkeyOnly)
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// `Cmd_Post_Remote_KM_Setting_Info` — announces the KM arrangement to the
    /// peer inside `<Param_KM_Setting_Info>`.
    ///
    /// Wire values:
    ///   Param_Move_Out_Direction              1 = peer on the left, 2 = on the right
    ///   Param_Move_Out_KM_Switch_Option       3 (both directions allowed)
    ///   Param_Move_Out_Use_Hotkey_Switch_Only 0
    public static func postRemoteKMSettingPayload(direction: Int, option: Int = 3,
                                                  hotkeyOnly: Int = 0) -> Data {
        let settingXML = kmSettingXML(direction: direction, option: option, hotkeyOnly: hotkeyOnly)
        let inner = "<OTIMSG><NP_Cmd>Cmd_Post_Remote_KM_Setting_Info</NP_Cmd>"
            + "<NP_Up_Notice_NamePipe_Name>\(clipboardPipeName)</NP_Up_Notice_NamePipe_Name>"
            + "<Param_KM_Setting_Info>\(settingXML)</Param_KM_Setting_Info>"
            + "</OTIMSG>"
        return envelope(inner)
    }

    /// Encodes a String as `GoBridgeDemon` `stringToUTF16BigEndianData`:
    /// precomposed UTF-16BE bytes followed by a 2-byte NUL terminator.
    public static func otiUnicodeBigEndianData(_ text: String) -> Data {
        let precomposed = text.precomposedStringWithCanonicalMapping
        var out = precomposed.data(using: .utf16BigEndian) ?? Data()
        if !precomposed.hasSuffix("\0") {
            out.append(contentsOf: [0x00, 0x00])
        }
        return out
    }

    /// Encodes `DomainFolders` (`0xAD`) matching `[DomainFolders encodeData]`.
    public static func domainFoldersPayload(desktop: String,
                                            documents: String,
                                            music: String,
                                            pictures: String) -> Data {
        let items: [(UInt32, String)] = [
            (0x0000_F00F, desktop),
            (0x0100_F00F, documents),
            (0x0300_F00F, music),
            (0x0400_F00F, pictures),
        ]
        var sub = Data()
        var entryCount: UInt8 = 0
        for (tagLE, path) in items where !path.isEmpty {
            entryCount += 1
            var t = tagLE.littleEndian
            sub.append(Data(bytes: &t, count: 4))
            let uni = otiUnicodeBigEndianData(path)
            var ulen = UInt32(uni.count).bigEndian
            sub.append(Data(bytes: &ulen, count: 4))
            sub.append(uni)
        }
        var out = Data([0xAD])
        var subLen = UInt32(sub.count).littleEndian
        out.append(Data(bytes: &subLen, count: 4))
        out.append(entryCount)
        out.append(sub)
        return out
    }

    /// Encodes `DriveInfo` (`0xA4`) matching `[DriveInfo encodeData]`.
    public static func driveInfoPayload(volumes: [(name: String, path: String, type: UInt8)]) -> Data {
        var out = Data([0xA4])
        var cnt = UInt16(volumes.count).littleEndian
        out.append(Data(bytes: &cnt, count: 2))
        for v in volumes {
            out.append(contentsOf: [0x00, v.type])
        }
        for v in volumes {
            let nameData = otiUnicodeBigEndianData(v.name)
            var nameLen = UInt16(nameData.count).bigEndian
            out.append(Data(bytes: &nameLen, count: 2))
            out.append(nameData)

            let pathData = otiUnicodeBigEndianData(v.path)
            var pathLen = UInt16(pathData.count).bigEndian
            out.append(Data(bytes: &pathLen, count: 2))
            out.append(pathData)
        }
        return out
    }

    public static func replayBridgeBlockStatusPayload(blocked: Bool = false) -> Data {
        let val = blocked ? "1" : "0"
        let sync = "&lt;OTIMSG&gt;&lt;Param_Remote_Bridge_Blocked&gt;\(val)&lt;/Param_Remote_Bridge_Blocked&gt;&lt;/OTIMSG&gt;"
        let inner = "<OTIMSG><NP_Cmd>Cmd_Replay_Bridge_Block_Status</NP_Cmd>"
            + "<NP_Up_Notice_NamePipe_Name>\\\\.\\pipe\\OTI_ClipboardAgent</NP_Up_Notice_NamePipe_Name>"
            + "<Param_Sync_Running_Info>\(sync)</Param_Sync_Running_Info></OTIMSG>"
        return envelope(inner)
    }

    public static func clipboardPayload(text: String) -> Data {
        var utf16 = text.data(using: .utf16LittleEndian) ?? Data()
        utf16.append(contentsOf: [0, 0])
        let hex = utf16.map { String(format: "%02X", $0) }.joined()
        let inner = [
            "<OTIMSG><Param_Clipboard_Info_2><OTIMSG>",
            "<CP_Content>\(hex)</CP_Content>",
            "<CB_Format_Type>CB_Format_Text</CB_Format_Type>",
            "</OTIMSG></Param_Clipboard_Info_2>",
            "<NP_Cmd>Cmd_Transfer_Clipboard</NP_Cmd>",
            "<NP_Up_Notice_NamePipe_Name>\\\\.\\pipe\\OTI_ClipboardAgent</NP_Up_Notice_NamePipe_Name>",
            "</OTIMSG>"
        ].joined()
        return envelope(inner)
    }

    public static func clipboardFilesPayload(
        files: [(path: String, size: UInt64, createdAt: Date, modifiedAt: Date)]
    ) -> Data {
        let lines = files.map { file in
            let hex = OTIFileTransfer.encodeNodeInfo(
                path: file.path,
                size: file.size,
                createdAt: file.createdAt,
                modifiedAt: file.modifiedAt).map { String(format: "%02X", $0) }.joined()
            return "<Line><NodeInfo>\(hex)</NodeInfo></Line>"
        }.joined()
        let inner = [
            "<OTIMSG><Param_Clipboard_Info_2><OTIMSG>",
            "<NodeInfoList>\(lines)</NodeInfoList>",
            "<CB_Format_Type>CB_Format_File</CB_Format_Type>",
            "</OTIMSG></Param_Clipboard_Info_2>",
            "<NP_Cmd>Cmd_Transfer_Clipboard</NP_Cmd>",
            "<NP_Up_Notice_NamePipe_Name>\\\\.\\pipe\\OTI_ClipboardAgent</NP_Up_Notice_NamePipe_Name>",
            "</OTIMSG>"
        ].joined()
        return envelope(inner)
    }

    /// Reply to `Cmd_Notify_KM_Switch_To_Remote`.
    ///
    /// The original `CKMEvent::ProcessSwitchToRemoteCmd` reads the live CapsLock
    /// state (`GetCurrentKeyModifiers` >> 10) and the system scroll direction
    /// (`com.apple.swipescrolldirection`) and forwards both, so the master can
    /// keep CapsLock in sync and invert scrolling when the two machines differ.
    public static func switchAcknowledgePayload(
        capsLock: Bool = false,
        naturalScroll: Bool = true
    ) -> Data {
        let inner = [
            "<OTIMSG><NP_Cmd>Cmd_Get_KM_Switch_Acknowlege</NP_Cmd>",
            "<NP_Up_Notice_NamePipe_Name>\\\\.\\pipe\\OTI_ClipboardAgent</NP_Up_Notice_NamePipe_Name>",
            "<Param_Remote_Screen_Size><OTIMSG>",
            "<Param_CapsLock>\(capsLock ? 1 : 0)</Param_CapsLock>",
            "<Param_ScrollDirection>\(naturalScroll ? "Natural" : "Normal")</Param_ScrollDirection>",
            "</OTIMSG></Param_Remote_Screen_Size></OTIMSG>"
        ].joined()
        return envelope(inner)
    }

    /// `true` when the system uses natural (content-tracking) scrolling.
    public static var systemUsesNaturalScroll: Bool {
        if let value = UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection") as? Bool {
            return value
        }
        return true
    }

    /// `true` while CapsLock (alpha shift) is engaged.
    public static var capsLockEngaged: Bool {
        CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
    }

    /// 32-byte `Param_Point_Event_Data` blob, exactly the shape the original
    /// daemon embeds (captured 2026-10-22 in docs/captures):
    ///
    ///   u32[0]=0  u32[1]=screenW  u32[2]=screenH  u32[3..5]=0
    ///   u32[6]=KM switch option (3)  u32[7]=Move_Out_Y
    ///
    /// Captured sample (Windows, 3840x2160, y=922):
    ///   00000000 000F0000 70080000 00000000 00000000 00000000 03000000 9A030000
    public static func pointEventData(option: Int, screenWidth: Int, screenHeight: Int,
                                      moveOutY: Int) -> String {
        var words: [UInt32] = [
            0,
            UInt32(max(0, screenWidth)),
            UInt32(max(0, screenHeight)),
            0, 0, 0,
            UInt32(max(0, option)),
            UInt32(bitPattern: Int32(truncatingIfNeeded: moveOutY)),
        ]
        var out = ""
        out.reserveCapacity(64)
        for w in words {
            for shift in stride(from: 0, through: 24, by: 8) {
                out += String(format: "%02X", (w >> UInt32(shift)) & 0xFF)
            }
        }
        words.removeAll()
        return out
    }

    /// `Cmd_Notify_KM_Switch_To_Remote` — "I am taking the pointer, get ready".
    ///
    /// Field-for-field copy of what the original daemon sends (see
    /// docs/KM-MOUSE-RE.md): the `Param_Point_Event_Data` blob and the trailing
    /// empty `Param_Clipboard_Info_2` used to be missing here, and the Windows
    /// GO! Bridge silently ignored the command without them.
    public static func switchToRemotePayload(direction: Int, x: Int, y: Int, width: Int, height: Int) -> Data {
        let option = 3
        let pointData = pointEventData(option: option, screenWidth: width, screenHeight: height,
                                       moveOutY: y)
        let escapedSetting = escapedKMSettingXML(direction: direction, option: option, hotkeyOnly: 0)
        let moveOut = [
            "<OTIMSG>",
            "<Param_Point_Event_Data>\(pointData)</Param_Point_Event_Data>",
            "<Param_Move_Out_Direction>\(direction)</Param_Move_Out_Direction>",
            "<Param_Move_Out_X>\(x)</Param_Move_Out_X>",
            "<Param_Move_Out_Y>\(y)</Param_Move_Out_Y>",
            "<Param_Move_Out_KM_Switch_Option>\(option)</Param_Move_Out_KM_Switch_Option>",
            "<Param_Move_Out_Use_Hotkey_Switch_Only>0</Param_Move_Out_Use_Hotkey_Switch_Only>",
            "<Param_Other_PC_Position_Option>\(direction)</Param_Other_PC_Position_Option>",
            "<Param_Remote_Screen_Width>\(width)</Param_Remote_Screen_Width>",
            "<Param_Remote_Screen_Height>\(height)</Param_Remote_Screen_Height>",
            "<Param_KM_Setting_Info>\(escapedSetting)</Param_KM_Setting_Info>",
            "</OTIMSG>"
        ].joined()
        let inner = [
            "<OTIMSG><NP_Cmd>Cmd_Notify_KM_Switch_To_Remote</NP_Cmd>",
            "<NP_Up_Notice_NamePipe_Name>\(clipboardPipeName)</NP_Up_Notice_NamePipe_Name>",
            "<Param_Move_Out_Info>\(moveOut)</Param_Move_Out_Info>",
            "<Param_Clipboard_Info_2></Param_Clipboard_Info_2></OTIMSG>"
        ].joined()
        return envelope(inner)
    }

    public static func switchToLocalPayload() -> Data {
        let inner = "<OTIMSG><NP_Cmd>Cmd_Notify_KM_Switch_To_Local</NP_Cmd>"
            + "<NP_Up_Notice_NamePipe_Name>\\\\.\\pipe\\OTI_ClipboardAgent</NP_Up_Notice_NamePipe_Name>"
            + "</OTIMSG>"
        return envelope(inner)
    }

    public static func forceRemoteSwitchLocalPayload(x: Int, y: Int, direction: Int) -> Data {
        let inner = [
            "<OTIMSG><NP_Cmd>Cmd_Force_Remote_To_Switch_Local</NP_Cmd>",
            "<NP_Up_Notice_NamePipe_Name>\\\\.\\pipe\\OTI_ClipboardAgent</NP_Up_Notice_NamePipe_Name>",
            "<Param_Move_In_Info><OTIMSG>",
            "<Param_Move_In_X>\(x)</Param_Move_In_X>",
            "<Param_Move_In_Y>\(y)</Param_Move_In_Y>",
            "<Param_Move_In_Direction>\(direction)</Param_Move_In_Direction>",
            "</OTIMSG></Param_Move_In_Info></OTIMSG>"
        ].joined()
        return envelope(inner)
    }

    public static func dragFileIsBeginningPayload() -> Data {
        let inner = "<OTIMSG><NP_Cmd>Cmd_Drag_File_Is_Beginning</NP_Cmd>"
            + "<NP_Up_Notice_NamePipe_Name>\\\\.\\pipe\\OTI_ClipboardAgent</NP_Up_Notice_NamePipe_Name>"
            + "</OTIMSG>"
        return envelope(inner)
    }

    public static func lateSendDropDataPayload(nodeInfoListXML: String) -> Data {
        let inner = "<OTIMSG><Param_Clipboard_Info_2>\(nodeInfoListXML)</Param_Clipboard_Info_2>"
            + "<NP_Cmd>Cmd_Late_Send_Drop_Data</NP_Cmd>"
            + "<NP_Up_Notice_NamePipe_Name>\\\\.\\pipe\\OTI_ClipboardAgent</NP_Up_Notice_NamePipe_Name>"
            + "</OTIMSG>"
        return envelope(inner)
    }
}

public protocol OTITransport {
    func send(frame: Data) throws
    func readFrame() throws -> Data?
}

public protocol OTIMultiBlockTransport: OTITransport {
    func sendBlocks(_ blocks: [Data]) throws
}

public protocol OTIHIDTransport: OTITransport {
    /// `true` when the bridge expects relative 4-byte mouse reports
    /// (`[buttons, dx, dy, wheel]`); `false` for 11-bit absolute reports.
    var hidMouseUsesRelativeReports: Bool { get }
    func sendHID(kind: UInt8, data12: [UInt8]) throws
}

public final class OTISession {
    private let transport: OTITransport
    private var nextSequence: UInt32 = 1

    public init(transport: OTITransport) { self.transport = transport }

    public func login() throws {
        try sendFrame(payloadType: 0xA1, payload: OTIXML.loginPayload())
    }

    public func sendLoginCommand(name: String, osVersion: UInt8 = 0x28, codePage: UInt16 = 0) throws {
        try sendFrame(
            payloadType: 0x01,
            payload: OTIXML.loginCommandPayload(name: name, osVersion: osVersion, codePage: codePage)
        )
    }

    public func sendLoginResponse(requestCommand: UInt8 = 0x01, osVersion: UInt8 = 0x28) throws {
        try sendFrame(
            payloadType: 0xA1,
            payload: OTIXML.loginResponsePayload(requestCommand: requestCommand, requestResult: 0x00, osVersion: osVersion)
        )
    }

    public func sendDomainFolders(desktop: String, documents: String, music: String, pictures: String) throws {
        try sendFrame(
            payloadType: 0xAD,
            payload: OTIXML.domainFoldersPayload(desktop: desktop, documents: documents, music: music, pictures: pictures)
        )
    }

    public func sendDriveInfo(volumes: [(name: String, path: String, type: UInt8)]) throws {
        try sendFrame(
            payloadType: 0xA4,
            payload: OTIXML.driveInfoPayload(volumes: volumes)
        )
    }

    public func sendBridgeBlockStatusReply(blocked: Bool = false) throws {
        try sendFrame(payloadType: 0x39, payload: OTIXML.replayBridgeBlockStatusPayload(blocked: blocked))
    }

    public func sendClipboard(_ text: String) throws {
        try sendFrame(payloadType: 0x39, payload: OTIXML.clipboardPayload(text: text))
    }

    public func sendClipboardFiles(
        _ files: [(path: String, size: UInt64, createdAt: Date, modifiedAt: Date)]
    ) throws {
        try sendFrame(payloadType: 0x39, payload: OTIXML.clipboardFilesPayload(files: files))
    }

    public func sendSwitchAcknowledge() throws {
        try sendFrame(payloadType: 0x39, payload: OTIXML.switchAcknowledgePayload(
            capsLock: OTIXML.capsLockEngaged,
            naturalScroll: OTIXML.systemUsesNaturalScroll))
    }

    public func sendLoginSubCommand(requestCommand: UInt8 = 0x04, osVersion: UInt8 = 0x28) throws {
        try sendFrame(payloadType: 0xA1,
                      payload: OTIXML.loginSubCommandPayload(requestCommand: requestCommand,
                                                             osVersion: osVersion))
    }

    public func sendPostRemoteKMSetting(direction: Int, option: Int = 3) throws {
        try sendFrame(payloadType: 0x39,
                      payload: OTIXML.postRemoteKMSettingPayload(direction: direction, option: option))
    }

    public func sendRemoteScreenInfo(width: Int, height: Int, virtualX: Int = 0, virtualY: Int = 0) throws {
        try sendFrame(payloadType: 0x39,
                      payload: OTIXML.postRemoteScreenInfoPayload(
                          width: width, height: height, virtualX: virtualX, virtualY: virtualY))
    }

    public func sendSwitchToRemote(direction: Int, x: Int, y: Int, width: Int, height: Int) throws {
        try sendFrame(
            payloadType: 0x39,
            payload: OTIXML.switchToRemotePayload(direction: direction, x: x, y: y, width: width, height: height)
        )
    }

    public func sendSwitchToLocal() throws {
        try sendFrame(payloadType: 0x39, payload: OTIXML.switchToLocalPayload())
    }

    public func sendForceRemoteSwitchLocal(x: Int, y: Int, direction: Int) throws {
        try sendFrame(payloadType: 0x39, payload: OTIXML.forceRemoteSwitchLocalPayload(x: x, y: y, direction: direction))
    }

    public func sendDragFileIsBeginning() throws {
        try sendFrame(payloadType: 0x39, payload: OTIXML.dragFileIsBeginningPayload())
    }

    public func sendLateDropData(nodeInfoListXML: String) throws {
        try sendFrame(payloadType: 0x39, payload: OTIXML.lateSendDropDataPayload(nodeInfoListXML: nodeInfoListXML))
    }

    public func sendFileData(sessionFileID: UInt32, data: Data) throws {
        let chunkSize = 65000
        let total = max(1, (data.count + chunkSize - 1) / chunkSize)
        for index in 1...total {
            let start = (index - 1) * chunkSize
            let end = min(start + chunkSize, data.count)
            let chunk = data.isEmpty ? Data() : data.subdata(in: start..<end)
            let payload = OTIFileTransfer.encodeFileData(
                sessionFileID: sessionFileID,
                totalCount: UInt32(total),
                currentCountIndex: UInt32(index),
                data: chunk)
            try sendFrame(payloadType: 0xA3, payload: payload)
        }
    }

    public func sendFileStream(sessionFileID: UInt32, handle: FileHandle, fileSize: UInt64) throws {
        let chunkSize = 65000
        if fileSize == 0 {
            let payload = OTIFileTransfer.encodeFileData(
                sessionFileID: sessionFileID,
                totalCount: 1,
                currentCountIndex: 1,
                data: Data())
            try sendFrame(payloadType: 0xA3, payload: payload)
            return
        }
        let total = UInt32((fileSize + UInt64(chunkSize) - 1) / UInt64(chunkSize))
        var index: UInt32 = 1
        while index <= total {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            let payload = OTIFileTransfer.encodeFileData(
                sessionFileID: sessionFileID,
                totalCount: total,
                currentCountIndex: index,
                data: chunk)
            try sendFrame(payloadType: 0xA3, payload: payload)
            index += 1
        }
    }

    public func fulfillDownloadRequest(_ request: OTIFileTransfer.DownloadRequest,
                                       validatePath: ((String) -> Bool)? = nil,
                                       onSent: ((String, UInt64) -> Void)? = nil,
                                       onError: ((String) -> Void)? = nil) throws {
        try sendFrame(payloadType: 0xA1, payload: OTIFileTransfer.encodeDownloadAck(multiSessionID: request.multiSessionID))
        for file in request.files {
            let allowed = validatePath?(file.path) ?? file.path.hasPrefix("/Users/")
            guard allowed else {
                onError?("refused path: \(file.path)")
                continue
            }
            do {
                let url = URL(fileURLWithPath: file.path)
                let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
                let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
                let created = (attrs[.creationDate] as? Date) ?? Date()
                let modified = (attrs[.modificationDate] as? Date) ?? created
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }

                try sendFileStream(sessionFileID: file.fileID, handle: handle, fileSize: size)
                try sendFrame(
                    payloadType: 0x37,
                    payload: OTIFileTransfer.encodeFileAttributes(createdAt: created, modifiedAt: modified, accessedAt: modified))
                onSent?(file.path, size)
            } catch {
                onError?("\(file.path): \(error)")
            }
        }
        try sendFrame(payloadType: 0xA7, payload: OTIFileTransfer.encodeDownloadFinish(multiSessionID: request.multiSessionID))
    }

    public func read() throws -> OTIFrame? {
        guard let data = try transport.readFrame() else { return nil }
        return OTIFrame.decode(data)
    }

    public func sendFrame(payloadType: UInt8, payload: Data) throws {
        let frame = OTIFrame(sequence: nextSequence, payloadType: payloadType, payload: payload)
        nextSequence += 1
        let blocks = frame.encodedBlocks()
        if blocks.count == 1 {
            try transport.send(frame: blocks[0])
        } else if let multi = transport as? OTIMultiBlockTransport {
            try multi.sendBlocks(blocks)
        } else {
            for block in blocks {
                try transport.send(frame: block)
            }
        }
    }
}
