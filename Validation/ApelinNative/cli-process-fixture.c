#include "NativeBuildProcess.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

struct Context { char text[512]; size_t size; unsigned ticks; };
static void output(NBPStream stream, const void *data, size_t count, void *raw) {
    (void)stream;
    struct Context *ctx = raw;
    size_t available = sizeof(ctx->text) - ctx->size - 1;
    if (count > available) count = available;
    memcpy(ctx->text + ctx->size, data, count); ctx->size += count;
}
static bool cancel(void *raw) { return ++((struct Context *)raw)->ticks > 3; }
int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--child-wait")) { for (;;) pause(); }
    if (argc == 3 && !strcmp(argv[1], "--child-argv")) { puts(argv[2]); return 0; }
    assert(argc == 1 && argv[0][0] == '/');
    struct Context ctx = {0};
    const char *args[] = {argv[0], "--child-argv", "$(touch /tmp/minis-injection); space ' quote", NULL};
    NBPOptions options = {.executable=argv[0], .argv=args, .timeout_ms=1000,
        .terminate_grace_ms=25, .output=output, .context=&ctx};
    NBPResult r = NBPRun(&options);
    assert(r.status == NBP_EXITED && r.exit_code == 0 && r.spawn_attempted);
    assert(!strcmp(ctx.text, "$(touch /tmp/minis-injection); space ' quote\n"));
    const char *waiting[] = {argv[0], "--child-wait", NULL};
    options.argv = waiting; options.timeout_ms = 75; ctx = (struct Context){0};
    r = NBPRun(&options); assert(r.status == NBP_TIMED_OUT && r.pid > 0);
    options.timeout_ms = 2000; options.cancelled = cancel; ctx = (struct Context){0};
    r = NBPRun(&options); assert(r.status == NBP_CANCELLED && r.pid > 0);
    options.executable = "/does/not/exist/minis-clang"; options.cancelled = NULL;
    r = NBPRun(&options); assert(r.status == NBP_SPAWN_ERROR && r.error_number != 0);
    puts("PASS: actual NBPRun literal argv/output, timeout, cancellation and spawn failure");
}
