#import "NativeBuildToolchain.h"
#include <unistd.h>
#include <sys/stat.h>

#include "NativeBuildMachO.inc"

static BOOL NBExecutableFile(NSString *path) {
    if (path.length == 0) return NO;
    const char *p = path.fileSystemRepresentation;
    struct stat st;
    if (stat(p, &st) != 0 || !S_ISREG(st.st_mode)) return NO;
    return access(p, X_OK) == 0;
}

NSString *NBToolchainRoot(void) {
    // Staged next to the app executable: <Bundle>/Toolchain (probe layout).
    NSString *root = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Toolchain"];
    return root;
}

NBToolchainProbe NBToolchainCheck(NSString *root) {
    NBToolchainProbe r = {0};
    if (root.length == 0) root = NBToolchainRoot();
    if (root.length == 0) return r;
    r.clang = NBExecutableFile([root stringByAppendingPathComponent:@"bin/clang"]);
    r.ld    = NBExecutableFile([root stringByAppendingPathComponent:@"bin/ld"]);
    r.ldid  = NBExecutableFile([root stringByAppendingPathComponent:@"bin/ldid"]);
    // SDK ships as an archive that is unpacked into a writable workspace at
    // build time (a directory of frameworks inside the bundle broke TrollStore's
    // recursive ldid -s during install — probed as install error 175).
    NSString *archive = [root stringByAppendingPathComponent:@"SDK.resources"];
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
        @"present": @(present),
        @"clang": @(p.clang),
        @"ld": @(p.ld),
        @"ldid": @(p.ldid),
        @"sdk_archive": @(p.sdk),
        @"resource_dir": @(p.resourceDir),
        @"ready": @(p.clang && p.ld && p.ldid && p.sdk && p.resourceDir),
        @"sdk_mode": @"archive-unpacked-at-build-time",
        @"note": @"ready only means every expected path exists and is executable; "
                 @"run the probe tests on this installation before claiming a build."
    };
}
