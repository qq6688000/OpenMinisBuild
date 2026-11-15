/* Fixture for NBPSpawnFlagsDescribe / NBPSpawnFlagsDenyLaunchPolicy and the
 * self-probe's non-Apple behaviour. Runs on Linux and on the device. */
#include "../src/ios/NativeOffloads/NativeBuildProcess.h"
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>

static int failures;
static void expect(int condition, const char *what) {
    if (!condition) { printf("FAIL %s\n", what); ++failures; }
}

int main(void) {
    char buffer[160];
    /* The shape the pinned archive's tools carry: CS_VALID | CS_ADHOC. */
    size_t needed = NBPSpawnFlagsDescribe(0x3u, buffer, sizeof(buffer));
    expect(strcmp(buffer, "CS_VALID,CS_ADHOC") == 0, "decodes 0x3");
    expect(needed == strlen("CS_VALID,CS_ADHOC"), "reports needed length");
    expect(!NBPSpawnFlagsDenyLaunchPolicy(0x3u), "0x3 (CS_VALID|CS_ADHOC) may launch");
    /* The shape that denies: a hard signature or an LV requirement. */
    expect(NBPSpawnFlagsDenyLaunchPolicy(0x101u), "CS_VALID|CS_HARD denies");
    expect(NBPSpawnFlagsDenyLaunchPolicy(0x3u | 0x2000u), "CS_REQUIRE_LV denies");
    expect(NBPSpawnFlagsDenyLaunchPolicy(0x3u | 0x1000u), "CS_ENFORCEMENT denies");
    expect(NBPSpawnFlagsDenyLaunchPolicy(0x2u), "no CS_VALID denies");
    expect(NBPSpawnFlagsDenyLaunchPolicy(0x08000003u), "CS_FORCED_LV is also a denial");
    /* Truncation never overruns and always terminates. */
    char tiny[6];
    NBPSpawnFlagsDescribe(0x3u, tiny, sizeof(tiny));
    expect(tiny[sizeof(tiny) - 1] == '\0', "truncated output terminated");
    memset(buffer, 'x', sizeof(buffer));
    NBPSpawnFlagsDescribe(0x04000003u, buffer, sizeof(buffer));
    expect(strstr(buffer, "CS_PLATFORM_BINARY") != NULL, "platform binary named");
    NBPResult none;
    memset(&none, 0, sizeof(none));
    NBPSpawnProbe probe;
    expect(NBPSpawnProbeSelf("/nonexistent", &probe) == 0, "probe accepts a path");
    expect(probe.pid == (pid_t)getpid(), "probe reports own pid");
    expect(NBPSpawnProbeSelf(NULL, NULL) == EINVAL, "probe rejects NULL");
    printf("nbp_spawn_probe: %s (%d failure(s))\n", failures ? "FAIL" : "PASS", failures);
    return failures ? 1 : 0;
}
