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

/// 0.7.178: PV式全屏分屏 —— App全屏前台启动，上滑到顶后固定为第一半并选第二个。
- (void)startPVFullscreenSplitForBundleID:(NSString *)bundleID;
- (void)handlePVFullscreenSplitPanBegan:(id)gesture;
- (void)handlePVFullscreenSplitPanChanged:(id)gesture;
- (BOOL)handlePVFullscreenSplitPanEnded:(id)gesture;
- (BOOL)isPVFullscreenSplitPending;
/// 0.7.179: 一次性建两个窗并铺满分屏（不露单个浮窗中间态）
- (void)createSplitPairWithFirst:(NSString *)firstBundleID second:(NSString *)secondBundleID;
/// 0.7.180: PV式 —— 松手后第一个 App 直接铺成上半屏，再选第二个填下半屏
- (BOOL)createTopHalfWithBundleID:(NSString *)firstBundleID;
/// 0.7.198: 分屏待命中，用户手动打开了第二个 App —— 拦截改判成分屏
- (BOOL)tryActivatePendingSplitForLaunchedBundleID:(NSString *)bundleID request:(id)request;
/// 0.7.199: 每次转场都抓 request 里的系统自建真实 displayItem 按 bundleID 缓存
- (void)cacheRealDisplayItemFromRequest:(id)request bundleID:(NSString *)bundleID;
/// 0.7.201: 枚举 SBApplication 属性，诊断 displayItem 到底在哪个字段
- (void)diagSBApplicationProperties:(NSString *)bundleID;
/// 0.7.203: 枚举前台 scene 属性，诊断 displayItem 真身（SBApplication 上没有）
- (void)diagForegroundSceneForBundleID:(NSString *)bundleID;
/// 0.7.204: 递归 dump 转场 request 对象树，定位真实 displayItem 藏在哪个字段
- (void)dumpTransitionRequest:(id)request;
/// 0.7.205: dump 系统真实 SBAppLayout 数组（切换器出现时），含每个 App 的真实 displayItem
- (void)dumpRealAppLayouts:(NSArray *)layouts;
/// 0.7.210: 照 PV —— 从切换器真实 layout 里收割每个 App 的真实 displayItem 进缓存表
- (void)harvestRealDisplayItemsFromSwitcherLayouts:(NSArray *)layouts;
/// 0.7.212: 照 PV 的上滑挂起 —— 把前台 App 收成贴边抽屉
- (BOOL)parkForegroundAppIntoPipDrawer:(NSString *)bundleID;
- (void)handleHomeGesturePanTouchesEnded:(id)recognizer;
- (BOOL)parkForegroundAppAsFloatingCard:(NSString *)bundleID;
- (UIImage *)captureForegroundSnapshot;

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
- (void)noteForegroundApplicationChanged:(nullable NSString *)bundleID;
/// 按 bundleID 从 SpringBoard 场景实体解析真实 displayItem（供 Switcher 卡注册）
- (nullable id)displayItemForBundleID:(NSString *)bundleID;
/// 当前分屏对应的 SBAppLayout（分屏态才有值，否则 nil）。Switcher 数据源 hook 用。
- (nullable id)currentSwitcherLayout;
- (void)observeSwitcherContentController:(nullable id)controller;
@property (nonatomic) NSUInteger switcherSourceCalls;
@property (nonatomic) NSUInteger switcherAppendCalls;
@property (nonatomic) NSUInteger switcherCacheCalls;
@property (nonatomic) NSUInteger switcherPageCalls;
/// 判断某 layout 是否就是我们的分屏卡
- (BOOL)isSwitcherCard:(nullable id)layout;
/// Switcher 卡被点击：恢复分屏会话
- (void)activateSwitcherCard:(nullable id)layout;
/// Record any native switcher activation candidate before identity matching.
- (BOOL)isSwitcherGroupDisplayItem:(nullable id)item;
- (void)noteSwitcherActivationCandidate:(nullable id)layout source:(NSString *)source;
/// 从两个分屏 pane 截图拼出 Switcher 卡内容（快照方式，不移动原视图）
- (nullable UIView *)contentViewForSwitcherLayout:(nullable id)layout;
/// 构造 Switcher 卡 page content 视图（类型安全的 DPGroupPageView，塞快照）
- (nullable UIView *)makeSwitcherPageView:(nullable id)layout;


/// 允许下一次该 bundle 全屏启动（用于先拉起进程再回桌面挂画面）
- (void)allowNextLaunchForBundleID:(NSString *)bundleID;

@end

NS_ASSUME_NONNULL_END
