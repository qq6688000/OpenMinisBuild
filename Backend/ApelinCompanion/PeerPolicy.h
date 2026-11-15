// Pure policy prototype; no kernel identity extraction is implemented here.
// Inputs are test observations, NOT authenticated claims from a device.
#pragma once
#include <stdint.h>
#include <stddef.h>
#include <string.h>
static inline int minis_peer_allowed(uint32_t uid, const char *identifier,
    const unsigned char *actual, const unsigned char *expected, size_t length,
    int client, int noSandbox, int valid) {
    if ((uid != 0 && uid != 501) || !identifier ||
        strcmp(identifier, "com.openminis.app") != 0 || length != 20 ||
        !actual || !expected || client != 1 || noSandbox != 1 || valid != 1) return 0;
    unsigned difference = 0, nonzero = 0;
    for (size_t i = 0; i < 20; ++i) {
        difference |= actual[i] ^ expected[i]; nonzero |= expected[i];
    }
    return difference == 0 && nonzero != 0;
}
#ifdef __APPLE__
#include <bsm/audit.h>
#include "MinisPeerPin.h"
// Fail closed: SDK symbol export alone proves neither operation numbers nor
// blob layout, signature trust, or audit-token semantics on the target device.
// Never call the pure predicate with unverified kernel or caller-supplied data.
static inline int minis_authenticate_token(audit_token_t *token, int client, int noSandbox) {
    (void)token; (void)client; (void)noSandbox;
    (void)minis_expected_cdhash;
    return 0;
}
#endif
