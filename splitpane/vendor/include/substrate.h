/* Minimal Substrate API declarations for logos-generated tweaks.
   Symbols resolve from libsubstrate.dylib at runtime (tbd provides linkage). */
#ifndef SUBSTRATE_H
#define SUBSTRATE_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef const void *MSImageRef;
void MSHookFunction(void *symbol, void *hook, void **old);
void MSHookMessageEx(Class _class, SEL sel, IMP imp, IMP *result);
MSImageRef MSGetImageByName(const char *file);
void *MSFindSymbol(MSImageRef image, const char *name);
void MSHookClassPair(Class hookClass, Class baseClass, Class oldClass);
void MSHookMemory(void *target, const void *data, size_t size);
#ifdef __cplusplus
}
#endif
#endif
