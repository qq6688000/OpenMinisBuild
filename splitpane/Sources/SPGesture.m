#import "SPGesture.h"
#import "SPCompat.h"
#import "SPSettings.h"
#import "SPHost.h"
#import "SPParkCard.h"
#import "SPAppPicker.h"
#import "SPPaneController.h"

static NSString *const SPDiagPath = @"/var/mobile/Library/Logs/SplitPane.log";

static void SPLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[SplitPane] %@", msg);
    // 真机抓日志：/var/mobile/Library/Logs/SplitPane.log（RootHide 下也常见）
    static NSDateFormatter *df; static dispatch_once_t o; dispatch_once(&o, ^{
        df = [NSDateFormatter new]; df.dateFormat = @"HH:mm:ss.SSS";
    });
    static NSMutableString *buf; static double lastAt;
    if (!buf) buf = [NSMutableString new];
    [buf appendFormat:@"%@ %@\n", [df stringFromDate:[NSDate date]], msg];
    double now = CFAbsoluteTimeGetCurrent();
    if (now - lastAt < 1.0) return;
    lastAt = now;
    [buf writeToFile:SPDiagPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [buf setString:@""];
}

@interface SPGesture () <SPParkCardDelegate>
@property (nonatomic, strong) SPParkCard *card;
@property (nonatomic, copy) NSString *parkedBundleID;
@property (nonatomic, assign) BOOL busy;
@property (nonatomic, weak) UIWindowScene *scene;
@property (nonatomic, assign) CGFloat dragStartY;
@end

@implementation SPGesture

+ (instancetype)shared {
    static SPGesture *inst; static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [SPGesture new]; });
    return inst;
}

- (void)installInWindowScene:(UIWindowScene *)scene {
    _scene = scene;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(settingsChanged)
                                                 name:SPNotifyChanged object:nil];
}

- (void)settingsChanged {
    if (![SPSettings enabled] && self.card) [self.card dismissAnimated:nil];
}

#pragma mark - 当前前台 App

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
                if ([bid isKindOfClass:[NSString class]] && [bid length]) return bid;
            }
        }
    }
    // 降级：系统应用列表里找 running、isForeground 的
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

#pragma mark - 上滑

- (void)handleHomePanBegan:(CGPoint)loc {
    _dragStartY = loc.y;
}

// pan 在 SpringBoard 的主窗口里，屏幕坐标 = 窗口坐标（竖屏）
- (BOOL)consumeHomePan:(UIPanGestureRecognizer *)pan translation:(CGPoint)translation velocity:(CGPoint)velocity {
    if (![SPSettings enabled]) return NO;
    if (_busy) return NO;
    CGSize screen = [UIScreen mainScreen].bounds.size;
    CGFloat h = screen.height;
    UIGestureRecognizerState st = pan.state;

    if (st != UIGestureRecognizerStateEnded) return NO;

    CGFloat up = -translation.y;
    CGFloat startY = _dragStartY;
    SPLog(@"pan end up=%.0f startY=%.0f v=%.0f active=%d card=%d", up, startY, velocity.y,
          (int)SPPaneController.shared.active, (int)(self.card != nil));
    // 起手必须在底部带（PV 语义：从 home 条往上拎）
    if (startY < h - 90) return NO;
    if (up < h * [SPSettings parkThreshold] * 0.7) return NO;

    NSString *front = [self frontmostBundleID];
    if (!front.length) { SPLog(@"no frontmost"); return NO; }

    if (SPPaneController.shared.active) {
        // 分屏进行中：再滑一次 = 换上面的 App
        [self presentPickerForSwap];
        return YES;
    }
    if (self.card) {
        // 卡片已经挂着：再滑一次就重新拎起来（换一张）
        [self.card dismissAnimated:nil];
        self.card = nil;
    }
    [self parkForegroundApp:front];
    return YES;
}

- (UIImage *)snapshotScreen {
    UIWindow *key = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (!w.isHidden && w.alpha > 0.01) key = w;
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
    NSString *name = [self displayNameForBundleID:bundleID];

    SPParkCard *card = [[SPParkCard alloc] initWithSnapshot:shot bundleID:bundleID name:name];
    card.delegate = self;
    self.card = card;
    CGSize s = [UIScreen mainScreen].bounds.size;
    CGRect from = CGRectMake(s.width * 0.5 - 40, s.height - 120, 80, 128);
    [card presentInWindowScene:_scene fromRect:from completion:^{
        self.busy = NO;
        // 卡片出现后再把 App 退回桌面；不这样做的话 App 还在前台，
        // 选完第二个 App 就被系统直接拉到前面 → 分屏一建立就散
        [self sendHomePress];
    }];
}

- (void)sendHomePress {
    Class uic = NSClassFromString(@"SBUIController");
    id ui = uic ? SPMsg0(uic, @"sharedInstance") : nil;
    if (ui && [ui respondsToSelector:NSSelectorFromString(@"handleHomeButtonSinglePressUp")]) {
        ((void (*)(id, SEL))objc_msgSend)(ui, NSSelectorFromString(@"handleHomeButtonSinglePressUp"));
        SPLog(@"home pressed");
    } else {
        SPLog(@"home press unavailable");
    }
}

#pragma mark - 卡片

- (void)parkCardDidTap:(SPParkCard *)card {
    SPLog(@"card tap %@", card.bundleID);
    [self presentPickerForSplitWithParked:card.bundleID];
}

- (void)presentPickerForSplitWithParked:(NSString *)parked {
    _busy = YES;
    __weak typeof(self) wself = self;
    [SPAppPicker presentFromWindowScene:_scene bundleIDs:@[parked] onPick:^(NSString *bid) {
        __strong typeof(wself) self = wself;
        SPLog(@"picked %@", bid);
        // 卡片收起来，分屏立刻起
        [self.card dismissAnimated:nil];
        self.card = nil;
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
    [SPAppPicker presentFromWindowScene:_scene bundleIDs:@[top ?: @"", bottom ?: @""] onPick:^(NSString *bid) {
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