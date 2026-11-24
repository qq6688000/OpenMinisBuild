#import "SPLog.h"
#import <dlfcn.h>

// 日志路径：多候选，挑第一个真的能写进去的。
// RootHide 下 /var/mobile/Library 经常不可写，rootless 在 /var/jb 下，
// 所以三个都试，最后还有 /tmp 兜底 —— 只要 dylib 被加载，就一定有日志。

static NSString *gPath = nil;
static dispatch_once_t gOnce;

static NSArray<NSString *> *SPCandidates(void) {
    NSMutableArray *a = [NSMutableArray array];
    // RootHide 的 jbroot：符号在 loader 里，拿到了就拼真路径
    void *sym = dlsym(RTLD_DEFAULT, "jbroot");
    if (sym) {
        NSString *(*jbroot)(NSString *) = (NSString *(*)(NSString *))sym;
        @try {
            NSString *p = jbroot(@"/var/mobile/Library/Logs");
            if (p.length) [a addObject:[p stringByAppendingPathComponent:@"SplitPane.log"]];
        } @catch (__unused NSException *e) {}
    }
    [a addObject:@"/var/mobile/Library/Logs/SplitPane.log"];
    [a addObject:@"/var/jb/var/mobile/Library/Logs/SplitPane.log"];
    [a addObject:@"/tmp/SplitPane.log"];
    [a addObject:@"/var/tmp/SplitPane.log"];
    return a;
}

static void SPResolvePath(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *cand in SPCandidates()) {
        NSString *dir = [cand stringByDeletingLastPathComponent];
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        if (![fm isWritableFileAtPath:dir] && ![fm fileExistsAtPath:dir]) continue;
        if ([fm createFileAtPath:cand contents:[NSData data] attributes:nil] ||
            [fm isWritableFileAtPath:cand]) {
            gPath = cand;
            return;
        }
    }
    gPath = @"/tmp/SplitPane.log";
}

NSString *SPLogPath(void) {
    dispatch_once(&gOnce, ^{ SPResolvePath(); });
    return gPath ?: @"/tmp/SplitPane.log";
}

void SPLogClear(void) {
    [[NSFileManager defaultManager] removeItemAtPath:SPLogPath() error:NULL];
}

void SPLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[SplitPane] %@", msg);

    static NSDateFormatter *df;
    static NSMutableString *buf;
    static double lastAt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        df = [NSDateFormatter new];
        df.dateFormat = @"HH:mm:ss.SSS";
        buf = [NSMutableString new];
    });
    @synchronized (buf) {
        [buf appendFormat:@"%@ %@\n", [df stringFromDate:[NSDate date]], msg];
        double now = CFAbsoluteTimeGetCurrent();
        if (now - lastAt < 0.4) return;
        lastAt = now;
        // 追加写，绝不能把上一次的内容冲掉
        NSString *path = SPLogPath();
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) { [buf writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]; }
        else {
            @try {
                [fh seekToEndOfFile];
                [fh writeData:[buf dataUsingEncoding:NSUTF8StringEncoding]];
                [fh closeFile];
            } @catch (__unused NSException *e) {}
        }
        [buf setString:@""];
    }
}