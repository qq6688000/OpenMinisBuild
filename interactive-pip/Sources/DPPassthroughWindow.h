#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 独立置顶窗口：挂在系统 UI 之上，不会因切 App 而消失。
/// 空白区域点击穿透，只有子视图（悬浮窗/分屏壳）接收触摸。
@interface DPPassthroughWindow : UIWindow
@end

/// 空白区域触摸穿透的根视图。
@interface DPPassthroughView : UIView
@end

NS_ASSUME_NONNULL_END
