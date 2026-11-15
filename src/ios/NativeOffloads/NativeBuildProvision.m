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
            @"execution_state":[execProbe[@"clang_run"][@"errno"] intValue] == EPERM ? @"denied" : @"requires_full_probe",
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
