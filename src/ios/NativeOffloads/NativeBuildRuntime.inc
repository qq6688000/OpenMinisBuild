/* Read-only, allowlisted runtime observations. Never enumerate all entitlements,
 * environment variables, preferences, credentials or provisioning profiles. */
#include <dlfcn.h>
#include <sys/utsname.h>
#include <sys/mount.h>
#include <CoreFoundation/CoreFoundation.h>

NSDictionary *NBRuntimeDiagnostics(void) {
    struct utsname u; memset(&u, 0, sizeof(u)); int urc = uname(&u);
    NSMutableDictionary *out = [@{@"schema_version":@1,
        @"os_version":NSProcessInfo.processInfo.operatingSystemVersionString,
        @"kernel":urc == 0 ? @(u.release) : @"unknown",
        @"hardware_machine":urc == 0 ? @(u.machine) : @"unknown",
#if defined(__arm64__) || defined(__aarch64__)
        @"cpu":@"arm64",
#elif defined(__x86_64__)
        @"cpu":@"x86_64",
#else
        @"cpu":@"unknown",
#endif
        @"build_revision":[NSBundle.mainBundle objectForInfoDictionaryKey:@"MinisBuildRevision"] ?: @"unknown",
        @"build_number":[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"unknown",
        @"uid":@(getuid()), @"euid":@(geteuid()), @"pid":@(getpid()),
        @"policy_cause":@"unknown; EPERM does not distinguish sandbox, AMFI or installation trust",
        @"signature_layout_is_trust_verification":@NO} mutableCopy];
    NSString *exe = NSBundle.mainBundle.executablePath;
    out[@"current_executable"] = NBPathDiagnostics(exe);
    out[@"current_signature"] = NBMachOInspect(exe);
    typedef CFTypeRef (*CreateTask)(CFAllocatorRef);
    typedef CFTypeRef (*CopyValue)(CFTypeRef, CFStringRef, CFErrorRef *);
    CreateTask create = (CreateTask)dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf");
    CopyValue copy = (CopyValue)dlsym(RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
    CFTypeRef task = create ? create(kCFAllocatorDefault) : NULL;
    NSMutableDictionary *ent = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"com.apple.private.security.no-sandbox",
          @"com.apple.private.security.storage.AppDataContainers", @"platform-application",
          @"get-task-allow", @"com.apple.private.security.container-required"]) {
        CFErrorRef error = NULL;
        CFTypeRef value = task && copy ? copy(task, (__bridge CFStringRef)key, &error) : NULL;
        BOOL boolean = value && CFGetTypeID(value) == CFBooleanGetTypeID();
        // container-required can be a string: expose its type, never its raw value.
        ent[key] = @{@"query_available":@(task && copy), @"present":@(value != NULL),
            @"boolean":boolean ? @(CFBooleanGetValue((CFBooleanRef)value)) : (id)NSNull.null,
            @"type":!value ? @"absent_or_unavailable" : boolean ? @"boolean" :
                CFGetTypeID(value) == CFStringGetTypeID() ? @"string" : @"other",
            @"query_error_code":error ? @(CFErrorGetCode(error)) : @0};
        if (value) CFRelease(value);
        if (error) CFRelease(error);
    }
    if (task) CFRelease(task);
    out[@"current_process_entitlements"] = ent;
    typedef int (*CSOps)(pid_t, unsigned, void *, size_t);
    CSOps csopsFn = (CSOps)dlsym(RTLD_DEFAULT, "csops");
    unsigned flags = 0;
    int rc = csopsFn ? csopsFn(getpid(), 0, &flags, sizeof(flags)) : -1;
    int saved = rc == 0 ? 0 : csopsFn ? errno : ENOSYS;
    out[@"current_code_signing_status"] = @{@"rc":@(rc), @"errno":@(saved),
        @"flags":rc == 0 ? @(flags) : (id)NSNull.null};
    NSMutableDictionary *mounts = [NSMutableDictionary dictionary];
    for (NSString *kind in @[@"bundle", @"extracted"]) {
        NSString *path = [kind isEqual:@"bundle"] ? NSBundle.mainBundle.bundlePath : NBToolchainRoot();
        struct statfs fs; memset(&fs, 0, sizeof(fs));
        rc = path ? statfs(path.fileSystemRepresentation, &fs) : -1;
        saved = rc == 0 ? 0 : path ? errno : ENOENT;
        mounts[kind] = @{@"rc":@(rc), @"errno":@(saved),
            @"noexec":rc == 0 ? @((fs.f_flags & MNT_NOEXEC) != 0) : (id)NSNull.null,
            @"readonly":rc == 0 ? @((fs.f_flags & MNT_RDONLY) != 0) : (id)NSNull.null};
    }
    out[@"mount_observations"] = mounts;
    // There is no standalone signed helper in build61. Do not spawn Minis or
    // an extension with --version: those entry points launch application code.
    out[@"bundle_helper_probe"] = @{@"status":@"unavailable", @"attempted":@NO,
        @"reason":@"No dedicated signed diagnostic helper is packaged; app and extension entry points are not safe CLI probes"};
    return out;
}
