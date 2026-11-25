// SPPaneController.h — 竖屏上下分屏的两块面板 + 可拖动接缝
// 结构照 PV 的 PVSlideOverContainer / PVPairPresentation 收口：
//   window(overlay) → topHost / bottomHost / seam(pan) / chrome(状态栏遮挡+退出按钮)
#import <UIKit/UIKit.h>

@interface SPPaneController : NSObject <UIGestureRecognizerDelegate>
@property (class, readonly) SPPaneController *shared;

@property (nonatomic, readonly) BOOL active;
@property (nonatomic, copy, readonly) NSString *topBundleID;
@property (nonatomic, copy, readonly) NSString *bottomBundleID;

// 用 top / bottom 两个 bundleID 起分屏；returns NO 时调用方保持原状
- (BOOL)startWithTop:(NSString *)top bottom:(NSString *)bottom windowScene:(UIWindowScene *)scene topSnapshot:(UIImage *)snap;

// 换掉上面那块（PV 里再次上滑的行为）
- (void)replaceTopWithBundleID:(NSString *)bundleID;
- (void)replaceBundleID:(NSString *)bundleID;

// 收工：恢复原布局、拆掉窗口、归还 scene
- (void)stopWithCompletion:(void (^)(void))completion;

// 分屏挂起：把整个分屏窗口缩成桌面上的一张卡片（画面保持实时，不拆 scene）
// 用户上划 home 时调用。返回 NO 表示没在分屏里。
- (BOOL)suspendToCardWithCompletion:(void (^)(void))completion;

// 点卡片恢复分屏（从卡片位置动画展开回全屏）
- (void)resumeFromCardWithCompletion:(void (^)(void))completion;

// 是否处于挂起（缩成卡片）状态
@property (nonatomic, readonly) BOOL suspended;
@end