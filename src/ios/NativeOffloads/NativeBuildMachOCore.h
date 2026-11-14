/* [T-native-build] Pure-C Mach-O inspector core.
 *
 * No Foundation, no ObjC: this file is compiled both into the app (wrapped by
 * NativeBuildToolchain.m) and into a host test, so the rules that gate a build
 * are executed for real during regression instead of being re-implemented.
 *
 * Every read is bounds-checked: a build artifact is untrusted input, so a
 * truncated or garbage file must yield "invalid", never a crash.
 */
#ifndef NB_MACHO_CORE_H
#define NB_MACHO_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif


typedef struct {
    bool exists;
    bool valid;
    unsigned long long size;
    char arch[16];          /* arm64 / x86_64 / other / unknown */
    char filetype[16];      /* object / executable / dylib / ... / unknown */
    bool pie;
    bool has_main;
    bool has_ios_build;
    unsigned min_ios;       /* packed X.Y.Z nibbles; 0 when absent */
    bool has_code_signature;
    unsigned long long signature_size;
    char error[48];         /* "" when valid */
} NBMachOInfo;

/* Parse `len` bytes. Never reads outside [data, data+len). */
void NBMachOParse(const void *data, size_t len, NBMachOInfo *out);

/* Compare an expectation string against a field. Returns 1 when it matches,
 * 0 when it does not, -1 when the field name is not assertable. */
int NBMachOMatch(const NBMachOInfo *info, const char *field, const char *expected);
const char *NBMachOFieldValue(const NBMachOInfo *info, const char *field);

#ifdef __cplusplus
}
#endif

#endif
