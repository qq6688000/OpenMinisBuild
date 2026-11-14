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

#ifdef __cplusplus
}
#endif
#endif
