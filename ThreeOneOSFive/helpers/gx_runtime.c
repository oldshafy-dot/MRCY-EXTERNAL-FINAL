#include "gx_runtime.h"

#include <TargetConditionals.h>

#ifndef DEBUG
#include <dlfcn.h>
#include <unistd.h>
#endif

static volatile uint64_t gx_stamp = 0;
static volatile uint32_t gx_ready = 0;

void gx_gate_bind(uint64_t stamp) {
    gx_stamp = stamp;
    gx_ready = stamp ? 0x00A11CE5u : 0;
}

void gx_gate_clear(void) {
    gx_stamp = 0;
    gx_ready = 0;
}

int gx_gate_ok(uint64_t stamp) {
    if (stamp == 0 || gx_stamp == 0 || gx_ready != 0x00A11CE5u) {
        return 0;
    }
    return gx_stamp == stamp;
}

void gx_unfold(
    const uint8_t *salt,
    size_t salt_n,
    const uint8_t *input,
    uint8_t *output,
    size_t count
) {
    if (salt == NULL || salt_n == 0 || input == NULL || output == NULL) {
        return;
    }
    for (size_t index = 0; index < count; index++) {
        uint8_t value = input[index];
        value = (uint8_t)((value >> 2) | (value << 6));
        value ^= (uint8_t)(0x3C ^ ((index * 29) & 0xFF));
        value = (uint8_t)((value >> 5) | (value << 3));
        value ^= (uint8_t)(0xA5 ^ ((index * 13) & 0xFF));
        value ^= salt[index % salt_n];
        output[index] = value;
    }
}

void gx_harden_process(void) {
#if !TARGET_OS_SIMULATOR && !defined(DEBUG)
    typedef int (*gx_trace)(int, pid_t, void *, int);
    gx_trace hook = (gx_trace)dlsym(RTLD_DEFAULT, "ptrace");
    if (hook != NULL) {
        hook(31, 0, 0, 0);
    }
#endif
}
