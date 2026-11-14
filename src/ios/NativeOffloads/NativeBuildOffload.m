#import <Foundation/Foundation.h>
#import "NativeBuildOffload.h"
#import "NativeBuildProcess.h"
#import "NativeBuildToolchain.h"
#import "NativeOffloadUtils.h"
#include "kernel/native_offload.h"
#include <unistd.h>
#include <errno.h>
#include <math.h>

/* NB_OUTPUT_BEGIN: kept plain C so the backpressure harness tests this code. */
#include <fcntl.h>
#include <poll.h>
#include <sys/stat.h>
#include <time.h>
#include <stdint.h>

/* Only valid for the per-invocation pipe write ends supplied by
 * exec_builtin_handler. dup() of a guest FD would NOT provide isolation. */
struct NBChannel {
    int fd, original_flags, error;
    bool changed, disabled;
    uint64_t wait_ms, written, dropped;
};
struct NBOutput {
    struct NBChannel channels[2];
    const char *cancel_path;
    uint64_t deadline_ms;
};
static uint64_t nb_now(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts)) return UINT64_MAX;
    return (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
}
static bool nb_cancelled(void *context) {
    struct NBOutput *fds=context;
    return fds->cancel_path && access(fds->cancel_path,F_OK)==0;
}
static void nb_channel_init(struct NBChannel *channel, int fd) {
    *channel=(struct NBChannel){.fd=fd,.original_flags=-1};
    struct stat st;
    if (fstat(fd,&st)<0) { channel->error=errno; goto fail; }
    if (!S_ISFIFO(st.st_mode)) { channel->error=ENOTSUP; goto fail; }
    channel->original_flags=fcntl(fd,F_GETFL);
    if (channel->original_flags<0) { channel->error=errno; goto fail; }
    /* Darwin's per-FD SIGPIPE suppression avoids changing process signals.
     * If unavailable, fail closed instead of risking the host process. */
    if (fcntl(fd,F_SETNOSIGPIPE,1)<0) { channel->error=errno; goto fail; }
    if (fcntl(fd,F_SETFL,channel->original_flags|O_NONBLOCK)<0) {
        channel->error=errno; goto fail;
    }
    channel->changed=true;
    return;
fail:
    channel->disabled=true;
}
static void nb_channel_close(struct NBChannel *channel) {
    /* The kernel owns the descriptors; do not close them here. */
    if (channel->changed && fcntl(channel->fd,F_SETFL,channel->original_flags)<0 && !channel->error)
        channel->error=errno;
}
static void nb_output(NBPStream stream, const void *bytes, size_t size, void *context) {
    struct NBOutput *fds=context;
    struct NBChannel *channel=&fds->channels[stream==NBP_STDOUT ? 0 : 1];
    const char *p=bytes;
    while (size && !channel->disabled) {
        uint64_t now=nb_now();
        if (now==UINT64_MAX) { channel->error=EIO; break; }
        if (nb_cancelled(fds)) { channel->error=ECANCELED; break; }
        if (fds->deadline_ms && now>=fds->deadline_ms) { channel->error=ETIMEDOUT; break; }
        /* Even an uninterrupted successful writer must check time/cancel
         * between bounded writes. Nonblocking makes poll readiness races safe. */
        size_t chunk=size>512 ? 512 : size;
        ssize_t n=write(channel->fd,p,chunk);
        if (n>0) { p+=n; size-=(size_t)n; channel->written+=(uint64_t)n; continue; }
        if (n<0 && errno==EINTR) {
            if (++channel->wait_ms>=100) { channel->error=EINTR; break; }
            continue;
        }
        if (n<0 && (errno==EAGAIN || errno==EWOULDBLOCK)) {
            if (channel->wait_ms>=100) { channel->error=EAGAIN; break; }
            int delay=(int)(100-channel->wait_ms);
            if (delay>10) delay=10;
            if (fds->deadline_ms && fds->deadline_ms-now<(uint64_t)delay)
                delay=(int)(fds->deadline_ms-now);
            struct pollfd watch={channel->fd,POLLOUT,0};
            int ready=poll(&watch,1,delay);
            int saved=errno;
            uint64_t after=nb_now();
            if (after==UINT64_MAX) { channel->error=EIO; break; }
            /* Charge at least one ms even on readiness races / EINTR. */
            channel->wait_ms+=after>now ? after-now : 1;
            if (ready<0 && saved!=EINTR) { channel->error=saved; break; }
            if (ready>0 && (watch.revents&(POLLERR|POLLHUP|POLLNVAL))) {
                channel->error=(watch.revents&POLLNVAL) ? EBADF : EPIPE; break;
            }
            continue;
        }
        channel->error=n<0 ? errno : EIO;
        break;
    }
    if (size) { channel->dropped+=(uint64_t)size; channel->disabled=true; }
}
/* NB_OUTPUT_END */

static void nb_json(struct NBOutput *fds, NBPStream stream, NSDictionary *value) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    if (data) {
        nb_output(stream,data.bytes,data.length,fds);
        nb_output(stream,"\n",1,fds);
    }
}
static int nb_error(struct NBOutput *fds, NSString *text) {
    nb_json(fds,NBP_STDERR,@{@"error":text}); return 2;
}
static BOOL nb_string(id value) {
    return [value isKindOfClass:NSString.class] && [value rangeOfString:[NSString stringWithFormat:@"%C",(unichar)0]].location==NSNotFound;
}
static int nb_handle(int argc,char **argv,int stdin_fd,struct NBOutput *fds) {
    (void)stdin_fd;
    @autoreleasepool {
        if(argc==1 || noff_has_flag(argc,argv,"--help")) {
            NSString *help=@"minis-native-build doctor\nminis-native-build inspect --artifact /guest/path/MachO\nminis-native-build doctor [--probe]\nminis-native-build run --request /guest/path/request.json\nRequest: executable (absolute HOST path), arguments (array), cwd (optional HOST path), timeout_ms (1..3600000). cancel_file (optional absolute GUEST path; create it to cancel, polled only). stdout/stderr stream raw with at most 100ms aggregate backpressure wait per stream; excess is dropped. Final status JSON on stderr is best effort; host log records delivery failures. stdin is /dev/null. No compiler is installed by this command; inspect only reads a Mach-O header (never executes it) and returns nonzero when the artifact is invalid.\n"; nb_output(NBP_STDERR,help.UTF8String,strlen(help.UTF8String),fds); return 0;
        }
        if(argc==4 && strcmp(argv[1],"inspect")==0 && strcmp(argv[2],"--artifact")==0) {
            /* Read-only artifact gate: exit status of a previous step is not
             * evidence that it produced a correct Mach-O. */
            NSString *guest=[NSString stringWithUTF8String:argv[3]];
            if(!guest || ![guest hasPrefix:@"/"]) return nb_error(fds,@"Artifact path must be absolute and is a GUEST path");
            NSString *host=noff_resolve_host_path(guest);
            if(!host) return nb_error(fds,@"Artifact path cannot be resolved");
            NSDictionary *info=NBMachOInspect(host);
            nb_json(fds,NBP_STDOUT,info);
            return [info[@"valid"] boolValue] ? 0 : 1;
        }
        if(argc==2 && strcmp(argv[1],"doctor")==0) {
            /* Two separate answers, deliberately not merged:
             *   toolchain  = what is staged in this build (stat/access only)
             *   verified   = what this installation actually ran (below)        */
            NSDictionary *toolchain = NBToolchainDescribe(nil);
            nb_json(fds,NBP_STDOUT,@{@"backend":@"ios-native",@"service_registered":@YES,@"toolchain":toolchain,@"native_spawn_verified":@NO,@"compiler_installed":[NSNull null],@"compiler_scan":@"not_scanned",@"note":@"toolchain.ready only means the expected files exist and are executable. Run `minis-native-build doctor --probe` to actually execute them, and run the device probe suite before claiming a build works here. Linux-cross remains independent."}); return 0;
        }
        if(argc==3 && strcmp(argv[1],"doctor")==0 && strcmp(argv[2],"--probe")==0) {
            /* Live check: really spawn each tool once. Paths existing is not proof
             * that this installation may execute bundled Mach-O under AMFI. */
            NSMutableDictionary *live=[NSMutableDictionary dictionary];
            NSDictionary *tools=@{@"clang":@"bin/clang",@"ld":@"bin/ld",@"ldid":@"bin/ldid"};
            NSString *root=NBToolchainRoot();
            for(NSString *name in tools){
                NSString *exe=[root stringByAppendingPathComponent:tools[name]];
                if(access(exe.fileSystemRepresentation,X_OK)!=0){live[name]=@{@"ran":@NO,@"reason":@"missing"};continue;}
                const char *av[]={exe.fileSystemRepresentation,"--version",NULL};
                NBPResult r=NBPRun(&(NBPOptions){.executable=exe.fileSystemRepresentation,.argv=av,.timeout_ms=15000,.terminate_grace_ms=250,.output=NULL});
                live[name]=@{@"ran":@(r.status==NBP_EXITED),@"exit":@(r.exit_code),@"status":@((int)r.status),@"errno":@(r.error_number)};
            }
            BOOL all=YES; for(NSString *k in live) all = all && [live[k][@"ran"] boolValue];
            nb_json(fds,NBP_STDOUT,@{@"backend":@"ios-native",@"probe":live,@"all_tools_ran":@(all),@"toolchain":NBToolchainDescribe(nil),@"note":@"--version proves launch only; compile/link/sign still need the source→IPA smoke run."}); return 0;
        }
        if(argc!=4 || strcmp(argv[1],"run") || strcmp(argv[2],"--request"))return nb_error(fds,@"Use run --request /absolute/guest/request.json");
        NSString *guest=[NSString stringWithUTF8String:argv[3]];
        if(!guest || ![guest hasPrefix:@"/"])return nb_error(fds,@"Request path must be absolute");
        NSString *host=noff_resolve_host_path(guest);
        NSData *data=host ? [NSData dataWithContentsOfFile:host options:NSDataReadingMappedIfSafe error:nil] : nil;
        if(!data || data.length>1024*1024)return nb_error(fds,@"Request unreadable or larger than 1MB");
        id value=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if(![value isKindOfClass:NSDictionary.class])return nb_error(fds,@"Request must be a JSON object");
        NSDictionary *request=value; NSString *exe=request[@"executable"]; id args=request[@"arguments"] ?: @[]; id cwd=request[@"cwd"];
        if(!nb_string(exe) || ![exe hasPrefix:@"/"] || ![args isKindOfClass:NSArray.class] || [args count]>1024)return nb_error(fds,@"Invalid executable/arguments");
        if(cwd && (!nb_string(cwd) || ![cwd hasPrefix:@"/"]))return nb_error(fds,@"cwd must be an absolute host path");
        for(id arg in args)if(!nb_string(arg))return nb_error(fds,@"Arguments must be strings without NUL bytes");
        id timeout=request[@"timeout_ms"] ?: @120000;
        double ms=[timeout isKindOfClass:NSNumber.class] ? [timeout doubleValue] : NAN;
        if(!isfinite(ms) || ms<1 || ms>3600000)return nb_error(fds,@"timeout_ms must be 1..3600000");
        NSMutableArray<NSString *> *all=[NSMutableArray arrayWithObject:exe]; [all addObjectsFromArray:args];
        const char **cargs=calloc(all.count+1,sizeof(char *));
        if(!cargs)return nb_error(fds,@"Allocation failed");
        for(NSUInteger i=0;i<all.count;i++)cargs[i]=all[i].UTF8String;
        id cancelGuest=request[@"cancel_file"];
        if(cancelGuest && (!nb_string(cancelGuest) || ![cancelGuest hasPrefix:@"/"])) { free(cargs); return nb_error(fds,@"cancel_file must be an absolute guest path"); }
        /* [T-native-build] Optional artifact gate. A step that exits 0 but wrote
         * the wrong thing is a failed step: `expect` names what must be true of
         * the produced Mach-O, checked after the process exits. */
        id expect=request[@"expect"];
        if (expect && ![expect isKindOfClass:NSDictionary.class]) { free(cargs); return nb_error(fds,@"expect must be an object"); }
        id expectPath = expect ? expect[@"artifact"] : nil;
        if (expectPath && (!nb_string(expectPath) || ![expectPath hasPrefix:@"/"])) { free(cargs); return nb_error(fds,@"expect.artifact must be an absolute GUEST path"); }
        if (expect && !expectPath) { free(cargs); return nb_error(fds,@"expect requires an artifact path"); }
        NSString *cancelHost=cancelGuest ? noff_resolve_host_path(cancelGuest) : nil;
        if (cancelGuest && !cancelHost) { free(cargs); return nb_error(fds,@"cancel_file cannot be resolved"); }
        fds->cancel_path=cancelHost.fileSystemRepresentation;
        uint64_t start=nb_now();
        if (start==UINT64_MAX) { free(cargs); return nb_error(fds,@"Monotonic clock unavailable"); }
        fds->deadline_ms=start+(uint64_t)ms;
        NBPOptions options={.executable=exe.fileSystemRepresentation,.argv=cargs,.cwd=cwd ? [cwd fileSystemRepresentation] : NULL,.timeout_ms=(uint64_t)ms,.terminate_grace_ms=250,.output=nb_output,.cancelled=nb_cancelled,.context=fds};
        NBPResult result=NBPRun(&options); free(cargs);
        /* Artifact gate: only meaningful when the process itself succeeded. */
        NSDictionary *artifact=nil; BOOL artifactOK=YES; NSString *artifactError=nil;
        if (expect && result.status==NBP_EXITED && result.exit_code==0) {
            NSString *hostPath=noff_resolve_host_path(expectPath);
            if (!hostPath) { artifactOK=NO; artifactError=@"expect.artifact cannot be resolved"; }
            else {
                artifact=NBMachOInspect(hostPath);
                if (![artifact[@"valid"] boolValue]) { artifactOK=NO; artifactError=artifact[@"error"]; }
                NSDictionary *want=@{@"arch":@"arch",@"filetype":@"filetype",@"has_main":@"has_main",
                                     @"has_code_signature":@"has_code_signature",@"pie":@"pie"};
                for (NSString *k in want) {
                    id v=expect[k];
                    if (!v) continue;
                    if (![artifact[k] isEqual:v]) {
                        artifactOK=NO;
                        artifactError=[NSString stringWithFormat:@"%@ expected %@, got %@",k,v,artifact[k] ?: @"<missing>"];
                        break;
                    }
                }
            }
        }
        /* Permit a bounded final report after timeout/cancel. A stream already
         * saturated or broken stays disabled; NSLog is the fallback record. */
        fds->cancel_path=NULL; fds->deadline_ms=0;
        for (int i=0;i<2;i++)
            if (fds->channels[i].error==ECANCELED || fds->channels[i].error==ETIMEDOUT)
                fds->channels[i].disabled=false;
        struct NBChannel out=fds->channels[0], err=fds->channels[1];
        NSDictionary *report=@{@"native_build_result":@YES,@"status":@(result.status),@"errno":@(result.error_number),@"exit_code":@(result.exit_code),@"signal":@(result.termination_signal),
            @"output_truncated":@(out.dropped>0 || err.dropped>0),
            @"stdout_written":@(out.written),@"stdout_dropped":@(out.dropped),@"stdout_errno":@(out.error),
            @"stderr_written":@(err.written),@"stderr_dropped":@(err.dropped),@"stderr_errno":@(err.error)};
        NSMutableDictionary *final=[report mutableCopy];
        if (expect) {
            final[@"artifact_checked"]=@YES;
            final[@"artifact_ok"]=@(artifactOK);
            if (artifactError) final[@"artifact_error"]=artifactError;
            if (artifact) final[@"artifact"]=artifact;
        }
        nb_json(fds,NBP_STDERR,final);
        NSLog(@"NativeBuild result %@; report delivery stderr errno=%d dropped=%llu",final,fds->channels[1].error,(unsigned long long)fds->channels[1].dropped);
        if (expect && !artifactOK) return 126;   /* ran fine, produced the wrong artifact */
        if(result.status==NBP_EXITED)return result.exit_code;
        return result.status==NBP_TIMED_OUT ? 124 : result.status==NBP_CANCELLED ? 130 : 125;
    }
}
static int nb_handler(int argc,char **argv,int stdin_fd,int stdout_fd,int stderr_fd) {
    struct NBOutput fds={0};
    nb_channel_init(&fds.channels[0],stdout_fd);
    nb_channel_init(&fds.channels[1],stderr_fd);
    int status=nb_handle(argc,argv,stdin_fd,&fds);
    for (int i=0;i<2;i++) {
        nb_channel_close(&fds.channels[i]);
        if (fds.channels[i].error || fds.channels[i].dropped)
            NSLog(@"NativeBuild output stream=%d errno=%d written=%llu dropped=%llu",i+1,
                  fds.channels[i].error,(unsigned long long)fds.channels[i].written,
                  (unsigned long long)fds.channels[i].dropped);
    }
    return status;
}
void native_build_offload_register(void) {
    int err=native_offload_add_handler("minis-native-build",nb_handler);
    if(!err)noff_ensure_guest_stub("/usr/local/bin/minis-native-build");
    else NSLog(@"NativeBuild: registration failed (%d)",err);
}
