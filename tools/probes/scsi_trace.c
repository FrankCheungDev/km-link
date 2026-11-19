// Interpose IOKit user-client calls to log the original app's SCSI traffic.
// Build (x86_64, to match the Intel GoBridgeDemon under Rosetta):
//   clang -target x86_64-apple-macos13.0 -dynamiclib -isysroot <SDK> \
//     -framework IOKit -o build/scsi_trace.dylib tools/scsi_trace.c
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <pthread.h>
#include <dlfcn.h>
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>

#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } \
    _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = \
    { (const void *)(uintptr_t)&_replacement, (const void *)(uintptr_t)&_replacee };

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static FILE *g_log;
static int g_ready;

static void ensure_log(void) {
    if (g_ready) return;
    g_ready = 1;
    const char *path = getenv("KMLINK_TRACE_PATH");
    g_log = fopen(path ? path : "/tmp/kmlink-scsi.log", "a");
}

static void dump(const uint8_t *data, size_t count, size_t limit) {
    if (!data) { fprintf(g_log, "-"); return; }
    size_t n = count < limit ? count : limit;
    for (size_t i = 0; i < n; i++) fprintf(g_log, "%02x", data[i]);
    if (count > n) fprintf(g_log, "...(%zu)", count);
}

static kern_return_t (*orig_struct)(io_connect_t, uint32_t, const void *, size_t, void *, size_t *);
static void *g_iokit;
static const char *g_target = "_IOConnectCallStructMethod";

static void *lookup_iokit_symbol(void) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || !strstr(name, "IOKit.framework")) continue;
        const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (!header || header->magic != MH_MAGIC_64) continue;
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const uint8_t *cursor = (const uint8_t *)(header + 1);
        const struct symtab_command *symtab = NULL;
        for (uint32_t c = 0; c < header->ncmds; c++) {
            const struct load_command *lc = (const struct load_command *)cursor;
            if (lc->cmd == LC_SYMTAB) { symtab = (const struct symtab_command *)cursor; break; }
            cursor += lc->cmdsize;
        }
        if (!symtab) continue;
        const struct nlist_64 *symbols = (const struct nlist_64 *)((const uint8_t *)header + symtab->symoff);
        const char *strings = (const char *)((const uint8_t *)header + symtab->stroff);
        for (uint32_t s = 0; s < symtab->nsyms; s++) {
            if (!symbols[s].n_un.n_strx) continue;
            const char *sym = strings + symbols[s].n_un.n_strx;
            if (strcmp(sym, g_target) == 0) return (void *)(symbols[s].n_value + slide);
        }
    }
    return NULL;
}
static long g_calls;
static __thread int g_in_call;

static kern_return_t my_struct(io_connect_t connection, uint32_t selector,
                               const void *input, size_t inputCount,
                               void *output, size_t *outputCount) {
    if (g_in_call) return KERN_FAILURE;
    if (!orig_struct) {
        orig_struct = (kern_return_t (*)(io_connect_t, uint32_t, const void *, size_t, void *, size_t *))
            lookup_iokit_symbol();
        if (!orig_struct) return KERN_FAILURE;
    }
    if (inputCount < 8 || g_calls > 4000) return orig_struct(connection, selector, input, inputCount, output, outputCount);
    g_calls++;
    g_in_call = 1;
    ensure_log();
    pthread_mutex_lock(&g_lock);
    fprintf(g_log, "CALL conn=%u sel=%u in=%zu ", connection, selector, inputCount);
    dump((const uint8_t *)input, inputCount, 512);
    fflush(g_log);
    pthread_mutex_unlock(&g_lock);

    kern_return_t kr = orig_struct(connection, selector, input, inputCount, output, outputCount);

    pthread_mutex_lock(&g_lock);
    fprintf(g_log, " -> 0x%x out=%zu ", kr, outputCount ? *outputCount : 0);
    dump((const uint8_t *)output, outputCount ? *outputCount : 0, 512);
    fprintf(g_log, "\n");
    fflush(g_log);
    pthread_mutex_unlock(&g_lock);
    g_in_call = 0;
    return kr;
}

DYLD_INTERPOSE(my_struct, IOConnectCallStructMethod)

__attribute__((constructor)) static void init(void) {
    ensure_log();
    if (g_log) { fprintf(g_log, "=== injected pid=%d ===\n", getpid()); fflush(g_log); }
}
