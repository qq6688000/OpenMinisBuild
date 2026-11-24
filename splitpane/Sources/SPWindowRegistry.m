#import "SPWindowRegistry.h"
#import "SPLog.h"

// ⚠️ 必须强引用登记。
// 之前用弱引用表：一旦外部强引用断开，对象被回收，但窗口仍挂在屏幕上，
// 而 killAll 只看到 0 个 —— 日志实证 `window killAll: 0` 却还有窗口没关。
static NSMutableArray *gWindows(void) {
    static NSMutableArray *t; static dispatch_once_t once;
    dispatch_once(&once, ^{ t = [NSMutableArray array]; });
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
    if (![gWindows() containsObject:w]) [gWindows() addObject:w];
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
    [gWindows() removeObjectIdenticalTo:w];
}

+ (void)killAll {
    NSUInteger n = [gWindows() count];
    for (UIWindow *w in [gWindows() copy]) [self releaseWindow:w];
    [gWindows() removeAllObjects];
    SPLog(@"window killAll: %lu", (unsigned long)n);
}

+ (NSUInteger)count { return [gWindows() count]; }

@end
