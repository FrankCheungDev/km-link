// xmlframe.c — A/B test for the OTi 64 KB frame header of XML (0x39) commands.
//
// Finding (2026-11-17): every payload type 0x39 frame we sent was rejected by
// the bridge with CHECK CONDITION (SCSI status 2, sense key NO SENSE,
// ASC/ASCQ 0x00/0x00) while 0x01/0xA1/0xAD/0xA4 frames were accepted.
// The original daemon's captured 0x39 frame (docs/PROTOCOL.md §7) has
//   0x00 = 1        (constant)
//   0x04 = sequence
// while our encoder wrote the sequence into BOTH words.
//
// Usage:
//   SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
//   clang -target arm64-apple-macos13.0 -isysroot "$SDK" -O1 \
//     -framework IOKit -framework CoreFoundation -framework DiskArbitration \
//     -ISources -o /tmp/xmlframe Sources/SCSITaskShim.c tools/xmlframe.c
//   /tmp/xmlframe seq     # 0x00 = sequence  (old behaviour)  -> expect CHECK CONDITION
//   /tmp/xmlframe one     # 0x00 = 1         (original)        -> expect success
//
// The tool opens the bridge exclusively (the mounted MacKMLINK volume is
// unmounted, as the app itself does), sends one XML frame and prints the
// SCSI result. Quit KMLink before running it.

#include "SCSITaskShim.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>

static uint8_t frame[65536];

static void put32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v & 0xFF);
    p[1] = (uint8_t)((v >> 8) & 0xFF);
    p[2] = (uint8_t)((v >> 16) & 0xFF);
    p[3] = (uint8_t)((v >> 24) & 0xFF);
}

static void put32be(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)((v >> 24) & 0xFF);
    p[1] = (uint8_t)((v >> 16) & 0xFF);
    p[2] = (uint8_t)((v >> 8) & 0xFF);
    p[3] = (uint8_t)(v & 0xFF);
}

static char xmlbuf[8192];
static const char *xml =
    "<ExtraXmlCommand>HookAppService</ExtraXmlCommand><ExtraXmlParam>"
    "<OTIMSG><NP_Cmd>Cmd_Check_Bridge_Block_Status</NP_Cmd>"
    "<NP_Up_Notice_NamePipe_Name>\\\\.\\pipe\\OTI_ClipboardAgent</NP_Up_Notice_NamePipe_Name>"
    "</OTIMSG></ExtraXmlParam>";

static size_t build_xml_frame(uint32_t seq, int header_word0_is_one, int plain_type, int with_mirror, int big) {
    const char *xmlLocal = xml;
    if (big) {
        // ~1230-byte payload, same size as the real KM switch command.
        int n = snprintf(xmlbuf, sizeof(xmlbuf),
            "<ExtraXmlCommand>HookAppService</ExtraXmlCommand><ExtraXmlParam><OTIMSG>"
            "<NP_Cmd>Cmd_Check_Bridge_Block_Status</NP_Cmd>"
            "<NP_Up_Notice_NamePipe_Name>\\\\.\\pipe\\OTI_ClipboardAgent</NP_Up_Notice_NamePipe_Name>"
            "<Param_Filler>");
        const char *filler = "KMLINK-SWITCH-SIZE-PROBE-0123456789ABCDEF";
        while (n < 1180) {
            int add = snprintf(xmlbuf + n, sizeof(xmlbuf) - n, "%s", filler);
            if (add <= 0) break;
            n += add;
        }
        snprintf(xmlbuf + n, sizeof(xmlbuf) - n, "</Param_Filler></OTIMSG></ExtraXmlParam>");
        xmlLocal = xmlbuf;
    }
    size_t xmlLen = strlen(xmlLocal);
    memset(frame, 0, sizeof frame);
    if (plain_type) {
        // Control case: a 0x01 LoginCommand frame, which the bridge accepts.
        const char *name = "kmlink";
        uint32_t plen = 1 + 1 + 1 + (uint32_t)strlen(name);
        put32(frame + 0x00, seq);
        put32(frame + 0x04, seq);
        put32(frame + 0x08, 0);
        put32(frame + 0x0C, 1);
        put32(frame + 0x10, plen);
        frame[0x14] = 0x01;
        frame[0x15] = 0x28;            // os version byte
        frame[0x16] = 0x00;            // codepage
        memcpy(frame + 0x17, name, strlen(name));
        if (with_mirror) for (int i = 0; i < 20; i++) frame[0xFFEC + i] = frame[i];
        return plen;
    }
    put32(frame + 0x00, header_word0_is_one ? 1u : seq);
    put32(frame + 0x04, seq);
    put32(frame + 0x08, 0);
    put32(frame + 0x0C, 1);
    put32(frame + 0x10, (uint32_t)(5 + xmlLen));
    frame[0x14] = 0x39;
    put32be(frame + 0x15, (uint32_t)xmlLen);
    memcpy(frame + 0x19, xml, xmlLen);
    if (with_mirror) for (int i = 0; i < 20; i++) frame[0xFFEC + i] = frame[i];
    return 5 + xmlLen;
}

int main(int argc, char **argv) {
    int asOne = (argc >= 2 && strcmp(argv[1], "one") == 0);
    int plainType = (argc >= 2 && strcmp(argv[1], "plain") == 0);
    int bigPayload = (argc >= 2 && strcmp(argv[1], "big") == 0);
    int noMirror = (argc >= 3 && strcmp(argv[2], "nomirror") == 0);
    int attempts = 1;
    int loopMode = 0;
    if (argc >= 4) {
        if (strcmp(argv[3], "loop") == 0 && argc >= 5) { loopMode = 1; attempts = atoi(argv[4]); }
        else attempts = atoi(argv[3]);
    }
    int err = 0;
    oti_usb_t *h = oti_usb_open(&err);
    if (!h) {
        printf("open failed: %d\n", err);
        return 1;
    }
    int hs = oti_usb_handshake(h);
    printf("handshake rc=%d functionType=0x%02x\n", hs, (unsigned)oti_usb_function_type(h));
    if (hs != 0) {
        oti_usb_close(h);
        return 2;
    }

    size_t plen = build_xml_frame(1, asOne, plainType, !noMirror, bigPayload);
    printf("sending %s frame: word0=%s mirror=%s payloadLen=%zu attempts=%d\n",
           plainType ? "0x01 control" : "0x39 xml",
           plainType || asOne ? "1" : "sequence", noMirror ? "no" : "yes", plen, attempts);
    int lastRc = -1;
    static uint8_t blk[65536];
    for (int attempt = 1; attempt <= attempts; attempt++) {
        uint8_t poll[16] = {0};
        int drainRounds = 0;
        // Drain any pending RX before writing (the app does the same).
        for (int d = 0; d < 8; d++) {
            int prc0 = oti_usb_poll_status(h, 0, poll);
            if (prc0 != 0 || poll[0] != 0x05) break;
            int cnt = (poll[1] << 8) | poll[2];
            if (cnt <= 0) break;
            for (int k = 0; k < cnt; k++) {
                if (oti_usb_read_block64k(h, blk) != 0) break;
                drainRounds++;
            }
        }
        int prc = oti_usb_poll_status(h, 2, poll);
        int rc = oti_usb_write_frame64k(h, frame);
        int kr = 0;
        uint8_t status = 0;
        uint8_t sense[18] = {0};
        oti_usb_last_error(h, &kr, &status, sense);
        printf("  attempt %d: drained=%d poll rc=%d state=0x%02x  write rc=%d scsi_status=%d\n",
               attempt, drainRounds, prc, poll[0], rc, (int)status);
        lastRc = rc;
        if (rc == 0 && !loopMode) break;
        if (!loopMode) usleep(400000);
        if (loopMode) usleep(150000);
    }
    printf("%s\n", lastRc == 0 ? "RESULT: accepted" : "RESULT: rejected");
    oti_usb_close(h);
    return lastRc == 0 ? 0 : 3;
}
