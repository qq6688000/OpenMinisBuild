// UI adapter lives in the registered native offload translation unit. No shell,
// PATH lookup, arbitrary executable, manifest flags, scripts, signing or install.
#include <stdatomic.h>

@interface MinisNativeCLICompile () {
    atomic_bool _cancelled;
    BOOL _running; // main queue only
}
- (BOOL)isCancelled;
@end

struct NBCLIContext {
    void *owner;
    void *output;
    size_t delivered;
    BOOL truncated;
};
// Bound inspection memory and reject replacement symlinks/non-regular outputs.
static BOOL nb_cli_artifact(NSString *path) {
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    return [attrs[NSFileType] isEqual:NSFileTypeRegular] &&
        [attrs[NSFileSize] unsignedLongLongValue] > 0 &&
        [attrs[NSFileSize] unsignedLongLongValue] <= 16 * 1024 * 1024 &&
        [path.stringByResolvingSymlinksInPath isEqual:path.stringByStandardizingPath];
}
static bool nb_cli_cancel(void *context) {
    MinisNativeCLICompile *owner = (__bridge MinisNativeCLICompile *)((struct NBCLIContext *)context)->owner;
    return [owner isCancelled];
}
static void nb_cli_output(NBPStream stream, const void *bytes, size_t size, void *context) {
    (void)stream;
    struct NBCLIContext *ctx = context;
    const size_t limit = 131072;
    size_t count = MIN(size, limit - ctx->delivered);
    if (count) {
        NSData *chunk = [NSData dataWithBytes:bytes length:count];
        void (^output)(NSData *) = (__bridge id)ctx->output;
        dispatch_async(dispatch_get_main_queue(), ^{ output(chunk); });
        ctx->delivered += count;
    }
    if (count != size) ctx->truncated = YES;
}
@implementation MinisNativeCLICompile
- (BOOL)isCancelled { return atomic_load(&_cancelled); }
- (void)cancel { atomic_store(&_cancelled, true); }
- (void)compileSource:(NSData *)source output:(void (^)(NSData *))output completion:(void (^)(NSDictionary *))completion {
    NSAssert(NSThread.isMainThread, @"UI adapter must be called on the main queue");
    if (_running) { completion(@{@"ok":@NO, @"error":@"A compilation is already running"}); return; }
    _running = YES;
    atomic_store(&_cancelled, false);
    NSData *snapshot = [source copy];
    void (^sink)(NSData *) = [output copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableDictionary *report = [NSMutableDictionary dictionaryWithDictionary:
            @{@"ok":@NO, @"phase":@"preflight", @"signed":@NO, @"installed":@NO}];
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *work = nil;
        do {
            if (snapshot.length == 0 || snapshot.length > 262144 || ![[NSString alloc] initWithData:snapshot encoding:NSUTF8StringEncoding]) {
                report[@"error"] = @"Source must be UTF-8, 1..262144 bytes"; break;
            }
            // iOS commonly returns /var/mobile paths whose system /var parent
            // aliases /private/var. Resolve that alias before composing children.
            NSString *root = NBToolchainRoot().stringByResolvingSymlinksInPath;
            NSString *sdk = NBSDKRoot().stringByResolvingSymlinksInPath;
            NSString *clang = [root stringByAppendingPathComponent:@"bin/clang"];
            NSString *resource = [root stringByAppendingPathComponent:@"lib/clang/23"];
            NSString *linker = [root stringByAppendingPathComponent:@"bin/ld"];
            report[@"linker"] = linker ?: @"";
            if (!linker || ![fm isExecutableFileAtPath:linker] ||
                ![linker.stringByResolvingSymlinksInPath isEqual:linker.stringByStandardizingPath]) {
                report[@"error"] = @"Native linker unavailable or symlinked: provision Toolchain/bin/ld with minis-native-build first"; break;
            }
            report[@"compiler"] = clang ?: @"";
            report[@"sdk"] = sdk ?: @"";
            // The SDK is provisioned to cache independently of bundle tools.
            BOOL paths = root && [fm isExecutableFileAtPath:clang] &&
                [fm isReadableFileAtPath:[sdk stringByAppendingPathComponent:@"SDKSettings.plist"]] &&
                [fm isReadableFileAtPath:[sdk stringByAppendingPathComponent:@"System/Library/Frameworks/Foundation.framework/Headers/Foundation.h"]] &&
                [fm isReadableFileAtPath:[resource stringByAppendingPathComponent:@"include/stddef.h"]];
            if (!paths) { report[@"error"] = @"Native compiler or iPhoneOS SDK unavailable; provision minis-native-build first"; break; }
            NSString *base = NBSearchPathForSharedCache(@"cli-builds").stringByResolvingSymlinksInPath;
            if (!base || ![base.stringByResolvingSymlinksInPath isEqual:base.stringByStandardizingPath] ||
                ![root.stringByResolvingSymlinksInPath isEqual:root.stringByStandardizingPath] ||
                ![sdk.stringByResolvingSymlinksInPath isEqual:sdk.stringByStandardizingPath]) {
                report[@"error"] = @"Build cache or toolchain path unavailable / contains symbolic links"; break;
            }
            NSError *error = nil;
            if (![fm createDirectoryAtPath:base withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error]) {
                report[@"error"] = error.localizedDescription; break;
            }
            if ([self isCancelled]) { report[@"error"] = @"Compilation cancelled before spawn"; break; }
            work = [base stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
            if (![fm createDirectoryAtPath:work withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:&error] ||
                ![snapshot writeToFile:[work stringByAppendingPathComponent:@"main.m"] options:NSDataWritingAtomic error:&error]) {
                report[@"error"] = error.localizedDescription ?: @"Cannot snapshot source"; break;
            }
            NSString *artifact = [work stringByAppendingPathComponent:@"main.o"];
            report[@"worktree"] = work;
            // Fixed Debug compile subset: exactly one .m translation unit,
            // arm64/iOS16, ARC, Foundation headers, no project-controlled flags.
            const char *args[] = {clang.fileSystemRepresentation, "-target", "arm64-apple-ios16.0",
                "-isysroot", sdk.fileSystemRepresentation, "-resource-dir", resource.fileSystemRepresentation,
                "-x", "objective-c", "-fobjc-arc", "-O0", "-g", "-DDEBUG=1",
                "-DAPELIN_VERSION=\"0.0.1\"", "-DAPELIN_BUILD_ID=\"minis-native-compile\"",
                "-c", "main.m", "-o", "main.o", NULL};
            const char *env[] = {"PATH=/usr/bin:/bin", "LANG=C", NULL};
            struct NBCLIContext context = {.owner=(__bridge void *)self, .output=(__bridge void *)sink};
            report[@"phase"] = @"compile";
            NBPResult result = NBPRun(&(NBPOptions){.executable=clang.fileSystemRepresentation, .argv=args,
                .envp=env, .cwd=work.fileSystemRepresentation, .timeout_ms=120000, .terminate_grace_ms=250,
                .output=nb_cli_output, .cancelled=nb_cli_cancel, .context=&context});
            report[@"status"] = @(result.status);
            report[@"exit_code"] = @(result.exit_code);
            report[@"errno"] = @(result.error_number);
            report[@"signal"] = @(result.termination_signal);
            report[@"spawn_attempted"] = @(result.spawn_attempted);
            report[@"error_stage"] = result.error_stage ? @(result.error_stage) : @"";
            report[@"output_truncated"] = @(context.truncated);
            if (result.status != NBP_EXITED || result.exit_code != 0) {
                report[@"error"] = result.status == NBP_CANCELLED ? @"Compilation cancelled" :
                    result.status == NBP_TIMED_OUT ? @"Compilation timed out" :
                    [NSString stringWithFormat:@"Compiler failed: status=%d exit=%d errno=%d (%s)", result.status, result.exit_code, result.error_number, strerror(result.error_number)];
                break;
            }
            if (!nb_cli_artifact(artifact)) { report[@"error"] = @"Object output must be a regular file, 1..16 MiB"; break; }
            NSDictionary *inspection = NBMachOInspect(artifact);
            report[@"artifact"] = inspection;
            BOOL ok = [inspection[@"valid"] boolValue] && [inspection[@"arch"] isEqual:@"arm64"] && [inspection[@"filetype"] isEqual:@"object"];
            report[@"phase"] = @"object-inspection";
            if (!ok) { report[@"error"] = @"Compiler output is not a valid arm64 Mach-O object"; break; }
            report[@"object"] = inspection;
            if ([self isCancelled]) { report[@"error"] = @"Build cancelled before link"; break; }
            // Direct linker invocation: no driver subprocess, response file,
            // manifest options, search PATH, signing or execution of the result.
            const char *linkArgs[] = {linker.fileSystemRepresentation,
                "-arch", "arm64", "-platform_version", "ios", "16.0", "16.5",
                "-syslibroot", sdk.fileSystemRepresentation, "-pie", "-e", "_main",
                "-no_adhoc_codesign", "main.o", "-lSystem", "-lobjc",
                "-framework", "Foundation", "-o", "hello-cli", NULL};
            report[@"phase"] = @"link";
            result = NBPRun(&(NBPOptions){.executable=linker.fileSystemRepresentation, .argv=linkArgs,
                .envp=env, .cwd=work.fileSystemRepresentation, .timeout_ms=120000, .terminate_grace_ms=250,
                .output=nb_cli_output, .cancelled=nb_cli_cancel, .context=&context});
            report[@"status"] = @(result.status);
            report[@"exit_code"] = @(result.exit_code);
            report[@"errno"] = @(result.error_number);
            report[@"signal"] = @(result.termination_signal);
            report[@"spawn_attempted"] = @(result.spawn_attempted);
            report[@"error_stage"] = result.error_stage ? @(result.error_stage) : @"";
            report[@"output_truncated"] = @(context.truncated);
            if (result.status != NBP_EXITED || result.exit_code != 0) {
                report[@"error"] = result.status == NBP_CANCELLED ? @"Link cancelled" :
                    result.status == NBP_TIMED_OUT ? @"Link timed out" :
                    [NSString stringWithFormat:@"Linker failed: status=%d exit=%d errno=%d", result.status, result.exit_code, result.error_number];
                break;
            }
            artifact = [work stringByAppendingPathComponent:@"hello-cli"];
            if ([self isCancelled]) { report[@"error"] = @"Build cancelled after link"; break; }
            if (!nb_cli_artifact(artifact)) { report[@"error"] = @"Executable output must be a regular file, 1..16 MiB"; break; }
            inspection = NBMachOInspect(artifact);
            report[@"artifact"] = inspection;
            NSSet *required = [NSSet setWithArray:@[@"/usr/lib/libSystem.B.dylib", @"/usr/lib/libobjc.A.dylib",
                @"/System/Library/Frameworks/Foundation.framework/Foundation"]];
            // The SDK may emit CoreFoundation as Foundation's re-export.
            NSMutableSet *allowed = [required mutableCopy];
            [allowed addObject:@"/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"];
            NSArray *dependencies = inspection[@"dependencies"];
            NSSet *actual = [NSSet setWithArray:dependencies ?: @[]];
            ok = [inspection[@"valid"] boolValue] && [inspection[@"arch"] isEqual:@"arm64"] &&
                [inspection[@"filetype"] isEqual:@"executable"] && [inspection[@"pie"] boolValue] &&
                [inspection[@"has_main"] boolValue] && [inspection[@"has_ios_build"] boolValue] &&
                ![inspection[@"has_code_signature"] boolValue] && ![inspection[@"dependencies_truncated"] boolValue] && dependencies.count == actual.count &&
                [required isSubsetOfSet:actual] && [actual isSubsetOfSet:allowed];
            report[@"ok"] = @(ok);
            report[@"phase"] = @"artifact-inspection";
            report[@"product_kind"] = @"unsigned executable";
            if (!ok) report[@"error"] = @"Linked artifact failed arm64 iOS MH_EXECUTE / PIE / LC_MAIN / unsigned / system-dependency checks";
        } while (0);
        // Keep the immutable snapshot and artifact for review. No product runs.
        dispatch_async(dispatch_get_main_queue(), ^{ self->_running = NO; completion(report); });
    });
}
@end

#import "NativeBuildProvision.h"
@implementation MinisNativeLocalToolchain
- (void)performOperation:(NBLocalToolchainOperation)operation completion:(void (^)(NSDictionary *))completion {
    // Serialize provisioning and inspections across UI instances. NBPRun policy
    // remains unchanged. Only bundled clang and ld --version may be probed.
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("minis.local-toolchain", DISPATCH_QUEUE_SERIAL); });
    dispatch_async(queue, ^{
        NSMutableDictionary *report = [NSMutableDictionary dictionary];
        report[@"schema_version"] = @1;
        report[@"runtime"] = NBRuntimeDiagnostics();
        report[@"operation"] = operation == NBLocalToolchainOperationProvision ? @"provision" : operation == NBLocalToolchainOperationProbe ? @"probe" : @"inspect";
        if (operation == NBLocalToolchainOperationProvision) report[@"provision"] = NBProvisionBundledToolchain();
        report[@"toolchain"] = NBToolchainDescribe(nil);
        NSString *root = NBToolchainRoot().stringByResolvingSymlinksInPath;
        NSString *sdk = NBSDKRoot().stringByResolvingSymlinksInPath;
        BOOL headers = [NSFileManager.defaultManager isReadableFileAtPath:[sdk stringByAppendingPathComponent:@"System/Library/Frameworks/Foundation.framework/Headers/Foundation.h"]];
        report[@"files_ready"] = @([report[@"toolchain"][@"files_ready"] boolValue] && headers);
        report[@"execution_state"] = @"not_probed";
        report[@"sdk"] = sdk ?: @"";
        if (operation == NBLocalToolchainOperationProbe) {
            NSMutableDictionary *probes = [NSMutableDictionary dictionary];
            BOOL passed = YES;
            for (NSString *name in @[@"clang", @"ld"]) {
                NSString *exe = [root stringByAppendingPathComponent:[@"bin/" stringByAppendingString:name]];
                // Same no-symlink requirement as Build+Link, not an X_OK gate.
                if (!exe || ![exe.stringByResolvingSymlinksInPath isEqual:exe.stringByStandardizingPath]) {
                    probes[name] = @{@"ok":@NO, @"error":@"Tool path unavailable or symlinked"}; passed = NO; continue;
                }
                const char *args[] = {exe.fileSystemRepresentation, "--version", NULL};
                const char *env[] = {"PATH=/usr/bin:/bin", "LANG=C", NULL};
                NBPResult result = NBPRun(&(NBPOptions){.executable=exe.fileSystemRepresentation, .argv=args, .envp=env, .timeout_ms=15000, .terminate_grace_ms=250});
                BOOL ok = result.status == NBP_EXITED && result.exit_code == 0;
                probes[name] = @{@"ok":@(ok), @"spawn_attempted":@(result.spawn_attempted), @"spawn_succeeded":@(result.pid>0), @"status":@(result.status), @"exit":@(result.exit_code), @"errno":@(result.error_number), @"error_stage":result.error_stage ? @(result.error_stage) : @"", @"signal":@(result.termination_signal)};
                passed = passed && ok;
            }
            report[@"probe"] = probes;
            report[@"spawn_verified"] = @(passed);
            BOOL denied = [probes[@"clang"][@"errno"] intValue] == EPERM || [probes[@"ld"][@"errno"] intValue] == EPERM;
            report[@"execution_state"] = passed ? @"verified" : denied ? @"denied" : @"failed";
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(report); });
    });
}
@end
