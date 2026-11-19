#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class DPFloatingWindow;

typedef NS_ENUM(NSInteger, DPPresentationMode) {
    DPPresentationModeNone = 0,
    DPPresentationModeFloating,
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
- (void)dismissAllAnimated:(BOOL)animated;
- (void)handleOrientationChange;

/// 若该 bundle 正被我们托管，应拦截其全屏激活
- (BOOL)shouldSuppressFullscreenForBundleID:(nullable NSString *)bundleID;
- (void)handlePotentialFullscreenActivationForBundleID:(nullable NSString *)bundleID;
- (void)bringOverlayToFront;

/// 允许下一次该 bundle 全屏启动（用于先拉起进程再回桌面挂画面）
- (void)allowNextLaunchForBundleID:(NSString *)bundleID;

@end

NS_ASSUME_NONNULL_END
