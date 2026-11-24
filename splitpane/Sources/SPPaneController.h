// SPPaneController.h — 竖屏上下分屏的两块面板 + 可拖动接缝
// 结构照 PV 的 PVSlideOverContainer / PVPairPresentation 收口：
//   window(overlay) → topHost / bottomHost / seam(pan) / chrome(状态栏遮挡+退出按钮)
#import <UIKit/UIKit.h>

@interface SPPaneController : NSObject
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
@end