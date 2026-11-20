#import "DPWindowManager.h"
#import "DPFloatingWindow.h"
#import "DPSceneHost.h"
#import "DPAppPicker.h"
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
@property (nonatomic, strong, nullable) id activeSwitcherCard;
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
    if (self.deviceLocked) return;
    if (![DPSettings shared].isEnabled) return;
    if (!bundleID.length) {
        [self handleActivationRequest];
        return;
    }
    if ([[DPSettings shared] isBundleBlacklisted:bundleID]) return;

    if (self.sessionParked) [self restoreParkedSession];
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
    if (!self.overlayRoot) return;
    DPFloatingWindow *f = self.focusedWindow;
    id sh = f.sceneHost;
    id kb = [self sharedRemoteKeyboards];
    UIView *hv = [sh keyboardRoutingView];
    id sc = [sh keyboardRoutingScene];
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"focus=%@\nhost=%@\n", f.bundleID ?: @"-",
       hv ? NSStringFromClass([hv class]) : @"nil"];
    [s appendFormat:@"scene=%@\n", sc ? NSStringFromClass([sc class]) : @"nil"];
    [s appendFormat:@"live=%d sceneView=%d pid=%d level=%.0f\n",
       [sh isLive] ? 1 : 0, [sh keyboardHostIsSceneView] ? 1 : 0,
       [sh keyboardRoutingPID], self.overlayWindow.windowLevel];
    [s appendFormat:@"hosted=%d _UIRemoteKeyboards=%d inst=%d factory=%s\n",
       self.hostedInputActive ? 1 : 0, kb ? 1 : 0, self.remoteKeyboardsInstance ? 1 : 0,
       self.remoteKeyboardsFactory ? sel_getName(self.remoteKeyboardsFactory) : "-"];
    [s appendFormat:@"wkscene=%@\n",
       NSStringFromClass([self.overlayWindow.windowScene class]) ?: @"nil"];
    if (kb) {
        if ([kb respondsToSelector:NSSelectorFromString(@"keyboardWindow")]) {
            @try {
                id kw = ((id (*)(id, SEL))objc_msgSend)(kb, NSSelectorFromString(@"keyboardWindow"));
                [s appendFormat:@"keyboardWindow=%@\n", kw ? NSStringFromClass([kw class]) : @"nil"];
            } @catch (__unused NSException *e) { [s appendFormat:@"keyboardWindow=ERR\n"]; }
        }
        [s appendFormat:@"hostedWin=%@\n", self.hostedKeyboardWindow ? NSStringFromClass([self.hostedKeyboardWindow class]) : @"nil"];
        unsigned n = 0;
        Method *ms = class_copyMethodList([kb class], &n);
        if (ms) {
            for (unsigned i = 0; i < n; i++) {
                NSString *nm = [NSString stringWithUTF8String:sel_getName(method_getName(ms[i]))];
                BOOL hit = [nm rangeOfString:@"Hosted"].location != NSNotFound ||
                           [nm rangeOfString:@"inputWindowController"].location != NSNotFound ||
                           [nm rangeOfString:@"keyboardWindow"].location != NSNotFound;
                if (!hit) continue;
                const char *t = method_getTypeEncoding(ms[i]);
                [s appendFormat:@" %@ %s\n", nm, t ? t : "-"];
            }
            free(ms);
        }
    }
    if (!self.diagLabel) {
        UILabel *l = [[UILabel alloc] init];
        l.tag = 0x445044;
        l.font = [UIFont monospacedSystemFontOfSize:8 weight:UIFontWeightRegular];
        l.textColor = [UIColor yellowColor];
        l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.8];
        l.numberOfLines = 0;
        l.layer.cornerRadius = 6;
        self.diagLabel = l;
        [self.overlayRoot addSubview:l];
    }
    self.diagLabel.text = s;
    CGFloat w = self.overlayRoot.bounds.size.width;
    self.diagLabel.frame = CGRectMake(6, 70, MIN(w - 12, 330), 250);
    self.diagLabel.hidden = NO;
}

- (void)prepareForHostedInput {
    if (self.deviceLocked || !self.overlayWindow || self.overlayWindow.hidden || !self.focusedWindow) return;
    [self.focusedWindow.sceneHost prepareForInput];
    [self configureRemoteKeyboardsForHostedInput:YES];
    UIView *host = [self.focusedWindow.sceneHost keyboardRoutingView];
    id scene = [self.focusedWindow.sceneHost keyboardRoutingScene];
    id kb = [self sharedRemoteKeyboards];
    if (kb && host && scene) {
        [self attemptRemoteKeyboardsRegistration:kb host:host pid:[self.focusedWindow.sceneHost keyboardRoutingPID] scene:scene];
    }
    [self attemptKeyboardScenePairingWithScene:scene host:host];
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

- (void)hostedKeyboardWillShow { /* Never steal keyboard focus on a notification. */ }
- (void)hostedKeyboardWillHide { [self restorePreviousKeyWindow]; }

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
    seam.backgroundColor = [UIColor blackColor];
    seam.userInteractionEnabled = NO;
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
    [self focusWindow:second];
}

- (void)layoutSplit {
    if (self.splitWindows.count != 2) return;
    CGRect full = self.overlayRoot.bounds;
    // Duo: panels fill the entire screen edge to edge (no status/home inset).
    CGRect b = full;
    BOOL sideBySide = b.size.width >= b.size.height;
    const CGFloat seamW = 8.0;                     // visible dark divider line
    const CGFloat touch = 20.0;                    // invisible draggable strip over the seam
    CGFloat total = sideBySide ? b.size.width : b.size.height;
    CGFloat ratio = MIN(0.95, MAX(0.05, self.splitRatio));
    CGFloat first = floor(total * ratio);          // panes meet at the seam: no gap
    CGRect a = b, c = b, h = b;
    if (sideBySide) {
        a.size.width = first;
        c.origin.x = b.origin.x + first; c.size.width = total - first;   // second pane fills rest
        h.origin.x = b.origin.x + first - touch / 2.0; h.size.width = touch;
    } else {
        a.size.height = first;
        c.origin.y = b.origin.y + first; c.size.height = total - first;
        h.origin.y = b.origin.y + first - touch / 2.0; h.size.height = touch;
    }
    for (DPFloatingWindow *w in self.splitWindows) {
        [w.layer removeAllAnimations];
        w.transform = CGAffineTransformIdentity;
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
        if (sideBySide) line.frame = CGRectMake((touch - seamW) / 2.0, 0, seamW, h.size.height);
        else line.frame = CGRectMake(0, (touch - seamW) / 2.0, h.size.width, seamW);
    }
    [self.overlayRoot bringSubviewToFront:self.splitDivider];
    [self updateSessionControls];
}

// Duo keeps the hinge fixed; drag gestures on the divider are intentionally
// absent so the two panes behave like two physical displays.

- (void)leaveSplit {
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

- (void)handleHomeGestureEnded {
    // Called when a FluidSwitcher pan gesture ends. Decide asynchronously
    // whether it was a "swipe to Home": session still alive AND the foreground
    // app is no longer one we host (nil / SpringBoard / another app) => Home.
    if (self.mode == DPPresentationModeNone || self.deviceLocked || self.internalHomeReturn) return;
    NSUInteger generation = self.sessionGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2 || generation != self2.sessionGeneration || self2.deviceLocked) return;
        if (self2.mode == DPPresentationModeNone) return;
        NSString *fg = [self2 foregroundBundleID];
        // If a hosted app is still foreground, this was an app switch / open — keep the session.
        if (fg.length && [self2.mutableHostedBundleIDs containsObject:fg]) return;
        NSLog(@"[InteractivePiP] 上滑回桌面 -> 挂到后台任务列表 (fg=%@)", fg ?: @"(none)");
        [self2 parkSessionInAppSwitcher];
    });
}

- (void)parkSessionInAppSwitcher {
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

- (void)handleUserHome {
    if (!self.internalHomeReturn) [self dismissAllAnimated:NO];
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

#pragma mark - Split ratio drag

- (void)handleSplitDrag:(UIPanGestureRecognizer *)gr {
    if (self.splitWindows.count != 2 || !self.overlayRoot) return;
    CGRect full = self.overlayRoot.bounds;
    BOOL sideBySide = (full.size.width >= full.size.height);
    CGFloat available = sideBySide ? full.size.width : full.size.height;
    if (available <= 1) return;

    CGPoint p = [gr locationInView:self.overlayRoot];
    CGFloat pos = sideBySide ? p.x : p.y;
    self.splitRatio = MIN(0.95, MAX(0.05, pos / available));
    [self layoutSplit];
    [[NSUserDefaults standardUserDefaults] setDouble:self.splitRatio forKey:@"sg.split.lastRatio"];
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

- (nullable id)switcherLayoutForBundleIDs:(NSArray<NSString *> *)bundleIDs {
    if (bundleIDs.count == 0) return nil;
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *bid in bundleIDs) {
        id di = [self displayItemForBundleID:bid];
        NSLog(@"[InteractivePiP] displayItemForBundleID %@ -> %@", bid, di?@"YES":@"NO");
        if (di) [items addObject:di];
    }
    if (items.count == 0) { NSLog(@"[InteractivePiP] switcherLayout: no displayItems"); return nil; }

    Class SBAppLayoutCls = NSClassFromString(@"SBAppLayout");
    if (!SBAppLayoutCls) return nil;
    id layout = nil;

    // 优先：initWithItemsForLayoutRoles:configuration:environment:preferredDisplayOrdinal:
    SEL s1 = NSSelectorFromString(@"initWithItemsForLayoutRoles:configuration:environment:preferredDisplayOrdinal:");
    if ([SBAppLayoutCls instancesRespondToSelector:s1]) {
        @try {
            layout = ((id(*)(id, SEL, id, id, id, id, long))objc_msgSend)(
                [[SBAppLayoutCls alloc] init], s1, items, @[@1], nil, nil, 0);
        } @catch (__unused NSException *e) { layout = nil; }
    }
    // 旧变体：initWithItemsForLayoutRoles:environment:preferredDisplayOrdinal:
    if (!layout) {
        SEL s2 = NSSelectorFromString(@"initWithItemsForLayoutRoles:environment:preferredDisplayOrdinal:");
        if ([SBAppLayoutCls instancesRespondToSelector:s2]) {
            @try {
                layout = ((id(*)(id, SEL, id, id, id, long))objc_msgSend)(
                    [[SBAppLayoutCls alloc] init], s2, items, @[@1], nil, 0);
            } @catch (__unused NSException *e) { layout = nil; }
        }
    }
    return layout;
}

#pragma mark - Switcher card (Stage C: current layout for data source)

- (nullable id)currentSwitcherLayout {
    if (self.mode != DPPresentationModeSplit || self.splitWindows.count < 2) {
        NSLog(@"[InteractivePiP] currentSwitcherLayout nil: mode=%ld count=%lu", (long)self.mode, (unsigned long)self.splitWindows.count);
        return nil;
    }
    // Cache the same SBAppLayout instance so the switcher data source and the
    // bring-to-front hook see one identical object.
    if (self.activeSwitcherCard) return self.activeSwitcherCard;
    NSMutableArray *bids = [NSMutableArray array];
    for (DPFloatingWindow *w in self.splitWindows) {
        if (w.bundleID) [bids addObject:w.bundleID];
    }
    if (bids.count < 2) return nil;
    id layout = [self switcherLayoutForBundleIDs:bids];
    NSLog(@"[InteractivePiP] currentSwitcherLayout built=%@ bids=%@", layout?@"YES":@"NO", bids);
    if (layout) self.activeSwitcherCard = layout;
    return layout;
}
- (BOOL)isSwitcherCard:(id)layout {
    return (layout && layout == self.activeSwitcherCard);
}
- (void)activateSwitcherCard:(id)layout {
    if (![self isSwitcherCard:layout]) return;
    NSLog(@"[InteractivePiP] Switcher 卡被点击 -> 恢复分屏会话");
    self.activeSwitcherCard = nil;
    [self restoreParkedSession];
}

- (UIView *)contentViewForSwitcherLayout:(id)layout {
    if (self.splitWindows.count < 2) return nil;
    DPFloatingWindow *w0 = self.splitWindows[0];
    DPFloatingWindow *w1 = self.splitWindows[1];
    UIView *v0 = w0.sceneHost.view;
    UIView *v1 = w1.sceneHost.view;
    if (!v0 || !v1) return nil;

    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 390, 844)];
    container.backgroundColor = [UIColor blackColor];
    container.clipsToBounds = YES;

    BOOL sideBySide = (container.bounds.size.width > container.bounds.size.height);
    CGRect r0, r1;
    if (sideBySide) {
        CGFloat w = container.bounds.size.width * 0.5;
        r0 = CGRectMake(0, 0, w, container.bounds.size.height);
        r1 = CGRectMake(w, 0, container.bounds.size.width - w, container.bounds.size.height);
    } else {
        CGFloat h = container.bounds.size.height * 0.5;
        r0 = CGRectMake(0, 0, container.bounds.size.width, h);
        r1 = CGRectMake(0, h, container.bounds.size.width, container.bounds.size.height - h);
    }

    // 快照方式：把每个 pane 的画面截图成 UIImageView，不移动原视图
    // （若直接 addSubview sceneHost.view 会把它从分屏父视图移除，破坏分屏）
    @try {
        UIGraphicsImageRenderer *ren = [[UIGraphicsImageRenderer alloc] initWithSize:r0.size];
        UIImage *img0 = [ren imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            BOOL ok = [v0 drawViewHierarchyInRect:CGRectMake(0, 0, r0.size.width, r0.size.height) afterScreenUpdates:NO];
            if (!ok) {
                [[UIColor darkGrayColor] setFill];
                UIRectFill(CGRectMake(0, 0, r0.size.width, r0.size.height));
            }
        }];
        UIImage *img1 = [ren imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            BOOL ok = [v1 drawViewHierarchyInRect:CGRectMake(0, 0, r1.size.width, r1.size.height) afterScreenUpdates:NO];
            if (!ok) {
                [[UIColor darkGrayColor] setFill];
                UIRectFill(CGRectMake(0, 0, r1.size.width, r1.size.height));
            }
        }];
        UIImageView *iv0 = [[UIImageView alloc] initWithImage:img0];
        iv0.frame = r0;
        UIImageView *iv1 = [[UIImageView alloc] initWithImage:img1];
        iv1.frame = r1;
        [container addSubview:iv0];
        [container addSubview:iv1];
    } @catch (__unused NSException *e) {
        // 截图失败：至少放两个标签示意
        UILabel *la = [[UILabel alloc] initWithFrame:r0];
        la.text = w0.bundleID ?: @"App1";
        la.textColor = [UIColor whiteColor];
        la.textAlignment = NSTextAlignmentCenter;
        UILabel *lb = [[UILabel alloc] initWithFrame:r1];
        lb.text = w1.bundleID ?: @"App2";
        lb.textColor = [UIColor whiteColor];
        lb.textAlignment = NSTextAlignmentCenter;
        [container addSubview:la];
        [container addSubview:lb];
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

@end
