// SPGesture.h — 底部上滑挂起（PV 同款入口）
// 从屏幕最底部 40pt 带起手、往上推超过阈值就接管：
//   ① 冻结当前 App 的画面 → 缩成挂起卡片停在底部
//   ② 点卡片 → 弹 App 选择面板 → 选中的 App 进下半屏，卡片里的 App 进上半屏
//   ③ 已经在分屏里再滑一次 → 直接换上面的 App（PV 的「一划切换」）
#import <UIKit/UIKit.h>

@interface SPGesture : NSObject
@property (class, readonly) SPGesture *shared;
- (void)installInWindowScene:(UIWindowScene *)scene;
- (void)handleHomePanBegan:(CGPoint)loc;
- (BOOL)consumeHomePan:(UIPanGestureRecognizer *)pan translation:(CGPoint)translation velocity:(CGPoint)velocity;
@end