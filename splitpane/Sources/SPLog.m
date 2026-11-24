#import "SPLog.h"

NSString *SPLogPath(void) {
    return @"/var/mobile/Library/Logs/SplitPane.log";
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
        [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/mobile/Library/Logs"
                                  withIntermediateDirectories:YES attributes:nil error:NULL];
    });
    @synchronized (buf) {
        [buf appendFormat:@"%@ %@\n", [df stringFromDate:[NSDate date]], msg];
        double now = CFAbsoluteTimeGetCurrent();
        if (now - lastAt < 0.4) return;
        lastAt = now;
        [buf writeToFile:SPLogPath() atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        [buf setString:@""];
    }
}