#import "NativeBuildToolchain.h"
#include <unistd.h>
#include <sys/stat.h>
#include <errno.h>
#include <string.h>

NSDictionary *NBPathDiagnostics(NSString *path) {
    /* Keep the JSON contract valid for callers that pass a missing path. */
    if (!path) path = @"";
    const char *p = path.fileSystemRepresentation;
    NSMutableDictionary *d = [@{@"path":path, @"uid":@(getuid()), @"euid":@(geteuid()),
                               @"gid":@(getgid()), @"egid":@(getegid())} mutableCopy];
    struct stat st;
    int rc = lstat(p, &st), saved = rc == 0 ? 0 : errno;
    d[@"lstat"] = @{@"rc":@(rc), @"errno":@(saved), @"error":@(strerror(saved)),
        @"mode":rc == 0 ? [NSString stringWithFormat:@"%06o", (unsigned)st.st_mode] : (id)[NSNull null]};
    rc = stat(p, &st); saved = rc == 0 ? 0 : errno;
    NSMutableDictionary *s = [@{@"rc":@(rc), @"errno":@(saved), @"error":@(strerror(saved))} mutableCopy];
    if (rc == 0) {
        s[@"mode"] = [NSString stringWithFormat:@"%06o", (unsigned)st.st_mode];
        s[@"uid"] = @(st.st_uid); s[@"gid"] = @(st.st_gid); s[@"size"] = @(st.st_size);
        s[@"regular"] = @(S_ISREG(st.st_mode));
    }
    d[@"stat"] = s;
    const int modes[] = {F_OK, R_OK, X_OK};
    NSArray *names = @[@"F_OK", @"R_OK", @"X_OK"];
    NSMutableDictionary *a = [NSMutableDictionary dictionary];
    for (NSUInteger i=0; i<3; i++) {
        rc=access(p,modes[i]); saved=rc == 0 ? 0 : errno;
        a[names[i]] = @{@"rc":@(rc), @"errno":@(saved), @"error":@(strerror(saved))};
    }
    d[@"access"] = a;
    d[@"foundation_executable"] = @([[NSFileManager defaultManager] isExecutableFileAtPath:path]);
    return d;
}

#include "NativeBuildMachO.inc"
#include "NativeBuildRuntime.inc"

static BOOL NBReadableToolFile(NSString *path) {
    if (path.length == 0) return NO;
    const char *p = path.fileSystemRepresentation;
    struct stat st;
    if (stat(p, &st) != 0 || !S_ISREG(st.st_mode)) return NO;
    return access(p, R_OK) == 0;
}

/* Writable staging location. Execution permission is installation-dependent;
 * a cache path or mode bits alone do not establish launch permission. */
NSString *NBSearchPathForSharedCache(NSString *name) {
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *base = dirs.count > 0 ? dirs[0] : nil;
    // On iOS this is <Data>/Library/Caches; tolerate a macOS-style path.
    if (!base.length || !name.length) return nil;
    NSString *root = [base stringByAppendingPathComponent:@"native-toolchain"];
    if (![[NSFileManager defaultManager] createDirectoryAtPath:root
                              withIntermediateDirectories:YES attributes:nil error:NULL]) return nil;
    return [root stringByAppendingPathComponent:name];
}

NSString *NBToolchainRoot(void) {
    NSString *bundle = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Toolchain"];
    BOOL directory = NO;
    if ([NSFileManager.defaultManager fileExistsAtPath:bundle isDirectory:&directory] && directory)
        return bundle;
    NSString *cache = NBSearchPathForSharedCache(@"native-toolchain");
    return cache.length ? [cache stringByAppendingPathComponent:@"Toolchain"] : nil;
}

NSString *NBSDKRoot(void) {
    NSString *cache = NBSearchPathForSharedCache(@"native-toolchain");
    return cache.length ? [cache stringByAppendingPathComponent:@"iPhoneOS16.5.sdk"] : nil;
}

NBToolchainProbe NBToolchainCheck(NSString *root) {
    NBToolchainProbe r = {0};
    if (root.length == 0) root = NBToolchainRoot();
    if (root.length == 0) return r;
    r.clang = NBReadableToolFile([root stringByAppendingPathComponent:@"bin/clang"]);
    r.ld    = NBReadableToolFile([root stringByAppendingPathComponent:@"bin/ld"]);
    r.ldid  = NBReadableToolFile([root stringByAppendingPathComponent:@"bin/ldid"]);
    // SDK provisioning is independent of the selected tool location.
    NSString *archive = [NBSDKRoot() stringByAppendingPathComponent:@"SDKSettings.plist"];
    r.sdk = archive.length > 0 && access(archive.fileSystemRepresentation, R_OK) == 0;
    r.resourceDir = (access([[root stringByAppendingPathComponent:@"lib/clang/23/include"]
                              fileSystemRepresentation], R_OK) == 0);
    return r;
}

NSDictionary *NBToolchainDescribe(NSString *root) {
    if (root.length == 0) root = NBToolchainRoot();
    NBToolchainProbe p = NBToolchainCheck(root);
    BOOL present = p.clang || p.ld || p.ldid || p.sdk || p.resourceDir;
    NSMutableDictionary *files = [NSMutableDictionary dictionary];
    BOOL filesReady = p.sdk && p.resourceDir;
    NSMutableDictionary *signatures = [NSMutableDictionary dictionary];
    for (NSString *name in @[@"clang", @"ld", @"ldid"]) {
        NSString *path = [root stringByAppendingPathComponent:[@"bin/" stringByAppendingString:name]];
        struct stat st;
        BOOL readable = path && stat(path.fileSystemRepresentation, &st) == 0 &&
            S_ISREG(st.st_mode) && access(path.fileSystemRepresentation, R_OK) == 0;
        files[name] = @(readable);
        signatures[name] = NBMachOInspect(path);
        filesReady = filesReady && readable;
        present = present || readable;
    }
    return @{
        @"files":files, @"files_ready":@(filesReady), @"signatures":signatures,
        @"execution_verified":@NO,
        @"root": root ?: @"",
        @"source": [root isEqual:[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Toolchain"]] ? @"bundle" : @"cache_fallback",
        @"sdk_root": NBSDKRoot() ?: @"",
        @"sdk_source": @"cache",
        @"paths": @{@"clang":NBPathDiagnostics([root stringByAppendingPathComponent:@"bin/clang"]),
                    @"ld":NBPathDiagnostics([root stringByAppendingPathComponent:@"bin/ld"]),
                    @"ldid":NBPathDiagnostics([root stringByAppendingPathComponent:@"bin/ldid"])},
        @"present": @(present),
        @"clang": @(p.clang),
        @"ld": @(p.ld),
        @"ldid": @(p.ldid),
        @"sdk": @(p.sdk),
        @"resource_dir": @(p.resourceDir),
        @"ready": @(p.clang && p.ld && p.ldid && p.sdk && p.resourceDir),
        @"sdk_mode": @"provisioned-sdk-directory",
        @"note": @"ready only means every expected path is readable; "
                 @"run the probe tests on this installation before claiming a build."
    };
}
