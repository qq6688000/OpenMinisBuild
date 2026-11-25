#import <UIKit/UIKit.h>

// 自建窗口统一登记 + 兜底回收。接口同步切到主队列；仅登记自建窗口。
// 通知在窗口完成摘除后同步发出，object 是被回收的 UIWindow。
FOUNDATION_EXPORT NSNotificationName const SPWindowRegistryDidReleaseWindowNotification;

@interface SPWindowRegistry : NSObject
+ (nullable UIWindow *)makeWindowWithScene:(UIWindowScene *)scene level:(CGFloat)level;
+ (nullable UIWindow *)makeWindowWithScene:(UIWindowScene *)scene
                                   level:(CGFloat)level
                             windowClass:(Class)windowClass;
+ (BOOL)containsWindow:(UIWindow *)window;
+ (void)releaseWindow:(UIWindow *)window;
// 只回收调用时的快照；忽略重入，不清除回调中新建的窗口。
+ (void)killAll;
+ (NSUInteger)count;
@end
