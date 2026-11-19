import AppKit
import Foundation

// MARK: - Self-test (--selftest)

private final class MockOTITransport: OTIHIDTransport {
    private let lock = NSLock()
    var incoming: [Data] = []
    var sent: [Data] = []
    var sentHID: [(kind: UInt8, data12: [UInt8])] = []
    var hidMouseUsesRelativeReports: Bool = true
    var failNextSendCount: Int = 0
    var forcedSendError: Error?

    func send(frame: Data) throws {
        lock.lock()
        if let err = forcedSendError {
            lock.unlock()
            throw err
        }
        if failNextSendCount > 0 {
            failNextSendCount -= 1
            lock.unlock()
            throw NSError(domain: "KMLinkMock", code: 4, userInfo: [NSLocalizedDescriptionKey: "simulated bridge busy"])
        }
        sent.append(frame)
        lock.unlock()
    }

    func readFrame() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return incoming.isEmpty ? nil : incoming.removeFirst()
    }

    func sendHID(kind: UInt8, data12: [UInt8]) throws {
        lock.lock()
        sentHID.append((kind: kind, data12: data12))
        lock.unlock()
    }
}

private func assertTrue(_ cond: @autoclosure () -> Bool, _ message: String) throws {
    if !cond() {
        throw NSError(domain: "KMLinkSelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private func runSelfTest() -> Int32 {
    do {
        // 1. OTIFrame 0x39 BE TX + BE/LE RX decode
        let xmlPayload = OTIXML.switchAcknowledgePayload()
        let f39 = OTIFrame(sequence: 1, payloadType: 0x39, payload: xmlPayload)
        let raw39 = f39.transferData()
        try assertTrue(raw39.count == OTIFrame.frameSize, "0x39 transferData must be 64 KB")
        try assertTrue(raw39[0x14] == 0x39, "0x39 byte at 0x14")
        let innerBE = (Int(raw39[0x15]) << 24) | (Int(raw39[0x16]) << 16) | (Int(raw39[0x17]) << 8) | Int(raw39[0x18])
        try assertTrue(innerBE == xmlPayload.count, "0x39 TX inner length must be BE")
        try assertTrue(raw39[0..<20] == raw39[OTIFrame.mirrorOffset..<(OTIFrame.mirrorOffset + 20)], "0x39 mirror mismatch")
        let dec39BE = OTIFrame.decode(raw39)
        try assertTrue(dec39BE?.payloadType == 0x39 && dec39BE?.payload == xmlPayload, "0x39 BE decode round-trip")

        // Simulate Windows LE innerLen on RX
        var raw39LE = raw39
        let leLen = UInt32(xmlPayload.count)
        raw39LE[0x15] = UInt8(leLen & 0xFF)
        raw39LE[0x16] = UInt8((leLen >> 8) & 0xFF)
        raw39LE[0x17] = UInt8((leLen >> 16) & 0xFF)
        raw39LE[0x18] = UInt8((leLen >> 24) & 0xFF)
        let dec39LE = OTIFrame.decode(raw39LE)
        try assertTrue(dec39LE?.payloadType == 0x39 && dec39LE?.payload == xmlPayload, "0x39 LE decode round-trip")
        print("PASS: OTIFrame 0x39 BE/LE")

        // 2. OTIFrame 0xA1 ResponseResult / domainFolders (0xAD) / driveInfo (0xA4)
        let login = OTIXML.loginPayload()
        try assertTrue(login.count == 44, "login payload must be 44 bytes")
        try assertTrue(login[0] == 0xA1 && login[1] == 0x01 && login[20] == 0x03 && login[34] == 0x28, "0xA1 OSVERSION=0x28 layout")
        let decLoginMac = OTIXML.decodeResponseResult(login)
        try assertTrue(decLoginMac?.requestCommand == 0x01 && decLoginMac?.requestResult == 0 && decLoginMac?.remoteOSVersion == 0x28, "decode Mac 0xA1")
        let winA1Hex = "a1010007070707000000000000000000000000030a0000004f5356455253494f4e07"
        var winA1Bytes = [UInt8]()
        var idx = winA1Hex.startIndex
        while idx < winA1Hex.endIndex {
            let nxt = winA1Hex.index(idx, offsetBy: 2)
            winA1Bytes.append(UInt8(winA1Hex[idx..<nxt], radix: 16)!)
            idx = nxt
        }
        let decLoginWin = OTIXML.decodeResponseResult(Data(winA1Bytes))
        try assertTrue(decLoginWin?.requestCommand == 0x01 && decLoginWin?.requestResult == 0 && decLoginWin?.remoteOSVersion == 0x07, "decode Windows 0xA1")

        let fA1 = OTIFrame(sequence: 1, payloadType: 0xA1, payload: login)
        try assertTrue(fA1.payloadLength == 44, "0xA1 payloadLength must be 44")
        let rawA1 = fA1.transferData()
        try assertTrue(rawA1[0x14] == 0xA1 && rawA1[0x15] == 0x01, "0xA1 must not duplicate command byte")
        let decA1 = OTIFrame.decode(rawA1)
        try assertTrue(decA1?.payloadType == 0xA1 && decA1?.payload == login, "0xA1 decode round-trip")

        let folders = OTIXML.domainFoldersPayload(desktop: "/Users/test/Desktop", documents: "/Users/test/Documents", music: "/Users/test/Music", pictures: "/Users/test/Pictures")
        try assertTrue(folders[0] == 0xAD && folders[5] == 4, "0xAD DomainFolders header")
        let drives = OTIXML.driveInfoPayload(volumes: [(name: "Macintosh HD", path: "/", type: 0x14)])
        try assertTrue(drives[0] == 0xA4 && drives[1] == 1 && drives[2] == 0 && drives[3] == 0 && drives[4] == 0x14, "0xA4 DriveInfo header")
        print("PASS: OTIFrame 0xA1 / 0xAD / 0xA4")

        // 3. OTIFileTransfer 0x10 parse from real capture bytes
        let pathUTF16 = "//Users/testuser/Desktop/sample-document.docx".data(using: .utf16LittleEndian)!
        var p10 = Data([0x10, 0xce, 0x0f, 0x25, 0x03, 0x01, 0x00, 0xcf, 0x0f, 0x25, 0x03])
        let plen = UInt16(pathUTF16.count)
        p10.append(UInt8(plen & 0xff))
        p10.append(UInt8(plen >> 8))
        p10.append(pathUTF16)
        let raw10 = OTIFrame(sequence: 0x03250fd0, payloadType: 0x10, payload: p10).transferData()
        let dec10 = OTIFrame.decode(raw10)
        try assertTrue(dec10?.payloadType == 0x10, "0x10 frame decode")
        let req10 = dec10.flatMap { OTIFileTransfer.parseDownloadRequest($0.payload) }
        try assertTrue(req10?.multiSessionID == 0x03250fce, "0x10 multiSessionID")
        try assertTrue(req10?.files.first?.fileID == 0x03250fcf, "0x10 fileID")
        try assertTrue(req10?.files.first?.path == "/Users/testuser/Desktop/sample-document.docx", "0x10 path")
        print("PASS: OTIFileTransfer 0x10 parse")

        // 4. OTIFileTransfer 0xA3 / 0xA1 / 0x37 / 0xA7
        let sampleData = Data("PK\u{03}\u{04}hello-oti-file".utf8)
        let pA3 = OTIFileTransfer.encodeFileData(sessionFileID: 0x03250fcf, totalCount: 1, currentCountIndex: 1, data: sampleData)
        let rawA3 = OTIFrame(sequence: 8, payloadType: 0xA3, payload: pA3).transferData()
        try assertTrue(rawA3[0x14] == 0xA3 && rawA3[0x15] == 0x03 && rawA3[0x18] == 0xcf, "0xA3 header layout")
        let decA3 = OTIFrame.decode(rawA3)
        let parsedA3 = decA3.flatMap { OTIFileTransfer.parseFileData($0.payload) }
        try assertTrue(parsedA3?.sessionFileID == 0x03250fcf && parsedA3?.data == sampleData && parsedA3?.truncated == false, "0xA3 decode")

        let ack34 = OTIFileTransfer.encodeDownloadAck(multiSessionID: 0x03250fce)
        try assertTrue(ack34.count == 34 && ack34[0] == 0xA1 && ack34[1] == 0x10 && ack34[3] == 0x03 && ack34[6] == 0xce, "0xA1 ack layout")
        let attr33 = OTIFileTransfer.encodeFileAttributes(createdAt: Date(), modifiedAt: Date(), accessedAt: Date())
        try assertTrue(attr33.count == 33 && attr33[0] == 0x37, "0x37 attr layout")
        let fin5 = OTIFileTransfer.encodeDownloadFinish(multiSessionID: 0x03250fce)
        try assertTrue(fin5 == Data([0xA7, 0x03, 0x25, 0x0f, 0xce]), "0xA7 finish layout")
        print("PASS: OTIFileTransfer 0xA3 / 0xA1 / 0x37 / 0xA7")

        // 5. NodeInfo 824B + Cmd_Late_Send_Drop_Data exact length check
        let now = Date()
        let nodeXML = OTIFileTransfer.nodeInfoListXML(files: [
            (path: "/Users/testuser/Desktop/sample-document.docx", size: 11459, createdAt: now, modifiedAt: now)
        ])
        let dropPayload = OTIXML.lateSendDropDataPayload(nodeInfoListXML: nodeXML)
        try assertTrue(dropPayload.count == 1998, "Cmd_Late_Send_Drop_Data payload must be 1998 bytes, got \(dropPayload.count)")
        let parsedNodes = OTIFileTransfer.parseNodeInfoList(Data(nodeXML.utf8))
        try assertTrue(parsedNodes.count == 1 && parsedNodes[0].size == 11459 && parsedNodes[0].path == "/Users/testuser/Desktop/sample-document.docx", "NodeInfo round-trip")
        print("PASS: NodeInfo 824B & LateSendDropData (1998B)")

        // 6. OTIBridge clipboard & KM switch parsing
        let clipPayload = OTIXML.clipboardPayload(text: "KMLink测试123")
        try assertTrue(OTIBridge.command(from: clipPayload) == OTIBridge.clipboardCommand, "clipboard command")
        try assertTrue(OTIBridge.clipboardText(from: clipPayload) == "KMLink测试123", "clipboard UTF-16LE round-trip")

        let switchXML = """
        <ExtraXmlCommand>HookAppService</ExtraXmlCommand><ExtraXmlParam><OTIMSG><NP_Cmd>Cmd_Notify_KM_Switch_To_Remote</NP_Cmd><NP_Up_Notice_NamePipe_Name>\\\\.\\pipe\\OTI_ClipboardAgent</NP_Up_Notice_NamePipe_Name><Param_Move_Out_Info><OTIMSG><Param_Move_Out_Direction>2</Param_Move_Out_Direction><Param_Move_Out_X>3860</Param_Move_Out_X><Param_Move_Out_Y>922</Param_Move_Out_Y><Param_Remote_Screen_Width>3840</Param_Remote_Screen_Width><Param_Remote_Screen_Height>2160</Param_Remote_Screen_Height></OTIMSG></Param_Move_Out_Info></OTIMSG></ExtraXmlParam>
        """
        let moveOut = OTIBridge.parseMoveOutInfo(from: Data(switchXML.utf8))
        try assertTrue(moveOut == KMSwitchMoveOutInfo(moveOutX: 3860, moveOutY: 922, remoteWidth: 3840, remoteHeight: 2160, direction: 2), "parseMoveOutInfo")
        let escapedSwitchXML = "<ExtraXmlCommand>HookAppService</ExtraXmlCommand><ExtraXmlParam><OTIMSG><NP_Cmd>Cmd_Notify_KM_Switch_To_Remote</NP_Cmd><Param_Move_Out_Info>&lt;OTIMSG&gt;&lt;Param_Move_Out_Direction&gt;1&lt;/Param_Move_Out_Direction&gt;&lt;Param_Move_Out_X&gt;10&lt;/Param_Move_Out_X&gt;&lt;Param_Move_Out_Y&gt;500&lt;/Param_Move_Out_Y&gt;&lt;Param_Remote_Screen_Width&gt;1920&lt;/Param_Remote_Screen_Width&gt;&lt;Param_Remote_Screen_Height&gt;1080&lt;/Param_Remote_Screen_Height&gt;&lt;/OTIMSG&gt;</Param_Move_Out_Info></OTIMSG></ExtraXmlParam>"
        try assertTrue(
            OTIBridge.parseMoveOutInfo(from: Data(escapedSwitchXML.utf8)) == KMSwitchMoveOutInfo(moveOutX: 10, moveOutY: 500, remoteWidth: 1920, remoteHeight: 1080, direction: 1),
            "parseMoveOutInfo escaped entities"
        )
        let moveInXML = "<OTIMSG><NP_Cmd>Cmd_Force_Remote_To_Switch_Local</NP_Cmd><Param_Move_In_Info><OTIMSG><Param_Move_In_Direction>2</Param_Move_In_Direction><Param_Move_In_X>5</Param_Move_In_X><Param_Move_In_Y>420</Param_Move_In_Y></OTIMSG></Param_Move_In_Info></OTIMSG>"
        try assertTrue(
            OTIBridge.parseMoveInInfo(from: Data(moveInXML.utf8)) == KMSwitchMoveInInfo(direction: 2, moveInX: 5, moveInY: 420),
            "parseMoveInInfo"
        )
        // Move-out geometry must survive one or two entity-escaping levels.
        let plainInfo = "<OTIMSG><Param_Move_Out_X>1511</Param_Move_Out_X><Param_Move_Out_Y>400</Param_Move_Out_Y><Param_Move_Out_Direction>2</Param_Move_Out_Direction><Param_Remote_Screen_Width>1512</Param_Remote_Screen_Width><Param_Remote_Screen_Height>982</Param_Remote_Screen_Height></OTIMSG>"
        let onceEscaped = plainInfo
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let twiceEscaped = onceEscaped
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let wrapper = "<ExtraXmlCommand>HookAppService</ExtraXmlCommand><ExtraXmlParam><OTIMSG><NP_Cmd>Cmd_Notify_KM_Switch_To_Remote</NP_Cmd><Param_Move_Out_Info>" 
        for (level, body) in [("plain", plainInfo), ("once", onceEscaped), ("twice", twiceEscaped)] {
            let payload = Data((wrapper + body + "</Param_Move_Out_Info></OTIMSG></ExtraXmlParam>").utf8)
            let parsed = OTIBridge.parseMoveOutInfo(from: payload)
            try assertTrue(parsed == KMSwitchMoveOutInfo(moveOutX: 1511, moveOutY: 400, remoteWidth: 1512, remoteHeight: 982, direction: 2),
                           "parseMoveOutInfo \(level)-escaped")
        }
        print("PASS: OTIBridge clipboard & KM switch")

        // 7. USBLink mock-transport end-to-end flow (clipboard, KM switch, drag info, 0x10 -> 0xA3)
        let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("kmlink-selftest-\(UUID().uuidString).bin")
        let tmpContent = Data("USB-OTi-File-Payload-0123456789".utf8)
        try tmpContent.write(to: tmpFile)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let mock = MockOTITransport()
        let link = USBLink(transport: mock)
        var gotClip: String?
        var gotSwitch: KMSwitchMoveOutInfo?
        var gotSentSize: UInt64 = 0
        link.onClipboard = { gotClip = $0 }
        link.onKMSwitchToLocal = { gotSwitch = $0 }
        link.onFileSent = { _, sz in gotSentSize = sz }
        link.stageFiles([tmpFile])
        try link.start()

        // Queue incoming frames: clipboard, switch, get dragging info, 0x10 download
        let reqPathBytes = ("/" + tmpFile.path).data(using: .utf16LittleEndian)!
        var dlPayload = Data([0x10, 0x11, 0x22, 0x33, 0x44, 0x01, 0x00, 0x55, 0x66, 0x77, 0x88])
        dlPayload.append(UInt8(reqPathBytes.count & 0xff))
        dlPayload.append(UInt8(reqPathBytes.count >> 8))
        dlPayload.append(reqPathBytes)

        // Also verify decoding Windows-style 0x01 LoginCommand frame
        let winLoginPayload = Data([0x01, 0x07, 0xa8, 0x03, 0x06, 0x57, 0x49, 0x4e, 0x50, 0x43, 0x31])
        let winLoginFrame = OTIFrame(sequence: 9, payloadType: 0x01, payload: winLoginPayload).transferData()
        let winDecoded = OTIFrame.decode(winLoginFrame)
        let winLoginInfo = winDecoded.flatMap { OTIXML.decodeLoginCommand($0.payload) }
        try assertTrue(
            winLoginInfo == OTIXML.LoginCommandInfo(osVersion: 0x07, codePage: 936, name: "WINPC1"),
            "Windows LoginCommand decode"
        )

        let switchOutXML = String(data: OTIXML.switchToRemotePayload(direction: 1, x: 0, y: 400, width: 1512, height: 982), encoding: .utf8) ?? ""
        try assertTrue(switchOutXML.contains("<Param_Move_Out_Direction>1</Param_Move_Out_Direction>"), "switchToRemote direction")
        try assertTrue(switchOutXML.contains("<Param_Other_PC_Position_Option>"), "switchToRemote Other_PC_Position_Option")
        try assertTrue(switchOutXML.contains("<Param_KM_Setting_Info>"), "switchToRemote KM_Setting_Info")
        print("PASS: switchToRemotePayload XML=\(switchOutXML)")

        mock.incoming = [
            OTIFrame(sequence: 9, payloadType: 0x01, payload: winLoginPayload).transferData(),
            OTIFrame(sequence: 10, payloadType: 0xA1, payload: Data(winA1Bytes)).transferData(),
            OTIFrame(sequence: 11, payloadType: 0x39, payload: OTIXML.clipboardPayload(text: "hello-usb")).transferData(),
            OTIFrame(sequence: 12, payloadType: 0x39, payload: Data(switchXML.utf8)).transferData(),
            OTIFrame(sequence: 13, payloadType: 0x39, payload: OTIXML.envelope("<OTIMSG><NP_Cmd>Cmd_Get_Remote_Dragging_Info</NP_Cmd></OTIMSG>")).transferData(),
            OTIFrame(sequence: 14, payloadType: 0x10, payload: dlPayload).transferData()
        ]
        try link.pump()

        try assertTrue(gotClip == "hello-usb", "USBLink clipboard callback")
        try assertTrue(gotSwitch == moveOut, "USBLink switch callback")
        try assertTrue(gotSentSize == UInt64(tmpContent.count), "USBLink file sent callback")

        let sentDecoded = mock.sent.compactMap { OTIFrame.decode($0) }
        // Expected TX sequence: 0x01 LoginCommand (on start), then on the incoming
        // 0x01 LoginCommand a full handshake (0xA1 ResponseResult, own 0x01
        // LoginCommand re-announcement, 0xAD DomainFolders, 0xA4 DriveInfo), then
        // 0x39 switchAck, 0x39 DragBeginning, 0x39 LateDrop, 0xA1 dlAck, 0xA3 data,
        // 0x37 attr, 0xA7 finish.
        // The login handshake now also announces the login sub-command (0xA1
        // cmd=0x04) and our screen geometry (Cmd_Post_Remote_Screen_Info), so the
        // announcement block is six frames instead of four.
        try assertTrue(sentDecoded.count == 16, "USBLink expected 16 TX frames, got \(sentDecoded.count)")
        try assertTrue(sentDecoded[0].payloadType == 0x01, "TX[0] LoginCommand")
        let txLogin = OTIXML.decodeLoginCommand(sentDecoded[0].payload)
        try assertTrue(txLogin?.osVersion == 0x10 && !(txLogin?.name.isEmpty ?? true),
                       "TX[0] LoginCommand payload (original Mac form: flags=0x10 + name)")
        try assertTrue(
            sentDecoded[1].payloadType == 0xA1 && OTIXML.decodeResponseResult(sentDecoded[1].payload)?.remoteOSVersion == 0x28,
            "TX[1] Login ACK 0xA1 (got type=0x\(String(format: "%02x", sentDecoded[1].payloadType)) len=\(sentDecoded[1].payload.count) hex=\(sentDecoded[1].payload.prefix(44).map { String(format: "%02x", $0) }.joined()))"
        )
        try assertTrue(sentDecoded[2].payloadType == 0x01 && OTIXML.decodeLoginCommand(sentDecoded[2].payload)?.osVersion == 0x10,
                       "TX[2] LoginCommand re-announcement")
        try assertTrue(sentDecoded[3].payloadType == 0xAD, "TX[3] DomainFolders")
        try assertTrue(sentDecoded[4].payloadType == 0xA4, "TX[4] DriveInfo")
        try assertTrue(sentDecoded[5].payloadType == 0xA1 && sentDecoded[5].payload.count == 34
                        && sentDecoded[5].payload[1] == 0x04, "TX[5] login sub-command 0xA1 cmd=0x04")
        try assertTrue(OTIBridge.command(from: sentDecoded[6].payload) == "Cmd_Post_Remote_Screen_Info",
                       "TX[6] screen info")
        try assertTrue(OTIBridge.command(from: sentDecoded[7].payload) == "Cmd_Post_Remote_KM_Setting_Info",
                       "TX[7] KM setting announcement")
        try assertTrue(OTIBridge.command(from: sentDecoded[8].payload) == OTIBridge.switchAcknowledge,
                       "TX[8] capability ack announcement")
        try assertTrue(OTIBridge.command(from: sentDecoded[9].payload) == OTIBridge.switchAcknowledge, "TX[9] switchAck")
        try assertTrue(OTIBridge.command(from: sentDecoded[10].payload) == OTIBridge.dragFileIsBeginning, "TX[10] dragBegin")
        try assertTrue(OTIBridge.command(from: sentDecoded[11].payload) == OTIBridge.lateSendDropData, "TX[11] lateDrop")
        try assertTrue(sentDecoded[12].payloadType == 0xA1, "TX[12] dlAck")
        try assertTrue(sentDecoded[13].payloadType == 0xA3, "TX[13] fileData")
        try assertTrue(OTIFileTransfer.parseFileData(sentDecoded[13].payload)?.data == tmpContent, "TX[12] fileData bytes")
        try assertTrue(sentDecoded[14].payloadType == 0x37, "TX[14] fileAttr")
        try assertTrue(sentDecoded[15].payloadType == 0xA7, "TX[15] dlFinish")

        // Verify USB Master KM TX (SwitchToRemote + HID D9 33/34 + SwitchToLocal + Ack RX + ForceSwitchLocal RX)
        var gotAck = false
        link.onKMSwitch = { if $0 == OTIBridge.switchAcknowledge { gotAck = true } }
        var endedInfo: KMSwitchMoveInInfo?
        link.onKMRemoteEnded = { endedInfo = $0 }
        link.pointerPrePositionEnabled = false
        try link.sendSwitchToRemote(direction: 1, x: 0, y: 400, width: 1512, height: 982)
        try link.sendHID(event: KMEvent(kind: "mouseMoved", dx: 12, dy: -4))
        try link.sendHID(event: KMEvent(kind: "mouseDown", button: 0))
        try link.sendHID(event: KMEvent(kind: "keyDown", keyCode: 0, flags: 0))
        try link.sendHID(event: KMEvent(kind: "keyUp", keyCode: 0, flags: 0))
        try link.sendHID(event: KMEvent(kind: "mouseUp", button: 0))
        try link.sendSwitchToLocal()
        try assertTrue(mock.sentHID.count == 5, "Expected 5 HID packets, got \(mock.sentHID.count)")
        // Relative mouse report (bridge descriptor is 4 bytes, no report id):
        // [buttons, dx, dy, wheel].
        try assertTrue(mock.sentHID[0].kind == 0x33 && mock.sentHID[0].data12[0] == 0x00
            && mock.sentHID[0].data12[1] == 12 && mock.sentHID[0].data12[2] == UInt8(bitPattern: -4),
            "HID mouse move layout")
        try assertTrue(mock.sentHID[1].kind == 0x33 && mock.sentHID[1].data12[0] == 0x01, "HID mouse down")
        try assertTrue(mock.sentHID[2].kind == 0x34 && mock.sentHID[2].data12[0] == 0 && mock.sentHID[2].data12[2] == 4, "HID keyDown A")
        try assertTrue(mock.sentHID[3].kind == 0x34 && mock.sentHID[3].data12[2] == 0, "HID keyUp A")
        try assertTrue(mock.sentHID[4].kind == 0x33 && mock.sentHID[4].data12[0] == 0x00, "HID mouse up")
        let masterFrames = mock.sent.dropFirst(16).compactMap { OTIFrame.decode($0) }
        // SwitchToRemote also pre-positions the peer pointer, which is disabled
        // above for this mock, so only the XML frames remain.
        try assertTrue(masterFrames.count == 2, "Expected 2 master XML frames, got \(masterFrames.count)")
        try assertTrue(OTIBridge.command(from: masterFrames[0].payload) == OTIBridge.switchToRemote, "Master TX[0] switchToRemote")
        try assertTrue(OTIBridge.parseMoveOutInfo(from: masterFrames[0].payload)?.direction == 1, "Master TX[0] direction")
        try assertTrue(OTIBridge.command(from: masterFrames[1].payload) == OTIBridge.switchToLocal, "Master TX[1] switchToLocal")
        mock.incoming = [
            OTIFrame(sequence: 15, payloadType: 0x39, payload: OTIXML.switchAcknowledgePayload()).transferData(),
            OTIFrame(sequence: 16, payloadType: 0x39, payload: Data(moveInXML.utf8)).transferData()
        ]
        try link.pump()
        try assertTrue(gotAck, "RX Cmd_Get_KM_Switch_Acknowlege")
        try assertTrue(endedInfo == KMSwitchMoveInInfo(direction: 2, moveInX: 5, moveInY: 420), "RX Cmd_Force_Remote_To_Switch_Local")
        print("PASS: USBLink end-to-end mock session")

        // 8. KMEngine coordinate math
        let macUnion = CGRect(x: 0, y: 0, width: 1512, height: 982)
        if let moveOut {
            let pt = KMEngine.entryPoint(from: moveOut, in: macUnion)
            let expectedY = CGFloat(922.0 / 2160.0) * 982.0
            try assertTrue(abs(pt.x - 3.0) < 0.01 && abs(pt.y - expectedY) < 0.5, "KMEngine entryPoint math")
        }
        try assertTrue(KMEngine.returnDirection(from: 2, fallbackPeerPosition: "right") == 1, "returnDirection 2->1")
        try assertTrue(KMEngine.returnDirection(from: 1, fallbackPeerPosition: "left") == 2, "returnDirection 1->2")
        let appkitPt = CGPoint(x: 100, y: 200)
        let cgPt = KMEngine.cgPoint(fromAppKit: appkitPt)
        let mainH = CGDisplayBounds(CGMainDisplayID()).height
        try assertTrue(abs(cgPt.x - 100) < 0.01 && abs(cgPt.y - (mainH - 200)) < 0.01, "cgPoint(fromAppKit:)")
        // Original CKMEvent::SendMouseEvent damping: large deltas are halved,
        // then clamped to the int8 range of the relative HID report.
        try assertTrue(USBLink.dampedRelativeDelta(0) == 0, "damp 0")
        try assertTrue(USBLink.dampedRelativeDelta(12) == 12, "damp small")
        try assertTrue(USBLink.dampedRelativeDelta(40) == 20, "damp 40 -> 20")
        try assertTrue(USBLink.dampedRelativeDelta(-100) == -50, "damp -100 -> -50")
        try assertTrue(USBLink.dampedRelativeDelta(1000) == 127, "damp clamp +127")
        try assertTrue(USBLink.dampedRelativeDelta(-1000) == -127, "damp clamp -127")
        print("PASS: HID relative delta damping")

        let edgeUnion = CGRect(x: 0, y: 0, width: 1512, height: 982)
        try assertTrue(KMEngine.edgeIsOutward(peerPosition: "right", point: CGPoint(x: 1511, y: 500), dx: 4, dy: 0, union: edgeUnion, tolerance: 1), "right edge outward")
        try assertTrue(!KMEngine.edgeIsOutward(peerPosition: "right", point: CGPoint(x: 1511, y: 500), dx: -4, dy: 0, union: edgeUnion, tolerance: 1), "right edge inward")
        try assertTrue(KMEngine.edgeIsOutward(peerPosition: "left", point: CGPoint(x: 0, y: 500), dx: -3, dy: 0, union: edgeUnion, tolerance: 1), "left edge outward")
        try assertTrue(!KMEngine.edgeIsOutward(peerPosition: "left", point: CGPoint(x: 400, y: 500), dx: -3, dy: 0, union: edgeUnion, tolerance: 1), "left not at edge")
        try assertTrue(KMEngine.edgeIsOutward(peerPosition: "down", point: CGPoint(x: 500, y: 981), dx: 0, dy: 7, union: edgeUnion, tolerance: 1), "bottom edge outward")
        try assertTrue(!KMEngine.edgeIsOutward(peerPosition: "down", point: CGPoint(x: 500, y: 981), dx: 0, dy: -7, union: edgeUnion, tolerance: 1), "bottom edge inward")
        print("PASS: KMEngine edge detection")

        // 9. Multi-block OTi framing (200 KB with 0x00 bytes across fragment boundaries)
        var largePayload = Data(count: 200_000)
        for i in 0..<largePayload.count {
            if i == 0 {
                largePayload[i] = 0x3A
            } else if (65_480...65_510).contains(i) || (130_980...131_010).contains(i) {
                largePayload[i] = 0x00
            } else {
                largePayload[i] = UInt8((i * 7 + 3) & 0xFF)
            }
        }
        let bigFrame = OTIFrame(sequence: 0x01020304, payloadType: 0x3A, payload: largePayload)
        let txBlocks = bigFrame.encodedBlocks()
        try assertTrue(txBlocks.count == 4, "200 KB frame should split into 4 blocks, got \(txBlocks.count)")
        for (idx, blk) in txBlocks.enumerated() {
            try assertTrue(blk.count == OTIFrame.frameSize, "Block \(idx) must be 64 KB")
            let fragIdx = UInt32(blk[8]) | (UInt32(blk[9]) << 8) | (UInt32(blk[10]) << 16) | (UInt32(blk[11]) << 24)
            let fragTotal = UInt32(blk[12]) | (UInt32(blk[13]) << 8) | (UInt32(blk[14]) << 16) | (UInt32(blk[15]) << 24)
            try assertTrue(fragIdx == UInt32(idx) && fragTotal == 4, "Block \(idx) fragment header mismatch")
        }
        var assembler = OTIBlockAssembler()
        var reassembled: Data?
        for (idx, blk) in txBlocks.enumerated() {
            let out = assembler.feed([UInt8](blk))
            if idx < txBlocks.count - 1 {
                try assertTrue(out == nil, "Intermediate block \(idx) must not emit early")
            } else {
                reassembled = out
            }
        }
        try assertTrue(reassembled != nil, "Assembler must emit on last block")
        let decodedBig = reassembled.flatMap { OTIFrame.decode($0) }
        try assertTrue(decodedBig?.sequence == 0x01020304 && decodedBig?.payloadType == 0x3A, "Reassembled big frame header")
        try assertTrue(decodedBig?.payload == largePayload, "Reassembled big frame payload byte-for-byte")
        print("PASS: Multi-block OTIFrame encodedBlocks + OTIBlockAssembler round-trip")

        // 10. UTF-16BE 0x10 DownloadMultipleFile + 0x3a MultipleFilePackage + 0xA9 ErrorResponse
        let winSrcPath = #"C:\Users\testuser\Downloads\测试文件清单.xlsx"#
        let macDstPath = "/Users/test/Downloads/测试文件清单.xlsx"
        let reqBE = OTIFileTransfer.encodeDownloadRequest(
            multiSessionID: 0x11223344,
            files: [(fileID: 0xAABBCCDD, path: winSrcPath, destinationPath: macDstPath, rawPath: nil)]
        )
        let expectedSrcBE = winSrcPath.data(using: .utf16BigEndian)! + Data([0x00, 0x00])
        let expectedDstBE = macDstPath.data(using: .utf16BigEndian)! + Data([0x00, 0x00])
        var expectedReq10 = Data([0x10, 0x11, 0x22, 0x33, 0x44, 0x00, 0x01, 0xAA, 0xBB, 0xCC, 0xDD])
        expectedReq10.append(UInt8(expectedSrcBE.count >> 8))
        expectedReq10.append(UInt8(expectedSrcBE.count & 0xFF))
        expectedReq10.append(expectedSrcBE)
        expectedReq10.append(UInt8(expectedDstBE.count >> 8))
        expectedReq10.append(UInt8(expectedDstBE.count & 0xFF))
        expectedReq10.append(expectedDstBE)
        try assertTrue(reqBE == expectedReq10, "0x10 Chinese UTF-16BE byte-exact match")

        // Build 0x3a MultipleFilePackage containing two Windows-LE 0xA3 chunks + one 0x37 attr
        func winSubA3(fileID: UInt32, totalCount: UInt32, index: UInt32, data: Data) -> Data {
            var out = Data([0xA3])
            for v in [fileID, totalCount, index, UInt32(data.count)] {
                var le = v.littleEndian
                withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
            }
            out.append(data)
            return out
        }
        func winFinA7(sessionID: UInt32) -> Data {
            var out = Data([0xA7])
            var le = sessionID.littleEndian
            withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
            return out
        }
        var chunkBytes = Data(count: 200_000)
        for i in 0..<chunkBytes.count {
            chunkBytes[i] = (65_480...65_520).contains(i) ? 0x00 : UInt8((i * 13 + 5) & 0xFF)
        }
        let splitIdx = 130_000
        let part1 = chunkBytes.subdata(in: 0..<splitIdx)
        let part2 = chunkBytes.subdata(in: splitIdx..<chunkBytes.count)
        let subA3_1 = winSubA3(fileID: 0x22334455, totalCount: 2, index: 1, data: part1)
        let subA3_2 = winSubA3(fileID: 0x22334455, totalCount: 2, index: 2, data: part2)
        let sub37 = OTIFileTransfer.encodeFileAttributes(createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                                       modifiedAt: Date(timeIntervalSince1970: 1_700_001_000),
                                                       accessedAt: Date(timeIntervalSince1970: 1_700_002_000))
        var pkg3a = Data([0x3A, 0x03, 0x00, 0x00, 0x00])
        pkg3a.append(Data(count: 11))
        pkg3a.append(subA3_1)
        pkg3a.append(subA3_2)
        pkg3a.append(sub37)
        let parsedPkg = OTIFileTransfer.parseMultipleFilePackage(pkg3a)
        try assertTrue(parsedPkg != nil, "0x3a MultipleFilePackage parse")

        var errA9 = Data([0xA9, 0x44, 0x33, 0x22, 0x11, 0x02, 0x00, 0x00, 0x00, 0x55, 0x44, 0x33, 0x22])
        errA9.append(Data("ErrStr".utf8))
        let errMsgData = "File in use".data(using: .utf16LittleEndian)!
        let errMsgLen = UInt32(errMsgData.count)
        errA9.append(Data([UInt8(errMsgLen & 0xFF), UInt8((errMsgLen >> 8) & 0xFF),
                           UInt8((errMsgLen >> 16) & 0xFF), UInt8((errMsgLen >> 24) & 0xFF)]))
        errA9.append(errMsgData)
        let parsedErr = OTIFileTransfer.parseErrorResponse(errA9)
        try assertTrue(parsedErr != nil, "0xA9 ErrorResponse parse")
        print("PASS: 0x10 UTF-16BE + 0x3a MultipleFilePackage + 0xA9 ErrorResponse")

        // 11. USBLink bidirectional file transfer mock tests (sendClipboardFiles + Win->Mac large Chinese RX + 0xA9 error)
        let biDirTmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("kmlink-bi-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: biDirTmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: biDirTmpDir) }
        let localSendFile = biDirTmpDir.appendingPathComponent("macToWin-测试.bin")
        var localSendData = Data(count: 70_000)
        for i in 0..<localSendData.count { localSendData[i] = UInt8((i * 11 + 1) & 0xFF) }
        try localSendData.write(to: localSendFile)

        let biMock = MockOTITransport()
        let biLink = USBLink(transport: biMock)
        biLink.downloadsDirectory = biDirTmpDir.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: biLink.downloadsDirectory, withIntermediateDirectories: true)
        var biReceivedURL: URL?
        var biErrors: [String] = []
        var biReceiveFailed: [String] = []
        var biSentPath: String?
        var biSentBytes: UInt64 = 0
        var biLogs: [String] = []
        biLink.onLog = { biLogs.append($0) }
        biLink.onFileReceived = { url in biReceivedURL = url }
        biLink.onFileReceiveFailed = { biReceiveFailed.append($0) }
        biLink.onFileError = { biErrors.append($0) }
        biLink.onFileSent = { path, sz in biSentPath = path; biSentBytes = sz }
        try biLink.start()

        // Complete login so file transfer & clipboard sending are active
        biMock.incoming = [
            OTIFrame(sequence: 1, payloadType: 0x01, payload: winLoginPayload).transferData(),
            OTIFrame(sequence: 2, payloadType: 0xA1, payload: Data(winA1Bytes)).transferData()
        ]
        try biLink.pump()
        biMock.sent.removeAll()

        // 11a. Mac -> Win clipboard file send
        try biLink.sendClipboardFiles([localSendFile])
        let clipTxFrames = biMock.sent.compactMap { OTIFrame.decode($0) }
        try assertTrue(clipTxFrames.count == 1, "sendClipboardFiles emits 1 XML frame")
        let clipTxXML = String(data: clipTxFrames[0].payload, encoding: .utf8) ?? ""
        let clipTxNodes = OTIFileTransfer.parseNodeInfoList(clipTxFrames[0].payload)
        try assertTrue(clipTxXML.contains("Cmd_Transfer_Clipboard") && clipTxXML.contains("CB_Format_File")
                       && clipTxNodes.count == 1 && clipTxNodes[0].path == localSendFile.path
                       && clipTxNodes[0].size == UInt64(localSendData.count),
                       "sendClipboardFiles XML/NodeInfo content")

        // Simulate Windows sending 0x10 download request for staged/clipboard Mac file (70 KB -> >1 chunk)
        biMock.sent.removeAll()
        let macReqPathBytes = ("/" + localSendFile.path).data(using: .utf16LittleEndian)!
        var winDlReq = Data([0x10, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00])
        winDlReq.append(UInt8(macReqPathBytes.count & 0xFF))
        winDlReq.append(UInt8(macReqPathBytes.count >> 8))
        winDlReq.append(macReqPathBytes)
        biMock.incoming = [OTIFrame(sequence: 3, payloadType: 0x10, payload: winDlReq).transferData()]
        try biLink.pump()
        let macToWinTx = biMock.sent.compactMap { OTIFrame.decode($0) }
        let reassembledSent = macToWinTx
            .filter { $0.payloadType == 0xA3 }
            .compactMap { OTIFileTransfer.parseFileData($0.payload)?.data }
            .reduce(Data(), +)
        try assertTrue(biSentPath == localSendFile.path && biSentBytes == UInt64(localSendData.count), "Mac->Win onFileSent stats")
        try assertTrue(reassembledSent == localSendData, "Mac->Win streamed 0xA3 chunks match exact 70 KB bytes")
        try assertTrue(macToWinTx.last?.payloadType == 0xA7, "Mac->Win ends with 0xA7")

        // 11b. Win -> Mac large Chinese file via CB_Format_File -> TX 0x10 -> RX reassembled 0x3a + 0xA7
        biMock.sent.removeAll()
        let winClipPayload = OTIXML.clipboardFilesPayload(
            files: [(path: winSrcPath, size: UInt64(chunkBytes.count), createdAt: now, modifiedAt: now)]
        )
        biMock.incoming = [OTIFrame(sequence: 4, payloadType: 0x39, payload: winClipPayload).transferData()]
        try biLink.pump()
        let reqFrames = biMock.sent.compactMap { OTIFrame.decode($0) }.filter { $0.payloadType == 0x10 }
        try assertTrue(reqFrames.count == 1, "Win->Mac clipboard file triggers 0x10 download request")
        // Extract exact session & fileID from TX 0x10 BE bytes: [1..4]=sess, [7..10]=fileID
        let tx10 = reqFrames[0].payload
        try assertTrue(tx10.count >= 13 && tx10[0] == 0x10, "TX 0x10 payload shape")
        let reqSessBE = (UInt32(tx10[1]) << 24) | (UInt32(tx10[2]) << 16) | (UInt32(tx10[3]) << 8) | UInt32(tx10[4])
        let reqFidBE = (UInt32(tx10[7]) << 24) | (UInt32(tx10[8]) << 16) | (UInt32(tx10[9]) << 8) | UInt32(tx10[10])

        let rxSub1 = winSubA3(fileID: reqFidBE, totalCount: 2, index: 1, data: part1)
        let rxSub2 = winSubA3(fileID: reqFidBE, totalCount: 2, index: 2, data: part2)
        var rx3a = Data([0x3A, 0x03, 0x00, 0x00, 0x00])
        rx3a.append(Data(count: 11))
        rx3a.append(rxSub1)
        rx3a.append(rxSub2)
        rx3a.append(sub37)
        let rxBlocks = OTIFrame(sequence: 5, payloadType: 0x3A, payload: rx3a).encodedBlocks()
        var rxAsm = OTIBlockAssembler()
        var rxAssembled3a: Data?
        for blk in rxBlocks {
            if let f = rxAsm.feed([UInt8](blk)) { rxAssembled3a = f }
        }
        try assertTrue(rxAssembled3a != nil, "Win->Mac 0x3a blocks reassembled")
        let rxFin = OTIFrame(sequence: 6, payloadType: 0xA7, payload: winFinA7(sessionID: reqSessBE)).transferData()
        biMock.incoming = [rxAssembled3a!, rxFin]
        try biLink.pump()
        try assertTrue(biReceivedURL?.lastPathComponent == "测试文件清单.xlsx",
                       "Win->Mac Chinese filename saved (got=\(String(describing: biReceivedURL)) errs=\(biErrors) logs=\(biLogs))")
        if let savedURL = biReceivedURL {
            let savedBytes = try Data(contentsOf: savedURL)
            try assertTrue(savedBytes == chunkBytes, "Win->Mac 200 KB file exact byte match")
        }

        // 11b2. Win -> Mac large standalone LE 0xA3 + standalone LE 0x37 + LE 0xA7 (e.g. >2 MB PDF)
        biMock.sent.removeAll()
        biReceivedURL = nil
        let pdfName = "（示例）测试文档_附件_01.pdf"
        let pdfWinPath = #"C:\Users\testuser\Downloads\"# + pdfName
        let pdfClipPayload = OTIXML.clipboardFilesPayload(
            files: [(path: pdfWinPath, size: UInt64(chunkBytes.count), createdAt: now, modifiedAt: now)]
        )
        biMock.incoming = [OTIFrame(sequence: 20, payloadType: 0x39, payload: pdfClipPayload).transferData()]
        try biLink.pump()
        let pdfReqFrames = biMock.sent.compactMap { OTIFrame.decode($0) }.filter { $0.payloadType == 0x10 }
        try assertTrue(pdfReqFrames.count == 1, "Win->Mac PDF triggers 0x10 download request")
        let pdfTx10 = pdfReqFrames[0].payload
        let pdfSessBE = (UInt32(pdfTx10[1]) << 24) | (UInt32(pdfTx10[2]) << 16) | (UInt32(pdfTx10[3]) << 8) | UInt32(pdfTx10[4])
        let pdfFidBE = (UInt32(pdfTx10[7]) << 24) | (UInt32(pdfTx10[8]) << 16) | (UInt32(pdfTx10[9]) << 8) | UInt32(pdfTx10[10])
        let standaloneA3 = winSubA3(fileID: pdfFidBE, totalCount: 1, index: 1, data: chunkBytes)
        let standaloneBlocks = OTIFrame(sequence: 21, payloadType: 0xA3, payload: standaloneA3).encodedBlocks()
        var pdfAsm = OTIBlockAssembler()
        var pdfAssembledA3: Data?
        for blk in standaloneBlocks {
            if let f = pdfAsm.feed([UInt8](blk)) { pdfAssembledA3 = f }
        }
        try assertTrue(pdfAssembledA3 != nil, "Win->Mac standalone LE 0xA3 blocks reassembled")
        let pdfDstPath = biLink.downloadsDirectory.appendingPathComponent(pdfName).path
        let pdfDstUTF16 = pdfDstPath.data(using: .utf16LittleEndian)! + Data([0x00, 0x00])
        var standalone37 = Data([0x37, 0x20, 0x00, 0x00, 0x00])
        var ftLE: UInt64 = (133_447_000_000_000_000 as UInt64).littleEndian
        for _ in 0..<3 { withUnsafeBytes(of: &ftLE) { standalone37.append(contentsOf: $0) } }
        var pLenLE = UInt32(pdfDstUTF16.count).littleEndian
        withUnsafeBytes(of: &pLenLE) { standalone37.append(contentsOf: $0) }
        standalone37.append(pdfDstUTF16)
        let pdfAttrFrame = OTIFrame(sequence: 22, payloadType: 0x37, payload: standalone37).transferData()
        let pdfFinFrame = OTIFrame(sequence: 23, payloadType: 0xA7, payload: winFinA7(sessionID: pdfSessBE)).transferData()
        biMock.incoming = [pdfAssembledA3!, pdfAttrFrame, pdfFinFrame]
        try biLink.pump()
        try assertTrue(biReceivedURL?.lastPathComponent == pdfName,
                       "Win->Mac standalone LE 0xA3 PDF saved (got=\(String(describing: biReceivedURL)))")
        if let savedPDF = biReceivedURL {
            let savedPDFBytes = try Data(contentsOf: savedPDF)
            try assertTrue(savedPDFBytes == chunkBytes, "Win->Mac standalone LE 0xA3 PDF byte match")
        }

        // 11c. 0xA9 + 0xA7 error response cleans up pending transfer and surfaces error
        biMock.sent.removeAll()
        biReceivedURL = nil
        let errClipPayload = OTIXML.clipboardFilesPayload(
            files: [(path: #"C:\Users\testuser\Downloads\broken.bin"#, size: 1234, createdAt: now, modifiedAt: now)]
        )
        biMock.incoming = [OTIFrame(sequence: 7, payloadType: 0x39, payload: errClipPayload).transferData()]
        try biLink.pump()
        if let txErr10 = biMock.sent.compactMap({ OTIFrame.decode($0) }).first(where: { $0.payloadType == 0x10 })?.payload,
           txErr10.count >= 11 {
            let errSess = (UInt32(txErr10[1]) << 24) | (UInt32(txErr10[2]) << 16) | (UInt32(txErr10[3]) << 8) | UInt32(txErr10[4])
            let errFid = (UInt32(txErr10[7]) << 24) | (UInt32(txErr10[8]) << 16) | (UInt32(txErr10[9]) << 8) | UInt32(txErr10[10])
            var a9 = Data([0xA9,
                           UInt8(errSess & 0xFF), UInt8((errSess >> 8) & 0xFF), UInt8((errSess >> 16) & 0xFF), UInt8((errSess >> 24) & 0xFF),
                           0x05, 0x00, 0x00, 0x00,
                           UInt8(errFid & 0xFF), UInt8((errFid >> 8) & 0xFF), UInt8((errFid >> 16) & 0xFF), UInt8((errFid >> 24) & 0xFF)])
            a9.append(Data("ErrStr".utf8))
            let em = "Access denied".data(using: .utf16LittleEndian)!
            a9.append(Data([UInt8(em.count & 0xFF), 0x00, 0x00, 0x00]))
            a9.append(em)
            let a9Frame = OTIFrame(sequence: 8, payloadType: 0xA9, payload: a9).transferData()
            let a7Frame = OTIFrame(sequence: 9, payloadType: 0xA7, payload: winFinA7(sessionID: errSess)).transferData()
            biMock.incoming = [a9Frame, a7Frame]
            try biLink.pump()
            let brokenPath = biLink.downloadsDirectory.appendingPathComponent("broken.bin").path
            try assertTrue(biReceiveFailed.contains("broken.bin")
                           && biReceivedURL == nil
                           && !FileManager.default.fileExists(atPath: brokenPath)
                           && biLogs.contains(where: { $0.contains("Access denied") }),
                           "0xA9 + 0xA7 invokes onFileReceiveFailed without saving empty file")
        } else {
            try assertTrue(false, "Expected 0x10 request for error cleanup test")
        }
        print("PASS: USBLink bidirectional file transfer + 0xA9 cleanup")

        // 12. ClipboardSync.capture prioritizes .fileURL over Finder .string fallback
        let capturedFileMsg = ClipboardSync.capture(fileURLs: [localSendFile], text: localSendFile.lastPathComponent)
        try assertTrue(capturedFileMsg?.filePaths == [localSendFile.path] && capturedFileMsg?.text == nil,
                       "ClipboardSync.capture prioritizes filePaths over Finder string fallback")
        let subDirURL = biDirTmpDir.appendingPathComponent("OnlyDir")
        try FileManager.default.createDirectory(at: subDirURL, withIntermediateDirectories: true)
        try assertTrue(ClipboardSync.capture(fileURLs: [subDirURL], text: "OnlyDir") == nil,
                       "ClipboardSync.capture ignores directories and their string names")
        let capturedPlainText = ClipboardSync.capture(fileURLs: [], text: "plain-clip")
        try assertTrue(capturedPlainText?.text == "plain-clip" && capturedPlainText?.filePaths == nil,
                       "ClipboardSync.capture preserves plain text when no fileURLs")
        let testPB = NSPasteboard.withUniqueName()
        defer { testPB.releaseGlobally() }
        testPB.clearContents()
        let pbItem = NSPasteboardItem()
        pbItem.setString(localSendFile.absoluteString, forType: .fileURL)
        pbItem.setString(localSendFile.lastPathComponent, forType: .string)
        if testPB.writeObjects([pbItem]) {
            let pbMsg = ClipboardSync.capture(from: testPB)
            try assertTrue(pbMsg?.filePaths == [localSendFile.path] && pbMsg?.text == nil,
                           "ClipboardSync.capture(from:) live pasteboard fileURL priority")
            testPB.clearContents()
            testPB.setString("only-text", forType: .string)
            try assertTrue(USBLink.readFileURLs(from: testPB).isEmpty,
                           "USBLink.readFileURLs skips non-fileURL pasteboard")
        }
        print("PASS: ClipboardSync fileURL priority")

        // 13. KMEngine off-main screen union & thread-safe state transitions
        let bgUnionGroup = DispatchGroup()
        var bgUnion: CGRect = .null
        bgUnionGroup.enter()
        DispatchQueue.global(qos: .userInteractive).async {
            bgUnion = KMEngine.cgScreenUnion()
            bgUnionGroup.leave()
        }
        bgUnionGroup.wait()
        try assertTrue(bgUnion == KMEngine.cgScreenUnion(), "KMEngine.cgScreenUnion consistent off main thread")
        let kmTest = KMEngine()
        kmTest.usbMode = true
        kmTest.canSwitch = true
        kmTest.peerPosition = "left"
        var switchReqButtons: UInt8 = 99
        kmTest.onRequestUSBRemoteSwitch = { _, _, _, buttons in switchReqButtons = buttons }
        kmTest.beginRemoteControl(from: CGPoint(x: 1, y: 200), isDragging: false)
        try assertTrue(kmTest.controllingRemote && switchReqButtons == 0, "KMEngine beginRemoteControl non-drag")
        kmTest.endRemoteControl(notifyPeer: false)
        try assertTrue(!kmTest.controllingRemote, "KMEngine endRemoteControl resets controllingRemote")
        print("PASS: KMEngine thread-safe state & CG geometry")

        // 14. Regression coverage for Windows->Mac (external mouse) reliability fixes
        let expectedPipeTag = "<NP_Up_Notice_NamePipe_Name>\\\\.\\pipe\\OTI_ClipboardAgent</NP_Up_Notice_NamePipe_Name>"
        let badPipeTag = "<NP_Up_Notice_NamePipe_Name>\\.\\pipe\\"
        let pipePayloads = [
            ("screenInfo", String(decoding: OTIXML.postRemoteScreenInfoPayload(width: 1512, height: 982), as: UTF8.self)),
            ("kmSetting", String(decoding: OTIXML.postRemoteKMSettingPayload(direction: 1, option: 3), as: UTF8.self)),
            ("switchToRemote", String(decoding: OTIXML.switchToRemotePayload(direction: 1, x: 0, y: 400, width: 1512, height: 982), as: UTF8.self))
        ]
        for (label, xml) in pipePayloads {
            try assertTrue(xml.contains(expectedPipeTag), "\(label) must include \\\\.\\pipe\\OTI_ClipboardAgent")
            try assertTrue(!xml.contains(badPipeTag), "\(label) must not omit leading backslash in pipe name")
        }
        try assertTrue(pipePayloads[0].1.contains("<Param_Screen_Info><OTIMSG>"),
                       "screenInfo must wrap geometry inside <Param_Screen_Info><OTIMSG>")
        let parsedSelfScreen = OTIBridge.parseScreenInfo(from: OTIXML.postRemoteScreenInfoPayload(width: 1512, height: 982))
        try assertTrue(parsedSelfScreen?.width == 1512 && parsedSelfScreen?.height == 982,
                       "screenInfo must round-trip through parseScreenInfo")

        // Option must always remain 3 across repeated reconnect/login announcements,
        // and handshake must resume after a transient write failure.
        let regMock = MockOTITransport()
        let regLink = USBLink(transport: regMock)
        regLink.localPeerPosition = "left"
        regLink.pointerPrePositionEnabled = false
        try regLink.start()

        for seq in UInt32(1)...UInt32(4) {
            if seq == 2 {
                regMock.failNextSendCount = 2
            }
            if seq == 4 {
                regLink.localPeerPosition = "right"
            }
            regMock.incoming = [OTIFrame(sequence: seq, payloadType: 0x01, payload: winLoginPayload).transferData()]
            try regLink.pump()
            if seq == 2 {
                for _ in 0..<2 {
                    usleep(400_000)
                    try regLink.pump()
                }
                try assertTrue(regMock.failNextSendCount == 0, "Simulated transient send failures should be drained")
            }
        }
        let kmSettingFrames = regMock.sent.compactMap { OTIFrame.decode($0) }.filter {
            OTIBridge.command(from: $0.payload) == "Cmd_Post_Remote_KM_Setting_Info"
        }
        try assertTrue(kmSettingFrames.count == 4, "Expected 4 KM setting announcements across 4 logins, got \(kmSettingFrames.count)")
        for (idx, frame) in kmSettingFrames.enumerated() {
            let rawXML = String(decoding: frame.payload, as: UTF8.self)
            try assertTrue(rawXML.contains("<Param_KM_Setting_Info><OTIMSG>"),
                           "KM setting #\(idx + 1) must wrap payload inside <Param_KM_Setting_Info><OTIMSG>")
            let innerXML = OTIBridge.unescapeLevels(rawXML, requiredTag: "Param_Move_Out_KM_Switch_Option") ?? ""
            try assertTrue(innerXML.contains("<Param_Move_Out_KM_Switch_Option>3</Param_Move_Out_KM_Switch_Option>"),
                           "KM setting #\(idx + 1) must keep option=3")
            let expectedDir = idx == 3 ? "<Param_Move_Out_Direction>2</Param_Move_Out_Direction>"
                                       : "<Param_Move_Out_Direction>1</Param_Move_Out_Direction>"
            try assertTrue(innerXML.contains(expectedDir), "KM setting #\(idx + 1) direction mismatch")
        }

        // Force-switch-local and 0x02 LogoutCommand must cancel pending switch resends.
        var logoutEndedCalls = 0
        regLink.onKMRemoteEnded = { if $0 == nil { logoutEndedCalls += 1 } }
        let beforeForceCount = regMock.sent.count
        try regLink.sendSwitchToRemote(direction: 1, x: 0, y: 400, width: 1512, height: 982)
        try regLink.sendForceRemoteSwitchLocal(x: 10, y: 400, direction: 2)
        let afterForceCount = regMock.sent.count
        usleep(600_000)
        try assertTrue(regMock.sent.count == afterForceCount && afterForceCount == beforeForceCount + 2,
                       "sendForceRemoteSwitchLocal must cancel switchToRemote resend")

        let screenAnnounce = Data("<ExtraXmlCommand>HookAppService</ExtraXmlCommand><ExtraXmlParam><OTIMSG><NP_Cmd>Cmd_Post_Remote_Screen_Info</NP_Cmd><Param_Remote_Screen_Width>2560</Param_Remote_Screen_Width><Param_Remote_Screen_Height>1440</Param_Remote_Screen_Height></OTIMSG></ExtraXmlParam>".utf8)
        let beforeLogoutTest = regMock.sent.count
        try regLink.sendSwitchToRemote(direction: 1, x: 0, y: 400, width: 1512, height: 982)
        regMock.incoming = [
            OTIFrame(sequence: 20, payloadType: 0x39, payload: screenAnnounce).transferData(),
            OTIFrame(sequence: 21, payloadType: 0x02, payload: Data([0x02])).transferData()
        ]
        try regLink.pump()
        try assertTrue(logoutEndedCalls == 1, "0x02 LogoutCommand must notify onKMRemoteEnded(nil)")
        try assertTrue(regLink.remoteScreenWidth == 2560 && regLink.remoteScreenHeight == 1440,
                       "Cmd_Post_Remote_Screen_Info must update USBLink dimensions")
        let afterLogoutTest = regMock.sent.count
        usleep(600_000)
        try assertTrue(regMock.sent.count == afterLogoutTest && afterLogoutTest == beforeLogoutTest + 1,
                       "0x02 LogoutCommand must cancel pending switchToRemote resend")
        regMock.sent.removeAll()
        regMock.incoming = [
            OTIFrame(sequence: 22, payloadType: 0xA1, payload: Data(winA1Bytes)).transferData()
        ]
        try regLink.pump()
        let a1ReconnectCmds = regMock.sent.compactMap { OTIFrame.decode($0) }.compactMap { OTIBridge.command(from: $0.payload) }
        try assertTrue(a1ReconnectCmds.contains("Cmd_Post_Remote_Screen_Info")
                        && a1ReconnectCmds.contains("Cmd_Post_Remote_KM_Setting_Info")
                        && a1ReconnectCmds.contains(OTIBridge.switchAcknowledge),
                       "Fast reconnect 0xA1(cmd=0x01) without 0x01 LoginCommand must announce screen & KM settings")
        regLink.stop()

        kmTest.forwardLocalInput = false
        kmTest.beginRemoteControl(from: CGPoint(x: 1, y: 200), isDragging: false)
        kmTest.beginUSBSlave(from: KMSwitchMoveOutInfo(moveOutX: 2559, moveOutY: 700, remoteWidth: 2560, remoteHeight: 1440, direction: 2))
        try assertTrue(!kmTest.controllingRemote && kmTest.usbSlaveActive, "beginUSBSlave takes slave state cleanly")
        kmTest.endUSBSlave(at: CGPoint(x: 0, y: 300), direction: 1, notifyPeer: false, becomeMaster: false)
        try assertTrue(!kmTest.usbSlaveActive && !kmTest.controllingRemote, "endUSBSlave(becomeMaster: false) stays local")
        print("PASS: Windows->Mac pipe name, option=3 stability, retry, cancel & slave hygiene")

        // 15. Disconnect / peer-offline guards against local cursor trapping
        kmTest.forwardLocalInput = true
        kmTest.canSwitch = false
        kmTest.beginRemoteControl(from: CGPoint(x: 0, y: 200), isDragging: false)
        try assertTrue(!kmTest.controllingRemote, "beginRemoteControl refuses when canSwitch is false")

        let offMock = MockOTITransport()
        let offLink = USBLink(transport: offMock)
        offLink.pointerPrePositionEnabled = false
        var switchThrewDisconnected = false
        do {
            try offLink.sendSwitchToRemote(direction: 1, x: 0, y: 400, width: 1512, height: 982)
        } catch {
            switchThrewDisconnected = SCSITaskTransport.isPeerOfflineError(error)
        }
        try assertTrue(switchThrewDisconnected, "sendSwitchToRemote throws notConnected when idle")

        var hidThrewDisconnected = false
        do {
            try offLink.sendHID(event: KMEvent(kind: "mouseMoved", dx: 5, dy: 0))
        } catch {
            hidThrewDisconnected = SCSITaskTransport.isPeerOfflineError(error)
        }
        try assertTrue(hidThrewDisconnected, "sendHID throws notConnected when idle")

        var onlineEvents: [Bool] = []
        offLink.onPeerOnlineChanged = { onlineEvents.append($0) }
        try offLink.start()
        try assertTrue(offLink.peerOnline, "peerOnline starts true after USB open")

        offMock.incoming = [OTIFrame(sequence: 30, payloadType: 0x02, payload: Data([0x02])).transferData()]
        try offLink.pump()
        try assertTrue(!offLink.peerOnline && onlineEvents == [false], "0x02 LogoutCommand sets peerOnline false")

        var switchThrewOffline = false
        do {
            try offLink.sendSwitchToRemote(direction: 1, x: 0, y: 400, width: 1512, height: 982)
        } catch {
            switchThrewOffline = SCSITaskTransport.isPeerOfflineError(error)
        }
        try assertTrue(switchThrewOffline, "sendSwitchToRemote fails fast while peer is logged out")

        offMock.incoming = [OTIFrame(sequence: 31, payloadType: 0x01, payload: winLoginPayload).transferData()]
        try offLink.pump()
        try assertTrue(offLink.peerOnline && onlineEvents == [false, true], "0x01 LoginCommand restores peerOnline")

        offMock.forcedSendError = SCSITaskTransport.TransportError.writeFailed(-3, 0x01, [])
        var switchThrewCodeMinus3 = false
        do {
            try offLink.sendSwitchToRemote(direction: 1, x: 0, y: 400, width: 1512, height: 982)
        } catch {
            switchThrewCodeMinus3 = SCSITaskTransport.isPeerOfflineError(error)
        }
        try assertTrue(switchThrewCodeMinus3 && !offLink.peerOnline && onlineEvents == [false, true, false],
                       "code=-3 offline failure aborts switch and marks peer offline")
        offLink.stop()

        let prefPayload = Data("<ExtraXmlCommand>HookAppService</ExtraXmlCommand><ExtraXmlParam><OTIMSG><NP_Cmd>Cmd_Post_Remote_KM_Preference_Setup_Info</NP_Cmd><Param_KM_Setting_Info><OTIMSG><KMSwitchMode>0</KMSwitchMode><ClipboardShareOption>1</ClipboardShareOption><BlockingBridge>0</BlockingBridge></OTIMSG></Param_KM_Setting_Info></OTIMSG></ExtraXmlParam>".utf8)
        let parsedPref = OTIBridge.parsePeerKMPreference(from: prefPayload)
        try assertTrue(parsedPref?.switchMode == 0 && parsedPref?.clipOption == 1 && parsedPref?.blocking == 0,
                       "parsePeerKMPreference decodes KMSwitchMode/ClipboardShareOption/BlockingBridge")
        print("PASS: Disconnect / peer-offline guards & preference parser")

        print("ALL SELFTESTS PASSED")
        return 0
    } catch {
        print("FAIL: \(error.localizedDescription)")
        return 1
    }
}



// MARK: - HID injection probe (--hidtest)
//
// Sends a short burst of relative mouse reports through the bridge without any
// KM handshake. If the other machine's pointer moves, hardware HID injection
// works on its own and the KM XML is only needed for mode hand-off.
private func runHIDTest() -> Int32 {
    let transport = SCSITaskTransport()
    defer { transport.close() }
    do {
        try transport.open()
        let session = OTISession(transport: transport)
        try session.sendLoginCommand(name: Host.current().localizedName ?? "kmlink")
        print("HIDTEST: connected, moving the other machine's pointer 30 x +6 px")
        var ok = 0
        for i in 1...30 {
            var pkt = [UInt8](repeating: 0, count: 12)
            pkt[0] = 0
            pkt[1] = 6
            pkt[2] = 0
            pkt[3] = 0
            do {
                try transport.sendHID(kind: 0x33, data12: pkt)
                ok += 1
            } catch {
                print("HIDTEST: report \(i) failed: \(error)")
            }
            usleep(12_000)
        }
        print("HIDTEST: \(ok)/30 reports accepted")
        return ok > 0 ? 0 : 1
    } catch {
        print("HIDTEST: setup failed: \(error)")
        return 2
    }
}

// MARK: - Switch-command send probe (--switchtest)
//
// Exercises the real 0x39 KM switch frame through SCSITaskTransport so we can
// verify the write path without moving a physical mouse.
private func runSwitchTest() -> Int32 {
    let transport = SCSITaskTransport()
    defer { transport.close() }
    do {
        try transport.open()
        let session = OTISession(transport: transport)
        try session.sendLoginCommand(name: Host.current().localizedName ?? "kmlink")
        print("SWITCHTEST: connected, sending 5 switch frames")
        var ok = 0
        for i in 1...5 {
            let payload = OTIXML.switchToRemotePayload(direction: 1, x: 0, y: 400,
                                                       width: 1512, height: 982)
            let frame = OTIFrame(sequence: UInt32(i), payloadType: 0x39, payload: payload)
            let started = Date()
            do {
                try transport.send(frame: frame.transferData())
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                print("SWITCHTEST: frame \(i) OK (\(frame.payloadLength) B payload, \(ms) ms)")
                ok += 1
            } catch {
                print("SWITCHTEST: frame \(i) FAILED \(error)")
            }
            _ = try? transport.pollStatus()
            usleep(150_000)
        }
        print("SWITCHTEST: \(ok)/5 accepted")
        return ok == 5 ? 0 : 1
    } catch {
        print("SWITCHTEST: setup failed: \(error)")
        return 2
    }
}

// MARK: - Live USB Probe (--usbprobe)

private func runUSBProbe() -> Int32 {
    let transport = SCSITaskTransport()
    defer { transport.close() }
    do {
        print("USBPROBE: opening IOCompactDiscServices via SCSITaskLib (native arm64)...")
        try transport.open()
        print("USBPROBE: open + handshake OK")

        let st = try transport.pollStatus()
        let hex = st.map { String(format: "%02x", $0) }.joined(separator: " ")
        print("USBPROBE: D8 00 03 status = [\(hex)]")

        if st.first == 0x05, st.count >= 3, st[2] > 0 {
            print("USBPROBE: RX pending (\(st[2]) blocks), draining...")
            while let raw = try transport.readFrame() {
                if let frame = OTIFrame.decode(raw) {
                    let cmd = frame.payloadType == 0x39 ? (OTIBridge.command(from: frame.payload) ?? "xml") : "bin"
                    print(String(format: "USBPROBE: RX frame seq=%u type=0x%02x len=%d cmd=%@",
                                 frame.sequence, frame.payloadType, frame.payload.count, cmd))
                } else {
                    print("USBPROBE: RX raw block (\(raw.count) bytes)")
                }
            }
        }

        if st.first == 0x07 || st.first == 0x05 {
            let session = OTISession(transport: transport)
            if CommandLine.arguments.contains("--probe-login") {
                let modeArg = CommandLine.arguments.first(where: { $0.hasPrefix("--mode=") }) ?? "--mode=a1"
                let mode = String(modeArg.dropFirst("--mode=".count))
                let localName = ProcessInfo.processInfo.hostName
                let cleanName = localName.hasSuffix(".local") ? String(localName.dropLast(6)) : localName
                try session.sendLoginCommand(name: cleanName)
                print("PROBE: TX 0x01 LoginCommand (\(cleanName))")
                let start = Date()
                var sentReply = false
                var testedStatus = false
                while Date().timeIntervalSince(start) < 13.5 {
                    let s = try transport.pollStatus()
                    if s.first == 0x04 {
                        let sHex = s.map { String(format: "%02x", $0) }.joined(separator: " ")
                        print(String(format: "PROBE [%.2fs]: POLL RESET status=[%@]", Date().timeIntervalSince(start), sHex))
                    }
                    while let raw = try transport.readFrame() {
                        if let f = OTIFrame.decode(raw) {
                            print(String(format: "PROBE [%.2fs]: RX type=0x%02x len=%d", Date().timeIntervalSince(start), f.payloadType, f.payload.count))
                            if f.payloadType == 0xAD {
                                print("PROBE RX 0xAD hex=" + f.payload.map { String(format: "%02x", $0) }.joined())
                            }
                            if f.payloadType == 0x01 && !sentReply {
                                sentReply = true
                                if mode != "none" {
                                    var a1 = OTIXML.loginResponsePayload(requestCommand: 0x01, requestResult: 0x00, osVersion: 0x28)
                                    if mode.contains("len10") {
                                        a1[20] = 0x0a
                                    }
                                    if mode.contains("34b") {
                                        a1 = Data(a1.prefix(34))
                                        a1[20] = 0x0a
                                    }
                                    try session.sendFrame(payloadType: 0xA1, payload: a1)
                                    print("PROBE: TX 0xA1 (\(a1.count)B extraLen=\(a1[20]))")
                                } else {
                                    print("PROBE: mode=none (skipping 0xA1/0xAD/0xA4)")
                                }
                                if mode.contains("+ad") {
                                    let fm = FileManager.default
                                    let home = fm.homeDirectoryForCurrentUser.path
                                    if mode.contains("be_len1") || mode.contains("be_misc") || mode.contains("le_misc") {
                                        var items: [(UInt32, String)] = [
                                            (0x0000_F00F, "\(home)/Desktop"),
                                            (0x0100_F00F, "\(home)/Documents"),
                                            (0x0300_F00F, "\(home)/Music"),
                                            (0x0400_F00F, "\(home)/Pictures"),
                                        ]
                                        if mode.contains("misc") {
                                            let miscPath = "/tmp/GSMiscInfo.dat"
                                            let minimalMisc = "<OTiMiscInfo><OSVer>40</OSVer><Theme>light</Theme></OTiMiscInfo>"
                                            try? minimalMisc.write(toFile: miscPath, atomically: true, encoding: .utf8)
                                            items.append((0x0200_F00F, miscPath))
                                        }
                                        var sub = Data()
                                        let useLE = mode.contains("le_misc")
                                        for (tag, p) in items {
                                            var t = useLE ? tag.bigEndian : tag.littleEndian
                                            sub.append(Data(bytes: &t, count: 4))
                                            var uni: Data
                                            if useLE {
                                                uni = p.precomposedStringWithCanonicalMapping.data(using: .utf16LittleEndian) ?? Data()
                                                uni.append(contentsOf: [0x00, 0x00])
                                            } else {
                                                uni = OTIXML.otiUnicodeBigEndianData(p)
                                            }
                                            var ulen = useLE ? UInt32(uni.count).littleEndian : UInt32(uni.count).bigEndian
                                            sub.append(Data(bytes: &ulen, count: 4))
                                            sub.append(uni)
                                        }
                                        var ad = Data([0xAD])
                                        let lenVal = mode.contains("exact") ? UInt32(sub.count) : UInt32(sub.count + 1)
                                        var subLen = lenVal.littleEndian
                                        ad.append(Data(bytes: &subLen, count: 4))
                                        ad.append(UInt8(items.count))
                                        ad.append(sub)
                                        try session.sendFrame(payloadType: 0xAD, payload: ad)
                                        print("PROBE: TX custom 0xAD mode=\(mode) len=\(ad.count) subLen=\(lenVal)")
                                    } else {
                                        try session.sendDomainFolders(desktop: "\(home)/Desktop", documents: "\(home)/Documents", music: "\(home)/Music", pictures: "\(home)/Pictures")
                                        print("PROBE: TX 0xAD")
                                    }
                                }
                                if mode.contains("+a4") {
                                    let rootName = FileManager.default.displayName(atPath: "/")
                                    try session.sendDriveInfo(volumes: [(name: rootName, path: "/", type: 0x14)])
                                    print("PROBE: TX 0xA4")
                                }
                            }
                            if f.payloadType == 0x39, let cmd = OTIBridge.command(from: f.payload) {
                                print(String(format: "PROBE [%.2fs]: RX XML cmd=%@", Date().timeIntervalSince(start), cmd))
                                if cmd == OTIBridge.switchAcknowledge {
                                    try? session.sendSwitchToLocal()
                                    print(String(format: "PROBE [%.2fs]: GOT SWITCH ACK! TX switchToLocal", Date().timeIntervalSince(start)))
                                }
                            }
                        }
                    }
                    if !testedStatus && sentReply && Date().timeIntervalSince(start) > 2.5 {
                        testedStatus = true
                        if CommandLine.arguments.contains("--test-switch") {
                            try session.sendSwitchToRemote(direction: 1, x: 0, y: 400, width: 1512, height: 982)
                            print(String(format: "PROBE [%.2fs]: TX switchToRemote OK", Date().timeIntervalSince(start)))
                        } else {
                            try session.sendFrame(payloadType: 0x39, payload: OTIXML.replayBridgeBlockStatusPayload(blocked: false))
                            print(String(format: "PROBE [%.2fs]: TX blockStatus OK", Date().timeIntervalSince(start)))
                        }
                    }
                    usleep(100_000)
                }
                print("PROBE: finished cleanly (mode=\(mode))")
                return 0
            }
            try session.login()
            print("USBPROBE: A1 login frame TX OK")
            if CommandLine.arguments.contains("--send-clipboard") {
                try session.sendClipboard("KMLink arm64 native USB probe")
                print("USBPROBE: clipboard TX OK")
            }
        } else {
            print(String(format: "USBPROBE: bridge local open OK, remote host status=0x%02x (Windows GO! Bridge offline)", st.first ?? 0))
        }
        return 0
    } catch {
        print("USBPROBE FAIL: \(error)")
        return 1
    }
}

// MARK: - Entry

if CommandLine.arguments.contains("--selftest") {
    exit(runSelfTest())
}

if CommandLine.arguments.contains("--pintest") {
    let union = KMEngine.cgScreenUnion()
    print("screen union:", union)
    for dir in 1...2 {
        let pin = KMEngine.pinTargetPoint(at: CGPoint(x: union.minX, y: union.height / 2), direction: dir)
        CGWarpMouseCursorPosition(pin)
        usleep(120_000)
        let now = CGEvent(source: nil)?.location ?? .zero
        print("dir=\(dir) pin=\(pin) cursorAfterWarp=\(now)")
    }
    exit(0)
}

if CommandLine.arguments.contains("--hidtest") {
    exit(runHIDTest())
}

if CommandLine.arguments.contains("--switchtest") {
    exit(runSwitchTest())
}

if CommandLine.arguments.contains("--usbprobe") {
    exit(runUSBProbe())
}

if CommandLine.arguments.contains("--kmcheck") {
    let engine = KMEngine()
    var status = ""
    engine.onStatus = { text in status = text; print("KM \(text)") }
    print("AX \(KMEngine.hasAccessibility())")
    engine.start()
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    engine.stop()
    exit(status.contains("active") ? 0 : 1)
}

private func renderViewToPNG(_ view: NSView, background: NSColor, output: String) {
    view.appearance = NSAppearance(named: .aqua)
    view.wantsLayer = true
    view.layer?.backgroundColor = background.cgColor
    view.layoutSubtreeIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    NSGraphicsContext.saveGraphicsState()
    if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
        NSGraphicsContext.current = ctx
        background.setFill()
        view.bounds.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    view.cacheDisplay(in: view.bounds, to: rep)
    if let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: output))
        print("rendered \(output) \(Int(view.bounds.width))x\(Int(view.bounds.height))")
    }
}

if let index = CommandLine.arguments.firstIndex(of: "--render-settings"),
   index + 1 < CommandLine.arguments.count {
    let output = CommandLine.arguments[index + 1]
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.appearance = NSAppearance(named: .aqua)
    let model = AppModel(previewMode: true)
    let controller = SettingsWindowController(model: model)
    if let window = controller.window, let view = window.contentView {
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .windowBackgroundColor
        renderViewToPNG(view, background: .windowBackgroundColor, output: output)
    }
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--render"),
   index + 1 < CommandLine.arguments.count {
    let output = CommandLine.arguments[index + 1]
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.appearance = NSAppearance(named: .aqua)
    let model = AppModel(previewMode: true)
    let controller = MainViewController(model: model)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .aqua)
    window.backgroundColor = .windowBackgroundColor
    window.contentViewController = controller
    controller.view.frame = NSRect(x: 0, y: 0, width: 560, height: 640)
    controller.refresh()
    renderViewToPNG(controller.view, background: .windowBackgroundColor, output: output)
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
