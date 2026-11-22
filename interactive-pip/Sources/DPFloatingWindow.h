#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class DPSceneHost;

// 0.7.113: keyboard expand/collapse event trace (shared with diagnostics panel).
FOUNDATION_EXPORT NSString *DPKeyboardExpandTrace(void);
FOUNDATION_EXPORT void DPKBLog(NSString *fmt, ...);

/// Hosts a second app scene inside a draggable / resizable floating chrome.
@interface DPFloatingWindow : UIView

@property (nonatomic, copy, readonly) NSString *bundleID;
@property (nonatomic, strong, readonly, nullable) DPSceneHost *sceneHost;
@property (nonatomic, assign) CGFloat contentOpacity;
@property (nonatomic, assign) CGFloat cornerRadiusValue;
@property (nonatomic, assign) BOOL showsBorder;
@property (nonatomic, assign, getter=isTiled) BOOL tiled;
@property (nonatomic, copy, nullable) void (^onSplit)(DPFloatingWindow *window);
@property (nonatomic, copy, nullable) void (^onClose)(DPFloatingWindow *window);
@property (nonatomic, copy, nullable) void (^onFocus)(DPFloatingWindow *window);
@property (nonatomic, copy, nullable) void (^onFrameChanged)(DPFloatingWindow *window, CGRect frame);

- (instancetype)initWithBundleID:(NSString *)bundleID frame:(CGRect)frame;
- (void)attachSceneHost:(DPSceneHost *)host;
- (nullable DPSceneHost *)detachSceneHost;
- (void)commitSceneLayout;
/// Round the pane's own chrome + content container while in Duo split.
/// Never touches the hosted scene layer container's layer.
- (void)setSplitCardCornerRadius:(CGFloat)radius;
- (void)setActive:(BOOL)active animated:(BOOL)animated;
- (void)bringToFront;
- (void)closeAnimated:(BOOL)animated completion:(void (^ _Nullable)(void))completion;
/// 键盘弹出时把浮窗放大到覆盖键盘上方的可用区域（近似全屏）。
/// 键盘收起时用 -collapseForKeyboardAnimated: 还原到键盘弹出前的 frame。
/// 与手动全屏按钮的 maximized 状态互相独立。
- (void)expandForKeyboardAnimated:(BOOL)animated;
- (void)collapseForKeyboardAnimated:(BOOL)animated;
/// 当前是否因键盘弹出而处于扩展态。
@property (nonatomic, assign, readonly) BOOL keyboardExpanded;

@end

NS_ASSUME_NONNULL_END
