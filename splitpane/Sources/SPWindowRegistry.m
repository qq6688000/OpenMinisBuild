#import "SPWindowRegistry.h"
#import "SPLog.h"

// 强引用登记：弱引用表会让对象被回收后窗口仍留在屏幕上，killAll 却只看到 0 个。
static NSMutableArray *SPWindows(void) {
    static NSMutableArray *a; static dispatch_once_t once;
    dispatch_once(&once, ^{ a = [NSMutableArray array]; });
    return a;
}

@implementation SPWindowRegistry

+ (UIWindow *)makeWindowWithScene:(UIWindowScene *)scene level:(CGFloat)level {
    UIWindow *w = [[UIWindow alloc] initWithWindowScene:scene];
    w.windowLevel = level;
    [SPWindows() addObject:w];
    SPLog(@"window +1 (level=%.0f total=%lu)", level, (unsigned long)[SPWindows() count]);
    return w;
}

+ (void)releaseWindow:(UIWindow *)w {
    if (!w) return;
    w.hidden = YES;
    w.rootViewController = nil;
    w.windowScene = nil;
    [w removeFromSuperview];
    [SPWindows() removeObjectIdenticalTo:w];
}

+ (void)killAll {
    NSUInteger n = [SPWindows() count];
    for (UIWindow *w in [SPWindows() copy]) [self releaseWindow:w];
    [SPWindows() removeAllObjects];
    SPLog(@"window killAll: %lu", (unsigned long)n);
}

+ (NSUInteger)count { return [SPWindows() count]; }

@end
