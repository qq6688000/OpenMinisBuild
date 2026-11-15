#import "NativeBuildProvision.h"
#include "NativeBuildExtract.h"
#import "NativeBuildToolchain.h"
#import "NativeBuildProcess.h"
#include "NativeBuildMachOCore.h"
#include <string.h>

NSDictionary *NBExtractArchive(NSString *archivePath, NSString *destDir,
                               NSString *stripFirstComponent) {
    if (!archivePath.length || !destDir.length)
        return @{ @"ok": @NO, @"entries": @0, @"bytes": @0,
                  @"stage": @"arguments", @"path": @"", @"errno": @(EINVAL),
                  @"error": @"missing arguments" };
    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:destDir
                                  withIntermediateDirectories:YES attributes:nil error:&error]) {
        return @{ @"ok": @NO, @"entries": @0, @"bytes": @0,
                  @"stage": @"dest_mkdir", @"path": destDir,
                  @"error": error.localizedDescription ?: @"destination creation failed",
                  @"error_domain": error.domain ?: @"", @"error_code": @(error.code) };
    }
    NBExtractResult r = NBExtractCore(archivePath.fileSystemRepresentation,
                                     destDir.fileSystemRepresentation,
                                     stripFirstComponent.UTF8String);
    NSString *stage = [NSString stringWithUTF8String:r.stage] ?: @"";
    NSString *path = [NSString stringWithUTF8String:r.path] ?: @"<invalid UTF-8>";
    NSString *detail = [NSString stringWithUTF8String:r.detail] ?: @"<invalid UTF-8>";
    return @{ @"ok": @(r.ok), @"entries": @(r.entries), @"bytes": @(r.bytes),
              @"directories": @(r.directories), @"symlinks": @(r.symlinks),
              @"stage": stage, @"path": path, @"errno": @(r.error_number),
              @"error": r.ok ? @"" : [NSString stringWithFormat:@"%@: %@ (errno=%d): %@",
                                      stage, path, r.error_number, detail] };
}

NSMutableDictionary *NBPLaunchPolicyDictionary(void) {
    NBPSpawnProbe probe;
    int rc = NBPSpawnProbeSelf(NULL, &probe);
    char decoded[192];
    NBPSpawnFlagsDescribe(probe.cs_flags, decoded, sizeof(decoded));
    NSString *verdict = @"unknown";
    if (probe.valid) {
        verdict = NBPSpawnFlagsDenyLaunchPolicy(probe.cs_flags) ? @"install_launch_policy_denies"
                                                               : @"launch_policy_allows";
    }
    return [@{@"rc":@(rc), @"probe_valid":@(probe.valid), @"probe_errno":@(probe.error_number),
        @"cs_flags":@(probe.cs_flags), @"cs_flags_decoded":@(decoded),
        @"denies_exec":probe.valid ? @(NBPSpawnFlagsDenyLaunchPolicy(probe.cs_flags)) : (id)NSNull.null,
        @"verdict":verdict,
        @"euid":@(probe.euid), @"egid":@(probe.egid), @"pid":@(probe.pid),
        @"parent_pid":@(probe.parent_pid),
        @"parent_executable":probe.parent_path_valid ? @(probe.parent_path) : @"unknown",
        @"entitlements_present":@(probe.entitlements_present),
        @"entitlement_blob_size":@(probe.entitlement_blob_size),
        @"topic":@"cs_flags describe this installation's code signature, not the toolchain. "
                  "CS_HARD / CS_ENFORCEMENT / CS_REQUIRE_LV / CS_FORCED_LV or a missing CS_VALID "
                  "make the kernel refuse every exec from this process (proc_launch_check), "
                  "including access(X_OK) on its own executable. That is an installation shape "
                  "problem: reinstall/resign the app in TrollStore, or ship without a platform blob."}
     mutableCopy];
}

// Shared structured entry point; callers must dispatch off the main thread.
NSDictionary *NBProvisionBundledToolchain(void) {
    @synchronized (NSFileManager.defaultManager) {
        NSString *bundle=NSBundle.mainBundle.bundlePath;
        NSString *resDir=[bundle stringByAppendingPathComponent:@"ToolchainResources"];
        NSString *cache=NBSearchPathForSharedCache(@"native-toolchain").stringByResolvingSymlinksInPath;
        if(!cache) return @{@"ready":@NO, @"ok":@NO, @"error":@"Writable native toolchain cache unavailable"};
        NSFileManager *fm=[NSFileManager defaultManager];
        NSString *toolRoot=NBToolchainRoot();
        BOOL bundleTools=[toolRoot isEqual:[bundle stringByAppendingPathComponent:@"Toolchain"]];

        NSDictionary *toolchain=bundleTools ? @{ @"ok":@YES, @"skipped":@YES, @"source":@"bundle" } : NBExtractArchive([resDir stringByAppendingPathComponent:@"MinToolchain.tgz"],
                                                 toolRoot,@"Toolchain");
        NSDictionary *sdk=NBExtractArchive([resDir stringByAppendingPathComponent:@"MinSDK.tgz"],
                                           NBSDKRoot(),@"iPhoneOS16.5.sdk");

        /* Trust nothing that was not checked: stat the things a build needs. */
        NSString *clang=[toolRoot stringByAppendingPathComponent:@"bin/clang"];
        NSString *ld=[toolRoot stringByAppendingPathComponent:@"bin/ld"];
        NSString *ldid=[toolRoot stringByAppendingPathComponent:@"bin/ldid"];
        NSString *sdkDir=NBSDKRoot();
        NSString *resDirClang=[toolRoot stringByAppendingPathComponent:@"lib/clang/23"];
        BOOL clangOK=[fm isReadableFileAtPath:clang];
        BOOL ldOK=[fm isReadableFileAtPath:ld];
        BOOL ldidOK=[fm isReadableFileAtPath:ldid];
        BOOL sdkOK=[fm fileExistsAtPath:[sdkDir stringByAppendingPathComponent:@"SDKSettings.plist"]];
        BOOL resOK=[fm fileExistsAtPath:[resDirClang stringByAppendingPathComponent:@"include/stddef.h"]];

        /* [T-native-build] Files existing is not the question; whether this
         * installation may execute them is. Run clang once here so a single
         * provision answers it instead of costing a separate probe round. */
        /* Before the first spawn: once one is denied the kernel caches the
         * verdict in P_LFLAG_NOEXEC for the rest of the process's life. */
        NSDictionary *launchPolicy=NBPLaunchPolicyDictionary();
        NSMutableDictionary *execProbe=[NSMutableDictionary dictionary];
        for(NSString *label in @[@"clang",@"ld",@"ldid"]){
            NSString *exe=[toolRoot stringByAppendingPathComponent:[@"bin/" stringByAppendingString:label]];
            NSDictionary *d=NBPathDiagnostics(exe);
            NSMutableDictionary *m=[NSMutableDictionary dictionaryWithDictionary:
                @{@"X_OK":d[@"access"][@"X_OK"],@"mode":d[@"stat"][@"mode"] ?: (id)[NSNull null]}];
            /* Structural observations only; blob count does not establish trust. */
            NSData *blobData=[NSData dataWithContentsOfFile:exe options:NSDataReadingMappedIfSafe error:NULL];
            if(blobData){
                NBMachOInfo info; memset(&info,0,sizeof(info));
                NBMachOParse(blobData.bytes,blobData.length,&info);
                if(info.valid){
                    m[@"signature_blobs"]=@(info.signature_blobs);
                    m[@"code_directory_size"]=@(info.code_directory_size);
                }
            }
            execProbe[label]=m;
        }
        {
            const char *av[]={clang.fileSystemRepresentation,"--version",NULL};
            NBPResult r=NBPRun(&(NBPOptions){.executable=clang.fileSystemRepresentation,.argv=av,
                                             .timeout_ms=15000,.terminate_grace_ms=250,.output=NULL});
            execProbe[@"clang_run"]=@{@"ran":@(r.status==NBP_EXITED),@"exit":@(r.exit_code),
                @"spawn_attempted":@(r.spawn_attempted), @"spawn_succeeded":@(r.pid>0),
                @"status":@(r.status), @"signal":@(r.termination_signal),
                @"error_stage":r.error_stage ? @(r.error_stage) : @"",@"errno":@(r.error_number),
                @"error":@(strerror(r.error_number))};
        }

        BOOL extracted = [toolchain[@"ok"] boolValue] && [sdk[@"ok"] boolValue];
        BOOL filesReady = clangOK&&ldOK&&ldidOK&&sdkOK&&resOK;
        return @{@"provision":@YES, @"ok":@(extracted && filesReady),
            @"extraction_ok":@(extracted), @"files_ready":@(filesReady),
            @"execution_verified":@NO,
            @"execution_state":^NSString*{
                int err=[execProbe[@"clang_run"][@"errno"] intValue];
                if(err!=EPERM) return @"requires_full_probe";
                return [launchPolicy[@"denies_exec"] boolValue] ? @"denied_launch_policy" : @"denied";
            }(),
            @"launch_policy":launchPolicy,
            @"runtime":NBRuntimeDiagnostics(),
            @"tool_source":bundleTools ? @"bundle" : @"cache_fallback",
            @"sdk_source":@"cache", @"tool_root":toolRoot,@"sdk_dir":sdkDir,@"path_diagnostics":NBToolchainDescribe(toolRoot)[@"paths"],
            @"sdk_archive":sdk,@"toolchain_archive":toolchain,
            @"clang":@(clangOK),@"ld":@(ldOK),@"ldid":@(ldidOK),
            @"sdk":@(sdkOK),@"resource_dir":@(resOK),
            @"exec_probe":execProbe,
            @"ready":@(extracted && filesReady),
            @"note":@"ok/ready describe extraction and readable files only. clang_run records the independent launch result, including errno/stage. A full clang/ld probe still gates Build+Link. Signature layout does not verify trust or identify an EPERM cause."};
    }
}
