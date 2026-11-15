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

/* [T-remove-development-projects] The Swift shims that used to live here
 * (`MinisNativeLocalToolchain`, `MinisNativeCLICompile`) only existed for the
 * 开发项目 page; that page and its compile adapter (`NativeCLICompile.inc`) are
 * gone, so exposing them to Swift again would be a dangling API. The
 * `minis-native-build` handler below is unaffected — it is registered from
 * iSHKernel and drives itself from the guest side. */

#endif /* MINIS_NATIVE_BUILD_OFFLOAD_H */
