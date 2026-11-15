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

static BOOL NBExecutableFile(NSString *path) {
    if (path.length == 0) return NO;
    const char *p = path.fileSystemRepresentation;
    struct stat st;
    if (stat(p, &st) != 0 || !S_ISREG(st.st_mode)) return NO;
    return access(p, X_OK) == 0;
}

/* [T-native-build] Single source of truth for where the toolchain lives.
 * Never the app's tmp/: on iOS that location rejects exec (access X_OK and
 * posix_spawn both return EPERM) even with no-sandbox + AppDataContainers,
 * which is what broke the container-required builds. Library/Caches is inside
 * the data container, writable, and executable. */
NSString *NBSearchPathForSharedCache(NSString *name) {
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *base = dirs.count > 0 ? dirs[0] : nil;
    // On iOS this is <Data>/Library/Caches; tolerate a macOS-style path.
    NSString *root = [base stringByAppendingPathComponent:@"native-toolchain"];
    [[NSFileManager defaultManager] createDirectoryAtPath:root
                              withIntermediateDirectories:YES attributes:nil error:NULL];
    return [root stringByAppendingPathComponent:name];
}

NSString *NBToolchainRoot(void) {
    // Unpacked from <Bundle>/ToolchainResources/MinToolchain.tgz by provision.
    // It must NOT be the bundle: TrollStore re-signs every Mach-O under the app
    // bundle on install, which inflates our pristine 4-blob adhoc signature to
    // 6 blobs and makes AMFI refuse exec with EPERM.
    NSString *cache = NBSearchPathForSharedCache(@"native-toolchain");
    if (cache.length) return [cache stringByAppendingPathComponent:@"Toolchain"];
    return nil;
}

NBToolchainProbe NBToolchainCheck(NSString *root) {
    NBToolchainProbe r = {0};
    if (root.length == 0) root = NBToolchainRoot();
    if (root.length == 0) return r;
    r.clang = NBExecutableFile([root stringByAppendingPathComponent:@"bin/clang"]);
    r.ld    = NBExecutableFile([root stringByAppendingPathComponent:@"bin/ld"]);
    r.ldid  = NBExecutableFile([root stringByAppendingPathComponent:@"bin/ldid"]);
    // Provision places SDK beside Toolchain, shared with the CLI compiler.
    NSString *archive = [[root stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"iPhoneOS16.5.sdk/SDKSettings.plist"];
    r.sdk = archive.length > 0 && access(archive.fileSystemRepresentation, R_OK) == 0;
    r.resourceDir = (access([[root stringByAppendingPathComponent:@"lib/clang/23/include"]
                              fileSystemRepresentation], R_OK) == 0);
    return r;
}

NSDictionary *NBToolchainDescribe(NSString *root) {
    if (root.length == 0) root = NBToolchainRoot();
    NBToolchainProbe p = NBToolchainCheck(root);
    BOOL present = p.clang || p.ld || p.ldid || p.sdk || p.resourceDir;
    return @{
        @"root": root ?: @"",
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
        @"note": @"ready only means every expected path exists and is executable; "
                 @"run the probe tests on this installation before claiming a build."
    };
}
