#ifndef _GNU_SOURCE
#define _GNU_SOURCE 1
#endif
#include "NativeBuildProcess.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <dlfcn.h>
#endif

#if defined(__APPLE__)
/* csops is libSystem SPI (no public header); it is resolved at run time so the
 * build needs no private header and a missing symbol degrades to valid = false
 * instead of a link error. The CS_OPS_* selectors and status bits are spelled
 * out below. */
#include <sys/stat.h>
#include <sandbox.h>
#ifndef SANDBOX_FILTER_NONE
#define SANDBOX_FILTER_NONE 0 /* private sandbox.h spelling */
#endif
#endif

extern char **environ;

/* CS_OPS_* selectors and status bits from Apple's cs_blobs.h. Spelled here so the
 * file builds against the public SDK and on Linux (where they are inert). */
#ifndef CS_OPS_STATUS
#define CS_OPS_STATUS 0
#endif
#ifndef CS_OPS_ENTITLEMENTS_BLOB
#define CS_OPS_ENTITLEMENTS_BLOB 7
#endif
#ifndef CS_VALID
#define CS_VALID 0x00000001u
#endif
#ifndef CS_ADHOC
#define CS_ADHOC 0x00000002u
#endif
#ifndef CS_HARD
#define CS_HARD 0x00000100u
#endif
#ifndef CS_RESTRICT
#define CS_RESTRICT 0x00000800u
#endif
#ifndef CS_ENFORCEMENT
#define CS_ENFORCEMENT 0x00001000u
#endif
#ifndef CS_REQUIRE_LV
#define CS_REQUIRE_LV 0x00002000u
#endif
#ifndef CS_INSTALLER
#define CS_INSTALLER 0x00020000u
#endif
#ifndef CS_PLATFORM_BINARY
#define CS_PLATFORM_BINARY 0x04000000u
#endif
#ifndef CS_FORCED_LV
#define CS_FORCED_LV 0x08000000u
#endif

typedef struct {
    const uint32_t bit;
    const char *name;
} NBPFlagName;

static const NBPFlagName nbp_flag_names[] = {
    {CS_VALID, "CS_VALID"},
    {CS_ADHOC, "CS_ADHOC"},
    {CS_HARD, "CS_HARD"},
    {CS_RESTRICT, "CS_RESTRICT"},
    {CS_ENFORCEMENT, "CS_ENFORCEMENT"},
    {CS_REQUIRE_LV, "CS_REQUIRE_LV"},
    {CS_INSTALLER, "CS_INSTALLER"},
    {CS_PLATFORM_BINARY, "CS_PLATFORM_BINARY"},
    {CS_FORCED_LV, "CS_FORCED_LV"},
};

size_t NBPSpawnFlagsDescribe(uint32_t flags, char *out, size_t capacity)
{
    size_t needed = 0;
    if (capacity) out[0] = '\0';
    for (size_t i = 0; i < sizeof(nbp_flag_names) / sizeof(nbp_flag_names[0]); ++i) {
        if (!(flags & nbp_flag_names[i].bit)) continue;
        size_t length = strlen(nbp_flag_names[i].name);
        if (needed) {
            if (out && needed + 1 < capacity) out[needed] = ',';
            needed += 1;
        }
        if (out && needed + length < capacity)
            memcpy(out + needed, nbp_flag_names[i].name, length);
        needed += length;
    }
    if (out && capacity && needed < capacity) out[needed] = '\0';
    else if (out && capacity) out[capacity - 1] = '\0';
    return needed;
}

bool NBPSpawnFlagsDenyLaunchPolicy(uint32_t flags)
{
    /* proc_launch_check(): CS_HARD denies outright; CS_ENFORCEMENT/CS_REQUIRE_LV
     * deny anything not platform; a missing CS_VALID means the kernel treats the
     * signature as not having been validated by amfi. CS_FORCED_LV is the flag
     * the kernel stamps on a process it holds to the platform trust cache. */
    if (!(flags & CS_VALID)) return true;
    if (flags & (CS_HARD | CS_ENFORCEMENT | CS_REQUIRE_LV | CS_FORCED_LV)) return true;
    return false;
}

int NBPSpawnProbeSelf(const char *executable, NBPSpawnProbe *probe)
{
    (void)executable;
    if (!probe) return EINVAL;
    memset(probe, 0, sizeof(*probe));
    probe->euid = geteuid();
    probe->egid = getegid();
    probe->pid = getpid();
    probe->parent_pid = getppid();
    probe->entitlement_blob_size = -1;
#if defined(__APPLE__)
    typedef int (*CSOps)(pid_t, unsigned, void *, size_t);
    void *symbol = dlsym(RTLD_DEFAULT, "csops");
    if (!symbol) { probe->error_number = ENOSYS; return 0; }
    CSOps csops_fn = NULL;
    _Static_assert(sizeof(csops_fn) == sizeof(symbol), "function pointer size");
    memcpy(&csops_fn, &symbol, sizeof(csops_fn));
    uint32_t flags = 0;
    if (csops_fn(probe->pid, CS_OPS_STATUS, &flags, sizeof(flags)) == 0) {
        probe->valid = true;
        probe->cs_flags = flags;
    } else {
        probe->error_number = errno;
    }
    /* Entitlements blob: read a 4-byte superblock header only (magic + length).
     * The dictionary itself is never copied out here. */
    {
        struct { uint32_t magic; uint32_t length; } header = {0, 0};
        if (csops_fn(probe->pid, CS_OPS_ENTITLEMENTS_BLOB, &header,
                     sizeof(header)) == 0 && header.magic == 0xfade7171) {
            probe->entitlements_present = true;
            probe->entitlement_blob_size = (int)header.length;
        }
    }
    /* proc_pidpath lives in libproc; the SDK keeps libproc.h out of usr/include,
     * so it is resolved the same way as csops. */
    typedef int (*ProcPIDPath)(int, void *, uint32_t);
    void *path_symbol = dlsym(RTLD_DEFAULT, "proc_pidpath");
    int length = 0;
    if (path_symbol) {
        ProcPIDPath path_fn = NULL;
        memcpy(&path_fn, &path_symbol, sizeof(path_fn));
        length = path_fn(probe->parent_pid, probe->parent_path,
                         (uint32_t)sizeof(probe->parent_path));
    }
    if (length > 0) {
        probe->parent_path_valid = true;
        const char *slash = strrchr(probe->parent_path, '/');
        if (slash && slash[1]) memmove(probe->parent_path, slash + 1, strlen(slash + 1) + 1);
    } else {
        probe->parent_path[0] = '\0';
    }
    /* Seatbelt asks the same question access(X_OK) does; the kernel asks amfi.
     * An allow here with EPERM from the kernel is a launch-policy denial. */
    probe->sandbox_checked = false;
    if (executable) {
        typedef int (*SandboxCheck)(pid_t, const char *, int, ...);
        void *sandbox_symbol = dlsym(RTLD_DEFAULT, "sandbox_check");
        if (sandbox_symbol) {
            SandboxCheck check_fn = NULL;
            memcpy(&check_fn, &sandbox_symbol, sizeof(check_fn));
            probe->sandbox_checked = true;
            probe->sandbox_allows_exec =
                check_fn(probe->pid, "file-write-execute",
                         SANDBOX_FILTER_NONE, executable) == 0;
        }
    }
#endif
    return 0;
}

static int add_chdir(posix_spawn_file_actions_t *actions, const char *cwd)
{
#if defined(__APPLE__)
    /* The iOS 16.5 SDK marks the declaration unavailable. Resolve the actual
     * Apple extension without bypassing availability diagnostics globally. */
    typedef int (*AddChdir)(posix_spawn_file_actions_t *, const char *);
    AddChdir function = NULL;
    void *symbol = dlsym(RTLD_DEFAULT, "posix_spawn_file_actions_addchdir_np");
    _Static_assert(sizeof(function) == sizeof(symbol), "function pointer size");
    memcpy(&function, &symbol, sizeof(function));
    return function ? function(actions, cwd) : ENOTSUP;
#else
    return posix_spawn_file_actions_addchdir_np(actions, cwd);
#endif
}

static void close_fd(int *fd)
{
    if (*fd >= 0) {
        /* Do not retry close(EINTR): the descriptor may already be released. */
        close(*fd);
        *fd = -1;
    }
}

static int make_pipe(int fds[2])
{
#if defined(__linux__)
    if (pipe2(fds, O_CLOEXEC) < 0) return errno;
#else
    if (pipe(fds) < 0) return errno;
#endif
    for (int i = 0; i < 2; ++i) {
        /* Keep all pipe descriptors away from stdin/stdout/stderr, even if
         * the caller entered with one of those closed. */
        if (fds[i] < 3) {
            int replacement = fcntl(fds[i], F_DUPFD_CLOEXEC, 3);
            if (replacement < 0) goto fail;
            close(fds[i]);
            fds[i] = replacement;
        }
        if (fcntl(fds[i], F_SETFD, FD_CLOEXEC) < 0) goto fail;
    }
    /* Only the reader is nonblocking; the child gets blocking writes. */
    int flags = fcntl(fds[0], F_GETFL);
    if (flags < 0 || fcntl(fds[0], F_SETFL, flags | O_NONBLOCK) < 0)
        goto fail;
    return 0;
fail: {
        int error = errno;
        close_fd(&fds[0]);
        close_fd(&fds[1]);
        return error;
    }
}

static int now_ms(uint64_t *value)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) < 0) return errno;
    *value = (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
    return 0;
}

static void signal_group(pid_t pid, int sig, bool child_alive)
{
    (void)kill(-pid, sig);
    /* Also cover a direct child that moved groups while descendants retained
     * the original group. Never address a direct PID after it was reaped. */
    if (child_alive) (void)kill(pid, sig);
}

static int reap(pid_t pid, int *status, int flags)
{
    pid_t value;
    do { value = waitpid(pid, status, flags); } while (value < 0 && errno == EINTR);
    return value < 0 ? -errno : (value == 0 ? 0 : 1);
}

NBPResult NBPRun(const NBPOptions *options)
{
    NBPResult result = {.status=NBP_SPAWN_ERROR, .exit_code=-1, .pid=-1,
                        .error_stage="validation"};
    int pipes[2][2] = { {-1, -1}, {-1, -1} };
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    bool actions_ready = false, attributes_ready = false;
    int error = 0;
    if (!options || !options->executable || options->executable[0] != '/' ||
        !options->argv || !options->argv[0]) {
        result.error_number = EINVAL;
        return result;
    }
#define CHECK(call) do { result.error_stage = #call; error = (call); if (error) goto setup_done; } while (0)
    CHECK(make_pipe(pipes[0]));
    CHECK(make_pipe(pipes[1]));
    CHECK(posix_spawn_file_actions_init(&actions));
    actions_ready = true;
    CHECK(posix_spawnattr_init(&attributes));
    attributes_ready = true;
    CHECK(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO,
                                         "/dev/null", O_RDONLY, 0));
    for (int i = 0; i < 2; ++i) {
        CHECK(posix_spawn_file_actions_addclose(&actions, pipes[i][0]));
        CHECK(posix_spawn_file_actions_adddup2(&actions, pipes[i][1], i + 1));
        CHECK(posix_spawn_file_actions_addclose(&actions, pipes[i][1]));
    }
    if (options->cwd)
        CHECK(add_chdir(&actions, options->cwd));
    sigset_t empty, defaults;
    sigemptyset(&empty);
    sigemptyset(&defaults);
    sigaddset(&defaults, SIGTERM);
    sigaddset(&defaults, SIGINT);
    sigaddset(&defaults, SIGHUP);
    sigaddset(&defaults, SIGQUIT);
    sigaddset(&defaults, SIGPIPE);
    CHECK(posix_spawnattr_setsigmask(&attributes, &empty));
    CHECK(posix_spawnattr_setsigdefault(&attributes, &defaults));
    CHECK(posix_spawnattr_setpgroup(&attributes, 0));
    CHECK(posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP |
                                  POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF));
    result.spawn_attempted = true;
    result.error_stage = "posix_spawn";
    error = posix_spawn(&result.pid, options->executable, &actions, &attributes,
                       (char *const *)options->argv,
                       options->envp ? (char *const *)options->envp : environ);
    if (!error) result.error_stage = NULL;
setup_done:
    if (attributes_ready) posix_spawnattr_destroy(&attributes);
    if (actions_ready) posix_spawn_file_actions_destroy(&actions);
    for (int i = 0; i < 2; ++i) close_fd(&pipes[i][1]);
    if (error) {
        for (int i = 0; i < 2; ++i) close_fd(&pipes[i][0]);
        result.pid = -1;
        result.error_number = error;
        return result;
    }
#undef CHECK

    uint64_t start = 0, now = 0, stop_at = 0, kill_at = 0;
    bool stopped = false, killed = false, reaped = false;
    int child_status = 0;
    result.status = NBP_EXITED;
    error = now_ms(&start);
    if (error) goto runtime_failure;
    for (;;) {
        if (!reaped) {
            int state = reap(result.pid, &child_status, WNOHANG);
            if (state < 0) { error = -state; goto runtime_failure; }
            reaped = state == 1;
        }
        bool drained = pipes[0][0] < 0 && pipes[1][0] < 0;
        if (reaped && drained && (!stopped || killed)) break;
        error = now_ms(&now);
        if (error) goto runtime_failure;
        if (!stopped) {
            if (options->cancelled && options->cancelled(options->context)) {
                result.status = NBP_CANCELLED;
                stopped = true;
            } else if (options->timeout_ms && now - start >= options->timeout_ms) {
                result.status = NBP_TIMED_OUT;
                stopped = true;
            }
            if (stopped) {
                stop_at = now;
                signal_group(result.pid, SIGTERM, !reaped);
            }
        }
        if (stopped && !killed && now - stop_at >= options->terminate_grace_ms) {
            signal_group(result.pid, SIGKILL, !reaped);
            killed = true;
            kill_at = now;
        }
        if (killed && now - kill_at >= 200) {
            for (int i = 0; i < 2; ++i) close_fd(&pipes[i][0]);
            if (reaped) break;
        }
        struct pollfd watched[2] = {
            {pipes[0][0], POLLIN, 0}, {pipes[1][0], POLLIN, 0}
        };
        int delay = 25;
        uint64_t remaining;
        if (!stopped && options->timeout_ms) {
            remaining = options->timeout_ms - (now - start);
            if (remaining < (uint64_t)delay) delay = (int)remaining;
        } else if (stopped && !killed) {
            remaining = options->terminate_grace_ms - (now - stop_at);
            if (remaining < (uint64_t)delay) delay = (int)remaining;
        }
        int ready = poll(watched, 2, delay);
        if (ready < 0) {
            if (errno == EINTR) continue;
            error = errno;
            goto runtime_failure;
        }
        for (int i = 0; i < 2; ++i) {
            if (watched[i].revents & POLLNVAL) {
                error = EBADF;
                goto runtime_failure;
            }
            if (!(watched[i].revents & (POLLIN | POLLHUP | POLLERR))) continue;
            char buffer[16384];
            ssize_t length = read(pipes[i][0], buffer, sizeof(buffer));
            if (length > 0) {
                if (options->output)
                    options->output((NBPStream)(i + 1), buffer, (size_t)length,
                                    options->context);
            } else if (length == 0) {
                close_fd(&pipes[i][0]);
            } else if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
                error = errno;
                goto runtime_failure;
            }
        }
    }
    goto finish;
runtime_failure:
    result.error_stage = "runtime";
    if (!stopped) result.status = NBP_SYSTEM_ERROR;
    result.error_number = error;
    signal_group(result.pid, SIGKILL, !reaped);
finish:
    for (int i = 0; i < 2; ++i) close_fd(&pipes[i][0]);
    if (!reaped) {
        int state = reap(result.pid, &child_status, 0);
        if (state < 0) {
            result.error_stage = "waitpid";
            if (!stopped) result.status = NBP_SYSTEM_ERROR;
            result.error_number = -state;
        } else reaped = true;
    }
    if (reaped) {
        if (WIFEXITED(child_status)) result.exit_code = WEXITSTATUS(child_status);
        if (WIFSIGNALED(child_status)) {
            result.termination_signal = WTERMSIG(child_status);
            if (result.status == NBP_EXITED) result.status = NBP_SIGNALED;
        }
    }
    return result;
}
