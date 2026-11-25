#import "SPGesture.h"
#import "SPCompat.h"
#import "SPHost.h"
#import "SPSettings.h"
#import "SPParkCard.h"

// SPParked.m 提供
@interface SPParked : NSObject
+ (void)install;
+ (void)parkFrontmostApp;
+ (BOOL)isArmed;
+ (NSString *)parkedBundleID;
+ (void)cancelPendingSession;
@end
#import "SPAppPicker.h"
#import "SPPaneController.h"
#import "SPLog.h"
#import "SPWindowRegistry.h"
#import <math.h>

// 入口层。三条通道，按可靠性排序：
//   1) hook 系统 home 手势的 touchesEnded（Duo 实证这条路能接住）
//   2) 自己往 SpringBoard 主窗口挂一个 pan（钩子失效时的备份，但会和系统抢触摸）
//   3) 状态栏双击 —— 完全不经手势，纯兜底，装完试这个最快
// 每个分支都落日志，装上没反应时能一眼看出断在哪。

static const CGFloat kBottomStrip = 110.0;   // 起手必须在这条带里（pt）
static const CGFloat kStatusStrip = 54.0;    // 状态栏双击命中区

@interface SPGesture () <SPParkCardDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, strong) SPParkCard *card;
@property (nonatomic, strong) UIImage *parkedSnapshot;
@property (nonatomic, copy) NSString *parkedBundleID;
@property (nonatomic, assign) BOOL busy;
@property (nonatomic, assign) double lastExitAt;   // 上次退出分屏的时间
@property (nonatomic, weak) UIWindowScene *scene;
@property (nonatomic, assign) CGFloat dragStartY;
@property (nonatomic, assign) CGFloat dragPeakY;
@property (nonatomic, assign) BOOL tracking;
@property (nonatomic, strong) UIPanGestureRecognizer *fallbackPan;
@property (nonatomic, strong) UITapGestureRecognizer *statusTap;
@property (nonatomic, weak) UIView *panHost;
@property (nonatomic, strong) NSMutableArray<UITapGestureRecognizer *> *statusTaps;
@property (nonatomic, assign) NSUInteger pickerGeneration;
- (BOOL)beginTrackingAtPoint:(CGPoint)loc;
- (void)removeStatusTaps;
- (void)removeFallbackPan;
- (UIWindowScene *)windowSceneForEntry;
- (void)presentPickerForSplitWithParked:(NSString *)parked needPark:(BOOL)needPark;
- (void)returnToHomeDismissingApp:(NSString *)bundleID;
@end

@implementation SPGesture

+ (instancetype)shared {
    static SPGesture *inst; static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [SPGesture new]; });
    return inst;
}

#pragma mark - 装入口

- (void)installInWindowScene:(UIWindowScene *)scene {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self installInWindowScene:scene]; });
        return;
    }
    if (scene && scene != _scene) {
        [self removeStatusTaps];
        [self removeFallbackPan];
        _scene = scene;
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self name:SPNotifyChanged object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(settingsChanged)
                                                 name:SPNotifyChanged object:nil];

    UIWindowScene *ws = scene ?: _scene;
    if (!ws) { SPLog(@"install: no window scene yet"); return; }
    @try {
        [self settingsChanged];
    } @catch (NSException *e) {
        SPLog(@"install ex %@", e.reason);
    }
    SPLog(@"install: scene ok hooks=%d statusTap=%d fallbackPan=%d",
          self.hooksAvailable, _statusTap != nil, self.fallbackPan != nil);
}

- (UIWindow *)springBoardWindowInScene:(UIWindowScene *)scene {
    // 日志实证的窗口栈：-2:SBHomeScreenWindow / 0:SBRootSceneWindow / 0:SBSystemApertureWindow
    // 状态栏那层的 host 用 SBRootSceneWindow 最靠谱。
    UIWindow *root = nil, *home = nil;
    for (UIWindow *w in scene.windows) {
        if ([[SPWindowRegistry registeredWindows] containsObject:w]) continue;
        if (w.isHidden || w.alpha < 0.01) continue;
        if (w.windowLevel > UIWindowLevelStatusBar) continue;
        // 排除我们家自己的 overlay（level 1~4），否则会把卡片/分屏窗口当成 SpringBoard 主窗口
        if (w.windowLevel > UIWindowLevelNormal && w.windowLevel < 100) continue;
        NSString *cn = NSStringFromClass(w.class);
        if ([cn containsString:@"RootScene"]) root = w;
        else if ([cn containsString:@"HomeScreen"]) home = w;
    }
    if (root) return root;
    if (home) return home;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.windowScene != scene || [[SPWindowRegistry registeredWindows] containsObject:w]) continue;
        if (w.isHidden || w.alpha <= 0.01) continue;
        if (w.windowLevel > UIWindowLevelNormal && w.windowLevel < 100) continue;
        if (w.windowLevel <= UIWindowLevelStatusBar) return w;
    }
    return nil;
}

- (void)installStatusTapInScene:(UIWindowScene *)scene {
    if (_statusTap) return;
    UIWindow *host = [self springBoardWindowInScene:scene];
    if (!host) {
        NSMutableArray *names = [NSMutableArray array];
        for (UIWindow *w in scene.windows) [names addObject:NSStringFromClass(w.class)];
        SPLog(@"statusTap: no host window (scene has %lu: %@)", (unsigned long)scene.windows.count,
              [names componentsJoinedByString:@","]);
        return;
    }
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(statusDoubleTapped:)];
    tap.numberOfTapsRequired = 2;
    tap.delegate = self;
    tap.cancelsTouchesInView = NO;
    [host addGestureRecognizer:tap];
    _statusTap = tap;
    _statusTaps = [NSMutableArray arrayWithObject:tap];

    // 状态栏本身是独立 window/子树：普通点击可能被系统吞掉，再往它的状态栏管理视图上挂一份
    @try {
        Class sbc = NSClassFromString(@"SBStatusBarManager");
        id mgr = sbc ? SPMsg0(sbc, @"sharedInstance") : nil;
        NSArray *views = nil;
        for (NSString *k in @[@"statusBarViews", @"_statusBars", @"statusBars"]) {
            id v = SPMsg0(mgr, k);
            if ([v isKindOfClass:[NSArray class]]) { views = v; break; }
        }
        for (UIView *sv in views) {
            if (![sv isKindOfClass:[UIView class]] || sv.window.windowScene != scene) continue;
            UITapGestureRecognizer *t2 = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(statusDoubleTapped:)];
            t2.numberOfTapsRequired = 2;
            t2.delegate = self;
            t2.cancelsTouchesInView = NO;
            [sv addGestureRecognizer:t2];
            [_statusTaps addObject:t2];
        }
        SPLog(@"statusTap installed on %@ + %lu status bars", NSStringFromClass(host.class),
              (unsigned long)views.count);
    } @catch (NSException *e) {
        SPLog(@"statusTap bar ex %@", e.reason);
    }
}

- (void)installFallbackPanInScene:(UIWindowScene *)scene {
    if (_fallbackPan) return;
    UIView *host = [self springBoardWindowInScene:scene];
    if (!host) return;
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(fallbackPanned:)];
    pan.delegate = self;
    pan.cancelsTouchesInView = NO;
    pan.maximumNumberOfTouches = 1;
    [host addGestureRecognizer:pan];
    _fallbackPan = pan;
    _panHost = host;
    SPLog(@"fallback pan installed");
}

- (void)removeStatusTaps {
    for (UITapGestureRecognizer *tap in [_statusTaps copy]) [tap.view removeGestureRecognizer:tap];
    _statusTaps = nil;
    _statusTap = nil;
}

- (void)removeFallbackPan {
    [_fallbackPan.view removeGestureRecognizer:_fallbackPan];
    _fallbackPan = nil;
    _panHost = nil;
    [self cancelTracking];
}

- (void)settingsChanged {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self settingsChanged]; });
        return;
    }
    [self cancelTracking];
    BOOL enabled = [SPSettings enabled];
    if (!enabled || ![SPSettings statusTapEnabled]) [self removeStatusTaps];
    else if (_scene) [self installStatusTapInScene:_scene];
    if (!enabled || ![SPSettings fallbackPanEnabled] || (self.hooksAvailable && [SPSettings hooksEnabled]))
        [self removeFallbackPan];
    else if (_scene) [self installFallbackPanInScene:_scene];
    if (!enabled) {
        ++_pickerGeneration;
        _busy = NO;
        [SPParked cancelPendingSession];
        [SPParkCard dismissAll];
        self.card = nil;
        self.parkedBundleID = nil;
        self.parkedSnapshot = nil;
    }
}

#pragma mark - 手势代理

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)touch {
    if (![SPSettings enabled] || _busy || [SPAppPicker isPresenting] ||
        [[SPWindowRegistry registeredWindows] containsObject:touch.window]) return NO;
    CGPoint p = [touch.window convertPoint:[touch locationInView:touch.window] toWindow:nil];
    if ([_statusTaps containsObject:(UITapGestureRecognizer *)g])
        return [SPSettings statusTapEnabled] && isfinite(p.y) && p.y >= 0 && p.y <= kStatusStrip;
    if (g == _fallbackPan) {
        if (![SPSettings fallbackPanEnabled] || (self.hooksAvailable && [SPSettings hooksEnabled])) return NO;
        return [self beginTrackingAtPoint:p]; // 用真正的 touchesBegan，不用 pan 达到识别阈值后的坐标
    }
    return NO;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if (![SPSettings enabled] || _busy || [SPAppPicker isPresenting]) return NO;
    if (g == _fallbackPan) {
        CGPoint v = [(UIPanGestureRecognizer *)g velocityInView:g.view];
        BOOL upward = _tracking && v.y < 0 && fabs(v.y) > fabs(v.x);
        if (!upward) [self cancelTracking];
        return upward;
    }
    return [_statusTaps containsObject:(UITapGestureRecognizer *)g] && [SPSettings statusTapEnabled];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

#pragma mark - 状态栏双击（兜底入口）

- (void)statusDoubleTapped:(UITapGestureRecognizer *)g {
    if (![SPSettings enabled] || ![SPSettings statusTapEnabled] ||
        g.state != UIGestureRecognizerStateRecognized || ![_statusTaps containsObject:(UITapGestureRecognizer *)g]) return;
    @try { [self _statusDoubleTapped]; } @catch (NSException *e) { SPLog(@"statusTap ex %@", e.reason); }
}

- (void)_statusDoubleTapped {
    if (_busy || [SPAppPicker isPresenting]) return;
    NSString *front = [self frontmostBundleID];
    SPLog(@"status double tap, front=%@ active=%d", front, (int)SPPaneController.shared.active);
    if (SPPaneController.shared.active) {
        // 分屏中上滑 = 回桌面（用户明确要求）。
        // 之前这里弹「换 App」面板，导致退出后又立刻进分屏，看起来像退不出去。
        SPLog(@"pan in split -> stop (back to home)");
        _lastExitAt = CFAbsoluteTimeGetCurrent();
        [SPPaneController.shared stopWithCompletion:nil];
        return;
    }
    if (_lastExitAt > 0 && CFAbsoluteTimeGetCurrent() - _lastExitAt < 1.2) return;
    if (!front.length || [front isEqualToString:@"com.apple.springboard"]) return;
    [self presentPickerForSplitWithParked:front needPark:NO];
}

#pragma mark - 备份 pan

- (void)fallbackPanned:(UIPanGestureRecognizer *)g {
    @try { [self _fallbackPanned:g]; } @catch (NSException *e) { SPLog(@"fallbackPan ex %@", e.reason); }
}

- (void)_fallbackPanned:(UIPanGestureRecognizer *)g {
    if (g != _fallbackPan) return;
    if (g.state == UIGestureRecognizerStateCancelled || g.state == UIGestureRecognizerStateFailed ||
        ![SPSettings enabled] || ![SPSettings fallbackPanEnabled]) {
        [self cancelTracking];
        return;
    }
    CGPoint p = [g.view.window convertPoint:[g locationInView:g.view.window] toWindow:nil];
    [self handleHomePanMoved:p];
    if (g.state != UIGestureRecognizerStateEnded) return;
    [self consumeHomePan:g translation:[g translationInView:g.view] velocity:[g velocityInView:g.view]];
}

#pragma mark - 前台 App

- (NSString *)frontmostBundleID {
    // 本机实证：allApplications 里 isForeground/isFrontmost 都不命中（193 个 App 全是 n），
    // allScenes 是 0。真正的前台 getter 挂在 SpringBoard 自己身上（Duo 注释 + 实测）。
    // 顺序：SpringBoard 的 frontmost getter → SBApplicationController 同名 getter → 打分兜底。
    NSMutableArray *owners = [NSMutableArray arrayWithObject:[UIApplication sharedApplication]];
    Class ac = NSClassFromString(@"SBApplicationController");
    id ctrl = ac ? SPMsg0(ac, @"sharedInstance") : nil;
    if (ctrl) [owners addObject:ctrl];

    NSArray *getters = @[@"_accessibilityFrontMostApplication", @"_frontMostApplication",
                         @"frontmostApplication", @"focusedApplication"];
    for (id owner in owners) {
        for (NSString *name in getters) {
            @try {
                SEL getter = NSSelectorFromString(name);
                if (![owner respondsToSelector:getter]) continue;
                NSMethodSignature *sig = [owner methodSignatureForSelector:getter];
                if (sig.numberOfArguments != 2 || sig.methodReturnType[0] != '@') continue;
                id app = ((id (*)(id, SEL))objc_msgSend)(owner, getter);
                if (!app) continue;
                id bidObj = SPMsg0(app, @"bundleIdentifier");
                if ([bidObj isKindOfClass:[NSString class]] && [(NSString *)bidObj length]) {
                    SPLog(@"frontmost via %@.%@ = %@", NSStringFromClass([owner class]), name, bidObj);
                    return (NSString *)bidObj;
                }
            } @catch (NSException *e) { SPLog(@"frontmost %@ ex %@", name, e.reason); }
        }
    }

    // 兜底：按「最后活跃」打分
    Class ac2 = NSClassFromString(@"SBApplicationController");
    id c2 = ac2 ? SPMsg0(ac2, @"sharedInstance") : nil;
    NSArray *apps = SPMsg0(c2, @"allApplications");
    NSString *best = nil; NSInteger bestScore = 0;
    for (id app in apps) {
        @try {
            id b = SPMsg0(app, @"bundleIdentifier");
            if (![b isKindOfClass:[NSString class]] || ![(NSString *)b length]) continue;
            NSInteger score = 0;
            if (SPBool0(app, @"isForeground")) score = 50;
            if (SPBool0(app, @"isFrontmost")) score += 30;
            id hs = SPMsg0(app, @"sceneHandles");
            if ([hs isKindOfClass:[NSArray class]]) score += (NSInteger)[hs count] * 5;
            if (SPBool0(app, @"isRunningBackground")) score -= 10;
            if (score > bestScore) { bestScore = score; best = b; }
        } @catch (__unused NSException *e) {}
    }
    if (best) SPLog(@"frontmost fallback=%@ score=%ld", best, (long)bestScore);
    else SPLog(@"frontmost: none (apps=%lu)", (unsigned long)([apps isKindOfClass:[NSArray class]] ? apps.count : 0));
    return best;
}

- (NSString *)displayNameForBundleID:(NSString *)bid {
    id app = [SPHost applicationProxyForBundleID:bid];
    id name = SPMsg0(app, @"displayName");
    return [name isKindOfClass:[NSString class]] ? name : bid;
}

#pragma mark - 上滑判定

// 触摸落在分屏窗口里：取消本次手势追踪，别误判
- (void)cancelTracking {
    _tracking = NO;
    _dragStartY = 0;
    _dragPeakY = 0;
}

- (BOOL)beginTrackingAtPoint:(CGPoint)loc {
    [self cancelTracking];
    CGSize size = [UIScreen mainScreen].bounds.size;
    if (![SPSettings enabled] || _busy || [SPAppPicker isPresenting] || [SPParked isArmed] ||
        !isfinite(loc.x) || !isfinite(loc.y) || loc.x < 0 || loc.x > size.width ||
        loc.y < size.height - kBottomStrip || loc.y > size.height) return NO;
    _dragStartY = loc.y;
    _dragPeakY = loc.y;
    _tracking = YES;
    return YES;
}

- (void)handleHomePanBegan:(CGPoint)loc {
    if (![SPSettings hooksEnabled] || !self.hooksAvailable) { [self cancelTracking]; return; }
    [self beginTrackingAtPoint:loc];
}

// pan 每动一次就更新最高点（touchesEnded 时 translation 已被清零，只能自己记）
- (void)handleHomePanMoved:(CGPoint)loc {
    if (!_tracking) return;
    if (!isfinite(loc.x) || !isfinite(loc.y)) { [self cancelTracking]; return; }
    if (loc.y < _dragPeakY) _dragPeakY = loc.y;
}

- (BOOL)consumeHomePan:(UIPanGestureRecognizer *)pan translation:(CGPoint)translation velocity:(CGPoint)velocity {
    @try { return [self _consumeHomePan:pan translation:translation velocity:velocity]; }
    @catch (NSException *e) { [self cancelTracking]; SPLog(@"consume ex %@", e.reason); return NO; }
}

- (BOOL)_consumeHomePan:(UIPanGestureRecognizer *)pan translation:(CGPoint)translation velocity:(CGPoint)velocity {
    (void)pan; (void)velocity;
    if (!_tracking) return NO; // 没有本次有效起手时，绝不能沿用上一次的 start/peak
    CGFloat startY = _dragStartY;
    CGFloat peakY = _dragPeakY;
    [self cancelTracking];
    if (![SPSettings enabled] || _busy || [SPAppPicker isPresenting] || [SPParked isArmed]) return NO;

    CGFloat h = [UIScreen mainScreen].bounds.size.height;
    // 只用真实走过的距离；速度推算会把底边短促轻扫放大成「已到灵动岛」。
    CGFloat up = startY - peakY;
    if (isfinite(translation.y)) up = MAX(up, -translation.y);
    CGFloat need = h * [SPSettings parkThreshold];
    BOOL fromBottom = (startY >= h - kBottomStrip && startY <= h);
    SPLog(@"pan up=%.0f need=%.0f startY=%.0f fromBottom=%d active=%d",
          up, need, startY, fromBottom, (int)SPPaneController.shared.active);

    if (!fromBottom) return NO;
    if (up < need) return NO;
    // 刚退出分屏 1.2 秒内的上滑忽略：用户是想回桌面，不是想再开一个
    if (_lastExitAt > 0 && CFAbsoluteTimeGetCurrent() - _lastExitAt < 1.2) {
        SPLog(@"ignored: %.2fs since last exit", CFAbsoluteTimeGetCurrent() - _lastExitAt);
        return NO;
    }

    // 保留 0.7.0 当前可达的退出语义；退出不应依赖私有前台 getter 是否成功。
    if (SPPaneController.shared.active) {
        SPLog(@"pan: 分屏中上划 -> 直接拆窗回桌面");
        _lastExitAt = CFAbsoluteTimeGetCurrent();
        [SPPaneController.shared stopWithCompletion:nil];
        return YES;
    }
    NSString *front = [self frontmostBundleID];
    if (!front.length || [front isEqualToString:@"com.apple.springboard"]) return NO;

    // ===== 主路径（PV 式）：全屏 App 内从底部上划到「灵动岛高度」松手 → 挂起该 App =====
    // 之后用户自己点开任意 App，SPParked 监听到新的前台 App 就自动组建分屏。
    // 判定：从底部起手 + 手指越过灵动岛以下约 120pt 的区域（约屏幕顶部 15%）
    if (!SPPaneController.shared.active && fromBottom) {
        CGFloat islandLine = h * 0.15;   // 灵动岛下沿附近
        BOOL reachedIsland = (peakY <= islandLine) || (up >= h * 0.75);
        if (reachedIsland) {
            SPLog(@"pan: 上划到灵动岛 (peakY=%.0f islandLine=%.0f) -> 挂起前台 App", peakY, islandLine);
            [SPParked parkFrontmostApp];
            return YES;
        }
        SPLog(@"pan: 上划未到灵动岛 (peakY=%.0f need<=%.0f)，放行系统", peakY, islandLine);
        return NO;
    }

    return NO;
}

#pragma mark - 挂起

- (UIImage *)snapshotScreen {
    UIWindow *key = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isHidden || w.alpha < 0.01) continue;
        if (w.windowLevel > UIWindowLevelStatusBar) continue;
        if (w.windowLevel > UIWindowLevelNormal && w.windowLevel < 100) continue;
        key = w;
    }
    if (!key) return nil;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:key.bounds.size];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [key drawViewHierarchyInRect:key.bounds afterScreenUpdates:NO];
    }];
}

- (void)parkForegroundApp:(NSString *)bundleID {
    if (![SPSettings enabled] || _busy || [SPAppPicker isPresenting] || SPPaneController.shared.active || !bundleID.length) return;
    // 不再停一张小卡片：上滑到位就直接冻结画面 + 弹「选 App」面板。
    // （用户要求：图 1 那种浮在桌面的小卡片彻底不要，桌面底部也不能留残留窗口）
    [SPParkCard dismissAll];
    self.card = nil;

    _parkedBundleID = bundleID;
    UIImage *shot = [self snapshotScreen];
    self.parkedSnapshot = shot;
    SPLog(@"park %@ snapshot=%@ -> open picker directly", bundleID, shot ? @"ok" : @"nil");

    // 先把前台 App 让开，再弹面板；面板是独立窗口，不依赖任何卡片
    [self presentPickerForSplitWithParked:bundleID needPark:NO];
}

- (void)sendHomePress {
    // 统一走 SPHost 的真实实现（handleHomeButtonSinglePressUpForWindowScene:）
    BOOL ok = [SPHost homePress];
    SPLog(@"home pressed=%d (diag=%@)", (int)ok, [SPHost homePressDiag]);
}

#pragma mark - 卡片 / 面板

- (void)parkCardDidTap:(SPParkCard *)card {
    SPLog(@"card tap %@", card.bundleID);
    [self presentPickerForSplitWithParked:card.bundleID needPark:YES];
}

- (UIWindowScene *)windowSceneForEntry {
    NSSet<UIScene *> *scenes = [UIApplication sharedApplication].connectedScenes;
    if (_scene && [scenes containsObject:_scene] &&
        _scene.activationState == UISceneActivationStateForegroundActive &&
        ![NSStringFromClass(_scene.class) containsString:@"Aperture"]) return _scene;
    for (UIScene *scene in scenes) {
        if ([scene isKindOfClass:[UIWindowScene class]] &&
            scene.activationState == UISceneActivationStateForegroundActive &&
            ![NSStringFromClass(scene.class) containsString:@"Aperture"]) return (UIWindowScene *)scene;
    }
    return nil;
}

- (void)presentPickerForSplitWithParked:(NSString *)parked needPark:(BOOL)needPark {
    if (![SPSettings enabled] || !parked.length || _busy || [SPAppPicker isPresenting] || SPPaneController.shared.active) return;
    [SPParked cancelPendingSession];
    _busy = YES;
    NSUInteger generation = ++_pickerGeneration;
    UIImage *snapshot = self.parkedSnapshot;
    UIWindowScene *scene = [self windowSceneForEntry];
    __weak typeof(self) wself = self;
    [SPAppPicker presentFromWindowScene:scene bundleIDs:@[parked] onPick:^(NSString *bid) {
        __strong typeof(wself) self = wself;
        if (!self || self.pickerGeneration != generation) return;
        self.busy = NO;
        self.parkedBundleID = nil;
        self.parkedSnapshot = nil;
        if (![SPSettings enabled] || SPPaneController.shared.active || !scene ||
            scene.activationState != UISceneActivationStateForegroundActive ||
            ![[UIApplication sharedApplication].connectedScenes containsObject:scene]) return;
        SPLog(@"picked %@", bid);
        if (needPark) { [self.card dismissAnimated:nil]; self.card = nil; }
        [SPParkCard dismissAll];
        BOOL ok = [SPPaneController.shared startWithTop:parked bottom:bid windowScene:scene topSnapshot:snapshot];
        SPLog(@"start top=%@ bottom=%@ -> %d", parked, bid, (int)ok);
        // 先由 pane 同步占有会话，再异步拉起上半屏；不引入阻塞主线程的 openApplication。
        if (ok) [SPHost openAppAsync:parked completion:^(BOOL okOpen) {
            SPLog(@"icon entry: ensure top %@ opened=%d", parked, (int)okOpen);
        }];
        else if (!SPPaneController.shared.active) [SPHost openAppAsync:bid completion:nil];
    } onCancel:^{
        __strong typeof(wself) self = wself;
        if (!self || self.pickerGeneration != generation) return;
        self.busy = NO;
        self.parkedBundleID = nil;
        self.parkedSnapshot = nil;
        if (![SPSettings enabled] || SPPaneController.shared.active) return;
        SPLog(@"picker cancel -> back to home, dismiss %@", parked);
        [self returnToHomeDismissingApp:parked];
    }];
}

// 取消挂起：先把 App 推回后台（不是 SIGKILL，避免 SpringBoard 重启），
// 再确保我们自己的窗口全部收掉，最后回桌面。
- (void)returnToHomeDismissingApp:(NSString *)bundleID {
    if (SPPaneController.shared.active) return; // 迟到的 picker 取消不能拆掉新的分屏
    ++_pickerGeneration;
    _busy = NO;
    [SPParked cancelPendingSession];
    [SPParkCard dismissAll];
    self.card = nil;
    self.parkedBundleID = nil;
    self.parkedSnapshot = nil;

    // 1) 让 App 退到后台：把它自己「收起」，SpringBoard 就会回到桌面
    if (bundleID.length) {
        @try {
            [SPHost suspendAppToBackground:bundleID];
        } @catch (NSException *e) { SPLog(@"suspend ex %@", e.reason); }
    }
    // picker 已经通过 registry 只释放自己的窗口，不能 killAll 误杀另一个会话。
    // 最后按一次 home（这台机器 homePress 不可用时它会自己跳过）
    [SPHost homePress];
    SPLog(@"returnToHome done");
}

// 从主屏图标长按菜单进入：这个 App 作为上半屏，弹面板选下半屏
- (void)startSplitFromIconForBundleID:(NSString *)bundleID {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self startSplitFromIconForBundleID:bundleID]; });
        return;
    }
    if (![bundleID isKindOfClass:[NSString class]] || !bundleID.length || ![SPSettings enabled]) return;
    // 快速再次长按不能改写正在展示的 picker 所属 App/快照；旧回调仍由其 generation 验证。
    if (_busy || [SPAppPicker isPresenting] || SPPaneController.shared.active) return;
    SPLog(@"icon entry: %@", bundleID);
    [SPParkCard dismissAll];
    self.card = nil;
    self.parkedBundleID = bundleID;
    self.parkedSnapshot = [self snapshotScreen];
    [self presentPickerForSplitWithParked:bundleID needPark:NO];
}

- (void)presentPickerForSwap {
    if (![SPSettings enabled] || _busy || [SPAppPicker isPresenting] || !SPPaneController.shared.active) return;
    _busy = YES;
    NSUInteger generation = ++_pickerGeneration;
    __weak typeof(self) wself = self;
    NSString *top = SPPaneController.shared.topBundleID;
    NSString *bottom = SPPaneController.shared.bottomBundleID;
    NSMutableArray *extra = [NSMutableArray array];
    if (top.length) [extra addObject:top];
    if (bottom.length) [extra addObject:bottom];
    UIWindowScene *scene = [self windowSceneForEntry];
    [SPAppPicker presentFromWindowScene:scene bundleIDs:extra onPick:^(NSString *bid) {
        __strong typeof(wself) self = wself;
        if (!self || self.pickerGeneration != generation) return;
        self.busy = NO;
        if (![SPSettings enabled] || !SPPaneController.shared.active ||
            ![SPPaneController.shared.topBundleID isEqualToString:top] ||
            ![SPPaneController.shared.bottomBundleID isEqualToString:bottom]) return;
        SPLog(@"swap pick %@", bid);
        [SPPaneController.shared replaceBundleID:bid];
    } onCancel:^{
        __strong typeof(wself) self = wself;
        if (self.pickerGeneration == generation) self.busy = NO;
    }];
}

@end