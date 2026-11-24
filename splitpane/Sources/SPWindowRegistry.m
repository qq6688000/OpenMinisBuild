#import "SPWindowRegistry.h"
#import "SPLog.h"

static NSHashTable *gWindows(void) {
    static NSHashTable *t; static dispatch_once_t once;
    dispatch_once(&once, ^{ t = [NSHashTable weakObjectsHashTable]; });
    return t;
}

@implementation SPWindowRegistry

+ (UIWindow *)makeWindowWithScene:(UIWindowScene *)scene level:(CGFloat)level keyable:(BOOL)keyable {
    UIWindow *w = [[UIWindow alloc] initWithWindowScene:scene];
    w.windowLevel = level;
    w.backgroundColor = UIColor.clearColor;
    if (!keyable) {
        // 不接输入焦点：避免抢键盘、抢状态栏
        Class passthrough = NSClassFromString(@"SPPassthroughWindow");
        (void)passthrough;
    }
    [gWindows() addObject:w];
    SPLog(@"window +1 (%@ level=%.0f total=%lu)", NSStringFromClass(w.class), level,
          (unsigned long)[gWindows() count]);
    return w;
}

+ (void)releaseWindow:(UIWindow *)w {
    if (!w) return;
    @try {
        w.hidden = YES;
        w.rootViewController = nil;
        w.windowScene = nil;
        [w removeFromSuperview];
        [w resignKeyWindow];
    } @catch (NSException *e) { SPLog(@"window release ex %@", e.reason); }
    [gWindows() removeObject:w];
}

+ (void)killAll {
    NSUInteger n = [gWindows() count];
    for (UIWindow *w in [gWindows() allObjects]) [self releaseWindow:w];
    SPLog(@"window killAll: %lu", (unsigned long)n);
}

+ (NSUInteger)count { return [gWindows() count]; }

@end
