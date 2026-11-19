// OTIBridge.swift
// Translation between OTi uPipe XML and app-level events.

import Foundation

public struct KMSwitchMoveOutInfo: Equatable {
    public var moveOutX: Int
    public var moveOutY: Int
    public var remoteWidth: Int
    public var remoteHeight: Int
    public var direction: Int
}

public struct KMSwitchMoveInInfo: Equatable {
    public var direction: Int
    public var moveInX: Int
    public var moveInY: Int
}

public enum OTIBridge {
    public static let clipboardCommand = "Cmd_Transfer_Clipboard"
    public static let switchToRemote = "Cmd_Notify_KM_Switch_To_Remote"
    public static let switchToLocal = "Cmd_Notify_KM_Switch_To_Local"
    public static let notifySwitchBack = "Cmd_Notify_Remote_To_Switch_Back"
    public static let forceSwitchLocal = "Cmd_Force_Remote_To_Switch_Local"
    public static let switchAcknowledge = "Cmd_Get_KM_Switch_Acknowlege"
    public static let postRemoteScreenInfo = "Cmd_Post_Remote_Screen_Info"
    public static let postRemoteKMPreference = "Cmd_Post_Remote_KM_Preference_Setup_Info"
    public static let getRemoteDraggingInfo = "Cmd_Get_Remote_Dragging_Info"
    public static let dragFileIsBeginning = "Cmd_Drag_File_Is_Beginning"
    public static let lateSendDropData = "Cmd_Late_Send_Drop_Data"

    /// Extract text from a clipboard payload containing
    /// <CP_Content>UTF-16LE hex</CP_Content>.
    public static func clipboardText(from payload: Data) -> String? {
        guard let xml = String(data: payload, encoding: .utf8) else { return nil }
        // The two implementations use different tag names for the payload:
        // the Mac side sends `CP_Content` with `CB_Format_Text`, while Windows
        // sends `CP_Content_Text` (and sometimes `HTML Format`) — only handling
        // the first one made Windows -> Mac silently drop every clipboard.
        let candidates = ["CP_Content", "CP_Content_Text", "CP_Content_UnicodeText"]
        for name in candidates {
            guard let raw = tagValue(name, in: xml)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { continue }
            if let text = decodeClipboardPayload(raw), !text.isEmpty { return text }
        }
        return nil
    }

    /// Decodes the hex payload used by both sides: UTF-16LE with a trailing
    /// `0000`, falling back to UTF-8 for callers that send raw bytes.
    private static func decodeClipboardPayload(_ raw: String) -> String? {
        let hex = raw.filter { !$0.isWhitespace }
        if hex.count >= 2, hex.count % 2 == 0, hex.allSatisfy({ $0.isHexDigit }) {
            var bytes = [UInt8]()
            bytes.reserveCapacity(hex.count / 2)
            var index = hex.startIndex
            while index < hex.endIndex {
                let next = hex.index(index, offsetBy: 2)
                guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
                bytes.append(byte)
                index = next
            }
            while bytes.count >= 2 && bytes[bytes.count - 1] == 0 && bytes[bytes.count - 2] == 0 {
                bytes.removeLast(2)
            }
            guard !bytes.isEmpty else { return nil }
            if let text = String(data: Data(bytes), encoding: .utf16LittleEndian), !text.isEmpty {
                return text
            }
            return String(data: Data(bytes), encoding: .utf8)
        }
        // Not hex: the tag already carried plain text.
        return raw
    }

    /// Extract <NP_Cmd>...</NP_Cmd> from a uPipe XML payload.
    public static func command(from payload: Data) -> String? {
        guard let xml = String(data: payload, encoding: .utf8) else { return nil }
        return tagValue("NP_Cmd", in: xml)
    }

    /// Parse <Param_Move_Out_Info> fields from Cmd_Notify_KM_Switch_To_Remote.
    ///
    /// The same structure arrives escaped zero, one or two times depending on
    /// which side built it (`<Param_Move_Out_Info>` is placed inside
    /// `ExtraXmlParam`, and the inner `<OTIMSG>` may be entity-escaped), so try
    /// every unescaping level before giving up.
    public static func parseMoveOutInfo(from payload: Data) -> KMSwitchMoveOutInfo? {
        guard let xml = unescapeLevels(String(decoding: payload, as: UTF8.self),
                                      requiredTag: "Param_Move_Out_X") else { return nil }
        guard let moveOutX = tagInt("Param_Move_Out_X", in: xml),
              let moveOutY = tagInt("Param_Move_Out_Y", in: xml),
              let direction = tagInt("Param_Move_Out_Direction", in: xml) else {
            return nil
        }
        let remoteWidth = tagInt("Param_Remote_Screen_Width", in: xml) ?? 0
        let remoteHeight = tagInt("Param_Remote_Screen_Height", in: xml) ?? 0
        return KMSwitchMoveOutInfo(
            moveOutX: moveOutX,
            moveOutY: moveOutY,
            remoteWidth: remoteWidth,
            remoteHeight: remoteHeight,
            direction: direction)
    }

    public static func parseMoveInInfo(from payload: Data) -> KMSwitchMoveInInfo? {
        guard let xml = unescapeLevels(String(decoding: payload, as: UTF8.self),
                                      requiredTag: "Param_Move_In_X") else { return nil }
        guard let moveInX = tagInt("Param_Move_In_X", in: xml),
              let moveInY = tagInt("Param_Move_In_Y", in: xml),
              let direction = tagInt("Param_Move_In_Direction", in: xml) else {
            return nil
        }
        return KMSwitchMoveInInfo(direction: direction, moveInX: moveInX, moveInY: moveInY)
    }

    public static func parseScreenInfo(from payload: Data) -> (width: Int, height: Int)? {
        guard let xml = unescapeLevels(String(decoding: payload, as: UTF8.self),
                                       requiredTag: "Param_Remote_Screen_Width") else { return nil }
        guard let width = tagInt("Param_Remote_Screen_Width", in: xml),
              let height = tagInt("Param_Remote_Screen_Height", in: xml),
              width > 0, height > 0 else {
            return nil
        }
        return (width, height)
    }

    /// Returns the first escaping level that contains `requiredTag`, or nil.
    static func unescapeLevels(_ raw: String, requiredTag: String, maxLevels: Int = 3) -> String? {
        var current = raw
        for _ in 0...maxLevels {
            if current.contains("<\(requiredTag)>") { return current }
            let next = unescapedEntities(current)
            if next == current { break }
            current = next
        }
        return nil
    }

    public static func parsePeerKMPreference(from payload: Data) -> (switchMode: Int, clipOption: Int?, blocking: Int?)? {
        guard let xml = String(data: payload, encoding: .utf8),
              let mode = tagInt("KMSwitchMode", in: xml) else {
            return nil
        }
        return (switchMode: mode, clipOption: tagInt("ClipboardShareOption", in: xml),
                blocking: tagInt("BlockingBridge", in: xml))
    }

    private static func unescapedEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&dq;", with: "\"")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func tagInt(_ tag: String, in xml: String) -> Int? {
        guard let raw = tagValue(tag, in: xml)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return Int(raw)
    }

    private static func tagValue(_ tag: String, in xml: String) -> String? {
        guard let start = xml.range(of: "<\(tag)>"),
              let end = xml.range(of: "</\(tag)>", range: start.upperBound..<xml.endIndex) else {
            return nil
        }
        return String(xml[start.upperBound..<end.lowerBound])
    }
}
