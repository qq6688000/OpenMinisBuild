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
    return [self makeWindowWithScene:scene level:level windowClass:[UIWindow class]];
}

+ (UIWindow *)makeWindowWithScene:(UIWindowScene *)scene level:(CGFloat)level windowClass:(Class)windowClass {
    if (![NSThread isMainThread]) {
        __block UIWindow *result = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{
            result = [self makeWindowWithScene:scene level:level windowClass:windowClass];
        });
        return result;
    }
    if (!scene || ![windowClass isSubclassOfClass:[UIWindow class]]) return nil;
    UIWindow *w = [[windowClass alloc] initWithWindowScene:scene];
    if (!w) return nil;
    w.windowLevel = level;
    [SPWindows() addObject:w];
    SPLog(@"window +1 (level=%.0f total=%lu)", level, (unsigned long)[SPWindows() count]);
    return w;
}

+ (NSArray<UIWindow *> *)registeredWindows {
    if (![NSThread isMainThread]) {
        __block NSArray *result = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{ result = [self registeredWindows]; });
        return result;
    }
    return [SPWindows() copy];
}

+ (void)releaseWindow:(UIWindow *)w {
    if (!w) return;
    if (![NSThread isMainThread]) {
        dispatch_sync(dispatch_get_main_queue(), ^{ [self releaseWindow:w]; });
        return;
    }
    // 只回收本插件登记的窗口；重复释放也不会碰到系统/其他插件的窗口。
    if ([SPWindows() indexOfObjectIdenticalTo:w] == NSNotFound) return;
    [SPWindows() removeObjectIdenticalTo:w];
    w.hidden = YES;
    [w resignKeyWindow];
    w.rootViewController = nil;
    w.windowScene = nil;
    [w removeFromSuperview];
}

+ (void)killAll {
    if (![NSThread isMainThread]) {
        dispatch_sync(dispatch_get_main_queue(), ^{ [self killAll]; });
        return;
    }
    NSArray<UIWindow *> *owned = [self registeredWindows];
    for (UIWindow *w in owned) [self releaseWindow:w];
    SPLog(@"window killAll: %lu", (unsigned long)owned.count);
}

+ (NSUInteger)count { return [self registeredWindows].count; }

@end
