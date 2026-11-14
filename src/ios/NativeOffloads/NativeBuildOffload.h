#ifndef MINIS_NATIVE_BUILD_OFFLOAD_H
#define MINIS_NATIVE_BUILD_OFFLOAD_H

/* Registers the `minis-native-build` command with the iSH kernel. Called once
 * at kernel init (ISHKernel.m). Declared extern "C" so an Objective-C++ or C++
 * translation unit can include this header without mangling the symbol. */
#ifdef __cplusplus
extern "C" {
#endif

void native_build_offload_register(void);

#ifdef __cplusplus
}
#endif

#endif /* MINIS_NATIVE_BUILD_OFFLOAD_H */
