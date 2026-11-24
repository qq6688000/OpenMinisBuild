#import "SPLog.h"
#import <dlfcn.h>

// ⚠️ 这里绝不能用 dlsym 调 RootHide 的 jbroot。
// roothide.h 里它有两个重载：
//     const char* jbroot(const char*);
//     NSString*   jbroot(NSString*) __attribute__((overloadable));
// dlsym(RTLD_DEFAULT,"jbroot") 拿到的是 C 版，按 NSString* 调用 = 把对象指针
// 当 C 字符串喂给 strlen → SIGSEGV → SpringBoard 进安全模式（0.2.1 就是这么炸的）。
// 现在只试固定路径，不碰任何 jailbreak 私有符号。

static NSString *gPath = nil;
static dispatch_once_t gOnce;

static NSArray<NSString *> *SPCandidates(void) {
    return @[
        @"/var/mobile/Library/Logs/SplitPane.log",
        @"/var/jb/var/mobile/Library/Logs/SplitPane.log",
        @"/tmp/SplitPane.log",
        @"/var/tmp/SplitPane.log",
    ];
}

static void SPResolvePath(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *cand in SPCandidates()) {
        NSString *dir = [cand stringByDeletingLastPathComponent];
        @try {
            [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
            if ([fm createFileAtPath:cand contents:[NSData data] attributes:nil] ||
                [fm isWritableFileAtPath:cand]) {
                gPath = cand;
                return;
            }
        } @catch (__unused NSException *e) {}
    }
    gPath = nil;   // 一个都写不进去：只走 NSLog，绝不因此崩
}

NSString *SPLogPath(void) {
    dispatch_once(&gOnce, ^{ SPResolvePath(); });
    return gPath;
}

void SPLogClear(void) {
    NSString *p = SPLogPath();
    if (p) [[NSFileManager defaultManager] removeItemAtPath:p error:NULL];
}

void SPLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[SplitPane] %@", msg);

    @try {
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
            NSString *path = SPLogPath();
            if (!path) { [buf setString:@""]; return; }
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
            if (!fh) {
                [buf writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            } else {
                [fh seekToEndOfFile];
                [fh writeData:[buf dataUsingEncoding:NSUTF8StringEncoding]];
                [fh closeFile];
            }
            [buf setString:@""];
        }
    } @catch (__unused NSException *e) {
        // 写日志本身失败绝不能让 SpringBoard 崩
    }
}