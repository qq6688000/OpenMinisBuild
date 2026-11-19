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
@property (nonatomic, weak) DPFloatingWindow *focusedWindow;
@property (nonatomic, strong) UIView *splitDivider;
@property (nonatomic, strong) NSArray<DPFloatingWindow *> *splitWindows;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *savedFrames;
@property (nonatomic, assign) CGFloat splitRatio;
@property (nonatomic, assign) BOOL creatingSplit;
- (void)layoutSplit;
- (void)pairWindow:(DPFloatingWindow *)first withBundleID:(NSString *)bundleID;

- (void)openFloatingWithBundleID:(NSString *)bundleID reusingHost:(nullable DPSceneHost *)reusableHost;
- (void)makeOverlayKeyWindow;
- (void)ensureOverlayVisible;
- (void)restorePreviousKeyWindow;
- (id)sharedRemoteKeyboards;
- (void)configureRemoteKeyboardsForHostedInput:(BOOL)enabled;
@end

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
        _splitRatio = 0.5;
        _savedFrames = [NSMutableDictionary dictionary];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                  selector:@selector(settingsChanged)
                                                      name:kDPSettingsChangedNotification
                                                    object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                   selector:@selector(hostedKeyboardWillHide)
                                                       name:UIKeyboardWillHideNotification
                                                     object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                   selector:@selector(hostedKeyboardWillShow)
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

    NSLog(@"[InteractivePiP] 顶层窗口已安装 level=%.0f", win.windowLevel);
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

    if (mode == DPPresentationModeSplit) {
        DPFloatingWindow *first = self.mutableFloatingWindows.lastObject;
        if (first && ![first.bundleID isEqualToString:bundleID]) {
            [self pairWindow:first withBundleID:bundleID];
        } else {
            [self openFloatingWithBundleID:bundleID];
            DPFloatingWindow *target = self.mutableFloatingWindows.lastObject;
            if (target) [self requestSplitForWindow:target];
        }
    } else {
        [self openFloatingWithBundleID:bundleID];
    }
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
    [self handleActivationForBundleID:bundleID preferredMode:mode];
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

    if (self.splitWindows.count) [self leaveSplit];

    // 关键：先登记托管，再画 UI —— 阻止随后的全屏启动
    [self.mutableHostedBundleIDs addObject:bundleID];
    self.suppressLaunch = YES;

    NSInteger max = self.creatingSplit ? MAX(2, [DPSettings shared].maxFloatingWindows) : [DPSettings shared].maxFloatingWindows;
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
        [weakSelf focusWindow:w];
    };
    window.onSplit = ^(DPFloatingWindow *w) { [weakSelf requestSplitForWindow:w]; };
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

    NSLog(@"[InteractivePiP] 打开悬浮窗 %@", bundleID);
}



- (void)closeFloatingWindow:(DPFloatingWindow *)window animated:(BOOL)animated {
    if (!window) return;
    if ([self.splitWindows containsObject:window]) [self leaveSplit];
    if (self.focusedWindow == window) self.focusedWindow = nil;
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
}

- (void)dismissAllAnimated:(BOOL)animated {
    [self leaveSplit];
    NSArray *copy = [self.mutableFloatingWindows copy];
    for (DPFloatingWindow *w in copy) {
        [self closeFloatingWindow:w animated:animated];
    }
    self.mode = DPPresentationModeNone;
    self.suppressLaunch = NO;
    [self.mutableHostedBundleIDs removeAllObjects];
    [self restorePreviousKeyWindow];
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

- (void)configureRemoteKeyboardsForHostedInput:(BOOL)enabled {
    id keyboards = [self sharedRemoteKeyboards];
    if (!keyboards) return;

    @try {
        SEL setSuppressing = NSSelectorFromString(@"setSuppressingKeyboard:");
        if ([keyboards respondsToSelector:setSuppressing]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(keyboards, setSuppressing, !enabled);
        }
    } @catch (__unused NSException *exception) {}

    @try {
        SEL setWindowEnabled = NSSelectorFromString(@"setWindowEnabled:");
        if ([keyboards respondsToSelector:setWindowEnabled]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(keyboards, setWindowEnabled, enabled);
        }
    } @catch (__unused NSException *exception) {}

    if (enabled) {
        @try {
            SEL setCurrentKeyboard = NSSelectorFromString(@"setCurrentKeyboard:");
            if ([keyboards respondsToSelector:setCurrentKeyboard]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(keyboards, setCurrentKeyboard, YES);
            }
        } @catch (__unused NSException *exception) {}

        @try {
            SEL prepareHosted = NSSelectorFromString(@"prepareForHostedWindow");
            if ([keyboards respondsToSelector:prepareHosted]) {
                ((id (*)(id, SEL))objc_msgSend)(keyboards, prepareHosted);
            }
        } @catch (__unused NSException *exception) {}

        @try {
            SEL clean = NSSelectorFromString(@"cleanSuppression");
            if ([keyboards respondsToSelector:clean]) {
                ((void (*)(id, SEL))objc_msgSend)(keyboards, clean);
            }
        } @catch (__unused NSException *exception) {}
    } else {
        @try {
            SEL finishHosted = NSSelectorFromString(@"finishWithHostedWindow");
            if ([keyboards respondsToSelector:finishHosted]) {
                ((void (*)(id, SEL))objc_msgSend)(keyboards, finishHosted);
            }
        } @catch (__unused NSException *exception) {}
    }
}

- (void)prepareForHostedInput {
    if (!self.overlayWindow || self.overlayWindow.hidden) return;
    // Keep DualPane chrome above SpringBoard, but do not permanently steal the
    // keyboard arbiter from third-party IMEs such as WeChat Keyboard.
    [self ensureOverlayVisible];
    [self configureRemoteKeyboardsForHostedInput:YES];
    DPFloatingWindow *window = self.focusedWindow ?: self.mutableFloatingWindows.lastObject;
    [window.sceneHost prepareForInput];
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

- (void)hostedKeyboardWillShow {
    if (self.mode != DPPresentationModeNone) {
        [self prepareForHostedInput];
    }
}

- (void)hostedKeyboardWillHide {
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
    if (self.splitWindows.count == 2) [self layoutSplit];
    [self bringOverlayToFront];
}


#pragma mark - Interactive split

- (void)focusWindow:(DPFloatingWindow *)window {
    if (![self.mutableFloatingWindows containsObject:window]) return;
    self.focusedWindow = window;
    for (DPFloatingWindow *other in self.mutableFloatingWindows) {
        [other setActive:(other == window) animated:NO];
    }
    [self prepareForHostedInput];
    [self bringOverlayToFront];
    if (self.splitDivider) [self.overlayRoot bringSubviewToFront:self.splitDivider];
}

- (void)requestSplitForWindow:(DPFloatingWindow *)window {
    if (self.splitWindows.count) { [self leaveSplit]; return; }
    if (![self.mutableFloatingWindows containsObject:window]) return;
    __weak typeof(self) weakSelf = self;
    [self presentAppPickerWithCompletion:^(NSString *bundleID) {
        if (bundleID.length && ![bundleID isEqualToString:window.bundleID])
            [weakSelf pairWindow:window withBundleID:bundleID];
    }];
}

- (void)pairWindow:(DPFloatingWindow *)first withBundleID:(NSString *)bundleID {
    if (!first || !bundleID.length || [first.bundleID isEqualToString:bundleID]) return;
    if ([[DPSettings shared] isBundleBlacklisted:bundleID]) return;
    [self leaveSplit];
    // Make room without evicting the chosen first app when max windows is 1.
    for (DPFloatingWindow *w in [self.mutableFloatingWindows copy]) {
        if (w != first && ![w.bundleID isEqualToString:bundleID])
            [self closeFloatingWindow:w animated:NO];
    }
    self.creatingSplit = YES;
    [self openFloatingWithBundleID:bundleID];
    self.creatingSplit = NO;
    DPFloatingWindow *second = nil;
    for (DPFloatingWindow *w in self.mutableFloatingWindows)
        if ([w.bundleID isEqualToString:bundleID]) second = w;
    if (!second || ![self.mutableFloatingWindows containsObject:first]) return;
    self.splitWindows = @[first, second];
    for (DPFloatingWindow *w in self.splitWindows) {
        [w.layer removeAllAnimations];
        w.alpha = 1;
        w.transform = CGAffineTransformIdentity;
        self.savedFrames[w.bundleID] = [NSValue valueWithCGRect:w.frame];
        w.tiled = YES;
    }
    UIView *divider = [[UIView alloc] initWithFrame:CGRectZero];
    divider.backgroundColor = [UIColor colorWithWhite:0.16 alpha:1];
    divider.layer.cornerRadius = 8;
    divider.accessibilityLabel = @"拖动调整分屏比例，双击退出分屏";
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(moveDivider:)];
    [divider addGestureRecognizer:pan];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(leaveSplit)];
    tap.numberOfTapsRequired = 2;
    [divider addGestureRecognizer:tap];
    self.splitDivider = divider;
    [self.overlayRoot addSubview:divider];
    self.mode = DPPresentationModeSplit;
    [self layoutSplit];
    [self focusWindow:second];
}

- (void)layoutSplit {
    if (self.splitWindows.count != 2) return;
    CGRect b = self.overlayRoot.bounds;
    UIEdgeInsets insets = self.overlayRoot.safeAreaInsets;
    b = UIEdgeInsetsInsetRect(b, UIEdgeInsetsMake(MAX(24,insets.top),MAX(4,insets.left),MAX(8,insets.bottom),MAX(4,insets.right)));
    BOOL horizontal = b.size.width > b.size.height;
    CGFloat total = horizontal ? b.size.width : b.size.height;
    CGFloat first = floor((total - 24) * self.splitRatio);
    CGRect a = b, c = b, d = b;
    if (horizontal) {
        a.size.width = first;
        d.origin.x = CGRectGetMaxX(a); d.size.width = 24;
        c.origin.x = CGRectGetMaxX(d); c.size.width = total-first-24;
    } else {
        a.size.height = first;
        d.origin.y = CGRectGetMaxY(a); d.size.height = 24;
        c.origin.y = CGRectGetMaxY(d); c.size.height = total-first-24;
    }
    self.splitWindows[0].frame = a;
    self.splitWindows[1].frame = c;
    self.splitDivider.frame = d;
    for (DPFloatingWindow *w in self.splitWindows) { [w layoutIfNeeded]; [w commitSceneLayout]; }
    [self.overlayRoot bringSubviewToFront:self.splitDivider];
}

- (void)moveDivider:(UIPanGestureRecognizer *)pan {
    CGRect b = self.overlayRoot.bounds;
    UIEdgeInsets i = self.overlayRoot.safeAreaInsets;
    b = UIEdgeInsetsInsetRect(b, UIEdgeInsetsMake(MAX(24,i.top),MAX(4,i.left),MAX(8,i.bottom),MAX(4,i.right)));
    CGPoint p = [pan locationInView:self.overlayRoot];
    BOOL horizontal = b.size.width > b.size.height;
    CGFloat total = (horizontal ? b.size.width : b.size.height) - 24;
    CGFloat pos = (horizontal ? p.x-b.origin.x : p.y-b.origin.y)-12;
    if (total > 0) self.splitRatio = MIN(0.7, MAX(0.3, pos/total));
    [self layoutSplit];
}

- (void)leaveSplit {
    for (DPFloatingWindow *w in self.splitWindows) {
        w.tiled = NO;
        NSValue *v = self.savedFrames[w.bundleID];
        if (v) w.frame = v.CGRectValue;
        [w layoutIfNeeded]; [w commitSceneLayout];
    }
    [self.splitDivider removeFromSuperview]; self.splitDivider = nil;
    self.splitWindows = nil; [self.savedFrames removeAllObjects];
    self.mode = self.mutableFloatingWindows.count ? DPPresentationModeFloating : DPPresentationModeNone;
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
    NSLog(@"[InteractivePiP] scene launch %@ suspended=%d", bundleID, launchedSuspended);

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
        NSLog(@"[InteractivePiP] scene attach %@ success=%d attempts=%@",
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
        NSLog(@"[InteractivePiP] suspended launch failed %@: %@", bundleID, e);
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
            NSLog(@"[InteractivePiP] openApplicationWithBundleID: %@", bundleID);
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
            NSLog(@"[InteractivePiP] activateApplication: %@", bundleID);
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
            NSLog(@"[InteractivePiP] 回桌面 via %@", name);
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

@end
