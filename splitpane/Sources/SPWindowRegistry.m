#import "SPWindowRegistry.h"
#import "SPLog.h"

NSNotificationName const SPWindowRegistryDidReleaseWindowNotification = @"SPWindowRegistryDidReleaseWindow";

// 强引用登记；所有读写与 UIKit 摘除操作都串行在主队列。
static NSMutableArray<UIWindow *> *SPWindows(void) {
    static NSMutableArray<UIWindow *> *windows;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ windows = [NSMutableArray array]; });
    return windows;
}

static BOOL gKillingAll = NO;

@implementation SPWindowRegistry

+ (UIWindow *)makeWindowWithScene:(UIWindowScene *)scene level:(CGFloat)level {
    return [self makeWindowWithScene:scene level:level windowClass:UIWindow.class];
}

+ (UIWindow *)makeWindowWithScene:(UIWindowScene *)scene level:(CGFloat)level windowClass:(Class)windowClass {
    if (![NSThread isMainThread]) {
        __block UIWindow *window = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{
            window = [self makeWindowWithScene:scene level:level windowClass:windowClass];
        });
        return window;
    }
    if (!scene || !windowClass || ![windowClass isSubclassOfClass:UIWindow.class]) {
        SPLog(@"window: rejected scene=%@ class=%@", scene, NSStringFromClass(windowClass));
        return nil;
    }
    UIWindow *window = [[windowClass alloc] initWithWindowScene:scene];
    if (!window) return nil;
    window.windowLevel = level;
    [SPWindows() addObject:window];
    SPLog(@"window +1 (class=%@ level=%.0f total=%lu)", NSStringFromClass(windowClass),
          level, (unsigned long)SPWindows().count);
    return window;
}

+ (BOOL)containsWindow:(UIWindow *)window {
    if (!window) return NO;
    if (![NSThread isMainThread]) {
        __block BOOL contains = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{ contains = [self containsWindow:window]; });
        return contains;
    }
    return [SPWindows() indexOfObjectIdenticalTo:window] != NSNotFound;
}

+ (void)releaseWindow:(UIWindow *)window {
    if (!window) return;
    if (![NSThread isMainThread]) {
        dispatch_sync(dispatch_get_main_queue(), ^{ [self releaseWindow:window]; });
        return;
    }
    if (![self containsWindow:window]) return;
    // 先取消登记，重入/过期动画 completion 再释放同一窗口时直接返回。
    [SPWindows() removeObjectIdenticalTo:window];
    window.hidden = YES;
    window.rootViewController = nil;
    window.windowScene = nil;
    [window removeFromSuperview];
    // Picker 自行同步清状态，不 import picker，也不回调其释放入口。
    [[NSNotificationCenter defaultCenter] postNotificationName:SPWindowRegistryDidReleaseWindowNotification
                                                      object:window];
}

+ (void)killAll {
    if (![NSThread isMainThread]) {
        dispatch_sync(dispatch_get_main_queue(), ^{ [self killAll]; });
        return;
    }
    if (gKillingAll) return;
    gKillingAll = YES;
    NSArray<UIWindow *> *snapshot = [SPWindows() copy];
    @try {
        for (UIWindow *window in snapshot) [self releaseWindow:window];
    } @finally {
        gKillingAll = NO;
    }
    // 不 removeAllObjects：通知/取消回调可能已经建立了新的分屏窗口。
    SPLog(@"window killAll: %lu (remaining=%lu)", (unsigned long)snapshot.count,
          (unsigned long)SPWindows().count);
}

+ (NSUInteger)count {
    if (![NSThread isMainThread]) {
        __block NSUInteger count = 0;
        dispatch_sync(dispatch_get_main_queue(), ^{ count = [self count]; });
        return count;
    }
    return SPWindows().count;
}

@end
