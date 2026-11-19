#import "DPWindowManager.h"
#import "DPFloatingWindow.h"
#import "DPSceneHost.h"
#import "DPAppPicker.h"
#import "DPSettings.h"
#import "DPPassthroughWindow.h"
#import <objc/message.h>

@interface DPWindowManager ()
@property (nonatomic, strong, nullable) DPPassthroughWindow *overlayWindow;
@property (nonatomic, strong) DPPassthroughView *overlayRoot;
@property (nonatomic, strong, readwrite) NSMutableArray<DPFloatingWindow *> *mutableFloatingWindows;
@property (nonatomic, assign, readwrite) DPPresentationMode mode;
@property (nonatomic, strong, nullable) DPAppPicker *picker;
@property (nonatomic, strong) NSMutableSet<NSString *> *mutableHostedBundleIDs;
@property (nonatomic, strong) NSMutableSet<NSString *> *launchAllowlist; // 临时允许全屏一次
@property (nonatomic, assign) BOOL suppressLaunch;
@property (nonatomic, assign) BOOL homeReturnPending;
@property (nonatomic, copy, nullable) NSString *pendingHomeBundleID;
@property (nonatomic, weak, nullable) UIWindow *keyWindowBeforeHostedInput;
@property (nonatomic, assign) BOOL hostedInputActive;
@property (nonatomic, assign) BOOL keyboardStateSaved;
@property (nonatomic, assign) BOOL oldCurrentKeyboard;
@property (nonatomic, assign) BOOL oldWindowEnabled;
@property (nonatomic, weak, nullable) DPFloatingWindow *keyboardRoutedWindow;
@property (nonatomic, weak, nullable) DPFloatingWindow *focusedWindow;
@property (nonatomic, strong, nullable) NSValue *frameBeforeKeyboard;
- (void)avoidKeyboardWithHeight:(CGFloat)height;
- (BOOL)kbBool:(id)kb name:(NSString *)n;
- (void)kbBool:(id)kb name:(NSString *)n value:(BOOL)v;
- (void)syncOverlayVisibility;
- (void)openFloatingWithBundleID:(NSString *)bundleID reusingHost:(nullable DPSceneHost *)reusableHost;
- (void)makeOverlayKeyWindow;
- (void)ensureOverlayVisible;
- (void)restorePreviousKeyWindow;
- (id)sharedRemoteKeyboards;
- (void)configureRemoteKeyboardsForHostedInput:(BOOL)enabled;
@end

static CGFloat _kbHeightFromNotification(NSNotification *note) {
    CGRect r = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    return r.size.height;
}

@implementation DPWindowManager

+ (instancetype)shared {
    static DPWindowManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[DPWindowManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _mutableFloatingWindows = [NSMutableArray array];
        _mutableHostedBundleIDs = [NSMutableSet set];
        _launchAllowlist = [NSMutableSet set];
        _mode = DPPresentationModeNone;
        _suppressLaunch = NO;
        _homeReturnPending = NO;
        _hostedInputActive = NO;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                  selector:@selector(settingsChanged)
                                                      name:kDPSettingsChangedNotification
                                                    object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                   selector:@selector(hostedKeyboardWillHide:)
                                                       name:UIKeyboardWillHideNotification
                                                     object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                   selector:@selector(hostedKeyboardWillShow:)
                                                       name:UIKeyboardWillShowNotification
                                                     object:nil];
    }
    return self;
}

- (NSArray<DPFloatingWindow *> *)floatingWindows {
    return [self.mutableFloatingWindows copy];
}

- (NSSet<NSString *> *)hostedBundleIDs {
    return [self.mutableHostedBundleIDs copy];
}

#pragma mark - Install（独立顶层窗口）

- (void)installInWindow:(UIWindow *)window {
    (void)window;
    [self install];
}

- (void)install {
    if (self.overlayWindow && self.overlayWindow.hidden == NO) {
        [self bringOverlayToFront];
        return;
    }

    CGRect bounds = [UIScreen mainScreen].bounds;
    DPPassthroughWindow *win = nil;

    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = [self activeWindowScene];
        if (scene) {
            win = [[DPPassthroughWindow alloc] initWithWindowScene:scene];
            win.frame = scene.coordinateSpace.bounds;
        }
    }
    if (!win) {
        win = [[DPPassthroughWindow alloc] initWithFrame:bounds];
    }

    win.windowLevel = UIWindowLevelStatusBar + 120.0;
    win.backgroundColor = [UIColor clearColor];
    win.hidden = NO;

    UIViewController *rootVC = [[UIViewController alloc] init];
    DPPassthroughView *root = [[DPPassthroughView alloc] initWithFrame:win.bounds];
    root.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    root.backgroundColor = [UIColor clearColor];
    rootVC.view = root;
    win.rootViewController = rootVC;

    self.overlayWindow = win;
    self.overlayRoot = root;

    NSLog(@"[DualPane] 顶层窗口已安装 level=%.0f", win.windowLevel);
}

- (UIWindowScene *)activeWindowScene API_AVAILABLE(ios(13.0)) {
    UIWindowScene *fallback = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        if (ws.activationState == UISceneActivationStateForegroundActive) return ws;
        if (!fallback) fallback = ws;
    }
    return fallback;
}

- (void)bringOverlayToFront {
    if (!self.overlayWindow) {
        [self install];
        return;
    }
    self.overlayWindow.hidden = NO;
    self.overlayWindow.windowLevel = UIWindowLevelStatusBar + 120.0;
    // 重新挂到当前 scene（切 App 后 scene 可能变）
    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = [self activeWindowScene];
        if (scene && self.overlayWindow.windowScene != scene) {
            self.overlayWindow.windowScene = scene;
            self.overlayWindow.frame = scene.coordinateSpace.bounds;
            self.overlayRoot.frame = self.overlayWindow.bounds;
        }
    }
    // 不抢 keyWindow，只确保可见
    self.overlayWindow.hidden = NO;
}

- (UIView *)contentParent {
    [self install];
    [self bringOverlayToFront];
    return self.overlayRoot;
}

#pragma mark - Activation

- (void)handleActivationRequest {
    if (![DPSettings shared].isEnabled) return;
    [self install];

    [self presentAppPickerWithCompletion:^(NSString *bundleID) {
        if (bundleID) [self openFloatingWithBundleID:bundleID];
    }];
}

- (void)handleActivationForBundleID:(NSString *)bundleID {
    [self handleActivationForBundleID:bundleID preferredMode:DPPresentationModeNone];
}

- (void)handleActivationForBundleID:(NSString *)bundleID preferredMode:(DPPresentationMode)mode {
    if (![DPSettings shared].isEnabled) return;
    if (!bundleID.length) {
        [self handleActivationRequest];
        return;
    }
    if ([[DPSettings shared] isBundleBlacklisted:bundleID]) return;

    [self install];

    (void)mode;
    [self openFloatingWithBundleID:bundleID];
    return;
    /*
        // 分屏：左边尽量用当前前台 App；主屏触发时用「桌面占位 + 目标 App」
        NSString *primary = [self foregroundBundleID];
        if (!primary.length ||
            [primary isEqualToString:bundleID] ||
            [primary isEqualToString:@"com.apple.springboard"]) {
            // 主屏触发：用目标 App 自己做主屏不合适，改为仅悬浮更直观
            // 但用户要分屏：主侧显示桌面快照占位，右侧目标 App
            primary = @"com.apple.springboard";
        }
        [self openSplitWithPrimary:primary secondary:bundleID];
        return;
    }

    // 询问
    if (self.modeChooser) {
        [self.modeChooser dismiss];
        self.modeChooser = nil;
    }
    UIView *parent = [self contentParent];
    __weak typeof(self) weakSelf = self;
    NSString *target = [bundleID copy];
    self.modeChooser = [[DPOverlayController alloc] init];
    [self.modeChooser presentModeChooserInView:parent
                                    completion:^(DPPresentationMode chosen) {
        weakSelf.modeChooser = nil;
        if (chosen == DPPresentationModeNone) return;
        [weakSelf handleActivationForBundleID:target preferredMode:chosen];
    }];
}

- (void)presentModeChooser {
    if (self.modeChooser) {
        [self.modeChooser dismiss];
        self.modeChooser = nil;
    }
    UIView *parent = [self contentParent];
    __weak typeof(self) weakSelf = self;
    self.modeChooser = [[DPOverlayController alloc] init];
    [self.modeChooser presentModeChooserInView:parent
                                    completion:^(DPPresentationMode chosen) {
        weakSelf.modeChooser = nil;
        if (chosen == DPPresentationModeNone) return;
        [weakSelf presentAppPickerWithCompletion:^(NSString *bundleID) {
            if (!bundleID) return;
            if (chosen == DPPresentationModeFloating) {
                [weakSelf openFloatingWithBundleID:bundleID];
            } else if (chosen == DPPresentationModeSplit) {
                [weakSelf handleActivationForBundleID:bundleID preferredMode:DPPresentationModeSplit];
            }
        }];
    }];
}
*/
}

- (void)presentAppPickerWithCompletion:(void (^)(NSString * _Nullable))completion {
    if (self.picker) {
        [self.picker dismissAnimated:NO];
        self.picker = nil;
    }
    UIView *parent = [self contentParent];
    self.picker = [[DPAppPicker alloc] init];
    __weak typeof(self) weakSelf = self;
    [self.picker presentInView:parent
                     favorites:[DPSettings shared].favorites
                     blacklist:[DPSettings shared].blacklist
                    completion:^(NSString *bundleID) {
        weakSelf.picker = nil;
        if (completion) completion(bundleID);
    }];
}

#pragma mark - Open

- (void)openBundleID:(NSString *)bundleID inMode:(DPPresentationMode)mode {
    (void)mode;
    [self openFloatingWithBundleID:bundleID];
}

- (void)openFloatingWithBundleID:(NSString *)bundleID {
    [self openFloatingWithBundleID:bundleID reusingHost:nil];
}

- (void)openFloatingWithBundleID:(NSString *)bundleID
                     reusingHost:(DPSceneHost *)reusableHost {
    if (!bundleID.length) return;
    if ([[DPSettings shared] isBundleBlacklisted:bundleID]) return;

    for (DPFloatingWindow *existing in self.mutableFloatingWindows) {
        if ([existing.bundleID isEqualToString:bundleID]) {
            [existing bringToFront];
            if (!existing.sceneHost.isLive) [existing.sceneHost retryAttach];
            [self bringOverlayToFront];
            return;
        }
    }

    // 关键：先登记托管，再画 UI —— 阻止随后的全屏启动
    [self.mutableHostedBundleIDs addObject:bundleID];
    self.suppressLaunch = YES;

    NSInteger max = [DPSettings shared].maxFloatingWindows;
    while ((NSInteger)self.mutableFloatingWindows.count >= max) {
        DPFloatingWindow *oldest = self.mutableFloatingWindows.firstObject;
        [self closeFloatingWindow:oldest animated:YES];
    }

    UIView *parent = [self contentParent];
    CGRect frame = [self initialFloatingFrameInBounds:parent.bounds];
    DPFloatingWindow *window = [[DPFloatingWindow alloc] initWithBundleID:bundleID frame:frame];
    window.contentOpacity = [DPSettings shared].floatingOpacity;
    window.cornerRadiusValue = [DPSettings shared].floatingCornerRadius;
    window.showsBorder = [DPSettings shared].showBorder;

    // 先占位，等 frame 落地后再创建 host，避免 0 尺寸 host view
    __weak typeof(self) weakSelf = self;
    window.onClose = ^(DPFloatingWindow *w) {
        [weakSelf closeFloatingWindow:w animated:YES];
    };
    window.onFocus = ^(DPFloatingWindow *w) {
        for (DPFloatingWindow *other in weakSelf.mutableFloatingWindows) {
            [other setActive:(other == w) animated:YES];
        }
        weakSelf.focusedWindow = w;
        [weakSelf prepareForHostedInput];
        [weakSelf bringOverlayToFront];
    };
    window.onFrameChanged = ^(DPFloatingWindow *w, CGRect f) {
        [[DPSettings shared] setLastFloatingFrame:f];
        (void)w;
    };

    [parent addSubview:window];
    [self.mutableFloatingWindows addObject:window];
    self.focusedWindow = window;
    self.mode = DPPresentationModeFloating;
    [self bringOverlayToFront];
    [self makeOverlayKeyWindow];

    // layout 后再挂 host，保证 contentContainer 有真实尺寸
    [window setNeedsLayout];
    [window layoutIfNeeded];
    DPSceneHost *host = reusableHost ?: [[DPSceneHost alloc] initWithBundleID:bundleID];
    [window attachSceneHost:host];

    if ([DPSettings shared].animateTransitions) {
        window.alpha = 0;
        window.transform = CGAffineTransformMakeScale(0.9, 0.9);
        [UIView animateWithDuration:0.28 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0.5 options:0 animations:^{
            window.alpha = 1;
            window.transform = CGAffineTransformIdentity;
        } completion:nil];
    }

    [self ensureSceneThenAttach:bundleID host:host onAttached:^{
        [weakSelf bringOverlayToFront];
    }];

    NSLog(@"[DualPane] 打开悬浮窗 %@", bundleID);
}

#if 0
- (void)openSplitWithPrimary:(NSString *)primary secondary:(NSString *)secondary {
    [self openSplitWithPrimary:primary
                     secondary:secondary
           reusingPrimaryHost:nil
         reusingSecondaryHost:nil];
}

- (BOOL)handleAppLaunchInActiveSplit:(NSString *)bundleID {
    if (!bundleID.length || !self.splitManager.isActive) return NO;
    if ([bundleID isEqualToString:@"com.apple.springboard"]) return NO;
    if ([[DPSettings shared] isBundleBlacklisted:bundleID]) return NO;
    if ([self.launchAllowlist containsObject:bundleID]) return NO;

    NSString *primary = self.splitManager.primaryBundleID;
    NSString *secondary = self.splitManager.secondaryBundleID;
    if ([bundleID isEqualToString:primary] || [bundleID isEqualToString:secondary]) return NO;

    [self openBundleInActiveSplit:bundleID];
    return YES;
}

- (void)openBundleInActiveSplit:(NSString *)bundleID {
    if (!bundleID.length || !self.splitManager.isActive) return;
    NSString *primary = self.splitManager.primaryBundleID;
    NSString *secondary = self.splitManager.secondaryBundleID;
    if ([bundleID isEqualToString:primary] || [bundleID isEqualToString:secondary]) {
        [self bringOverlayToFront];
        return;
    }

    if ([primary isEqualToString:@"com.apple.springboard"] && secondary.length) {
        DPSceneHost *promotedHost = [self.splitManager detachSecondaryHost];
        [self.mutableHostedBundleIDs removeObject:primary];
        [self.mutableHostedBundleIDs removeObject:secondary];
        [self.splitManager dismissAnimated:NO completion:nil];
        self.splitManager = nil;
        [self openSplitWithPrimary:secondary
                         secondary:bundleID
               reusingPrimaryHost:promotedHost
             reusingSecondaryHost:nil];
        return;
    }

    [self openSplitWithPrimary:primary ?: @"com.apple.springboard"
                     secondary:bundleID
           reusingPrimaryHost:nil
         reusingSecondaryHost:nil];
}

- (void)openSplitWithPrimary:(NSString *)primary
                   secondary:(NSString *)secondary
         reusingPrimaryHost:(DPSceneHost *)reusablePrimaryHost
       reusingSecondaryHost:(DPSceneHost *)reusableSecondaryHost {
    if (!secondary.length) return;
    if ([[DPSettings shared] isBundleBlacklisted:secondary]) return;
    if ([primary isEqualToString:secondary]) primary = @"com.apple.springboard";

    [self.mutableHostedBundleIDs addObject:secondary];
    if (primary.length && ![primary isEqualToString:@"com.apple.springboard"]) {
        [self.mutableHostedBundleIDs addObject:primary];
    }
    self.suppressLaunch = YES;

    NSArray *copy = [self.mutableFloatingWindows copy];
    for (DPFloatingWindow *w in copy) {
        [self closeFloatingWindow:w animated:NO];
    }

    UIView *parent = [self contentParent];

    if (self.splitManager.isActive) {
        NSString *oldPrimary = self.splitManager.primaryBundleID;
        NSString *oldSecondary = self.splitManager.secondaryBundleID;
        if (oldPrimary) [self.mutableHostedBundleIDs removeObject:oldPrimary];
        if (oldSecondary) [self.mutableHostedBundleIDs removeObject:oldSecondary];
        [self.splitManager dismissAnimated:NO completion:nil];
        self.splitManager = nil;
    }

    self.splitManager = [[DPSplitManager alloc] init];
    CGFloat ratio = [DPSettings shared].lastSplitRatio;

    __weak typeof(self) weakSelf = self;
    self.splitManager.onClose = ^{
        NSString *p = weakSelf.splitManager.primaryBundleID;
        NSString *s = weakSelf.splitManager.secondaryBundleID;
        if (p) [weakSelf.mutableHostedBundleIDs removeObject:p];
        if (s) [weakSelf.mutableHostedBundleIDs removeObject:s];
        [weakSelf.splitManager dismissAnimated:YES completion:^{
            weakSelf.splitManager = nil;
            weakSelf.mode = DPPresentationModeNone;
            weakSelf.suppressLaunch = NO;
        }];
    };
    self.splitManager.onRatioChanged = ^(CGFloat r) {
        [[DPSettings shared] setLastSplitRatio:r];
    };
    self.splitManager.onPromoteSecondaryToFloating = ^(NSString *bundleID) {
        NSString *p = weakSelf.splitManager.primaryBundleID;
        NSString *s = weakSelf.splitManager.secondaryBundleID;
        if (p) [weakSelf.mutableHostedBundleIDs removeObject:p];
        if (s) [weakSelf.mutableHostedBundleIDs removeObject:s];
        DPSceneHost *reusedHost = [weakSelf.splitManager detachSecondaryHost];
        [weakSelf.splitManager dismissAnimated:YES completion:^{
            weakSelf.splitManager = nil;
            [weakSelf openFloatingWithBundleID:bundleID reusingHost:reusedHost];
        }];
    };

    [self.splitManager presentInView:parent
                       primaryBundle:primary ?: @"com.apple.springboard"
                     secondaryBundle:secondary
                               ratio:ratio
                            animated:YES];

    // 先 layout 再挂 host，避免 0 尺寸
    [self.splitManager layoutForBounds:parent.bounds];
    BOOL primaryIsHome = !primary.length || [primary isEqualToString:@"com.apple.springboard"];
    DPSceneHost *pHost = primaryIsHome ? nil : (reusablePrimaryHost ?: [[DPSceneHost alloc] initWithBundleID:primary]);
    DPSceneHost *sHost = reusableSecondaryHost ?: [[DPSceneHost alloc] initWithBundleID:secondary];
    if (pHost) [self.splitManager attachPrimaryHost:pHost];
    [self.splitManager attachSecondaryHost:sHost];

    self.mode = DPPresentationModeSplit;
    [[DPSettings shared] setLastPrimaryBundleID:primary];
    [[DPSettings shared] setLastSecondaryBundleID:secondary];
    [self bringOverlayToFront];

    [self ensureSceneThenAttach:secondary host:sHost onAttached:^{
        [weakSelf bringOverlayToFront];
    }];
    if (pHost) {
        [self ensureSceneThenAttach:primary host:pHost onAttached:^{
            [weakSelf bringOverlayToFront];
        }];
    }

    NSLog(@"[DualPane] 打开分屏 primary=%@ secondary=%@", primary, secondary);
}
#endif

- (void)closeFloatingWindow:(DPFloatingWindow *)window animated:(BOOL)animated {
    if (!window) return;
    if (window.bundleID) {
        [self.mutableHostedBundleIDs removeObject:window.bundleID];
    }
    [self.mutableFloatingWindows removeObject:window];
    [window closeAnimated:animated completion:nil];
    if (self.mutableFloatingWindows.count == 0) {
        self.mode = DPPresentationModeNone;
        self.suppressLaunch = NO;
        [self restorePreviousKeyWindow];
    }
    [self syncOverlayVisibility];
}

- (void)dismissAllAnimated:(BOOL)animated {
    NSArray *copy = [self.mutableFloatingWindows copy];
    for (DPFloatingWindow *w in copy) {
        [self closeFloatingWindow:w animated:animated];
    }
    self.mode = DPPresentationModeNone;
    self.suppressLaunch = NO;
    [self.mutableHostedBundleIDs removeAllObjects];
    [self restorePreviousKeyWindow];
    [self syncOverlayVisibility];
}

- (id)sharedRemoteKeyboards {
    Class remoteClass = NSClassFromString(@"_UIRemoteKeyboards");
    if (!remoteClass) return nil;
    SEL shared = NSSelectorFromString(@"sharedRemoteKeyboards");
    if (![remoteClass respondsToSelector:shared]) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(remoteClass, shared);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

- (BOOL)kbBool:(id)kb name:(NSString *)n {
    SEL sel = NSSelectorFromString(n);
    if (![kb respondsToSelector:sel]) return NO;
    @try { return ((BOOL (*)(id, SEL))objc_msgSend)(kb, sel); } @catch (__unused NSException *e) { return NO; }
}
- (void)kbBool:(id)kb name:(NSString *)n value:(BOOL)v {
    SEL sel = NSSelectorFromString(n);
    if (![kb respondsToSelector:sel]) return;
    @try { ((void (*)(id, SEL, BOOL))objc_msgSend)(kb, sel, v); } @catch (__unused NSException *e) {}
}

- (void)configureRemoteKeyboardsForHostedInput:(BOOL)enabled {
    id kb = [self sharedRemoteKeyboards];
    if (!kb) return;

    if (!enabled) {
        SEL fin = NSSelectorFromString(@"finishWithHostedWindow");
        if ([kb respondsToSelector:fin]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(kb, fin); } @catch (__unused NSException *e) {}
        }
        if (self.keyboardStateSaved) {
            [self kbBool:kb name:@"setCurrentKeyboard:" value:self.oldCurrentKeyboard];
            [self kbBool:kb name:@"setWindowEnabled:" value:self.oldWindowEnabled];
        }
        self.keyboardStateSaved = NO;
        self.hostedInputActive = NO;
        self.keyboardRoutedWindow = nil;
        return;
    }

    DPFloatingWindow *target = self.focusedWindow;
    if (!target) return;
    if (self.hostedInputActive && self.keyboardRoutedWindow == target) return;

    UIView *host = [target.sceneHost keyboardRoutingView];
    int pid = [target.sceneHost keyboardRoutingPID];
    if (!host || pid <= 0) {
        // No real FBSceneHostWrapperView: pixels only, keyboard cannot be routed.
        NSLog(@"[InteractivePiP] %@ 非 wrapper 宿主，跳过键盘登记", target.bundleID);
        self.hostedInputActive = NO;
        self.keyboardRoutedWindow = nil;
        return;
    }

    self.oldCurrentKeyboard = [self kbBool:kb name:@"currentKeyboard"];
    self.oldWindowEnabled = [self kbBool:kb name:@"windowEnabled"];
    self.keyboardStateSaved = YES;

    @try {
        SEL prep = NSSelectorFromString(@"prepareForHostedWindow");
        if ([kb respondsToSelector:prep]) ((id (*)(id, SEL))objc_msgSend)(kb, prep);

        SEL add = NSSelectorFromString(@"addHostedWindowView:fromPID:");
        if ([kb respondsToSelector:add]) ((void (*)(id, SEL, id, int))objc_msgSend)(kb, add, host, pid);

        [self kbBool:kb name:@"setWindowEnabled:" value:YES];
        [self kbBool:kb name:@"setCurrentKeyboard:" value:YES];

        SEL clean = NSSelectorFromString(@"cleanSuppression");
        if ([kb respondsToSelector:clean]) ((void (*)(id, SEL))objc_msgSend)(kb, clean);
        SEL upd = NSSelectorFromString(@"sceneUpdated");
        if ([kb respondsToSelector:upd]) ((void (*)(id, SEL))objc_msgSend)(kb, upd);

        self.hostedInputActive = YES;
        self.keyboardRoutedWindow = target;
        NSLog(@"[InteractivePiP] 键盘登记 %@ pid=%d", target.bundleID, pid);
    } @catch (NSException *e) {
        NSLog(@"[InteractivePiP] 键盘登记失败 %@: %@", target.bundleID, e);
        self.keyboardStateSaved = NO;
        self.hostedInputActive = NO;
    }
}

- (void)prepareForHostedInput {
    if (!self.overlayWindow || self.overlayWindow.hidden) return;
    // Keep DualPane chrome above SpringBoard, but do not permanently steal the
    // keyboard arbiter from third-party IMEs such as WeChat Keyboard.
    [self ensureOverlayVisible];
    [self configureRemoteKeyboardsForHostedInput:YES];
    for (DPFloatingWindow *window in self.mutableFloatingWindows) {
        [window.sceneHost prepareForInput];
    }
}

- (void)ensureOverlayVisible {
    if (!self.overlayWindow) return;
    self.overlayWindow.hidden = NO;
    [self bringOverlayToFront];
}

- (void)makeOverlayKeyWindow {
    if (!self.overlayWindow || self.overlayWindow.hidden) return;
    if (!self.hostedInputActive) {
        UIWindow *current = [UIApplication sharedApplication].keyWindow;
        if (current != self.overlayWindow) self.keyWindowBeforeHostedInput = current;
        self.hostedInputActive = YES;
    }
    // Prefer visibility over becoming the exclusive key window. Third-party
    // keyboards often need SpringBoard/remote keyboard ownership intact.
    [self ensureOverlayVisible];
}

- (void)restorePreviousKeyWindow {
    [self configureRemoteKeyboardsForHostedInput:NO];
    if (!self.hostedInputActive) return;
    self.hostedInputActive = NO;
    UIWindow *target = self.keyWindowBeforeHostedInput;
    self.keyWindowBeforeHostedInput = nil;
    if (target && target != self.overlayWindow && !target.hidden) {
        [target makeKeyWindow];
    } else if (self.overlayWindow.isKeyWindow) {
        [self.overlayWindow resignKeyWindow];
    }
}

- (void)hostedKeyboardWillShow:(NSNotification *)note {
    if (self.mode != DPPresentationModeNone) {
        [self prepareForHostedInput];
    }
    [self avoidKeyboardWithHeight:_kbHeightFromNotification(note)];
}



- (void)hostedKeyboardWillHide:(NSNotification *)note {
    [self avoidKeyboardWithHeight:0];
    // Keep remote keyboard support armed while a hosted app is open. UIKit
    // sends hide notifications while changing text fields.
    if (self.mutableFloatingWindows.count > 0) {
        [self configureRemoteKeyboardsForHostedInput:YES];
        return;
    }
    [self restorePreviousKeyWindow];
}

- (void)handleOrientationChange {
    if (self.overlayWindow) {
        CGRect bounds = [UIScreen mainScreen].bounds;
        if (@available(iOS 13.0, *)) {
            UIWindowScene *scene = self.overlayWindow.windowScene ?: [self activeWindowScene];
            if (scene) bounds = scene.coordinateSpace.bounds;
        }
        self.overlayWindow.frame = bounds;
        self.overlayRoot.frame = self.overlayWindow.bounds;
    }
    for (DPFloatingWindow *w in self.mutableFloatingWindows) {
        CGRect f = w.frame;
        CGRect bounds = self.overlayRoot.bounds;
        if (CGRectGetMaxX(f) < 40) f.origin.x = 0;
        if (CGRectGetMaxY(f) < 40) f.origin.y = 0;
        if (f.origin.x > bounds.size.width - 40) f.origin.x = bounds.size.width - f.size.width;
        if (f.origin.y > bounds.size.height - 40) f.origin.y = bounds.size.height - 40;
        w.frame = f;
        [w commitSceneLayout];
    }
    [self bringOverlayToFront];
}

#pragma mark - Launch suppress

- (BOOL)shouldSuppressFullscreenForBundleID:(NSString *)bundleID {
    if (!bundleID.length) return NO;
    // 临时放行：为了创建 scene 允许启动一次
    if ([self.launchAllowlist containsObject:bundleID]) {
        return NO;
    }
    // 只有我们真正在展示悬浮/分屏时才拦截；避免误伤普通启动
    if (self.mode == DPPresentationModeNone) return NO;
    if ([self.mutableHostedBundleIDs containsObject:bundleID]) return YES;
    return NO;
}

- (void)allowNextLaunchForBundleID:(NSString *)bundleID {
    if (bundleID.length) [self.launchAllowlist addObject:bundleID];
}

- (void)handlePotentialFullscreenActivationForBundleID:(NSString *)bundleID {
    if (![self shouldSuppressFullscreenForBundleID:bundleID]) {
        [self bringOverlayToFront];
        return;
    }
    [self scheduleHomeReturnForBundleID:bundleID delay:0.15];
}

- (void)scheduleHomeReturnForBundleID:(NSString *)bundleID delay:(NSTimeInterval)delay {
    if (!bundleID.length) return;

    self.pendingHomeBundleID = [bundleID copy];
    if (self.homeReturnPending) return;
    self.homeReturnPending = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2) return;
        NSString *target = self2.pendingHomeBundleID;
        self2.pendingHomeBundleID = nil;
        self2.homeReturnPending = NO;
        if (self2.mode == DPPresentationModeNone ||
            ![self2 shouldSuppressFullscreenForBundleID:target]) {
            [self2 bringOverlayToFront];
            return;
        }
        [self2 goHome];
    });
}

/// Launch suspended and poll briefly for the scene. Foreground launch is only
/// a compatibility fallback when the suspended SpringBoard API is unavailable.
- (void)ensureSceneThenAttach:(NSString *)bundleID
                         host:(DPSceneHost *)host
                   onAttached:(void (^)(void))onAttached {
    if (!bundleID.length || !host) return;
    if ([bundleID isEqualToString:@"com.apple.springboard"]) return;

    __weak typeof(self) weakSelf = self;
    __weak DPSceneHost *weakHost = host;

    if (host.isLive) {
        if (onAttached) onAttached();
        self.suppressLaunch = NO;
        return;
    }

    [host retryAttach];
    if (host.isLive) {
        if (onAttached) onAttached();
        self.suppressLaunch = NO;
        return;
    }

    BOOL launchedSuspended = [self openApplicationSuspended:bundleID];
    BOOL usedForegroundFallback = !launchedSuspended;
    if (usedForegroundFallback) {
        [self.launchAllowlist addObject:bundleID];
        [self openApplicationForeground:bundleID];
    }
    NSLog(@"[DualPane] scene launch %@ suspended=%d", bundleID, launchedSuspended);

    __block dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                              dispatch_get_main_queue());
    __block NSUInteger attempts = 0;
    __block BOOL finished = NO;
    void (^finish)(BOOL) = ^(BOOL success) {
        if (finished) return;
        finished = YES;
        if (timer) {
            dispatch_source_cancel(timer);
            timer = nil;
        }

        __strong typeof(weakSelf) self2 = weakSelf;
        if (self2) {
            [self2.launchAllowlist removeObject:bundleID];
            self2.suppressLaunch = NO;
            if (usedForegroundFallback && self2.mode != DPPresentationModeNone) {
                [self2 scheduleHomeReturnForBundleID:bundleID delay:0.0];
            }
            [self2 bringOverlayToFront];
        }
        if (onAttached) onAttached();
        NSLog(@"[DualPane] scene attach %@ success=%d attempts=%@",
              bundleID, success, @(attempts));
    };

    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(0.25 * NSEC_PER_SEC),
                              (uint64_t)(0.03 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(timer, ^{
        if (finished) return;
        attempts += 1;
        __strong DPSceneHost *host2 = weakHost;
        if (!host2) {
            finish(NO);
            return;
        }
        [host2 retryAttach];
        if (host2.isLive) {
            finish(YES);
        } else if (attempts >= 12) {
            finish(NO);
        }
    });
    dispatch_resume(timer);
}

- (BOOL)openApplicationSuspended:(NSString *)bundleID {
    if (!bundleID.length) return NO;
    UIApplication *application = [UIApplication sharedApplication];
    SEL selector = NSSelectorFromString(@"launchApplicationWithIdentifier:suspended:");
    if (![application respondsToSelector:selector]) return NO;

    @try {
        NSMethodSignature *signature = [application methodSignatureForSelector:selector];
        if (!signature) return NO;
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        invocation.target = application;
        invocation.selector = selector;
        NSString *identifier = [bundleID copy];
        BOOL suspended = YES;
        [invocation setArgument:&identifier atIndex:2];
        [invocation setArgument:&suspended atIndex:3];
        [invocation invoke];

        if (signature.methodReturnLength == sizeof(BOOL)) {
            BOOL launched = NO;
            [invocation getReturnValue:&launched];
            return launched;
        }
        return YES;
    } @catch (NSException *e) {
        NSLog(@"[DualPane] suspended launch failed %@: %@", bundleID, e);
        return NO;
    }
}

- (void)openApplicationForeground:(NSString *)bundleID {
    if (!bundleID.length) return;

    // 优先 LSApplicationWorkspace
    Class LSApplicationWorkspace = NSClassFromString(@"LSApplicationWorkspace");
    if (LSApplicationWorkspace) {
        id workspace = ((id (*)(id, SEL))objc_msgSend)(LSApplicationWorkspace, @selector(defaultWorkspace));
        SEL sel = NSSelectorFromString(@"openApplicationWithBundleID:");
        if ([workspace respondsToSelector:sel]) {
            ((void (*)(id, SEL, id))objc_msgSend)(workspace, sel, bundleID);
            NSLog(@"[DualPane] openApplicationWithBundleID: %@", bundleID);
            return;
        }
    }

    // 兜底：SBUIController activateApplication
    Class SBUIController = NSClassFromString(@"SBUIController");
    Class SBAppController = NSClassFromString(@"SBApplicationController");
    if (SBUIController && SBAppController) {
        id ctrl = ((id (*)(id, SEL))objc_msgSend)(SBAppController, @selector(sharedInstance));
        id app = nil;
        SEL appSel = NSSelectorFromString(@"applicationWithBundleIdentifier:");
        if ([ctrl respondsToSelector:appSel]) {
            app = ((id (*)(id, SEL, id))objc_msgSend)(ctrl, appSel, bundleID);
        }
        id ui = ((id (*)(id, SEL))objc_msgSend)(SBUIController, @selector(sharedInstance));
        SEL act = NSSelectorFromString(@"activateApplication:");
        if (app && [ui respondsToSelector:act]) {
            ((void (*)(id, SEL, id))objc_msgSend)(ui, act, app);
            NSLog(@"[DualPane] activateApplication: %@", bundleID);
        }
    }
}

- (void)goHome {
    Class SBUIController = NSClassFromString(@"SBUIController");
    if (!SBUIController) return;
    id ui = ((id (*)(id, SEL))objc_msgSend)(SBUIController, @selector(sharedInstance));
    for (NSString *name in @[@"handleHomeButtonSinglePressUp", @"clickedMenuButton"]) {
        SEL sel = NSSelectorFromString(name);
        if ([ui respondsToSelector:sel]) {
            ((void (*)(id, SEL))objc_msgSend)(ui, sel);
            NSLog(@"[DualPane] 回桌面 via %@", name);
            break;
        }
    }
    [self bringOverlayToFront];
}

#pragma mark - Helpers

- (CGRect)initialFloatingFrameInBounds:(CGRect)bounds {
    CGRect last = [DPSettings shared].lastFloatingFrame;
    if (!CGRectIsNull(last) && !CGRectIsEmpty(last)) {
        last.size.width = MIN(last.size.width, bounds.size.width);
        last.size.height = MIN(last.size.height, bounds.size.height);
        last.origin.x = MIN(MAX(0, last.origin.x), MAX(0, bounds.size.width - last.size.width));
        last.origin.y = MIN(MAX(0, last.origin.y), MAX(0, bounds.size.height - last.size.height));
        return last;
    }
    CGSize size = [DPSettings shared].defaultFloatingSize;
    size.width = MIN(size.width, bounds.size.width - 24);
    size.height = MIN(size.height, bounds.size.height - 48);
    CGFloat x = bounds.size.width - size.width - 12;
    CGFloat y = MAX(48, (bounds.size.height - size.height) / 2.0);
    CGFloat stagger = self.mutableFloatingWindows.count * 24.0;
    return CGRectMake(x - stagger, y + stagger, size.width, size.height);
}

- (NSString *)foregroundBundleID {
    Class SBAppController = NSClassFromString(@"SBApplicationController");
    if (SBAppController) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id controller = [SBAppController performSelector:@selector(sharedInstance)];
#pragma clang diagnostic pop
        NSArray *sels = @[@"frontmostApplication", @"_frontMostApplication", @"focusedApplication"];
        for (NSString *name in sels) {
            SEL sel = NSSelectorFromString(name);
            if ([controller respondsToSelector:sel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                id app = [controller performSelector:sel];
#pragma clang diagnostic pop
                NSString *bid = [app valueForKey:@"bundleIdentifier"];
                if (bid.length) return bid;
            }
        }
    }
    return nil;
}

- (void)settingsChanged {
    if (![DPSettings shared].isEnabled) {
        [self dismissAllAnimated:YES];
    }
    for (DPFloatingWindow *w in self.mutableFloatingWindows) {
        w.contentOpacity = [DPSettings shared].floatingOpacity;
        w.cornerRadiusValue = [DPSettings shared].floatingCornerRadius;
        w.showsBorder = [DPSettings shared].showBorder;
    }
}

#pragma mark - Overlay consistency

// A live overlay with zero sessions is what left the home screen covered.
- (void)syncOverlayVisibility {
    if (!self.overlayWindow) return;
    BOOL hasSession = self.mutableFloatingWindows.count > 0;
    self.overlayWindow.hidden = !hasSession;
    self.overlayWindow.userInteractionEnabled = hasSession;
    if (!hasSession) {
        [self restorePreviousKeyWindow];
        [self.mutableHostedBundleIDs removeAllObjects];
        self.suppressLaunch = NO;
    }
}


#pragma mark - Keyboard avoidance

- (void)avoidKeyboardWithHeight:(CGFloat)height {
    DPFloatingWindow *w = self.focusedWindow;
    if (!w) return;
    CGRect screen = self.overlayRoot.bounds;
    if (height <= 1.0) {
        NSValue *v = self.frameBeforeKeyboard;
        self.frameBeforeKeyboard = nil;
        if (v) {
            w.frame = v.CGRectValue;
            [w layoutIfNeeded];
            [w commitSceneLayout];
        }
        return;
    }
    if (!self.frameBeforeKeyboard) self.frameBeforeKeyboard = [NSValue valueWithCGRect:w.frame];
    CGRect base = self.frameBeforeKeyboard.CGRectValue;
    CGFloat limit = screen.size.height - height - 8.0;
    CGRect f = base;
    if (f.size.height > limit) f.size.height = MAX(160.0, limit);
    if (CGRectGetMaxY(f) > limit) f.origin.y = MAX(0.0, limit - f.size.height);
    w.frame = f;
    [w layoutIfNeeded];
    [w commitSceneLayout];
    NSLog(@"[InteractivePiP] keyboard %.0f -> %@", height, NSStringFromCGRect(f));
}

@end
