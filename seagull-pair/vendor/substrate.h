#pragma once
#include <objc/runtime.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Minimal declarations for the public substrate APIs used by this project.
 * Link-only interface; no substrate implementation is bundled. */
void MSHookMessageEx(Class cls, SEL selector, IMP replacement, IMP *original);
void MSHookFunction(void *symbol, void *replacement, void **original);
#ifdef __cplusplus
}
#endif
