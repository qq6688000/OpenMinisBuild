/* Tool discovery and file diagnostics only. Actual launch probes establish
 * execution readiness on this installation; bundle placement does not prove it. */
#ifndef MINIS_NATIVE_BUILD_TOOLCHAIN_H
#define MINIS_NATIVE_BUILD_TOOLCHAIN_H

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    BOOL clang, ld, ldid, sdk, resourceDir;
} NBToolchainProbe;

/* Prefer bundle Toolchain/ when present, otherwise the legacy cache location.
 * NBToolchainDescribe reports the selected source; no launch-based fallback. */
NSString *NBToolchainRoot(void);
/* SDK always lives in the writable cache, independently of the tool root. */
NSString *NBSDKRoot(void);

/* Writable staging location <Data>/Library/Caches/native-toolchain/<name>.
 * Execution readiness must be established independently on this installation. */
NSString *NBSearchPathForSharedCache(NSString *name);

/* Stat/access the layout rooted at `root` (nil → NBToolchainRoot()). */
NBToolchainProbe NBToolchainCheck(NSString *root);

/* Human/JSON-ready description. Never runs anything. */
NSDictionary *NBToolchainDescribe(NSString *root);
/* Independent host lstat/stat/access observations; never gates a launch. */
NSDictionary *NBPathDiagnostics(NSString *path);
/* Actual current-process entitlements and observed signing/mount policy.
 * Allowlisted booleans/types only; never raw profile, preferences or credentials. */
NSDictionary *NBRuntimeDiagnostics(void);

/* [T-native-build] Artifact inspection: parse a Mach-O far enough to answer
 * "did the tool actually produce the right thing?", so no build step is ever
 * accepted on exit status alone. Read-only; the file is never executed and no
 * signature is cryptographically verified — only the LC_CODE_SIGNATURE region.
 *
 * Keys: path, exists, valid, size, arch (arm64/x86_64/other), filetype
 * (object/executable/dylib/...), pie, has_main, has_ios_build, min_ios,
 * has_code_signature, signature_size, error ("" when valid). */
NSDictionary *NBMachOInspect(NSString *path);

#ifdef __cplusplus
}
#endif

#endif /* MINIS_NATIVE_BUILD_TOOLCHAIN_H */
