#ifndef NATIVE_BUILD_PROCESS_H
#define NATIVE_BUILD_PROCESS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    NBP_EXITED,
    NBP_SIGNALED,
    NBP_SPAWN_ERROR, /* validation, pipe, spawn actions, or posix_spawn */
    NBP_TIMED_OUT,
    NBP_CANCELLED,
    NBP_SYSTEM_ERROR /* poll/read/clock/waitpid failure after spawning */
} NBPStatus;

typedef enum { NBP_STDOUT = 1, NBP_STDERR = 2 } NBPStream;

typedef void (*NBPOutputCallback)(NBPStream stream, const void *bytes,
                                  size_t length, void *context);
typedef bool (*NBPCancelCallback)(void *context);

typedef struct {
    const char *executable;       /* required absolute path; no PATH search */
    const char *const *argv;      /* required, NULL terminated, argv[0] required */
    const char *const *envp;      /* NULL inherits environ; {NULL} is empty */
    const char *cwd;              /* NULL inherits cwd; never changes parent cwd */
    uint64_t timeout_ms;          /* 0 disables timeout; starts after spawn */
    unsigned int terminate_grace_ms; /* TERM -> KILL delay; 0 means immediate */
    NBPOutputCallback output;     /* optional; NULL still drains both pipes */
    NBPCancelCallback cancelled;  /* optional; true requests cancellation */
    void *context;                /* shared by both callbacks */
} NBPOptions;

typedef struct {
    NBPStatus status;
    int error_number;             /* errno / posix_spawn error, otherwise 0 */
    int exit_code;                /* -1 unless child exited normally */
    int termination_signal;       /* 0 unless child died from a signal */
    pid_t pid;                    /* -1 unless spawn succeeded */
    const char *error_stage;       /* static string; NULL on success */
    bool spawn_attempted;          /* reached the actual posix_spawn call */
} NBPResult;

/* Synchronous, reentrant, no global signal handlers or cwd changes.
 * Callbacks run on the calling thread, are serialized, and must return promptly.
 * Output is binary, not NUL terminated; its storage lasts only during callback.
 * Each poll cycle checks cancellation (maximum poll sleep 25 ms); a cancellation
 * observed in the same cycle as timeout wins. Callbacks are not invoked before
 * spawn succeeds. stdin is /dev/null; unrelated non-CLOEXEC descriptors remain
 * inherited. Output callbacks preserve order within each stream only.
 * Child gets its own process group and an empty signal mask, with standard
 * termination signals reset to default. Timeout/cancel sends group TERM then
 * KILL, reaps the direct child, and drains output. After KILL, draining is bounded
 * to 200 ms in case an escaped descendant retains a pipe; late output may be lost.
 * timeout_ms covers child execution AND pipe draining, excluding spawn time.
 * Blocking callbacks delay timeout/cancellation observation.
 * A timeout/cancel result also records the child's eventual exit/signal when known.
 * Do not concurrently reap this child or mutate environ during inheritance.
 * Apple uses pipe + fcntl(CLOEXEC): concurrent external fork/exec callers must
 * serialize that short setup window. Linux uses atomic pipe2(O_CLOEXEC).
 * Apple resolves addchdir_np with dlsym because iOS SDKs mark it unavailable;
 * requesting cwd returns NBP_SPAWN_ERROR / ENOTSUP if the symbol is absent.
 */
NBPResult NBPRun(const NBPOptions *options);

/* Read-only launch-policy fingerprint of the calling process.
 *
 * The kernel caches the result of proc_launch_check() in P_LFLAG_NOEXEC for the
 * life of the process, so the first failed spawn poisons every later check. Call
 * this before the first spawn: while no attempt has failed it reports the
 * process's code-signing flags (csops CS_OPS_STATUS), its security-token
 * identity, whether the sandbox would deny exec of a path, and whether access()
 * and stat() agree with that. It never spawns, never mutates state, and makes no
 * trust verdict: it only separates "the installation's launch policy denies this
 * process" from "Seatbelt denies this path" from "AMFI denies this file".
 *
 * On non-Apple platforms every field is zero except valid = false.
 */
typedef struct {
    bool valid;               /* csops(CS_OPS_STATUS) succeeded */
    int error_number;         /* errno from csops when !valid */
    uint32_t cs_flags;        /* raw current-process status flags */
    bool audit_token_valid;   /* csops_audittoken(CS_OPS_STATUS) succeeded */
    uid_t euid;
    gid_t egid;
    pid_t pid;
    pid_t parent_pid;
    bool parent_path_valid;   /* proc_pidpath(parent) returned a path */
    char parent_path[256];    /* basename of the parent executable */
    bool entitlements_present;/* CS_OPS_ENTITLEMENTS_BLOB returned a blob */
    int entitlement_blob_size;
    bool sandbox_checked;     /* sandbox_check() was available and asked */
    bool sandbox_allows_exec; /* Seatbelt allows exec of `executable` */
} NBPSpawnProbe;

/* Fills *probe for the calling process. `executable` (may be NULL) is the path
 * whose exec the caller is about to attempt; it is only read with access() and
 * stat(), never opened for execution. Returns 0, or an errno for bad arguments. */
int NBPSpawnProbeSelf(const char *executable, NBPSpawnProbe *probe);

/* Shell-free decode of cs_flags into the names that matter for launch policy:
 * "CS_VALID,CS_ADHOC" or "CS_HARD,CS_PLATFORM_BINARY". Writes at most
 * capacity bytes, always NUL terminated. Returns the number of bytes needed. */
size_t NBPSpawnFlagsDescribe(uint32_t flags, char *out, size_t capacity);

/* True when the flags describe a process the kernel will refuse to exec from:
 * CS_HARD, CS_ENFORCEMENT, CS_REQUIRE_LV or CS_FORCED_LV set, or CS_VALID
 * absent (amfi treated as out of its way for nobody). */
bool NBPSpawnFlagsDenyLaunchPolicy(uint32_t flags);

#ifdef __cplusplus
}
#endif
#endif
