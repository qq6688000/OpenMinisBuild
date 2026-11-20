#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class DPFloatingWindow;

typedef NS_ENUM(NSInteger, DPPresentationMode) {
    DPPresentationModeNone = 0,
    DPPresentationModeFloating,
    DPPresentationModeSplit,
};

/// 悬浮窗 / 分屏总控
@interface DPWindowManager : NSObject

+ (instancetype)shared;

@property (nonatomic, strong, readonly) NSArray<DPFloatingWindow *> *floatingWindows;
@property (nonatomic, assign, readonly) DPPresentationMode mode;

/// 当前被托管、禁止全屏前台切换的 App bundleID 列表
@property (nonatomic, strong, readonly) NSSet<NSString *> *hostedBundleIDs;

- (void)install;
- (void)installInWindow:(UIWindow *)window; // 兼容旧调用，内部转 install

- (void)handleActivationRequest;
- (void)handleActivationForBundleID:(NSString *)bundleID;
- (void)handleActivationForBundleID:(NSString *)bundleID preferredMode:(DPPresentationMode)mode;

- (void)presentAppPickerWithCompletion:(void (^ _Nullable)(NSString * _Nullable bundleID))completion;
- (void)openBundleID:(NSString *)bundleID inMode:(DPPresentationMode)mode;
- (void)openFloatingWithBundleID:(NSString *)bundleID;
- (void)prepareForHostedInput;
- (void)prepareForTouchInView:(UIView *)view;
- (void)handleUserHome;
- (void)handleHomeGestureEnded;
- (void)handleDeviceLock;
- (void)handleDeviceUnlock;
- (void)focusWindow:(DPFloatingWindow *)window;
- (void)requestSplitForWindow:(DPFloatingWindow *)window;
- (void)leaveSplit;
- (void)dismissAllAnimated:(BOOL)animated;
- (void)handleOrientationChange;

/// 若该 bundle 正被我们托管，应拦截其全屏激活
- (BOOL)shouldSuppressFullscreenForBundleID:(nullable NSString *)bundleID;
- (void)handlePotentialFullscreenActivationForBundleID:(nullable NSString *)bundleID;
- (void)bringOverlayToFront;
/// 按 bundleID 从 SpringBoard 场景实体解析真实 displayItem（供 Switcher 卡注册）
- (nullable id)displayItemForBundleID:(NSString *)bundleID;
/// 当前分屏对应的 SBAppLayout（分屏态才有值，否则 nil）。Switcher 数据源 hook 用。
- (nullable id)currentSwitcherLayout;
/// 判断某 layout 是否就是我们的分屏卡
- (BOOL)isSwitcherCard:(nullable id)layout;
/// Switcher 卡被点击：恢复分屏会话
- (void)activateSwitcherCard:(nullable id)layout;
/// 从两个分屏 pane 的真实宿主视图拼出 Switcher 卡内容（page view 提供器用）
- (nullable UIView *)contentViewForSwitcherLayout:(nullable id)layout;


/// 允许下一次该 bundle 全屏启动（用于先拉起进程再回桌面挂画面）
- (void)allowNextLaunchForBundleID:(NSString *)bundleID;

@end

NS_ASSUME_NONNULL_END
