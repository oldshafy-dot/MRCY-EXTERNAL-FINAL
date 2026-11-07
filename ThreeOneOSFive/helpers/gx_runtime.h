#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void gx_gate_bind(uint64_t stamp);
void gx_gate_clear(void);
int gx_gate_ok(uint64_t stamp);
void gx_unfold(
    const uint8_t *salt,
    size_t salt_n,
    const uint8_t *input,
    uint8_t *output,
    size_t count
);
void gx_harden_process(void);

#ifdef __cplusplus
}
#endif
