#import "SPGesture.h"
#import "SPCompat.h"
#import "SPHost.h"
#import "SPSettings.h"
#import "SPParkCard.h"
#import "SPAppPicker.h"
#import "SPPaneController.h"
#import "SPLog.h"

// 入口层。三条通道，按可靠性排序：
//   1) hook 系统 home 手势的 touchesEnded（Duo 实证这条路能接住）
//   2) 自己往 SpringBoard 主窗口挂一个 pan（钩子失效时的备份，但会和系统抢触摸）
//   3) 状态栏双击 —— 完全不经手势，纯兜底，装完试这个最快
// 每个分支都落日志，装上没反应时能一眼看出断在哪。

static const CGFloat kBottomStrip = 110.0;   // 起手必须在这条带里（pt）
static const CGFloat kStatusStrip = 54.0;    // 状态栏双击命中区

@interface SPGesture () <SPParkCardDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, strong) SPParkCard *card;
@property (nonatomic, copy) NSString *parkedBundleID;
@property (nonatomic, assign) BOOL busy;
@property (nonatomic, weak) UIWindowScene *scene;
@property (nonatomic, assign) CGFloat dragStartY;
@property (nonatomic, strong) UIPanGestureRecognizer *fallbackPan;
@property (nonatomic, strong) UITapGestureRecognizer *statusTap;
@property (nonatomic, weak) UIView *panHost;
@end

@implementation SPGesture

+ (instancetype)shared {
    static SPGesture *inst; static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [SPGesture new]; });
    return inst;
}

#pragma mark - 装入口

- (void)installInWindowScene:(UIWindowScene *)scene {
    if (scene) _scene = scene;
    [[NSNotificationCenter defaultCenter] removeObserver:self name:SPNotifyChanged object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(settingsChanged)
                                                 name:SPNotifyChanged object:nil];

    UIWindowScene *ws = scene ?: _scene;
    if (!ws) { SPLog(@"install: no window scene yet"); return; }
    [self installStatusTapInScene:ws];
    if (!self.hooksAvailable) [self installFallbackPanInScene:ws];
    SPLog(@"install: scene ok hooks=%d pan=%d", self.hooksAvailable, self.fallbackPan != nil);
}

- (UIView *)springBoardWindowInScene:(UIWindowScene *)scene {
    // SpringBoard 的主窗口在 normal level，且铺满整屏
    UIWindow *best = nil;
    for (UIWindow *w in scene.windows) {
        if (w.isHidden || w.alpha < 0.01) continue;
        if (w.windowLevel > UIWindowLevelStatusBar) continue;
        if (!best || w.windowLevel < best.windowLevel) best = w;
    }
    if (!best) best = [UIApplication sharedApplication].windows.firstObject;
    return best;
}

- (void)installStatusTapInScene:(UIWindowScene *)scene {
    if (_statusTap) return;
    UIView *host = [self springBoardWindowInScene:scene];
    if (!host) { SPLog(@"statusTap: no host window"); return; }
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(statusDoubleTapped:)];
    tap.numberOfTapsRequired = 2;
    tap.delegate = self;
    tap.cancelsTouchesInView = NO;
    [host addGestureRecognizer:tap];
    _statusTap = tap;
    SPLog(@"statusTap installed on %@", NSStringFromClass(host.class));
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

- (void)settingsChanged {
    if (![SPSettings enabled] && self.card) [self.card dismissAnimated:nil];
}

#pragma mark - 手势代理

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)touch {
    CGPoint p = [touch locationInView:g.view];
    CGFloat h = g.view.bounds.size.height;
    if (g == _statusTap) return p.y <= kStatusStrip;
    if (g == _fallbackPan) return p.y >= h - kBottomStrip;
    return YES;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if (g == _fallbackPan) {
        CGPoint v = [(UIPanGestureRecognizer *)g velocityInView:g.view];
        return v.y < 0;    // 只认往上
    }
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

#pragma mark - 状态栏双击（兜底入口）

- (void)statusDoubleTapped:(UITapGestureRecognizer *)g {
    if (![SPSettings enabled]) return;
    NSString *front = [self frontmostBundleID];
    SPLog(@"status double tap, front=%@ active=%d", front, (int)SPPaneController.shared.active);
    if (SPPaneController.shared.active) { [self presentPickerForSwap]; return; }
    if (!front.length) return;
    [self presentPickerForSplitWithParked:front needPark:NO];
}

#pragma mark - 备份 pan

- (void)fallbackPanned:(UIPanGestureRecognizer *)g {
    CGPoint p = [g locationInView:g.view];
    if (g.state == UIGestureRecognizerStateBegan) {
        _dragStartY = p.y;
        return;
    }
    if (g.state != UIGestureRecognizerStateEnded) return;
    CGPoint t = [g translationInView:g.view];
    CGPoint v = [g velocityInView:g.view];
    [self consumeHomePan:nil translation:t velocity:v];
}

#pragma mark - 前台 App

- (NSString *)frontmostBundleID {
    id mgr = [SPHost mainDisplaySceneManager];
    if (mgr) {
        NSArray *scenes = SPMsg0(mgr, @"allScenes");
        if ([scenes isKindOfClass:[NSArray class]]) {
            for (id s in scenes) {
                if (!SPBool0(s, @"isActive")) continue;
                id handle = SPMsg0(s, @"handle");
                id app = SPMsg0(handle, @"application");
                id bid = SPMsg0(app, @"bundleIdentifier");
                if ([bid isKindOfClass:[NSString class]] && [(NSString *)bid length]) return bid;
            }
        }
    }
    Class ac = NSClassFromString(@"SBApplicationController");
    id ctrl = ac ? SPMsg0(ac, @"sharedInstance") : nil;
    NSArray *apps = SPMsg0(ctrl, @"allApplications");
    if ([apps isKindOfClass:[NSArray class]]) {
        for (id app in apps) {
            if (!SPBool0(app, @"isForeground")) continue;
            id bid = SPMsg0(app, @"bundleIdentifier");
            if ([bid isKindOfClass:[NSString class]]) return bid;
        }
    }
    return nil;
}

- (NSString *)displayNameForBundleID:(NSString *)bid {
    id app = [SPHost applicationProxyForBundleID:bid];
    id name = SPMsg0(app, @"displayName");
    return [name isKindOfClass:[NSString class]] ? name : bid;
}

#pragma mark - 上滑判定

- (void)handleHomePanBegan:(CGPoint)loc {
    _dragStartY = loc.y;
}

- (BOOL)consumeHomePan:(UIPanGestureRecognizer *)pan translation:(CGPoint)translation velocity:(CGPoint)velocity {
    if (![SPSettings enabled]) return NO;
    if (_busy) return NO;

    CGSize screen = [UIScreen mainScreen].bounds.size;
    CGFloat h = screen.height;
    // 有些情况下 recognizer 的 translation 已被清零，velocity 还能用，两个都算一遍取大的
    CGFloat up = MAX(-translation.y, -velocity.y * 0.18);
    CGFloat need = MAX(150.0, h * [SPSettings parkThreshold] * 0.75);
    BOOL fromBottom = (_dragStartY >= h - kBottomStrip);
    SPLog(@"pan up=%.0f need=%.0f startY=%.0f fromBottom=%d active=%d",
          up, need, _dragStartY, fromBottom, (int)SPPaneController.shared.active);

    if (!fromBottom) return NO;
    if (up < need) return NO;

    NSString *front = [self frontmostBundleID];
    if (!front.length) { SPLog(@"no frontmost"); return NO; }

    if (SPPaneController.shared.active) { [self presentPickerForSwap]; return YES; }
    if (self.card) { [self.card dismissAnimated:nil]; self.card = nil; }
    [self parkForegroundApp:front];
    return YES;
}

#pragma mark - 挂起

- (UIImage *)snapshotScreen {
    UIWindow *key = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isHidden || w.alpha < 0.01) continue;
        if (w.windowLevel > UIWindowLevelStatusBar) continue;
        key = w;
    }
    if (!key) return nil;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:key.bounds.size];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [key drawViewHierarchyInRect:key.bounds afterScreenUpdates:NO];
    }];
}

- (void)parkForegroundApp:(NSString *)bundleID {
    _busy = YES;
    _parkedBundleID = bundleID;
    UIImage *shot = [self snapshotScreen];
    SPLog(@"park %@ snapshot=%@", bundleID, shot ? @"ok" : @"nil");

    SPParkCard *card = [[SPParkCard alloc] initWithSnapshot:shot
                                                    bundleID:bundleID
                                                        name:[self displayNameForBundleID:bundleID]];
    card.delegate = self;
    self.card = card;
    CGSize s = [UIScreen mainScreen].bounds.size;
    CGRect from = CGRectMake(s.width * 0.5 - 40, s.height - 120, 80, 126);
    __weak typeof(self) wself = self;
    [card presentInWindowScene:_scene fromRect:from completion:^{
        __strong typeof(wself) self = wself;
        self.busy = NO;
        SPLog(@"card presented");
        [self sendHomePress];
    }];
}

- (void)sendHomePress {
    Class uic = NSClassFromString(@"SBUIController");
    id ui = uic ? SPMsg0(uic, @"sharedInstance") : nil;
    SEL sel = NSSelectorFromString(@"handleHomeButtonSinglePressUp");
    if (ui && [ui respondsToSelector:sel]) {
        ((void (*)(id, SEL))objc_msgSend)(ui, sel);
        SPLog(@"home pressed");
    } else {
        SPLog(@"home press unavailable");
    }
}

#pragma mark - 卡片 / 面板

- (void)parkCardDidTap:(SPParkCard *)card {
    SPLog(@"card tap %@", card.bundleID);
    [self presentPickerForSplitWithParked:card.bundleID needPark:YES];
}

- (void)presentPickerForSplitWithParked:(NSString *)parked needPark:(BOOL)needPark {
    _busy = YES;
    __weak typeof(self) wself = self;
    [SPAppPicker presentFromWindowScene:_scene bundleIDs:@[parked ?: @""] onPick:^(NSString *bid) {
        __strong typeof(wself) self = wself;
        SPLog(@"picked %@", bid);
        if (needPark) { [self.card dismissAnimated:nil]; self.card = nil; }
        BOOL ok = [SPPaneController.shared startWithTop:parked bottom:bid windowScene:self.scene];
        SPLog(@"start top=%@ bottom=%@ -> %d", parked, bid, (int)ok);
        if (!ok) [SPHost openApp:bid suspended:NO completion:nil];
        self.busy = NO;
    } onCancel:^{
        __strong typeof(wself) self = wself;
        SPLog(@"picker cancel");
        self.busy = NO;
    }];
}

- (void)presentPickerForSwap {
    _busy = YES;
    __weak typeof(self) wself = self;
    NSString *top = SPPaneController.shared.topBundleID;
    NSString *bottom = SPPaneController.shared.bottomBundleID;
    NSMutableArray *extra = [NSMutableArray array];
    if (top.length) [extra addObject:top];
    if (bottom.length) [extra addObject:bottom];
    [SPAppPicker presentFromWindowScene:_scene bundleIDs:extra onPick:^(NSString *bid) {
        __strong typeof(wself) self = wself;
        SPLog(@"swap pick %@", bid);
        [SPPaneController.shared replaceBundleID:bid];
        self.busy = NO;
    } onCancel:^{
        __strong typeof(wself) self = wself;
        self.busy = NO;
    }];
}

@end