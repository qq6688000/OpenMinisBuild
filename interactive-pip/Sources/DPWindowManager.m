#import "DPWindowManager.h"
#import "DPFloatingWindow.h"
#import "DPSceneHost.h"
#import "DPAppPicker.h"
#import "DPEdgeShelfWindow.h"
#import "DPSettings.h"
#import "DPPassthroughWindow.h"
#import <objc/message.h>
#import <objc/runtime.h>

// ============ DPGroupPageView ============
// Switcher 卡内容视图。SpringBoard 对 pageContentViewForAppLayout: 的返回对象
// 会发 setActive:/appLayout 等协议消息；继承 UIView 保证 addSubview 可用，
// 消息转发兜底保证任何未知协议消息都不崩（0.7.2 安全模式根因）。
@interface DPGroupPageView : UIView
@property (nonatomic, strong, nullable) id appLayout;
@end

@implementation DPGroupPageView
- (void)setActive:(BOOL)active { }
- (void)setAppLayout:(id)layout { _appLayout = layout; }
- (void)prepareForReuse { }
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    NSMethodSignature *s = [super methodSignatureForSelector:sel];
    if (s) return s;
    // 返回一个通用的 "@@:" 签名（id, self, _cmd），让未知消息不崩
    return [NSMethodSignature signatureWithObjCTypes:"@@:"];
}
- (void)forwardInvocation:(NSInvocation *)invocation { }
@end

@interface DPWindowManager ()
@property (nonatomic, strong, nullable) DPPassthroughWindow *overlayWindow;
@property (nonatomic, strong) DPPassthroughView *overlayRoot;
@property (nonatomic, strong, nullable) UILabel *diagLabel;
/// `prepareForHostedWindowWithScene:` 返回的键盘宿主窗口。必须保留，否则 ARC 释放，
/// 系统 `keyboardWindow` 就变 nil，键盘永远不出现。
@property (nonatomic, strong, nullable) id hostedKeyboardWindow;
/// 缓存的 _UIRemoteKeyboards 实例（用类方法表自动发现工厂，不再猜名）。
@property (nonatomic, strong, nullable) id remoteKeyboardsInstance;
/// 类方法表里真正返回对象的那个工厂 selector，探到一次就记住。
@property (nonatomic, assign) SEL remoteKeyboardsFactory;
@property (nonatomic, strong, readwrite) NSMutableArray<DPFloatingWindow *> *mutableFloatingWindows;
@property (nonatomic, assign, readwrite) DPPresentationMode mode;
@property (nonatomic, strong, nullable) DPAppPicker *picker;
@property (nonatomic, strong, nullable) UIWindow *prePickerKeyWindow;
@property (nonatomic, assign) BOOL lastLandscapeState;
@property (nonatomic, assign) BOOL lastLandscapeKnown;
@property (nonatomic, assign) BOOL watchingDeviceOrientation; // 0.7.126: picker search needs a key window
@property (nonatomic, strong) NSMutableSet<NSString *> *mutableHostedBundleIDs;
@property (nonatomic, strong) NSMutableSet<NSString *> *launchAllowlist; // 临时允许全屏一次
@property (nonatomic, assign) BOOL suppressLaunch;
@property (nonatomic, assign) BOOL homeReturnPending;
@property (nonatomic, copy, nullable) NSString *pendingHomeBundleID;
@property (nonatomic, weak, nullable) UIWindow *keyWindowBeforeHostedInput;
@property (nonatomic, assign) BOOL hostedInputActive;
@property (nonatomic, weak, nullable) DPFloatingWindow *keyboardRoutedWindow;
@property (nonatomic, weak, nullable) DPFloatingWindow *focusedWindow;
@property (nonatomic, assign) BOOL deviceLocked;
@property (nonatomic, assign) BOOL sessionParked;
@property (nonatomic) BOOL floatingHiddenOnHome;
@property (nonatomic, strong, nullable) DPEdgeShelfWindow *edgeShelf;
@property (nonatomic, copy) NSArray *shelfThumbnails;
@property (nonatomic) NSUInteger shelfWindowCount;
@property (nonatomic) BOOL homeGestureSettling;
@property (nonatomic, copy, nullable) NSString *pvPendingFirstBundleID; // 0.7.178: PV式全屏分屏待命的第一个App
@property (nonatomic) BOOL pvSplitGestureArmed; // 上滑手势是否已就绪（前台是我们的App）
@property (nonatomic, strong, nullable) NSTimer *floatingHomeTimer;
- (void)hideFloatingOnHome;
@property (nonatomic, strong, nullable) id activeSwitcherCard;
@property (nonatomic, copy, nullable) NSString *switcherBuildStatus;
@property (nonatomic, weak, nullable) id switcherContentController;
@property (nonatomic) BOOL switcherRefreshScheduled;
@property (nonatomic) NSUInteger switcherPreviewRefreshGeneration;
@property (nonatomic) NSUInteger switcherGestureEpoch;
@property (nonatomic) BOOL switcherRestorePending;
@property (nonatomic) NSTimeInterval switcherRestoreGraceUntil;
@property (nonatomic, copy, nullable) NSString *switcherGroupIdentifier;
@property (nonatomic, weak, nullable) UIWindowScene *switcherHomeScene;
- (void)finishSwitcherRestore:(NSUInteger)epoch card:(id)card deadline:(NSTimeInterval)deadline;
@property (nonatomic, copy, nullable) NSString *switcherTapStatus;
@property (nonatomic, copy, nullable) NSArray *switcherPaneImages;
- (void)captureSwitcherPaneImages;
@property (nonatomic, copy, nullable) NSString *switcherRefreshStatus;
- (void)createSwitcherGroupCard;
- (void)requestSwitcherGroupRefresh;
@property (nonatomic, strong) UIView *splitDivider;
@property (nonatomic, strong) UIStackView *sessionControls;
@property (nonatomic, strong) UIButton *leaveSplitButton;
@property (nonatomic, assign) NSUInteger sessionGeneration;
@property (nonatomic, assign) BOOL internalHomeReturn;
@property (nonatomic, strong) NSArray<DPFloatingWindow *> *splitWindows;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *savedFrames;
@property (nonatomic, assign) CGFloat splitRatio;
@property (nonatomic, assign) BOOL duoMode;
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

static BOOL DPDuoSystemSwitcherVisible(void) {
    for (NSString *name in @[@"SBMainSwitcherControllerCoordinator", @"SBMainSwitcherViewController"]) {
        Class cls = NSClassFromString(name);
        SEL shared = @selector(sharedInstance);
        if (!cls || ![cls respondsToSelector:shared]) continue;
        id controller = ((id (*)(id, SEL))objc_msgSend)(cls, shared);
        if (!controller) continue;
        for (NSString *key in @[@"isMainSwitcherVisible", @"isAnySwitcherVisible"]) {
            SEL sel = NSSelectorFromString(key);
            NSMethodSignature *sig = [controller methodSignatureForSelector:sel];
            const char *type = sig.methodReturnType;
            if (sig.numberOfArguments == 2 && type && (type[0] == 'B' || type[0] == 'c') &&
                ((BOOL (*)(id, SEL))objc_msgSend)(controller, sel)) return YES;
        }
    }
    return NO;
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
    if (self.overlayWindow) {
        // Reuse the existing window, hidden or not. Creating a second window
        // here orphans the old one together with every hosted scene in it.
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

    win.windowLevel = UIWindowLevelStatusBar + 90.0;
    win.backgroundColor = [UIColor clearColor];
    // Start hidden: an empty overlay must never cover home or lock screen.
    win.hidden = YES;

    UIViewController *rootVC = [[UIViewController alloc] init];
    DPPassthroughView *root = [[DPPassthroughView alloc] initWithFrame:win.bounds];
    root.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    root.backgroundColor = [UIColor clearColor];
    rootVC.view = root;
    win.rootViewController = rootVC;

    self.overlayWindow = win;
    self.overlayRoot = root;

    NSLog(@"[InteractivePiP] 顶层窗口已安装 level=%.0f", win.windowLevel);
    [self startWatchingDeviceOrientation];
    CGRect rb = self.overlayRoot.bounds;
    self.lastLandscapeKnown = YES;
    self.lastLandscapeState = (rb.size.width > rb.size.height);
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
    if (self.deviceLocked) return;
    // While parked in the app switcher, passive foreground callbacks must not
    // yank the session back. Only an explicit activation restores it.
    if (self.floatingHiddenOnHome) return;
    if (self.sessionParked) return;
    // Never resurrect a chrome-only overlay: it covers the home screen with
    // nothing inside, which is exactly the "stuck on split screen" symptom.
    if (self.mutableFloatingWindows.count == 0) {
        self.overlayWindow.hidden = YES;
        [self updateSessionControls];
        return;
    }
    [self updateSessionControls];
    if (!self.overlayWindow) {
        [self install];
        return;
    }
    self.overlayWindow.windowLevel = UIWindowLevelStatusBar + 90.0;
    // 重新挂到当前 scene（切 App 后 scene 可能变）
    if (@available(iOS 13.0, *)) {
        UIWindowScene *saved = self.switcherHomeScene;
        UIWindowScene *scene = self.switcherRestorePending && saved.activationState == UISceneActivationStateForegroundActive && saved ? saved : [self activeWindowScene];
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

    // 0.7.179: 通用入口也走 PV式全屏分屏 —— 选 App 后全屏打开，上滑到顶再选第二个。
    __weak typeof(self) weakSelf = self;
    [self presentAppPickerWithCompletion:^(NSString *bundleID) {
        typeof(weakSelf) s = weakSelf;
        if (!s || !bundleID.length) return;
        [s startPVFullscreenSplitForBundleID:bundleID];
    }];
}

- (void)handleActivationForBundleID:(NSString *)bundleID {
    [self handleActivationForBundleID:bundleID preferredMode:DPPresentationModeNone];
}

- (void)handleActivationForBundleID:(NSString *)bundleID preferredMode:(DPPresentationMode)mode {
    if (self.deviceLocked) return;
    if (![DPSettings shared].isEnabled) return;
    if (!bundleID.length) {
        [self handleActivationRequest];
        return;
    }
    if ([[DPSettings shared] isBundleBlacklisted:bundleID]) return;

    [self.floatingHomeTimer invalidate]; self.floatingHomeTimer = nil;
    self.floatingHiddenOnHome = NO;
    self.edgeShelf.hidden = YES;
    if (self.sessionParked) [self restoreParkedSession];
    [self install];

    // 0.7.178: 统一入口改为 PV式全屏分屏 —— 全屏启动 App，上滑到顶再选第二个。
    [self startPVFullscreenSplitForBundleID:bundleID];
}

- (void)presentAppPickerWithCompletion:(void (^)(NSString * _Nullable))completion {
    if (self.picker) {
        [self.picker dismissAnimated:NO];
        self.picker = nil;
    }
    [self install];
    [self bringOverlayToFront];
    // 0.7.183: 系统分屏模式下没有浮窗，bringOverlayToFront 会因为 count==0 把 overlay 隐藏，
    // 导致 picker 弹不出来（"卡住"）。这里强制把它拉起来。
    if (self.overlayWindow) {
        self.overlayWindow.hidden = NO;
        self.overlayWindow.windowLevel = UIWindowLevelStatusBar + 90.0;
        if (@available(iOS 13.0, *)) {
            UIWindowScene *scene = [self activeWindowScene];
            if (scene && self.overlayWindow.windowScene != scene) {
                self.overlayWindow.windowScene = scene;
                self.overlayWindow.frame = scene.coordinateSpace.bounds;
                self.overlayRoot.frame = self.overlayWindow.bounds;
            }
        }
    }
    UIViewController *host = self.overlayWindow.rootViewController;
    if (!host) { NSLog(@"[InteractivePiP] picker: no host VC"); if (completion) completion(nil); return; }

    // 0.7.127: mount the picker in a MODALLY PRESENTED view controller. Hanging it
    // straight on our passthrough window makes it first responder but the system
    // never routes a keyboard to that window, which is why the caret appeared and
    // nothing else happened. A modal presentation gets a proper input context.
    UIViewController *modal = [[UIViewController alloc] init];
    modal.view.backgroundColor = [UIColor clearColor];
    modal.modalPresentationStyle = UIModalPresentationOverFullScreen;
    modal.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;

    self.picker = [[DPAppPicker alloc] init];
    __weak typeof(self) weakSelf = self;
    [host presentViewController:modal animated:NO completion:^{
        typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.picker) return;
        [strongSelf.picker presentInView:modal.view
                               favorites:[DPSettings shared].favorites
                               blacklist:[DPSettings shared].blacklist
                              completion:^(NSString *bundleID) {
            typeof(weakSelf) s2 = weakSelf;
            if (s2) {
                s2.picker = nil;
                [modal dismissViewControllerAnimated:NO completion:nil];
                [s2 restorePrePickerKeyWindow];
            }
            if (completion) completion(bundleID);
        }];
    }];
}

// 0.7.126: key-window juggling for the app picker's search field.
- (UIWindow *)currentKeyWindow {
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow) return w;
    }
    return nil;
}

- (void)restorePrePickerKeyWindow {
    UIWindow *saved = self.prePickerKeyWindow;
    self.prePickerKeyWindow = nil;
    if (saved && !saved.isHidden) {
        [saved makeKeyWindow];
    }
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
            [existing.sceneHost setSuspended:NO];   // resume after lightweight home/lock exit
            [existing bringToFront];
            if (!existing.sceneHost.isLive) [existing.sceneHost retryAttach];
            [self bringOverlayToFront];
            return;
        }
    }

    // Only leave the split when a third, unrelated app is opened.
    if (self.splitWindows.count && !self.creatingSplit) [self leaveSplit];

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
    // 0.7.180: 上滑到顶松手 → 该 App 直接铺成上半屏，再选第二个填下半屏。
    // 必须在这里统一挂，不能只在 beginDragToKeepForWindow 里挂（那条路径已废弃）。
    window.onSwipeUpToIsland = ^(DPFloatingWindow *w) {
        typeof(weakSelf) s = weakSelf;
        if (!s || !w) return;
        [s createTopHalfWithBundleID:w.bundleID];
    };
    window.onFrameChanged = ^(DPFloatingWindow *w, CGRect f) {
        [[DPSettings shared] setLastFloatingFrame:f];
        (void)w;
    };

    [parent addSubview:window];
    [self.mutableFloatingWindows addObject:window];
    if (self.focusedWindow != window) [self restorePreviousKeyWindow];
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
    if (self.focusedWindow == window) { [self restorePreviousKeyWindow]; self.focusedWindow = nil; }
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
    [self updateSessionControls];
}

- (void)dismissAllAnimated:(BOOL)animated {
    self.sessionGeneration += 1;
    self.sessionParked = NO;
    self.overlayRoot.transform = CGAffineTransformIdentity;
    self.overlayWindow.windowLevel = UIWindowLevelStatusBar + 90.0;
    self.pendingHomeBundleID = nil; self.homeReturnPending = NO;
    [self.launchAllowlist removeAllObjects];
    [self leaveSplit];
    NSArray *copy = [self.mutableFloatingWindows copy];
    for (DPFloatingWindow *w in copy) {
        [self closeFloatingWindow:w animated:animated];
    }
    self.mode = DPPresentationModeNone;
    self.suppressLaunch = NO;
    [self.mutableHostedBundleIDs removeAllObjects];
    [self restorePreviousKeyWindow];
    [self updateSessionControls];
    self.overlayWindow.hidden = YES;
}

- (id)sharedRemoteKeyboards {
    if (self.remoteKeyboardsInstance) return self.remoteKeyboardsInstance;
    Class remoteClass = NSClassFromString(@"_UIRemoteKeyboards");
    if (!remoteClass) return nil;

    // Preferred: the canonical singleton accessor. The 0.7.7 diagnostics panel
    // proved `+sharedRemoteKeyboards` exists and returns an instance on this
    // build, so try it first before any generic discovery.
    SEL shared = NSSelectorFromString(@"sharedRemoteKeyboards");
    if ([remoteClass respondsToSelector:shared]) {
        @try {
            id inst = ((id (*)(id, SEL))objc_msgSend)(remoteClass, shared);
            NSLog(@"[InteractivePiP] _UIRemoteKeyboards +sharedRemoteKeyboards -> %@", inst);
            if (inst) {
                self.remoteKeyboardsInstance = inst;
                self.remoteKeyboardsFactory = shared;
                return inst;
            }
        } @catch (__unused NSException *exception) {}
    }

    // Fallback: enumerate the CLASS method list (meta class). `+sharedRemoteKeyboards`
    // is a class method, so it lives in the metaclass method table, not the
    // instance table. Pick any id-returning factory.
    Class metaClass = object_getClass(remoteClass);
    unsigned metaCount = 0;
    Method *meta = metaClass ? class_copyMethodList(metaClass, &metaCount) : NULL;
    if (meta) {
        for (unsigned i = 0; i < metaCount; i++) {
            const char *name = sel_getName(method_getName(meta[i]));
            if (!name) continue;
            NSString *ns = [NSString stringWithUTF8String:name];
            BOOL factoryName = [ns containsString:@"hared"] || [ns containsString:@"nstance"];
            const char *types = method_getTypeEncoding(meta[i]);
            BOOL returnsObject = types && (types[0] == '@');
            if (!factoryName && !returnsObject) continue;
            @try {
                id inst = ((id (*)(id, SEL))objc_msgSend)(remoteClass, method_getName(meta[i]));
                NSLog(@"[InteractivePiP] _UIRemoteKeyboards 工厂 %@ -> %s (%@)", name, types ? types : "-", inst);
                if (inst) {
                    self.remoteKeyboardsInstance = inst;
                    self.remoteKeyboardsFactory = method_getName(meta[i]);
                    break;
                }
            } @catch (__unused NSException *exception) {}
        }
        free(meta);
    }
    if (!self.remoteKeyboardsInstance) {
        NSLog(@"[InteractivePiP] _UIRemoteKeyboards 没有找到实例工厂方法");
    }
    return self.remoteKeyboardsInstance;
}

- (Class)remoteKeyboardsClass {
    return NSClassFromString(@"_UIRemoteKeyboards");
}

- (void)configureRemoteKeyboardsForHostedInput:(BOOL)enabled {
    id kb = [self sharedRemoteKeyboards];
    if (!kb) return;

    if (!enabled) {
        SEL fin = NSSelectorFromString(@"finishWithHostedWindow");
        if ([kb respondsToSelector:fin]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(kb, fin); } @catch (__unused NSException *e) {}
        }
        self.hostedInputActive = NO;
        self.keyboardRoutedWindow = nil;
        return;
    }

    DPFloatingWindow *target = self.focusedWindow;
    if (!target || self.deviceLocked) return;
    if (self.hostedInputActive && self.keyboardRoutedWindow == target) return;

    UIView *host = [target.sceneHost keyboardRoutingView];
    id fs = [target.sceneHost keyboardRoutingScene];
    // `prepareForHostedWindowWithScene:` expects a UIWindowScene, NOT an FBScene.
    // Try the FBScene's own uiWindowScene first (most correct), then fall back to
    // the hosted window's actual UIWindowScene (SBSystemApertureCurtainWindowScene).
    id scene = nil;
    if (fs) {
        SEL su = NSSelectorFromString(@"uiWindowScene");
        if ([fs respondsToSelector:su]) {
            @try { scene = ((id (*)(id, SEL))objc_msgSend)(fs, su); } @catch (__unused NSException *e) {}
        }
    }
    if (!scene) scene = host.window.windowScene ?: self.overlayWindow.windowScene ?: fs;
    int pid = [target.sceneHost keyboardRoutingPID];
    if (!host || !scene || pid <= 0) {
        NSLog(@"[InteractivePiP] 无场景宿主，跳过键盘登记 %@", target.bundleID);
        self.hostedInputActive = NO;
        return;
    }

    @try {
        // The scene-aware prep may throw if the hosted scene is not in a state
        // the system accepts. It must NEVER abort the registration: split every
        // call into its own try so one failure cannot skip the actual
        // `addHostedWindowView:` registration below.
        SEL prep = NSSelectorFromString(@"prepareForHostedWindowWithScene:");
        if ([kb respondsToSelector:prep]) {
            @try {
                // This returns the hosted keyboard window. Retain it: if the
                // reference is dropped, ARC releases the window and the system's
                // `keyboardWindow` goes nil — the keyboard never appears.
                id prepWin = ((id (*)(id, SEL, id))objc_msgSend)(kb, prep, scene);
                if (prepWin) {
                    self.hostedKeyboardWindow = prepWin;
                    NSLog(@"[InteractivePiP] 键盘 prep 成功 scene=%@ win=%@", scene, prepWin);
                } else {
                    NSLog(@"[InteractivePiP] 键盘 prep 返回 nil scene=%@", scene);
                }
            } @catch (__unused NSException *prepEx) {
                NSLog(@"[InteractivePiP] 键盘 prep 异常(继续登记): %@", prepEx);
            }
        }

        SEL add = NSSelectorFromString(@"addHostedWindowView:fromPID:forScene:");
        if ([kb respondsToSelector:add]) {
            @try {
                ((void (*)(id, SEL, id, int, id))objc_msgSend)(kb, add, host, pid, scene);
                NSLog(@"[InteractivePiP] 键盘 addHostedWindowView 已调用 pid=%d scene=%@", pid, scene);
            } @catch (__unused NSException *addEx) {
                NSLog(@"[InteractivePiP] 键盘 add 异常: %@", addEx);
            }
        } else {
            NSLog(@"[InteractivePiP] 无 addHostedWindowView:fromPID:forScene: 方法");
        }

        // After addHostedWindowView:, the system needs finishWithHostedWindow
        // (no-arg, confirmed on panel: v16@0:8) to complete the hosted window
        // setup and start rendering the keyboard content layer. Without it the
        // window exists but the content area stays empty.
        SEL finish = NSSelectorFromString(@"finishWithHostedWindow");
        if ([kb respondsToSelector:finish]) {
            @try {
                ((void (*)(id, SEL))objc_msgSend)(kb, finish);
                NSLog(@"[InteractivePiP] 键盘 finishWithHostedWindow 已调用");
            } @catch (__unused NSException *finEx) {
                NSLog(@"[InteractivePiP] 键盘 finish 异常: %@", finEx);
            }
        } else {
            NSLog(@"[InteractivePiP] 无 finishWithHostedWindow 方法");
        }

        SEL enable = NSSelectorFromString(@"setWindowEnabled:");
        if ([kb respondsToSelector:enable]) {
            @try {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(kb, enable, YES);
                NSLog(@"[InteractivePiP] 键盘 setWindowEnabled:YES");
            } @catch (__unused NSException *enEx) {
                NSLog(@"[InteractivePiP] 键盘 enable 异常: %@", enEx);
            }
        }

        self.hostedInputActive = YES;
        self.keyboardRoutedWindow = target;
        NSLog(@"[InteractivePiP] 键盘登记完成 %@ pid=%d scene=%@", target.bundleID, pid, scene);
    } @catch (NSException *e) {
        NSLog(@"[InteractivePiP] 键盘登记异常 %@: %@", target.bundleID, e);
        self.hostedInputActive = NO;
    }
}

- (void)attemptKeyboardScenePairingWithScene:(id)scene host:(UIView *)host {
    // A hosted input view lives inside OUR overlay window, so the system never
    // pairs the keyboard input scene with it on its own. PanoramicView leases one
    // via `ui_inputScenePairing`. Probe the candidate receivers and only invoke
    // a pairing method whose type encoding proves it is a void setter — a wrong
    // signature can therefore never crash us. Read-only probes also log the
    // pairing methods each candidate actually exposes, which tells us the real
    // spelling on this iOS build.
    NSSet *candidates = [NSSet setWithArray:@[
        (id)self.overlayWindow ?: (id)[NSNull null],
        (id)self.overlayWindow.windowScene ?: (id)[NSNull null],
        (id)self.overlayRoot ?: (id)[NSNull null],
        (id)host ?: (id)[NSNull null],
        (id)scene ?: (id)[NSNull null],
    ]];
    for (id obj in candidates) {
        if (!obj || [obj isKindOfClass:[NSNull class]]) continue;
        Class c = [obj class];
        unsigned count = 0;
        Method *methods = class_copyMethodList(c, &count);
        if (!methods) continue;
        for (unsigned i = 0; i < count; i++) {
            SEL sel = method_getName(methods[i]);
            const char *name = sel_getName(sel);
            if (!name) continue;
            NSString *ns = [NSString stringWithUTF8String:name];
            BOOL interesting = [ns containsString:@"airing"] ||
                               [ns containsString:@"nputScene"] ||
                               [ns containsString:@"Keyboards"];
            if (!interesting) continue;
            const char *types = method_getTypeEncoding(methods[i]);
            NSLog(@"[InteractivePiP] 配对候选 %@ -> %s (%s)", NSStringFromClass(c), name, types ? types : "-");
            // Only touch void-returning setters; a getter invocation has no
            // side effect, and a non-void setter with the wrong arity would be
            // unsafe to guess.
            if (!types || types[0] != 'v') continue;
            if (![obj respondsToSelector:sel]) continue;
            @try {
                ((void (*)(id, SEL, id))objc_msgSend)(obj, sel, scene);
                NSLog(@"[InteractivePiP] 键盘 scene 配对已调用 %@.%s", NSStringFromClass(c), name);
            } @catch (__unused NSException *exception) {
            }
        }
        free(methods);
    }
}

- (void)attemptRemoteKeyboardsRegistration:(id)kb host:(UIView *)host pid:(int)pid scene:(id)scene {
    if (!kb) return;
    // Exact spelling wins: the diagnostics panel proved this selector exists on
    // this build. Trusting the exact name is what turns a silent no-op into a
    // real registration.
    SEL add = NSSelectorFromString(@"addHostedWindowView:fromPID:forScene:");
    if ([kb respondsToSelector:add]) {
        @try {
            ((void (*)(id, SEL, id, int, id))objc_msgSend)(kb, add, host, pid, scene);
            NSLog(@"[InteractivePiP] 远程键盘登记已调用 addHostedWindowView:fromPID:forScene: pid=%d scene=%@", pid, scene);
            return;
        } @catch (__unused NSException *exception) {
        }
    }
    // Generic fallback: any void setter whose encoding is (object, int, object).
    Class c = [kb class];
    unsigned count = 0;
    Method *methods = class_copyMethodList(c, &count);
    if (!methods) return;
    for (unsigned i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        const char *types = method_getTypeEncoding(methods[i]);
        if (!types || types[0] != 'v') continue;
        NSString *args = [NSString stringWithUTF8String:types + 3];
        // An object, then a scalar integer pid, then an object.
        if ([args length] < 3) continue;
        if ([args characterAtIndex:0] != '@') continue;
        unichar mid = [args characterAtIndex:1];
        BOOL isInt = (mid == 'i' || mid == 'q' || mid == 'Q' || mid == 'I');
        if (!isInt) continue;
        @try {
            ((void (*)(id, SEL, id, int, id))objc_msgSend)(kb, sel, host, pid, scene);
            NSLog(@"[InteractivePiP] 远程键盘登记已调用 %s (%s)", sel_getName(sel), types);
        } @catch (__unused NSException *exception) {
        }
    }
    free(methods);
}

- (void)showKeyboardDiagnostics {
    // 0.7.125: on-screen diagnostic panel removed. NSLog output stays, so the
    // terminal still shows [InteractivePiP] / [KeyboardReflow] lines when needed.
    if (self.diagLabel) {
        [self.diagLabel removeFromSuperview];
        self.diagLabel = nil;
    }
}

- (void)prepareForHostedInput {
    if (self.deviceLocked || !self.overlayWindow || self.overlayWindow.hidden || !self.focusedWindow) return;
    [self.focusedWindow.sceneHost prepareForInput];
    // The remote-keyboard registration was the culprit: registering the hosted
    // scene with _UIRemoteKeyboards made the system treat it as a remote
    // keyboard scene and dropped its normal presentation, so the pane stayed
    // empty. Registration is disabled and any earlier registration is undone.
    [self configureRemoteKeyboardsForHostedInput:NO];
    [self showKeyboardDiagnostics];
}

- (void)prepareForTouchInView:(UIView *)view {
    for (UIView *v = view; v; v = v.superview) {
        if ([v isKindOfClass:[DPFloatingWindow class]] && [self.mutableFloatingWindows containsObject:(id)v]) {
            [self focusWindow:(DPFloatingWindow *)v];
            return;
        }
    }
    [self restorePreviousKeyWindow];
}

- (void)showKeyboardHelp {
    if (!self.focusedWindow) return;
    NSString *bundleID = self.focusedWindow.bundleID;
    BOOL supported = [[self sharedRemoteKeyboards] respondsToSelector:NSSelectorFromString(@"prepareForHostedWindow")];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"键盘诊断"
        message:[NSString stringWithFormat:@"焦点应用：%@\n远程宿主接口：%@\n接口存在不代表键盘已路由。若点输入框仍无键盘，可结束悬浮会话后全屏输入。", bundleID, supported ? @"存在（需真机验证）" : @"不可用"]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"结束会话并全屏输入" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self dismissAllAnimated:NO];
        [self openApplicationForeground:bundleID];
    }]];
    [self.overlayWindow.rootViewController presentViewController:alert animated:YES completion:nil];
}

- (void)closeSession { [self dismissAllAnimated:YES]; }

- (void)updateSessionControls {
    if (!self.sessionControls) {
        self.sessionControls = [[UIStackView alloc] init];
        self.sessionControls.axis = UILayoutConstraintAxisHorizontal;
        self.sessionControls.distribution = UIStackViewDistributionFillEqually;
        self.sessionControls.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.97];
        NSArray *titles = @[@"退出分屏", @"键盘帮助", @"关闭全部"];
        NSArray *actions = @[@"leaveSplit", @"showKeyboardHelp", @"closeSession"];
        for (NSUInteger i = 0; i < titles.count; i++) {
            UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
            [button setTitle:titles[i] forState:UIControlStateNormal];
            button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
            button.tintColor = [UIColor whiteColor];
            [button addTarget:self action:NSSelectorFromString(actions[i]) forControlEvents:UIControlEventTouchUpInside];
            [self.sessionControls addArrangedSubview:button];
            if (i == 0) self.leaveSplitButton = button;
        }
        [self.overlayRoot addSubview:self.sessionControls];
    }
    CGRect b = self.overlayRoot.bounds;
    self.sessionControls.frame = CGRectMake(0, self.overlayRoot.safeAreaInsets.top, b.size.width, 44);
    // Top toolbar removed per user: never show the exit/close bar over the panes.
    self.sessionControls.hidden = YES;
    self.leaveSplitButton.enabled = self.duoMode;
    [self.overlayRoot bringSubviewToFront:self.sessionControls];
}

- (void)handleDeviceLock {
    self.deviceLocked = YES;
    // Mirrors PanoramicView -[PVTaskSession cancelPendingSelectionOnLock]:
    // stop any in-flight interactive resize/drag, but KEEP the hosted pair.
    // Tearing down the scene here (windowScene = nil / dismissAll) is what made
    // the overlay bleed onto the lock screen and never come back on unlock.
    UIPanGestureRecognizer *drag = nil;
    for (UIGestureRecognizer *g in self.splitDivider.gestureRecognizers) {
        if ([g isKindOfClass:[UIPanGestureRecognizer class]]) { drag = (UIPanGestureRecognizer *)g; break; }
    }
    if (drag) { drag.enabled = NO; drag.enabled = YES; }  // cancels current touch
    self.overlayWindow.hidden = YES;                       // pixels off lock screen
    // Suspend every hosted scene: stops the 1s keepAlive + reconnect timers so
    // nothing can re-foreground the panes and rebound them over the lock screen.
    for (DPFloatingWindow *w in self.mutableFloatingWindows) {
        [w.sceneHost setSuspended:YES];
    }
    // NOTE: windowScene / pair intentionally preserved; session survives lock.
}

- (void)handleDeviceUnlock {
    self.deviceLocked = NO;
    // Keep hidden until a real activation; bringOverlayToFront will re-show it.
    self.overlayWindow.hidden = YES;
    // Do NOT resume here: session is rebuilt on next explicit activation, which
    // avoids replaying the hosted scene onto the home/lock screen.
}

- (void)ensureOverlayVisible {
    if (!self.overlayWindow || self.deviceLocked) return;
    if (self.mutableFloatingWindows.count == 0) { self.overlayWindow.hidden = YES; return; }
    [self bringOverlayToFront];
}

- (void)makeOverlayKeyWindow { [self ensureOverlayVisible]; }

- (void)restorePreviousKeyWindow {
    [self configureRemoteKeyboardsForHostedInput:NO];
    self.keyWindowBeforeHostedInput = nil;
}

- (void)hostedKeyboardWillShow {
    DPKBLog(@"WM show notify windows=%lu split=%lu",
            (unsigned long)self.floatingWindows.count, (unsigned long)self.splitWindows.count);
    // 0.7.126: the app picker owns its own UISearchBar. Expanding a floating
    // window here would steal the responder chain and the search keyboard never
    // appears, so leave everything alone while the picker is on screen.
    if (self.picker) { DPKBLog(@"WM show:skip picker"); return; }
    // 键盘弹出 -> 把活跃浮窗放大到近似全屏。不依赖 focusedWindow（直接弹出
    // 的浮窗可能没经过 focus 路径），而是找最上层的一个非分屏窗口。
    // 不抢键盘焦点、不改 maximized，只改 frame；收键盘时 collapse 还原。
    if (self.deviceLocked || !self.overlayWindow || self.overlayWindow.hidden) { DPKBLog(@"WM show:skip overlay"); return; }
    if (self.splitWindows.count) { DPKBLog(@"WM show:skip split"); return; }
    DPFloatingWindow *target = nil;
    for (DPFloatingWindow *w in self.floatingWindows) {
        if (w.isTiled) continue;
        if (!target || w.layer.zPosition > target.layer.zPosition) target = w;
    }
    if (target) {
        [target expandForKeyboardAnimated:YES];
        __weak typeof(self) ws = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [ws showKeyboardDiagnostics];
        });
    }
}

- (void)hostedKeyboardWillHide {
    // 0.7.126: never touch the key window while the picker is up - that is the
    // picker's own search keyboard closing.
    if (self.picker) { DPKBLog(@"WM hide:skip picker"); return; }
    // 键盘收起 -> 还原到弹出前的 frame。
    if (self.splitWindows.count) { [self restorePreviousKeyWindow]; return; }
    DPFloatingWindow *target = nil;
    for (DPFloatingWindow *w in self.floatingWindows) {
        if (w.isTiled) continue;
        if (w.keyboardExpanded) { target = w; break; }
    }
    if (!target) {
        for (DPFloatingWindow *w in self.floatingWindows) {
            if (!w.isTiled) { target = w; break; }
        }
    }
    if (target) {
        [target collapseForKeyboardAnimated:YES];
        __weak typeof(self) ws = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [ws showKeyboardDiagnostics];
        });
    }
    [self restorePreviousKeyWindow];
}

// 0.7.131: every window whose scene host needs a canvas refresh on rotation.
- (NSArray<DPFloatingWindow *> *)allWindowsForRotation {
    NSMutableOrderedSet<DPFloatingWindow *> *set = [NSMutableOrderedSet orderedSet];
    [set addObjectsFromArray:self.mutableFloatingWindows];
    [set addObjectsFromArray:self.splitWindows];
    if (self.focusedWindow) [set addObject:self.focusedWindow];
    return set.array;
}

// 0.7.132: rotation watchdog. SB's private orientation callback is not reliable
// on every iOS build, so also poll the effective geometry whenever layout runs.
// 0.7.132: belt and braces - also watch the device orientation notification, which
// fires even when SpringBoard's private orientation callback does not.
- (void)startWatchingDeviceOrientation {
    if (self.watchingDeviceOrientation) return;
    self.watchingDeviceOrientation = YES;
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(deviceOrientationDidChange:)
                                                 name:UIDeviceOrientationDidChangeNotification
                                               object:nil];
}

- (void)deviceOrientationDidChange:(NSNotification *)note {
    (void)note;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self syncRotationIfNeeded];
    });
}

- (void)syncRotationIfNeeded {
    if (!self.overlayWindow) return;
    CGRect full = self.overlayRoot.bounds;
    if (full.size.width < 2 || full.size.height < 2) return;
    BOOL nowLandscape = full.size.width > full.size.height;
    if (nowLandscape == self.lastLandscapeState && self.lastLandscapeKnown) return;
    self.lastLandscapeKnown = YES;
    self.lastLandscapeState = nowLandscape;
    NSLog(@"[InteractivePiP] rotation sync landscape=%d bounds=%@", nowLandscape, NSStringFromCGRect(full));
    for (DPFloatingWindow *w in [self allWindowsForRotation]) {
        [w updateNaturalCanvasForCurrentScreen];
    }
    if (self.duoMode && self.splitWindows.count == 2) [self layoutSplit];
}

- (void)handleOrientationChange {
    // 0.7.131: rotation must resync the window geometry AND the hosts' natural
    // canvas. Without the second part the scene keeps the portrait reference size
    // and cover-scale squeezes it into a landscape pane -> wrong proportions and
    // the pane's right half stays black.
    if (self.overlayWindow) {
        CGRect bounds = [UIScreen mainScreen].bounds;
        UIWindowScene *scene = nil;
        if (@available(iOS 13.0, *)) {
            scene = self.overlayWindow.windowScene ?: [self activeWindowScene];
            if (scene) bounds = scene.coordinateSpace.bounds;
        }
        // fall back to the device orientation when the scene is still reporting
        // the pre-rotation size during the transition
        if (UIDeviceOrientationIsLandscape([UIDevice currentDevice].orientation) &&
            bounds.size.width < bounds.size.height) {
            bounds = CGRectMake(0, 0, MAX(bounds.size.width, bounds.size.height),
                                MIN(bounds.size.width, bounds.size.height));
        }
        self.overlayWindow.frame = bounds;
        self.overlayRoot.frame = self.overlayWindow.bounds;
        for (DPFloatingWindow *w in [self allWindowsForRotation]) {
            [w updateNaturalCanvasForCurrentScreen];
        }
    }
    if (self.duoMode && self.splitWindows.count == 2) {
        [self layoutSplit];
        [self bringOverlayToFront];
        return;
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
    if (self.focusedWindow != window) [self restorePreviousKeyWindow];
    self.focusedWindow = window;
    for (DPFloatingWindow *other in self.mutableFloatingWindows) {
        [other setActive:(other == window) animated:NO];
    }
    [self prepareForHostedInput];
    [self bringOverlayToFront];
    if (self.splitDivider) [self.overlayRoot bringSubviewToFront:self.splitDivider];
}

- (void)beginDragToKeepForWindow:(DPFloatingWindow *)window {
    if (!window) return;
    // 0.7.175: 不再预先显示「松手保留」提示——提示只在用户真正上滑/拖动过程中出现。
    __weak typeof(self) weakSelf = self;
    window.onDragPreviewEnded = ^(DPFloatingWindow *w) {
        typeof(weakSelf) s = weakSelf;
        if (!s) return;
        // 松手即固定（窗口留在当前位置），随后自动弹 picker 选第二个 App 组成分屏
        [s endDragPreviewForWindow:w];
        [s requestSplitForWindow:w];
    };
    // 0.7.175: App 内容区上滑到灵动岛松手 → 固定并进入分屏配对
    window.onSwipeUpToIsland = ^(DPFloatingWindow *w) {
        typeof(weakSelf) s = weakSelf;
        if (!s) return;
        [s endDragPreviewForWindow:w];
        [s requestSplitForWindow:w];
    };
}

- (void)endDragPreviewForWindow:(DPFloatingWindow *)window {
    if (!window) return;
    [window endDragPreview];
    window.onDragPreviewEnded = nil;
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

/// 0.7.180: PV 式 —— 上滑到顶松手后，第一个 App 直接铺成「上半屏」（不是小浮窗），
/// 然后选第二个 App 填下半屏。
- (BOOL)createTopHalfWithBundleID:(NSString *)firstBundleID {
    if (!firstBundleID.length) return NO;
    // 0.7.183: 系统原生分屏 —— 不建窗口、不抓 scene。
    // 注意：调用本方法时系统正在执行"App 缩小回桌面"的过渡动画，
    // 必须等它跑完再弹 picker，否则会把动画冻住或弹不出来。
    NSLog(@"[InteractivePiP] nativeSplit: first=%@ scheduling picker", firstBundleID);
    [self probeSplitActivationAPI];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        typeof(weakSelf) s = weakSelf;
        if (!s) return;
        [s presentAppPickerWithCompletion:^(NSString *secondBundleID) {
            typeof(weakSelf) s2 = weakSelf;
            if (!s2 || !secondBundleID.length) return;
            if ([secondBundleID isEqualToString:firstBundleID]) return;
            [s2 activateNativeSplitFirst:firstBundleID second:secondBundleID];
        }];
    });
    return YES;
}

/// 0.7.182: 用 SBAppLayout + SBMainWorkspace 让系统自己把两个 App 铺成两半。
- (BOOL)activateNativeSplitFirst:(NSString *)firstBundleID second:(NSString *)secondBundleID {
    if (!firstBundleID.length || !secondBundleID.length) return NO;
    // 0.7.185: 绝不在这里重新打开第一个 App —— picker 正在 dismiss 时再拉前台，
    // 两个过渡互相冲突会把主线程卡死（"随便点就卡住"的真凶）。
    id itemA = [self displayItemForBundleID:firstBundleID];
    id itemB = [self displayItemForBundleID:secondBundleID];
    if (!itemA) {
        NSLog(@"[InteractivePiP] nativeSplit: itemA nil for %@ (not relaunching)", firstBundleID);
    }
    NSLog(@"[InteractivePiP] nativeSplit items a=%@ b=%@",
          itemA ? NSStringFromClass([itemA class]) : @"nil",
          itemB ? NSStringFromClass([itemB class]) : @"nil");

    // 第二个 App 未运行时没有 scene，先启动它（后台挂起即可），再取 displayItem
    if (!itemB) {
        NSLog(@"[InteractivePiP] nativeSplit: launching second %@ (deferred)", secondBundleID);
        __weak typeof(self) weakSelf = self;
        // 等 picker 完全消失再启动，避免过渡冲突卡死
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            typeof(weakSelf) s = weakSelf;
            if (!s) return;
            [s.launchAllowlist addObject:secondBundleID];
            if (![s openApplicationSuspended:secondBundleID]) {
                [s openApplicationForeground:secondBundleID];
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                typeof(weakSelf) s3 = weakSelf;
                if (!s3) return;
                id b2 = [s3 displayItemForBundleID:secondBundleID];
                NSLog(@"[InteractivePiP] nativeSplit retry itemB=%@",
                      b2 ? NSStringFromClass([b2 class]) : @"nil");
                if (!b2) return;
                [s3 commitNativeSplitFirst:firstBundleID
                                     itemA:[s3 displayItemForBundleID:firstBundleID]
                                    second:secondBundleID itemB:b2];
            });
        });
        return YES;
    }
    return [self commitNativeSplitFirst:firstBundleID itemA:itemA second:secondBundleID itemB:itemB];
}

- (BOOL)commitNativeSplitFirst:(NSString *)firstBundleID itemA:(id)itemA
                        second:(NSString *)secondBundleID itemB:(id)itemB {
    if (!itemA || !itemB) {
        NSLog(@"[InteractivePiP] nativeSplit commit: missing items a=%d b=%d", itemA != nil, itemB != nil);
        return NO;
    }
    CGRect screen = [UIScreen mainScreen].bounds;
    BOOL vertical = screen.size.height >= screen.size.width;
    id layout = [self buildPairAppLayoutWithFirst:itemA second:itemB vertical:vertical];
    if (!layout) {
        NSLog(@"[InteractivePiP] nativeSplit: layout build failed");
        return NO;
    }
    BOOL ok = [self requestSystemActivateLayout:layout];
    NSLog(@"[InteractivePiP] nativeSplit %@ + %@ activate ok=%d vertical=%d",
          firstBundleID, secondBundleID, ok, vertical);
    return ok;
}

/// 0.7.179: 一次性建两个窗并立刻铺满分屏 —— 中间不露单个浮窗。
- (void)createSplitPairWithFirst:(NSString *)firstBundleID second:(NSString *)secondBundleID {
    if (!firstBundleID.length || !secondBundleID.length) return;
    if ([firstBundleID isEqualToString:secondBundleID]) return;
    if ([[DPSettings shared] isBundleBlacklisted:firstBundleID] ||
        [[DPSettings shared] isBundleBlacklisted:secondBundleID]) return;

    [self leaveSplit];
    [self install];
    for (DPFloatingWindow *w in [self.mutableFloatingWindows copy]) {
        [self closeFloatingWindow:w animated:NO];
    }

    // 建两个窗，先隐藏避免任何中间态闪现
    self.creatingSplit = YES;
    [self openFloatingWithBundleID:firstBundleID];
    [self openFloatingWithBundleID:secondBundleID];
    self.creatingSplit = NO;

    DPFloatingWindow *first = nil, *second = nil;
    for (DPFloatingWindow *w in self.mutableFloatingWindows) {
        if ([w.bundleID isEqualToString:firstBundleID]) first = w;
        else if ([w.bundleID isEqualToString:secondBundleID]) second = w;
    }
    if (!first || !second) {
        NSLog(@"[InteractivePiP] createSplitPair FAILED first=%d second=%d",
              first != nil, second != nil);
        return;
    }
    [self pairWindow:first withBundleID:secondBundleID];
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
    [self.floatingHomeTimer invalidate]; self.floatingHomeTimer = nil;
    self.floatingHiddenOnHome = NO;
    self.edgeShelf.hidden = YES;
    self.splitWindows = @[first, second];
    for (DPFloatingWindow *w in self.splitWindows) {
        [w.layer removeAllAnimations];
        w.alpha = 1;
        w.transform = CGAffineTransformIdentity;
        self.savedFrames[w.bundleID] = [NSValue valueWithCGRect:w.frame];
        w.tiled = YES;
    }
    UIView *divider = [[UIView alloc] initWithFrame:CGRectZero];
    // Transparent touch strip; only the thin seam subview is visible, so the
    // two panes appear to fill the screen with just one dark line between.
    divider.backgroundColor = [UIColor clearColor];
    divider.layer.cornerRadius = 0;
    divider.layer.shadowColor = [UIColor blackColor].CGColor;
    divider.layer.shadowOpacity = 0.9;
    divider.layer.shadowRadius = 8;
    divider.accessibilityLabel = @"双击铰链退出 Duo 分屏";
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(leaveSplit)];
    tap.numberOfTapsRequired = 2;
    [divider addGestureRecognizer:tap];
    UIView *seam = [[UIView alloc] initWithFrame:CGRectZero];
    seam.tag = 0x5D1;
    // Divider styled like the iOS home indicator: a solid white rounded bar
    // running along the seam, 5pt thick with a soft radius and no shadow.
    seam.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.92];
    seam.layer.cornerRadius = 2.5;
    seam.layer.cornerCurve = kCACornerCurveContinuous;
    seam.userInteractionEnabled = NO;
    seam.alpha = 1.0;
    [divider addSubview:seam];
    divider.backgroundColor = [UIColor clearColor];

    UIPanGestureRecognizer *drag = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(handleSplitDrag:)];
    [divider addGestureRecognizer:drag];
    self.splitDivider = divider;
    [self.overlayRoot addSubview:divider];
    self.mode = DPPresentationModeSplit;
    self.duoMode = YES;
    CGFloat saved = [[NSUserDefaults standardUserDefaults] doubleForKey:@"sg.split.lastRatio"];
    self.splitRatio = (saved > 0.03 && saved < 0.97) ? saved : 0.5;
    [self layoutSplit];
    [self createSwitcherGroupCard];
    [self focusWindow:second];
}

- (void)layoutSplit {
    if (self.splitWindows.count != 2) return;
    [self syncRotationIfNeeded];
    [self scheduleSwitcherPreviewRefresh];
    CGRect full = self.overlayRoot.bounds;
    // Duo: panels fill the entire screen edge to edge (no status/home inset).
    CGRect b = full;
    // 0.7.141: reverted 0.7.140 - flipping the axis broke both orientations.
    // Original rule: side by side when the window is wide, stacked when it is tall.
    BOOL sideBySide = b.size.width >= b.size.height;
    // Card-style split: each pane keeps a rounded card edge and a narrow gap
    // between them shows the backdrop, like the native app switcher cards.
    const CGFloat seamW = 10.0;                    // white bar thickness
    const CGFloat cardGap = seamW / 2.0;           // inset each card by half the gap
    const CGFloat cardRadius = 26.0;               // matches native switcher corner
    const CGFloat touch = 28.0;                    // invisible draggable strip over the seam
    CGFloat total = sideBySide ? b.size.width : b.size.height;
    CGFloat ratio = MIN(0.95, MAX(0.05, self.splitRatio));
    CGFloat first = floor((total - seamW) * ratio); // panes share the space minus the gap
    CGRect a = b, c = b, h = b;
    if (sideBySide) {
        a.size.width = first;
        c.origin.x = b.origin.x + first + seamW; c.size.width = total - first - seamW;
        h.origin.x = b.origin.x + first + (seamW - touch) / 2.0; h.size.width = touch;
    } else {
        a.size.height = first;
        c.origin.y = b.origin.y + first + seamW; c.size.height = total - first - seamW;
        h.origin.y = b.origin.y + first + (seamW - touch) / 2.0; h.size.height = touch;
    }
    for (DPFloatingWindow *w in self.splitWindows) {
        [w.layer removeAllAnimations];
        w.transform = CGAffineTransformIdentity;
        // Round our own chrome/content views only (never the scene layer host
        // container: mutating it crashed SpringBoard on dealloc).
        [w setSplitCardCornerRadius:cardRadius];
    }
    self.splitWindows[0].frame = a;
    self.splitWindows[1].frame = c;
    self.splitDivider.frame = h;
    for (DPFloatingWindow *w in self.splitWindows) {
        [w setNeedsLayout]; [w layoutIfNeeded]; [w commitSceneLayout];
    }
    // one thin dark line, centered in the transparent touch strip
    UIView *line = [self.splitDivider viewWithTag:0x5D1];
    if (line) {
        if (sideBySide) line.frame = CGRectMake((touch - seamW) / 2.0, -b.size.height, seamW, h.size.height + b.size.height * 2.0);
        else line.frame = CGRectMake(-b.size.width, (touch - seamW) / 2.0, h.size.width + b.size.width * 2.0, seamW);
    }
    [self.overlayRoot bringSubviewToFront:self.splitDivider];
    [self updateSessionControls];
}

// Duo keeps the hinge fixed; drag gestures on the divider are intentionally
// absent so the two panes behave like two physical displays.

- (void)leaveSplit {
    BOOL hadCard = self.activeSwitcherCard != nil;
    self.switcherPaneImages = nil;
    self.switcherGroupIdentifier = nil;
    self.switcherHomeScene = nil;
    self.switcherRestoreGraceUntil = 0;
    self.switcherRestorePending = NO;
    self.switcherGestureEpoch++;
    self.activeSwitcherCard = nil;
    if (hadCard) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self2 = weakSelf;
            if (self2 && !self2.activeSwitcherCard) [self2 requestSwitcherGroupRefresh];
        });
    }
    self.switcherBuildStatus = nil;
    for (DPFloatingWindow *w in self.splitWindows) {
        w.tiled = NO;
        NSValue *v = self.savedFrames[w.bundleID];
        if (v) w.frame = v.CGRectValue;
        [w layoutIfNeeded]; [w commitSceneLayout];
    }
    [self.splitDivider removeFromSuperview]; self.splitDivider = nil;


    self.splitWindows = nil; [self.savedFrames removeAllObjects]; self.duoMode = NO;
    self.mode = self.mutableFloatingWindows.count ? DPPresentationModeFloating : DPPresentationModeNone;
    [self updateSessionControls];
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
    NSUInteger generation = self.sessionGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2 || generation != self2.sessionGeneration || self2.deviceLocked) return;
        NSString *target = self2.pendingHomeBundleID;
        self2.pendingHomeBundleID = nil;
        self2.homeReturnPending = NO;
        if (self2.mode == DPPresentationModeNone ||
            ![self2 shouldSuppressFullscreenForBundleID:target]) {
            [self2 bringOverlayToFront];
            return;
        }
        // A completed Home transition must not trigger another Home cycle.
        if (![[self2 foregroundBundleID] isEqualToString:target]) return;
        [self2 goHome];
    });
}

/// Launch suspended and poll briefly for the scene. Foreground launch is only
/// a compatibility fallback when the suspended SpringBoard API is unavailable.
- (void)ensureSceneThenAttach:(NSString *)bundleID
                         host:(DPSceneHost *)host
                   onAttached:(void (^)(void))onAttached {
    if (self.deviceLocked || !bundleID.length || !host) return;
    if ([bundleID isEqualToString:@"com.apple.springboard"]) return;

    __weak typeof(self) weakSelf = self;
    __weak DPSceneHost *weakHost = host;
    NSUInteger generation = self.sessionGeneration;

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
        if (self2 && generation == self2.sessionGeneration && !self2.deviceLocked) {
            [self2.launchAllowlist removeObject:bundleID];
            self2.suppressLaunch = NO;
            if (usedForegroundFallback && self2.mode != DPPresentationModeNone) {
                [self2 scheduleHomeReturnForBundleID:bundleID delay:0.0];
            }
            [self2 bringOverlayToFront];
        }
        if (onAttached && self2 && generation == self2.sessionGeneration && !self2.deviceLocked) onAttached();
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
        if (!host2 || !weakSelf || generation != weakSelf.sessionGeneration || weakSelf.deviceLocked || ![weakSelf.mutableHostedBundleIDs containsObject:bundleID]) {
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

#pragma mark - PV-style fullscreen split (0.7.178)
// App 全屏前台启动；用户在 App 内从底部上滑（hook SBFluidSwitcherGestureManager），
// 上滑到顶松手后把该 App 固定为第一半、弹 picker 选第二个，再用 layoutSplit 铺满两半。
// 全程不创建"浮动小窗"中间态。

- (BOOL)isPVFullscreenSplitPending {
    return self.pvPendingFirstBundleID.length > 0;
}

- (void)startPVFullscreenSplitForBundleID:(NSString *)bundleID {
    if (!bundleID.length || [bundleID isEqualToString:@"com.apple.springboard"]) return;
    if (![DPSettings shared].isEnabled) return;
    if ([[DPSettings shared] isBundleBlacklisted:bundleID]) return;
    [self.floatingHomeTimer invalidate]; self.floatingHomeTimer = nil;
    self.floatingHiddenOnHome = NO;
    self.edgeShelf.hidden = YES;
    [self install];

    self.pvPendingFirstBundleID = [bundleID copy];
    self.pvSplitGestureArmed = NO;
    // 全屏前台启动第一个 App（不 suspended、不 host 到浮窗）
    [self.launchAllowlist addObject:bundleID];
    [self openApplicationForeground:bundleID];
    NSLog(@"[InteractivePiP] PV fullscreen split: launch foreground %@, waiting for swipe-up", bundleID);
    // 0.6s 后确认 App 是否真的到了前台，便于真机定位"全屏没起来"的问题
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        typeof(weakSelf) s = weakSelf;
        if (!s || ![s.pvPendingFirstBundleID isEqualToString:bundleID]) return;
        NSString *fg = [s foregroundBundleID];
        NSLog(@"[InteractivePiP] PV split 0.6s check: fg=%@ expected=%@ match=%d",
              fg ?: @"(none)", bundleID, [fg isEqualToString:bundleID]);
    });
}

// 安全读取手势的位置/位移（系统私有手势类未必有 translationInView:）
- (CGPoint)dpsafeLocationForGesture:(id)gesture {
    if ([gesture respondsToSelector:@selector(locationInView:)]) {
        UIView *v = nil;
        if ([gesture respondsToSelector:@selector(view)]) v = [gesture valueForKey:@"view"];
        return ((CGPoint (*)(id, SEL, id))objc_msgSend)(gesture, @selector(locationInView:), v);
    }
    return CGPointZero;
}

// 0.7.181: PV式 —— 任意前台 App 全屏时上滑到顶松手即触发分屏，不需要预先选择。
- (void)handlePVFullscreenSplitPanBegan:(id)gesture {
    NSString *fg = [self foregroundBundleID];
    if (!fg.length || [fg isEqualToString:@"com.apple.springboard"]) {
        self.pvSplitGestureArmed = NO;
        return;
    }
    if ([[DPSettings shared] isBundleBlacklisted:fg]) {
        self.pvSplitGestureArmed = NO;
        return;
    }
    // 已经在分屏/浮窗会话里时不重复触发
    if (self.mode == DPPresentationModeSplit) {
        self.pvSplitGestureArmed = NO;
        return;
    }
    self.pvSplitGestureArmed = YES;
    self.pvPendingFirstBundleID = [fg copy];
    NSLog(@"[InteractivePiP] PV split pan BEGAN fg=%@", fg);
}

- (void)handlePVFullscreenSplitPanChanged:(id)gesture {
    if (!self.pvSplitGestureArmed) return;
}

- (BOOL)handlePVFullscreenSplitPanEnded:(id)gesture {
    BOOL wasArmed = self.pvSplitGestureArmed;
    self.pvSplitGestureArmed = NO;
    if (!wasArmed) return NO;

    // 判定是否上滑到顶：必须明显上滑（超过屏高 40%）或手指进入顶部区，避免普通回桌面被误触发
    BOOL reachedTop = NO;
    if ([gesture respondsToSelector:@selector(translationInView:)]) {
        UIView *v = ([gesture respondsToSelector:@selector(view)]) ? [gesture valueForKey:@"view"] : nil;
        CGPoint t = ((CGPoint (*)(id, SEL, id))objc_msgSend)(gesture, @selector(translationInView:), v);
        CGPoint loc = [self dpsafeLocationForGesture:gesture];
        CGFloat screenH = v ? v.bounds.size.height : 852.0;
        CGFloat topZone = MAX(90.0, (v ? v.safeAreaInsets.top : 0) + 60.0);
        reachedTop = (t.y < -(screenH * 0.4));
        if (loc.y > 0 && loc.y <= topZone) reachedTop = YES;
        NSLog(@"[InteractivePiP] PV split pan ENDED t=%@ loc=%@ screenH=%.0f topZone=%.0f reachedTop=%d",
              NSStringFromCGPoint(t), NSStringFromCGPoint(loc), screenH, topZone, reachedTop);
    } else {
        // 拿不到位移信息时：只要手势正常结束且前台还是这个 App，就当作到顶
        NSString *fg = [self foregroundBundleID];
        reachedTop = [fg isEqualToString:self.pvPendingFirstBundleID];
        NSLog(@"[InteractivePiP] PV split pan ENDED (no translation API) reachedTop=%d fg=%@",
              reachedTop, fg ?: @"(none)");
    }
    if (!reachedTop) {
        self.pvPendingFirstBundleID = nil;
        return NO;
    }

    // 到顶 → 该 App 固定为上半屏，再选第二个填下半屏
    NSString *first = self.pvPendingFirstBundleID;
    self.pvPendingFirstBundleID = nil;
    if (!first.length) return NO;
    BOOL ok = [self createTopHalfWithBundleID:first];
    // 只有窗口真的建出来了才接管（否则放行系统回桌面，避免卡死）
    return ok;
}

- (void)handleHomeGestureEnded {
    // Called when a FluidSwitcher pan gesture ends. Decide asynchronously
    // whether it was a "swipe to Home": session still alive AND the foreground
    // app is no longer one we host (nil / SpringBoard / another app) => Home.
    if (self.mode == DPPresentationModeNone || self.deviceLocked || self.internalHomeReturn || self.switcherRestorePending || NSProcessInfo.processInfo.systemUptime < self.switcherRestoreGraceUntil) return;
    NSUInteger epoch = self.switcherGestureEpoch;
    NSUInteger generation = self.sessionGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2 || generation != self2.sessionGeneration || self2.deviceLocked) return;
        if (self2.mode == DPPresentationModeNone || self2.switcherRestorePending || self2.switcherGestureEpoch != epoch) return;
        NSString *fg = [self2 foregroundBundleID];
        // If a hosted app is still foreground, this was an app switch / open — keep the session.
        if (fg.length && [self2.mutableHostedBundleIDs containsObject:fg]) return;
        if (self2.mode == DPPresentationModeFloating) {
            if (!fg.length || [fg isEqualToString:@"com.apple.springboard"])
                [self2 hideFloatingOnHome];
            return;
        }
        NSLog(@"[InteractivePiP] 上滑回桌面 -> 挂到后台任务列表 (fg=%@)", fg ?: @"(none)");
        [self2 parkSessionInAppSwitcher];
    });
}

- (void)parkSessionInAppSwitcher {
    if (self.sessionParked || self.switcherRestorePending) return;
    self.switcherHomeScene = self.overlayWindow.windowScene ?: self.switcherHomeScene;
    // No on-park capture: previews are pre-rendered while idle (scheduleSwitcherPreviewRefresh).
    // Keep the whole session alive but take it off screen entirely, so the home
    // screen and the app switcher stay visually clean. Nothing is torn down:
    // scenes stay hosted and resume instantly on the next activation.
    self.sessionParked = YES;
    for (DPFloatingWindow *w in self.mutableFloatingWindows) {
        [w.sceneHost setSuspended:YES];
    }
    // Hide the overlay completely. Lowering the level and keeping it visible
    // left a solid black rectangle (tiled panes use a black background) sitting
    // on top of the home screen. The session itself stays alive in memory, so
    // nothing has to be rebuilt when the user comes back.
    self.overlayRoot.transform = CGAffineTransformIdentity;
    self.overlayWindow.hidden = YES;
    self.overlayWindow.windowLevel = UIWindowLevelNormal;
    // Drop the black tile backdrop too, just in case the window is shown by
    // anything else before we restore it properly.
    for (DPFloatingWindow *w in self.mutableFloatingWindows) {
        [w setTiled:NO];
        w.alpha = 0.0;
    }
    [self updateSessionControls];
    if (self.activeSwitcherCard) [self requestSwitcherGroupRefresh];
    NSLog(@"[InteractivePiP] 会话已停靠后台任务列表，窗口数=%lu",
          (unsigned long)self.mutableFloatingWindows.count);
}

- (void)restoreParkedSession {
    if (!self.sessionParked) return;
    self.sessionParked = NO;
    self.overlayRoot.transform = CGAffineTransformIdentity;
    self.overlayWindow.windowLevel = UIWindowLevelStatusBar + 90.0;
    self.overlayWindow.hidden = NO;
    for (DPFloatingWindow *w in self.mutableFloatingWindows) {
        w.alpha = 1.0;
        [w.sceneHost setSuspended:NO];
    }
    if (self.duoMode) {
        for (DPFloatingWindow *w in self.splitWindows) { w.tiled = YES; }
        [self layoutSplit];
    }
    [self bringOverlayToFront];
    NSLog(@"[InteractivePiP] 从后台任务列表恢复会话");
}

// Keep floating hosts alive while Home is visible; only hide our overlay.
// A single low-frequency timer exists only during this hidden state, does no
// rendering or scene mutation, and stops after resume/close/split transition.
- (void)noteForegroundApplicationChanged:(NSString *)bundleID {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self noteForegroundApplicationChanged:bundleID]; });
        return;
    }
    if (!self.floatingHiddenOnHome || self.deviceLocked || self.mode != DPPresentationModeFloating || !self.mutableFloatingWindows.count) return;
    // Empty means no foreground application, not evidence that Home was left.
    if (!bundleID.length || [bundleID isEqualToString:@"com.apple.springboard"]) return;
    [self.floatingHomeTimer invalidate]; self.floatingHomeTimer = nil;
    self.floatingHiddenOnHome = NO;
    for (DPFloatingWindow *window in self.mutableFloatingWindows) {
        window.alpha = 1;
        [window.sceneHost setSuspended:NO];
    }
    [self bringOverlayToFront];
}

// 0.7.150: ZengNiu-style edge shelf. While the floating windows are parked on the
// home screen (one swipe up), show a column of thumbnail cards on the left edge.
// Tapping a card brings that window back. Split pairs keep the native group card.
// 0.7.152: snapshot every floating window BEFORE hiding the overlay, so the edge
// shelf cards can show a real thumbnail (ZengNiu style) instead of a black block.
- (NSArray<UIImage *> *)captureFloatingThumbnails {
    NSMutableArray<UIImage *> *shots = [NSMutableArray array];
    for (DPFloatingWindow *w in self.mutableFloatingWindows) {
        UIImage *img = nil;
        @try {
            CGRect b = w.bounds;
            if (b.size.width > 2 && b.size.height > 2) {
                UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
                fmt.scale = MIN(2.0, [UIScreen mainScreen].scale);
                fmt.opaque = NO;
                UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:b.size format:fmt];
                img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
                    BOOL ok = [w drawViewHierarchyInRect:b afterScreenUpdates:NO];
                    if (!ok) [w.layer renderInContext:ctx.CGContext];
                }];
            }
        } @catch (__unused NSException *e) { img = nil; }
        if (img) [shots addObject:img];
        else [shots addObject:[NSNull null]];
    }
    return shots;
}

- (void)updateEdgeShelf {
    if (!self.floatingHiddenOnHome || self.mode != DPPresentationModeFloating ||
        self.deviceLocked || self.switcherRestorePending || self.homeGestureSettling ||
        ![DPSettings shared].isEnabled) {
        self.edgeShelf.hidden = YES;
        return;
    }
    NSString *fg = [self foregroundBundleID];
    if ((fg.length && ![fg isEqualToString:@"com.apple.springboard"]) || DPDuoSystemSwitcherVisible()) {
        self.edgeShelf.hidden = YES;
        return;
    }
    UIWindowScene *scene = self.switcherHomeScene;
    if (!scene || scene.activationState != UISceneActivationStateForegroundActive) scene = [self activeWindowScene];
    if (!scene || scene.activationState != UISceneActivationStateForegroundActive || scene.screen != UIScreen.mainScreen) {
        self.edgeShelf.hidden = YES;
        return;
    }
    if (self.edgeShelf && self.shelfWindowCount != self.mutableFloatingWindows.count) {
        self.edgeShelf.hidden = YES;
        self.edgeShelf = nil;
    }
    if (self.edgeShelf.windowScene != scene) {
        self.edgeShelf.hidden = YES;
        DPEdgeShelfWindow *shelf = [[DPEdgeShelfWindow alloc] initWithWindowScene:scene];
        shelf.hidden = YES;
        NSArray<DPFloatingWindow *> *floaters = [self.mutableFloatingWindows copy];
        NSMutableArray *names = [NSMutableArray arrayWithCapacity:floaters.count];
        NSMutableArray *images = [NSMutableArray arrayWithCapacity:floaters.count];
        NSArray<UIImage *> *shots = self.shelfThumbnails;
        for (NSUInteger i = 0; i < floaters.count; i++) {
            DPFloatingWindow *window = floaters[i];
            NSString *bundle = window.bundleID ?: @"?";
            [names addObject:bundle.pathExtension.length ? bundle.pathExtension : bundle];
            id shot = (i < shots.count) ? shots[i] : nil;
            if ([shot isKindOfClass:[UIImage class]]) {
                [images addObject:shot];
            } else {
                UIImage *icon = [window.sceneHost iconImageLarge];
                [images addObject:icon ?: (id)[NSNull null]];
            }
        }
        NSUInteger generation = self.sessionGeneration;
        __weak typeof(self) weakSelf = self;
        __weak DPEdgeShelfWindow *weakShelf = shelf;
        [shelf configureWithNames:names images:images restore:^(NSUInteger index) {
            __strong typeof(weakSelf) manager = weakSelf;
            if (!manager || !weakShelf || manager.edgeShelf != weakShelf ||
                manager.sessionGeneration != generation ||
                index >= manager.mutableFloatingWindows.count) return;
            manager.floatingHiddenOnHome = NO;
            [manager.floatingHomeTimer invalidate];
            manager.floatingHomeTimer = nil;
            DPFloatingWindow *selected = manager.mutableFloatingWindows[index];
            for (DPFloatingWindow *window in manager.mutableFloatingWindows) {
                window.alpha = 1;
                [window.sceneHost setSuspended:NO];
            }
            manager.overlayWindow.hidden = NO;
            [manager focusWindow:selected];
            [manager updateEdgeShelf];
            NSLog(@"[InteractivePiP] edge shelf restore %@", selected.bundleID);
        }];
        self.edgeShelf = shelf;
        self.shelfWindowCount = floaters.count;
    }
    self.edgeShelf.frame = scene.coordinateSpace.bounds;
    self.edgeShelf.hidden = NO;
}

- (void)hideFloatingOnHome {
    if (self.mode != DPPresentationModeFloating || self.mutableFloatingWindows.count == 0) return;
    // 0.7.152: grab the pictures while they are still on screen.
    self.shelfThumbnails = [self captureFloatingThumbnails];
    self.floatingHiddenOnHome = YES;
    self.overlayWindow.hidden = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.28 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self updateEdgeShelf];
    });
    if (self.floatingHomeTimer) return;
    NSUInteger generation = self.sessionGeneration;
    __weak typeof(self) weakSelf = self;
    NSTimer *timer = [NSTimer timerWithTimeInterval:0.4 repeats:YES block:^(NSTimer *tick) {
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2 || self2.sessionGeneration != generation ||
            self2.mode != DPPresentationModeFloating || !self2.mutableFloatingWindows.count) {
            [tick invalidate];
            self2.floatingHomeTimer = nil;
            self2.floatingHiddenOnHome = NO;
            return;
        }
        if (self2.deviceLocked) return;
        NSString *foreground = [self2 foregroundBundleID];
        if (!foreground.length || [foreground isEqualToString:@"com.apple.springboard"]) return;
        [self2 noteForegroundApplicationChanged:foreground];
    }];
    timer.tolerance = 0.08;
    self.floatingHomeTimer = timer;
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
}

- (void)handleUserHome {
    if (self.internalHomeReturn || self.switcherRestorePending || NSProcessInfo.processInfo.systemUptime < self.switcherRestoreGraceUntil) return;
    if (self.mode == DPPresentationModeFloating) {
        [self hideFloatingOnHome];
        return;
    }
    if (self.mode == DPPresentationModeSplit && self.splitWindows.count == 2) {
        [self parkSessionInAppSwitcher];
    } else {
        [self dismissAllAnimated:NO];
    }
}

- (void)goHome {
    Class SBUIController = NSClassFromString(@"SBUIController");
    if (!SBUIController) return;
    id ui = ((id (*)(id, SEL))objc_msgSend)(SBUIController, @selector(sharedInstance));
    for (NSString *name in @[@"handleHomeButtonSinglePressUp", @"clickedMenuButton"]) {
        SEL sel = NSSelectorFromString(name);
        if ([ui respondsToSelector:sel]) {
            self.internalHomeReturn = YES;
            ((void (*)(id, SEL))objc_msgSend)(ui, sel);
            self.internalHomeReturn = NO;
            NSLog(@"[InteractivePiP] 回桌面 via %@", name);
            break;
        }
    }
    // Do not re-show the overlay after Home; that repaints split panes over
    // the home screen. Session stays alive and is rebuilt on next activation.
}

#pragma mark - Native system split (0.7.182)
// PV 式真分屏：不改 scene、不建自己的窗口。构造双 item 的 SBAppLayout，
// 交给 SBMainWorkspace 提交，让系统自己把两个 App 铺成两半。
// App 全程在系统自己的 scene 里渲染 —— 原生、流畅、能进 switcher、能划掉。

- (id)buildPairAppLayoutWithFirst:(id)firstItem second:(id)secondItem vertical:(BOOL)vertical {
    if (!firstItem || !secondItem) return nil;
    Class cls = NSClassFromString(@"SBAppLayout");
    if (!cls) return nil;
    // SBAppLayoutRole: 1=primary 2=side(左右) 3=top 4=bottom(上下)
    NSNumber *roleA = vertical ? @3 : @1;
    NSNumber *roleB = vertical ? @4 : @2;
    NSDictionary *roles = @{roleA: firstItem, roleB: secondItem};
    NSArray<NSString *> *names = @[
        @"initWithItemsForLayoutRoles:configuration:environment:preferredDisplayOrdinal:",
        @"initWithItemsForLayoutRoles:environment:preferredDisplayOrdinal:",
        @"initWithItemsForLayoutRoles:configuration:environment:"];
    for (NSUInteger i = 0; i < names.count; i++) {
        SEL sel = NSSelectorFromString(names[i]);
        NSMethodSignature *sig = [cls instanceMethodSignatureForSelector:sel];
        NSUInteger n = i == 0 ? 6 : 5;
        if (!sig || sig.numberOfArguments != n || sig.methodReturnType[0] != '@') continue;
        if ([sig getArgumentTypeAtIndex:2][0] != '@') continue;
        BOOL valid = YES;
        for (NSUInteger j = 3; j < n; j++) {
            if ([sig getArgumentTypeAtIndex:j][0] != 'q') valid = NO;
        }
        if (!valid) continue;
        @try {
            id allocated = [cls alloc];
            id layout;
            if (i == 0) {
                // configuration: 1 = 分屏（PV 实测值），environment: 1
                layout = ((id (*)(id, SEL, id, NSInteger, NSInteger, NSInteger))objc_msgSend)(allocated, sel, roles, 1, 1, 0);
            } else {
                layout = ((id (*)(id, SEL, id, NSInteger, NSInteger))objc_msgSend)(allocated, sel, roles, 1, i == 1 ? 0 : 1);
            }
            NSLog(@"[InteractivePiP] buildPairAppLayout %lu -> %@", (unsigned long)i+1, layout ? @"ok" : @"nil");
            if (layout) return layout;
        } @catch (NSException *e) {
            NSLog(@"[InteractivePiP] buildPairAppLayout %@ ex: %@", names[i], e);
        }
    }
    return nil;
}

/// 请求系统激活一个分屏 layout（PV: requestForActivatingAppLayout:）
- (BOOL)requestSystemActivateLayout:(id)layout {
    if (!layout) return NO;
    Class WS = NSClassFromString(@"SBMainWorkspace");
    id workspace = nil;
    if (WS && [WS respondsToSelector:NSSelectorFromString(@"sharedInstance")]) {
        @try { workspace = ((id(*)(id, SEL))objc_msgSend)(WS, NSSelectorFromString(@"sharedInstance")); }
        @catch (__unused NSException *e) {}
    }
    if (!workspace) { NSLog(@"[InteractivePiP] requestSystemActivate: no workspace"); return NO; }

    // 0.7.184: PV 用的是 +[? requestForActivatingAppLayout:] —— 类方法。
    // 依次尝试：候选类上的类方法 → workspace 实例方法 → 直接提交 layout。
    NSArray<NSString *> *factoryNames = @[@"requestForActivatingAppLayout:",
                                          @"requestWithAppLayout:",
                                          @"_requestForActivatingAppLayout:"];
    NSArray<NSString *> *candidateClasses = @[@"SBMainWorkspaceTransitionRequest",
                                             @"SBWorkspaceTransitionRequest",
                                             @"SBMainWorkspace"];

    for (NSString *clsName in candidateClasses) {
        Class C = NSClassFromString(clsName);
        if (!C) continue;
        for (NSString *fname in factoryNames) {
            SEL fsel = NSSelectorFromString(fname);
            // 类方法
            if (![C respondsToSelector:fsel]) continue;
            @try {
                id req = ((id(*)(id, SEL, id))objc_msgSend)((id)C, fsel, layout);
                NSLog(@"[InteractivePiP] requestSystemActivate: %@ %@ -> %@", clsName, fname, req ? @"req" : @"nil");
                if (!req) continue;
                // req 自己可能能 execute
                SEL selfExec = NSSelectorFromString(@"execute");
                if ([req respondsToSelector:selfExec]) {
                    ((void(*)(id, SEL))objc_msgSend)(req, selfExec);
                    NSLog(@"[InteractivePiP] requestSystemActivate: executed via req execute, cls=%@", clsName);
                    return YES;
                }
                SEL exec = NSSelectorFromString(@"executeTransitionRequest:");
                if ([workspace respondsToSelector:exec]) {
                    BOOL ok = ((BOOL(*)(id, SEL, id))objc_msgSend)(workspace, exec, req);
                    NSLog(@"[InteractivePiP] requestSystemActivate via %@/%@ workspace-exec ok=%d", clsName, fname, ok);
                    if (ok) return YES;
                }
            } @catch (NSException *e) {
                NSLog(@"[InteractivePiP] requestSystemActivate %@/%@ ex: %@", clsName, fname, e);
            }
        }
    }

    NSLog(@"[InteractivePiP] requestSystemActivate: trying SBSwitcherTransitionRequest path");
    // 0.7.184: PV 实际用的路径 —— SBSwitcherTransitionRequest + setAppLayout: + setSource:
    Class TRCls = NSClassFromString(@"SBSwitcherTransitionRequest");
    if (TRCls) {
        @try {
            id req = [TRCls new];
            // 0.7.188: 本工程已验证的真实 setter 是 setActivatingDisplayItem:，
            // 以及 toAppLayout / transitionContext。按它们的真实形态填。
            SEL setItem = NSSelectorFromString(@"setActivatingDisplayItem:");
            SEL setLayout = NSSelectorFromString(@"setAppLayout:");
            SEL setToLayout = NSSelectorFromString(@"setToAppLayout:");
            // 先设 toAppLayout（双 item 布局）——这才是分屏形态
            if ([req respondsToSelector:setToLayout]) {
                ((void(*)(id, SEL, id))objc_msgSend)(req, setToLayout, layout);
                NSLog(@"[InteractivePiP] req setToAppLayout ok");
            }
            if ([req respondsToSelector:setLayout]) {
                ((void(*)(id, SEL, id))objc_msgSend)(req, setLayout, layout);
                NSLog(@"[InteractivePiP] req setAppLayout ok");
            }
            // activatingDisplayItem 用一个真实 item（从 layout 里取第一个）
            if ([req respondsToSelector:setItem]) {
                id firstItem = nil;
                SEL itemsSel = NSSelectorFromString(@"allItems");
                if ([layout respondsToSelector:itemsSel]) {
                    id arr = ((id(*)(id,SEL))objc_msgSend)(layout, itemsSel);
                    if ([arr isKindOfClass:NSArray.class] && [arr count]) firstItem = [arr firstObject];
                }
                if (firstItem) {
                    ((void(*)(id, SEL, id))objc_msgSend)(req, setItem, firstItem);
                    NSLog(@"[InteractivePiP] req setActivatingDisplayItem=%@", NSStringFromClass([firstItem class]));
                }
            }
            NSLog(@"[InteractivePiP] requestSystemActivate: built SBSwitcherTransitionRequest %@", req);

            // 0.7.187: 交给我们已 hook 验证过的真实转场接收者。
            // 本机 iOS 上 SBFluidSwitcherViewController / SBMainSwitcherControllerCoordinator
            // 都实现了 switcherContentController:performTransitionWithRequest:gestureInitiated:，
            // 优先用 switcher 里登记的 controller，再退到 sharedInstance。
            id content = self.switcherContentController;
            if (!content) {
                for (NSString *cn in @[@"SBFluidSwitcherViewController", @"SBMainSwitcherControllerCoordinator"]) {
                    Class C = NSClassFromString(cn);
                    if (!C) continue;
                    if ([C respondsToSelector:NSSelectorFromString(@"sharedInstance")]) {
                        id inst = ((id(*)(id,SEL))objc_msgSend)(C, NSSelectorFromString(@"sharedInstance"));
                        if ([inst respondsToSelector:@selector(switcherContentController:performTransitionWithRequest:gestureInitiated:)]) {
                            content = inst; break;
                        }
                        for (NSString *g in @[@"switcherContentController", @"_switcherContentController"]) {
                            SEL gs = NSSelectorFromString(g);
                            if ([inst respondsToSelector:gs]) {
                                id c2 = ((id(*)(id,SEL))objc_msgSend)(inst, gs);
                                if (c2) { content = c2; break; }
                            }
                        }
                        if (content) break;
                    }
                }
            }
            NSLog(@"[InteractivePiP] requestSystemActivate: content=%@", content ? NSStringFromClass([content class]) : @"nil");
            NSLog(@"[InteractivePiP] requestSystemActivate: content=%@", content ? NSStringFromClass([content class]) : @"nil");
            if (content) {
                for (NSString *m in @[@"performTransitionWithRequest:gestureInitiated:",
                                      @"performTransitionWithRequest:",
                                      @"requestTransitionWithRequest:"]) {
                    SEL ms = NSSelectorFromString(m);
                    if (![content respondsToSelector:ms]) continue;
                    NSMethodSignature *sig = [content methodSignatureForSelector:ms];
                    if (sig.numberOfArguments == 3) {
                        ((void(*)(id,SEL,id))objc_msgSend)(content, ms, req);
                    } else if (sig.numberOfArguments == 4) {
                        ((void(*)(id,SEL,id,BOOL))objc_msgSend)(content, ms, req, NO);
                    } else continue;
                    NSLog(@"[InteractivePiP] requestSystemActivate: performed via %@", m);
                    // 0.7.187: 给用户可见反馈，便于无日志时判断是否走到这一步
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        NSLog(@"[InteractivePiP] nativeSplit: if you still see ONE app, the transition was ignored");
                    });
                    return YES;
                }
            }
        } @catch (NSException *e) {
            NSLog(@"[InteractivePiP] requestSystemActivate switcherReq ex: %@", e);
        }
    }

    // 实例方法兜底
    for (NSString *fname in factoryNames) {
        SEL fsel = NSSelectorFromString(fname);
        if (![workspace respondsToSelector:fsel]) continue;
        @try {
            id req = ((id(*)(id, SEL, id))objc_msgSend)(workspace, fsel, layout);
            if (!req) continue;
            SEL exec = NSSelectorFromString(@"executeTransitionRequest:");
            if ([workspace respondsToSelector:exec]) {
                BOOL ok = ((BOOL(*)(id, SEL, id))objc_msgSend)(workspace, exec, req);
                NSLog(@"[InteractivePiP] requestSystemActivate instance %@ ok=%d", fname, ok);
                if (ok) return YES;
            }
        } @catch (NSException *e) {
            NSLog(@"[InteractivePiP] requestSystemActivate instance %@ ex: %@", fname, e);
        }
    }
    NSLog(@"[InteractivePiP] requestSystemActivate: ALL paths failed");
    return NO;
}

#pragma mark - Helpers

- (CGRect)initialFloatingFrameInBounds:(CGRect)bounds {
    // 0.7.180: PV 式 —— 新窗默认就是「上半屏」尺寸，视觉上像 App 缩成卡片后的形态，
    // 而不是 280x500 的小浮窗。用户上滑即固定为上半屏。
    if (bounds.size.width > 0 && bounds.size.height > 0) {
        CGFloat h = floor(bounds.size.height / 2.0);
        return CGRectMake(bounds.origin.x, bounds.origin.y, bounds.size.width, h);
    }
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
    return CGRectMake(0, 0, size.width, size.height);
}

- (NSString *)foregroundBundleID {
    // Frontmost-app accessors live on SpringBoard itself on some iOS 16 builds,
    // not SBApplicationController. Only accept a real application bundle ID.
    NSMutableArray *owners = [NSMutableArray arrayWithObject:UIApplication.sharedApplication];
    Class cls = NSClassFromString(@"SBApplicationController");
    SEL shared = NSSelectorFromString(@"sharedInstance");
    if ([cls respondsToSelector:shared]) {
        id controller = ((id(*)(id,SEL))objc_msgSend)(cls,shared);
        if (controller) [owners addObject:controller];
    }
    for (id owner in owners) {
        for (NSString *name in @[@"_accessibilityFrontMostApplication", @"_frontMostApplication", @"frontmostApplication", @"focusedApplication"]) {
            @try {
                SEL getter = NSSelectorFromString(name);
                if (![owner respondsToSelector:getter]) continue;
                NSMethodSignature *sig = [owner methodSignatureForSelector:getter];
                if (sig.numberOfArguments != 2 || sig.methodReturnType[0] != '@') continue;
                id app = ((id(*)(id,SEL))objc_msgSend)(owner,getter);
                SEL bidGetter = @selector(bundleIdentifier);
                if (![app respondsToSelector:bidGetter]) continue;
                NSMethodSignature *bidSig = [app methodSignatureForSelector:bidGetter];
                if (bidSig.numberOfArguments != 2 || bidSig.methodReturnType[0] != '@') continue;
                id bid = ((id(*)(id,SEL))objc_msgSend)(app,bidGetter);
                if ([bid isKindOfClass:NSString.class] && [bid length]) return bid;
            } @catch (__unused NSException *e) { }
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

#pragma mark - Split ratio drag

- (void)handleSplitDrag:(UIPanGestureRecognizer *)gr {
    if (self.splitWindows.count != 2 || !self.overlayRoot) return;
    CGRect full = self.overlayRoot.bounds;
    BOOL sideBySide = (full.size.width >= full.size.height);
    CGFloat available = sideBySide ? full.size.width : full.size.height;
    if (available <= 1) return;

    if (gr.state == UIGestureRecognizerStateBegan || gr.state == UIGestureRecognizerStateChanged) {
        CGPoint p = [gr locationInView:self.overlayRoot];
        CGFloat pos = sideBySide ? p.x : p.y;
        self.splitRatio = MIN(0.95, MAX(0.05, pos / available));
        [self layoutSplit];
    } else if (gr.state == UIGestureRecognizerStateEnded || gr.state == UIGestureRecognizerStateCancelled) {
        [[NSUserDefaults standardUserDefaults] setDouble:self.splitRatio forKey:@"sg.split.lastRatio"];
        [self scheduleSwitcherPreviewRefresh];
    }
}

#pragma mark - Switcher card (Stage A: resolve real displayItem)

static id DPDynamicGet(id obj, NSString *key) {
    if (!obj || !key) return nil;
    @try {
        id v = [obj valueForKey:key];
        return v;
    } @catch (__unused NSException *e) { return nil; }
}

- (nullable id)displayItemForBundleID:(NSString *)bundleID {
    if (!bundleID) return nil;
    NSLog(@"[InteractivePiP] displayItemForBundleID: try %@", bundleID);

    // 1) FBSceneManager: 遍历已激活场景，找 bundleID 匹配的 scene 实体 → displayItem
    Class FBSceneManagerCls = NSClassFromString(@"FBSceneManager");
    id sceneManager = nil;
    if (FBSceneManagerCls && [FBSceneManagerCls respondsToSelector:NSSelectorFromString(@"sharedManager")]) {
        @try {
            sceneManager = ((id(*)(id, SEL))objc_msgSend)(FBSceneManagerCls, NSSelectorFromString(@"sharedManager"));
        } @catch (__unused NSException *e) {}
    }
    if (sceneManager) {
        id scenes = DPDynamicGet(sceneManager, @"scenes");
        if ([scenes isKindOfClass:[NSArray class]]) {
            for (id sc in scenes) {
                if (!sc) continue;
                id entity = sc;
                // scene 对象通常有 identity/identifier，取 bundleID
                NSString *scBundle = DPDynamicGet(entity, @"bundleIdentifier");
                if (!scBundle) scBundle = DPDynamicGet(entity, @"bundleID");
                if (![scBundle isEqualToString:bundleID]) continue;
                id di = DPDynamicGet(entity, @"displayItem");
                if (di) return di;
                // scene 可能包在 sceneIdentity 里
                id ident = DPDynamicGet(entity, @"sceneIdentity");
                id di2 = DPDynamicGet(ident, @"displayItem");
                if (di2) return di2;
            }
        }
    }

    // 2) SBApplicationController: applicationWithBundleIdentifier → displayItem
    Class SBAppCtrl = NSClassFromString(@"SBApplicationController");
    id appCtrl = nil;
    if (SBAppCtrl && [SBAppCtrl respondsToSelector:NSSelectorFromString(@"sharedInstance")]) {
        @try {
            appCtrl = ((id(*)(id, SEL))objc_msgSend)(SBAppCtrl, NSSelectorFromString(@"sharedInstance"));
        } @catch (__unused NSException *e) {}
    }
    if (appCtrl) {
        if ([appCtrl respondsToSelector:NSSelectorFromString(@"applicationWithBundleIdentifier:")]) {
            @try {
                id app = ((id(*)(id, SEL, id))objc_msgSend)(appCtrl, NSSelectorFromString(@"applicationWithBundleIdentifier:"), bundleID);
                if (app) {
                    id di = DPDynamicGet(app, @"displayItem");
                    if (di) return di;
                }
            } @catch (__unused NSException *e) {}
        }
    }

    return nil;
}

#pragma mark - Switcher card (Stage B: build SBAppLayout)

- (nullable id)switcherLayoutForGroupIdentifier:(NSString *)identifier {
    Class itemClass = NSClassFromString(@"SBDisplayItem");
    SEL makeItem = NSSelectorFromString(@"initWithType:bundleIdentifier:uniqueIdentifier:");
    NSMethodSignature *itemSig = [itemClass instanceMethodSignatureForSelector:makeItem];
    self.switcherBuildStatus = @"proxy-no-ABI";
    if (!itemSig || itemSig.numberOfArguments != 5 || itemSig.methodReturnType[0] != '@' ||
        strcmp([itemSig getArgumentTypeAtIndex:2], @encode(NSInteger)) != 0 ||
        [itemSig getArgumentTypeAtIndex:3][0] != '@' || [itemSig getArgumentTypeAtIndex:4][0] != '@') return nil;
    id proxy = nil;
    @try {
        proxy = ((id (*)(id, SEL, NSInteger, id, id))objc_msgSend)([itemClass alloc], makeItem, 2, identifier, identifier);
    } @catch (__unused NSException *e) {
        self.switcherBuildStatus = @"proxy-ex";
        return nil;
    }
    if (!proxy || ![proxy isKindOfClass:itemClass]) {
        self.switcherBuildStatus = @"proxy-nil";
        return nil;
    }
    Class cls = NSClassFromString(@"SBAppLayout");
    NSDictionary *roles = @{@1:proxy};
    NSArray<NSString *> *names = @[
        @"initWithItemsForLayoutRoles:configuration:environment:preferredDisplayOrdinal:",
        @"initWithItemsForLayoutRoles:environment:preferredDisplayOrdinal:",
        @"initWithItemsForLayoutRoles:configuration:environment:"];
    self.switcherBuildStatus = @"no-ABI";
    for (NSUInteger i = 0; i < names.count; i++) {
        SEL sel = NSSelectorFromString(names[i]);
        NSMethodSignature *sig = [cls instanceMethodSignatureForSelector:sel];
        NSUInteger n = i == 0 ? 6 : 5;
        if (!sig || sig.numberOfArguments != n || sig.methodReturnType[0] != '@' ||
            [sig getArgumentTypeAtIndex:2][0] != '@') continue;
        BOOL valid = YES;
        for (NSUInteger j = 3; j < n; j++) {
            if ([sig getArgumentTypeAtIndex:j][0] != 'q') valid = NO;
        }
        if (!valid) continue;
        @try {
            id allocated = [cls alloc];
            id layout;
            if (i == 0) {
                layout = ((id (*)(id, SEL, id, NSInteger, NSInteger, NSInteger))objc_msgSend)(allocated, sel, roles, 1, 1, 0);
            } else {
                layout = ((id (*)(id, SEL, id, NSInteger, NSInteger))objc_msgSend)(allocated, sel, roles, 1, i == 1 ? 0 : 1);
            }
            self.switcherBuildStatus = [NSString stringWithFormat:@"init%lu-%@", (unsigned long)i+1, layout ? @"ok" : @"nil"];
            if (layout) return layout;
        } @catch (NSException *e) {
            self.switcherBuildStatus = [NSString stringWithFormat:@"init%lu-ex", (unsigned long)i+1];
            NSLog(@"[InteractivePiP] split layout %@: %@", names[i], e);
        }
    }
    return nil;
}

#pragma mark - Switcher card (Stage C: current layout for data source)

- (void)observeSwitcherContentController:(id)controller {
    if (![NSThread isMainThread] || !controller) return;
    SEL sel = NSSelectorFromString(@"noteAppLayoutsDidChange");
    if (![controller respondsToSelector:sel]) return;
    if (self.switcherContentController == controller) return;
    self.switcherContentController = controller;
    // First data-source request may arrive after the split pair is created.
    // Defer one refresh off the callback stack; repeat reads of this same
    // controller do not schedule another one.
    if (self.activeSwitcherCard) [self requestSwitcherGroupRefresh];
}

- (void)requestSwitcherGroupRefresh {
    if (self.switcherRefreshScheduled) return;
    if (!self.switcherContentController) {
        self.switcherRefreshStatus = @"wait-controller";
        return;
    }
    self.switcherRefreshStatus = @"queued";
    self.switcherRefreshScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.switcherRefreshScheduled = NO;
        id controller = self.switcherContentController;
        SEL sel = NSSelectorFromString(@"noteAppLayoutsDidChange");
        NSMethodSignature *sig = [controller methodSignatureForSelector:sel];
        if (!sig || sig.numberOfArguments != 2 || sig.methodReturnType[0] != 'v') {
            self.switcherRefreshStatus = @"no-method";
            return;
        }
        @try {
            ((void (*)(id, SEL))objc_msgSend)(controller, sel);
            self.switcherRefreshStatus = @"called";
        } @catch (NSException *e) {
            self.switcherRefreshStatus = @"exception";
            NSLog(@"[InteractivePiP] group refresh: %@", e.name);
        }
    });
}

- (void)createSwitcherGroupCard {
    if (self.splitWindows.count != 2 || self.activeSwitcherCard) return;
    NSString *identifier = [@"com.seagull.interactivepip.group." stringByAppendingString:[NSUUID UUID].UUIDString];
    self.activeSwitcherCard = [self switcherLayoutForGroupIdentifier:identifier];
    self.switcherGroupIdentifier = self.activeSwitcherCard ? identifier : nil;
    NSLog(@"[InteractivePiP] group layout %@", self.switcherBuildStatus);
    if (self.activeSwitcherCard) { [self requestSwitcherGroupRefresh]; [self scheduleSwitcherPreviewRefresh]; }
}

- (nullable id)currentSwitcherLayout {
    return self.activeSwitcherCard;
}
static id DPSwitcherObjectValue(id obj, SEL sel) {
    NSMethodSignature *sig = [obj methodSignatureForSelector:sel];
    if (!sig || sig.numberOfArguments != 2 || sig.methodReturnType[0] != '@') return nil;
    return ((id(*)(id, SEL))objc_msgSend)(obj, sel);
}

- (BOOL)isSwitcherGroupDisplayItem:(id)item {
    if (!self.activeSwitcherCard || !self.switcherGroupIdentifier.length ||
        ![item isKindOfClass:NSClassFromString(@"SBDisplayItem")]) return NO;
    @try {
        id tag = DPSwitcherObjectValue(item, NSSelectorFromString(@"uniqueIdentifier"));
        return [tag isKindOfClass:[NSString class]] && [self.switcherGroupIdentifier isEqualToString:tag];
    } @catch (__unused NSException *e) { return NO; }
}

- (BOOL)isSwitcherCard:(id)layout {
    id card = self.activeSwitcherCard;
    if (!layout || !card || ![layout isKindOfClass:[card class]]) return NO;
    if (layout == card || [card isEqual:layout]) return YES;
    @try {
        id items = DPSwitcherObjectValue(layout, NSSelectorFromString(@"allItems"));
        if (![items isKindOfClass:[NSArray class]] && ![items isKindOfClass:[NSSet class]] && ![items isKindOfClass:[NSOrderedSet class]]) return NO;
        if ([items count] != 1) return NO;
        for (id item in items) {
            id tag = DPSwitcherObjectValue(item, NSSelectorFromString(@"uniqueIdentifier"));
            return [self.switcherGroupIdentifier isEqual:tag];
        }
    } @catch (__unused NSException *e) { }
    return NO;
}

- (void)noteSwitcherActivationCandidate:(id)layout source:(NSString *)source {
    if (!self.activeSwitcherCard || !layout) return;
    self.switcherTapStatus = [NSString stringWithFormat:@"candidate-%@", source ?: @"?"];
    NSLog(@"[InteractivePiP] switcher candidate source=%@ class=%@ ours=%@",
          source, NSStringFromClass([layout class]), [self isSwitcherCard:layout] ? @"YES" : @"NO");
}

- (void)activateSwitcherCard:(id)layout {
    if (self.activeSwitcherCard && layout) [self noteSwitcherActivationCandidate:layout source:@"activate"];
    if (![self isSwitcherCard:layout] || self.deviceLocked || self.switcherRestorePending) return;
    self.switcherRestorePending = YES;
    self.switcherTapStatus = @"received";
    NSUInteger epoch = ++self.switcherGestureEpoch;
    id card = self.activeSwitcherCard;
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 1.5;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self finishSwitcherRestore:epoch card:card deadline:deadline];
    });
}

- (void)finishSwitcherRestore:(NSUInteger)epoch card:(id)card deadline:(NSTimeInterval)deadline {
    if (epoch != self.switcherGestureEpoch) return;
    if (self.activeSwitcherCard != card || self.deviceLocked || self.splitWindows.count != 2) {
        self.switcherRestorePending = NO;
        self.switcherTapStatus = @"cancelled";
        return;
    }
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    UIWindowScene *saved = self.switcherHomeScene;
    if (saved && saved.activationState != UISceneActivationStateForegroundActive && now < deadline) {
        self.switcherTapStatus = @"wait-scene";
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self finishSwitcherRestore:epoch card:card deadline:deadline];
        });
        return;
    }
    self.switcherRestoreGraceUntil = now + 0.45;
    if (self.sessionParked) [self restoreParkedSession];
    else [self bringOverlayToFront];
    self.switcherRestorePending = NO;
    self.switcherTapStatus = self.overlayWindow.hidden ? @"hidden" : @"shown";
    dispatch_async(dispatch_get_main_queue(), ^{ [self showKeyboardDiagnostics]; });
    [self scheduleSwitcherPreviewRefresh];
    NSLog(@"[InteractivePiP] group tap %@ scene=%@", self.switcherTapStatus, self.overlayWindow.windowScene);
}

static BOOL DPHasPreviewDetail(UIImage *image) {
    CGImageRef cg = image.CGImage;
    if (!cg) return NO;
    uint8_t pixels[8 * 8 * 4] = {0};
    CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = color ? CGBitmapContextCreate(pixels, 8, 8, 8, 32, color, kCGImageAlphaPremultipliedLast) : NULL;
    if (color) CGColorSpaceRelease(color);
    if (!ctx) return NO;
    CGContextDrawImage(ctx, CGRectMake(0, 0, 8, 8), cg);
    CGContextRelease(ctx);
    for (NSUInteger i = 4; i < sizeof(pixels); i += 4) {
        for (NSUInteger j = 0; j < 3; j++) {
            if (abs((int)pixels[i+j] - (int)pixels[j]) > 12) return YES;
        }
    }
    return NO;
}

- (void)scheduleSwitcherPreviewRefresh {
    if (!self.activeSwitcherCard || self.splitWindows.count != 2 || self.sessionParked) return;
    // Debounce: layoutSplit runs every frame while dragging the divider; only
    // the last scheduled refresh may actually capture (earlier ones are voided).
    NSUInteger refreshGeneration = ++self.switcherPreviewRefreshGeneration;
    NSUInteger generation = self.sessionGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2 || self2.sessionParked || self2.deviceLocked) return;
        if (self2.sessionGeneration != generation || !self2.activeSwitcherCard || self2.splitWindows.count != 2) return;
        if (self2.switcherPreviewRefreshGeneration != refreshGeneration) return;
        [self2 captureSwitcherPaneImages];
        NSLog(@"[InteractivePiP] idle preview refresh panes=%lu", (unsigned long)self2.switcherPaneImages.count);
    });
}

- (void)captureSwitcherPaneImages {
    if (!self.activeSwitcherCard || self.sessionParked || self.splitWindows.count != 2) return;
    NSMutableArray *images = [NSMutableArray arrayWithCapacity:2];
    for (DPFloatingWindow *window in self.splitWindows) {
        UIView *view = window.sceneHost.view;
        __block BOOL drawn = NO;
        UIImage *image = nil;
        if (view.window && !view.window.hidden && view.bounds.size.width >= 2 && view.bounds.size.height >= 2) {
            @try {
                CGFloat scale = MIN(1.0, 240.0 / MAX(view.bounds.size.width, view.bounds.size.height));
                CGSize size = CGSizeMake(view.bounds.size.width * scale, view.bounds.size.height * scale);
                UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
                format.scale = 1;
                UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
                image = [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *ctx) {
                    drawn = [view drawViewHierarchyInRect:(CGRect){CGPointZero, size} afterScreenUpdates:NO];
                }];
            } @catch (__unused NSException *e) { }
        }
        [images addObject:(drawn && DPHasPreviewDetail(image)) ? (id)image : [NSNull null]];
    }
    self.switcherPaneImages = images;
}

- (UIView *)contentViewForSwitcherLayout:(id)layout {
    if (![self isSwitcherCard:layout] || self.splitWindows.count != 2) return nil;
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 390, 844)];
    container.backgroundColor = [UIColor colorWithWhite:0.16 alpha:1];
    container.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    container.clipsToBounds = YES;
    for (NSUInteger i = 0; i < 2; i++) {
        UIView *pane = [UIView new];
        pane.translatesAutoresizingMaskIntoConstraints = NO;
        pane.backgroundColor = i ? [UIColor colorWithRed:0.15 green:0.25 blue:0.37 alpha:1] : [UIColor colorWithRed:0.22 green:0.32 blue:0.43 alpha:1];
        pane.clipsToBounds = YES;
        [container addSubview:pane];
        [NSLayoutConstraint activateConstraints:@[
            [pane.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
            [pane.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
            [pane.heightAnchor constraintEqualToAnchor:container.heightAnchor multiplier:0.5 constant:-1],
            i ? [pane.bottomAnchor constraintEqualToAnchor:container.bottomAnchor] : [pane.topAnchor constraintEqualToAnchor:container.topAnchor]
        ]];
        id image = self.switcherPaneImages[i];
        if ([image isKindOfClass:[UIImage class]]) {
            UIImageView *preview = [[UIImageView alloc] initWithImage:image];
            preview.translatesAutoresizingMaskIntoConstraints = NO;
            preview.contentMode = UIViewContentModeScaleAspectFill;
            [pane addSubview:preview];
            [NSLayoutConstraint activateConstraints:@[
                [preview.leadingAnchor constraintEqualToAnchor:pane.leadingAnchor], [preview.trailingAnchor constraintEqualToAnchor:pane.trailingAnchor],
                [preview.topAnchor constraintEqualToAnchor:pane.topAnchor], [preview.bottomAnchor constraintEqualToAnchor:pane.bottomAnchor]]];
        } else {
            UILabel *name = [UILabel new];
            name.translatesAutoresizingMaskIntoConstraints = NO;
            name.text = self.splitWindows[i].bundleID;
            name.textColor = UIColor.whiteColor;
            name.font = [UIFont systemFontOfSize:23 weight:UIFontWeightSemibold];
            [pane addSubview:name];
            [NSLayoutConstraint activateConstraints:@[[name.centerXAnchor constraintEqualToAnchor:pane.centerXAnchor], [name.centerYAnchor constraintEqualToAnchor:pane.centerYAnchor]]];
        }
    }
    return container;
}

- (UIView *)makeSwitcherPageView:(id)layout {
    DPGroupPageView *pv = [[DPGroupPageView alloc] initWithFrame:CGRectMake(0, 0, 390, 844)];
    pv.appLayout = layout;
    UIView *content = [self contentViewForSwitcherLayout:layout];
    if (content) {
        content.frame = pv.bounds;
        [pv addSubview:content];
    }
    return pv;
}

#pragma mark - 0.7.186 runtime probe for split activation API
// 运行时枚举所有类，找出谁实现了 +requestForActivatingAppLayout:
// 真机上打日志，一次性定位正确的宿主类，不再靠猜。
- (void)probeSplitActivationAPI {
    SEL target = NSSelectorFromString(@"requestForActivatingAppLayout:");
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) { NSLog(@"[InteractivePiP] probe: no classes"); return; }
    Class *classes = (Class *)malloc(sizeof(Class) * count);
    if (!classes) return;
    count = objc_getClassList(classes, count);
    NSMutableArray *hits = [NSMutableArray array];
    for (int i = 0; i < count; i++) {
        Class C = classes[i];
        const char *nm = class_getName(C);
        if (!nm) continue;
        if (strncmp(nm, "SB", 2) != 0 && strncmp(nm, "FB", 2) != 0) continue;
        // 类方法
        if (class_getClassMethod(C, target)) {
            [hits addObject:[NSString stringWithFormat:@"+%s", nm]];
        }
        // 实例方法
        if (class_getInstanceMethod(C, target)) {
            [hits addObject:[NSString stringWithFormat:@"-%s", nm]];
        }
    }
    free(classes);
    NSLog(@"[InteractivePiP] probe requestForActivatingAppLayout: hits=%@", hits);

    // 0.7.188: 同时把结果写到固定文件，方便用 Filza 直接看，不用抓系统日志。
    NSString *path = @"/var/mobile/Library/Preferences/com.seagull.interactivepip.probe.txt";
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"requestForActivatingAppLayout hosts:\n%@\n\n", hits];
    // 顺便记录几个关键类的相关方法，一次问清
    NSArray *clsNames = @[@"SBMainWorkspaceTransitionRequest", @"SBSwitcherTransitionRequest",
                          @"SBMainSwitcherControllerCoordinator", @"SBMainWorkspace"];
    for (NSString *cn in clsNames) {
        Class C = NSClassFromString(cn);
        if (!C) { [out appendFormat:@"%@: NOT FOUND\n", cn]; continue; }
        [out appendFormat:@"=== %@ ===\n", cn];
        unsigned int mc = 0;
        // 类方法
        Method *cms = class_copyMethodList(object_getClass(C), &mc);
        for (unsigned int i = 0; i < mc; i++) {
            const char *nm = sel_getName(method_getName(cms[i]));
            if (strstr(nm, "Layout") || strstr(nm, "Transition") || strstr(nm, "Activat") || strstr(nm, "request")) {
                [out appendFormat:@"  +%s  %s\n", nm, method_getTypeEncoding(cms[i])];
            }
        }
        free(cms);
        // 实例方法
        mc = 0;
        Method *ims = class_copyMethodList(C, &mc);
        for (unsigned int i = 0; i < mc; i++) {
            const char *nm = sel_getName(method_getName(ims[i]));
            if (strstr(nm, "Layout") || strstr(nm, "Transition") || strstr(nm, "Activat") || strstr(nm, "request")) {
                [out appendFormat:@"  -%s  %s\n", nm, method_getTypeEncoding(ims[i])];
            }
        }
        free(ims);
        [out appendString:@"\n"];
    }
    [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"[InteractivePiP] probe written to %@", path);
}

@end

