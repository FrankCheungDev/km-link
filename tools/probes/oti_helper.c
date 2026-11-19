// Research helper: drive the original OTiTransfer C API and dump raw frames.
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <stdint.h>

extern int OTi_Open(void);
extern void OTi_Close(void);
extern int OTi_ReadData(void *buffer);
extern int OTi_SendData(const void *buffer);
extern int OTi_SetDeviceMode(int mode);

static void dumpFrame(const uint8_t *bytes, int length) {
    printf("len=%d header=", length);
    for (int i = 0; i < 20 && i < length; i++) printf("%02x", bytes[i]);
    printf("\n");
    if (length >= 20) {
        printf("payload_len=%u type=%02x mirror=", *(const uint32_t *)(bytes + 16), bytes[0x14]);
        if (length >= 0x10000) printf("%s\n", memcmp(bytes, bytes + 0xFFEC, 20) == 0 ? "MATCH" : "DIFF");
        else printf("n/a\n");
    }
    for (int i = 0; i + 8 < length; i++) {
        if (!memcmp(bytes + i, "<OTIMSG>", 8) || !memcmp(bytes + i, "OTIMSG", 6)) {
            printf("XML@0x%x: ", i);
            for (int j = 0; j < 400 && i + j < length; j++) {
                unsigned char c = bytes[i + j];
                putchar(c >= 32 && c < 127 ? c : '.');
            }
            printf("\n");
            break;
        }
    }
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    int rc = OTi_Open();
    printf("OTi_Open=%d\n", rc);
    if (!rc) return 1;
    sleep(1);

    if ((argc > 1 && !strcmp(argv[1], "--send-frame")) || (argc > 1 && !strcmp(argv[1], "--send-cmd"))) {
        const char *cmd = (argc > 2) ? argv[2] : "Cmd_Get_KM_Switch_Acknowlege";
        char xml[1024];
        snprintf(xml, sizeof(xml),
            "<OTIMSG><NP_Cmd>%s</NP_Cmd>"
            "<NP_Up_Notice_NamePipe_Name>\\\\.\\pipe\\OTI_ClipboardAgent</NP_Up_Notice_NamePipe_Name>"
            "<Param_Clipboard_Info_2></Param_Clipboard_Info_2></OTIMSG>", cmd);
        uint32_t xlen = (uint32_t)strlen(xml);
        uint8_t *pkt = calloc(1, 0x10000);
        uint32_t *h = (uint32_t *)pkt;
        h[0] = 1; h[1] = 0x11223344; h[2] = 0; h[3] = 1; h[4] = 1 + xlen;
        pkt[0x14] = 0x31;
        memcpy(pkt + 0x15, xml, xlen);
        memcpy(pkt + 0xFFEC, pkt, 20);
        int s = OTi_SendData(pkt);
        printf("OTi_SendData(frame)=%d payload_len=%u\n", s, h[4]);
        free(pkt);
        sleep(2);
    }

    if (argc > 1 && !strcmp(argv[1], "--send-xml")) {
        const char *xml =
            "<OTIMSG><NP_Cmd>Cmd_Get_KM_Switch_Acknowlege</NP_Cmd>"
            "<NP_Up_Notice_NamePipe_Name>\\\\.\\pipe\\OTI_ClipboardAgent</NP_Up_Notice_NamePipe_Name>"
            "<Param_Clipboard_Info_2></Param_Clipboard_Info_2></OTIMSG>";
        uint8_t *pkt = calloc(1, 0x10000);
        strcpy((char *)pkt, xml);
        int s = OTi_SendData(pkt);
        printf("OTi_SendData=%d xml_len=%zu\n", s, strlen(xml));
        free(pkt);
        sleep(1);
    }

    uint8_t *buf = calloc(1, 0x10000);
    for (int i = 0; i < 10; i++) {
        memset(buf, 0, 0x10000);
        int r = OTi_ReadData(buf);
        printf("OTi_ReadData[%d]=%d ", i, r);
        if (r > 0) dumpFrame(buf, r);
        else printf("\n");
        usleep(500000);
    }
    free(buf);
    OTi_Close();
    return 0;
}
