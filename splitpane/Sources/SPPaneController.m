#import "SPPaneController.h"
#import "SPHost.h"
#import "SPSettings.h"
#import "SPCompat.h"
#import "SPLog.h"
#import "SPRepair.h"
#import "SPParkCard.h"
#import "SPWindowRegistry.h"
#import <objc/runtime.h>

// ════════════════════════════════════════════════════════════════════════════
// 竖屏上下分屏
//  · 两块面板各是一个 overlay window，里面放「参考尺寸 = 面板尺寸」的 SBSceneView，
//    App 会按半屏重排（不是缩放整张手机画面）。
//  · 中间接缝可拖 / 可捏，拖只改布局，不重建 scene。
//  · 每块底下垫冻结快照：后台 scene 被系统收走时立刻露出来，绝不黑屏。
//  · 退出 = 把主 App 交回系统全屏（openApp:suspended:NO），再拆窗。
// ════════════════════════════════════════════════════════════════════════════

static const CGFloat kChromeHeight = 46.0;
static const CGFloat kSeamHeight = 26.0;
static const CGFloat kMinPaneRatio = 0.22;
static const CGFloat kMaxPaneRatio = 0.78;

// ---------------------------------------------------------------- 接缝视图

@interface SPSplitView : UIView
@property (nonatomic, strong) UIView *topContainer;
@property (nonatomic, strong) UIView *bottomContainer;
@property (nonatomic, strong) UIView *seam;
@property (nonatomic, strong) UIView *grabber;
@property (nonatomic, assign) CGFloat splitRatio;
@property (nonatomic, copy) void (^onSeamMoved)(void);
@property (nonatomic, copy) void (^onSeamEnded)(void);
@end

@implementation SPSplitView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor blackColor];
        _topContainer = [UIView new];
        _bottomContainer = [UIView new];
        for (UIView *c in @[_topContainer, _bottomContainer]) {
            c.backgroundColor = [UIColor blackColor];
            c.layer.cornerRadius = 14;
            c.layer.cornerCurve = kCACornerCurveContinuous;
            c.layer.masksToBounds = YES;
            [self addSubview:c];
        }
        _seam = [UIView new];
        _seam.backgroundColor = [UIColor clearColor];
        _seam.userInteractionEnabled = YES;
        _grabber = [UIView new];
        _grabber.backgroundColor = [UIColor colorWithWhite:1 alpha:0.45];
        _grabber.layer.cornerRadius = 2.5;
        _grabber.userInteractionEnabled = NO;
        [_seam addSubview:_grabber];
        [self addSubview:_seam];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panned:)];
        [_seam addGestureRecognizer:pan];
        _splitRatio = 0.5;
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    CGFloat usable = b.size.height;
    CGFloat topH = round((usable - kSeamHeight) * _splitRatio);
    CGFloat w = b.size.width - 8;
    _topContainer.frame = CGRectMake(4, 0, w, topH);
    _seam.frame = CGRectMake(0, topH, b.size.width, kSeamHeight);
    _bottomContainer.frame = CGRectMake(4, topH + kSeamHeight, w, usable - topH - kSeamHeight);
    _grabber.frame = CGRectMake((b.size.width - 64) / 2.0, (kSeamHeight - 5) / 2.0, 64, 5);
}

- (void)panned:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan && [SPSettings haptics]) {
        UIImpactFeedbackGenerator *h = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [h impactOccurred];
    }
    CGPoint p = [g locationInView:self];
    CGFloat usable = MAX(self.bounds.size.height - kSeamHeight, 1);
    CGFloat r = p.y / usable;
    self.splitRatio = MIN(MAX(r, kMinPaneRatio), kMaxPaneRatio);
    [self setNeedsLayout];
    if (self.onSeamMoved) self.onSeamMoved();
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        if (self.onSeamEnded) self.onSeamEnded();
    }
    if (g.state == UIGestureRecognizerStateEnded && [SPSettings haptics]) {
        UIImpactFeedbackGenerator *h = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleRigid];
        [h impactOccurred];
    }
}

@end

// ---------------------------------------------------------------- 引擎

@interface SPOverlayWindow : UIWindow
@end
@implementation SPOverlayWindow

// 底部那条（home 手势区）不接触摸：返回 nil 让事件落到 SpringBoard，
// 否则系统上滑手势永远收不到，用户就回不了桌面。
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    CGFloat h = self.bounds.size.height;
    // 底部 70pt（系统 home 手势的起手区）完全透传，事件落到 SpringBoard
    if (point.y >= h - 70.0) return nil;
    UIView *hit = [super hitTest:point withEvent:event];
    return hit;
}

// 必须能成为 key window，否则里面的 App 弹不出键盘、点进去也没光标
// 不能抢 key：一旦成为 key window，触摸事件就归我们，SpringBoard 上挂的
// home 手势识别器收不到 → 用户永远回不了桌面。
- (BOOL)canBecomeKeyWindow { return YES; }
@end

@interface SPPaneController ()
@property (nonatomic, strong) SPOverlayWindow *window;
@property (nonatomic, strong) SPSplitView *split;
@property (nonatomic, strong) UIView *chrome;
@property (nonatomic, strong) SPHost *topHost;
@property (nonatomic, strong) SPHost *bottomHost;
@property (nonatomic, copy, readwrite) NSString *topBundleID;
@property (nonatomic, copy, readwrite) NSString *bottomBundleID;
@property (nonatomic, assign, readwrite) BOOL active;
@property (nonatomic, strong) NSTimer *heartbeat;
@property (nonatomic, strong) UIImage *topSnapshot;
@property (nonatomic, strong) UIPanGestureRecognizer *homeSwipe;
@property (nonatomic, assign) CGFloat homeSwipeStartY;
@property (nonatomic, assign) BOOL homeSwipeArmed;
@property (nonatomic, assign) BOOL resizeCoalescing;
@property (nonatomic, assign) BOOL pendingResize;
@property (nonatomic, strong) UIImage *bottomSnapshot;
- (void)flushResize;
- (void)startHeartbeat;
@end

@implementation SPPaneController

+ (instancetype)shared {
    static SPPaneController *inst; static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [SPPaneController new]; });
    return inst;
}

#pragma mark 顶部控制条

- (UIView *)buildChromeWithWidth:(CGFloat)width {
    UIView *bar = [UIView new];
    bar.backgroundColor = [UIColor blackColor];
    bar.frame = CGRectMake(0, 0, width, kChromeHeight);

    UILabel *title = [UILabel new];
    title.text = @"上下分屏";
    title.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    title.textColor = [UIColor colorWithWhite:1 alpha:0.65];
    title.frame = CGRectMake(0, 0, 120, kChromeHeight);
    title.textAlignment = NSTextAlignmentCenter;
    title.center = CGPointMake(width / 2.0, kChromeHeight / 2.0);
    title.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [bar addSubview:title];

    UIImageView *handle = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 56, 5)];
    handle.backgroundColor = [UIColor colorWithWhite:1 alpha:0.28];
    handle.layer.cornerRadius = 2.5;
    handle.center = CGPointMake(width / 2.0, kChromeHeight - 12);
    handle.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [bar addSubview:handle];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setTitle:@"×" forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:24 weight:UIFontWeightLight];
    [close setTitleColor:[UIColor colorWithWhite:1 alpha:0.85] forState:UIControlStateNormal];
    close.frame = CGRectMake(10, (kChromeHeight - 34) / 2.0, 34, 34);
    close.layer.cornerRadius = 17;
    close.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
    [close addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:close];

    UIButton *swap = [UIButton buttonWithType:UIButtonTypeSystem];
    [swap setTitle:@"交换" forState:UIControlStateNormal];
    swap.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    [swap setTitleColor:[UIColor colorWithWhite:1 alpha:0.8] forState:UIControlStateNormal];
    swap.frame = CGRectMake(width - 70, (kChromeHeight - 30) / 2.0, 60, 30);
    swap.layer.cornerRadius = 15;
    swap.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
    swap.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [swap addTarget:self action:@selector(swapTapped) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:swap];
    // 顶部区域整体允许接收点击（否则父视图不吃触摸时按钮点不到）
    bar.userInteractionEnabled = YES;
    return bar;
}

#pragma mark 启动

- (BOOL)startWithTop:(NSString *)top bottom:(NSString *)bottom windowScene:(UIWindowScene *)scene topSnapshot:(UIImage *)snap {
    if (_active || !top.length || !bottom.length) return NO;
    // 分屏一旦建立，挂起卡片就没有存在的意义了；它的独立窗口必须立刻销毁
    [SPParkCard dismissAll];
    if (!scene) scene = self.foregroundWindowScene;
    if (!scene) return NO;

    SPOverlayWindow *w = (SPOverlayWindow *)[SPWindowRegistry makeWindowWithScene:scene
                                                                            level:UIWindowLevelStatusBar + 10   // 必须高于状态栏；键盘另作处理
                                                                          keyable:YES];
    w.backgroundColor = [UIColor blackColor];
    w.frame = scene.coordinateSpace.bounds;
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = [UIColor blackColor];
    w.rootViewController = vc;
    w.hidden = NO;

    UIView *chrome = [self buildChromeWithWidth:w.bounds.size.width];
    chrome.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [vc.view addSubview:chrome];
    // chrome 必须在最上层：split 一旦因为坐标系错位盖到顶部，× 就点不到了（已发生）
    chrome.layer.zPosition = 1000;

    // 底部留 34pt 给系统的 home 手势，否则上滑回桌面会被我们整块吞掉
    CGFloat bottomInset = 60.0;   // 给系统 home 手势留足空间，否则回不了桌面
    SPSplitView *split = [[SPSplitView alloc] initWithFrame:CGRectMake(0, kChromeHeight, w.bounds.size.width,
                                                                       w.bounds.size.height - kChromeHeight - bottomInset)];
    // 底部那条不能吃触摸，让系统 home 手势直接穿过去
    split.clipsToBounds = YES;
    split.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    __weak typeof(self) wself = self;
    split.onSeamMoved = ^{ [wself resizePanes]; };
    split.onSeamEnded = ^{ [wself flushResize]; };
    [vc.view addSubview:split];
    [vc.view bringSubviewToFront:chrome];

    // 键盘联动：弹出时让位，收起后回到状态栏之上
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillShow:)
                                                 name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillHide:)
                                                 name:UIKeyboardWillHideNotification object:nil];

    // 出口 0：从底部往上滑 = 回桌面。
    // 系统的 home 手势会被我们的窗口挡住（日志实证：从底部起手只能拿到 70~126pt），
    // 所以自己认一次：位移超过 80pt 就当作「回桌面」，直接退出分屏。
    UIPanGestureRecognizer *homeSwipe = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(homeSwipePanned:)];
    homeSwipe.maximumNumberOfTouches = 1;
    homeSwipe.cancelsTouchesInView = NO;
    homeSwipe.delegate = (id<UIGestureRecognizerDelegate>)self;
    [vc.view addGestureRecognizer:homeSwipe];
    _homeSwipe = homeSwipe;

    // 出口 1：三指下滑
    UISwipeGestureRecognizer *escape = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(escapeSwipe:)];
    escape.numberOfTouchesRequired = 3;
    escape.direction = UISwipeGestureRecognizerDirectionDown;
    escape.delegate = (id<UIGestureRecognizerDelegate>)self;
    [vc.view addGestureRecognizer:escape];

    // 出口 2：三指双击（不依赖任何可点区域，× 被盖住时靠它）
    UITapGestureRecognizer *triple = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(escapeSwipe:)];
    triple.numberOfTapsRequired = 2;
    triple.numberOfTouchesRequired = 3;
    triple.delegate = (id<UIGestureRecognizerDelegate>)self;
    triple.cancelsTouchesInView = NO;
    triple.delaysTouchesEnded = NO;
    [vc.view addGestureRecognizer:triple];

    // 出口 3：右上角整块热区也可退出（点不到 × 时往右上角戳两下）
    UITapGestureRecognizer *corner = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(escapeSwipe:)];
    corner.numberOfTapsRequired = 2;
    corner.delegate = (id<UIGestureRecognizerDelegate>)self;
    corner.cancelsTouchesInView = NO;
    [self.chrome addGestureRecognizer:corner];

    _window = w;
    _chrome = chrome;
    _split = split;
    _topBundleID = [top copy];
    _bottomBundleID = [bottom copy];

    // 关键：这里绝不等待 open 完成。
    // LSApplicationWorkspace.openApplicationWithBundleID: 实测阻塞 10 秒（日志实证），
    // 所以扔后台、立刻把两块面板搭起来，哪边有 scene 就先挂哪边，
    // 没 scene 的那边留着占位 + 自动重试，App 起来了自然接上。
    [SPHost openAppAsync:bottom completion:^(BOOL ok) {
        SPLog(@"open bottom %@ -> %d", bottom, (int)ok);
    }];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(wself) self = wself;
        if (!self || !self->_window) return;
        SPHost *topHost = [[SPHost alloc] initWithBundleID:top];
        self->_topHost = topHost;
        [topHost attachWhenReady:split.topContainer inWindowScene:scene attempts:5 interval:1.5];
        if (snap) [topHost installSnapshot:snap];
        SPLog(@"top attach diag=%@ live=%d", topHost.lastDiag ?: @"-", (int)topHost.live);

        SPHost *bottomHost = [[SPHost alloc] initWithBundleID:bottom];
        self->_bottomHost = bottomHost;
        if (snap) [bottomHost installSnapshot:snap];   // 没画面时垫住，绝不露黑
        [bottomHost attachWhenReady:split.bottomContainer inWindowScene:scene attempts:8 interval:1.5];
        SPLog(@"bottom attach diag=%@ live=%d", bottomHost.lastDiag ?: @"-", (int)bottomHost.live);

        [self resizePanes];
        self->_active = YES;
        [self startHeartbeat];
    });
    return YES;
}

#pragma mark - UIGestureRecognizerDelegate

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

// 关键：homeSwipe 只能在底部条内接收触摸。
// 之前它挂在整个 vc.view 上，用户点顶部的 × / 交换 时手指的微小位移
// 会被它当成 pan 抢走，按钮永远收不到 touchUpInside（日志实证：全程零次 closeTapped）。
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)touch {
    if (g == _homeSwipe) {
        CGPoint p = [touch locationInView:g.view];
        return p.y >= g.view.bounds.size.height - 110.0;
    }
    return YES;
}

// 键盘可见时把分屏窗口降到键盘层以下，否则键盘被盖住；收起后恢复。
- (void)keyboardWillShow:(NSNotification *)note {
    if (!_window) return;
    _window.windowLevel = UIWindowLevelNormal + 1;
}
- (void)keyboardWillHide:(NSNotification *)note {
    if (!_window) return;
    _window.windowLevel = UIWindowLevelStatusBar + 10;
}

- (void)startHeartbeat {
    __weak typeof(self) wself = self;
    [_heartbeat invalidate];
    _heartbeat = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *t) {
        __strong typeof(wself) self = wself;
        if (!self || !self->_active) { [t invalidate]; return; }
        @try {
            if (!self->_topHost) [t invalidate];
        } @catch (__unused NSException *e) {}
    }];
}

- (void)resizePanes {
    if (!_split) return;
    if (_chrome && _chrome.superview) [_chrome.superview bringSubviewToFront:_chrome];
    [_split setNeedsLayout];
    [_split layoutIfNeeded];
    // 布局立刻改（本地、便宜），但推给远端 scene 要节流：
    // updateSettings 是往 FrontBoard 发的跨进程事务，拖动时每秒 60 次会把整机拖死。
    _pendingResize = YES;
    if (_resizeCoalescing) return;
    _resizeCoalescing = YES;
    __weak typeof(self) wself = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(wself) self = wself;
        if (!self) return;
        self->_resizeCoalescing = NO;
        if (!self->_pendingResize) return;
        self->_pendingResize = NO;
        [self->_topHost setFrameSize:self->_split.topContainer.bounds.size];
        [self->_bottomHost setFrameSize:self->_split.bottomContainer.bounds.size];
    });
}

- (void)flushResize {
    // 松手那一刻一定把最终尺寸推一次，保证画面和接缝对齐
    _pendingResize = NO;
    [_topHost setFrameSize:_split.topContainer.bounds.size];
    [_bottomHost setFrameSize:_split.bottomContainer.bounds.size];
}

#pragma mark 操作

// 底部上滑 = 回桌面。
// 严格要求「从底部条起手」：中缝拖动、面板内滚动都会产生 pan，
// 不限制起点就会把接缝拖动吃掉（0.5.3 日志里的 up=-319 就是这个）。
- (void)homeSwipePanned:(UIPanGestureRecognizer *)g {
    CGPoint p = [g locationInView:g.view];
    CGFloat h = g.view.bounds.size.height;

    if (g.state == UIGestureRecognizerStateBegan) {
        _homeSwipeStartY = p.y;
        _homeSwipeArmed = (p.y >= h - 110.0);
        return;
    }
    if (!_homeSwipeArmed) return;
    if (g.state != UIGestureRecognizerStateEnded) return;

    _homeSwipeArmed = NO;
    CGFloat up = _homeSwipeStartY - p.y;
    CGPoint v = [g velocityInView:g.view];
    SPLog(@"homeSwipe: startY=%.0f up=%.0f v=%.0f (need 300 & v<=-600)", _homeSwipeStartY, up, v.y);
    // 阈值和 SPGesture 保持一致：普通点击/滚动不会误触
    if (up >= 300.0 && v.y <= -600.0) {
        SPLog(@"homeSwipe -> stop (back to home)");
        [self stopWithCompletion:nil];
    }
}

- (void)escapeSwipe:(UIGestureRecognizer *)g {
    SPLog(@"escape swipe -> stop");
    [self stopWithCompletion:nil];
}

- (void)closeTapped {
    SPLog(@"closeTapped");
    [self stopWithCompletion:nil];
}

- (void)swapTapped {
    if (!_bottomBundleID.length) return;
    NSString *t = _topBundleID, *b = _bottomBundleID;
    UIWindowScene *scene = _window.windowScene;
    [self stopWithCompletion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self startWithTop:b bottom:t windowScene:scene topSnapshot:nil];
        });
    }];
}

- (void)replaceBundleID:(NSString *)bundleID {
    if ([bundleID isEqualToString:_bottomBundleID]) { [self swapTapped]; return; }
    [self replaceTopWithBundleID:bundleID];
}

- (void)replaceTopWithBundleID:(NSString *)bundleID {
    if (!_active || !bundleID.length) return;
    if ([bundleID isEqualToString:_topBundleID]) return;
    SPHost *fresh = [[SPHost alloc] initWithBundleID:bundleID];
    if (![fresh attachToContainer:_split.topContainer inWindowScene:_window.windowScene]) return;
    [_topHost detach];
    _topHost = fresh;
    _topBundleID = [bundleID copy];
    [self resizePanes];
}

- (UIWindowScene *)foregroundWindowScene {
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive)
            return (UIWindowScene *)s;
    }
    return [UIApplication sharedApplication].windows.firstObject.windowScene;
}

#pragma mark 收工

- (void)teardown {
    // 先把两个 scene 的尺寸恢复成全屏，再拆窗口。
    // 顺序不能反：拆掉窗口后我们就不再持有 scene 的接管权，恢复会失效。
    // 卡片窗口层级很高，不清理会一直挡在桌面上（也会挡点击）
    [SPParkCard dismissAll];

    SPDumpScenes("before-teardown");
    @try {
        [_topHost restoreOriginalSceneSettings];
        [_bottomHost restoreOriginalSceneSettings];
        // 兜底：把「被压小」的 scene 全扫一遍恢复（漏掉某个 host 也不会留下残废 App）
        [SPRepair restoreAllScenes];
        SPLog(@"repair report: %@", [SPRepair lastReport]);
    } @catch (NSException *e) { SPLog(@"restore ex %@", e.reason); }

    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_heartbeat invalidate];
    _heartbeat = nil;
    [_topHost detach];
    [_bottomHost detach];
    _topHost = nil;
    _bottomHost = nil;
    _split = nil;
    _chrome = nil;
    UIWindow *w = _window;
    _window = nil;
    _active = NO;
    // 必须彻底撤掉：只 hidden 不释放会留一个隐形窗口，影响桌面点击/系统手势
    [SPWindowRegistry releaseWindow:w];
    // 无论前面哪一步漏了什么，这里把所有自建窗口一并收掉
    [SPWindowRegistry killAll];
    SPDumpScenes("after-teardown");
}

- (void)stopWithCompletion:(void (^)(void))completion {
    if (!_active) { if (completion) completion(); return; }
    NSString *main = _topBundleID ?: _bottomBundleID;
    _active = NO;
    // 先把窗口从屏幕上撤掉（teardown 会用 releaseWindow 真正销毁它，
    // 所以这里先抓一份引用做 hidden，避免 teardown 后 _window 已是 nil）
    _window.hidden = YES;
    [self teardown];
    // 退出必须瞬时完成：拆窗即回到桌面。
    // 不要把 App 重新 open 一遍 —— 那是跨进程同步调用，日志实证会卡 10 秒。
    SPLog(@"stop: window torn down, main=%@", main);
    // 让 App 自己重新走一遍全屏布局（scene 尺寸已恢复，但内部排版要它自己重算）
    if (main.length) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [SPHost reactivateApp:main];
        });
    }
    if (completion) completion();
}

@end